// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IUniversalRouter } from "../src/MaidMarianSevenMagnificent.sol";
import { MaidMarianEtfFactory as Factory } from "../src/MaidMarianEtfFactory.sol";
import { MaidMarianEtfV3 as Etf, SOURCE_NONE } from "../src/MaidMarianEtfV3.sol";
import { MaidMarianEtfFactoryRef as FactoryRef } from "./ref/MaidMarianEtfFactoryRef.sol";
import { TokenMock, PoolMock } from "./Mocks.sol";
import { MaidMarianEtfV3Base } from "./MaidMarianEtfV3.t.sol";

/// Three legs (AAA 250, BBB 500, CCC 125 USDG; 50 / 30 / 20 %) for the v3 bis tests.
abstract contract EtfV3BisBase is MaidMarianEtfV3Base {
    TokenMock internal a;
    TokenMock internal b;
    TokenMock internal c;
    PoolMock internal pa;
    PoolMock internal pb;
    PoolMock internal pc;

    function setUp() public virtual override {
        super.setUp();
        (a, pa) = _token("AAA", 250);
        (b, pb) = _token("BBB", 500);
        (c, pc) = _token("CCC", 125);
        _v4Pool(address(c), 100, 1);
    }

    function _legs3() internal view returns (address[] memory t, uint16[] memory w) {
        t = new address[](3);
        (t[0], t[1], t[2]) = (address(a), address(b), address(c));
        w = new uint16[](3);
        (w[0], w[1], w[2]) = (5000, 3000, 2000);
    }

    function _approveLegs(address who, address etf_) internal {
        vm.startPrank(who);
        a.approve(etf_, type(uint256).max);
        b.approve(etf_, type(uint256).max);
        c.approve(etf_, type(uint256).max);
        usdg.approve(etf_, type(uint256).max);
        vm.stopPrank();
    }
}

/**
 * The v3 bis's doors give the same shares as the deployed v3: the same calls, by the same callers,
 * on an ETF of each factory over the same mocks (tokens, pools, router), compared after every step
 * - what each call returns, every caller's tokens and USDG moved, and each fund's supply, holdings,
 * balances, `mintOf`, `lastMintAt` and clocks. The reference is `test/ref/`, the deployed source
 * renamed; the v3 bis ETF is a clone of the factory's implementation. Proves the cost bookkeeping, the
 * renames and the clone changed no door's arithmetic, on mocks.
 */
