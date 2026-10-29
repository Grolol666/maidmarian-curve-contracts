// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { oneThreshold } from "./CurveFixtures.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MaidMarianEtfFactory as Factory } from "../src/MaidMarianEtfFactory.sol";
import { MaidMarianEtfFactoryV4 as FactoryV4 } from "../src/MaidMarianEtfFactoryV4.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { IUniversalRouter } from "../src/MaidMarianSevenMagnificent.sol";
import { MaidMarianTokenLauncher as CurveFactory, IWrappedNative } from "../src/MaidMarianTokenLauncher.sol";
import { MaidMarianToken as Token } from "../src/MaidMarianToken.sol";
import { MaidMarianLaunchCurve as Curve, IPoolManagerV4, curveBuy, curveSell, curveCloneArgs, curveReserved } from "../src/MaidMarianLaunchCurve.sol";
import { BadName, BadSymbol, BadLogo, storeLogoAsCode } from "../src/MaidMarianTokenChecks.sol";
import { TokenMock, PoolMock } from "./Mocks.sol";
import { EtfV3BisBase } from "./MaidMarianEtfV3Bis.t.sol";
import { MaidMarianLaunchHook as Hook } from "../src/MaidMarianLaunchHook.sol";
import { V4PoolManagerMock, V4Trader, WethMock, deltaAmounts } from "./CurveFixtures.sol";
import { mineLaunchHookSalt, launchHookAddress } from "../script/DeployTokenLauncher.s.sol";

// The 1e9-token supply most tests launch with, and the tokens left at its curve's end.
uint256 constant CURVE_SUPPLY = 1e27;
uint256 constant CURVE_RESERVED = (2 * CURVE_SUPPLY) / 7;

/**
 * The launcher with one more door for the suite: `launchBare`, the plain-quote launch without its first
 * buy, so a curve starts at its base price, where the simulation's vectors start. Everything else is the
 * launcher's own code. The real door, `launchWithToken`, makes the creator's first buy, one buy like any
 * other on that same curve: `MaidMarianLauncherScenarios.t.sol` proves it, and the launch's refusals here
 * go through it.
 */
contract LauncherHarness is CurveFactory {
    /// The entry of the quote's list `launchBare` takes (the first when past its end).
    uint256 public pickIndex;

    constructor(Factory etfFactory_, address owner_, IWrappedNative weth_, bytes32 hookSalt) CurveFactory(etfFactory_, owner_, weth_, hookSalt) { }

    function setPickIndex(uint256 i) external {
        pickIndex = i;
    }

    function launchBare(
        string calldata name_,
        string calldata symbol_,
        bytes calldata logoPng,
        CurveFactory.Profile calldata profile,
        address quote,
        uint16 creatorTaxBps,
        uint256 supply,
        address[] calldata snipeExempt
    ) external payable returns (Curve curve) {
        uint256[] memory offered = this.quoteThresholds(quote);
        require(offered.length != 0 && isSupply(supply), "harness: quote or supply");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 threshold = uint128(offered[pickIndex < offered.length ? pickIndex : 0]);
        address pointer = logoPng.length == 0 ? address(0) : storeLogoAsCode(logoPng);
        // forge-lint: disable-next-line(unsafe-typecast)
        Terms memory t = Terms({ quote: quote, etfQuote: false, threshold: threshold, creatorTaxBps: creatorTaxBps, supply: uint96(supply * 1e18), usdgCutPct: 0 });
        curve = _launch(name_, symbol_, pointer, logoPng, profile, t, snipeExempt);
    }
}

/**
 * Offline: the curve factory and its curves over the v3 bis harness (the real
 * `MaidMarianEtfFactory` and `MaidMarianEtfV3` code on mock tokens, pools and router) and a V4
 * PoolManager mock etched at the router's `poolManager()` (`CurveFixtures.sol`). Proves the
 * contracts' arithmetic and refusals against mocks; the deployed ETF factory, mCandles and the
 * deployed PoolManager are `MaidMarianLaunchCurve.fork.t.sol`.
 */
abstract contract CurveBase is EtfV3BisBase {
    LauncherHarness internal cf;
    V4PoolManagerMock internal pm;
    TokenMock internal qt; // a plain 18-decimal quote, listed at the simulation's threshold
    WethMock internal weth; // wrapped ether, the launcher's `WETH`, listed at 4.2

    uint256 internal constant LAUNCH_FEE = 0.0005 ether;
    // The simulation's threshold: 8 000 USDG at NAV 0.996, in shares (`toWei(8000 / 0.996)`).
    uint128 internal constant SIM_THRESHOLD = 8_032_128_514_000_000_000_000;
    /// `launchWithEtf`'s least first buy, the launcher's `MIN_ETF_SEED_USDG`.
    uint256 internal constant SEED_USDG = 10e6;
    /// The least first buy of `launchWithToken` on each listed quote, as the deploy script lists them.
    uint256 internal constant QT_FIRST_BUY = 1e18;
    uint256 internal constant USDG_FIRST_BUY = 5e6;
    uint256 internal constant WETH_FIRST_BUY = 0.002e18;

    address[5] internal holders;

    /// The ETF threshold `_launchWithEtf` picks: the launcher's list at deploy holds 8 000 shares alone.
    uint256 internal etfPick = 8000e18;

    function setUp() public virtual override {
        super.setUp();
        address pmAt = router.poolManager();
        vm.etch(pmAt, address(new V4PoolManagerMock()).code);
        pm = V4PoolManagerMock(pmAt);
        _useEtfFactory();
        weth = new WethMock();
        (bytes32 salt,) = mineLaunchHookSalt(vm.computeCreateAddress(address(this), vm.getNonce(address(this))), pmAt);
        cf = new LauncherHarness(factory, owner, IWrappedNative(address(weth)), salt);
        qt = new TokenMock("QT", "QT", 18);
        PoolMock qtPool = _poolAt(address(qt), _tickAt(1e18), 3000);
        usdg.mint(address(qtPool), 1e12);
        PoolMock wethPool = _poolAt(address(weth), _tickAt(4000e18), 3000);
        usdg.mint(address(wethPool), 1e12);
        vm.startPrank(owner);
        cf.setTokenQuote(address(qt), true, false, oneThreshold(SIM_THRESHOLD), QT_FIRST_BUY);
        cf.setTokenQuote(address(usdg), true, false, oneThreshold(8000e6), USDG_FIRST_BUY);
        cf.setTokenQuote(address(weth), true, false, oneThreshold(4.2e18), WETH_FIRST_BUY);
        vm.stopPrank();
        qt.mint(maker, 1e30);
        vm.prank(maker);
        qt.approve(address(cf), type(uint256).max);
        for (uint256 i = 0; i < 5; i++) {
            holders[i] = makeAddr(string.concat("holder", vm.toString(i)));
            qt.mint(holders[i], 1e30);
            usdg.mint(holders[i], 1e15);
        }
        vm.deal(maker, 10 ether);
        usdg.mint(maker, 1e12);
        vm.prank(maker);
        usdg.approve(address(cf), type(uint256).max);
    }

    /// The ETF factory the launcher is deployed over and the tests create ETFs on: the v3 bis. A subclass
    /// (`MaidMarianLaunchCurveV4.t.sol`) calls `_switchToV4` here, and every test of the suite then runs
    /// on a v4 factory listing the same tokens and pools.
    function _useEtfFactory() internal virtual { }

    function _switchToV4() internal {
        FactoryV4 v4 = new FactoryV4(IERC20(address(usdg)), IUniversalRouter(address(router)), address(v3), owner);
        vm.startPrank(owner);
        v4.addToken(address(a), address(pa));
        v4.addToken(address(b), address(pb));
        v4.addToken(address(c), address(pc));
        v4.setTokenV4Pool(address(c), 100, 1, address(0));
        vm.stopPrank();
        factory = Factory(address(v4));
    }

    /// `launchWithEtf`'s first-mint routes for `legs`: 10 USDG less the 0.10 % entry fee, split by bps,
    /// the dust on leg 0, as the ETF's `firstMintSplit` (no external call, so a prank survives it).
    function _seedRoutes(Factory.LegSpec[] memory legs) internal view returns (Etf.Route[] memory r) {
        return _seedRoutesFor(legs, SEED_USDG);
    }

    /// The same for a seed of `seedUsdg`.
    function _seedRoutesFor(Factory.LegSpec[] memory legs, uint256 seedUsdg) internal view returns (Etf.Route[] memory r) {
        uint256 net = seedUsdg - seedUsdg * 10 / 10_000;
        r = new Etf.Route[](legs.length);
        uint256 sum;
        for (uint256 i = 0; i < legs.length; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            r[i] = Etf.Route({ leg: uint8(i), sell: false, v4: false, amountIn: net * legs[i].bps / 10_000, amountOutMin: 0, deadline: vm.getBlockTimestamp() + 60 });
            sum += r[i].amountIn;
        }
        r[0].amountIn += net - sum;
    }

    function _noProfileC() internal pure returns (CurveFactory.Profile memory) {
        return CurveFactory.Profile({ description: "", x: "", telegram: "", website: "", discord: "" });
    }

    /// A curve on `quote` by `maker`, every holder's quote and USDG approved, the snipe tax past.
    function _launch(address quote, uint16 tax) internal returns (Curve curve) {
        vm.prank(maker);
        curve = cf.launchBare{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), quote, tax, 1_000_000_000, new address[](0));
        _approveAll(curve, quote);
        vm.warp(vm.getBlockTimestamp() + 3);
    }

    function _approveAll(Curve curve, address quote) internal {
        address[8] memory who = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker];
        for (uint256 i = 0; i < who.length; i++) {
            vm.startPrank(who[i]);
            IERC20(quote).approve(address(curve), type(uint256).max);
            usdg.approve(address(curve), type(uint256).max);
            _tok(curve).approve(address(curve), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _noRoutes() internal pure returns (Etf.Route[] memory r) { }

    function _tok(Curve curve) internal view returns (Token) {
        return Token(curve.token());
    }

    /// A sale paid in the quote, or in kind on an ETF quote (which never pays shares).
    function _sell(Curve curve, address who, uint256 tokensIn) internal returns (uint256 out) {
        uint8 payout = curve.etfQuote() ? 1 : 0;
        vm.prank(who);
        out = curve.sell(tokensIn, 0, payout, _noRoutes(), 0, 0);
    }

    /// The price the bond opened its pool at (the bond's one swap moves it after by a few units).
    function _poolPrice(Curve curve) internal view returns (uint160) {
        return pm.openedAt(curve.poolId());
    }

    /// `sqrtPriceX96` of `q` quote per `t` tokens, as the curve computes it.
    function _sqrtAt(Curve curve, uint256 q, uint256 t) internal view returns (uint160) {
        (uint256 a1, uint256 a0) = curve.token() < curve.quote() ? (q, t) : (t, q);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(Math.sqrt(Math.mulDiv(a1, 1 << 192, a0)));
    }

    /// An ETF of a, b, c (50 / 30 / 20) with `p`, its first 1 000 USDG minted by `maker`.
    function _etf(Etf.Params memory p) internal returns (Etf etf) {
        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (address(a), address(b), address(c));
        uint16[] memory w = new uint16[](3);
        (w[0], w[1], w[2]) = (5000, 3000, 2000);
        etf = _createWith("BASE", t, w, p);
        _mint(etf, maker, 1000e6);
    }

    /// The backing ETF's terms as decided: entry and exit 0, hold 0, non-minter penalty 10 %.
    function _backing() internal pure returns (Etf.Params memory) {
        return Etf.Params({ entryFeeBps: 0, exitFeeBps: 0, holdPeriod: 0, earlyPenaltyBps: 0, nonMinterPenaltyBps: 1000, rebalanceBandBps: 200, rebalanceMinInterval: 0 });
    }

    function _legsAbc() internal view returns (Factory.LegSpec[] memory l) {
        l = new Factory.LegSpec[](3);
        l[0] = Factory.LegSpec({ token: address(a), bps: 5000 });
        l[1] = Factory.LegSpec({ token: address(b), bps: 3000 });
        l[2] = Factory.LegSpec({ token: address(c), bps: 2000 });
    }

    /// `launchWithEtf` by `maker`: a reserve ETF of a, b, c (50 / 30 / 20), band 2 %, no interval.
    function _launchWithEtf(string memory name_, string memory symbol_, bytes memory logoPng, CurveFactory.Profile memory p, uint16 tax) internal returns (Etf etf, Curve curve) {
        vm.prank(maker);
        (etf, curve) = cf.launchWithEtf{ value: FEE }(
            name_, symbol_, logoPng, p, _legsAbc(), 200, 0, etfPick, tax, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), 0, new Etf.Route[](0), 0
        );
    }

    /// The same, every holder approved, the snipe tax past.
    function _launchEtf(uint16 tax) internal returns (Etf etf, Curve curve) {
        (etf, curve) = _launchWithEtf("Robin Coin", "ROBIN", "", _noProfileC(), tax);
        _approveAll(curve, address(etf));
        vm.warp(vm.getBlockTimestamp() + 3);
    }

    function _buyUsdg(Curve curve, address who, uint256 usdgIn) internal returns (uint256 tokensOut) {
        Etf etf = Etf(curve.quote());
        Etf.Route[] memory r = _buyRoutes(etf, usdgIn, etf.totalSupply() == 0);
        vm.prank(who);
        tokensOut = curve.buyWithUsdg(usdgIn, r, 1, 1, new Etf.Route[](0), 0);
    }

    function _vectors() internal view returns (string memory) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return vm.readFile("script/curve-vectors.json");
    }

    function _u(string memory json, string memory key) internal pure returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, key));
    }
}

