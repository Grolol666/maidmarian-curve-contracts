// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { oneThreshold } from "./CurveFixtures.sol";
import { Vm } from "forge-std/Vm.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MaidMarianEtfFactory as Factory } from "../src/MaidMarianEtfFactory.sol";
import { MaidMarianEtfFactoryV4 as FactoryV4 } from "../src/MaidMarianEtfFactoryV4.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianTokenLauncher as Launcher } from "../src/MaidMarianTokenLauncher.sol";
import { MaidMarianLaunchCurve as Curve, IPoolManagerV4, curveBuy } from "../src/MaidMarianLaunchCurve.sol";
import { TokenMock, UniversalRouterMock } from "./Mocks.sol";
import { MaidMarianLaunchHook as Hook } from "../src/MaidMarianLaunchHook.sol";
import { CurveBase } from "./MaidMarianLaunchCurve.t.sol";

/**
 * Offline: an ETF curve's creator chooses at launch, for good, the bond pool's
 * other currency, USDG by default or the reserve ETF's shares (`backedByEtf`). On USDG the buy that bonds
 * redeems every share the curve holds (its real quote and both fee pots) with the buyer's `bondRoutes`,
 * each set to its leg's whole due, so no leg stays; the USDG is the curve's balance change, at least
 * `minUsdgAtBond`; each pot becomes its part of it, rounded down, the real quote the rest; the token /
 * USDG pool opens at the curve's price times the redeem's USDG per share with 70 % of the real quote's
 * USDG, the rest booked to the protocol, every other token burned. Then the token trades against USDG
 * directly and the fees are claimed in USDG. Fuzzed over the last buy's size and the creator tax, to the
 * unit; the refusals; the seed that bonds in the launch; the gas of the bonding buy on ten legs. The real
 * launcher, curve, token, v4 factory and v4 ETF code over the curve suite's mocks (`_switchToV4`); the
 * deployed v4, real pools and the real PoolManager are `MaidMarianLauncherV3Graduation.fork.t.sol`.
 *
 *   forge test --match-contract MaidMarianLauncherV3GraduationTest -vv
 */
