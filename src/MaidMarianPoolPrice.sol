// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { TickMath } from "./uniswap/TickMath.sol";
import { FullMath } from "./uniswap/FullMath.sol";

/// A Uniswap V3 pool's two reads the launcher v5 uses.
interface IUniswapV3PoolPrice {
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked);
}

uint32 constant POOL_TWAP_WINDOW_SECONDS = 1800;

// The launcher v5's price reader, shared by its curve and its launcher. Sentinels, no revert: 0 for no price.

/// `pool`'s 30 min mean tick as a `sqrtPriceX96`.
function poolTwapSqrtPrice(address pool) view returns (uint160) {
    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = POOL_TWAP_WINDOW_SECONDS;
    (bool answered, bytes memory data) = pool.staticcall(abi.encodeCall(IUniswapV3PoolPrice.observe, (secondsAgos)));
    if (!answered || data.length < 8 * 32) return 0;
    (int56[] memory tickCumulatives,) = abi.decode(data, (int56[], uint160[]));
    if (tickCumulatives.length < 2) return 0;
    int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
    // forge-lint: disable-next-line(unsafe-typecast)
    int24 avgTick = int24(tickDelta / int56(uint56(POOL_TWAP_WINDOW_SECONDS)));
    // Solidity truncates toward zero; the tick rounds down.
    if (tickDelta < 0 && (tickDelta % int56(uint56(POOL_TWAP_WINDOW_SECONDS)) != 0)) avgTick--;
    return TickMath.getSqrtPriceAtTick(avgTick);
}

/// `pool`'s spot `sqrtPriceX96`, for a pool too young for a TWAP.
function poolSpotSqrtPrice(address pool) view returns (uint160) {
    (bool answered, bytes memory data) = pool.staticcall(abi.encodeCall(IUniswapV3PoolPrice.slot0, ()));
    if (!answered || data.length != 7 * 32) return 0;
    uint256 sqrtPriceX96 = abi.decode(data, (uint256));
    if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) return 0;
    // In Uniswap's range, so under 2^160.
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint160(sqrtPriceX96);
}

/// `amount` of `base` in `quote`; past 2^128 the ratio is carried at X128, squaring would overflow.
function poolValueAt(uint160 sqrtPriceX96, uint256 amount, address base, address quote) pure returns (uint256) {
    if (sqrtPriceX96 <= type(uint128).max) {
        uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
        return base < quote ? FullMath.mulDiv(ratioX192, amount, 1 << 192) : FullMath.mulDiv(1 << 192, amount, ratioX192);
    }
    uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
    return base < quote ? FullMath.mulDiv(ratioX128, amount, 1 << 128) : FullMath.mulDiv(1 << 128, amount, ratioX128);
}

/// `pool`'s `observationCardinalityNext`; `ok` false for any other answer.
function poolCardinalityNext(address pool) view returns (bool ok, uint16 next) {
    (bool success, bytes memory ret) = pool.staticcall(abi.encodeCall(IUniswapV3PoolPrice.slot0, ()));
    if (!success || ret.length != 7 * 32) return (false, 0);
    (,,,, uint256 n,,) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
    if (n > type(uint16).max) return (false, 0);
    // forge-lint: disable-next-line(unsafe-typecast)
    return (true, uint16(n));
}
