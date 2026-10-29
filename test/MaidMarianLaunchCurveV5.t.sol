// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TickMath } from "../src/uniswap/TickMath.sol";
import { IUniversalRouter } from "../src/MaidMarianSevenMagnificent.sol";
import { MaidMarianBagPoolOracle } from "../src/MaidMarianBagPoolOracle.sol";
import { IPoolManagerV4, curveBuy, curveSell, curveReserved } from "../src/MaidMarianLaunchCurve.sol";
import { MaidMarianTokenLauncherV5 as Launcher } from "../src/MaidMarianTokenLauncherV5.sol";
import { MaidMarianLaunchCurveV5 as Curve, BasketStock } from "../src/MaidMarianLaunchCurveV5.sol";
import { MaidMarianLaunchHook as Hook } from "../src/MaidMarianLaunchHook.sol";
import { TokenMock, PoolMock, UniversalRouterMock, UniswapV3FactoryMock } from "./Mocks.sol";
import { V4Trader } from "./CurveFixtures.sol";
import { V4RangePoolManagerMock } from "./CurveV5Fixtures.sol";
import { mineLaunchHookSalt } from "../script/DeployTokenLauncher.s.sol";

/// The `sqrtPriceX96` of an 18-decimal `token` at `price18` USDG (18 decimals) against 6-decimal `usdg`.
function spotSqrtPrice(address token, address usdg, uint256 price18) pure returns (uint160) {
    return token < usdg ? uint160(Math.sqrt(Math.mulDiv(price18, 1 << 192, 1e30))) : uint160(Math.sqrt(Math.mulDiv(1e30, 1 << 192, price18)));
}
import { checkProfileDiscord, isAsciiAlnum, BadDiscord } from "../src/MaidMarianTokenChecks.sol";

/**
 * Offline: the launcher v5 "STOCKS are SEED" and its curves on `test/Mocks.sol` (USDG 6
 * decimals, three 18-decimal stocks A / B / C at 500 / 400 / 250 USDG, each on a V3 pool mock whose 30 min TWAP
 * the launcher's own reader `MaidMarianPoolPrice.sol` reads (the real `MaidMarianBagPoolOracle` kept as the reference), the Universal Router mock trading each at its set price both ways)
 * and the V4 PoolManager mock (`CurveFixtures.sol`) etched at the router's `poolManager()`. Prices are of the form
 * 2^a 5^b so every swap is exact to the wei; a TWAP reads one tick (1 bp) under its price. Proves the contracts'
 * arithmetic and refusals against mocks; that the deployed pools, router and PoolManager behave as the mocks do is
 * `MaidMarianLauncherV5.fork.t.sol`.
 *
 *   forge test --match-contract MaidMarianLaunchCurveV5Test -vv
 */
contract LauncherV5Base is Test {
    TokenMock internal usdg;
    UniversalRouterMock internal router;
    UniswapV3FactoryMock internal v3;
    MaidMarianBagPoolOracle internal oracle;
    V4RangePoolManagerMock internal pm;
    Launcher internal lv5;
    TokenMock[3] internal stock;
    PoolMock[3] internal pool;

    address internal owner = makeAddr("owner");
    address internal maker = makeAddr("maker");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant LAUNCH_FEE = 0.0005 ether;
    uint256 internal constant FIRST_BUY = 10e6;
    uint256 internal constant TARGET = 5000e6;
    uint256 internal constant SUPPLY = 1e27;
    uint256[3] internal prices = [uint256(500), 400, 250];

    function setUp() public virtual {
        vm.warp(1_790_000_000);
        usdg = new TokenMock("USDG", "USDG", 6);
        router = new UniversalRouterMock();
        router.setSink(makeAddr("pools"));
        v3 = new UniswapV3FactoryMock();
        oracle = new MaidMarianBagPoolOracle();
        address pmAt = router.poolManager();
        vm.etch(pmAt, address(new V4RangePoolManagerMock()).code);
        pm = V4RangePoolManagerMock(pmAt);
        usdg.mint(address(router), 1e30);
        for (uint256 i = 0; i < 3; i++) {
            stock[i] = new TokenMock(i == 0 ? "A" : i == 1 ? "B" : "C", "S", 18);
            stock[i].mint(address(router), 1e30);
            pool[i] = _poolAt(address(stock[i]), _tickAt(prices[i] * 1e18));
            _routerAt(address(stock[i]), prices[i] * 1e18);
        }
        (bytes32 salt,) = mineLaunchHookSalt(vm.computeCreateAddress(address(this), vm.getNonce(address(this))), pmAt);
        lv5 = new Launcher(IERC20(address(usdg)), IUniversalRouter(address(router)), address(v3), owner, salt);
        vm.startPrank(owner);
        for (uint256 i = 0; i < 3; i++) {
            lv5.addToken(address(stock[i]), address(pool[i]));
        }
        vm.stopPrank();
        address[5] memory who = [maker, alice, bob, carol, owner];
        for (uint256 i = 0; i < who.length; i++) {
            usdg.mint(who[i], 1e15);
            vm.deal(who[i], 1 ether);
            vm.prank(who[i]);
            usdg.approve(address(lv5), type(uint256).max);
        }
    }

    // ------------------------------------------------------------ helpers ---

    function _tickAt(uint256 price18) internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(Math.mulDiv(price18, 1 << 192, 1e30))));
    }

    function _poolAt(address token, int24 tickForToken0) internal returns (PoolMock p) {
        bool tokenFirst = token < address(usdg);
        p = tokenFirst ? new PoolMock(token, address(usdg)) : new PoolMock(address(usdg), token);
        p.setFee(3000);
        p.setAverageTick(tokenFirst ? tickForToken0 : -tickForToken0);
        v3.setPool(p);
    }

    /// The router trades `token` at `price18` both ways, and its pool's spot (`slot0`) says so exactly.
    function _routerAt(address token, uint256 price18) internal {
        router.setPairRate(address(usdg), token, 1e48 / price18);
        router.setPairRate(token, address(usdg), price18 / 1e12);
        address p = v3.getPool(token, address(usdg), 3000);
        if (p != address(0)) PoolMock(p).setSpotSqrtPrice(spotSqrtPrice(token, address(usdg), price18));
    }

    /// Stock `i` trades at `price` (whole USDG) both ways and its TWAP reads it, as after 30 min there.
    function _move(uint256 i, uint256 price) internal {
        prices[i] = price;
        bool tokenFirst = address(stock[i]) < address(usdg);
        int24 tick = _tickAt(price * 1e18);
        pool[i].setAverageTick(tokenFirst ? tick : -tick);
        _routerAt(address(stock[i]), price * 1e18);
    }

    function _basket() internal view returns (BasketStock[] memory b) {
        b = new BasketStock[](3);
        b[0] = BasketStock({ token: address(stock[0]), bps: 4000 });
        b[1] = BasketStock({ token: address(stock[1]), bps: 3000 });
        b[2] = BasketStock({ token: address(stock[2]), bps: 3000 });
    }

    function _none() internal pure returns (Launcher.Profile memory) {
        return Launcher.Profile({ description: "", x: "", telegram: "", website: "", discord: "" });
    }

    function _launchArgs(BasketStock[] memory b, uint256 target, uint16 tax) internal pure returns (Launcher.Launch memory) {
        return Launcher.Launch({
            name: "Robin Stocks",
            symbol: "ROBS",
            logoPng: "",
            profile: _none(),
            stocks: b,
            target: target,
            creatorTaxBps: tax,
            supply: 1_000_000_000,
            firstBuy: FIRST_BUY,
            v4Mask: 0,
            minTokensOut: 1,
            snipeExempt: new address[](0)
        });
    }

    function _launch(uint256 target, uint16 tax) internal returns (Curve c) {
        vm.prank(maker);
        c = lv5.launch{ value: LAUNCH_FEE }(_launchArgs(_basket(), target, tax));
        vm.warp(vm.getBlockTimestamp() + 10);
    }

    /// `who` buys `usdgIn`; the contract splits it.
    function _buy(Curve c, address who, uint256 usdgIn) internal returns (uint256 out) {
        vm.prank(who);
        out = lv5.buy(address(c), usdgIn, 0, 1);
    }

    function _sell(Curve c, address who, uint256 tokensIn) internal returns (uint256 out) {
        IERC20 t = IERC20(c.token());
        vm.startPrank(who);
        t.approve(address(lv5), tokensIn);
        out = lv5.sell(address(c), tokensIn, 0, 0);
        vm.stopPrank();
    }

    /// The curve's stock beyond its count and its pots: 0 unless donated.
    function _uncounted(Curve c, uint256 i) internal view returns (int256) {
        address s = address(stock[i]);
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(IERC20(s).balanceOf(address(c))) - int256(c.held(i) + c.ownerPot(s) + c.creatorPot(s));
    }
}

