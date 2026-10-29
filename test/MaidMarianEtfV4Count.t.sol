// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IUniversalRouter } from "../src/MaidMarianSevenMagnificent.sol";
import { TickMath } from "../src/uniswap/TickMath.sol";
import { MaidMarianEtfV4 as Etf } from "../src/MaidMarianEtfV4.sol";
import { MaidMarianEtfFactory as FactoryV3 } from "../src/MaidMarianEtfFactory.sol";
import { TokenMock, PoolMock, UniversalRouterMock, SenderFeeTokenMock, FeeOnTransferTokenMock } from "./Mocks.sol";
import { EtfV4BisBase } from "./MaidMarianEtfV4Bis.t.sol";

/**
 * The ETF v4's own claims, offline on `test/Mocks.sol`: the fund holds `min(count,
 * balanceOf)` per leg and for its USDG, each door moving the count by what it moved; a donation, before
 * or after creation, is no holding, so it moves no share's price (S2 replayed against the v3 bis on the
 * same mocks); `rescueTokenTo` sends only what is beyond the count, to the address the factory's owner
 * chooses, and never a counted unit; the blocking cases kept (a leg burned from
 * the fund, a fee-on-transfer leg, a hook that reverts on swap); a swap's output above its floor counted
 * whole. The invariant at the end fuzzes every door with donations and rescues in between. Mocks prove
 * the arithmetic; the hooked pools of the chain are `MaidMarianEtfFactoryV4.fork.t.sol`.
 */
