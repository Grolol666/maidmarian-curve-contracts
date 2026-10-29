// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TickMath } from "../src/uniswap/TickMath.sol";
import { IPoolManagerV4, curveBuy } from "../src/MaidMarianLaunchCurve.sol";
import { MaidMarianTokenLauncherV5 as Launcher } from "../src/MaidMarianTokenLauncherV5.sol";
import { MaidMarianLaunchCurveV5 as Curve } from "../src/MaidMarianLaunchCurveV5.sol";
import { V4Trader } from "./CurveFixtures.sol";
import { LauncherV5Base } from "./MaidMarianLaunchCurveV5.t.sol";

/**
 * Offline: what a cheating creator, a sandwicher or the market alone does to a "STOCKS are
 * SEED" bond, on the real launcher v5, curve v5, token and hook over the v5 suite's mocks (`LauncherV5Base`: USDG 6
 * decimals, A / B / C at 500 / 400 / 250 USDG, 40 / 30 / 30, the 5 000 USDG target). Each test is one finding of
 * the security review, turned into regressions once fixed (the first buy follows
 * the weights, its units are the stocks it got at TWAP, every pool sized by the TWAP value it gets, no clamp); each
 * test now claims the fixed behaviour, the finding as it was read below:
 *  - F1: the bond clamps each stock's share of the tokens to its weight +- 25 % (v4's F1 fix), but nothing in v5 holds
 *    the reserve's composition to the weights - the first buy's `parts` were the creator's (since removed: the
 *    contract splits every buy, author 2026-10-26), and the site then split
 *    every buy as the reserve is. A basket launched 99.98 / 0.01 / 0.01 opens B's and C's pools with the token
 *    thousands of times cheaper than in A's, and an arbitrageur paying 20 USDG of B and C takes 40 % of the stocks the
 *    holders' pools hold. The same trade on an honest bond loses money. The market alone (A x2 over the curve's life)
 *    opens the pools 20 % apart.
 *  - F2: the first buy's `minTokensOut` guards nothing: its units are `net` whatever the swaps brought, so a sandwich of
 *    the launch takes the creator's USDG, and leaves the unit defined on dust - the next 100 USDG buy at the weights takes
 *    98 % of the supply and bonds the curve on pools worth 100 USDG.
 *
 *   forge test --match-contract MaidMarianLauncherV5SecurityTest -vv
 */
