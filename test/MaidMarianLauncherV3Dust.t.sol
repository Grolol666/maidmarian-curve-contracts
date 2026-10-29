// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianEtfV4 } from "../src/MaidMarianEtfV4.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MaidMarianLaunchCurve as Curve, routesAtDue, CURVE_EXPLOSION } from "../src/MaidMarianLaunchCurve.sol";
import { TokenMock } from "./Mocks.sol";
import { CurveBase } from "./MaidMarianLaunchCurve.t.sol";

/// `routesAtDue` called from calldata, as the curve and the launcher call it.
contract RoutesAtDueHarness {
    function atDue(Etf etf, address holder, uint256 shares, Etf.Route[] calldata routes) external view returns (Etf.Route[] memory) {
        return routesAtDue(etf, holder, shares, routes);
    }
}

/**
 * Offline: no door hands its caller a leg or USDG he did not ask for. A buy pays the
 * tokens alone, the mint's refunds (the rounding of his routes against the fund's proportions) going to
 * the launcher's owner; a payout to USDG sells each routed leg's whole due, so nothing of a routed leg is
 * paid in kind; in kind only on the in-kind payout and a leg routed at 0. A last buy is bought whole.
 * The real launcher, curve, token, v4 factory and v4 ETF code (`_switchToV4`) over the curve suite's
 * mocks; the launcher's owner moved to `treasury` so its receipts are not mixed with the v4 factory's
 * owner's management fee. Proves the contracts against the mocks; the deployed v4, real pools and the
 * amounts on mCandles's legs are `MaidMarianLauncherV3Dust.fork.t.sol`.
 *
 *   forge test --match-contract MaidMarianLauncherV3DustTest -vv
 */
