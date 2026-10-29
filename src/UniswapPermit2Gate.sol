// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// The Universal Router's entry point.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @title UniswapPermit2Gate
 * @notice A thin, stateless adapter that lets any caller - a contract holding
 * a plain ERC-20 allowance, or a wallet - execute a Uniswap Universal Router
 * route without Permit2.
 *
 * `swap` moves `amountIn` of `tokenIn` from the caller straight into the
 * Universal Router, calls `execute(commands, inputs, deadline)`, measures the
 * `tokenOut` that arrived on this contract during the call, requires it to be
 * at least `minOut`, and sends exactly that amount to the caller.
 *
 * Calldata requirements. `commands` and `inputs` are the Universal Router's,
 * built by the caller for this contract as payer and recipient:
 *  - the router must pay the input from its own balance: `payerIsUser` must
 *    be `false` (v2/v3 commands), and a v4 plan must settle with
 *    `payerIsUser: false`;
 *  - the route must deliver `tokenOut` to this contract (its address as
 *    recipient, or the router's `MSG_SENDER` alias);
 *  - a route that ends in native ETH is declared with `tokenOut ==
 *    address(0)`; the ETH it delivers here is forwarded the same way.
 *
 * What it does not do. It does not refund unconsumed input: whatever the
 * route does not spend stays in the router, or on this contract if the plan
 * sweeps it back. It applies no slippage logic beyond `minOut`, checked on
 * what actually arrived. It never reads the calldata: the caller is
 * responsible for the bytes.
 *
 * Owner. The owner can only move balances that are already stuck on this
 * contract (`rescueToken`, `rescueNative`); a swap funds the router, runs
 * and pays in one call under one lock, so nothing in flight can be rescued.
 * This contract never holds `tokenIn`. Ownership is
 * transferable and can never be renounced.
 */
contract UniswapPermit2Gate is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// The Universal Router this contract pre-funds and calls.
    IUniversalRouter public immutable UNIVERSAL_ROUTER;

    /// Emitted once per completed swap.
    event Swapped(address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    /// Emitted when the owner moves a stuck balance; `token` is `address(0)` for ETH.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// The route delivered less than `minOut`; the call is rolled back.
    error InsufficientOutput(uint256 amountOut, uint256 minOut);

    /// `amountIn` is zero, or `tokenIn == tokenOut`.
    error NothingToSwap();

    /// `tokenIn == address(0)`: input must be an ERC-20.
    error NativeInputUnsupported();

    /// `to` rejected an ETH transfer.
    error NativeTransferFailed(address to, uint256 amount);

    /// ETH was sent to this contract outside a swap.
    error UnexpectedNative();

    /// Ownership cannot be renounced.
    error RenounceForbidden();

    /// A rescue to `address(0)` is refused.
    error RescueToNobody();

    /// @param universalRouter The Universal Router this contract pre-funds and calls.
    /// @param initialOwner The account allowed to rescue stuck balances.
    constructor(IUniversalRouter universalRouter, address initialOwner) Ownable(initialOwner) {
        UNIVERSAL_ROUTER = universalRouter;
    }

    /// Accepts ETH only while a swap is running (a route paying out native ETH).
    receive() external payable {
        if (!_reentrancyGuardEntered()) revert UnexpectedNative();
    }

    /**
     * @notice Swap `amountIn` of `tokenIn` for at least `minOut` of `tokenOut`
     * through the Universal Router; the caller receives exactly what arrived.
     * @param tokenIn ERC-20 the caller has approved this contract for `amountIn`.
     * @param amountIn Amount moved from the caller into the router.
     * @param tokenOut ERC-20 the route delivers, or `address(0)` for native ETH.
     * @param minOut Minimum `tokenOut` (or wei) that must arrive, or the call reverts.
     * @param commands Universal Router command bytes.
     * @param inputs One input per command.
     * @param deadline Forwarded to the router.
     * @return amountOut The `tokenOut` (or wei) delivered by the route and sent to the caller.
     */
    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut, bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0 || tokenIn == tokenOut) revert NothingToSwap();
        if (tokenIn == address(0)) revert NativeInputUnsupported();

        IERC20 tIn = IERC20(tokenIn);

        // Output is measured as a difference: a balance already held here is
        // neither counted toward `minOut` nor paid out.
        uint256 before = _held(tokenOut);

        // The router pays the pool from its own balance, so the input goes
        // from the caller straight into the router before `execute`.
        tIn.safeTransferFrom(msg.sender, address(UNIVERSAL_ROUTER), amountIn);
        UNIVERSAL_ROUTER.execute(commands, inputs, deadline);

        amountOut = _held(tokenOut) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        if (amountOut > 0) _send(tokenOut, msg.sender, amountOut);      //on peut recv des natives ???

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @notice Send this contract's whole balance of `token` to `to`. Owner only.
    /// @param token The ERC-20 to move.
    /// @param to The recipient; must not be `address(0)`.
    /// @return amount The amount moved.
    function rescueToken(IERC20 token, address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert RescueToNobody();
        amount = token.balanceOf(address(this));
        if (amount > 0) token.safeTransfer(to, amount);
        emit Rescued(address(token), to, amount);
    }

    /// @notice Send this contract's whole ETH balance to `to`. Owner only.
    /// @param to The recipient; must not be `address(0)`.
    /// @return amount The wei moved.
    function rescueNative(address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert RescueToNobody();
        amount = address(this).balance;
        if (amount > 0) _send(address(0), to, amount);
        emit Rescued(address(0), to, amount);
    }

    /// @notice Always reverts: ownership can be transferred, never renounced.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceForbidden();
    }

    /// This contract's balance of `token`; wei when `token` is `address(0)`.
    function _held(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// `amount` of `token` to `to`; a plain call for ETH.
    function _send(address token, address to, uint256 amount) private {
        if (token != address(0)) {
            IERC20(token).safeTransfer(to, amount);
            return;
        }
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed(to, amount);
    }
}