contract MaidMarianLaunchCurveV5Test is LauncherV5Base {
    // -------------------------------------------------------------- launch ---

    /// The launch writes the creator's basket, target, tax, supply and the launcher's bond share into the clone,
    /// creates the token, and the first buy defines the unit: units = the USDG swapped, each stock its share.
    function test_TheLaunchWritesTheBasketAndTheFirstBuyDefinesTheUnit() public {
        Curve c = _launch(TARGET, 0);
        assertEq(c.creator(), maker);
        assertEq(c.target(), TARGET);
        assertEq(c.supply(), SUPPLY);
        assertEq(c.bondShareBps(), 2500, "25 % at deploy");
        assertEq(c.stockCount(), 3);
        (address s1, uint256 b1) = c.stockAt(1);
        assertEq(s1, address(stock[1]));
        assertEq(b1, 3000);
        assertEq(IERC20(c.token()).totalSupply(), SUPPLY);
        uint256 net = FIRST_BUY - FIRST_BUY * 75 / 10_000;
        uint256 atTwap;
        for (uint256 i = 0; i < 3; i++) {
            (uint256 v,) = oracle.tryQuote(address(pool[i]), c.held(i), address(stock[i]), address(usdg));
            atTwap += v;
        }
        assertEq(c.realUnits(), atTwap, "one unit per raw USDG of the stocks it got, at TWAP (F2)");
        assertLe(c.realUnits(), net, "at most one per raw USDG paid");
        assertApproxEqRel(c.realUnits(), net, 2e14, "the TWAP reads one tick under the swaps' price");
        assertEq(c.phantomQuote(), TARGET / 3, "1/3 of the target");
        assertEq(c.reserved(), SUPPLY / 4, "1/4 of the supply kept for the pools");
        assertEq(c.held(0), (net * 4000 / 10_000) * 1e30 / (500e18), "A: 40 % of the net at 500");
        assertEq(c.held(1), (net * 3000 / 10_000) * 1e30 / (400e18));
        assertEq(c.held(2), (net * 3000 / 10_000) * 1e30 / (250e18));
        (uint256 out,,,) = curveBuy(TARGET / 3, SUPPLY, c.realUnits(), 0, 0);
        assertEq(IERC20(c.token()).balanceOf(maker), out, "the creator's tokens at the base price, no snipe tax");
        assertEq(c.ownerPot(address(usdg)), FIRST_BUY * 75 / 10_000 * 3000 / 10_000, "30 % of the fee");
        assertEq(c.creatorPot(address(usdg)), FIRST_BUY * 75 / 10_000 - FIRST_BUY * 75 / 10_000 * 3000 / 10_000, "70 % of the fee");
        assertEq(address(lv5).balance, LAUNCH_FEE);
        assertTrue(lv5.isCurve(address(c)));
    }

    /// The launch's refusals, each by its named error.
    function test_TheLaunchRefusesABadBasketTargetFirstBuyFeeOrTax() public {
        BasketStock[] memory one = new BasketStock[](1);
        one[0] = BasketStock({ token: address(stock[0]), bps: 10_000 });
        _expectLaunchRevert(_launchArgs(one, TARGET, 0), abi.encodeWithSelector(Launcher.BadStockCount.selector, 1));
        BasketStock[] memory b = _basket();
        b[2].bps = 2999;
        _expectLaunchRevert(_launchArgs(b, TARGET, 0), abi.encodeWithSelector(Launcher.BadBps.selector, 9999));
        b = _basket();
        b[2].token = address(stock[0]);
        _expectLaunchRevert(_launchArgs(b, TARGET, 0), abi.encodeWithSelector(Launcher.DuplicateToken.selector, address(stock[0])));
        b = _basket();
        b[1].bps = 0;
        b[0].bps = 7000;
        _expectLaunchRevert(_launchArgs(b, TARGET, 0), abi.encodeWithSelector(Launcher.BadBps.selector, 0));
        b = _basket();
        b[2].token = address(usdg);
        _expectLaunchRevert(_launchArgs(b, TARGET, 0), abi.encodeWithSelector(Launcher.NotEligible.selector, address(usdg)));
        _expectLaunchRevert(_launchArgs(_basket(), 1000e6, 0), abi.encodeWithSelector(Launcher.TargetNotOffered.selector, 1000e6));
        _expectLaunchRevert(_launchArgs(_basket(), TARGET, 1001), abi.encodeWithSelector(Launcher.BadCreatorTax.selector, 1001));
        Launcher.Launch memory l = _launchArgs(_basket(), TARGET, 0);
        l.firstBuy = 10e6 - 1;
        _expectLaunchRevert(l, abi.encodeWithSelector(Launcher.FirstBuyTooSmall.selector, 10e6 - 1, 10e6));
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Launcher.WrongLaunchFee.selector, LAUNCH_FEE, LAUNCH_FEE + 1));
        lv5.launch{ value: LAUNCH_FEE + 1 }(_launchArgs(_basket(), TARGET, 0));
        vm.prank(owner);
        lv5.removeToken(address(stock[2]));
        _expectLaunchRevert(_launchArgs(_basket(), TARGET, 0), abi.encodeWithSelector(Launcher.NotEligible.selector, address(stock[2])));
    }

    function _expectLaunchRevert(Launcher.Launch memory l, bytes memory err) internal {
        vm.prank(maker);
        vm.expectRevert(err);
        lv5.launch{ value: LAUNCH_FEE }(l);
    }

    /// Eleven stocks are refused, ten are launched (the clone carries 10 x 22 bytes of basket).
    function test_TenStocksLaunchElevenAreRefused() public {
        BasketStock[] memory b = new BasketStock[](11);
        vm.startPrank(owner);
        for (uint256 i = 0; i < 11; i++) {
            TokenMock t = new TokenMock("X", "X", 18);
            t.mint(address(router), 1e30);
            PoolMock p = _poolAt(address(t), _tickAt(100e18));
            _routerAt(address(t), 100e18);
            lv5.addToken(address(t), address(p));
            b[i] = BasketStock({ token: address(t), bps: i < 10 ? 1000 : 0 });
        }
        vm.stopPrank();
        _expectLaunchRevert(_launchArgs(b, TARGET, 0), abi.encodeWithSelector(Launcher.BadStockCount.selector, 11));
        BasketStock[] memory ten = new BasketStock[](10);
        for (uint256 i = 0; i < 10; i++) {
            ten[i] = b[i];
        }
        vm.prank(maker);
        Curve c = lv5.launch{ value: LAUNCH_FEE }(_launchArgs(ten, TARGET, 0));
        (address last, uint256 bps) = c.stockAt(9);
        assertEq(last, ten[9].token);
        assertEq(bps, 1000);
        assertGt(c.held(9), 0);
    }

    // ---------------------------------------------------------------- owner ---

    /// `lowerProtocolShare` on the curve: the launcher's owner alone, down only (the same share or higher refused), before
    /// the bond only; `ProtocolShareLowered(from, to)`; the launcher's own share for future launches untouched.
    function test_TheOwnerOnlyLowersARunningCurvesProtocolShareBeforeItsBond() public {
        Curve c = _launch(TARGET, 0);
        vm.prank(alice);
        vm.expectRevert(Curve.NotOwner.selector);
        c.lowerProtocolShare(1000);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(Curve.ShareNotLower.selector, 2500, 2500));
        c.lowerProtocolShare(2500);
        vm.expectRevert(abi.encodeWithSelector(Curve.ShareNotLower.selector, 2500, 3000));
        c.lowerProtocolShare(3000);
        vm.expectEmit(address(c));
        emit Curve.ProtocolShareLowered(2500, 1000);
        c.lowerProtocolShare(1000);
        assertEq(c.bondShareBps(), 1000);
        vm.expectRevert(abi.encodeWithSelector(Curve.ShareNotLower.selector, 1000, 2000));
        c.lowerProtocolShare(2000);
        c.lowerProtocolShare(0);
        assertEq(c.bondShareBps(), 0);
        vm.stopPrank();
        assertEq(lv5.bondProtocolBps(), 2500, "future launches keep the launcher's share");
        _buyAndBond(c);
        vm.prank(owner);
        vm.expectRevert(Curve.AlreadyBonded.selector);
        c.lowerProtocolShare(0);
    }

    /// At 0 % the bond still fits: every stock into the pools, nothing to the owner's pots, the tokens at the price
    /// (all the units at the curve's last price, 0.1875 of the supply at the target) under the 1/4 the curve keeps,
    /// the rest above the price, every pool at one price.
    function test_AZeroProtocolShareStillBondsEveryStockIntoThePools() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 4980e6);
        vm.prank(owner);
        c.lowerProtocolShare(0);
        _move(0, 550);
        (uint256 q, uint256 t) = (c.quoteReserve(), c.tokenReserve());
        uint256 real = c.realUnits();
        uint256 tokensAtPrice = Math.mulDiv(real, t, q);
        assertLt(tokensAtPrice, t, "the pools at the price need less than the curve keeps");
        c.bond();
        assertEq(c.bondedStocks(), 7);
        _checkAbove(c);
        uint256 priced;
        for (uint256 i = 0; i < 3; i++) {
            address s = address(stock[i]);
            assertLe(c.ownerPot(s), 1e12, "no protocol share: the owner's pot holds only the pool's rounding");
            uint256 sqrtP = pm.openedAt(keccak256(abi.encode(c.poolKeyIn(s))));
            uint256 ratio = c.token() < s ? Math.mulDiv(sqrtP * sqrtP, 1e18, 1 << 192) : Math.mulDiv(1 << 192, 1e18, sqrtP * sqrtP);
            if (i == 0) priced = ratio * prices[i];
            else assertApproxEqRel(ratio * prices[i], priced, 2e14, "one price in USDG");
        }
        assertEq(IERC20(c.token()).balanceOf(address(c)), 0);
        assertEq(IERC20(c.token()).totalSupply(), SUPPLY, "the supply stays the launch's round number");
        assertLt(IERC20(c.token()).balanceOf(address(0x000000000000000000000000000000000000dEaD)), 1e12, "the rounding to 0xdEaD only");
    }

    /// The owner's lists: targets (1 to 8, increasing, in bounds), the bond share (< 100 %), the launch fee; a
    /// launched curve keeps its bond share; ownership is never renounced.
    function test_TheOwnerSetsTargetsAndBondShareForFutureLaunchesOnly() public {
        uint256[] memory t = lv5.targets();
        assertEq(t.length, 6);
        assertEq(t[0], 5000e6);
        assertEq(t[5], 30_000e6);
        Curve before = _launch(TARGET, 0);
        vm.startPrank(owner);
        lv5.setBondProtocolBps(1000);
        vm.expectRevert(abi.encodeWithSelector(Launcher.BadBondProtocolBps.selector, 10_000));
        lv5.setBondProtocolBps(10_000);
        uint256[] memory bad = new uint256[](2);
        (bad[0], bad[1]) = (2000e6, 2000e6);
        vm.expectRevert(abi.encodeWithSelector(Launcher.TargetsNotIncreasing.selector, 1));
        lv5.setTargets(bad);
        bad[1] = 1e9 - 1;
        bad[0] = 1e9 - 1;
        vm.expectRevert(abi.encodeWithSelector(Launcher.BadTarget.selector, 1e9 - 1));
        lv5.setTargets(bad);
        uint256[] memory one = new uint256[](1);
        one[0] = 1000e6;
        lv5.setTargets(one);
        vm.expectRevert(Launcher.RenounceForbidden.selector);
        lv5.renounceOwnership();
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        lv5.setBondProtocolBps(0);
        Curve next = _launch(1000e6, 0);
        assertEq(before.bondShareBps(), 2500, "the running curve keeps its split");
        assertEq(next.bondShareBps(), 1000);
        assertEq(next.target(), 1000e6);
    }

    /// `addToken` takes `MaidMarianEtfFactoryV4`'s checks: the factory's own pool of the pair, 1 801 observations.
    function test_AddTokenRefusesAPoolThatIsNotTheFactorysOrHasAThinOracle() public {
        TokenMock t = new TokenMock("T", "T", 18);
        PoolMock p = _poolAt(address(t), _tickAt(100e18));
        p.setCardinality(1800, 1800);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(Launcher.ThinOracle.selector, address(p), 1800, 1801));
        lv5.addToken(address(t), address(p));
        PoolMock stray = address(t) < address(usdg) ? new PoolMock(address(t), address(usdg)) : new PoolMock(address(usdg), address(t));
        vm.expectRevert(abi.encodeWithSelector(Launcher.BadPool.selector, address(stray)));
        lv5.addToken(address(t), address(stray));
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- buys ---

    /// The contract splits a buy by the reserve's mix at spot, what the swaps pay (review finding F4): after A +25 %, every stock
    /// brings the same units, the reserve keeps its shape; A's TWAP 20 % off its spot changes nothing. A spot moved alone
    /// (A's `slot0` 20 % over what its swap pays) gives A too much of the USDG: the others bring the fewest units and A's
    /// surplus stays in the reserve - the mover donates, no claim per unit falls.
    function test_ABuyIsSplitByTheReservesMixAtSpotAndNoClaimFalls() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 1000e6);
        _move(0, 625); // A +25 %
        uint256[3] memory h = [c.held(0), c.held(1), c.held(2)];
        uint256 real = c.realUnits();
        uint256 snap = vm.snapshotState();
        _buy(c, bob, 100e6);
        uint256 units = c.realUnits() - real;
        for (uint256 i = 0; i < 3; i++) {
            uint256 brought = Math.mulDiv(real, c.held(i) - h[i], h[i]);
            assertApproxEqRel(brought, units, 1e12, "every stock brings the same units: the reserve keeps its shape");
            assertGe(c.held(i) * real, h[i] * c.realUnits(), "no stock's claim per unit fell");
        }
        vm.revertToState(snap);
        // A's TWAP reads 750 while it trades at 625: the split does not read it.
        bool aFirst = address(stock[0]) < address(usdg);
        int24 tick = _tickAt(750e18);
        pool[0].setAverageTick(aFirst ? tick : -tick);
        _buy(c, bob, 100e6);
        assertEq(c.realUnits() - real, units, "a TWAP lag changes nothing");
        vm.revertToState(snap);
        // A's spot reads 750 while its swap pays at 625.
        pool[0].setSpotSqrtPrice(spotSqrtPrice(address(stock[0]), address(usdg), 750e18));
        _buy(c, bob, 100e6);
        assertLt(c.realUnits() - real, units, "the others bring fewer units: the moved spot costs the buyer");
        assertGt(c.held(0) * real, h[0] * c.realUnits(), "A's surplus stays behind every unit");
        for (uint256 i = 0; i < 3; i++) {
            assertGe(c.held(i) * real, h[i] * c.realUnits(), "no stock's claim per unit fell");
        }
    }

    /// A sandwiched stock (the router pays half of B) brings half the units and the buyer gets their tokens; the
    /// other holders' claims never fall. His `minTokensOut` refuses it.
    function test_ASandwichedStockCostsOnlyTheBuyerAndHisMinimumRefusesIt() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 1000e6);
        uint256 real = c.realUnits();
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        uint256 fair = lv5.buy(address(c), 100e6, 0, 1);
        uint256 fairUnits = c.realUnits() - real;
        vm.revertToState(snap);
        router.setPairRate(address(usdg), address(stock[1]), 1e48 / 800e18);
        uint256[3] memory h = [c.held(0), c.held(1), c.held(2)];
        vm.prank(bob);
        uint256 hurt = lv5.buy(address(c), 100e6, 0, 1);
        assertApproxEqAbs(c.realUnits() - real, fairUnits / 2, 1, "B brought half its units");
        (uint256 q, uint256 t) = (c.quoteReserve(), c.tokenReserve());
        (uint256 expected,,,) = curveBuy(q - (c.realUnits() - real), t + hurt, c.realUnits() - real, 0, 0);
        assertEq(hurt, expected, "the tokens of those units");
        assertLt(hurt, fair);
        for (uint256 i = 0; i < 3; i++) {
            assertGe(c.held(i) * real, h[i] * c.realUnits(), "no holder's claim fell");
        }
        vm.prank(carol);
        vm.expectPartialRevert(Curve.TooFewTokens.selector);
        lv5.buy(address(c), 100e6, 0, fair);
    }

    /// Bit i of `v4Mask` sends stock i through its registered V4 pool (`V4_SWAP`), refused when none.
    function test_TheV4MaskSwapsAStockThroughItsRegisteredV4Pool() public {
        Curve c = _launch(TARGET, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Curve.NoV4Pool.selector, address(stock[2])));
        lv5.buy(address(c), 100e6, 4, 1);
        address s = address(stock[2]);
        (address c0, address c1) = s < address(usdg) ? (s, address(usdg)) : (address(usdg), s);
        pm.initialize(IPoolManagerV4.PoolKey({ currency0: c0, currency1: c1, fee: 100, tickSpacing: 1, hooks: address(0) }), uint160(1 << 96));
        vm.prank(owner);
        lv5.setTokenV4Pool(s, 100, 1, address(0));
        router.setRecord(true);
        vm.prank(alice);
        lv5.buy(address(c), 100e6, 4, 1);
        assertEq(router.lastCommands(), hex"10", "the last swap, C's, was V4_SWAP");
    }

    /// The snipe tax: 9 900 >> (s x 14 / 5) bps in the first 5 s, 0 after; the creator and his named friends pay
    /// none; it is fee (30 % protocol).
    function test_TheSnipeTaxRunsFiveSecondsAndSparesTheExempted() public {
        Launcher.Launch memory l = _launchArgs(_basket(), TARGET, 0);
        l.snipeExempt = new address[](1);
        l.snipeExempt[0] = bob;
        vm.prank(maker);
        Curve c = lv5.launch{ value: LAUNCH_FEE }(l);
        assertEq(c.currentSnipeTaxBps(alice), 9900);
        assertEq(c.currentSnipeTaxBps(bob), 0);
        assertEq(c.currentSnipeTaxBps(maker), 0);
        vm.warp(vm.getBlockTimestamp() + 2);
        assertEq(c.currentSnipeTaxBps(alice), 9900 >> 5);
        vm.warp(vm.getBlockTimestamp() + 2);
        assertEq(c.currentSnipeTaxBps(alice), 9900 >> 11);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(c.currentSnipeTaxBps(alice), 0);
        Launcher.Launch memory many = _launchArgs(_basket(), TARGET, 0);
        many.snipeExempt = new address[](11);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Curve.TooManyExemptions.selector, 11, 10));
        lv5.launch{ value: LAUNCH_FEE }(many);
    }

    // ---------------------------------------------------------------- sales ---

    /// A sale's units come off the curve's formula; each stock gives `held x units / real`, sold at spot; the
    /// seller gets the USDG less 0.75 % and the tax, 70 / 30 and the tax to the creator's pot.
    function test_ASaleSellsEachStocksProRataPartAtSpotAndPaysTheUsdgLessFeeAndTax() public {
        Curve c = _launch(TARGET, 500);
        vm.warp(vm.getBlockTimestamp() + 10);
        uint256 tokens = _buy(c, alice, 1000e6);
        (uint256 q, uint256 t) = (c.quoteReserve(), c.tokenReserve());
        uint256 real = c.realUnits();
        uint256[3] memory h = [c.held(0), c.held(1), c.held(2)];
        uint256 sold = tokens / 2;
        (uint256 units,,) = curveSell(q, t, sold, 0, 0);
        uint256 gross;
        for (uint256 i = 0; i < 3; i++) {
            uint256 pay = h[i] * units / real;
            gross += pay * (prices[i] * 1e6) / 1e18;
        }
        uint256 creatorBefore = c.creatorPot(address(usdg));
        uint256 ownerBefore = c.ownerPot(address(usdg));
        uint256 out = _sell(c, alice, sold);
        uint256 fee = gross * 75 / 10_000;
        uint256 tax = gross * 500 / 10_000;
        assertEq(out, gross - fee - tax);
        assertEq(c.realUnits(), real - units);
        assertEq(c.ownerPot(address(usdg)) - ownerBefore, fee * 3000 / 10_000);
        assertEq(c.creatorPot(address(usdg)) - creatorBefore, fee - fee * 3000 / 10_000 + tax);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(c.held(i), h[i] - h[i] * units / real);
            assertEq(_uncounted(c, i), 0, "every stock counted");
        }
        assertEq(usdg.balanceOf(address(c)), c.ownerPot(address(usdg)) + c.creatorPot(address(usdg)), "the curve's USDG is its pots");
    }

    /// A falling market pays less: the curve sells the stocks it holds and never owes USDG it does not.
    function test_AFallingMarketPaysTheSellerLessNeverTheReserve() public {
        Curve c = _launch(TARGET, 0);
        uint256 tokens = _buy(c, alice, 1000e6);
        uint256 snap = vm.snapshotState();
        uint256 flat = _sell(c, alice, tokens);
        vm.revertToState(snap);
        for (uint256 i = 0; i < 3; i++) {
            _move(i, prices[i] * 4 / 5);
        }
        uint256 down = _sell(c, alice, tokens);
        assertApproxEqRel(down, flat * 4 / 5, 1e12, "-20 % on every stock: -20 % on the sale");
        assertGt(c.held(0), 0, "the creator's units still backed");
    }

    /// The last holder out leaves the reserve at the phantom; the next buy defines the unit again.
    function test_EveryoneOutThenTheNextBuyRestartsTheUnit() public {
        Curve c = _launch(TARGET, 0);
        uint256 a = _buy(c, alice, 500e6);
        _sell(c, alice, a);
        _sell(c, maker, IERC20(c.token()).balanceOf(maker));
        assertEq(IERC20(c.token()).balanceOf(address(c)), SUPPLY);
        assertLe(c.realUnits(), 1, "the units are back to dust at most");
        _buy(c, bob, 100e6);
        assertGt(c.realUnits(), 0);
    }

    // ----------------------------------------------------------------- bond ---

    /// `bond()` reverts `NotDue` under the target; a market move alone (A +10 %, its TWAP read 30 min later)
    /// puts the reserve over it and anyone bonds it, no reward.
    function test_AMarketMoveAloneLetsAnyoneBond() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 4980e6);
        (uint256 value, bool ok) = c.reserveValueUsdg();
        assertTrue(ok);
        assertLt(value, TARGET, "not yet");
        assertFalse(c.bondDue());
        vm.prank(carol);
        vm.expectRevert(Curve.NotDue.selector);
        c.bond();
        _move(0, 550);
        (value,) = c.reserveValueUsdg();
        assertGe(value, TARGET, "A +10 %: over the target at TWAP");
        assertTrue(c.bondDue());
        uint256 carolUsdg = usdg.balanceOf(carol);
        vm.prank(carol);
        c.bond();
        assertTrue(c.bonded());
        assertEq(usdg.balanceOf(carol), carolUsdg, "no reward");
        assertEq(IERC20(c.token()).balanceOf(carol), 0);
        vm.prank(carol);
        vm.expectRevert(Curve.NotDue.selector);
        c.bond();
    }

    /// A sale can bond: the move puts the reserve over the target, the next sale bonds it after paying.
    function test_ASaleAfterAMarketMoveBondsTheCurve() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 4980e6);
        _move(0, 600);
        uint256 out = _sell(c, alice, 1e18);
        assertTrue(c.bonded(), "bonded by the sale");
        assertGt(out, 0);
        vm.prank(alice);
        vm.expectRevert(Curve.AlreadyBonded.selector);
        lv5.buy(address(c), 1e6, 0, 0);
    }

    /// A buy that takes the reserve over the target bonds it in the same transaction: here a 1 USDG buy once A's +10 %
    /// put the reserve over it.
    function test_ABuyOverTheTargetBondsInItsOwnTransaction() public {
        Curve c = _launch(TARGET, 0);
        _buyAndBond(c);
    }

    /// 4 980 USDG, A +10 %, then a 1 USDG buy bonds the curve.
    function _buyAndBond(Curve c) internal {
        _buy(c, alice, 4980e6);
        _move(0, 550);
        _buy(c, bob, 1e6);
        assertTrue(c.bonded());
    }

    /// No stall when the stocks fell (author, 2026-10-26): every stock -30 % after a 2 000 USDG buy, buyers keep buying
    /// 200 USDG at a time - none refused, past 3/4 of the supply into the quarter the curve keeps at the target - until
    /// the reserve is worth the target at TWAP and the buy that crosses it bonds; the pools take every token the
    /// curve held, at the price or above it.
    function test_ACurveWhoseStocksFellIsCarriedToTheBondByItsBuyers() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 2000e6);
        for (uint256 i = 0; i < 3; i++) {
            _move(i, prices[i] * 7 / 10);
        }
        uint256 k;
        uint256 t;
        uint256 pmTokens;
        for (; k < 60 && !c.bonded(); k++) {
            (t, pmTokens) = (c.tokenReserve(), IERC20(c.token()).balanceOf(address(pm)));
            _buy(c, bob, 200e6);
        }
        assertTrue(c.bonded(), "the buyers bonded it");
        assertLt(t, c.reserved(), "they bought into the quarter the curve keeps at the target");
        assertGt(c.realUnits(), TARGET, "at -30 % it took more units than the target: no stall at 3/4");
        _checkAbove(c);
        assertEq(IERC20(c.token()).totalSupply(), SUPPLY, "nothing burned");
        assertLt(IERC20(c.token()).balanceOf(address(0x000000000000000000000000000000000000dEaD)), 1e12, "the liquidity's rounding to 0xdEaD only");
        // The bonding buy's tokens left the curve to bob, the rest to the pools.
        assertEq(IERC20(c.token()).balanceOf(address(c)), 0);
        assertGt(IERC20(c.token()).balanceOf(address(pm)), pmTokens, "the pools took the curve's tokens");
    }

    /// A huge last buy bonds: the pools still have their tokens. On x * y = k the curve keeps t = k / q and the pools at
    /// its last price need (1 - s)(q - q0) t / q: always less. 5x the target in one buy, then 200 000x (1e9 USDG);
    /// every pool opens at one price, the rest above it, nothing burned, the rounding to 0xdEaD.
    function test_AHugeLastBuyBondsAndThePoolsStillHaveTheirTokens() public {
        uint256[2] memory sizes = [uint256(5 * TARGET), 1e15];
        for (uint256 k = 0; k < 2; k++) {
            uint256 snap = vm.snapshotState();
            for (uint256 i = 0; i < 3; i++) {
                stock[i].mint(address(router), 1e40);
            }
            usdg.mint(alice, sizes[k]);
            Curve c = _launch(TARGET, 0);
            _buy(c, alice, sizes[k]);
            assertTrue(c.bonded(), "one buy bonds");
            assertEq(c.bondedStocks(), 7);
            _checkAbove(c);
            uint256 priced;
            for (uint256 i = 0; i < 3; i++) {
                address s_ = address(stock[i]);
                uint256 sqrtP = pm.openedAt(keccak256(abi.encode(c.poolKeyIn(s_))));
                uint256 ratio = c.token() < s_ ? Math.mulDiv(uint256(sqrtP) * sqrtP, 1e18, 1 << 192) : Math.mulDiv(1 << 192, 1e18, uint256(sqrtP) * sqrtP);
                if (i == 0) priced = ratio * prices[i];
                else assertApproxEqRel(ratio * prices[i], priced, 2e14, "one price in USDG");
            }
            assertEq(IERC20(c.token()).balanceOf(address(c)), 0);
            assertEq(IERC20(c.token()).totalSupply(), SUPPLY, "nothing burned");
            assertLt(IERC20(c.token()).balanceOf(address(0x000000000000000000000000000000000000dEaD)), 1e12, "the liquidity's rounding to 0xdEaD only");
            vm.revertToState(snap);
        }
    }

    /// The proof's inequality on the curve's own numbers, fuzzed: whatever the units in, from the phantom up to the
    /// `curveFits` edge, and whatever the protocol's share, the pools at the last price need fewer tokens than the curve
    /// keeps.
    function testFuzz_ThePoolsAtTheLastPriceNeedLessThanTheCurveKeeps(uint256 units, uint256 share) public pure {
        uint256 q0 = TARGET / 3;
        units = bound(units, 1, 1e30);
        share = bound(share, 0, 9999);
        (uint256 out,,,) = curveBuy(q0, SUPPLY, units, 0, 0);
        uint256 q = q0 + units;
        uint256 t = SUPPLY - out;
        uint256 real = q - q0;
        uint256 tokensAtPrice = Math.mulDiv(real - real * share / 10_000, t, q);
        assertLt(tokensAtPrice, t);
    }

    /// Without a TWAP on one held stock the reserve's value is unknown: no bond, but buys (split at spot) and sales go on;
    /// the TWAP back, anyone's `bond()` bonds it. A held stock whose pool gives no spot refuses a buy (`StockUnpriced`).
    function test_AStockWithoutATwapHoldsTheBondButNotTrades() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 4980e6);
        pool[1].setNoHistory(true);
        _move(0, 550);
        (, bool ok) = c.reserveValueUsdg();
        assertFalse(ok);
        assertFalse(c.bondDue());
        _buy(c, bob, 1e6);
        assertFalse(c.bonded(), "a buy goes through, no bond without the value");
        vm.expectRevert(Curve.NotDue.selector);
        c.bond();
        assertGt(_sell(c, alice, 1e24), 0, "a sale goes through");
        assertFalse(c.bonded());
        uint256 snap = vm.snapshotState();
        pool[2].setSpotSqrtPrice(0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Curve.StockUnpriced.selector, 2, address(stock[2])));
        lv5.buy(address(c), 1e6, 0, 1);
        vm.revertToState(snap);
        pool[1].setNoHistory(false);
        c.bond();
        assertTrue(c.bonded());
    }

    /// The bond: 25 % of each stock to the owner's pot, the rest into one token / stock pool per stock behind the
    /// hook, every pool at one token price in USDG (to 2 bp, the TWAP ticks), the tokens sized from the curve's last
    /// price; the tokens left in the same pools alone, from just above the opening price to 10x it (on the spacing's
    /// ticks, on the side the token's price rises, never holding stock), split as the pools' tokens: nothing burned, the rounding sent to 0xdEaD
    /// but the liquidity's rounding; one display swap per pool; the curve owns every position.
    function test_TheBondOpensOnePoolPerStockAtOnePriceAndBooksTheProtocolShareInStocks() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 4980e6);
        _move(0, 550);
        uint256[3] memory h = [c.held(0), c.held(1), c.held(2)];
        (uint256 q, uint256 t) = (c.quoteReserve(), c.tokenReserve());
        uint256 real = c.realUnits();
        uint256 pmTokens = IERC20(c.token()).balanceOf(address(pm));
        vm.recordLogs();
        c.bond();
        _checkAbove(c);
        assertEq(c.bondPools().length, 3);
        assertEq(c.bondedStocks(), 7);
        uint256 tokensAtPrice = Math.mulDiv(real - real * 2500 / 10_000, t, q);
        uint256 priced;
        uint256 pooledTokens;
        for (uint256 i = 0; i < 3; i++) {
            address s = address(stock[i]);
            assertEq(c.held(i), 0);
            assertGe(c.ownerPot(s), h[i] * 2500 / 10_000, "the protocol's 25 % in stock");
            assertLe(c.ownerPot(s), h[i] * 2500 / 10_000 + 1e12, "and the pool's rounding, no more");
            IPoolManagerV4.PoolKey memory key = c.poolKeyIn(s);
            assertEq(key.hooks, address(lv5.HOOK()));
            bytes32 id = keccak256(abi.encode(key));
            assertGt(pm.liquidity(id), 0);
            uint256 sqrtP = pm.openedAt(id);
            // Stock per token at the opening price, times the stock's price: one USDG price per token.
            uint256 ratio = c.token() < s ? Math.mulDiv(sqrtP * sqrtP, 1e18, 1 << 192) : Math.mulDiv(1 << 192, 1e18, sqrtP * sqrtP);
            uint256 p = ratio * prices[i];
            if (i == 0) priced = p;
            else assertApproxEqRel(p, priced, 2e14, "one price in USDG");
            pooledTokens += Math.mulDiv(h[i] - h[i] * 2500 / 10_000, 1e18, ratio);
        }
        assertApproxEqRel(pooledTokens, tokensAtPrice, 1e14, "the pools hold the tokens the curve's last price gives");
        assertEq(IERC20(c.token()).balanceOf(address(c)), 0, "the curve keeps no token");
        assertEq(IERC20(c.token()).totalSupply(), SUPPLY, "nothing burned: the token has no burn");
        // One unit of liquidity above the price is worth ~1e6 - 1e7 token wei here: 7.03e6 wei, 7e-12 token.
        uint256 dust = IERC20(c.token()).balanceOf(address(0x000000000000000000000000000000000000dEaD));
        assertLt(dust, 1e12, "the liquidity's rounding to 0xdEaD, under 1e-6 token");
        assertEq(IERC20(c.token()).balanceOf(address(pm)) - pmTokens, t - dust, "every token the curve kept is in its pools");
        assertEq(usdg.balanceOf(address(c)), c.ownerPot(address(usdg)) + c.creatorPot(address(usdg)));
    }

    /// Each pool's position above the price: a real range, on the spacing, about 10x wide (23 027 ticks less the
    /// spacing's rounding), on the side where the token's price rises from the opening tick, holding tokens only
    /// (the mock's three cases), and the pool's price not moved by it; the positions' tokens are in the
    /// pools' proportions.
    function _checkAbove(Curve c) internal view {
        uint256 n = c.stockCount();
        uint256[] memory l = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            (address s,) = c.stockAt(i);
            (int24 lower, int24 upper) = c.aboveRange(i);
            assertLt(lower, upper, "a range");
            assertEq(lower % 200, 0);
            assertEq(upper % 200, 0);
            assertGe(int256(upper) - int256(lower), 23_027 - 400);
            assertLe(int256(upper) - int256(lower), 23_027);
            bytes32 id = keccak256(abi.encode(c.poolKeyIn(s)));
            int24 open = TickMath.getTickAtSqrtPrice(pm.openedAt(id));
            int24 now_ = TickMath.getTickAtSqrtPrice(pm.sqrtPriceOf(id));
            if (c.token() < s) {
                assertGt(lower, open, "token0: above the opening tick");
                assertLe(now_, open, "the display swap sold tokens: the price went away from the range");
            } else {
                assertLe(upper, open, "token1: at or below the opening tick");
                assertGe(now_, open);
            }
            l[i] = pm.positionLiquidity(keccak256(abi.encode(id, lower, upper)));
            assertGt(l[i], 0);
        }
    }

    /// The tokens above split as the pools' tokens: read from `Bonded`, `aboveTokens / poolTokens` the same in
    /// every pool, to the liquidity's rounding.
    function test_TheTokensAboveAreSplitAsThePoolsTokens() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, 4980e6);
        _move(0, 550);
        (uint256 q, uint256 t) = (c.quoteReserve(), c.tokenReserve());
        uint256 real = c.realUnits();
        vm.recordLogs();
        c.bond();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 bonded = keccak256("Bonded(address,bytes32,address,uint256,uint256,uint256,uint256,uint256,uint256)");
        uint256 ratio;
        uint256 atPrice;
        uint256 above;
        uint256 k;
        for (uint256 j = 0; j < logs.length; j++) {
            if (logs[j].topics[0] != bonded || logs[j].emitter != address(c)) continue;
            (, uint256 poolTokens,, uint256 aboveTokens,,,) = abi.decode(logs[j].data, (address, uint256, uint256, uint256, uint256, uint256, uint256));
            uint256 r = Math.mulDiv(aboveTokens, 1e18, poolTokens);
            if (k++ == 0) ratio = r;
            else assertApproxEqRel(r, ratio, 1e12, "one ratio above / at the price in every pool");
            (atPrice, above) = (atPrice + poolTokens, above + aboveTokens);
        }
        assertEq(k, 3);
        assertApproxEqRel(atPrice + above, t, 1e12, "every token the curve kept, at the price or above it");
        // 75 % of the units at the curve's last price (the model's 0.1406 S at the target).
        assertApproxEqRel(atPrice, Math.mulDiv(real - real / 4, t, q), 1e12, "the tokens at the price");
    }

    /// After the bond, a trade in a pool earns fees; `collectPoolFees` (anyone) sends the token fees 30 / 70 and
    /// books the stock fees 30 / 70 to the pots, which the owner and the creator alone claim.
    function test_PoolFeesSplitSeventyThirtyAndThePotsAreClaimedByTheirOwners() public {
        Curve c = _launch(TARGET, 0);
        _buyAndBond(c);
        V4Trader trader = new V4Trader(IPoolManagerV4(address(pm)));
        address s = address(stock[0]);
        stock[0].mint(address(trader), 1e18);
        IPoolManagerV4.PoolKey memory key = c.poolKeyIn(s);
        bool zeroForOne = key.currency0 == s;
        trader.swapExactIn(key, zeroForOne, 1e17, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        uint256 ownerPotBefore = c.ownerPot(s);
        uint256 creatorPotBefore = c.creatorPot(s);
        vm.prank(carol);
        c.collectPoolFees();
        uint256 fees = (c.ownerPot(s) - ownerPotBefore) + (c.creatorPot(s) - creatorPotBefore);
        assertApproxEqAbs(fees, 1e15, 2, "1 % of the stock traded in");
        assertEq(c.ownerPot(s) - ownerPotBefore, fees * 3000 / 10_000);
        vm.prank(alice);
        vm.expectRevert(Curve.NotCreator.selector);
        c.claimCreatorPot(s, alice);
        vm.prank(maker);
        uint256 got = c.claimCreatorPot(s, maker);
        assertEq(IERC20(s).balanceOf(maker), got);
        vm.prank(alice);
        vm.expectRevert(Curve.NotOwner.selector);
        c.claimOwnerPot(s, alice);
        vm.prank(owner);
        c.claimOwnerPot(s, owner);
        vm.prank(owner);
        c.claimOwnerPot(address(usdg), owner);
        assertEq(c.ownerPot(s), 0);
    }

    /// Only the curve opens its pools: anyone else initializing the token / stock key is refused by the hook.
    function test_NobodyButTheCurveOpensItsPools() public {
        Curve c = _launch(TARGET, 0);
        IPoolManagerV4.PoolKey memory key = c.poolKeyIn(address(stock[0]));
        vm.expectRevert(abi.encodeWithSelector(Hook.NotLaunchedCurve.selector, address(this)));
        pm.initialize(key, uint160(1 << 96));
    }

    /// The curve's doors on the clone only, the launcher's `For` doors the launcher's only.
    function test_TheForDoorsAreTheLaunchersAlone() public {
        Curve c = _launch(TARGET, 0);
        vm.expectRevert(Curve.NotFactory.selector);
        c.buyFor(alice, 1e6, 0, 0);
        vm.expectRevert(Curve.NotFactory.selector);
        c.sellFor(alice, 1, 0, 0);
        Curve impl = lv5.CURVE_IMPLEMENTATION();
        vm.expectRevert(Curve.NotAClone.selector);
        impl.bond();
    }

    /// The curve's own doors and the launcher's give the same result: the same buy and sale, from the same state, by
    /// the buyer on the curve (his approve to it) and through the launcher, the same tokens and the same USDG.
    function test_ADirectBuyAndSaleEqualTheLaunchersDoors() public {
        Curve c = _launch(TARGET, 0);
        _buy(c, bob, 500e6);
        uint256 snap = vm.snapshotState();
        uint256 viaLauncher = _buy(c, alice, 100e6);
        uint256 backViaLauncher = _sell(c, alice, viaLauncher / 2);
        vm.revertToState(snap);
        IERC20 t = IERC20(c.token());
        vm.startPrank(alice);
        usdg.approve(address(c), 100e6);
        uint256 direct = c.buy(100e6, 0, 1);
        t.approve(address(c), direct / 2);
        uint256 backDirect = c.sell(direct / 2, 0, 0);
        vm.stopPrank();
        assertEq(direct, viaLauncher, "the same tokens");
        assertEq(backDirect, backViaLauncher, "the same USDG back");
    }
}

