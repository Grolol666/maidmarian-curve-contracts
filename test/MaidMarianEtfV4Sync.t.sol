// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniversalRouter } from "../src/MaidMarianSevenMagnificent.sol";
import { MaidMarianEtfFactoryV4 as Factory } from "../src/MaidMarianEtfFactoryV4.sol";
import { MaidMarianEtfV4 as Etf } from "../src/MaidMarianEtfV4.sol";
import { EtfV4BisBase } from "./MaidMarianEtfV4Bis.t.sol";

/**
 * The v4 factory's one-approve doors (`mint`, `mintInKind`) and the two refusals of
 * the security review (a payout or a fee recipient aimed at the ETF itself), offline on the v4 suite's
 * mocks and the real factory and ETF code. Twin ETFs of one factory (same legs, same parameters, same first
 * mint) take the same call, one directly and one through the factory, and are compared whole: what the call
 * returns, every wallet's move, the fund, `mintOf` and `lastMintAt`. Proves the factory's and the ETF's side
 * on mocks; that the deployed ones agree is `MaidMarianEtfFactoryV4.fork.t.sol`.
 *
 *   forge test --match-contract MaidMarianEtfV4Sync -vv
 */
contract MaidMarianEtfV4SyncTest is EtfV4BisBase {
    Etf internal direct; // minted on by its minters
    Etf internal viaFactory; // minted on through the factory

    function setUp() public override {
        super.setUp();
        Etf.Params memory p = Etf.Params({ entryFeeBps: 50, exitFeeBps: 30, holdPeriod: 1 days, earlyPenaltyBps: 100, nonMinterPenaltyBps: 200, rebalanceBandBps: 200, rebalanceMinInterval: 1 hours });
        (address[] memory t, uint16[] memory w) = _legs3();
        direct = _createWith("DIR", t, w, p);
        viaFactory = _createWith("VIA", t, w, p);
        _mint(direct, maker, 1000e6);
        _mint(viaFactory, maker, 1000e6);
        for (uint256 i = 0; i < 3; i++) {
            address who = i == 0 ? alice : i == 1 ? bob : carol;
            _approveLegs(who, address(direct));
            _approveLegs(who, address(factory));
            usdg.mint(who, 1e12);
        }
    }

    // ----------------------------------------------------------- helpers ---

    function _actors() internal view returns (address[6] memory) {
        return [alice, bob, carol, maker, owner, address(factory)];
    }

    /// Every actor's USDG, AAA, BBB, CCC and shares of both ETFs.
    function _wallets() internal view returns (uint256[] memory w) {
        address[6] memory who = _actors();
        w = new uint256[](36);
        for (uint256 i = 0; i < 6; i++) {
            w[6 * i] = usdg.balanceOf(who[i]);
            w[6 * i + 1] = a.balanceOf(who[i]);
            w[6 * i + 2] = b.balanceOf(who[i]);
            w[6 * i + 3] = c.balanceOf(who[i]);
            w[6 * i + 4] = direct.balanceOf(who[i]);
            w[6 * i + 5] = viaFactory.balanceOf(who[i]);
        }
    }

    /// A fund's supply, holdings, counts, every actor's `mintOf` and `lastMintAt`, and its clocks.
    function _state(Etf f) internal view returns (bytes memory s) {
        s = abi.encode(f.totalSupply(), usdg.balanceOf(address(f)), a.balanceOf(address(f)), b.balanceOf(address(f)), c.balanceOf(address(f)), f.lastRebalanceAt(), f.lastAccrualAt());
        s = abi.encodePacked(s, abi.encode(f.usdgHeld(), f.legHeld(0), f.legHeld(1), f.legHeld(2)));
        address[6] memory who = _actors();
        for (uint256 i = 0; i < 5; i++) {
            s = abi.encodePacked(s, abi.encode(f.balanceOf(who[i]), f.mintOf(who[i]), f.lastMintAt(who[i])));
        }
    }

    /// The same moves in the wallets and the same funds after: `first` ran on `direct`, `second` on `viaFactory`.
    function _assertSameMove(uint256[] memory w0, uint256[] memory w1, uint256[] memory w2) internal view {
        for (uint256 k = 0; k < w0.length; k++) {
            // The shares columns (4, 5 of each actor) are one ETF's each: compare a column to the other's.
            uint256 col = k % 6;
            if (col == 4 || col == 5) {
                uint256 twin = col == 4 ? k + 1 : k - 1;
                // forge-lint: disable-next-line(unsafe-typecast)
                assertEq(int256(w1[k]) - int256(w0[k]), int256(w2[twin]) - int256(w1[twin]), "the same shares move");
            } else {
                // forge-lint: disable-next-line(unsafe-typecast)
                assertEq(int256(w1[k]) - int256(w0[k]), int256(w2[k]) - int256(w1[k]), "the same wallet move");
            }
        }
        assertEq(_state(direct), _state(viaFactory), "the same fund after");
    }

    /// Routes that spend 99 % of `amount` on legs 0, 1, 2 at 60 / 25 / 15 %, off the fund's 50 / 30 / 20: the
    /// ETF keeps what matches its mix and refunds the rest of leg 0, so a mint has leg refunds and USDG back.
    function _skewRoutes(uint256 amount) internal view returns (Etf.Route[] memory r) {
        uint256 spend = amount - amount / 100;
        r = new Etf.Route[](3);
        r[0] = _swapRoute(0, false, spend * 60 / 100);
        r[1] = _swapRoute(1, false, spend * 25 / 100);
        r[2] = _swapRoute(2, false, spend - spend * 60 / 100 - spend * 25 / 100);
    }

    function _mintDirect(address who, uint256 usdgIn, Etf.Route[] memory r) internal returns (uint256 shares) {
        vm.prank(who);
        shares = direct.mint(usdgIn, r, 1);
    }

    function _mintVia(address who, uint256 usdgIn, Etf.Route[] memory r) internal returns (uint256 shares) {
        vm.prank(who);
        shares = factory.mint(address(viaFactory), usdgIn, r, 1);
    }

    function _heldByTheFactory() internal view returns (uint256 total) {
        total = usdg.balanceOf(address(factory)) + a.balanceOf(address(factory)) + b.balanceOf(address(factory)) + c.balanceOf(address(factory)) + direct.balanceOf(address(factory))
            + viaFactory.balanceOf(address(factory));
    }

    // -------------------------------------------------------------- mint ---

    /// A mint through the factory is a mint on the ETF by its caller: the same shares and refunds, the same
    /// fees, `mintOf` and clock of the caller on the ETF, and the factory holds nothing after.
    function test_AMintThroughTheFactoryIsTheCallersOwnMintOnTheEtf() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        Etf.Route[] memory r = _skewRoutes(500e6);
        uint256[] memory w0 = _wallets();
        uint256 s1 = _mintDirect(alice, 500e6, r);
        uint256[] memory w1 = _wallets();
        uint256 s2 = _mintVia(alice, 500e6, r);
        uint256[] memory w2 = _wallets();
        assertEq(s1, s2, "the same shares");
        assertGt(s1, 0);
        _assertSameMove(w0, w1, w2);
        assertEq(viaFactory.mintOf(alice), direct.mintOf(alice), "his mintOf");
        assertEq(viaFactory.mintOf(alice), s2);
        assertEq(viaFactory.lastMintAt(alice), direct.lastMintAt(alice), "his clock");
        assertEq(viaFactory.lastMintAt(alice), vm.getBlockTimestamp());
        assertEq(viaFactory.mintOf(address(factory)), 0, "the factory is no minter");
        assertEq(viaFactory.lastMintAt(address(factory)), 0);
        assertGt(a.balanceOf(alice), 0, "leg refunds came to him");
        assertEq(_heldByTheFactory(), 0, "the factory holds nothing");
        assertEq(usdg.allowance(address(factory), address(viaFactory)), 0, "and approved nothing left");
    }

    /// The first mint of an ETF goes through the factory too, at the exact split: the same shares and the
    /// minter's `mintOf`, `DEAD_SHARES` locked as on a direct first mint.
    function test_TheFirstMintOfAnEtfCanGoThroughTheFactory() public {
        (address[] memory t, uint16[] memory w) = _legs3();
        Etf.Params memory p = Etf.Params({ entryFeeBps: 50, exitFeeBps: 30, holdPeriod: 1 days, earlyPenaltyBps: 100, nonMinterPenaltyBps: 200, rebalanceBandBps: 200, rebalanceMinInterval: 1 hours });
        Etf one = _createWith("ONE", t, w, p);
        Etf two = _createWith("TWO", t, w, p);
        Etf.Route[] memory r = _buyRoutes(one, 1000e6, true);
        vm.prank(alice);
        uint256 s1 = one.mint(1000e6, r, 1);
        vm.prank(alice);
        uint256 s2 = factory.mint(address(two), 1000e6, r, 1);
        assertEq(s1, s2);
        assertEq(two.mintOf(alice), one.mintOf(alice));
        assertEq(two.totalSupply(), one.totalSupply());
        assertEq(two.balanceOf(factory.owner()), one.balanceOf(factory.owner()));
        assertEq(two.balanceOf(address(factory)), 0);
    }

    /// The caller's allowance to the factory is spent for the caller only. A stranger with no USDG cannot
    /// reach a holder's approve to the factory, whoever he is and whatever he asks for; a stranger with funds
    /// of his own mints for himself and leaves the holder's balance and allowance exactly as they were.
    function testFuzz_AMintSpendsOnlyTheCallersAllowance(address stranger, uint256 amount) public {
        vm.assume(stranger != address(0) && stranger.code.length == 0 && stranger != bob && stranger != address(factory) && stranger != address(vm));
        vm.assume(stranger != alice && stranger != carol && stranger != maker && stranger != owner && stranger != makeAddr("pools") && stranger != address(0xdEaD));
        assertEq(viaFactory.balanceOf(stranger) + a.balanceOf(stranger) + b.balanceOf(stranger) + c.balanceOf(stranger) + usdg.balanceOf(stranger), 0, "a stranger starts with nothing");
        amount = bound(amount, 1e6, 500e6);
        vm.prank(bob);
        usdg.approve(address(factory), type(uint256).max);
        uint256 bobUsdg = usdg.balanceOf(bob);
        Etf.Route[] memory r = _skewRoutes(amount);

        vm.prank(stranger);
        vm.expectRevert();
        factory.mint(address(viaFactory), amount, r, 1);
        assertEq(usdg.balanceOf(bob), bobUsdg, "bob untouched by a stranger without funds");
        assertEq(usdg.allowance(bob, address(factory)), type(uint256).max);

        usdg.mint(stranger, amount);
        vm.startPrank(stranger);
        usdg.approve(address(factory), amount);
        uint256 shares = factory.mint(address(viaFactory), amount, r, 1);
        vm.stopPrank();
        assertEq(usdg.balanceOf(bob), bobUsdg, "bob untouched by a stranger with funds");
        assertEq(usdg.allowance(bob, address(factory)), type(uint256).max);
        assertEq(viaFactory.balanceOf(stranger), shares);
        assertEq(viaFactory.mintOf(stranger), shares);
        assertEq(_heldByTheFactory(), 0);
    }

    /// Whatever a mint is (any size, any skew of the routes, left USDG or not), the factory ends it holding
    /// nothing and the caller owns every share and refund.
    function testFuzz_TheFactoryEndsEveryMintHoldingNothing(uint256 amount, uint256 skew) public {
        amount = bound(amount, 10e6, 5000e6);
        skew = bound(skew, 0, 50);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 spend = (amount - amount / 100) * (100 - skew) / 100;
        Etf.Route[] memory r = new Etf.Route[](3);
        r[0] = _swapRoute(0, false, spend * 50 / 100);
        r[1] = _swapRoute(1, false, spend * 30 / 100);
        r[2] = _swapRoute(2, false, spend * 20 / 100);
        uint256 supply0 = viaFactory.totalSupply();
        vm.prank(alice);
        uint256 shares = factory.mint(address(viaFactory), amount, r, 0);
        assertEq(_heldByTheFactory(), 0);
        assertEq(viaFactory.balanceOf(alice), shares);
        assertGt(viaFactory.totalSupply(), supply0);
    }

    /// Only an ETF this factory made. A stranger's address, a token, an ETF of another factory and the
    /// factory itself are refused by name, before any pull.
    function test_OnlyAnEtfOfTheFactoryCanBeMintedOn() public {
        Etf.Route[] memory r = _skewRoutes(100e6);
        Factory other = new Factory(IERC20(address(usdg)), IUniversalRouter(address(router)), address(v3), owner);
        vm.startPrank(owner);
        other.addToken(address(a), address(pa));
        other.addToken(address(b), address(pb));
        other.addToken(address(c), address(pc));
        vm.stopPrank();
        (address[] memory t, uint16[] memory w) = _legs3();
        vm.prank(maker);
        Etf foreign = other.createEtf{ value: FEE }("Maid Marian FOR", "FOR", "", _spec(t, w), _params(), _noProfile());
        address[5] memory bad = [makeAddr("stranger"), address(usdg), address(a), address(foreign), address(factory)];
        for (uint256 i = 0; i < bad.length; i++) {
            uint256 usdgBefore = usdg.balanceOf(alice);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(Factory.NotFactoryEtf.selector, bad[i]));
            factory.mint(bad[i], 100e6, r, 1);
            uint256[] memory amounts = new uint256[](3);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(Factory.NotFactoryEtf.selector, bad[i]));
            factory.mintInKind(bad[i], amounts, 0, 1);
            assertEq(usdg.balanceOf(alice), usdgBefore);
        }
    }

    /// `mintFor` and `mintInKindFor` answer the factory alone: not the owner, the creator, a holder, a
    /// stranger, nor the ETF.
    function testFuzz_OnlyTheFactoryCanMintForSomeone(address caller) public {
        vm.assume(caller != address(factory));
        Etf.Route[] memory r = _skewRoutes(100e6);
        uint256[] memory amounts = new uint256[](3);
        vm.startPrank(caller);
        vm.expectRevert(Etf.NotFactory.selector);
        viaFactory.mintFor(alice, 100e6, r, 1);
        vm.expectRevert(Etf.NotFactory.selector);
        viaFactory.mintInKindFor(alice, amounts, 0, 1);
        vm.stopPrank();
    }

    /// `minShares` binds a mint through the factory as on the ETF, and the revert takes the pull with it.
    function test_MinSharesBindsAMintThroughTheFactory() public {
        Etf.Route[] memory r = _skewRoutes(100e6);
        uint256 usdgBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        factory.mint(address(viaFactory), 100e6, r, type(uint256).max);
        assertEq(usdg.balanceOf(alice), usdgBefore);
        assertEq(_heldByTheFactory(), 0);
    }

    // ------------------------------------------------------- mint in kind ---

    /// `mintInKind` through the factory is the caller's own on the ETF, as `mint` is: the same shares (the
    /// entry fee in shares), refunds of the legs he brought too much of, `mintOf` and clock; nothing left in
    /// the factory.
    function test_AMintInKindThroughTheFactoryIsTheCallersOwnMintInKindOnTheEtf() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        (uint256[] memory need,) = direct.quoteMint(50e18);
        uint256[] memory bring = new uint256[](3);
        (bring[0], bring[1], bring[2]) = (need[0] * 2, need[1], need[2] * 3);
        a.mint(alice, 4 * bring[0]);
        b.mint(alice, 4 * bring[1]);
        c.mint(alice, 4 * bring[2]);
        usdg.mint(alice, 50e6);
        uint256[] memory w0 = _wallets();
        vm.prank(alice);
        uint256 s1 = direct.mintInKind(bring, 20e6, 1);
        uint256[] memory w1 = _wallets();
        vm.prank(alice);
        uint256 s2 = factory.mintInKind(address(viaFactory), bring, 20e6, 1);
        uint256[] memory w2 = _wallets();
        assertEq(s1, s2, "the same shares");
        assertGt(s1, 0);
        _assertSameMove(w0, w1, w2);
        assertEq(viaFactory.mintOf(alice), direct.mintOf(alice));
        assertEq(viaFactory.lastMintAt(alice), direct.lastMintAt(alice));
        assertEq(viaFactory.mintOf(address(factory)), 0);
        assertEq(_heldByTheFactory(), 0);
        assertEq(a.allowance(address(factory), address(viaFactory)) + b.allowance(address(factory), address(viaFactory)) + c.allowance(address(factory), address(viaFactory)), 0);
    }

    function test_AMintInKindThroughTheFactoryNeedsOneAmountPerLeg() public {
        uint256[] memory two = new uint256[](2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Factory.WrongLength.selector, 2, 3));
        factory.mintInKind(address(viaFactory), two, 0, 1);
    }

    /// The caller's legs and USDG only, as for `mint`: a stranger without them cannot reach a holder's approves.
    function testFuzz_AMintInKindSpendsOnlyTheCallersAllowances(address stranger, uint256 scale) public {
        vm.assume(stranger != address(0) && stranger.code.length == 0 && stranger != bob && stranger != address(factory) && stranger != address(vm));
        vm.assume(stranger != alice && stranger != carol && stranger != maker && stranger != owner && stranger != makeAddr("pools") && stranger != address(0xdEaD));
        assertEq(viaFactory.balanceOf(stranger) + a.balanceOf(stranger) + b.balanceOf(stranger) + c.balanceOf(stranger) + usdg.balanceOf(stranger), 0, "a stranger starts with nothing");
        scale = bound(scale, 1, 4);
        (uint256[] memory need,) = viaFactory.quoteMint(10e18);
        uint256[] memory bring = new uint256[](3);
        (bring[0], bring[1], bring[2]) = (need[0] * scale, need[1] * scale, need[2] * scale);
        a.mint(bob, bring[0]);
        b.mint(bob, bring[1]);
        c.mint(bob, bring[2]);
        uint256[4] memory bobBefore = [a.balanceOf(bob), b.balanceOf(bob), c.balanceOf(bob), usdg.balanceOf(bob)];
        vm.prank(bob);
        a.approve(address(factory), type(uint256).max);
        vm.prank(bob);
        b.approve(address(factory), type(uint256).max);
        vm.prank(bob);
        c.approve(address(factory), type(uint256).max);

        vm.prank(stranger);
        vm.expectRevert();
        factory.mintInKind(address(viaFactory), bring, 0, 1);
        assertEq(a.balanceOf(bob) + b.balanceOf(bob) + c.balanceOf(bob), bobBefore[0] + bobBefore[1] + bobBefore[2]);

        a.mint(stranger, bring[0]);
        b.mint(stranger, bring[1]);
        c.mint(stranger, bring[2]);
        vm.startPrank(stranger);
        a.approve(address(factory), bring[0]);
        b.approve(address(factory), bring[1]);
        c.approve(address(factory), bring[2]);
        uint256 shares = factory.mintInKind(address(viaFactory), bring, 0, 1);
        vm.stopPrank();
        assertEq(viaFactory.mintOf(stranger), shares);
        assertEq(a.balanceOf(bob), bobBefore[0]);
        assertEq(b.balanceOf(bob), bobBefore[1]);
        assertEq(c.balanceOf(bob), bobBefore[2]);
        assertEq(a.allowance(bob, address(factory)), type(uint256).max);
        assertEq(_heldByTheFactory(), 0);
    }

    // ------------------------------------------------------------- exits ---

    /// After a mint through the factory the minter leaves as a minter: his covered shares, no non-minter
    /// penalty, the same payout as after a direct mint (`mintOf` is his, not the factory's).
    function test_AMinterThroughTheFactoryRedeemsAsAMinter() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        Etf.Route[] memory r = _skewRoutes(500e6);
        _mintDirect(alice, 500e6, r);
        _mintVia(alice, 500e6, r);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        uint256 shares = direct.balanceOf(alice);
        (uint256 paid1, uint256 fee1, uint256 pen1, uint256[] memory due1, uint256 usdg1) = direct.previewRedeem(alice, shares);
        (uint256 paid2, uint256 fee2, uint256 pen2, uint256[] memory due2, uint256 usdg2) = viaFactory.previewRedeem(alice, shares);
        assertEq(paid1, paid2);
        assertEq(fee1, fee2);
        assertEq(pen1, pen2);
        assertEq(usdg1, usdg2);
        assertEq(due1[0], due2[0]);
        (uint256 coveredBps, uint256 otherBps, uint256 covered,) = viaFactory.exitRates(alice);
        (uint256 coveredBps2, uint256 otherBps2, uint256 covered2,) = direct.exitRates(alice);
        assertEq(coveredBps, coveredBps2);
        assertEq(otherBps, otherBps2);
        assertEq(covered, covered2);
        assertEq(covered, shares, "all of his shares are covered by his mintOf");
        uint256[] memory w0 = _wallets();
        vm.prank(alice);
        direct.redeemInKind(shares, alice, 0);
        uint256[] memory w1 = _wallets();
        vm.prank(alice);
        viaFactory.redeemInKind(shares, alice, 0);
        uint256[] memory w2 = _wallets();
        _assertSameMove(w0, w1, w2);
    }

    // ------------------------------------------------------------ gas ---

    /// What the factory's one approve costs on top of the direct door, each from the same state: about
    /// 90 000 gas more for `mint` (the USDG goes through the factory: one more transfer and an approve set
    /// and cleared), about 190 000 for `mintInKind` on three legs (that, per leg and for USDG).
    function test_Gas_TheFactoryDoorsAgainstTheEtfsOwn() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        Etf.Route[] memory r = _skewRoutes(500e6);
        (uint256[] memory need,) = direct.quoteMint(50e18);
        a.mint(alice, 2 * need[0]);
        b.mint(alice, 2 * need[1]);
        c.mint(alice, 2 * need[2]);
        // Each door measured from the same state, then undone, so neither runs on the other's warm slots.
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 g = gasleft();
        direct.mint(500e6, r, 1);
        uint256 gDirect = g - gasleft();
        vm.revertToState(snap);
        snap = vm.snapshotState();
        vm.prank(alice);
        g = gasleft();
        factory.mint(address(viaFactory), 500e6, r, 1);
        uint256 gVia = g - gasleft();
        vm.revertToState(snap);
        emit log_named_uint("mint, direct, 3 legs", gDirect);
        emit log_named_uint("mint, through the factory, 3 legs", gVia);
        assertLt(gVia, gDirect + 100_000);

        snap = vm.snapshotState();
        vm.prank(alice);
        g = gasleft();
        direct.mintInKind(need, 0, 1);
        gDirect = g - gasleft();
        vm.revertToState(snap);
        vm.prank(alice);
        g = gasleft();
        factory.mintInKind(address(viaFactory), need, 0, 1);
        gVia = g - gasleft();
        emit log_named_uint("mintInKind, direct, 3 legs", gDirect);
        emit log_named_uint("mintInKind, through the factory, 3 legs", gVia);
        assertLt(gVia, gDirect + 250_000);
    }

    // ------------------------------------------- security review 1 and 3 ---

    /// A payout aimed at the ETF itself would stay in the fund uncounted, the owner's to rescue: both
    /// redeems refuse it by name, and nothing moved.
    function test_Y1_ARedeemPaidToTheEtfItselfIsRefused() public {
        vm.warp(vm.getBlockTimestamp() + 2 days);
        uint256 shares = direct.balanceOf(maker);
        assertGt(shares, 0);
        bytes memory state = _state(direct);
        vm.startPrank(maker);
        vm.expectRevert(Etf.PayoutToTheEtf.selector);
        direct.redeemInKind(shares, address(direct), 0);
        Etf.Route[] memory none = new Etf.Route[](3);
        vm.expectRevert(Etf.PayoutToTheEtf.selector);
        direct.redeem(shares, none, 0, address(direct));
        vm.stopPrank();
        assertEq(_state(direct), state, "nothing moved");
        // The refusal is the ETF's alone: to anyone else the same redeem goes through.
        vm.prank(maker);
        direct.redeemInKind(shares, carol, 0);
        assertGt(a.balanceOf(carol), 0);
    }

    /// The creator's fees (USDG at entry, shares as management fee) are never aimed at the ETF itself, by
    /// `setFeeRecipient` or by `setCreator` (which moves the recipient with the role); any other address is
    /// still accepted.
    function test_Y3_AFeeRecipientOrACreatorSetToTheEtfItselfIsRefused() public {
        vm.startPrank(maker);
        vm.expectRevert(Etf.FeeRecipientIsTheEtf.selector);
        direct.setFeeRecipient(address(direct));
        vm.expectRevert(Etf.FeeRecipientIsTheEtf.selector);
        direct.setCreator(address(direct));
        assertEq(direct.creator(), maker);
        assertEq(direct.feeRecipient(), maker);
        direct.setFeeRecipient(carol);
        assertEq(direct.feeRecipient(), carol);
        direct.setCreator(bob);
        vm.stopPrank();
        assertEq(direct.creator(), bob);
        assertEq(direct.feeRecipient(), bob);
    }
}
