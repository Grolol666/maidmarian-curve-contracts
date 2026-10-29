// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// The mocks every suite shares. Nothing here imports `src/`: a mock that needs a product
// type (a vault, the Key) is a fixture of one test and lives beside it.

// ------------------------------------------------------------------ tokens ---

/**
 * A minimal ERC-20, standard-compliant `transferFrom`/`transfer` return values
 * included, so `SafeERC20` never has anything to complain about.
 *
 * `decimals` is `immutable` rather than plain storage: USDG's mock is placed
 * at `MaidMarianTradingAgentKey.USDG()`'s address via `vm.etch`, which copies runtime bytecode
 * only, never storage — a regular state variable set in the constructor would
 * read back as 0 at the etched address. An immutable is baked into the
 * bytecode itself, so it survives the etch; `symbol` stays plain storage
 * since nothing asserts on it post-etch. `symbol` is slot 0 on purpose: a test
 * that wants the etched USDG to say its name writes it there with `vm.store`.
 */
contract TokenMock {
    string public symbol;
    string public name;
    // lowercase to match the ERC-20 `decimals()` getter this mock implements
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// A token that can freeze an address, as USDG can (`freeze(address)` on its facet, read on chain
/// 2026-10-19, block 92 604 149): any transfer from or to a frozen address reverts.
contract FreezableTokenMock is TokenMock {
    error AddressFrozen(address account);

    mapping(address => bool) public isFrozen;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) TokenMock(name_, symbol_, decimals_) { }

    function freeze(address account, bool value) external {
        isFrozen[account] = value;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _check(msg.sender, to);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _check(from, to);
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function _check(address from, address to) private view {
        if (isFrozen[from]) revert AddressFrozen(from);
        if (isFrozen[to]) revert AddressFrozen(to);
    }
}

/// Reverts on zero-value transfers, as several real ERC-20s do. Used to prove
/// a lane rebalanced down to zero cannot strand a vault.
contract ZeroRevertingTokenMock is TokenMock {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) TokenMock(name_, symbol_, decimals_) { }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(amount > 0, "zero transfer");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Burns a tenth of every transfer, so the recipient receives less than sent.
contract FeeOnTransferTokenMock is TokenMock {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) TokenMock(name_, symbol_, decimals_) { }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - amount / 10;
        return true;
    }
}

/// Deducts more than `amount` from the *sender* on a plain `transfer` — the
/// shape the vault's exactness check on a push exists to catch, distinct from
/// `FeeOnTransferTokenMock` above, which only shorts the recipient on
/// `transferFrom` (the inbound path already guards).
contract SenderFeeTokenMock is TokenMock {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) TokenMock(name_, symbol_, decimals_) { }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount + amount / 10;
        balanceOf[to] += amount;
        return true;
    }
}

/// A token that can be told to stop answering: `balanceOf`, `transfer`,
/// `symbol` and `decimals` each revert once flagged, the way a paused or
/// upgraded-away token would. A lane on it must still close.
contract BrickableTokenMock {
    mapping(address => uint256) internal bal;
    bool public brickBalance;
    bool public brickTransfer;
    bool public brickMetadata;

    function brick(bool balance_, bool transfer_, bool metadata_) external {
        (brickBalance, brickTransfer, brickMetadata) = (balance_, transfer_, metadata_);
    }

    function mint(address to, uint256 amount) external {
        bal[to] += amount;
    }

    function symbol() external view returns (string memory) {
        require(!brickMetadata, "no symbol");
        return "BRICK";
    }

    function decimals() external view returns (uint8) {
        require(!brickMetadata, "no decimals");
        return 18;
    }

    function balanceOf(address a) external view returns (uint256) {
        require(!brickBalance, "no balance");
        return bal[a];
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!brickTransfer, "no transfer");
        bal[msg.sender] -= amount;
        bal[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        bal[from] -= amount;
        bal[to] += amount;
        return true;
    }
}