/**
 * The invariant's handler: random buys (random sizes, the contract's own split by the reserve's mix at TWAP), sales
 * of random parts of a holder's tokens, market moves of +- 30 % on any stock (spot and TWAP), and lags (a stock's
 * spot alone +- 20 % off its TWAP), the reserve kept under its target
 * so the curve never bonds. After every call it checks that no stock's claim per unit fell (`held_i / realUnits`,
 * cross-multiplied).
 */
contract CurveV5Handler is Test {
    Curve internal c;
    Launcher internal lv5;
    TokenMock internal usdg;
    UniversalRouterMock internal router;
    TokenMock[3] internal stock;
    PoolMock[3] internal pool;
    uint256[3] internal base = [uint256(500), 400, 250];
    uint256[3] public price = [uint256(500), 400, 250];
    address[4] internal holders;
    bool public claimFell;
    uint256 public paid;
    uint256 public calls;

    constructor(Curve c_, Launcher lv5_, TokenMock usdg_, UniversalRouterMock router_, TokenMock[3] memory stock_, PoolMock[3] memory pool_) {
        (c, lv5, usdg, router) = (c_, lv5_, usdg_, router_);
        for (uint256 i = 0; i < 3; i++) {
            (stock[i], pool[i]) = (stock_[i], pool_[i]);
        }
        IERC20 t = IERC20(c.token());
        for (uint256 i = 0; i < 4; i++) {
            holders[i] = makeAddr(string.concat("h", vm.toString(i)));
            usdg.mint(holders[i], 1e15);
            vm.startPrank(holders[i]);
            usdg.approve(address(lv5), type(uint256).max);
            t.approve(address(lv5), type(uint256).max);
            vm.stopPrank();
        }
    }

    function holder(uint256 i) external view returns (address) {
        return holders[i];
    }

    function _snap() private view returns (uint256[3] memory h, uint256 real) {
        h = [c.held(0), c.held(1), c.held(2)];
        real = c.realUnits();
    }

    function _check(uint256[3] memory h, uint256 real) private {
        uint256 now_ = c.realUnits();
        for (uint256 i = 0; i < 3; i++) {
            // held_i' / real' >= held_i / real; a real of 0 claims nothing.
            if (now_ != 0 && c.held(i) * real < h[i] * now_) claimFell = true;
        }
        calls++;
    }

    function buy(uint256 who, uint256 amount) external {
        amount = bound(amount, 1e6, 600e6);
        if (paid + amount > 14_000e6) return;
        address b = holders[who % 4];
        (uint256[3] memory h, uint256 real) = _snap();
        vm.prank(b);
        lv5.buy(address(c), amount, 0, 0);
        paid += amount;
        _check(h, real);
    }

    function sell(uint256 who, uint256 fraction) external {
        address s = holders[who % 4];
        uint256 bal = IERC20(c.token()).balanceOf(s);
        uint256 tokensIn = bal * bound(fraction, 1, 100) / 100;
        if (tokensIn == 0) return;
        (uint256 units,) = c.previewSell(tokensIn);
        if (units == 0) return;
        (uint256[3] memory h, uint256 real) = _snap();
        vm.prank(s);
        lv5.sell(address(c), tokensIn, 0, 0);
        _check(h, real);
    }

    /// Stock i's spot alone moves +- 20 % off its TWAP (the router's rates); the next `move` puts both together again.
    function lag(uint256 i, uint256 pct) external {
        i %= 3;
        uint256 p = price[i] * bound(pct, 80, 120) / 100;
        router.setPairRate(address(usdg), address(stock[i]), 1e48 / (p * 1e18));
        router.setPairRate(address(stock[i]), address(usdg), p * 1e18 / 1e12);
        pool[i].setSpotSqrtPrice(spotSqrtPrice(address(stock[i]), address(usdg), p * 1e18));
    }

    function move(uint256 i, uint256 pct) external {
        i %= 3;
        uint256 p = base[i] * bound(pct, 70, 130) / 100;
        price[i] = p;
        bool tokenFirst = address(stock[i]) < address(usdg);
        int24 tick = TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(Math.mulDiv(p * 1e18, 1 << 192, 1e30))));
        pool[i].setAverageTick(tokenFirst ? tick : -tick);
        router.setPairRate(address(usdg), address(stock[i]), 1e48 / (p * 1e18));
        router.setPairRate(address(stock[i]), address(usdg), p * 1e18 / 1e12);
        pool[i].setSpotSqrtPrice(spotSqrtPrice(address(stock[i]), address(usdg), p * 1e18));
    }
}