/// The curve against the simulation, to the wei.
contract MaidMarianLaunchCurveSimTest is CurveBase {
    /**
     * `curveBuy`, the contract's own curve step, replays the simulation's check row ("ours, mCandles
     * shares", fee 1 %, tax 0.50 %, buys of 20 shares to the bond) buy by buy: every `tokensOut` of
     * the 408 the simulation's `Curve` gives (the off-chain
     * model, its cut turned off), the end reserves, the fees; the last buy
     * bought whole past the end (real - threshold 5.47 shares, T under 2/7 of the supply); and its
     * 50-share run's fees.
     */
    function test_TheCurveStepReplaysTheSimulationsCheckToTheWei() public view {
        string memory j = _vectors();
        uint256 threshold = _u(j, ".threshold");
        uint256 phantom = _u(j, ".phantom");
        assertEq(threshold, SIM_THRESHOLD);
        assertEq(phantom, threshold * 2 / 5);
        assertEq(_u(j, ".reserved"), CURVE_RESERVED);
        string[] memory outs = vm.parseJsonStringArray(j, ".a.tokensOut");
        assertEq(outs.length, 408);
        (uint256 q, uint256 t, uint256 creatorFees, uint256 protocolFees) = (phantom, CURVE_SUPPLY, 0, 0);
        for (uint256 i = 0; i < outs.length; i++) {
            (uint256 out, uint256 fee, uint256 tax, uint256 net) = curveBuy(q, t, 20e18, 100, 50);
            assertEq(out, vm.parseUint(outs[i]), "tokensOut");
            (q, t) = (q + net, t - out);
            protocolFees += fee * 3000 / 10_000;
            creatorFees += fee - fee * 3000 / 10_000 + tax;
        }
        assertEq(q, _u(j, ".a.q"));
        assertEq(t, _u(j, ".a.t"));
        assertLt(t, CURVE_RESERVED, "past the end");
        assertEq(q - phantom - threshold, 5_471_486e12, "real - threshold: the last 20 shares, whole");
        assertEq(creatorFees, _u(j, ".a.creator"));
        assertEq(protocolFees, _u(j, ".a.protocol"));
        // Price x12.25 first to the curve's end, a little more past it: (q / t) / (phantom / supply).
        assertGt(Math.mulDiv(q * 1e18, CURVE_SUPPLY, t * phantom), 12.25e18);
        assertApproxEqRel(Math.mulDiv(q * 1e18, CURVE_SUPPLY, t * phantom), 12.25e18, 2e15);

        (q, t, creatorFees, protocolFees) = (phantom, CURVE_SUPPLY, 0, 0);
        uint256 buys;
        while (q - phantom < threshold && t > CURVE_RESERVED) {
            (uint256 out, uint256 fee, uint256 tax, uint256 net) = curveBuy(q, t, 50e18, 100, 50);
            (q, t) = (q + net, t - out);
            protocolFees += fee * 3000 / 10_000;
            creatorFees += fee - fee * 3000 / 10_000 + tax;
            buys++;
        }
        assertEq(buys, vm.parseJsonUint(j, ".b.buys"));
        assertEq(q, _u(j, ".b.q"));
        assertEq(creatorFees, _u(j, ".b.creator"));
        assertEq(protocolFees, _u(j, ".b.protocol"));
    }

    /**
     * A deployed curve (a clone, quote 18 decimals listed at the simulation's threshold, creator tax
     * 0.50 %, the contract's 0.75 % fee) replays the simulation's seeded walk of 401 trades by five
     * holders - 263 buys, 138 sales, then one buy past the end, bought whole - to the wei: every output,
     * every amount paid, both reserves and both fee balances after each trade; and the walk's last buy
     * bonds.
     */
    function test_ACurveReplaysTheSimulationsWalkToTheWei() public {
        string memory j = _vectors();
        Curve curve = _launch(address(qt), 50);
        uint256 n = vm.parseJsonUint(j, ".walk.count");
        for (uint256 i = 0; i < n; i++) {
            string memory k = string.concat(".walk.ops[", vm.toString(i), "]");
            address who = holders[vm.parseJsonUint(j, string.concat(k, ".who"))];
            uint256 amount = _u(j, string.concat(k, ".amount"));
            if (keccak256(bytes(vm.parseJsonString(j, string.concat(k, ".kind")))) == keccak256("buy")) {
                uint256 before = qt.balanceOf(who);
                vm.prank(who);
                uint256 out = curve.buy(amount, 0);
                assertEq(out, _u(j, string.concat(k, ".out")), "tokensOut");
                assertEq(before - qt.balanceOf(who), amount - _u(j, string.concat(k, ".refund")), "quote paid");
            } else {
                assertEq(_sell(curve, who, amount), _u(j, string.concat(k, ".out")), "quoteOut");
            }
            if (curve.bonded()) {
                assertEq(i, n - 1, "only the last trade bonds");
                break;
            }
            (uint256 q, uint256 t) = curve.getReserves();
            assertEq(q, _u(j, string.concat(k, ".q")), "quote reserve");
            assertEq(t, _u(j, string.concat(k, ".t")), "token reserve");
            assertEq(curve.creatorFees(), _u(j, string.concat(k, ".creator")), "creator fees");
            assertEq(curve.protocolFees(), _u(j, string.concat(k, ".protocol")), "protocol fees");
        }
        assertTrue(curve.bonded());
        (uint256 qEnd, uint256 tEnd) = curve.getReserves();
        string memory last = string.concat(".walk.ops[", vm.toString(n - 1), "]");
        assertEq(qEnd, _u(j, string.concat(last, ".q")));
        assertEq(tEnd, _u(j, string.concat(last, ".t")));
        assertLt(tEnd, CURVE_RESERVED, "past the end");
        assertEq(curve.creatorFees(), _u(j, string.concat(last, ".creator")));
        assertEq(curve.protocolFees() - curve.bondSetAside(), _u(j, string.concat(last, ".protocol")), "the protocol's fees, the bond's 30 % booked beside them");
    }
}

/// Fees, taxes, snipe protection, solvency.
contract MaidMarianLaunchCurveFeesTest is CurveBase {
    /// A USDG curve, tax 3 %: a buy of 1 000 USDG pays 7.5 fee (2.25 protocol, 5.25 creator) and 30
    /// tax (creator), a sale the same rates on its gross; the curve holds exactly its reserve and fees.
    function test_FeesAndTaxSplitToTheUnit() public {
        Curve curve = _launch(address(usdg), 300);
        vm.prank(alice);
        uint256 out = curve.buy(1000e6, 0);
        assertEq(curve.protocolFees(), 2.25e6);
        assertEq(curve.creatorFees(), 5.25e6 + 30e6);
        assertEq(curve.realQuote(), 1000e6 - 7.5e6 - 30e6);
        (uint256 q, uint256 t) = curve.getReserves();
        (uint256 gross, uint256 fee, uint256 tax) = curveSell(q, t, out / 2, 75, 300);
        uint256 before = usdg.balanceOf(alice);
        assertEq(_sell(curve, alice, out / 2), gross - fee - tax);
        assertEq(usdg.balanceOf(alice) - before, gross - fee - tax);
        assertEq(curve.protocolFees(), 2.25e6 + fee * 3000 / 10_000);
        assertEq(curve.creatorFees(), 35.25e6 + fee - fee * 3000 / 10_000 + tax);
        assertEq(usdg.balanceOf(address(curve)), curve.realQuote() + curve.creatorFees() + curve.protocolFees());
    }

    /// Pons's snipe tax: 9 900 >> (s x 14 / 3) bps on a buy s seconds after the launch - 99 %, 6.18 %,
    /// 0.19 %, then 0 from 3 s - in the fee (split 30 / 70), never past 100 % with the tax; the
    /// creator exempt.
    function test_TheSnipeTaxIsPonssAndSparesTheCreator() public {
        vm.prank(maker);
        Curve curve = cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(usdg), 8000e6, 100, 1_000_000_000, USDG_FIRST_BUY, new address[](0));
        _approveAll(curve, address(usdg));
        uint256 t0 = vm.getBlockTimestamp();
        assertEq(curve.currentSnipeTaxBps(alice), 9900);
        assertEq(curve.currentSnipeTaxBps(maker), 0);
        (, uint256 fee0,) = curve.previewBuy(1000e6, alice);
        assertEq(fee0, 1000e6 * (10_000 - 100) / 10_000, "fee + snipe capped at 100 % less the tax");
        uint256 pFirst = curve.protocolFees();
        assertEq(pFirst, USDG_FIRST_BUY * 75 / 10_000 * 3000 / 10_000, "the first buy, at second 0: 0.75 % only");
        vm.prank(maker);
        curve.buy(100e6, 0);
        assertEq(curve.protocolFees() - pFirst, 100e6 * 75 / 10_000 * 3000 / 10_000, "the creator pays 0.75 % only");
        vm.warp(t0 + 1);
        assertEq(curve.currentSnipeTaxBps(alice), 618);
        uint256 p = curve.protocolFees();
        vm.prank(alice);
        curve.buy(1000e6, 0);
        assertEq(curve.protocolFees() - p, 1000e6 * 693 / 10_000 * 3000 / 10_000);
        vm.warp(t0 + 2);
        assertEq(curve.currentSnipeTaxBps(alice), 19);
        vm.warp(t0 + 3);
        assertEq(curve.currentSnipeTaxBps(alice), 0);
    }

    /// Fuzzed: random buys and sales by three holders never leave the real reserve short of what
    /// selling every outstanding token at once would pay, the quote balance is the reserve plus the
    /// fees to the wei, and a full unwind brings the token reserve back to the supply with the real
    /// reserve never below 0.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_TheReserveAlwaysCoversTheCurve(uint256 seed) public {
        Curve curve = _launch(address(qt), 200);
        uint256[3] memory held;
        for (uint256 i = 0; i < 40; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 who = seed % 3;
            if (seed % 5 < 3 || held[who] == 0) {
                vm.prank(holders[who]);
                held[who] += curve.buy(1e15 + (seed >> 8) % 300e18, 0);
                if (curve.bonded()) return;
            } else {
                uint256 amount = held[who] * (1 + (seed >> 16) % 1000) / 1000;
                _sell(curve, holders[who], amount);
                held[who] -= amount;
            }
            (uint256 q, uint256 t) = curve.getReserves();
            assertGe(curve.realQuote(), q - Math.ceilDiv(q * t, CURVE_SUPPLY), "owed if all sold");
            assertEq(qt.balanceOf(address(curve)), curve.realQuote() + curve.creatorFees() + curve.protocolFees());
        }
        for (uint256 w = 0; w < 3; w++) {
            if (held[w] > 0) _sell(curve, holders[w], held[w]);
        }
        (, uint256 tEnd) = curve.getReserves();
        assertEq(tEnd, CURVE_SUPPLY);
        assertLt(curve.realQuote(), 1e6, "dust only");
    }
}

