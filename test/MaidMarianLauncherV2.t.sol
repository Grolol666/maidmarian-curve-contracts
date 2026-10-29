// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianTokenLauncher as Launcher } from "../src/MaidMarianTokenLauncher.sol";
import { MaidMarianLaunchCurve as Curve, curveBuy } from "../src/MaidMarianLaunchCurve.sol";
import { UniversalRouterMock } from "./Mocks.sol";
import { CurveBase, CURVE_SUPPLY } from "./MaidMarianLaunchCurve.t.sol";

/**
 * Offline: no user and no fee receiver ever holds a reserve ETF's shares through the
 * launcher. The real launcher, curve, token, v4 factory and v4 ETF code (`_switchToV4`) over the curve
 * suite's mocks and the V4 PoolManager mock (`CurveFixtures.sol`). Each rule of the brief is a test
 * below, and one fuzzed sequence of every door checks the whole rule after each transaction. Proves the
 * contracts against the mocks; the deployed v4 factory, real pools and the real PoolManager are
 * `MaidMarianLauncherV2.fork.t.sol`.
 *
 * One holder stays outside the launcher's reach and is named where it shows: the v4 ETF mints its
 * protocol management fee (0.20 % a year) in shares to its factory's owner at each of its doors. That is
 * the deployed v4's own fee; the launcher cannot redirect it.
 *
 *   forge test --match-contract MaidMarianLauncherV2Test -vv
 */