/**
 * The invariant: whatever the order of buys, sales and market moves, no stock's
 * claim per unit ever falls, every stock's count stays within the curve's balance less its pots, and the reserve
 * covers every holder: selling every holder's tokens, one after another, succeeds and leaves each count at or
 * above 0 with the units back to dust.
 *
 *   forge test --match-contract MaidMarianLaunchCurveV5InvariantTest -vv
 */
contract MaidMarianLaunchCurveV5InvariantTest is LauncherV5Base {
    CurveV5Handler internal handler;
    Curve internal c;

    function setUp() public override {
        super.setUp();
        c = _launch(30_000e6, 300);
        handler = new CurveV5Handler(c, lv5, usdg, router, stock, pool);
        targetContract(address(handler));
    }

    function invariant_NoClaimPerUnitEverFalls() public view {
        assertFalse(handler.claimFell());
        assertFalse(c.bonded());
    }

    /// At any state the bond, once the market puts the reserve over its target (every stock x3 here), opens every
    /// pool and its range above, keeps no token, burns nothing and sends only the rounding to 0xdEaD.
    function invariant_ABondAtAnyStateOpensEveryPoolAndBurnsNothing() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < 3; i++) {
            _move(i, handler.price(i) * 3);
        }
        uint256 t = c.tokenReserve();
        if (c.bondDue()) {
            c.bond();
            assertEq(c.bondedStocks(), 7);
            assertEq(IERC20(c.token()).balanceOf(address(c)), 0);
            assertEq(IERC20(c.token()).totalSupply(), SUPPLY, "nothing burned");
            assertLt(IERC20(c.token()).balanceOf(address(0x000000000000000000000000000000000000dEaD)), 1e12, "the liquidity's rounding to 0xdEaD, under 1e-6 token");
            assertGe(IERC20(c.token()).balanceOf(address(pm)), t - 1e12);
            for (uint256 i = 0; i < 3; i++) {
                (int24 lower, int24 upper) = c.aboveRange(i);
                assertLt(lower, upper);
            }
        }
        vm.revertToState(snap);
    }

    function invariant_EveryCountIsHeld() public view {
        for (uint256 i = 0; i < 3; i++) {
            assertEq(_uncounted(c, i), 0);
        }
        assertEq(usdg.balanceOf(address(c)), c.ownerPot(address(usdg)) + c.creatorPot(address(usdg)));
    }

    function invariant_TheReserveCoversEveryHolderSellingInTurn() public {
        uint256 snap = vm.snapshotState();
        address[5] memory who = [handler.holder(0), handler.holder(1), handler.holder(2), handler.holder(3), maker];
        IERC20 t = IERC20(c.token());
        for (uint256 k = 0; k < who.length; k++) {
            uint256 bal = t.balanceOf(who[k]);
            if (bal == 0) continue;
            (uint256 units,) = c.previewSell(bal);
            if (units == 0) continue;
            vm.startPrank(who[k]);
            t.approve(address(lv5), bal);
            lv5.sell(address(c), bal, 0, 0);
            vm.stopPrank();
        }
        // Each trade's `ceilDiv` keeps at most one raw unit (1e-6 USDG) in the curve, backed and owned by nobody.
        assertLe(c.realUnits(), handler.calls() + who.length + 1, "every unit sold back, dust at most");
        assertEq(t.balanceOf(address(c)) + _dust(t, who), SUPPLY, "every token back but unsellable dust");
        vm.revertToState(snap);
    }

    function _dust(IERC20 t, address[5] memory who) private view returns (uint256 d) {
        for (uint256 k = 0; k < who.length; k++) {
            d += t.balanceOf(who[k]);
        }
    }
}

