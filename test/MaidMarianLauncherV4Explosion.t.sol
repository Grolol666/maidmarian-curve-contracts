// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MaidMarianEtfFactory as Factory } from "../src/MaidMarianEtfFactory.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianEtfV4 as EtfV4 } from "../src/MaidMarianEtfV4.sol";
import { MaidMarianTokenLauncher as Launcher } from "../src/MaidMarianTokenLauncher.sol";
import { MaidMarianLaunchCurve as Curve, IPoolManagerV4, CURVE_EXPLOSION } from "../src/MaidMarianLaunchCurve.sol";
import { MaidMarianLaunchHook as Hook } from "../src/MaidMarianLaunchHook.sol";
import { TokenMock, UniversalRouterMock } from "./Mocks.sol";
import { CurveBase } from "./MaidMarianLaunchCurve.t.sol";

/**
 * Offline, "ETF is seed": an ETF curve launched with `CURVE_EXPLOSION` bonds by
 * redeeming 70 % of its real quote in kind (no swap) and opening one token / leg pool per leg it received,
 * each at the curve's price in shares times the shares' TWAP value expressed in that leg, so every pool
 * opens at one price in USDG; the 30 % and both pots stay in shares; the fund's USDG goes to the owner's
 * pot; every pool takes one tiny swap at once. Fuzzed over the last buy, the tax, the target and the
 * fund's cash, to the unit; a paused leg; the hook; a sandwich; the doors after the bond; the claims at the
 * floor; the leg pools' fees; the gas of the bonding buy on 4, 5 and 6 legs. The real launcher, curve,
 * token, v4 factory and v4 ETF code over the curve suite's mocks; the deployed v4 and the real PoolManager
 * are `MaidMarianLauncherV4Explosion.fork.t.sol`.
 *
 *   forge test --match-contract MaidMarianLauncherV4ExplosionTest -vv
 */