/// The bond.
contract MaidMarianLaunchCurveBondTest is CurveBase {
    /// A plain quote's bond: the pool opens at the curve's last price with 70 % of the real quote, 30 %
    /// (and the dust) booked to the protocol's fees (`bondSetAside`), nothing paid out, every token not
    /// in the pool burned, the curve left with its fees only, the position the curve's; trading on the
    /// curve refused after.
    function test_ThePlainBondSplits30To70AndBurnsTheRest() public {
        Curve curve = _launch(address(qt), 50);
        vm.prank(holders[0]);
        curve.buy(5000e18, 0);
        (uint256 q0,) = curve.getReserves();
        uint256 ownerBefore = qt.balanceOf(owner);
        vm.prank(holders[1]);
        curve.buy(9000e18, 0);
        assertTrue(curve.bonded());
        (uint256 q, uint256 t) = curve.getReserves();
        assertGt(q, q0);
        assertLt(t, CURVE_RESERVED, "the whole 9 000 bought, past the end");
        uint256 real = q - curve.phantomQuote();
        uint256 poolQuote = qt.balanceOf(address(pm));
        uint256 p0 = curve.protocolFees();
        uint256 setAside = curve.bondSetAside();
        assertEq(qt.balanceOf(owner), ownerBefore, "nothing paid at the bond");
        assertEq(setAside + poolQuote, real, "70 / 30 of the real quote, dust to the set-aside");
        assertGe(p0, setAside, "booked to the protocol's fees");
        assertGe(setAside, real * 3000 / 10_000);
        assertLe(setAside, real * 3000 / 10_000 + 2 + curve.BOND_SWAP_QUOTE_UNITS(), "and the bond swap's output");
        assertEq(qt.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees());
        // The pool's price is the curve's last; its tokens keep that price; the rest is burned.
        assertEq(_poolPrice(curve), _sqrtAt(curve, q, t));
        uint256 poolTokens = _tok(curve).balanceOf(address(pm));
        assertApproxEqRel(poolTokens, Math.mulDiv(t, real - real * 3000 / 10_000, q), 1e3, "the price-keeping tokens, to 1e-15");
        assertEq(_tok(curve).balanceOf(address(curve)), 0);
        assertEq(_tok(curve).totalSupply(), CURVE_SUPPLY - (t - poolTokens));
        assertGt(pm.liquidity(curve.poolId()), 0);
        vm.prank(holders[0]);
        vm.expectRevert(Curve.AlreadyBonded.selector);
        curve.buy(1e18, 0);
        vm.prank(holders[0]);
        vm.expectRevert(Curve.AlreadyBonded.selector);
        curve.sell(1e18, 0, 0, _noRoutes(), 0, 0);
    }

    /// The token is a plain ERC-20: before the bond a holder may open his own hookless V4 pool of it at any
    /// price and fill it; that pool has another key (no `HOOK`), so the bond still opens its own at the
    /// curve's price, and after the bond the bond's pool trades.
    function test_AStrangersOwnPoolBeforeTheBondLeavesTheBondPoolAlone() public {
        Curve curve = _launch(address(qt), 0);
        vm.prank(holders[0]);
        curve.buy(100e18, 0);
        Token token = _tok(curve);
        V4Trader trader = new V4Trader(IPoolManagerV4(address(pm)));
        IPoolManagerV4.PoolKey memory own = curve.poolKey();
        own.hooks = address(0);
        pm.initialize(own, 1 << 96);
        vm.startPrank(holders[0]);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(address(trader), 1e24);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        qt.transfer(address(trader), 1e24);
        vm.stopPrank();
        trader.addLiquidity(own, -887_200, 887_200, 1e20);
        vm.prank(holders[1]);
        curve.buy(9000e18, 0);
        assertTrue(curve.bonded());
        (uint256 q, uint256 t) = curve.getReserves();
        assertEq(pm.openedAt(curve.poolId()), _sqrtAt(curve, q, t), "the bond's pool opens at the curve's price");
        vm.prank(holders[0]);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(address(trader), 1e24);
        IPoolManagerV4.PoolKey memory key = curve.poolKey();
        bool tokenIs0 = key.currency0 == curve.token();
        int256 d = trader.swapExactIn(key, tokenIs0, 1e24, tokenIs0 ? 4295128740 : 1461446703485210103287273052203988822378723970341);
        (int256 a0, int256 a1) = deltaAmounts(d);
        assertGt(tokenIs0 ? a1 : a0, 0, "the pool pays quote for the tokens");
    }

    /// No one but the curve opens its pool: a stranger's `initialize` of the bond's key is refused by
    /// the hook before the bond (at any price) and after it, and the last buy opens it at the curve's price.
    function test_NoOneButItsCurveInitializesTheBondPool() public {
        Curve curve = _launch(address(qt), 0);
        assertEq(curve.poolKey().hooks, address(cf.HOOK()));
        vm.prank(holders[0]);
        curve.buy(100e18, 0);
        IPoolManagerV4.PoolKey memory key = curve.poolKey();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Hook.NotLaunchedCurve.selector, alice));
        pm.initialize(key, uint160(1 << 96));
        vm.prank(holders[1]);
        curve.buy(9000e18, 0);
        assertTrue(curve.bonded());
        (uint256 q, uint256 t) = curve.getReserves();
        assertEq(_poolPrice(curve), _sqrtAt(curve, q, t));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Hook.NotLaunchedCurve.selector, alice));
        pm.initialize(key, uint160(1 << 96));
    }

    /// The hook answers the PoolManager only, and passes a launched curve on its own pool key only: not
    /// another curve of the launcher on that key, not a stranger, not a curve of another launcher.
    function test_TheHookPassesOnlyALaunchedCurveOnItsOwnPool() public {
        Hook hook = cf.HOOK();
        assertEq(hook.LAUNCHER(), address(cf));
        assertEq(hook.POOL_MANAGER(), address(pm));
        Curve mine = _launch(address(qt), 0);
        Curve other = _launch(address(usdg), 0);
        IPoolManagerV4.PoolKey memory key = mine.poolKey();
        vm.expectRevert(Hook.NotPoolManager.selector);
        hook.beforeInitialize(address(mine), key, 1 << 96);
        vm.prank(address(mine));
        vm.expectRevert(Hook.NotPoolManager.selector);
        hook.beforeInitialize(address(mine), key, 1 << 96);
        vm.startPrank(address(pm));
        assertEq(hook.beforeInitialize(address(mine), key, 1 << 96), Hook.beforeInitialize.selector);
        vm.expectRevert(abi.encodeWithSelector(Hook.NotLaunchedCurve.selector, address(other)));
        hook.beforeInitialize(address(other), key, 1 << 96);
        vm.expectRevert(abi.encodeWithSelector(Hook.NotLaunchedCurve.selector, alice));
        hook.beforeInitialize(alice, key, 1 << 96);
        key.fee = 3000;
        vm.expectRevert(abi.encodeWithSelector(Hook.NotLaunchedCurve.selector, address(mine)));
        hook.beforeInitialize(address(mine), key, 1 << 96);
        vm.stopPrank();
    }

    /// The hook's address carries `beforeInitialize` alone among V4's 14 permission bits; a salt that
    /// gives any other address is refused by the launcher's constructor.
    function test_TheHookAddressHasTheBeforeInitializeFlagAlone() public {
        assertEq(uint160(address(cf.HOOK())) & 0x3fff, 0x2000);
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        (bytes32 salt,) = mineLaunchHookSalt(next, address(pm));
        bytes32 bad = bytes32(uint256(salt) + 1);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadHookAddress.selector, launchHookAddress(next, address(pm), bad)));
        new CurveFactory(factory, owner, IWrappedNative(address(weth)), bad);
    }

    /// After the bond, the pool's 1 % fees are the curve's position's: `collectPoolFees` gives the
    /// tokens' 70 % to the creator and 30 % to the owner, and credits the quote's to the fee balances.
    function test_PoolFeesGo70ToTheCreatorAnd30ToTheProtocol() public {
        Curve curve = _launch(address(qt), 0);
        vm.prank(holders[1]);
        curve.buy(9000e18, 0);
        V4Trader trader = new V4Trader(IPoolManagerV4(address(pm)));
        qt.mint(address(trader), 1000e18);
        // The bond's own swap left its 1 % in the pool's token fees.
        uint256 bondFee = curve.token() < address(qt) ? pm.fees0(curve.poolId()) : pm.fees1(curve.poolId());
        Token token = _tok(curve);
        vm.prank(holders[1]);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(address(trader), 1e24);
        IPoolManagerV4.PoolKey memory key = curve.poolKey();
        bool tokenIs0 = key.currency0 == curve.token();
        uint160 lo = 4295128740;
        uint160 hi = 1461446703485210103287273052203988822378723970341;
        trader.swapExactIn(key, tokenIs0, 1e24, tokenIs0 ? lo : hi);
        trader.swapExactIn(key, !tokenIs0, 100e18, tokenIs0 ? hi : lo);
        bytes32 id = curve.poolId();
        (uint256 tokenFee, uint256 quoteFee) = tokenIs0 ? (pm.fees0(id), pm.fees1(id)) : (pm.fees1(id), pm.fees0(id));
        assertEq(tokenFee - bondFee, 1e24 - 1e24 * 99 / 100, "beside the bond swap's fee");
        assertEq(quoteFee, 100e18 - 100e18 * 99 / 100);
        uint256 c0 = curve.creatorFees();
        uint256 p0 = curve.protocolFees();
        uint256 makerTokens = _tok(curve).balanceOf(maker);
        (uint256 tf, uint256 qf) = curve.collectPoolFees();
        assertEq(tf, tokenFee);
        assertEq(qf, quoteFee);
        assertEq(_tok(curve).balanceOf(owner), tokenFee * 3000 / 10_000);
        assertEq(_tok(curve).balanceOf(maker) - makerTokens, tokenFee - tokenFee * 3000 / 10_000);
        assertEq(curve.protocolFees() - p0, quoteFee * 3000 / 10_000);
        assertEq(curve.creatorFees() - c0, quoteFee - quoteFee * 3000 / 10_000);
    }

    /// The bond's 30 % stays in the curve, booked to the protocol's fees: the owner claims it with them,
    /// in the quote, to whom he names; the creator cannot (`NotOwner` is his claim of the protocol's).
    function test_TheOwnerClaimsTheBondsSetAsideWithTheProtocolsFees() public {
        Curve curve = _launch(address(qt), 0);
        vm.prank(holders[1]);
        curve.buy(9000e18, 0);
        uint256 real = curve.realQuote();
        uint256 setAside = curve.bondSetAside();
        assertApproxEqAbs(setAside, real * 3000 / 10_000, 2 + curve.BOND_SWAP_QUOTE_UNITS(), "the 30 %, the rounding and the bond swap's output");
        uint256 due = curve.protocolFees();
        assertGt(due, setAside, "the set-aside and the protocol's 30 % of the fees");
        vm.prank(maker);
        vm.expectRevert(Curve.NotOwner.selector);
        curve.claim(true, due, maker, 0, _noRoutes(), 0, 0);
        address treasury = makeAddr("treasury");
        vm.prank(owner);
        curve.claim(true, due, treasury, 0, _noRoutes(), 0, 0);
        assertEq(qt.balanceOf(treasury), due);
        assertEq(curve.protocolFees(), 0);
        assertEq(curve.bondSetAside(), setAside, "a record of the bond");
        assertEq(qt.balanceOf(address(curve)), curve.creatorFees());
    }
}