/**
 * Gas on the mocks, accounts cooled before each call (`vm.cool` on the launcher, the curve, its token, USDG, the
 * stocks, their pools, the router and the PoolManager), the call's execution only (no intrinsic): a 100 USDG buy, a
 * sale of half of it, and a bonding 1 USDG buy (the reserve filled to about 97 % of the target, A, B and C +30 %), on 3 and on
 * 10 stocks. The mocks' `observe` is one storage read, so a real pool's binary search over its observations (about
 * 20 000 - 87 000 gas a stock at the chain's head, measured on chain) comes on top of every TWAP read counted here.
 *
 *   forge test --match-contract MaidMarianLaunchCurveV5GasTest -vv
 */
contract MaidMarianLaunchCurveV5GasTest is LauncherV5Base {
    TokenMock[] internal extra;
    PoolMock[] internal extraPools;

    function _cool(Curve c) internal {
        vm.cool(address(lv5));
        vm.cool(address(c));
        vm.cool(c.token());
        vm.cool(address(usdg));
        vm.cool(address(router));
        vm.cool(address(pm));
        uint256 n = c.stockCount();
        for (uint256 i = 0; i < n; i++) {
            (address s,) = c.stockAt(i);
            vm.cool(s);
            (address p,,,,) = lv5.poolsOf(s);
            vm.cool(p);
        }
    }

    function _basketOf(uint256 n) internal returns (BasketStock[] memory b) {
        b = new BasketStock[](n);
        for (uint256 i = 0; i < 3 && i < n; i++) {
            b[i] = BasketStock({ token: address(stock[i]), bps: 0 });
        }
        vm.startPrank(owner);
        for (uint256 i = 3; i < n; i++) {
            TokenMock t = new TokenMock("X", "X", 18);
            t.mint(address(router), 1e30);
            PoolMock p = _poolAt(address(t), _tickAt(100e18));
            _routerAt(address(t), 100e18);
            lv5.addToken(address(t), address(p));
            b[i] = BasketStock({ token: address(t), bps: 0 });
        }
        vm.stopPrank();
        for (uint256 i = 0; i < n; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            b[i].bps = uint16(10_000 / n + (i == 0 ? 10_000 % n : 0));
        }
    }

    function _measure(uint256 n) internal returns (uint256 buyGas, uint256 sellGas, uint256 bondGas) {
        Launcher.Launch memory l = _launchArgs(_basketOf(n), TARGET, 0);
        vm.prank(maker);
        Curve c = lv5.launch{ value: LAUNCH_FEE }(l);
        vm.warp(vm.getBlockTimestamp() + 10);
        _cool(c);
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 out = lv5.buy(address(c), 100e6, 0, 1);
        buyGas = g - gasleft();
        IERC20 token = IERC20(c.token());
        vm.prank(alice);
        token.approve(address(lv5), out);
        _cool(c);
        vm.prank(alice);
        g = gasleft();
        lv5.sell(address(c), out / 2, 0, 0);
        sellGas = g - gasleft();
        _buy(c, bob, 4800e6);
        for (uint256 i = 0; i < 3; i++) {
            _move(i, prices[i] * 13 / 10);
        }
        assertTrue(c.bondDue());
        _cool(c);
        vm.prank(carol);
        g = gasleft();
        lv5.buy(address(c), 1e6, 0, 1);
        bondGas = g - gasleft();
        assertTrue(c.bonded());
    }

    function test_GasOfABuyASaleAndABondingBuyOnThreeAndTenStocks() public {
        uint256 snap = vm.snapshotState();
        (uint256 b3, uint256 s3, uint256 k3) = _measure(3);
        vm.revertToState(snap);
        (uint256 b10, uint256 s10, uint256 k10) = _measure(10);
        emit log_named_uint("3 stocks: buy 100 USDG", b3);
        emit log_named_uint("3 stocks: sale", s3);
        emit log_named_uint("3 stocks: bonding buy", k3);
        emit log_named_uint("10 stocks: buy 100 USDG", b10);
        emit log_named_uint("10 stocks: sale", s10);
        emit log_named_uint("10 stocks: bonding buy", k10);
    }
}

