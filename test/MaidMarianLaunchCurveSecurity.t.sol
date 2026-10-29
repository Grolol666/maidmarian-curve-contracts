// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { oneThreshold } from "./CurveFixtures.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MaidMarianEtfFactory as Factory } from "../src/MaidMarianEtfFactory.sol";
import { MaidMarianTokenLauncher as CurveFactory } from "../src/MaidMarianTokenLauncher.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianLaunchCurve as Curve } from "../src/MaidMarianLaunchCurve.sol";
import { TokenMock, PoolMock } from "./Mocks.sol";
import { CurveBase } from "./MaidMarianLaunchCurve.t.sol";

/**
 * What a user can no longer do to a curve, offline: the real launcher, curve, token, ETF factory and
 * ETF v3 code over the v3 bis harness's mocks and the V4 mock. The bond's range and its pending path
 * are claims about the deployed PoolManager: `MaidMarianLaunchCurveSecurity.fork.t.sol`.
 *  - the reserve ETF's first mint is the launch's own (10 USDG), so no one sets a share's first price;
 *    what a donation must then be to move it, and that it goes to the holders;
 *  - on the ETF v3 code itself: a minuscule first mint and a donation leave a later minter whole;
 *  - an ETF quote's fees are always payable, however the curve was bought;
 *  - every door under 5 M gas at the 10 KiB logo cap, calldata included.
 *
 *   forge test --match-contract MaidMarianLaunchCurveSecurityTest -vv
 */