/// An ETF quote, through the real `MaidMarianEtfV3` code: the reserve ETF `launchWithEtf` creates.
contract MaidMarianLaunchCurveEtfTest is CurveBase {
    /// `buyWithUsdg`: the curve mints the shares (its own `mintOf`), buys with exactly what the mint
    /// gave, and sends what the mint refunded to the launcher's owner: the buyer pays his USDG to the wei,
    /// the curve keeps no leg and no USDG.
    function test_ABuyInUsdgMintsTheSharesAndSendsTheRefundsToTheOwner() public {
        (Etf etf, Curve curve) = _launchEtf(50);
        _buyUsdg(curve, bob, 100e6);
        (uint256 q, uint256 t) = curve.getReserves();
        uint256 sharesBefore = etf.balanceOf(address(curve));
        uint256 usdgBefore = usdg.balanceOf(alice);
        uint256 ownerBefore = usdg.balanceOf(cf.owner());
        uint256 out = _buyUsdg(curve, alice, 500e6);
        uint256 shares = etf.balanceOf(address(curve)) - sharesBefore;
        (uint256 expected,,,) = curveBuy(q, t, shares, 75, 50);
        assertEq(out, expected);
        assertEq(_tok(curve).balanceOf(alice), out);
        assertEq(etf.mintOf(address(curve)), etf.balanceOf(address(curve)));
        assertEq(usdgBefore - usdg.balanceOf(alice), 500e6, "his USDG, to the wei: no refund to him");
        (uint256 entry,,) = etf.entryFee(500e6);
        assertGt(usdg.balanceOf(cf.owner()) - ownerBefore, entry, "the mint's USDG refund to the owner, beside the ETF's entry fee");
        assertEq(usdg.balanceOf(address(curve)), 0);
        assertEq(a.balanceOf(address(curve)) + b.balanceOf(address(curve)) + c.balanceOf(address(curve)), 0);
    }

    /// A sale paid in kind, or in USDG through the caller's routes, both redeemed by the curve within its
    /// `mintOf`, so no non-minter penalty: the seller gets the ETF's whole due. In shares it is refused.
    function test_ASaleIsPaidInKindOrInUsdgNeverInShares() public {
        (Etf etf, Curve curve) = _launchEtf(0);
        uint256 out = _buyUsdg(curve, alice, 2000e6);
        // Shares: refused.
        (uint256 quoteOut,,) = curve.previewSell(out / 4);
        vm.prank(alice);
        vm.expectRevert(Curve.SharesStayInTheCurve.selector);
        curve.sell(out / 4, quoteOut, 0, _noRoutes(), 0, 0);
        assertEq(etf.balanceOf(alice), 0);
        // In kind.
        (,, uint256 penalty, uint256[] memory amounts, uint256 usdgDue) = etf.previewRedeem(address(curve), quoteOut);
        assertEq(penalty, 0);
        uint256 aBefore = a.balanceOf(alice);
        uint256 uBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        curve.sell(out / 4, quoteOut, 1, _noRoutes(), 0, 0);
        assertEq(a.balanceOf(alice) - aBefore, amounts[0]);
        assertEq(usdg.balanceOf(alice) - uBefore, usdgDue);
        // USDG.
        (quoteOut,,) = curve.previewSell(out / 4);
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(address(curve), quoteOut);
        uBefore = usdg.balanceOf(alice);
        Etf.Route[] memory sr = _sellRoutes(etf, due);
        vm.prank(alice);
        curve.sell(out / 4, quoteOut, 2, sr, 1, 0);
        assertGt(usdg.balanceOf(alice), uBefore);
        assertEq(a.balanceOf(address(curve)) + usdg.balanceOf(address(curve)), 0);
    }

    /// Every share an ETF curve holds is one it minted: the shares it buys with are minted by its own
    /// `buyWithUsdg` (a buy in shares is refused), so its `mintOf` stays its balance through buys and
    /// sales, and its redeems are free of the non-minter penalty whatever the ETF's terms.
    function test_EveryShareAnEtfCurveHoldsIsOneItMinted() public {
        (Etf etf, Curve curve) = _launchEtf(0);
        uint256 out = _buyUsdg(curve, alice, 1000e6);
        _buyUsdg(curve, bob, 700e6);
        _sell(curve, alice, out / 2);
        assertEq(etf.mintOf(address(curve)), etf.balanceOf(address(curve)));
        vm.prank(maker);
        usdg.approve(address(etf), type(uint256).max);
        uint256 shares = _mint(etf, maker, 100e6);
        vm.prank(maker);
        etf.approve(address(curve), type(uint256).max);
        vm.prank(maker);
        vm.expectRevert(Curve.SharesStayInTheCurve.selector);
        curve.buy(shares, 0);
        assertEq(etf.mintOf(address(curve)), etf.balanceOf(address(curve)));
    }

    /// An ETF quote's bond at 8 000 shares: 30 % of them stay in the curve, booked to the protocol's fees
    /// (`bondSetAside`), nothing redeemed and no leg touched at the bond; 70 % in the pool with the
    /// tokens that keep the curve's price.
    function test_AnEtfBondBooksTheSetAsideToTheProtocol() public {
        (Etf etf, Curve curve) = _launchEtf(0);
        assertEq(curve.threshold(), 8000e18);
        _buyUsdg(curve, alice, 4000e6);
        uint256 aBefore = a.balanceOf(owner);
        uint256 sharesOwnerBefore = etf.balanceOf(owner);
        _buyUsdg(curve, bob, 6000e6);
        assertTrue(curve.bonded());
        uint256 real = curve.realQuote();
        assertGe(real, 8000e18);
        uint256 poolShares = etf.balanceOf(address(pm));
        assertApproxEqAbs(poolShares, real - real * 3000 / 10_000, 2 + curve.BOND_SWAP_QUOTE_UNITS(), "70 %, less the bond swap's output");
        assertEq(curve.bondSetAside() + poolShares, real, "70 / 30, dust to the set-aside");
        assertGe(curve.protocolFees(), curve.bondSetAside(), "booked to the protocol's fees");
        assertEq(a.balanceOf(owner), aBefore, "no leg paid at the bond");
        assertEq(etf.balanceOf(owner) - sharesOwnerBefore, 0, "no shares handed over");
        assertEq(etf.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees());
        (uint256 q, uint256 t) = curve.getReserves();
        assertEq(_poolPrice(curve), _sqrtAt(curve, q, t));
    }

    /// The reserve ETF's terms are the launcher's, whatever the caller: no fee and no penalty (entry, exit,
    /// hold, early, non-minter all 0); the caller's band and interval only. Anyone who holds its shares
    /// (minted straight on the ETF, outside the launcher) redeems them free before and after the bond; fee
    /// claims are paid at once, in kind or in USDG, never as shares.
    function test_TheReserveEtfsTermsAreFixedAndClaimsPayAtOnce() public {
        vm.prank(maker);
        (Etf etf, Curve curve) = cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 750, 6 hours, 8000e18, 100, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), 0, new Etf.Route[](0), 0
        );
        Etf.Params memory p = etf.params();
        assertEq(
            abi.encode(p), abi.encode(Etf.Params({ entryFeeBps: 0, exitFeeBps: 0, holdPeriod: 0, earlyPenaltyBps: 0, nonMinterPenaltyBps: 0, rebalanceBandBps: 750, rebalanceMinInterval: 6 hours }))
        );
        _approveAll(curve, address(etf));
        vm.warp(vm.getBlockTimestamp() + 3);
        // A holder of shares he did not mint (given by a minter) redeems them free, before the bond.
        _buyUsdg(curve, alice, 1000e6);
        vm.prank(carol);
        usdg.approve(address(etf), type(uint256).max);
        usdg.mint(carol, 1000e6);
        uint256 shares = _mint(etf, carol, 500e6);
        vm.prank(carol);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        etf.transfer(alice, shares);
        assertEq(etf.mintOf(alice), 0);
        (, uint256 feeShares, uint256 penaltyShares,,) = etf.previewRedeem(alice, shares / 2);
        assertEq(feeShares + penaltyShares, 0);
        uint256 aBefore = a.balanceOf(alice);
        vm.prank(alice);
        etf.redeemInKind(shares / 2, alice, 0);
        assertGt(a.balanceOf(alice), aBefore);
        _buyUsdg(curve, bob, 11_000e6);
        assertTrue(curve.bonded());
        // And after it.
        uint256 left = etf.balanceOf(alice);
        (, feeShares, penaltyShares,,) = etf.previewRedeem(alice, left);
        assertEq(feeShares + penaltyShares, 0);
        vm.prank(alice);
        etf.redeemInKind(left, alice, 0);
        assertEq(etf.balanceOf(alice), 0);
        uint256 inShares = curve.creatorFees() / 4;
        address dave = makeAddr("dave");
        vm.prank(maker);
        vm.expectRevert(Curve.SharesStayInTheCurve.selector);
        curve.claim(false, inShares, dave, 0, _noRoutes(), 0, 0);
        assertEq(etf.balanceOf(dave), 0, "never the shares themselves");
        uint256 creatorFees = curve.creatorFees() + curve.unbookedShares();
        (,, uint256 penalty,,) = etf.previewRedeem(address(curve), creatorFees);
        assertEq(penalty, 0);
        vm.prank(maker);
        curve.claim(false, creatorFees, carol, 1, _noRoutes(), 0, 0);
        assertGt(a.balanceOf(carol), 0);
        assertEq(etf.balanceOf(carol), 0);
        uint256 protocolFees = curve.protocolFees();
        (uint256[] memory dueLegs,,,) = etf.previewRedeemToUsdg(address(curve), protocolFees);
        uint256 uBefore = usdg.balanceOf(owner);
        Etf.Route[] memory sr = _sellRoutes(etf, dueLegs);
        vm.prank(owner);
        curve.claim(true, protocolFees, owner, 2, sr, 1, 0);
        assertGt(usdg.balanceOf(owner), uBefore);
        assertEq(curve.protocolFees(), 0);
    }

    /// `launchWithEtf` makes the reserve ETF's first mint in the launch, the caller's 10 USDG (approved to
    /// the launcher) bought on the curve for him: no one else sets a share's first price, the shares stay in
    /// the curve, his tokens are his.
    function test_LaunchWithEtfMakesTheReserveEtfsFirstMintWithTheCallersUsdg() public {
        assertEq(cf.MIN_ETF_SEED_USDG(), SEED_USDG);
        uint256 usdgBefore = usdg.balanceOf(maker);
        (Etf etf, Curve curve) = _launchEtf(0);
        assertEq(usdgBefore - usdg.balanceOf(maker), SEED_USDG, "10 USDG from the caller");
        // One share per USDG kept after the 0.10 % entry fee, `DEAD_SHARES` locked, the rest the curve's.
        assertEq(etf.totalSupply(), 9.99e18);
        assertEq(etf.balanceOf(address(curve)), 9.99e18 - etf.DEAD_SHARES());
        assertEq(etf.balanceOf(maker), 0);
        assertGt(_tok(curve).balanceOf(maker), 0, "his first buy");
        assertEq(usdg.balanceOf(address(cf)), 0);
        assertEq(etf.balanceOf(address(cf)), 0);
        (uint256 nav,) = etf.nav();
        assertApproxEqRel(nav * 1e18 / etf.totalSupply(), 1e6, 0.02e18, "a share at 1 USDG");
        uint256 out = _buyUsdg(curve, alice, 100e6);
        assertGt(out, 0);
        assertEq(etf.mintOf(address(curve)), etf.balanceOf(address(curve)));
        // Without the 10 USDG approved, no launch.
        address poor = makeAddr("poor");
        vm.deal(poor, 1 ether);
        vm.prank(poor);
        vm.expectRevert();
        cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 0, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), 0, new Etf.Route[](0), 0
        );
    }

    /// `launchWithEtf`: one transaction, the ETF factory's creation fee only, the launcher the ETF's creator
    /// and the curve its fee recipient, the curve on it at 8 000 shares. The ETF is named after the token
    /// ("<name> ETF", "etf<symbol>", the case kept), shares its logo (one pointer, stored once) and holds the
    /// token's profile, but Discord, kept by the launcher; `profileOf(curve)` reads both. A name over 60 bytes, a
    /// symbol over 8, a logo over 10 KiB and a wrong fee are refused.
    function test_LaunchWithEtfNamesTheEtfAfterItsTokenAndMakesTheCurveItsFeeRecipient() public {
        CurveFactory.Profile memory p = CurveFactory.Profile({ description: "A coin.", x: "https://x.com/robin", telegram: "https://t.me/robins", website: "https://example.com", discord: "https://discord.gg/robins" });
        uint256 etfFactoryBalance = address(factory).balance;
        (Etf etf, Curve curve) = _launchWithEtf("NinjaWarrior", "NW", _png(64, 64, 100), p, 0);
        assertEq(address(factory).balance - etfFactoryBalance, FEE);
        assertEq(address(cf).balance, 0);
        assertTrue(factory.isEtf(address(etf)));
        assertEq(etf.creator(), address(cf));
        assertEq(etf.feeRecipient(), address(curve));
        assertEq(etf.name(), "NinjaWarrior ETF");
        assertEq(etf.symbol(), "etfNW");
        assertEq(_tok(curve).name(), "NinjaWarrior");
        assertEq(_tok(curve).symbol(), "NW");
        assertEq(curve.quote(), address(etf));
        assertTrue(curve.etfQuote());
        assertEq(curve.threshold(), 8000e18);
        assertEq(curve.creator(), maker);
        assertEq(cf.curveInfo(address(curve)).logoPointer, factory.etfInfo(address(etf)).logoPointer, "one logo, stored once");
        assertEq(keccak256(curve.logo()), keccak256(_png(64, 64, 100)));
        assertEq(keccak256(factory.logo(address(etf))), keccak256(_png(64, 64, 100)));
        (string memory d, string memory x, string memory t, string memory w,) = factory.profileOf(address(etf));
        assertEq(abi.encode(d, x, t, w), abi.encode(p.description, p.x, p.telegram, p.website), "stored on the ETF");
        (CurveFactory.Profile memory cp,) = cf.profileOf(address(curve));
        assertEq(abi.encode(cp), abi.encode(p), "the token's, Discord too");
        vm.prank(maker);
        cf.setProfile(address(curve), CurveFactory.Profile({ description: "Another coin.", x: "", telegram: "https://t.me/robins", website: "", discord: "https://discord.gg/other" }));
        (d, x, t, w,) = factory.profileOf(address(etf));
        assertEq(abi.encode(d, x, t, w), abi.encode("Another coin.", "", "https://t.me/robins", ""), "edited on the ETF");
        (cp,) = cf.profileOf(address(curve));
        assertEq(abi.encode(cp), abi.encode(CurveFactory.Profile({ description: "Another coin.", x: "", telegram: "https://t.me/robins", website: "", discord: "https://discord.gg/other" })));

        (etf, curve) = _launchWithEtf("RH Sdeamon", "rhD", "", _noProfileC(), 0);
        assertEq(etf.name(), "RH Sdeamon ETF");
        assertEq(etf.symbol(), "etfrhD");
        string memory name60 = "Robin Coin Robin Coin Robin Coin Robin Coin Robin Coin Robin";
        assertEq(bytes(name60).length, 60);
        (etf, curve) = _launchWithEtf(name60, "ROBINHOO", "", _noProfileC(), 0);
        assertEq(etf.name(), string.concat(name60, " ETF"));
        assertEq(etf.symbol(), "etfROBINHOO");
        vm.prank(maker);
        vm.expectRevert(BadName.selector);
        cf.launchWithEtf{ value: FEE }(
            string.concat(name60, "X"), "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 0, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), 0, new Etf.Route[](0), 0
        );
        assertEq(cf.curveInfo(address(curve)).logoPointer, address(0));
        vm.prank(maker);
        vm.expectRevert(BadSymbol.selector);
        cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBINHOOD", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 0, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), 0, new Etf.Route[](0), 0
        );
        vm.prank(maker);
        vm.expectRevert(BadLogo.selector);
        cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", _png(64, 64, 10_241), _noProfileC(), _legsAbc(), 200, 0, 8000e18, 0, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), 0, new Etf.Route[](0), 0
        );
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Factory.WrongCreationFee.selector, FEE, 0.0005 ether));
        cf.launchWithEtf{ value: 0.0005 ether }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 0, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), 0, new Etf.Route[](0), 0
        );
    }
}

