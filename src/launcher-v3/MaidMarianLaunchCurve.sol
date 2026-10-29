// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { StorageSlot } from "@openzeppelin/contracts/utils/StorageSlot.sol";
import { TickMath } from "./uniswap/TickMath.sol";
import { MaidMarianEtfV3, SOURCE_NONE } from "./MaidMarianEtfV3.sol";
import { MaidMarianEtfFactory } from "./MaidMarianEtfFactory.sol";
import { MaidMarianToken } from "./MaidMarianToken.sol";

/// The curve's shape, the same for every supply: 5/7 of it sold, 2/7 left at the end.
function curveReserved(uint256 supply) pure returns (uint256) {
    return (2 * supply) / 7;
}

uint256 constant CURVE_BPS = 10_000;

// A sale's or a claim's payout, the curve's `PAY_*` (the launcher's `sellAfterBond` reads the last two).
uint8 constant CURVE_PAY_QUOTE = 0;
uint8 constant CURVE_PAY_IN_KIND = 1;
uint8 constant CURVE_PAY_USDG = 2;

/// A buy of `quoteIn` on the reserves `(q, t)`: x * y = k on the quote reserve `q` (phantom plus real)
/// and the token reserve `t`, rounded for the curve. Fee and tax come off `quoteIn` first, outside k;
/// `net` enters `q`. A buy past the curve's end is not cut: the whole of it is bought on the same formula.
function curveBuy(uint256 q, uint256 t, uint256 quoteIn, uint256 feeBps, uint256 taxBps) pure returns (uint256 tokensOut, uint256 fee, uint256 tax, uint256 net) {
    fee = quoteIn * feeBps / CURVE_BPS;
    tax = quoteIn * taxBps / CURVE_BPS;
    net = quoteIn - fee - tax;
    tokensOut = t - Math.ceilDiv(q * t, q + net);
}

/// Whether reserves `(q, t)` leave a bond pool the curve can open at their price: `q / t` and `t / q`
/// both under 2^64, what its `sqrtPriceX96` is computed for (`ratio x 2^192` fits 256 bits), far inside
/// the full range's ticks; and `q` under 2^127, so the pool's quote fits a V4 delta (int128). The tokens
/// left always cover the pool: it takes 70 % of the real quote, under 70 % of `q`, so under 70 % of `t`
/// in tokens at the price `q / t`; its liquidity, at most 0.7 x sqrt(q x t), stays far under V4's per-tick
/// cap. In the quote, the launcher's threshold bounds keep every reserve up to the curve's end inside;
/// only a last buy far past it leaves them (`BuyTooLarge`). In USDG (a bond to USDG) `q` is the quote
/// reserve times the USDG a share redeems to, so the fit also depends on that rate: the launcher's ETF
/// floor keeps it down to 0.111 USDG a share, and under it the bond waits for a last buy large enough
/// (`BondDoesNotFit`).
function curveFits(uint256 q, uint256 t) pure returns (bool) {
    return q >> 127 == 0 && q >> 64 < t && t >> 64 < q;
}

/// A sale of `tokensIn` on `(q, t)`: `gross` leaves `q`; fee and tax come off it, the seller gets the rest.
function curveSell(uint256 q, uint256 t, uint256 tokensIn, uint256 feeBps, uint256 taxBps) pure returns (uint256 gross, uint256 fee, uint256 tax) {
    gross = q - Math.ceilDiv(q * t, t + tokensIn);
    fee = gross * feeBps / CURVE_BPS;
    tax = gross * taxBps / CURVE_BPS;
}

// The clone's arguments, packed: quote (20 bytes), quote kind (1: 0 a plain quote, else an ETF quote and
// 1 + its USDG cut / 25), creator tax in bps (2), threshold (16), creator (20), token (20), supply in raw
// units (12).
uint256 constant CURVE_ARGS_ETF = 20;
uint256 constant CURVE_ARGS_TAX = 21;
uint256 constant CURVE_ARGS_THRESHOLD = 23;
uint256 constant CURVE_ARGS_CREATOR = 39;
uint256 constant CURVE_ARGS_TOKEN = 59;
uint256 constant CURVE_ARGS_SUPPLY = 79;
// An ETF curve's USDG cut, in percent: 0, 25, 50, 75 or 100, a multiple of this step.
uint8 constant CURVE_CUT_STEP = 25;
uint8 constant CURVE_CUT_ALL = 100;

/// `routes` for a redeem of `shares` by `holder` now, each route that sells set to its leg's whole due and
/// its `amountOutMin` moved in the same proportion, rounded up: a payout to USDG sells every routed leg
/// whole at the price floor its route wrote, so no remainder of it is paid in kind, whether the route was
/// read a little under or over the due. A route at 0 stays 0, its leg paid in kind; a leg whose due is 0
/// is not routed. The due is not read when no route sells.
function routesAtDue(MaidMarianEtfV3 etf, address holder, uint256 shares, MaidMarianEtfV3.Route[] calldata routes) view returns (MaidMarianEtfV3.Route[] memory atDue) {
    atDue = routes;
    uint256 n = atDue.length;
    uint256 i;
    while (i < n && atDue[i].amountIn == 0) i++;
    if (i == n) return atDue;
    (uint256[] memory due,,,) = etf.previewRedeemToUsdg(holder, shares);
    if (due.length < n) n = due.length;
    for (; i < n; i++) {
        moveRouteToDue(atDue[i], due[i]);
    }
}

/// `r`, unless it sells nothing, set to sell `due`, its `amountOutMin` moved in the same proportion, rounded up.
function moveRouteToDue(MaidMarianEtfV3.Route memory r, uint256 due) pure {
    if (r.amountIn == 0 || r.amountIn == due) return;
    r.amountOutMin = Math.mulDiv(r.amountOutMin, due, r.amountIn, Math.Rounding.Ceil);
    r.amountIn = due;
}

/// `usdgCutPct` is read for an ETF quote only, one of 0, 25, 50, 75, 100 (the launcher checks it).
function curveCloneArgs(address quote, bool etfQuote, uint8 usdgCutPct, uint16 creatorTaxBps, uint128 threshold, address creator, address token, uint96 supply) pure returns (bytes memory) {
    uint8 kind = !etfQuote ? 0 : 1 + usdgCutPct / CURVE_CUT_STEP;
    return abi.encodePacked(quote, kind, creatorTaxBps, threshold, creator, token, supply);
}

/// What a curve reads from its factory.
interface IMaidMarianTokenLauncherReads {
    function owner() external view returns (address);
    function logo(address curve) external view returns (bytes memory);
}

/// The Uniswap V4 PoolManager, the calls a curve makes.
interface IPoolManagerV4 {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData) external returns (int256 callerDelta, int256 feesAccrued);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

