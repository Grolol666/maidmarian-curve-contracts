// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { oneThreshold } from "./CurveFixtures.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianTokenLauncher as Launcher } from "../src/MaidMarianTokenLauncher.sol";
import { MaidMarianLaunchCurve as Curve, curveBuy } from "../src/MaidMarianLaunchCurve.sol";
import { CurveBase, CURVE_SUPPLY, CURVE_RESERVED } from "./MaidMarianLaunchCurve.t.sol";

/// A holder that cannot receive ether: no `receive`, no `fallback`.
contract NoReceive {
    function sellForEth(Launcher launcher, address curve, uint256 tokensIn) external returns (bool ok, bytes memory ret) {
        IERC20(Curve(curve).token()).approve(address(launcher), tokensIn);
        (ok, ret) = address(launcher).call(abi.encodeCall(Launcher.sellForEth, (curve, tokensIn, 0)));
    }

    function sellForWeth(Curve curve, uint256 tokensIn) external returns (uint256) {
        IERC20(curve.token()).approve(address(curve), tokensIn);
        return curve.sell(tokensIn, 0, curve.PAY_QUOTE(), new Etf.Route[](0), 0, 0);
    }
}

/// A holder whose `receive` tries the launcher's ether doors again, and a curve sale, while it is paid.
contract Reenterer {
    Launcher internal immutable LAUNCHER;
    Curve internal immutable CURVE;
    bool public reentryOk;
    bytes public reentryRet;
    uint256 public curveSaleOut;
    uint256 public received;

    constructor(Launcher launcher, Curve curve) {
        (LAUNCHER, CURVE) = (launcher, curve);
    }

    function sellForEth(uint256 tokensIn) external returns (uint256) {
        IERC20(CURVE.token()).approve(address(LAUNCHER), type(uint256).max);
        IERC20(CURVE.token()).approve(address(CURVE), type(uint256).max);
        return LAUNCHER.sellForEth(address(CURVE), tokensIn, 0);
    }

    receive() external payable {
        if (msg.sender != address(LAUNCHER)) return;
        received += msg.value;
        (reentryOk, reentryRet) = address(LAUNCHER).call(abi.encodeCall(Launcher.sellForEth, (address(CURVE), 1e18, 0)));
        curveSaleOut = CURVE.sell(1e18, 0, CURVE.PAY_QUOTE(), new Etf.Route[](0), 0, 0);
    }
}

/**
 * The launcher's scenario changes, offline: the creator's first buys (`launchWithEtf`'s seed of 10 USDG or
 * more, `launchWithToken`'s compulsory first buy at the owner's minimum per quote), ether on a WETH curve
 * (bought with it, sold and claimed in it), and the bond's 30 % booked to the protocol's fees in the
 * curve. The real launcher, curve, token, v4 factory and v4 ETF code (`_switchToV4`) over the curve
 * suite's mocks, wrapped ether a mock with WETH's `deposit` / `withdraw`. Proves the contracts against
 * the mocks; the deployed v4, the chain's WETH and the real pools are `MaidMarianLauncherScenarios.fork.t.sol`.
 *
 *   forge test --match-contract MaidMarianLauncherScenariosTest -vv
 */