/// The factory: launch fee, quotes, profile, clones.
contract MaidMarianTokenLauncherTest is CurveBase {
    /// `setEtfFactory`, by the owner only: refused without code or for a contract that does not answer
    /// as an ETF factory on this USDG and PoolManager; a launch after the change creates its reserve ETF
    /// on the new factory, and a curve launched before keeps its ETF and its old factory's legs: it buys,
    /// sells and bonds as if nothing happened.
    function test_TheEtfFactoryChangesForNewLaunchesOnly() public {
        (Etf oldEtf, Curve oldCurve) = _launchEtf(0);
        _buyUsdg(oldCurve, alice, 100e6);
        Factory next = new Factory(IERC20(address(usdg)), IUniversalRouter(address(router)), address(v3), owner);
        vm.startPrank(owner);
        next.addToken(address(a), address(pa));
        next.addToken(address(b), address(pb));
        next.addToken(address(c), address(pc));
        next.setTokenV4Pool(address(c), 100, 1);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cf.setEtfFactory(next);
        address nothing = makeAddr("nothing");
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.NoCode.selector, nothing));
        cf.setEtfFactory(Factory(nothing));
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadEtfFactory.selector, address(qt)));
        cf.setEtfFactory(Factory(address(qt)));
        vm.expectEmit(address(cf));
        emit CurveFactory.EtfFactoryChanged(address(factory), address(next));
        cf.setEtfFactory(next);
        vm.stopPrank();
        assertEq(address(cf.etfFactory()), address(next));

        (Etf newEtf, Curve newCurve) = _launchEtf(0);
        assertTrue(next.isEtf(address(newEtf)));
        assertFalse(factory.isEtf(address(newEtf)));
        assertEq(address(newEtf.FACTORY()), address(next));
        assertGt(_buyUsdg(newCurve, alice, 100e6), 0);

        assertEq(address(oldEtf.FACTORY()), address(factory), "the old curve's ETF keeps its factory");
        uint256 out = _buyUsdg(oldCurve, bob, 100e6);
        _sell(oldCurve, bob, out / 2);
        _buyUsdg(oldCurve, bob, 11_000e6);
        assertTrue(oldCurve.bonded());
        assertEq(oldCurve.HOOK(), address(cf.HOOK()));
    }

    /// A factory with the three legs listed, on this USDG and PoolManager.
    function _nextFactory() internal returns (Factory next) {
        next = new Factory(IERC20(address(usdg)), IUniversalRouter(address(router)), address(v3), owner);
        vm.startPrank(owner);
        next.addToken(address(a), address(pa));
        next.addToken(address(b), address(pb));
        next.addToken(address(c), address(pc));
        vm.stopPrank();
    }

    /// After `setEtfFactory`, an ETF of the factory used before is still refused as a quote unless
    /// `force`; forced, it is a plain quote.
    function test_AnEtfOfAPastFactoryIsStillRefusedWithoutForce() public {
        Etf oldEtf = _etf(_backing());
        PoolMock p = _pool(address(oldEtf), _tickAt(1e18));
        usdg.mint(address(p), 1000e6);
        Factory next = _nextFactory();
        vm.startPrank(owner);
        cf.setEtfFactory(next);
        assertFalse(next.isEtf(address(oldEtf)));
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.EtfQuoteNeedsForce.selector, address(oldEtf)));
        cf.setTokenQuote(address(oldEtf), true, false, oneThreshold(8000e18), 1);
        cf.setTokenQuote(address(oldEtf), true, true, oneThreshold(8000e18), 1);
        vm.stopPrank();
        assertEq(cf.quotePool(address(oldEtf)), address(p));
        Curve curve = _launch(address(oldEtf), 0);
        assertFalse(curve.etfQuote());
    }

    /// `etfFactories` lists each factory once, in the order first used, however often it is set again.
    function test_AFactorySetTwiceIsListedOnce() public {
        Factory next = _nextFactory();
        vm.startPrank(owner);
        cf.setEtfFactory(next);
        cf.setEtfFactory(next);
        cf.setEtfFactory(factory);
        cf.setEtfFactory(next);
        vm.stopPrank();
        address[] memory list = cf.etfFactories();
        assertEq(list.length, 2);
        assertEq(list[0], address(factory));
        assertEq(list[1], address(next));
        assertEq(address(cf.etfFactory()), address(next));
    }

    function test_ALaunchCostsExactlyTheLaunchFee() public {
        assertEq(cf.launchFee(), 0.0005 ether);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.WrongLaunchFee.selector, LAUNCH_FEE, 0));
        cf.launchWithToken("Robin Coin", "ROBIN", "", _noProfileC(), address(qt), SIM_THRESHOLD, 0, 1_000_000_000, QT_FIRST_BUY, new address[](0));
        _launch(address(qt), 0);
        assertEq(address(cf).balance, LAUNCH_FEE);
        vm.prank(owner);
        cf.setLaunchFee(0.001 ether);
        assertEq(cf.launchFee(), 0.001 ether);
        vm.prank(owner);
        cf.withdrawFees(payable(carol));
        assertEq(carol.balance, LAUNCH_FEE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cf.setLaunchFee(0);
    }

    /// The launch event carries the terms, the names, the logo and the profile; the creator tax is at
    /// most 10 %.
    function test_ALaunchIsListedFromItsEventAndItsTaxIsBounded() public {
        CurveFactory.Profile memory p = CurveFactory.Profile({ description: "A coin.", x: "https://x.com/robin", telegram: "https://t.me/robins", website: "https://example.com", discord: "https://discord.gg/robins" });
        vm.recordLogs();
        vm.prank(maker);
        Curve curve = cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", _png(32, 32, 64), p, address(usdg), 8000e6, 1000, 1_000_000_000, USDG_FIRST_BUY, new address[](0));
        assertEq(vm.getRecordedLogs().length > 0, true);
        assertEq(cf.curveCount(), 1);
        assertEq(cf.curves(0), address(curve));
        assertTrue(cf.isCurve(address(curve)));
        assertEq(_tok(curve).name(), "Robin Coin");
        assertEq(_tok(curve).symbol(), "ROBIN");
        assertEq(_tok(curve).decimals(), 18);
        assertEq(_tok(curve).totalSupply(), 1e27);
        assertEq(_tok(curve).balanceOf(address(curve)) + _tok(curve).balanceOf(maker), 1e27, "the curve, less the first buy");
        assertGt(_tok(curve).balanceOf(maker), 0);
        assertEq(curve.creatorTaxBps(), 1000);
        assertEq(curve.threshold(), 8000e6);
        assertEq(curve.phantomQuote(), 3200e6);
        assertEq(keccak256(curve.logo()), keccak256(_png(32, 32, 64)));
        (CurveFactory.Profile memory cp, uint256 updatedAt) = cf.profileOf(address(curve));
        assertEq(abi.encode(cp), abi.encode(p));
        assertEq(updatedAt, block.timestamp);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadCreatorTax.selector, 1001));
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(usdg), 8000e6, 1001, 1_000_000_000, USDG_FIRST_BUY, new address[](0));
    }

    /// `setTokenQuote` finds the pool itself: of a token's pools against USDG, the one holding the most
    /// USDG (here the 1 % tier, not the 0.05 % holding less). The threshold is the owner's, in the
    /// token's units; each curve keeps the one it launched with, listing again changes new launches only.
    /// USDG needs no pool.
    function test_AListedTokenHasItsDeepestPoolAndTheOwnersThreshold() public {
        TokenMock d = new TokenMock("DDD", "DDD", 18);
        PoolMock thin = _poolAt(address(d), _tickAt(2e18), 500);
        PoolMock deep = _poolAt(address(d), _tickAt(2.5e18), 10_000);
        usdg.mint(address(thin), 1000e6);
        usdg.mint(address(deep), 5000e6);
        vm.expectEmit(address(cf));
        emit CurveFactory.QuoteSet(address(d), address(deep), oneThreshold(4e18), 1);
        vm.prank(owner);
        cf.setTokenQuote(address(d), true, false, oneThreshold(4e18), 1);
        assertEq(cf.quotePool(address(d)), address(deep));
        assertEq(cf.quoteThresholds(address(d))[0], 4e18);
        Curve curve = _launch(address(d), 0);
        assertEq(curve.threshold(), 4e18);
        assertFalse(curve.etfQuote());
        vm.prank(owner);
        cf.setTokenQuote(address(d), true, false, oneThreshold(9e18), 1);
        assertEq(cf.quoteThresholds(address(d))[0], 9e18);
        assertEq(curve.threshold(), 4e18, "a launched curve keeps its own");
        assertEq(_launch(address(d), 0).threshold(), 9e18);

        assertEq(cf.quoteThresholds(address(usdg))[0], 8000e6);
        assertEq(cf.quotePool(address(usdg)), address(0));
        assertEq(cf.quoteCount(), 4);
    }

    /// A token is refused without a pool against USDG (or with pools holding no USDG), with a pool whose
    /// oracle keeps under 1 801 observations, or one with no price at all (no TWAP and no spot); a pool
    /// with a spot but no TWAP yet passes, as at `addToken`. A threshold outside 1e9 - 1e33 is refused,
    /// for USDG too; the owner only.
    function test_ATokenWithoutAValidPoolOrThresholdIsRefused() public {
        TokenMock d = new TokenMock("DDD", "DDD", 18);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.NoPool.selector, address(d)));
        cf.setTokenQuote(address(d), true, false, oneThreshold(1e18), 1);
        PoolMock p = _poolAt(address(d), _tickAt(2e18), 3000);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.NoPool.selector, address(d)));
        cf.setTokenQuote(address(d), true, false, oneThreshold(1e18), 1);
        usdg.mint(address(p), 1000e6);
        p.setCardinality(1, 1800);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.ThinOracle.selector, address(p), 1800, 1801));
        cf.setTokenQuote(address(d), true, false, oneThreshold(1e18), 1);
        p.setCardinality(1, 1801);
        p.setNoHistory(true);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadPool.selector, address(p)));
        cf.setTokenQuote(address(d), true, false, oneThreshold(1e18), 1);
        p.setSpotSqrtPrice(_spot100(address(d)));
        cf.setTokenQuote(address(d), true, false, oneThreshold(1e18), 1);
        assertEq(cf.quotePool(address(d)), address(p));

        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadThreshold.selector, 1e9 - 1));
        cf.setTokenQuote(address(d), true, false, oneThreshold(1e9 - 1), 1);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadThreshold.selector, 1e33 + 1));
        cf.setTokenQuote(address(d), true, false, oneThreshold(1e33 + 1), 1);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadThreshold.selector, 0));
        cf.setTokenQuote(address(usdg), true, false, oneThreshold(0), 1);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cf.setTokenQuote(address(d), true, false, oneThreshold(1e18), 1);
    }

    /// A factory ETF is refused as a quote unless `force`; forced, it is a plain quote: bought and sold
    /// in shares, never minted or redeemed by the curve.
    function test_AFactoryEtfIsAPlainQuoteOnlyWhenForced() public {
        Etf etf = _etf(_backing());
        PoolMock p = _pool(address(etf), _tickAt(1e18));
        usdg.mint(address(p), 1000e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.EtfQuoteNeedsForce.selector, address(etf)));
        cf.setTokenQuote(address(etf), true, false, oneThreshold(8000e18), 1);
        vm.prank(owner);
        cf.setTokenQuote(address(etf), true, true, oneThreshold(8000e18), 1);
        assertEq(cf.quotePool(address(etf)), address(p));
        Curve curve = _launch(address(etf), 0);
        assertFalse(curve.etfQuote());
        assertEq(curve.threshold(), 8000e18);
        vm.prank(alice);
        vm.expectRevert(Curve.NotEtfQuote.selector);
        curve.buyWithUsdg(100e6, _noRoutes(), 1, 1, new Etf.Route[](0), 0);
        vm.startPrank(maker);
        etf.approve(address(curve), type(uint256).max);
        uint256 out = curve.buy(100e18, 0);
        _tok(curve).approve(address(curve), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Curve.BadPayout.selector, 1));
        curve.sell(out, 0, 1, _noRoutes(), 0, 0);
        uint256 back = curve.sell(out, 0, 0, _noRoutes(), 0, 0);
        vm.stopPrank();
        assertGt(back, 0);
        assertEq(etf.mintOf(address(curve)), 0);
    }

    /// The ETF thresholds are the owner's list: 8 000 shares alone at deploy; `setEtfThresholds` replaces
    /// the whole list (`EtfThresholdsSet`), a launch picks one by value and its curve keeps it whatever the
    /// list becomes; a value not in the list is `ThresholdNotOffered(0, value)`, one dropped from the list
    /// too (a launch signed before the change is refused, never bonded elsewhere).
    function test_TheEtfThresholdIsPickedFromTheOwnersListAndKept() public {
        uint256[] memory initial = cf.etfThresholds();
        assertEq(initial.length, 1);
        assertEq(initial[0], 8000e18);
        (, Curve first) = _launchEtf(0);
        uint256[] memory five = _fiveEtfThresholds();
        vm.expectEmit(address(cf));
        emit CurveFactory.EtfThresholdsSet(five);
        vm.prank(owner);
        cf.setEtfThresholds(five);
        assertEq(keccak256(abi.encode(cf.etfThresholds())), keccak256(abi.encode(five)));
        assertEq(first.threshold(), 8000e18);
        for (uint256 i = 0; i < five.length; i++) {
            etfPick = five[i];
            (, Curve c) = _launchEtf(0);
            assertEq(c.threshold(), five[i]);
            assertEq(c.phantomQuote(), five[i] * 2 / 5);
        }
        etfPick = 3000e18;
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.ThresholdNotOffered.selector, address(0), 3000e18));
        _launchWithEtf("Robin Coin", "ROBIN", "", _noProfileC(), 0);
        vm.prank(owner);
        cf.setEtfThresholds(oneThreshold(2000e18));
        etfPick = 5000e18;
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.ThresholdNotOffered.selector, address(0), 5000e18));
        _launchWithEtf("Robin Coin", "ROBIN", "", _noProfileC(), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cf.setEtfThresholds(five);
    }

    /// Every list is checked whole and refused whole, the list in place untouched: 1 to
    /// `MAX_THRESHOLD_CHOICES` entries (`BadThresholdCount`), strictly increasing
    /// (`ThresholdsNotIncreasing(i)`, a repeat included), each within its bounds (`BadThreshold`): the ETF
    /// list from `MIN_ETF_THRESHOLD` (100 shares, where a bond to USDG fits down to 0.111 USDG a share),
    /// a quote's from `MIN_THRESHOLD`, both to `MAX_THRESHOLD`; a quote's least first buy at most its
    /// smallest threshold (`BadMinFirstBuy`).
    function test_EveryThresholdListIsCheckedWholeAndRefusedWhole() public {
        assertEq(cf.MAX_THRESHOLD_CHOICES(), 8);
        assertEq(cf.MIN_ETF_THRESHOLD(), 100e18);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadThresholdCount.selector, 0));
        cf.setEtfThresholds(new uint256[](0));
        uint256[] memory nine = new uint256[](9);
        for (uint256 i = 0; i < 9; i++) {
            nine[i] = (i + 1) * 1000e18;
        }
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadThresholdCount.selector, 9));
        cf.setEtfThresholds(nine);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadThresholdCount.selector, 9));
        cf.setTokenQuote(address(usdg), true, false, nine, 1);
        uint256[] memory eight = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) {
            eight[i] = nine[i];
        }
        cf.setEtfThresholds(eight);
        assertEq(cf.etfThresholds().length, 8);
        uint256[] memory l = _fiveEtfThresholds();
        l[2] = l[1];
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.ThresholdsNotIncreasing.selector, 2));
        cf.setEtfThresholds(l);
        l = _fiveEtfThresholds();
        (l[3], l[4]) = (l[4], l[3]);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.ThresholdsNotIncreasing.selector, 4));
        cf.setEtfThresholds(l);
        l = _fiveEtfThresholds();
        l[0] = 100e18 - 1;
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadThreshold.selector, 100e18 - 1));
        cf.setEtfThresholds(l);
        l[0] = 100e18;
        cf.setEtfThresholds(l);
        l[4] = 1e33 + 1;
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadThreshold.selector, 1e33 + 1));
        cf.setEtfThresholds(l);
        assertEq(cf.etfThresholds()[0], 100e18, "a refused list leaves the one in place");
        assertEq(cf.etfThresholds()[4], 15_000e18);

        uint256[] memory q = _fiveUsdgThresholds();
        q[0] = 1e9 - 1;
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadThreshold.selector, 1e9 - 1));
        cf.setTokenQuote(address(usdg), true, false, q, 1);
        q = _fiveUsdgThresholds();
        q[1] = q[0];
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.ThresholdsNotIncreasing.selector, 1));
        cf.setTokenQuote(address(usdg), true, false, q, 1);
        q = _fiveUsdgThresholds();
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadMinFirstBuy.selector, 1000e6 + 1));
        cf.setTokenQuote(address(usdg), true, false, q, 1000e6 + 1);
        cf.setTokenQuote(address(usdg), true, false, q, 1000e6);
        vm.stopPrank();
        assertEq(keccak256(abi.encode(cf.quoteThresholds(address(usdg)))), keccak256(abi.encode(q)));
    }

    /// `launchWithToken` picks its threshold from its quote's list by value, `CurveLaunched` carries it in
    /// its terms, the curve keeps it: each of the five USDG targets bonds a curve at exactly that real
    /// quote; a value off the list, or dropped from it after the launch was signed, is refused.
    function test_ALaunchPicksItsQuoteThresholdFromTheListAndTheCurveKeepsIt() public {
        uint256[] memory q = _fiveUsdgThresholds();
        vm.expectEmit(address(cf));
        emit CurveFactory.QuoteSet(address(usdg), address(0), q, USDG_FIRST_BUY);
        vm.prank(owner);
        cf.setTokenQuote(address(usdg), true, false, q, USDG_FIRST_BUY);
        for (uint256 i = 0; i < q.length; i++) {
            vm.recordLogs();
            vm.prank(maker);
            Curve curve = cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(usdg), q[i], 0, 1_000_000_000, USDG_FIRST_BUY, new address[](0));
            assertEq(curve.threshold(), q[i]);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool seen;
            for (uint256 k = 0; k < logs.length; k++) {
                if (logs[k].emitter != address(cf) || logs[k].topics[0] != CurveFactory.CurveLaunched.selector) continue;
                (, uint256 index, CurveFactory.Terms memory terms) = abi.decode(logs[k].data, (address, uint256, CurveFactory.Terms));
                assertEq(index, cf.curveCount() - 1);
                assertEq(terms.threshold, q[i], "CurveLaunched carries the pick");
                seen = true;
            }
            assertTrue(seen);
            _approveAll(curve, address(usdg));
            vm.warp(vm.getBlockTimestamp() + 3);
            vm.prank(holders[0]);
            curve.buy(q[i] * 2, 0);
            assertTrue(curve.bonded(), "the last buy bonds at the pick");
            assertGe(curve.realQuote(), q[i]);
            assertGe(curve.bondSetAside(), q[i] * 3000 / 10_000, "30 % of a real quote past the pick");
        }
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.ThresholdNotOffered.selector, address(usdg), 4000e6));
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(usdg), 4000e6, 0, 1_000_000_000, USDG_FIRST_BUY, new address[](0));
        vm.prank(owner);
        cf.setTokenQuote(address(usdg), true, false, oneThreshold(2000e6), USDG_FIRST_BUY);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.ThresholdNotOffered.selector, address(usdg), 8000e6));
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(usdg), 8000e6, 0, 1_000_000_000, USDG_FIRST_BUY, new address[](0));
    }

    function _fiveEtfThresholds() internal pure returns (uint256[] memory t) {
        t = new uint256[](5);
        (t[0], t[1], t[2], t[3], t[4]) = (1000e18, 2000e18, 5000e18, 8000e18, 15_000e18);
    }

    function _fiveUsdgThresholds() internal pure returns (uint256[] memory t) {
        t = new uint256[](5);
        (t[0], t[1], t[2], t[3], t[4]) = (1000e6, 2000e6, 5000e6, 8000e6, 15_000e6);
    }

    /// Delisting: new launches on the token refused, launched curves keep their terms; an unlisted token
    /// is refused at launch and at delisting.
    function test_ADelistedQuoteKeepsItsCurves() public {
        TokenMock d = new TokenMock("DDD", "DDD", 18);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadQuote.selector, address(d)));
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(d), 1e18, 0, 1_000_000_000, 1e18, new address[](0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadQuote.selector, address(d)));
        cf.setTokenQuote(address(d), false, false, oneThreshold(0), 1);
        Curve onQt = _launch(address(qt), 0);
        vm.prank(owner);
        cf.setTokenQuote(address(qt), false, false, oneThreshold(0), 1);
        assertEq(cf.quoteThresholds(address(qt)).length, 0);
        assertEq(onQt.threshold(), SIM_THRESHOLD);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadQuote.selector, address(qt)));
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(qt), SIM_THRESHOLD, 0, 1_000_000_000, QT_FIRST_BUY, new address[](0));
        vm.prank(holders[0]);
        onQt.buy(100e18, 0);
        assertEq(cf.quoteCount(), 3);
    }

    /// Names, symbols, logos and every profile field are checked by the same code as the ETF factory's:
    /// each of these inputs is accepted or refused, with the same error, by both.
    function test_TheProfileAllowlistsAreTheEtfFactorysOwn() public {
        Etf etf = _etf(_backing());
        Curve curve = _launch(address(qt), 0);
        string[16] memory inputs = [
            "",
            "A coin.",
            "line\nbreak",
            unicode"café",
            "https://x.com/abc",
            "https://x.com/",
            "https://x.com/abc/",
            "https://t.me/abcde",
            "https://t.me/abcd",
            "https://example.com/a?b=c#d",
            "https://",
            "https:///path",
            "javascript:alert(1)",
            "https://exa mple.com",
            "https://x.com/A_b9",
            "https://t.me/abc.de"
        ];
        for (uint256 i = 0; i < inputs.length; i++) {
            for (uint256 field = 0; field < 4; field++) {
                string[4] memory f;
                f[field] = inputs[i];
                vm.prank(maker);
                (bool okEtf, bytes memory errEtf) = address(factory).call(abi.encodeCall(Factory.setProfile, (address(etf), f[0], f[1], f[2], f[3])));
                vm.prank(maker);
                (bool okCurve, bytes memory errCurve) =
                    address(cf).call(abi.encodeCall(CurveFactory.setProfile, (address(curve), CurveFactory.Profile({ description: f[0], x: f[1], telegram: f[2], website: f[3], discord: "" }))));
                assertEq(okCurve, okEtf, inputs[i]);
                assertEq(errCurve, errEtf, inputs[i]);
            }
        }
        string[6] memory names = ["Robin Coin", " Robin", "Robin  Coin", "Rob!n", "R", ""];
        for (uint256 i = 0; i < names.length; i++) {
            vm.prank(maker);
            (bool ok, bytes memory err) = address(cf).call{ value: LAUNCH_FEE }(
                abi.encodeCall(CurveFactory.launchWithToken, (names[i], "ROBIN", "", _noProfileC(), address(qt), SIM_THRESHOLD, 0, 1_000_000_000, QT_FIRST_BUY, new address[](0)))
            );
            if (i == 0 || i == 4) assertTrue(ok);
            else assertEq(err, abi.encodeWithSelector(BadName.selector));
        }
        vm.prank(maker);
        vm.expectRevert(BadSymbol.selector);
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN-1", "", _noProfileC(), address(qt), SIM_THRESHOLD, 0, 1_000_000_000, QT_FIRST_BUY, new address[](0));
        vm.prank(maker);
        vm.expectRevert(BadLogo.selector);
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", _png(257, 64, 100), _noProfileC(), address(qt), SIM_THRESHOLD, 0, 1_000_000_000, QT_FIRST_BUY, new address[](0));
        bytes memory big = _png(64, 64, 10_241);
        vm.prank(maker);
        vm.expectRevert(BadLogo.selector);
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", big, _noProfileC(), address(qt), SIM_THRESHOLD, 0, 1_000_000_000, QT_FIRST_BUY, new address[](0));
    }

    /// `setProfile`: the curve's creator only, a factory curve only, the whole profile with Discord.
    function test_OnlyTheCreatorSetsTheProfile() public {
        Curve curve = _launch(address(qt), 0);
        CurveFactory.Profile memory mine = CurveFactory.Profile({ description: "Mine.", x: "", telegram: "", website: "", discord: "https://discord.gg/mine" });
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.NotCreator.selector, address(curve), alice));
        cf.setProfile(address(curve), mine);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.NotCurve.selector, address(qt)));
        cf.setProfile(address(qt), mine);
        vm.expectEmit(address(cf));
        emit CurveFactory.ProfileSet(address(curve), maker, mine);
        vm.prank(maker);
        cf.setProfile(address(curve), mine);
        (CurveFactory.Profile memory p,) = cf.profileOf(address(curve));
        assertEq(abi.encode(p), abi.encode(mine));
    }

    /// `discord` is empty, or `https://discord.gg/` or `https://discord.com/invite/` and 2 - 32 of
    /// `[A-Za-z0-9-]`, nothing after, at launch and in `setProfile`; anything else `BadDiscord`.
    function test_TheDiscordFieldIsAnInviteLinkOrEmpty() public {
        Curve curve = _launch(address(qt), 0);
        string[7] memory good = [
            "",
            "https://discord.gg/ab",
            "https://discord.gg/Robin-Coin9",
            "https://discord.com/invite/abcDEF123",
            "https://discord.gg/abcdefghijklmnopqrstuvwxyz012345",
            "https://discord.com/invite/abcdefghijklmnopqrstuvwxyz012345",
            "https://discord.gg/--"
        ];
        string[10] memory bad = [
            "https://discord.gg/",
            "https://discord.gg/a",
            "https://discord.gg/abcdefghijklmnopqrstuvwxyz0123456",
            "https://discord.gg/ab/",
            "https://discord.gg/a_b",
            "http://discord.gg/abc",
            "https://discord.com/abc",
            "https://discord.com/invite/",
            "https://discordapp.com/invite/abc",
            "javascript:alert(1)"
        ];
        for (uint256 i = 0; i < good.length; i++) {
            vm.prank(maker);
            cf.setProfile(address(curve), CurveFactory.Profile({ description: "", x: "", telegram: "", website: "", discord: good[i] }));
            (CurveFactory.Profile memory p,) = cf.profileOf(address(curve));
            assertEq(p.discord, good[i]);
        }
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(maker);
            vm.expectRevert(CurveFactory.BadDiscord.selector);
            cf.setProfile(address(curve), CurveFactory.Profile({ description: "", x: "", telegram: "", website: "", discord: bad[i] }));
        }
        vm.prank(maker);
        vm.expectRevert(CurveFactory.BadDiscord.selector);
        cf.launchWithToken{ value: LAUNCH_FEE }(
            "Robin Coin", "ROBIN", "", CurveFactory.Profile({ description: "", x: "", telegram: "", website: "", discord: bad[0] }), address(qt), SIM_THRESHOLD, 0, 1_000_000_000, QT_FIRST_BUY, new address[](0)
        );
    }

    /// `setLogo`: the curve's creator only, a launched curve only, any time; the launch's PNG checks and
    /// 10 KiB cap (an empty PNG refused); stored, then replaced, each with its `LogoSet`; the curve's and
    /// the token's state untouched by it.
    function test_OnlyTheCreatorSetsTheLogoAndReplacesIt() public {
        Curve curve = _launch(address(qt), 0);
        Token tok = _tok(curve);
        bytes memory first = _png(64, 64, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.NotCreator.selector, address(curve), alice));
        cf.setLogo(address(curve), first);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.NotCurve.selector, address(qt)));
        cf.setLogo(address(qt), first);
        bytes[4] memory refused = [bytes(""), _png(257, 64, 100), _png(64, 0, 100), _png(64, 64, 10_241)];
        for (uint256 i = 0; i < refused.length; i++) {
            vm.prank(maker);
            vm.expectRevert(BadLogo.selector);
            cf.setLogo(address(curve), refused[i]);
        }
        bytes memory notPng = _png(64, 64, 100);
        notPng[0] = 0x00;
        vm.prank(maker);
        vm.expectRevert(BadLogo.selector);
        cf.setLogo(address(curve), notPng);

        bytes32 before = _curveAndTokenState(curve, tok);
        vm.expectEmit(address(cf));
        emit CurveFactory.LogoSet(address(curve), maker, first);
        vm.prank(maker);
        cf.setLogo(address(curve), first);
        assertEq(keccak256(curve.logo()), keccak256(first));
        bytes memory second = _png(256, 256, 10_240);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectEmit(address(cf));
        emit CurveFactory.LogoSet(address(curve), maker, second);
        vm.prank(maker);
        cf.setLogo(address(curve), second);
        assertEq(keccak256(cf.logo(address(curve))), keccak256(second), "replaced");
        assertEq(_curveAndTokenState(curve, tok), before, "the curve and the token unchanged");
    }

    /// Everything a logo could touch on the curve and its token, hashed.
    function _curveAndTokenState(Curve curve, Token tok) internal view returns (bytes32) {
        bytes32 c = keccak256(abi.encode(curve.quoteReserve(), curve.tokenReserve(), curve.creatorFees(), curve.protocolFees(), curve.bonded(), address(curve).codehash));
        return keccak256(abi.encode(c, tok.totalSupply(), tok.balanceOf(address(curve)), tok.balanceOf(maker), tok.name(), tok.symbol(), address(tok).codehash));
    }

    /// The implementation is locked; a clone is the minimal proxy and its terms, initialized once, by
    /// the factory only; the callback answers the PoolManager only; ownership is never renounced.
    function test_CloneGuards() public {
        Curve impl = cf.CURVE_IMPLEMENTATION();
        vm.expectRevert(Curve.NotFactory.selector);
        impl.initialize(new address[](0), "A", "A");
        vm.prank(address(cf));
        vm.expectRevert(Curve.AlreadyInitialized.selector);
        impl.initialize(new address[](0), "A", "A");
        vm.expectRevert(Curve.NotAClone.selector);
        impl.buy(1, 0);
        Curve curve = _launch(address(qt), 25);
        vm.prank(address(cf));
        vm.expectRevert(Curve.AlreadyInitialized.selector);
        curve.initialize(new address[](0), "A", "A");
        // 1e27, under 2^96.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(Clones.fetchCloneArgs(address(curve)), curveCloneArgs(address(qt), false, 0, 25, SIM_THRESHOLD, maker, uint96(CURVE_SUPPLY)));
        // The token: a contract of its own, the curve's first creation, its whole supply to the curve at
        // its creation; a holder burns his own, and only his.
        Token token = _tok(curve);
        assertEq(cf.curveInfo(address(curve)).token, address(token));
        assertEq(address(token), vm.computeCreateAddress(address(curve), 1), "the curve's first creation");
        assertGt(address(token).code.length, 1000, "a whole contract, not a clone");
        assertEq(token.name(), "Robin Coin");
        assertEq(token.symbol(), "ROBIN");
        assertEq(token.totalSupply(), CURVE_SUPPLY);
        vm.prank(holders[0]);
        uint256 got = curve.buy(10e18, 0);
        vm.prank(holders[0]);
        token.burn(got / 2);
        assertEq(token.balanceOf(holders[0]), got - got / 2);
        assertEq(token.totalSupply(), 1e27 - got / 2);
        vm.prank(holders[1]);
        vm.expectRevert();
        token.burn(1);
        vm.expectRevert(Curve.NotPoolManager.selector);
        curve.unlockCallback(abi.encode(uint8(1)));
        vm.prank(owner);
        vm.expectRevert(CurveFactory.RenounceForbidden.selector);
        cf.renounceOwnership();
    }

    /// Claims on a plain quote: the creator his, the owner the protocol's, nobody else, never more than due.
    function test_ClaimsArePaidToTheirReceiversOnly() public {
        Curve curve = _launch(address(usdg), 200);
        vm.prank(alice);
        curve.buy(1000e6, 0);
        uint256 cfees = curve.creatorFees();
        vm.prank(alice);
        vm.expectRevert(Curve.NotCreator.selector);
        curve.claim(false, cfees, alice, 0, _noRoutes(), 0, 0);
        vm.prank(maker);
        vm.expectRevert(Curve.NotOwner.selector);
        curve.claim(true, 1, maker, 0, _noRoutes(), 0, 0);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Curve.TooMuch.selector, cfees + 1, cfees));
        curve.claim(false, cfees + 1, maker, 0, _noRoutes(), 0, 0);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Curve.BadPayout.selector, 1));
        curve.claim(false, cfees, maker, 1, _noRoutes(), 0, 0);
        uint256 before = usdg.balanceOf(carol);
        vm.prank(maker);
        curve.claim(false, cfees, carol, 0, _noRoutes(), 0, 0);
        assertEq(usdg.balanceOf(carol) - before, cfees);
        uint256 pfees = curve.protocolFees();
        vm.prank(owner);
        curve.claim(true, pfees, owner, 0, _noRoutes(), 0, 0);
        assertEq(curve.protocolFees(), 0);
    }
}