/// A `tokenOut` whose `balanceOf` grows on every read - the second read of a
/// call is always higher, so `amountOut >= amountOutMin` passes whatever
/// `data` did on `router`. What the vault's router gate exists to refuse.
contract GrowingBalanceMock {
    function balanceOf(address) external view returns (uint256) {
        return 1e30 - gasleft();
    }

    function symbol() external pure returns (string memory) {
        return "GROW";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// Any other ERC-721, so that "a vault accepts one from its book and from
/// nowhere else" is a claim with something to test it against.
contract StrayNft is ERC721 {
    constructor() ERC721("Stray", "STRAY") { }

    function mintTo(address to, uint256 tokenId) external {
        _safeMint(to, tokenId);
    }
}

// ------------------------------------------------------------- price feeds ---

/// Same shape as `StockTokenLens.t.sol`'s `FeedMock`. The round id is 42 until
/// `setRoundId` moves it - m7m's round sensor waits for it to grow - and
/// `setReverting` makes `latestRoundData` revert, a feed that stopped answering.
contract FeedMock {
    uint8 public decimals;
    int256 private answer;
    uint256 private updatedAt;
    uint80 private roundId = 42;
    bool private reverting;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setRoundId(uint80 roundId_) external {
        roundId = roundId_;
    }

    function setReverting(bool value) external {
        reverting = value;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverting, "mock: feed down");
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

contract RevertingFeedMock {
    fallback() external {
        revert("no");
    }
}

/**
 * Mimics the three reads `MaidMarianPriceRegistry` makes of a real Uniswap V3
 * pool — `token0`/`token1` and `observe` — without reimplementing an AMM.
 * `setAverageTick` sets the two tick cumulatives `observe([1800, 0])` answers
 * directly, chosen so `(tickCumulativeNow - tickCumulativeThen) / 1800 ==
 * avgTick` exactly, which is all the TWAP read ever derives from the pair.
 * `setLiquidity` sets the `secondsPerLiquidityCumulativeX128` the same window
 * gains, `1800 x 2^128 / L` (Uniswap's accrual at a constant in-range L), which
 * is all `MaidMarianEtfPoolDepth` derives from it; by default 1 800, an L of
 * 2^128: deeper than any floor. The registry does not read it.
 */
contract PoolMock {
    address public token0;
    address public token1;
    /// The bag reads this to build a triggered order's path, so the mock has to
    /// answer it like a real pool does.
    uint24 public fee = 3000;
    int56 private tickCumulativeNow;
    bool private reverting;
    uint160 public perLiquidityDelta = 1800;
    /// `slot0()`'s price; 0 (the default) is an uninitialised pool, which prices nothing.
    uint160 public spotSqrtPriceX96;
    /// `slot0()`'s `observationCardinality` / `observationCardinalityNext`: 1 801 each by
    /// default, the least `MaidMarianEtfFactory` lists (`MIN_OBSERVATION_CARDINALITY`), so a pool
    /// of the mock is listable unless a test thins it (`setCardinality`). Nothing else reads them;
    /// `observe` answers by `setNoHistory` alone.
    uint16 public observationCardinality = 1801;
    uint16 public observationCardinalityNext = 1801;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setAverageTick(int24 avgTick) external {
        tickCumulativeNow = int56(avgTick) * 1800;
        reverting = false;
    }

    /// A pool younger than the TWAP window — the registry must not silently
    /// treat this as a price of zero.
    function setNoHistory(bool value) external {
        reverting = value;
    }

    /// Another fee tier, so a test can hold two pools of one pair in one factory.
    function setFee(uint24 fee_) external {
        fee = fee_;
    }

    /// The in-range liquidity held through the whole window; 0 is accrued as 1, as Uniswap does.
    function setLiquidity(uint128 liquidity) external {
        perLiquidityDelta = uint160((uint256(1800) << 128) / (liquidity == 0 ? 1 : liquidity));
    }

    /// The spot a test sets: `slot0()` answers it, seven words as the real pool does.
    function setSpotSqrtPrice(uint160 sqrtPriceX96) external {
        spotSqrtPriceX96 = sqrtPriceX96;
    }

    /// The oracle's size a test sets, as `slot0()` reports it.
    function setCardinality(uint16 current, uint16 next) external {
        (observationCardinality, observationCardinalityNext) = (current, next);
    }

    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 cardinality, uint16 cardinalityNext, uint8 feeProtocol, bool unlocked) {
        return (spotSqrtPriceX96, 0, 0, observationCardinality, observationCardinalityNext, 0, true);
    }

    function observe(uint32[] calldata) external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) {
        require(!reverting, "mock: pool has no history yet");
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = tickCumulativeNow;
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
        secondsPerLiquidityCumulativeX128s[1] = perLiquidityDelta;
    }
}

/**
 * A Uniswap V3 factory's `getPool(tokenA, tokenB, fee)` - either order, as the real
 * one answers - over the pools a test registers; the zero address otherwise.
 */
contract UniswapV3FactoryMock {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    /// Registers `pool` under its own `token0`, `token1` and `fee`.
    function setPool(PoolMock pool) external {
        (address a, address b, uint24 f) = (pool.token0(), pool.token1(), pool.fee());
        getPool[a][b][f] = address(pool);
        getPool[b][a][f] = address(pool);
    }
}

// --------------------------------------------------------------- registries ---

/// Registries that are not one: the first reverts on everything, the second
/// answers whatever bytes a test set - one word, three words with a dirty
/// flag, a real-looking answer - to any call.
contract RevertingRegistryMock {
    fallback() external {
        revert("not a registry");
    }
}

contract GarbageRegistryMock {
    bytes public answer;

    function setAnswer(bytes calldata answer_) external {
        answer = answer_;
    }

    fallback() external {
        bytes memory out = answer;
        assembly ("memory-safe") {
            return(add(out, 32), mload(out))
        }
    }
}

// ------------------------------------------------------------------- venues ---

/**
 * A venue, in the only sense the vault has of one: an address that takes a
 * call, pulls `tokenIn` by allowance and delivers `tokenOut`. It deliberately
 * mimics no real router — the vault forwards `(router, data)` and knows
 * neither the venue's ABI nor what a path would be, so there is no shape to
 * be faithful to. `amountOut = amountIn * rate`, minted to the caller the way
 * a pool would deliver it.
 */
contract VenueMock {
    uint256 public rateNumerator;
    uint256 public rateDenominator;

    function setRate(uint256 numerator, uint256 denominator) external {
        rateNumerator = numerator;
        rateDenominator = denominator;
    }

    /// @dev 1:1 until `setRate` says otherwise.
    function _rate() private view returns (uint256 numerator, uint256 denominator) {
        return rateDenominator == 0 ? (1, 1) : (rateNumerator, rateDenominator);
    }

    /// @dev Pulls by allowance and pays the caller, which is all a vault's
    /// swap leg needs a venue to do. The selector and the argument list are
    /// this mock's own - the vault does not know either, it forwards the
    /// calldata the test handed it.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMinimum) external {
        TokenMock(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        (uint256 numerator, uint256 denominator) = _rate();
        uint256 amountOut = amountIn * numerator / denominator;
        require(amountOut >= amountOutMinimum, "mock: too little received");

        TokenMock(tokenOut).mint(msg.sender, amountOut);
    }
}

/// A venue that hands tokens over for nothing: mints `tokenOut` to the
/// caller and pulls no `tokenIn` - a gift dressed as a swap.
contract GiftRouterMock {
    function gift(address tokenOut, uint256 amount) external {
        TokenMock(tokenOut).mint(msg.sender, amount);
    }
}

// A Uniswap universal-router-shaped mock, the book's: pays out at a settable
// rate from its own balance, reading tokenOut off the end of the path.
contract RouterMock {
    uint256 public rate = 1e18;
    bytes public lastPath;
    bool public payNothing;

    function setRate(uint256 value) external {
        rate = value;
    }

    function setPayNothing(bool value) external {
        payNothing = value;
    }

    function execute(bytes calldata, bytes[] calldata inputs, uint256) external payable {
        (address to, uint256 amountIn,, bytes memory path,,) = abi.decode(inputs[0], (address, uint256, uint256, bytes, bool, uint256[]));
        lastPath = path;
        if (payNothing) return;

        address tokenOut;
        assembly {
            tokenOut := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
        }
        IERC20(tokenOut).transfer(to, (amountIn * rate) / 1e18);
    }
}

// Takes escrow and pays out of its own inventory, the shape an RFQ filler
// has. The switches are the ways a fill can be wrong, for fillOrder's own
// checks to catch.
contract FillerMock {
    uint256 public rateNumerator = 1;
    uint256 public rateDenominator = 1;
    uint256 public spendBps = 10_000;
    bool public payNothing;

    function setRate(uint256 numerator, uint256 denominator) external {
        rateNumerator = numerator;
        rateDenominator = denominator;
    }

    // Under 10,000 leaves escrow stranded in an order about to be marked filled.
    function setSpendBps(uint256 bps) external {
        spendBps = bps;
    }

    function setPayNothing(bool value) external {
        payNothing = value;
    }

    function fill(address tokenIn, address tokenOut, uint256 amountIn) external {
        uint256 taken = (amountIn * spendBps) / 10_000;
        if (taken > 0) IERC20(tokenIn).transferFrom(msg.sender, address(this), taken);
        if (payNothing) return;
        IERC20(tokenOut).transfer(msg.sender, (amountIn * rateNumerator) / rateDenominator);
    }
}

// The Universal Router as the gate feeds it: pre-funded. `execute` finds
// `amountIn` of `tokenIn` already on its own balance (`payerIsUser: false` -
// nothing is pulled from anyone), keeps `takeBps` of it, pays `tokenOut` to
// the recipient at a settable rate out of its own inventory, and sends the
// untaken rest back to `msg.sender` - what a trailing `SWEEP(tokenIn, gate)`
// does on the real router. `tokenOut == address(0)` pays native ETH, the way
// the PoolManager settles a v4 route that ends in ETH. `reenter` makes it
// call the caller's `swap` back mid-execute and record the answer, the one
// way a router could try to run the gate twice on one funding.
//
// `setPairRate(tokenIn, tokenOut, rate)` overrides `rate` for one direction of
// one pair, so a fund trading seven tokens against USDG can be priced leg by
// leg; 0 falls back to `rate`.
//
// The input is decoded as `V3_SWAP_EXACT_IN`'s five fields (a sixth, which the
// older tests append, is ignored, as the real router ignores it), and
// `amountOutMin` is enforced as the real router does (`V3TooLittleReceived`);
// `lastAmountOutMin` records the one the last call carried.
//
// `commands == 0x10` reads a `V4_SWAP` instead, as the ETF v3 writes it:
// `SWAP_EXACT_IN_SINGLE(key, zeroForOne, amountIn, amountOutMinimum, minHopPriceX36, hookData)`,
// `SETTLE(tokenIn, amount, payerIsUser)`, `TAKE(tokenOut, recipient, amount)`;
// `lastHooks` records the key's hooks; a key whose hooks are `revertingHooks` reverts, as a hook that refuses the swap. `setPoolRate` prices one pool - a V3 single hop at its fee, a
// V4 key at its fee / tick spacing - over `pairRate`, so a test can hold pools of one pair at different
// prices; `poolManager()` is a `PoolManagerMock`, as the real router names its V4 PoolManager. With `record` set, `lastCommands` /
// `lastInput` keep the last call's bytes. With a `sink` set, the input actually swapped leaves the
// router for it, as it leaves the real one for the pool. `keepBps` keeps that
// part of the input on the router, unswapped; `gift` sends extra tokens to the
// caller once, during the next swap, as a route sweeping into it would; `probe` makes a
// static call mid-swap and keeps the answer.
struct V4KeyMock {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct V4SingleMock {
    V4KeyMock poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes hookData;
}

/// The V4 PoolManager as the factory reads it: `extsload` of a pool's first state word, at v4's
/// `StateLibrary` slot `keccak256(keccak256(key), 6)`, whose low 160 bits are `sqrtPriceX96`.
/// `initialize` writes that word for any key, hooked or not.
contract PoolManagerMock {
    mapping(bytes32 slot => bytes32) private _slots;

    function initialize(V4KeyMock memory key, uint160 sqrtPriceX96) external {
        bytes32 id = keccak256(abi.encode(key));
        _slots[keccak256(abi.encode(id, uint256(6)))] = bytes32(uint256(sqrtPriceX96));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }
}

contract UniversalRouterMock {
    error V3TooLittleReceived();

    address public immutable poolManager = address(new PoolManagerMock());
    mapping(bytes32 pool => uint256) public poolRate;

    uint256 public lastAmountOutMin;
    bytes public lastCommands;
    bytes public lastInput;
    address public lastHooks;
    address public revertingHooks;
    address public sink;
    uint256 public keepBps;
    address public giftToken;
    uint256 public giftAmount;
    address public probeTarget;
    bytes public probeData;
    bytes public probeAnswer;
    bool public record;
    uint256 public rate = 1e18;
    mapping(address tokenIn => mapping(address tokenOut => uint256)) public pairRate;
    uint256 public takeBps = 10_000;
    bool public payNothing;
    bool public reenter;
    bytes public reentryRevert;

    function setRate(uint256 value) external {
        rate = value;
    }

    function setPairRate(address tokenIn, address tokenOut, uint256 value) external {
        pairRate[tokenIn][tokenOut] = value;
    }

    /// The rate of one pool: `v4` false, the V3 pool at `fee` (`tickSpacing` 0); `v4` true, the hookless key.
    function setPoolRate(address tokenIn, address tokenOut, bool v4, uint24 fee, int24 tickSpacing, uint256 value) external {
        poolRate[keccak256(abi.encode(tokenIn, tokenOut, v4, fee, tickSpacing))] = value;
    }

    function setRevertingHooks(address hooks) external {
        revertingHooks = hooks;
    }

    function setTakeBps(uint256 bps) external {
        takeBps = bps;
    }

    function setPayNothing(bool value) external {
        payNothing = value;
    }

    function setReenter(bool value) external {
        reenter = value;
    }

    function setSink(address value) external {
        sink = value;
    }

    function setKeepBps(uint256 bps) external {
        keepBps = bps;
    }

    function setGift(address token, uint256 amount) external {
        (giftToken, giftAmount) = (token, amount);
    }

    function setRecord(bool value) external {
        record = value;
    }

    /// A static call made mid-swap, its answer kept: what a callback inside a route could read.
    function setProbe(address target, bytes calldata data) external {
        (probeTarget, probeData) = (target, data);
    }

    receive() external payable { }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        if (record) (lastCommands, lastInput) = (commands, inputs[0]);
        bool v4 = commands.length == 1 && commands[0] == 0x10;
        (address to, uint256 amountIn, uint256 amountOutMin, address tokenIn, address tokenOut, bytes32 pool) = v4 ? _readV4(inputs[0]) : _readV3(inputs[0]);
        lastAmountOutMin = amountOutMin;
        require(IERC20(tokenIn).balanceOf(address(this)) >= amountIn, "mock: not funded");
        if (probeTarget != address(0)) {
            (, bytes memory answer) = probeTarget.staticcall(probeData);
            probeAnswer = answer;
        }
        uint256 gift = giftAmount;
        if (gift > 0) {
            giftAmount = 0;
            IERC20(giftToken).transfer(msg.sender, gift);
        }
        amountIn -= (amountIn * keepBps) / 10_000;

        if (reenter) {
            (bool ok, bytes memory ret) =
                msg.sender.call(abi.encodeWithSignature("swap(address,uint256,address,uint256,bytes,bytes[],uint256)", tokenIn, amountIn, tokenOut, 0, commands, inputs, deadline));
            reentryRevert = ok ? bytes("") : ret;
        }

        uint256 taken = (amountIn * takeBps) / 10_000;
        if (taken < amountIn) IERC20(tokenIn).transfer(msg.sender, amountIn - taken);
        if (sink != address(0)) IERC20(tokenIn).transfer(sink, taken);
        if (payNothing) return;

        uint256 r = poolRate[pool];
        if (r == 0) r = pairRate[tokenIn][tokenOut];
        uint256 out = (taken * (r == 0 ? rate : r)) / 1e18;
        if (out < amountOutMin) revert V3TooLittleReceived();
        if (tokenOut == address(0)) {
            (bool paid,) = to.call{ value: out }("");
            require(paid, "mock: native refused");
        } else {
            IERC20(tokenOut).transfer(to, out);
        }
    }

    function _readV3(bytes calldata input) private pure returns (address to, uint256 amountIn, uint256 amountOutMin, address tokenIn, address tokenOut, bytes32 pool) {
        bytes memory path;
        bool payerIsUser;
        (to, amountIn, amountOutMin, path, payerIsUser) = abi.decode(input, (address, uint256, uint256, bytes, bool));
        require(!payerIsUser, "mock: the router is pre-funded");
        uint24 fee;
        assembly {
            tokenIn := shr(96, mload(add(path, 32)))
            fee := shr(232, mload(add(path, 52)))
            tokenOut := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
        }
        if (path.length == 43) pool = keccak256(abi.encode(tokenIn, tokenOut, false, fee, int24(0)));
    }

    function _readV4(bytes calldata input) private returns (address to, uint256 amountIn, uint256 amountOutMin, address tokenIn, address tokenOut, bytes32 pool) {
        (bytes memory actions, bytes[] memory params) = abi.decode(input, (bytes, bytes[]));
        require(keccak256(actions) == keccak256(hex"060b0e") && params.length == 3, "mock: not swap, settle, take");
        V4SingleMock memory s = abi.decode(params[0], (V4SingleMock));
        lastHooks = s.poolKey.hooks;
        require(s.poolKey.hooks == address(0) || s.poolKey.hooks != revertingHooks, "mock: the hook reverts");
        (tokenIn, tokenOut) = s.zeroForOne ? (s.poolKey.currency0, s.poolKey.currency1) : (s.poolKey.currency1, s.poolKey.currency0);
        (amountIn, amountOutMin) = (s.amountIn, s.amountOutMinimum);
        (address settled, uint256 settleAmount, bool payerIsUser) = abi.decode(params[1], (address, uint256, bool));
        require(settled == tokenIn && settleAmount == amountIn && !payerIsUser, "mock: settle from the router");
        address taken;
        uint256 takeAmount;
        (taken, to, takeAmount) = abi.decode(params[2], (address, address, uint256));
        require(taken == tokenOut && takeAmount == 0, "mock: take the whole output");
        if (s.poolKey.hooks == address(0)) pool = keccak256(abi.encode(tokenIn, tokenOut, true, s.poolKey.fee, s.poolKey.tickSpacing));
    }
}

// ----------------------------------------------------------------- renderer ---

/// Matches `IMaidMarianTradingAgentRenderer`'s one function with an output no real
/// renderer would produce, so `setRenderer` swapping it in is unmistakable.
contract AltRendererMock {
    function tokenURI(uint256, address, uint8) external pure returns (string memory) {
        return "alt-renderer-output";
    }
}
