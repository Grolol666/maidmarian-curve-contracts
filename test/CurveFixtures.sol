// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TickMath } from "../src/uniswap/TickMath.sol";
import { IPoolManagerV4 } from "../src/MaidMarianLaunchCurve.sol";
import { Vm } from "forge-std/Vm.sol";

/// A thresholds' list of one entry, for the launcher's `setTokenQuote` and `setEtfThresholds`.
function oneThreshold(uint256 threshold) pure returns (uint256[] memory list) {
    list = new uint256[](1);
    list[0] = threshold;
}

interface IUnlockCallbackV4 {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// A BalanceDelta: amount0 in the high 128 bits, amount1 in the low, as Uniswap V4 packs it.
function packDelta(int256 a0, int256 a1) pure returns (int256) {
    // forge-lint: disable-next-line(unsafe-typecast)
    return int256((uint256(a0) << 128) | uint256(uint128(int128(a1))));
}

function deltaAmounts(int256 d) pure returns (int256 a0, int256 a1) {
    a0 = d >> 128;
    // forge-lint: disable-next-line(unsafe-typecast)
    a1 = int256(int128(d));
}

/**
 * A Uniswap V4 PoolManager for the offline curve tests: `initialize`, `unlock` with V4's flash
 * accounting (`sync` / `settle` / `take`, every delta zero at the end), `modifyLiquidity` with V4's
 * amount formulas (rounded up when the caller pays), and exact-in `swap` on one range of liquidity
 * per pool (the bond's full range) with its fee kept for the position, a swap on no liquidity moving
 * the price to its limit for free. Storage slot 0 is `PoolManagerMock`'s, so it can be etched at the
 * router's `poolManager()` and the pools already initialised there stay. Proves the curve's side of
 * the calls; that the deployed PoolManager agrees is `MaidMarianLaunchCurve.fork.t.sol`.
 */
contract V4PoolManagerMock {
    mapping(bytes32 slot => bytes32) private _slots;
    mapping(bytes32 id => uint256) public liquidity;
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
            // forge-lint: disable-next-line(unsafe-typecast)
            d0 = -int256(_amount0(sqrtP, upper, l, true));
            // forge-lint: disable-next-line(unsafe-typecast)
            d1 = -int256(_amount1(lower, sqrtP, l, true));
            liquidity[id] += l;
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

/**
 * Trades on, or adds liquidity to, a V4 pool through the PoolManager directly: one exact-in swap
 * (`swapExactIn`) or one position (`addLiquidity`), paid from this contract's own balance, the
 * output kept. Works on the mock and on the deployed PoolManager alike.
 */
contract V4Trader is IUnlockCallbackV4 {
    IPoolManagerV4 public immutable PM;

    constructor(IPoolManagerV4 pm) {
        PM = pm;
    }

    function swapExactIn(IPoolManagerV4.PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit) external returns (int256 d) {
        d = abi.decode(PM.unlock(abi.encode(uint8(1), key, zeroForOne, amountIn, limit, int24(0), int24(0), uint256(0))), (int256));
    }

    function addLiquidity(IPoolManagerV4.PoolKey memory key, int24 lower, int24 upper, uint256 l) external returns (int256 d) {
        d = abi.decode(PM.unlock(abi.encode(uint8(2), key, false, uint256(0), uint160(0), lower, upper, l)), (int256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM), "trader: not the PoolManager");
        (uint8 op, IPoolManagerV4.PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit, int24 lower, int24 upper, uint256 l) =
            abi.decode(data, (uint8, IPoolManagerV4.PoolKey, bool, uint256, uint160, int24, int24, uint256));
        int256 d;
        if (op == 1) {
            // forge-lint: disable-next-line(unsafe-typecast)
            d = PM.swap(key, IPoolManagerV4.SwapParams({ zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit }), "");
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            (d,) = PM.modifyLiquidity(key, IPoolManagerV4.ModifyLiquidityParams({ tickLower: lower, tickUpper: upper, liquidityDelta: int256(l), salt: bytes32(0) }), "");
        }
        (int256 a0, int256 a1) = deltaAmounts(d);
        _settle(key.currency0, a0);
        _settle(key.currency1, a1);
        return abi.encode(d);
    }

    function _settle(address currency, int256 amount) private {
        if (amount < 0) {
            PM.sync(currency);
            // forge-lint: disable-next-line(unsafe-typecast,erc20-unchecked-transfer)
            IERC20(currency).transfer(address(PM), uint256(-amount));
            PM.settle();
        } else if (amount > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            PM.take(currency, address(this), uint256(amount));
        }
    }
}

/// Wrapped ether for the offline suite: `deposit` mints what is sent, `withdraw` burns and sends ether
/// back with all the gas, as the chain's WETH does (`MaidMarianLauncherScenarios.fork.t.sol`).
contract WethMock {
    // The ERC-20 getters, lowercase as the standard names them.
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant name = "Wrapped Ether";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant symbol = "WETH";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{ value: amount }("");
        require(ok, "mock: withdraw");
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function totalSupply() external view returns (uint256) {
        return address(this).balance;
    }
}

/// The `sqrtPriceX96` pool `id` was opened at, from the PoolManager `pm`'s `Initialize` in `logs` (0 if none):
/// the bond's price before its one swap moves it.
function initializedAt(Vm.Log[] memory logs, address pm, bytes32 id) pure returns (uint160 sqrtP) {
    bytes32 topic = keccak256("Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)");
    for (uint256 i = 0; i < logs.length; i++) {
        if (logs[i].emitter == pm && logs[i].topics[0] == topic && logs[i].topics[1] == id) (,,, sqrtP,) = abi.decode(logs[i].data, (uint24, int24, address, uint160, int24));
    }
}