/// The supply, one of five, chosen at launch.
contract MaidMarianLaunchCurveSupplyTest is CurveBase {
    /**
     * `curveBuy` at each supply a launch may choose (1 M, 10 M, 100 M, 500 M, 1 B tokens) replays the
     * simulation's run A at that supply (`script/curve-vectors.json`,
     * one run per supply): every `tokensOut` of the 408 buys of 20 shares, the end reserves, both fee totals;
     * the last buy, bought whole, ends past 2/7 of the supply with the same real quote at every supply.
     */
    function test_EverySupplyReplaysItsSimulationVectorToTheWei() public view {
        string memory j = _vectors();
        uint256 threshold = _u(j, ".threshold");
        uint256 phantom = _u(j, ".phantom");
        uint256[5] memory wholes = [uint256(1_000_000), 10_000_000, 100_000_000, 500_000_000, 1_000_000_000];
        for (uint256 k = 0; k < 5; k++) {
            string memory key = string.concat(".supplies[", vm.toString(k), "]");
            uint256 supply = _u(j, string.concat(key, ".supply"));
            assertEq(supply, wholes[k] * 1e18);
            assertTrue(cf.isSupply(wholes[k]));
            uint256 reserved = curveReserved(supply);
            assertEq(reserved, _u(j, string.concat(key, ".reserved")));
            string[] memory outs = vm.parseJsonStringArray(j, string.concat(key, ".tokensOut"));
            assertEq(outs.length, 408);
            (uint256 q, uint256 t, uint256 creatorFees, uint256 protocolFees) = (phantom, supply, 0, 0);
            for (uint256 i = 0; i < outs.length; i++) {
                (uint256 out, uint256 fee, uint256 tax, uint256 net) = curveBuy(q, t, 20e18, 100, 50);
                assertEq(out, vm.parseUint(outs[i]), "tokensOut");
                (q, t) = (q + net, t - out);
                protocolFees += fee * 3000 / 10_000;
                creatorFees += fee - fee * 3000 / 10_000 + tax;
            }
            assertEq(q, _u(j, string.concat(key, ".q")));
            assertEq(t, _u(j, string.concat(key, ".t")));
            assertLt(t, reserved, "past the end");
            assertEq(q - phantom - threshold, _u(j, string.concat(key, ".realMinusThreshold")));
            assertEq(creatorFees, _u(j, string.concat(key, ".creator")));
            assertEq(protocolFees, _u(j, string.concat(key, ".protocol")));
        }
    }

    /// A launch at each supply: the token mints exactly it to the curve, the curve sells 5/7 of it and
    /// more on its last buy, bought whole, and bonds, the pool opening at the curve's price; the launch event's terms
    /// carry it. Any other supply is refused, on both doors.
    function test_ALaunchTakesOneOfFiveSupplies() public {
        uint256[5] memory wholes = [uint256(1_000_000), 10_000_000, 100_000_000, 500_000_000, 1_000_000_000];
        for (uint256 k = 0; k < 5; k++) {
            vm.recordLogs();
            vm.prank(maker);
            Curve curve = cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(qt), SIM_THRESHOLD, 0, wholes[k], QT_FIRST_BUY, new address[](0));
            CurveFactory.Terms memory terms = _launchedTerms();
            assertEq(terms.supply, wholes[k] * 1e18, "the event carries the supply");
            _approveAll(curve, address(qt));
            vm.warp(vm.getBlockTimestamp() + 3);
            Token token = _tok(curve);
            assertEq(token.totalSupply(), wholes[k] * 1e18);
            uint256 first = token.balanceOf(maker);
            assertGt(first, 0, "the first buy");
            assertEq(token.balanceOf(address(curve)) + first, wholes[k] * 1e18);
            assertEq(curve.supply(), wholes[k] * 1e18);
            assertEq(curve.reserved(), (2 * wholes[k] * 1e18) / 7);
            vm.prank(holders[0]);
            uint256 sold = curve.buy(3000e18, 0);
            vm.prank(holders[1]);
            sold += curve.buy(9000e18, 0);
            assertTrue(curve.bonded());
            (uint256 q, uint256 t) = curve.getReserves();
            assertLt(t, curve.reserved(), "the last buy bought whole, past the end");
            assertEq(sold + first, wholes[k] * 1e18 - t);
            assertEq(_poolPrice(curve), _sqrtAt(curve, q, t));
            assertEq(qt.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees());
        }
        uint256[4] memory bad = [uint256(0), 2_000_000, 1e27, 999_999_999];
        for (uint256 k = 0; k < 4; k++) {
            assertFalse(cf.isSupply(bad[k]));
            vm.prank(maker);
            vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadSupply.selector, bad[k]));
            cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(qt), SIM_THRESHOLD, 0, bad[k], QT_FIRST_BUY, new address[](0));
            vm.prank(maker);
            vm.expectRevert(abi.encodeWithSelector(CurveFactory.BadSupply.selector, bad[k]));
            cf.launchWithEtf{ value: FEE }(
                "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 0, bad[k], SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), 0, new Etf.Route[](0), 0
            );
        }
        vm.prank(maker);
        (, Curve onEtf) = cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 0, 1_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), 0, new Etf.Route[](0), 0
        );
        assertEq(onEtf.supply(), 1e24);
        assertEq(_tok(onEtf).totalSupply(), 1e24);
    }

    /// The `Terms` of the last `CurveLaunched` recorded.
    function _launchedTerms() internal view returns (CurveFactory.Terms memory terms) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == CurveFactory.CurveLaunched.selector) {
                (,, terms,,,,) = abi.decode(logs[i - 1].data, (address, uint256, CurveFactory.Terms, string, string, bytes, CurveFactory.Profile));
                return terms;
            }
        }
        revert("no CurveLaunched");
    }
}

