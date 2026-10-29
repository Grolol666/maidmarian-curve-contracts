// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TickMath } from "../src/uniswap/TickMath.sol";
import { IPoolManagerV4 } from "../src/MaidMarianLaunchCurve.sol";
import { IUnlockCallbackV4, packDelta, deltaAmounts } from "./CurveFixtures.sol";

/**
 * `CurveFixtures.sol`'s `V4PoolManagerMock` for the launcher v5 (copied, the original untouched: v4's suites use it),
 * with V4's three cases in `modifyLiquidity`: a range above the price takes currency0 alone, below it currency1
 * alone, and only a range holding the price adds to the liquidity swaps trade on. Swaps still run on that one
 * liquidity and never cross a range's edge: what the v5 bond's position above the price does once the price walks
 * into it is proved on the deployed PoolManager, `MaidMarianLauncherV5.fork.t.sol`. The original's header follows.
 *
 * A Uniswap V4 PoolManager for the offline curve tests: `initialize`, `unlock` with V4's flash
 * accounting (`sync` / `settle` / `take`, every delta zero at the end), `modifyLiquidity` with V4's
 * amount formulas (rounded up when the caller pays), and exact-in `swap` on one range of liquidity
 * per pool (the bond's full range) with its fee kept for the position, a swap on no liquidity moving
 * the price to its limit for free. Storage slot 0 is `PoolManagerMock`'s, so it can be etched at the
 * router's `poolManager()` and the pools already initialised there stay. Proves the curve's side of
 * the calls; that the deployed PoolManager agrees is `MaidMarianLaunchCurve.fork.t.sol`.
 */
