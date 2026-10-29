// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { MaidMarianEtfFactory } from "../src/MaidMarianEtfFactory.sol";
import { MaidMarianTokenLauncher, IWrappedNative } from "../src/MaidMarianTokenLauncher.sol";
import { MaidMarianLaunchHook, HOOK_BEFORE_INITIALIZE_FLAG, HOOK_ALL_FLAGS_MASK } from "../src/MaidMarianLaunchHook.sol";

// The address `launcher` deploys its hook at with `salt` (CREATE2, the hook's constructor argument
// the PoolManager).
function launchHookAddress(address launcher, address poolManager, bytes32 salt) pure returns (address) {
    // forge-lint: disable-next-line(asm-keccak256)
    bytes32 initCodeHash = keccak256(abi.encodePacked(type(MaidMarianLaunchHook).creationCode, abi.encode(poolManager)));
    // forge-lint: disable-next-line(asm-keccak256)
    return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), launcher, salt, initCodeHash)))));
}

// The first salt from 0 whose hook address has `beforeInitialize` alone among V4's 14 permission bits:
// one address in 16 384 on average. Returns the salt and the tries. One buffer, the salt written in
// place, so the search allocates no memory per try.
function mineLaunchHookSalt(address launcher, address poolManager) pure returns (bytes32 salt, uint256 tries) {
    // forge-lint: disable-next-line(asm-keccak256)
    bytes32 initCodeHash = keccak256(abi.encodePacked(type(MaidMarianLaunchHook).creationCode, abi.encode(poolManager)));
    bytes memory buf = abi.encodePacked(bytes1(0xff), launcher, salt, initCodeHash);
    while (true) {
        // The salt sits after the length word, 0xff and the launcher: 32 + 1 + 20 bytes in.
        assembly ("memory-safe") {
            mstore(add(buf, 53), salt)
        }
        // forge-lint: disable-next-line(asm-keccak256)
        if (uint160(uint256(keccak256(buf))) & HOOK_ALL_FLAGS_MASK == HOOK_BEFORE_INITIALIZE_FLAG) break;
        salt = bytes32(uint256(salt) + 1);
    }
    tries = uint256(salt) + 1;
}

