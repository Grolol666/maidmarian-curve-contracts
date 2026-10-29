// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { UniswapPermit2Gate, IUniversalRouter } from "../src/UniswapPermit2Gate.sol";
import { TokenMock, UniversalRouterMock } from "./Mocks.sol";

/**
 * The gate against a mock router: what it proves is the gate's own
 * bookkeeping - that it pulls, pre-funds, runs, measures a delta and pays
 * exactly that, leaves the rest where it lies, and lets only the owner move
 * it - not that the real router accepts the calldata or pays from its own
 * balance. Those claims are `UniswapPermit2Gate.fork.t.sol`'s.
 *
 * The router is a constructor argument, so the mock is injected, not etched.
 * The owner is this test contract, the deployer.
 */
contract UniswapPermit2GateTest is Test {
    UniswapPermit2Gate internal gate;
    UniversalRouterMock internal router;
    TokenMock internal usdg;
    TokenMock internal aapl;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal safe = address(0x5AFE);

    uint256 internal constant AMOUNT_IN = 1_000e6;
    uint256 internal constant ROUTER_INVENTORY = 1_000e18;

    event Swapped(address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        router = new UniversalRouterMock();
        gate = new UniswapPermit2Gate(IUniversalRouter(address(router)), address(this));

        usdg = new TokenMock("USDG", "USDG", 6);
        aapl = new TokenMock("Apple", "AAPL", 18);
        aapl.mint(address(router), ROUTER_INVENTORY);
        vm.deal(address(router), ROUTER_INVENTORY);

        usdg.mint(alice, AMOUNT_IN);
        vm.prank(alice);
        usdg.approve(address(gate), AMOUNT_IN);
    }

    /// A `V3_SWAP_EXACT_IN` input as this deployment reads it (six members,
    /// the trailing `bytes` empty), built for the gate as recipient and with
    /// `payerIsUser: false` - the router pays from what the gate put there.
    function _calldata(uint256 amountIn, address tokenOut) internal view returns (bytes memory commands, bytes[] memory inputs) {
        commands = hex"00";
        inputs = new bytes[](1);
        inputs[0] = abi.encode(address(gate), amountIn, uint256(0), abi.encodePacked(address(usdg), uint24(500), tokenOut), false, bytes(""));
    }

    function _swap(address who, address tokenOut, uint256 minOut) internal returns (uint256 out) {
        (bytes memory commands, bytes[] memory inputs) = _calldata(AMOUNT_IN, tokenOut);
        vm.prank(who);
        out = gate.swap(address(usdg), AMOUNT_IN, tokenOut, minOut, commands, inputs, block.timestamp + 60);
    }

    /// The whole path, and the whole balance sheet after it: the caller has the
    /// output, the router has the input, the gate has nothing of either (an
    /// exact-in route spends it all), and the event says what happened.
    function test_ASwapLeavesTheCallerWithTheOutputAndTheRouterWithTheInput() public {
        vm.expectEmit(true, true, true, true, address(gate));
        emit Swapped(alice, address(usdg), address(aapl), AMOUNT_IN, AMOUNT_IN);

        uint256 out = _swap(alice, address(aapl), 0);

        assertEq(out, AMOUNT_IN, "rate 1:1 in raw units, as the mock is set");
        assertEq(aapl.balanceOf(alice), AMOUNT_IN, "the output reached the caller");
        assertEq(usdg.balanceOf(alice), 0, "the input left the caller");
        assertEq(usdg.balanceOf(address(router)), AMOUNT_IN, "and reached the router by transfer, ahead of execute");
        assertEq(usdg.balanceOf(address(gate)), 0, "the router spent it all, so no input is on the gate");
        assertEq(aapl.balanceOf(address(gate)), 0, "and the whole output went on to the caller");
    }

    /// The gate's floor, not the router's: the mock ignores `amountOutMinimum`
    /// and pays at its rate, and the gate still refuses with its named error.
    /// The caller keeps its input, since the whole call rolls back.
    function test_LessThanMinOutRevertsWithInsufficientOutputAndTheCallerKeepsItsInput() public {
        router.setRate(5e17);

        (bytes memory commands, bytes[] memory inputs) = _calldata(AMOUNT_IN, address(aapl));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UniswapPermit2Gate.InsufficientOutput.selector, AMOUNT_IN / 2, AMOUNT_IN));
        gate.swap(address(usdg), AMOUNT_IN, address(aapl), AMOUNT_IN, commands, inputs, block.timestamp + 60);

        assertEq(usdg.balanceOf(alice), AMOUNT_IN, "the input is still the caller's");
    }

    /// A router that pays nothing is the same refusal, with 0 in the error.
    function test_ARouterThatPaysNothingIsRefusedTheSameWay() public {
        router.setPayNothing(true);

        (bytes memory commands, bytes[] memory inputs) = _calldata(AMOUNT_IN, address(aapl));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UniswapPermit2Gate.InsufficientOutput.selector, 0, 1));
        gate.swap(address(usdg), AMOUNT_IN, address(aapl), 1, commands, inputs, block.timestamp + 60);
    }

    /// The router spent 40% of what it was given and sent the rest back to
    /// the gate (a `SWEEP` on the real one): the caller gets the output on
    /// what was spent, and the 60% **stays on the gate** - dust, the owner's
    /// to rescue, not the caller's to reclaim. The gate executes, the Book
    /// judges.
    function test_UnspentInputStaysOnTheGateAsDust() public {
        router.setTakeBps(4_000);

        uint256 out = _swap(alice, address(aapl), 0);

        assertEq(out, (AMOUNT_IN * 4) / 10, "output on what was really spent");
        assertEq(aapl.balanceOf(alice), out, "and it reached the caller");
        assertEq(usdg.balanceOf(alice), 0, "nothing of the input came back to the caller");
        assertEq(usdg.balanceOf(address(gate)), (AMOUNT_IN * 6) / 10, "the unspent 60% remains on the gate");
        assertEq(usdg.balanceOf(address(router)), (AMOUNT_IN * 4) / 10, "the router kept what it spent");
    }

    /// A balance of `tokenOut` the gate already carried is not the route's
    /// output: the caller receives the delta and the floor is checked on the
    /// delta; what was there before stays there after.
    function test_ABalanceTheGateAlreadyHeldIsNeitherCountedNorPaidOut() public {
        aapl.mint(address(gate), 7e18);
        router.setRate(5e17);

        (bytes memory commands, bytes[] memory inputs) = _calldata(AMOUNT_IN, address(aapl));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UniswapPermit2Gate.InsufficientOutput.selector, AMOUNT_IN / 2, AMOUNT_IN));
        gate.swap(address(usdg), AMOUNT_IN, address(aapl), AMOUNT_IN, commands, inputs, block.timestamp + 60);

        uint256 out = _swap(alice, address(aapl), AMOUNT_IN / 2);
        assertEq(out, AMOUNT_IN / 2, "the delta, not the balance");
        assertEq(aapl.balanceOf(alice), AMOUNT_IN / 2, "the caller got the delta");
        assertEq(aapl.balanceOf(address(gate)), 7e18, "the earlier balance remains");
    }

    /// A route that ends in native ETH: `tokenOut == address(0)`, the router
    /// pays the gate in wei, the gate measures and forwards the wei delta.
    function test_ANativeOutRouteDeliversEthToTheCaller() public {
        vm.expectEmit(true, true, true, true, address(gate));
        emit Swapped(alice, address(usdg), address(0), AMOUNT_IN, AMOUNT_IN);

        uint256 out = _swap(alice, address(0), AMOUNT_IN);

        assertEq(out, AMOUNT_IN, "wei out at the mock's 1:1");
        assertEq(alice.balance, AMOUNT_IN, "the ETH reached the caller");
        assertEq(address(router).balance, ROUTER_INVENTORY - AMOUNT_IN, "out of the router's inventory");
        assertEq(address(gate).balance, 0, "the whole delta went on");
    }

    /// A native-out route whose caller cannot take ETH is rolled back by
    /// name, not left with wei on the gate.
    function test_ANativeOutRouteToACallerWithoutReceiveIsRolledBack() public {
        NoReceive caller = new NoReceive();
        usdg.mint(address(caller), AMOUNT_IN);
        (bytes memory commands, bytes[] memory inputs) = _calldata(AMOUNT_IN, address(0));

        vm.expectRevert(abi.encodeWithSelector(UniswapPermit2Gate.NativeTransferFailed.selector, address(caller), AMOUNT_IN));
        caller.go(gate, usdg, commands, inputs);

        assertEq(usdg.balanceOf(address(caller)), AMOUNT_IN, "the caller's input is untouched");
        assertEq(address(gate).balance, 0);
    }

    /// The router calls `swap` back while it is running - the one way one
    /// funding could be run twice. The guard refuses it by OpenZeppelin's
    /// named error; the outer swap completes on its own and the balance sheet
    /// is the honest one.
    function test_AReentrantSwapFromTheRouterIsRefusedAndTheOuterSwapCompletes() public {
        router.setReenter(true);

        uint256 out = _swap(alice, address(aapl), 0);

        assertEq(router.reentryRevert(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector), "the second entry hit the guard");
        assertEq(out, AMOUNT_IN, "the first entry paid once");
        assertEq(aapl.balanceOf(alice), AMOUNT_IN);
        assertEq(aapl.balanceOf(address(router)), ROUTER_INVENTORY - AMOUNT_IN, "the router paid once");
    }

    /// Dust on the gate is not a second caller's: a `swap` with nothing
    /// approved reverts in the pull, and a swap that runs measures its own
    /// delta - the dust is neither counted nor paid.
    function test_DustIsNotASecondCallersOutput() public {
        router.setTakeBps(4_000);
        _swap(alice, address(aapl), 0);
        uint256 dust = usdg.balanceOf(address(gate));
        assertEq(dust, (AMOUNT_IN * 6) / 10);

        (bytes memory commands, bytes[] memory inputs) = _calldata(AMOUNT_IN, address(aapl));
        vm.prank(bob);
        vm.expectRevert();
        gate.swap(address(usdg), AMOUNT_IN, address(aapl), 0, commands, inputs, block.timestamp + 60);

        assertEq(usdg.balanceOf(address(gate)), dust, "the dust is still there");
        assertEq(aapl.balanceOf(bob), 0, "bob got nothing");
    }

    /// The owner takes the gate's whole balance of a token to where it says;
    /// the event names it.
    function test_TheOwnerRescuesDustToWhereItSays() public {
        router.setTakeBps(4_000);
        _swap(alice, address(aapl), 0);
        uint256 dust = usdg.balanceOf(address(gate));

        vm.expectEmit(true, true, true, true, address(gate));
        emit Rescued(address(usdg), safe, dust);
        uint256 amount = gate.rescueToken(IERC20(address(usdg)), safe);

        assertEq(amount, dust);
        assertEq(usdg.balanceOf(safe), dust, "the dust is at the safe");
        assertEq(usdg.balanceOf(address(gate)), 0, "and no longer on the gate");
    }

    /// Wei the gate carries goes the same way, by `rescueNative`.
    function test_TheOwnerRescuesNativeDust() public {
        vm.deal(address(gate), 3 ether);

        vm.expectEmit(true, true, true, true, address(gate));
        emit Rescued(address(0), safe, 3 ether);
        uint256 amount = gate.rescueNative(safe);

        assertEq(amount, 3 ether);
        assertEq(safe.balance, 3 ether);
        assertEq(address(gate).balance, 0);
    }

    /// A stranger asking for a rescue is refused by OpenZeppelin's named
    /// error, for tokens and for wei, and the dust does not move.
    function test_AStrangerCannotRescue() public {
        router.setTakeBps(4_000);
        _swap(alice, address(aapl), 0);
        uint256 dust = usdg.balanceOf(address(gate));
        vm.deal(address(gate), 1 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        gate.rescueToken(IERC20(address(usdg)), bob);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        gate.rescueNative(bob);

        assertEq(usdg.balanceOf(address(gate)), dust);
        assertEq(address(gate).balance, 1 ether);
    }

    /// A rescue to nobody is refused - the balance would be burned.
    function test_ARescueToAddressZeroIsRefused() public {
        vm.expectRevert(UniswapPermit2Gate.RescueToNobody.selector);
        gate.rescueToken(IERC20(address(usdg)), address(0));
        vm.expectRevert(UniswapPermit2Gate.RescueToNobody.selector);
        gate.rescueNative(address(0));
    }

    /// The house rule: ownership cannot be given up, only moved.
    function test_RenounceOwnershipIsForbiddenAndTransferOwnershipWorks() public {
        vm.expectRevert(UniswapPermit2Gate.RenounceForbidden.selector);
        gate.renounceOwnership();
        assertEq(gate.owner(), address(this));

        gate.transferOwnership(safe);
        assertEq(gate.owner(), safe);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        gate.rescueNative(safe);
    }

    /// ETH sent to the gate outside a swap is refused: only the PoolManager,
    /// mid-swap, is expected to pay it.
    function test_EthSentOutsideASwapIsRefused() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(gate).call{ value: 1 ether }("");
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(UniswapPermit2Gate.UnexpectedNative.selector));
        assertEq(address(gate).balance, 0);
    }

    /// The degenerate inputs the balance bookkeeping cannot represent, and
    /// the one it does not serve.
    function test_ZeroAmountSameTokenAndNativeInputAreRefused() public {
        (bytes memory commands, bytes[] memory inputs) = _calldata(0, address(aapl));

        vm.prank(alice);
        vm.expectRevert(UniswapPermit2Gate.NothingToSwap.selector);
        gate.swap(address(usdg), 0, address(aapl), 0, commands, inputs, block.timestamp + 60);

        vm.prank(alice);
        vm.expectRevert(UniswapPermit2Gate.NothingToSwap.selector);
        gate.swap(address(usdg), AMOUNT_IN, address(usdg), 0, commands, inputs, block.timestamp + 60);

        vm.prank(alice);
        vm.expectRevert(UniswapPermit2Gate.NativeInputUnsupported.selector);
        gate.swap(address(0), AMOUNT_IN, address(aapl), 0, commands, inputs, block.timestamp + 60);
    }
}

/// A caller that approves and swaps but has no `receive`: the shape of a
/// contract handed a native-out route by mistake.
contract NoReceive {
    function go(UniswapPermit2Gate gate, TokenMock tokenIn, bytes memory commands, bytes[] memory inputs) external {
        uint256 amount = tokenIn.balanceOf(address(this));
        tokenIn.approve(address(gate), amount);
        gate.swap(address(tokenIn), amount, address(0), 0, commands, inputs, block.timestamp + 60);
    }
}
