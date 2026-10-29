// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { oneThreshold } from "./CurveFixtures.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianTokenLauncher as CurveFactory, IWrappedNative } from "../src/MaidMarianTokenLauncher.sol";
import { MaidMarianToken as Token } from "../src/MaidMarianToken.sol";
import { MaidMarianLaunchCurve as Curve } from "../src/MaidMarianLaunchCurve.sol";
import { CurveBase } from "./MaidMarianLaunchCurve.t.sol";
import { mineLaunchHookSalt } from "../script/DeployTokenLauncher.s.sol";

/**
 * Offline: the launcher's two buy doors (one approve for every curve) and the token's
 * sale with the usual approve, over the curve suite's mocks and the real launcher, curve, token, ETF factory and
 * ETF code. A curve bought through the launcher and its twin bought directly are compared; "only the
 * caller's funds" is fuzzed over the caller. The launcher on the deployed v4 is
 * `MaidMarianEtfV4Launch.fork.t.sol`.
 *
 *   forge test --match-contract MaidMarianLauncherDoors -vv
 */
contract MaidMarianLauncherDoorsTest is CurveBase {
    function setUp() public virtual override {
        super.setUp();
        address[8] memory who = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker];
        for (uint256 i = 0; i < who.length; i++) {
            vm.startPrank(who[i]);
            qt.approve(address(cf), type(uint256).max);
            usdg.approve(address(cf), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ----------------------------------------------------------- helpers ---

    /// A curve on `qt` by `maker`, nobody approved to it: its buyers come through the launcher.
    function _bare(uint16 tax) internal returns (Curve curve) {
        vm.prank(maker);
        curve = cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(qt), SIM_THRESHOLD, tax, 1_000_000_000, QT_FIRST_BUY, new address[](0));
        vm.warp(vm.getBlockTimestamp() + 3);
    }

    /// A reserve-ETF curve by `maker`, nobody approved to it.
    function _bareEtf(uint16 tax) internal returns (Etf etf, Curve curve) {
        (etf, curve) = _launchWithEtf("Robin Coin", "ROBIN", "", _noProfileC(), tax);
        vm.warp(vm.getBlockTimestamp() + 3);
    }

    /// Routes that spend 99 % of `usdgIn` at 60 / 25 / 15 % over the reserve ETF's three legs, off its 50 / 30 / 20.
    function _skew(uint256 usdgIn) internal view returns (Etf.Route[] memory r) {
        uint256 spend = usdgIn - usdgIn / 100;
        r = new Etf.Route[](3);
        r[0] = _swapRoute(0, false, spend * 60 / 100);
        r[1] = _swapRoute(1, false, spend * 25 / 100);
        r[2] = _swapRoute(2, false, spend - spend * 60 / 100 - spend * 25 / 100);
    }

    /// What the launcher holds of every asset a door touches.
    function _launcherHolds(Curve curve) internal view returns (uint256 total) {
        total = qt.balanceOf(address(cf)) + usdg.balanceOf(address(cf)) + _tok(curve).balanceOf(address(cf)) + a.balanceOf(address(cf)) + b.balanceOf(address(cf)) + c.balanceOf(address(cf));
        if (curve.etfQuote()) total += IERC20(curve.quote()).balanceOf(address(cf));
    }

    function _allowances(Curve curve) internal view returns (uint256) {
        return IERC20(curve.quote()).allowance(address(cf), address(curve)) + usdg.allowance(address(cf), address(curve));
    }

    // --------------------------------------------------------------- buy ---

    /// A buy through the launcher is the buyer's own buy on the curve: the same tokens, fees, reserves and
    /// quote spent as the same buy made directly on a twin curve, the tokens in his wallet, and the launcher
    /// holds nothing and left no allowance to the curve. The curve's `Bought` names the caller.
    function test_ABuyThroughTheLauncherIsTheCallersOwnBuy() public {
        Curve direct = _bare(50);
        Curve via = _bare(50);
        vm.prank(holders[0]);
        qt.approve(address(direct), type(uint256).max);
        uint256 qBefore0 = qt.balanceOf(holders[0]);
        vm.prank(holders[0]);
        uint256 out1 = direct.buy(2000e18, 0);
        uint256 spent1 = qBefore0 - qt.balanceOf(holders[0]);

        uint256 qBefore1 = qt.balanceOf(holders[1]);
        vm.expectEmit(true, false, false, false, address(via));
        emit Curve.Bought(holders[1], 0, 0, 0, 0, 0, 0, 0);
        vm.prank(holders[1]);
        uint256 out2 = cf.buy(address(via), 2000e18, 1);
        assertEq(out2, out1, "the same tokens");
        assertEq(qBefore1 - qt.balanceOf(holders[1]), spent1, "the same quote spent");
        assertEq(_tok(via).balanceOf(holders[1]), out2);
        (uint256 q1, uint256 t1) = direct.getReserves();
        (uint256 q2, uint256 t2) = via.getReserves();
        assertEq(q2, q1);
        assertEq(t2, t1);
        assertEq(via.creatorFees(), direct.creatorFees());
        assertEq(via.protocolFees(), direct.protocolFees());
        assertEq(_launcherHolds(via), 0, "the launcher holds nothing");
        assertEq(_allowances(via), 0, "and left the curve no allowance");
        assertEq(_tok(via).balanceOf(address(cf)), 0);
    }

    /// The last buy, past the curve's end, through the launcher: the curve takes all of it, the caller
    /// pays it whole and gets the previewed tokens, the curve bonds, the launcher keeps nothing.
    function test_TheLastBuyThroughTheLauncherIsBoughtWhole() public {
        Curve curve = _bare(0);
        (uint256 expected,,) = curve.previewBuy(20_000e18, holders[2]);
        uint256 before = qt.balanceOf(holders[2]);
        vm.prank(holders[2]);
        uint256 out = cf.buy(address(curve), 20_000e18, 1);
        assertTrue(curve.bonded());
        assertEq(out, expected);
        assertEq(before - qt.balanceOf(holders[2]), 20_000e18, "he paid it whole");
        assertEq(_tok(curve).balanceOf(holders[2]), out);
        assertEq(_launcherHolds(curve), 0);
    }

    /// A donation to the launcher stays where it is: the caller gets what his own call moved, not a wei of it.
    function test_ADonationToTheLauncherIsNotPassedToTheCaller() public {
        Curve curve = _bare(0);
        vm.prank(holders[3]);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        qt.transfer(address(cf), 5e18);
        deal(address(_tok(curve)), address(cf), 7e18);
        uint256 before = qt.balanceOf(holders[2]);
        vm.prank(holders[2]);
        uint256 out = cf.buy(address(curve), 100e18, 1);
        assertEq(before - qt.balanceOf(holders[2]), 100e18);
        assertEq(_tok(curve).balanceOf(holders[2]), out, "only the tokens his buy produced");
        assertEq(qt.balanceOf(address(cf)), 5e18);
        assertEq(_tok(curve).balanceOf(address(cf)), 7e18);
    }

    /// Whatever the amount, the launcher ends a buy holding what it held before, and the caller holds the tokens.
    function testFuzz_TheLauncherEndsEveryBuyHoldingNothing(uint256 amount) public {
        amount = bound(amount, 1e12, 30_000e18);
        Curve curve = _bare(100);
        vm.prank(holders[4]);
        uint256 out = cf.buy(address(curve), amount, 1);
        assertEq(_launcherHolds(curve), 0);
        assertEq(_allowances(curve), 0);
        assertEq(_tok(curve).balanceOf(holders[4]), out);
    }

    /// Only the caller's allowance to the launcher is spent. A holder's standing approve is out of reach of a
    /// stranger who has no funds, and untouched by one who has.
    function testFuzz_ABuySpendsOnlyTheCallersAllowance(address stranger, uint256 amount) public {
        vm.assume(stranger != address(0) && stranger.code.length == 0 && stranger != address(cf) && stranger != address(vm) && stranger != makeAddr("pools") && stranger != address(0xdEaD));
        vm.assume(stranger != alice && stranger != bob && stranger != maker && stranger != owner);
        for (uint256 i = 0; i < holders.length; i++) {
            vm.assume(stranger != holders[i]);
        }
        amount = bound(amount, 1e12, 5000e18);
        Curve curve = _bare(0);
        address victim = holders[0];
        uint256 victimQuote = qt.balanceOf(victim);
        assertEq(qt.allowance(victim, address(cf)), type(uint256).max);

        vm.prank(stranger);
        vm.expectRevert();
        cf.buy(address(curve), amount, 1);
        assertEq(qt.balanceOf(victim), victimQuote);

        qt.mint(stranger, amount);
        vm.startPrank(stranger);
        qt.approve(address(cf), amount);
        uint256 out = cf.buy(address(curve), amount, 1);
        vm.stopPrank();
        assertEq(qt.balanceOf(victim), victimQuote, "the victim's balance is untouched");
        assertEq(qt.allowance(victim, address(cf)), type(uint256).max, "and his allowance too");
        assertEq(_tok(curve).balanceOf(stranger), out);
        assertEq(_tok(curve).balanceOf(victim), 0);
        assertEq(_launcherHolds(curve), 0);
    }

    /// Only a curve this launcher made: a stranger's address, the launcher, a token, and a curve of another
    /// launcher are refused by name, before any pull.
    function test_OnlyACurveOfTheLauncherCanBeBoughtThrough() public {
        (bytes32 salt,) = mineLaunchHookSalt(vm.computeCreateAddress(address(this), vm.getNonce(address(this))), router.poolManager());
        CurveFactory other = new CurveFactory(factory, owner, IWrappedNative(address(weth)), salt);
        vm.startPrank(owner);
        other.setTokenQuote(address(qt), true, false, oneThreshold(SIM_THRESHOLD), 1);
        vm.stopPrank();
        vm.prank(maker);
        qt.approve(address(other), type(uint256).max);
        vm.prank(maker);
        Curve foreign = other.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(qt), SIM_THRESHOLD, 0, 1_000_000_000, QT_FIRST_BUY, new address[](0));
        Curve own = _bare(0);
        address[5] memory bad = [makeAddr("stranger"), address(cf), address(qt), address(foreign), address(_tok(own))];
        Etf.Route[] memory none = new Etf.Route[](3);
        for (uint256 i = 0; i < bad.length; i++) {
            uint256 before = qt.balanceOf(holders[0]);
            vm.startPrank(holders[0]);
            vm.expectRevert(abi.encodeWithSelector(CurveFactory.NotCurve.selector, bad[i]));
            cf.buy(bad[i], 100e18, 1);
            vm.expectRevert(abi.encodeWithSelector(CurveFactory.NotCurve.selector, bad[i]));
            cf.buyWithUsdg(bad[i], 100e6, none, 1, 1, new Etf.Route[](0), 0);
            vm.stopPrank();
            assertEq(qt.balanceOf(holders[0]), before);
        }
    }

    function test_AMinimumOfTokensBindsTheBuyAndNothingIsPulled() public {
        Curve curve = _bare(0);
        (uint256 expected,,) = curve.previewBuy(100e18, holders[1]);
        uint256 before = qt.balanceOf(holders[1]);
        vm.prank(holders[1]);
        vm.expectRevert(abi.encodeWithSelector(Curve.TooFewTokens.selector, expected, expected + 1));
        cf.buy(address(curve), 100e18, expected + 1);
        assertEq(qt.balanceOf(holders[1]), before);
        vm.prank(holders[1]);
        vm.expectRevert(Curve.NothingIn.selector);
        cf.buy(address(curve), 0, 0);
    }

    /// A curve quoted in a reserve ETF's shares is not bought in shares through this door: the launcher
    /// refuses it by name (`EtfCurveBuysInUsdg`) before pulling anything; `buyWithUsdg` is its door.
    function test_AnEtfQuoteCurveIsNotBoughtInSharesThroughTheLauncher() public {
        (Etf etf, Curve curve) = _bareEtf(0);
        vm.prank(alice);
        usdg.approve(address(etf), type(uint256).max);
        uint256 shares = _mint(etf, alice, 10e6);
        vm.prank(alice);
        etf.approve(address(cf), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.EtfCurveBuysInUsdg.selector, address(curve)));
        cf.buy(address(curve), shares, 1);
        assertEq(etf.balanceOf(alice), shares, "nothing pulled");
        assertEq(_launcherHolds(curve), 0);
    }

    // ------------------------------------------------------- buyWithUsdg ---

    /// The same, in USDG: the curve mints the shares, buys with them, and pays the caller (the launcher's)
    /// the tokens alone, the USDG the routes left and each leg the mint refunded going to the launcher's
    /// owner - the same as the same buy made directly on the curve, each run from one state - and holds
    /// nothing.
    function test_ABuyInUsdgThroughTheLauncherIsTheCallersOwnBuy() public {
        (Etf etf, Curve curve) = _bareEtf(50);
        Token token = _tok(curve);
        Etf.Route[] memory r = _skew(500e6);
        vm.startPrank(alice);
        usdg.approve(address(curve), type(uint256).max);
        usdg.approve(address(cf), type(uint256).max);
        vm.stopPrank();
        uint256[4] memory a0 = [usdg.balanceOf(alice), a.balanceOf(alice), b.balanceOf(alice), c.balanceOf(alice)];
        uint256 ownerA0 = a.balanceOf(cf.owner());
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 out1 = curve.buyWithUsdg(500e6, r, 1, 1, new Etf.Route[](0), 0);
        uint256[4] memory a1 = [usdg.balanceOf(alice), a.balanceOf(alice), b.balanceOf(alice), c.balanceOf(alice)];
        (uint256 q1, uint256 t1) = curve.getReserves();
        (uint256 mintOf1, uint256 shares1) = (etf.mintOf(address(curve)), etf.balanceOf(address(curve)));
        vm.revertToState(snap);

        vm.prank(alice);
        uint256 out2 = cf.buyWithUsdg(address(curve), 500e6, r, 1, 1, new Etf.Route[](0), 0);
        uint256[4] memory a2 = [usdg.balanceOf(alice), a.balanceOf(alice), b.balanceOf(alice), c.balanceOf(alice)];
        assertEq(out2, out1, "the same tokens");
        assertEq(token.balanceOf(alice), out2);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(a2[i], a1[i], "the same wallet after");
        }
        assertEq(a2[1], a0[1], "no leg to him");
        assertEq(a0[0] - a2[0], 500e6, "his USDG to the wei");
        assertGt(a.balanceOf(cf.owner()), ownerA0, "the mint's leg refund to the owner");
        (uint256 q2, uint256 t2) = curve.getReserves();
        assertEq(q2, q1);
        assertEq(t2, t1);
        assertEq(etf.mintOf(address(curve)), mintOf1, "the curve's mintOf");
        assertEq(etf.balanceOf(address(curve)), shares1);
        assertEq(_launcherHolds(curve), 0, "the launcher holds nothing");
        assertEq(etf.balanceOf(address(cf)), 0);
        assertEq(_allowances(curve), 0);
    }

    /// The last buy in USDG through the launcher: every share it minted is bought, the caller gets the
    /// tokens and no leg, no USDG, no share; the launcher holds nothing.
    function test_TheLastBuyInUsdgThroughTheLauncherBuysEveryShareItMinted() public {
        (Etf etf, Curve curve) = _bareEtf(0);
        vm.prank(alice);
        cf.buyWithUsdg(address(curve), 4000e6, _skew(4000e6), 1, 1, new Etf.Route[](0), 0);
        uint256 aBefore = a.balanceOf(bob);
        uint256 usdgBefore = usdg.balanceOf(bob);
        Etf.Route[] memory r = _skew(9000e6);
        vm.prank(bob);
        uint256 out = cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, new Etf.Route[](0), 0);
        assertTrue(curve.bonded());
        assertEq(_tok(curve).balanceOf(bob), out);
        assertEq(a.balanceOf(bob), aBefore, "no leg in kind");
        assertEq(usdgBefore - usdg.balanceOf(bob), 9000e6, "his USDG, to the wei");
        assertEq(etf.balanceOf(bob), 0);
        assertEq(_launcherHolds(curve), 0);
        assertEq(etf.balanceOf(address(cf)), 0);
    }

    function testFuzz_TheLauncherEndsEveryBuyInUsdgHoldingNothing(uint256 amount, uint256 skew) public {
        amount = bound(amount, 20e6, 6000e6);
        skew = bound(skew, 0, 40);
        (, Curve curve) = _bareEtf(100);
        uint256 spend = (amount - amount / 100) * (100 - skew) / 100;
        Etf.Route[] memory r = new Etf.Route[](3);
        r[0] = _swapRoute(0, false, spend * 50 / 100);
        r[1] = _swapRoute(1, false, spend * 30 / 100);
        r[2] = _swapRoute(2, false, spend * 20 / 100);
        vm.prank(alice);
        uint256 out = cf.buyWithUsdg(address(curve), amount, r, 0, 1, new Etf.Route[](0), 0);
        assertEq(_launcherHolds(curve), 0);
        assertEq(_allowances(curve), 0);
        assertEq(_tok(curve).balanceOf(alice), out);
    }

    function testFuzz_ABuyInUsdgSpendsOnlyTheCallersAllowance(address stranger, uint256 amount) public {
        vm.assume(stranger != address(0) && stranger.code.length == 0 && stranger != address(cf) && stranger != address(vm) && stranger != makeAddr("pools") && stranger != address(0xdEaD));
        vm.assume(stranger != alice && stranger != bob && stranger != maker && stranger != owner);
        for (uint256 i = 0; i < holders.length; i++) {
            vm.assume(stranger != holders[i]);
        }
        amount = bound(amount, 20e6, 2000e6);
        (, Curve curve) = _bareEtf(0);
        uint256 victimUsdg = usdg.balanceOf(alice);
        Etf.Route[] memory r = _skew(amount);

        vm.prank(stranger);
        vm.expectRevert();
        cf.buyWithUsdg(address(curve), amount, r, 1, 1, new Etf.Route[](0), 0);
        assertEq(usdg.balanceOf(alice), victimUsdg);

        usdg.mint(stranger, amount);
        vm.startPrank(stranger);
        usdg.approve(address(cf), amount);
        uint256 out = cf.buyWithUsdg(address(curve), amount, r, 1, 1, new Etf.Route[](0), 0);
        vm.stopPrank();
        assertEq(usdg.balanceOf(alice), victimUsdg, "the victim's USDG is untouched");
        assertEq(usdg.allowance(alice, address(cf)), type(uint256).max);
        assertEq(_tok(curve).balanceOf(stranger), out);
        assertEq(a.balanceOf(alice), 0);
        assertEq(_launcherHolds(curve), 0);
    }

    function test_AUsdgBuyOnACurveWithNoEtfQuoteIsRefusedByName() public {
        Curve curve = _bare(0);
        Etf.Route[] memory none = new Etf.Route[](3);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CurveFactory.NotEtfCurve.selector, address(curve)));
        cf.buyWithUsdg(address(curve), 100e6, none, 1, 1, new Etf.Route[](0), 0);
        assertEq(usdg.balanceOf(alice), before);
    }

    // ----------------------------------------------------------- gas ---

    function test_Gas_TheLaunchersDoorsAgainstTheCurvesOwn() public {
        Curve one = _bare(0);
        Curve two = _bare(0);
        vm.prank(holders[0]);
        qt.approve(address(one), type(uint256).max);
        vm.prank(holders[0]);
        uint256 g = gasleft();
        one.buy(1000e18, 1);
        uint256 gDirect = g - gasleft();
        vm.prank(holders[0]);
        g = gasleft();
        cf.buy(address(two), 1000e18, 1);
        uint256 gVia = g - gasleft();
        emit log_named_uint("buy, direct", gDirect);
        emit log_named_uint("buy, through the launcher", gVia);
        assertLt(gVia, gDirect + 150_000);

        (, Curve e1) = _bareEtf(0);
        (, Curve e2) = _bareEtf(0);
        Etf.Route[] memory r = _skew(500e6);
        vm.prank(alice);
        usdg.approve(address(e1), type(uint256).max);
        vm.prank(alice);
        g = gasleft();
        e1.buyWithUsdg(500e6, r, 1, 1, new Etf.Route[](0), 0);
        gDirect = g - gasleft();
        vm.prank(alice);
        g = gasleft();
        cf.buyWithUsdg(address(e2), 500e6, r, 1, 1, new Etf.Route[](0), 0);
        gVia = g - gasleft();
        emit log_named_uint("buyWithUsdg, direct, 3 legs", gDirect);
        emit log_named_uint("buyWithUsdg, through the launcher, 3 legs", gVia);
        assertLt(gVia, gDirect + 250_000);
    }
}

