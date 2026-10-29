// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

// The contract exactly as deployed from git 45553e5, renamed `...Ref` and its imports repointed: the
// reference `MaidMarianEtfV3Bis.t.sol` compares every door's shares against. Not deployed from here.

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IUniversalRouter } from "../../src/MaidMarianSevenMagnificent.sol";

// `getPriceUsd` sources, shared by the factory and the ETF. 1 is not used.
uint8 constant SOURCE_NONE = 0;
uint8 constant SOURCE_POOL = 2;
uint8 constant SOURCE_NAV = 3;
uint8 constant SOURCE_SPOT = 4;

// Rules fixed for every ETF of the factory, file-level so the factory imports the same numbers.
uint256 constant ETF_V3_CREATOR_MANAGEMENT_FEE_BPS = 30;
uint256 constant ETF_V3_PROTOCOL_MANAGEMENT_FEE_BPS = 20;
uint256 constant ETF_V3_TOLERANCE_BPS = 50;
// The protocol's cut of the creator's entry and exit fees (30 %), and its least part at entry (0.10 %).
uint256 constant ETF_V3_PROTOCOL_CUT_BPS = 3000;
uint256 constant ETF_V3_PROTOCOL_MIN_ENTRY_BPS = 10;

/// Bounds of every creator-chosen parameter, both inclusive, read by the ETF's constructor and the factory's
/// `paramBounds()`. `nonMinterPenaltyBps` is also capped at 10 000 - `exitFeeBps`, and `earlyPenaltyBps` at
/// `nonMinterPenaltyBps`, so a transfer to a fresh address never pays less. Band 10 - 5 000 points:
/// under 10, every move trades dust at the pool's fee; over 5 000, a 50 % leg never trades. A band wider
/// than a leg's weight never buys that leg back from 0.
function etfV3ParamBounds() pure returns (MaidMarianEtfV3Ref.Params memory lo, MaidMarianEtfV3Ref.Params memory hi) {
    lo = MaidMarianEtfV3Ref.Params({ entryFeeBps: 0, exitFeeBps: 0, holdPeriod: 0, earlyPenaltyBps: 0, nonMinterPenaltyBps: 0, rebalanceBandBps: 10, rebalanceMinInterval: 0 });
    hi = MaidMarianEtfV3Ref.Params({ entryFeeBps: 500, exitFeeBps: 500, holdPeriod: 30 days, earlyPenaltyBps: 5000, nonMinterPenaltyBps: 10_000, rebalanceBandBps: 5000, rebalanceMinInterval: 24 hours });
}

/// What an ETF reads from its factory: prices, each token's pools, its logo, and the owner who receives the protocol's fees.
interface IMaidMarianEtfPricerRef {
    function getPriceUsd(address token) external view returns (uint256 price, uint8 source);
    function getTradablePriceUsd(address token) external view returns (uint256 price, uint8 source);
    function poolsOf(address token) external view returns (address pool, uint24 fee, uint24 v4Fee, int24 v4TickSpacing);
    function logo(address etf) external view returns (bytes memory);
    function owner() external view returns (address);
}

/**
 * @title Maid Marian ETF v3
 * @notice One ERC-20 holding 1 to 10 legs at fixed weights in bps (sum 10 000), created by
 * `MaidMarianEtfFactoryRef.createEtf`. No owner: nobody changes the legs, the weights or the parameters.
 *
 * Doors. Mint and redeem read no price: shares follow what the fund already holds.
 *  - `mint`: USDG in, the caller's routes buy the legs. Entry fee in USDG.
 *  - `mintInKind`: the caller brings the legs and the USDG part. Entry fee in shares.
 *  - `redeem`: the caller's routes sell the legs for USDG, the rest paid in kind. Exit fee in shares.
 *  - `redeemInKind`: each leg's share and the USDG's; no route, always works. Exit fee in shares.
 *  - `rebalance`: anyone, once per `REBALANCE_MIN_INTERVAL`, trades legs out of band back to target.
 * Routes: every swap is written whole by the contract (`Route`), only against USDG and only through
 * the token's pool registered in the factory: one `V3_SWAP_EXACT_IN` single hop through its V3 pool,
 * or one `V4_SWAP` through its hookless V4 pool if it has one. The fund pays exactly `amountIn` and
 * receives the output; no other command.
 * Fees: entry and exit chosen by the creator, 30 % of them to the protocol (0.10 % least at entry);
 * management 0.50 % a year in shares (0.30 % creator, 0.20 % protocol), accrued at every door;
 * the exit fee and the penalties in shares, split as the exit fee. The first mint locks `DEAD_SHARES`
 * at `DEAD`, so the supply never returns to 0.
 * Danger: the factory's owner chooses those pools. A caller is protected by his own `amountOutMin`,
 * the fund by the rebalance's floor, the holders by the in-kind formula.
 */
