// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { StorageSlot } from "@openzeppelin/contracts/utils/StorageSlot.sol";
import { IUniversalRouter } from "./MaidMarianSevenMagnificent.sol";
import {
    SOURCE_NONE,
    ETF_V3_CREATOR_MANAGEMENT_FEE_BPS,
    ETF_V3_PROTOCOL_MANAGEMENT_FEE_BPS,
    ETF_V3_TOLERANCE_BPS,
    ETF_V3_PROTOCOL_CUT_BPS,
    ETF_V3_PROTOCOL_MIN_ENTRY_BPS,
    ETF_V3_ARGS_LEG_COUNT,
    ETF_V3_ARGS_LEGS,
    ETF_V3_ARGS_LEG_BYTES
} from "./MaidMarianEtfV3.sol";

/// Bounds of every creator-chosen parameter, both inclusive, the v3's: read by the ETF's `initialize` and
/// the factory's `paramBounds()`. `nonMinterPenaltyBps` is also capped at 10 000 - `exitFeeBps`, and
/// `earlyPenaltyBps` at `nonMinterPenaltyBps`, so a transfer to a fresh address never pays less.
function etfV4ParamBounds() pure returns (MaidMarianEtfV4.Params memory lo, MaidMarianEtfV4.Params memory hi) {
    lo = MaidMarianEtfV4.Params({ entryFeeBps: 0, exitFeeBps: 0, holdPeriod: 0, earlyPenaltyBps: 0, nonMinterPenaltyBps: 0, rebalanceBandBps: 10, rebalanceMinInterval: 0 });
    hi = MaidMarianEtfV4.Params({ entryFeeBps: 500, exitFeeBps: 500, holdPeriod: 30 days, earlyPenaltyBps: 5000, nonMinterPenaltyBps: 10_000, rebalanceBandBps: 5000, rebalanceMinInterval: 24 hours });
}

/// The clone arguments of an ETF, packed as the v3's: the seven `Params` fields (2, 2, 4, 2, 2, 2, 4
/// bytes), the leg count (1), each leg's token, bps and decimals (20, 2, 1), then the name and the
/// symbol, each a length byte and its bytes. The factory caps the name at 64 bytes, the symbol at 11
/// and the legs at 10, so every length fits its byte.
function etfV4CloneArgs(string memory name_, string memory symbol_, MaidMarianEtfV4.LegInit[] memory legs_, MaidMarianEtfV4.Params memory p) pure returns (bytes memory args) {
    // forge-lint: disable-start(unsafe-typecast)
    args = abi.encodePacked(p.entryFeeBps, p.exitFeeBps, p.holdPeriod, p.earlyPenaltyBps, p.nonMinterPenaltyBps, p.rebalanceBandBps, p.rebalanceMinInterval, uint8(legs_.length));
    for (uint256 i = 0; i < legs_.length; i++) {
        args = abi.encodePacked(args, legs_[i].token, legs_[i].bps, legs_[i].decimals);
    }
    args = abi.encodePacked(args, uint8(bytes(name_).length), name_, uint8(bytes(symbol_).length), symbol_);
    // forge-lint: disable-end(unsafe-typecast)
}

/// What an ETF reads from its factory: prices, each token's pools, its logo, and the owner who receives
/// the protocol's fees and may rescue what the fund does not count.
interface IMaidMarianEtfV4Pricer {
    function getPriceUsdg(address token) external view returns (uint256 price, uint8 source);
    function getTradablePriceUsdg(address token) external view returns (uint256 price, uint8 source);
    function poolsOf(address token) external view returns (address pool, uint24 fee, uint24 v4Fee, int24 v4TickSpacing, address v4Hooks);
    function logo(address etf) external view returns (bytes memory);
    function owner() external view returns (address);
}

/**
 * @title Maid Marian ETF v4
 * @notice One ERC-20 holding 1 to 10 legs at fixed weights in bps (sum 10 000), created by
 * `MaidMarianEtfFactoryV4.createEtf`. No owner: nobody changes the legs, the weights or the parameters.
 *
 * Doors. Mint and redeem read no price: shares follow what the fund holds.
 *  - `mint`: USDG in, the routes buy the legs. Entry fee in USDG.
 *  - `mintInKind`: the caller brings the legs and the USDG part. Entry fee in shares.
 *  - `redeem`: the routes sell the legs for USDG, the rest paid in kind. Exit fee in shares.
 *  - `redeemInKind`: each leg's share and the USDG's; no route, always works. Exit fee in shares.
 *  - `rebalance`: anyone, once per `REBALANCE_MIN_INTERVAL`, trades legs out of band back to target.
 * Holdings: each door counts what it moves, per leg and for the USDG, and the fund holds
 * `min(count, balanceOf)` (`legHeld`, `usdgHeld`). A donation is never counted, so it moves no share's
 * value; the factory's owner sends it where he chooses (`rescueTokenTo`), never a counted unit.
 * Routes: one `V3_SWAP_EXACT_IN` through the token's registered V3 pool, or one `V4_SWAP` through its
 * registered V4 pool, hooked or not (empty hook data); always against USDG, written whole here.
 * Fees: entry and exit chosen by the creator, 30 % of them to the protocol (0.10 % least at entry);
 * management 0.50 % a year in shares (0.30 % creator, 0.20 % protocol). The first mint locks
 * `DEAD_SHARES` at `DEAD`. Cost: each leg's USDG cost (`costs()`), for display only.
 * Danger: the factory's owner chooses the pools and their hooks. A caller is protected by his own
 * `amountOutMin`, the fund by the rebalance's floor, the holders by the in-kind formula.
 * Clone: an EIP-1167 clone of one locked implementation, its legs, parameters, name and symbol in its code.
 */