contract MaidMarianEtfV4CountTest is EtfV4BisBase {
    address internal mallory = makeAddr("mallory");
    address internal back = makeAddr("back"); // where the owner sends a rescue

    function _three(string memory symbol) internal returns (Etf etf) {
        (address[] memory t, uint16[] memory w) = _legs3();
        etf = _createWith(symbol, t, w, _free());
        _approveLegs(alice, address(etf));
        _approveLegs(bob, address(etf));
        _approveLegs(mallory, address(etf));
        usdg.mint(mallory, 1e12);
    }

    /// No creator fee and no penalty: what a holder gets back is what the formula gives, less the
    /// protocol's 0.10 % at entry.
    function _free() internal pure returns (Etf.Params memory) {
        return Etf.Params({ entryFeeBps: 0, exitFeeBps: 0, holdPeriod: 0, earlyPenaltyBps: 0, nonMinterPenaltyBps: 0, rebalanceBandBps: 200, rebalanceMinInterval: 1 hours });
    }

    function _count(Etf etf, uint256 i) internal view returns (uint256) {
        return uint256(vm.load(address(etf), bytes32(COUNT_SLOT + i)));
    }

    function _usdgCount(Etf etf) internal view returns (uint256) {
        return uint256(vm.load(address(etf), bytes32(USDG_COUNT_SLOT)));
    }

    function _move(PoolMock p, address token, uint256 price18) internal {
        p.setAverageTick(token < address(usdg) ? _tickAt(price18) : -_tickAt(price18));
        _routerAt(token, price18);
    }

    // -------------------------------------------------------------- count ---

    /// The slots the tests read and write are the ETF's counts: after a mint, each leg's slot is its
    /// `legHeld`, and a rebalance that only sells A leaves its exact output in the USDG slot.
    function test_TheCountSlotsAreTheOnesTheTestsWrite() public {
        Etf etf = _three("SLOT");
        _mint(etf, alice, 1000e6);
        for (uint256 i = 0; i < 3; i++) {
            assertGt(_count(etf, i), 0);
            assertEq(_count(etf, i), etf.legHeld(i));
        }
        assertEq(_usdgCount(etf), 0, "a first mint keeps no USDG");
        _move(pa, address(a), 400e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        Etf.PlanLeg[] memory p = etf.plan();
        assertTrue(p[0].sell && p[0].leg == 0);
        Etf.Route[] memory one = new Etf.Route[](1);
        one[0] = _swapRoute(0, true, p[0].amountIn);
        etf.rebalance(one);
        assertEq(_usdgCount(etf), _out(address(a), address(usdg), p[0].amountIn), "the sale's output, counted");
        assertEq(_usdgCount(etf), etf.usdgHeld());
        assertEq(_usdgCount(etf), usdg.balanceOf(address(etf)));
    }

    /// S2 (a first mint followed by a donation) replayed on both factories over the same mocks: mallory first-mints 0.003
    /// USDG, then donates 10 USDG of each leg and 10 USDG. On the v3 bis the share jumps from 1 USDG to
    /// over 10 000; on the v4 the factory's NAV is unmoved to the unit, alice's 1 000 USDG mint gets
    /// 999 shares (one per USDG kept), her in-kind exit returns what her mint kept, and mallory's returns
    /// only what her own mint bought - the donation in neither, still in the fund, rescuable.
    function test_S2_AMinusculeFirstMintAndADonationMoveNoSharesPriceAndTheMinterIsWhole() public {
        FactoryV3 v3bis = new FactoryV3(IERC20(address(usdg)), IUniversalRouter(address(router)), address(v3), owner);
        vm.startPrank(owner);
        v3bis.addToken(address(a), address(pa));
        v3bis.addToken(address(b), address(pb));
        v3bis.addToken(address(c), address(pc));
        vm.stopPrank();
        (address[] memory t, uint16[] memory w) = _legs3();
        vm.prank(maker);
        (bool ok, bytes memory ret) = address(v3bis).call{ value: FEE }(abi.encodeWithSelector(FactoryV3.createEtf.selector, "Maid Marian OLD", "OLD", bytes(""), _spec(t, w), _free(), _noProfile()));
        require(ok, "v3 bis createEtf");
        Etf old = Etf(abi.decode(ret, (address))); // the same ABI, read as the v4's
        Etf etf = _three("NEW");
        vm.prank(mallory);
        usdg.approve(address(old), type(uint256).max);

        Etf[2] memory both = [old, etf];
        uint256[2] memory before;
        uint256[2] memory donated;
        uint256 fair;
        for (uint256 k = 0; k < 2; k++) {
            Etf f = both[k];
            Etf.Route[] memory r = _buyRoutes(f, 3000, true);
            vm.prank(mallory);
            f.mint(3000, r, 1);
            (before[k],) = (k == 0 ? FactoryV3(address(v3bis)).getPriceUsdg(address(f)) : factory.getPriceUsdg(address(f)));
            if (k == 1) {
                uint256 snap = vm.snapshotState();
                fair = _mint(etf, alice, 1000e6);
                vm.revertToState(snap);
            }
            a.mint(address(f), 0.04e18); // 10 USDG at 250
            b.mint(address(f), 0.02e18); // 10 USDG at 500
            c.mint(address(f), 0.08e18); // 10 USDG at 125
            usdg.mint(address(f), 10e6);
            (donated[k],) = (k == 0 ? FactoryV3(address(v3bis)).getPriceUsdg(address(f)) : factory.getPriceUsdg(address(f)));
        }
        console2.log("v3 bis: a share before / after the donation, USDG 18 dec", before[0], donated[0]);
        console2.log("v4:     a share before / after the donation, USDG 18 dec", before[1], donated[1]);
        assertApproxEqRel(before[0], 1e18, ONE_BP);
        assertGt(donated[0], 10_000e18, "the v3 bis: over 10 000 USDG a share");
        assertEq(donated[1], before[1], "the v4: unmoved to the unit");
        assertApproxEqRel(before[1], 1e18, ONE_BP);

        uint256[3] memory heldBefore = [etf.legHeld(0), etf.legHeld(1), etf.legHeld(2)];
        uint256 shares = _mint(etf, alice, 1000e6);
        assertEq(shares, fair, "the shares of the same mint without the donation");
        console2.log("alice's 1 000 USDG mint, shares", shares);
        (uint256 afterMint,) = factory.getPriceUsdg(address(etf));
        assertApproxEqRel(afterMint, before[1], ONE_BP);
        uint256[3] memory kept;
        for (uint256 i = 0; i < 3; i++) {
            kept[i] = etf.legHeld(i) - heldBefore[i];
        }
        TokenMock[3] memory legs = [a, b, c];
        uint256[3] memory refunded = [a.balanceOf(alice), b.balanceOf(alice), c.balanceOf(alice)];
        vm.prank(alice);
        etf.redeemInKind(shares, alice, 0);
        for (uint256 i = 0; i < 3; i++) {
            uint256 got = legs[i].balanceOf(alice) - refunded[i];
            assertLe(got, kept[i], "no more than her mint kept");
            assertApproxEqRel(got, kept[i], 1e9, "and all of it, to 1e-9");
        }
        uint256 mallorys = etf.balanceOf(mallory);
        vm.prank(mallory);
        etf.redeemInKind(mallorys, mallory, 0);
        for (uint256 i = 0; i < 3; i++) {
            assertLe(legs[i].balanceOf(mallory), heldBefore[i], "mallory: only what her mint bought");
        }
        assertEq(etf.rescuable(address(a)), 0.04e18);
        assertEq(etf.rescuable(address(b)), 0.02e18);
        assertEq(etf.rescuable(address(c)), 0.08e18);
        assertEq(etf.rescuable(address(usdg)), 10e6);
    }

    // ------------------------------------------------------------- rescue ---

    /// The owner sends a donation of a leg, of USDG, a token sent by mistake and the ETF's own shares
    /// sent to it, each to the address he chooses, each with its event; every count and every holding
    /// unchanged, nothing left to rescue after (`NothingToRescue`).
    function test_ARescueReturnsADonationAndATokenSentByMistakeToTheAddressTheOwnerChooses() public {
        Etf etf = _three("RSC");
        _mint(etf, alice, 1000e6);
        _mint(etf, bob, 500e6);
        TokenMock stray = new TokenMock("ZZZ", "ZZZ", 18);
        a.mint(address(etf), 1e18);
        usdg.mint(address(etf), 7e6);
        stray.mint(address(etf), 5e18);
        vm.prank(alice);
        assertTrue(etf.transfer(address(etf), 3e18));
        uint256[3] memory held = [etf.legHeld(0), etf.legHeld(1), etf.legHeld(2)];
        uint256 supply = etf.totalSupply();
        assertEq(etf.rescuable(address(a)), 1e18);
        assertEq(etf.rescuable(address(b)), 0, "no donation of b");
        assertEq(etf.rescuable(address(usdg)), 7e6);
        assertEq(etf.rescuable(address(stray)), 5e18, "a token the fund does not count: all of it");
        assertEq(etf.rescuable(address(etf)), 3e18);

        address[4] memory tokens = [address(a), address(usdg), address(stray), address(etf)];
        uint256[4] memory amounts = [uint256(1e18), 7e6, 5e18, 3e18];
        for (uint256 k = 0; k < 4; k++) {
            vm.expectEmit(true, true, false, true, address(etf));
            emit Etf.Rescued(tokens[k], back, amounts[k]);
            vm.prank(owner);
            assertEq(etf.rescueTokenTo(tokens[k], back), amounts[k]);
            assertEq(IERC20(tokens[k]).balanceOf(back), amounts[k]);
            assertEq(etf.rescuable(tokens[k]), 0);
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(Etf.NothingToRescue.selector, tokens[k]));
            etf.rescueTokenTo(tokens[k], back);
        }
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Etf.NothingToRescue.selector, address(b)));
        etf.rescueTokenTo(address(b), back);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(etf.legHeld(i), held[i], "no counted unit moved");
            assertEq(_count(etf, i), held[i]);
        }
        assertEq(etf.usdgHeld(), 0);
        assertEq(etf.totalSupply(), supply, "the shares moved, none burned");
    }

    /// Only the factory's `owner()`: not a holder, not the ETF's creator, not the old owner once
    /// ownership moved (the new one can); never to the zero address.
    function test_OnlyTheFactorysOwnerRescues() public {
        Etf etf = _three("OWN");
        _mint(etf, alice, 1000e6);
        a.mint(address(etf), 1e18);
        address[3] memory others = [alice, maker, bob];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(others[i]);
            vm.expectRevert(Etf.NotFactoryOwner.selector);
            etf.rescueTokenTo(address(a), others[i]);
        }
        vm.prank(owner);
        vm.expectRevert(Etf.ZeroAddress.selector);
        etf.rescueTokenTo(address(a), address(0));
        address next = makeAddr("next owner");
        vm.prank(owner);
        factory.transferOwnership(next);
        vm.prank(owner);
        vm.expectRevert(Etf.NotFactoryOwner.selector);
        etf.rescueTokenTo(address(a), owner);
        vm.prank(next);
        etf.rescueTokenTo(address(a), back);
        assertEq(a.balanceOf(back), 1e18);
        Etf implementation = factory.ETF_IMPLEMENTATION();
        vm.prank(next);
        vm.expectRevert(Etf.NotAClone.selector);
        implementation.rescueTokenTo(address(a), back);
    }

    /// A leg whose `transfer` takes a fee from the sender: a rescue of its donation would take the fee
    /// from counted units, so it reverts (`RescueTookCounted`) and the count stands.
    function test_ARescueThatWouldTakeACountedUnitReverts() public {
        SenderFeeTokenMock f = new SenderFeeTokenMock("SFEE", "SFEE", 18);
        f.mint(address(router), 1e30);
        PoolMock pf = _pool(address(f), _tickAt(100e18));
        vm.prank(owner);
        factory.addToken(address(f), address(pf));
        _routerAt(address(f), 100e18);
        Etf etf = _createWith("SFE", _two(address(a), address(f)), _bps2(5000, 5000), _free());
        _mint(etf, alice, 1000e6);
        uint256 held = etf.legHeld(1);
        f.mint(address(etf), 1e18);
        assertEq(etf.rescuable(address(f)), 1e18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Etf.RescueTookCounted.selector, address(f)));
        etf.rescueTokenTo(address(f), back);
        assertEq(etf.legHeld(1), held);
    }

    // ----------------------------------------------------- blocking cases ---

    /// Case 2: half of leg A burned from the fund (an issuer's burn, a wipe). The holding is the balance
    /// at once, both holders leave in kind pro rata of what is there, the last one too, with `allowFail`
    /// 0; the count follows the balance down and a new mint runs on it.
    function test_ALegBurnedFromTheFundLowersItsCountAndTheLastHolderStillLeaves() public {
        Etf etf = _three("BRN");
        _mint(etf, alice, 1000e6);
        _mint(etf, bob, 500e6);
        uint256 balance = a.balanceOf(address(etf));
        deal(address(a), address(etf), balance / 2);
        assertEq(etf.legHeld(0), balance / 2, "the holding is the balance");
        assertEq(_count(etf, 0), balance, "the count is not, until a door");
        uint256 supply = etf.totalSupply();
        uint256 aliceShares = etf.balanceOf(alice);
        vm.prank(alice);
        etf.redeemInKind(aliceShares, alice, 0);
        assertEq(a.balanceOf(alice), Math.mulDiv(balance / 2, aliceShares, supply));
        assertEq(_count(etf, 0), a.balanceOf(address(etf)), "the door wrote the count down");
        uint256 bobShares = etf.balanceOf(bob);
        vm.prank(bob);
        etf.redeemInKind(bobShares, bob, 0);
        assertGt(a.balanceOf(bob), 0);
        assertEq(_count(etf, 0), a.balanceOf(address(etf)));
        assertEq(etf.totalSupply(), etf.DEAD_SHARES());
        assertGt(_mint(etf, alice, 100e6), 0, "a later mint runs");
    }

    /// Case 9: a leg that burns a tenth of what is sent to it by `transferFrom`. A `mintInKind` counts
    /// what arrived, not what was sent; count and balance stay equal, nothing to rescue.
    function test_AFeeOnTransferLegIsCountedAsWhatArrived() public {
        FeeOnTransferTokenMock f = new FeeOnTransferTokenMock("FOT", "FOT", 18);
        f.mint(address(router), 1e30);
        PoolMock pf = _pool(address(f), _tickAt(100e18));
        vm.prank(owner);
        factory.addToken(address(f), address(pf));
        _routerAt(address(f), 100e18);
        Etf etf = _createWith("FOT", _two(address(a), address(f)), _bps2(5000, 5000), _free());
        _mint(etf, alice, 1000e6);
        (uint256[] memory need,) = etf.quoteMint(100e18);
        uint256[] memory bring = new uint256[](2);
        (bring[0], bring[1]) = (need[0], need[1] * 10 / 9 + 10);
        a.mint(bob, bring[0]);
        f.mint(bob, bring[1]);
        vm.startPrank(bob);
        a.approve(address(etf), type(uint256).max);
        f.approve(address(etf), type(uint256).max);
        uint256 before = etf.legHeld(1);
        etf.mintInKind(bring, 0, 1);
        vm.stopPrank();
        assertLe(etf.legHeld(1) - before, bring[1] - bring[1] / 10, "at most what arrived");
        assertEq(_count(etf, 1), f.balanceOf(address(etf)), "the count is what the fund holds");
        assertEq(etf.rescuable(address(f)), 0);
    }

    /// Case 6: c's V4 pool carries a hook. Its route mints and redeems through it, the hook in the key;
    /// once the hook refuses every swap, a V4 route reverts and nothing else does: the same mint and
    /// the same redeem through c's V3 pool run, the in-kind exit runs, and the owner clears the V4 pool.
    function test_AHookThatRevertsBlocksOnlyItsV4RouteAndTheHolderLeaves() public {
        address hook = makeAddr("hook");
        _v4PoolHooked(address(c), 500, 10, hook);
        Etf etf = _three("HOK");
        Etf.Route[] memory r = _buyRoutes(etf, 1000e6, true);
        r[2].v4 = true;
        vm.prank(alice);
        etf.mint(1000e6, r, 1);
        assertEq(router.lastHooks(), hook, "the first mint bought c through the hooked pool");
        uint256 cBefore = c.balanceOf(alice);
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(alice, 10e18);
        Etf.Route[] memory sell = _sellRoutes(etf, due);
        sell[2].v4 = true;
        vm.prank(alice);
        etf.redeem(10e18, sell, 1, alice);
        assertEq(c.balanceOf(alice), cBefore, "c sold through the hooked pool, none paid in kind");

        router.setRevertingHooks(hook);
        r = _buyRoutes(etf, 100e6, false);
        r[2].v4 = true;
        vm.prank(bob);
        vm.expectRevert("mock: the hook reverts");
        etf.mint(100e6, r, 1);
        r[2].v4 = false;
        vm.prank(bob);
        assertGt(etf.mint(100e6, r, 1), 0, "the same mint through c's V3 pool");
        (due,,,) = etf.previewRedeemToUsdg(alice, 10e18);
        sell = _sellRoutes(etf, due);
        sell[2].v4 = true;
        vm.prank(alice);
        vm.expectRevert("mock: the hook reverts");
        etf.redeem(10e18, sell, 1, alice);
        sell[2].v4 = false;
        vm.prank(alice);
        assertGt(etf.redeem(10e18, sell, 1, alice), 0, "the same redeem through c's V3 pool");
        uint256 rest = etf.balanceOf(alice);
        vm.prank(alice);
        etf.redeemInKind(rest, alice, 0);
        assertEq(etf.balanceOf(alice), 0, "and the in-kind exit");

        vm.prank(owner);
        factory.setTokenV4Pool(address(c), 0, 0, address(0));
        r = _buyRoutes(etf, 100e6, false);
        r[2].v4 = true;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Etf.NoV4Pool.selector, address(c)));
        etf.mint(100e6, r, 1);
    }

    // -------------------------------------------------------------- swaps ---

    /// A rebalance sale the router fills 4 % above the price it was planned at: the whole output is
    /// counted, none of it left as a surplus. A router that sends another token during a mint's swap
    /// sends a donation: never counted, rescuable.
    function test_ASwapOutputAboveItsFloorIsTheFundsAndARoutersGiftIsADonation() public {
        Etf etf = _three("OUT");
        _mint(etf, alice, 1000e6);
        _credit(etf, address(a), 1e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        Etf.PlanLeg[] memory p = etf.plan();
        assertTrue(p[0].sell && p[0].leg == 0);
        router.setPairRate(address(a), address(usdg), 260e6); // 260 USDG a token, the TWAP 250
        Etf.Route[] memory one = new Etf.Route[](1);
        one[0] = _swapRoute(0, true, p[0].amountIn);
        etf.rebalance(one);
        uint256 out = p[0].amountIn * 260e6 / 1e18;
        assertGt(out, p[0].minOut * 104 / 100, "4 % above the floor's price");
        assertEq(etf.usdgHeld(), out, "all of it counted");
        assertEq(etf.rescuable(address(usdg)), 0);

        router.setGift(address(b), 1e18);
        _mint(etf, bob, 100e6);
        assertEq(etf.rescuable(address(b)), 1e18, "the gift is no holding");
        assertEq(_count(etf, 1) + 1e18, b.balanceOf(address(etf)));
    }
}