contract MaidMarianLauncherV4ExplosionTest is CurveBase {
    bytes32 internal constant BONDED = keccak256("Bonded(address,bytes32,address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function _useEtfFactory() internal override {
        _switchToV4();
    }

    function setUp() public override {
        super.setUp();
        address[8] memory who = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            usdg.approve(address(cf), type(uint256).max);
        }
    }

    // ----------------------------------------------------------- helpers ---

    struct Pool {
        address leg;
        uint256 setAside;
        uint256 poolTokens;
        uint256 poolQuote;
        uint256 burned;
    }

    /// The deploy script's ETF targets, the owner's list set to them, `pick` choosing one.
    function _pickTarget(uint8 pick) internal returns (uint256 shares) {
        uint256[] memory list = new uint256[](8);
        (list[0], list[1], list[2], list[3], list[4], list[5], list[6], list[7]) = (100e18, 1000e18, 5000e18, 8000e18, 15_000e18, 20_000e18, 25_000e18, 30_000e18);
        vm.prank(owner);
        cf.setEtfThresholds(list);
        shares = list[pick % 8];
        etfPick = shares;
    }

    /// An "ETF is seed" curve by `maker` on a, b, c (50 / 30 / 20). `cash`: the fund then holds USDG of its
    /// own, 1 % of its seed, as a rebalance leaves it (its count and its balance written, slot 25 of the v4).
    function _launchSeed(uint16 tax, bool cash) internal returns (Etf etf, Curve curve) {
        Etf.Route[] memory seed = _seedRoutes(_legsAbc());
        vm.prank(maker);
        (etf, curve) = cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, etfPick, tax, 1_000_000_000, SEED_USDG, seed, 1, new address[](0), CURVE_EXPLOSION, _noRoutes(), 0
        );
        if (cash) {
            uint256 extra = SEED_USDG / 100;
            usdg.mint(address(etf), extra);
            vm.store(address(etf), bytes32(uint256(25)), bytes32(EtfV4(address(etf)).usdgHeld() + extra));
        }
        _approveAll(curve, address(etf));
        address[8] memory who = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker];
        for (uint256 i = 0; i < who.length; i++) {
            vm.startPrank(who[i]);
            _tok(curve).approve(address(cf), type(uint256).max);
            vm.stopPrank();
        }
        vm.warp(vm.getBlockTimestamp() + 3);
    }

    /// `bob`'s bonding buy of `usdgIn` through the launcher, no bond routes.
    function _bondBuy(Etf etf, Curve curve, uint256 usdgIn) internal returns (Vm.Log[] memory logs) {
        Etf.Route[] memory r = _buyRoutes(etf, usdgIn, false);
        vm.recordLogs();
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), usdgIn, r, 1, 1, _noRoutes(), 0);
        logs = vm.getRecordedLogs();
        assertTrue(curve.bonded());
    }

    /// A curve bonded by `bob`'s 9 000 USDG after `alice`'s 4 000, at the 8 000 share target.
    function _bonded(bool cash) internal returns (Etf etf, Curve curve) {
        (etf, curve) = _launchSeed(100, cash);
        _buyUsdg(curve, alice, 4000e6);
        _bondBuy(etf, curve, 9000e6);
    }

    function _pools(Vm.Log[] memory logs, address curve) internal pure returns (Pool[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == curve && logs[i].topics[0] == BONDED) n++;
        }
        out = new Pool[](n);
        uint256 k;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != curve || logs[i].topics[0] != BONDED) continue;
            Pool memory p;
            (p.leg, p.setAside, p.poolTokens, p.poolQuote, p.burned) = abi.decode(logs[i].data, (address, uint256, uint256, uint256, uint256));
            out[k++] = p;
        }
    }

    /// The ETF's `RedeemedInKind` of the bond: what each leg and the USDG paid the curve.
    function _redeemed(Vm.Log[] memory logs, address etf) internal pure returns (uint256 shares, uint256[] memory amounts, uint256 usdgOut, uint16 forfeited) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == etf && logs[i].topics[0] == EtfV4.RedeemedInKind.selector) {
                (shares,,,,,, amounts, usdgOut, forfeited) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256[], uint256, uint16));
                return (shares, amounts, usdgOut, forfeited);
            }
        }
        revert("no RedeemedInKind");
    }

    /// The bond's swap in pool `id` (`BondSwapped`): its tokens in and its output.
    function _swapIn(Vm.Log[] memory logs, address curve, bytes32 id) internal pure returns (uint256 tokensIn) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == curve && logs[i].topics[0] == Curve.BondSwapped.selector && logs[i].topics[1] == id) (tokensIn,) = abi.decode(logs[i].data, (uint256, uint256));
        }
    }

    function _swapOut(Vm.Log[] memory logs, address curve, bytes32 id) internal pure returns (uint256 quoteOut) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == curve && logs[i].topics[0] == Curve.BondSwapped.selector && logs[i].topics[1] == id) (, quoteOut) = abi.decode(logs[i].data, (uint256, uint256));
        }
    }

    function _swaps(Vm.Log[] memory logs, address curve) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(pm) && logs[i].topics[0] == SWAP && address(uint160(uint256(logs[i].topics[2]))) == curve) n++;
        }
    }

    function _id(Curve curve, address currency) internal view returns (bytes32) {
        return keccak256(abi.encode(curve.poolKeyIn(currency)));
    }

    /// `sqrtPriceX96` of `amount` of `currency` per `tokens` tokens, as the curve computes it.
    function _sqrt(Curve curve, address currency, uint256 amount, uint256 tokens) internal view returns (uint160) {
        (uint256 a1, uint256 a0) = curve.token() < currency ? (amount, tokens) : (tokens, amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(Math.sqrt(Math.mulDiv(a1, 1 << 192, a0)));
    }

    /// The token's price in a pool opened at `sqrtP`, in `currency` units per token unit, scaled by 1e36.
    function _price(Curve curve, address currency, uint256 sqrtP) internal view returns (uint256) {
        uint256 p = Math.mulDiv(sqrtP * 1e18, sqrtP * 1e18, 1 << 192);
        return curve.token() < currency ? p : Math.mulDiv(1e36, 1e36, p);
    }

    function _twap(address leg) internal view returns (uint256 price) {
        (price,) = factory.getTradablePriceUsdg(leg);
    }

    /// Leg a traded by the router at `bps` of its price both ways: a pool moved within the block.
    function _moveLegA(uint256 bps) internal {
        router.setPairRate(address(a), address(usdg), 250e6 * bps / 10_000);
        router.setPairRate(address(usdg), address(a), 1e48 / (250e18 * bps / 10_000));
    }

    // -------------------------------------------------------- the bond ---

    /**
     * A last buy of any size from 3/4 to 250 x the target in USDG (half of it bought before), any tax,
     * any of the eight targets, the fund with or without USDG of its own: bought whole (the buyer's USDG
     * down by exactly what he paid, no leg, no share). The bond redeems in kind exactly 70 % of the real
     * quote (`real - real x 30 %`) to the curve; each leg's pool opens, in leg order, at `got_i / tokens_i`,
     * `tokens_i = (budget x t / q) x worth_i / value` with `worth_i` the leg received at its TWAP and
     * `value` the budget's due at the TWAPs plus its USDG, to the unit of the sqrt price; every pool at the
     * same price in USDG (to 1e-9); each pool holding what `Bonded` says (the PoolManager's balance of the
     * leg), at most what was received, the rest of it (the rounding and the swap's output) in the owner's
     * pot to the unit; the fund's USDG in the owner's pot to the unit, no pool of USDG; one swap per pool,
     * moving its price by under 1e-6; the 30 % in shares in `protocolFees`, the curve's shares exactly its
     * two pots; the tokens pooled plus burned the reserve.
     */
    function testFuzz_AnEtfIsSeedBondOpensOnePoolPerLegAtOnePrice(uint256 usdgIn, uint16 tax, uint8 pick, bool cash) public {
        tax = uint16(bound(tax, 0, 1000));
        uint256 target = _pickTarget(pick);
        (Etf etf, Curve curve) = _launchSeed(tax, cash);
        assertTrue(curve.explodes());
        assertEq(curve.usdgCutPct(), 0);
        if (target > 100e18) _buyUsdg(curve, holders[0], target / 2e12);
        // Half the target bought before, 3 / 4 more always bonds; at 100 shares nothing before, 5 / 4 (fee, a 10 % tax).
        usdgIn = bound(usdgIn, target > 100e18 ? target * 3 / 4e12 : target * 5 / 4e12, target * 250 / 1e12);
        uint256[4] memory before = [usdg.balanceOf(bob), a.balanceOf(bob), b.balanceOf(bob), c.balanceOf(bob)];
        uint256 c0 = curve.creatorFees() + curve.unbookedShares();
        uint256 p0 = curve.protocolFees();
        Vm.Log[] memory logs = _bondBuy(etf, curve, usdgIn);
        assertEq(before[0] - usdg.balanceOf(bob), usdgIn, "his USDG, to the wei");
        assertEq(a.balanceOf(bob) + b.balanceOf(bob) + c.balanceOf(bob), before[1] + before[2] + before[3], "no leg");
        assertEq(etf.balanceOf(bob), 0, "no share");

        (uint256 q, uint256 t) = curve.getReserves();
        uint256 real = q - curve.phantomQuote();
        uint256 budget = real - real * 3000 / 10_000;
        (uint256 redeemed, uint256[] memory got, uint256 usdgOut, uint16 forfeited) = _redeemed(logs, address(etf));
        assertEq(redeemed, budget, "70 % of the real quote, in kind");
        assertEq(forfeited, 0);
        assertEq(curve.ownerPot(address(usdg)) >= usdgOut, true);
        if (cash) assertGt(usdgOut, 0, "the fund had USDG of its own");

        Pool[] memory pools = _pools(logs, address(curve));
        assertEq(pools.length, 3, "one pool per leg");
        assertEq(_swaps(logs, address(curve)), 3, "one swap in each pool at the bond");
        address[3] memory legs = [address(a), address(b), address(c)];
        uint256 value = usdgOut * 1e12;
        for (uint256 i = 0; i < 3; i++) {
            value += Math.mulDiv(got[i], _twap(legs[i]), 1e18);
        }
        uint256 atPrice = Math.mulDiv(budget, t, q);
        uint256 usdgPrice0;
        uint256 tokensPooled;
        uint256 swapIn;
        for (uint256 i = 0; i < 3; i++) {
            Pool memory p = pools[i];
            assertEq(p.leg, legs[i], "in leg order");
            bytes32 id = _id(curve, legs[i]);
            uint256 tokens = Math.mulDiv(atPrice, Math.mulDiv(got[i], _twap(legs[i]), 1e18), value);
            assertEq(pm.openedAt(id), _sqrt(curve, legs[i], got[i], tokens), "the pool opens at got / tokens");
            uint256 inUsdg = Math.mulDiv(_price(curve, legs[i], pm.openedAt(id)), _twap(legs[i]), 1e18);
            if (i == 0) usdgPrice0 = inUsdg;
            else assertApproxEqRel(inUsdg, usdgPrice0, 1e9, "every pool at one price in USDG");
            assertApproxEqRel(pm.sqrtPriceOf(id), pm.openedAt(id), 1e12, "the swap moves the price by under 1e-6");
            uint256 out = _swapOut(logs, address(curve), id);
            assertEq(p.poolQuote - out, IERC20(legs[i]).balanceOf(address(pm)), "the pool holds its position less the swap's output");
            assertLe(p.poolQuote, got[i]);
            assertEq(curve.ownerPot(legs[i]), got[i] - p.poolQuote + out, "the leg's rest and the swap's output in the owner's pot, to the unit");
            assertEq(IERC20(legs[i]).balanceOf(address(curve)), curve.ownerPot(legs[i]), "the curve holds its pot alone");
            tokensPooled += p.poolTokens;
            swapIn += _swapIn(logs, address(curve), id);
            assertTrue(curve.isBondPool(id));
            // forge-lint: disable-next-line(incorrect-shift)
            assertEq(curve.explodedLegs() & (1 << i), 1 << i);
        }
        assertEq(tokensPooled + swapIn, _tok(curve).balanceOf(address(pm)), "the pools hold the positions and the swaps' tokens");
        assertEq(pools[2].burned, t - tokensPooled - swapIn, "every other token burned");
        assertEq(_tok(curve).totalSupply(), curve.supply() - pools[2].burned);
        assertApproxEqRel(tokensPooled, Math.mulDiv(atPrice, value - usdgOut * 1e12, value), 1e12, "the tokens at the curve's price for the legs");
        assertEq(pools[2].setAside, real - budget, "the 30 %, in shares, on the last pool");
        assertEq(curve.bondSetAside(), real - budget);
        assertEq(usdg.balanceOf(address(curve)), curve.ownerPot(address(usdg)), "the fund's USDG in the owner's pot, to the unit");
        assertEq(curve.ownerPot(address(usdg)), usdgOut, "and nothing else in it");
        assertEq(etf.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees(), "solvent to the unit, in shares");
        assertGe(curve.creatorFees(), c0);
        assertGe(curve.protocolFees(), p0 + real - budget);
        address[] memory bp = curve.bondPools();
        assertEq(bp.length, 3);
        assertEq(curve.ownerPot(address(etf)), 0);
    }

    /// The fund's cash, said apart (author, 2026-10-23): an ETF holding USDG at the bond seeds every leg
    /// pool from its legs alone (no pool of the token and USDG, none of the shares), and the USDG its
    /// redeem brought is in the owner's pot to the unit, which he claims.
    function test_TheFundsUsdgAtTheBondGoesToTheOwnersPotAndOpensNoPool() public {
        (Etf etf, Curve curve) = _launchSeed(100, true);
        _buyUsdg(curve, alice, 4000e6);
        Vm.Log[] memory logs = _bondBuy(etf, curve, 9000e6);
        (,, uint256 usdgOut,) = _redeemed(logs, address(etf));
        assertGt(usdgOut, 0);
        assertEq(curve.ownerPot(address(usdg)), usdgOut, "to the unit");
        assertEq(pm.openedAt(_id(curve, address(usdg))), 0, "no USDG pool");
        assertEq(pm.openedAt(_id(curve, address(etf))), 0, "no shares pool");
        assertEq(usdg.balanceOf(address(pm)), 0, "the PoolManager holds no USDG");
        uint256 o0 = usdg.balanceOf(owner);
        vm.prank(owner);
        curve.claimOwnerPot(address(usdg), owner);
        assertEq(usdg.balanceOf(owner) - o0, usdgOut);
    }

    /// Leg b refusing the transfer to the curve at the bond (a pause, a blocklist): the in-kind redeem lets
    /// it fail, b's part stays in the fund (its count untouched by the redeem), b's pool is not opened (no
    /// pool, `bondPools` a and c, `explodedLegs` bits 0 and 2), and a's and c's pools open at the very
    /// prices the bond without the pause gives (the forfeited leg's value is in the price, its tokens are
    /// burned). The after-bond doors refuse b's pool (`NoSuchPool`), the hook refuses a stranger opening it.
    function test_APausedLegKeepsItsPoolClosedAndItsPartInTheFund() public {
        (Etf etf, Curve curve) = _launchSeed(100, false);
        _buyUsdg(curve, alice, 4000e6);
        uint256 snap = vm.snapshotState();
        _bondBuy(etf, curve, 9000e6);
        uint160 honestA = pm.openedAt(_id(curve, address(a)));
        uint160 honestC = pm.openedAt(_id(curve, address(c)));
        uint256 honestBurn = _tok(curve).totalSupply();
        vm.revertToState(snap);

        vm.mockCallRevert(address(b), abi.encodeWithSelector(IERC20.transfer.selector, address(curve)), "paused");
        uint256 bHeld = EtfV4(address(etf)).legHeld(1);
        Vm.Log[] memory logs = _bondBuy(etf, curve, 9000e6);
        (,,, uint16 forfeited) = _redeemed(logs, address(etf));
        assertEq(forfeited, 1 << 1, "b forfeited");
        assertGt(EtfV4(address(etf)).legHeld(1), bHeld, "b's part stays in the fund (the mint added, the redeem took none)");
        assertEq(b.balanceOf(address(curve)), 0);
        assertEq(pm.openedAt(_id(curve, address(b))), 0, "no pool for b");
        assertEq(curve.explodedLegs(), 5);
        address[] memory bp = curve.bondPools();
        assertEq(bp.length, 2);
        (address p0, address p1) = (bp[0], bp[1]);
        assertEq(p0, address(a));
        assertEq(p1, address(c));
        assertEq(_pools(logs, address(curve)).length, 2);
        assertEq(_swaps(logs, address(curve)), 2);
        assertEq(pm.openedAt(_id(curve, address(a))), honestA, "a at the honest price");
        assertEq(pm.openedAt(_id(curve, address(c))), honestC, "c at the honest price");
        assertLt(_tok(curve).totalSupply(), honestBurn, "b's tokens burned");
        assertEq(etf.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees(), "solvent in shares");

        vm.clearMockedCalls();
        b.mint(bob, 1e18);
        vm.startPrank(bob);
        b.approve(address(cf), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Launcher.NoSuchPool.selector, address(curve), address(b)));
        cf.buyAfterBond(address(curve), address(b), 1e18, _noRoutes(), 1);
        vm.stopPrank();
        IPoolManagerV4.PoolKey memory key = curve.poolKeyIn(address(b));
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Hook.NotLaunchedCurve.selector, stranger));
        pm.initialize(key, 1 << 96);
    }

    /// No one but the curve opens a leg pool: before the bond a stranger's `initialize` of any leg's key,
    /// at any price, is refused by the hook (`isBondPool` false outside the curve's own unlock), and the
    /// bond opens all three.
    function test_NoOneButItsCurveOpensALegPool() public {
        (Etf etf, Curve curve) = _launchSeed(100, false);
        _buyUsdg(curve, alice, 4000e6);
        address stranger = makeAddr("stranger");
        address[3] memory legs = [address(a), address(b), address(c)];
        for (uint256 i = 0; i < 3; i++) {
            IPoolManagerV4.PoolKey memory key = curve.poolKeyIn(legs[i]);
            assertFalse(curve.isBondPool(keccak256(abi.encode(key))));
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(Hook.NotLaunchedCurve.selector, stranger));
            pm.initialize(key, 1 << 96);
        }
        _bondBuy(etf, curve, 9000e6);
        for (uint256 i = 0; i < 3; i++) {
            assertGt(pm.openedAt(_id(curve, legs[i])), 0);
        }
        assertFalse(curve.isBondPool(_id(curve, address(usdg))));
        assertFalse(curve.isBondPool(_id(curve, address(etf))));
    }

    /// A sandwich at the bond takes nothing: the bond swaps no leg, so leg a's pool pushed 10 % down in the
    /// block before the bonding buy changes no pool's opening price (each priced at its 30 min TWAP, which
    /// the block does not move) and the buy goes through; the push only changes what the buyer's own mint
    /// paid for leg a. The same bond at the legs' prices opens at the same prices.
    function test_ASandwichAtTheBondMovesNoOpeningPrice() public {
        (Etf etf, Curve curve) = _launchSeed(100, false);
        _buyUsdg(curve, alice, 4000e6);
        uint256 snap = vm.snapshotState();
        Vm.Log[] memory honest = _bondBuy(etf, curve, 9000e6);
        (, uint256[] memory gotHonest,,) = _redeemed(honest, address(etf));
        uint256[3] memory sqrtHonest;
        address[3] memory legs = [address(a), address(b), address(c)];
        for (uint256 i = 0; i < 3; i++) {
            sqrtHonest[i] = pm.openedAt(_id(curve, legs[i]));
        }
        vm.revertToState(snap);
        _moveLegA(9000);
        Vm.Log[] memory pushed = _bondBuy(etf, curve, 9000e6);
        (, uint256[] memory gotPushed,,) = _redeemed(pushed, address(etf));
        for (uint256 i = 0; i < 3; i++) {
            if (gotPushed[i] == gotHonest[i]) assertEq(pm.openedAt(_id(curve, legs[i])), sqrtHonest[i], "the same opening price");
            uint256 inUsdg = Math.mulDiv(_price(curve, legs[i], pm.openedAt(_id(curve, legs[i]))), _twap(legs[i]), 1e18);
            uint256 inUsdg0 = Math.mulDiv(_price(curve, legs[0], pm.openedAt(_id(curve, legs[0]))), _twap(legs[0]), 1e18);
            assertApproxEqRel(inUsdg, inUsdg0, 1e9, "one price in USDG, pushed or not");
        }
    }

    /// The choice: `CURVE_EXPLOSION` (255) is kept by the curve (`explodes`, `CurveLaunched`'s terms 255);
    /// 254 is `BadUsdgCut`; a cut curve does not explode.
    function test_EtfIsSeedIsChosenAtLaunchAndKept() public {
        vm.recordLogs();
        (, Curve curve) = _launchSeed(0, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 launched = keccak256("CurveLaunched(address,address,address,address,uint256,(address,bool,uint128,uint16,uint96,uint8),string,string,bytes,(string,string,string,string,string))");
        Launcher.Terms memory terms;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(cf) && logs[i].topics[0] == launched) {
                (,, terms,,,,) = abi.decode(logs[i].data, (address, uint256, Launcher.Terms, string, string, bytes, Factory.Profile));
            }
        }
        assertEq(terms.usdgCutPct, 255);
        assertTrue(curve.explodes());
        assertFalse(curve.graduatesToUsdg());
        assertEq(curve.bondPools().length, 3, "every leg before the bond");
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Launcher.BadUsdgCut.selector, uint256(254)));
        cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, etfPick, 0, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), 254, _noRoutes(), 0
        );
        vm.prank(maker);
        (, Curve cut) = cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, etfPick, 0, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), 50, _noRoutes(), 0
        );
        assertFalse(cut.explodes());
        assertEq(cut.usdgCutPct(), 50);
        assertEq(cf.MAX_EXPLOSION_LEGS(), 10, "every reserve ETF the factory makes");
    }

    /// The bond's swap in every pool of every mode (author, 2026-10-23: "un swap dans chaque pool"): a plain
    /// quote's bond, the cuts 0, 25, 50, 75 and 100, each pool it opens has one `Swap` by the curve at the
    /// bond (`BondSwapped` matching it), its price moved by under 1e-6 from its opening; the curve's books
    /// whole after it (USDG pots and set-aside, or shares).
    function test_EveryPoolOfEveryBondTakesOneSwapAtTheBond() public {
        Curve plain = _launch(address(qt), 0);
        vm.recordLogs();
        vm.prank(holders[1]);
        plain.buy(12_000e18, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(plain.bonded());
        assertEq(_swaps(logs, address(plain)), 1, "the plain pool");
        assertApproxEqRel(pm.sqrtPriceOf(plain.poolId()), pm.openedAt(plain.poolId()), 1e12);
        assertEq(qt.balanceOf(address(plain)), plain.creatorFees() + plain.protocolFees(), "the swap's output with the 30 %");

        uint8[5] memory cuts = [0, 25, 50, 75, 100];
        for (uint256 k = 0; k < 5; k++) {
            vm.prank(maker);
            (Etf etf, Curve curve) = cf.launchWithEtf{ value: FEE }(
                "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, etfPick, 100, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), cuts[k], _noRoutes(), 0
            );
            vm.warp(vm.getBlockTimestamp() + 3);
            uint256[] memory one = new uint256[](3);
            (one[0], one[1], one[2]) = (1, 1, 1);
            Etf.Route[] memory br = cuts[k] == 0 ? _noRoutes() : _sellRoutes(etf, one);
            Etf.Route[] memory r = _buyRoutes(etf, 12_000e6, false);
            vm.recordLogs();
            vm.prank(bob);
            cf.buyWithUsdg(address(curve), 12_000e6, r, 1, 1, br, 1);
            logs = vm.getRecordedLogs();
            assertTrue(curve.bonded());
            address[] memory pools = curve.bondPools();
            assertEq(_swaps(logs, address(curve)), pools.length, "one swap per pool");
            uint256 swapped;
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].emitter == address(curve) && logs[i].topics[0] == Curve.BondSwapped.selector) swapped++;
            }
            assertEq(swapped, pools.length, "each said by BondSwapped");
            for (uint256 i = 0; i < pools.length; i++) {
                bytes32 id = _id(curve, pools[i]);
                assertGt(pm.openedAt(id), 0);
                assertApproxEqRel(pm.sqrtPriceOf(id), pm.openedAt(id), 1e12, "the swap moves the price by under 1e-6");
            }
            if (curve.graduatesToUsdg()) assertEq(usdg.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees(), "solvent in USDG");
            else assertEq(etf.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees(), "solvent in shares");
        }
    }

    // ------------------------------------------------------ after the bond ---

    /// After the bond each leg pool trades through the launcher, named by its leg: a buy pays the leg and
    /// gets the tokens, a sale pays the tokens and gets the leg (`PAY_IN_KIND` only, `BadPayout(2)`
    /// otherwise; `TooLittleOut` under the minimum); the USDG and shares pools do not exist (`NoSuchPool`).
    /// Nothing stays with the launcher, no share with anyone.
    function test_EachLegPoolTradesThroughTheLauncher() public {
        (Etf etf, Curve curve) = _bonded(false);
        address[3] memory legs = [address(a), address(b), address(c)];
        vm.startPrank(carol);
        for (uint256 i = 0; i < 3; i++) {
            TokenMock(legs[i]).mint(carol, 10e18);
            IERC20(legs[i]).approve(address(cf), type(uint256).max);
            uint256 bought = cf.buyAfterBond(address(curve), legs[i], 1e17, _noRoutes(), 1);
            assertGt(bought, 0);
            _tok(curve).approve(address(cf), type(uint256).max);
            vm.expectRevert(abi.encodeWithSelector(Launcher.BadPayout.selector, uint8(2)));
            cf.sellAfterBond(address(curve), legs[i], bought, 0, 2, _noRoutes(), 0, 0);
            vm.expectPartialRevert(Launcher.TooLittleOut.selector);
            cf.sellAfterBond(address(curve), legs[i], bought, 0, 1, _noRoutes(), type(uint256).max, 0);
            uint256 l0 = IERC20(legs[i]).balanceOf(carol);
            uint256 back = cf.sellAfterBond(address(curve), legs[i], bought, 0, 1, _noRoutes(), 1, 0);
            assertEq(IERC20(legs[i]).balanceOf(carol) - l0, back);
            assertGt(back, 1e17 * 97 / 100, "back within the two 1 % fees");
            assertEq(IERC20(legs[i]).balanceOf(address(cf)), 0);
        }
        vm.expectRevert(abi.encodeWithSelector(Launcher.NoSuchPool.selector, address(curve), address(usdg)));
        cf.buyAfterBond(address(curve), address(usdg), 1e6, _noRoutes(), 1);
        vm.expectRevert(abi.encodeWithSelector(Launcher.NoSuchPool.selector, address(curve), address(etf)));
        cf.buyAfterBond(address(curve), address(etf), 1e6, _noRoutes(), 1);
        vm.stopPrank();
        assertEq(etf.balanceOf(carol) + etf.balanceOf(address(cf)), 0);
        assertEq(_tok(curve).balanceOf(address(cf)), 0);
    }

    /// The leg pools' fees, collected by anyone: the tokens 70 / 30 out to the creator and the owner, each
    /// leg's fees booked 70 % to `creatorPot` and 30 % to `ownerPot`, claimed by each alone.
    function test_TheLegPoolsFeesAreBookedToTheCreatorsAndTheOwnersPots() public {
        (, Curve curve) = _bonded(false);
        vm.startPrank(carol);
        a.mint(carol, 10e18);
        a.approve(address(cf), type(uint256).max);
        cf.buyAfterBond(address(curve), address(a), 5e18, _noRoutes(), 1);
        vm.stopPrank();
        uint256 owner0 = curve.ownerPot(address(a));
        uint256 fees0 = pm.fees0(_id(curve, address(a)));
        uint256 fees1 = pm.fees1(_id(curve, address(a)));
        uint256 legFees = curve.token() < address(a) ? fees1 : fees0;
        assertGt(legFees, 0);
        curve.collectPoolFees();
        uint256 toOwner = legFees * 3000 / 10_000;
        assertEq(curve.ownerPot(address(a)) - owner0, toOwner, "30 % to the owner's pot");
        assertEq(curve.creatorPot(address(a)), legFees - toOwner, "70 % to the creator's pot");
        vm.prank(carol);
        vm.expectRevert(Curve.NotCreator.selector);
        curve.claimCreatorPot(address(a), carol);
        uint256 m0 = a.balanceOf(maker);
        vm.prank(maker);
        curve.claimCreatorPot(address(a), maker);
        assertEq(a.balanceOf(maker) - m0, legFees - toOwner);
        assertEq(curve.creatorPot(address(a)), 0);
        assertEq(a.balanceOf(address(curve)), curve.ownerPot(address(a)), "the curve holds the owner's pot alone");
    }

    /// The owner's 30 % after the bond, in shares: claimed in USDG only at the bond's floor (each leg sold
    /// whole, at least its TWAP value less its pool's fee and 1 %, whatever the routes say): routes at 0
    /// floor bond's floor pass at the legs' prices, a route that sells nothing is `BondRouteMissing`, leg a
    /// pushed 10 % down reverts on the floor; in kind it always leaves, `allowFail` as any sale.
    function test_TheOwnersThirtyPercentLeavesToUsdgAtTheFloorOrInKind() public {
        (Etf etf, Curve curve) = _bonded(false);
        uint256 amount = curve.protocolFees() / 4;
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(address(curve), amount);
        Etf.Route[] memory routes = _sellRoutes(etf, due);
        Etf.Route[] memory missing = _sellRoutes(etf, due);
        missing[1].amountIn = 0;
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(Curve.BondRouteMissing.selector, 1));
        curve.claim(true, amount, owner, 2, missing, 0, 0);
        _moveLegA(9000);
        vm.expectRevert(UniversalRouterMock.V3TooLittleReceived.selector);
        curve.claim(true, amount, owner, 2, routes, 0, 0);
        _moveLegA(10_000);
        uint256 o0 = usdg.balanceOf(owner);
        curve.claim(true, amount, owner, 2, routes, 0, 0);
        assertGt(usdg.balanceOf(owner), o0, "paid in USDG");
        uint256 a0 = a.balanceOf(owner);
        curve.claim(true, amount, owner, 1, _noRoutes(), 0, 0);
        assertGt(a.balanceOf(owner), a0, "and in kind");
        vm.stopPrank();
        assertEq(etf.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees());
    }

    // ---------------------------------------------------------------- gas ---

    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i = 0; i < data.length; i++) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// The bonding buy of an "ETF is seed" curve on 4, 5 and 6 mock legs through the launcher, accounts
    /// cooled, intrinsic and calldata added. Logged; the chain's figure is the fork's.
    function test_Gas_TheExplodingBuyOnFourFiveAndSixLegs() public {
        uint256[3] memory ns = [uint256(4), 5, 6];
        for (uint256 k = 0; k < 3; k++) {
            uint256 n = ns[k];
            Factory.LegSpec[] memory l = new Factory.LegSpec[](n);
            for (uint256 i = 0; i < n; i++) {
                (TokenMock tk,) = _token(string.concat("G", vm.toString(k), vm.toString(i)), 10 + i);
                // forge-lint: disable-next-line(unsafe-typecast)
                l[i] = Factory.LegSpec({ token: address(tk), bps: uint16(10_000 / n + (i == 0 ? 10_000 % n : 0)) });
            }
            vm.prank(maker);
            (Etf etf, Curve curve) = cf.launchWithEtf{ value: FEE }(
                "Robin Coin", "ROBIN", "", _noProfileC(), l, 200, 0, 8000e18, 100, 1_000_000_000, SEED_USDG, _seedRoutes(l), 1, new address[](0), CURVE_EXPLOSION, _noRoutes(), 0
            );
            vm.warp(vm.getBlockTimestamp() + 3);
            Etf.Route[] memory r = _buyRoutes(etf, 11_000e6, false);
            address[6] memory touched = [address(cf), address(factory), address(usdg), address(router), address(pm), address(curve)];
            for (uint256 i = 0; i < touched.length; i++) {
                vm.cool(touched[i]);
            }
            for (uint256 i = 0; i < n; i++) {
                vm.cool(l[i].token);
            }
            vm.cool(address(etf));
            vm.prank(bob);
            uint256 g = gasleft();
            cf.buyWithUsdg(address(curve), 11_000e6, r, 1, 1, _noRoutes(), 0);
            uint256 used = g - gasleft() + _intrinsic(abi.encodeCall(cf.buyWithUsdg, (address(curve), 11_000e6, r, 1, 1, _noRoutes(), 0)));
            assertTrue(curve.bonded());
            assertEq(curve.bondPools().length, n);
            emit log_named_uint(string.concat("exploding buy, mocks, legs ", vm.toString(n)), used);
            assertLt(used, 6_500_000);
        }
    }
}