contract MaidMarianLaunchCurveSecurityTest is CurveBase {
    // ---------------------------------------------------------------- S2 ---

    /// After the launch's own first mint (10 USDG, about 9.99 shares, every one in the curve but `DEAD`'s),
    /// moving a share's price x10 takes a donation of 9 x the NAV (about 90 USDG), x1 000 about 9 980 USDG;
    /// the donation is the holders': the curve's shares (its reserve and fees) and `DEAD`'s, and the curve
    /// then needs that many times more USDG to bond. The creator holds no share to take it out with.
    function test_S2_AfterTheLaunchsFirstMintADonationOnlyEnrichesTheHolders() public virtual {
        uint256 makerUsdg = usdg.balanceOf(maker);
        (Etf etf, Curve curve) = _launchEtf(0);
        assertEq(makerUsdg - usdg.balanceOf(maker), 10e6);
        (uint256 nav0,) = etf.nav();
        uint256 supply = etf.totalSupply();
        uint256 curveShares = etf.balanceOf(address(curve));
        assertEq(curveShares, supply - etf.DEAD_SHARES());
        assertEq(etf.balanceOf(maker), 0);
        emit log_named_uint("S2 NAV after the launch's first mint, raw USDG", nav0);

        uint256[2] memory factor = [uint256(10), 1000];
        for (uint256 k = 0; k < 2; k++) {
            (uint256 nav,) = etf.nav();
            uint256 donation = nav0 * factor[k] - nav;
            address attacker = holders[k];
            vm.prank(attacker);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            usdg.transfer(address(etf), donation);
            (uint256 after_,) = etf.nav();
            emit log_named_uint(k == 0 ? "S2 donation to x10 a share, raw USDG" : "S2 donation to x1000 a share, raw USDG (both donations)", nav0 * factor[k] - nav0);
            assertApproxEqRel(after_ * 1e18 / supply, nav0 * factor[k] * 1e18 / supply, 1e12);
            // The donation is the holders': the curve's shares carry it, pro rata.
            assertApproxEqRel(after_ * curveShares / supply, (nav0 * factor[k]) * curveShares / supply, 1e12);
        }
        assertEq(etf.balanceOf(address(curve)), curveShares, "no share moved");
        assertEq(etf.balanceOf(maker), 0);
        assertFalse(curve.bonded());
    }

    /// Closed: the launch's first shares are the curve's, not the creator's, so a donation he makes is
    /// his loss whole. Before any buy he donates 9 x the NAV: a share goes x10 (the bond then at 10 x the
    /// USDG), and the lift sits in the curve's reserve and fees; he holds no share to redeem it with.
    function test_S2_TheCreatorCanNoLongerLiftTheSharePriceForFree() public virtual {
        (Etf etf, Curve curve) = _launchEtf(0);
        (uint256 nav0,) = etf.nav();
        uint256 price0 = nav0 * 1e18 / etf.totalSupply();
        uint256 donation = nav0 * 9;
        uint256 before = _value(etf, maker);
        vm.prank(maker);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdg.transfer(address(etf), donation);
        assertEq(etf.balanceOf(maker), 0, "no share to take it back with");
        (uint256 nav1,) = etf.nav();
        assertApproxEqRel(nav1 * 1e18 / etf.totalSupply(), price0 * 10, 1e15);
        assertEq(before - _value(etf, maker), donation, "the whole donation is his loss");
        assertApproxEqRel(nav1 * etf.balanceOf(address(curve)) / etf.totalSupply(), (nav0 + donation) * etf.balanceOf(address(curve)) / etf.totalSupply(), 1e12, "the curve's");
    }

    /// On the ETF v3 code (the v3 bis harness, an ETF of a, b, c at 50 / 30 / 20, no fee but the 0.10 %
    /// entry floor): a minuscule first mint (0.002 USDG, the least `DEAD_SHARES` allows), 10 USDG
    /// donated straight to the ETF, then an ordinary 1 000 USDG mint. The ETF keeps of his legs only
    /// what matches its own mix and refunds the rest, so his shares are worth what it kept, within dust;
    /// redeemed to USDG, he ends with what a plain mint and redeem leaves (the control), to 1 USDG.
    function test_EtfV3_AFirstMintAndADonationLeaveTheNextMinterWhole() public {
        uint256 lossAttacked = _mintAndRedeem(true);
        uint256 lossPlain = _mintAndRedeem(false);
        emit log_named_uint("v3: the minter's loss after a first mint and a donation, raw USDG", lossAttacked);
        emit log_named_uint("v3: the same mint and redeem without them, raw USDG", lossPlain);
        assertApproxEqAbs(lossAttacked, lossPlain, 1e6, "the donation took nothing from him");
    }

    /// Alice's 1 000 USDG through `mint` and `redeem` on a fresh ETF, first minted with 0.002 USDG (and
    /// 10 USDG donated when `donate`): what she lost, her refunded legs valued at the factory's price.
    function _mintAndRedeem(bool donate) internal returns (uint256 loss) {
        Etf etf = _etf0();
        address attacker = holders[0];
        vm.prank(attacker);
        usdg.approve(address(etf), type(uint256).max);
        _mint(etf, attacker, 2000);
        if (donate) {
            vm.prank(attacker);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            usdg.transfer(address(etf), 10e6);
        }
        address minter = makeAddr(donate ? "minter-attacked" : "minter-plain");
        usdg.mint(minter, 1000e6);
        vm.prank(minter);
        usdg.approve(address(etf), type(uint256).max);
        uint256 value0 = _value(etf, minter);
        uint256 shares = _mint(etf, minter, 1000e6);
        (uint256 nav,) = etf.nav();
        uint256 worth = nav * shares / etf.totalSupply();
        // What he holds after the mint, his shares at the NAV: 1 000 less the 0.10 % fee and the pools'.
        assertApproxEqRel(_value(etf, minter) + worth, value0, 0.01e18);
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(minter, shares);
        Etf.Route[] memory sr = _sellRoutes(etf, due);
        vm.prank(minter);
        etf.redeem(shares, sr, 1, minter);
        loss = value0 - _value(etf, minter);
    }

    /// `who`'s USDG plus his legs at the factory's price, raw USDG.
    function _value(Etf etf, address who) internal view returns (uint256 v) {
        v = usdg.balanceOf(who);
        Etf.Leg[] memory l = etf.legs();
        for (uint256 i = 0; i < l.length; i++) {
            (uint256 price,) = factory.getPriceUsdg(l[i].token);
            v += IERC20(l[i].token).balanceOf(who) * price / 10 ** l[i].decimals / 1e12;
        }
    }

    /// An ETF of a, b, c (50 / 30 / 20), no fee and no penalty, no supply.
    function _etf0() internal returns (Etf etf) {
        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (address(a), address(b), address(c));
        uint16[] memory w = new uint16[](3);
        (w[0], w[1], w[2]) = (5000, 3000, 2000);
        etf = _createWith("ZERO", t, w, Etf.Params({ entryFeeBps: 0, exitFeeBps: 0, holdPeriod: 0, earlyPenaltyBps: 0, nonMinterPenaltyBps: 0, rebalanceBandBps: 200, rebalanceMinInterval: 0 }));
    }

    // ---------------------------------------------------------------- S3 ---

    /// An ETF curve's fees are always payable: every share it holds is one it minted, so its redeems stay
    /// within its `mintOf`. Bought in USDG, on the curve and through the launcher, sold in kind and to
    /// USDG; the creator's and the protocol's fees are claimed in kind before the bond and after it, to the
    /// last share, and the curve ends holding none.
    function test_S3_AnEtfCurvesFeesArePaidInKindBeforeAndAfterTheBond() public {
        (Etf etf, Curve curve) = _launchEtf(100);
        vm.prank(alice);
        usdg.approve(address(cf), type(uint256).max);
        uint256 out = _buyUsdg(curve, alice, 3000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 2000e6, false);
        vm.prank(alice);
        out += cf.buyWithUsdg(address(curve), 2000e6, r, 1, 1, new Etf.Route[](0), 0);
        _sell(curve, alice, out / 3);
        (uint256 quoteOut,,) = curve.previewSell(out / 3);
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(address(curve), quoteOut);
        Etf.Route[] memory sr = _sellRoutes(etf, due);
        vm.prank(alice);
        curve.sell(out / 3, 0, 2, sr, 1, 0);
        uint256 half = (curve.creatorFees() + curve.unbookedShares()) / 2;
        vm.prank(maker);
        curve.claim(false, half, carol, 1, _noRoutes(), 0, 0);
        assertGt(a.balanceOf(carol), 0, "in kind");
        assertEq(etf.balanceOf(carol), 0);

        _buyUsdg(curve, bob, 12_000e6);
        assertTrue(curve.bonded());
        assertGe(etf.mintOf(address(curve)), etf.balanceOf(address(curve)), "within its own mint (the pool's shares left by the bond, not by a redeem)");

        uint256 creatorFees = curve.creatorFees() + curve.unbookedShares();
        uint256 protocolFees = curve.protocolFees();
        address dave = makeAddr("dave");
        vm.prank(maker);
        curve.claim(false, creatorFees, dave, 1, _noRoutes(), 0, 0);
        uint256 ownerA = a.balanceOf(owner);
        vm.prank(owner);
        curve.claim(true, protocolFees, owner, 1, _noRoutes(), 0, 0);
        assertGt(a.balanceOf(owner), ownerA);
        assertEq(etf.balanceOf(dave), 0);
        assertEq(curve.creatorFees() + curve.protocolFees(), 0);
        assertEq(etf.balanceOf(address(curve)), 0, "nothing left behind");
    }

    /// A curve whose buyers all sold back in kind: every fee is still claimed, in kind, to the last share.
    function test_S3_AFullySoldBackCurvePaysAllItsFees() public {
        (, Curve curve) = _launchEtf(100);
        uint256 aliceTokens = _buyUsdg(curve, alice, 2000e6);
        uint256 bobTokens = _buyUsdg(curve, bob, 2000e6);
        _sell(curve, bob, bobTokens);
        _sell(curve, alice, aliceTokens);
        uint256 creatorFees = curve.creatorFees() + curve.unbookedShares();
        uint256 protocolFees = curve.protocolFees();
        vm.prank(maker);
        curve.claim(false, creatorFees, maker, 1, _noRoutes(), 0, 0);
        vm.prank(owner);
        curve.claim(true, protocolFees, owner, 1, _noRoutes(), 0, 0);
        assertEq(curve.creatorFees() + curve.protocolFees(), 0);
    }

    /// A factory ETF listed by force as a plain quote is a plain token: its fees are paid as shares,
    /// never redeemed by the curve.
    function test_S3_AForcedFactoryEtfIsAPlainQuotePaidAsShares() public {
        Etf etf = _etf(_backing());
        PoolMock etfPool = _poolAt(address(etf), _tickAt(1e18), 3000);
        usdg.mint(address(etfPool), 1e12);
        vm.prank(owner);
        cf.setTokenQuote(address(etf), true, true, oneThreshold(8000e18), 1);
        Curve curve = _launch(address(etf), 100);
        assertFalse(curve.etfQuote());
        vm.prank(maker);
        etf.approve(address(curve), type(uint256).max);
        vm.prank(maker);
        curve.buy(100e18, 0);
        uint256 fees = curve.creatorFees();
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Curve.BadPayout.selector, 1));
        curve.claim(false, fees, maker, 1, _noRoutes(), 0, 0);
        uint256 before = etf.balanceOf(carol);
        vm.prank(maker);
        curve.claim(false, fees, carol, 0, _noRoutes(), 0, 0);
        assertEq(etf.balanceOf(carol) - before, fees);
    }

    // ---------------------------------------------------------------- G1 ---

    function _fullProfile() internal pure returns (CurveFactory.Profile memory) {
        return CurveFactory.Profile({
            description: "Every byte of the 280 allowed: a description long enough to fill the whole field, so the profile costs what the largest one costs in storage, twice, once for the token and once for its ETF. Padding to the limit: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            x: "https://x.com/abcdefghijklmno",
            telegram: "https://t.me/abcdefghijklmnopqrstuvwxyz012345",
            website: "https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            discord: "https://discord.com/invite/abcdefghijklmnopqrstuvwxyz012345"
        });
    }

    /// A PNG the factory accepts, `size` bytes, every byte after the header non-zero (16 gas each in calldata).
    function _densePng(uint256 size) internal pure returns (bytes memory png) {
        png = _png(256, 256, size);
        for (uint256 i = 33; i < size; i++) {
            png[i] = bytes1(uint8(0x41 + (i % 26)));
        }
    }

    /// 21 000 plus the calldata's 4 / 16 gas a byte: what `gasleft()` around a call does not see.
    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i = 0; i < data.length; i++) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    function _legs10() internal returns (Factory.LegSpec[] memory l) {
        l = new Factory.LegSpec[](10);
        l[0] = Factory.LegSpec({ token: address(a), bps: 1000 });
        l[1] = Factory.LegSpec({ token: address(b), bps: 1000 });
        l[2] = Factory.LegSpec({ token: address(c), bps: 1000 });
        for (uint256 i = 3; i < 10; i++) {
            (TokenMock t,) = _token(string.concat("L", vm.toString(i)), 10 + i);
            l[i] = Factory.LegSpec({ token: address(t), bps: 1000 });
        }
    }

    function _cool(Factory.LegSpec[] memory legs) internal {
        address[8] memory touched = [address(cf), address(factory), address(usdg), address(qt), address(router), address(pm), address(cf.CURVE_IMPLEMENTATION()), address(factory.ETF_IMPLEMENTATION())];
        for (uint256 i = 0; i < touched.length; i++) {
            vm.cool(touched[i]);
        }
        for (uint256 i = 0; i < legs.length; i++) {
            vm.cool(legs[i].token);
        }
    }

    /// `launchWithEtf` with a dense logo, a full profile and a 60-byte name, its first mint included,
    /// intrinsic and calldata gas added.
    function _gasLaunchWithEtf(Factory.LegSpec[] memory legs, uint256 logoBytes) internal returns (uint256 total) {
        bytes memory logo = _densePng(logoBytes);
        CurveFactory.Profile memory full = _fullProfile();
        string memory name60 = "Robin Coin With A Name Of Sixty Bytes At Most xxxxxxxxxxxxx";
        Etf.Route[] memory seed = _seedRoutes(legs);
        _cool(legs);
        vm.prank(maker);
        uint256 g = gasleft();
        cf.launchWithEtf{ value: FEE }(name60, "ROBINROB", logo, full, legs, 200, 0, 8000e18, 100, 1_000_000_000, SEED_USDG, seed, 1, new address[](0), 0, new Etf.Route[](0), 0);
        total = g - gasleft()
            + _intrinsic(
                abi.encodeCall(cf.launchWithEtf, (name60, "ROBINROB", logo, full, legs, 200, 0, 8000e18, 100, 1_000_000_000, SEED_USDG, seed, 1, new address[](0), uint8(0), new Etf.Route[](0), 0))
            );
    }

    /// The 10 KiB cap measured on the mocks: with its first mint (10 legs swapped), the creator's seed buy on
    /// the curve and the token deployed whole, `launchWithEtf` is about 7.0 M on ten legs and 5.7 M on three,
    /// ten legs at a 6 KiB logo about 5.6 M (about 240 gas a logo byte); the chain's are the fork's.
    function test_Gas_LaunchWithEtfAtTheTenKiBCapPerLegCountAndLogo() public {
        uint256 slack = _gasSlack();
        Factory.LegSpec[] memory l10 = _legs10();
        uint256 g10 = _gasLaunchWithEtf(l10, 10_240);
        uint256 g10at8 = _gasLaunchWithEtf(l10, 8192);
        uint256 g10at6 = _gasLaunchWithEtf(l10, 6144);
        uint256 g3 = _gasLaunchWithEtf(_legsAbc(), 10_240);
        emit log_named_uint("launchWithEtf, 10 legs, 10 KiB, full profile, first mint: with intrinsic + calldata", g10);
        emit log_named_uint("launchWithEtf, 10 legs, 8 KiB: with intrinsic + calldata", g10at8);
        emit log_named_uint("launchWithEtf, 10 legs, 6 KiB: with intrinsic + calldata", g10at6);
        emit log_named_uint("launchWithEtf, 3 legs, 10 KiB: with intrinsic + calldata", g3);
        assertGt(g10, 5_000_000);
        assertLt(g10, 7_100_000);
        assertLt(g10at6, 5_050_000 + slack + TOKEN_DEPLOYMENT + DISCORD_AND_TOKEN_WORDS);
        assertGt(g3, 5_000_000);
        assertLt(g3, 5_150_000 + slack + TOKEN_DEPLOYMENT + DISCORD_AND_TOKEN_WORDS);
    }

    /// The launch deploys the token whole (a contract of its own, not a clone): about 0.55 M more, measured.
    uint256 internal constant TOKEN_DEPLOYMENT = 600_000;

    /// A full Discord link (three storage words) and the token's stored address (one): about 0.09 M.
    uint256 internal constant DISCORD_AND_TOKEN_WORDS = 100_000;

    /// What the bounds above allow beyond the v3 bis's: 0 here.
    function _gasSlack() internal view virtual returns (uint256) {
        return 0;
    }

    /// The 10 KiB cap's other doors, accounts cooled: `launchWithToken` with a dense 10 240-byte logo, a
    /// full profile and a 60-byte name; then a ten-leg curve's buys, sales and bond. Each under 5 M.
    function test_Gas_EveryOtherDoorIsUnderFiveMillionAtTheTenKiBLogoCap() public {
        bytes memory logo = _densePng(cf.MAX_LOGO_BYTES());
        CurveFactory.Profile memory full = _fullProfile();
        string memory name60 = "Robin Coin With A Name Of Sixty Bytes At Most xxxxxxxxxxxxx";
        Factory.LegSpec[] memory l10 = _legs10();

        _cool(l10);
        vm.prank(maker);
        uint256 g = gasleft();
        cf.launchWithToken{ value: LAUNCH_FEE }(name60, "ROBINROBIN1", logo, full, address(qt), SIM_THRESHOLD, 100, 1_000_000_000, QT_FIRST_BUY, new address[](0));
        uint256 used = g - gasleft();
        uint256 total = used + _intrinsic(abi.encodeCall(cf.launchWithToken, (name60, "ROBINROBIN1", logo, full, address(qt), SIM_THRESHOLD, 100, 1_000_000_000, QT_FIRST_BUY, new address[](0))));
        emit log_named_uint("launchWithToken, 10 KiB, full profile: with intrinsic + calldata", total);
        assertLt(total, 5_000_000);

        Etf.Route[] memory seed = _seedRoutes(l10);
        vm.prank(maker);
        (Etf etf, Curve curve) =
            cf.launchWithEtf{ value: FEE }("Robin Coin", "ROBIN", "", _noProfileC(), l10, 200, 0, 8000e18, 100, 1_000_000_000, SEED_USDG, seed, 1, new address[](0), 0, new Etf.Route[](0), 0);

        _approveAll(curve, address(etf));
        vm.warp(vm.getBlockTimestamp() + 3);
        Etf.Route[] memory r = _buyRoutes(etf, 500e6, false);
        _cool(l10);
        vm.prank(alice);
        g = gasleft();
        uint256 out = curve.buyWithUsdg(500e6, r, 1, 1, new Etf.Route[](0), 0);
        emit log_named_uint("buyWithUsdg, 10 legs", g - gasleft());
        _cool(l10);
        vm.prank(alice);
        g = gasleft();
        curve.sell(out / 3, 0, 1, _noRoutes(), 0, 0);
        emit log_named_uint("sell in kind, 10 legs", g - gasleft());
        (uint256 quoteOut,,) = curve.previewSell(out / 3);
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(address(curve), quoteOut);
        Etf.Route[] memory sr = _sellRoutes(etf, due);
        _cool(l10);
        vm.prank(alice);
        g = gasleft();
        curve.sell(out / 3, 0, 2, sr, 1, 0);
        emit log_named_uint("sell to USDG, 10 legs", g - gasleft());
        r = _buyRoutes(etf, 11_000e6, false);
        _cool(l10);
        vm.prank(bob);
        g = gasleft();
        curve.buyWithUsdg(11_000e6, r, 1, 1, new Etf.Route[](0), 0);
        used = g - gasleft();
        emit log_named_uint("last buyWithUsdg + bond, 10 legs", used);
        assertTrue(curve.bonded());
        assertLt(used, 5_000_000);
        assertEq(IERC20(address(etf)).balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees());
    }
}