contract MaidMarianLauncherScenariosTest is CurveBase {
    function _useEtfFactory() internal override {
        _switchToV4();
    }

    function setUp() public override {
        super.setUp();
        address[3] memory who = [alice, bob, carol];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            usdg.approve(address(cf), type(uint256).max);
            vm.deal(who[i], 100 ether);
        }
        usdg.mint(carol, 1e12);
    }

    // ----------------------------------------------------------- helpers ---

    /// `launchWithEtf` by `maker` with a seed of `seedUsdg`, on a, b, c.
    function _launchEtfSeed(uint256 seedUsdg, uint16 tax) internal returns (Etf etf, Curve curve) {
        vm.prank(maker);
        (etf, curve) = cf.launchWithEtf{ value: FEE }(
            "Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, tax, 1_000_000_000, seedUsdg, _seedRoutesFor(_legsAbc(), seedUsdg), 1, new address[](0), 0, new Etf.Route[](0), 0
        );
    }

    /// A WETH curve by `maker`, its first buy of 0.002 WETH paid in ether, the snipe tax past.
    function _wethCurve(uint16 tax) internal returns (Curve curve) {
        vm.prank(maker);
        curve = cf.launchWithToken{ value: LAUNCH_FEE + WETH_FIRST_BUY }("Robin Coin", "ROBIN", "", _noProfileC(), address(weth), 4.2e18, tax, 1_000_000_000, WETH_FIRST_BUY, new address[](0));
        vm.warp(vm.getBlockTimestamp() + 3);
    }

    /// What the launcher holds of the WETH curve's assets, ether beyond its launch fees included.
    function _launcherHoldsWeth(Curve curve, uint256 fees) internal view returns (uint256) {
        return weth.balanceOf(address(cf)) + _tok(curve).balanceOf(address(cf)) + (address(cf).balance - fees) + weth.allowance(address(cf), address(curve));
    }

    function _zeroRoutes(Etf etf) internal view returns (Etf.Route[] memory r) {
        uint256[] memory zero = new uint256[](etf.LEGS());
        r = _sellRoutes(etf, zero);
    }

    // ---------------------------------------- 1. launchWithEtf's first buy ---

    /// A seed of 1 000 USDG: one mint of the whole seed, the reserve ETF's first (999 shares, `DEAD_SHARES`
    /// locked), the routes the caller's, `firstMintSplit(1 000 USDG)`; one curve buy of every share minted
    /// from the base price for the creator, 0.75 % and his tax, no snipe tax; he holds the tokens and no
    /// share, the launcher nothing.
    function test_ASeedOfAThousandUsdgIsOneFirstMintAndOneBuyFromTheBasePrice() public {
        uint256 seedUsdg = 1000e6;
        uint256 shares = 999e18 - 1e15;
        uint256 phantom = uint256(cf.etfThresholds()[0]) * 2 / 5;
        (uint256 expected, uint256 fee, uint256 tax, uint256 net) = curveBuy(phantom, CURVE_SUPPLY, shares, 75, 100);
        uint256 usdgBefore = usdg.balanceOf(maker);
        vm.expectEmit(true, false, false, true);
        emit Curve.Bought(maker, shares, seedUsdg, expected, fee, tax, phantom + net, CURVE_SUPPLY - expected);
        (Etf etf, Curve curve) = _launchEtfSeed(seedUsdg, 100);
        assertEq(usdgBefore - usdg.balanceOf(maker), seedUsdg, "his 1 000 USDG");
        assertEq(etf.totalSupply(), 999e18, "one first mint of the whole seed, one share per USDG kept");
        assertEq(etf.balanceOf(address(curve)), shares, "every share in the curve");
        assertEq(fee, shares * 75 / 10_000, "0.75 %, no snipe tax");
        assertEq(_tok(curve).balanceOf(maker), expected, "his tokens, one buy from the base price");
        assertEq(etf.balanceOf(maker), 0, "no share");
        assertEq(curve.realQuote() + curve.creatorFees() + curve.protocolFees(), shares);
        assertEq(usdg.balanceOf(address(cf)) + etf.balanceOf(address(cf)) + a.balanceOf(address(cf)), 0, "the launcher holds nothing");
        assertFalse(curve.bonded());
    }

    /// Under `MIN_ETF_SEED_USDG` (10 USDG) the launch is refused by name, before anything is created; 10
    /// USDG exactly is the least seed.
    function test_ASeedUnderTenUsdgIsRefused() public {
        assertEq(cf.MIN_ETF_SEED_USDG(), 10e6);
        Etf.Route[] memory r = _seedRoutesFor(_legsAbc(), 10e6 - 1);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Launcher.SeedTooSmall.selector, 10e6 - 1, 10e6));
        cf.launchWithEtf{ value: FEE }("Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 0, 1_000_000_000, 10e6 - 1, r, 1, new address[](0), 0, new Etf.Route[](0), 0);
        assertEq(cf.curveCount(), 0);
        (Etf etf,) = _launchEtfSeed(10e6, 0);
        assertEq(etf.totalSupply(), 9.99e18);
    }

    /// A seed past the threshold bonds the curve in the launch: the whole seed is minted and every share
    /// bought, past the curve's end (no leg, no USDG, no share back to the creator), the pool opened, the
    /// 30 % booked to the protocol's fees.
    function test_ASeedPastTheThresholdBondsInTheLaunch() public {
        uint256 aBefore = a.balanceOf(maker);
        uint256 usdgBefore = usdg.balanceOf(maker);
        (Etf etf, Curve curve) = _launchEtfSeed(13_000e6, 0);
        assertTrue(curve.bonded());
        assertEq(etf.balanceOf(maker), 0, "no share");
        assertEq(a.balanceOf(maker), aBefore, "no leg");
        assertEq(usdgBefore - usdg.balanceOf(maker), 13_000e6, "his seed, whole");
        assertGt(curve.bondSetAside(), 0);
        assertEq(etf.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees());
        uint256 shares = etf.totalSupply() - etf.DEAD_SHARES();
        (uint256 expected,,,) = curveBuy(uint256(cf.etfThresholds()[0]) * 2 / 5, CURVE_SUPPLY, shares, 75, 0);
        assertEq(_tok(curve).balanceOf(maker), expected, "every share bought, one buy from the base price");
        assertGt(expected, CURVE_SUPPLY - CURVE_RESERVED, "past the curve's end");
    }

    // ---------------------------------------- 2. launchWithToken's first buy ---

    /// `launchWithToken` makes the creator's first buy in the launch: one curve buy from the base price, no
    /// snipe tax at second 0, the fee and his tax as any buy, his USDG pulled (approved to the launcher),
    /// the tokens his; a larger first buy is the same one buy.
    function test_LaunchWithTokenMakesTheCreatorsFirstBuyFromTheBasePrice() public {
        uint256[2] memory amounts = [USDG_FIRST_BUY, 1000e6];
        for (uint256 k = 0; k < 2; k++) {
            uint256 phantom = uint256(8000e6) * 2 / 5;
            (uint256 expected, uint256 fee, uint256 tax, uint256 net) = curveBuy(phantom, CURVE_SUPPLY, amounts[k], 75, 100);
            uint256 before = usdg.balanceOf(maker);
            vm.expectEmit(true, false, false, true);
            emit Curve.Bought(maker, amounts[k], 0, expected, fee, tax, phantom + net, CURVE_SUPPLY - expected);
            vm.prank(maker);
            Curve curve = cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(usdg), 8000e6, 100, 1_000_000_000, amounts[k], new address[](0));
            assertEq(before - usdg.balanceOf(maker), amounts[k]);
            assertEq(_tok(curve).balanceOf(maker), expected);
            assertEq(fee, amounts[k] * 75 / 10_000, "no snipe tax");
            assertEq(usdg.balanceOf(address(curve)), curve.realQuote() + curve.creatorFees() + curve.protocolFees());
            assertEq(usdg.balanceOf(address(cf)), 0);
        }
    }

    /// Under the quote's minimum the launch is refused by name; the minimum is the owner's, per quote, set
    /// with the listing (1 to the threshold), kept through a delisting, in `QuoteSet`.
    function test_TheFirstBuyIsAtLeastTheMinimumTheOwnerSetsWithTheListing() public {
        assertEq(cf.quoteMinFirstBuy(address(usdg)), 5e6);
        assertEq(cf.quoteMinFirstBuy(address(weth)), 0.002e18);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Launcher.FirstBuyTooSmall.selector, 5e6 - 1, 5e6));
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(usdg), 8000e6, 0, 1_000_000_000, 5e6 - 1, new address[](0));
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(Launcher.BadMinFirstBuy.selector, 0));
        cf.setTokenQuote(address(usdg), true, false, oneThreshold(8000e6), 0);
        vm.expectRevert(abi.encodeWithSelector(Launcher.BadMinFirstBuy.selector, 8000e6 + 1));
        cf.setTokenQuote(address(usdg), true, false, oneThreshold(8000e6), 8000e6 + 1);
        vm.expectEmit(address(cf));
        emit Launcher.QuoteSet(address(usdg), address(0), oneThreshold(8000e6), 20e6);
        cf.setTokenQuote(address(usdg), true, false, oneThreshold(8000e6), 20e6);
        vm.stopPrank();
        assertEq(cf.quoteMinFirstBuy(address(usdg)), 20e6);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Launcher.FirstBuyTooSmall.selector, 5e6, 20e6));
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(usdg), 8000e6, 0, 1_000_000_000, 5e6, new address[](0));
        vm.prank(alice);
        vm.expectRevert();
        cf.setTokenQuote(address(usdg), true, false, oneThreshold(8000e6), 1);
    }

    /// A first buy past the threshold is bought whole and bonds the curve in the launch: the creator pays
    /// all of it, no change, and the launcher keeps nothing.
    function test_AFirstBuyPastTheThresholdIsBoughtWholeAndBonds() public {
        uint256 before = usdg.balanceOf(maker);
        vm.prank(maker);
        Curve curve = cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(usdg), 8000e6, 0, 1_000_000_000, 20_000e6, new address[](0));
        assertTrue(curve.bonded());
        uint256 paid = before - usdg.balanceOf(maker);
        assertEq(paid, 20_000e6, "all of it, no change");
        assertEq(paid, usdg.balanceOf(address(curve)) + usdg.balanceOf(address(pm)), "the curve's fees and set-aside, the pool's 70 %");
        assertEq(usdg.balanceOf(address(cf)), 0);
    }

    // ------------------------------------------------- 3. ether on WETH ---

    /// A WETH curve's launch takes the launch fee and the first buy in one `msg.value`: `launchFee()`
    /// stays in the launcher, exactly `firstBuy` is wrapped and bought with; or the fee alone in ether and
    /// the first buy pulled in WETH. Any other split is refused by name: under the fee `WrongLaunchFee`,
    /// ether that is not the first buy `WrongValue`, ether on a USDG launch `NotWethQuote`.
    function test_AWethLaunchTakesTheFeeAndTheFirstBuyInEther() public {
        uint256 ethBefore = maker.balance;
        Curve curve = _wethCurve(0);
        assertEq(ethBefore - maker.balance, LAUNCH_FEE + WETH_FIRST_BUY);
        assertEq(address(cf).balance, LAUNCH_FEE, "the fee stays, the first buy is wrapped");
        assertEq(weth.balanceOf(address(curve)), WETH_FIRST_BUY);
        assertGt(_tok(curve).balanceOf(maker), 0);
        assertEq(weth.balanceOf(address(cf)), 0);

        weth.mint(maker, 1e18);
        vm.prank(maker);
        weth.approve(address(cf), type(uint256).max);
        vm.prank(maker);
        Curve pulled = cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(weth), 4.2e18, 0, 1_000_000_000, WETH_FIRST_BUY, new address[](0));
        assertEq(weth.balanceOf(address(pulled)), WETH_FIRST_BUY, "pulled in WETH");
        assertEq(weth.balanceOf(maker), 1e18 - WETH_FIRST_BUY);

        vm.startPrank(maker);
        vm.expectRevert(abi.encodeWithSelector(Launcher.WrongLaunchFee.selector, LAUNCH_FEE, LAUNCH_FEE - 1));
        cf.launchWithToken{ value: LAUNCH_FEE - 1 }("Robin Coin", "ROBIN", "", _noProfileC(), address(weth), 4.2e18, 0, 1_000_000_000, WETH_FIRST_BUY, new address[](0));
        vm.expectRevert(abi.encodeWithSelector(Launcher.WrongValue.selector, WETH_FIRST_BUY, 0.001e18));
        cf.launchWithToken{ value: LAUNCH_FEE + 0.001e18 }("Robin Coin", "ROBIN", "", _noProfileC(), address(weth), 4.2e18, 0, 1_000_000_000, WETH_FIRST_BUY, new address[](0));
        vm.expectRevert(abi.encodeWithSelector(Launcher.NotWethQuote.selector, address(usdg)));
        cf.launchWithToken{ value: LAUNCH_FEE + 5e6 }("Robin Coin", "ROBIN", "", _noProfileC(), address(usdg), 8000e6, 0, 1_000_000_000, 5e6, new address[](0));
        vm.stopPrank();
    }

    /// `buy` on a WETH curve with ether: `msg.value` is `quoteIn`, wrapped and bought with for the caller
    /// (`Bought` his), the tokens as a WETH buy gives them; ether that differs is `WrongValue`, ether on a
    /// curve of another quote `NotWethQuote`. The launcher keeps nothing.
    function test_AWethCurveIsBoughtWithEther() public {
        Curve curve = _wethCurve(100);
        (uint256 expected,,) = curve.previewBuy(1e18, alice);
        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 out = cf.buy{ value: 1e18 }(address(curve), 1e18, expected);
        assertEq(out, expected);
        assertEq(_tok(curve).balanceOf(alice), out);
        assertEq(before - alice.balance, 1e18);
        assertEq(_launcherHoldsWeth(curve, LAUNCH_FEE), 0);
        assertEq(weth.balanceOf(address(curve)), curve.realQuote() + curve.creatorFees() + curve.protocolFees());

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Launcher.WrongValue.selector, 1e18, 1e18 - 1));
        cf.buy{ value: 1e18 - 1 }(address(curve), 1e18, 0);
        vm.stopPrank();
        Curve onUsdg = _launch(address(usdg), 0);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Launcher.NotWethQuote.selector, address(usdg)));
        cf.buy{ value: 1e6 }(address(onUsdg), 1e6, 0);
        vm.stopPrank();
    }

    /// The last buy in ether is bought whole, past the curve's end: the caller pays all his ether and gets
    /// the previewed tokens, the curve bonds, the launcher keeps no WETH and no ether.
    function test_ALastBuyInEtherIsBoughtWhole() public {
        Curve curve = _wethCurve(0);
        (uint256 expected,,) = curve.previewBuy(6e18, bob);
        uint256 before = bob.balance;
        vm.prank(bob);
        uint256 out = cf.buy{ value: 6e18 }(address(curve), 6e18, 0);
        assertTrue(curve.bonded());
        assertEq(out, expected);
        assertEq(before - bob.balance, 6e18, "all his ether, no change");
        assertEq(_launcherHoldsWeth(curve, LAUNCH_FEE), 0);
    }

    /// `sellForEth`: refused without the holder's approve to the launcher (`ERC20InsufficientAllowance`); with it
    /// the launcher pulls his tokens, the curve pays it in WETH, the launcher unwraps it and sends him the ether in the same
    /// call: what `previewSell` says, `Sold` his; `minEthOut` binds (`TooLittleQuote`).
    function test_ASaleOnAWethCurveIsPaidInEtherAfterItsApprove() public {
        Curve curve = _wethCurve(100);
        vm.prank(alice);
        uint256 tokens = cf.buy{ value: 2e18 }(address(curve), 2e18, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(cf), 0, tokens / 2));
        cf.sellForEth(address(curve), tokens / 2, 0);
        vm.startPrank(alice);
        _tok(curve).approve(address(cf), type(uint256).max);
        vm.stopPrank();
        (uint256 quoteOut, uint256 fee, uint256 tax) = curve.previewSell(tokens / 2);
        (uint256 q, uint256 t) = curve.getReserves();
        uint256 before = alice.balance;
        vm.expectEmit(address(curve));
        emit Curve.Sold(alice, tokens / 2, quoteOut, 0, fee, tax, q - quoteOut - fee - tax, t + tokens / 2);
        vm.prank(alice);
        uint256 ethOut = cf.sellForEth(address(curve), tokens / 2, quoteOut);
        assertEq(ethOut, quoteOut);
        assertEq(alice.balance - before, quoteOut, "paid in ether");
        assertEq(_launcherHoldsWeth(curve, LAUNCH_FEE), 0);
        (quoteOut,,) = curve.previewSell(tokens / 4);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Curve.TooLittleQuote.selector, quoteOut, quoteOut + 1));
        cf.sellForEth(address(curve), tokens / 4, quoteOut + 1);
    }

    /// A seller that cannot receive ether is refused by name (`NativeTransferFailed`), his tokens untouched;
    /// he sells on the curve itself and is paid in WETH.
    function test_ASellerWithoutReceiveIsRefusedEtherAndSellsForWeth() public {
        Curve curve = _wethCurve(0);
        vm.prank(alice);
        uint256 tokens = cf.buy{ value: 1e18 }(address(curve), 1e18, 0);
        NoReceive nr = new NoReceive();
        IERC20 token = _tok(curve);
        vm.prank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(address(nr), tokens);
        (uint256 quoteOut,,) = curve.previewSell(tokens);
        (bool ok, bytes memory ret) = nr.sellForEth(cf, address(curve), tokens);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(Launcher.NativeTransferFailed.selector, address(nr), quoteOut));
        assertEq(_tok(curve).balanceOf(address(nr)), tokens, "nothing moved");
        assertEq(nr.sellForWeth(curve, tokens), quoteOut);
        assertEq(weth.balanceOf(address(nr)), quoteOut, "paid in WETH by the curve");
    }

    /// The ether goes out last, under the launcher's guard: a seller whose `receive` calls `sellForEth`
    /// again is refused (`ReentrancyGuardReentrantCall`); its `receive` selling on the curve itself is an
    /// ordinary sale, the curve's books exact after both; nothing stays in the launcher.
    function test_TheEtherSendCannotReenterTheLauncher() public {
        Curve curve = _wethCurve(0);
        Reenterer r = new Reenterer(cf, curve);
        vm.prank(alice);
        uint256 tokens = cf.buy{ value: 2e18 }(address(curve), 2e18, 0);
        IERC20 token = _tok(curve);
        vm.prank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(address(r), tokens);
        (uint256 quoteOut,,) = curve.previewSell(tokens / 2);
        uint256 out = r.sellForEth(tokens / 2);
        assertEq(out, quoteOut);
        assertEq(r.received(), quoteOut);
        assertFalse(r.reentryOk(), "the launcher refused the second door");
        assertEq(r.reentryRet(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertGt(r.curveSaleOut(), 0);
        assertEq(weth.balanceOf(address(r)), r.curveSaleOut());
        assertEq(weth.balanceOf(address(curve)), curve.realQuote() + curve.creatorFees() + curve.protocolFees());
        assertEq(_launcherHoldsWeth(curve, LAUNCH_FEE), 0);
    }

    /// `claimInEth`: the creator's fees and the protocol's (the bond's 30 % among them) in ether to whom
    /// each names, checked by the curve as its own `claim` (`NotCreator`, `NotOwner`, `TooMuch`); a curve
    /// of another quote is `NotWethQuote`, `to` 0 `ZeroAddress`.
    function test_AWethCurvesFeesAreClaimedInEther() public {
        Curve curve = _wethCurve(300);
        vm.prank(alice);
        cf.buy{ value: 2e18 }(address(curve), 2e18, 0);
        uint256 creatorFees = curve.creatorFees();
        vm.prank(alice);
        vm.expectRevert(Curve.NotCreator.selector);
        cf.claimInEth(address(curve), false, creatorFees, alice);
        vm.prank(maker);
        vm.expectRevert(Launcher.ZeroAddress.selector);
        cf.claimInEth(address(curve), false, creatorFees, address(0));
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Curve.TooMuch.selector, creatorFees + 1, creatorFees));
        cf.claimInEth(address(curve), false, creatorFees + 1, carol);
        uint256 before = carol.balance;
        vm.prank(maker);
        cf.claimInEth(address(curve), false, creatorFees, carol);
        assertEq(carol.balance - before, creatorFees);
        assertEq(curve.creatorFees(), 0);

        vm.prank(bob);
        cf.buy{ value: 5e18 }(address(curve), 5e18, 0);
        assertTrue(curve.bonded());
        uint256 due = curve.protocolFees();
        assertGt(due, curve.bondSetAside());
        vm.prank(maker);
        vm.expectRevert(Curve.NotOwner.selector);
        cf.claimInEth(address(curve), true, due, maker);
        address treasury = makeAddr("treasury");
        vm.prank(owner);
        cf.claimInEth(address(curve), true, due, treasury);
        assertEq(treasury.balance, due, "the protocol's fees and the bond's 30 %, in ether");
        assertEq(weth.balanceOf(address(curve)), curve.creatorFees());
        assertEq(_launcherHoldsWeth(curve, LAUNCH_FEE), 0);

        (, Curve onEtf) = _launchEtfSeed(10e6, 0);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Launcher.NotWethQuote.selector, onEtf.quote()));
        cf.claimInEth(address(onEtf), false, 1, maker);
    }

    /// The curve's `sellFor` and `claimFor` are its launcher's alone (`NotFactory`) and a plain quote's:
    /// on an ETF quote they would pay the launcher shares (`SharesStayInTheCurve`). The launcher's ether doors
    /// refuse an ETF curve (`NotWethQuote`) and ether from anyone but WETH (`NotWeth`).
    function test_TheEtherDoorsArePlainWethCurvesOnly() public {
        Curve curve = _wethCurve(0);
        vm.prank(alice);
        cf.buy{ value: 1e18 }(address(curve), 1e18, 0);
        vm.startPrank(alice);
        vm.expectRevert(Curve.NotFactory.selector);
        curve.sellFor(alice, 1e18, 0);
        vm.expectRevert(Curve.NotFactory.selector);
        curve.claimFor(maker, false, 1);
        vm.stopPrank();
        (Etf etf, Curve onEtf) = _launchEtfSeed(10e6, 0);
        vm.startPrank(address(cf));
        vm.expectRevert(Curve.SharesStayInTheCurve.selector);
        onEtf.sellFor(maker, 1e18, 0);
        vm.expectRevert(Curve.SharesStayInTheCurve.selector);
        onEtf.claimFor(maker, false, 1);
        vm.stopPrank();
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Launcher.NotWethQuote.selector, address(etf)));
        cf.sellForEth(address(onEtf), 1e18, 0);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(cf).call{ value: 1 }("");
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(Launcher.NotWeth.selector, alice));
    }

    // ------------------------------------------ 4. the owner's 30 % booked ---

    /// The bond pays no one: the 30 % stays in the curve, booked to the protocol's fees (`bondSetAside`),
    /// no leg redeemed to the owner (his USDG moves only by the v4's own 0.10 % entry fee on each mint),
    /// the 30 % never leaving the curve at the bond. The owner claims
    /// it with the protocol's fees, to USDG with his routes; or, a leg's token refusing the transfer, in kind
    /// with `allowFail`, that leg forfeited to the fund, no share either way.
    function test_TheBondBooksTheOwners30PercentAndHeClaimsItInUsdgOrInKind() public {
        (Etf etf, Curve curve) = _launchEtfSeed(10e6, 0);
        _approveAll(curve, address(etf));
        vm.warp(vm.getBlockTimestamp() + 3);
        _buyUsdg(curve, alice, 4000e6);
        uint256 ownerLegs = a.balanceOf(owner) + b.balanceOf(owner) + c.balanceOf(owner);
        _buyUsdg(curve, bob, 7000e6);
        assertTrue(curve.bonded());
        assertEq(a.balanceOf(owner) + b.balanceOf(owner) + c.balanceOf(owner), ownerLegs, "the bond redeemed nothing to the owner");
        uint256 real = curve.realQuote();
        assertEq(curve.bondSetAside() + etf.balanceOf(address(pm)), real, "70 % in the pool, 30 % booked");
        assertEq(etf.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees());
        uint256 due = curve.protocolFees();
        assertGe(due, curve.bondSetAside());

        uint256 usdgBefore = usdg.balanceOf(owner);
        uint256 half = due / 2;
        (uint256[] memory legDue,,,) = etf.previewRedeemToUsdg(address(curve), half);
        Etf.Route[] memory sr = _sellRoutes(etf, legDue);
        vm.prank(owner);
        curve.claim(true, half, owner, 2, sr, 1, 0);
        assertGt(usdg.balanceOf(owner), usdgBefore, "in USDG with his routes");

        uint256 rest = curve.protocolFees();
        vm.mockCallRevert(address(a), abi.encodeWithSelector(IERC20.transfer.selector), "paused");
        vm.prank(owner);
        vm.expectRevert();
        curve.claim(true, rest, carol, 1, _noRoutes(), 0, 0);
        vm.prank(owner);
        curve.claim(true, rest, carol, 1, _noRoutes(), 0, 1);
        vm.clearMockedCalls();
        assertEq(a.balanceOf(carol), 0, "leg a forfeited");
        assertGt(b.balanceOf(carol) + c.balanceOf(carol), 0, "the other legs paid");
        assertEq(curve.protocolFees(), 0);
        assertEq(etf.balanceOf(carol), 0, "no share");
    }

    /// A plain quote's 30 % the same: booked, no transfer at the bond, claimed by the owner in the quote.
    function test_APlainBondBooksTheSetAsideAndTheOwnerClaimsItInTheQuote() public {
        Curve curve = _launch(address(usdg), 0);
        uint256 before = usdg.balanceOf(owner);
        vm.prank(holders[0]);
        curve.buy(9000e6, 0);
        assertTrue(curve.bonded());
        assertEq(usdg.balanceOf(owner), before, "nothing paid at the bond");
        assertEq(usdg.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees());
        uint256 due = curve.protocolFees();
        vm.prank(owner);
        curve.claim(true, due, owner, 0, _noRoutes(), 0, 0);
        assertEq(usdg.balanceOf(owner) - before, due);
        assertGe(due, curve.bondSetAside());
    }

    // --------------------------------------------------------------- gas ---

    /// The ether doors and the first buys, `gasleft()` around the call, accounts warm: `launchWithToken`
    /// with its first buy paid in ether and pulled in USDG, `buy` in ether, `sellForEth`, `claimInEth`,
    /// `launchWithEtf` with a 10 and a 1 000 USDG seed on three legs.
    function test_Gas_TheEtherDoorsAndTheFirstBuys() public {
        vm.prank(maker);
        uint256 g = gasleft();
        Curve curve = cf.launchWithToken{ value: LAUNCH_FEE + WETH_FIRST_BUY }("Robin Coin", "ROBIN", "", _noProfileC(), address(weth), 4.2e18, 100, 1_000_000_000, WETH_FIRST_BUY, new address[](0));
        emit log_named_uint("launchWithToken, first buy in ether", g - gasleft());
        vm.prank(maker);
        g = gasleft();
        cf.launchWithToken{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(usdg), 8000e6, 100, 1_000_000_000, USDG_FIRST_BUY, new address[](0));
        emit log_named_uint("launchWithToken, first buy in USDG", g - gasleft());
        vm.warp(vm.getBlockTimestamp() + 3);
        vm.prank(alice);
        g = gasleft();
        uint256 tokens = cf.buy{ value: 1e18 }(address(curve), 1e18, 0);
        emit log_named_uint("buy in ether", g - gasleft());
        vm.startPrank(alice);
        _tok(curve).approve(address(cf), type(uint256).max);
        vm.stopPrank();
        vm.prank(alice);
        g = gasleft();
        cf.sellForEth(address(curve), tokens / 2, 0);
        emit log_named_uint("sellForEth", g - gasleft());
        uint256 fees = curve.creatorFees();
        vm.prank(maker);
        g = gasleft();
        cf.claimInEth(address(curve), false, fees, maker);
        emit log_named_uint("claimInEth", g - gasleft());
        Etf.Route[] memory r10 = _seedRoutesFor(_legsAbc(), 10e6);
        Etf.Route[] memory r1000 = _seedRoutesFor(_legsAbc(), 1000e6);
        uint256 snap = vm.snapshotState();
        vm.prank(maker);
        g = gasleft();
        cf.launchWithEtf{ value: FEE }("Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 100, 1_000_000_000, 10e6, r10, 1, new address[](0), 0, new Etf.Route[](0), 0);
        emit log_named_uint("launchWithEtf, 3 legs, 10 USDG seed", g - gasleft());
        vm.revertToState(snap);
        vm.prank(maker);
        g = gasleft();
        cf.launchWithEtf{ value: FEE }("Robin Coin", "ROBIN", "", _noProfileC(), _legsAbc(), 200, 0, 8000e18, 100, 1_000_000_000, 1000e6, r1000, 1, new address[](0), 0, new Etf.Route[](0), 0);
        emit log_named_uint("launchWithEtf, 3 legs, 1 000 USDG seed", g - gasleft());
    }
}