contract MaidMarianLauncherV3GraduationTest is CurveBase {
    bytes32 internal constant BONDED = keccak256("Bonded(address,bytes32,address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant LAUNCHED =
        keccak256("CurveLaunched(address,address,address,address,uint256,(address,bool,uint128,uint16,uint96,uint8),string,string,bytes,(string,string,string,string,string))");

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

    struct Bond {
        address pairedWith;
        uint256 setAside;
        uint256 poolTokens;
        uint256 poolQuote;
        uint256 burned;
        uint256 redeemed;
        uint256 usdgOut;
        // The pool's swap at the bond (`BondSwapped`, emitted just before its `Bonded`).
        uint256 swapIn;
        uint256 swapOut;
    }

    function _bond(Vm.Log[] memory logs, address curve) internal pure returns (Bond memory bd) {
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != curve) continue;
            if (logs[i].topics[0] == BONDED) {
                (bd.pairedWith, bd.setAside, bd.poolTokens, bd.poolQuote, bd.burned) = abi.decode(logs[i].data, (address, uint256, uint256, uint256, uint256));
                found = true;
            } else if (logs[i].topics[0] == Curve.BondSwapped.selector) {
                (bd.swapIn, bd.swapOut) = abi.decode(logs[i].data, (uint256, uint256));
            } else if (logs[i].topics[0] == Curve.BondRedeemed.selector) {
                (bd.redeemed, bd.usdgOut) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        require(found, "no Bonded");
    }

    /// The `quoteIn` of the curve's `Bought`: the shares the buy took.
    function _boughtShares(Vm.Log[] memory logs, address curve) internal pure returns (uint256 quoteIn) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == curve && logs[i].topics[0] == Curve.Bought.selector) {
                (quoteIn,,,,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
                return quoteIn;
            }
        }
        revert("no Bought");
    }

    /// One of the deploy script's five ETF targets (1 000 to 15 000 shares), the owner's list set to them
    /// and `_launchMode` picking it.
    function _pickEtfTarget(uint8 pick) internal returns (uint256 shares) {
        uint256[] memory five = new uint256[](5);
        (five[0], five[1], five[2], five[3], five[4]) = (1000e18, 2000e18, 5000e18, 8000e18, 15_000e18);
        vm.prank(owner);
        cf.setEtfThresholds(five);
        shares = five[pick % 5];
        etfPick = shares;
    }

    /// `launchWithEtf` by `maker` on a, b, c (50 / 30 / 20), the 10 USDG seed, the bond's pool as chosen.
    function _launchMode(bool backedByEtf, uint16 tax) internal returns (Etf etf, Curve curve) {
        return _launchCut(backedByEtf ? 0 : 100, tax);
    }

    /// The same with the USDG cut `cut`.
    function _launchCut(uint8 cut, uint16 tax) internal returns (Etf etf, Curve curve) {
        vm.prank(maker);
        (etf, curve) = cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, etfPick, tax, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), cut, _noRoutes(), 0
        );
        _approveAll(curve, address(etf));
        address[8] memory who = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker];
        for (uint256 i = 0; i < who.length; i++) {
            vm.startPrank(who[i]);
            _tok(curve).approve(address(cf), type(uint256).max);
            vm.stopPrank();
        }
        vm.warp(vm.getBlockTimestamp() + 3);
    }

    /// The bond routes a site reads for a buy minting `sharesMinted`: each leg's due from `previewBond`, the
    /// mock router's floor 0.
    function _bondRoutes(Etf etf, Curve curve, uint256 sharesMinted) internal view returns (Etf.Route[] memory) {
        (, uint256[] memory due,) = curve.previewBond(sharesMinted);
        return _sellRoutes(etf, due);
    }

    /// Routes that sell 1 unit of every leg: `routesAtDue` raises each to its due at execution.
    function _anyBondRoutes(Etf etf) internal view returns (Etf.Route[] memory) {
        uint256[] memory one = new uint256[](etf.LEGS());
        for (uint256 i = 0; i < one.length; i++) {
            one[i] = 1;
        }
        return _sellRoutes(etf, one);
    }

    function _sqrtUsdg(Curve curve, uint256 q, uint256 t) internal view returns (uint160) {
        (uint256 a1, uint256 a0) = curve.token() < address(usdg) ? (q, t) : (t, q);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(Math.sqrt(Math.mulDiv(a1, 1 << 192, a0)));
    }

    /// A curve on USDG bonded by `bob`'s last buy of 9 000 USDG after `alice`'s 4 000.
    function _bondedToUsdg() internal returns (Etf etf, Curve curve) {
        (etf, curve) = _launchMode(false, 100);
        _buyUsdg(curve, alice, 4000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 9000e6, false);
        Etf.Route[] memory br = _anyBondRoutes(etf);
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 1);
        assertTrue(curve.bonded());
    }

    // ------------------------------------------------------------- the mode ---

    /// USDG is the default: `launchWithEtf` with `backedByEtf` false makes a curve that `graduatesToUsdg`,
    /// its pool keyed on the token and USDG, said by `CurveLaunched`'s terms; `backedByEtf` true keeps the
    /// token / shares pool; a plain-quote curve pairs with its quote and does not graduate.
    function test_TheBondPoolsCurrencyIsChosenAtLaunchUsdgByDefault() public {
        bool[2] memory backed = [false, true];
        for (uint256 k = 0; k < 2; k++) {
            vm.recordLogs();
            (Etf etf, Curve curve) = _launchMode(backed[k], 0);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            Launcher.Terms memory terms;
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].emitter == address(cf) && logs[i].topics[0] == LAUNCHED) {
                    (,, terms,,,,) = abi.decode(logs[i].data, (address, uint256, Launcher.Terms, string, string, bytes, Factory.Profile));
                }
            }
            assertTrue(terms.etfQuote);
            assertEq(terms.usdgCutPct, backed[k] ? 0 : 100, "the event says the cut");
            assertEq(curve.graduatesToUsdg(), !backed[k], "the curve says it");
            address paired = backed[k] ? address(etf) : address(usdg);
            assertEq(curve.poolCurrency(), paired);
            IPoolManagerV4.PoolKey memory key = curve.poolKey();
            (address c0, address c1) = curve.token() < paired ? (curve.token(), paired) : (paired, curve.token());
            assertEq(key.currency0, c0);
            assertEq(key.currency1, c1);
        }
        Curve plain = _launch(address(qt), 0);
        assertFalse(plain.graduatesToUsdg());
        assertEq(plain.poolCurrency(), address(qt));
        (uint256 s, uint256[] memory due, uint256 u) = plain.previewBond(1e18);
        assertEq(s + due.length + u, 0, "no bond preview on a plain quote");
    }

    // -------------------------------------------------------------- the bond ---

    /// The amounts a bond with a USDG cut must give, from the state before the last buy.
    struct Expect {
        uint256 shares;
        uint256 creatorShares;
        uint256 protocolShares;
        uint256 kept;
        uint256 redeemed;
        uint256 qPrice;
        uint256 creatorUsdg;
        uint256 protocolUsdg;
        uint256 budget;
    }

    /// Both `Bonded` of a bond: the USDG pool's and, with a cut under 100, the shares pool's.
    function _bonds(Vm.Log[] memory logs, address curve, address etf) internal pure returns (Bond memory inUsdg, Bond memory inShares) {
        (uint256 redeemed, uint256 usdgOut, uint256 swapIn, uint256 swapOut) = (0, 0, 0, 0);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != curve) continue;
            if (logs[i].topics[0] == BONDED) {
                Bond memory bd;
                (bd.pairedWith, bd.setAside, bd.poolTokens, bd.poolQuote, bd.burned) = abi.decode(logs[i].data, (address, uint256, uint256, uint256, uint256));
                (bd.swapIn, bd.swapOut) = (swapIn, swapOut);
                if (bd.pairedWith == etf) inShares = bd;
                else inUsdg = bd;
            } else if (logs[i].topics[0] == Curve.BondSwapped.selector) {
                (swapIn, swapOut) = abi.decode(logs[i].data, (uint256, uint256));
            } else if (logs[i].topics[0] == Curve.BondRedeemed.selector) {
                (redeemed, usdgOut) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        require(inUsdg.pairedWith != address(0), "no Bonded");
        (inUsdg.redeemed, inUsdg.usdgOut) = (redeemed, usdgOut);
    }

    /// A pool's opening price of the token in its other currency, units per unit, scaled by 1e36.
    function _tokenPrice(Curve curve, bytes32 id, address currency) internal view returns (uint256) {
        uint256 sp = pm.openedAt(id);
        uint256 p = Math.mulDiv(sp * 1e18, sp * 1e18, 1 << 192);
        return curve.token() < currency ? p : Math.mulDiv(1e36, 1e36, p);
    }

    /**
     * A last buy of any size from 3/4 to 250 x the target in USDG (half of it already bought), any creator
     * tax, any of the five ETF targets, and every USDG cut above 0 (25, 50, 75, 100), its bond routes read
     * from `previewBond`: bought whole (the buyer's USDG down by exactly what he paid, no leg, no share,
     * `curveBuy`'s tokens for every share minted). The bond keeps for the shares pool the cut's complement
     * of 70 % of the real quote (none at 100) and redeems every other share the curve held (the rest of the
     * real quote, both pots and the management fee its mint accrued), the USDG the curve's balance change;
     * each pot `floor(usdg x pot / redeemed)`; the USDG pool keyed on USDG at the curve's price times
     * `usdg / redeemed` with at most the cut's part of 70 % at that rate, short of it by the pool's rounding
     * only; the shares pool at the curve's price in shares with at most the shares kept, short by its
     * rounding only, that rounding held for the protocol (`protocolShares`); both pools at the same price,
     * the shares pool's times the redeem's rate equal to the USDG pool's to 1e-9 (the USDG price's rounding
     * to a unit of USDG; a tick is 1e-4); the set-aside the rest
     * of the real quote's USDG; the tokens pooled those that keep the price, every other one burned; the
     * curve left with no leg, the shares `protocolShares` and USDG equal to its two pots, which both claims,
     * in USDG, then empty.
     */
    function testFuzz_ABondWithAUsdgCutRedeemsAndOpensItsPoolsToTheUnit(uint256 usdgIn, uint16 tax, uint8 pick, uint8 cutPick) public {
        tax = uint16(bound(tax, 0, 1000));
        uint8 cut = uint8(25 * (1 + cutPick % 4));
        uint256 shares = _pickEtfTarget(pick);
        (Etf etf, Curve curve) = _launchCut(cut, tax);
        _buyUsdg(curve, holders[0], shares / 2e12);
        // Half the target bought, the 0.75 % fee, a 10 % creator tax and the ETF entry fee: 3 / 4 more always bonds.
        usdgIn = bound(usdgIn, shares * 3 / 4e12, shares * 250 / 1e12);
        address buyer = holders[1];
        uint256[4] memory before = [usdg.balanceOf(buyer), a.balanceOf(buyer), b.balanceOf(buyer), c.balanceOf(buyer)];
        (uint256 q0, uint256 t0) = curve.getReserves();
        uint256 held0 = etf.balanceOf(address(curve));
        (uint256 c0, uint256 p0) = (curve.creatorFees() + curve.unbookedShares(), curve.protocolFees());
        (uint256 accrued,) = etf.pendingManagementFee();
        uint256 pmUsdg0 = usdg.balanceOf(address(pm));

        Etf.Route[] memory r = _buyRoutes(etf, usdgIn, false);
        Etf.Route[] memory br = _bondRoutes(etf, curve, usdgIn * 1e12);
        vm.recordLogs();
        vm.prank(buyer);
        uint256 got = curve.buyWithUsdg(usdgIn, r, 1, 1, br, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(curve.bonded());
        (Bond memory bd, Bond memory bs) = _bonds(logs, address(curve), address(etf));

        uint256 bought = _boughtShares(logs, address(curve));
        (uint256 out, uint256 fee, uint256 taxPaid, uint256 net) = curveBuy(q0, t0, bought, 75, tax);
        assertEq(got, out, "curveBuy's tokens for every share minted");
        (uint256 q, uint256 t) = curve.getReserves();
        assertEq(q, q0 + net);
        assertEq(t, t0 - out);
        assertEq(before[0] - usdg.balanceOf(buyer), usdgIn, "his USDG, to the wei");
        assertEq(a.balanceOf(buyer), before[1], "no leg");
        assertEq(b.balanceOf(buyer), before[2], "no leg");
        assertEq(c.balanceOf(buyer), before[3], "no leg");
        assertEq(etf.balanceOf(buyer), 0, "no share");

        Expect memory e;
        e.creatorShares = c0 + accrued + fee - fee * 3000 / 10_000 + taxPaid;
        e.protocolShares = p0 + fee * 3000 / 10_000;
        e.shares = held0 + bought + accrued;
        uint256 real = q - curve.phantomQuote();
        assertEq(e.shares, real + e.creatorShares + e.protocolShares, "every share the curve held: the real quote and both pots");
        uint256 pooled = real - real * 3000 / 10_000;
        e.kept = pooled * (100 - cut) / 100;
        e.redeemed = e.shares - e.kept;
        assertEq(bd.redeemed, e.redeemed, "the bond redeems every share held but the shares pool's");
        e.qPrice = Math.mulDiv(q, bd.usdgOut, e.redeemed);
        e.creatorUsdg = Math.mulDiv(bd.usdgOut, e.creatorShares, e.redeemed);
        e.protocolUsdg = Math.mulDiv(bd.usdgOut, e.protocolShares, e.redeemed);
        e.budget = Math.mulDiv(bd.usdgOut, pooled - e.kept, e.redeemed);

        assertEq(bd.pairedWith, address(usdg), "the last pool pairs the token with USDG");
        assertEq(curve.creatorFees(), e.creatorUsdg, "the creator's pot at the redeem's rate");
        assertEq(curve.protocolFees(), e.protocolUsdg + bd.setAside, "the protocol's pot at that rate, and the set-aside");
        assertEq(bd.poolQuote, usdg.balanceOf(address(pm)) - pmUsdg0 + bd.swapOut, "the USDG pool holds its position less the bond swap's output");
        assertLe(bd.poolQuote, e.budget, "the cut's part of 70 % at most");
        assertLe(e.budget - bd.poolQuote, Math.sqrt(e.qPrice / t) + 3, "short of it by the pool's rounding only");
        assertEq(bd.setAside, bd.usdgOut - e.creatorUsdg - e.protocolUsdg - bd.poolQuote + bd.swapOut, "the 30 %, the roundings and the swap's output");
        assertEq(curve.bondSetAside(), bd.setAside);
        assertEq(_poolPrice(curve), _sqrtUsdg(curve, e.qPrice, t), "the USDG pool opens at the curve's price in USDG");
        assertGt(pm.liquidity(curve.poolId()), 0);

        uint256 sharesTokens;
        if (cut == 100) {
            assertEq(bs.pairedWith, address(0), "one pool at 100");
            assertEq(etf.balanceOf(address(curve)), 0, "no share left in the curve");
        } else {
            bytes32 sid = keccak256(abi.encode(curve.poolKeyIn(address(etf))));
            assertTrue(curve.isBondPool(sid));
            assertEq(bs.poolQuote, etf.balanceOf(address(pm)) + bs.swapOut, "the shares pool holds its position less the swap's output");
            assertLe(bs.poolQuote, e.kept, "the shares kept at most");
            assertLe(e.kept - bs.poolQuote, Math.sqrt(q / t) + 3, "short of them by the pool's rounding only");
            assertEq(bs.setAside, e.kept - bs.poolQuote + bs.swapOut);
            assertEq(curve.protocolShares(), bs.setAside, "that rounding held for the protocol");
            assertEq(etf.balanceOf(address(curve)), curve.protocolShares(), "the curve holds the protocol's shares alone");
            assertEq(curve.claimableShares(), 0);
            assertEq(bs.burned, 0);
            assertGt(pm.liquidity(sid), 0);
            assertApproxEqRel(Math.mulDiv(_tokenPrice(curve, sid, address(etf)), bd.usdgOut, e.redeemed), _tokenPrice(curve, curve.poolId(), address(usdg)), 1e9, "both pools at the same price");
            sharesTokens = bs.poolTokens + bs.swapIn;
        }
        assertEq(bd.poolTokens + bd.swapIn + sharesTokens, _tok(curve).balanceOf(address(pm)), "the pools hold the positions and the swaps' tokens");
        assertApproxEqRel(bd.poolTokens + sharesTokens, Math.mulDiv(t, pooled, q), 1e12, "the price-keeping tokens");
        assertLt(bd.poolTokens + sharesTokens, t * 7 / 10, "the tokens left cover the pools");
        assertEq(bd.burned, t - bd.poolTokens - bd.swapIn - sharesTokens, "every other token burned");
        assertEq(_tok(curve).totalSupply(), curve.supply() - bd.burned);

        assertEq(a.balanceOf(address(curve)) + b.balanceOf(address(curve)) + c.balanceOf(address(curve)), 0, "no leg left in the curve");
        assertEq(usdg.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees(), "solvent to the unit, in USDG");
        assertEq(curve.unbookedShares(), 0);

        uint256 pf = curve.protocolFees();
        uint256 o0 = usdg.balanceOf(owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Curve.BadPayout.selector, uint8(1)));
        curve.claim(true, pf, owner, 1, _noRoutes(), 0, 0);
        vm.prank(owner);
        curve.claim(true, pf, owner, 2, _noRoutes(), 0, 0);
        assertEq(usdg.balanceOf(owner) - o0, pf, "the owner's claim in USDG, exactly");
        uint256 cfees = curve.creatorFees();
        uint256 m0 = usdg.balanceOf(maker);
        vm.prank(maker);
        curve.claim(false, cfees, maker, 2, _noRoutes(), 0, 0);
        assertEq(usdg.balanceOf(maker) - m0, cfees, "the creator's claim in USDG, exactly");
        assertEq(usdg.balanceOf(address(curve)), 0, "both claims empty it");
    }

    /// The bond's refusals, each reverting the whole last buy: a route that sells nothing
    /// (`BondRouteMissing`), no routes (the ETF's `WrongLength`), a floor one unit above what the redeem
    /// brings (`TooLittleUsdgAtBond`, the USDG read from a dry run). At that floor exactly it bonds.
    function test_ABondToUsdgRefusesAMissingRouteAndAFloorItMisses() public {
        (Etf etf, Curve curve) = _launchMode(false, 100);
        _buyUsdg(curve, alice, 4000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 9000e6, false);
        Etf.Route[] memory br = _anyBondRoutes(etf);

        br[1].amountIn = 0;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Curve.BondRouteMissing.selector, uint256(1)));
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 0);
        br[1].amountIn = 1;

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Etf.WrongLength.selector, uint256(0), uint256(3)));
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, _noRoutes(), 0);

        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 0);
        uint256 usdgOut = _bond(vm.getRecordedLogs(), address(curve)).usdgOut;
        vm.revertToState(snap);
        assertGt(usdgOut, 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Curve.TooLittleUsdgAtBond.selector, usdgOut, usdgOut + 1));
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, usdgOut + 1);
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, usdgOut);
        assertTrue(curve.bonded());
    }

    /// A curve backed by its ETF bonds as before, its bond routes unread: the pool keyed on the shares,
    /// every share booked in the curve, no redeem.
    function test_ACurveBackedByItsEtfBondsIntoTheSharesPoolAndReadsNoBondRoute() public {
        (Etf etf, Curve curve) = _launchMode(true, 100);
        _buyUsdg(curve, alice, 4000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 9000e6, false);
        Etf.Route[] memory br = _anyBondRoutes(etf);
        br[0].amountIn = 0;
        vm.recordLogs();
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, type(uint256).max);
        Bond memory bd = _bond(vm.getRecordedLogs(), address(curve));
        assertEq(bd.pairedWith, address(etf));
        assertEq(bd.redeemed, 0, "no redeem");
        assertEq(etf.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees());
    }

    /// A seed past the threshold bonds to USDG in the launch (the threshold set to 1 000 shares, a seed of
    /// 2 000 USDG): one first mint, one buy for the creator, then the redeem of every share and the token /
    /// USDG pool; the creator holds tokens and no share or leg; the curve holds no share.
    function test_ASeedPastTheThresholdBondsToUsdgInTheLaunch() public {
        vm.prank(owner);
        cf.setEtfThresholds(oneThreshold(1000e18));
        uint256 seedUsdg = 2000e6;
        uint256[4] memory m0 = [usdg.balanceOf(maker), a.balanceOf(maker), b.balanceOf(maker), c.balanceOf(maker)];
        Etf.Route[] memory br = new Etf.Route[](3);
        for (uint256 i = 0; i < 3; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            br[i] = Etf.Route({ leg: uint8(i), sell: true, v4: false, amountIn: 1, amountOutMin: 0, deadline: vm.getBlockTimestamp() + 60 });
        }
        vm.recordLogs();
        vm.prank(maker);
        (Etf etf, Curve curve) = cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 1000e18, 0, 1_000_000_000, seedUsdg, _seedRoutesFor(_legsAbc(), seedUsdg), 1, new address[](0), 100, br, 1
        );
        Bond memory bd = _bond(vm.getRecordedLogs(), address(curve));
        assertTrue(curve.bonded());
        assertEq(bd.pairedWith, address(usdg));
        assertGt(bd.usdgOut, 0);
        assertGt(_tok(curve).balanceOf(maker), 0);
        assertEq(m0[0] - usdg.balanceOf(maker), seedUsdg);
        assertEq(a.balanceOf(maker), m0[1]);
        assertEq(b.balanceOf(maker), m0[2]);
        assertEq(c.balanceOf(maker), m0[3]);
        assertEq(etf.balanceOf(maker), 0);
        assertEq(etf.balanceOf(address(curve)), 0);
        assertEq(usdg.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees());
    }

    /// The token / USDG pool is the curve's alone to open, as the shares pool is: a stranger's
    /// `initialize` of its key is refused by the hook before the bond and after it.
    function test_NoOneButItsCurveOpensTheUsdgPool() public {
        (Etf etf, Curve curve) = _launchMode(false, 100);
        _buyUsdg(curve, alice, 4000e6);
        IPoolManagerV4.PoolKey memory key = curve.poolKey();
        assertEq(key.hooks, address(cf.HOOK()));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Hook.NotLaunchedCurve.selector, alice));
        pm.initialize(key, uint160(1 << 96));
        Etf.Route[] memory r = _buyRoutes(etf, 9000e6, false);
        Etf.Route[] memory br = _anyBondRoutes(etf);
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 1);
        assertTrue(curve.bonded());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Hook.NotLaunchedCurve.selector, alice));
        pm.initialize(key, uint160(1 << 96));
    }

    // ---------------------------------------------------- after the bond ---

    /**
     * After a bond to USDG the token trades against USDG directly through the launcher: `buyAfterBond`
     * takes exactly the buyer's USDG and pays the pool's tokens, no mint (the ETF's supply unchanged), no
     * leg; `sellAfterBond` pays USDG alone, `PAY_USDG` only; both minimums bind (`TooFewTokens`,
     * `TooLittleUsdg`). The pool's fees, collected, are USDG booked 70 / 30 and the token's split alike;
     * the curve stays solvent in USDG. The launcher keeps nothing.
     */
    function test_AfterABondToUsdgTheTokenTradesAgainstUsdgDirectly() public {
        (Etf etf, Curve curve) = _bondedToUsdg();
        uint256 supply0 = etf.totalSupply();
        uint256[4] memory b0 = [usdg.balanceOf(carol), a.balanceOf(carol), b.balanceOf(carol), c.balanceOf(carol)];
        usdg.mint(carol, 1000e6);
        vm.startPrank(carol);
        usdg.approve(address(cf), type(uint256).max);
        _tok(curve).approve(address(cf), type(uint256).max);
        vm.stopPrank();

        uint256 snap = vm.snapshotState();
        vm.prank(carol);
        uint256 expected = cf.buyAfterBond(address(curve), address(usdg), 500e6, _noRoutes(), 1);
        vm.revertToState(snap);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Launcher.TooFewTokens.selector, expected, expected + 1));
        cf.buyAfterBond(address(curve), address(usdg), 500e6, _noRoutes(), expected + 1);

        // Mint routes are unread on a USDG pool: any pass.
        Etf.Route[] memory unread = _buyRoutes(etf, 500e6, false);
        vm.prank(carol);
        uint256 tokens = cf.buyAfterBond(address(curve), address(usdg), 500e6, unread, expected);
        assertEq(tokens, expected);
        assertEq(_tok(curve).balanceOf(carol), tokens);
        assertEq(b0[0] + 1000e6 - usdg.balanceOf(carol), 500e6, "his USDG, exactly");
        assertEq(etf.totalSupply(), supply0, "no mint");
        assertEq(a.balanceOf(carol) + b.balanceOf(carol) + c.balanceOf(carol), b0[1] + b0[2] + b0[3], "no leg");

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Launcher.BadPayout.selector, uint8(1)));
        cf.sellAfterBond(address(curve), address(usdg), tokens / 2, 0, 1, _noRoutes(), 0, 0);
        snap = vm.snapshotState();
        vm.prank(carol);
        uint256 usdgOut = cf.sellAfterBond(address(curve), address(usdg), tokens / 2, 0, 2, _noRoutes(), 1, 0);
        vm.revertToState(snap);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Launcher.TooLittleUsdg.selector, usdgOut, usdgOut + 1));
        cf.sellAfterBond(address(curve), address(usdg), tokens / 2, 0, 2, _noRoutes(), usdgOut + 1, 0);
        uint256 u0 = usdg.balanceOf(carol);
        vm.prank(carol);
        assertEq(cf.sellAfterBond(address(curve), address(usdg), tokens / 2, type(uint256).max, 2, _noRoutes(), usdgOut, 0), usdgOut);
        assertEq(usdg.balanceOf(carol) - u0, usdgOut, "USDG alone");
        assertEq(etf.balanceOf(carol), 0);
        assertEq(a.balanceOf(carol) + b.balanceOf(carol) + c.balanceOf(carol), b0[1] + b0[2] + b0[3], "no leg");
        assertEq(usdg.balanceOf(address(cf)) + _tok(curve).balanceOf(address(cf)) + etf.balanceOf(address(cf)), 0, "the launcher keeps nothing");

        (uint256 c0, uint256 p0) = (curve.creatorFees(), curve.protocolFees());
        uint256 makerTokens = _tok(curve).balanceOf(maker);
        (uint256 tokenFees, uint256 quoteFees) = curve.collectPoolFees();
        assertGt(quoteFees, 0, "the pool's USDG fees");
        assertGt(tokenFees, 0, "the pool's token fees");
        assertEq(curve.protocolFees() - p0, quoteFees * 3000 / 10_000);
        assertEq(curve.creatorFees() - c0, quoteFees - quoteFees * 3000 / 10_000);
        assertEq(_tok(curve).balanceOf(maker) - makerTokens, tokenFees - tokenFees * 3000 / 10_000);
        assertEq(usdg.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees(), "solvent in USDG");
    }

    // -------------------------------------------------- the contract's floor ---

    /// Leg a (250 USDG, its pool's TWAP one tick under) traded by the router at `bps` of its price both
    /// ways: a pool moved within the block, which its 30 min TWAP does not see.
    function _moveLegA(uint256 bps) internal {
        router.setPairRate(address(a), address(usdg), 250e6 * bps / 10_000);
        router.setPairRate(address(usdg), address(a), 1e48 / (250e18 * bps / 10_000));
    }

    /// A sandwiched last buy: leg a's pool pushed 10 % down in the block before it, the buyer's bond
    /// routes and `minUsdgAtBond` all at 0. The bond's sale of leg a is held to its due at the TWAP less
    /// its pool's registered fee (0.3 %) and 1 %, written into the swap whatever the route says, so the router refuses it and the whole buy
    /// reverts: nothing bought, nothing bonded. Proves the curve's floor on mocks.
    function test_ASandwichedLastBuyWithFloorsAtZeroRevertsOnTheContractsFloor() public {
        (Etf etf, Curve curve) = _launchMode(false, 100);
        _buyUsdg(curve, alice, 4000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 9000e6, false);
        Etf.Route[] memory br = _bondRoutes(etf, curve, 9000e18);
        for (uint256 i = 0; i < br.length; i++) {
            assertEq(br[i].amountOutMin, 0);
        }
        _moveLegA(9000);
        vm.prank(bob);
        vm.expectRevert(UniversalRouterMock.V3TooLittleReceived.selector);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 0);
        assertFalse(curve.bonded());

        // 1.4 % under (the TWAP one tick under): still refused; 1.2 % under, inside 0.3 % + 1 %: it bonds.
        _moveLegA(9860);
        vm.prank(bob);
        vm.expectRevert(UniversalRouterMock.V3TooLittleReceived.selector);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 0);
        _moveLegA(9880);
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 0);
        assertTrue(curve.bonded());
    }

    /// An honest last buy, floors at 0: the router trading at the legs' prices, it bonds, and the floor the
    /// curve wrote into the last leg's sale is that leg's due at the factory's TWAP price less its pool's registered fee and 1 %, to the
    /// unit (the due read off what the router's pools received). Leg c has a V4 pool registered (fee 0.01 %)
    /// beside its V3 one (0.3 %): its route names V3, the sale goes through the V4 pool, at its fee.
    function test_AnHonestLastBuyBondsAndEachSaleCarriesTheTwapFloor() public {
        (Etf etf, Curve curve) = _launchMode(false, 100);
        _buyUsdg(curve, alice, 4000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 9000e6, false);
        Etf.Route[] memory br = _bondRoutes(etf, curve, 9000e18);
        assertFalse(br[br.length - 1].v4);
        router.setRecord(true);
        address pools = router.sink();
        uint256 c0 = c.balanceOf(pools);
        uint256 last = br.length - 1;
        assertEq(address(c), factory.legsOf(address(etf))[last].token);
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 0);
        assertTrue(curve.bonded());
        uint256 dueC = c.balanceOf(pools) - c0;
        (uint256 price,) = factory.getTradablePriceUsdg(address(c));
        assertGt(dueC, 0);
        (, uint24 v3FeeC, uint24 feeC, int24 spacingC,) = FactoryV4(address(factory)).poolsOf(address(c));
        assertEq(v3FeeC, 3000);
        assertEq(feeC, 100);
        assertEq(spacingC, 1);
        assertEq(router.lastCommands(), hex"10", "the V4 pool, not the route's V3");
        assertEq(router.lastAmountOutMin(), Math.mulDiv(Math.mulDiv(dueC, price, 1e30), 1e6 - feeC - 10_000, 1e6), "the TWAP floor, not the buyer's 0");
        assertEq(curve.BOND_TOLERANCE_BPS(), 100);
    }

    /// The bond's venue is the contract's: every bond route's `v4` flag flipped (legs a and b, V3 only, named
    /// V4, which the ETF would refuse `NoV4Pool`; leg c, V3 and V4 registered, named V3, its V3 pool priced 2 %
    /// under, so a sale there would fall under the floor) and the last buy still bonds: a and b through their
    /// V3 pools, c through its V4 pool at the V4 fee's floor. Without the override the buy reverts.
    function test_TheBondSellsEachLegThroughItsRegisteredPoolWhateverTheRouteSays() public {
        (Etf etf, Curve curve) = _launchMode(false, 100);
        _buyUsdg(curve, alice, 4000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 9000e6, false);
        Etf.Route[] memory br = _bondRoutes(etf, curve, 9000e18);
        for (uint256 i = 0; i < br.length; i++) {
            br[i].v4 = !br[i].v4;
        }
        (br[0].v4, br[1].v4, br[2].v4) = (true, true, false);
        router.setPoolRate(address(c), address(usdg), false, 3000, 0, router.pairRate(address(c), address(usdg)) * 98 / 100);
        router.setRecord(true);
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 0);
        assertTrue(curve.bonded());
        assertEq(router.lastCommands(), hex"10", "leg c through its V4 pool");
        assertEq(router.lastHooks(), address(0));
    }

    /// A leg whose pool gives no 30 min TWAP (`observe` refuses) at the bond: no floor, so the last buy
    /// reverts `BondLegUnpriced(leg, token)`; once the pool answers again the same buy bonds.
    function test_ABondToUsdgRevertsWhenALegHasNoTwapAndBondsOnceItHasOne() public {
        (Etf etf, Curve curve) = _launchMode(false, 100);
        _buyUsdg(curve, alice, 4000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 9000e6, false);
        Etf.Route[] memory br = _bondRoutes(etf, curve, 9000e18);
        pb.setNoHistory(true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Curve.BondLegUnpriced.selector, uint256(1), address(b)));
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 0);
        pb.setNoHistory(false);
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 0);
        assertTrue(curve.bonded());
    }

    // -------------------------------------------------------------- the cut ---

    /// A curve with the USDG cut `cut` bonded by `bob`'s last buy of 9 000 USDG after `alice`'s 4 000.
    function _bondedAt(uint8 cut) internal returns (Etf etf, Curve curve) {
        (etf, curve) = _launchCut(cut, 100);
        _buyUsdg(curve, alice, 4000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 9000e6, false);
        Etf.Route[] memory br = cut == 0 ? _noRoutes() : _anyBondRoutes(etf);
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 1);
        assertTrue(curve.bonded());
    }

    /// The cut is one of 0, 25, 50, 75, 100, chosen at launch and kept by the curve, `CurveLaunched` carrying
    /// it; any other value is refused `BadUsdgCut`, nothing launched. The curve's pools: at 0 the shares
    /// pool alone, at 100 the USDG pool alone, at 25 to 75 both (`isBondPool`), `poolKey` the USDG one.
    function test_TheUsdgCutIsOneOfFiveChosenAtLaunchAndKept() public {
        uint8[5] memory cuts = [0, 25, 50, 75, 100];
        for (uint256 k = 0; k < cuts.length; k++) {
            vm.recordLogs();
            (Etf etf, Curve curve) = _launchCut(cuts[k], 100);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            Launcher.Terms memory terms;
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].emitter == address(cf) && logs[i].topics[0] == LAUNCHED) {
                    (,, terms,,,,) = abi.decode(logs[i].data, (address, uint256, Launcher.Terms, string, string, bytes, Factory.Profile));
                }
            }
            assertEq(terms.usdgCutPct, cuts[k], "the event says the cut");
            assertEq(curve.usdgCutPct(), cuts[k], "the curve keeps it");
            assertEq(curve.graduatesToUsdg(), cuts[k] != 0);
            assertEq(curve.poolCurrency(), cuts[k] == 0 ? address(etf) : address(usdg));
            bytes32 sharesId = keccak256(abi.encode(curve.poolKeyIn(address(etf))));
            bytes32 usdgId = keccak256(abi.encode(curve.poolKeyIn(address(usdg))));
            assertEq(curve.isBondPool(sharesId), cuts[k] != 100, "a shares pool under 100");
            assertEq(curve.isBondPool(usdgId), cuts[k] != 0, "a USDG pool above 0");
            assertFalse(curve.isBondPool(keccak256(abi.encode(curve.poolKeyIn(address(a))))));
        }
        uint8[4] memory bad = [1, 26, 101, 254];
        for (uint256 k = 0; k < bad.length; k++) {
            vm.prank(maker);
            vm.expectRevert(abi.encodeWithSelector(Launcher.BadUsdgCut.selector, uint256(bad[k])));
            cf.launchWithEtf{ value: FEE }(
                "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, etfPick, 100, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), bad[k], _noRoutes(), 0
            );
        }
    }

    /// A sandwiched last buy, every floor the buyer writes at 0, leg a's pool pushed 10 % down in the block:
    /// at every cut that redeems (25, 50, 75, 100) the bond's sale of leg a is held to the contract's floor
    /// and the whole buy reverts, nothing bought; the same buy at the legs' prices bonds.
    function test_ASandwichedLastBuyRevertsOnTheFloorAtEveryCutThatRedeems() public {
        uint8[4] memory cuts = [25, 50, 75, 100];
        for (uint256 k = 0; k < cuts.length; k++) {
            (Etf etf, Curve curve) = _launchCut(cuts[k], 100);
            _buyUsdg(curve, alice, 4000e6);
            Etf.Route[] memory r = _buyRoutes(etf, 9000e6, false);
            Etf.Route[] memory br = _bondRoutes(etf, curve, 9000e18);
            _moveLegA(9000);
            vm.prank(bob);
            vm.expectRevert(UniversalRouterMock.V3TooLittleReceived.selector);
            cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 0);
            assertFalse(curve.bonded());
            _moveLegA(10_000);
            vm.prank(bob);
            cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 0);
            assertTrue(curve.bonded());
        }
    }

    /// The two pools are the curve's alone to open: before the bond a stranger's `initialize` of either key
    /// is refused by the hook, and the bond opens both.
    function test_NoOneButItsCurveOpensEitherPoolOfACut() public {
        (Etf etf, Curve curve) = _launchCut(50, 100);
        IPoolManagerV4.PoolKey memory sharesKey = curve.poolKeyIn(address(etf));
        IPoolManagerV4.PoolKey memory usdgKey = curve.poolKey();
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Hook.NotLaunchedCurve.selector, alice));
        pm.initialize(sharesKey, uint160(1 << 96));
        vm.expectRevert(abi.encodeWithSelector(Hook.NotLaunchedCurve.selector, alice));
        pm.initialize(usdgKey, uint160(1 << 96));
        vm.stopPrank();
        _buyUsdg(curve, alice, 4000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 9000e6, false);
        Etf.Route[] memory br = _anyBondRoutes(etf);
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 1);
        assertGt(pm.liquidity(keccak256(abi.encode(sharesKey))), 0);
        assertGt(pm.liquidity(keccak256(abi.encode(usdgKey))), 0);
    }

    /**
     * At a cut of 50 the token trades in both pools through the launcher, each door in the pool the caller
     * names: `buyAfterBond` in the USDG pool takes his USDG alone, in the shares pool mints and swaps; a sale
     * in the USDG pool pays USDG, in the shares pool redeems in kind; no share with him or the launcher. The
     * pool the cut did not open is refused `NoSuchPool`: the USDG pool at 0, the shares pool at 100.
     * Collected, the USDG pool's fees go to the USDG pots 70 / 30, the shares pool's stay in shares, 30 %
     * booked to `protocolShares`, the rest the creator's (`claimableShares`), each redeemed by `claimShares`
     * by its owner alone (`NotCreator` for a stranger, `TooMuch` past his part); the curve stays solvent.
     */
    function test_WithBothPoolsEachDoorTakesTheNamedPoolAndTheSharesFeesAreSplit() public {
        (Etf etf, Curve curve) = _bondedAt(50);
        usdg.mint(carol, 2000e6);
        vm.startPrank(carol);
        usdg.approve(address(cf), type(uint256).max);
        _tok(curve).approve(address(cf), type(uint256).max);
        vm.stopPrank();
        uint256 supply0 = etf.totalSupply();

        vm.prank(carol);
        uint256 viaUsdg = cf.buyAfterBond(address(curve), address(usdg), 500e6, _noRoutes(), 1);
        assertEq(etf.totalSupply(), supply0, "no mint in the USDG pool");
        Etf.Route[] memory mintRoutes = _buyRoutes(etf, 500e6, false);
        vm.prank(carol);
        uint256 viaShares = cf.buyAfterBond(address(curve), address(etf), 500e6, mintRoutes, 1);
        assertGt(etf.totalSupply(), supply0, "a mint in the shares pool");
        assertGt(viaUsdg, 0);
        assertGt(viaShares, 0);
        assertEq(etf.balanceOf(carol) + etf.balanceOf(address(cf)), 0, "no share with him or the launcher");

        uint256 u0 = usdg.balanceOf(carol);
        vm.prank(carol);
        uint256 usdgOut = cf.sellAfterBond(address(curve), address(usdg), viaUsdg / 2, 0, 2, _noRoutes(), 1, 0);
        assertEq(usdg.balanceOf(carol) - u0, usdgOut, "USDG from the USDG pool");
        uint256 a0 = a.balanceOf(carol);
        Etf.Route[] memory zero = _sellRoutes(etf, new uint256[](3));
        vm.prank(carol);
        cf.sellAfterBond(address(curve), address(etf), viaShares / 2, 1, 1, zero, 0, 0);
        assertGt(a.balanceOf(carol), a0, "legs in kind from the shares pool");
        assertEq(etf.balanceOf(carol) + etf.balanceOf(address(cf)), 0, "no share with him or the launcher");

        uint256 ps0 = curve.protocolShares();
        uint256 held0 = etf.balanceOf(address(curve));
        (uint256 c0, uint256 p0) = (curve.creatorFees(), curve.protocolFees());
        vm.recordLogs();
        curve.collectPoolFees();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 shareFees;
        uint256 quoteFees;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(curve) && logs[i].topics[0] == Curve.PoolFeesCollected.selector) (, quoteFees, shareFees) = abi.decode(logs[i].data, (uint256, uint256, uint256));
        }
        assertGt(shareFees, 0, "the shares pool's fees");
        assertGt(quoteFees, 0, "the USDG pool's fees");
        assertEq(etf.balanceOf(address(curve)) - held0, shareFees, "held in shares");
        assertEq(curve.protocolShares() - ps0, shareFees * 3000 / 10_000, "30 % to the protocol");
        assertEq(curve.protocolFees() - p0, quoteFees * 3000 / 10_000, "the USDG fees 70 / 30");
        assertEq(curve.creatorFees() - c0, quoteFees - quoteFees * 3000 / 10_000);
        assertEq(curve.claimableShares(), etf.balanceOf(address(curve)) - curve.protocolShares(), "the rest the creator's");
        assertEq(usdg.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees(), "solvent in USDG");

        uint256 creatorPart = curve.claimableShares();
        uint256 protocolPart = curve.protocolShares();
        vm.prank(carol);
        vm.expectRevert(Curve.NotCreator.selector);
        curve.claimShares(1, carol, 1, _noRoutes(), 0, 0);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Curve.TooMuch.selector, creatorPart + 1, creatorPart));
        curve.claimShares(creatorPart + 1, maker, 1, _noRoutes(), 0, 0);
        vm.prank(maker);
        curve.claimShares(creatorPart, maker, 1, _noRoutes(), 0, 0);
        assertEq(curve.protocolShares(), protocolPart, "the creator's claim leaves the protocol's");
        vm.prank(owner);
        curve.claimShares(protocolPart, owner, 1, _noRoutes(), 0, 0);
        assertEq(curve.protocolShares(), 0);
        assertEq(etf.balanceOf(address(curve)), 0, "both parts redeemed");
        assertEq(etf.balanceOf(maker), 0, "in kind, never as shares");
    }

    /// The after-bond doors refuse the pool a cut did not open: the USDG pool at 0, the shares pool at 100.
    function test_TheAfterBondDoorsRefuseThePoolACutDidNotOpen() public {
        (, Curve backed) = _bondedAt(0);
        (Etf allUsdgEtf, Curve allUsdg) = _bondedAt(100);
        vm.startPrank(carol);
        vm.expectRevert(abi.encodeWithSelector(Launcher.NoSuchPool.selector, address(backed), address(usdg)));
        cf.buyAfterBond(address(backed), address(usdg), 1e6, _noRoutes(), 1);
        vm.expectRevert(abi.encodeWithSelector(Launcher.NoSuchPool.selector, address(allUsdg), address(allUsdgEtf)));
        cf.buyAfterBond(address(allUsdg), address(allUsdgEtf), 1e6, _noRoutes(), 1);
        vm.expectRevert(abi.encodeWithSelector(Launcher.NoSuchPool.selector, address(backed), address(usdg)));
        cf.sellAfterBond(address(backed), address(usdg), 1, 0, 2, _noRoutes(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(Launcher.NoSuchPool.selector, address(allUsdg), address(allUsdgEtf)));
        cf.sellAfterBond(address(allUsdg), address(allUsdgEtf), 1, 0, 1, _noRoutes(), 0, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- gas ---

    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i = 0; i < data.length; i++) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /**
     * The heaviest bonding buy: ten legs, through the launcher, a last buy of 11 000 USDG minting through
     * ten swaps and the bond redeeming through ten more, accounts cooled, intrinsic and calldata added,
     * against the same buy on a curve backed by its ETF. Logged; under the ~7 M a wallet simulates.
     */
    function test_Gas_TheBondingBuyToUsdgOnTenLegs() public {
        Factory.LegSpec[] memory l10 = new Factory.LegSpec[](10);
        l10[0] = Factory.LegSpec({ token: address(a), bps: 1000 });
        l10[1] = Factory.LegSpec({ token: address(b), bps: 1000 });
        l10[2] = Factory.LegSpec({ token: address(c), bps: 1000 });
        for (uint256 i = 3; i < 10; i++) {
            (TokenMock tk,) = _token(string.concat("L", vm.toString(i)), 10 + i);
            l10[i] = Factory.LegSpec({ token: address(tk), bps: 1000 });
        }
        uint256[3] memory used;
        uint8[3] memory cuts = [100, 0, 50];
        for (uint256 k = 0; k < 3; k++) {
            vm.prank(maker);
            (Etf etf, Curve curve) = cf.launchWithEtf{ value: FEE }(
                "Robin Coin", "ROBIN", "", _noProfileC(), l10, 200, 0, 8000e18, 100, 1_000_000_000, SEED_USDG, _seedRoutes(l10), 1, new address[](0), cuts[k], _noRoutes(), 0
            );
            vm.warp(vm.getBlockTimestamp() + 3);
            Etf.Route[] memory r = _buyRoutes(etf, 11_000e6, false);
            Etf.Route[] memory br = _bondRoutes(etf, curve, 11_000e18);
            address[6] memory touched = [address(cf), address(factory), address(usdg), address(router), address(pm), address(curve)];
            for (uint256 i = 0; i < touched.length; i++) {
                vm.cool(touched[i]);
            }
            for (uint256 i = 0; i < 10; i++) {
                vm.cool(l10[i].token);
            }
            vm.cool(address(etf));
            vm.prank(bob);
            uint256 g = gasleft();
            cf.buyWithUsdg(address(curve), 11_000e6, r, 1, 1, br, 1);
            used[k] = g - gasleft() + _intrinsic(abi.encodeCall(cf.buyWithUsdg, (address(curve), 11_000e6, r, 1, 1, br, 1)));
            assertTrue(curve.bonded());
        }
        emit log_named_uint("last buyWithUsdg + bond to USDG, 10 legs, launcher, intrinsic + calldata", used[0]);
        emit log_named_uint("last buyWithUsdg + bond backed by the ETF, 10 legs, the same", used[1]);
        emit log_named_uint("last buyWithUsdg + bond at a cut of 50 (both pools), 10 legs, the same", used[2]);
        assertLt(used[0], 7_000_000, "under the wallets' simulation ceiling");
        assertLt(used[2], 7_000_000, "under the wallets' simulation ceiling");
    }
}