abstract contract LauncherV5SecurityBase is LauncherV5Base {
    uint256 internal constant BPS = 10_000;

    /// Launches (the first buy by the weights, the contract's split), alice buys 4 980 USDG, A
    /// +10 % bonds it (`bond()` by a stranger), then the arbitrage: 10 USDG of B and 10 of C spent on the token in their
    /// pools, the token sold in A's. Returns B's opening price over A's (1e18 = equal), the take in raw USDG and the
    /// pools' stock value at the bond.
    function _launchBuyBondAndArb() internal returns (uint256 gap, int256 take, uint256 pooled) {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 4980e6);
        _move(0, 550);
        assertTrue(c.bondDue());
        pooled = _pooledValue(c);
        vm.prank(carol);
        c.bond();
        assertEq(c.bondedStocks(), 7, "every pool opened");
        gap = _openPriceUsd(c, 0) * 1e18 / _openPriceUsd(c, 1);
        V4Trader trader = new V4Trader(IPoolManagerV4(address(pm)));
        take = _roundTrip(c, trader, 1, 0, 10e6) + _roundTrip(c, trader, 2, 0, 10e6);
    }

    function _launchArgsMin(uint256 minTokensOut) internal view returns (Launcher.Launch memory l) {
        l = _launchArgs(_basket(), TARGET, 0);
        l.minTokensOut = minTokensOut;
    }

    /// The stocks the pools will hold at the bond (75 % of each count), in raw USDG at the mocks' prices.
    function _pooledValue(Curve c) internal view returns (uint256 value) {
        for (uint256 i = 0; i < 3; i++) {
            uint256 h = c.held(i);
            value += (h - h * 2500 / BPS) * prices[i] / 1e12;
        }
    }

    /// The token's price in USDG at stock i's pool's opening `sqrtPriceX96`, scaled 1e18 (stock per token x price).
    function _openPriceUsd(Curve c, uint256 i) internal view returns (uint256) {
        address s = address(stock[i]);
        uint256 sqrtP = pm.openedAt(keccak256(abi.encode(c.poolKeyIn(s))));
        uint256 ratio = c.token() < s ? Math.mulDiv(sqrtP * sqrtP, 1e18, 1 << 192) : Math.mulDiv(1 << 192, 1e18, sqrtP * sqrtP);
        return ratio * prices[i];
    }

    /// `trader` pays `payUsdg` worth of stock `from` for the token in its pool, sells every token got in stock `to`'s
    /// pool; the take is what it holds in `to` less what it paid in `from`, in raw USDG at the mocks' prices.
    function _roundTrip(Curve c, V4Trader trader, uint256 from, uint256 to, uint256 payUsdg) internal returns (int256 take) {
        uint256 pay = payUsdg * 1e12 / prices[from];
        stock[from].mint(address(trader), pay);
        IERC20 token = IERC20(c.token());
        uint256 tokensBefore = token.balanceOf(address(trader));
        uint256 toBefore = stock[to].balanceOf(address(trader));
        IPoolManagerV4.PoolKey memory key = c.poolKeyIn(address(stock[from]));
        bool zeroForOne = key.currency0 == address(stock[from]);
        trader.swapExactIn(key, zeroForOne, pay, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        uint256 tokens = token.balanceOf(address(trader)) - tokensBefore;
        assertGt(tokens, 0, "the pool sold tokens");
        key = c.poolKeyIn(address(stock[to]));
        zeroForOne = key.currency0 == c.token();
        trader.swapExactIn(key, zeroForOne, tokens, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        uint256 gotTo = stock[to].balanceOf(address(trader)) - toBefore;
        // forge-lint: disable-next-line(unsafe-typecast)
        take = int256(gotTo * prices[to] / 1e12) - int256(payUsdg);
    }

    /// Stock `i`'s 30 min TWAP alone reads `price` (whole USDG); its spot and the router stay.
    function _moveTwap(uint256 i, uint256 price) internal {
        bool tokenFirst = address(stock[i]) < address(usdg);
        int24 tick = _tickAt(price * 1e18);
        pool[i].setAverageTick(tokenFirst ? tick : -tick);
    }

    /// Stock `i`'s spot (its pool's `slot0`, the router's rate, the prices the tests value with) alone moves to `price`;
    /// its TWAP stays.
    function _moveSpot(uint256 i, uint256 price) internal {
        prices[i] = price;
        _routerAt(address(stock[i]), price * 1e18);
    }
}

contract MaidMarianLauncherV5SecurityTest is LauncherV5SecurityBase {
    // --------------------------------------------------------------------------------------------- F1 ---

    /// F1, fixed. Was: the creator's first buy put 99.98 % of its USDG in A (`parts`), the clamp opened B's and C's
    /// pools 4 952 x cheaper than A's, and an arbitrageur took 45.7 % of the pools' stock for 20 USDG. Now no caller
    /// splits a buy (`parts` gone from the ABI): the first by the weights, every later one by the reserve's mix at
    /// TWAP; every pool opens at one price and the two round trips lose their fees.
    function test_F1_NoCallerSplitsABuyAndEveryPoolOpensAtOnePrice() public {
        (uint256 gap, int256 take, uint256 pooled) = _launchBuyBondAndArb();
        assertApproxEqRel(gap, 1e18, 1e15, "one price in every pool");
        assertLt(take, 0, "the two round trips lose their fees");
        emit log_named_uint("F1: B's opening price over A's, 1e18 = equal, inverse", 1e36 / gap);
        emit log_named_int("F1: the two round trips, raw USDG", take);
        emit log_named_uint("F1: the pools' stock at the bond, raw USDG", pooled);
    }

    /// F1, the market alone, fixed. Was: A doubling before the bond made A 57 % of the value for a 40 % weight, the
    /// clamp opened A's pool 1.20 x dearer than B's and C's and 80 USDG of round trips took 8.16 USDG. Now each pool
    /// is sized by the TWAP value it gets: the three open at one price and the round trips lose their fees.
    function test_F1_AStockDoublingOverTheCurvesLifeStillOpensEveryPoolAtOnePrice() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 4980e6);
        _move(0, 1000);
        assertTrue(c.bondDue(), "A x2 brings the reserve over the target at TWAP");
        uint256 pooled = _pooledValue(c);
        vm.prank(carol);
        c.bond();
        uint256 pA = _openPriceUsd(c, 0);
        uint256 pB = _openPriceUsd(c, 1);
        uint256 pC = _openPriceUsd(c, 2);
        assertApproxEqRel(pB, pC, 1e15, "B and C open alike");
        uint256 gap = pA * 1e18 / pB;
        assertApproxEqRel(gap, 1e18, 1e15, "A's pool opens at B's price");
        V4Trader trader = new V4Trader(IPoolManagerV4(address(pm)));
        // The same 40 USDG of B and of C sold through the token into A's pool.
        int256 take = _roundTrip(c, trader, 1, 0, 40e6) + _roundTrip(c, trader, 2, 0, 40e6);
        assertLt(take, 0, "nothing on the table: the round trips lose their fees");
        emit log_named_int("F1 drift: take, raw USDG, for 80 USDG of B and C", take);
        emit log_named_uint("F1 drift: the pools' stock at the bond, raw USDG", pooled);
        emit log_named_uint("F1 drift: A's opening price over B's, 1e18 = equal", gap);
    }

    // --------------------------------------------------------------------------------------------- F2 ---

    /// F2, fixed. Was: a launch whose swaps were sandwiched to a thousandth still met the creator's `minTokensOut` to
    /// the wei (units = the USDG paid), and bob's next 100 USDG took 98 % of the supply and bonded the curve. Now the
    /// first buy's units are the stocks it got at TWAP: the sandwiched launch fails the creator's minimum. Launched
    /// anyway with no minimum, the unit is worth what it holds: bob's 100 USDG gets about 100 USDG of units, a small
    /// share of the supply, and the curve does not bond.
    function test_F2_ASandwichedLaunchFailsTheCreatorsMinimumAndTheUnitKeepsItsWorth() public {
        (uint256 fair,,,) = curveBuy(TARGET / 3, SUPPLY, FIRST_BUY - FIRST_BUY * 75 / BPS, 0, 0);
        for (uint256 i = 0; i < 3; i++) {
            router.setPairRate(address(usdg), address(stock[i]), 1e48 / (prices[i] * 1e18) / 1000);
        }
        // The creator's minimum, 1 % under the honest first buy's tokens, refuses the sandwiched launch.
        vm.prank(maker);
        vm.expectPartialRevert(Curve.TooFewTokens.selector);
        lv5.launch{ value: LAUNCH_FEE }(_launchArgsMin(fair * 99 / 100));
        vm.prank(maker);
        Curve c = lv5.launch{ value: LAUNCH_FEE }(_launchArgsMin(1));
        uint256 honestNet = FIRST_BUY - FIRST_BUY * 75 / BPS;
        assertLt(c.realUnits(), honestNet / 900, "units: what the first buy got, a thousandth");
        for (uint256 i = 0; i < 3; i++) {
            _routerAt(address(stock[i]), prices[i] * 1e18);
        }
        vm.warp(vm.getBlockTimestamp() + 10);
        uint256 real = c.realUnits();
        vm.prank(bob);
        uint256 got = lv5.buy(address(c), 100e6, 0, 1);
        uint256 bobUnits = c.realUnits() - real;
        assertApproxEqRel(bobUnits, 100e6 - 100e6 * 75 / BPS, 1e15, "bob's 100 USDG: 99.25 USDG of units, one per raw USDG");
        assertLt(got, SUPPLY / 10, "a small share of the supply");
        assertFalse(c.bonded(), "the curve does not bond on 110 USDG");
        emit log_named_uint("F2 fixed: bob's units for 100 USDG, raw USDG", bobUnits);
        emit log_named_uint("F2 fixed: bob's tokens, of 1e27", got);
    }
}