/// Gas per door, every touched account cooled before the call.
contract MaidMarianLaunchCurveGasTest is CurveBase {
    function _coolAll(Curve curve) internal {
        address[13] memory touched = [
            address(curve),
            address(curve) == address(0) ? address(0) : curve.token(),
            address(cf),
            address(factory),
            address(usdg),
            address(qt),
            address(a),
            address(b),
            address(c),
            address(router),
            address(pm),
            address(cf.CURVE_IMPLEMENTATION()),
            address(factory.ETF_IMPLEMENTATION())
        ];
        for (uint256 i = 0; i < touched.length; i++) {
            if (touched[i] != address(0)) vm.cool(touched[i]);
        }
    }

    function _gasLaunch(bytes memory logoPng) internal returns (uint256 used) {
        _coolAll(Curve(address(0)));
        vm.prank(maker);
        uint256 g = gasleft();
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", logoPng, _noProfileC(), address(qt), SIM_THRESHOLD, 100, 1_000_000_000, QT_FIRST_BUY, new address[](0));
        used = g - gasleft();
    }

    function test_gas_Doors() public {
        emit log_named_uint("launch, no logo", _gasLaunch(""));
        emit log_named_uint("launch, 8 KiB logo", _gasLaunch(_png(256, 256, 8192)));

        Curve plain = _launch(address(qt), 100);
        vm.prank(holders[0]);
        plain.buy(10e18, 0);
        _coolAll(plain);
        vm.prank(holders[0]);
        uint256 g = gasleft();
        uint256 out = plain.buy(100e18, 0);
        emit log_named_uint("buy, plain quote", g - gasleft());
        _coolAll(plain);
        vm.prank(holders[0]);
        g = gasleft();
        plain.sell(out / 2, 0, 0, _noRoutes(), 0, 0);
        emit log_named_uint("sell, plain quote", g - gasleft());
        _coolAll(plain);
        vm.prank(holders[1]);
        g = gasleft();
        plain.buy(9000e18, 0);
        emit log_named_uint("last buy + bond, plain quote", g - gasleft());

        (Etf etf, Curve onEtf) = _launchEtf(100);
        _buyUsdg(onEtf, alice, 100e6);
        Etf.Route[] memory r = _buyRoutes(etf, 500e6, false);
        _coolAll(onEtf);
        vm.cool(address(etf));
        vm.prank(alice);
        g = gasleft();
        out = onEtf.buyWithUsdg(500e6, r, 1, 1, new Etf.Route[](0), 0);
        emit log_named_uint("buyWithUsdg, 3 legs", g - gasleft());
        (uint256 quoteOut,,) = onEtf.previewSell(out / 3);
        _coolAll(onEtf);
        vm.cool(address(etf));
        vm.prank(alice);
        g = gasleft();
        onEtf.sell(out / 3, 0, 1, _noRoutes(), 0, 0);
        emit log_named_uint("sell in kind, 3 legs", g - gasleft());
        (quoteOut,,) = onEtf.previewSell(out / 3);
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(address(onEtf), quoteOut);
        Etf.Route[] memory sr = _sellRoutes(etf, due);
        _coolAll(onEtf);
        vm.cool(address(etf));
        vm.prank(alice);
        g = gasleft();
        onEtf.sell(out / 3, 0, 2, sr, 1, 0);
        emit log_named_uint("sell to USDG, 3 legs", g - gasleft());
        r = _buyRoutes(etf, 11_000e6, false);
        _coolAll(onEtf);
        vm.cool(address(etf));
        vm.prank(bob);
        g = gasleft();
        onEtf.buyWithUsdg(11_000e6, r, 1, 1, new Etf.Route[](0), 0);
        emit log_named_uint("last buyWithUsdg + bond, 3 legs", g - gasleft());
        assertTrue(onEtf.bonded());

        CurveFactory.Profile memory full = CurveFactory.Profile({
            description: "Every byte of the 280 allowed: a description long enough to fill the whole field, so the profile costs what the largest one costs in storage, twice, once for the token and once for its ETF. Padding to the limit: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            x: "https://x.com/abcdefghijklmno",
            telegram: "https://t.me/abcdefghijklmnopqrstuvwxyz012345",
            website: "https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            discord: "https://discord.com/invite/abcdefghijklmnopqrstuvwxyz012345"
        });
        Factory.LegSpec[] memory legs0 = _legsAbc();
        _coolAll(Curve(address(0)));
        vm.prank(maker);
        g = gasleft();
        cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), legs0, 200, 0, 8000e18, 100, 1_000_000_000, SEED_USDG, _seedRoutes(legs0), 1, new address[](0), 0, new Etf.Route[](0), 0
        );
        emit log_named_uint("launchWithEtf, 3 legs, no logo, no profile", g - gasleft());
        bytes memory logo12 = _png(256, 256, 8192);
        Factory.LegSpec[] memory legs = _legsAbc();
        _coolAll(Curve(address(0)));
        vm.prank(maker);
        g = gasleft();
        cf.launchWithEtf{ value: FEE }("Robin Coin", "ROBIN", logo12, full, legs, 200, 0, 8000e18, 100, 1_000_000_000, SEED_USDG, _seedRoutes(legs), 1, new address[](0), 0, new Etf.Route[](0), 0);
        emit log_named_uint("launchWithEtf, 3 legs, 8 KiB logo, full profile", g - gasleft());
        bytes memory logo16 = _png(256, 256, 8192);
        _coolAll(Curve(address(0)));
        vm.prank(maker);
        g = gasleft();
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", logo16, full, address(qt), SIM_THRESHOLD, 100, 1_000_000_000, QT_FIRST_BUY, new address[](0));
        emit log_named_uint("launchWithToken, 8 KiB logo, full profile", g - gasleft());
        TokenMock d = new TokenMock("DDD", "DDD", 18);
        for (uint24 fee = 100; fee <= 10_000; fee = fee == 100 ? 500 : fee == 500 ? 3000 : fee == 3000 ? 10_000 : 20_000) {
            usdg.mint(address(_poolAt(address(d), _tickAt(2e18), fee)), 1000e6 + fee);
        }
        vm.prank(owner);
        g = gasleft();
        cf.setTokenQuote(address(d), true, false, oneThreshold(4e18), 1);
        emit log_named_uint("setTokenQuote, four pools", g - gasleft());
    }
}
