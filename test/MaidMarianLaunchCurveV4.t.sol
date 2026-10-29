// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {
    MaidMarianLaunchCurveSimTest,
    MaidMarianLaunchCurveFeesTest,
    MaidMarianLaunchCurveBondTest,
    MaidMarianLaunchCurveEtfTest,
    MaidMarianTokenLauncherTest,
    MaidMarianLaunchCurveSupplyTest,
    MaidMarianLaunchCurveGasTest
} from "./MaidMarianLaunchCurve.t.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianEtfV4 } from "../src/MaidMarianEtfV4.sol";
import { MaidMarianLaunchCurveSecurityTest } from "./MaidMarianLaunchCurveSecurity.t.sol";

/**
 * The launcher's suites on the ETF v4: each contract below is a suite of `MaidMarianLaunchCurve.t.sol`
 * (or `MaidMarianLaunchCurveSecurity.t.sol`) run again, every test unchanged, with the launcher deployed
 * over a v4 factory (`MaidMarianEtfFactoryV4`) that lists the same tokens and pools instead of the v3 bis
 * factory, and every ETF of the suite created on it. Proves the launcher and its curves work over the v4
 * factory and its ETFs on the suite's mocks, as they do over the v3 bis; the deployed v4 is
 * `MaidMarianEtfV4Launch.fork.t.sol`. A test that holds on the v3 bis only is overridden below.
 */
contract MaidMarianLaunchCurveSimV4Test is MaidMarianLaunchCurveSimTest {
    function _useEtfFactory() internal override {
        _switchToV4();
    }
}

contract MaidMarianLaunchCurveFeesV4Test is MaidMarianLaunchCurveFeesTest {
    function _useEtfFactory() internal override {
        _switchToV4();
    }
}

contract MaidMarianLaunchCurveBondV4Test is MaidMarianLaunchCurveBondTest {
    function _useEtfFactory() internal override {
        _switchToV4();
    }
}

contract MaidMarianLaunchCurveEtfV4Test is MaidMarianLaunchCurveEtfTest {
    function _useEtfFactory() internal override {
        _switchToV4();
    }
}

contract MaidMarianTokenLauncherV4Test is MaidMarianTokenLauncherTest {
    function _useEtfFactory() internal override {
        _switchToV4();
    }
}

contract MaidMarianLaunchCurveSupplyV4Test is MaidMarianLaunchCurveSupplyTest {
    function _useEtfFactory() internal override {
        _switchToV4();
    }
}

contract MaidMarianLaunchCurveGasV4Test is MaidMarianLaunchCurveGasTest {
    function _useEtfFactory() internal override {
        _switchToV4();
    }
}

/**
 * The security suite on the v4, three tests changed because the v4 is not the v3 bis on one point: a
 * donation to a reserve ETF is not counted, so it moves no share (S2 closed outright), and its first
 * mint writes one count word per leg more.
 */
contract MaidMarianLaunchCurveSecurityV4Test is MaidMarianLaunchCurveSecurityTest {
    function _useEtfFactory() internal override {
        _switchToV4();
    }

    /// The v4's first mint writes a count word per leg and one for USDG: about 0.2 M on ten legs, 0.08 M
    /// on three (`MaidMarianEtfV4LaunchGas.t.sol`).
    function _gasSlack() internal pure override returns (uint256) {
        return 250_000;
    }

    /// A donation to the reserve ETF, even x1 000 the NAV, moves neither its NAV nor a share's price: the
    /// ETF holds `min(count, balance)`, and the donation is the factory owner's to rescue.
    function test_S2_AfterTheLaunchsFirstMintADonationMovesNothingOnTheV4() public {
        (Etf etf,) = _launchEtf(0);
        MaidMarianEtfV4 v4 = MaidMarianEtfV4(address(etf));
        (uint256 nav0,) = etf.nav();
        uint256 usdgHeld0 = v4.usdgHeld();
        uint256 donation = nav0 * 1000;
        vm.prank(holders[0]);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdg.transfer(address(etf), donation);
        (uint256 nav1,) = etf.nav();
        assertEq(nav1, nav0, "the NAV did not move");
        assertEq(v4.usdgHeld(), usdgHeld0, "the donation is not counted");
        assertEq(v4.rescuable(address(usdg)), donation, "it is the owner's to rescue");
    }

    /// The creator's own donation lifts nothing either: the share's price stays, he holds no share, and the
    /// donation is the factory owner's to rescue.
    function test_S2_TheCreatorsDonationLiftsNoSharePriceOnTheV4() public {
        (Etf etf,) = _launchEtf(0);
        MaidMarianEtfV4 v4 = MaidMarianEtfV4(address(etf));
        (uint256 nav0,) = etf.nav();
        vm.prank(maker);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdg.transfer(address(etf), nav0 * 9);
        (uint256 nav1,) = etf.nav();
        assertEq(nav1, nav0, "a share's price is where the first mint put it");
        assertEq(etf.balanceOf(maker), 0);
        assertEq(v4.rescuable(address(usdg)), nav0 * 9, "his donation stayed in the ETF, the owner's");
    }

    function test_S2_AfterTheLaunchsFirstMintADonationOnlyEnrichesTheHolders() public pure override {
        // Replaced by the two tests above: a donation enriches no holder on the v4.
    }

    function test_S2_TheCreatorCanNoLongerLiftTheSharePriceForFree() public pure override {
        // Replaced by the two tests above: it lifts nothing on the v4.
    }
}