contract MaidMarianEtfV3BisParityTest is EtfV3BisBase {
    FactoryRef internal refFactory;
    Etf internal etf;
    address internal refEtf;

    function setUp() public override {
        super.setUp();
        refFactory = new FactoryRef(IERC20(address(usdg)), IUniversalRouter(address(router)), address(v3), owner);
        vm.startPrank(owner);
        refFactory.addToken(address(a), address(pa));
        refFactory.addToken(address(b), address(pb));
        refFactory.addToken(address(c), address(pc));
        refFactory.setTokenV4Pool(address(c), 100, 1);
        vm.stopPrank();

        Etf.Params memory p = Etf.Params({ entryFeeBps: 50, exitFeeBps: 30, holdPeriod: 1 days, earlyPenaltyBps: 100, nonMinterPenaltyBps: 200, rebalanceBandBps: 200, rebalanceMinInterval: 1 hours });
        (address[] memory t, uint16[] memory w) = _legs3();
        etf = _createWith("PAR", t, w, p);
        vm.prank(maker);
        (bool ok, bytes memory ret) = address(refFactory).call{ value: FEE }(abi.encodeWithSelector(FactoryRef.createEtf.selector, "Maid Marian PAR", "PAR", bytes(""), _spec(t, w), p));
        require(ok, "ref createEtf");
        refEtf = abi.decode(ret, (address));
        for (uint256 i = 0; i < 3; i++) {
            address who = i == 0 ? alice : i == 1 ? bob : carol;
            _approveLegs(who, address(etf));
            _approveLegs(who, refEtf);
        }
    }

    function _actors() internal view returns (address[5] memory) {
        return [alice, bob, carol, maker, owner];
    }

    /// Every actor's USDG, AAA, BBB and CCC.
    function _wallets() internal view returns (uint256[] memory w) {
        address[5] memory who = _actors();
        w = new uint256[](20);
        for (uint256 i = 0; i < 5; i++) {
            (w[4 * i], w[4 * i + 1], w[4 * i + 2], w[4 * i + 3]) = (usdg.balanceOf(who[i]), a.balanceOf(who[i]), b.balanceOf(who[i]), c.balanceOf(who[i]));
        }
    }

    /// A fund's supply, holdings, every actor's shares, `mintOf` and `lastMintAt`, and its clocks.
    function _state(address e) internal view returns (bytes memory s) {
        Etf f = Etf(e);
        s = abi.encode(f.totalSupply(), usdg.balanceOf(e), a.balanceOf(e), b.balanceOf(e), c.balanceOf(e), f.lastRebalanceAt(), f.lastAccrualAt());
        address[5] memory who = _actors();
        for (uint256 i = 0; i < 5; i++) {
            s = abi.encodePacked(s, abi.encode(f.balanceOf(who[i]), f.mintOf(who[i]), f.lastMintAt(who[i])));
        }
    }

    /// `data` sent by `who` to both ETFs: the same answer, the same moves in every wallet, the same funds and reads after.
    function _both(address who, bytes memory data) internal returns (bytes memory ret) {
        uint256[] memory w0 = _wallets();
        vm.prank(who);
        (bool ok, bytes memory retNew) = address(etf).call(data);
        if (!ok) _bubble(retNew);
        uint256[] memory w1 = _wallets();
        vm.prank(who);
        bytes memory retRef;
        (ok, retRef) = refEtf.call(data);
        if (!ok) _bubble(retRef);
        uint256[] memory w2 = _wallets();
        assertEq(retNew, retRef, "the same answer");
        for (uint256 k = 0; k < w0.length; k++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(int256(w1[k]) - int256(w0[k]), int256(w2[k]) - int256(w1[k]), "the same wallet move");
        }
        assertEq(_state(address(etf)), _state(refEtf), "the same fund after");
        _sameReads(who);
        return retNew;
    }

    function _bubble(bytes memory reason) internal pure {
        assembly ("memory-safe") {
            revert(add(reason, 32), mload(reason))
        }
    }

    function _same(bytes memory call_) internal view {
        (bool ok1, bytes memory r1) = address(etf).staticcall(call_);
        (bool ok2, bytes memory r2) = refEtf.staticcall(call_);
        assertTrue(ok1 && ok2);
        assertEq(r1, r2, "the same view");
    }

    /// The parameters, legs, name and symbol the clone reads from its arguments, and the views built on them,
    /// for `holder`.
    function _sameReads(address holder) internal view {
        bytes4[12] memory reads = [
            Etf.name.selector,
            Etf.symbol.selector,
            bytes4(keccak256("decimals()")),
            Etf.params.selector,
            Etf.LEGS.selector,
            Etf.ENTRY_FEE_BPS.selector,
            Etf.EXIT_FEE_BPS.selector,
            Etf.HOLD_PERIOD.selector,
            Etf.EARLY_PENALTY_BPS.selector,
            Etf.NON_MINTER_PENALTY_BPS.selector,
            Etf.REBALANCE_BAND_BPS.selector,
            Etf.REBALANCE_MIN_INTERVAL.selector
        ];
        for (uint256 i = 0; i < reads.length; i++) {
            _same(abi.encodeWithSelector(reads[i]));
        }
        _same(abi.encodeWithSignature("USDG()"));
        _same(abi.encodeWithSignature("UNIVERSAL_ROUTER()"));
        _same(abi.encodeCall(Etf.entryFee, (10_000)));
        _same(abi.encodeCall(Etf.exitRates, (holder)));
        _same(abi.encodeCall(Etf.canRebalance, ()));
        _same(abi.encodeCall(Etf.nav, ()));
        _same(abi.encodeCall(Etf.accruedSupply, ()));
        _same(abi.encodeCall(Etf.pendingManagementFee, ()));
        _same(abi.encodeCall(Etf.previewRedeem, (holder, 1e18)));
    }

    /// Mint, a V4 route, mint in kind, a rebalance after a move, a transfer, both redeems (early,
    /// non-minter, the fee recipient a year later, a whole exit): the same shares at every door, and the
    /// same reads of the parameters and legs before and after each door.
    function test_EveryDoorGivesTheSameSharesAsTheDeployedV3() public {
        _sameReads(alice);
        Etf.Route[] memory r = _buyRoutes(etf, 1000e6, true);
        _same(abi.encodeCall(Etf.firstMintSplit, (1000e6)));
        _both(alice, abi.encodeCall(Etf.mint, (1000e6, r, 1)));

        vm.warp(vm.getBlockTimestamp() + 1 days);
        r = _buyRoutes(etf, 500e6, false);
        r[2].v4 = true;
        _both(bob, abi.encodeCall(Etf.mint, (500e6, r, 1)));

        _same(abi.encodeCall(Etf.quoteMint, (50e18)));
        (uint256[] memory need,) = etf.quoteMint(50e18);
        uint256[] memory bring = new uint256[](3);
        (bring[0], bring[1], bring[2]) = (need[0] * 2, need[1], need[2] * 3);
        a.mint(bob, 2 * bring[0]);
        b.mint(bob, 2 * bring[1]);
        c.mint(bob, 2 * bring[2]);
        _both(bob, abi.encodeCall(Etf.mintInKind, (bring, 0, 1)));

        pa.setAverageTick(address(a) < address(usdg) ? _tickAt(300e18) : -_tickAt(300e18));
        _routerAt(address(a), 300e18);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _same(abi.encodeCall(Etf.plan, ()));
        Etf.PlanLeg[] memory plan = etf.plan();
        assertTrue(plan.length >= 2 && plan[0].sell, "the move makes AAA a sale");
        _both(carol, abi.encodeCall(Etf.rebalance, (_planRoutes(plan))));

        _both(alice, abi.encodeCall(IERC20.transfer, (carol, 10e18)));
        _both(bob, abi.encodeCall(Etf.redeemInKind, (5e18, bob, 0)));

        _same(abi.encodeCall(Etf.previewRedeemToUsdg, (alice, 200e18)));
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(alice, 200e18);
        for (uint256 i = 0; i < 3; i++) {
            due[i] /= 2;
        }
        Etf.Route[] memory sell = _sellRoutes(etf, due);
        sell[2].v4 = true;
        _both(alice, abi.encodeCall(Etf.redeem, (200e18, sell, 0, alice)));
        _both(carol, abi.encodeCall(Etf.redeemInKind, (10e18, carol, 0)));

        vm.warp(vm.getBlockTimestamp() + 365 days);
        uint256 makerShares = etf.balanceOf(maker);
        assertEq(makerShares, Etf(refEtf).balanceOf(maker));
        _both(maker, abi.encodeCall(Etf.redeemInKind, (makerShares, maker, 0)));

        uint256 bobShares = etf.balanceOf(bob);
        (due,,,) = etf.previewRedeemToUsdg(bob, bobShares);
        _both(bob, abi.encodeCall(Etf.redeem, (bobShares, _sellRoutes(etf, due), 0, bob)));
    }
}

