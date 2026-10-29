// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TickMath } from "./uniswap/TickMath.sol";
import { IPoolManagerV4 } from "./MaidMarianLaunchCurve.sol";

// The launcher v5's Uniswap helpers, one copy for its launcher and its curve.

uint256 constant Q96 = 1 << 96;

// Universal Router commands and the V4 router's actions (`SWAP_EXACT_IN_SINGLE`, `SETTLE`, `TAKE`).
bytes1 constant UR_V3_SWAP_EXACT_IN = 0x00;
bytes1 constant UR_V4_SWAP = 0x10;
bytes constant V4_SWAP_SETTLE_TAKE = hex"060b0e";

/// The deployed V4 router's `SWAP_EXACT_IN_SINGLE` params: without `minHopPriceX36` it reverts.
struct V4ExactInputSingle {
    IPoolManagerV4.PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes hookData;
}

/// A one-word answer to a static call; `ok` false for anything else.
function readWord(address target, bytes memory data) view returns (bool ok, uint256 value) {
    (bool success, bytes memory ret) = target.staticcall(data);
    if (!success || ret.length != 32) return (false, 0);
    return (true, abi.decode(ret, (uint256)));
}

function v4PoolId(IPoolManagerV4.PoolKey memory key) pure returns (bytes32) {
    // forge-lint: disable-next-line(asm-keccak256)
    return keccak256(abi.encode(key));
}

/// A V4 pool's `sqrtPriceX96` (its state at `keccak256(id, 6)`), 0 when uninitialised.
function v4SqrtPriceOf(address poolManager, bytes32 id) view returns (uint160) {
    (bool ok, uint256 word) = readWord(poolManager, abi.encodeWithSelector(0x1e2eaeaf, keccak256(abi.encode(id, uint256(6))))); // extsload(bytes32)
    // forge-lint: disable-next-line(unsafe-typecast)
    return ok ? uint160(word) : 0;
}

/// A `BalanceDelta`'s two halves: amount0 in the high 128 bits.
function v4Amounts(int256 delta) pure returns (int256 a0, int256 a1) {
    a0 = delta >> 128;
    // forge-lint: disable-next-line(unsafe-typecast)
    a1 = int256(int128(delta));
}

function v4AddDeltas(int256 a, int256 b) pure returns (int256) {
    (int256 a0, int256 a1) = v4Amounts(a);
    (int256 b0, int256 b1) = v4Amounts(b);
    // forge-lint: disable-next-line(unsafe-typecast)
    return int256((uint256(a0 + b0) << 128) | uint256(uint128(int128(a1 + b1))));
}

/// The highest multiple of `spacing` at or under `tick`.
function floorTick(int24 tick, int24 spacing) pure returns (int24) {
    int24 r = tick % spacing;
    return r < 0 ? tick - r - spacing : tick - r;
}

/// The lowest multiple of `spacing` at or over `tick`.
function ceilTick(int24 tick, int24 spacing) pure returns (int24) {
    int24 f = floorTick(tick, spacing);
    return f == tick ? f : f + spacing;
}

/// `sqrt(amount1 / amount0)` in Q96.
function sqrtPriceOfAmounts(uint256 amount1, uint256 amount0) pure returns (uint160) {
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint160(Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0)));
}

/// The liquidity `amount0` and `amount1` give in `[lowerTick, upperTick]` at `sqrtPrice`, inside the range.
function rangeLiquidity(uint160 sqrtPrice, uint256 amount0, uint256 amount1, int24 lowerTick, int24 upperTick) pure returns (uint256) {
    uint256 lower = TickMath.getSqrtPriceAtTick(lowerTick);
    uint256 upper = TickMath.getSqrtPriceAtTick(upperTick);
    uint256 l0 = Math.mulDiv(amount0, Math.mulDiv(sqrtPrice, upper, Q96), upper - sqrtPrice);
    uint256 l1 = Math.mulDiv(amount1, Q96, sqrtPrice - lower);
    return Math.min(l0, l1);
}

/// The liquidity of `amount` of one currency alone in `[lowerTick, upperTick]`: currency0 above the price,
/// currency1 below it.
function singleSidedLiquidity(uint256 amount, bool currency0, int24 lowerTick, int24 upperTick) pure returns (uint256) {
    uint256 sa = TickMath.getSqrtPriceAtTick(lowerTick);
    uint256 sb = TickMath.getSqrtPriceAtTick(upperTick);
    return currency0 ? Math.mulDiv(amount, Math.mulDiv(sa, sb, Q96), sb - sa) : Math.mulDiv(amount, Q96, sb - sa);
}

/// `V3_SWAP_EXACT_IN`'s input, the router pre-funded: the deployed router reads a sixth field.
function v3SwapInput(address recipient, address tokenIn, uint24 fee, address tokenOut, uint256 amountIn) pure returns (bytes memory) {
    return abi.encode(recipient, amountIn, uint256(0), abi.encodePacked(tokenIn, fee, tokenOut), false, bytes(""));
}

/// `V4_SWAP`'s input: `SWAP_EXACT_IN_SINGLE`, `SETTLE` from the router, `TAKE` of the whole output.
function v4SwapInput(address recipient, address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, address hooks, uint128 amountIn) pure returns (bytes memory) {
    bool zeroForOne = tokenIn < tokenOut;
    (address c0, address c1) = zeroForOne ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
    IPoolManagerV4.PoolKey memory key = IPoolManagerV4.PoolKey({ currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: hooks });
    bytes[] memory params = new bytes[](3);
    params[0] = abi.encode(V4ExactInputSingle({ poolKey: key, zeroForOne: zeroForOne, amountIn: amountIn, amountOutMinimum: 0, minHopPriceX36: 0, hookData: "" }));
    params[1] = abi.encode(tokenIn, uint256(amountIn), false);
    params[2] = abi.encode(tokenOut, recipient, uint256(0));
    return abi.encode(V4_SWAP_SETTLE_TAKE, params);
}