contract MaidMarianLauncherV2Test is CurveBase {
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

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

    /// A reserve-ETF curve by `maker`, every holder's USDG approved to it and the launcher, his token to
    /// the launcher, the snipe tax past.
    function _etfCurve(uint16 tax) internal returns (Etf etf, Curve curve) {
        (etf, curve) = _launchEtf(tax);
        IERC20 token = _tok(curve);
        address[8] memory who = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            token.approve(address(cf), type(uint256).max);
        }
    }

    /// The same, bonded by two buys in USDG.
    function _bondedEtfCurve() internal returns (Etf etf, Curve curve) {
        (etf, curve) = _etfCurve(100);
        _buyUsdg(curve, alice, 4000e6);
        _buyUsdg(curve, bob, 7000e6);
        assertTrue(curve.bonded());
    }

    /// Routes of 0 on every leg: a redeem paid wholly in kind.
    function _zeroRoutes(Etf etf) internal view returns (Etf.Route[] memory r) {
        uint256[] memory zero = new uint256[](etf.LEGS());
        r = _sellRoutes(etf, zero);
    }

    /// What the launcher holds of every asset an ETF curve's doors touch, its allowances included.
    function _launcherHolds(Etf etf, Curve curve) internal view returns (uint256 total) {
        total = usdg.balanceOf(address(cf)) + IERC20(address(etf)).balanceOf(address(cf)) + _tok(curve).balanceOf(address(cf)) + a.balanceOf(address(cf)) + b.balanceOf(address(cf))
            + c.balanceOf(address(cf));
        total += usdg.allowance(address(cf), address(curve)) + usdg.allowance(address(cf), address(etf));
    }

    /// Every address of the suite but the curve, `DEAD` and the PoolManager: none holds a share.
    function _assertNoUserHoldsShares(Etf etf) internal view {
        address[10] memory who = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker, carol, address(cf)];
        for (uint256 i = 0; i < who.length; i++) {
            assertEq(etf.balanceOf(who[i]), 0, "a share outside the curve");
        }
    }

    /// The shares sold by `sellAfterBond(tokensIn)` now, read from a dry run reverted after.
    function _sharesForTokens(Etf etf, Curve curve, address who, uint256 tokensIn) internal returns (uint256 shares) {
        uint256 snap = vm.snapshotState();
        uint256 pool = etf.balanceOf(address(pm));
        Etf.Route[] memory zero = _zeroRoutes(etf);
        vm.prank(who);
        cf.sellAfterBond(address(curve), address(etf), tokensIn, 0, 2, zero, 0, 0);
        shares = pool - etf.balanceOf(address(pm));
        vm.revertToState(snap);
    }

    /// Redeem routes selling all of `shares`'s due on every leg, as the launcher would redeem them.
    function _usdgRoutes(Etf etf, address redeemer, uint256 shares) internal view returns (Etf.Route[] memory) {
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(redeemer, shares);
        return _sellRoutes(etf, due);
    }

    // ------------------------------------------------------ 1. the seed ---

    /// `launchWithEtf`'s 10 USDG are the creator's first buy: the curve's `buyWithUsdg` for him, in the launch.
    /// Its mint is the reserve ETF's first (9.99 shares, `DEAD_SHARES` locked), every other share minted
    /// lands in the curve's reserve and its `mintOf`; the creator gets the tokens of a buy at the curve's
    /// base price with the fee and his tax, no snipe tax; he holds no share, nor does the launcher, which
    /// is the ETF's creator for good and made the curve its fee recipient.
    function test_TheSeedIsTheCreatorsFirstBuyAndItsSharesLandInTheCurve() public {
        uint256 seedShares = 9.99e18 - 1e15;
        uint256 phantom = uint256(cf.etfThresholds()[0]) * 2 / 5;
        (uint256 expected, uint256 fee, uint256 tax, uint256 net) = curveBuy(phantom, CURVE_SUPPLY, seedShares, 75, 100);
        uint256 usdgBefore = usdg.balanceOf(maker);
        vm.expectEmit(true, false, false, true);
        emit Curve.Bought(maker, seedShares, SEED_USDG, expected, fee, tax, phantom + net, CURVE_SUPPLY - expected);
        (Etf etf, Curve curve) = _launchWithEtf("Robin Coin", "ROBIN", "", _noProfileC(), 100);
        assertEq(usdgBefore - usdg.balanceOf(maker), SEED_USDG, "his 10 USDG");
        assertEq(etf.totalSupply(), 9.99e18, "the ETF's first mint");
        assertEq(etf.balanceOf(etf.DEAD()), etf.DEAD_SHARES());
        assertEq(etf.balanceOf(address(curve)), seedShares, "the shares in the curve");
        assertEq(etf.mintOf(address(curve)), seedShares, "minted by the curve");
        assertEq(curve.realQuote() + curve.creatorFees() + curve.protocolFees(), seedShares, "booked: reserve and fees");
        assertEq(curve.protocolFees(), fee * 3000 / 10_000);
        assertEq(curve.creatorFees(), fee - fee * 3000 / 10_000 + tax);
        assertEq(fee, seedShares * 75 / 10_000, "0.75 %, no snipe tax");
        assertEq(_tok(curve).balanceOf(maker), expected, "his tokens");
        assertEq(etf.balanceOf(maker), 0, "no share");
        assertEq(etf.creator(), address(cf));
        assertEq(etf.feeRecipient(), address(curve));
        assertEq(_launcherHolds(etf, curve), 0, "the launcher holds nothing");
    }

    /// Without the 10 USDG approved, or with first-mint routes off the ETF's split, no launch.
    function test_ALaunchWithoutItsSeedDoesNotHappen() public {
        address poor = makeAddr("poor");
        vm.deal(poor, 1 ether);
        vm.prank(poor);
        vm.expectRevert();
        cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 0, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), 0, new Etf.Route[](0), 0
        );
        Etf.Route[] memory off = _seedRoutes(_legsAbc());
        off[0].amountIn -= 1;
        vm.prank(maker);
        vm.expectRevert();
        cf.launchWithEtf{ value: FEE }("Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 0, 1_000_000_000, SEED_USDG, off, 1, new address[](0), 0, new Etf.Route[](0), 0);
    }

    // ------------------------------------------------ 2. buy in USDG only ---

    /// Shares minted outside the launcher (straight on the ETF) cannot buy: the curve refuses them
    /// (`SharesStayInTheCurve`) on `buy` and on its launcher-only `buyFor`, the launcher's `buy` names the
    /// curve (`EtfCurveBuysInUsdg`); nothing is taken. A plain-quote curve buys as before.
    function test_AnEtfCurveRefusesSharesOnTheCurveAndOnTheLauncher() public {
        (Etf etf, Curve curve) = _etfCurve(0);
        vm.prank(alice);
        usdg.approve(address(etf), type(uint256).max);
        uint256 shares = _mint(etf, alice, 100e6);
        vm.startPrank(alice);
        etf.approve(address(curve), type(uint256).max);
        etf.approve(address(cf), type(uint256).max);
        vm.expectRevert(Curve.SharesStayInTheCurve.selector);
        curve.buy(shares, 0);
        vm.expectRevert(abi.encodeWithSelector(Launcher.EtfCurveBuysInUsdg.selector, address(curve)));
        cf.buy(address(curve), shares, 0);
        vm.stopPrank();
        vm.prank(address(cf));
        vm.expectRevert(Curve.SharesStayInTheCurve.selector);
        curve.buyFor(alice, shares, 0);
        assertEq(etf.balanceOf(alice), shares, "nothing taken");

        Curve plain = _launch(address(qt), 0);
        vm.prank(holders[0]);
        assertGt(plain.buy(100e18, 0), 0, "a plain quote buys in itself");
    }

    // ---------------------------------------- 3. sell for USDG, or in kind ---

    /// A sale is paid in kind or to USDG by the curve's own redeem; a sale for shares is refused
    /// (`SharesStayInTheCurve`), an unknown payout too (`BadPayout`). The seller ends with legs and USDG,
    /// no share. A plain quote still pays in itself and refuses a redeem (`BadPayout`).
    function test_ASaleIsPaidInKindOrInUsdgAndNeverInShares() public {
        (Etf etf, Curve curve) = _etfCurve(100);
        uint256 out = _buyUsdg(curve, alice, 2000e6);
        vm.startPrank(alice);
        vm.expectRevert(Curve.SharesStayInTheCurve.selector);
        curve.sell(out / 4, 0, 0, _noRoutes(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(Curve.BadPayout.selector, 3));
        curve.sell(out / 4, 0, 3, _noRoutes(), 0, 0);
        vm.stopPrank();

        (uint256 quoteOut,,) = curve.previewSell(out / 4);
        (,,, uint256[] memory amounts, uint256 usdgDue) = etf.previewRedeem(address(curve), quoteOut);
        uint256 aBefore = a.balanceOf(alice);
        uint256 uBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        curve.sell(out / 4, quoteOut, 1, _noRoutes(), 0, 0);
        assertEq(a.balanceOf(alice) - aBefore, amounts[0], "in kind: the leg's due");
        assertEq(usdg.balanceOf(alice) - uBefore, usdgDue, "and the USDG part");

        (quoteOut,,) = curve.previewSell(out / 4);
        Etf.Route[] memory sr = _usdgRoutes(etf, address(curve), quoteOut);
        uBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        curve.sell(out / 4, quoteOut, 2, sr, 1, 0);
        assertGt(usdg.balanceOf(alice), uBefore, "to USDG");
        _assertNoUserHoldsShares(etf);

        Curve plain = _launch(address(qt), 0);
        vm.prank(holders[0]);
        uint256 got = plain.buy(100e18, 0);
        vm.prank(holders[0]);
        vm.expectRevert(abi.encodeWithSelector(Curve.BadPayout.selector, 1));
        plain.sell(got, 0, 1, _noRoutes(), 0, 0);
    }

    /**
     * The way out in kind, and why it is kept. Leg a's pool is drained: it pays a millionth of a millionth
     * of a USDG for what it took, so a sale to USDG with a floor on that leg reverts
     * (`V3TooLittleReceived`), and without the in-kind door the holder could not leave while it lasts.
     * The sale in kind goes through (no router, no price): each leg's due and the USDG part, to the wei;
     * and a sale to USDG with leg a's route at 0 pays leg a in kind and sells the others.
     */
    function test_ASaleInKindIsTheWayOutWhenALegsPoolCannotSell() public {
        (Etf etf, Curve curve) = _etfCurve(0);
        uint256 out = _buyUsdg(curve, alice, 3000e6);
        (uint256 quoteOut,,) = curve.previewSell(out / 3);
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(address(curve), quoteOut);
        Etf.Route[] memory sr = _sellRoutes(etf, due);
        sr[0].amountOutMin = _out(address(a), address(usdg), due[0]) * 99 / 100;
        router.setPoolRate(address(a), address(usdg), false, 3000, 0, 1);
        vm.prank(alice);
        vm.expectRevert(UniversalRouterMock.V3TooLittleReceived.selector);
        curve.sell(out / 3, 0, 2, sr, 1, 0);

        (,,, uint256[] memory amounts, uint256 usdgDue) = etf.previewRedeem(address(curve), quoteOut);
        uint256[3] memory legsBefore = [a.balanceOf(alice), b.balanceOf(alice), c.balanceOf(alice)];
        uint256 uBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        curve.sell(out / 3, quoteOut, 1, _noRoutes(), 0, 0);
        assertEq(a.balanceOf(alice) - legsBefore[0], amounts[0], "leg a in kind");
        assertEq(b.balanceOf(alice) - legsBefore[1], amounts[1]);
        assertEq(c.balanceOf(alice) - legsBefore[2], amounts[2]);
        assertEq(usdg.balanceOf(alice) - uBefore, usdgDue);

        (quoteOut,,) = curve.previewSell(out / 3);
        (due,,,) = etf.previewRedeemToUsdg(address(curve), quoteOut);
        sr = _sellRoutes(etf, due);
        sr[0].amountIn = 0;
        uint256 aBefore = a.balanceOf(alice);
        vm.prank(alice);
        curve.sell(out / 3, quoteOut, 2, sr, 1, 0);
        assertEq(a.balanceOf(alice) - aBefore, due[0], "leg a in kind, the others sold");
        _assertNoUserHoldsShares(etf);
    }

    // ------------------------------------------- 4. fees in USDG or in kind ---

    /// The creator's and the protocol's claims on an ETF quote pay by the curve's redeem, in kind or to
    /// USDG; in shares they are refused (`SharesStayInTheCurve`). Every fee is claimed, to the last share,
    /// and no receiver holds a share.
    function test_FeeClaimsPayInKindOrInUsdgAndNeverInShares() public {
        (Etf etf, Curve curve) = _etfCurve(300);
        _buyUsdg(curve, alice, 2000e6);
        uint256 creatorFees = curve.creatorFees() + curve.unbookedShares();
        uint256 protocolFees = curve.protocolFees();
        vm.prank(maker);
        vm.expectRevert(Curve.SharesStayInTheCurve.selector);
        curve.claim(false, creatorFees, maker, 0, _noRoutes(), 0, 0);
        vm.prank(owner);
        vm.expectRevert(Curve.SharesStayInTheCurve.selector);
        curve.claim(true, protocolFees, owner, 0, _noRoutes(), 0, 0);

        vm.prank(maker);
        curve.claim(false, creatorFees / 2, carol, 1, _noRoutes(), 0, 0);
        assertGt(a.balanceOf(carol), 0, "in kind");
        uint256 rest = curve.creatorFees();
        Etf.Route[] memory sr = _usdgRoutes(etf, address(curve), rest);
        uint256 uBefore = usdg.balanceOf(maker);
        vm.prank(maker);
        curve.claim(false, rest, maker, 2, sr, 1, 0);
        assertGt(usdg.balanceOf(maker), uBefore, "to USDG");
        uint256 ownerShares = etf.balanceOf(owner);
        sr = _usdgRoutes(etf, address(curve), protocolFees);
        vm.prank(owner);
        curve.claim(true, protocolFees, owner, 2, sr, 1, 0);
        assertEq(curve.creatorFees() + curve.protocolFees(), 0, "all claimed");
        assertEq(etf.balanceOf(owner), ownerShares, "the protocol got no share from its claim");
        _assertNoUserHoldsShares(etf);
    }

    /**
     * The reserve ETF mints its management fee at each of its doors: the creator's 0.30 % a year to its
     * fee recipient, the curve, which books it to the creator's fees at its next door (`unbookedShares`),
     * claimed like any fee; a donation of shares to the curve is booked the same way. The protocol's
     * 0.20 % a year goes to the v4 factory's owner in shares: that is the deployed v4's own fee, which the
     * launcher cannot redirect, measured here to the share.
     */
    function test_TheReserveEtfsManagementFeeIsMintedToTheCurveAndBookedToTheCreator() public {
        (Etf etf, Curve curve) = _etfCurve(0);
        _buyUsdg(curve, alice, 1000e6);
        uint256 creatorFees0 = curve.creatorFees();
        uint256 curveShares0 = etf.balanceOf(address(curve));
        uint256 ownerShares0 = etf.balanceOf(owner);
        uint256 unbooked0 = curve.unbookedShares();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(curve.unbookedShares(), unbooked0, "nothing minted before a door of the ETF");
        (uint256 creatorPart, uint256 protocolPart) = etf.pendingManagementFee();
        assertGt(creatorPart, 0);
        vm.prank(carol);
        etf.rebalance(new Etf.Route[](0));
        assertEq(etf.balanceOf(address(curve)) - curveShares0, creatorPart, "the creator's part, to the curve");
        assertEq(curve.unbookedShares(), unbooked0 + creatorPart);
        assertEq(etf.balanceOf(owner) - ownerShares0, protocolPart, "the v4's own protocol fee, to its factory's owner");

        vm.prank(alice);
        usdg.approve(address(etf), type(uint256).max);
        uint256 gift = _mint(etf, alice, 10e6);
        vm.prank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        etf.transfer(address(curve), gift);
        assertEq(curve.unbookedShares(), unbooked0 + creatorPart + gift, "a donation of shares, booked the same way");

        uint256 all = creatorFees0 + unbooked0 + creatorPart + gift;
        vm.prank(maker);
        curve.claim(false, all, carol, 1, _noRoutes(), 0, 0);
        assertEq(curve.creatorFees(), 0);
        assertEq(curve.unbookedShares(), 0);
        assertEq(etf.balanceOf(carol), 0);
        assertGe(etf.balanceOf(address(curve)), curve.realQuote() + curve.protocolFees(), "the reserve still covered");
    }

    /// The bond's set-aside stays in the curve, booked to the protocol's fees, and pays no one; the pool
    /// holds 70 % of the real quote, the curve its fees and the set-aside; the owner then claims it like
    /// any fee, to USDG or in kind, no share.
    function test_TheBondsSetAsideIsBookedAndClaimedNotPaid() public {
        (Etf etf, Curve curve) = _bondedEtfCurve();
        assertEq(a.balanceOf(owner) + b.balanceOf(owner) + c.balanceOf(owner), 0, "no leg paid at the bond");
        uint256 real = curve.realQuote();
        assertApproxEqAbs(etf.balanceOf(address(pm)), real - real * 3000 / 10_000, 2 + curve.BOND_SWAP_QUOTE_UNITS(), "70 %, less the bond swap's output");
        assertEq(etf.balanceOf(address(pm)) + curve.bondSetAside(), real);
        assertEq(etf.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees());
        uint256 due = curve.protocolFees();
        Etf.Route[] memory sr = _usdgRoutes(etf, address(curve), due);
        address treasury = makeAddr("treasury");
        vm.prank(owner);
        curve.claim(true, due, treasury, 2, sr, 1, 0);
        assertGt(usdg.balanceOf(treasury), 0, "to USDG");
        assertEq(etf.balanceOf(treasury), 0, "no share");
        assertEq(curve.protocolFees(), 0);
        _assertNoUserHoldsShares(etf);
    }

    // ------------------------------------------------- 5. after the bond ---

    /// `buyAfterBond`: the caller's USDG, the reserve ETF's own `mint` to the launcher, every share swapped
    /// into the bond pool for the token, the tokens to him, the mint's refunds to the owner; the launcher ends
    /// with no share, no token, no leg, no USDG and no allowance. `minTokensOut` binds the whole trade.
    function test_BuyAfterBondMintsSwapsAndHandsTokensNotShares() public {
        (Etf etf, Curve curve) = _bondedEtfCurve();
        address buyer = holders[0];
        Etf.Route[] memory r = _buyRoutes(etf, 500e6, false);
        uint256 pool0 = etf.balanceOf(address(pm));
        uint256 usdg0 = usdg.balanceOf(buyer);
        vm.recordLogs();
        vm.prank(buyer);
        uint256 out = cf.buyAfterBond(address(curve), address(etf), 500e6, r, 1);
        uint256 shares = _boughtAfterBondShares(vm.getRecordedLogs());
        assertGt(out, 0);
        assertEq(_tok(curve).balanceOf(buyer), out, "the tokens to the buyer");
        assertEq(etf.balanceOf(address(pm)) - pool0, shares, "every share minted went into the pool");
        assertEq(usdg0 - usdg.balanceOf(buyer), 500e6, "his USDG to the wei: the mint's refund went to the owner");
        assertEq(_launcherHolds(etf, curve), 0, "the launcher holds nothing");
        _assertNoUserHoldsShares(etf);

        vm.prank(buyer);
        vm.expectPartialRevert(Launcher.TooFewTokens.selector);
        cf.buyAfterBond(address(curve), address(etf), 500e6, r, type(uint256).max);
    }

    /// `sellAfterBond`: the caller's tokens (approved to the launcher) swapped in the bond pool for shares,
    /// every share redeemed to him with his routes: USDG, and in kind a leg whose route is 0. The launcher
    /// ends with nothing; `minUsdgOut` binds.
    function test_SellAfterBondSwapsTheTokensAndRedeemsEveryShareToUsdg() public {
        (Etf etf, Curve curve) = _bondedEtfCurve();
        address seller = holders[1];
        Etf.Route[] memory br = _buyRoutes(etf, 1000e6, false);
        vm.prank(seller);
        uint256 tokens = cf.buyAfterBond(address(curve), address(etf), 1000e6, br, 1);
        uint256 shares = _sharesForTokens(etf, curve, seller, tokens / 2);
        Etf.Route[] memory sr = _usdgRoutes(etf, address(cf), shares);
        uint256 usdg0 = usdg.balanceOf(seller);
        vm.prank(seller);
        uint256 usdgOut = cf.sellAfterBond(address(curve), address(etf), tokens / 2, 0, 2, sr, 1, 0);
        assertEq(usdg.balanceOf(seller) - usdg0, usdgOut, "USDG to the seller");
        assertGt(usdgOut, 0);
        assertEq(_launcherHolds(etf, curve), 0);

        shares = _sharesForTokens(etf, curve, seller, tokens / 4);
        sr = _usdgRoutes(etf, address(cf), shares);
        uint256 dueA = sr[0].amountIn;
        sr[0].amountIn = 0;
        uint256 a0 = a.balanceOf(seller);
        vm.prank(seller);
        cf.sellAfterBond(address(curve), address(etf), tokens / 4, 0, 2, sr, 1, 0);
        assertEq(a.balanceOf(seller) - a0, dueA, "leg a in kind");
        assertEq(_launcherHolds(etf, curve), 0);
        _assertNoUserHoldsShares(etf);

        uint256 left = _tok(curve).balanceOf(seller);
        Etf.Route[] memory zero = _zeroRoutes(etf);
        vm.prank(seller);
        vm.expectPartialRevert(Etf.TooLittleOut.selector);
        cf.sellAfterBond(address(curve), address(etf), left, 0, 2, zero, type(uint256).max, 0);
    }

    /// The after-bond doors are an ETF curve's, after its bond: before it `NotBonded`, on a plain curve
    /// `NotEtfCurve`, on anything else `NotCurve`, nothing in `NothingIn`.
    function test_TheAfterBondDoorsAreABondedEtfCurvesOnly() public {
        (Etf etf, Curve curve) = _etfCurve(0);
        Etf.Route[] memory r = _buyRoutes(etf, 100e6, false);
        Etf.Route[] memory zero = _zeroRoutes(etf);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Launcher.NotBonded.selector, address(curve)));
        cf.buyAfterBond(address(curve), address(etf), 100e6, r, 1);
        vm.expectRevert(abi.encodeWithSelector(Launcher.NotBonded.selector, address(curve)));
        cf.sellAfterBond(address(curve), address(etf), 1, 0, 2, zero, 0, 0);
        vm.stopPrank();
        Curve plain = _launch(address(qt), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Launcher.NotEtfCurve.selector, address(plain)));
        cf.buyAfterBond(address(plain), address(etf), 100e6, r, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Launcher.NotCurve.selector, address(etf)));
        cf.sellAfterBond(address(etf), address(usdg), 1, 0, 2, zero, 0, 0);
        (Etf bondedEtf, Curve bonded) = _bondedEtfCurve();
        vm.prank(alice);
        vm.expectRevert(Launcher.NothingIn.selector);
        cf.sellAfterBond(address(bonded), address(bondedEtf), 0, 0, 2, zero, 0, 0);
    }

    /// The launcher's `unlockCallback` serves only the PoolManager inside its own swap: a stranger, and the
    /// PoolManager itself outside one, are refused (`NotPoolManager`).
    function test_OnlyThePoolManagerInsideTheLaunchersOwnSwapCallsBack() public {
        (, Curve curve) = _bondedEtfCurve();
        bytes memory data = abi.encode(curve.poolKey(), curve.token(), uint256(1), carol);
        vm.prank(carol);
        vm.expectRevert(Launcher.NotPoolManager.selector);
        cf.unlockCallback(data);
        vm.prank(address(pm));
        vm.expectRevert(Launcher.NotPoolManager.selector);
        cf.unlockCallback(data);
    }

    function _boughtAfterBondShares(Vm.Log[] memory logs) internal view returns (uint256 shares) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(cf) && logs[i].topics[0] == Launcher.BoughtAfterBond.selector) (,, shares,) = abi.decode(logs[i].data, (address, uint256, uint256, uint256));
        }
    }

    // -------------------------------------------------- every door, fuzzed ---

    /**
     * The launch with a fuzzed seed (10 to 2 010 USDG), then a fuzzed sequence of 24 doors - buys in USDG
     * on the curve and through the launcher, sales in kind and to USDG, both fee claims each way (the
     * protocol's with the bond's 30 % once bonded), the refused buys in shares (shares then given to the
     * curve), the ether doors (refused on an ETF curve), a stranger's rebalance, the pool fee collection,
     * `buyAfterBond`, `sellAfterBond` each way - with time passing between them, the curve bonded
     * half-way. After the launch and every transaction: no address that received a share in it holds one
     * unless it is the curve, the ETF's `DEAD` or the PoolManager, none of the suite's users, receivers or
     * the launcher holds one, the v4 factory's owner gained only the v4's own management fee (`0` or the
     * part `pendingManagementFee` gave before the transaction), and the curve holds at least what it books.
     */
    function testFuzz_NoDoorEverLeavesAShareWithAUserOrAFeeReceiver(uint256 seed) public {
        uint256 seedUsdg = 10e6 + seed % 2000e6;
        Etf.Route[] memory seedRoutes = _seedRoutesFor(_legsAbc(), seedUsdg);
        vm.recordLogs();
        vm.prank(maker);
        (Etf etf, Curve curve) = cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 100, 1_000_000_000, seedUsdg, seedRoutes, 1, new address[](0), 0, new Etf.Route[](0), 0
        );
        _checkShares(etf, curve, 0, 0);
        _approveAll(curve, address(etf));
        IERC20 token = _tok(curve);
        address[8] memory who = [holders[0], holders[1], holders[2], holders[3], holders[4], alice, bob, maker];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            token.approve(address(cf), type(uint256).max);
        }
        vm.warp(vm.getBlockTimestamp() + 3);
        vm.prank(carol);
        usdg.approve(address(etf), type(uint256).max);
        usdg.mint(carol, 1e12);
        vm.getRecordedLogs();
        for (uint256 k = 0; k < 24; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            uint256 ownerBefore = etf.balanceOf(owner);
            (, uint256 pendingProtocol) = etf.pendingManagementFee();
            if (k == 12 && !curve.bonded()) _buyUsdg(curve, holders[4], 12_000e6);
            else _door(etf, curve, holders[r % 5], (r >> 8) % 10, r >> 16);
            _checkShares(etf, curve, ownerBefore, pendingProtocol);
            vm.warp(vm.getBlockTimestamp() + (r >> 128) % 3 days);
        }
        assertTrue(curve.bonded());
    }

    function _door(Etf etf, Curve curve, address who, uint256 op, uint256 r) internal {
        bool bonded = curve.bonded();
        uint256 usdgIn = 1e6 + r % 1500e6;
        uint256 held = _tok(curve).balanceOf(who);
        uint256 tokensIn = held * (1 + r % 100) / 100;
        vm.getRecordedLogs();
        if (op == 0 || op == 1) {
            Etf.Route[] memory routes = _buyRoutes(etf, usdgIn, false);
            vm.prank(who);
            if (bonded) cf.buyAfterBond(address(curve), address(etf), usdgIn, routes, 1);
            else if (op == 0) curve.buyWithUsdg(usdgIn, routes, 1, 1, new Etf.Route[](0), 0);
            else cf.buyWithUsdg(address(curve), usdgIn, routes, 1, 1, new Etf.Route[](0), 0);
        } else if (op == 2 || op == 3) {
            if (tokensIn == 0) return;
            Etf.Route[] memory routes;
            if (bonded) {
                routes = op == 2 ? _zeroRoutes(etf) : _usdgRoutes(etf, address(cf), _sharesForTokens(etf, curve, who, tokensIn));
                vm.getRecordedLogs();
                vm.prank(who);
                cf.sellAfterBond(address(curve), address(etf), tokensIn, 0, 2, routes, 0, 0);
            } else {
                (uint256 quoteOut,,) = curve.previewSell(tokensIn);
                routes = op == 2 ? _noRoutes() : _usdgRoutes(etf, address(curve), quoteOut);
                vm.prank(who);
                curve.sell(tokensIn, 0, op == 2 ? 1 : 2, routes, 0, 0);
            }
        } else if (op == 4 || op == 5) {
            bool protocol = op == 5;
            uint256 amount = (protocol ? curve.protocolFees() : curve.creatorFees() + curve.unbookedShares()) / 2;
            if (amount == 0) return;
            bool inKind = r % 2 == 0;
            Etf.Route[] memory routes = inKind ? _noRoutes() : _usdgRoutes(etf, address(curve), amount);
            vm.prank(protocol ? owner : maker);
            curve.claim(protocol, amount, protocol ? owner : maker, inKind ? 1 : 2, routes, 0, 0);
        } else if (op == 6) {
            // Shares minted straight on the ETF, outside the launcher: refused by both buy doors, then
            // given to the curve, which books them to the creator.
            uint256 shares = _mint(etf, carol, usdgIn);
            vm.startPrank(carol);
            etf.approve(address(curve), shares);
            vm.expectRevert(Curve.SharesStayInTheCurve.selector);
            curve.buy(shares, 0);
            vm.expectRevert(abi.encodeWithSelector(Launcher.EtfCurveBuysInUsdg.selector, address(curve)));
            cf.buy(address(curve), shares, 0);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            etf.transfer(address(curve), shares);
            vm.stopPrank();
        } else if (op == 7) {
            vm.prank(carol);
            etf.rebalance(new Etf.Route[](0));
        } else if (op == 9) {
            vm.deal(who, 1 ether);
            vm.startPrank(who);
            vm.expectRevert(abi.encodeWithSelector(Launcher.EtfCurveBuysInUsdg.selector, address(curve)));
            cf.buy{ value: 1 }(address(curve), 1, 0);
            vm.expectRevert(abi.encodeWithSelector(Launcher.NotWethQuote.selector, address(etf)));
            cf.sellForEth(address(curve), 1, 0);
            vm.expectRevert(abi.encodeWithSelector(Launcher.NotWethQuote.selector, address(etf)));
            cf.claimInEth(address(curve), false, 1, who);
            vm.stopPrank();
        } else if (bonded) {
            curve.collectPoolFees();
        }
    }

    function _checkShares(Etf etf, Curve curve, uint256 ownerBefore, uint256 pendingProtocol) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(etf) || logs[i].topics[0] != TRANSFER) continue;
            address to = address(uint160(uint256(logs[i].topics[2])));
            if (to == address(curve) || to == etf.DEAD() || to == address(pm) || to == address(0) || to == owner) continue;
            assertEq(etf.balanceOf(to), 0, "a door left a share with someone");
        }
        _assertNoUserHoldsShares(etf);
        uint256 gained = etf.balanceOf(owner) - ownerBefore;
        assertTrue(gained == 0 || gained == pendingProtocol, "the factory's owner gained only the v4's management fee");
        uint256 booked = curve.creatorFees() + curve.protocolFees() + (curve.bonded() ? 0 : curve.realQuote());
        assertGe(etf.balanceOf(address(curve)), booked, "the curve holds what it books");
    }

    // ------------------------------------------------------------- gas ---

    /// Every door of a reserve-ETF curve on three legs, measured with `gasleft()` around the call: the
    /// launch with its seed buy, both buys in USDG, both sales, both claims each way, and the two
    /// after-bond doors. Each under 5 M.
    function test_Gas_EveryDoorOfAReserveEtfCurve() public {
        vm.prank(maker);
        uint256 g = gasleft();
        (Etf etf, Curve curve) = cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 100, 1_000_000_000, SEED_USDG, _seedRoutes(_legsAbc()), 1, new address[](0), 0, new Etf.Route[](0), 0
        );
        _log("launchWithEtf, 3 legs, its seed buy", g - gasleft());
        _approveAll(curve, address(etf));
        IERC20 token = _tok(curve);
        vm.prank(alice);
        token.approve(address(cf), type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 3);
        Etf.Route[] memory r = _buyRoutes(etf, 500e6, false);
        vm.prank(alice);
        g = gasleft();
        uint256 out = curve.buyWithUsdg(500e6, r, 1, 1, new Etf.Route[](0), 0);
        _log("curve.buyWithUsdg", g - gasleft());
        r = _buyRoutes(etf, 500e6, false);
        vm.prank(alice);
        g = gasleft();
        out += cf.buyWithUsdg(address(curve), 500e6, r, 1, 1, new Etf.Route[](0), 0);
        _log("launcher.buyWithUsdg", g - gasleft());
        vm.prank(alice);
        g = gasleft();
        curve.sell(out / 4, 0, 1, _noRoutes(), 0, 0);
        _log("sell in kind", g - gasleft());
        (uint256 quoteOut,,) = curve.previewSell(out / 4);
        Etf.Route[] memory sr = _usdgRoutes(etf, address(curve), quoteOut);
        vm.prank(alice);
        g = gasleft();
        curve.sell(out / 4, 0, 2, sr, 1, 0);
        _log("sell to USDG", g - gasleft());
        uint256 fees = curve.creatorFees() / 2;
        vm.prank(maker);
        g = gasleft();
        curve.claim(false, fees, maker, 1, _noRoutes(), 0, 0);
        _log("claim in kind", g - gasleft());
        sr = _usdgRoutes(etf, address(curve), fees);
        vm.prank(maker);
        g = gasleft();
        curve.claim(false, fees, maker, 2, sr, 1, 0);
        _log("claim to USDG", g - gasleft());
        _buyUsdg(curve, bob, 11_000e6);
        assertTrue(curve.bonded());
        r = _buyRoutes(etf, 500e6, false);
        vm.prank(alice);
        g = gasleft();
        uint256 tokens = cf.buyAfterBond(address(curve), address(etf), 500e6, r, 1);
        _log("buyAfterBond", g - gasleft());
        uint256 shares = _sharesForTokens(etf, curve, alice, tokens);
        sr = _usdgRoutes(etf, address(cf), shares);
        vm.prank(alice);
        g = gasleft();
        cf.sellAfterBond(address(curve), address(etf), tokens, 0, 2, sr, 1, 0);
        _log("sellAfterBond to USDG", g - gasleft());
        Etf.Route[] memory zero = _zeroRoutes(etf);
        uint256 rest = _tok(curve).balanceOf(alice) / 2;
        vm.prank(alice);
        g = gasleft();
        cf.sellAfterBond(address(curve), address(etf), rest, 0, 1, zero, 0, 0);
        _log("sellAfterBond in kind", g - gasleft());
    }

    function _log(string memory what, uint256 gasUsed) internal {
        emit log_named_uint(what, gasUsed);
        assertLt(gasUsed, 5_000_000, what);
    }
}
