// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IPoolManagerV4 } from "./MaidMarianLaunchCurve.sol";

// V4's `Hooks.BEFORE_INITIALIZE_FLAG` (bit 13) and the mask of all 14 permission bits of a hook address.
uint160 constant HOOK_BEFORE_INITIALIZE_FLAG = 1 << 13;
uint160 constant HOOK_ALL_FLAGS_MASK = (1 << 14) - 1;

interface IMaidMarianLaunchHookReads {
    function isCurve(address curve) external view returns (bool);
    function isBondPool(bytes32 id) external view returns (bool);
}

/**
 * @title Maid Marian launch hook
 * @notice The V4 hook of every bond pool: only `beforeInitialize`, so only its curve opens a pool.
 * @dev V4 reads a hook's permissions from its address: deployed at one whose low 14 bits are
 * `HOOK_BEFORE_INITIALIZE_FLAG` alone.
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

    /// @notice Passes only a curve of `LAUNCHER` opening one of its own bond pools.
    function beforeInitialize(address sender, IPoolManagerV4.PoolKey calldata key, uint160) external view returns (bytes4) {
        if (msg.sender != POOL_MANAGER) revert NotPoolManager();
        // forge-lint: disable-next-line(asm-keccak256)
        if (!IMaidMarianLaunchHookReads(LAUNCHER).isCurve(sender) || !IMaidMarianLaunchHookReads(sender).isBondPool(keccak256(abi.encode(key)))) revert NotLaunchedCurve(sender);
        return this.beforeInitialize.selector;
    }
}