/**
 * @title Maid Marian launch curve
 * @notice The bonding curve of one `MaidMarianToken` (its whole supply held here at launch), quoted
 * in a factory ETF's shares or in a token the factory's owner lists. x * y = k on a phantom quote reserve (2/5 of the
 * threshold) plus the real one; 5/7 of the supply is sold on the curve, price x12.25 first to last.
 * Doors:
 *  - `buy`: a plain quote only, paid in it.
 *  - `buyWithUsdg`: an ETF quote's only way in; the curve mints the shares itself with the caller's routes.
 *  - `sell`: paid in the plain quote, or for an ETF quote by the curve's own redeem, in kind or to USDG.
 * An ETF quote's shares are the curve's alone: minted by it, held by it, redeemed by it. None is taken
 * in (`buy` refuses them, `SharesStayInTheCurve`) and none is paid out: sales and claims are redeemed.
 * They leave the curve only into the ETF's redeem and the bond's pool. A buy pays the buyer the tokens
 * alone: the mint's refunds go to the factory's owner. A payout to USDG sells each routed leg whole: no
 * remainder of it is paid in kind.
 * Fees, on the quote side, outside k: 0.75 % each way, 70 % creator / 30 % protocol (the factory's
 * owner), plus the creator's tax (0 - 10 % each way, all his), plus a snipe tax on buys in the first
 * 3 s (99 %, 6.18 %, 0.19 %), split as the fee; the creator and the addresses he named at launch are
 * exempt from it (`isSnipeExempt`), not from the fee or his tax. The buyer is the caller, or, on
 * `buyFor` / `buyWithUsdgFor`, the address the factory names: the factory alone may name one, the
 * caller of its own doors; the factory pays, the buyer is paid the tokens.
 * On a plain quote the factory may also sell (`sellFor`) or claim (`claimFor`) for the caller of its
 * own door, the quote paid to the factory, which passes it on. Fees are kept in the curve and
 * claimed (`claim`), as the quote token or, for an ETF quote, by the curve's own redeem. An ETF quote's
 * shares held beyond what the curve books (the reserve ETF's management fee, minted to the curve as its
 * fee recipient, or a donation) are booked to the creator's fees by the next door (`unbookedShares`).
 * Bond: the buy that brings the real quote to the threshold or past it is bought whole (no cut, no
 * change), up to `BuyTooLarge`, and opens a Uniswap V4 pool (1 %, full range) at the curve's price
 * after it with 70 % of the real quote; the other 30 % stays here, booked to the protocol's fees
 * (`bondSetAside`) and claimed by the factory's owner as any fee, so the bond pays no one; every token
 * not in a pool burned, each position owned by this contract with no way to remove it. A plain quote's
 * pool pairs the token with the quote. An ETF quote's creator chooses at launch, for good, its USDG cut
 * (`usdgCutPct()`): 0, one token / shares pool; 100, one token / USDG pool; 25, 50 or 75, both, that
 * percent of the 70 % in the USDG pool and the rest in the shares pool, both opened at the same price.
 * A cut above 0 (`graduatesToUsdg()`) redeems at the bond every share the curve holds but those the
 * shares pool takes, to USDG with the last buyer's `bondRoutes` (each leg sold whole), never under the
 * contract's floor: each leg sold through the token's one registered pool (the V4 one if any, else the
 * V3; the route's `v4` flag ignored) for at least its due at its 30 min TWAP in USDG less that pool's
 * registered fee and `BOND_TOLERANCE_BPS`, whatever the buyer's own floors say (`minUsdgAtBond` and his
 * routes' can only raise it); it turns both fee pots and the 30 % into USDG at the redeem's own rate, and
 * opens the token / USDG pool at the curve's price times that rate; from then on its fees are USDG and
 * no share is booked to them: a share the reserve ETF mints to it afterwards (the creator's part of its
 * management fee) is the creator's, and of the shares pool's fees in shares 30 % are the protocol's
 * (`protocolShares`), both redeemed by `claimShares`.
 * Each pool's hook (`HOOK`) lets only this curve initialize it, so no one can open it first, at any price.
 * A mint's refund the factory's owner's address refuses (frozen on USDG, blocklisted on a leg) is kept
 * here for him (`ownerPot`, `claimOwnerPot`), so it never stops a buy.
 * Clone: an EIP-1167 clone of one implementation, initialized by the factory in the launch, after its token.
 */