contract V4RangePoolManagerMock {
    mapping(bytes32 slot => bytes32) private _slots;
    mapping(bytes32 id => uint256) public liquidity;
    /// Each position's liquidity, by `keccak256(id, tickLower, tickUpper)`.
    mapping(bytes32 position => uint256) public positionLiquidity;
    mapping(bytes32 id => uint256) public fees0;
    mapping(bytes32 id => uint256) public fees1;
    /// The `sqrtPriceX96` each pool was initialized at.
    mapping(bytes32 id => uint160) public openedAt;
    mapping(address currency => int256) public delta;
    address public locker;
    address[] private _touched;
    address private _synced;
    uint256 private _syncedBalance;

    uint256 private constant Q96 = 1 << 96;

    /// `IHooks.beforeInitialize(address,PoolKey,uint160)`.
    bytes4 internal constant BEFORE_INITIALIZE = 0xdc98354e;

    /// V4's `IPoolManager.Swap`, emitted by every swap.
    event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee);

    error PoolAlreadyInitialized();
    error InvalidHookResponse();
    error NotLocker();
    error CurrencyNotSettled(address currency);

    function poolId(IPoolManagerV4.PoolKey memory key) public pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function sqrtPriceOf(bytes32 id) public view returns (uint160) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(uint256(_slots[keccak256(abi.encode(id, uint256(6)))]));
    }

    function _setPrice(bytes32 id, uint160 p) private {
        _slots[keccak256(abi.encode(id, uint256(6)))] = bytes32(uint256(p));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }

    /// As V4: a hook with the `beforeInitialize` bit is called first with the caller, and its revert
    /// or a wrong answer refuses the pool (V4 wraps the reason in `WrappedError`; the mock passes it as is).
    function initialize(IPoolManagerV4.PoolKey memory key, uint160 sqrtPriceX96) external returns (int24) {
        if (uint160(key.hooks) & (1 << 13) != 0) {
            (bool ok, bytes memory ret) = key.hooks.call(abi.encodeWithSelector(BEFORE_INITIALIZE, msg.sender, key, sqrtPriceX96));
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
            // The first 4 of 32 bytes: the selector the hook answers.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (ret.length != 32 || bytes4(ret) != BEFORE_INITIALIZE) revert InvalidHookResponse();
        }
        bytes32 id = poolId(key);
        if (sqrtPriceOf(id) != 0) revert PoolAlreadyInitialized();
        _setPrice(id, sqrtPriceX96);
        openedAt[id] = sqrtPriceX96;
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (locker != address(0)) revert NotLocker();
        locker = msg.sender;
        result = IUnlockCallbackV4(msg.sender).unlockCallback(data);
        for (uint256 i = 0; i < _touched.length; i++) {
            if (delta[_touched[i]] != 0) revert CurrencyNotSettled(_touched[i]);
        }
        delete _touched;
        locker = address(0);
    }

    function _account(address currency, int256 d) private {
        if (d == 0) return;
        _touched.push(currency);
        delta[currency] += d;
    }

    function modifyLiquidity(IPoolManagerV4.PoolKey memory key, IPoolManagerV4.ModifyLiquidityParams memory p, bytes calldata) external returns (int256 callerDelta, int256 feesAccrued) {
        if (msg.sender != locker) revert NotLocker();
        bytes32 id = poolId(key);
        uint160 sqrtP = sqrtPriceOf(id);
        int256 d0;
        int256 d1;
        if (p.liquidityDelta > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 l = uint256(p.liquidityDelta);
            uint256 lower = TickMath.getSqrtPriceAtTick(p.tickLower);
            uint256 upper = TickMath.getSqrtPriceAtTick(p.tickUpper);
            // V4's three cases: under the range currency0 alone, over it currency1 alone, in it both and active.
            uint256 a0;
            uint256 a1;
            if (sqrtP <= lower) {
                a0 = _amount0(lower, upper, l, true);
            } else if (sqrtP >= upper) {
                a1 = _amount1(lower, upper, l, true);
            } else {
                (a0, a1) = (_amount0(sqrtP, upper, l, true), _amount1(lower, sqrtP, l, true));
                liquidity[id] += l;
            }
            // forge-lint: disable-next-line(unsafe-typecast)
            (d0, d1) = (-int256(a0), -int256(a1));
            positionLiquidity[keccak256(abi.encode(id, p.tickLower, p.tickUpper))] += l;
        }
        (uint256 f0, uint256 f1) = (fees0[id], fees1[id]);
        (fees0[id], fees1[id]) = (0, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        feesAccrued = packDelta(int256(f0), int256(f1));
        // forge-lint: disable-next-line(unsafe-typecast)
        (d0, d1) = (d0 + int256(f0), d1 + int256(f1));
        callerDelta = packDelta(d0, d1);
        _account(key.currency0, d0);
        _account(key.currency1, d1);
    }

    function swap(IPoolManagerV4.PoolKey memory key, IPoolManagerV4.SwapParams memory p, bytes calldata) external returns (int256 swapDelta) {
        if (msg.sender != locker) revert NotLocker();
        require(p.amountSpecified < 0, "mock: exact input only");
        bytes32 id = poolId(key);
        uint160 sqrtP = sqrtPriceOf(id);
        uint256 l = liquidity[id];
        if (l == 0) {
            _setPrice(id, p.sqrtPriceLimitX96);
            return 0;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountIn = uint256(-p.amountSpecified);
        uint256 lessFee = amountIn * (1e6 - key.fee) / 1e6;
        uint256 next;
        uint256 out;
        if (p.zeroForOne) {
            next = Math.mulDiv(l << 96, sqrtP, (l << 96) + lessFee * sqrtP, Math.Rounding.Ceil);
            if (next < p.sqrtPriceLimitX96) {
                next = p.sqrtPriceLimitX96;
                lessFee = _amount0(next, sqrtP, l, true);
                amountIn = lessFee + Math.mulDiv(lessFee, key.fee, 1e6 - key.fee, Math.Rounding.Ceil);
            }
            out = _amount1(next, sqrtP, l, false);
            fees0[id] += amountIn - lessFee;
            // forge-lint: disable-next-line(unsafe-typecast)
            swapDelta = packDelta(-int256(amountIn), int256(out));
        } else {
            next = sqrtP + Math.mulDiv(lessFee, Q96, l);
            if (next > p.sqrtPriceLimitX96) {
                next = p.sqrtPriceLimitX96;
                lessFee = _amount1(sqrtP, next, l, true);
                amountIn = lessFee + Math.mulDiv(lessFee, key.fee, 1e6 - key.fee, Math.Rounding.Ceil);
            }
            out = _amount0(sqrtP, next, l, false);
            fees1[id] += amountIn - lessFee;
            // forge-lint: disable-next-line(unsafe-typecast)
            swapDelta = packDelta(int256(out), -int256(amountIn));
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        _setPrice(id, uint160(next));
        (int256 a0, int256 a1) = deltaAmounts(swapDelta);
        _account(key.currency0, a0);
        _account(key.currency1, a1);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit Swap(id, msg.sender, int128(a0), int128(a1), uint160(next), uint128(l), TickMath.getTickAtSqrtPrice(uint160(next)), key.fee);
    }

    function sync(address currency) external {
        (_synced, _syncedBalance) = (currency, IERC20(currency).balanceOf(address(this)));
    }

    function settle() external payable returns (uint256 paid) {
        paid = IERC20(_synced).balanceOf(address(this)) - _syncedBalance;
        // forge-lint: disable-next-line(unsafe-typecast)
        _account(_synced, int256(paid));
        _synced = address(0);
    }

    function take(address currency, address to, uint256 amount) external {
        if (msg.sender != locker) revert NotLocker();
        // forge-lint: disable-next-line(unsafe-typecast)
        _account(currency, -int256(amount));
        require(IERC20(currency).transfer(to, amount), "mock: take");
    }

    function _amount0(uint256 a, uint256 b, uint256 l, bool up) private pure returns (uint256) {
        if (up) return Math.ceilDiv(Math.mulDiv(l << 96, b - a, b, Math.Rounding.Ceil), a);
        return Math.mulDiv(l << 96, b - a, b) / a;
    }

    function _amount1(uint256 a, uint256 b, uint256 l, bool up) private pure returns (uint256) {
        return Math.mulDiv(l, b - a, Q96, up ? Math.Rounding.Ceil : Math.Rounding.Floor);
    }
}