/// Drives every door of one three-leg v4 ETF with fuzzed sizes, and between them donations, price moves,
/// share transfers, time and the owner's rescues; keeps what was donated and not rescued per token.
contract EtfV4Handler is Test {
    Etf internal immutable ETF;
    TokenMock internal immutable USDG;
    UniversalRouterMock internal immutable ROUTER;
    address internal immutable OWNER;
    TokenMock[3] internal legs;
    PoolMock[3] internal pools;
    TokenMock internal immutable STRAY;
    address[3] internal actors;

    /// Donated and not rescued, per token (the ETF's own shares included).
    mapping(address token => uint256) public donated;
    /// Set if a rescue ever moved a count or left a balance under it.
    bool public rescueTookCounted;
    mapping(bytes32 door => uint256) public calls;

    constructor(Etf etf, TokenMock usdg, UniversalRouterMock router, address owner, TokenMock[3] memory legs_, PoolMock[3] memory pools_, address[3] memory actors_) {
        (ETF, USDG, ROUTER, OWNER) = (etf, usdg, router, owner);
        legs = legs_;
        pools = pools_;
        actors = actors_;
        STRAY = new TokenMock("ZZZ", "ZZZ", 18);
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(actors[i]);
            usdg.approve(address(etf), type(uint256).max);
            for (uint256 j = 0; j < 3; j++) {
                legs[j].approve(address(etf), type(uint256).max);
            }
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function _routes(uint256[] memory amounts, bool sell) internal view returns (Etf.Route[] memory r) {
        r = new Etf.Route[](3);
        for (uint256 i = 0; i < 3; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            r[i] = Etf.Route({ leg: uint8(i), sell: sell, v4: false, amountIn: amounts[i], amountOutMin: 0, deadline: block.timestamp + 60 });
        }
    }

    function mint(uint256 seed, uint256 amount) external {
        amount = bound(amount, 1e6, 20_000e6);
        address who = _actor(seed);
        USDG.mint(who, amount);
        uint256[] memory split = new uint256[](3);
        if (ETF.totalSupply() == 0) {
            split = ETF.firstMintSplit(amount);
        } else {
            uint256 spend = amount - amount / 50 - (seed % 2 == 0 ? 0 : amount / 10);
            (split[0], split[1], split[2]) = (spend / 2, spend * 3 / 10, spend - spend / 2 - spend * 3 / 10);
        }
        vm.prank(who);
        try ETF.mint(amount, _routes(split, false), 1) {
            calls[keccak256("mint")]++;
        } catch { }
    }

    function mintInKind(uint256 seed, uint256 gross) external {
        if (ETF.totalSupply() == 0) return;
        gross = bound(gross, 1e15, 5_000e18);
        address who = _actor(seed);
        (uint256[] memory need, uint256 usdgNeed) = ETF.quoteMint(gross);
        for (uint256 i = 0; i < 3; i++) {
            need[i] += need[i] * (seed % 7) / 100; // up to 6 % more than needed, refunded
            legs[i].mint(who, need[i]);
        }
        USDG.mint(who, usdgNeed);
        vm.prank(who);
        try ETF.mintInKind(need, usdgNeed, 1) {
            calls[keccak256("mintInKind")]++;
        } catch { }
    }

    function redeem(uint256 seed, uint256 bps, uint256 sellBps) external {
        address who = _actor(seed);
        uint256 shares = ETF.balanceOf(who) * bound(bps, 1, 10_000) / 10_000;
        if (shares == 0) return;
        (uint256[] memory due,,,) = ETF.previewRedeemToUsdg(who, shares);
        sellBps = bound(sellBps, 0, 10_000);
        for (uint256 i = 0; i < 3; i++) {
            due[i] = due[i] * sellBps / 10_000;
        }
        vm.prank(who);
        try ETF.redeem(shares, _routes(due, true), 0, who) {
            calls[keccak256("redeem")]++;
        } catch { }
    }

    function redeemInKind(uint256 seed, uint256 bps) external {
        address who = _actor(seed);
        uint256 shares = ETF.balanceOf(who) * bound(bps, 1, 10_000) / 10_000;
        if (shares == 0) return;
        vm.prank(who);
        try ETF.redeemInKind(shares, who, 0) {
            calls[keccak256("redeemInKind")]++;
        } catch { }
    }

    /// One leg's price moved by -30 % to +30 % at its pool and its router, an hour later the plan run.
    function rebalance(uint256 seed, uint256 moveBps) external {
        uint256 i = seed % 3;
        uint256[3] memory base = [uint256(250e18), 500e18, 125e18];
        uint256 price = base[i] * bound(moveBps, 7000, 13_000) / 10_000;
        address token = address(legs[i]);
        pools[i].setAverageTick(token < address(USDG) ? _tickAt(price) : -_tickAt(price));
        ROUTER.setPairRate(address(USDG), token, 1e48 / price);
        ROUTER.setPairRate(token, address(USDG), price / 1e12);
        vm.warp(block.timestamp + 1 hours);
        Etf.PlanLeg[] memory p = ETF.plan();
        Etf.Route[] memory r = new Etf.Route[](p.length);
        for (uint256 k = 0; k < p.length; k++) {
            r[k] = Etf.Route({ leg: p[k].leg, sell: p[k].sell, v4: false, amountIn: p[k].amountIn, amountOutMin: 0, deadline: block.timestamp + 60 });
        }
        try ETF.rebalance(r) {
            calls[keccak256("rebalance")]++;
        } catch { }
    }

    function _tickAt(uint256 price18) internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(Math.mulDiv(price18, 1 << 192, 1e30))));
    }

    /// A leg, USDG, a token the fund does not count, or shares sent to the ETF.
    function donate(uint256 seed, uint256 amount) external {
        uint256 k = seed % 5;
        amount = bound(amount, 1, 1e21);
        address token;
        if (k < 3) {
            token = address(legs[k]);
            legs[k].mint(address(ETF), amount);
        } else if (k == 3) {
            token = address(USDG);
            amount = amount % 1e10 + 1;
            USDG.mint(address(ETF), amount);
        } else {
            token = address(STRAY);
            STRAY.mint(address(ETF), amount);
        }
        donated[token] += amount;
        calls[keccak256("donate")]++;
    }

    function giveShares(uint256 seed, uint256 bps) external {
        address who = _actor(seed);
        uint256 shares = ETF.balanceOf(who) * bound(bps, 1, 10_000) / 10_000;
        if (shares == 0) return;
        vm.prank(who);
        require(ETF.transfer(address(ETF), shares), "transfer");
        donated[address(ETF)] += shares;
        calls[keccak256("giveShares")]++;
    }

    function transferShares(uint256 seed, uint256 bps) external {
        address from = _actor(seed);
        address to = _actor(seed / 3 + 1);
        uint256 shares = ETF.balanceOf(from) * bound(bps, 1, 10_000) / 10_000;
        if (shares == 0 || from == to) return;
        vm.prank(from);
        require(ETF.transfer(to, shares), "transfer");
    }

    function rescue(uint256 seed) external {
        uint256 k = seed % 6;
        address token = k < 3 ? address(legs[k]) : k == 3 ? address(USDG) : k == 4 ? address(STRAY) : address(ETF);
        uint256[4] memory before = _counts();
        vm.prank(OWNER);
        try ETF.rescueTokenTo(token, makeAddr("back")) returns (uint256 amount) {
            donated[token] -= amount;
            calls[keccak256("rescue")]++;
        } catch { }
        uint256[4] memory afterRescue = _counts();
        for (uint256 i = 0; i < 4; i++) {
            if (afterRescue[i] != before[i]) rescueTookCounted = true;
        }
        if (k < 3 && legs[k].balanceOf(address(ETF)) < afterRescue[k]) rescueTookCounted = true;
        if (k == 3 && USDG.balanceOf(address(ETF)) < afterRescue[3]) rescueTookCounted = true;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 30 days));
    }

    /// The three leg counts and the USDG count, read from the ETF's storage.
    function _counts() internal view returns (uint256[4] memory c) {
        for (uint256 i = 0; i < 3; i++) {
            c[i] = uint256(vm.load(address(ETF), bytes32(uint256(15 + i))));
        }
        c[3] = uint256(vm.load(address(ETF), bytes32(uint256(25))));
    }

    function stray() external view returns (address) {
        return address(STRAY);
    }
}