contract MaidMarianLaunchCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------ constants ---

    /// The curve fee, each way: 0.75 %.
    uint256 public constant FEE_BPS = 75;

    /// The protocol's part of the fee: 30 %.
    uint256 public constant PROTOCOL_SHARE_BPS = 3000;

    uint256 public constant MAX_CREATOR_TAX_BPS = 1000;

    /// Snipe tax on a buy `s` seconds after the launch: `9 900 >> (s x 14 / 3)` bps, 0 from 3 s.
    uint256 public constant SNIPE_TAX_START_BPS = 9900;
    uint256 public constant SNIPE_TAX_SECONDS = 3;

    /// The addresses a launch may exempt from the snipe tax, the creator not counted. Each costs about
    /// 24 000 gas in the launch (a storage word from zero and its event): with 20, the heaviest
    /// `launchWithEtf` (ten legs, 10 KiB logo, full profile) is about 6.7 M plus the chain's L1 part,
    /// near the ~7 M a wallet simulates.
    uint256 public constant MAX_SNIPE_EXEMPTIONS = 20;

    /// The bond to USDG's floor under each leg's 30 min TWAP value, beyond the fee of the pool it sells
    /// through: 1 %. That redeem sells the whole fund for every holder, so its floor is the contract's, not
    /// the last buyer's: a TWAP moves by a fraction of a spot held for a fraction of its window, and not at
    /// all by a pool moved within the block. The pool's fee is counted apart because a sale pays it before
    /// any price impact: a leg in a 1 % pool sold honestly on mCandles at 94 926 000 for 98.996 % of its
    /// TWAP, under a floor of 99 % without it.
    uint256 public constant BOND_TOLERANCE_BPS = 100;

    /// A Uniswap fee's unit (V3 tiers and V4 fees in millionths), and V4's largest static fee: a value
    /// at or above it is a dynamic fee's flag, not a fee.
    uint256 private constant FEE_UNIT = 1_000_000;

    /// Part of the real quote booked to the protocol's fees at the bond: 30 %.
    uint256 public constant SET_ASIDE_BPS = 3000;

    /// The pool: 1 %, the tick spacing Uniswap pairs with 1 %, full range.
    uint24 public constant POOL_FEE = 10_000;
    int24 public constant POOL_TICK_SPACING = 200;
    int24 public constant POOL_TICK_LOWER = -887_200;
    int24 public constant POOL_TICK_UPPER = 887_200;

    /// How a sale or a claim is paid. `PAY_QUOTE`: a plain quote itself, never an ETF's shares; for an
    /// ETF quote `PAY_IN_KIND` (`redeemInKind` with the caller's `allowFail`) or `PAY_USDG` (`redeem` with
    /// the caller's routes, every leg not routed paid in kind).
    uint8 public constant PAY_QUOTE = CURVE_PAY_QUOTE;
    uint8 public constant PAY_IN_KIND = CURVE_PAY_IN_KIND;
    uint8 public constant PAY_USDG = CURVE_PAY_USDG;

    uint256 private constant BPS = CURVE_BPS;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant CLONE_CODE_BYTES = 0x2d;
    uint8 private constant OP_SEED = 1;
    uint8 private constant OP_COLLECT = 2;

    // ----------------------------------------------------------- immutables ---

    IMaidMarianTokenLauncherReads public immutable FACTORY;
    IERC20 public immutable USDG;
    IPoolManagerV4 public immutable POOL_MANAGER;
    /// Every bond pool's hook: `MaidMarianLaunchHook`, deployed by the launcher.
    address public immutable HOOK;
    address private immutable SELF;
    /// `10 ** (18 - USDG decimals)`: from a price in USDG per whole token (18 decimals) to USDG units.
    uint256 private immutable USDG_UNIT_TO_18;

    // ---------------------------------------------------------------- state ---

    /// The curve's quote reserve, phantom included, and its token reserve.
    uint256 public quoteReserve;
    uint256 public tokenReserve;

    /// Fees kept in the curve, in quote units, until claimed.
    uint256 public creatorFees;
    uint256 public protocolFees;

    /// The 30 % of the real quote the bond booked to `protocolFees`; 0 before the bond.
    uint256 public bondSetAside;

    /// After a bond with both pools: the reserve ETF's shares held for the protocol (the shares pool's
    /// rounding at the bond and 30 % of its fees in shares), redeemed by the factory's owner with `claimShares`.
    uint256 public protocolShares;

    uint64 public launchedAt;
    bool public bonded;
    bool private _initialized;
    /// Set once `ownerPot` holds anything: until then a mint's sweep reads this one word, not a pot per asset.
    bool private _ownerPotUsed;

    /// A mint's refund the factory's owner's address refused, per asset, kept here for him (`claimOwnerPot`).
    mapping(address asset => uint256) public ownerPot;

    /// Exempted from the snipe tax at launch, for good; the creator is too, without an entry.
    mapping(address account => bool) private _snipeExempt;

    // --------------------------------------------------------------- events ---

    /// One per address exempted from the snipe tax, the creator first, all in the launch.
    event SnipeTaxExempted(address indexed account);
    /// `buyer`: the caller, or the one the factory named; `quoteIn`: the quote paid, fee and tax in;
    /// `usdgIn`: the USDG minted into it (0 for `buy`).
    event Bought(address indexed buyer, uint256 quoteIn, uint256 usdgIn, uint256 tokensOut, uint256 fee, uint256 tax, uint256 quoteReserve, uint256 tokenReserve);
    /// `quoteOut`: the quote paid out, fee and tax off, before any redeem.
    event Sold(address indexed seller, uint256 tokensIn, uint256 quoteOut, uint8 payout, uint256 fee, uint256 tax, uint256 quoteReserve, uint256 tokenReserve);
    /// One per pool the bond opens, a shares pool first. `pairedWith`: its other currency; `setAside` and
    /// `poolQuote` in it, booked to `protocolFees` (to `protocolShares` for a shares pool beside a USDG one);
    /// `burned` on the last only.
    event Bonded(address indexed token, bytes32 indexed poolId, address pairedWith, uint256 setAside, uint256 poolTokens, uint256 poolQuote, uint256 burned);
    /// A bond to USDG's redeem: every share the curve held, and the USDG it brought (the balance change).
    event BondRedeemed(uint256 shares, uint256 usdgOut);
    event FeesClaimed(address indexed by, address indexed to, bool protocol, uint256 amount, uint8 payout);
    /// Once bonded to USDG, the creator's redeem of `amount` of the shares the reserve ETF minted here.
    event SharesClaimed(address indexed by, address indexed to, uint256 amount, uint8 payout);
    /// A mint's refund the owner's address refused, kept for him; and its claim.
    event OwnerPotBooked(address indexed asset, uint256 amount);
    event OwnerPotClaimed(address indexed asset, address indexed to, uint256 amount);
    /// `quoteFees` in `poolCurrency()`; `shareFees` the shares pool's beside a USDG pool, else 0.
    event PoolFeesCollected(uint256 tokenFees, uint256 quoteFees, uint256 shareFees);

    // --------------------------------------------------------------- errors ---

    error ZeroAddress();
    error NotFactory();
    error AlreadyInitialized();
    error NotAClone();
    error AlreadyBonded();
    error NotBonded();
    error NotBondedToUsdg();
    error NothingIn();
    error TooFewTokens(uint256 tokensOut, uint256 minTokensOut);
    error TooLittleQuote(uint256 quoteOut, uint256 minQuoteOut);
    error NotEtfQuote();
    error BadPayout(uint8 payout);
    error NotCovered(uint256 shares, uint256 covered);
    error HoldRunning(uint256 endsAt);
    error NotCreator();
    error NotOwner();
    error TooMuch(uint256 amount, uint256 available);
    error NotPoolManager();
    error TooManyExemptions(uint256 count, uint256 max);
    error SharesStayInTheCurve();
    /// The buy would leave reserves no bond pool opens at (`curveFits`).
    error BuyTooLarge(uint256 quoteReserve, uint256 tokenReserve);
    /// A bond to USDG: leg `leg`'s route sells nothing, so its due would stay here in kind.
    error BondRouteMissing(uint256 leg);
    error TooLittleUsdgAtBond(uint256 usdgOut, uint256 minUsdgOut);
    /// A bond to USDG: leg `leg` is due something and has no 30 min TWAP price (`getTradablePriceUsdg`),
    /// so no floor; the buy reverts and can be made again once its pool answers.
    error BondLegUnpriced(uint256 leg, address token);
    /// A bond whose price leaves no pool that opens (`curveFits`, in the pool's currency) or nothing to seed it.
    error BondDoesNotFit(uint256 quoteReserve, uint256 tokenReserve);

    // ---------------------------------------------------------- constructor ---

    /// The implementation, deployed by the factory (`FACTORY = msg.sender`). Locked: never initialized.
    constructor(IERC20 usdg, IPoolManagerV4 poolManager, address hook) {
        if (address(usdg) == address(0) || address(poolManager) == address(0) || hook == address(0)) revert ZeroAddress();
        FACTORY = IMaidMarianTokenLauncherReads(msg.sender);
        USDG = usdg;
        POOL_MANAGER = poolManager;
        HOOK = hook;
        SELF = address(this);
        USDG_UNIT_TO_18 = 10 ** (18 - uint256(IERC20Metadata(address(usdg)).decimals()));
        _initialized = true;
    }

    /// @notice Called once, by the factory, in the launch, once its token minted the supply to it.
    /// @param snipeExempt Exempted from the snipe tax with the creator, at most `MAX_SNIPE_EXEMPTIONS`;
    /// `address(0)` refused, a repeat or the creator skipped (one event per address).
    function initialize(address[] calldata snipeExempt) external {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        if (_initialized) revert AlreadyInitialized();
        if (snipeExempt.length > MAX_SNIPE_EXEMPTIONS) revert TooManyExemptions(snipeExempt.length, MAX_SNIPE_EXEMPTIONS);
        _initialized = true;
        launchedAt = uint64(block.timestamp);
        quoteReserve = phantomQuote();
        tokenReserve = supply();
        // A clone's storage starts at 0: the guard is set to `ReentrancyGuard`'s NOT_ENTERED.
        StorageSlot.getUint256Slot(_reentrancyGuardStorageSlot()).value = 1;
        address creator_ = creator();
        emit SnipeTaxExempted(creator_);
        for (uint256 i = 0; i < snipeExempt.length; i++) {
            address a = snipeExempt[i];
            if (a == address(0)) revert ZeroAddress();
            if (a == creator_ || _snipeExempt[a]) continue;
            _snipeExempt[a] = true;
            emit SnipeTaxExempted(a);
        }
    }

    modifier onlyClone() {
        _onlyClone();
        _;
    }

    function _onlyClone() private view {
        if (address(this) == SELF) revert NotAClone();
    }

    // ---------------------------------------------------------------- doors ---

    /// @notice Buy with `quoteIn` of a plain quote (approved to this contract), all of it bought: the last
    /// buy goes past the curve's end and bonds. An ETF quote's shares are refused
    /// (`SharesStayInTheCurve`): `buyWithUsdg` is its door.
    function buy(uint256 quoteIn, uint256 minTokensOut) external onlyClone nonReentrant returns (uint256 tokensOut) {
        return _buyInQuote(msg.sender, quoteIn, minTokensOut);
    }

    /// @notice `buy` by the factory for `buyer`, the caller of its own door: the factory pays, `buyer` is
    /// the buyer (the snipe tax, `Bought`) and is paid the tokens. `NotFactory` for any other caller.
    function buyFor(address buyer, uint256 quoteIn, uint256 minTokensOut) external onlyClone nonReentrant returns (uint256 tokensOut) {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        return _buyInQuote(buyer, quoteIn, minTokensOut);
    }

    /// @notice ETF quote: pay `usdgIn` USDG (approved to this contract); the curve mints the ETF's shares
    /// with `routes` and `minShares` (as the ETF's `mint`), keeps them and buys with them. The buyer gets
    /// the tokens; what the mint refunds goes to the factory's owner (`_sweepMintRefunds`). Every share
    /// minted is bought: the last buy goes past the curve's end and bonds.
    /// @param bondRoutes Read only by a buy that bonds a curve graduating to USDG: its redeem's, one per
    /// leg as the ETF's `redeem` takes them, each selling something (`BondRouteMissing`); each is set to
    /// its leg's whole due at execution, its `amountOutMin` moved in proportion (`routesAtDue`), so routes
    /// read from `previewBond` run; and its `amountOutMin` raised to the contract's floor for that leg
    /// when lower (the pool's registered fee and `BOND_TOLERANCE_BPS` under the TWAP); its `v4` flag set by
    /// the contract to the token's registered pool, whatever it says. Empty for any other buy.
    /// @param minUsdgAtBond The least USDG that redeem must bring, read from the curve's balance
    /// (`TooLittleUsdgAtBond`), raised to the contract's floor when lower; read with `bondRoutes` only.
    function buyWithUsdg(uint256 usdgIn, MaidMarianEtfV3.Route[] calldata routes, uint256 minShares, uint256 minTokensOut, MaidMarianEtfV3.Route[] calldata bondRoutes, uint256 minUsdgAtBond)
        external
        onlyClone
        nonReentrant
        returns (uint256 tokensOut)
    {
        return _buyInUsdg(msg.sender, usdgIn, routes, minShares, minTokensOut, bondRoutes, minUsdgAtBond);
    }

    /// @notice `buyWithUsdg` by the factory for `buyer`, as `buyFor`.
    function buyWithUsdgFor(
        address buyer,
        uint256 usdgIn,
        MaidMarianEtfV3.Route[] calldata routes,
        uint256 minShares,
        uint256 minTokensOut,
        MaidMarianEtfV3.Route[] calldata bondRoutes,
        uint256 minUsdgAtBond
    ) external onlyClone nonReentrant returns (uint256 tokensOut) {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        return _buyInUsdg(buyer, usdgIn, routes, minShares, minTokensOut, bondRoutes, minUsdgAtBond);
    }

    /// @notice Sell `tokensIn`, paid `PAY_QUOTE` (a plain quote), or for an ETF quote `PAY_IN_KIND` /
    /// `PAY_USDG` by the curve's own redeem (`routes`, `minUsdgOut` as the ETF's `redeem`, `allowFail` as
    /// its `redeemInKind`); shares are never paid (`SharesStayInTheCurve`). `minQuoteOut` bounds the quote
    /// paid out, before the redeem. `PAY_USDG` sells every routed leg's whole due (`routesAtDue`), so the
    /// seller gets USDG and, in kind, only the legs he routed at 0. On an ETF with a non-minter penalty a
    /// redeem is never beyond the curve's `mintOf` (`NotCovered`). No approve: the token lets this curve take the caller's tokens for
    /// his own sale (`takeForSale`).
    /// @dev `PAY_IN_KIND` is the way out that needs no pool: `redeemInKind` calls no router and reads no
    /// price, so a holder still leaves when a leg's pool cannot sell (`PAY_USDG` with that leg's route at
    /// 0 pays that one leg in kind and sells the others). When a leg's token refuses the transfer (paused,
    /// or the seller blocklisted on it), `allowFail` bit i lets leg i fail: its part is forfeited and stays
    /// in the fund for the other holders, the rest paid. Read for `PAY_IN_KIND` only; 0 asks every leg.
    function sell(uint256 tokensIn, uint256 minQuoteOut, uint8 payout, MaidMarianEtfV3.Route[] calldata routes, uint256 minUsdgOut, uint16 allowFail)
        external
        onlyClone
        nonReentrant
        returns (uint256 quoteOut)
    {
        quoteOut = _sell(msg.sender, tokensIn, minQuoteOut, payout);
        _payOut(quoteOut, msg.sender, payout, routes, minUsdgOut, allowFail);
    }

    /// @notice `sell` by the factory for `seller`, the caller of its own door, on a plain quote only
    /// (`SharesStayInTheCurve` on an ETF quote): `seller`'s tokens are taken (`takeForSale`, no approve)
    /// and the quote is paid to the factory, which passes it on. `NotFactory` for any other caller.
    function sellFor(address seller, uint256 tokensIn, uint256 minQuoteOut) external onlyClone nonReentrant returns (uint256 quoteOut) {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        if (etfQuote()) revert SharesStayInTheCurve();
        quoteOut = _sell(seller, tokensIn, minQuoteOut, PAY_QUOTE);
        IERC20(quote()).safeTransfer(msg.sender, quoteOut);
    }

    /// @notice Claim `amount` of the creator's fees (`protocol` false, the creator only) or of the
    /// protocol's (`protocol` true, the factory's owner only) to `to`: a plain quote as itself
    /// (`PAY_QUOTE`), an ETF quote by the curve's redeem only (`PAY_IN_KIND`, `PAY_USDG`), which never
    /// runs while the ETF's hold period on the curve's last mint runs. `allowFail` as `sell`'s. The
    /// protocol's fees include the bond's 30 % (`bondSetAside`). Once bonded to USDG the fees are USDG,
    /// paid as such with `PAY_USDG` alone (`routes`, `minUsdgOut`, `allowFail` unread).
    function claim(bool protocol, uint256 amount, address to, uint8 payout, MaidMarianEtfV3.Route[] calldata routes, uint256 minUsdgOut, uint16 allowFail) external onlyClone nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _debitFees(msg.sender, protocol, amount);
        _payOut(amount, to, payout, routes, minUsdgOut, allowFail);
        emit FeesClaimed(msg.sender, to, protocol, amount, payout);
    }

    /// @notice `claim` by the factory for `claimant`, the caller of its own door, on a plain quote only
    /// (`SharesStayInTheCurve` on an ETF quote): `claimant` must be the creator or the factory's owner, as
    /// on `claim`; the quote is paid to the factory, which passes it on. `NotFactory` for any other caller.
    function claimFor(address claimant, bool protocol, uint256 amount) external onlyClone nonReentrant {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        if (etfQuote()) revert SharesStayInTheCurve();
        _debitFees(claimant, protocol, amount);
        IERC20(quote()).safeTransfer(msg.sender, amount);
        emit FeesClaimed(claimant, msg.sender, protocol, amount, PAY_QUOTE);
    }

    /// @notice Once bonded with a USDG cut: redeem `amount` of the reserve ETF's shares this curve holds to
    /// `to`. The creator: `claimableShares()` (his part of the ETF's management fee, minted to the curve as
    /// its fee recipient, 70 % of the shares pool's fees, or a donation); the factory's owner:
    /// `protocolShares`; one who is both, the two, the creator's first. `PAY_IN_KIND` or `PAY_USDG` with
    /// `routes`, `minUsdgOut` and `allowFail` as `sell`'s, never as shares.
    function claimShares(uint256 amount, address to, uint8 payout, MaidMarianEtfV3.Route[] calldata routes, uint256 minUsdgOut, uint16 allowFail) external onlyClone nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (!_bondedToUsdg()) revert NotBondedToUsdg();
        bool isCreator = msg.sender == creator();
        bool isOwner = msg.sender == FACTORY.owner();
        if (!isCreator && !isOwner) revert NotCreator();
        if (amount == 0) revert NothingIn();
        uint256 own = isCreator ? claimableShares() : 0;
        uint256 held = own + (isOwner ? protocolShares : 0);
        if (amount > held) revert TooMuch(amount, held);
        if (amount > own) protocolShares -= amount - own;
        _requireNoHold();
        _redeem(amount, to, payout, routes, minUsdgOut, allowFail);
        emit SharesClaimed(msg.sender, to, amount, payout);
    }

    /// @notice Send the refunds kept for the factory's owner in `asset` (`ownerPot`) to `to`, an address
    /// of his choice: the way out for an owner frozen on that asset. The factory's owner only.
    function claimOwnerPot(address asset, address to) external onlyClone nonReentrant returns (uint256 amount) {
        if (msg.sender != FACTORY.owner()) revert NotOwner();
        if (to == address(0)) revert ZeroAddress();
        amount = ownerPot[asset];
        if (amount == 0) revert NothingIn();
        ownerPot[asset] = 0;
        IERC20(asset).safeTransfer(to, amount);
        emit OwnerPotClaimed(asset, to, amount);
    }

    /// @notice After the bond: collect every pool position's fees, the tokens' 70 % to the creator and 30 %
    /// to the factory's owner, those in `poolCurrency()` into `creatorFees` / `protocolFees`; a shares pool's
    /// beside a USDG one stay here in shares, 30 % booked to `protocolShares`, the rest the creator's
    /// (`claimableShares`). Anyone.
    function collectPoolFees() external onlyClone nonReentrant returns (uint256 tokenFees, uint256 quoteFees) {
        if (!bonded) revert NotBonded();
        _bookUnbookedShares();
        uint256 shareFees;
        (tokenFees, quoteFees) = _collect(poolCurrency());
        if (_twoPools()) {
            uint256 tokensInShares;
            (tokensInShares, shareFees) = _collect(quote());
            tokenFees += tokensInShares;
            protocolShares += shareFees * PROTOCOL_SHARE_BPS / BPS;
        }
        if (tokenFees > 0) {
            uint256 toProtocol = tokenFees * PROTOCOL_SHARE_BPS / BPS;
            IERC20(token()).safeTransfer(FACTORY.owner(), toProtocol);
            IERC20(token()).safeTransfer(creator(), tokenFees - toProtocol);
        }
        if (quoteFees > 0) _takeFees(quoteFees, 0);
        emit PoolFeesCollected(tokenFees, quoteFees, shareFees);
    }

    /// @notice The PoolManager's callback, for the bond's seeding and the fee collection only; `currency`
    /// names the pool, the token and it.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (uint8 op, address currency) = abi.decode(data, (uint8, address));
        IPoolManagerV4.PoolKey memory key = poolKeyIn(currency);
        if (op == OP_SEED) {
            (,, uint256 q, uint256 budget) = abi.decode(data, (uint8, address, uint256, uint256));
            (uint256 poolTokens, uint256 poolQuote) = _seed(key, currency, q, budget);
            return abi.encode(poolTokens, poolQuote);
        }
        (int256 delta,) = POOL_MANAGER.modifyLiquidity(key, _range(0), "");
        (int256 dToken, int256 dQuote) = _split(delta, currency);
        // Fees only: both deltas are owed to the curve.
        // forge-lint: disable-next-line(unsafe-typecast)
        (uint256 tokenFees, uint256 quoteFees) = (uint256(dToken), uint256(dQuote));
        if (tokenFees > 0) POOL_MANAGER.take(token(), address(this), tokenFees);
        if (quoteFees > 0) POOL_MANAGER.take(currency, address(this), quoteFees);
        return abi.encode(tokenFees, quoteFees);
    }

    // ---------------------------------------------------------------- views ---

    /// The quote token: a factory ETF's shares (`etfQuote()`) or a listed plain token.
    function quote() public view returns (address) {
        return address(uint160(_arg(0, 20)));
    }

    function etfQuote() public view returns (bool) {
        return _arg(CURVE_ARGS_ETF, 1) != 0;
    }

    /// An ETF-quoted curve's USDG cut, chosen at launch for good: the percent of the bond's pooled quote
    /// redeemed to USDG and paired with it, 0, 25, 50, 75 or 100; the rest pairs the token with the
    /// shares. 0 for a plain quote.
    function usdgCutPct() public view returns (uint256) {
        uint256 kind = _arg(CURVE_ARGS_ETF, 1);
        return kind == 0 ? 0 : (kind - 1) * CURVE_CUT_STEP;
    }

    /// Whether the bond redeems shares to USDG (a cut above 0): a token / USDG pool, and fees in USDG once bonded.
    function graduatesToUsdg() public view returns (bool) {
        return usdgCutPct() != 0;
    }

    /// The bond pool's other currency, and the fees' once bonded: USDG for a cut above 0, else the quote.
    /// With a cut of 25 to 75 the token / shares pool is the other one (`poolKeyIn(quote())`).
    function poolCurrency() public view returns (address) {
        return graduatesToUsdg() ? address(USDG) : quote();
    }

    function creatorTaxBps() public view returns (uint256) {
        return _arg(CURVE_ARGS_TAX, 2);
    }

    /// The real quote that bonds the curve.
    function threshold() public view returns (uint256) {
        return _arg(CURVE_ARGS_THRESHOLD, 16);
    }

    /// The phantom quote reserve: 2/5 of the threshold, so the curve's 5/7 sell for the threshold.
    function phantomQuote() public view returns (uint256) {
        return threshold() * 2 / 5;
    }

    function creator() public view returns (address) {
        return address(uint160(_arg(CURVE_ARGS_CREATOR, 20)));
    }

    /// The token this curve sells.
    function token() public view returns (address) {
        return address(uint160(_arg(CURVE_ARGS_TOKEN, 20)));
    }

    /// The token's supply, raw units: all of it here at launch.
    function supply() public view returns (uint256) {
        return _arg(CURVE_ARGS_SUPPLY, 12);
    }

    /// The tokens left in the curve when 5/7 of the supply is sold: the end of the curve.
    function reserved() public view returns (uint256) {
        return curveReserved(supply());
    }

    /// The real quote in the curve: what the sales owe, every token sold back at once covered.
    function realQuote() public view returns (uint256) {
        return quoteReserve - phantomQuote();
    }

    function getReserves() external view returns (uint256 quoteReserve_, uint256 tokenReserve_) {
        return (quoteReserve, tokenReserve);
    }

    /// An ETF quote's shares held beyond what the curve books (its real quote until the bond, its fees):
    /// the next door books them to `creatorFees`. 0 for a plain quote, and once bonded with a USDG cut: its
    /// fees are USDG, and every share it holds is `claimableShares()` or `protocolShares`.
    function unbookedShares() public view returns (uint256) {
        if (!etfQuote() || _bondedToUsdg()) return 0;
        uint256 booked = creatorFees + protocolFees + (bonded ? 0 : realQuote());
        uint256 held = IERC20(quote()).balanceOf(address(this));
        return held > booked ? held - booked : 0;
    }

    /// The reserve ETF's shares the creator may redeem with `claimShares`: every share held once bonded with
    /// a USDG cut but `protocolShares` (the bond redeemed or pooled all it held); 0 otherwise.
    function claimableShares() public view returns (uint256) {
        if (!_bondedToUsdg()) return 0;
        uint256 held = IERC20(quote()).balanceOf(address(this));
        return held > protocolShares ? held - protocolShares : 0;
    }

    /// The curve's marginal price, quote units per whole token, 18 decimals.
    function price() external view returns (uint256) {
        return Math.mulDiv(quoteReserve, 1e18, tokenReserve);
    }

    /// Whether `account` pays no snipe tax: the creator, or an address he named at launch.
    function isSnipeExempt(address account) public view returns (bool) {
        return account == creator() || _snipeExempt[account];
    }

    /// The snipe tax `buyer` would pay now, in bps; 0 for an exempted address.
    function currentSnipeTaxBps(address buyer) public view returns (uint256) {
        if (isSnipeExempt(buyer)) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        if (elapsed >= SNIPE_TAX_SECONDS) return 0;
        return SNIPE_TAX_START_BPS >> (elapsed * 14 / SNIPE_TAX_SECONDS);
    }

    /// What `buy(quoteIn)` by `buyer` would do now, all of `quoteIn` bought: tokens out, fee (snipe tax
    /// in) and tax. Zeros once bonded and for a buy refused `BuyTooLarge`.
    function previewBuy(uint256 quoteIn, address buyer) external view returns (uint256 tokensOut, uint256 fee, uint256 tax) {
        if (bonded || quoteIn == 0) return (0, 0, 0);
        (uint256 q, uint256 t) = (quoteReserve, tokenReserve);
        uint256 net;
        (tokensOut, fee, tax, net) = curveBuy(q, t, quoteIn, _feeBps(buyer), creatorTaxBps());
        if (!curveFits(q + net, t - tokensOut)) return (0, 0, 0);
    }

    /// What `sell(tokensIn)` would pay now in quote units, and its fee and tax. Zeros once bonded or
    /// for more than was ever sold.
    function previewSell(uint256 tokensIn) external view returns (uint256 quoteOut, uint256 fee, uint256 tax) {
        if (bonded || tokensIn == 0 || tokenReserve + tokensIn > supply()) return (0, 0, 0);
        uint256 gross;
        (gross, fee, tax) = curveSell(quoteReserve, tokenReserve, tokensIn, FEE_BPS, creatorTaxBps());
        quoteOut = gross - fee - tax;
    }

    /// For a buy that mints `sharesMinted` and bonds a curve with a USDG cut: the shares its bond redeems
    /// (every share the curve then holds but the shares pool's), each leg's due and the fund's USDG for
    /// them, as the ETF's `quoteMint` reads them now. The shares pool's part is read on the buy's fee and
    /// tax without a snipe tax. A mint keeps the legs in the fund's proportions, so a due moves with the
    /// mint's rounding only, and the bond sets each route to its exact due. Zeros for a plain quote.
    function previewBond(uint256 sharesMinted) external view returns (uint256 shares, uint256[] memory due, uint256 usdg) {
        if (!etfQuote()) return (0, due, 0);
        uint256 net = sharesMinted - sharesMinted * (FEE_BPS + creatorTaxBps()) / BPS;
        shares = IERC20(quote()).balanceOf(address(this)) + sharesMinted - _sharesPooled(realQuote() + net);
        (due, usdg) = MaidMarianEtfV3(quote()).quoteMint(shares);
    }

    /// The bond's pool in `poolCurrency()`: the USDG pool for a cut above 0.
    function poolKey() public view returns (IPoolManagerV4.PoolKey memory) {
        return poolKeyIn(poolCurrency());
    }

    function poolId() public view returns (bytes32) {
        return _poolId(poolCurrency());
    }

    /// A bond pool's key: the token and `currency`, sorted, 1 %, spacing 200, `HOOK`. The curve's pools are
    /// `poolCurrency()`'s and, with a cut of 25 to 75, `quote()`'s.
    function poolKeyIn(address currency) public view returns (IPoolManagerV4.PoolKey memory key) {
        address t = token();
        (address c0, address c1) = t < currency ? (t, currency) : (currency, t);
        key = IPoolManagerV4.PoolKey({ currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: POOL_TICK_SPACING, hooks: HOOK });
    }

    /// Whether `id` is one of this curve's bond pools, what `HOOK` lets it initialize.
    function isBondPool(bytes32 id) external view returns (bool) {
        return id == poolId() || (_twoPools() && id == _poolId(quote()));
    }

    /// The token's PNG logo, stored by the factory; empty if none.
    function logo() external view returns (bytes memory) {
        return FACTORY.logo(address(this));
    }

    // ------------------------------------------------------------- internal ---

    /// `buy` for `buyer`, paid by the caller, the tokens to `buyer`; a plain quote only.
    function _buyInQuote(address buyer, uint256 quoteIn, uint256 minTokensOut) private returns (uint256 tokensOut) {
        if (etfQuote()) revert SharesStayInTheCurve();
        if (quoteIn == 0) revert NothingIn();
        IERC20(quote()).safeTransferFrom(msg.sender, address(this), quoteIn);
        tokensOut = _buy(buyer, quoteIn, 0, minTokensOut);
        if (_bondDue()) _bondInQuote();
    }

    /// `buyWithUsdg` for `buyer`, paid by the caller, every output to `buyer`.
    function _buyInUsdg(
        address buyer,
        uint256 usdgIn,
        MaidMarianEtfV3.Route[] calldata routes,
        uint256 minShares,
        uint256 minTokensOut,
        MaidMarianEtfV3.Route[] calldata bondRoutes,
        uint256 minUsdgAtBond
    ) private returns (uint256 tokensOut) {
        if (!etfQuote()) revert NotEtfQuote();
        if (usdgIn == 0) revert NothingIn();
        MaidMarianEtfV3 etf = MaidMarianEtfV3(quote());
        USDG.safeTransferFrom(msg.sender, address(this), usdgIn);
        USDG.forceApprove(address(etf), usdgIn);
        // The ETF's first mint (the launch's seed) keeps all it buys, one share per USDG kept: it refunds
        // nothing, so its eleven balance reads on ten legs (about 33 000 gas) are skipped.
        bool first = etf.totalSupply() == 0;
        uint256 shares = etf.mint(usdgIn, routes, minShares);
        if (!first) _sweepMintRefunds(etf);
        tokensOut = _buy(buyer, shares, usdgIn, minTokensOut);
        if (!_bondDue()) return tokensOut;
        if (graduatesToUsdg()) _bondToUsdg(etf, bondRoutes, minUsdgAtBond);
        else _bondInQuote();
    }

    /// The curve step of both buys: `quoteIn` is already in the contract and all of it is bought; the snipe
    /// tax and the tokens are `buyer`'s.
    function _buy(address buyer, uint256 quoteIn, uint256 usdgIn, uint256 minTokensOut) private returns (uint256 tokensOut) {
        if (bonded) revert AlreadyBonded();
        (uint256 q, uint256 t) = (quoteReserve, tokenReserve);
        (uint256 out, uint256 fee, uint256 tax, uint256 net) = curveBuy(q, t, quoteIn, _feeBps(buyer), creatorTaxBps());
        if (out == 0 || out < minTokensOut) revert TooFewTokens(out, minTokensOut);
        (q, t) = (q + net, t - out);
        if (!curveFits(q, t)) revert BuyTooLarge(q, t);
        (quoteReserve, tokenReserve) = (q, t);
        _takeFees(fee, tax);
        IERC20(token()).safeTransfer(buyer, out);
        emit Bought(buyer, quoteIn, usdgIn, out, fee, tax, q, t);
        return out;
    }

    /// The curve step of both sales: `seller`'s tokens in; the quote owed is returned, not paid.
    function _sell(address seller, uint256 tokensIn, uint256 minQuoteOut, uint8 payout) private returns (uint256 quoteOut) {
        if (bonded) revert AlreadyBonded();
        if (tokensIn == 0) revert NothingIn();
        _bookUnbookedShares();
        (uint256 q, uint256 t) = (quoteReserve, tokenReserve);
        (uint256 gross, uint256 fee, uint256 tax) = curveSell(q, t, tokensIn, FEE_BPS, creatorTaxBps());
        quoteOut = gross - fee - tax;
        if (quoteOut < minQuoteOut) revert TooLittleQuote(quoteOut, minQuoteOut);
        (quoteReserve, tokenReserve) = (q - gross, t + tokensIn);
        _takeFees(fee, tax);
        MaidMarianToken(token()).takeForSale(seller, tokensIn);
        emit Sold(seller, tokensIn, quoteOut, payout, fee, tax, q - gross, t + tokensIn);
    }

    /// Takes `amount` off the protocol's fees (`claimant` the factory's owner) or the creator's
    /// (`claimant` the creator). On an ETF quote, never while the hold runs on the curve's last mint.
    function _debitFees(address claimant, bool protocol, uint256 amount) private {
        _bookUnbookedShares();
        uint256 available;
        if (protocol) {
            if (claimant != FACTORY.owner()) revert NotOwner();
            available = protocolFees;
            if (amount > available) revert TooMuch(amount, available);
            protocolFees = available - amount;
        } else {
            if (claimant != creator()) revert NotCreator();
            available = creatorFees;
            if (amount > available) revert TooMuch(amount, available);
            creatorFees = available - amount;
        }
        if (amount == 0) revert NothingIn();
        if (etfQuote() && !_bondedToUsdg()) _requireNoHold();
    }

    function _feeBps(address buyer) private view returns (uint256) {
        // Capped so fee, snipe and tax never pass 100 %.
        return FEE_BPS + Math.min(currentSnipeTaxBps(buyer), BPS - FEE_BPS - creatorTaxBps());
    }

    /// The fee's 30 % to the protocol, its 70 % and the tax to the creator.
    function _takeFees(uint256 fee, uint256 tax) private {
        uint256 toProtocol = fee * PROTOCOL_SHARE_BPS / BPS;
        protocolFees += toProtocol;
        creatorFees += fee - toProtocol + tax;
    }

    /// Every leg and USDG the curve holds after a mint is what the mint refunded (`received - used` of each
    /// leg, the USDG its routes left): the rounding of the buyer's routes against the fund's proportions,
    /// not what he asked for. It goes to the factory's owner: a curve's fee pots count the quote's shares
    /// only, and a donation to the ETF is not counted by it. The buyer gets the tokens alone. The legs are
    /// read on the ETF's own factory, fixed for that ETF. A transfer the owner's address refuses (frozen on
    /// USDG, blocklisted on a leg) never stops the buy: the amount is kept in `ownerPot` for him.
    function _sweepMintRefunds(MaidMarianEtfV3 etf) private {
        address to = FACTORY.owner();
        MaidMarianEtfFactory.LegSpec[] memory legs = MaidMarianEtfFactory(address(etf.FACTORY())).legsOf(address(etf));
        for (uint256 i = 0; i < legs.length; i++) {
            _sendToOwner(IERC20(legs[i].token), to);
        }
        _sendToOwner(USDG, to);
    }

    /// Sends `to`, the factory's owner, what the curve holds of `asset` beyond `ownerPot`; what he refuses
    /// joins the pot.
    function _sendToOwner(IERC20 asset, address to) private {
        uint256 pot = _ownerPotUsed ? ownerPot[address(asset)] : 0;
        uint256 held = asset.balanceOf(address(this));
        uint256 left = held > pot ? held - pot : 0;
        if (left == 0 || asset.trySafeTransfer(to, left)) return;
        ownerPot[address(asset)] = pot + left;
        _ownerPotUsed = true;
        emit OwnerPotBooked(address(asset), left);
    }

    /// Books `unbookedShares()` to the creator's fees: the reserve ETF mints the creator's part of its
    /// management fee to its fee recipient, this curve, at each of its doors.
    function _bookUnbookedShares() private {
        uint256 extra = unbookedShares();
        if (extra > 0) creatorFees += extra;
    }

    /// Pays `amount` of quote to `to`: a plain quote as itself, an ETF quote by the curve's redeem, in
    /// kind (`allowFail` passed on) or to USDG (each routed leg sold whole, `routesAtDue`), never as
    /// shares. On an ETF with a non-minter penalty a redeem stays within the curve's `mintOf`, so the curve
    /// never pays that penalty.
    function _payOut(uint256 amount, address to, uint8 payout, MaidMarianEtfV3.Route[] calldata routes, uint256 minUsdgOut, uint16 allowFail) private {
        if (!etfQuote()) {
            if (payout != PAY_QUOTE) revert BadPayout(payout);
            IERC20(quote()).safeTransfer(to, amount);
            return;
        }
        if (_bondedToUsdg()) {
            if (payout != PAY_USDG) revert BadPayout(payout);
            USDG.safeTransfer(to, amount);
            return;
        }
        _redeem(amount, to, payout, routes, minUsdgOut, allowFail);
    }

    /// Redeems `amount` of the curve's shares to `to`, in kind or to USDG, never as shares.
    function _redeem(uint256 amount, address to, uint8 payout, MaidMarianEtfV3.Route[] calldata routes, uint256 minUsdgOut, uint16 allowFail) private {
        if (payout == PAY_QUOTE) revert SharesStayInTheCurve();
        if (payout != PAY_IN_KIND && payout != PAY_USDG) revert BadPayout(payout);
        MaidMarianEtfV3 etf = MaidMarianEtfV3(quote());
        if (etf.NON_MINTER_PENALTY_BPS() != 0) {
            uint256 covered = etf.mintOf(address(this));
            if (amount > covered) revert NotCovered(amount, covered);
        }
        if (payout == PAY_IN_KIND) etf.redeemInKind(amount, to, allowFail);
        else etf.redeem(amount, routesAtDue(etf, address(this), amount, routes), minUsdgOut, to);
    }

    /// Reverts while the ETF's early penalty would fall on the curve's redeem.
    function _requireNoHold() private view {
        MaidMarianEtfV3 etf = MaidMarianEtfV3(quote());
        uint256 endsAt = _holdEndsAt(etf);
        if (endsAt > block.timestamp) revert HoldRunning(endsAt);
    }

    /// When the ETF stops charging its early penalty on the curve's redeems; 0 when it charges none.
    function _holdEndsAt(MaidMarianEtfV3 etf) private view returns (uint256) {
        if (etf.EARLY_PENALTY_BPS() == 0) return 0;
        return etf.lastMintAt(address(this)) + etf.HOLD_PERIOD();
    }

    function _bondDue() private view returns (bool) {
        return realQuote() >= threshold() || tokenReserve <= reserved();
    }

    function _bondedToUsdg() private view returns (bool) {
        return bonded && graduatesToUsdg();
    }

    /// The bond in the quote itself: a plain quote, or an ETF quote whose pool pairs the token with its shares.
    function _bondInQuote() private {
        _bookUnbookedShares();
        _bond(quoteReserve, realQuote());
    }

    /// The bond of a curve with a USDG cut: keeps the shares the shares pool takes (`_sharesPooled`, none at
    /// a cut of 100) and redeems every other share held (the rest of the real quote and both fee pots) with
    /// the caller's routes, each set to its leg's whole due, so no leg stays here, never under the
    /// contract's floor (`_bondRoutesAtFloor`); the USDG is the balance change. Each pot becomes its part
    /// of it, rounded down: one rate for all, the redeem's. The shares pool opens at the curve's price
    /// (`quoteReserve / tokenReserve`, in shares) with the shares kept, the USDG pool at that price times
    /// the rate with the cut's part of the 70 % at that rate; the USDG left beyond the pots is the 30 %
    /// and the rounding, booked to `protocolFees`. The reserve ETF accrues its fee at the mint just made in
    /// this call, so its redeem mints the curve none.
    function _bondToUsdg(MaidMarianEtfV3 etf, MaidMarianEtfV3.Route[] calldata routes, uint256 minUsdgAtBond) private {
        _bookUnbookedShares();
        for (uint256 i = 0; i < routes.length; i++) {
            if (routes[i].amountIn == 0) revert BondRouteMissing(i);
        }
        uint256 real = realQuote();
        uint256 budget = real - real * SET_ASIDE_BPS / BPS;
        uint256 kept = _sharesPooled(real);
        uint256 shares = IERC20(address(etf)).balanceOf(address(this)) - kept;
        (MaidMarianEtfV3.Route[] memory atFloor, uint256 floor) = _bondRoutesAtFloor(etf, shares, routes);
        if (minUsdgAtBond > floor) floor = minUsdgAtBond;
        uint256 before = USDG.balanceOf(address(this));
        // The whole floor is checked on the balance change, below.
        etf.redeem(shares, atFloor, 0, address(this));
        uint256 usdgOut = USDG.balanceOf(address(this)) - before;
        if (usdgOut < floor) revert TooLittleUsdgAtBond(usdgOut, floor);
        emit BondRedeemed(shares, usdgOut);
        creatorFees = Math.mulDiv(usdgOut, creatorFees, shares);
        protocolFees = Math.mulDiv(usdgOut, protocolFees, shares);
        bonded = true;
        uint256 q = quoteReserve;
        if (kept > 0) {
            (uint256 sharesTokens, uint256 sharesQuote) = _openPool(quote(), q, kept);
            uint256 left = kept - sharesQuote;
            protocolShares = left;
            emit Bonded(token(), _poolId(quote()), quote(), left, sharesTokens, sharesQuote, 0);
        }
        (uint256 poolTokens, uint256 poolQuote) = _openPool(address(USDG), Math.mulDiv(q, usdgOut, shares), Math.mulDiv(usdgOut, budget - kept, shares));
        _closeBond(poolTokens, poolQuote);
    }

    /// The shares a bond keeps for the shares pool out of the real quote `real`: the part of its 70 % the
    /// USDG cut leaves, all of it at a cut of 0, none at 100.
    function _sharesPooled(uint256 real) private view returns (uint256) {
        return (real - real * SET_ASIDE_BPS / BPS) * (CURVE_CUT_ALL - usdgCutPct()) / CURVE_CUT_ALL;
    }

    /// Whether the curve has two bond pools: an ETF quote with a cut of 25, 50 or 75.
    function _twoPools() private view returns (bool) {
        uint256 cut = usdgCutPct();
        return cut != 0 && cut != CURVE_CUT_ALL;
    }

    function _poolId(address currency) private view returns (bytes32) {
        // A few reads per bond: plain `keccak256` for readability.
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(poolKeyIn(currency)));
    }

    /// The bond's redeem routes: each set to its leg's whole due (`moveRouteToDue`), its `amountOutMin`
    /// raised to the leg's floor when lower: the due at the leg's price by the reserve ETF's own factory's
    /// `getTradablePriceUsdg` (its pool's 30 min TWAP, or a factory ETF's NAV on such prices; never a
    /// spot) less the fee of the pool it sells through and `BOND_TOLERANCE_BPS`. That pool is the token's
    /// registered one (`_registeredPool`), the route's `v4` flag overwritten, never the caller's choice.
    /// `floor`: the fund's USDG paid along plus every leg's floor. A leg due something without that price
    /// reverts (`BondLegUnpriced`). Read before the redeem, while the fund is inside none of its doors.
    function _bondRoutesAtFloor(MaidMarianEtfV3 etf, uint256 shares, MaidMarianEtfV3.Route[] calldata routes) private view returns (MaidMarianEtfV3.Route[] memory atFloor, uint256 floor) {
        (uint256[] memory due, uint256 usdg,,) = etf.previewRedeemToUsdg(address(this), shares);
        MaidMarianEtfFactory pricer = MaidMarianEtfFactory(address(etf.FACTORY()));
        MaidMarianEtfFactory.LegSpec[] memory legs = pricer.legsOf(address(etf));
        atFloor = routes;
        floor = usdg;
        uint256 n = Math.min(atFloor.length, due.length);
        for (uint256 i = 0; i < n; i++) {
            MaidMarianEtfV3.Route memory r = atFloor[i];
            moveRouteToDue(r, due[i]);
            if (due[i] == 0) continue;
            address leg = legs[i].token;
            (uint256 legPrice, uint8 source) = pricer.getTradablePriceUsdg(leg);
            if (legPrice == 0 || source == SOURCE_NONE) revert BondLegUnpriced(i, leg);
            uint256 scale = 10 ** uint256(IERC20Metadata(leg).decimals()) * USDG_UNIT_TO_18;
            uint256 fee;
            (r.v4, fee) = _registeredPool(address(pricer), leg);
            uint256 off = fee + BOND_TOLERANCE_BPS * (FEE_UNIT / BPS);
            uint256 legFloor = off >= FEE_UNIT ? 0 : Math.mulDiv(Math.mulDiv(due[i], legPrice, scale), FEE_UNIT - off, FEE_UNIT);
            if (r.amountOutMin < legFloor) r.amountOutMin = legFloor;
            floor += legFloor;
        }
    }

    /// The pool the reserve ETF sells `legToken` through at the bond, from its factory's `poolsOf`: the V4
    /// pool when one is registered (its tick spacing not 0, the factories' own "none"), else the V3 pool,
    /// which every listed token has. One pool per token is the rule; should both be registered, the V4
    /// wins, whatever a route says. `fee` in millionths, as registered: a V4 dynamic-fee flag (at or above
    /// `FEE_UNIT`) or an unreadable answer counts 0, the strictest floor. Read raw: the v3 bis factory
    /// answers four words, the v4 five, the first four alike.
    function _registeredPool(address factory, address legToken) private view returns (bool v4, uint256 fee) {
        (bool ok, bytes memory ret) = factory.staticcall(abi.encodeWithSelector(MaidMarianEtfFactory.poolsOf.selector, legToken));
        if (!ok || ret.length < 128) return (false, 0);
        (, uint256 v3Fee, uint256 v4Fee, int256 v4TickSpacing) = abi.decode(ret, (uint256, uint256, uint256, int256));
        v4 = v4TickSpacing != 0;
        fee = v4 ? v4Fee : v3Fee;
        if (fee >= FEE_UNIT) fee = 0;
    }

    /// The bond in the quote itself: opens its pool at the price `q / tokenReserve` with 70 % of `real`,
    /// the real quote in it, and closes the bond (`_closeBond`). On the quote itself `curveFits` was
    /// checked at the buy.
    function _bond(uint256 q, uint256 real) private {
        bonded = true;
        (uint256 poolTokens, uint256 poolQuote) = _openPool(quote(), q, real - real * SET_ASIDE_BPS / BPS);
        _closeBond(poolTokens, poolQuote);
    }

    /// Opens the pool of the token and `currency` at the price `q / tokenReserve` with at most `budget` of
    /// `currency` and the tokens that hold that price. The pool does not exist before: `HOOK` lets only
    /// this curve initialize it, and the bond is the curve's only call to `initialize`. `curveFits` is
    /// checked here for a price in USDG.
    function _openPool(address currency, uint256 q, uint256 budget) private returns (uint256 poolTokens, uint256 poolQuote) {
        uint256 t = tokenReserve;
        if (budget < 2 || !curveFits(q, t)) revert BondDoesNotFit(q, t);
        POOL_MANAGER.initialize(poolKeyIn(currency), _sqrtPriceAt(q, t, currency));
        (poolTokens, poolQuote) = abi.decode(POOL_MANAGER.unlock(abi.encode(OP_SEED, currency, q, budget)), (uint256, uint256));
    }

    /// The bond's last step: burns every token left, books what the curve holds of `poolCurrency()` beyond
    /// the fee pots and `ownerPot` (the 30 % and the pool's rounding) to `protocolFees`. It pays no one.
    function _closeBond(uint256 poolTokens, uint256 poolQuote) private {
        MaidMarianToken launched = MaidMarianToken(token());
        uint256 burned = launched.balanceOf(address(this));
        launched.burn(burned);
        address paired = poolCurrency();
        uint256 setAside = IERC20(paired).balanceOf(address(this)) - creatorFees - protocolFees - ownerPot[paired];
        protocolFees += setAside;
        bondSetAside = setAside;
        emit Bonded(address(launched), poolId(), paired, setAside, poolTokens, poolQuote, burned);
    }

    /// Collects the fees of the pool of the token and `currency`, through the PoolManager's unlock.
    function _collect(address currency) private returns (uint256 tokenFees, uint256 quoteFees) {
        (tokenFees, quoteFees) = abi.decode(POOL_MANAGER.unlock(abi.encode(OP_COLLECT, currency)), (uint256, uint256));
    }

    /// Inside the unlock: adds the full-range position, at most `budget` of `currency` and the tokens held,
    /// to the pool just initialized at `q / tokenReserve`, and settles.
    function _seed(IPoolManagerV4.PoolKey memory key, address currency, uint256 q, uint256 budget) private returns (uint256 poolTokens, uint256 poolQuote) {
        uint256 t = tokenReserve;
        uint256 held = IERC20(token()).balanceOf(address(this));
        uint160 sqrtPrice = _sqrtPriceAt(q, t, currency);
        // What the position may take, one unit short of each so the PoolManager's rounding up stays within it.
        uint256 liquidity = key.currency0 == token() ? _liquidity(sqrtPrice, held - 1, budget - 1) : _liquidity(sqrtPrice, budget - 1, held - 1);
        if (liquidity == 0) revert BondDoesNotFit(q, t);
        // forge-lint: disable-next-line(unsafe-typecast)
        (int256 delta,) = POOL_MANAGER.modifyLiquidity(key, _range(int256(liquidity)), "");
        (int256 dToken, int256 dQuote) = _split(delta, currency);
        // forge-lint: disable-next-line(unsafe-typecast)
        (poolTokens, poolQuote) = (uint256(-dToken), uint256(-dQuote));
        _settle(token(), dToken);
        _settle(currency, dQuote);
    }

    /// Pays the PoolManager what the curve owes in `currency` (`delta` < 0), or takes what it is owed.
    function _settle(address currency, int256 delta) private {
        if (delta < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 owed = uint256(-delta);
            POOL_MANAGER.sync(currency);
            IERC20(currency).safeTransfer(address(POOL_MANAGER), owed);
            POOL_MANAGER.settle();
        } else if (delta > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            POOL_MANAGER.take(currency, address(this), uint256(delta));
        }
    }

    /// A V4 `BalanceDelta` of the token / `currency` pool as (the token's, the currency's): amount0 in the
    /// high 128 bits, amount1 in the low.
    function _split(int256 delta, address currency) private view returns (int256 dToken, int256 dQuote) {
        int256 a0 = delta >> 128;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 a1 = int256(int128(delta));
        (dToken, dQuote) = token() < currency ? (a0, a1) : (a1, a0);
    }

    function _range(int256 liquidityDelta) private pure returns (IPoolManagerV4.ModifyLiquidityParams memory) {
        return IPoolManagerV4.ModifyLiquidityParams({ tickLower: POOL_TICK_LOWER, tickUpper: POOL_TICK_UPPER, liquidityDelta: liquidityDelta, salt: bytes32(0) });
    }

    /// The full-range liquidity `amount0` and `amount1` buy at `sqrtPrice`, the smaller of the two.
    function _liquidity(uint160 sqrtPrice, uint256 amount0, uint256 amount1) private pure returns (uint256) {
        uint256 lower = TickMath.getSqrtPriceAtTick(POOL_TICK_LOWER);
        uint256 upper = TickMath.getSqrtPriceAtTick(POOL_TICK_UPPER);
        uint256 l0 = Math.mulDiv(amount0, Math.mulDiv(sqrtPrice, upper, Q96), upper - sqrtPrice);
        uint256 l1 = Math.mulDiv(amount1, Q96, sqrtPrice - lower);
        return Math.min(l0, l1);
    }

    /// `sqrtPriceX96` of the price `q` of `currency` per `t` tokens, as currency1 per currency0.
    /// `curveFits` keeps the ratio under 2^64 either way, so `ratio x 2^192` fits.
    function _sqrtPriceAt(uint256 q, uint256 t, address currency) private view returns (uint160) {
        (uint256 a1, uint256 a0) = token() < currency ? (q, t) : (t, q);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(Math.sqrt(Math.mulDiv(a1, 1 << 192, a0)));
    }

    /// `len` (1 - 32) bytes of the clone's arguments from `offset`, big-endian.
    function _arg(uint256 offset, uint256 len) private view returns (uint256 v) {
        assembly ("memory-safe") {
            extcodecopy(address(), 0, add(CLONE_CODE_BYTES, offset), 32)
            v := shr(sub(256, shl(3, len)), mload(0))
        }
    }
}
