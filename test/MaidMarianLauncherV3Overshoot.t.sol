// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Vm } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { MaidMarianEtfV3 as Etf } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianLaunchCurve as Curve, curveBuy, curveFits, curveReserved } from "../src/MaidMarianLaunchCurve.sol";
import { CurveBase } from "./MaidMarianLaunchCurve.t.sol";

/**
 * Offline: the last buy is bought whole, past the curve's end, and bonds there.
 * The buyer pays all he sent and gets `curveBuy`'s tokens for all of it, no change and no cut; the bond
 * follows in the same call on the larger reserve: the pool opens at the curve's price after the buy
 * with 70 % of the real quote, the rest of it (30 % and the pool's rounding) booked to the protocol, every
 * token not in the pool burned. Fuzzed over the last buy's size, the curve solvent to the unit and every
 * amount checked against its formula. The cap (`curveFits`, `BuyTooLarge`) is the largest buy whose pool
 * still opens, computed here for the 8 000-share and the 4.2 WETH thresholds at the smallest and largest
 * supply, and proved at its edge. The real launcher, curve, token, v4 factory and ETF code over the curve
 * suite's mocks (a V4 PoolManager with V4's amounts); the deployed v4 and the real PoolManager are
 * `MaidMarianLauncherV3Overshoot.fork.t.sol`.
 *
 *   forge test --match-contract MaidMarianLauncherV3OvershootTest -vv
 */