/**
 * The security review, second pass (the first buy
 * by the weights, counted at TWAP; the pools sized by TWAP value, no clamp; `lowerProtocolShare`; no size limit on a
 * buy; the bond at the reserve's TWAP value alone). Each test is one question of the pass, its numbers in
 * the review. The mock's swaps never cross a range's edge, so what the position
 * of tokens above the opening price adds to an arbitrage is reasoned there, not measured here.
 *
 *   forge test --match-contract MaidMarianLauncherV5SecurityPass2Test -vv
 */
contract MaidMarianLauncherV5SecurityPass2Test is LauncherV5SecurityBase {
    /// After a full sell-out the curve keeps one unit of rounding (both doors round the reserve up), so the next buy
    /// is an ordinary buy, not a first one: split by that unit's mix at TWAP (about one raw USDG of each stock, read
    /// coarsely), credited the fewest units its stocks bring against that unit's claim, no claim per unit falls; a TWAP
    /// 20 % over or under the spot moves the split, never a claim. F1 / F2 need no first-buy rule here: the unit's worth
    /// survives the sell-out. (Was, with the caller's `parts`: a crafted split donated all but a thousandth.)
    function test_AfterAFullSellOutTheNextBuyIsAnOrdinaryOneAgainstTheOneUnitLeft() public {
        Curve c = _launch(TARGET, 0);
        uint256 a = _buy(c, alice, 1000e6);
        _sell(c, alice, a);
        _sell(c, maker, IERC20(c.token()).balanceOf(maker));
        assertEq(IERC20(c.token()).balanceOf(address(c)), SUPPLY, "every token is back");
        assertEq(c.realUnits(), 1, "one unit of rounding stays (these amounts)");
        uint256[3] memory h = [c.held(0), c.held(1), c.held(2)];
        uint256 expected = type(uint256).max;
        for (uint256 i = 0; i < 3; i++) {
            assertGt(h[i], 0, "its claim on each stock");
            assertApproxEqRel(h[i] * prices[i] / 1e12, [uint256(4000), 3000, 3000][i] / 10_000, 2e17, "about one raw USDG of each stock at the weights");
        }
        uint256 net = 100e6 - 100e6 * 75 / BPS;
        uint256 snap = vm.snapshotState();
        _moveTwap(0, 600);
        vm.prank(bob);
        lv5.buy(address(c), 100e6, 0, 1);
        uint256 units = c.realUnits() - 1;
        for (uint256 i = 0; i < 3; i++) {
            expected = Math.min(expected, (c.held(i) - h[i]) / h[i]);
            assertGe(c.held(i) * 1, h[i] * c.realUnits(), "no claim per unit fell");
        }
        assertEq(units, expected, "the fewest units any stock brought against the one unit's claim");
        assertLe(units, net * 2, "at most about its USDG, the one unit's claim read coarsely");
        emit log_named_uint("after a sell-out, A's TWAP 600: units for 99.25 USDG", units);
        vm.revertToState(snap);
        _moveTwap(0, 400);
        vm.prank(bob);
        lv5.buy(address(c), 100e6, 0, 1);
        for (uint256 i = 0; i < 3; i++) {
            assertGe(c.held(i) * 1, h[i] * c.realUnits(), "no claim per unit fell");
        }
        emit log_named_uint("after a sell-out, A's TWAP 400: units for 99.25 USDG", c.realUnits() - 1);
    }

    /// `lowerProtocolShare` only deepens the pools: lowered to 0 in front of the same `bond()`, every pool opens at the
    /// price it would have opened at with 25 %, holds 4/3 of the stock, the owner's pots keep the display swaps' dust
    /// alone; after the bond it reverts `AlreadyBonded`, and a share not under the current one `ShareNotLower`.
    function test_LoweringTheProtocolShareInFrontOfABondDeepensThePoolsAtTheSamePrice() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 4980e6);
        _move(0, 550);
        assertTrue(c.bondDue());
        uint256[3] memory h = [c.held(0), c.held(1), c.held(2)];
        uint256 snap = vm.snapshotState();
        vm.prank(carol);
        c.bond();
        uint256[3] memory price25;
        uint256[3] memory stock25;
        for (uint256 i = 0; i < 3; i++) {
            price25[i] = _openPriceUsd(c, i);
            stock25[i] = stock[i].balanceOf(address(pm));
            assertApproxEqRel(stock25[i], h[i] * 3 / 4, 1e12, "25 %: the pools hold 3/4 of the stock");
        }
        vm.revertToState(snap);
        vm.prank(owner);
        c.lowerProtocolShare(0);
        assertEq(c.bondShareBps(), 0);
        vm.prank(carol);
        c.bond();
        for (uint256 i = 0; i < 3; i++) {
            assertApproxEqRel(_openPriceUsd(c, i), price25[i], 1e12, "the same opening price: the share scales both sides");
            assertApproxEqRel(stock[i].balanceOf(address(pm)), h[i], 1e12, "0 %: the pools hold every stock");
            assertLt(c.ownerPot(address(stock[i])), h[i] / 1e6, "the owner's pot: the display swap's dust");
        }
        assertEq(IERC20(c.token()).balanceOf(address(c)), 0, "no token kept");
        vm.prank(owner);
        vm.expectRevert(Curve.AlreadyBonded.selector);
        c.lowerProtocolShare(0);
        Curve d = _launch(TARGET, 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Curve.ShareNotLower.selector, 2500, 2500));
        d.lowerProtocolShare(2500);
        vm.prank(owner);
        d.lowerProtocolShare(1000);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Curve.ShareNotLower.selector, 1000, 1500));
        d.lowerProtocolShare(1500);
    }

    /// No size limit, share lowered to 0: bob's 100 000 USDG on a 5 000 curve bonds inside his buy, every pool at one
    /// price with every stock in it, no token kept; and the pools cannot be a pump: sold back whole into the three
    /// pools, his 61 % of the supply fetches less than the 100 000 he put in (the measured figure logged).
    function test_AHugeBuyAtZeroShareBondsAtOnePriceAndCannotTakeOutMoreThanItPutIn() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 1000e6);
        vm.prank(owner);
        c.lowerProtocolShare(0);
        uint256 pmTokens = IERC20(c.token()).balanceOf(address(pm));
        vm.prank(bob);
        uint256 got = lv5.buy(address(c), 100_000e6, 0, 1);
        assertTrue(c.bonded(), "bonded inside the buy");
        assertGt(got, SUPPLY * 60 / 100, "bob holds 61 % of the supply: 97 % of what the curve had after alice's 37.5 %");
        assertEq(IERC20(c.token()).balanceOf(address(c)), 0, "the curve keeps no token");
        uint256 inPools = IERC20(c.token()).balanceOf(address(pm)) - pmTokens;
        assertEq(
            inPools + got + IERC20(c.token()).balanceOf(maker) + IERC20(c.token()).balanceOf(alice) + IERC20(c.token()).balanceOf(address(0x000000000000000000000000000000000000dEaD)),
            IERC20(c.token()).totalSupply(),
            "every token is in a pool, a hand or 0xdEaD (the rounding)"
        );
        uint256 p = _openPriceUsd(c, 0);
        assertApproxEqRel(_openPriceUsd(c, 1), p, 1e15, "one price");
        assertApproxEqRel(_openPriceUsd(c, 2), p, 1e15);
        V4Trader trader = new V4Trader(IPoolManagerV4(address(pm)));
        IERC20 launched = IERC20(c.token());
        vm.prank(bob);
        launched.transfer(address(trader), got);
        uint256 back;
        for (uint256 i = 0; i < 3; i++) {
            uint256 before = stock[i].balanceOf(address(trader));
            IPoolManagerV4.PoolKey memory key = c.poolKeyIn(address(stock[i]));
            bool zeroForOne = key.currency0 == c.token();
            uint256 part = i == 2 ? IERC20(c.token()).balanceOf(address(trader)) : got / 3;
            trader.swapExactIn(key, zeroForOne, part, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
            back += (stock[i].balanceOf(address(trader)) - before) * prices[i] / 1e12;
        }
        assertLt(back, 100_000e6, "less than he put in");
        emit log_named_uint("huge buy: USDG back from dumping 61 % of the supply into the pools, of 100 000", back);
    }

    /// What a pushed TWAP buys now that nothing clamps it: A's TWAP read 2x its spot (held 30 min, v4's price list for
    /// the cost) bonds a reserve worth 72 % of the target and gives A's pool 57 % of the tokens for 40 % of the value,
    /// the token half its price there; A sold through the token into B's and C's pools takes the logged amount, the
    /// v4 F1 figure on v5's pools (the position above the opening price adds to it on chain, reasoned in the review).
    function test_ATwapPushedTwoFoldBondsEarlyOpensItsPoolAtHalfPriceAndTheArbTakesThisMuch() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 3590e6);
        assertFalse(c.bondDue());
        _moveTwap(0, 1000);
        assertTrue(c.bondDue(), "the push bonds a reserve worth 72 % of the target at spot");
        uint256 pooled = _pooledValue(c);
        uint256 poolA = (c.held(0) - c.held(0) * 2500 / BPS) * prices[0] / 1e12;
        assertLt(pooled, TARGET * 75 / 100 * 73 / 100);
        vm.prank(carol);
        c.bond();
        uint256 gap = _openPriceUsd(c, 1) * 1e18 / _openPriceUsd(c, 0);
        assertApproxEqRel(gap, 2e18, 1e15, "the token half its price in A's pool at spot");
        V4Trader trader = new V4Trader(IPoolManagerV4(address(pm)));
        int256 take = _roundTrip(c, trader, 0, 1, 100e6) + _roundTrip(c, trader, 0, 2, 100e6);
        assertGt(take, 0, "the push leaves a take");
        emit log_named_int("push x2: take, raw USDG, for 200 USDG of A", take);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit log_named_uint("push x2: take, bps of A's pool", uint256(take) * BPS / poolA);
        emit log_named_uint("push x2: the pools' stock at spot, raw USDG", pooled);
    }

    /// The TWAP's own lag, nobody pushing: A's spot 10 % under its 30 min TWAP at the bond (a stock falling in the last
    /// half hour) opens A's pool with the token 11 % cheaper than B's and C's; A sold through the token into their pools
    /// takes the logged amount, under 1 % of A's pool - the price of sizing by a 30 min average.
    function test_ATenPercentLagBetweenATwapAndItsSpotAtTheBondLeavesUnderOnePercentToTheArbitrage() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 4980e6);
        _move(1, 440);
        assertTrue(c.bondDue());
        _moveSpot(0, 450);
        uint256 poolA = (c.held(0) - c.held(0) * 2500 / BPS) * prices[0] / 1e12;
        vm.prank(carol);
        c.bond();
        uint256 gap = _openPriceUsd(c, 1) * 1e18 / _openPriceUsd(c, 0);
        assertApproxEqRel(gap, uint256(1e18) * 500 / 450, 1e15, "11 % cheaper in A's pool at spot");
        V4Trader trader = new V4Trader(IPoolManagerV4(address(pm)));
        int256 take = _roundTrip(c, trader, 0, 1, 25e6) + _roundTrip(c, trader, 0, 2, 25e6);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertLt(take, int256(poolA / 100), "under 1 % of A's pool");
        emit log_named_int("lag 10 %: take, raw USDG, for 50 USDG of A", take);
        emit log_named_uint("lag 10 %: A's pool at spot, raw USDG", poolA);
    }

    /// F2's cap: a first buy under a lagging TWAP is credited at most its net USDG. A's TWAP 20 % over its spot (A fell
    /// in the last half hour) would read the launch's stocks at 108 % of the USDG paid: credited 100 %. A's TWAP 20 %
    /// under (A rose): credited 92 %, the creator's `minTokensOut` his guard. Never more units than USDG paid.
    function test_AFirstBuyUnderALaggingTwapIsCreditedAtMostItsUsdg() public {
        uint256 net = FIRST_BUY - FIRST_BUY * 75 / BPS;
        uint256 snap = vm.snapshotState();
        _moveTwap(0, 600);
        Curve c = _launch(TARGET, 0);
        assertEq(c.realUnits(), net, "A's TWAP over its spot: the USDG paid, not 108 % of it");
        vm.revertToState(snap);
        _moveTwap(0, 400);
        c = _launch(TARGET, 0);
        assertApproxEqRel(c.realUnits(), net * 92 / 100, 1e15, "A's TWAP under its spot: 8 % fewer units");
        assertLt(c.realUnits(), net);
    }
}

