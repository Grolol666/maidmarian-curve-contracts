// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// The clone's arguments: the name and the symbol, each a length byte and its bytes.
function tokenCloneArgs(string memory name_, string memory symbol_) pure returns (bytes memory) {
    // The launcher caps the name at 64 bytes and the symbol at 11, so each length fits its byte.
    // forge-lint: disable-next-line(unsafe-typecast)
    return abi.encodePacked(uint8(bytes(name_).length), name_, uint8(bytes(symbol_).length), symbol_);
}

// What the token reads from its curve.
interface ILaunchCurveBonded {
    function bonded() external view returns (bool);
}

/**
 * @title Maid Marian token
 * @notice A plain ERC-20, 18 decimals, its whole supply minted at launch to its bonding curve; no
 * owner, no mint after that. Any holder burns his own (`burn`). A holder sells to the curve without
 * an approve (`takeForSale`); the usual `approve` and `transferFrom` work as on any ERC-20.
 * @dev Until its curve bonds, only the curve can send the token to the Uniswap V4 PoolManager, so no
 * V4 pool holds it before the curve opens its own. An EIP-1167 clone, its name and symbol appended to
 * its code, initialized by the launcher in the launch; the implementation is locked.
 */
contract MaidMarianToken is ERC20 {
    uint256 private constant CLONE_CODE_BYTES = 0x2d;

    address private immutable LAUNCHER;
    address private immutable POOL_MANAGER;

    address private _curve;
    bool private _initialized;

    error NotLauncher();
    error AlreadyInitialized();
    error NotTradableYet();
    error NotCurve();

    /// The implementation, deployed by the launcher. Locked: never initialized.
    constructor(address poolManager) ERC20("", "") {
        LAUNCHER = msg.sender;
        POOL_MANAGER = poolManager;
        _initialized = true;
    }

    /// @notice Called once, by the launcher, in the launch: the whole `supply` to `curve`.
    function initialize(address curve, uint256 supply) external {
        if (msg.sender != LAUNCHER) revert NotLauncher();
        if (_initialized) revert AlreadyInitialized();
        (_curve, _initialized) = (curve, true);
        _mint(curve, supply);
    }

    /// @notice Move `amount` of `holder`'s tokens to the curve with no allowance: the curve's, for the sale
    /// `holder` is making.
    /// @dev Only the curve can call it, and the curve calls it from its `sell` alone, with its own
    /// `msg.sender` as `holder`, never an address it was given: the holder is whoever called `sell`, so he
    /// moves his own tokens and nobody else's. The curve is the clone of the launcher's implementation
    /// that `initialize` recorded; the launcher itself has no such right.
    function takeForSale(address holder, uint256 amount) external {
        if (msg.sender != _curve) revert NotCurve();
        _transfer(holder, msg.sender, amount);
    }

    /// @notice Burn `amount` of the caller's tokens.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function name() public view override returns (string memory) {
        return _argString(0);
    }

    function symbol() public view override returns (string memory) {
        return _argString(1 + _argByte(0));
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to == POOL_MANAGER) {
            address curve = _curve;
            if (from != curve && !ILaunchCurveBonded(curve).bonded()) revert NotTradableYet();
        }
        super._update(from, to, value);
    }

    function _argByte(uint256 pos) private view returns (uint256 v) {
        assembly ("memory-safe") {
            extcodecopy(address(), 0, add(CLONE_CODE_BYTES, pos), 32)
            v := shr(248, mload(0))
        }
    }

    /// The string whose length byte is at `pos` in the clone's arguments.
    function _argString(uint256 pos) private view returns (string memory s) {
        uint256 len = _argByte(pos);
        s = new string(len);
        assembly ("memory-safe") {
            extcodecopy(address(), add(s, 32), add(CLONE_CODE_BYTES, add(pos, 1)), len)
        }
    }
}