/**
 * Each leg's cost, on mocks: what every door adds or takes, to the unit, and that `legs()` and
 * `costs()` agree. The cost is display only: the parity test above shows no door reads it.
 */
contract MaidMarianEtfV3CostTest is EtfV3BisBase {
    Etf internal etf;

    function setUp() public override {
        super.setUp();
        (address[] memory t, uint16[] memory w) = _legs3();
        etf = _create("CST", t, w);
        _approveLegs(bob, address(etf));
    }

    function _held() internal view returns (uint256[] memory h) {
        h = new uint256[](3);
        (h[0], h[1], h[2]) = (a.balanceOf(address(etf)), b.balanceOf(address(etf)), c.balanceOf(address(etf)));
    }

    function _bobLegs() internal view returns (uint256[] memory h) {
        h = new uint256[](3);
        (h[0], h[1], h[2]) = (a.balanceOf(bob), b.balanceOf(bob), c.balanceOf(bob));
    }

    function _tokens() internal view returns (address[3] memory) {
        return [address(a), address(b), address(c)];
    }

    /// The first mint keeps all its swaps brought: each leg costs its route's USDG. A later mint whose
    /// BBB route is halved keeps only part of AAA and CCC and refunds the rest: those legs cost
    /// `amountIn x used / received`, BBB its whole route.
    function test_AMintBooksEachLegAtTheUsdgItsSwapSpentOnThePartTheFundKeeps() public {
        Etf.Route[] memory r = _buyRoutes(etf, 1000e6, true);
        vm.prank(alice);
        etf.mint(1000e6, r, 1);
        uint256[] memory before = etf.costs();
        for (uint256 i = 0; i < 3; i++) {
            assertEq(before[i], r[i].amountIn, "the first mint: the whole route");
        }

        r = _buyRoutes(etf, 100e6, false);
        r[1].amountIn /= 2;
        uint256[] memory bob0 = _bobLegs();
        vm.prank(bob);
        etf.mint(100e6, r, 1);
        uint256[] memory refund = _bobLegs();
        uint256[] memory after_ = etf.costs();
        address[3] memory t = _tokens();
        for (uint256 i = 0; i < 3; i++) {
            uint256 received = _out(address(usdg), t[i], r[i].amountIn);
            uint256 used = received - (refund[i] - bob0[i]);
            assertEq(after_[i] - before[i], Math.mulDiv(r[i].amountIn, used, received), "the USDG spent on the part kept");
        }
        assertEq(refund[1], bob0[1], "BBB, the scarce leg, is kept whole");
        assertEq(after_[1] - before[1], r[1].amountIn);
        assertGt(refund[0], bob0[0], "AAA's excess comes back");
    }

    /// Tokens brought in kind are booked at `getTradablePriceUsdg`: `used x price / 1e30` each.
    function test_AMintInKindBooksTheTokensKeptAtTheTradablePrice() public {
        _mint(etf, alice, 1000e6);
        (uint256[] memory need,) = etf.quoteMint(100e18);
        uint256[] memory bring = new uint256[](3);
        (bring[0], bring[1], bring[2]) = (need[0] * 2, need[1], need[2] * 3);
        a.mint(bob, bring[0]);
        b.mint(bob, bring[1]);
        c.mint(bob, bring[2]);
        uint256[] memory before = etf.costs();
        vm.prank(bob);
        etf.mintInKind(bring, 0, 1);
        uint256[] memory left = _bobLegs();
        uint256[] memory after_ = etf.costs();
        address[3] memory t = _tokens();
        for (uint256 i = 0; i < 3; i++) {
            (uint256 price,) = factory.getTradablePriceUsdg(t[i]);
            assertEq(after_[i] - before[i], Math.mulDiv(bring[i] - left[i], price, 1e30), "the kept tokens at the tradable price");
        }
    }

    /// A leg without a tradable price is booked at the fund's average cost, `cost x used / held`; the
    /// mint runs.
    function test_AMintInKindBooksAnUnpricedLegAtTheFundsAverageCost() public {
        _mint(etf, alice, 1000e6);
        pb.setNoHistory(true);
        (, uint8 source) = factory.getTradablePriceUsdg(address(b));
        assertEq(source, SOURCE_NONE, "BBB has no tradable price");
        (uint256[] memory need,) = etf.quoteMint(100e18);
        a.mint(bob, need[0]);
        b.mint(bob, need[1]);
        c.mint(bob, need[2]);
        uint256[] memory before = etf.costs();
        uint256[] memory held = _held();
        vm.prank(bob);
        etf.mintInKind(need, 0, 1);
        uint256[] memory after_ = etf.costs();
        assertEq(after_[1] - before[1], Math.mulDiv(before[1], need[1], held[1]), "BBB at the average cost");
        (uint256 price,) = factory.getTradablePriceUsdg(address(a));
        assertEq(after_[0] - before[0], Math.mulDiv(need[0], price, 1e30), "AAA still at its price");
    }

    /// What leaves through `redeem` (sold or in kind) and through `redeemInKind` takes its part of the
    /// cost: `cost x out / held`.
    function test_BothRedeemsLowerEachLegsCostByThePartThatLeaves() public {
        _mint(etf, alice, 1000e6);
        _mint(etf, bob, 500e6);

        uint256[] memory before = etf.costs();
        uint256[] memory held = _held();
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(alice, 100e18);
        uint256[] memory half = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            half[i] = due[i] / 2;
        }
        Etf.Route[] memory sell = _sellRoutes(etf, half);
        vm.prank(alice);
        etf.redeem(100e18, sell, 0, alice);
        uint256[] memory after_ = etf.costs();
        for (uint256 i = 0; i < 3; i++) {
            assertEq(before[i] - after_[i], Math.mulDiv(before[i], due[i], held[i]), "redeem: sold and in kind alike");
        }

        before = after_;
        held = _held();
        (,,, uint256[] memory amounts,) = etf.previewRedeem(bob, 50e18);
        vm.prank(bob);
        etf.redeemInKind(50e18, bob, 0);
        after_ = etf.costs();
        for (uint256 i = 0; i < 3; i++) {
            assertEq(before[i] - after_[i], Math.mulDiv(before[i], amounts[i], held[i]), "redeemInKind");
        }
    }

    /// A rebalance sale lowers the leg's cost by `cost x amountIn / held`, a purchase adds the USDG
    /// spent. A donation moves no cost.
    function test_ARebalanceSaleTakesItsPartOfTheCostAndAPurchaseAddsItsUsdg() public {
        _mint(etf, alice, 1000e6);
        uint256[] memory before = etf.costs();
        a.mint(address(etf), 1e18);
        assertEq(abi.encode(etf.costs()), abi.encode(before), "a donation moves no cost");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256[] memory held = _held();
        Etf.PlanLeg[] memory p = etf.plan();
        assertTrue(p.length >= 2 && p[0].sell && p[0].leg == 0);
        vm.prank(carol);
        etf.rebalance(_planRoutes(p));
        uint256[] memory expected = before;
        for (uint256 k = 0; k < p.length; k++) {
            uint256 i = p[k].leg;
            expected[i] = p[k].sell ? before[i] - Math.mulDiv(before[i], p[k].amountIn, held[i]) : before[i] + p[k].amountIn;
        }
        assertEq(abi.encode(etf.costs()), abi.encode(expected));
    }

    /// `legs()` carries each leg's cost beside its value, the same as `costs()`.
    function test_LegsCarriesTheCostThatCostsReturns() public {
        _mint(etf, alice, 1000e6);
        Etf.Leg[] memory l = etf.legs();
        uint256[] memory k = etf.costs();
        assertEq(k.length, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(l[i].cost, k[i]);
            assertGt(l[i].cost, 0);
        }
    }
}