contract MaidMarianLauncherV3DustTest is CurveBase {
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    address internal treasury = makeAddr("treasury");

    function _useEtfFactory() internal override {
        _switchToV4();
    }

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        cf.transferOwnership(treasury);
        address[8] memory who = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            usdg.approve(address(cf), type(uint256).max);
        }
    }

    // ----------------------------------------------------------- helpers ---

    /// A reserve-ETF curve by `maker`, every holder's USDG and token approved to the curve and the launcher.
    function _etfCurve() internal returns (Etf etf, Curve curve) {
        (etf, curve) = _launchEtf(100);
        IERC20 token = _tok(curve);
        address[8] memory who = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            token.approve(address(cf), type(uint256).max);
        }
    }

    function _bondedEtfCurve() internal returns (Etf etf, Curve curve) {
        (etf, curve) = _etfCurve();
        _buyUsdg(curve, alice, 4000e6);
        _buyUsdg(curve, bob, 7000e6);
        assertTrue(curve.bonded());
    }

    /// USDG then the legs: every asset a reserve-ETF door may pay.
    function _assets(Etf etf) internal view returns (address[] memory out) {
        Etf.Leg[] memory legs = etf.legs();
        out = new address[](legs.length + 1);
        out[0] = address(usdg);
        for (uint256 i = 0; i < legs.length; i++) {
            out[i + 1] = legs[i].token;
        }
    }

    function _balances(address[] memory assets, address who) internal view returns (uint256[] memory out) {
        out = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            out[i] = IERC20(assets[i]).balanceOf(who);
        }
    }

    /// Redeem routes selling `bps` / 10 000 of each leg's due on a redeem of `shares` by `redeemer`, with
    /// the mock router's floor 0: a site's routes read from a preview, a little under or over the due.
    function _routesAt(Etf etf, address redeemer, uint256 shares, uint256 bps) internal view returns (Etf.Route[] memory) {
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(redeemer, shares);
        for (uint256 i = 0; i < due.length; i++) {
            due[i] = due[i] * bps / 10_000;
        }
        return _sellRoutes(etf, due);
    }

    /// The shares `sellAfterBond(tokensIn)` would sell now, read from a dry run reverted after.
    function _sharesForTokens(Etf etf, Curve curve, address who, uint256 tokensIn) internal returns (uint256 shares) {
        uint256 snap = vm.snapshotState();
        uint256 pool = etf.balanceOf(address(pm));
        Etf.Route[] memory zero = _sellRoutes(etf, new uint256[](etf.LEGS()));
        vm.prank(who);
        cf.sellAfterBond(address(curve), address(etf), tokensIn, 0, 2, zero, 0, 0);
        shares = pool - etf.balanceOf(address(pm));
        vm.revertToState(snap);
    }

    /// What the ETF paid `to` in the recorded logs, by `_assets` order: each `Redeemed`'s USDG and legs in
    /// kind, each `RedeemedInKind`'s legs and USDG. `routedInKind`: a `Redeemed` paid some leg in kind.
    function _etfPaid(Etf etf, Vm.Log[] memory logs, address to) internal pure returns (uint256[] memory paid, bool routedInKind) {
        uint256 n = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(etf) || logs[i].topics.length < 3 || address(uint160(uint256(logs[i].topics[2]))) != to) continue;
            uint256[] memory legs;
            uint256 usdgOut;
            if (logs[i].topics[0] == MaidMarianEtfV4.Redeemed.selector) {
                (, usdgOut,,,,,, legs) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256[]));
                for (uint256 j = 0; j < legs.length; j++) {
                    if (legs[j] > 0) routedInKind = true;
                }
            } else if (logs[i].topics[0] == MaidMarianEtfV4.RedeemedInKind.selector) {
                (,,,,,, legs, usdgOut,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256[], uint256, uint16));
            } else {
                continue;
            }
            if (paid.length == 0) {
                n = legs.length + 1;
                paid = new uint256[](n);
            }
            paid[0] += usdgOut;
            for (uint256 j = 0; j < legs.length; j++) {
                paid[j + 1] += legs[j];
            }
        }
    }

    /// `who`'s USDG and legs moved exactly by `usdgIn` out and what the ETF's redeems paid him, nothing else.
    function _assertMovedOnlyAsPromised(Etf etf, address who, uint256[] memory before, uint256 usdgIn, Vm.Log[] memory logs, bool inKindAllowed) internal view {
        _assertMovedOnlyAsPromised(etf, who, before, usdgIn, 0, logs, inKindAllowed);
    }

    /// The same, `usdgDirect` paid to him beside the ETF (a USDG pool's swap, a fee pot in USDG).
    function _assertMovedOnlyAsPromised(Etf etf, address who, uint256[] memory before, uint256 usdgIn, uint256 usdgDirect, Vm.Log[] memory logs, bool inKindAllowed) internal view {
        address[] memory assets = _assets(etf);
        uint256[] memory now_ = _balances(assets, who);
        (uint256[] memory paid, bool routedInKind) = _etfPaid(etf, logs, who);
        assertFalse(routedInKind, "a routed leg paid in kind");
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 expected = before[i] + (paid.length == 0 ? 0 : paid[i]) + (i == 0 ? usdgDirect : 0) - (i == 0 ? usdgIn : 0);
            assertEq(now_[i], expected, i == 0 ? "the caller's USDG moved beyond the door's promise" : "the caller's leg moved beyond the door's promise");
            if (!inKindAllowed && i > 0) assertEq(now_[i], before[i], "a leg reached the caller on a door that pays none");
        }
    }

    // ------------------------------------------------------- the buys ---

    /// A buy in USDG on the curve and through the launcher: the buyer's USDG falls by what he paid, he gets
    /// the tokens and not one wei of a leg or of USDG back; the mint's refunds (the routes' 1 % of USDG
    /// left, each leg's `received - used`) go to the launcher's owner; the curve and the launcher keep none.
    function test_ABuyInUsdgPaysTheTokensAloneAndTheMintsRefundsGoToTheOwner() public {
        (Etf etf, Curve curve) = _etfCurve();
        address[] memory assets = _assets(etf);
        for (uint256 k = 0; k < 2; k++) {
            uint256[] memory a0 = _balances(assets, alice);
            uint256[] memory t0 = _balances(assets, treasury);
            // Leg 1 bought 10 % short of its bps: it binds the mint, legs 0 and 2 bring more than the fund keeps.
            Etf.Route[] memory r = _buyRoutes(etf, 500e6, false);
            r[1].amountIn -= r[1].amountIn / 10;
            vm.prank(alice);
            uint256 out = k == 0 ? curve.buyWithUsdg(500e6, r, 1, 1, new Etf.Route[](0), 0) : cf.buyWithUsdg(address(curve), 500e6, r, 1, 1, new Etf.Route[](0), 0);
            assertGt(out, 0);
            uint256[] memory a1 = _balances(assets, alice);
            uint256[] memory t1 = _balances(assets, treasury);
            assertEq(a0[0] - a1[0], 500e6, "his USDG, exactly");
            for (uint256 i = 1; i < assets.length; i++) {
                assertEq(a1[i], a0[i], "no leg to the buyer");
            }
            assertGt(t1[0] - t0[0], 0, "the USDG the routes left, to the owner");
            uint256 legs;
            for (uint256 i = 1; i < assets.length; i++) {
                legs += t1[i] - t0[i];
            }
            assertGt(legs, 0, "the mint's leg refunds, to the owner");
            assertEq(_balances(assets, address(curve))[0] + _balances(assets, address(cf))[0], 0, "no USDG kept");
        }
    }

    /// After the bond, `buyAfterBond`: the tokens to the buyer, his USDG down by what he paid and no leg
    /// back; the mint's refunds to the owner; the launcher keeps none.
    function test_BuyAfterBondPaysTheTokensAloneAndTheRefundsGoToTheOwner() public {
        (Etf etf, Curve curve) = _bondedEtfCurve();
        address[] memory assets = _assets(etf);
        uint256[] memory a0 = _balances(assets, alice);
        uint256[] memory t0 = _balances(assets, treasury);
        Etf.Route[] memory r = _buyRoutes(etf, 500e6, false);
        vm.prank(alice);
        uint256 tokens = cf.buyAfterBond(address(curve), address(etf), 500e6, r, 1);
        assertGt(tokens, 0);
        uint256[] memory a1 = _balances(assets, alice);
        assertEq(a0[0] - a1[0], 500e6);
        for (uint256 i = 1; i < assets.length; i++) {
            assertEq(a1[i], a0[i], "no leg to the buyer");
        }
        assertGt(_balances(assets, treasury)[0], t0[0], "the routes' USDG left, to the owner");
        uint256[] memory held = _balances(assets, address(cf));
        for (uint256 i = 0; i < held.length; i++) {
            assertEq(held[i], 0, "the launcher keeps nothing");
        }
    }

    /// The last buy, past the curve's end, is bought whole: every share it minted stays in the curve, the
    /// buyer gets the tokens and nothing else (no redeem, no leg, his USDG down by exactly what he paid);
    /// the mint's refunds go to the owner.
    function test_ALastBuyIsBoughtWholeAndPaysTheTokensAlone() public {
        (Etf etf, Curve curve) = _etfCurve();
        _buyUsdg(curve, alice, 4000e6);
        uint256[] memory b0 = _balances(_assets(etf), bob);
        uint256 t0 = usdg.balanceOf(treasury);
        Etf.Route[] memory r = _buyRoutes(etf, 9000e6, false);
        vm.recordLogs();
        vm.prank(bob);
        curve.buyWithUsdg(9000e6, r, 1, 1, new Etf.Route[](0), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(curve.bonded());
        (uint256[] memory paid,) = _etfPaid(etf, logs, bob);
        assertEq(paid.length, 0, "no redeem to him");
        _assertMovedOnlyAsPromised(etf, bob, b0, 9000e6, logs, false);
        assertEq(etf.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees(), "every share booked");
        assertGt(usdg.balanceOf(treasury), t0, "the mint's USDG refund to the owner");
    }

    // ------------------------------------------------ payouts to USDG ---

    /// A sale to USDG with routes at 99.9 % of each due (a preview's margin) and at 100.1 % (over the due,
    /// which the ETF's `redeem` refuses as written): each runs at the due, the seller gets USDG and no leg.
    /// A leg routed at 0 is the one paid in kind, its whole due.
    function test_ASaleToUsdgSellsEveryRoutedLegWholeAndALegAtZeroInKind() public {
        (Etf etf, Curve curve) = _etfCurve();
        uint256 out = _buyUsdg(curve, alice, 2000e6);
        address[] memory assets = _assets(etf);
        uint256[2] memory bps = [uint256(9990), 10_010];
        for (uint256 k = 0; k < 2; k++) {
            (uint256 quoteOut,,) = curve.previewSell(out / 4);
            Etf.Route[] memory r = _routesAt(etf, address(curve), quoteOut, bps[k]);
            uint256[] memory a0 = _balances(assets, alice);
            vm.prank(alice);
            curve.sell(out / 4, 0, 2, r, 1, 0);
            uint256[] memory a1 = _balances(assets, alice);
            assertGt(a1[0], a0[0], "USDG to the seller");
            for (uint256 i = 1; i < assets.length; i++) {
                assertEq(a1[i], a0[i], "no remainder of a routed leg");
            }
        }
        (uint256 q,,) = curve.previewSell(out / 4);
        Etf.Route[] memory z = _routesAt(etf, address(curve), q, 9990);
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(address(curve), q);
        z[0].amountIn = 0;
        uint256 leg0 = IERC20(assets[1]).balanceOf(alice);
        vm.prank(alice);
        curve.sell(out / 4, 0, 2, z, 1, 0);
        assertEq(IERC20(assets[1]).balanceOf(alice) - leg0, due[0], "leg 0 routed at 0: its whole due in kind");
    }

    /// `routesAtDue` on a redeem's dues: a route under its due raised to it, one over lowered to it, each
    /// floor moved in the same proportion, rounded up (the price the seller wrote still binds); a route at 0
    /// stays 0; the routes' other fields untouched.
    function test_RoutesAtDueSetEveryRouteThatSellsToItsDueAndMoveItsFloorAlike() public {
        (Etf etf, Curve curve) = _etfCurve();
        _buyUsdg(curve, alice, 2000e6);
        uint256 shares = curve.realQuote() / 3;
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(address(curve), shares);
        Etf.Route[] memory r = _sellRoutes(etf, due);
        (r[0].amountIn, r[0].amountOutMin) = (due[0] / 2, 1001);
        (r[1].amountIn, r[1].amountOutMin) = (due[1] * 2, 999);
        (r[2].amountIn, r[2].amountOutMin) = (0, 7);
        RoutesAtDueHarness h = new RoutesAtDueHarness();
        Etf.Route[] memory got = h.atDue(etf, address(curve), shares, r);
        assertEq(got[0].amountIn, due[0]);
        assertEq(got[0].amountOutMin, Math.mulDiv(1001, due[0], due[0] / 2, Math.Rounding.Ceil), "the floor raised alike, rounded up");
        assertEq(got[1].amountIn, due[1]);
        assertEq(got[1].amountOutMin, Math.mulDiv(999, due[1], due[1] * 2, Math.Rounding.Ceil), "the floor lowered alike, rounded up");
        assertEq(got[2].amountIn, 0, "a route at 0 stays 0");
        assertEq(got[2].amountOutMin, 7);
        assertEq(got[0].deadline, r[0].deadline);
        assertTrue(got[0].sell);
    }

    /// Both fee claims to USDG, with routes at 99.9 % of the due: each claimant gets USDG and no leg.
    function test_AClaimToUsdgSellsEveryRoutedLegWhole() public {
        (Etf etf, Curve curve) = _etfCurve();
        _buyUsdg(curve, alice, 2000e6);
        address[] memory assets = _assets(etf);
        address[2] memory who = [maker, treasury];
        for (uint256 k = 0; k < 2; k++) {
            bool protocol = k == 1;
            uint256 amount = (protocol ? curve.protocolFees() : curve.creatorFees()) / 2;
            Etf.Route[] memory r = _routesAt(etf, address(curve), amount, 9990);
            uint256[] memory c0 = _balances(assets, who[k]);
            vm.recordLogs();
            vm.prank(who[k]);
            curve.claim(protocol, amount, who[k], 2, r, 1, 0);
            _assertMovedOnlyAsPromised(etf, who[k], c0, 0, vm.getRecordedLogs(), false);
            assertGt(usdg.balanceOf(who[k]), c0[0]);
        }
    }

    /// `sellAfterBond` to USDG with routes at 99.9 % of the due (a preview read a moment before): every
    /// leg sold whole, USDG to the seller, no leg.
    function test_SellAfterBondToUsdgSellsEveryRoutedLegWhole() public {
        (Etf etf, Curve curve) = _bondedEtfCurve();
        uint256 tokens = _tok(curve).balanceOf(alice) / 3;
        uint256 shares = _sharesForTokens(etf, curve, alice, tokens);
        Etf.Route[] memory r = _routesAt(etf, address(cf), shares, 9990);
        uint256[] memory a0 = _balances(_assets(etf), alice);
        vm.recordLogs();
        vm.prank(alice);
        uint256 usdgOut = cf.sellAfterBond(address(curve), address(etf), tokens, 0, 2, r, 1, 0);
        _assertMovedOnlyAsPromised(etf, alice, a0, 0, vm.getRecordedLogs(), false);
        assertEq(usdg.balanceOf(alice) - a0[0], usdgOut);
    }

    // -------------------------------------------------- every door, fuzzed ---

    /**
     * In every USDG cut (0, 25, 50, 75, 100 by the seed: the pool on the shares, on USDG, or both, each
     * after-bond door then taking one of the two by the door's draw) and in "ETF is seed" (a leg pool drawn
     * by each after-bond buy and sale, paid and paying in that leg alone), the launch with a fuzzed
     * seed (10 to 2 010 USDG), then 24 fuzzed doors - buys in USDG on the curve and through the launcher
     * (with bond routes, read only by a buy that bonds to USDG), sales in kind and to USDG, both fee claims
     * each way, `buyAfterBond`, `sellAfterBond` each way, a stranger's rebalance, the pool fee collection -
     * the routes to USDG at 99.9 % or 100.1 % of the due, time passing, the curve bonded half-way. After a
     * bond to USDG a sale, a claim and `sellAfterBond` pay USDG directly. After every door, two rules:
     *  - no share with a user, a fee receiver or the launcher (the curve, the ETF's `DEAD`, the PoolManager
     *    and the v4 factory's owner, by its management fee only, aside), the curve holding what it books
     *    (shares, or USDG once bonded to it);
     *  - the caller's (or the payee's) USDG and every leg move exactly by the USDG he put in, what the ETF's
     *    redeems paid him and the USDG a USDG pool or pot paid him, a payout to USDG paying no leg, a buy
     *    paying no leg.
     */
    function testFuzz_EveryDoorInEveryCutMovesTheCallersLegsAndUsdgOnlyAsItPromisesAndLeavesNoShare(uint256 seed) public {
        uint256 seedUsdg = 10e6 + seed % 2000e6;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint8 cut = seed % 6 == 5 ? CURVE_EXPLOSION : uint8(seed % 6 * 25);
        vm.prank(maker);
        (Etf etf, Curve curve) = cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 100, 1_000_000_000, seedUsdg, _seedRoutesFor(_legsAbc(), seedUsdg), 1, new address[](0), cut, _noRoutes(), 0
        );
        assertEq(curve.explodes(), cut == CURVE_EXPLOSION);
        _approveAll(curve, address(etf));
        IERC20 token = _tok(curve);
        address[8] memory all = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker];
        for (uint256 i = 0; i < all.length; i++) {
            vm.prank(all[i]);
            token.approve(address(cf), type(uint256).max);
        }
        vm.warp(vm.getBlockTimestamp() + 3);
        for (uint256 k = 0; k < 24; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            uint256 ownerBefore = etf.balanceOf(owner);
            (, uint256 pendingProtocol) = etf.pendingManagementFee();
            vm.recordLogs();
            if (k == 12 && !curve.bonded()) _door(etf, curve, holders[4], 0, 12_000e6);
            else _door(etf, curve, holders[r % 5], (r >> 8) % 9, r >> 16);
            _checkShares(etf, curve, ownerBefore, pendingProtocol);
            vm.warp(vm.getBlockTimestamp() + (r >> 128) % 3 days);
        }
        assertTrue(curve.bonded());
        if (curve.graduatesToUsdg()) {
            assertGe(usdg.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees());
        }
    }

    /// Bond routes selling 1 unit of every leg: `routesAtDue` raises each to its due when a buy bonds to USDG.
    function _anyBondRoutes(Etf etf) internal view returns (Etf.Route[] memory) {
        uint256[] memory one = new uint256[](etf.LEGS());
        for (uint256 i = 0; i < one.length; i++) {
            one[i] = 1;
        }
        return _sellRoutes(etf, one);
    }

    /// One door by `who` (`op` 0-1 buys, 2-3 sales, 4-5 claims, 6 rebalance, 7 pool fees, 8 a buy through
    /// the launcher), checked against its promise. `r` doubles as the USDG of a forced bonding buy.
    function _door(Etf etf, Curve curve, address who, uint256 op, uint256 r) internal {
        bool bonded = curve.bonded();
        if (bonded && curve.explodes() && (op <= 3 || op == 8)) return _legPoolDoor(etf, curve, who, op, r);
        bool feesInUsdg = bonded && curve.graduatesToUsdg();
        uint256 cut = curve.usdgCutPct();
        bool usdgPool = bonded && cut != 0 && (cut == 100 || r % 3 == 0);
        address[] memory assets = _assets(etf);
        uint256 usdgIn = r == 12_000e6 ? r : 1e6 + r % 1500e6;
        uint256 bps = r % 2 == 0 ? 9990 : 10_010;
        uint256 tokensIn = _tok(curve).balanceOf(who) * (1 + r % 100) / 100;
        if (op <= 1 || op == 8) {
            uint256[] memory b0 = _balances(assets, who);
            Etf.Route[] memory routes = _buyRoutes(etf, usdgIn, false);
            Etf.Route[] memory bondRoutes = _anyBondRoutes(etf);
            vm.getRecordedLogs();
            vm.prank(who);
            if (bonded) cf.buyAfterBond(address(curve), usdgPool ? address(usdg) : address(etf), usdgIn, routes, 1);
            else if (op == 0) curve.buyWithUsdg(usdgIn, routes, 1, 1, bondRoutes, 0);
            else cf.buyWithUsdg(address(curve), usdgIn, routes, 1, 1, bondRoutes, 0);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            _assertMovedOnlyAsPromised(etf, who, b0, usdgIn, logs, false);
            _replay(logs);
        } else if (op == 2 || op == 3) {
            if (tokensIn == 0) return;
            bool inKind = op == 2 && !usdgPool;
            Etf.Route[] memory routes;
            if (usdgPool) {
                routes = _noRoutes();
            } else if (bonded) {
                routes = inKind ? _sellRoutes(etf, new uint256[](etf.LEGS())) : _routesAt(etf, address(cf), _sharesForTokens(etf, curve, who, tokensIn), bps);
            } else {
                (uint256 quoteOut,,) = curve.previewSell(tokensIn);
                routes = inKind ? _noRoutes() : _routesAt(etf, address(curve), quoteOut, bps);
            }
            uint256[] memory b0 = _balances(assets, who);
            vm.getRecordedLogs();
            vm.prank(who);
            uint256 direct;
            if (bonded) direct = cf.sellAfterBond(address(curve), usdgPool ? address(usdg) : address(etf), tokensIn, 0, inKind ? 1 : 2, routes, 0, 0);
            else curve.sell(tokensIn, 0, inKind ? 1 : 2, routes, 0, 0);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            _assertMovedOnlyAsPromised(etf, who, b0, 0, usdgPool ? direct : 0, logs, inKind);
            _replay(logs);
        } else if (op == 4 || op == 5) {
            bool protocol = op == 5;
            address claimant = protocol ? treasury : maker;
            uint256 amount = (protocol ? curve.protocolFees() : curve.creatorFees() + curve.unbookedShares()) / 2;
            if (amount == 0) return;
            bool inKind = r % 3 == 0 && !feesInUsdg;
            Etf.Route[] memory routes = inKind || feesInUsdg ? _noRoutes() : _routesAt(etf, address(curve), amount, bps);
            uint256[] memory b0 = _balances(assets, claimant);
            vm.getRecordedLogs();
            vm.prank(claimant);
            curve.claim(protocol, amount, claimant, inKind ? 1 : 2, routes, 0, 0);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            _assertMovedOnlyAsPromised(etf, claimant, b0, 0, feesInUsdg ? amount : 0, logs, inKind);
            _replay(logs);
        } else if (op == 6) {
            vm.prank(carol);
            etf.rebalance(new Etf.Route[](0));
        } else if (bonded) {
            curve.collectPoolFees();
        }
    }

    /// After an "ETF is seed" bond, a buy or a sale in one of the leg pools (drawn by `r`) through the
    /// launcher: the caller's leg falls by exactly what he paid in (a buy) or rises by exactly what the pool
    /// paid (a sale), USDG and every other leg untouched.
    function _legPoolDoor(Etf etf, Curve curve, address who, uint256 op, uint256 r) internal {
        address[] memory pools = curve.bondPools();
        address leg = pools[r % pools.length];
        address[] memory assets = _assets(etf);
        uint256[] memory b0;
        int256 moved;
        vm.getRecordedLogs();
        if (op <= 1 || op == 8) {
            uint256 amount = 1e15 + r % 1e18;
            TokenMock(leg).mint(who, amount);
            b0 = _balances(assets, who);
            vm.startPrank(who);
            IERC20(leg).approve(address(cf), amount);
            cf.buyAfterBond(address(curve), leg, amount, _noRoutes(), 1);
            vm.stopPrank();
            // forge-lint: disable-next-line(unsafe-typecast)
            moved = -int256(amount);
        } else {
            uint256 tokensIn = _tok(curve).balanceOf(who) * (1 + r % 100) / 100;
            if (tokensIn == 0) return;
            b0 = _balances(assets, who);
            vm.prank(who);
            moved = int256(cf.sellAfterBond(address(curve), leg, tokensIn, 0, 1, _noRoutes(), 0, 0));
        }
        uint256[] memory now_ = _balances(assets, who);
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == leg) assertEq(int256(now_[i]), int256(b0[i]) + moved, "the leg moved by the trade alone");
            else assertEq(now_[i], b0[i], "nothing else moved");
        }
        _replay(vm.getRecordedLogs());
    }

    /// Puts `logs` back in the recorder for `_checkShares`, which reads the door's share transfers.
    Vm.Log[] internal _kept;

    function _replay(Vm.Log[] memory logs) internal {
        delete _kept;
        for (uint256 i = 0; i < logs.length; i++) {
            _kept.push(logs[i]);
        }
    }

    function _checkShares(Etf etf, Curve curve, uint256 ownerBefore, uint256 pendingProtocol) internal {
        Vm.Log[] memory fresh = vm.getRecordedLogs();
        for (uint256 j = 0; j < _kept.length + fresh.length; j++) {
            Vm.Log memory l = j < _kept.length ? _kept[j] : fresh[j - _kept.length];
            if (l.emitter != address(etf) || l.topics[0] != TRANSFER) continue;
            address to = address(uint160(uint256(l.topics[2])));
            if (to == address(curve) || to == etf.DEAD() || to == address(pm) || to == address(0) || to == owner) continue;
            assertEq(etf.balanceOf(to), 0, "a door left a share with someone");
        }
        delete _kept;
        address[11] memory who = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker, carol, treasury, address(cf)];
        for (uint256 i = 0; i < who.length; i++) {
            assertEq(etf.balanceOf(who[i]), 0, "a share outside the curve");
        }
        uint256 gained = etf.balanceOf(owner) - ownerBefore;
        assertTrue(gained == 0 || gained == pendingProtocol, "the factory's owner gained only the v4's management fee");
        if (curve.bonded() && curve.graduatesToUsdg()) {
            assertGe(usdg.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees(), "the curve holds what it books, in USDG");
            return;
        }
        uint256 booked = curve.creatorFees() + curve.protocolFees() + (curve.bonded() ? 0 : curve.realQuote());
        assertGe(etf.balanceOf(address(curve)), booked, "the curve holds what it books");
    }
}