contract MaidMarianEtfV3Ref is ERC20, ReentrancyGuard {
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

    // ---------------------------------------------------------------- types ---

    struct LegInit {
        address token;
        uint16 bps;
        uint8 decimals;
    }

    /// The creator's choices, checked against `paramBounds()` at construction, immutable after:
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
    ///  - `v4` true: its hookless V4 pool; `NoV4Pool` if the factory registered none.
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

    /// A leg as `legs()` returns it: `price` in USDG per whole token (18 decimals), `value` and `target` in USDG (0 when unpriced).
    struct Leg {
        address token;
        uint16 bps;
        uint8 decimals;
        uint256 held;
        uint256 price;
        uint8 source;
        uint256 value;
        uint256 target;
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

    // ----------------------------------------------------------- immutables ---

    /// The factory: prices, logo, and through `owner()` the protocol's fee recipient.
    IMaidMarianEtfPricerRef public immutable FACTORY;

    IERC20 public immutable USDG;

    /// The Uniswap Universal Router every swap runs on.
    IUniversalRouter public immutable UNIVERSAL_ROUTER;

    uint256 public immutable LEGS;

    uint256 public immutable ENTRY_FEE_BPS;
    uint256 public immutable EXIT_FEE_BPS;
    uint256 public immutable HOLD_PERIOD;
    uint256 public immutable EARLY_PENALTY_BPS;
    uint256 public immutable NON_MINTER_PENALTY_BPS;
    uint256 public immutable REBALANCE_BAND_BPS;
    uint256 public immutable REBALANCE_MIN_INTERVAL;

    /// Shares per USDG unit at the first mint: one whole share per whole USDG.
    uint256 private immutable FIRST_SHARES_PER_UNIT;

    // ---------------------------------------------------------------- legs ---

    /// A leg, written once. Value in USDG units = `held x price / scale`,
    /// `scale = 10 ** (decimals + 18 - USDG decimals)`.
    struct LegConfig {
        IERC20 token;
        uint16 bps;
        uint8 decimals;
        uint256 scale;
    }

    LegConfig[MAX_LEGS] private _legs;

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

    /// Called by the factory (`FACTORY = msg.sender`), which checked the legs; rechecks what it can and the parameters.
    constructor(string memory name_, string memory symbol_, LegInit[] memory legs_, Params memory p, IERC20 usdg, IUniversalRouter router, address creator_) ERC20(name_, symbol_) {
        if (address(usdg) == address(0) || address(router) == address(0) || creator_ == address(0)) revert ZeroAddress();
        if (address(usdg).code.length == 0) revert NoCode(address(usdg));
        if (address(router).code.length == 0) revert NoCode(address(router));
        _checkParams(p);
        uint256 n = legs_.length;
        if (n == 0 || n > MAX_LEGS) revert BadLegCount(n);
        (bool usdgOk, uint256 usdgDecimals) = _readUint(address(usdg), abi.encodeWithSelector(0x313ce567)); // decimals()
        if (!usdgOk || usdgDecimals > 18) revert BadToken(address(usdg));

        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            LegInit memory l = legs_[i];
            if (l.token == address(0)) revert ZeroAddress();
            if (l.token == address(usdg)) revert DuplicateToken(l.token);
            if (l.token.code.length == 0) revert NoCode(l.token);
            if (l.decimals > 36) revert BadToken(l.token);
            if (l.bps == 0) revert BadBps(0);
            for (uint256 j = 0; j < i; j++) {
                if (legs_[j].token == l.token) revert DuplicateToken(l.token);
            }
            total += l.bps;
            _legs[i] = LegConfig({ token: IERC20(l.token), bps: l.bps, decimals: l.decimals, scale: 10 ** (uint256(l.decimals) + 18 - usdgDecimals) });
        }
        if (total != BPS) revert BadBps(total);

        FACTORY = IMaidMarianEtfPricerRef(msg.sender);
        USDG = usdg;
        UNIVERSAL_ROUTER = router;
        LEGS = n;
        FIRST_SHARES_PER_UNIT = 10 ** (18 - usdgDecimals);
        ENTRY_FEE_BPS = p.entryFeeBps;
        EXIT_FEE_BPS = p.exitFeeBps;
        HOLD_PERIOD = p.holdPeriod;
        EARLY_PENALTY_BPS = p.earlyPenaltyBps;
        NON_MINTER_PENALTY_BPS = p.nonMinterPenaltyBps;
        REBALANCE_BAND_BPS = p.rebalanceBandBps;
        REBALANCE_MIN_INTERVAL = p.rebalanceMinInterval;
        creator = creator_;
        feeRecipient = creator_;
        lastAccrualAt = block.timestamp;
    }

    /// @notice Every parameter's bounds, both inclusive. Also `nonMinterPenaltyBps` <= 10 000 - `exitFeeBps`
    /// and `earlyPenaltyBps` <= `nonMinterPenaltyBps`.
    function paramBounds() public pure returns (Params memory lo, Params memory hi) {
        return etfV3ParamBounds();
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

    function _bound(uint256 value, uint256 lo, uint256 hi, string memory name) private pure {
        if (value < lo || value > hi) revert ParamOutOfBounds(name);
    }

    // ---------------------------------------------------------------- doors ---

    /// @notice Buy in with USDG. The entry fee (`entryFee(usdgIn)`) is taken first and pushed at once;
    /// `routes[i]` spends the rest on leg i (one route per leg, 0 skips it), for at least its `amountOutMin`.
    /// @dev Shares = `totalSupply x min(received_i / held_i)` over the legs and the USDG left, rounded down;
    /// `received_i` is what route i's swap brought, the USDG left what no route spent: nothing else is
    /// credited. The fund keeps `ceil(held_i x shares / totalSupply)` of each and refunds the rest, so no
    /// holder's tokens per share can fall. First mint: routes must equal `firstMintSplit(usdgIn)`, each
    /// delivering something, one share per USDG kept, `DEAD_SHARES` of them locked at `DEAD`.
    /// A frozen fee recipient makes this revert.
    function mint(uint256 usdgIn, Route[] calldata routes, uint256 minShares) external nonReentrant returns (uint256 shares) {
        _accrue();
        if (usdgIn == 0) revert NothingToMint();
        uint256 n = LEGS;
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
                if (split[i] == 0) revert NothingDelivered(address(_legs[i].token));
            }
        } else if (routed > net) {
            revert RoutesOverspend(routed, net);
        }

        uint256[] memory held = _heldAll();
        uint256 usdgHeld = USDG.balanceOf(address(this));
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
                if (received[i] == 0) revert NothingDelivered(address(_legs[i].token));
            }
            gross = net * FIRST_SHARES_PER_UNIT;
            if (gross <= DEAD_SHARES) revert TooFewShares(0, minShares);
            _mint(DEAD, DEAD_SHARES);
            (gross, used, usdgUsed) = (gross - DEAD_SHARES, received, usdgReceived);
        } else {
            (gross, used, usdgUsed) = _keep(supply, held, received, usdgHeld, usdgReceived);
        }
        (shares,,) = _issue(gross, minShares, false);
        _refund(received, used, usdgReceived, usdgUsed);
        emit Minted(msg.sender, false, usdgIn, shares, protocolFee, creatorFee, used, usdgUsed);
    }

    /// @notice Bring the legs and the USDG part yourself; `mint`'s formula applies, the excess refunded.
    /// @dev Entry fee in shares: valuing tokens in USDG would need a price. Not for the first mint.
    function mintInKind(uint256[] calldata amounts, uint256 usdgAmount, uint256 minShares) external nonReentrant returns (uint256 shares) {
        _accrue();
        uint256 n = LEGS;
        if (amounts.length != n) revert WrongLength(amounts.length, n);
        uint256 supply = totalSupply();
        if (supply == 0) revert FirstMintIsUsdg();

        uint256[] memory held = _heldAll();
        uint256 usdgHeld = USDG.balanceOf(address(this));
        for (uint256 i = 0; i < n; i++) {
            if (amounts[i] > 0) _legs[i].token.safeTransferFrom(msg.sender, address(this), amounts[i]);
        }
        if (usdgAmount > 0) USDG.safeTransferFrom(msg.sender, address(this), usdgAmount);
        uint256[] memory received = _heldAll();
        for (uint256 i = 0; i < n; i++) {
            received[i] -= held[i];
        }
        uint256 usdgReceived = USDG.balanceOf(address(this)) - usdgHeld;

        (uint256 gross, uint256[] memory used, uint256 usdgUsed) = _keep(supply, held, received, usdgHeld, usdgReceived);
        uint256 protocolFee;
        uint256 creatorFee;
        (shares, protocolFee, creatorFee) = _issue(gross, minShares, true);
        _refund(received, used, usdgReceived, usdgUsed);
        emit Minted(msg.sender, true, usdgAmount, shares, protocolFee, creatorFee, used, usdgUsed);
    }

    /// @notice Leave for USDG: `routes[i]` sells up to leg i's due for at least its `amountOutMin`; what is
    /// not sold is paid in kind.
    /// @dev As `redeemInKind`: the exit fee and the penalties are moved in shares first, only the shares
    /// paid are burned, and leg i's due is `held_i x paid / supply`, the fund's USDG in the same part.
    /// No fee in USDG, so no recipient is paid here.
    function redeem(uint256 shares, Route[] calldata routes, uint256 minUsdgOut, address to) external nonReentrant returns (uint256 usdgOut) {
        _accrue();
        if (to == address(0)) revert ZeroAddress();
        uint256 n = LEGS;
        if (routes.length != n) revert WrongLength(routes.length, n);
        Exit memory e = _exit(shares);
        uint256[] memory held = _heldAll();
        usdgOut = Math.mulDiv(USDG.balanceOf(address(this)), e.paid, e.supply);
        (uint256 protocolFee, uint256 creatorFee) = _takeFees(e);
        _burn(msg.sender, e.paid);

        uint256[] memory inKind = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            IERC20 token = _legs[i].token;
            uint256 due = Math.mulDiv(held[i], e.paid, e.supply);
            uint256 amountIn = routes[i].amountIn;
            if (amountIn > due) revert OverRedeem(address(token), amountIn, due);
            if (due == 0) continue;
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
    /// @dev `allowFail` bit i (`USDG_BIT` for USDG) lets that transfer fail: the amount stays in the fund
    /// and `forfeited` names it. A leg whose balance cannot be read is paid nothing and named too, whatever
    /// `allowFail` says. A transfer that succeeds always delivers.
    function redeemInKind(uint256 shares, address to, uint16 allowFail) external nonReentrant {
        _accrue();
        if (to == address(0)) revert ZeroAddress();
        uint256 n = LEGS;
        Exit memory e = _exit(shares);
        (uint256 paid, uint256 supply) = (e.paid, e.supply);
        uint256 usdgOut = Math.mulDiv(USDG.balanceOf(address(this)), paid, supply);
        (uint256 protocolFee, uint256 creatorFee) = _takeFees(e);
        _burn(msg.sender, paid);

        uint16 forfeited;
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            IERC20 token = _legs[i].token;
            (bool read, uint256 held) = _readUint(address(token), abi.encodeCall(IERC20.balanceOf, (address(this))));
            uint256 due = Math.mulDiv(held, paid, supply);
            if (read && due == 0) continue;
            if (!read || !_pay(token, to, due, allowFail, i)) {
                // forge-lint: disable-next-line(incorrect-shift)
                forfeited |= uint16(1 << i);
                continue;
            }
            amounts[i] = due;
        }
        if (usdgOut > 0 && !_pay(USDG, to, usdgOut, allowFail, USDG_BIT)) {
            forfeited |= uint16(1 << USDG_BIT);
            usdgOut = 0;
        }
        emit RedeemedInKind(msg.sender, to, shares, protocolFee, creatorFee, e.covered, e.penaltyShares, e.nonMinterShares, amounts, usdgOut, forfeited);
    }

    /// @notice Trade legs out of band back toward their targets. Anyone, once per `REBALANCE_MIN_INTERVAL`.
    /// @dev Accrues the management fee first, as every door does. Each leg is priced once by the factory's `getTradablePriceUsd`
    /// (NAV, else TWAP 30 min, never a spot); a leg without that price is skipped (`LegUnpriced`), out of
    /// the NAV and the targets. A leg is due when its weight is more than `REBALANCE_BAND_BPS` points from
    /// target. Routes: sells before buys, at most the gap; the floor (price less `TOLERANCE_BPS`) is written
    /// into the swap and checked again after. The window closes only if a route ran and every priced leg
    /// ends in band. An empty `routes` only accrues the fee.
    function rebalance(Route[] calldata routes) external nonReentrant {
        uint256 readyAt = lastRebalanceAt + REBALANCE_MIN_INTERVAL;
        if (block.timestamp < readyAt) revert TooSoon(readyAt);

        (uint256 creatorFee, uint256 protocolFee) = _accrue();

        uint256 n = LEGS;
        Snapshot memory s = _snapshot(true);
        for (uint256 i = 0; i < n; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (s.legs[i].source == SOURCE_NONE) emit LegUnpriced(uint8(i), address(_legs[i].token));
        }

        uint256 seen;
        bool buying;
        for (uint256 k = 0; k < routes.length; k++) {
            Route calldata r = routes[k];
            if (r.leg >= n) revert UnknownLeg(r.leg);
            LegConfig memory c = _legs[r.leg];
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
            } else {
                if (r.amountIn > gap) revert OverTrade(address(c.token), r.amountIn, gap);
                minOut = _buyFloor(r.amountIn, l.price, c.scale);
            }
            uint256 amountOut = _swap(r, r.leg, r.sell, minOut);
            emit LegTraded(address(c.token), r.sell, r.amountIn, amountOut, minOut, l.price, l.source);
        }

        bool closed = routes.length > 0 && _noneDueAfter(s);
        if (closed) lastRebalanceAt = block.timestamp;
        emit Rebalanced(msg.sender, s.nav, s.pricedCount, routes.length, creatorFee, protocolFee, closed);
    }

    /// @notice Hand the creator role to `next`. Creator only; `feeRecipient` is unchanged.
    function setCreator(address next) external {
        if (msg.sender != creator) revert NotCreator();
        if (next == address(0)) revert ZeroAddress();
        emit CreatorChanged(creator, next);
        creator = next;
    }

    /// @notice Send the creator's fee part to `next`. Creator only.
    /// @dev USDG can freeze an address: a frozen recipient blocks `mint` until moved.
    function setFeeRecipient(address next) external {
        if (msg.sender != creator) revert NotCreator();
        if (next == address(0)) revert ZeroAddress();
        emit FeeRecipientChanged(feeRecipient, next);
        feeRecipient = next;
    }

    // ---------------------------------------------------------------- views ---

    /// @notice The legs, priced for display: a spot price shown here is one `rebalance` skips.
    function legs() external view returns (Leg[] memory out) {
        Snapshot memory s = _snapshot(false);
        uint256 n = LEGS;
        out = new Leg[](n);
        for (uint256 i = 0; i < n; i++) {
            LegConfig memory c = _legs[i];
            State memory l = s.legs[i];
            out[i] = Leg({ token: address(c.token), bps: c.bps, decimals: c.decimals, held: l.held, price: l.price, source: l.source, value: l.value, target: l.target });
        }
    }

    /// @notice The parameters as constructed (each cast fits: every value was checked against its bound).
    function params() external view returns (Params memory p) {
        // forge-lint: disable-start(unsafe-typecast)
        p = Params({
            entryFeeBps: uint16(ENTRY_FEE_BPS),
            exitFeeBps: uint16(EXIT_FEE_BPS),
            holdPeriod: uint32(HOLD_PERIOD),
            earlyPenaltyBps: uint16(EARLY_PENALTY_BPS),
            nonMinterPenaltyBps: uint16(NON_MINTER_PENALTY_BPS),
            rebalanceBandBps: uint16(REBALANCE_BAND_BPS),
            rebalanceMinInterval: uint32(REBALANCE_MIN_INTERVAL)
        });
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice Fund value in USDG at `legs()`'s prices; `complete` is false when a leg is unpriced (left out).
    function nav() external view returns (uint256 value, bool complete) {
        Snapshot memory s = _snapshot(false);
        return (s.nav, s.pricedCount == LEGS);
    }

    /// @notice What a mint keeps for `grossShares`: `ceil(held_i x grossShares / supply)` of each leg and of the USDG.
    /// @dev Every preview divides by the supply once the door has accrued the management fee.
    function quoteMint(uint256 grossShares) external view returns (uint256[] memory amounts, uint256 usdg) {
        uint256 n = LEGS;
        amounts = new uint256[](n);
        uint256 supply = accruedSupply();
        if (supply == 0) return (amounts, 0);
        uint256[] memory held = _heldAll();
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = Math.mulDiv(held[i], grossShares, supply, Math.Rounding.Ceil);
        }
        usdg = Math.mulDiv(USDG.balanceOf(address(this)), grossShares, supply, Math.Rounding.Ceil);
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
        total = Math.mulDiv(amount, Math.max(ENTRY_FEE_BPS, PROTOCOL_MIN_ENTRY_BPS), BPS);
        protocol = Math.max(Math.mulDiv(amount, PROTOCOL_MIN_ENTRY_BPS, BPS), Math.mulDiv(amount, ENTRY_FEE_BPS * PROTOCOL_CUT_BPS, BPS * BPS));
        creator_ = total - protocol;
    }

    /// @notice What `mintInKind` would mint now: the caller's shares and the fee's two parts. Zeros if empty or wrong length.
    function previewMintInKind(uint256[] calldata amounts, uint256 usdgAmount) external view returns (uint256 shares, uint256 protocolFeeShares, uint256 creatorFeeShares) {
        uint256 supply = accruedSupply();
        if (supply == 0 || amounts.length != LEGS) return (0, 0, 0);
        (uint256 gross,,) = _keep(supply, _heldAll(), amounts, USDG.balanceOf(address(this)), usdgAmount);
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
    /// `redeemInKind` pays that leg nothing.
    function previewRedeem(address holder, uint256 shares) public view returns (uint256 paid, uint256 feeShares, uint256 penaltyShares, uint256[] memory amounts, uint256 usdg) {
        uint256 n = LEGS;
        amounts = new uint256[](n);
        uint256 supply = accruedSupply();
        if (supply == 0 || shares == 0) return (0, 0, 0, amounts, 0);
        Exit memory e = _exitSplit(holder, shares);
        (paid, feeShares, penaltyShares) = (e.paid, e.feeShares, e.penaltyShares + e.nonMinterShares);
        uint256[] memory held = _heldAll();
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = Math.mulDiv(held[i], paid, supply);
        }
        usdg = Math.mulDiv(USDG.balanceOf(address(this)), paid, supply);
    }

    /// @notice The trades `rebalance` would accept now, sells first, each at full size; buys never exceed the
    /// USDG held plus the sells' floors, so the plan runs as listed.
    function plan() external view returns (PlanLeg[] memory out) {
        Snapshot memory s = _snapshot(true);
        uint256 n = LEGS;
        PlanLeg[] memory rows = new PlanLeg[](n);
        uint256 count;
        uint256 usdgAvailable = s.usdgHeld;
        for (uint256 pass = 0; pass < 2; pass++) {
            bool wantSell = pass == 0;
            for (uint256 i = 0; i < n; i++) {
                State memory l = s.legs[i];
                (bool due, bool sell, uint256 gap) = _due(l, s.nav);
                if (!due || sell != wantSell) continue;
                uint256 scale = _legs[i].scale;
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
                rows[count++] = PlanLeg({ leg: uint8(i), token: address(_legs[i].token), sell: sell, amountIn: amountIn, minOut: minOut, deviationBps: deviation });
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
        readyAt = lastRebalanceAt + REBALANCE_MIN_INTERVAL;
        ready = block.timestamp >= readyAt;
    }

    /// @notice `holder`'s redeem rates in bps: `coveredBps` on shares within `mintOf`, `otherBps` on the rest.
    /// They add, never compound, and are moved in shares to the protocol and `feeRecipient`.
    function exitRates(address holder) external view returns (uint256 coveredBps, uint256 otherBps, uint256 covered, uint256 holdEndsAt) {
        holdEndsAt = lastMintAt[holder] + HOLD_PERIOD;
        coveredBps = block.timestamp < holdEndsAt ? EXIT_FEE_BPS + EARLY_PENALTY_BPS : EXIT_FEE_BPS;
        otherBps = EXIT_FEE_BPS + NON_MINTER_PENALTY_BPS;
        covered = mintOf[holder];
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
        uint256 n = LEGS;
        amounts = new uint256[](n);
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = usdgIn * _legs[i].bps / BPS;
            sum += amounts[i];
        }
        amounts[0] += usdgIn - sum;
    }

    /// The in-kind formula: `gross = supply x min(received_i / held_i)`, then keep `ceil(held_i x gross / supply)`,
    /// never above `received_i`. A leg the fund does not hold keeps nothing.
    function _keep(uint256 supply, uint256[] memory held, uint256[] memory received, uint256 usdgHeld, uint256 usdgReceived)
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
        if (usdgHeld > 0) gross = Math.min(gross, Math.mulDiv(supply, usdgReceived, usdgHeld));
        if (gross == type(uint256).max) gross = 0;
        used = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            used[i] = Math.mulDiv(held[i], gross, supply, Math.Rounding.Ceil);
        }
        usdgUsed = Math.mulDiv(usdgHeld, gross, supply, Math.Rounding.Ceil);
    }

    /// Mints `gross` to the caller (less the entry fee in shares when `inKind`), into its `mintOf`, clock restarted.
    function _issue(uint256 gross, uint256 minShares, bool inKind) private returns (uint256 shares, uint256 protocolFee, uint256 creatorFee) {
        shares = gross;
        if (inKind) {
            uint256 fee;
            (fee, protocolFee, creatorFee) = entryFee(gross);
            shares = gross - fee;
        }
        if (shares == 0 || shares < minShares) revert TooFewShares(shares, minShares);
        if (protocolFee > 0) _mintFee(FACTORY.owner(), protocolFee);
        if (creatorFee > 0) _mintFee(feeRecipient, creatorFee);
        _mint(msg.sender, shares);
        mintOf[msg.sender] += shares;
        lastMintAt[msg.sender] = block.timestamp;
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

    /// Pushes a USDG fee to the factory's `owner()` and `feeRecipient`. Reverts if either is frozen.
    function _pushFees(uint256 protocolFee, uint256 creatorFee) private {
        if (protocolFee > 0) USDG.safeTransfer(FACTORY.owner(), protocolFee);
        if (creatorFee > 0) USDG.safeTransfer(feeRecipient, creatorFee);
    }

    /// Returns to the caller what arrived beyond what the fund keeps.
    function _refund(uint256[] memory received, uint256[] memory used, uint256 usdgReceived, uint256 usdgUsed) private {
        for (uint256 i = 0; i < received.length; i++) {
            if (received[i] > used[i]) _legs[i].token.safeTransfer(msg.sender, received[i] - used[i]);
        }
        if (usdgReceived > usdgUsed) USDG.safeTransfer(msg.sender, usdgReceived - usdgUsed);
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
    /// kept none of it, `tokenOut` rose by at least `minOut`. Returns that rise.
    function _swap(Route calldata r, uint8 leg, bool sell, uint256 minOut) private returns (uint256 amountOut) {
        uint256 amountIn = r.amountIn;
        IERC20 token = _legs[leg].token;
        (IERC20 tokenIn, IERC20 tokenOut) = sell ? (token, USDG) : (USDG, token);
        (, uint24 fee, uint24 v4Fee, int24 v4TickSpacing) = FACTORY.poolsOf(address(token));
        bytes[] memory inputs = new bytes[](1);
        bytes memory command;
        if (r.v4) {
            if (v4TickSpacing == 0) revert NoV4Pool(address(token));
            if (amountIn > type(uint128).max || minOut > type(uint128).max) revert BadRoute(leg);
            command = V4_SWAP;
            inputs[0] = _v4Input(address(tokenIn), address(tokenOut), v4Fee, v4TickSpacing, amountIn, minOut);
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

    /// `V4_SWAP`'s input: `SWAP_EXACT_IN_SINGLE` on the pool `(sorted tokens, fee, tickSpacing, no hook)`,
    /// no price limit but `amountOutMinimum`, then `SETTLE(tokenIn, amountIn, payerIsUser false)` from the
    /// router's balance and `TAKE(tokenOut, fund, 0)`, 0 taking the whole output.
    function _v4Input(address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, uint256 amountIn, uint256 minOut) private view returns (bytes memory) {
        bool zeroForOne = tokenIn < tokenOut;
        (address c0, address c1) = zeroForOne ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        PoolKey memory key = PoolKey({ currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: address(0) });
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

    function _heldAll() private view returns (uint256[] memory held) {
        uint256 n = LEGS;
        held = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            held[i] = _legs[i].token.balanceOf(address(this));
        }
    }

    /// The fund now: each leg's balance and price (a zero price counts as none), `nav`, targets among the
    /// priced legs. `tradable`: the rebalance's prices (`getTradablePriceUsd`), else the display's.
    function _snapshot(bool tradable) private view returns (Snapshot memory s) {
        uint256 n = LEGS;
        s.legs = new State[](n);
        s.usdgHeld = USDG.balanceOf(address(this));
        s.nav = s.usdgHeld;
        for (uint256 i = 0; i < n; i++) {
            LegConfig memory c = _legs[i];
            State memory l = s.legs[i];
            l.held = c.token.balanceOf(address(this));
            (l.price, l.source) = tradable ? FACTORY.getTradablePriceUsd(address(c.token)) : FACTORY.getPriceUsd(address(c.token));
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
            if (l.source != SOURCE_NONE) l.target = Math.mulDiv(s.nav, _legs[i].bps, s.pricedBps);
        }
    }

    /// Out of band when `gap x 10 000 > band x nav`, exact; a leg at the edge is in band.
    function _due(State memory l, uint256 nav_) private view returns (bool due, bool sell, uint256 gap) {
        if (l.source == SOURCE_NONE) return (false, false, 0);
        uint256 target = l.target;
        sell = l.value > target;
        gap = sell ? l.value - target : target - l.value;
        due = gap * BPS > REBALANCE_BAND_BPS * nav_;
    }

    /// Whether every priced leg is in band after the trades, at the snapshot's prices.
    function _noneDueAfter(Snapshot memory before) private view returns (bool) {
        if (before.pricedCount == 0) return true;
        uint256 n = LEGS;
        State[] memory afterLegs = new State[](n);
        uint256 navAfter = USDG.balanceOf(address(this));
        for (uint256 i = 0; i < n; i++) {
            State memory b = before.legs[i];
            State memory a = afterLegs[i];
            a.source = b.source;
            if (b.source == SOURCE_NONE) continue;
            a.value = Math.mulDiv(_legs[i].token.balanceOf(address(this)), b.price, _legs[i].scale);
            navAfter += a.value;
        }
        for (uint256 i = 0; i < n; i++) {
            State memory a = afterLegs[i];
            if (a.source == SOURCE_NONE) continue;
            a.target = Math.mulDiv(navAfter, _legs[i].bps, before.pricedBps);
            (bool due,,) = _due(a, navAfter);
            if (due) return false;
        }
        return true;
    }

    /// Both redeems start here: the split, `mintOf` lowered by the covered part, the supply before burns.
    function _exit(uint256 shares) private returns (Exit memory e) {
        if (shares == 0) revert NothingToRedeem();
        e = _exitSplit(msg.sender, shares);
        mintOf[msg.sender] -= e.covered;
        e.supply = totalSupply();
    }

    /// A redeem's split. Minted shares go first: `covered = min(shares, mintOf)`. Rates add, never compound:
    /// exit fee on all, early penalty on `covered` within the hold period, non-minter penalty on the rest.
    /// The bounds keep `paid` from underflowing.
    function _exitSplit(address holder, uint256 shares) private view returns (Exit memory e) {
        e.covered = Math.min(shares, mintOf[holder]);
        e.feeShares = shares * EXIT_FEE_BPS / BPS;
        if (block.timestamp < lastMintAt[holder] + HOLD_PERIOD) e.penaltyShares = e.covered * EARLY_PENALTY_BPS / BPS;
        e.nonMinterShares = (shares - e.covered) * NON_MINTER_PENALTY_BPS / BPS;
        e.paid = shares - e.feeShares - e.penaltyShares - e.nonMinterShares;
    }

    /// `safeTransfer`, or with the `allowFail` bit set a low-level `transfer` that returns false on failure.
    function _pay(IERC20 token, address to, uint256 amount, uint16 allowFail, uint256 bit) private returns (bool) {
        if (allowFail & (1 << bit) == 0) {
            token.safeTransfer(to, amount);
            return true;
        }
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (uint256)) == 1));
    }

    /// A one-word answer to a static call; `ok == false` otherwise.
    function _readUint(address target, bytes memory data) private view returns (bool ok, uint256 value) {
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }
}
