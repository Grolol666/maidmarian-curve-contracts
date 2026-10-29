// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianEtfV4 as EtfV4 } from "../src/MaidMarianEtfV4.sol";
import { MaidMarianTokenLauncher as Launcher } from "../src/MaidMarianTokenLauncher.sol";
import { MaidMarianLaunchCurve as Curve } from "../src/MaidMarianLaunchCurve.sol";
import { CurveBase } from "./MaidMarianLaunchCurve.t.sol";

/**
 * The curve's and the launcher's ways out when a leg's token refuses the transfer, and `sellAfterBond`'s
 * bounds, offline: the real launcher, curve, token, v4 factory and v4 ETF code (`_switchToV4`) over the
 * curve suite's mocks. A paused stock token (the chain's `Stock` carries `onlyNotPaused` /
 * `onlyNotBlocked`) is a `transfer` that reverts (`vm.mockCallRevert`). Proves the contracts against the
 * mocks; the deployed v4 and its real legs are `MaidMarianLauncherV2Fixes.fork.t.sol`.
 *
 *   forge test --match-contract MaidMarianLauncherV2FixesTest -vv
 */
contract MaidMarianLauncherV2FixesTest is CurveBase {
    uint16 internal constant LEG_A = 1;

    function _useEtfFactory() internal override {
        _switchToV4();
    }

    function setUp() public override {
        super.setUp();
        address[3] memory who = [alice, bob, carol];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            usdg.approve(address(cf), type(uint256).max);
        }
        usdg.mint(carol, 1e12);
    }

    // ----------------------------------------------------------- helpers ---

    /// A reserve-ETF curve, alice's and bob's tokens approved to the launcher.
    function _etfCurve(uint16 tax) internal returns (Etf etf, Curve curve) {
        (etf, curve) = _launchEtf(tax);
        IERC20 token = _tok(curve);
        address[2] memory who = [alice, bob];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            token.approve(address(cf), type(uint256).max);
        }
    }

    /// The same, bonded by two buys in USDG, and alice holding tokens bought in the bond pool.
    function _bonded() internal returns (Etf etf, Curve curve, uint256 tokens) {
        (etf, curve) = _etfCurve(100);
        _buyUsdg(curve, alice, 4000e6);
        _buyUsdg(curve, bob, 7000e6);
        assertTrue(curve.bonded());
        Etf.Route[] memory r = _buyRoutes(etf, 500e6, false);
        vm.prank(alice);
        tokens = cf.buyAfterBond(address(curve), address(etf), 500e6, r, 1);
    }

    function _zeroRoutes(Etf etf) internal view returns (Etf.Route[] memory r) {
        uint256[] memory zero = new uint256[](etf.LEGS());
        r = _sellRoutes(etf, zero);
    }

    function _usdgRoutes(Etf etf, address redeemer, uint256 shares) internal view returns (Etf.Route[] memory) {
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(redeemer, shares);
        return _sellRoutes(etf, due);
    }

    /// The shares `sellAfterBond(tokensIn)` by `who` would take out of the pool now, from a dry run reverted after.
    function _sharesForTokens(Etf etf, Curve curve, address who, uint256 tokensIn) internal returns (uint256 shares) {
        uint256 snap = vm.snapshotState();
        uint256 pool = etf.balanceOf(address(pm));
        Etf.Route[] memory zero = _zeroRoutes(etf);
        vm.prank(who);
        cf.sellAfterBond(address(curve), address(etf), tokensIn, 0, 1, zero, 0, 0);
        shares = pool - etf.balanceOf(address(pm));
        vm.revertToState(snap);
    }

    function _launcherHolds(Etf etf, Curve curve) internal view returns (uint256) {
        return usdg.balanceOf(address(cf)) + etf.balanceOf(address(cf)) + _tok(curve).balanceOf(address(cf)) + a.balanceOf(address(cf)) + b.balanceOf(address(cf)) + c.balanceOf(address(cf));
    }

    /// `token` paused: every `transfer` reverts, as a paused or blocklisting stock token's does.
    function _pause(address token) internal {
        vm.mockCallRevert(token, abi.encodeWithSelector(IERC20.transfer.selector), "paused");
    }

    // ------------------------------------------------- 1. the escape ---

    /// Before the bond, leg a paused: alice's sale in kind with a's bit in `allowFail` goes through, b, c
    /// and the USDG part paid, a's part left in the fund (its count unmoved), her tokens taken, no share to
    /// her. The same sale with `allowFail` 0, and the sales to USDG (which have no `allowFail`), still
    /// revert on a; the escape in shares stays refused.
    function test_APausedLegLetsACurveHolderSellInKindWithAllowFail() public {
        (Etf etf, Curve curve) = _etfCurve(0);
        uint256 out = _buyUsdg(curve, alice, 2000e6);
        (uint256 quoteOut,,) = curve.previewSell(out / 4);
        Etf.Route[] memory aInKind = _usdgRoutes(etf, address(curve), quoteOut);
        aInKind[0].amountIn = 0;
        (,,, uint256[] memory due,) = etf.previewRedeem(address(curve), quoteOut);
        uint256 aHeld = EtfV4(address(etf)).legHeld(0);

        _pause(address(a));

        vm.startPrank(alice);
        vm.expectRevert();
        curve.sell(out / 4, 0, 1, _noRoutes(), 0, 0);
        vm.expectRevert();
        curve.sell(out / 4, 0, 2, aInKind, 0, LEG_A);
        vm.expectRevert(Curve.SharesStayInTheCurve.selector);
        curve.sell(out / 4, 0, 0, _noRoutes(), 0, LEG_A);
        (uint256 b0, uint256 c0) = (b.balanceOf(alice), c.balanceOf(alice));
        curve.sell(out / 4, 0, 1, _noRoutes(), 0, LEG_A);
        vm.stopPrank();

        assertEq(_tok(curve).balanceOf(alice), out - out / 4, "her tokens taken");
        assertEq(b.balanceOf(alice) - b0, due[1], "b paid");
        assertEq(c.balanceOf(alice) - c0, due[2], "c paid");
        assertEq(a.balanceOf(alice), 0, "a not paid");
        assertEq(EtfV4(address(etf)).legHeld(0), aHeld, "a's part stays in the fund");
        assertEq(etf.balanceOf(alice), 0, "no share to her");
    }

    /// Before the bond, leg a paused: the creator claims his fees in kind with a's bit set; with 0 it reverts.
    function test_APausedLegLetsTheCreatorClaimInKindWithAllowFail() public {
        (Etf etf, Curve curve) = _etfCurve(100);
        _buyUsdg(curve, alice, 2000e6);
        uint256 fees = curve.creatorFees() + curve.unbookedShares();
        _pause(address(a));
        vm.startPrank(maker);
        vm.expectRevert();
        curve.claim(false, fees, carol, 1, _noRoutes(), 0, 0);
        uint256 b0 = b.balanceOf(carol);
        curve.claim(false, fees, carol, 1, _noRoutes(), 0, LEG_A);
        vm.stopPrank();
        assertEq(curve.creatorFees(), 0, "claimed whole");
        assertGt(b.balanceOf(carol), b0, "b paid");
        assertEq(a.balanceOf(carol), 0, "a not paid");
        assertEq(etf.balanceOf(carol), 0, "no share to him");
    }

    /// With no leg paused, `allowFail` changes nothing: every leg delivered, as with 0.
    function test_AllowFailChangesNothingWhileEveryTransferGoesThrough() public {
        (Etf etf, Curve curve) = _etfCurve(0);
        uint256 out = _buyUsdg(curve, alice, 2000e6);
        (uint256 quoteOut,,) = curve.previewSell(out / 4);
        (,,, uint256[] memory due,) = etf.previewRedeem(address(curve), quoteOut);
        vm.prank(alice);
        curve.sell(out / 4, 0, 1, _noRoutes(), 0, type(uint16).max);
        assertEq(a.balanceOf(alice), due[0]);
        assertEq(b.balanceOf(alice), due[1]);
        assertEq(c.balanceOf(alice), due[2]);
    }

    /// After the bond, leg a paused: `sellAfterBond` in kind with a's bit set goes through (b and c paid, a
    /// in the fund, the launcher left with nothing); with 0, and to USDG, it reverts.
    function test_APausedLegLetsACurveHolderSellAfterTheBondInKindWithAllowFail() public {
        (Etf etf, Curve curve, uint256 tokens) = _bonded();
        Etf.Route[] memory zero = _zeroRoutes(etf);
        Etf.Route[] memory toUsdg = _usdgRoutes(etf, address(cf), _sharesForTokens(etf, curve, alice, tokens));
        uint256 aHeld = EtfV4(address(etf)).legHeld(0);
        uint256 held = _tok(curve).balanceOf(alice);
        (uint256 a0, uint256 b0, uint256 c0) = (a.balanceOf(alice), b.balanceOf(alice), c.balanceOf(alice));

        _pause(address(a));

        vm.startPrank(alice);
        vm.expectRevert();
        cf.sellAfterBond(address(curve), address(etf), tokens, 0, 1, zero, 0, 0);
        vm.expectRevert();
        cf.sellAfterBond(address(curve), address(etf), tokens, 0, 2, toUsdg, 0, LEG_A);
        uint256 usdgOut = cf.sellAfterBond(address(curve), address(etf), tokens, 0, 1, zero, 0, LEG_A);
        vm.stopPrank();

        assertEq(usdgOut, 0, "in kind");
        assertEq(held - _tok(curve).balanceOf(alice), tokens, "her tokens sold");
        assertGt(b.balanceOf(alice), b0, "b paid");
        assertGt(c.balanceOf(alice), c0, "c paid");
        assertEq(a.balanceOf(alice), a0, "a not paid");
        assertEq(EtfV4(address(etf)).legHeld(0), aHeld, "a's part stays in the fund");
        assertEq(_launcherHolds(etf, curve), 0, "the launcher holds nothing");
        assertEq(etf.balanceOf(alice), 0, "no share to her");
    }

    /// `sellAfterBond` takes a payout of the curve's two redeems only.
    function test_SellAfterBondRefusesAnyOtherPayout() public {
        (Etf etf, Curve curve, uint256 tokens) = _bonded();
        Etf.Route[] memory zero = _zeroRoutes(etf);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Launcher.BadPayout.selector, uint8(0)));
        cf.sellAfterBond(address(curve), address(etf), tokens, 0, 0, zero, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(Launcher.BadPayout.selector, uint8(3)));
        cf.sellAfterBond(address(curve), address(etf), tokens, 0, 3, zero, 0, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------- 2. minSharesOut ---

    /// `minSharesOut` bounds the pool step whatever the payout: one share more than the pool gives reverts
    /// `TooFewShares`, in kind as to USDG; exactly what it gives goes through.
    function test_SellAfterBondsMinSharesOutBoundsThePoolStep() public {
        (Etf etf, Curve curve, uint256 tokens) = _bonded();
        uint256 shares = _sharesForTokens(etf, curve, alice, tokens);
        Etf.Route[] memory zero = _zeroRoutes(etf);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Launcher.TooFewShares.selector, shares, shares + 1));
        cf.sellAfterBond(address(curve), address(etf), tokens, shares + 1, 1, zero, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(Launcher.TooFewShares.selector, shares, shares + 1));
        cf.sellAfterBond(address(curve), address(etf), tokens, shares + 1, 2, zero, 0, 0);
        cf.sellAfterBond(address(curve), address(etf), tokens, shares, 1, zero, 0, 0);
        vm.stopPrank();
    }

    // ------------------------------------- 3. routes within the due ---

    /// Routes read from a preview, then a sale by bob moves the pool against alice: her due on every leg
    /// falls under her routes (the ETF's `redeem` refuses a route above its due, `OverRedeem`). The launcher
    /// lowers each to its due: every leg sold, nothing in kind, USDG to her, the launcher left with nothing.
    function test_SellAfterBondRoutesAboveTheDueAreLoweredToIt() public {
        (Etf etf, Curve curve, uint256 tokens) = _bonded();
        Etf.Route[] memory sr = _usdgRoutes(etf, address(cf), _sharesForTokens(etf, curve, alice, tokens));
        uint256 bobTokens = _tok(curve).balanceOf(bob) / 10;
        Etf.Route[] memory zero = _zeroRoutes(etf);
        vm.prank(bob);
        cf.sellAfterBond(address(curve), address(etf), bobTokens, 0, 1, zero, 0, 0);
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(address(cf), _sharesForTokens(etf, curve, alice, tokens));
        for (uint256 i = 0; i < due.length; i++) {
            assertGt(sr[i].amountIn, due[i], "the move put every route above its due");
        }

        (uint256 a0, uint256 b0, uint256 c0, uint256 u0) = (a.balanceOf(alice), b.balanceOf(alice), c.balanceOf(alice), usdg.balanceOf(alice));
        vm.prank(alice);
        uint256 usdgOut = cf.sellAfterBond(address(curve), address(etf), tokens, 0, 2, sr, 1, 0);
        assertGt(usdgOut, 0);
        assertEq(usdg.balanceOf(alice) - u0, usdgOut, "USDG to her");
        assertEq(a.balanceOf(alice), a0, "a sold whole");
        assertEq(b.balanceOf(alice), b0, "b sold whole");
        assertEq(c.balanceOf(alice), c0, "c sold whole");
        assertEq(_launcherHolds(etf, curve), 0, "the launcher holds nothing");
    }

    /// A route moved to its due keeps the caller's price: lowered, its `amountOutMin` falls in the same
    /// proportion, rounded up, and reaches the router so (the last leg's, the router's `lastAmountOutMin`);
    /// raised from half its due, the floor rises alike, so no remainder of the leg is paid in kind.
    function test_SellAfterBondMovesARouteAndItsAmountOutMinToTheDueInProportion() public {
        (Etf etf, Curve curve, uint256 tokens) = _bonded();
        uint256 shares = _sharesForTokens(etf, curve, alice, tokens / 2);
        Etf.Route[] memory sr = _usdgRoutes(etf, address(cf), shares);
        uint256 last = sr.length - 1;
        uint256 written = sr[last].amountIn;
        sr[last].amountIn = written + written / 3;
        sr[last].amountOutMin = 1e6 + 1;
        vm.prank(alice);
        cf.sellAfterBond(address(curve), address(etf), tokens / 2, 0, 2, sr, 1, 0);
        assertEq(router.lastAmountOutMin(), Math.mulDiv(1e6 + 1, written, written + written / 3, Math.Rounding.Ceil), "the floor in proportion");

        shares = _sharesForTokens(etf, curve, alice, tokens / 4);
        sr = _usdgRoutes(etf, address(cf), shares);
        uint256 due = sr[last].amountIn;
        sr[last].amountIn = due / 2;
        sr[last].amountOutMin = 7;
        uint256 c0 = c.balanceOf(alice);
        vm.prank(alice);
        cf.sellAfterBond(address(curve), address(etf), tokens / 4, 0, 2, sr, 1, 0);
        assertEq(router.lastAmountOutMin(), Math.mulDiv(7, due, due / 2, Math.Rounding.Ceil), "a route under its due raised to it, its floor alike");
        assertEq(c.balanceOf(alice), c0, "the leg sold whole");
    }
}
