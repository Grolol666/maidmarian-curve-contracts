// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { TickMath } from "./uniswap/TickMath.sol";
import { FullMath } from "./uniswap/FullMath.sol";

interface IUniswapV3PoolObserve {
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

// A Uniswap V3 TWAP, read through observe(). Separate from the registry so the
// tick maths and its libraries live outside the contracts that price bags.
contract MaidMarianBagPoolOracle {
    uint32 public constant TWAP_WINDOW_SECONDS = 1800;

    /// @notice A `pool`'s 30-minute TWAP, priced for `amount` — and whether the
    /// pool could answer at all.
    /// @dev This is the only place in these three contracts that talks to code
    /// nobody here wrote, so it is the only place a low-level call is the right
    /// tool: `observe` reverts on a pool with too little history, and there is
    /// no way to learn that without asking. Everything above this line is told
    /// with a flag, which is why nothing above it needs a try/catch.
    ///
    /// `staticcall` reports success for an address with no code at all, so the
    /// returndata is length-checked too: an empty answer is not a price.
    function tryQuote(address pool, uint256 amount, address baseToken, address quoteToken) external view returns (uint256 quoteAmount, bool ok) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW_SECONDS;
        secondsAgos[1] = 0;

        (bool answered, bytes memory data) = pool.staticcall(abi.encodeCall(IUniswapV3PoolObserve.observe, (secondsAgos)));
        // Two dynamic arrays of two entries: 2 offsets, then a length and two
        // values each. Anything shorter is not what this asked for.
        if (!answered || data.length < 8 * 32) return (0, false);

        (int56[] memory tickCumulatives,) = abi.decode(data, (int56[], uint160[]));
        if (tickCumulatives.length < 2) return (0, false);

        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 avgTick = int24(tickDelta / int56(uint56(TWAP_WINDOW_SECONDS)));
        // Solidity truncates toward zero; the tick has to round down, so a
        // negative delta that does not divide evenly is one tick too high.
        if (tickDelta < 0 && (tickDelta % int56(uint56(TWAP_WINDOW_SECONDS)) != 0)) avgTick--;

        return (_quoteAtTick(avgTick, amount, baseToken, quoteToken), true);
    }

    function _quoteAtTick(int24 tick, uint256 baseAmount, address baseToken, address quoteToken) private pure returns (uint256 quoteAmount) {
        // Two branches for one formula: squaring sqrtRatioX96 overflows past
        // uint128, so a large ratio is carried at X128 instead of X192.
        uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192) : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128) : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