/**
 * One TWAP read a transaction (author, 2026-10-26): the curve reads each stock's mean tick once and values every
 * amount from it (`_twapPrices`, `_valueAt`), where it used to ask `MaidMarianBagPoolOracle.tryQuote` per amount.
 * Claimed equal to the wei: the curve's `reserveValueUsdg()` (the new path) against the sum of the oracle's own
 * `tryQuote` on each count (the old path), over fuzzed prices on both sides of USDG (a stock sorted before and after
 * it, prices from 1e-6 to 1e6 USDG, ticks negative and positive) and after buys and sales; and the bond decision the
 * same.
 *
 *   forge test --match-contract MaidMarianLaunchCurveV5OnceTest -vv
 */
contract MaidMarianLaunchCurveV5OnceTest is LauncherV5Base {
    function _oracleValue(Curve c) internal view returns (uint256 value, bool ok) {
        for (uint256 i = 0; i < 3; i++) {
            uint256 h = c.held(i);
            if (h == 0) continue;
            (uint256 v, bool priced) = oracle.tryQuote(address(pool[i]), h, address(stock[i]), address(usdg));
            if (!priced || v == 0) return (0, false);
            value += v;
        }
        return (value, true);
    }

    function testFuzz_TheOnceReadPricesValueAsTheOracleDid(uint256 pa, uint256 pb, uint256 pc, uint256 buy, uint256 sellPct) public {
        Curve c = _launch(TARGET, 0);
        _buy(c, alice, bound(buy, 1e6, 3000e6));
        uint256 tokens = IERC20(c.token()).balanceOf(alice);
        uint256 part = tokens * bound(sellPct, 0, 90) / 100;
        if (part > 0) _sell(c, alice, part);
        uint256[3] memory moved = [bound(pa, 1, 1e6), bound(pb, 1, 1e6), bound(pc, 1, 1e6)];
        for (uint256 i = 0; i < 3; i++) {
            // The TWAP alone, at a price from 1e-6 to 1e6 USDG a whole stock.
            int24 tick = _tickAt(moved[i] * 1e12);
            pool[i].setAverageTick(address(stock[i]) < address(usdg) ? tick : -tick);
        }
        (uint256 got, bool ok) = c.reserveValueUsdg();
        (uint256 want, bool wantOk) = _oracleValue(c);
        assertEq(ok, wantOk, "priced alike");
        assertEq(got, want, "the same value to the wei");
        assertEq(c.bondDue(), wantOk && want >= TARGET, "the same bond decision");
    }

    /// An unpriced stock reads unpriced on both paths.
    function test_TheOnceReadPricesSeeAnUnpricedStockAsTheOracleDid() public {
        Curve c = _launch(TARGET, 0);
        pool[2].setNoHistory(true);
        (, bool ok) = c.reserveValueUsdg();
        (, bool wantOk) = _oracleValue(c);
        assertFalse(ok);
        assertEq(ok, wantOk);
    }
}