/**
 * The sale with the usual approve: the token is a plain ERC-20, so the curve's `sell` pulls the seller's
 * tokens with `transferFrom`, against his approve to the curve, and nobody else's.
 *
 *   forge test --match-contract MaidMarianSaleWithApprove -vv
 */
contract MaidMarianSaleWithApproveTest is CurveBase {
    /// A curve on `qt` with the buyers' quote approved to it and not one token approved.
    function _noTokenApprove(uint16 tax) internal returns (Curve curve) {
        vm.prank(maker);
        curve = cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(qt), SIM_THRESHOLD, tax, 1_000_000_000, QT_FIRST_BUY, new address[](0));
        for (uint256 i = 0; i < holders.length; i++) {
            vm.prank(holders[i]);
            qt.approve(address(curve), type(uint256).max);
        }
        vm.warp(vm.getBlockTimestamp() + 3);
    }

    /// A holder who approved nothing cannot sell (`ERC20InsufficientAllowance`, nothing moved); once he
    /// approves the curve the sale pays what `previewSell` said, the curve's reserves move as in any sale,
    /// and the sale spends exactly its tokens of the allowance.
    function test_ASaleNeedsTheSellersApproveAndSpendsIt() public {
        Curve curve = _noTokenApprove(50);
        Token token = _tok(curve);
        vm.prank(holders[0]);
        uint256 out = curve.buy(3000e18, 0);
        vm.prank(holders[0]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(curve), 0, out / 2));
        curve.sell(out / 2, 0, 0, _noRoutes(), 0, 0);
        assertEq(token.balanceOf(holders[0]), out, "nothing moved");
        vm.prank(holders[0]);
        token.approve(address(curve), out);
        (uint256 expected,,) = curve.previewSell(out / 2);
        uint256 before = qt.balanceOf(holders[0]);
        vm.prank(holders[0]);
        uint256 paid = curve.sell(out / 2, expected, 0, _noRoutes(), 0, 0);
        assertEq(paid, expected);
        assertEq(qt.balanceOf(holders[0]) - before, expected);
        assertEq(token.balanceOf(holders[0]), out - out / 2);
        assertEq(token.allowance(holders[0], address(curve)), out - out / 2, "the sale spent its tokens of the allowance");
        (, uint256 t) = curve.getReserves();
        assertEq(token.balanceOf(address(curve)), t, "the curve holds what its reserve says");
    }

    /// The token is a plain ERC-20: a spender the holder approved moves his tokens by `transferFrom`, the
    /// allowance spent; a holder burns his own (`burn`), and the supply falls by it.
    function test_TheTokenIsAPlainErc20WithBurn() public {
        Curve curve = _noTokenApprove(0);
        Token token = _tok(curve);
        vm.prank(holders[1]);
        uint256 out = curve.buy(3000e18, 0);
        vm.prank(holders[1]);
        token.approve(holders[4], out / 4);
        vm.prank(holders[4]);
        assertTrue(token.transferFrom(holders[1], holders[4], out / 4));
        assertEq(token.balanceOf(holders[4]), out / 4);
        assertEq(token.allowance(holders[1], holders[4]), 0);
        uint256 supply = token.totalSupply();
        vm.prank(holders[4]);
        token.burn(out / 8);
        assertEq(token.totalSupply(), supply - out / 8);
        assertEq(token.balanceOf(holders[4]), out / 4 - out / 8);
    }

    /// A sale only ever takes the caller's own tokens: a stranger with none and no approve is refused by
    /// the token, another holder's balance untouched, even one who approved the curve; with tokens of his
    /// own and his approve the stranger sells his, and the other holder's stay.
    function testFuzz_ASaleNeverMovesAnotherHoldersTokens(address seller, uint256 amount) public {
        vm.assume(seller != address(0) && seller.code.length == 0 && seller != address(vm) && seller != makeAddr("pools") && seller != address(0xdEaD));
        for (uint256 i = 0; i < holders.length; i++) {
            vm.assume(seller != holders[i]);
        }
        vm.assume(seller != alice && seller != bob && seller != maker && seller != owner);
        Curve curve = _noTokenApprove(0);
        vm.startPrank(holders[2]);
        uint256 out = curve.buy(3000e18, 0);
        _tok(curve).approve(address(curve), type(uint256).max);
        vm.stopPrank();
        amount = bound(amount, 1e12, out);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(curve), 0, amount));
        curve.sell(amount, 0, 0, _noRoutes(), 0, 0);
        assertEq(_tok(curve).balanceOf(holders[2]), out);

        qt.mint(seller, 1000e18);
        vm.startPrank(seller);
        qt.approve(address(curve), type(uint256).max);
        _tok(curve).approve(address(curve), type(uint256).max);
        uint256 mine = curve.buy(1000e18, 0);
        curve.sell(mine / 2, 0, 0, _noRoutes(), 0, 0);
        vm.stopPrank();
        assertEq(_tok(curve).balanceOf(seller), mine - mine / 2);
        assertEq(_tok(curve).balanceOf(holders[2]), out, "the other holder's tokens did not move");
    }
}

/// The two suites above on the ETF v4.
contract MaidMarianLauncherDoorsV4Test is MaidMarianLauncherDoorsTest {
    function _useEtfFactory() internal override {
        _switchToV4();
    }
}

contract MaidMarianSaleWithApproveV4Test is MaidMarianSaleWithApproveTest {
    function _useEtfFactory() internal override {
        _switchToV4();
    }
}
