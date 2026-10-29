// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IPoolManagerV4 } from "./MaidMarianLaunchCurve.sol";

// V4's `Hooks.BEFORE_INITIALIZE_FLAG` (bit 13) and the mask of all 14 permission bits of a hook address.
uint160 constant HOOK_BEFORE_INITIALIZE_FLAG = 1 << 13;
uint160 constant HOOK_ALL_FLAGS_MASK = (1 << 14) - 1;

/// What the hook reads from its launcher and from a curve.
interface IMaidMarianLaunchHookReads {
    function isCurve(address curve) external view returns (bool);
    function poolId() external view returns (bytes32);
}

/**
 * @title Maid Marian launch hook
 * @notice The Uniswap V4 hook of every bond pool: only `beforeInitialize`, so the pool is opened by
 * its curve and no one else, at the bond. No fee, no swap or liquidity logic, no owner, no setting.
 * @dev Deployed by its launcher (`LAUNCHER = msg.sender`) with CREATE2, at an address whose low 14
 * bits are `HOOK_BEFORE_INITIALIZE_FLAG` alone: V4 reads a hook's permissions from its address.
 */
contract MaidMarianLaunchHook {
    address public immutable LAUNCHER;
    address public immutable POOL_MANAGER;

    error NotPoolManager();
    error NotLaunchedCurve(address sender);

    constructor(address poolManager) {
        LAUNCHER = msg.sender;
        POOL_MANAGER = poolManager;
    }

    /// @notice The PoolManager's call before it initializes a pool with this hook: passes only when
    /// `sender` is a curve of `LAUNCHER` opening its own pool (`key` is the curve's `poolId()`).
    function beforeInitialize(address sender, IPoolManagerV4.PoolKey calldata key, uint160) external view returns (bytes4) {
        if (msg.sender != POOL_MANAGER) revert NotPoolManager();
        // A few reads per bond: plain `keccak256` for readability.
        // forge-lint: disable-next-line(asm-keccak256)
        if (!IMaidMarianLaunchHookReads(LAUNCHER).isCurve(sender) || IMaidMarianLaunchHookReads(sender).poolId() != keccak256(abi.encode(key))) revert NotLaunchedCurve(sender);
        return this.beforeInitialize.selector;
    }
}