/**
 * The launcher reads prices with the curve's reader (`MaidMarianPoolPrice.sol`), the oracle gone from v5 (author,
 * 2026-10-26). Claimed equal to what `MaidMarianBagPoolOracle` gave: `twapPriceUsdg` against the oracle's `tryQuote` of
 * one whole stock, fuzzed over prices on both sides of USDG; and `addToken`'s price check, listing or refusing as the
 * oracle's TWAP-else-spot did: a pool with a TWAP, a young pool with a spot only, and a pool with neither.
 *
 *   forge test --match-contract MaidMarianLauncherV5PriceTest -vv
 */
contract MaidMarianLauncherV5PriceTest is LauncherV5Base {
    function testFuzz_TwapPriceUsdgIsTheOraclesQuote(uint256 price, uint256 i) public {
        i = bound(i, 0, 2);
        price = bound(price, 1, 1e12);
        int24 tick = _tickAt(price * 1e12);
        pool[i].setAverageTick(address(stock[i]) < address(usdg) ? tick : -tick);
        (uint256 got, bool ok) = lv5.twapPriceUsdg(address(stock[i]));
        (uint256 want, bool wantOk) = oracle.tryQuote(address(pool[i]), 1e18, address(stock[i]), address(usdg));
        assertEq(ok, wantOk);
        assertEq(got, want, "to the wei");
        pool[i].setNoHistory(true);
        (got, ok) = lv5.twapPriceUsdg(address(stock[i]));
        (want, wantOk) = oracle.tryQuote(address(pool[i]), 1e18, address(stock[i]), address(usdg));
        assertEq(ok, wantOk, "no TWAP on both");
        assertFalse(ok);
    }

    /// The oracle's verdict on a pool, `_checkPool`'s rule: its TWAP of one whole token, else its spot, above 0.
    function _oracleLists(PoolMock p, address t) internal view returns (bool) {
        (uint256 q, bool ok) = oracle.tryQuote(address(p), 1e30, t, address(usdg));
        if (!ok || q == 0) (q, ok) = oracle.trySpotQuote(address(p), 1e30, t, address(usdg));
        return ok && q > 0;
    }

    function test_AddTokensPriceCheckListsAndRefusesAsTheOracleDid() public {
        vm.startPrank(owner);
        // A pool with a TWAP.
        TokenMock a = new TokenMock("T1", "T1", 18);
        PoolMock pa = _poolAt(address(a), _tickAt(100e18));
        assertTrue(_oracleLists(pa, address(a)));
        lv5.addToken(address(a), address(pa));
        // A young pool: no TWAP yet, a spot.
        TokenMock b = new TokenMock("T2", "T2", 18);
        PoolMock pb = _poolAt(address(b), _tickAt(100e18));
        pb.setNoHistory(true);
        pb.setSpotSqrtPrice(uint160(1 << 96));
        assertTrue(_oracleLists(pb, address(b)));
        lv5.addToken(address(b), address(pb));
        // Neither: refused on both.
        TokenMock c = new TokenMock("T3", "T3", 18);
        PoolMock pc = _poolAt(address(c), _tickAt(100e18));
        pc.setNoHistory(true);
        assertFalse(_oracleLists(pc, address(c)));
        vm.expectRevert(abi.encodeWithSelector(Launcher.BadPool.selector, address(pc)));
        lv5.addToken(address(c), address(pc));
        vm.stopPrank();
        assertTrue(lv5.isEligible(address(a)) && lv5.isEligible(address(b)) && !lv5.isEligible(address(c)));
    }
}

