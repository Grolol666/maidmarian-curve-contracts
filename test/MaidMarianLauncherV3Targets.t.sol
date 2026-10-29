// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianTokenLauncher as Launcher } from "../src/MaidMarianTokenLauncher.sol";
import { MaidMarianLaunchCurve as Curve } from "../src/MaidMarianLaunchCurve.sol";
import { FreezableTokenMock } from "./Mocks.sol";
import { CurveBase } from "./MaidMarianLaunchCurve.t.sol";

/**
 * Offline, the security pass's two doors: a mint's refund the owner's address
 * refuses (USDG frozen on him) never stops a buy, on the curve's doors and on the launcher's
 * `buyAfterBond`, and waits for him in a pot he claims to an address of his choice; the reserve ETF's
 * shares that reach a curve after its bond to USDG (the creator's part of the ETF's management fee) are
 * the creator's, redeemed by `claimShares`. The real launcher, curve, token, v4 factory and v4 ETF code
 * over the curve suite's mocks (`_switchToV4`), USDG a freezable mock.
 *
 *   forge test --match-contract MaidMarianLauncherV3TargetsTest -vv
 */
contract MaidMarianLauncherV3TargetsTest is CurveBase {
    address internal lo = makeAddr("launcher owner");

    function _useEtfFactory() internal override {
        _switchToV4();
    }

    /// The launcher's owner set apart from the v4 factory's, whose own entry fee every v4 mint pushes in
    /// USDG (not this launcher's door); every holder's USDG approved to the launcher.
    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        cf.transferOwnership(lo);
        address[8] memory who = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            usdg.approve(address(cf), type(uint256).max);
        }
    }

    function _launchMode(bool backedByEtf) internal returns (Etf etf, Curve curve) {
        vm.prank(maker);
        (etf, curve) = cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, etfPick, 100, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), backedByEtf ? 0 : 100, _noRoutes(), 0
        );
        _approveAll(curve, address(etf));
        vm.warp(vm.getBlockTimestamp() + 3);
    }

    /// Routes that sell 1 unit of every leg: the bond raises each to its due at execution.
    function _anyBondRoutes(Etf etf) internal view returns (Etf.Route[] memory) {
        uint256[] memory one = new uint256[](etf.LEGS());
        for (uint256 i = 0; i < one.length; i++) {
            one[i] = 1;
        }
        return _sellRoutes(etf, one);
    }

    /// Redeem routes selling all of `shares`'s due on every leg.
    function _usdgRoutes(Etf etf, address redeemer, uint256 shares) internal view returns (Etf.Route[] memory) {
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(redeemer, shares);
        return _sellRoutes(etf, due);
    }

    /// Bob's last buy of 9 000 USDG after alice's 4 000, through the launcher.
    function _bond(Etf etf, Curve curve) internal {
        _buyUsdg(curve, alice, 4000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 9000e6, false);
        Etf.Route[] memory br = _anyBondRoutes(etf);
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), 9000e6, r, 1, 1, br, 1);
        assertTrue(curve.bonded());
    }

    // ----------------------------------------------------- the owner's pot ---

    /**
     * The launcher's owner frozen on USDG: every buy goes on, on the launcher's door and the curve's own,
     * the buyer paying exactly his USDG; the refunds his address refuses are booked to the curve's
     * `ownerPot` (`OwnerPotBooked`) and kept apart from the fees, so the bond in the same state is solvent
     * to the unit with the pot beside the pots; only he claims it (`NotOwner` otherwise), to an address of
     * his choice, exactly the pot, after which the curve holds exactly its fees.
     */
    function test_AnOwnerFrozenOnUsdgNeverStopsABuyAndClaimsHisPotElsewhere() public {
        (Etf etf, Curve curve) = _launchMode(false);
        _buyUsdg(curve, alice, 1000e6);
        FreezableTokenMock(address(usdg)).freeze(lo, true);
        uint256 o0 = usdg.balanceOf(lo);
        Etf.Route[] memory r = _buyRoutes(etf, 1000e6, false);
        uint256 b0 = usdg.balanceOf(bob);
        vm.expectEmit(true, false, false, false, address(curve));
        emit Curve.OwnerPotBooked(address(usdg), 0);
        vm.prank(bob);
        assertGt(cf.buyWithUsdg(address(curve), 1000e6, r, 1, 1, _noRoutes(), 0), 0, "the launcher's door buys");
        assertEq(b0 - usdg.balanceOf(bob), 1000e6, "his USDG, exactly");
        uint256 pot = curve.ownerPot(address(usdg));
        assertGt(pot, 0, "the refund waits in the pot");
        vm.prank(bob);
        assertGt(curve.buyWithUsdg(1000e6, r, 1, 1, _noRoutes(), 0), 0, "the curve's own door buys");
        assertGt(curve.ownerPot(address(usdg)), pot, "the pot grows by the next refund, never sent twice");
        assertEq(usdg.balanceOf(lo), o0, "nothing reached the frozen owner");

        _bond(etf, curve);
        pot = curve.ownerPot(address(usdg));
        assertEq(usdg.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees() + pot, "solvent to the unit, the pot apart");

        address next = makeAddr("owner's other address");
        vm.prank(alice);
        vm.expectRevert(Curve.NotOwner.selector);
        curve.claimOwnerPot(address(usdg), alice);
        vm.prank(lo);
        vm.expectRevert(Curve.ZeroAddress.selector);
        curve.claimOwnerPot(address(usdg), address(0));
        vm.expectEmit(address(curve));
        emit Curve.OwnerPotClaimed(address(usdg), next, pot);
        vm.prank(lo);
        assertEq(curve.claimOwnerPot(address(usdg), next), pot);
        assertEq(usdg.balanceOf(next), pot);
        assertEq(curve.ownerPot(address(usdg)), 0);
        assertEq(usdg.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees(), "exactly its fees");
        vm.prank(lo);
        vm.expectRevert(Curve.NothingIn.selector);
        curve.claimOwnerPot(address(usdg), next);
    }

    /// Unfrozen, the refunds go to the owner as before and the pot stays empty: the may-fail transfer
    /// changes nothing for an owner who can receive.
    function test_AnOwnerWhoCanReceiveIsPaidTheRefundsAndThePotStaysEmpty() public {
        (Etf etf, Curve curve) = _launchMode(false);
        _buyUsdg(curve, alice, 1000e6);
        uint256 o0 = usdg.balanceOf(lo);
        Etf.Route[] memory r = _buyRoutes(etf, 1000e6, false);
        vm.prank(bob);
        cf.buyWithUsdg(address(curve), 1000e6, r, 1, 1, _noRoutes(), 0);
        assertGt(usdg.balanceOf(lo), o0, "the refund reached the owner");
        assertEq(curve.ownerPot(address(usdg)), 0);
        assertEq(usdg.balanceOf(address(curve)), 0, "the curve keeps no USDG before the bond");
    }

    /// `buyAfterBond` in a shares pool with the owner frozen on USDG: the buy goes on, the buyer pays
    /// exactly his USDG, the mint's refund waits in the launcher's `ownerPot`, which only he claims, to an
    /// address of his choice; the launcher then holds no USDG.
    function test_BuyAfterBondWithTheOwnerFrozenKeepsHisRefundInTheLaunchersPot() public {
        (Etf etf, Curve curve) = _launchMode(true);
        _bond(etf, curve);
        FreezableTokenMock(address(usdg)).freeze(lo, true);
        Etf.Route[] memory r = _buyRoutes(etf, 500e6, false);
        uint256 b0 = usdg.balanceOf(holders[0]);
        vm.prank(holders[0]);
        assertGt(cf.buyAfterBond(address(curve), address(etf), 500e6, r, 1), 0);
        assertEq(b0 - usdg.balanceOf(holders[0]), 500e6, "his USDG, exactly");
        uint256 pot = cf.ownerPot(address(usdg));
        assertGt(pot, 0, "the refund waits in the launcher's pot");
        assertEq(usdg.balanceOf(address(cf)), pot);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cf.claimOwnerPot(address(usdg), alice);
        address next = makeAddr("owner's other address");
        vm.expectEmit(address(cf));
        emit Launcher.OwnerPotClaimed(address(usdg), next, pot);
        vm.prank(lo);
        cf.claimOwnerPot(address(usdg), next);
        assertEq(usdg.balanceOf(next), pot);
        assertEq(usdg.balanceOf(address(cf)), 0);
    }

    // ------------------------------------------- shares after a USDG bond ---

    /**
     * After a bond to USDG the curve stays the reserve ETF's fee recipient: a stranger's mint and a year
     * bring it the creator's part of the management fee as shares. They are `claimableShares()`, the
     * creator's alone (`NotCreator`), up to what is held (`TooMuch`), never as shares (`PAY_QUOTE` is
     * `SharesStayInTheCurve`): redeemed in kind or to USDG with his routes; the USDG pots untouched, the
     * curve left with no share. Before a bond, or on a curve bonded in shares, the door is shut
     * (`NotBondedToUsdg`).
     */
    function test_TheSharesAReserveEtfMintsAfterAUsdgBondAreTheCreatorsToRedeem() public {
        (Etf etf, Curve curve) = _launchMode(false);
        vm.prank(maker);
        vm.expectRevert(Curve.NotBondedToUsdg.selector);
        curve.claimShares(1, maker, 1, _noRoutes(), 0, 0);
        _bond(etf, curve);
        assertEq(etf.balanceOf(address(curve)), 0);
        assertEq(curve.claimableShares(), 0);
        usdg.mint(carol, 20_000e6);
        vm.startPrank(carol);
        usdg.approve(address(etf), type(uint256).max);
        etf.mint(10_000e6, _buyRoutes(etf, 10_000e6, false), 1);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        etf.mint(1000e6, _buyRoutes(etf, 1000e6, false), 1);
        vm.stopPrank();
        uint256 held = etf.balanceOf(address(curve));
        assertGt(held, 0, "the year's creator fee reached the curve");
        assertEq(curve.claimableShares(), held);
        uint256 pots = curve.creatorFees() + curve.protocolFees();

        vm.prank(alice);
        vm.expectRevert(Curve.NotCreator.selector);
        curve.claimShares(held, alice, 1, _noRoutes(), 0, 0);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Curve.TooMuch.selector, held + 1, held));
        curve.claimShares(held + 1, maker, 1, _noRoutes(), 0, 0);
        vm.prank(maker);
        vm.expectRevert(Curve.SharesStayInTheCurve.selector);
        curve.claimShares(held, maker, 0, _noRoutes(), 0, 0);

        uint256 half = held / 2;
        uint256 a0 = a.balanceOf(maker);
        vm.expectEmit(address(curve));
        emit Curve.SharesClaimed(maker, maker, half, 1);
        vm.prank(maker);
        curve.claimShares(half, maker, 1, _noRoutes(), 0, 0);
        assertGt(a.balanceOf(maker), a0, "in kind");
        uint256 rest = curve.claimableShares();
        Etf.Route[] memory sr = _usdgRoutes(etf, address(curve), rest);
        uint256 u0 = usdg.balanceOf(maker);
        vm.prank(maker);
        curve.claimShares(rest, maker, 2, sr, 1, 0);
        assertGt(usdg.balanceOf(maker), u0, "to USDG");
        assertEq(etf.balanceOf(address(curve)), curve.claimableShares());
        assertLe(etf.balanceOf(address(curve)), 1, "nothing left but a redeem's own accrual");
        assertEq(curve.creatorFees() + curve.protocolFees(), pots, "the USDG pots untouched");
        assertEq(usdg.balanceOf(address(curve)), pots, "solvent to the unit");
    }

    /// A curve bonded into its shares pool books shares to the creator's pot as before; `claimShares` is
    /// not its door.
    function test_ACurveBondedInSharesHasNoClaimSharesDoor() public {
        (Etf etf, Curve curve) = _launchMode(true);
        _bond(etf, curve);
        assertEq(curve.claimableShares(), 0);
        vm.prank(maker);
        vm.expectRevert(Curve.NotBondedToUsdg.selector);
        curve.claimShares(1, maker, 1, _noRoutes(), 0, 0);
    }
}