/**
 * The profile, now in the factory: given at creation in the same transaction, edited by the ETF's
 * creator, every field on its allowlist. On mocks.
 */
contract MaidMarianEtfFactoryProfileTest is EtfV3BisBase {
    Etf internal etf;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        (address[] memory t, uint16[] memory w) = _legs3();
        etf = _create("PRO", t, w);
    }

    function _pro(string memory d, string memory x, string memory t, string memory w) internal pure returns (Factory.Profile memory) {
        return Factory.Profile({ description: d, x: x, telegram: t, website: w });
    }

    function _set(string memory d, string memory x, string memory t, string memory w) internal {
        vm.prank(maker);
        factory.setProfile(address(etf), d, x, t, w);
    }

    /// Each refusal is checked both at `setProfile` and at `createEtf`.
    function _expectRevert(bytes4 err, string memory d, string memory x, string memory t, string memory w) internal {
        vm.prank(maker);
        vm.expectRevert(err);
        factory.setProfile(address(etf), d, x, t, w);
        Factory.LegSpec[] memory l = _spec(_two(address(a), address(b)), _bps2(5000, 5000));
        vm.prank(maker);
        vm.expectRevert(err);
        factory.createEtf{ value: FEE }("n", "N", "", l, _params(), _pro(d, x, t, w));
    }

    function _repeat(bytes1 ch, uint256 n) internal pure returns (string memory) {
        bytes memory s = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            s[i] = ch;
        }
        return string(s);
    }

    function test_AProfileGivenAtCreationIsStoredInTheSameTransaction() public {
        vm.warp(1_800_000_000);
        Factory.LegSpec[] memory l = _spec(_two(address(a), address(b)), _bps2(5000, 5000));
        vm.prank(maker);
        Etf e = factory.createEtf{ value: FEE }("n", "N", "", l, _params(), _pro("A basket.", "https://x.com/abc", "https://t.me/abcde", "https://example.com/a"));
        (string memory d, string memory x, string memory t, string memory w, uint256 updatedAt) = factory.profileOf(address(e));
        assertEq(d, "A basket.");
        assertEq(x, "https://x.com/abc");
        assertEq(t, "https://t.me/abcde");
        assertEq(w, "https://example.com/a");
        assertEq(updatedAt, 1_800_000_000);
    }

    function test_AnEmptyProfileAtCreationStoresNothing() public view {
        (string memory d, string memory x, string memory t, string memory w, uint256 updatedAt) = factory.profileOf(address(etf));
        assertEq(bytes(d).length + bytes(x).length + bytes(t).length + bytes(w).length, 0);
        assertEq(updatedAt, 0, "no profile");
    }

    function test_TheCreatorOverwritesTheWholeProfileWithAnEventAndEmptyStringsClear() public {
        vm.expectEmit(address(factory));
        emit Factory.ProfileSet(address(etf), maker, "One.", "https://x.com/one", "https://t.me/oneone", "https://one.example");
        _set("One.", "https://x.com/one", "https://t.me/oneone", "https://one.example");
        vm.warp(vm.getBlockTimestamp() + 1);
        _set("", "https://x.com/two", "", "");
        (string memory d, string memory x, string memory t, string memory w, uint256 updatedAt) = factory.profileOf(address(etf));
        assertEq(d, "");
        assertEq(x, "https://x.com/two");
        assertEq(t, "");
        assertEq(w, "");
        assertEq(updatedAt, block.timestamp);
    }

    function test_OnlyTheEtfsCreatorAndOnlyForAnEtfOfThisFactory() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Factory.NotCreator.selector, address(etf), stranger));
        factory.setProfile(address(etf), "", "", "", "");
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Factory.NotFactoryEtf.selector, stranger));
        factory.setProfile(stranger, "", "", "", "");
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Factory.NotFactoryEtf.selector, address(a)));
        factory.setProfile(address(a), "", "", "", "");
    }

    function test_ACreatorWhoHandsTheRoleOnHandsTheProfileOn() public {
        vm.prank(maker);
        etf.setCreator(stranger);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Factory.NotCreator.selector, address(etf), maker));
        factory.setProfile(address(etf), "", "", "", "");
        vm.prank(stranger);
        factory.setProfile(address(etf), "Next.", "", "", "");
    }

    function test_ADescriptionIsAtMost280PrintableAsciiBytes() public {
        _set(_repeat("a", 280), "", "", "");
        _set(" !~ Plain text, <b>tags</b> stay text. ", "", "", "");
        _expectRevert(Factory.BadDescription.selector, _repeat("a", 281), "", "", "");
        _expectRevert(Factory.BadDescription.selector, "line\nbreak", "", "", "");
        _expectRevert(Factory.BadDescription.selector, "tab\there", "", "", "");
        _expectRevert(Factory.BadDescription.selector, string(abi.encodePacked("del", bytes1(0x7F))), "", "", "");
        _expectRevert(Factory.BadDescription.selector, string(abi.encodePacked("nul", bytes1(0x00))), "", "", "");
        _expectRevert(Factory.BadDescription.selector, unicode"café", "", "", "");
    }

    function test_AnXLinkIsTheExactPrefixAndOneToFifteenHandleBytes() public {
        _set("", "https://x.com/a", "", "");
        _set("", string.concat("https://x.com/", _repeat("Z", 15)), "", "");
        _set("", "https://x.com/A_b9", "", "");
        _expectRevert(Factory.BadX.selector, "", "https://x.com/", "", "");
        _expectRevert(Factory.BadX.selector, "", string.concat("https://x.com/", _repeat("Z", 16)), "", "");
        _expectRevert(Factory.BadX.selector, "", "http://x.com/abc", "", "");
        _expectRevert(Factory.BadX.selector, "", "https://x.com.evil/abc", "", "");
        _expectRevert(Factory.BadX.selector, "", "https://X.com/abc", "", "");
        _expectRevert(Factory.BadX.selector, "", "https://twitter.com/abc", "", "");
        _expectRevert(Factory.BadX.selector, "", "https://x.com/abc/", "", "");
        _expectRevert(Factory.BadX.selector, "", "https://x.com/ab?c", "", "");
        _expectRevert(Factory.BadX.selector, "", "https://x.com/a-b", "", "");
        _expectRevert(Factory.BadX.selector, "", "https://x.com/@abc", "", "");
        _expectRevert(Factory.BadX.selector, "", "javascript:alert(1)", "", "");
        _expectRevert(Factory.BadX.selector, "", "abc", "", "");
    }

    function test_ATelegramLinkIsTheExactPrefixAndFiveToThirtyTwoHandleBytes() public {
        _set("", "", "https://t.me/abcde", "");
        _set("", "", string.concat("https://t.me/", _repeat("_", 32)), "");
        _expectRevert(Factory.BadTelegram.selector, "", "", "https://t.me/abcd", "");
        _expectRevert(Factory.BadTelegram.selector, "", "", string.concat("https://t.me/", _repeat("a", 33)), "");
        _expectRevert(Factory.BadTelegram.selector, "", "", "https://t.me/abcde/f", "");
        _expectRevert(Factory.BadTelegram.selector, "", "", "https://t.me/a/b", "");
        _expectRevert(Factory.BadTelegram.selector, "", "", "http://t.me/abcde", "");
        _expectRevert(Factory.BadTelegram.selector, "", "", "https://t.me.evil/abcde", "");
        _expectRevert(Factory.BadTelegram.selector, "", "", "https://t.me/abc.de", "");
        _expectRevert(Factory.BadTelegram.selector, "", "", "javascript:alert(1)", "");
    }

    function test_AWebsiteIsHttpsAHostAndAtMost100AllowlistedBytes() public {
        _set("", "", "", "https://a");
        _set("", "", "", "https://a-b.example:443/p_a.t~h/?q=1&r=%20#top");
        _set("", "", "", string.concat("https://", _repeat("a", 92)));
        _expectRevert(Factory.BadWebsite.selector, "", "", "", string.concat("https://", _repeat("a", 93)));
        _expectRevert(Factory.BadWebsite.selector, "", "", "", "https://");
        _expectRevert(Factory.BadWebsite.selector, "", "", "", "https:///path");
        _expectRevert(Factory.BadWebsite.selector, "", "", "", "https://?q");
        _expectRevert(Factory.BadWebsite.selector, "", "", "", "https://#f");
        _expectRevert(Factory.BadWebsite.selector, "", "", "", "http://example.com");
        _expectRevert(Factory.BadWebsite.selector, "", "", "", "HTTPS://example.com");
        _expectRevert(Factory.BadWebsite.selector, "", "", "", "javascript:alert(1)");
        _expectRevert(Factory.BadWebsite.selector, "", "", "", "example.com");
    }

    function test_AWebsiteRefusesEveryForbiddenByteClass() public {
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes1[14] memory bad = [bytes1(" "), '"', "'", "<", ">", "\\", "`", "@", "!", "(", bytes1(0x00), bytes1(0x0A), bytes1(0x7F), bytes1(0xC3)];
        for (uint256 i = 0; i < bad.length; i++) {
            _expectRevert(Factory.BadWebsite.selector, "", "", "", string(abi.encodePacked("https://a.example/", bad[i], "b")));
        }
    }

    function testFuzz_EveryByteOutsideTheWebsiteAllowlistIsRefused(uint8 v) public {
        bytes1 ch = bytes1(v);
        bool allowed = (ch >= "0" && ch <= "9") || (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z") || ch == "-" || ch == "." || ch == "_" || ch == "~" || ch == "/" || ch == ":" || ch == "?"
            || ch == "=" || ch == "&" || ch == "%" || ch == "#";
        string memory url = string(abi.encodePacked("https://a.example/", ch));
        if (allowed) {
            _set("", "", "", url);
        } else {
            _expectRevert(Factory.BadWebsite.selector, "", "", "", url);
        }
    }

    /// The gas a full profile adds to `createEtf`, and of an edit.
    function test_gas_AFullProfileAtCreationAndItsEdit() public {
        Factory.Profile memory full =
            _pro(_repeat("a", 280), string.concat("https://x.com/", _repeat("b", 15)), string.concat("https://t.me/", _repeat("c", 32)), string.concat("https://", _repeat("d", 92)));
        Factory.LegSpec[] memory l = _spec(_two(address(a), address(b)), _bps2(5000, 5000));
        vm.prank(maker);
        uint256 g = gasleft();
        factory.createEtf{ value: FEE }("n", "N1", "", l, _params(), _noProfile());
        uint256 bare = g - gasleft();
        vm.prank(maker);
        g = gasleft();
        Etf e = factory.createEtf{ value: FEE }("n", "N2", "", l, _params(), full);
        uint256 withProfile = g - gasleft();
        vm.prank(maker);
        g = gasleft();
        factory.setProfile(address(e), full.description, full.x, full.telegram, full.website);
        uint256 edit = g - gasleft();
        emit log_named_uint("createEtf, no profile, gas", bare);
        emit log_named_uint("createEtf, full profile, gas", withProfile);
        emit log_named_uint("setProfile, full, overwrite, gas", edit);
    }
}