/**
 * The invariant: whatever sequence of mints, mints in kind, redeems to USDG and in kind, rebalances,
 * donations, share transfers, time and rescues, each count is what the ETF really holds less what was
 * donated and not rescued - for each leg and for the USDG -, the holding the doors read is that count,
 * and a rescue never moves a count. Runs and depth set below (a run is one fresh ETF and that many
 * calls); the calls each door made are logged after every run.
 */
contract MaidMarianEtfV4InvariantTest is EtfV4BisBase {
    EtfV4Handler internal handler;
    Etf internal etf;

    function setUp() public override {
        super.setUp();
        (address[] memory t, uint16[] memory w) = _legs3();
        etf = _createWith("INV", t, w, _params());
        handler = new EtfV4Handler(etf, usdg, router, owner, [a, b, c], [pa, pb, pc], [alice, bob, carol]);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 128
    function invariant_EachCountIsWhatTheEtfHoldsLessDonations() public view {
        TokenMock[3] memory legs = [a, b, c];
        for (uint256 i = 0; i < 3; i++) {
            uint256 count = uint256(vm.load(address(etf), bytes32(COUNT_SLOT + i)));
            assertEq(count, legs[i].balanceOf(address(etf)) - handler.donated(address(legs[i])), "a leg's count");
            assertEq(etf.legHeld(i), count, "the holding is the count");
            assertEq(etf.rescuable(address(legs[i])), handler.donated(address(legs[i])), "rescuable: the donations only");
        }
        uint256 usdgCount = uint256(vm.load(address(etf), bytes32(USDG_COUNT_SLOT)));
        assertEq(usdgCount, usdg.balanceOf(address(etf)) - handler.donated(address(usdg)), "the USDG count");
        assertEq(etf.usdgHeld(), usdgCount);
        assertEq(etf.rescuable(handler.stray()), handler.donated(handler.stray()));
        assertEq(etf.rescuable(address(etf)), handler.donated(address(etf)), "shares sent to the ETF");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 128
    function invariant_ARescueNeverTakesACountedUnit() public view {
        assertFalse(handler.rescueTookCounted());
    }

    function afterInvariant() external view {
        string[8] memory doors = ["mint", "mintInKind", "redeem", "redeemInKind", "rebalance", "donate", "giveShares", "rescue"];
        for (uint256 i = 0; i < doors.length; i++) {
            console2.log(doors[i], handler.calls(keccak256(bytes(doors[i]))));
        }
    }
}