contract MaidMarianLauncherV3OvershootTest is CurveBase {
    bytes32 internal constant BONDED = keccak256("Bonded(address,bytes32,address,uint256,uint256,uint256,uint256)");

    function _useEtfFactory() internal override {
        _switchToV4();
    }

    /// What the bond did, read from its `Bonded`.
    struct Bond {
        uint256 setAside;
        uint256 poolTokens;
        uint256 poolQuote;
        uint256 burned;
        // The bond's one swap (`BondSwapped`): tokens in, quote out.
        uint256 swapIn;
        uint256 swapOut;
    }

    function _bonded(Vm.Log[] memory logs, address curve) internal pure returns (Bond memory bd) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == curve && logs[i].topics[0] == BONDED) {
                (, bd.setAside, bd.poolTokens, bd.poolQuote, bd.burned) = abi.decode(logs[i].data, (address, uint256, uint256, uint256, uint256));
            } else if (logs[i].emitter == curve && logs[i].topics[0] == Curve.BondSwapped.selector) {
                (bd.swapIn, bd.swapOut) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        require(bd.poolTokens != 0, "no Bonded");
    }

    /// One of the deploy script's ten plain targets in raw units, USDG's 1 000 to 15 000 (1e9 to 1.5e10)
    /// or WETH's 0.5 to 8 (5e17 to 8e18), listed on `qt` alone and picked by the harness's launch: the curve
    /// reads raw units only, so `qt` carries either list's numbers.
    function _pickPlainTarget(uint8 pick) internal returns (uint256 threshold) {
        uint256[] memory l = new uint256[](5);
        if (pick % 10 < 5) (l[0], l[1], l[2], l[3], l[4]) = (1000e6, 2000e6, 5000e6, 8000e6, 15_000e6);
        else (l[0], l[1], l[2], l[3], l[4]) = (0.5e18, 1e18, 2e18, 4e18, 8e18);
        vm.prank(owner);
        cf.setTokenQuote(address(qt), true, false, l, 1);
        cf.setPickIndex(pick % 5);
        threshold = l[pick % 5];
    }

    /// The least gross buy that takes `(q, t)` to the curve's end, at `feeBps + taxBps`.
    function _toTheEnd(Curve curve, uint256 feeAndTaxBps) internal view returns (uint256) {
        (uint256 q, uint256 t) = curve.getReserves();
        uint256 need = Math.ceilDiv(q * t, curve.reserved()) - q;
        return Math.ceilDiv(need * 10_000, 10_000 - feeAndTaxBps) + 1;
    }

    /**
     * The bond's amounts against the reserves after the last buy, to the unit: the pool's quote at most the
     * 70 % budget (`real - real x 30 %`) and short of it by the pool's rounding only (under sqrt(q / t) + 3
     * raw units: one unit of liquidity is worth sqrt(price) of the quote), the set-aside exactly the real
     * quote less the pool's quote, the pool's tokens exactly what the PoolManager holds and under 70 % of
     * `t`, the burn exactly `t` less them, the pool at the curve's price, the supply down by the burn.
     */
    function _assertBond(Curve curve, Bond memory bd, uint256 quoteInPool) internal view {
        (uint256 q, uint256 t) = curve.getReserves();
        assertLe(t, curve.reserved(), "at or past the curve's end");
        uint256 real = q - curve.phantomQuote();
        uint256 budget = real - real * 3000 / 10_000;
        assertEq(bd.poolQuote, quoteInPool + bd.swapOut, "the pool holds the position less the bond swap's output");
        assertLe(bd.poolQuote, budget, "70 % at most");
        assertLe(budget - bd.poolQuote, Math.sqrt(q / t) + 3, "short of 70 % by the pool's rounding only");
        assertEq(bd.setAside, real - bd.poolQuote + bd.swapOut, "the 30 %, the pool's rounding and the swap's output");
        assertEq(curve.bondSetAside(), bd.setAside);
        assertEq(bd.poolTokens + bd.swapIn, _tok(curve).balanceOf(address(pm)), "the pool holds the position and the swap's tokens");
        assertLt(bd.poolTokens, t * 7 / 10 + 1, "the tokens left cover the pool");
        assertApproxEqRel(bd.poolTokens, Math.mulDiv(t, budget, q), 1e12, "the price-keeping tokens");
        assertEq(bd.burned, t - bd.poolTokens - bd.swapIn, "every other token burned");
        assertEq(_tok(curve).balanceOf(address(curve)), 0);
        assertEq(_tok(curve).totalSupply(), curve.supply() - bd.burned);
        assertEq(_poolPrice(curve), _sqrtAt(curve, q, t), "the pool opens at the curve's price after the buy");
        assertGt(pm.liquidity(curve.poolId()), 0);
    }

    /// A plain quote's last buy of any size from the least that reaches the end to 1e29 (a hundred billion
    /// tokens of the quote), any creator tax: bought whole (the buyer down by exactly what he sent, the
    /// tokens `curveBuy` gives for all of it, after `previewBuy` said so), the bond's amounts to the unit,
    /// the fees booked by their formula and the bond's set-aside, the curve holding exactly its fees, the
    /// owner paid nothing at the bond; then both claims empty the curve.
    function testFuzz_APlainLastBuyOfAnySizeIsBoughtWholeAndBondsToTheUnit(uint256 lastIn, uint16 tax, uint8 pick) public {
        tax = uint16(bound(tax, 0, 1000));
        uint256 threshold = _pickPlainTarget(pick);
        Curve curve = _launch(address(qt), tax);
        assertEq(curve.threshold(), threshold);
        vm.prank(holders[0]);
        curve.buy(threshold * 5 / 8, 0);
        lastIn = bound(lastIn, _toTheEnd(curve, 75 + tax), Math.min(1e29, threshold * 1e8));
        (uint256 q0, uint256 t0) = curve.getReserves();
        (uint256 c0, uint256 p0) = (curve.creatorFees(), curve.protocolFees());
        (uint256 out, uint256 fee, uint256 taxPaid, uint256 net) = curveBuy(q0, t0, lastIn, 75, tax);
        (uint256 previewed, uint256 fee_, uint256 tax_) = curve.previewBuy(lastIn, holders[1]);
        assertEq(previewed, out);
        assertEq(fee_, fee);
        assertEq(tax_, taxPaid);
        uint256 paid0 = qt.balanceOf(holders[1]);
        uint256 owner0 = qt.balanceOf(owner);

        vm.recordLogs();
        vm.prank(holders[1]);
        uint256 got = curve.buy(lastIn, out);
        Bond memory bond = _bonded(vm.getRecordedLogs(), address(curve));

        assertTrue(curve.bonded());
        assertEq(got, out, "curveBuy's tokens for all of it");
        assertEq(_tok(curve).balanceOf(holders[1]), out);
        assertEq(paid0 - qt.balanceOf(holders[1]), lastIn, "bought whole: no change");
        (uint256 q, uint256 t) = curve.getReserves();
        assertEq(q, q0 + net);
        assertEq(t, t0 - out);
        _assertBond(curve, bond, qt.balanceOf(address(pm)));
        uint256 toProtocol = fee * 3000 / 10_000;
        assertEq(curve.protocolFees(), p0 + toProtocol + bond.setAside, "the protocol: its fee and the set-aside");
        assertEq(curve.creatorFees(), c0 + fee - toProtocol + taxPaid, "the creator: his fee and tax");
        assertEq(qt.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees(), "solvent to the unit");
        assertEq(qt.balanceOf(owner), owner0, "the bond pays no one");

        uint256 pf = curve.protocolFees();
        vm.prank(owner);
        curve.claim(true, pf, owner, 0, _noRoutes(), 0, 0);
        uint256 cfees = curve.creatorFees();
        vm.prank(maker);
        curve.claim(false, cfees, maker, 0, _noRoutes(), 0, 0);
        assertEq(qt.balanceOf(address(curve)), 0, "both claims empty it");
    }

    /// An ETF quote's last buy in USDG of any size from one threshold's worth (past the end at any tax) to 250
    /// of them: every share it minted is bought (the buyer down by exactly his USDG, no leg, no share, no USDG
    /// back; the tokens `curveBuy` gives for those shares), the bond's amounts to the unit in shares, the
    /// protocol's fees by formula and set-aside, the curve holding exactly its fees in shares; then both
    /// claims in kind empty it.
    function testFuzz_AnEtfLastBuyOfAnySizeBuysEveryShareAndBondsToTheUnit(uint256 usdgIn, uint16 tax, uint8 pick) public {
        tax = uint16(bound(tax, 0, 1000));
        uint256[] memory five = new uint256[](5);
        (five[0], five[1], five[2], five[3], five[4]) = (1000e18, 2000e18, 5000e18, 8000e18, 15_000e18);
        vm.prank(owner);
        cf.setEtfThresholds(five);
        etfPick = five[pick % 5];
        (Etf etf, Curve curve) = _launchEtf(tax);
        assertEq(curve.threshold(), etfPick);
        _buyUsdg(curve, holders[0], etfPick / 2e12);
        usdgIn = bound(usdgIn, etfPick / 1e12, etfPick * 250 / 1e12);
        (uint256 q0, uint256 t0) = curve.getReserves();
        uint256 p0 = curve.protocolFees();
        address buyer = holders[1];
        uint256 a0 = a.balanceOf(buyer);
        uint256 b0 = b.balanceOf(buyer);
        uint256 c0 = c.balanceOf(buyer);
        uint256 usdg0 = usdg.balanceOf(buyer);
        uint256 held0 = etf.balanceOf(address(curve));

        Etf.Route[] memory r = _buyRoutes(etf, usdgIn, false);
        vm.recordLogs();
        vm.prank(buyer);
        uint256 got = curve.buyWithUsdg(usdgIn, r, 1, 1, new Etf.Route[](0), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(curve.bonded(), "past the end");
        Bond memory bd = _bonded(logs, address(curve));

        // The shares the buy took; what the curve gained beyond them is the reserve ETF's management fee.
        uint256 bought = _boughtShares(logs, address(curve));
        assertLe(bought, etf.balanceOf(address(curve)) + bd.poolQuote - held0);
        (uint256 out, uint256 fee,, uint256 net) = curveBuy(q0, t0, bought, 75, tax);
        assertEq(got, out, "curveBuy's tokens for every share minted");
        (uint256 q, uint256 t) = curve.getReserves();
        assertEq(q, q0 + net);
        assertEq(t, t0 - out);
        assertEq(usdg0 - usdg.balanceOf(buyer), usdgIn, "his USDG, to the wei");
        assertEq(a.balanceOf(buyer), a0, "no leg");
        assertEq(b.balanceOf(buyer), b0, "no leg");
        assertEq(c.balanceOf(buyer), c0, "no leg");
        assertEq(etf.balanceOf(buyer), 0, "no share");
        _assertBond(curve, bd, etf.balanceOf(address(pm)));
        assertEq(curve.protocolFees(), p0 + fee * 3000 / 10_000 + bd.setAside, "the protocol: its fee and the set-aside");
        assertEq(etf.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees(), "solvent to the unit");

        uint256 pf = curve.protocolFees();
        vm.prank(owner);
        curve.claim(true, pf, owner, 1, _noRoutes(), 0, 0);
        uint256 cfees = curve.creatorFees();
        vm.prank(maker);
        curve.claim(false, cfees, maker, 1, _noRoutes(), 0, 0);
        assertEq(etf.balanceOf(address(curve)), 0, "both claims empty it");
    }

    /// The `quoteIn` of the curve's `Bought`: the shares the buy took.
    function _boughtShares(Vm.Log[] memory logs, address curve) internal pure returns (uint256 quoteIn) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == curve && logs[i].topics[0] == Curve.Bought.selector) {
                (quoteIn,,,,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
                return quoteIn;
            }
        }
        revert("no Bought");
    }

    // ------------------------------------------------------------- the cap ---

    /// The largest `quoteIn` one buy from the base price may take on a curve of `threshold` and `supply`,
    /// at the curve's fee alone (the creator's first buy): the last that `curveFits`, by bisection (the
    /// test is monotone in `quoteIn`).
    function _cap(uint256 threshold, uint256 supply) internal pure returns (uint256 lo) {
        uint256 q = threshold * 2 / 5;
        lo = 1;
        uint256 hi = 1 << 200;
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            (uint256 out,,, uint256 net) = curveBuy(q, supply, mid, 75, 0);
            if (curveFits(q + net, supply - out)) lo = mid;
            else hi = mid;
        }
    }

    /**
     * The cap, in the quote's raw units, for one buy from the base price: 8 000 shares, 1 M tokens:
     * 2.448e32 (2.4e14 shares, 30 billion times the threshold); 1 B tokens: 7.741e33. 4.2 WETH, 1 M
     * tokens: 5.609e30 (5.6e12 WETH); 1 B tokens: 1.774e32. Every one far past any quote's supply; the reserves at
     * the cap leave the curve millions of raw tokens and the pool's quote under 2^127. One unit past it
     * is refused.
     */
    function test_TheCapIsTheLargestBuyWhosePoolOpens() public pure {
        uint256[2] memory thresholds = [uint256(8000e18), 4.2e18];
        uint256[2] memory supplies = [uint256(1e24), 1e27];
        uint256[4] memory expected = [uint256(2448e29), 7741e30, 5609e27, 1774e29];
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 j = 0; j < 2; j++) {
                uint256 cap = _cap(thresholds[i], supplies[j]);
                console2.log("threshold", thresholds[i], "supply", supplies[j]);
                console2.log("  largest buy from the base price, raw", cap);
                assertApproxEqRel(cap, expected[i * 2 + j], 0.001e18);
                uint256 q = thresholds[i] * 2 / 5;
                (uint256 out,,, uint256 net) = curveBuy(q, supplies[j], cap, 75, 0);
                assertTrue(curveFits(q + net, supplies[j] - out));
                assertGt(supplies[j] - out, 1e6, "tokens left for the pool");
                (out,,, net) = curveBuy(q, supplies[j], cap + 1, 75, 0);
                assertFalse(curveFits(q + net, supplies[j] - out), "one unit more is past the cap");
            }
        }
    }

    /// At the edge on a launched 4.2 WETH curve of 1 M tokens: the largest buy is bought whole and bonds,
    /// the pool opened at its price; one unit more is refused `BuyTooLarge` and `previewBuy` says zeros.
    function test_AtTheCapTheLastBuyBondsAndOneUnitMoreIsRefused() public {
        uint256 cap = _cap(4.2e18, 1e24);
        address buyer = holders[2];
        weth.mint(buyer, cap + 1);
        Curve curve = _bareWeth();
        vm.prank(buyer);
        weth.approve(address(curve), type(uint256).max);
        (uint256 q, uint256 t) = curve.getReserves();
        (uint256 out,,, uint256 net) = curveBuy(q, t, cap + 1, 75, 0);
        (uint256 previewed,,) = curve.previewBuy(cap + 1, buyer);
        assertEq(previewed, 0, "previewBuy past the cap: zeros");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Curve.BuyTooLarge.selector, q + net, t - out));
        curve.buy(cap + 1, 0);

        vm.recordLogs();
        vm.prank(buyer);
        uint256 got = curve.buy(cap, 0);
        Bond memory bond = _bonded(vm.getRecordedLogs(), address(curve));
        assertTrue(curve.bonded());
        assertEq(weth.balanceOf(buyer), 1, "all of it");
        assertEq(got + bond.poolTokens + bond.swapIn + bond.burned, 1e24, "every token sold, pooled, swapped in or burned");
        _assertBond(curve, bond, weth.balanceOf(address(pm)));
        assertEq(weth.balanceOf(address(curve)), curve.creatorFees() + curve.protocolFees(), "solvent to the unit");
    }

    /// A 1 M-token WETH curve with no first buy, the snipe tax past.
    function _bareWeth() internal returns (Curve curve) {
        vm.prank(maker);
        curve = cf.launchBare{ value: LAUNCH_FEE }("Robin Coin", "ROBIN", "", _noProfileC(), address(weth), 0, 1_000_000, new address[](0));
        vm.warp(vm.getBlockTimestamp() + 3);
        assertEq(curve.reserved(), curveReserved(1e24));
    }
}