/**
 * The security review, final pass: the contract splits every buy itself (the weights
 * first, then the reserve's mix at TWAP), one TWAP read per transaction, `MaidMarianPoolPrice`, `MaidMarianToken2`,
 * the dust to 0xdEaD, `lowerProtocolShare` on the curve. The new mechanism is the split: a buy's swaps are at spot and
 * its split at TWAP, so when the stocks' TWAP / spot ratios differ the buyer is credited less than his USDG's worth of
 * the basket, the rest left to the holders - never more.
 *
 *   forge test --match-contract MaidMarianLauncherV5SecurityFinalTest -vv
 */
contract MaidMarianLauncherV5SecurityFinalTest is LauncherV5SecurityBase {
    /// The units a buy of `net` USDG is worth at spot: its share of the reserve's spot value.
    function _fairUnits(Curve c, uint256 net) internal view returns (uint256) {
        uint256 value;
        for (uint256 i = 0; i < 3; i++) {
            value += c.held(i) * prices[i] / 1e12;
        }
        return Math.mulDiv(net, c.realUnits(), value);
    }

    /// F4, fixed. Was: the split at TWAP credited bob 98.83 % of his USDG's worth of the basket at spot with A's spot 2 %
    /// over its TWAP (99.20 % 2 % under), the rest left to the holders. Now the split reads the spot, what the swaps pay:
    /// credited 100 % both ways, to the rounding, and no claim per unit falls.
    function test_F4_ABuyUnderAnUnevenTwapLagIsCreditedItsSpotWorth() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 1000e6);
        uint256 net = 1000e6 - 1000e6 * 75 / BPS;
        uint256 snap = vm.snapshotState();
        uint256[2] memory spot = [uint256(510), 490];
        for (uint256 k = 0; k < 2; k++) {
            _moveSpot(0, spot[k]);
            uint256 fair = _fairUnits(c, net);
            uint256[3] memory h = [c.held(0), c.held(1), c.held(2)];
            uint256 real = c.realUnits();
            _buy(c, bob, 1000e6);
            uint256 ratio = (c.realUnits() - real) * 1e18 / fair;
            assertApproxEqRel(ratio, 1e18, 1e12, "credited its spot worth, to the rounding");
            for (uint256 i = 0; i < 3; i++) {
                assertGe(c.held(i) * real, h[i] * c.realUnits(), "no claim per unit falls");
            }
            emit log_named_uint(k == 0 ? "F4 fixed: A spot +2 %, units per 1e18 of spot worth" : "F4 fixed: A spot -2 %, units per 1e18 of spot worth", ratio);
            vm.revertToState(snap);
        }
    }

    /// The reserve's side of F4, fuzzed: whatever each stock's spot does against its TWAP (-20 % to +20 %), an ordinary
    /// buy is never credited more than its USDG's worth of the basket at spot, within one unit of rounding, and no claim
    /// per unit falls - a lag costs the buyer, never the holders (the first pass's invariant on the final split).
    function testFuzz_AnOrdinaryBuyIsNeverCreditedMoreThanItsSpotWorth(uint256 la, uint256 lb, uint256 lc, uint256 usdgIn) public {
        la = bound(la, 800, 1200);
        lb = bound(lb, 800, 1200);
        lc = bound(lc, 800, 1200);
        usdgIn = bound(usdgIn, 1e6, 100_000e6);
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 1000e6);
        _moveSpot(0, 500 * la / 1000);
        _moveSpot(1, 400 * lb / 1000);
        _moveSpot(2, 250 * lc / 1000);
        uint256 net = usdgIn - usdgIn * 75 / BPS;
        uint256 fair = _fairUnits(c, net);
        uint256[3] memory h = [c.held(0), c.held(1), c.held(2)];
        uint256 real = c.realUnits();
        vm.prank(bob);
        lv5.buy(address(c), usdgIn, 0, 1);
        uint256 units = c.quoteReserve() - c.phantomQuote() - real;
        assertLe(units, fair + 1, "never more than its spot worth");
        if (!c.bonded()) {
            for (uint256 i = 0; i < 3; i++) {
                assertGe(c.held(i) * real, h[i] * c.realUnits(), "no claim per unit falls");
            }
        }
    }

    /// The final code keeps the pools their tokens and one price whatever the share and however far the last buy went:
    /// shares 25 %, 10 %, 0 % and a 1 000 or 50 000 USDG crossing buy each open three pools at one price, the curve
    /// keeping no token, the dust at 0xdEaD under 1e-6 token, and the supply the launch's number (no burn).
    function test_ThePoolsAlwaysHaveTheirTokensAtOnePriceOnTheFinalCode() public {
        uint16[3] memory shares = [uint16(2500), 1000, 0];
        uint256[2] memory crossing = [uint256(1000e6), 50_000e6];
        for (uint256 s = 0; s < 3; s++) {
            for (uint256 k = 0; k < 2; k++) {
                uint256 snap = vm.snapshotState();
                Curve c = _launch(TARGET, 0);
                _buy(c, alice, 4200e6);
                if (shares[s] != 2500) {
                    vm.prank(owner);
                    c.lowerProtocolShare(shares[s]);
                }
                uint256 pmTokens = IERC20(c.token()).balanceOf(address(pm));
                _buy(c, bob, crossing[k]);
                assertTrue(c.bonded(), "the crossing buy bonds");
                assertEq(c.bondedStocks(), 7, "three pools");
                IERC20 launched = IERC20(c.token());
                assertEq(launched.balanceOf(address(c)), 0, "no token kept");
                assertLt(launched.balanceOf(c.DEAD()), 1e12, "the dust under 1e-6 token");
                assertEq(launched.totalSupply(), SUPPLY, "no burn: the supply is the launch's");
                assertGt(launched.balanceOf(address(pm)) - pmTokens, 0);
                uint256 p = _openPriceUsd(c, 0);
                assertApproxEqRel(_openPriceUsd(c, 1), p, 1e15, "one price");
                assertApproxEqRel(_openPriceUsd(c, 2), p, 1e15, "one price");
                vm.revertToState(snap);
            }
        }
    }
}
