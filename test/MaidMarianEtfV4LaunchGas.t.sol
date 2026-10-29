// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniversalRouter } from "../src/MaidMarianSevenMagnificent.sol";
import { MaidMarianEtfFactory as Factory } from "../src/MaidMarianEtfFactory.sol";
import { MaidMarianTokenLauncher as CurveFactory } from "../src/MaidMarianTokenLauncher.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianEtfFactoryV4 as FactoryV4 } from "../src/MaidMarianEtfFactoryV4.sol";
import { TokenMock } from "./Mocks.sol";
import { CurveBase } from "./MaidMarianLaunchCurve.t.sol";

/**
 * The launcher's `launchWithEtf` on the v4 factory against the v3 bis, offline on the curve suite's
 * mocks: the same launches (ten legs and three, a dense 10 KiB logo, a full profile, a 60-byte name,
 * the reserve ETF's first mint) measured on the v3 bis factory, then again after the owner's
 * `setEtfFactory` to a v4 factory listing the same tokens and pools, accounts cooled, intrinsic and
 * calldata gas added - `MaidMarianLaunchCurveSecurity.t.sol`'s measure. The v4's first mint writes one
 * more storage word per leg and one for the USDG, each from zero.
 */
contract MaidMarianEtfV4LaunchGasTest is CurveBase {
    FactoryV4 internal v4;

    function setUp() public override {
        super.setUp();
        v4 = new FactoryV4(IERC20(address(usdg)), IUniversalRouter(address(router)), address(v3), owner);
    }

    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i = 0; i < data.length; i++) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    function _fullProfile() internal pure returns (CurveFactory.Profile memory) {
        return CurveFactory.Profile({
            description: "Every byte of the 280 allowed: a description long enough to fill the whole field, so the profile costs what the largest one costs in storage, twice, once for the token and once for its ETF. Padding to the limit: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            x: "https://x.com/abcdefghijklmno",
            telegram: "https://t.me/abcdefghijklmnopqrstuvwxyz012345",
            website: "https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            discord: "https://discord.com/invite/abcdefghijklmnopqrstuvwxyz012345"
        });
    }

    function _densePng(uint256 size) internal pure returns (bytes memory png) {
        png = _png(256, 256, size);
        for (uint256 i = 33; i < size; i++) {
            png[i] = bytes1(uint8(0x41 + (i % 26)));
        }
    }

    /// Ten legs listed on both factories with the same V3 pools: a, b, c and seven more.
    function _legs10() internal returns (Factory.LegSpec[] memory l) {
        l = new Factory.LegSpec[](10);
        l[0] = Factory.LegSpec({ token: address(a), bps: 1000 });
        l[1] = Factory.LegSpec({ token: address(b), bps: 1000 });
        l[2] = Factory.LegSpec({ token: address(c), bps: 1000 });
        for (uint256 i = 3; i < 10; i++) {
            (TokenMock t,) = _token(string.concat("L", vm.toString(i)), 10 + i);
            l[i] = Factory.LegSpec({ token: address(t), bps: 1000 });
        }
        vm.startPrank(owner);
        for (uint256 i = 0; i < 10; i++) {
            (address pool,,,) = factory.poolsOf(l[i].token);
            v4.addToken(l[i].token, pool);
        }
        vm.stopPrank();
    }

    function _cool(Factory.LegSpec[] memory legs, address etfFactory, address implementation) internal {
        address[8] memory touched = [address(cf), etfFactory, address(usdg), address(qt), address(router), address(pm), address(cf.CURVE_IMPLEMENTATION()), implementation];
        for (uint256 i = 0; i < touched.length; i++) {
            vm.cool(touched[i]);
        }
        for (uint256 i = 0; i < legs.length; i++) {
            vm.cool(legs[i].token);
        }
    }

    function _gasLaunchWithEtf(Factory.LegSpec[] memory legs, uint256 logoBytes, string memory symbol) internal returns (uint256 total, Etf etf) {
        return _gasLaunchWithEtf(legs, logoBytes, symbol, new address[](0));
    }

    function _gasLaunchWithEtf(Factory.LegSpec[] memory legs, uint256 logoBytes, string memory symbol, address[] memory exempt) internal returns (uint256 total, Etf etf) {
        return _gasLaunchWithEtf(legs, logoBytes, symbol, exempt, SEED_USDG);
    }

    function _gasLaunchWithEtf(Factory.LegSpec[] memory legs, uint256 logoBytes, string memory symbol, address[] memory exempt, uint256 seedUsdg) internal returns (uint256 total, Etf etf) {
        bytes memory logo = _densePng(logoBytes);
        CurveFactory.Profile memory full = _fullProfile();
        string memory name60 = "Robin Coin With A Name Of Sixty Bytes At Most xxxxxxxxxxxxx";
        Etf.Route[] memory seed = _seedRoutesFor(legs, seedUsdg);
        address etfFactory = address(cf.etfFactory());
        _cool(legs, etfFactory, etfFactory == address(v4) ? address(v4.ETF_IMPLEMENTATION()) : address(factory.ETF_IMPLEMENTATION()));
        vm.prank(maker);
        uint256 g = gasleft();
        (etf,) = cf.launchWithEtf{ value: FEE }(name60, symbol, logo, full, legs, 200, 0, 8000e18, 100, 1_000_000_000, seedUsdg, seed, 1, exempt, 0, new Etf.Route[](0), 0);
        total = g - gasleft()
            + _intrinsic(abi.encodeCall(cf.launchWithEtf, (name60, symbol, logo, full, legs, 200, 0, 8000e18, 100, 1_000_000_000, seedUsdg, seed, 1, exempt, uint8(0), new Etf.Route[](0), 0)));
    }

    /// Ten legs: the v4 adds about 0.2 M gas to the v3 bis's `launchWithEtf` (eleven words written from
    /// zero by the first mint); three legs about 0.08 M. Both logged; the reserve ETF is the v4's.
    function test_Gas_LaunchWithEtfOnTheV4AgainstTheV3Bis() public {
        Factory.LegSpec[] memory l10 = _legs10();
        Factory.LegSpec[] memory l3 = _legsAbc();
        (uint256 g10v3,) = _gasLaunchWithEtf(l10, 10_240, "ROBINAA");
        (uint256 g3v3,) = _gasLaunchWithEtf(l3, 10_240, "ROBINAB");
        vm.prank(owner);
        cf.setEtfFactory(Factory(address(v4)));
        (uint256 g10v4, Etf etf) = _gasLaunchWithEtf(l10, 10_240, "ROBINBA");
        (uint256 g3v4,) = _gasLaunchWithEtf(l3, 10_240, "ROBINBB");
        assertTrue(v4.isEtf(address(etf)), "the reserve ETF is the v4's");
        emit log_named_uint("launchWithEtf, 10 legs, 10 KiB, full profile, first mint, v3 bis", g10v3);
        emit log_named_uint("launchWithEtf, 10 legs, 10 KiB, full profile, first mint, v4", g10v4);
        emit log_named_uint("launchWithEtf, 3 legs, 10 KiB, full profile, first mint, v3 bis", g3v3);
        emit log_named_uint("launchWithEtf, 3 legs, 10 KiB, full profile, first mint, v4", g3v4);
        assertLt(g10v4 - g10v3, 250_000);
        assertLt(g3v4 - g3v3, 100_000);
        assertLt(g10v4, 7_000_000, "under the wallets' simulation ceiling");
    }

    /// `MAX_SNIPE_EXEMPTIONS` distinct addresses, each a storage word written from zero.
    function _exemptAtCap() internal returns (address[] memory e) {
        e = new address[](cf.CURVE_IMPLEMENTATION().MAX_SNIPE_EXEMPTIONS());
        for (uint256 i = 0; i < e.length; i++) {
            e[i] = makeAddr(string.concat("exempt", vm.toString(i)));
        }
    }

    /// Both launch doors at their heaviest with the exemption list full: `launchWithEtf` on the v4 with ten
    /// legs, a dense 10 KiB logo, a full profile and a 60-byte name; `launchWithToken` with the same logo
    /// and profile. The list adds about 0.39 M (20 000 an address); both stay under the ~7 M a wallet simulates.
    function test_Gas_BothLaunchDoorsAtTheExemptionCap() public {
        Factory.LegSpec[] memory l10 = _legs10();
        address[] memory exempt = _exemptAtCap();
        vm.prank(owner);
        cf.setEtfFactory(Factory(address(v4)));
        (uint256 etfBare,) = _gasLaunchWithEtf(l10, 10_240, "ROBINCA");
        (uint256 etfCap,) = _gasLaunchWithEtf(l10, 10_240, "ROBINCB", exempt);

        bytes memory logo = _densePng(10_240);
        CurveFactory.Profile memory full = _fullProfile();
        string memory name64 = "Robin Coin With A Name Of Sixty-Four Bytes At Most xxxxxxxxxxxxx";
        _cool(l10, address(v4), address(v4.ETF_IMPLEMENTATION()));
        vm.prank(maker);
        uint256 g = gasleft();
        cf.launchWithToken{ value: LAUNCH_FEE }(name64, "ROBINHOOD", logo, full, address(qt), SIM_THRESHOLD, 100, 1_000_000_000, QT_FIRST_BUY, exempt);
        uint256 tokenCap = g - gasleft() + _intrinsic(abi.encodeCall(cf.launchWithToken, (name64, "ROBINHOOD", logo, full, address(qt), SIM_THRESHOLD, 100, 1_000_000_000, QT_FIRST_BUY, exempt)));

        emit log_named_uint("launchWithEtf, v4, 10 legs, 10 KiB, full profile, no exemption", etfBare);
        emit log_named_uint("launchWithEtf, v4, 10 legs, 10 KiB, full profile, 10 exemptions", etfCap);
        emit log_named_uint("launchWithToken, 10 KiB, full profile, 10 exemptions", tokenCap);
        assertLt(etfCap - etfBare, 450_000, "the list costs about 20 000 an address");
        // The token is deployed whole in the launch (about 0.6 M): the heaviest launch passes the ~7 M a
        // wallet simulates; the measure is held here, the cap is the author's call.
        assertLt(etfCap, 7_400_000, "the heaviest launch, measured");
        assertLt(tokenCap, 7_000_000);
    }

    /// The heaviest launches with the creator's larger first buys: `launchWithEtf` on the v4 with ten legs, a
    /// dense 10 KiB logo, a full profile, 10 exemptions and a seed of 1 000 USDG (one first mint, the same
    /// ten swaps as at 10 USDG); `launchWithToken` at the same cap with its first buy of 0.002 WETH paid in
    /// ether, wrapped. Both under the ~7 M a wallet simulates.
    function test_Gas_TheHeaviestLaunchesWithALargerFirstBuy() public {
        Factory.LegSpec[] memory l10 = _legs10();
        address[] memory exempt = _exemptAtCap();
        vm.prank(owner);
        cf.setEtfFactory(Factory(address(v4)));
        // A first ETF on the v4, as on the deployed one: the factory's counters are no longer at zero.
        _gasLaunchWithEtf(l10, 10_240, "ROBINCZ");
        uint256 snap = vm.snapshotState();
        (uint256 etf10,) = _gasLaunchWithEtf(l10, 10_240, "ROBINDA", exempt, SEED_USDG);
        vm.revertToState(snap);
        (uint256 etf1000,) = _gasLaunchWithEtf(l10, 10_240, "ROBINDA", exempt, 1000e6);

        bytes memory logo = _densePng(10_240);
        CurveFactory.Profile memory full = _fullProfile();
        string memory name64 = "Robin Coin With A Name Of Sixty-Four Bytes At Most xxxxxxxxxxxxx";
        _cool(l10, address(v4), address(v4.ETF_IMPLEMENTATION()));
        vm.cool(address(weth));
        vm.prank(maker);
        uint256 g = gasleft();
        cf.launchWithToken{ value: LAUNCH_FEE + WETH_FIRST_BUY }(name64, "ROBINHOOD", logo, full, address(weth), 4.2e18, 100, 1_000_000_000, WETH_FIRST_BUY, exempt);
        uint256 tokenEth = g - gasleft() + _intrinsic(abi.encodeCall(cf.launchWithToken, (name64, "ROBINHOOD", logo, full, address(weth), 4.2e18, 100, 1_000_000_000, WETH_FIRST_BUY, exempt)));

        emit log_named_uint("launchWithEtf, v4, 10 legs, 10 KiB, full profile, 10 exemptions, 10 USDG seed", etf10);
        emit log_named_uint("launchWithEtf, v4, 10 legs, 10 KiB, full profile, 10 exemptions, 1 000 USDG seed", etf1000);
        emit log_named_uint("launchWithToken, 10 KiB, full profile, 10 exemptions, first buy in ether", tokenEth);
        assertLt(etf1000, 7_400_000, "the heaviest launch with the token deployed whole, measured");
        assertLt(tokenEth, 7_000_000);
    }
}