/// The launcher's deploy steps, shared by `DeployTokenLauncher` and `DeployLaunchStack`.
abstract contract TokenLauncherDeploy is Script {
    // WETH on chain 4663.
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    /// The least first buy of a launch on each: 5 USDG, 0.002 WETH.
    uint256 internal constant USDG_MIN_FIRST_BUY = 5e6;
    uint256 internal constant WETH_MIN_FIRST_BUY = 0.002e18;

    /// The bond targets a launch picks from: USDG 1 000 / 5 000 / 8 000 / 15 000 / 20 000 / 25 000 / 30 000.
    function _usdgThresholds() internal pure returns (uint256[] memory t) {
        t = new uint256[](7);
        (t[0], t[1], t[2], t[3], t[4], t[5], t[6]) = (1000e6, 5000e6, 8000e6, 15_000e6, 20_000e6, 25_000e6, 30_000e6);
    }

    /// WETH 0.5 / 1 / 2 / 4 / 8.
    function _wethThresholds() internal pure returns (uint256[] memory t) {
        t = new uint256[](5);
        (t[0], t[1], t[2], t[3], t[4]) = (0.5e18, 1e18, 2e18, 4e18, 8e18);
    }

    /// ETF curves 100 / 1 000 / 5 000 / 8 000 / 15 000 / 20 000 / 25 000 / 30 000 shares (at most 8).
    function _etfThresholds() internal pure returns (uint256[] memory t) {
        t = new uint256[](8);
        (t[0], t[1], t[2], t[3], t[4], t[5], t[6], t[7]) = (100e18, 1000e18, 5000e18, 8000e18, 15_000e18, 20_000e18, 25_000e18, 30_000e18);
    }

    function _sameList(uint256[] memory a, uint256[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    /// Inside the broadcast by `owner`: mines the hook's salt for the address the launcher is about to be
    /// created at (the broadcaster's next CREATE), deploys it over `etfFactory` with `WETH`, lists USDG and
    /// WETH with their thresholds and least first buys, and sets the ETF curves' thresholds.
    function _deployLauncher(MaidMarianEtfFactory etfFactory, address owner, address poolManager) internal returns (MaidMarianTokenLauncher launcher, bytes32 salt) {
        address expected = vm.computeCreateAddress(owner, vm.getNonce(owner));
        uint256 t0 = vm.unixTime();
        uint256 tries;
        (salt, tries) = mineLaunchHookSalt(expected, poolManager);
        console.log("hook salt", vm.toString(salt));
        console.log("  tries", tries, "ms", vm.unixTime() - t0);
        launcher = new MaidMarianTokenLauncher(etfFactory, owner, IWrappedNative(WETH), salt);
        require(address(launcher) == expected, "check: the launcher is not at the address the salt was mined for");
        launcher.setTokenQuote(address(etfFactory.USDG()), true, false, _usdgThresholds(), USDG_MIN_FIRST_BUY);
        launcher.setTokenQuote(WETH, true, false, _wethThresholds(), WETH_MIN_FIRST_BUY);
        launcher.setEtfThresholds(_etfThresholds());
    }

    /// After the broadcast: the read-backs, and every address and constructor argument to verify. The owner
    /// is never printed: it is the launcher's second constructor argument.
    function _checkLauncher(MaidMarianTokenLauncher launcher, MaidMarianEtfFactory etfFactory, address owner, bytes32 salt) internal view {
        address usdg = address(etfFactory.USDG());
        address poolManager = etfFactory.POOL_MANAGER();
        require(launcher.owner() == owner, "check: the owner is not the broadcaster");
        require(_sameList(launcher.quoteThresholds(usdg), _usdgThresholds()) && _sameList(launcher.quoteThresholds(WETH), _wethThresholds()), "check: quotes");
        require(launcher.quoteMinFirstBuy(usdg) == USDG_MIN_FIRST_BUY && launcher.quoteMinFirstBuy(WETH) == WETH_MIN_FIRST_BUY, "check: least first buys");
        require(launcher.quotePool(WETH) != address(0) && address(launcher.WETH()) == WETH, "check: WETH");
        require(_sameList(launcher.etfThresholds(), _etfThresholds()), "check: ETF thresholds");
        require(address(launcher.CURVE_IMPLEMENTATION().FACTORY()) == address(launcher), "check: the curve implementation is not the launcher's");
        require(address(launcher.POOL_MANAGER()) == poolManager && address(launcher.etfFactory()) == address(etfFactory), "check: PoolManager, ETF factory");
        require(address(launcher.HOOK()) == launchHookAddress(address(launcher), poolManager, salt), "check: hook address");
        require(launcher.HOOK().LAUNCHER() == address(launcher) && launcher.HOOK().POOL_MANAGER() == poolManager, "check: hook");
        require(launcher.CURVE_IMPLEMENTATION().HOOK() == address(launcher.HOOK()), "check: the curve implementation's hook");
        console.log("WETH pool", launcher.quotePool(WETH));
        console.log("token launcher", address(launcher));
        console.log("  constructor args, the owner second (the broadcaster, not printed):");
        console.log("    etfFactory", address(etfFactory));
        console.log("    weth", WETH);
        console.log("    hookSalt", vm.toString(salt));
        console.log("curve implementation", address(launcher.CURVE_IMPLEMENTATION()));
        console.log("  constructor args", vm.toString(abi.encode(usdg, poolManager, address(launcher.HOOK()))));
        console.log("hook", address(launcher.HOOK()));
        console.log("  constructor args", vm.toString(abi.encode(poolManager)));
        console.log(string.concat("DEPLOYED MaidMarianTokenLauncher ", vm.toString(address(launcher))));
    }
}

/**
 * @title DeployTokenLauncher
 * @notice Deploys `MaidMarianTokenLauncher` on the real chain (4663) over
 * the deployed ETF factory v4 `0x1854…7AAA` and the chain's WETH, the broadcaster as owner: he receives the launch fees (0.0005 ETH,
 * `setLaunchFee`) and claims the protocol's 30 % of every curve fee and the 30 % each bond books to it.
 * The launcher's constructor deploys the curves' implementation `CURVE_IMPLEMENTATION`, locked (each
 * launch's token is a contract of its own, created by its curve), and the bond pools' hook `HOOK` with CREATE2: the script mines
 * its salt for the launcher's address (the broadcaster's next CREATE) before deploying, and logs the
 * tries and the time. It logs every address and constructor argument for verification. Lists two quotes
 * with their USDG pools (`setTokenQuote` finds them), each with the bond targets a launch picks from: USDG
 * 1 000 / 5 000 / 8 000 / 15 000 / 20 000 / 25 000 / 30 000 with a first buy of 5 USDG at least, WETH 0.5 / 1 / 2 / 4 / 8
 * with 0.002 WETH at least; stock tokens are listed later by the owner. `launchWithEtf` picks from
 * 100 / 1 000 / 5 000 / 8 000 / 15 000 / 20 000 / 25 000 / 30 000 shares (`setEtfThresholds`). The launcher deployed
 * before keeps running for its own curves; this one is a new address with its own hook. To run:
 *
 *   ETF_FACTORY=0x1854fB4dE64515d8050e7B48D8d8Af2aBac67AAA \
 *   forge script script/DeployTokenLauncher.s.sol --rpc-url hood --code-size-limit 98304 [--broadcast]
 *
 * Without `--broadcast`, everything runs against a fork. The owner is never printed; the last line
 * is `DEPLOYED MaidMarianTokenLauncher <address>`.
 */
contract DeployTokenLauncher is TokenLauncherDeploy {
    address internal constant EXPECTED_ETF_FACTORY = 0x1854fB4dE64515d8050e7B48D8d8Af2aBac67AAA;

    function run() external returns (MaidMarianTokenLauncher launcher) {
        require(block.chainid == 4663, "real chain is 4663");
        MaidMarianEtfFactory etfFactory = MaidMarianEtfFactory(vm.envAddress("ETF_FACTORY"));
        require(address(etfFactory) == EXPECTED_ETF_FACTORY, "ETF_FACTORY is not the deployed ETF factory v4 0x1854...7AAA");

        address owner = _broadcast();
        bytes32 salt;
        (launcher, salt) = _deployLauncher(etfFactory, owner, etfFactory.POOL_MANAGER());
        vm.stopBroadcast();
        _checkLauncher(launcher, etfFactory, owner, salt);
    }

    function _broadcast() private returns (address sender) {
        string memory key = vm.envOr("PRIVATE_KEY", string(""));
        if (bytes(key).length == 0) vm.startBroadcast();
        else vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        (, sender,) = vm.readCallers();
    }
}