contract MaidMarianEtfV4 is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------ constants ---

    uint256 public constant MAX_LEGS = 10;

    /// `redeemInKind`'s `allowFail` bit for USDG.
    uint256 public constant USDG_BIT = 15;

    /// Management fee: 0.50 % of the supply a year, minted in shares at each rebalance.
    uint256 public constant MANAGEMENT_FEE_BPS = ETF_V3_CREATOR_MANAGEMENT_FEE_BPS + ETF_V3_PROTOCOL_MANAGEMENT_FEE_BPS;

    /// Creator's part of the management fee: 0.30 % a year, to `feeRecipient`.
    uint256 public constant CREATOR_MANAGEMENT_FEE_BPS = ETF_V3_CREATOR_MANAGEMENT_FEE_BPS;

    /// Protocol's part of the management fee: 0.20 % a year, to the factory's `owner()`.
    uint256 public constant PROTOCOL_MANAGEMENT_FEE_BPS = ETF_V3_PROTOCOL_MANAGEMENT_FEE_BPS;

    /// Protocol's cut of the creator's entry and exit fees: 30 %, inside them, not on top.
    uint256 public constant PROTOCOL_CUT_BPS = ETF_V3_PROTOCOL_CUT_BPS;

    /// Least protocol entry fee: 0.10 %. The minter pays `max(ENTRY_FEE_BPS, 10)` (`entryFee`).
    uint256 public constant PROTOCOL_MIN_ENTRY_BPS = ETF_V3_PROTOCOL_MIN_ENTRY_BPS;

    /// Most a rebalance trade may give up against the leg's price: 0.5 %.
    uint256 public constant TOLERANCE_BPS = ETF_V3_TOLERANCE_BPS;

    /// The two Universal Router commands the contract writes, one per swap.
    bytes private constant V3_SWAP_EXACT_IN = hex"00";
    bytes private constant V4_SWAP = hex"10";

    /// The V4 plan: `SWAP_EXACT_IN_SINGLE`, `SETTLE` (from the router's balance), `TAKE` (to the fund).
    bytes private constant V4_ACTIONS = hex"060b0e";

    /// Where the first mint locks `DEAD_SHARES`: an address nobody holds the key of.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// Shares locked at the first mint, never redeemable: 0.001 share, paid 0.001 USDG by the first minter.
    /// With them the supply never drops below 1e15, so the creator's 30 bps a year mint at least one wei
    /// of share every second, and a donation would need 1e15 USDG to make one wei of share cost 1 USDG.
    uint256 public constant DEAD_SHARES = 1e15;

    uint256 private constant BPS = 10_000;
    uint256 private constant YEAR = 365 days;

    /// The EIP-1167 code before a clone's arguments: 45 bytes, where `Clones.fetchCloneArgs` starts.
    uint256 private constant CLONE_CODE_BYTES = 0x2d;

    // ---------------------------------------------------------------- types ---

    struct LegInit {
        address token;
        uint16 bps;
        uint8 decimals;
    }

    /// The creator's choices, checked against `paramBounds()` at initialization, fixed after:
    ///  - `entryFeeBps` 0 - 500, `exitFeeBps` 0 - 500: the creator's fees, the protocol's cut inside.
    ///  - `holdPeriod` 0 - 30 days, `earlyPenaltyBps` 0 - 5 000: on minted shares redeemed within the hold.
    ///  - `nonMinterPenaltyBps` 0 - (10 000 - `exitFeeBps`): on shares beyond the redeemer's `mintOf`.
    ///  - `rebalanceBandBps` 10 - 5 000: a leg trades when its weight is more than this many points from
    ///    its target (200: a 50 % leg trades outside 48 - 52 %).
    ///  - `rebalanceMinInterval` 0 - 24 h. Danger at 0: anyone may rebalance after every move.
    /// Penalties are moved in shares, as the exit fee: 30 % to the protocol, 70 % to `feeRecipient`.
    struct Params {
        uint16 entryFeeBps;
        uint16 exitFeeBps;
        uint32 holdPeriod;
        uint16 earlyPenaltyBps;
        uint16 nonMinterPenaltyBps;
        uint16 rebalanceBandBps;
        uint32 rebalanceMinInterval;
    }

    /// One swap of a leg against USDG; the contract writes the whole router call, the fund as recipient,
    /// the router pre-funded, through the pool the factory registered for the leg (`poolsOf`).
    ///  - `v4` false: its V3 pool, the path `token, fee, USDG` (or back) built here.
    ///  - `v4` true: its V4 pool, with its hook if it has one; `NoV4Pool` if the factory registered none.
    ///  - `mint` / `redeem`: array index = leg, `leg` and `sell` ignored, `amountOutMin` the caller's.
    ///  - `rebalance`: `leg` and `sell` name the trade; `amountOutMin` ignored, the contract writes its floor.
    struct Route {
        uint8 leg;
        bool sell;
        bool v4;
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 deadline;
    }

    /// Uniswap V4's pool key, currencies sorted.
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// The deployed V4 router's `SWAP_EXACT_IN_SINGLE` params: the published four plus `minHopPriceX36`
    /// before `hookData` (measured on chain 4663; without it the router reverts in `unlockCallback`).
    struct ExactInputSingle {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// A leg as `legs()` returns it: `price` in USDG per whole token (18 decimals), `value` and `target` in USDG (0 when unpriced),
    /// `cost` what the holding cost in USDG.
    struct Leg {
        address token;
        uint16 bps;
        uint8 decimals;
        uint256 held;
        uint256 price;
        uint8 source;
        uint256 value;
        uint256 target;
        uint256 cost;
    }

    /// A trade `rebalance` would accept now. `minOut`: the floor written into the swap; `deviationBps`: weight minus target, in points of the NAV.
    struct PlanLeg {
        uint8 leg;
        address token;
        bool sell;
        uint256 amountIn;
        uint256 minOut;
        int256 deviationBps;
    }

    // --------------------------------------------------------------- events ---

    /// Fees in USDG for `mint`, in shares for `mintInKind`; `used` / `usdgUsed` kept by the fund, the rest refunded.
    event Minted(address indexed by, bool inKind, uint256 usdgIn, uint256 shares, uint256 protocolFee, uint256 creatorFee, uint256[] used, uint256 usdgUsed);
    /// `covered`: shares within `mintOf`. `protocolFeeShares` / `creatorFeeShares`: the exit fee and the
    /// penalties, moved in shares; `inKind[i]` paid as tokens.
    event Redeemed(
        address indexed by,
        address indexed to,
        uint256 shares,
        uint256 usdgOut,
        uint256 protocolFeeShares,
        uint256 creatorFeeShares,
        uint256 covered,
        uint256 penaltyShares,
        uint256 nonMinterShares,
        uint256[] inKind
    );
    /// As `Redeemed`; `amounts` and `usdgOut` paid, 0 where `forfeited` (a failed transfer or an unread balance).
    event RedeemedInKind(
        address indexed by,
        address indexed to,
        uint256 shares,
        uint256 protocolFeeShares,
        uint256 creatorFeeShares,
        uint256 covered,
        uint256 penaltyShares,
        uint256 nonMinterShares,
        uint256[] amounts,
        uint256 usdgOut,
        uint16 forfeited
    );
    event Rebalanced(address indexed by, uint256 nav, uint256 pricedCount, uint256 legsTraded, uint256 creatorFeeShares, uint256 protocolFeeShares, bool closed);
    /// `minOut`: the floor written into the swap; `price` / `source`: what the leg was read at.
    event LegTraded(address indexed token, bool sell, uint256 amountIn, uint256 amountOut, uint256 minOut, uint256 price, uint8 source);
    /// A leg the rebalance skipped: no price.
    event LegUnpriced(uint8 indexed leg, address indexed token);
    event CreatorChanged(address indexed previous, address indexed next);
    /// What the fund held of `token` beyond its count, sent by the factory's owner.
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event FeeRecipientChanged(address indexed previous, address indexed next);

    // --------------------------------------------------------------- errors ---

    error ZeroAddress();
    error NoCode(address account);
    error BadLegCount(uint256 count);
    error BadBps(uint256 total);
    error DuplicateToken(address token);
    error ParamOutOfBounds(string name);
    error WrongLength(uint256 length, uint256 legs);
    error NothingToMint();
    error NothingToRedeem();
    error FirstMintIsUsdg();
    error FirstMintSplit(uint8 leg, uint256 amountIn, uint256 expected);
    error RoutesOverspend(uint256 routed, uint256 usdgIn);
    error NothingDelivered(address token);
    error TooFewShares(uint256 shares, uint256 minShares);
    error OverRedeem(address token, uint256 amountIn, uint256 due);
    error TooLittleOut(uint256 usdgOut, uint256 minUsdgOut);
    error TooSoon(uint256 readyAt);
    error UnknownLeg(uint8 leg);
    error LegUnpricedNow(uint8 leg);
    error LegNotDue(address token);
    error DuplicateLeg(address token);
    error SellsFirst();
    error OverTrade(address token, uint256 amountIn, uint256 max);
    error BadRoute(uint8 leg);
    error NoV4Pool(address token);
    error InputNotSpent(address token);
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    error NotCreator();
    error BadToken(address token);
    error NotFactory();
    error AlreadyInitialized();
    error NotAClone();
    error NotFactoryOwner();
    error NoSuchLeg(uint256 leg);
    error NothingToRescue(address token);
    error RescueTookCounted(address token);
    error PayoutToTheEtf();
    error FeeRecipientIsTheEtf();

    // ----------------------------------------------------------- immutables ---
    // The implementation's, so every clone's: the same for every ETF of the factory.

    /// The factory: prices, logo, and through `owner()` the protocol's fee recipient.
    IMaidMarianEtfV4Pricer public immutable FACTORY;

    IERC20 public immutable USDG;

    /// The Uniswap Universal Router every swap runs on.
    IUniversalRouter public immutable UNIVERSAL_ROUTER;

    /// Shares per USDG unit at the first mint: one whole share per whole USDG.
    uint256 private immutable FIRST_SHARES_PER_UNIT;

    /// The implementation's own address: a call that runs there and not in a clone is refused.
    address private immutable SELF;

    // ---------------------------------------------------------------- legs ---

    /// A leg, read from the clone's arguments. Value in USDG units = `held x price / scale`,
    /// `scale = 10 ** (decimals + 18 - USDG decimals)`.
    struct LegConfig {
        IERC20 token;
        uint16 bps;
        uint8 decimals;
        uint256 scale;
    }

    /// Each leg's cost in USDG units: what the fund paid for what it holds. Display only.
    uint256[MAX_LEGS] private _cost;

    /// What each door moved in and out of each leg and of the USDG: the fund holds `min(count, balanceOf)`.
    /// A unit that arrived by no door is never counted.
    uint256[MAX_LEGS] private _count;
    uint256 private _usdgCount;

    /// A leg as the rebalance reads it; price 0 and `SOURCE_NONE` when unpriced.
    struct State {
        uint256 held;
        uint256 price;
        uint8 source;
        uint256 value;
        uint256 target;
    }

    struct Snapshot {
        State[] legs;
        uint256 usdgHeld;
        uint256 nav;
        uint256 pricedBps;
        uint256 pricedCount;
    }

    struct Exit {
        uint256 paid;
        uint256 supply;
        uint256 feeShares;
        uint256 covered;
        uint256 penaltyShares;
        uint256 nonMinterShares;
    }

    // ---------------------------------------------------------------- state ---

    /// Sets `feeRecipient` and can hand its role on (`setCreator`). Receives nothing itself.
    address public creator;

    /// Set by `initialize`, and at construction on the implementation, so neither is initialized twice.
    bool private _initialized;

    /// Receives the creator's part of every fee.
    address public feeRecipient;

    /// When the last rebalance closed; 0 at birth.
    uint256 public lastRebalanceAt;

    /// Up to when the management fee has been minted; set by the first mint.
    uint256 public lastAccrualAt;

    /// What each part has accrued short of a whole share, in 1 / (10 000 x 365 days) of a share, carried
    /// to the next accrual. Each stays below 10 000 x 365 days.
    uint128 private _creatorFeeRemainder;
    uint128 private _protocolFeeRemainder;

    /// Shares an address minted (plus fee shares received) and has not redeemed. Only its redeems
    /// lower it; transfers never move it. Shares beyond it pay the non-minter penalty. A mint always
    /// credits its caller, so nobody can reset another's hold period.
    mapping(address holder => uint256) public mintOf;

    /// Last mint of each address, any size: its covered shares pay the early penalty until `+ HOLD_PERIOD`. Fee shares do not move it.
    mapping(address holder => uint256) public lastMintAt;

    // ---------------------------------------------------------- constructor ---

    /// The implementation, deployed by the factory (`FACTORY = msg.sender`) at its own construction.
    /// Locked: never initialized, no door runs on it (`NotAClone`).
    constructor(IERC20 usdg, IUniversalRouter router) ERC20("", "") {
        if (address(usdg) == address(0) || address(router) == address(0)) revert ZeroAddress();
        if (address(usdg).code.length == 0) revert NoCode(address(usdg));
        if (address(router).code.length == 0) revert NoCode(address(router));
        (bool usdgOk, uint256 usdgDecimals) = _readUint(address(usdg), abi.encodeWithSelector(0x313ce567)); // decimals()
        if (!usdgOk || usdgDecimals > 18) revert BadToken(address(usdg));
        FACTORY = IMaidMarianEtfV4Pricer(msg.sender);
        USDG = usdg;
        UNIVERSAL_ROUTER = router;
        FIRST_SHARES_PER_UNIT = 10 ** (18 - usdgDecimals);
        SELF = address(this);
        _initialized = true;
    }

    /// @notice Called once, by the factory, in the transaction that creates this clone. The factory checked
    /// the legs; this rechecks what it can and the parameters, in the clone's arguments.
    function initialize(address creator_) external {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        if (_initialized) revert AlreadyInitialized();
        if (creator_ == address(0)) revert ZeroAddress();
        _checkParams(params());
        uint256 n = LEGS();
        if (n == 0 || n > MAX_LEGS) revert BadLegCount(n);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            (IERC20 t, uint16 bps, uint8 decimals) = _legArgs(i);
            address token = address(t);
            if (token == address(0)) revert ZeroAddress();
            if (token == address(USDG)) revert DuplicateToken(token);
            if (token.code.length == 0) revert NoCode(token);
            if (decimals > 36) revert BadToken(token);
            if (bps == 0) revert BadBps(0);
            for (uint256 j = 0; j < i; j++) {
                if (address(_token(j)) == token) revert DuplicateToken(token);
            }
            total += bps;
        }
        if (total != BPS) revert BadBps(total);
        _initialized = true;
        creator = creator_;
        feeRecipient = creator_;
        lastAccrualAt = block.timestamp;
        // A clone's storage starts at 0: the guard is set to `ReentrancyGuard`'s NOT_ENTERED, as its constructor does.
        StorageSlot.getUint256Slot(_reentrancyGuardStorageSlot()).value = 1;
    }

    /// @notice Every parameter's bounds, both inclusive. Also `nonMinterPenaltyBps` <= 10 000 - `exitFeeBps`
    /// and `earlyPenaltyBps` <= `nonMinterPenaltyBps`.
    function paramBounds() public pure returns (Params memory lo, Params memory hi) {
        return etfV4ParamBounds();
    }

    function _checkParams(Params memory p) private pure {
        (Params memory lo, Params memory hi) = paramBounds();
        _bound(p.entryFeeBps, lo.entryFeeBps, hi.entryFeeBps, "entryFeeBps");
        _bound(p.exitFeeBps, lo.exitFeeBps, hi.exitFeeBps, "exitFeeBps");
        _bound(p.holdPeriod, lo.holdPeriod, hi.holdPeriod, "holdPeriod");
        _bound(p.earlyPenaltyBps, lo.earlyPenaltyBps, hi.earlyPenaltyBps, "earlyPenaltyBps");
        _bound(p.nonMinterPenaltyBps, lo.nonMinterPenaltyBps, hi.nonMinterPenaltyBps - p.exitFeeBps, "nonMinterPenaltyBps");
        if (p.earlyPenaltyBps > p.nonMinterPenaltyBps) revert ParamOutOfBounds("earlyPenaltyBps");
        _bound(p.rebalanceBandBps, lo.rebalanceBandBps, hi.rebalanceBandBps, "rebalanceBandBps");
        _bound(p.rebalanceMinInterval, lo.rebalanceMinInterval, hi.rebalanceMinInterval, "rebalanceMinInterval");
    }

    function _bound(uint256 value, uint256 lo, uint256 hi, string memory field) private pure {
        if (value < lo || value > hi) revert ParamOutOfBounds(field);
    }

    // ---------------------------------------------------------------- doors ---

    /// On every door: the implementation has no arguments, so none runs there.
    modifier onlyClone() {
        _onlyClone();
        _;
    }

    function _onlyClone() private view {
        if (address(this) == SELF) revert NotAClone();
    }

    /// @notice Buy in with USDG. The entry fee (`entryFee(usdgIn)`) is taken first and pushed at once;
    /// `routes[i]` spends the rest on leg i (one route per leg, 0 skips it), for at least its `amountOutMin`.
    /// @dev Shares = `totalSupply x min(received_i / held_i)` over the legs and the USDG left, rounded down;
    /// `received_i` is what route i's swap brought, the USDG left what no route spent: nothing else is
    /// credited. The fund keeps `ceil(held_i x shares / totalSupply)` of each and refunds the rest, so no
    /// holder's tokens per share can fall. First mint: routes must equal `firstMintSplit(usdgIn)`, each
    /// delivering something, one share per USDG kept, `DEAD_SHARES` of them locked at `DEAD`.
    /// A frozen fee recipient makes this revert.
    function mint(uint256 usdgIn, Route[] calldata routes, uint256 minShares) external onlyClone nonReentrant returns (uint256 shares) {
        return _mintTo(msg.sender, usdgIn, routes, minShares);
    }

    /// @notice `mint` for `minter`, by the factory only: the USDG is pulled from the factory (which took it
    /// from `minter` in the same transaction), the shares and the refunds go to `minter`, whose `mintOf`
    /// and `lastMintAt` are written as if he had called `mint` himself.
    /// @dev The factory passes its own `msg.sender` as `minter` and nothing else; this ETF trusts it as it
    /// does for `owner()` and the prices. The shares are never the factory's, so it holds none.
    function mintFor(address minter, uint256 usdgIn, Route[] calldata routes, uint256 minShares) external onlyClone nonReentrant returns (uint256 shares) {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        return _mintTo(minter, usdgIn, routes, minShares);
    }

    /// `mint`'s body: the USDG comes from the caller, the shares and the refunds go to `minter`.
    function _mintTo(address minter, uint256 usdgIn, Route[] calldata routes, uint256 minShares) private returns (uint256 shares) {
        _accrue();
        if (usdgIn == 0) revert NothingToMint();
        uint256 n = LEGS();
        if (routes.length != n) revert WrongLength(routes.length, n);
        uint256 supply = totalSupply();
        (uint256 fee, uint256 protocolFee, uint256 creatorFee) = entryFee(usdgIn);
        uint256 net = usdgIn - fee;
        uint256 routed;
        for (uint256 i = 0; i < n; i++) {
            routed += routes[i].amountIn;
        }
        if (supply == 0) {
            uint256[] memory split = _firstMintSplit(net);
            for (uint256 i = 0; i < n; i++) {
                // forge-lint: disable-next-line(unsafe-typecast)
                if (routes[i].amountIn != split[i]) revert FirstMintSplit(uint8(i), routes[i].amountIn, split[i]);
                if (split[i] == 0) revert NothingDelivered(address(_token(i)));
            }
        } else if (routed > net) {
            revert RoutesOverspend(routed, net);
        }

        uint256[] memory held = _heldAll();
        uint256 fundUsdg = _usdgNow();
        USDG.safeTransferFrom(msg.sender, address(this), usdgIn);
        _pushFees(protocolFee, creatorFee);
        uint256[] memory received = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            Route calldata r = routes[i];
            // forge-lint: disable-next-line(unsafe-typecast)
            if (r.amountIn > 0) received[i] = _swap(r, uint8(i), false, r.amountOutMin);
        }
        uint256 usdgReceived = net - routed;

        uint256 gross;
        uint256[] memory used;
        uint256 usdgUsed;
        if (supply == 0) {
            for (uint256 i = 0; i < n; i++) {
                if (received[i] == 0) revert NothingDelivered(address(_token(i)));
            }
            gross = net * FIRST_SHARES_PER_UNIT;
            if (gross <= DEAD_SHARES) revert TooFewShares(0, minShares);
            _mint(DEAD, DEAD_SHARES);
            (gross, used, usdgUsed) = (gross - DEAD_SHARES, received, usdgReceived);
        } else {
            (gross, used, usdgUsed) = _keep(supply, held, received, fundUsdg, usdgReceived);
        }
        // Each leg's cost grows by the USDG its swap spent on the part the fund keeps; its count by that part.
        for (uint256 i = 0; i < n; i++) {
            _count[i] = held[i] + used[i];
            if (used[i] > 0) _cost[i] += Math.mulDiv(routes[i].amountIn, used[i], received[i]);
        }
        _usdgCount = fundUsdg + usdgUsed;
        (shares,,) = _issue(minter, gross, minShares, false);
        _refund(minter, received, used, usdgReceived, usdgUsed);
        emit Minted(minter, false, usdgIn, shares, protocolFee, creatorFee, used, usdgUsed);
    }

    /// @notice Bring the legs and the USDG part yourself; `mint`'s formula applies, the excess refunded.
    /// @dev Entry fee in shares: valuing tokens in USDG would need a price. Not for the first mint.
    function mintInKind(uint256[] calldata amounts, uint256 usdgAmount, uint256 minShares) external onlyClone nonReentrant returns (uint256 shares) {
        return _mintInKindTo(msg.sender, amounts, usdgAmount, minShares);
    }

    /// @notice `mintInKind` for `minter`, by the factory only, as `mintFor` is `mint`: the legs and the USDG
    /// are pulled from the factory, the shares and the refunds go to `minter`.
    function mintInKindFor(address minter, uint256[] calldata amounts, uint256 usdgAmount, uint256 minShares) external onlyClone nonReentrant returns (uint256 shares) {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        return _mintInKindTo(minter, amounts, usdgAmount, minShares);
    }

    function _mintInKindTo(address minter, uint256[] calldata amounts, uint256 usdgAmount, uint256 minShares) private returns (uint256 shares) {
        _accrue();
        uint256 n = LEGS();
        if (amounts.length != n) revert WrongLength(amounts.length, n);
        uint256 supply = totalSupply();
        if (supply == 0) revert FirstMintIsUsdg();

        // What arrived is the balance rise, so a token that takes a fee on transfer is counted as received.
        uint256[] memory balances = _balances();
        uint256 usdgBalance = USDG.balanceOf(address(this));
        uint256[] memory held = _heldOf(balances);
        uint256 fundUsdg = Math.min(_usdgCount, usdgBalance);
        for (uint256 i = 0; i < n; i++) {
            if (amounts[i] > 0) _token(i).safeTransferFrom(msg.sender, address(this), amounts[i]);
        }
        if (usdgAmount > 0) USDG.safeTransferFrom(msg.sender, address(this), usdgAmount);
        uint256[] memory received = _balances();
        for (uint256 i = 0; i < n; i++) {
            received[i] -= balances[i];
        }
        uint256 usdgReceived = USDG.balanceOf(address(this)) - usdgBalance;

        (uint256 gross, uint256[] memory used, uint256 usdgUsed) = _keep(supply, held, received, fundUsdg, usdgReceived);
        _usdgCount = fundUsdg + usdgUsed;
        // Tokens brought are booked at the tradable price, else at the leg's average cost.
        for (uint256 i = 0; i < n; i++) {
            _count[i] = held[i] + used[i];
            if (used[i] == 0) continue;
            (bool priced, uint256 price) = _tradablePrice(address(_token(i)));
            _cost[i] += priced ? Math.mulDiv(used[i], price, _leg(i).scale) : Math.mulDiv(_cost[i], used[i], held[i]);
        }
        uint256 protocolFee;
        uint256 creatorFee;
        (shares, protocolFee, creatorFee) = _issue(minter, gross, minShares, true);
        _refund(minter, received, used, usdgReceived, usdgUsed);
        emit Minted(minter, true, usdgAmount, shares, protocolFee, creatorFee, used, usdgUsed);
    }

    /// @notice Leave for USDG: `routes[i]` sells up to leg i's due for at least its `amountOutMin`; what is
    /// not sold is paid in kind.
    /// @dev As `redeemInKind`: the exit fee and the penalties are moved in shares first, only the shares
    /// paid are burned, and leg i's due is `held_i x paid / supply`, the fund's USDG in the same part.
    /// No fee in USDG, so no recipient is paid here.
    function redeem(uint256 shares, Route[] calldata routes, uint256 minUsdgOut, address to) external onlyClone nonReentrant returns (uint256 usdgOut) {
        _accrue();
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert PayoutToTheEtf();
        uint256 n = LEGS();
        if (routes.length != n) revert WrongLength(routes.length, n);
        Exit memory e = _exit(shares);
        uint256[] memory held = _heldAll();
        uint256 fundUsdg = _usdgNow();
        usdgOut = Math.mulDiv(fundUsdg, e.paid, e.supply);
        _usdgCount = fundUsdg - usdgOut;
        (uint256 protocolFee, uint256 creatorFee) = _takeFees(e);
        _burn(msg.sender, e.paid);

        // The USDG a sale brings goes to `to` whole, so it never enters the count.
        uint256[] memory inKind = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            IERC20 token = _token(i);
            uint256 due = Math.mulDiv(held[i], e.paid, e.supply);
            uint256 amountIn = routes[i].amountIn;
            if (amountIn > due) revert OverRedeem(address(token), amountIn, due);
            _count[i] = held[i] - due;
            if (due == 0) continue;
            _takeCost(i, due, held[i]);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (amountIn > 0) usdgOut += _swap(routes[i], uint8(i), true, routes[i].amountOutMin);
            inKind[i] = due - amountIn;
            if (inKind[i] > 0) token.safeTransfer(to, inKind[i]);
        }
        if (usdgOut < minUsdgOut) revert TooLittleOut(usdgOut, minUsdgOut);
        if (usdgOut > 0) USDG.safeTransfer(to, usdgOut);
        emit Redeemed(msg.sender, to, shares, usdgOut, protocolFee, creatorFee, e.covered, e.penaltyShares, e.nonMinterShares, inKind);
    }

    /// @notice Leave in kind: each leg's and the USDG's share of what is paid, after the exit fee and the
    /// penalties (in shares).
    /// @dev `allowFail` bit i (`USDG_BIT` for USDG) lets that transfer fail: the amount stays in the fund,
    /// still counted, and `forfeited` names it. A leg whose balance cannot be read is paid from its count,
    /// its transfer allowed to fail whatever `allowFail` says. A transfer that succeeds always delivers.
    function redeemInKind(uint256 shares, address to, uint16 allowFail) external onlyClone nonReentrant {
        _accrue();
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert PayoutToTheEtf();
        uint256 n = LEGS();
        Exit memory e = _exit(shares);
        (uint256 paid, uint256 supply) = (e.paid, e.supply);
        (bool usdgRead, uint256 fundUsdg) = _heldRead(USDG, _usdgCount);
        uint256 usdgOut = Math.mulDiv(fundUsdg, paid, supply);
        (uint256 protocolFee, uint256 creatorFee) = _takeFees(e);
        _burn(msg.sender, paid);

        uint16 forfeited;
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            IERC20 token = _token(i);
            (bool read, uint256 held) = _heldRead(token, _count[i]);
            uint256 due = Math.mulDiv(held, paid, supply);
            if (due > 0 && _pay(token, to, due, allowFail, i, !read)) {
                amounts[i] = due;
                _takeCost(i, due, held);
            } else if (due > 0) {
                // `1 << i` is the bit of leg i; i < LEGS() <= 10, so it fits 16 bits.
                // forge-lint: disable-next-line(incorrect-shift, unsafe-typecast)
                forfeited |= uint16(1 << i);
            }
            _count[i] = held - amounts[i];
        }
        _usdgCount = fundUsdg;
        if (usdgOut > 0) {
            if (_pay(USDG, to, usdgOut, allowFail, USDG_BIT, !usdgRead)) {
                _usdgCount = fundUsdg - usdgOut;
            } else {
                // `1 << USDG_BIT` is the USDG bit; USDG_BIT is 15, so it fits 16 bits.
                // forge-lint: disable-next-line(incorrect-shift, unsafe-typecast)
                forfeited |= uint16(1 << USDG_BIT);
                usdgOut = 0;
            }
        }
        emit RedeemedInKind(msg.sender, to, shares, protocolFee, creatorFee, e.covered, e.penaltyShares, e.nonMinterShares, amounts, usdgOut, forfeited);
    }

    /// @notice Trade legs out of band back toward their targets. Anyone, once per `REBALANCE_MIN_INTERVAL`.
    /// @dev Accrues the management fee first, as every door does. Each leg is priced once by the factory's `getTradablePriceUsdg`
    /// (NAV, else TWAP 30 min, never a spot); a leg without that price is skipped (`LegUnpriced`), out of
    /// the NAV and the targets. A leg is due when its weight is more than `REBALANCE_BAND_BPS` points from
    /// target. Routes: sells before buys, at most the gap; the floor (price less `TOLERANCE_BPS`) is written
    /// into the swap and checked again after. The window closes only if a route ran and every priced leg
    /// ends in band. An empty `routes` only accrues the fee.
    function rebalance(Route[] calldata routes) external onlyClone nonReentrant {
        uint256 readyAt = lastRebalanceAt + REBALANCE_MIN_INTERVAL();
        if (block.timestamp < readyAt) revert TooSoon(readyAt);

        (uint256 creatorFee, uint256 protocolFee) = _accrue();

        uint256 n = LEGS();
        Snapshot memory s = _snapshot(true);
        for (uint256 i = 0; i < n; i++) {
            _count[i] = s.legs[i].held;
            // forge-lint: disable-next-line(unsafe-typecast)
            if (s.legs[i].source == SOURCE_NONE) emit LegUnpriced(uint8(i), address(_token(i)));
        }
        // A purchase spends only counted USDG; a sale's whole output is counted.
        uint256 fundUsdg = s.usdgHeld;

        uint256 seen;
        bool buying;
        for (uint256 k = 0; k < routes.length; k++) {
            Route calldata r = routes[k];
            if (r.leg >= n) revert UnknownLeg(r.leg);
            LegConfig memory c = _leg(r.leg);
            // forge-lint: disable-next-line(incorrect-shift)
            uint256 bit = 1 << r.leg;
            if (seen & bit != 0) revert DuplicateLeg(address(c.token));
            seen |= bit;
            if (r.sell && buying) revert SellsFirst();
            buying = !r.sell;

            State memory l = s.legs[r.leg];
            if (l.source == SOURCE_NONE) revert LegUnpricedNow(r.leg);
            (bool due, bool sell, uint256 gap) = _due(l, s.nav);
            if (!due || sell != r.sell) revert LegNotDue(address(c.token));
            uint256 minOut;
            if (r.sell) {
                // Never more than held: the gap can pass the holding on a leg whose target fell.
                uint256 max = Math.min(Math.mulDiv(gap, c.scale, l.price), l.held);
                if (r.amountIn > max) revert OverTrade(address(c.token), r.amountIn, max);
                minOut = _sellFloor(r.amountIn, l.price, c.scale);
                _takeCost(r.leg, r.amountIn, l.held);
            } else {
                if (r.amountIn > gap) revert OverTrade(address(c.token), r.amountIn, gap);
                if (r.amountIn > fundUsdg) revert OverTrade(address(USDG), r.amountIn, fundUsdg);
                minOut = _buyFloor(r.amountIn, l.price, c.scale);
                _cost[r.leg] += r.amountIn;
            }
            uint256 amountOut = _swap(r, r.leg, r.sell, minOut);
            if (r.sell) {
                _count[r.leg] = l.held - r.amountIn;
                fundUsdg += amountOut;
            } else {
                _count[r.leg] = l.held + amountOut;
                fundUsdg -= r.amountIn;
            }
            emit LegTraded(address(c.token), r.sell, r.amountIn, amountOut, minOut, l.price, l.source);
        }

        _usdgCount = fundUsdg;
        bool closed = routes.length > 0 && _noneDueAfter(s);
        if (closed) lastRebalanceAt = block.timestamp;
        emit Rebalanced(msg.sender, s.nav, s.pricedCount, routes.length, creatorFee, protocolFee, closed);
    }

    /// @notice Hand the creator role to `next`, and the creator's fees with it: `feeRecipient` becomes `next`,
    /// who may move it with `setFeeRecipient`. Creator only.
    function setCreator(address next) external {
        if (msg.sender != creator) revert NotCreator();
        if (next == address(0)) revert ZeroAddress();
        if (next == address(this)) revert FeeRecipientIsTheEtf();
        emit CreatorChanged(creator, next);
        creator = next;
        emit FeeRecipientChanged(feeRecipient, next);
        feeRecipient = next;
    }

    /// @notice Send the creator's fee part to `next`. Creator only.
    /// @dev USDG can freeze an address: a frozen recipient blocks `mint` until moved.
    function setFeeRecipient(address next) external {
        if (msg.sender != creator) revert NotCreator();
        if (next == address(0)) revert ZeroAddress();
        if (next == address(this)) revert FeeRecipientIsTheEtf();
        emit FeeRecipientChanged(feeRecipient, next);
        feeRecipient = next;
    }

    /// @notice Send what the fund holds of `token` beyond its count (`rescuable`) to `to`: a donation, a
    /// token sent by mistake, this ETF's own shares. The factory's `owner()` only.
    /// @dev Reverts if the transfer took more than that from the fund (a fee charged to the sender).
    function rescueTokenTo(address token, address to) external onlyClone nonReentrant returns (uint256 amount) {
        if (msg.sender != FACTORY.owner()) revert NotFactoryOwner();
        if (to == address(0)) revert ZeroAddress();
        amount = rescuable(token);
        if (amount == 0) revert NothingToRescue(token);
        if (token == address(this)) {
            _transfer(address(this), to, amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
            if (IERC20(token).balanceOf(address(this)) < _countOf(token)) revert RescueTookCounted(token);
        }
        emit Rescued(token, to, amount);
    }

    // ---------------------------------------------------------------- views ---

    /// @notice What the fund holds of leg `leg`: `min(count, balanceOf)`. Every door and every view reads it.
    function legHeld(uint256 leg) external view returns (uint256) {
        if (leg >= LEGS()) revert NoSuchLeg(leg);
        return Math.min(_count[leg], _token(leg).balanceOf(address(this)));
    }

    /// @notice What the fund holds of USDG: `min(count, balanceOf)`.
    function usdgHeld() external view returns (uint256) {
        return _usdgNow();
    }

    /// @notice What `rescueTokenTo` would send of `token` now: its balance beyond the count, all of it for a
    /// token the fund does not count.
    function rescuable(address token) public view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 counted = _countOf(token);
        return balance > counted ? balance - counted : 0;
    }

    /// @notice The legs, priced for display: a spot price shown here is one `rebalance` skips.
    function legs() external view returns (Leg[] memory out) {
        Snapshot memory s = _snapshot(false);
        uint256 n = LEGS();
        out = new Leg[](n);
        for (uint256 i = 0; i < n; i++) {
            LegConfig memory c = _leg(i);
            State memory l = s.legs[i];
            out[i] = Leg({ token: address(c.token), bps: c.bps, decimals: c.decimals, held: l.held, price: l.price, source: l.source, value: l.value, target: l.target, cost: _cost[i] });
        }
    }

    /// @notice Each leg's cost in USDG units, for display: no door reads it.
    function costs() external view returns (uint256[] memory out) {
        uint256 n = LEGS();
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _cost[i];
        }
    }

    /// @notice The parameters as created (each cast exact: the field is that many bytes of the arguments).
    function params() public view returns (Params memory p) {
        // forge-lint: disable-start(unsafe-typecast)
        p = Params({
            entryFeeBps: uint16(ENTRY_FEE_BPS()),
            exitFeeBps: uint16(EXIT_FEE_BPS()),
            holdPeriod: uint32(HOLD_PERIOD()),
            earlyPenaltyBps: uint16(EARLY_PENALTY_BPS()),
            nonMinterPenaltyBps: uint16(NON_MINTER_PENALTY_BPS()),
            rebalanceBandBps: uint16(REBALANCE_BAND_BPS()),
            rebalanceMinInterval: uint32(REBALANCE_MIN_INTERVAL())
        });
        // forge-lint: disable-end(unsafe-typecast)
    }

    // forge-lint: disable-start(mixed-case-function)
    // The per-ETF values, read from the clone's arguments.

    function LEGS() public view returns (uint256) {
        return _arg(ETF_V3_ARGS_LEG_COUNT, 1);
    }

    function ENTRY_FEE_BPS() public view returns (uint256) {
        return _arg(0, 2);
    }

    function EXIT_FEE_BPS() public view returns (uint256) {
        return _arg(2, 2);
    }

    function HOLD_PERIOD() public view returns (uint256) {
        return _arg(4, 4);
    }

    function EARLY_PENALTY_BPS() public view returns (uint256) {
        return _arg(8, 2);
    }

    function NON_MINTER_PENALTY_BPS() public view returns (uint256) {
        return _arg(10, 2);
    }

    function REBALANCE_BAND_BPS() public view returns (uint256) {
        return _arg(12, 2);
    }

    function REBALANCE_MIN_INTERVAL() public view returns (uint256) {
        return _arg(14, 4);
    }
    // forge-lint: disable-end(mixed-case-function)

    function name() public view override returns (string memory) {
        return _argString(_namesAt());
    }

    function symbol() public view override returns (string memory) {
        uint256 pos = _namesAt();
        return _argString(pos + 1 + _arg(pos, 1));
    }

    /// @notice Fund value in USDG at `legs()`'s prices; `complete` is false when a leg is unpriced (left out).
    function nav() external view returns (uint256 value, bool complete) {
        Snapshot memory s = _snapshot(false);
        return (s.nav, s.pricedCount == LEGS());
    }

    /// @notice What a mint keeps for `grossShares`: `ceil(held_i x grossShares / supply)` of each leg and of the USDG.
    /// @dev Every preview divides by the supply once the door has accrued the management fee.
    function quoteMint(uint256 grossShares) external view returns (uint256[] memory amounts, uint256 usdg) {
        uint256 n = LEGS();
        amounts = new uint256[](n);
        uint256 supply = accruedSupply();
        if (supply == 0) return (amounts, 0);
        uint256[] memory held = _heldAll();
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = Math.mulDiv(held[i], grossShares, supply, Math.Rounding.Ceil);
        }
        usdg = Math.mulDiv(_usdgNow(), grossShares, supply, Math.Rounding.Ceil);
    }

    /// @notice The first mint's route amounts: `usdgIn` less the entry fee, split by bps, dust on leg 0.
    function firstMintSplit(uint256 usdgIn) external view returns (uint256[] memory amounts) {
        (uint256 fee,,) = entryFee(usdgIn);
        return _firstMintSplit(usdgIn - fee);
    }

    /// @notice The entry fee on `amount` (USDG for `mint`, gross shares for `mintInKind`) and its split.
    /// @dev Total `max(ENTRY_FEE_BPS, 10)`; protocol `max(10, 30 % of ENTRY_FEE_BPS)`; creator the rest.
    /// At 100 bps: 1 % paid, 0.70 % creator, 0.30 % protocol. `entryFee(10 000)` gives the rates in bps.
    function entryFee(uint256 amount) public view returns (uint256 total, uint256 protocol, uint256 creator_) {
        uint256 entryBps = ENTRY_FEE_BPS();
        total = Math.mulDiv(amount, Math.max(entryBps, PROTOCOL_MIN_ENTRY_BPS), BPS);
        protocol = Math.max(Math.mulDiv(amount, PROTOCOL_MIN_ENTRY_BPS, BPS), Math.mulDiv(amount, entryBps * PROTOCOL_CUT_BPS, BPS * BPS));
        creator_ = total - protocol;
    }

    /// @notice What `mintInKind` would mint now: the caller's shares and the fee's two parts. Zeros if empty or wrong length.
    function previewMintInKind(uint256[] calldata amounts, uint256 usdgAmount) external view returns (uint256 shares, uint256 protocolFeeShares, uint256 creatorFeeShares) {
        uint256 supply = accruedSupply();
        if (supply == 0 || amounts.length != LEGS()) return (0, 0, 0);
        (uint256 gross,,) = _keep(supply, _heldAll(), amounts, _usdgNow(), usdgAmount);
        uint256 fee;
        (fee, protocolFeeShares, creatorFeeShares) = entryFee(gross);
        shares = gross - fee;
    }

    /// @notice For `redeem`: `due[i]`, the most of leg i its routes may sell, the rest paid in kind; `usdg`,
    /// the fund's USDG that comes along; `feeShares`, the exit fee and the penalties moved to the recipients;
    /// `paid`, the shares burned. The payout of `previewRedeem`.
    function previewRedeemToUsdg(address holder, uint256 shares) external view returns (uint256[] memory due, uint256 usdg, uint256 feeShares, uint256 paid) {
        uint256 penaltyShares;
        (paid, feeShares, penaltyShares, due, usdg) = previewRedeem(holder, shares);
        feeShares += penaltyShares;
    }

    /// @notice What both redeems would do now: shares paid (burned), the exit fee's and the penalties' shares
    /// (moved to the recipients), and the payout. Reverts if a leg's balance cannot be read, where
    /// `redeemInKind` pays that leg from its count.
    function previewRedeem(address holder, uint256 shares) public view returns (uint256 paid, uint256 feeShares, uint256 penaltyShares, uint256[] memory amounts, uint256 usdg) {
        uint256 n = LEGS();
        amounts = new uint256[](n);
        uint256 supply = accruedSupply();
        if (supply == 0 || shares == 0) return (0, 0, 0, amounts, 0);
        Exit memory e = _exitSplit(holder, _mintOfAtDoor(holder), shares);
        (paid, feeShares, penaltyShares) = (e.paid, e.feeShares, e.penaltyShares + e.nonMinterShares);
        uint256[] memory held = _heldAll();
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = Math.mulDiv(held[i], paid, supply);
        }
        usdg = Math.mulDiv(_usdgNow(), paid, supply);
    }

    /// @notice The trades `rebalance` would accept now, sells first, each at full size; buys never exceed the
    /// USDG held plus the sells' floors, so the plan runs as listed.
    function plan() external view returns (PlanLeg[] memory out) {
        Snapshot memory s = _snapshot(true);
        uint256 n = LEGS();
        PlanLeg[] memory rows = new PlanLeg[](n);
        uint256 count;
        uint256 usdgAvailable = s.usdgHeld;
        for (uint256 pass = 0; pass < 2; pass++) {
            bool wantSell = pass == 0;
            for (uint256 i = 0; i < n; i++) {
                State memory l = s.legs[i];
                (bool due, bool sell, uint256 gap) = _due(l, s.nav);
                if (!due || sell != wantSell) continue;
                uint256 scale = _leg(i).scale;
                uint256 amountIn;
                uint256 minOut;
                if (sell) {
                    amountIn = Math.min(Math.mulDiv(gap, scale, l.price), l.held);
                    minOut = _sellFloor(amountIn, l.price, scale);
                    usdgAvailable += minOut;
                } else {
                    amountIn = Math.min(gap, usdgAvailable);
                    if (amountIn == 0) continue;
                    usdgAvailable -= amountIn;
                    minOut = _buyFloor(amountIn, l.price, scale);
                }
                // forge-lint: disable-next-line(unsafe-typecast)
                int256 deviation = (int256(l.value) - int256(l.target)) * int256(BPS) / int256(s.nav);
                // forge-lint: disable-next-line(unsafe-typecast)
                rows[count++] = PlanLeg({ leg: uint8(i), token: address(_token(i)), sell: sell, amountIn: amountIn, minOut: minOut, deviationBps: deviation });
            }
        }
        out = new PlanLeg[](count);
        for (uint256 k = 0; k < count; k++) {
            out[k] = rows[k];
        }
    }

    /// @notice Whether a door or a rebalance of this ETF is running now; the factory gives no NAV for it then.
    function entered() external view returns (bool) {
        return _reentrancyGuardEntered();
    }

    /// @notice Whether `rebalance` is open now, and when it opens.
    function canRebalance() external view returns (bool ready, uint256 readyAt) {
        readyAt = lastRebalanceAt + REBALANCE_MIN_INTERVAL();
        ready = block.timestamp >= readyAt;
    }

    /// @notice `holder`'s redeem rates in bps: `coveredBps` on shares within `mintOf`, `otherBps` on the rest.
    /// They add, never compound, and are moved in shares to the protocol and `feeRecipient`.
    function exitRates(address holder) external view returns (uint256 coveredBps, uint256 otherBps, uint256 covered, uint256 holdEndsAt) {
        holdEndsAt = lastMintAt[holder] + HOLD_PERIOD();
        coveredBps = block.timestamp < holdEndsAt ? EXIT_FEE_BPS() + EARLY_PENALTY_BPS() : EXIT_FEE_BPS();
        otherBps = EXIT_FEE_BPS() + NON_MINTER_PENALTY_BPS();
        covered = _mintOfAtDoor(holder);
    }

    /// @notice The management fee the next door would mint now, per part `supply x bps x elapsed / (10 000 x 365 days)`,
    /// plus what earlier accruals left short of a whole share.
    /// @dev Accrued first at every door (`mint`, `mintInKind`, `redeem`, `redeemInKind`, `rebalance`), on the
    /// supply before it, so each holder pays for the time it held.
    function pendingManagementFee() public view returns (uint256 creatorShares, uint256 protocolShares) {
        (creatorShares, protocolShares,,) = _pendingFee();
    }

    /// @notice `totalSupply()` as the next door sees it, once the management fee due is minted; the factory
    /// divides an ETF's NAV by it.
    function accruedSupply() public view returns (uint256) {
        (uint256 creatorFee, uint256 protocolFee) = pendingManagementFee();
        return totalSupply() + creatorFee + protocolFee;
    }

    /// @notice The ETF's PNG logo, stored by the factory; empty if none.
    function logo() external view returns (bytes memory) {
        return FACTORY.logo(address(this));
    }

    // ------------------------------------------------------------- internal ---

    function _firstMintSplit(uint256 usdgIn) private view returns (uint256[] memory amounts) {
        uint256 n = LEGS();
        amounts = new uint256[](n);
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = usdgIn * _leg(i).bps / BPS;
            sum += amounts[i];
        }
        amounts[0] += usdgIn - sum;
    }

    /// The in-kind formula: `gross = supply x min(received_i / held_i)`, then keep `ceil(held_i x gross / supply)`,
    /// never above `received_i`. A leg the fund does not hold keeps nothing.
    function _keep(uint256 supply, uint256[] memory held, uint256[] memory received, uint256 fundUsdg, uint256 usdgReceived)
        private
        pure
        returns (uint256 gross, uint256[] memory used, uint256 usdgUsed)
    {
        gross = type(uint256).max;
        uint256 n = held.length;
        for (uint256 i = 0; i < n; i++) {
            if (held[i] == 0) continue;
            gross = Math.min(gross, Math.mulDiv(supply, received[i], held[i]));
        }
        if (fundUsdg > 0) gross = Math.min(gross, Math.mulDiv(supply, usdgReceived, fundUsdg));
        if (gross == type(uint256).max) gross = 0;
        used = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            used[i] = Math.mulDiv(held[i], gross, supply, Math.Rounding.Ceil);
        }
        usdgUsed = Math.mulDiv(fundUsdg, gross, supply, Math.Rounding.Ceil);
    }

    /// Mints `gross` to `minter` (less the entry fee in shares when `inKind`), into his `mintOf`, clock restarted.
    function _issue(address minter, uint256 gross, uint256 minShares, bool inKind) private returns (uint256 shares, uint256 protocolFee, uint256 creatorFee) {
        shares = gross;
        if (inKind) {
            uint256 fee;
            (fee, protocolFee, creatorFee) = entryFee(gross);
            shares = gross - fee;
        }
        if (shares == 0 || shares < minShares) revert TooFewShares(shares, minShares);
        if (protocolFee > 0) _mintFee(FACTORY.owner(), protocolFee);
        if (creatorFee > 0) _mintFee(feeRecipient, creatorFee);
        _mint(minter, shares);
        mintOf[minter] += shares;
        lastMintAt[minter] = block.timestamp;
    }

    /// Mints the management fee due and moves `lastAccrualAt` every time, each part's rest short of a share
    /// carried, so frequent doors round no fee away. In shares (`_mint`): no recipient is called, none can
    /// block a door here.
    function _accrue() private returns (uint256 creatorFee, uint256 protocolFee) {
        uint256 creatorRest;
        uint256 protocolRest;
        (creatorFee, protocolFee, creatorRest, protocolRest) = _pendingFee();
        lastAccrualAt = block.timestamp;
        // forge-lint: disable-next-line(unsafe-typecast)
        (_creatorFeeRemainder, _protocolFeeRemainder) = (uint128(creatorRest), uint128(protocolRest));
        if (creatorFee > 0) _mintFee(feeRecipient, creatorFee);
        if (protocolFee > 0) _mintFee(FACTORY.owner(), protocolFee);
    }

    /// Each part's whole shares due since `lastAccrualAt` and the rest short of one, from
    /// `supply x bps x elapsed` plus the carried remainder.
    function _pendingFee() private view returns (uint256 creatorShares, uint256 protocolShares, uint256 creatorRest, uint256 protocolRest) {
        uint256 base = totalSupply() * (block.timestamp - lastAccrualAt);
        uint256 creatorDue = base * CREATOR_MANAGEMENT_FEE_BPS + _creatorFeeRemainder;
        uint256 protocolDue = base * PROTOCOL_MANAGEMENT_FEE_BPS + _protocolFeeRemainder;
        (creatorShares, creatorRest) = (creatorDue / (BPS * YEAR), creatorDue % (BPS * YEAR));
        (protocolShares, protocolRest) = (protocolDue / (BPS * YEAR), protocolDue % (BPS * YEAR));
    }

    /// Fee shares count in the receiver's `mintOf` (no non-minter penalty on them) without moving its clock.
    function _mintFee(address to, uint256 shares) private {
        _mint(to, shares);
        mintOf[to] += shares;
    }

    /// Fee shares moved from the redeemer, counted like `_mintFee`.
    function _moveFee(address to, uint256 shares) private {
        _transfer(msg.sender, to, shares);
        mintOf[to] += shares;
    }

    /// A redeem's exit fee and penalties, moved from the redeemer in shares, split by `_cut`.
    function _takeFees(Exit memory e) private returns (uint256 protocol, uint256 creator_) {
        (protocol, creator_) = _cut(e.feeShares + e.penaltyShares + e.nonMinterShares);
        if (protocol > 0) _moveFee(FACTORY.owner(), protocol);
        if (creator_ > 0) _moveFee(feeRecipient, creator_);
    }

    /// `PROTOCOL_CUT_BPS` of a redeem's fee and penalty shares to the protocol, the rest to the creator. No minimum.
    function _cut(uint256 fee) private pure returns (uint256 protocol, uint256 creator_) {
        protocol = fee * PROTOCOL_CUT_BPS / BPS;
        creator_ = fee - protocol;
    }

    /// `out` of leg i's `held` leaves the fund: its cost falls by the same part.
    function _takeCost(uint256 i, uint256 out, uint256 held) private {
        if (out > 0) _cost[i] -= Math.mulDiv(_cost[i], out, held);
    }

    /// The factory's `getTradablePriceUsdg`, read without a revert: false when it fails or gives no price.
    function _tradablePrice(address token) private view returns (bool ok, uint256 price) {
        (bool success, bytes memory ret) = address(FACTORY).staticcall(abi.encodeCall(IMaidMarianEtfV4Pricer.getTradablePriceUsdg, (token)));
        if (!success || ret.length != 64) return (false, 0);
        uint256 source;
        (price, source) = abi.decode(ret, (uint256, uint256));
        ok = price > 0 && source != SOURCE_NONE;
    }

    /// Pushes a USDG fee to the factory's `owner()` and `feeRecipient`. Reverts if either is frozen.
    function _pushFees(uint256 protocolFee, uint256 creatorFee) private {
        if (protocolFee > 0) USDG.safeTransfer(FACTORY.owner(), protocolFee);
        if (creatorFee > 0) USDG.safeTransfer(feeRecipient, creatorFee);
    }

    /// Returns to `to` what arrived beyond what the fund keeps.
    function _refund(address to, uint256[] memory received, uint256[] memory used, uint256 usdgReceived, uint256 usdgUsed) private {
        for (uint256 i = 0; i < received.length; i++) {
            if (received[i] > used[i]) _token(i).safeTransfer(to, received[i] - used[i]);
        }
        if (usdgReceived > usdgUsed) USDG.safeTransfer(to, usdgReceived - usdgUsed);
    }

    /// Least USDG a sale must bring: the value at `price` less the tolerance.
    function _sellFloor(uint256 amountIn, uint256 price, uint256 scale) private pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(amountIn, price, scale), BPS - TOLERANCE_BPS, BPS);
    }

    /// Fewest tokens a purchase must bring: the quantity at `price` less the tolerance.
    function _buyFloor(uint256 amountIn, uint256 price, uint256 scale) private pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(amountIn, scale, price), BPS - TOLERANCE_BPS, BPS);
    }

    /// Runs `r` as one swap of leg `leg` against USDG (`sell`: the leg in), written here through the
    /// factory's registered pool: the router pre-funded with `amountIn` by transfer, no approval, one
    /// command, the output to the fund. Then on balances: the fund gave exactly `amountIn`, the router
    /// kept none of it, `tokenOut` rose by at least `minOut`. Returns that rise, all of it the door's:
    /// a pool or hook that pays more than quoted pays the fund, or the minter's refund, never a surplus.
    function _swap(Route calldata r, uint8 leg, bool sell, uint256 minOut) private returns (uint256 amountOut) {
        uint256 amountIn = r.amountIn;
        IERC20 token = _token(leg);
        (IERC20 tokenIn, IERC20 tokenOut) = sell ? (token, USDG) : (USDG, token);
        (, uint24 fee, uint24 v4Fee, int24 v4TickSpacing, address v4Hooks) = FACTORY.poolsOf(address(token));
        bytes[] memory inputs = new bytes[](1);
        bytes memory command;
        if (r.v4) {
            if (v4TickSpacing == 0) revert NoV4Pool(address(token));
            if (amountIn > type(uint128).max || minOut > type(uint128).max) revert BadRoute(leg);
            command = V4_SWAP;
            inputs[0] =
                _v4Input(address(tokenIn), address(tokenOut), PoolKey({ currency0: address(0), currency1: address(0), fee: v4Fee, tickSpacing: v4TickSpacing, hooks: v4Hooks }), amountIn, minOut);
        } else {
            command = V3_SWAP_EXACT_IN;
            // The deployed router reads a sixth field; the five-field form reverts `SliceOutOfBounds()`.
            inputs[0] = abi.encode(address(this), amountIn, minOut, abi.encodePacked(address(tokenIn), fee, address(tokenOut)), false, bytes(""));
        }
        address router = address(UNIVERSAL_ROUTER);
        uint256 inBefore = tokenIn.balanceOf(address(this));
        uint256 routerBefore = tokenIn.balanceOf(router);
        uint256 outBefore = tokenOut.balanceOf(address(this));
        tokenIn.safeTransfer(router, amountIn);
        UNIVERSAL_ROUTER.execute(command, inputs, r.deadline);
        if (tokenIn.balanceOf(address(this)) + amountIn != inBefore || tokenIn.balanceOf(router) != routerBefore) revert InputNotSpent(address(tokenIn));
        amountOut = tokenOut.balanceOf(address(this)) - outBefore;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }

    /// `V4_SWAP`'s input: `SWAP_EXACT_IN_SINGLE` on the pool `(sorted tokens, fee, tickSpacing, hooks)`
    /// of `key` (its currencies filled here), empty hook data, no price limit but `amountOutMinimum`, then
    /// `SETTLE(tokenIn, amountIn, payerIsUser false)` from the router's balance and `TAKE(tokenOut, fund, 0)`,
    /// 0 taking the whole output.
    function _v4Input(address tokenIn, address tokenOut, PoolKey memory key, uint256 amountIn, uint256 minOut) private view returns (bytes memory) {
        bool zeroForOne = tokenIn < tokenOut;
        (key.currency0, key.currency1) = zeroForOne ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        // Both under 2^128, checked by `_swap`.
        // forge-lint: disable-next-line(unsafe-typecast)
        (uint128 amountIn128, uint128 minOut128) = (uint128(amountIn), uint128(minOut));
        ExactInputSingle memory swap = ExactInputSingle({ poolKey: key, zeroForOne: zeroForOne, amountIn: amountIn128, amountOutMinimum: minOut128, minHopPriceX36: 0, hookData: "" });
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(swap);
        actionParams[1] = abi.encode(tokenIn, amountIn, false);
        actionParams[2] = abi.encode(tokenOut, address(this), uint256(0));
        return abi.encode(V4_ACTIONS, actionParams);
    }

    /// Each leg's balance.
    function _balances() private view returns (uint256[] memory balances) {
        uint256 n = LEGS();
        balances = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            balances[i] = _token(i).balanceOf(address(this));
        }
    }

    /// Each leg's holding: `min(count, balance)`. Above the balance, a count is lowered to it (a token that
    /// burns from the fund); below, the rest is a donation.
    function _heldOf(uint256[] memory balances) private view returns (uint256[] memory held) {
        held = new uint256[](balances.length);
        for (uint256 i = 0; i < held.length; i++) {
            held[i] = Math.min(_count[i], balances[i]);
        }
    }

    function _heldAll() private view returns (uint256[] memory held) {
        uint256 n = LEGS();
        held = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            held[i] = Math.min(_count[i], _token(i).balanceOf(address(this)));
        }
    }

    function _usdgNow() private view returns (uint256) {
        return Math.min(_usdgCount, USDG.balanceOf(address(this)));
    }

    /// `min(count, balance)`, or the count itself when the balance cannot be read (`read` false).
    function _heldRead(IERC20 token, uint256 count) private view returns (bool read, uint256 held) {
        uint256 balance;
        (read, balance) = _readUint(address(token), abi.encodeCall(IERC20.balanceOf, (address(this))));
        held = read ? Math.min(count, balance) : count;
    }

    /// What the fund counts of `token`: its leg's count, the USDG count, 0 for any other token.
    function _countOf(address token) private view returns (uint256) {
        if (token == address(USDG)) return _usdgCount;
        uint256 n = LEGS();
        for (uint256 i = 0; i < n; i++) {
            if (address(_token(i)) == token) return _count[i];
        }
        return 0;
    }

    /// The fund now: each leg's balance and price (a zero price counts as none), `nav`, targets among the
    /// priced legs. `tradable`: the rebalance's prices (`getTradablePriceUsdg`), else the display's.
    function _snapshot(bool tradable) private view returns (Snapshot memory s) {
        uint256 n = LEGS();
        s.legs = new State[](n);
        s.usdgHeld = _usdgNow();
        s.nav = s.usdgHeld;
        for (uint256 i = 0; i < n; i++) {
            LegConfig memory c = _leg(i);
            State memory l = s.legs[i];
            l.held = Math.min(_count[i], c.token.balanceOf(address(this)));
            (l.price, l.source) = tradable ? FACTORY.getTradablePriceUsdg(address(c.token)) : FACTORY.getPriceUsdg(address(c.token));
            if (l.source == SOURCE_NONE || l.price == 0) {
                (l.price, l.source) = (0, SOURCE_NONE);
                continue;
            }
            l.value = Math.mulDiv(l.held, l.price, c.scale);
            s.nav += l.value;
            s.pricedBps += c.bps;
            s.pricedCount++;
        }
        for (uint256 i = 0; i < n; i++) {
            State memory l = s.legs[i];
            if (l.source != SOURCE_NONE) l.target = Math.mulDiv(s.nav, _leg(i).bps, s.pricedBps);
        }
    }

    /// Out of band when `gap x 10 000 > band x nav`, exact; a leg at the edge is in band.
    function _due(State memory l, uint256 nav_) private view returns (bool due, bool sell, uint256 gap) {
        if (l.source == SOURCE_NONE) return (false, false, 0);
        uint256 target = l.target;
        sell = l.value > target;
        gap = sell ? l.value - target : target - l.value;
        due = gap * BPS > REBALANCE_BAND_BPS() * nav_;
    }

    /// Whether every priced leg is in band after the trades, at the snapshot's prices, on the counts.
    function _noneDueAfter(Snapshot memory before) private view returns (bool) {
        if (before.pricedCount == 0) return true;
        uint256 n = LEGS();
        State[] memory afterLegs = new State[](n);
        uint256 navAfter = _usdgCount;
        for (uint256 i = 0; i < n; i++) {
            State memory b = before.legs[i];
            State memory a = afterLegs[i];
            a.source = b.source;
            if (b.source == SOURCE_NONE) continue;
            a.value = Math.mulDiv(_count[i], b.price, _leg(i).scale);
            navAfter += a.value;
        }
        for (uint256 i = 0; i < n; i++) {
            State memory a = afterLegs[i];
            if (a.source == SOURCE_NONE) continue;
            a.target = Math.mulDiv(navAfter, _leg(i).bps, before.pricedBps);
            (bool due,,) = _due(a, navAfter);
            if (due) return false;
        }
        return true;
    }

    /// Both redeems start here: the split, `mintOf` lowered by the covered part, the supply before burns.
    function _exit(uint256 shares) private returns (Exit memory e) {
        if (shares == 0) revert NothingToRedeem();
        e = _exitSplit(msg.sender, mintOf[msg.sender], shares);
        mintOf[msg.sender] -= e.covered;
        e.supply = totalSupply();
    }

    /// `holder`'s `mintOf` as the next door sees it: the management fee due counts for its recipients.
    function _mintOfAtDoor(address holder) private view returns (uint256 minted) {
        minted = mintOf[holder];
        (uint256 creatorPending, uint256 protocolPending) = pendingManagementFee();
        if (holder == feeRecipient) minted += creatorPending;
        if (holder == FACTORY.owner()) minted += protocolPending;
    }

    /// A redeem's split. Minted shares go first: `covered = min(shares, mintOf)`. Rates add, never compound:
    /// exit fee on all, early penalty on `covered` within the hold period, non-minter penalty on the rest.
    /// The bounds keep `paid` from underflowing.
    function _exitSplit(address holder, uint256 minted, uint256 shares) private view returns (Exit memory e) {
        e.covered = Math.min(shares, minted);
        e.feeShares = shares * EXIT_FEE_BPS() / BPS;
        if (block.timestamp < lastMintAt[holder] + HOLD_PERIOD()) e.penaltyShares = e.covered * EARLY_PENALTY_BPS() / BPS;
        e.nonMinterShares = (shares - e.covered) * NON_MINTER_PENALTY_BPS() / BPS;
        e.paid = shares - e.feeShares - e.penaltyShares - e.nonMinterShares;
    }

    /// `safeTransfer`, or with the `allowFail` bit set (or `mayFail`) a low-level `transfer` that returns false on failure.
    function _pay(IERC20 token, address to, uint256 amount, uint16 allowFail, uint256 bit, bool mayFail) private returns (bool) {
        // `1 << bit` is the mask of bit `bit`, the intended order.
        // forge-lint: disable-next-line(incorrect-shift)
        if (!mayFail && allowFail & (1 << bit) == 0) {
            token.safeTransfer(to, amount);
            return true;
        }
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (uint256)) == 1));
    }

    /// `len` (1 - 32) bytes of the clone's arguments from `offset`, big-endian. `extcodecopy` of the running
    /// account: warm, about 110 gas a read.
    function _arg(uint256 offset, uint256 len) private view returns (uint256 v) {
        assembly ("memory-safe") {
            extcodecopy(address(), 0, add(CLONE_CODE_BYTES, offset), 32)
            v := shr(sub(256, shl(3, len)), mload(0))
        }
    }

    /// Leg `i`'s token, bps and decimals; the casts take the low bytes of the 23 read.
    function _legArgs(uint256 i) private view returns (IERC20 token, uint16 bps, uint8 decimals) {
        uint256 v = _arg(ETF_V3_ARGS_LEGS + i * ETF_V3_ARGS_LEG_BYTES, ETF_V3_ARGS_LEG_BYTES);
        // forge-lint: disable-start(unsafe-typecast)
        (token, bps, decimals) = (IERC20(address(uint160(v >> 24))), uint16(v >> 8), uint8(v));
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// Leg `i` with its scale; its decimals were checked at 36 at most by `initialize`.
    function _leg(uint256 i) private view returns (LegConfig memory c) {
        (IERC20 token, uint16 bps, uint8 decimals) = _legArgs(i);
        c = LegConfig({ token: token, bps: bps, decimals: decimals, scale: 10 ** uint256(decimals) * FIRST_SHARES_PER_UNIT });
    }

    function _token(uint256 i) private view returns (IERC20) {
        return IERC20(address(uint160(_arg(ETF_V3_ARGS_LEGS + i * ETF_V3_ARGS_LEG_BYTES, 20))));
    }

    /// Where the name's length byte is, after the legs.
    function _namesAt() private view returns (uint256) {
        return ETF_V3_ARGS_LEGS + LEGS() * ETF_V3_ARGS_LEG_BYTES;
    }

    /// The string whose length byte is at `pos`.
    function _argString(uint256 pos) private view returns (string memory s) {
        uint256 len = _arg(pos, 1);
        s = new string(len);
        assembly ("memory-safe") {
            extcodecopy(address(), add(s, 32), add(CLONE_CODE_BYTES, add(pos, 1)), len)
        }
    }

    /// A one-word answer to a static call; `ok == false` otherwise.
    function _readUint(address target, bytes memory data) private view returns (bool ok, uint256 value) {
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }
}
