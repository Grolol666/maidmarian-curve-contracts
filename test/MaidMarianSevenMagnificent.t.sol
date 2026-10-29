// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MaidMarianSevenMagnificent as M7m, IUniversalRouter } from "../src/MaidMarianSevenMagnificent.sol";
import { TokenMock, FeedMock, UniversalRouterMock, GarbageRegistryMock } from "./Mocks.sol";

/**
 * m7m offline, on `test/Mocks.sol`: seven 18-decimal `TokenMock`s, USDG at 6,
 * seven 8-decimal `FeedMock`s, a pre-funded `UniversalRouterMock` priced leg by
 * leg with `setPairRate`, called by m7m directly (no gate since the fourth amendment).
 *
 * These tests prove the contract's arithmetic and refusals against mocks - the
 * share rule, the fees, the sensors, the band, the floors, the cost record. They
 * cannot prove that real routes fill or that real feeds answer the way the mocks
 * do: that is `MaidMarianSevenMagnificent.fork.t.sol`.
 *
 * The prices are chosen so `1e30 / price` is exact (prices of the form 2^a 5^b):
 * a router rate at Chainlink's price delivers to the wei what Chainlink values,
 * so "at the price" and "1 % under it" are exact numbers, not approximations.
 */
contract MaidMarianSevenMagnificentTest is Test {
    uint256 internal constant N = 7;
    // AAPL MSFT GOOGL AMZN NVDA META TSLA, in whole USD.
    uint256[7] internal prices = [uint256(250), 500, 200, 125, 100, 400, 80];

    TokenMock internal usdg;
    TokenMock[7] internal tokens;
    FeedMock[7] internal feeds;
    UniversalRouterMock internal router;
    M7m internal m7m;

    address internal sponsor = makeAddr("sponsor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol"); // holds nothing: what she receives is what a door paid

    function setUp() public {
        vm.warp(1_790_000_000);
        usdg = new TokenMock("USDG", "USDG", 6);
        router = new UniversalRouterMock();
        address[7] memory t;
        address[7] memory f;
        for (uint256 i = 0; i < N; i++) {
            tokens[i] = new TokenMock(string.concat("T", vm.toString(i)), string.concat("T", vm.toString(i)), 18);
            feeds[i] = new FeedMock(8, int256(prices[i] * 1e8), block.timestamp);
            t[i] = address(tokens[i]);
            f[i] = address(feeds[i]);
            tokens[i].mint(address(router), 1e30);
            _routerAt(i, prices[i] * 1e8);
        }
        usdg.mint(address(router), 1e30);
        m7m = new M7m(t, f, IERC20(address(usdg)), IUniversalRouter(address(router)), sponsor);

        usdg.mint(alice, 1e15);
        usdg.mint(bob, 1e15);
        vm.prank(alice);
        usdg.approve(address(m7m), type(uint256).max);
        vm.prank(bob);
        usdg.approve(address(m7m), type(uint256).max);
    }

    // ------------------------------------------------------------ helpers ---

    /// The router buys and sells leg `i` at exactly `answer` (8 decimals): Chainlink values
    /// `raw x answer / 1e20` USDG units, so the buy rate is `1e38 / answer` and the sell rate
    /// `answer / 100`, both scaled by the mock's 1e18.
    function _routerAt(uint256 i, uint256 answer) internal {
        router.setPairRate(address(usdg), address(tokens[i]), 1e38 / answer);
        router.setPairRate(address(tokens[i]), address(usdg), answer / 100);
    }

    /// One mock route: m7m as recipient, `payerIsUser: false`, the pair in the path.
    function _route(uint8 leg, bool sell, uint256 amountIn) internal view returns (M7m.Route memory r) {
        (address tin, address tout) = sell ? (address(tokens[leg]), address(usdg)) : (address(usdg), address(tokens[leg]));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(m7m), amountIn, uint256(0), abi.encodePacked(tin, uint24(3000), tout), false, bytes(""));
        r = M7m.Route({ leg: leg, sell: sell, amountIn: amountIn, commands: hex"00", inputs: inputs, deadline: block.timestamp + 60 });
    }

    /// Buy routes for the seven amounts (0 skips a leg).
    function _buys(uint256[7] memory amounts) internal view returns (M7m.Route[7] memory r) {
        for (uint256 i = 0; i < N; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            r[i] = _route(uint8(i), false, amounts[i]);
        }
    }

    function _each(uint256 amount) internal pure returns (uint256[7] memory a) {
        for (uint256 i = 0; i < N; i++) {
            a[i] = amount;
        }
    }

    function _sum(uint256[7] memory a) internal pure returns (uint256 s) {
        for (uint256 i = 0; i < N; i++) {
            s += a[i];
        }
    }

    /// The `usdgIn` whose net of the 10 bps entry fee is exactly `net`: `u - u / 1000` steps by
    /// one except where it holds, so every net is reached.
    function _gross(uint256 net) internal pure returns (uint256 u) {
        u = net * 10_000 / 9990;
        while (u - u * 10 / 10_000 < net) u++;
        while (u - u * 10 / 10_000 > net) u--;
    }

    /// `who` mints with routes buying `amounts` (the net the routes spend), the fee on top.
    function _mintSplit(address who, uint256[7] memory amounts) internal returns (uint256 shares) {
        M7m.Route[7] memory r = _buys(amounts);
        vm.prank(who);
        shares = m7m.mint(_gross(_sum(amounts)), r, 1, who);
    }

    function _mint(address who, uint256 each) internal returns (uint256) {
        return _mintSplit(who, _each(each));
    }

    /// Every feed writes a new round at `block.timestamp`, at its current answer.
    function _tick() internal {
        for (uint256 i = 0; i < N; i++) {
            (uint80 id, int256 answer,,,) = feeds[i].latestRoundData();
            feeds[i].setRoundId(id + 1);
            feeds[i].setAnswer(answer, block.timestamp);
        }
    }

    /// Leg `i` repriced on the feed (with a new round) and on the router.
    function _reprice(uint256 i, uint256 answer) internal {
        (uint80 id,,,,) = feeds[i].latestRoundData();
        feeds[i].setRoundId(id + 1);
        // forge-lint: disable-next-line(unsafe-typecast)
        feeds[i].setAnswer(int256(answer), block.timestamp);
        _routerAt(i, answer);
    }

    function _held(uint256 i) internal view returns (uint256) {
        return tokens[i].balanceOf(address(m7m));
    }

    function _assertAllInBand() internal view {
        M7m.Leg[7] memory l = m7m.legs();
        uint256 target = m7m.nav() / _liveCount(l);
        for (uint256 i = 0; i < N; i++) {
            if (!l[i].live) continue;
            uint256 gap = l[i].value > target ? l[i].value - target : target - l[i].value;
            assertLt(gap, target * 200 / 10_000, "every live leg is within the dead band of its target");
        }
        assertEq(m7m.plan().length, 0, "and plan() has nothing left to trade");
    }

    function _liveCount(M7m.Leg[7] memory l) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < N; i++) {
            if (l[i].live) n++;
        }
    }

    function _run(M7m.PlanLeg[] memory p) internal {
        M7m.Route[] memory routes = new M7m.Route[](p.length);
        for (uint256 k = 0; k < p.length; k++) {
            routes[k] = _route(p[k].leg, p[k].sell, p[k].amountIn);
        }
        _rebalance(routes);
    }

    /// `rebalance` is the owner's (security review 2026-10-15, M3).
    function _rebalance(M7m.Route[] memory routes) internal {
        vm.prank(sponsor);
        m7m.rebalance(routes);
    }

    /// A mock route whose output goes to `recipient` instead of m7m - the review's tool.
    function _routeTo(uint8 leg, bool sell, uint256 amountIn, address recipient) internal view returns (M7m.Route memory r) {
        r = _route(leg, sell, amountIn);
        (address tin, address tout) = sell ? (address(tokens[leg]), address(usdg)) : (address(usdg), address(tokens[leg]));
        r.inputs[0] = abi.encode(recipient, amountIn, uint256(0), abi.encodePacked(tin, uint24(3000), tout), false, bytes(""));
    }

    /// What `who` holds at the feeds' initial prices, in USDG units.
    function _worth(address who) internal view returns (uint256 v) {
        v = usdg.balanceOf(who);
        for (uint256 i = 0; i < N; i++) {
            v += tokens[i].balanceOf(who) * prices[i] * 1e6 / 1e18;
        }
    }

    /// `shares` less the exit fee and the early penalty `holder` would pay now: what is paid out.
    function _paid(address holder, uint256 shares) internal view returns (uint256) {
        uint256 total = m7m.exitFeeBps(holder);
        return shares - shares * 30 / 10_000 - shares * (total - 30) / 10_000;
    }

    function _one(M7m.Route memory r) internal pure returns (M7m.Route[] memory routes) {
        routes = new M7m.Route[](1);
        routes[0] = r;
    }

    /// A fresh memory array: `address[7] memory b = a` aliases, it does not copy.
    function _copy(address[7] memory a) internal pure returns (address[7] memory b) {
        for (uint256 i = 0; i < N; i++) {
            b[i] = a[i];
        }
    }

    // ------------------------------------------------------------- birth ---

    /// The seven, their feeds, USDG and the router are what the constructor was given; the
    /// first rebalance needs no wait, the fee clock starts at deploy.
    function test_TheConstructorStoresTheSevenAndTheirFeedsAndStartsTheFeeClockAtDeploy() public view {
        M7m.Leg[7] memory l = m7m.legs();
        for (uint256 i = 0; i < N; i++) {
            assertEq(l[i].token, address(tokens[i]));
            assertEq(l[i].feed, address(feeds[i]));
            assertEq(l[i].feedDecimals, 8);
            assertTrue(l[i].live);
        }
        assertEq(address(m7m.USDG()), address(usdg));
        assertEq(address(m7m.UNIVERSAL_ROUTER()), address(router));
        assertEq(m7m.name(), "Maid Marian Seven Magnificent");
        assertEq(m7m.symbol(), "m7m");
        assertEq(m7m.decimals(), 18);
        assertEq(m7m.lastAccrualAt(), block.timestamp);
        assertEq(m7m.lastRebalanceAt(), 0);
        assertEq(m7m.owner(), sponsor);
    }

    /// A zero address, a token without code, a duplicate, USDG among the seven, a feed that
    /// does not answer five words: each refused by name.
    function test_TheConstructorRefusesAZeroAddressACodelessTokenADuplicateAndAFeedThatDoesNotAnswer() public {
        address[7] memory t;
        address[7] memory f;
        for (uint256 i = 0; i < N; i++) {
            (t[i], f[i]) = (address(tokens[i]), address(feeds[i]));
        }
        IERC20 u = IERC20(address(usdg));

        address[7] memory bad = _copy(t);
        bad[3] = address(0);
        vm.expectRevert(M7m.ZeroAddress.selector);
        new M7m(bad, f, u, IUniversalRouter(address(router)), sponsor);

        bad = _copy(t);
        bad[3] = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(M7m.NoCode.selector, bad[3]));
        new M7m(bad, f, u, IUniversalRouter(address(router)), sponsor);

        bad = _copy(t);
        bad[5] = t[1];
        vm.expectRevert(abi.encodeWithSelector(M7m.DuplicateToken.selector, t[1]));
        new M7m(bad, f, u, IUniversalRouter(address(router)), sponsor);

        bad = _copy(t);
        bad[0] = address(usdg);
        vm.expectRevert(abi.encodeWithSelector(M7m.DuplicateToken.selector, address(usdg)));
        new M7m(bad, f, u, IUniversalRouter(address(router)), sponsor);

        GarbageRegistryMock garbage = new GarbageRegistryMock();
        garbage.setAnswer(abi.encode(uint256(8))); // answers decimals(), and one word to latestRoundData()
        address[7] memory badFeeds = _copy(f);
        badFeeds[2] = address(garbage);
        vm.expectRevert(abi.encodeWithSelector(M7m.BadFeed.selector, address(garbage)));
        new M7m(t, badFeeds, u, IUniversalRouter(address(router)), sponsor);

        feeds[4].setReverting(true);
        vm.expectRevert(abi.encodeWithSelector(M7m.BadFeed.selector, address(feeds[4])));
        new M7m(t, f, u, IUniversalRouter(address(router)), sponsor);
    }

    // -------------------------------------------------------------- mint ---

    /// The first mint buys the seven legs with the net of the entry fee and mints one share
    /// per USDG that reached the fund; nothing in shares goes to the owner.
    function test_TheFirstMintBuysTheSevenAndMintsOneSharePerUsdgThatReachesTheFund() public {
        uint256 shares = _mint(alice, 1000e6);
        assertEq(shares, 7000e18, "one share per USDG in the fund");
        assertEq(m7m.totalSupply(), 7000e18);
        assertEq(m7m.balanceOf(sponsor), 0, "the entry fee is not in shares");
        for (uint256 i = 0; i < N; i++) {
            assertEq(_held(i), 1000e6 * (1e38 / (prices[i] * 1e8)) / 1e18, "each leg holds what its route delivered");
            assertEq(m7m.legs()[i].value, 1000e6, "worth 1000 USDG at Chainlink");
        }
        assertEq(m7m.nav(), 7000e6);
        assertEq(m7m.navPerShare(), 1e6, "1 USDG a share");
        assertEq(usdg.balanceOf(address(m7m)), 0, "every USDG was spent");
    }

    /// The entry fee is 0.1 % of `usdgIn`, in USDG, to the owner, before the routes run; the
    /// routes must spend exactly the rest - `usdgIn` itself is refused.
    function test_TheEntryFeeLeavesTheOwnerATenthOfAPercentInUsdgAndTheRoutesSpendTheNet() public {
        M7m.Route[7] memory r = _buys(_each(142_857_143)); // 7 x 142 857 143 = 1 000 000 001
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M7m.RoutesDoNotSpendInput.selector, 1_000_000_001, 999_000_000));
        m7m.mint(1000e6, r, 1, alice);

        uint256[7] memory a = _each(142_714_285);
        a[0] = 999_000_000 - 6 * 142_714_285;
        r = _buys(a);
        uint256 aliceBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        m7m.mint(1000e6, r, 1, alice);
        assertEq(usdg.balanceOf(sponsor), 1e6, "0.1 % of 1000 USDG to the owner");
        assertEq(aliceBefore - usdg.balanceOf(alice), 1000e6, "the minter paid usdgIn, no more");
        assertEq(m7m.nav(), 999e6, "the net is in the fund");
        assertEq(m7m.balanceOf(sponsor), 0);
    }

    /// The routes must spend exactly the net, no more, no less.
    function test_AMintWhoseRoutesDoNotSumToItsNetReverts() public {
        M7m.Route[7] memory r = _buys(_each(100e6));
        uint256 usdgIn = _gross(700e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M7m.RoutesDoNotSpendInput.selector, 700e6, 700e6 + 1));
        m7m.mint(_gross(700e6 + 1), r, 1, alice);
        vm.prank(alice);
        m7m.mint(usdgIn, r, 1, alice);
    }

    /// A route that delivers more than Chainlink values is credited what was paid: the excess
    /// stays with every holder, and NAV per share rises. Skipping six legs is allowed.
    function test_AMintIsCreditedWhatItPaidWhenTheRouteDeliversMoreThanChainlinkValue() public {
        _mint(alice, 1000e6);
        uint256 perShare = m7m.navPerShare();
        // forge-lint: disable-next-line(divide-before-multiply)
        router.setPairRate(address(usdg), address(tokens[2]), (1e38 / (prices[2] * 1e8)) * 11 / 10);
        uint256[7] memory a;
        a[2] = 100e6;
        uint256 shares = _mintSplit(bob, a);
        assertEq(shares, 100e18, "credit = 100 USDG paid, at 1 USDG a share");
        assertGt(m7m.navPerShare(), perShare, "the 10 % extra stays with every holder");
    }

    /// A route that delivers less than Chainlink values is credited only what it is worth.
    function test_AMintIsCreditedChainlinkValueWhenTheRouteDeliversLess() public {
        _mint(alice, 1000e6);
        uint256 perShare = m7m.navPerShare();
        // forge-lint: disable-next-line(divide-before-multiply)
        router.setPairRate(address(usdg), address(tokens[2]), (1e38 / (prices[2] * 1e8)) * 9 / 10);
        uint256[7] memory a;
        a[2] = 100e6;
        uint256 shares = _mintSplit(bob, a);
        assertEq(shares, 90e18, "credit = the 90 USDG the delivery is worth");
        assertEq(m7m.navPerShare(), perShare, "holders lose nothing");
    }

    /// A stale feed, low or high against the router's real price, never over-mints: the
    /// holders' NAV per share at Chainlink does not fall on a mint following `mintPlan`.
    function test_AStaleFeedNeverOverMintsHoldersNavPerShareDoesNotFall() public {
        _mint(alice, 1000e6);
        uint256[2] memory stale = [uint256(200e8), 300e8]; // AAPL trades at 250 on the router
        for (uint256 k = 0; k < 2; k++) {
            uint256 snap = vm.snapshotState();
            // forge-lint: disable-next-line(unsafe-typecast)
            feeds[0].setAnswer(int256(stale[k]), block.timestamp);
            uint256 perShare = m7m.navPerShare();
            uint256 usdgIn = _gross(700e6);
            M7m.Route[7] memory r = _buys(m7m.mintPlan(usdgIn));
            vm.prank(bob);
            m7m.mint(usdgIn, r, 1, bob);
            assertGe(m7m.navPerShare(), perShare, "no holder pays for the stale feed");
            vm.revertToState(snap);
        }
    }

    /// Security review 2026-10-15, H2. A dead feed drops its leg from `nav` but `redeemInKind`
    /// still pays it: a minter would buy the fund at 6/7 and walk out with a share of the dead
    /// leg (the PoC: +7 % in a day, alice -6 %). `mint` is now refused while a held leg's feed is
    /// dead; `mintInKind`, proportional and oracle-free, stays open.
    function test_AMintIsRefusedWhileAHeldLegsFeedIsDeadAndMintInKindStaysOpen() public {
        _mint(alice, 1000e6);
        feeds[6].setReverting(true);
        uint256[7] memory a;
        for (uint256 i = 0; i < 6; i++) {
            a[i] = 1000e6;
        }
        M7m.Route[7] memory r = _buys(a);
        uint256 usdgIn = _gross(6000e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(M7m.LegDead.selector, address(tokens[6])));
        m7m.mint(usdgIn, r, 1, bob);

        uint256[7] memory amounts;
        for (uint256 i = 0; i < N; i++) {
            amounts[i] = _held(i) / 10;
            tokens[i].mint(bob, amounts[i]);
            vm.prank(bob);
            tokens[i].approve(address(m7m), amounts[i]);
        }
        vm.prank(bob);
        assertGt(m7m.mintInKind(amounts, 1, bob), 0, "the in-kind door is open");
    }

    /// Security review 2026-10-15, M8. A mint needs every live feed's last round younger than
    /// `MINT_FEED_AGE` (6 hours, second pass): one second over, refused with the feed's time; a
    /// new round, open again. Creations during market hours.
    function test_AMintIsRefusedWhileALiveFeedIsOlderThanSixHours() public {
        _mint(alice, 1000e6);
        uint256 t0 = vm.getBlockTimestamp(); // not block.timestamp: via_ir re-reads it after vm.warp
        vm.warp(t0 + 6 hours + 1);
        M7m.Route[7] memory r = _buys(_each(100e6));
        uint256 usdgIn = _gross(700e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(M7m.FeedStale.selector, address(tokens[0]), t0));
        m7m.mint(usdgIn, r, 1, bob);
        _tick();
        vm.prank(bob);
        assertGt(m7m.mint(usdgIn, r, 1, bob), 0, "fresh rounds: open");
    }

    /// Security review 2026-10-15, L9. A first mint whose routes deliver nothing (the PoC paid the
    /// minter) would leave shares with nothing behind them and brick every later mint: refused,
    /// as is a first mint that skips a leg.
    function test_AFirstMintThatDeliversNothingOrSkipsALegIsRefused() public {
        M7m.Route[7] memory r;
        for (uint256 i = 0; i < N; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            r[i] = _routeTo(uint8(i), false, 1e6, bob);
        }
        uint256 usdgIn = _gross(7e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(M7m.NothingDelivered.selector, address(tokens[0])));
        m7m.mint(usdgIn, r, 1, bob);

        uint256[7] memory a = _each(1e6);
        a[3] = 0;
        a[4] = 2e6;
        r = _buys(a);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(M7m.NothingDelivered.selector, address(tokens[3])));
        m7m.mint(usdgIn, r, 1, bob);
    }

    /// Second review pass, L-a. A first mint whose routes deliver 1 wei per leg (the PoC: 7 shares
    /// over 7 wei, every later mint refused) is refused: each leg must bring at least 99 % of its
    /// cost at Chainlink.
    function test_AFirstMintOfOneWeiPerLegIsRefused() public {
        for (uint256 i = 0; i < N; i++) {
            router.setPairRate(address(usdg), address(tokens[i]), 1e12); // 1 USDG -> 1 wei
        }
        M7m.Route[7] memory r = _buys(_each(1e6));
        uint256 g = _gross(7e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(M7m.FirstMintUnderDelivered.selector, address(tokens[0]), 0, 1e6));
        m7m.mint(g, r, 1, bob);
    }

    /// Second review pass, M-a. Once a dead feed is replaced, the owner's feed is a price with no
    /// notice (the PoC: a feed at 1 on TSLA, the six others bought at 6/7, +7 % in a day). `mint`
    /// now waits `FEED_NOTICE` (3 days) after a replacement - one second before, refused; at 3
    /// days, open - while the holders can leave in kind.
    function test_AMintWaitsThreeDaysAfterTheOwnerReplacesAFeed() public {
        _mint(alice, 1000e6);
        uint256 t0 = vm.getBlockTimestamp(); // not block.timestamp: via_ir re-reads it after vm.warp
        vm.warp(t0 + 8 days);
        _tick();
        feeds[6].setAnswer(int256(prices[6] * 1e8), t0); // TSLA's own feed silent 8 days: dead
        FeedMock own = new FeedMock(8, 1, block.timestamp);
        vm.prank(sponsor);
        m7m.replaceFeed(6, address(own));
        uint256 readyAt = t0 + 8 days + 3 days;
        assertEq(m7m.feedReplacedAt(6), t0 + 8 days);

        usdg.mint(sponsor, 1e12);
        vm.prank(sponsor);
        usdg.approve(address(m7m), type(uint256).max);
        uint256[7] memory a;
        for (uint256 i = 0; i < 6; i++) {
            a[i] = 1000e6;
        }
        M7m.Route[7] memory r = _buys(a);
        uint256 g = _gross(6000e6);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(M7m.FeedNotice.selector, 6, readyAt));
        m7m.mint(g, r, 1, sponsor);

        vm.warp(readyAt - 1);
        _tick();
        own.setAnswer(1, block.timestamp);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(M7m.FeedNotice.selector, 6, readyAt));
        m7m.mint(g, r, 1, sponsor);

        uint256 aliceShares = m7m.balanceOf(alice);
        uint256 tsla = _held(6);
        vm.prank(alice);
        m7m.redeemInKind(aliceShares, alice, 0); // the notice is for this: alice leaves first
        assertEq(tokens[6].balanceOf(alice), tsla - tsla * 30 / 10_000, "her TSLA whole, less only the 0.3 % fee");

        vm.warp(readyAt);
        _tick();
        own.setAnswer(1, block.timestamp);
        vm.prank(sponsor);
        assertGt(m7m.mint(g, r, 1, sponsor), 0, "after the notice, open");
    }

    /// `canMint` says closed exactly when `mint` reverts, for each of the three guards, and open
    /// when it passes: a stale feed (6 h + 1 s, `readyAt` 0), a dead held leg, a feed notice
    /// (with its `readyAt`).
    function test_CanMintSaysClosedExactlyWhenMintRevertsForEachGuard() public {
        _mint(alice, 1000e6);
        M7m.Route[7] memory r = _buys(_each(100e6));
        uint256 g = _gross(700e6);
        (bool open, M7m.MintGuard why, address token, uint256 readyAt) = m7m.canMint();
        assertTrue(open && why == M7m.MintGuard.Open && token == address(0) && readyAt == 0, "open");

        uint256 snap = vm.snapshotState();
        uint256 t0 = vm.getBlockTimestamp(); // not block.timestamp: via_ir re-reads it after vm.warp
        vm.warp(t0 + 6 hours + 1);
        (open, why, token, readyAt) = m7m.canMint();
        assertTrue(!open && why == M7m.MintGuard.FeedStale && token == address(tokens[0]) && readyAt == 0, "stale");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(M7m.FeedStale.selector, address(tokens[0]), t0));
        m7m.mint(g, r, 1, bob);
        vm.revertToState(snap);

        feeds[6].setReverting(true);
        (open, why, token,) = m7m.canMint();
        assertTrue(!open && why == M7m.MintGuard.LegDead && token == address(tokens[6]), "dead");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(M7m.LegDead.selector, address(tokens[6])));
        m7m.mint(g, r, 1, bob);

        FeedMock next = new FeedMock(8, int256(prices[6] * 1e8), block.timestamp);
        vm.prank(sponsor);
        m7m.replaceFeed(6, address(next));
        (open, why, token, readyAt) = m7m.canMint();
        assertTrue(!open && why == M7m.MintGuard.FeedNotice && token == address(tokens[6]) && readyAt == t0 + 3 days, "notice");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(M7m.FeedNotice.selector, 6, t0 + 3 days));
        m7m.mint(g, r, 1, bob);

        vm.warp(t0 + 3 days);
        feeds[6].setReverting(false); // the replaced mock, so the test's own `_tick` can read it; m7m no longer does
        _tick();
        next.setAnswer(int256(prices[6] * 1e8), block.timestamp);
        (open,,,) = m7m.canMint();
        assertTrue(open, "open again");
        vm.prank(bob);
        assertGt(m7m.mint(g, r, 1, bob), 0, "and mint passes");
    }

    /// `Minted` carries what the legs were credited and the nav the shares were priced at.
    function test_MintedCarriesTheCreditAndTheNavItWasPricedAt() public {
        _mint(alice, 1000e6);
        M7m.Route[7] memory r = _buys(_each(100e6));
        uint256 g = _gross(700e6);
        vm.expectEmit(true, true, false, true, address(m7m));
        emit M7m.Minted(bob, bob, g, 700e18, g - 700e6, 700e6, 7000e6);
        vm.prank(bob);
        m7m.mint(g, r, 1, bob);
    }

    /// `mintInKind` without a leg the fund holds is refused by name.
    function test_MintInKindWithoutAHeldLegIsRefusedByName() public {
        _mint(alice, 1000e6);
        uint256[7] memory amounts;
        for (uint256 i = 0; i < N; i++) {
            if (i == 4) continue;
            amounts[i] = _held(i) / 10;
            tokens[i].mint(bob, amounts[i]);
            vm.prank(bob);
            tokens[i].approve(address(m7m), amounts[i]);
        }
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(M7m.LegNotBrought.selector, address(tokens[4])));
        m7m.mintInKind(amounts, 1, bob);
    }

    /// `minShares` is checked on what the minter receives.
    function test_MinSharesIsCheckedOnWhatTheMinterReceives() public {
        M7m.Route[7] memory r = _buys(_each(100e6));
        uint256 usdgIn = _gross(700e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M7m.TooFewShares.selector, 700e18, 700e18 + 1));
        m7m.mint(usdgIn, r, 700e18 + 1, alice);
    }

    // ---------------------------------------------------------- mint plan ---

    /// One leg's deficit larger than the money: all of it goes there, the sum exact.
    function test_MintPlanSendsEverythingToTheOneLegInDeficitWhenItsDeficitExceedsTheInput() public {
        _mint(alice, 1000e6);
        _reprice(0, prices[0] * 1e8 / 2); // AAPL at 500 against six at 1000
        uint256[7] memory a = m7m.mintPlan(_gross(100e6));
        assertEq(a[0], 100e6, "everything to AAPL");
        for (uint256 i = 1; i < N; i++) {
            assertEq(a[i], 0);
        }
    }

    /// A balanced fund: the deficits are equal, the rounding goes to the first leg, the sum
    /// is the net exactly.
    function test_MintPlanSpreadsEquallyOnABalancedFundAndSumsExactly() public {
        _mint(alice, 1000e6);
        uint256[7] memory a = m7m.mintPlan(_gross(701e6));
        assertEq(_sum(a), 701e6, "the routes' net, to the unit");
        for (uint256 i = 1; i < N; i++) {
            assertEq(a[i], 100_142_857, "target (7701 / 7) minus 1000, rounded down");
        }
        assertEq(a[0], 701e6 - 6 * 100_142_857, "the dust on the first live leg");
    }

    /// An empty fund splits equally among the live legs; a dead leg gets nothing.
    function test_MintPlanOnAnEmptyFundSplitsEquallyAndGivesADeadLegNothing() public {
        feeds[6].setReverting(true);
        uint256[7] memory a = m7m.mintPlan(_gross(600e6));
        for (uint256 i = 0; i < 6; i++) {
            assertEq(a[i], 100e6);
        }
        assertEq(a[6], 0, "dead: nothing");
    }

    /// New money rebalances: AAPL halved, a mint of 500 USDG following `mintPlan` goes all to
    /// AAPL and leaves every leg within the band. (New money only fills deficits: an overweight
    /// leg waits for `rebalance` or for enough money to raise the target to it.)
    function test_AMintFollowingMintPlanLeavesEveryLegInBand() public {
        _mint(alice, 1000e6);
        _reprice(0, prices[0] * 1e8 / 2);
        uint256 usdgIn = _gross(500e6);
        M7m.Route[7] memory r = _buys(m7m.mintPlan(usdgIn));
        vm.prank(bob);
        m7m.mint(usdgIn, r, 1, bob);
        _assertAllInBand();
    }

    // -------------------------------------------------------- mint in kind ---

    /// `mintInKind` follows the smallest ratio, keeps the excess, pays the owner 10 bps of the
    /// shares, and its preview says so beforehand.
    function test_MintInKindFollowsTheSmallestRatioKeepsTheExcessAndPaysTenBpsInShares() public {
        _mint(alice, 1000e6);
        uint256 supply = m7m.totalSupply();
        uint256[7] memory amounts;
        for (uint256 i = 0; i < N; i++) {
            amounts[i] = _held(i) / 10; // 10 % of every leg
            tokens[i].mint(bob, amounts[i]);
            vm.prank(bob);
            tokens[i].approve(address(m7m), amounts[i]);
        }
        amounts[6] = _held(6) / 20; // TSLA only 5 %
        uint256 heldBefore0 = _held(0);
        (uint256 preview, uint256 previewFee, uint256 previewUsdg) = m7m.previewMintInKind(amounts);
        assertEq(previewUsdg, 0, "the fund holds no USDG: none asked");

        vm.prank(bob);
        uint256 shares = m7m.mintInKind(amounts, 1, bob);

        uint256 gross = supply / 20;
        assertEq(shares, gross - gross * 10 / 10_000, "the smallest ratio, 5 %, less the fee");
        assertEq(shares, preview, "previewMintInKind said it");
        assertEq(previewFee, gross * 10 / 10_000);
        assertEq(m7m.balanceOf(sponsor), previewFee, "paid to the owner in shares");
        assertEq(_held(0), heldBefore0 + heldBefore0 / 10, "the 10 % brought on leg 0 is in the fund");
    }

    /// Security review 2026-10-15, M6. With USDG left in the fund (an under-traded rebalance: the
    /// sell ran, the buys wait), `mintInKind` pulls its share of that USDG too; a mint-and-redeem
    /// round trip in kind no longer takes a profit from the holders.
    function test_MintInKindBringsItsShareOfTheFundsUsdgAndARoundTripTakesNothing() public {
        _mint(alice, 1000e6);
        _reprice(0, prices[0] * 1e8 * 12 / 10);
        M7m.PlanLeg[] memory p = m7m.plan();
        assertTrue(p[0].sell);
        _rebalance(_one(_route(p[0].leg, true, p[0].amountIn))); // the sell only
        uint256 u = usdg.balanceOf(address(m7m));
        assertGt(u, 0, "USDG left in the fund");

        address mallory = makeAddr("mallory");
        uint256[7] memory amounts;
        uint256 valueIn;
        for (uint256 i = 0; i < N; i++) {
            amounts[i] = _held(i);
            tokens[i].mint(mallory, amounts[i]);
            vm.prank(mallory);
            tokens[i].approve(address(m7m), amounts[i]);
            valueIn += m7m.legs()[i].value;
        }
        usdg.mint(mallory, u);
        vm.prank(mallory);
        usdg.approve(address(m7m), u);
        (,, uint256 asked) = m7m.previewMintInKind(amounts);
        assertEq(asked, u, "the whole fund doubled: all its USDG asked again");
        vm.prank(mallory);
        uint256 shares = m7m.mintInKind(amounts, 1, mallory);
        assertEq(usdg.balanceOf(mallory), 0, "and pulled");
        valueIn += u;

        vm.warp(block.timestamp + 1 days);
        vm.prank(mallory);
        m7m.redeemInKind(shares, mallory, 0);
        uint256 valueOut = usdg.balanceOf(mallory);
        for (uint256 i = 0; i < N; i++) {
            valueOut += tokens[i].balanceOf(mallory) * uint256(m7m.legs()[i].answer) / 1e20;
        }
        assertLe(valueOut, valueIn, "no profit paid by alice");
    }

    /// The first share is born at 1 USDG through `mint`, and only there.
    function test_MintInKindRefusesToBeTheFirstMint() public {
        uint256[7] memory amounts;
        vm.prank(bob);
        vm.expectRevert(M7m.FirstMintIsUsdg.selector);
        m7m.mintInKind(amounts, 0, bob);
    }

    // ------------------------------------------------------- management fee ---

    /// A rebalance 365 days after birth mints 0.3 % of the supply to the owner; one 20 h later
    /// mints 0.3 % x 20 / 8 760 of the supply then; nothing is accrued outside `rebalance`.
    function test_TheManagementFeeIsThreeTenthsOfAPercentAYearAccruedOnlyByRebalance() public {
        _mint(alice, 1000e6);
        vm.warp(block.timestamp + 365 days);
        assertEq(m7m.balanceOf(sponsor), 0, "time alone mints nothing");

        uint256 supply = m7m.totalSupply();
        assertEq(m7m.pendingManagementFee(), supply * 30 / 10_000);
        _tick();
        _rebalance(new M7m.Route[](0));
        assertEq(m7m.balanceOf(sponsor), supply * 30 / 10_000, "0.3 % of the supply after a year");
        assertEq(m7m.pendingManagementFee(), 0);

        uint256 supply2 = m7m.totalSupply();
        uint256 owned = m7m.balanceOf(sponsor);
        vm.warp(block.timestamp + 20 hours);
        _tick();
        _rebalance(new M7m.Route[](0));
        assertEq(m7m.balanceOf(sponsor) - owned, supply2 * 30 * 20 hours / (10_000 * 365 days), "0.3 % x 20 / 8760 of the supply 20 h later");
    }

    /// Security review 2026-10-15, L10. The management fee runs from the first mint, not from
    /// deploy: a fund deployed a year before its first share pays no fee for that year.
    function test_TheManagementFeeRunsFromTheFirstMintNotFromDeploy() public {
        vm.warp(block.timestamp + 365 days);
        _tick();
        _mint(alice, 1000e6);
        assertEq(m7m.lastAccrualAt(), block.timestamp, "the clock starts at the first mint");
        _rebalance(new M7m.Route[](0));
        assertEq(m7m.balanceOf(sponsor), 0, "nothing for the empty year");
    }

    // ------------------------------------------------------------- redeem ---

    /// The exit fee comes first, in shares (0.3 % to the owner); the rest's due is paid in USDG
    /// for what the routes sell and in kind for the remainder, whole; no feed is read (all seven
    /// dead).
    function test_RedeemTakesItsFeeInSharesThenPaysUsdgForWhatTheRoutesSellAndTheRestInKind() public {
        uint256 shares = _mint(alice, 1000e6);
        vm.warp(block.timestamp + 30 days);
        for (uint256 i = 0; i < N; i++) {
            feeds[i].setReverting(true);
        }
        uint256 half = shares / 2;
        uint256 fee = half * 30 / 10_000;
        uint256 paid = half - fee;
        uint256 supply = m7m.totalSupply();
        uint256[7] memory due;
        M7m.Route[7] memory r;
        uint256 sold;
        for (uint256 i = 0; i < N; i++) {
            due[i] = _held(i) * paid / supply;
            // forge-lint: disable-next-line(unsafe-typecast)
            r[i] = _route(uint8(i), true, i < 3 ? due[i] : due[i] / 2); // legs 0-2 sold whole, 3-6 half
            sold += r[i].amountIn * prices[i] * 1e6 / 1e18;
        }
        uint256 sponsorUsdg = usdg.balanceOf(sponsor); // the entry fee
        uint256[7] memory inKind;
        for (uint256 i = 0; i < N; i++) {
            inKind[i] = due[i] - r[i].amountIn;
        }
        vm.expectEmit(true, true, false, true, address(m7m));
        emit M7m.Redeemed(alice, carol, half, sold, fee, 0, inKind);
        vm.prank(alice);
        uint256 out = m7m.redeem(half, r, sold, carol);

        assertEq(out, sold, "USDG for what was sold, nothing taken from it");
        assertEq(usdg.balanceOf(carol), out);
        assertEq(m7m.balanceOf(sponsor), fee, "the 0.3 % to the owner, in shares");
        assertEq(usdg.balanceOf(sponsor), sponsorUsdg, "and no USDG fee");
        for (uint256 i = 0; i < N; i++) {
            assertEq(tokens[i].balanceOf(carol), due[i] - r[i].amountIn, "the unsold rest in kind, whole");
        }
    }

    /// Security review 2026-10-15, H1. Routes that pay the redeemer directly made the USDG fee
    /// 0 (the PoC: 1 % due, 0 paid). In shares, before any route, the fee cannot be routed
    /// around: an early redeemer routing everything to herself still leaves 0.3 % of her shares
    /// to the owner and burns 0.7 % for the holders, whose NAV per share rises.
    function test_ARedeemWhoseRoutesPayTheRedeemerStillPaysItsFeeAndPenaltyInShares() public {
        _mint(bob, 1000e6);
        uint256 shares = _mint(alice, 1000e6);
        assertEq(m7m.exitFeeBps(alice), 100, "alice is early: 1 % due");
        uint256 supply = m7m.totalSupply();
        uint256 paid = _paid(alice, shares);
        uint256 perShare = m7m.navPerShare();
        M7m.Route[7] memory r;
        for (uint256 i = 0; i < N; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            r[i] = _routeTo(uint8(i), true, _held(i) * paid / supply, alice);
        }
        vm.prank(alice);
        m7m.redeem(shares, r, 0, alice);
        assertEq(m7m.balanceOf(sponsor), shares * 30 / 10_000, "the owner's 0.3 %, in shares");
        assertEq(m7m.totalSupply(), supply - shares + shares * 30 / 10_000, "the 0.7 % burned with the rest");
        assertGt(m7m.navPerShare(), perShare, "for bob, who stays");
    }

    /// A route that sells more than the leg's due is refused, by leg.
    function test_ARedeemRouteAboveItsDueIsRefusedWithOverRedeem() public {
        uint256 shares = _mint(alice, 1000e6);
        uint256 due = _held(4) * _paid(alice, shares) / m7m.totalSupply();
        M7m.Route[7] memory r;
        r[4] = _route(4, true, due + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M7m.OverRedeem.selector, address(tokens[4]), due + 1, due));
        m7m.redeem(shares, r, 0, alice);
    }

    /// `minUsdgOut` floors the USDG `to` receives, on the due of the shares left after the fee
    /// and the early penalty (0.3 % + 0.7 % here: the shares are seconds old).
    function test_MinUsdgOutFloorsWhatArrives() public {
        uint256 shares = _mint(alice, 1000e6);
        uint256 due = _held(0) * _paid(alice, shares) / m7m.totalSupply();
        M7m.Route[7] memory r;
        r[0] = _route(0, true, due);
        uint256 out = due * prices[0] * 1e6 / 1e18;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M7m.TooLittleOut.selector, out, out + 1));
        m7m.redeem(shares, r, out + 1, alice);
        vm.prank(alice);
        assertEq(m7m.redeem(shares, r, out, alice), out);
    }

    // ------------------------------------------------------ redeem in kind ---

    /// The in-kind exit pays 0.3 % of the shares to the owner and the rest, burned, exactly
    /// `held x burned / supply` of each leg and of the USDG - what `previewRedeem` said, and what
    /// `RedeemedInKind` reports, leg by leg.
    function test_AnInKindExitPaysThreeTenthsOfAPercentOfTheSharesAndTheRestProRata() public {
        uint256 shares = _mint(alice, 1000e6);
        vm.warp(block.timestamp + 30 days);
        usdg.mint(address(m7m), 333e6); // USDG held, as after a sell-only rebalance
        uint256 supply = m7m.totalSupply();
        uint256 part = shares / 3;
        uint256 feeShares = part * 30 / 10_000;
        uint256 burned = part - feeShares;
        (uint256 pPaid, uint256 pFee, uint256 pPenalty, uint256[7] memory preview, uint256 previewUsdg) = m7m.previewRedeem(alice, part);
        assertEq(pPaid, burned);
        assertEq(pFee, feeShares);
        assertEq(pPenalty, 0, "30 days old: no penalty");
        uint256[7] memory held;
        for (uint256 i = 0; i < N; i++) {
            held[i] = _held(i);
        }
        vm.expectEmit(true, true, false, true, address(m7m));
        emit M7m.RedeemedInKind(alice, carol, part, feeShares, 0, preview, previewUsdg, 0);
        vm.prank(alice);
        m7m.redeemInKind(part, carol, 0);
        assertEq(m7m.balanceOf(sponsor), feeShares, "0.3 % of the shares to the owner");
        assertEq(m7m.totalSupply(), supply - burned, "the rest burned");
        for (uint256 i = 0; i < N; i++) {
            assertEq(tokens[i].balanceOf(carol), held[i] * burned / supply, "pro rata, rounded down");
            assertEq(tokens[i].balanceOf(carol), preview[i], "as previewed");
        }
        assertEq(usdg.balanceOf(carol), 333e6 * burned / supply, "and the same share of the USDG");
        assertEq(usdg.balanceOf(carol), previewUsdg);
    }

    /// `previewRedeem(holder, shares)` is what `redeemInKind` pays, for a holder seconds old (1 %:
    /// 0.3 % to the owner, 0.7 % burned) and for one two days old (0.3 %).
    function test_PreviewRedeemIsWhatRedeemInKindPaysForAFreshAndAnOldHolder() public {
        uint256 old = _mint(alice, 1000e6);
        vm.warp(block.timestamp + 2 days);
        _tick();
        uint256 fresh = _mint(bob, 1000e6);
        usdg.mint(address(m7m), 70e6);
        address[2] memory who = [bob, alice];
        uint256[2] memory part = [fresh / 3, old / 3];
        uint256[2] memory penalty = [part[0] * 70 / 10_000, uint256(0)];
        for (uint256 k = 0; k < 2; k++) {
            uint256 snap = vm.snapshotState();
            (uint256 paid, uint256 fee, uint256 pen, uint256[7] memory amounts, uint256 u) = m7m.previewRedeem(who[k], part[k]);
            assertEq(fee, part[k] * 30 / 10_000);
            assertEq(pen, penalty[k]);
            assertEq(paid, part[k] - fee - pen);
            address out = makeAddr(string.concat("out", vm.toString(k)));
            vm.prank(who[k]);
            m7m.redeemInKind(part[k], out, 0);
            for (uint256 i = 0; i < N; i++) {
                assertEq(tokens[i].balanceOf(out), amounts[i], "each leg as previewed");
            }
            assertEq(usdg.balanceOf(out), u, "and the USDG");
            vm.revertToState(snap);
        }
    }

    /// The door that always works: every feed dead three ways, the router paying nothing, a
    /// decade later - `redeemInKind` still pays.
    function test_RedeemInKindWorksWithEveryFeedDeadAndTheRouterBrokenAtAnyTime() public {
        uint256 shares = _mint(alice, 1000e6);
        router.setPayNothing(true);
        feeds[0].setReverting(true);
        feeds[1].setAnswer(0, block.timestamp);
        feeds[2].setAnswer(-1, block.timestamp);
        vm.warp(block.timestamp + 3650 days); // the four others are now ten years old
        vm.prank(alice);
        m7m.redeemInKind(shares, alice, 0);
        for (uint256 i = 0; i < N; i++) {
            assertGt(tokens[i].balanceOf(alice), 0);
        }
        assertEq(m7m.balanceOf(alice), 0);
    }

    // -------------------------------------------------- frozen tokens waived ---

    /// A frozen leg - its transfer to the redeemer reverts, as a paused or blocklisting stock
    /// token's would (`vm.mockCallRevert` on that one call, no mock changed) - blocks
    /// `redeemInKind` with mask 0 and passes with its bit set: the six others paid, the frozen
    /// amount left in the fund for the holders, `forfeited` naming the leg.
    function test_AFrozenLegBlocksRedeemInKindUnlessItsBitIsSetThenStaysInTheFund() public {
        uint256 shares = _mint(alice, 1000e6);
        _mint(bob, 1000e6);
        vm.mockCallRevert(address(tokens[3]), abi.encodeWithSelector(IERC20.transfer.selector, carol), "paused");
        uint256 part = shares / 2;
        vm.prank(alice);
        vm.expectRevert(bytes("paused"));
        m7m.redeemInKind(part, carol, 0);

        uint256 held3 = _held(3);
        uint256 supply = m7m.totalSupply();
        (,,, uint256[7] memory preview,) = m7m.previewRedeem(alice, part);
        uint256[7] memory paidOut = preview;
        paidOut[3] = 0; // forfeited: reported as 0 paid
        vm.expectEmit(true, true, false, true, address(m7m));
        emit M7m.RedeemedInKind(alice, carol, part, part * 30 / 10_000, part * 70 / 10_000, paidOut, 0, uint8(1 << 3));
        vm.prank(alice);
        m7m.redeemInKind(part, carol, uint8(1 << 3));
        assertEq(_held(3), held3, "the frozen leg stays whole in the fund");
        assertEq(tokens[3].balanceOf(carol), 0);
        for (uint256 i = 0; i < N; i++) {
            if (i != 3) assertEq(tokens[i].balanceOf(carol), preview[i], "the six others paid");
        }
        assertLt(m7m.totalSupply(), supply, "the shares are burned all the same");
    }

    /// The mask waives a frozen transfer, never a working one: with every bit set and no token
    /// frozen, the redeemer receives all seven and the USDG.
    function test_ASetBitNeverForfeitsAWorkingTransfer() public {
        uint256 shares = _mint(alice, 1000e6);
        usdg.mint(address(m7m), 100e6);
        (,,, uint256[7] memory preview, uint256 previewUsdg) = m7m.previewRedeem(alice, shares);
        vm.prank(alice);
        m7m.redeemInKind(shares, carol, type(uint8).max);
        for (uint256 i = 0; i < N; i++) {
            assertEq(tokens[i].balanceOf(carol), preview[i]);
        }
        assertEq(usdg.balanceOf(carol), previewUsdg);
    }

    /// USDG likewise, bit 7: frozen, it blocks with mask 0 and stays in the fund with the bit set.
    function test_FrozenUsdgBlocksUnlessBitSevenIsSetThenStaysInTheFund() public {
        uint256 shares = _mint(alice, 1000e6);
        usdg.mint(address(m7m), 100e6);
        vm.mockCallRevert(address(usdg), abi.encodeWithSelector(IERC20.transfer.selector, carol), "frozen");
        vm.prank(alice);
        vm.expectRevert(bytes("frozen"));
        m7m.redeemInKind(shares / 2, carol, 0);
        vm.prank(alice);
        m7m.redeemInKind(shares / 2, carol, uint8(1 << 7));
        assertEq(usdg.balanceOf(address(m7m)), 100e6, "the USDG stays in the fund");
        assertGt(tokens[0].balanceOf(carol), 0, "the seven are paid");
    }

    /// A transfer that returns false instead of reverting is a failure too: forfeited with its
    /// bit set (SafeERC20's own test, inline).
    function test_ATransferThatReturnsFalseIsForfeitedWithItsBitSet() public {
        uint256 shares = _mint(alice, 1000e6);
        vm.mockCall(address(tokens[5]), abi.encodeWithSelector(IERC20.transfer.selector, carol), abi.encode(false));
        uint256 held5 = _held(5);
        vm.prank(alice);
        m7m.redeemInKind(shares / 2, carol, uint8(1 << 5));
        assertEq(_held(5), held5, "nothing left the fund");
    }

    // ---------------------------------------------------------- the clock ---

    /// Shares held one second under a day exit at 1 % (0.3 % to the owner, 0.7 % burned for
    /// the holders), at one day at 0.3 % - the owner's part is the same either way.
    function test_SharesHeldUnderOneDayPayOnePercentAndOneDayThreeTenths() public {
        uint256 shares = _mint(alice, 1000e6);
        uint256 t0 = vm.getBlockTimestamp(); // not block.timestamp: via_ir re-reads it after vm.warp
        assertEq(m7m.heldSince(alice), t0);
        uint256 part = shares / 2;
        vm.warp(t0 + 1 days - 1);
        assertEq(m7m.exitFeeBps(alice), 100);
        uint256 snap = vm.snapshotState();
        uint256 supply = m7m.totalSupply();
        vm.prank(alice);
        m7m.redeemInKind(part, carol, 0);
        assertEq(m7m.balanceOf(sponsor), part * 30 / 10_000, "0.3 % of the shares to the owner");
        assertEq(m7m.totalSupply(), supply - part + part * 30 / 10_000, "the rest burned, the 0.7 % with it");
        vm.revertToState(snap);

        vm.warp(t0 + 1 days);
        assertEq(m7m.exitFeeBps(alice), 30);
        vm.prank(alice);
        m7m.redeemInKind(part, carol, 0);
        assertEq(m7m.balanceOf(sponsor), part * 30 / 10_000, "0.3 % of the shares, nothing else");
    }

    /// The early penalty goes to the holders who stay, not the owner, through both doors: 0.7 %
    /// of the shares burned for nothing, 0.3 % to the owner - bob, who stays, sees his NAV per
    /// share rise both times.
    function test_AnEarlyExitLeavesItsPenaltyWithTheHoldersNotTheOwner() public {
        _mint(bob, 1000e6);
        vm.warp(block.timestamp + 1 days);
        _tick();
        uint256 shares = _mint(alice, 1000e6);
        uint256 perShare = m7m.navPerShare();

        uint256 snap = vm.snapshotState();
        uint256 due = _held(0) * _paid(alice, shares) / m7m.totalSupply();
        M7m.Route[7] memory r;
        r[0] = _route(0, true, due);
        vm.prank(alice);
        m7m.redeem(shares, r, 0, carol);
        assertEq(m7m.balanceOf(sponsor), shares * 30 / 10_000, "the owner's 0.3 %, in shares");
        assertGt(m7m.navPerShare(), perShare, "the 0.7 % burned raises the holders' NAV per share");
        vm.revertToState(snap);

        vm.prank(alice);
        m7m.redeemInKind(shares, carol, 0);
        assertEq(m7m.balanceOf(sponsor), shares * 30 / 10_000, "the owner's 0.3 %, in shares");
        assertGt(m7m.navPerShare(), perShare, "the 0.7 % burned for nothing raises the holders' NAV per share");
    }

    /// 1 wei received after a day leaves the clock where it was: the exit stays at 0.3 %.
    function test_OneWeiReceivedAfterOneDayLeavesTheFeeAtThreeTenths() public {
        _mint(alice, 1000e6);
        _mint(bob, 1000e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        assertTrue(m7m.transfer(alice, 1));
        assertEq(m7m.exitFeeBps(alice), 30, "a stranger's wei cannot restart the clock");
    }

    /// A whole balance moved to a fresh address starts a fresh clock: no laundering the age.
    function test_AFreshAddressReceivingAWholeBalancePaysOnePercent() public {
        uint256 shares = _mint(alice, 1000e6);
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        assertTrue(m7m.transfer(carol, shares));
        vm.warp(block.timestamp + 12 hours);
        assertEq(m7m.exitFeeBps(alice), 30);
        assertEq(m7m.exitFeeBps(carol), 100, "carol's clock started at the transfer");
    }

    /// A holder topping up with as many shares as they hold sits halfway between now and what
    /// they held - counted at most one hold period old (M7): received at t0, topped up at t0 + 2
    /// days, the clock reads t0 + 1.5 days.
    function test_AHolderToppingUpWithAnEqualAmountSitsHalfway() public {
        uint256 t0 = vm.getBlockTimestamp(); // not block.timestamp: via_ir re-reads it after vm.warp
        uint256 shares = _mint(alice, 1000e6);
        assertEq(_mint(bob, 1000e6), shares, "same price, same shares");
        vm.warp(t0 + 2 days);
        vm.prank(bob);
        assertTrue(m7m.transfer(alice, shares));
        assertEq(m7m.heldSince(alice), t0 + 1.5 days, "the mean of (t0 + 2 days - 1 day) and t0 + 2 days");
        assertEq(m7m.heldSince(bob), t0, "the sender's clock does not move");
    }

    /// Security review 2026-10-15, M7. The weighted clock banked age without limit: 1 USDG held 100
    /// days absorbed 90 times as many fresh shares and exited at 0.3 % the second it minted. Held
    /// shares now count as at most one hold period old: the fresh mint pays 1 %.
    function test_AnOldSmallBalanceCannotLaunderFreshSharesOutOfThePenalty() public {
        uint256 t0 = vm.getBlockTimestamp(); // not block.timestamp: via_ir re-reads it after vm.warp
        _mint(alice, 1e6);
        vm.warp(t0 + 100 days);
        _tick();
        _mint(alice, 90e6);
        assertEq(m7m.exitFeeBps(alice), 100, "630 USDG of shares minted this second: the penalty applies");
    }

    /// A transfer restarts the receiver's clock and leaves the sender's alone.
    function test_ATransferResetsTheReceiversClockAndNotTheSenders() public {
        _mint(alice, 1000e6);
        uint256 t0 = vm.getBlockTimestamp(); // not block.timestamp: via_ir re-reads it after vm.warp
        vm.warp(t0 + 31 days);
        vm.prank(alice);
        assertTrue(m7m.transfer(bob, 1e18));
        assertEq(m7m.heldSince(bob), t0 + 31 days, "the receiver's clock starts now");
        assertEq(m7m.exitFeeBps(bob), 100);
        assertEq(m7m.heldSince(alice), t0, "the sender's does not move");
        assertEq(m7m.exitFeeBps(alice), 30);
    }

    /// Fuzz: a first mint at any amounts and router prices, then `redeemInKind` of every share
    /// the minter holds, never returns more of a leg than its route delivered.
    function testFuzz_MintThenRedeemInKindNeverReturnsMoreOfALegThanWasDelivered(uint256[7] memory amounts, uint256[7] memory rates) public {
        for (uint256 i = 0; i < N; i++) {
            amounts[i] = bound(amounts[i], 1, 1e12);
            // A first mint must deliver at least 99 % of each route's cost at Chainlink (L-a), so
            // the routers fuzzed here deliver between the fair rate and a hundred times it.
            uint256 fair = 1e38 / (prices[i] * 1e8);
            rates[i] = bound(rates[i], fair, fair * 100);
            router.setPairRate(address(usdg), address(tokens[i]), rates[i]);
        }
        uint256 shares = _mintSplit(alice, amounts);
        vm.prank(alice);
        m7m.redeemInKind(shares, alice, 0);
        for (uint256 i = 0; i < N; i++) {
            uint256 delivered = amounts[i] * rates[i] / 1e18;
            assertLe(tokens[i].balanceOf(alice), delivered, "never more than was delivered");
        }
    }

    // ---------------------------------------------------------- rebalance ---

    /// Security review 2026-10-15, M3. `rebalance` is the owner's: a stranger's routes could keep
    /// everything above the 1 % floor (the fork PoC: 9 534 units of an 853 927 sale).
    function test_AStrangerCannotRebalance() public {
        _mint(alice, 1000e6);
        address mallory = makeAddr("mallory");
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        m7m.rebalance(new M7m.Route[](0));
    }

    /// The time sensor: 20 hours after the last rebalance, not a second before.
    function test_RebalanceIsRefusedWithTooSoonBeforeTwentyHours() public {
        _mint(alice, 1000e6);
        _rebalance(new M7m.Route[](0));
        uint256 readyAt = block.timestamp + 20 hours;
        vm.warp(readyAt - 1);
        _tick();
        vm.expectRevert(abi.encodeWithSelector(M7m.TooSoon.selector, readyAt));
        _rebalance(new M7m.Route[](0));
        vm.warp(readyAt);
        _rebalance(new M7m.Route[](0));
    }

    /// The round sensor: one live feed that kept its round holds the whole rebalance back.
    function test_RebalanceIsRefusedWithFeedNotMovedWhenOneLiveFeedKeptItsRound() public {
        _mint(alice, 1000e6);
        _rebalance(new M7m.Route[](0)); // first ever: stored rounds are 0, so it passes
        vm.warp(block.timestamp + 20 hours);
        _tick();
        feeds[5].setRoundId(42); // META back on the round recorded last time
        vm.expectRevert(abi.encodeWithSelector(M7m.FeedNotMoved.selector, address(tokens[5])));
        _rebalance(new M7m.Route[](0));
    }

    /// What m7m records for a feed: its round id, or 0 when it does not answer.
    function _roundIdOrZero(uint256 i) internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(feeds[i]).staticcall(abi.encodeWithSignature("latestRoundData()"));
        if (!ok) return 0;
        (uint80 id,,,,) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
        return id;
    }

    /// A dead feed - seven days old, answering <= 0, or reverting - is ignored: not valued,
    /// not traded, not waited for; the six others target `nav / 6`.
    function test_ADeadFeedIsIgnoredAndTheSixOthersTargetNavOverSix() public {
        _mint(alice, 1000e6);
        for (uint256 kind = 0; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            vm.warp(block.timestamp + 8 days);
            _tick();
            // forge-lint: disable-next-line(unsafe-typecast)
            if (kind == 0) feeds[6].setAnswer(int256(prices[6] * 1e8), block.timestamp - 7 days - 1);
            if (kind == 1) feeds[6].setAnswer(0, block.timestamp);
            if (kind == 2) feeds[6].setReverting(true);
            uint256 up = prices[0] * 1e8 * 112 / 100;
            _reprice(0, up); // AAPL +12 %: 1120 against five legs at 1000
            uint256 tslaRound = _roundIdOrZero(6);

            M7m.Leg[7] memory l = m7m.legs();
            assertFalse(l[6].live, "TSLA is dead");
            assertEq(l[6].value, 0, "and not valued");
            assertEq(m7m.nav(), 6120e6, "nav is the six live legs");
            M7m.PlanLeg[] memory p = m7m.plan();
            assertEq(p.length, 1, "only AAPL is out of band against nav / 6 = 1020; the five at 1000 are 1.96 % under, in band");
            assertEq(p[0].leg, 0);
            assertEq(p[0].amountIn, (1120e6 - 1020e6) * 1e20 / up);

            vm.expectRevert(abi.encodeWithSelector(M7m.LegNotDue.selector, address(tokens[6])));
            _rebalance(_one(_route(6, true, 1)));

            _run(p); // TSLA's round is not waited for
            assertEq(m7m.roundAtLastRebalance()[6], tslaRound, "its round is recorded as read");
            _assertAllInBand();
            vm.revertToState(snap);
        }
    }

    /// A leg within 2 % of its target refuses a route, on either side.
    function test_ALegInBandRefusesARouteWithLegNotDue() public {
        _mint(alice, 1000e6);
        _reprice(1, prices[1] * 1e8 * 1015 / 1000); // MSFT +1.5 %, inside the 2 % band
        vm.expectRevert(abi.encodeWithSelector(M7m.LegNotDue.selector, address(tokens[1])));
        _rebalance(_one(_route(1, true, 1e15)));
        _reprice(1, prices[1] * 1e8 * 13 / 10); // now out of band, but on the sell side
        vm.expectRevert(abi.encodeWithSelector(M7m.LegNotDue.selector, address(tokens[1])));
        _rebalance(_one(_route(1, false, 1e6)));
    }

    /// Sells come before buys, and a leg is traded at most once.
    function test_SellsMustPrecedeBuysAndALegIsTradedOnce() public {
        _mint(alice, 1000e6);
        _reprice(0, prices[0] * 1e8 * 12 / 10);
        _reprice(1, prices[1] * 1e8 * 8 / 10);
        usdg.mint(address(m7m), 10e6); // so the buy placed first can run and the order is what refuses
        M7m.Route[] memory routes = new M7m.Route[](2);
        routes[0] = _route(1, false, 10e6);
        routes[1] = _route(0, true, 1e15);
        vm.expectRevert(M7m.SellsFirst.selector);
        _rebalance(routes);

        routes[0] = _route(0, true, 1e15);
        routes[1] = _route(0, true, 1e15);
        vm.expectRevert(abi.encodeWithSelector(M7m.DuplicateLeg.selector, address(tokens[0])));
        _rebalance(routes);
    }

    /// A sell never pushes past the target, nor a buy: one unit over is `OverTrade`.
    function test_ATradePastTheTargetIsRefusedWithOverTrade() public {
        _mint(alice, 1000e6);
        uint256 up = prices[0] * 1e8 * 12 / 10;
        _reprice(0, up);
        _reprice(1, prices[1] * 1e8 * 8 / 10);
        // nav 7000, target 1000: AAPL 200 over, MSFT 200 under.
        uint256 maxSell = 200e6 * 1e20 / up;
        vm.expectRevert(abi.encodeWithSelector(M7m.OverTrade.selector, address(tokens[0]), maxSell + 1, maxSell));
        _rebalance(_one(_route(0, true, maxSell + 1)));
        vm.expectRevert(abi.encodeWithSelector(M7m.OverTrade.selector, address(tokens[1]), 200e6 + 1, 200e6));
        _rebalance(_one(_route(1, false, 200e6 + 1)));
    }

    /// The floor is the contract's, from Chainlink: a router 1 % + 1 bp under the feed is
    /// refused with `InsufficientOutput`, measured on what arrived; at exactly 99 % it passes.
    function test_ARouterBelowChainlinkLessOnePercentIsRefusedWithInsufficientOutput() public {
        _mint(alice, 1000e6);
        uint256 up = prices[0] * 1e8 * 12 / 10;
        _reprice(0, up);
        uint256 amountIn = 1e15;
        uint256 value = amountIn * up / 1e20;
        uint256 floor = value * 9900 / 10_000;
        router.setPairRate(address(tokens[0]), address(usdg), up / 100 * 9899 / 10_000);
        uint256 got = amountIn * (up / 100 * 9899 / 10_000) / 1e18;
        vm.expectRevert(abi.encodeWithSelector(M7m.InsufficientOutput.selector, got, floor));
        _rebalance(_one(_route(0, true, amountIn)));

        router.setPairRate(address(tokens[0]), address(usdg), up / 100 * 9900 / 10_000);
        _rebalance(_one(_route(0, true, amountIn)));
    }

    /// A full day: AAPL up 20 %, MSFT down 20 %; one sell, one buy, both from `plan()`, and
    /// both legs end within the band. `LegTraded` carries each trade.
    function test_AFullDayWithOneSellAndOneBuyEndsWithBothLegsInBand() public {
        _mint(alice, 1000e6);
        _reprice(0, prices[0] * 1e8 * 12 / 10);
        _reprice(1, prices[1] * 1e8 * 8 / 10);
        M7m.PlanLeg[] memory p = m7m.plan();
        assertEq(p.length, 2);
        assertTrue(p[0].sell && p[0].leg == 0, "the sell first");
        assertTrue(!p[1].sell && p[1].leg == 1, "then the buy");
        assertEq(p[0].deviationBps, 2000);
        assertEq(p[1].deviationBps, -2000);
        assertEq(p[1].amountIn, p[0].minOut, "the buy is sized to what the sell must bring");

        vm.expectEmit(true, false, false, true, address(m7m));
        // 666 666 666 666 666 666 AAPL at 300 USDG: 199.999999 USDG, the last wei rounded down.
        emit M7m.LegTraded(address(tokens[0]), true, p[0].amountIn, 199_999_999, int256(prices[0] * 1e8 * 12 / 10));
        _run(p);
        _assertAllInBand();
        (uint256 timestamp, uint256 navAt, uint256 liveCount, uint256 legsTraded) = m7m.lastRebalance();
        assertEq(timestamp, block.timestamp);
        assertEq(navAt, 7000e6);
        assertEq(liveCount, 7);
        assertEq(legsTraded, 2);
    }

    /// USDG held is counted in `nav` and spent by the buys: 700 USDG on the fund lifts the
    /// target to 1100, the seven buys of `plan()` spend it all.
    function test_UsdgHeldIsCountedInNavAndSpentByBuys() public {
        _mint(alice, 1000e6);
        usdg.mint(address(m7m), 700e6);
        assertEq(m7m.nav(), 7700e6);
        M7m.PlanLeg[] memory p = m7m.plan();
        assertEq(p.length, 7);
        for (uint256 k = 0; k < 7; k++) {
            assertFalse(p[k].sell);
            assertEq(p[k].amountIn, 100e6);
        }
        _run(p);
        assertEq(usdg.balanceOf(address(m7m)), 0, "every USDG spent");
        _assertAllInBand();
    }

    /// An empty `routes` passes the sensors and consumes the day: the documented griefing.
    function test_AnEmptyRebalanceConsumesTheDay() public {
        _mint(alice, 1000e6);
        _reprice(0, prices[0] * 1e8 * 112 / 100);
        _rebalance(new M7m.Route[](0));
        assertEq(m7m.lastRebalanceAt(), block.timestamp);
        M7m.PlanLeg[] memory p = m7m.plan();
        assertEq(p.length, 1, "AAPL is still out of band");
        vm.expectRevert(abi.encodeWithSelector(M7m.TooSoon.selector, block.timestamp + 20 hours));
        _run(p);
    }

    // ------------------------------------------------------- plan / sensors ---

    /// `canRebalance()` names the sensor that says no, and `plan()` is what `rebalance` then
    /// accepts and runs to a fund in band.
    function test_CanRebalanceAndPlanSayWhatRebalanceThenDoes() public {
        _mint(alice, 1000e6);
        (bool ready, M7m.Sensor sensor,, uint256 readyAt) = m7m.canRebalance();
        assertTrue(ready && sensor == M7m.Sensor.Ready && readyAt == 20 hours, "birth: ready at once");
        _rebalance(new M7m.Route[](0));

        (ready, sensor,, readyAt) = m7m.canRebalance();
        assertTrue(!ready && sensor == M7m.Sensor.TooSoon && readyAt == block.timestamp + 20 hours);
        vm.expectRevert(abi.encodeWithSelector(M7m.TooSoon.selector, readyAt));
        _rebalance(new M7m.Route[](0));

        vm.warp(readyAt);
        address token;
        (ready, sensor, token,) = m7m.canRebalance();
        assertTrue(!ready && sensor == M7m.Sensor.FeedNotMoved && token == address(tokens[0]));
        vm.expectRevert(abi.encodeWithSelector(M7m.FeedNotMoved.selector, address(tokens[0])));
        _rebalance(new M7m.Route[](0));

        _tick();
        _reprice(3, prices[3] * 1e8 * 3 / 2);
        _reprice(4, prices[4] * 1e8 * 7 / 10);
        (ready, sensor,,) = m7m.canRebalance();
        assertTrue(ready && sensor == M7m.Sensor.Ready);
        _run(m7m.plan());
        _assertAllInBand();
    }

    // ----------------------------------------------------------- the cost ---

    /// The cost record: a mint adds what it spent per leg; a redeem in kind removes the burned
    /// share of it; a rebalance sell of half a holding halves it; `mintInKind` adds the
    /// Chainlink value, 0 on a dead feed; `totalCost` is the sum; and `nav - totalCost` moves
    /// with the feed's answer and with nothing else.
    function test_TheCostRecordFollowsWhatWasPaidAndNavMinusCostMovesOnlyWithTheFeed() public {
        _mint(alice, 1000e6);
        for (uint256 i = 0; i < N; i++) {
            assertEq(m7m.legs()[i].cost, 1000e6, "a mint adds what it spent on the leg");
            assertEq(m7m.legs()[i].avgCost, prices[i] * 1e6, "average price paid, USDG per whole token");
        }
        assertEq(m7m.totalCost(), 7000e6);
        assertEq(m7m.nav(), m7m.totalCost(), "bought at the feed's price: nothing unrealised");

        _reprice(2, prices[2] * 1e8 * 11 / 10);
        assertEq(int256(m7m.nav()) - int256(m7m.totalCost()), 100e6, "+10 % on one leg: +100 USDG unrealised, nothing else moved");

        // A quarter of the supply leaves in kind, less its exit fee and early penalty in shares.
        uint256 supply = m7m.totalSupply();
        uint256 quarter = supply / 4;
        uint256 burned = quarter - quarter * 30 / 10_000 - quarter * 70 / 10_000;
        uint256[7] memory heldBefore;
        for (uint256 i = 0; i < N; i++) {
            heldBefore[i] = _held(i);
        }
        vm.prank(alice);
        m7m.redeemInKind(quarter, alice, 0);
        for (uint256 i = 0; i < N; i++) {
            uint256 due = heldBefore[i] * burned / supply;
            assertEq(m7m.legs()[i].cost, 1000e6 - 1000e6 * due / heldBefore[i], "the burned share of the cost left with it");
        }

        // AAPL x3: sell half of its holding.
        _reprice(0, prices[0] * 1e8 * 3);
        uint256 costBefore0 = m7m.legs()[0].cost;
        uint256 heldA = _held(0);
        uint256 half = heldA / 2;
        _rebalance(_one(_route(0, true, half)));
        assertEq(m7m.legs()[0].cost, costBefore0 - costBefore0 * half / heldA, "half the holding sold: half the cost");

        // mintInKind: the Chainlink value on a live leg, 0 on a dead one.
        feeds[5].setReverting(true);
        uint256[7] memory amounts;
        for (uint256 i = 0; i < N; i++) {
            amounts[i] = _held(i);
            tokens[i].mint(bob, amounts[i]);
            vm.prank(bob);
            tokens[i].approve(address(m7m), amounts[i]);
        }
        uint256 costBefore4 = m7m.legs()[4].cost;
        uint256 value4 = m7m.legs()[4].value;
        uint256 costBefore5 = m7m.legs()[5].cost;
        vm.prank(bob);
        m7m.mintInKind(amounts, 1, bob);
        assertEq(m7m.legs()[4].cost, costBefore4 + value4, "in kind on a live leg: booked at Chainlink value");
        assertEq(m7m.legs()[5].cost, costBefore5, "in kind on a dead leg: booked at 0");

        uint256 sum;
        M7m.Leg[7] memory l = m7m.legs();
        for (uint256 i = 0; i < N; i++) {
            sum += l[i].cost;
        }
        assertEq(m7m.totalCost(), sum, "totalCost is the sum");
    }

    // ----------------------------------------------------------- the legs ---

    /// The seven legs read back as constructed after a full day - a first mint, a second
    /// seven-route mint, a seven-leg rebalance, a redeem and a redeem in kind - since no function
    /// in the ABI writes them. Also the test `--gas-report --isolate` measures the seven-route
    /// mint and the seven-leg rebalance on.
    function test_TheSevenLegsReadBackAsConstructedAfterAFullDay() public {
        _mint(alice, 1000e6);
        _mint(bob, 100e6);
        usdg.mint(address(m7m), 770e6); // target 1210: every leg 110 under, seven buys due
        M7m.PlanLeg[] memory p = m7m.plan();
        assertEq(p.length, 7, "a seven-leg rebalance");
        _run(p);
        M7m.Route[7] memory r;
        r[0] = _route(0, true, _held(0) / 10);
        uint256 aliceHalf = m7m.balanceOf(alice) / 2; // read before the prank, which a call in the arguments would consume
        vm.prank(alice);
        m7m.redeem(aliceHalf, r, 0, alice);
        uint256 bobShares = m7m.balanceOf(bob);
        vm.prank(bob);
        m7m.redeemInKind(bobShares, bob, 0);

        M7m.Leg[7] memory l = m7m.legs();
        for (uint256 i = 0; i < N; i++) {
            assertEq(l[i].token, address(tokens[i]), "the token constructed");
            assertEq(l[i].feed, address(feeds[i]), "the feed constructed");
            assertEq(l[i].feedDecimals, 8, "its decimals as read at construction");
        }
        assertEq(address(m7m.USDG()), address(usdg));
        assertEq(address(m7m.UNIVERSAL_ROUTER()), address(router));
    }

    // ------------------------------------------------------- feed replacement ---

    /// Security review 2026-10-15, M4 + M5. The owner cannot touch a live feed (the PoC: six
    /// feeds proposed, applied three days later at 1, the fund taken; a proposal never expired):
    /// `replaceFeed` is refused while the feed is live, whoever waits.
    function test_TheOwnerCannotReplaceALiveFeed() public {
        FeedMock next = new FeedMock(8, 1, block.timestamp);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(M7m.FeedStillLive.selector, 2));
        m7m.replaceFeed(2, address(next));
        vm.warp(block.timestamp + 400 days - 1);
        feeds[2].setAnswer(int256(prices[2] * 1e8), block.timestamp);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(M7m.FeedStillLive.selector, 2));
        m7m.replaceFeed(2, address(next));
    }

    /// Over a dead feed - reverting, or 8 days silent - the owner replaces it at once; the new feed
    /// must answer five words and keep the leg's decimals.
    function test_TheOwnerReplacesADeadFeedAtOnceWithOneThatAnswersAtTheSameDecimals() public {
        for (uint256 kind = 0; kind < 2; kind++) {
            uint256 snap = vm.snapshotState();
            vm.warp(block.timestamp + 8 days);
            if (kind == 0) feeds[2].setReverting(true);
            GarbageRegistryMock garbage = new GarbageRegistryMock();
            garbage.setAnswer(abi.encode(uint256(8))); // decimals() fine, one word to latestRoundData()
            FeedMock eighteen = new FeedMock(18, 200e18, block.timestamp);
            FeedMock next = new FeedMock(8, int256(prices[2] * 1e8), block.timestamp);
            vm.startPrank(sponsor);
            vm.expectRevert(abi.encodeWithSelector(M7m.BadFeed.selector, address(garbage)));
            m7m.replaceFeed(2, address(garbage));
            vm.expectRevert(abi.encodeWithSelector(M7m.BadFeed.selector, address(eighteen)));
            m7m.replaceFeed(2, address(eighteen));
            vm.expectEmit(true, false, false, true, address(m7m));
            emit M7m.FeedReplaced(2, address(feeds[2]), address(next));
            m7m.replaceFeed(2, address(next));
            vm.stopPrank();
            assertEq(m7m.legs()[2].feed, address(next));
            assertTrue(m7m.legs()[2].live);
            vm.revertToState(snap);
        }
    }

    /// The new feed's round counter is not compared with the old one's: the next rebalance after a
    /// replacement passes the round sensor for that leg, with the same round id 42 the old feed
    /// had when it was recorded.
    function test_TheRebalanceAfterAReplacedFeedDoesNotWaitOnTheOldFeedsRound() public {
        _mint(alice, 1000e6);
        _rebalance(new M7m.Route[](0)); // records round 42 for every leg
        vm.warp(block.timestamp + 20 hours);
        _tick();
        feeds[2].setReverting(true);
        FeedMock next = new FeedMock(8, int256(prices[2] * 1e8), block.timestamp); // round id 42
        vm.prank(sponsor);
        m7m.replaceFeed(2, address(next));
        assertEq(m7m.roundAtLastRebalance()[2], 0, "the leg's recorded round is reset");
        _rebalance(new M7m.Route[](0));
        assertEq(m7m.roundAtLastRebalance()[2], 42, "and the new feed's round is recorded");
    }

    /// A stranger cannot replace a feed, dead or not.
    function test_AStrangerCannotReplaceAFeed() public {
        feeds[2].setReverting(true);
        FeedMock next = new FeedMock(8, int256(prices[2] * 1e8), block.timestamp);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        m7m.replaceFeed(2, address(next));
    }

    // -------------------------------------------------------------- owner ---

    /// `rescueToken` refuses each of the seven and USDG, and hands over a stranger token.
    function test_RescueTokenRefusesTheSevenAndUsdgAndAcceptsAStranger() public {
        _mint(alice, 1000e6);
        vm.startPrank(sponsor);
        for (uint256 i = 0; i < N; i++) {
            vm.expectRevert(abi.encodeWithSelector(M7m.NotRescuable.selector, address(tokens[i])));
            m7m.rescueToken(IERC20(address(tokens[i])), sponsor);
        }
        vm.expectRevert(abi.encodeWithSelector(M7m.NotRescuable.selector, address(usdg)));
        m7m.rescueToken(IERC20(address(usdg)), sponsor);
        TokenMock stranger = new TokenMock("X", "X", 18);
        stranger.mint(address(m7m), 5e18);
        assertEq(m7m.rescueToken(IERC20(address(stranger)), sponsor), 5e18);
        vm.stopPrank();
        assertEq(stranger.balanceOf(sponsor), 5e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        m7m.rescueToken(IERC20(address(stranger)), alice);
    }

    /// Ownership can be transferred, never renounced; the fees then go to the new owner.
    function test_RenounceOwnershipRevertsAndTransferOwnershipWorks() public {
        vm.prank(sponsor);
        vm.expectRevert(M7m.RenounceForbidden.selector);
        m7m.renounceOwnership();

        vm.prank(sponsor);
        m7m.transferOwnership(carol);
        assertEq(m7m.owner(), carol);
        uint256 usdgIn = _gross(700e6);
        _mint(alice, 100e6);
        assertEq(usdg.balanceOf(carol), usdgIn - 700e6, "the entry fee goes to the new owner");
        assertEq(usdg.balanceOf(sponsor), 0);
    }
}