/// The launcher v5's former private Discord check, kept as the reference, beside the shared one.
contract DiscordCheckHarness {
    function shared(bytes calldata s) external pure returns (bool) {
        checkProfileDiscord(s);
        return true;
    }

    function former(bytes calldata s) external pure returns (bool) {
        uint256 n = s.length;
        if (n == 0) return true;
        uint256 p = _startsWith(s, "https://discord.gg/") ? 19 : _startsWith(s, "https://discord.com/invite/") ? 27 : 0;
        if (p == 0 || n < p + 2 || n > p + 32) revert BadDiscord();
        for (uint256 i = p; i < n; i++) {
            if (!isAsciiAlnum(s[i]) && s[i] != "-") revert BadDiscord();
        }
        return true;
    }

    function _startsWith(bytes calldata s, bytes memory prefix) private pure returns (bool) {
        if (s.length < prefix.length) return false;
        for (uint256 i = 0; i < prefix.length; i++) {
            if (s[i] != prefix[i]) return false;
        }
        return true;
    }
}

/**
 * `checkProfileDiscord` (`MaidMarianTokenChecks.sol`) accepts exactly what the launcher v5's private copy accepted:
 * the same vectors, and fuzzed suffixes behind both prefixes and behind none.
 *
 *   forge test --match-contract MaidMarianProfileDiscordTest -vv
 */
contract MaidMarianProfileDiscordTest is Test {
    DiscordCheckHarness internal h = new DiscordCheckHarness();

    function _same(bytes memory s) internal view {
        (bool okShared,) = address(h).staticcall(abi.encodeCall(DiscordCheckHarness.shared, (s)));
        (bool okFormer,) = address(h).staticcall(abi.encodeCall(DiscordCheckHarness.former, (s)));
        assertEq(okShared, okFormer, string(s));
    }

    function test_TheSharedDiscordCheckAcceptsWhatTheFormerDid() public view {
        string[16] memory v = [
            "",
            "https://discord.gg/ab",
            "https://discord.gg/a",
            "https://discord.gg/abcdefghijklmnopqrstuvwxyz012345",
            "https://discord.gg/abcdefghijklmnopqrstuvwxyz0123456",
            "https://discord.gg/a-b-C9",
            "https://discord.gg/a_b",
            "https://discord.gg/ab/",
            "https://discord.com/invite/xyZ-9",
            "https://discord.com/invite/x",
            "https://discord.com/invite/",
            "http://discord.gg/abc",
            "https://Discord.gg/abc",
            "https://discord.gg/",
            "https://discord.com/abc",
            "https://discord.gg/ab c"
        ];
        uint256 accepted;
        for (uint256 i = 0; i < v.length; i++) {
            _same(bytes(v[i]));
            (bool ok,) = address(h).staticcall(abi.encodeCall(DiscordCheckHarness.shared, (bytes(v[i]))));
            if (ok) accepted++;
        }
        assertEq(accepted, 5, "empty, gg 2 and 32 chars, gg with dashes, invite");
    }

    function testFuzz_TheSharedDiscordCheckAcceptsWhatTheFormerDid(bytes calldata suffix, uint8 which) public view {
        bytes memory prefix = which % 3 == 0 ? bytes("https://discord.gg/") : which % 3 == 1 ? bytes("https://discord.com/invite/") : bytes("");
        _same(bytes.concat(prefix, suffix));
    }
}
