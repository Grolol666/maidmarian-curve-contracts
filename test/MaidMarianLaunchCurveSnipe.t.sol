// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Vm } from "forge-std/Vm.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianTokenLauncher as CurveFactory, IWrappedNative } from "../src/MaidMarianTokenLauncher.sol";
import { MaidMarianLaunchCurve as Curve, curveCloneArgs } from "../src/MaidMarianLaunchCurve.sol";
import { CurveBase, CURVE_SUPPLY } from "./MaidMarianLaunchCurve.t.sol";
import { mineLaunchHookSalt } from "../script/DeployTokenLauncher.s.sol";

/**
 * Offline over the curve suite's mocks and the real launcher, curve, token, ETF
 * factory and ETF code: the snipe tax of the first 3 s and its exemptions hold on every door. The curve
 * takes a buyer's address from its own launcher only (`buyFor`, `buyWithUsdgFor`), and the launcher
 * passes its caller; the creator names at launch up to `MAX_SNIPE_EXEMPTIONS` addresses exempted with
 * him, for good. A launcher buy and the same buy made directly are compared from one state.
 *
 *   forge test --match-contract MaidMarianLaunchCurveSnipe -vv
 */
contract MaidMarianLaunchCurveSnipeTest is CurveBase {

    function setUp() public virtual override {
        super.setUp();
        address[8] memory who = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker];
        qt.mint(maker, 1e30);
        qt.mint(alice, 1e30);
        qt.mint(bob, 1e30);
        for (uint256 i = 0; i < who.length; i++) {
            vm.startPrank(who[i]);
            qt.approve(address(cf), type(uint256).max);
            usdg.approve(address(cf), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ----------------------------------------------------------- helpers ---

    function _list(address x, address y) internal pure returns (address[] memory l) {
        l = new address[](2);
        (l[0], l[1]) = (x, y);
    }

    function _distinct(uint256 n) internal returns (address[] memory l) {
        l = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            l[i] = makeAddr(string.concat("exempt", vm.toString(i)));
        }
    }

    /// A curve on `qt` by `maker` with `exempt`, at its base price (`launchBare`: the snipe tax is measured
    /// from it), every holder approved to it, the snipe tax running.
    function _launchExempt(address[] memory exempt, uint16 tax) internal returns (Curve curve) {
        vm.prank(maker);
        curve = cf.launchBare{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(qt), tax, 1_000_000_000, exempt);
        _approveAll(curve, address(qt));
    }

    function _launchEtfExempt(address[] memory exempt) internal returns (Etf etf, Curve curve) {
        vm.prank(maker);
        (etf, curve) = cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 0, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, exempt, 0, new Etf.Route[](0), 0
        );
        _approveAll(curve, address(etf));
    }

    function _fees(Curve curve) internal view returns (uint256) {
        return curve.creatorFees() + curve.protocolFees();
    }

    /// Routes spending 99 % of `usdgIn` on the reserve ETF's three legs at 50 / 30 / 20.
    function _routes(uint256 usdgIn) internal view returns (Etf.Route[] memory r) {
        uint256 spend = usdgIn - usdgIn / 100;
        r = new Etf.Route[](3);
        r[0] = _swapRoute(0, false, spend * 50 / 100);
        r[1] = _swapRoute(1, false, spend * 30 / 100);
        r[2] = _swapRoute(2, false, spend - spend * 50 / 100 - spend * 30 / 100);
    }

    // -------------------------------------------------- the real buyer ---

    /// Nobody but the curve's own launcher names a buyer: whoever else calls `buyFor` or
    /// `buyWithUsdgFor` - a stranger, the creator, the owner, the token, the hook - is refused
    /// `NotFactory`, and nothing moves.
    function testFuzz_NobodyButItsLauncherCanNameABuyer(address caller) public {
        vm.assume(caller != address(cf));
        Curve curve = _launchExempt(new address[](0), 0);
        (, Curve onEtf) = _launchEtfExempt(new address[](0));
        address[5] memory who = [caller, maker, owner, curve.token(), address(cf.HOOK())];
        for (uint256 i = 0; i < who.length; i++) {
            vm.startPrank(who[i]);
            vm.expectRevert(Curve.NotFactory.selector);
            curve.buyFor(maker, 100e18, 0);
            vm.expectRevert(Curve.NotFactory.selector);
            onEtf.buyWithUsdgFor(maker, 100e6, _routes(100e6), 0, 0, new Etf.Route[](0), 0);
            vm.stopPrank();
        }
        (, uint256 t) = curve.getReserves();
        assertEq(t, CURVE_SUPPLY, "nothing sold");
    }

    /// Another launcher, as real as this one, is a stranger to this launcher's curves: it cannot name a buyer
    /// on them, and its own doors refuse them (`NotCurve`).
    function test_AnotherLauncherCannotNameABuyer() public {
        (bytes32 salt,) = mineLaunchHookSalt(vm.computeCreateAddress(address(this), vm.getNonce(address(this))), router.poolManager());
        CurveFactory other = new CurveFactory(factory, owner, IWrappedNative(address(weth)), salt);
        Curve curve = _launchExempt(new address[](0), 0);
        vm.prank(address(other));
        vm.expectRevert(Curve.NotFactory.selector);
        curve.buyFor(maker, 100e18, 0);
        vm.prank(holders[0]);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.NotCurve.selector, address(curve)));
        other.buy(address(curve), 100e18, 0);
    }

    /// A stranger's clone of the curve implementation, its terms naming the real creator and token: its
    /// factory is this launcher, so the stranger can neither initialize it nor name a buyer on it; the
    /// implementation itself is no curve (`NotAClone`).
    function test_ACloneOfTheImplementationCannotNameABuyer() public {
        _launchExempt(new address[](0), 0);
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        // 1e27, under 2^96.
        // forge-lint: disable-next-line(unsafe-typecast)
        Curve fake = Curve(Clones.cloneWithImmutableArgs(address(cf.CURVE_IMPLEMENTATION()), curveCloneArgs(address(qt), false, 0, 0, SIM_THRESHOLD, maker, uint96(CURVE_SUPPLY))));
        vm.expectRevert(Curve.NotFactory.selector);
        fake.initialize(new address[](0), "A", "A");
        vm.expectRevert(Curve.NotFactory.selector);
        fake.buyFor(maker, 100e18, 0);
        Curve impl = cf.CURVE_IMPLEMENTATION();
        vm.expectRevert(Curve.NotAClone.selector);
        impl.buyFor(maker, 100e18, 0);
        vm.stopPrank();
    }

    /// The creator through the launcher in each of the first 3 s pays no snipe tax: his buy is the same as
    /// his direct buy from the same state (tokens, fees), its fee the 0.75 % alone, and the curve's `Bought`
    /// names him.
    function test_TheCreatorThroughTheLauncherPaysNoSnipeTax() public {
        Curve curve = _launchExempt(new address[](0), 0);
        uint64 t0 = curve.launchedAt();
        for (uint256 s = 0; s < 3; s++) {
            vm.warp(t0 + s);
            uint256 snap = vm.snapshotState();
            (uint256 expected, uint256 fee,) = curve.previewBuy(1000e18, maker);
            assertEq(fee, 1000e18 * 75 / 10_000, "the fee alone");
            vm.prank(maker);
            uint256 direct = curve.buy(1000e18, 1);
            uint256 feesDirect = _fees(curve);
            vm.revertToState(snap);

            vm.expectEmit(true, false, false, false, address(curve));
            emit Curve.Bought(maker, 0, 0, 0, 0, 0, 0, 0);
            vm.prank(maker);
            uint256 via = cf.buy(address(curve), 1000e18, 1);
            assertEq(via, direct, "the same tokens");
            assertEq(via, expected);
            assertEq(_fees(curve), feesDirect, "the same fees");
            assertEq(_fees(curve), fee);
            vm.revertToState(snap);
        }
    }

    /// A stranger through the launcher pays the snipe tax exactly as directly, at every second and amount:
    /// the same tokens and fees from the same state, more than the fee alone inside the 3 s.
    function testFuzz_AStrangerThroughTheLauncherPaysTheSnipeTaxAsDirectly(uint256 elapsed, uint256 amount) public {
        elapsed = bound(elapsed, 0, 3);
        amount = bound(amount, 1e15, 5000e18);
        Curve curve = _launchExempt(new address[](0), 0);
        vm.warp(curve.launchedAt() + elapsed);
        (uint256 expected, uint256 fee,) = curve.previewBuy(amount, holders[0]);
        uint256 snap = vm.snapshotState();
        vm.prank(holders[0]);
        uint256 direct = curve.buy(amount, 1);
        uint256 feesDirect = _fees(curve);
        vm.revertToState(snap);
        vm.prank(holders[0]);
        uint256 via = cf.buy(address(curve), amount, 1);
        assertEq(via, direct);
        assertEq(via, expected);
        assertEq(_fees(curve), feesDirect);
        if (elapsed < 3) assertGt(fee, amount * 75 / 10_000, "the snipe tax is in the fee");
        else assertEq(fee, amount * 75 / 10_000);
    }

    // --------------------------------------------------- the exemptions ---

    /// Two addresses named at launch: at its first second one buys directly and the other through the
    /// launcher, each with the fee and the creator's 1 % tax and no snipe tax, as the creator would; a
    /// holder not named pays the snipe tax, which at that second with the tax takes the whole buy (fee,
    /// snipe and tax are capped at 100 %): refused `TooFewTokens`.
    function test_ExemptedAddressesPayNoSnipeTaxOnEitherDoor() public {
        Curve curve = _launchExempt(_list(alice, bob), 100);
        (uint256 asCreator, uint256 creatorFee, uint256 creatorTax) = curve.previewBuy(500e18, maker);
        assertGt(creatorTax, 0, "the creator's tax applies");

        uint256 before = _fees(curve);
        vm.prank(alice);
        uint256 outAlice = curve.buy(500e18, 1);
        assertEq(_fees(curve) - before, creatorFee + creatorTax, "alice: fee and tax, no snipe tax");

        (uint256 asCreator2, uint256 creatorFee2, uint256 creatorTax2) = curve.previewBuy(500e18, maker);
        (uint256 asBob,,) = curve.previewBuy(500e18, bob);
        assertEq(asBob, asCreator2);
        before = _fees(curve);
        vm.prank(bob);
        uint256 outBob = cf.buy(address(curve), 500e18, 1);
        assertEq(outBob, asCreator2, "bob through the launcher");
        assertEq(_fees(curve) - before, creatorFee2 + creatorTax2);
        assertEq(outAlice, asCreator);

        (uint256 asHolder, uint256 holderFee, uint256 holderTax) = curve.previewBuy(500e18, holders[0]);
        assertEq(asHolder, 0, "a holder not named pays the snipe tax");
        assertEq(holderFee + holderTax, 500e18);
        vm.prank(holders[0]);
        vm.expectRevert(abi.encodeWithSelector(Curve.TooFewTokens.selector, 0, 1));
        cf.buy(address(curve), 500e18, 1);
    }

    /// The same on a reserve-ETF curve in USDG through the launcher: an exempted address buying at the
    /// launch's second gets what the creator gets there; a stranger gets less than a tenth of it.
    function test_AnExemptedAddressBuysInUsdgThroughTheLauncherWithoutTheSnipeTax() public {
        (, Curve curve) = _launchEtfExempt(_list(alice, address(0xA11CE)));
        Etf.Route[] memory r = _routes(500e6);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 atLaunch = cf.buyWithUsdg(address(curve), 500e6, r, 1, 1, new Etf.Route[](0), 0);
        vm.revertToState(snap);
        vm.prank(holders[0]);
        uint256 strangerAtLaunch = cf.buyWithUsdg(address(curve), 500e6, r, 1, 1, new Etf.Route[](0), 0);
        vm.revertToState(snap);
        vm.prank(maker);
        uint256 creatorAtLaunch = cf.buyWithUsdg(address(curve), 500e6, r, 1, 1, new Etf.Route[](0), 0);
        assertEq(atLaunch, creatorAtLaunch, "no snipe tax for her");
        assertLt(strangerAtLaunch * 10, atLaunch, "the stranger paid the 99 %");
    }

    /// The list is kept as given, no event: a repeat, the creator and the zero address flagged harmlessly;
    /// `isSnipeExempt` answers it, for good, the creator with or without an entry, and nobody else.
    function test_TheListIsKept() public {
        address[] memory l = new address[](5);
        (l[0], l[1], l[2], l[3], l[4]) = (alice, bob, alice, maker, address(0));
        Curve curve = _launchExempt(l, 0);
        Curve bare = _launchExempt(new address[](0), 0);
        assertTrue(bare.isSnipeExempt(maker), "the creator without an entry");
        assertTrue(curve.isSnipeExempt(maker) && curve.isSnipeExempt(alice) && curve.isSnipeExempt(bob));
        assertFalse(curve.isSnipeExempt(holders[0]));
        assertFalse(curve.isSnipeExempt(address(cf)), "the launcher is not exempt");
        vm.warp(curve.launchedAt() + 365 days);
        assertTrue(curve.isSnipeExempt(alice), "kept");
        assertEq(curve.currentSnipeTaxBps(holders[0]), 0, "after 3 s nobody pays it");
        vm.warp(curve.launchedAt());
        assertEq(curve.currentSnipeTaxBps(alice), 0);
        assertEq(curve.currentSnipeTaxBps(holders[0]), 9900);
    }

    /// The cap: `MAX_SNIPE_EXEMPTIONS` (10) addresses on both doors; one more refused by name.
    function test_TheCapHoldsOnBothDoors() public {
        uint256 cap = cf.CURVE_IMPLEMENTATION().MAX_SNIPE_EXEMPTIONS();
        assertEq(cap, 10);
        address[] memory full = _distinct(cap);
        address[] memory over = _distinct(cap + 1);
        Curve c1 = _launchExempt(full, 0);
        assertTrue(c1.isSnipeExempt(full[cap - 1]));
        (, Curve c2) = _launchEtfExempt(full);
        assertTrue(c2.isSnipeExempt(full[0]));

        vm.startPrank(maker);
        vm.expectRevert(abi.encodeWithSelector(Curve.TooManyExemptions.selector, cap + 1, cap));
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(qt), SIM_THRESHOLD, 0, 1_000_000_000, QT_FIRST_BUY, over);
        Etf.Route[] memory seed = _seedRoutes(_legsAbc());
        vm.expectRevert(abi.encodeWithSelector(Curve.TooManyExemptions.selector, cap + 1, cap));
        cf.launchWithEtf{ value: FEE }("Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 0, 1_000_000_000, SEED_USDG, seed, 1, over, 0, new Etf.Route[](0), 0);
        vm.stopPrank();
    }
}

/// The suite above on the ETF v4.
contract MaidMarianLaunchCurveSnipeV4Test is MaidMarianLaunchCurveSnipeTest {
    function _useEtfFactory() internal override {
        _switchToV4();
    }
}