/**
 * The redeem previews count, for the factory's owner and the creator's recipient, the management fee
 * shares the door mints into their `mintOf` before the split. On mocks.
 */
contract MaidMarianEtfV3PreviewTest is EtfV3BisBase {
    /// A year after the last door, the creator's recipient redeems all its shares, the year's fee shares
    /// included: the preview counts them covered (no non-minter penalty), and pays to the unit what
    /// `redeemInKind` pays.
    function test_TheRecipientsPreviewCountsTheFeeSharesItsDoorMints() public {
        (address[] memory t, uint16[] memory w) = _legs3();
        Etf etf = _create("PRV", t, w);
        _mint(etf, alice, 1000e6);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _mint(etf, bob, 10e6);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        (uint256 pendingCreator,) = etf.pendingManagementFee();
        uint256 shares = etf.balanceOf(maker) + pendingCreator;
        assertGt(shares, etf.mintOf(maker), "beyond today's mintOf");
        (,, uint256 penaltyShares, uint256[] memory amounts,) = etf.previewRedeem(maker, shares);
        assertEq(penaltyShares, 0, "all covered at the door");
        (,, uint256 covered,) = etf.exitRates(maker);
        assertEq(covered, shares);
        vm.prank(maker);
        etf.redeemInKind(shares, carol, 0);
        assertEq(a.balanceOf(carol), amounts[0]);
        assertEq(b.balanceOf(carol), amounts[1]);
        assertEq(c.balanceOf(carol), amounts[2]);
    }
}
