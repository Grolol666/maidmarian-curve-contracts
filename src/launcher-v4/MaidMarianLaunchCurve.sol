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

/// 5/7 of the supply sold on the curve, 2/7 left at its end, whatever the supply.
function curveReserved(uint256 supply) pure returns (uint256) {
    return (2 * supply) / 7;
}

uint256 constant CURVE_BPS = 10_000;

uint8 constant CURVE_PAY_QUOTE = 0;
uint8 constant CURVE_PAY_IN_KIND = 1;
uint8 constant CURVE_PAY_USDG = 2;

/// x * y = k on the quote reserve (phantom plus real); fee and tax come off `quoteIn` first, outside k.
function curveBuy(uint256 q, uint256 t, uint256 quoteIn, uint256 feeBps, uint256 taxBps) pure returns (uint256 tokensOut, uint256 fee, uint256 tax, uint256 net) {
    fee = quoteIn * feeBps / CURVE_BPS;
    tax = quoteIn * taxBps / CURVE_BPS;
    net = quoteIn - fee - tax;
    tokensOut = t - Math.ceilDiv(q * t, q + net);
}

/// Whether a pool opens at `q / t`: both ratios under 2^64 (the `sqrtPriceX96` math) and `q` under
/// 2^127 (a V4 delta).
function curveFits(uint256 q, uint256 t) pure returns (bool) {
    return q >> 127 == 0 && q >> 64 < t && t >> 64 < q;
}

function curveSell(uint256 q, uint256 t, uint256 tokensIn, uint256 feeBps, uint256 taxBps) pure returns (uint256 gross, uint256 fee, uint256 tax) {
    gross = q - Math.ceilDiv(q * t, t + tokensIn);
    fee = gross * feeBps / CURVE_BPS;
    tax = gross * taxBps / CURVE_BPS;
}

// Packed clone arguments: quote 20, kind 1, creator tax 2, threshold 16, creator 20, supply 12 bytes.
uint256 constant CURVE_ARGS_ETF = 20;
uint256 constant CURVE_ARGS_TAX = 21;
uint256 constant CURVE_ARGS_THRESHOLD = 23;
uint256 constant CURVE_ARGS_CREATOR = 39;
uint256 constant CURVE_ARGS_SUPPLY = 59;
uint8 constant CURVE_CUT_STEP = 25;
uint8 constant CURVE_CUT_ALL = 100;
// `usdgCutPct` and kind byte of a bond that explodes the reserve into one pool per leg.
uint8 constant CURVE_EXPLOSION = 255;
uint8 constant CURVE_KIND_EXPLOSION = 6;

/// `routes` with each selling route set to its leg's whole due, `amountOutMin` scaled and rounded up,
/// so a payout to USDG leaves no remainder in kind.
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

function moveRouteToDue(MaidMarianEtfV3.Route memory r, uint256 due) pure {
    if (r.amountIn == 0 || r.amountIn == due) return;
    r.amountOutMin = Math.mulDiv(r.amountOutMin, due, r.amountIn, Math.Rounding.Ceil);
    r.amountIn = due;
}

function curveCloneArgs(address quote, bool etfQuote, uint8 usdgCutPct, uint16 creatorTaxBps, uint128 threshold, address creator, uint96 supply) pure returns (bytes memory) {
    uint8 kind = !etfQuote ? 0 : usdgCutPct == CURVE_EXPLOSION ? CURVE_KIND_EXPLOSION : 1 + usdgCutPct / CURVE_CUT_STEP;
    return abi.encodePacked(quote, kind, creatorTaxBps, threshold, creator, supply);
}

interface IMaidMarianTokenLauncherReads {
    function owner() external view returns (address);
    function logo(address curve) external view returns (bytes memory);
}

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
 * @notice The bonding curve of one token, quoted in a factory ETF's shares or a listed token; its last
 * buy bonds into Uniswap V4 pools behind `HOOK`. An ETF quote's shares never leave it but into the
 * ETF's redeem or a bond pool.
 * @dev An EIP-1167 clone of one implementation, initialized by its launcher in the launch.
 */
contract MaidMarianLaunchCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------ constants ---

    uint256 public constant FEE_BPS = 75;

    uint256 public constant PROTOCOL_SHARE_BPS = 3000;

    uint256 public constant MAX_CREATOR_TAX_BPS = 1000;

    /// `9 900 >> (s x 14 / 3)` bps `s` seconds after the launch, 0 from 3 s.
    uint256 public constant SNIPE_TAX_START_BPS = 9900;
    uint256 public constant SNIPE_TAX_SECONDS = 3;

    uint256 public constant MAX_SNIPE_EXEMPTIONS = 10;

    /// The bond's floor under each leg's 30 min TWAP value, beyond its pool's fee: the contract's, not the
    /// last buyer's, since that redeem sells the whole fund.
    uint256 public constant BOND_TOLERANCE_BPS = 100;

    /// V3 and V4 fees are in millionths; at or above it a V4 fee is the dynamic flag.
    uint256 private constant FEE_UNIT = 1_000_000;

    uint256 public constant SET_ASIDE_BPS = 3000;

    /// 1 %, full range.
    uint24 public constant POOL_FEE = 10_000;
    int24 public constant POOL_TICK_SPACING = 200;
    int24 public constant POOL_TICK_LOWER = -887_200;
    int24 public constant POOL_TICK_UPPER = 887_200;

    uint8 public constant PAY_QUOTE = CURVE_PAY_QUOTE;
    uint8 public constant PAY_IN_KIND = CURVE_PAY_IN_KIND;
    uint8 public constant PAY_USDG = CURVE_PAY_USDG;

    uint256 private constant BPS = CURVE_BPS;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant CLONE_CODE_BYTES = 0x2d;
    uint8 private constant OP_SEED = 1;
    uint8 private constant OP_COLLECT = 2;
    uint8 private constant OP_EXPLODE = 3;

    /// One swap in each pool at its bond, so an indexer lists every pool at once.
    uint256 public constant BOND_SWAP_QUOTE_UNITS = 16;

    // ----------------------------------------------------------- immutables ---

    IMaidMarianTokenLauncherReads public immutable FACTORY;
    IERC20 public immutable USDG;
    IPoolManagerV4 public immutable POOL_MANAGER;
    address public immutable HOOK;
    address private immutable SELF;
    uint256 private immutable USDG_UNIT_TO_18;

    // ---------------------------------------------------------------- state ---

    uint256 public quoteReserve;
    uint256 public tokenReserve;

    uint256 public creatorFees;
    uint256 public protocolFees;

    uint256 public bondSetAside;

    /// The reserve ETF's shares held for the protocol beside a USDG pool, claimed with `claimShares`.
    uint256 public protocolShares;

    address public token;

    uint64 public launchedAt;
    bool public bonded;
    bool private _initialized;
    /// Until set, a mint's sweep reads this one word instead of a pot per asset.
    bool private _ownerPotUsed;
    /// Bit i set when leg i's pool was opened.
    uint16 public explodedLegs;

    /// Refunds the owner's address refused, and an explosion's USDG, leg rounding, swap output and 30 % of leg fees.
    mapping(address asset => uint256) public ownerPot;

    /// The creator's 70 % of each leg pool's fees.
    mapping(address asset => uint256) public creatorPot;

    /// The pool an explosion bond is initializing, for `isBondPool`.
    bytes32 private transient _opening;

    /// The creator is exempt without an entry.
    mapping(address account => bool) private _snipeExempt;

    // --------------------------------------------------------------- events ---

    /// `usdgIn`: the USDG minted into `quoteIn` (0 for `buy`).
    event Bought(address indexed buyer, uint256 quoteIn, uint256 usdgIn, uint256 tokensOut, uint256 fee, uint256 tax, uint256 quoteReserve, uint256 tokenReserve);
    event Sold(address indexed seller, uint256 tokensIn, uint256 quoteOut, uint8 payout, uint256 fee, uint256 tax, uint256 quoteReserve, uint256 tokenReserve);
    /// One per pool the bond opens, a shares pool first, an explosion's in leg order; `setAside` and
    /// `burned` on the last pool only.
    event Bonded(address indexed token, bytes32 indexed poolId, address pairedWith, uint256 setAside, uint256 poolTokens, uint256 poolQuote, uint256 burned);
    event BondRedeemed(uint256 shares, uint256 usdgOut);
    event FeesClaimed(address indexed by, address indexed to, bool protocol, uint256 amount, uint8 payout);
    event SharesClaimed(address indexed by, address indexed to, uint256 amount, uint8 payout);
    event OwnerPotBooked(address indexed asset, uint256 amount);
    event OwnerPotClaimed(address indexed asset, address indexed to, uint256 amount);
    event PoolFeesCollected(uint256 tokenFees, uint256 quoteFees, uint256 shareFees);
    event BondSwapped(bytes32 indexed poolId, uint256 tokensIn, uint256 quoteOut);
    event CreatorPotBooked(address indexed asset, uint256 amount);
    event CreatorPotClaimed(address indexed asset, address indexed to, uint256 amount);

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
    error BuyTooLarge(uint256 quoteReserve, uint256 tokenReserve);
    error BondRouteMissing(uint256 leg);
    error TooLittleUsdgAtBond(uint256 usdgOut, uint256 minUsdgOut);
    /// A leg is due something and has no 30 min TWAP: no floor, so the bond waits.
    error BondLegUnpriced(uint256 leg, address token);
    error BondDoesNotFit(uint256 quoteReserve, uint256 tokenReserve);

    // ---------------------------------------------------------- constructor ---

    /// The implementation; locked.
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

    /// @notice Called once by the launcher in the launch: creates the token, its supply minted here.
    /// @param snipeExempt Flagged as given: a zero address, the creator or a repeat harms nobody.
    function initialize(address[] calldata snipeExempt, string calldata name_, string calldata symbol_) external {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        if (_initialized) revert AlreadyInitialized();
        if (snipeExempt.length > MAX_SNIPE_EXEMPTIONS) revert TooManyExemptions(snipeExempt.length, MAX_SNIPE_EXEMPTIONS);
        _initialized = true;
        token = address(new MaidMarianToken(name_, symbol_, supply()));
        launchedAt = uint64(block.timestamp);
        quoteReserve = phantomQuote();
        tokenReserve = supply();
        // A clone's storage starts at 0: the guard is set to NOT_ENTERED.
        StorageSlot.getUint256Slot(_reentrancyGuardStorageSlot()).value = 1;
        for (uint256 i = 0; i < snipeExempt.length; i++) {
            _snipeExempt[snipeExempt[i]] = true;
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

    /// @notice Buy with a plain quote, all of `quoteIn` bought: the last buy goes past the curve's end and bonds.
    function buy(uint256 quoteIn, uint256 minTokensOut) external onlyClone nonReentrant returns (uint256 tokensOut) {
        return _buyInQuote(msg.sender, quoteIn, minTokensOut);
    }

    /// @notice `buy` by the launcher for `buyer`, the caller of its door.
    function buyFor(address buyer, uint256 quoteIn, uint256 minTokensOut) external onlyClone nonReentrant returns (uint256 tokensOut) {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        return _buyInQuote(buyer, quoteIn, minTokensOut);
    }

    /// @notice Buy with USDG on an ETF quote: the curve mints the shares with `routes` and buys with them;
    /// the mint's refunds go to the owner.
    /// @param bondRoutes, minUsdgAtBond Read only by a buy that bonds a curve with a USDG cut; floored by the contract.
    function buyWithUsdg(uint256 usdgIn, MaidMarianEtfV3.Route[] calldata routes, uint256 minShares, uint256 minTokensOut, MaidMarianEtfV3.Route[] calldata bondRoutes, uint256 minUsdgAtBond)
        external
        onlyClone
        nonReentrant
        returns (uint256 tokensOut)
    {
        return _buyInUsdg(msg.sender, usdgIn, routes, minShares, minTokensOut, bondRoutes, minUsdgAtBond);
    }

    /// @notice `buyWithUsdg` by the launcher for `buyer`.
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

    /// @notice Sell, paid in the plain quote or by the curve's redeem of an ETF quote, in kind or to USDG.
    /// `PAY_IN_KIND` needs no pool; `allowFail` bit i lets leg i's transfer fail, its part left in the fund.
    function sell(uint256 tokensIn, uint256 minQuoteOut, uint8 payout, MaidMarianEtfV3.Route[] calldata routes, uint256 minUsdgOut, uint16 allowFail)
        external
        onlyClone
        nonReentrant
        returns (uint256 quoteOut)
    {
        quoteOut = _sell(msg.sender, tokensIn, minQuoteOut, payout);
        _payOut(quoteOut, msg.sender, payout, routes, minUsdgOut, allowFail);
    }

    /// @notice `sell` by the launcher for `seller`, a plain quote only.
    function sellFor(address seller, uint256 tokensIn, uint256 minQuoteOut) external onlyClone nonReentrant returns (uint256 quoteOut) {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        if (etfQuote()) revert SharesStayInTheCurve();
        quoteOut = _sell(seller, tokensIn, minQuoteOut, PAY_QUOTE);
        IERC20(quote()).safeTransfer(msg.sender, quoteOut);
    }

    /// @notice Claim the creator's fees or the protocol's (the 30 % included), as `sell` pays.
    function claim(bool protocol, uint256 amount, address to, uint8 payout, MaidMarianEtfV3.Route[] calldata routes, uint256 minUsdgOut, uint16 allowFail) external onlyClone nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _debitFees(msg.sender, protocol, amount);
        _payOut(amount, to, payout, routes, minUsdgOut, allowFail);
        emit FeesClaimed(msg.sender, to, protocol, amount, payout);
    }

    /// @notice `claim` by the launcher for `claimant`, a plain quote only.
    function claimFor(address claimant, bool protocol, uint256 amount) external onlyClone nonReentrant {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        if (etfQuote()) revert SharesStayInTheCurve();
        _debitFees(claimant, protocol, amount);
        IERC20(quote()).safeTransfer(msg.sender, amount);
        emit FeesClaimed(claimant, msg.sender, protocol, amount, PAY_QUOTE);
    }

    /// @notice Once bonded with a USDG cut, redeem the reserve ETF's shares held: the creator's, the owner's.
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

    /// @notice Send the refunds kept for the owner in `asset` to `to`.
    function claimOwnerPot(address asset, address to) external onlyClone nonReentrant returns (uint256 amount) {
        if (msg.sender != FACTORY.owner()) revert NotOwner();
        if (to == address(0)) revert ZeroAddress();
        amount = ownerPot[asset];
        if (amount == 0) revert NothingIn();
        ownerPot[asset] = 0;
        IERC20(asset).safeTransfer(to, amount);
        emit OwnerPotClaimed(asset, to, amount);
    }

    /// @notice Send the creator's part of the leg pools' fees in `asset` to `to`.
    function claimCreatorPot(address asset, address to) external onlyClone nonReentrant returns (uint256 amount) {
        if (msg.sender != creator()) revert NotCreator();
        if (to == address(0)) revert ZeroAddress();
        amount = creatorPot[asset];
        if (amount == 0) revert NothingIn();
        creatorPot[asset] = 0;
        IERC20(asset).safeTransfer(to, amount);
        emit CreatorPotClaimed(asset, to, amount);
    }

    /// @notice After the bond, collect every pool's fees, 70 % to the creator, 30 % to the owner. Anyone.
    function collectPoolFees() external onlyClone nonReentrant returns (uint256 tokenFees, uint256 quoteFees) {
        if (!bonded) revert NotBonded();
        _bookUnbookedShares();
        uint256 shareFees;
        if (explodes()) tokenFees = _collectLegPools();
        else (tokenFees, quoteFees) = _collect(poolCurrency());
        if (_twoPools()) {
            uint256 tokensInShares;
            (tokensInShares, shareFees) = _collect(quote());
            tokenFees += tokensInShares;
            protocolShares += shareFees * PROTOCOL_SHARE_BPS / BPS;
        }
        if (tokenFees > 0) {
            uint256 toProtocol = tokenFees * PROTOCOL_SHARE_BPS / BPS;
            IERC20(token).safeTransfer(FACTORY.owner(), toProtocol);
            IERC20(token).safeTransfer(creator(), tokenFees - toProtocol);
        }
        if (quoteFees > 0) _takeFees(quoteFees, 0);
        emit PoolFeesCollected(tokenFees, quoteFees, shareFees);
    }

    /// @notice The PoolManager's callback: the bond's seeding and the fee collection.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (uint8 op, address currency) = abi.decode(data, (uint8, address));
        if (op == OP_EXPLODE) {
            (,, address[] memory legs, uint256[] memory got, uint256[] memory tokens) = abi.decode(data, (uint8, address, address[], uint256[], uint256[]));
            (uint256[] memory poolTokens, uint256[] memory poolQuote, uint256[] memory rest) = _seedLegPools(legs, got, tokens);
            return abi.encode(poolTokens, poolQuote, rest);
        }
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
        if (tokenFees > 0) POOL_MANAGER.take(token, address(this), tokenFees);
        if (quoteFees > 0) POOL_MANAGER.take(currency, address(this), quoteFees);
        return abi.encode(tokenFees, quoteFees);
    }

    // ---------------------------------------------------------------- views ---

    function quote() public view returns (address) {
        return address(uint160(_arg(0, 20)));
    }

    function etfQuote() public view returns (bool) {
        return _arg(CURVE_ARGS_ETF, 1) != 0;
    }

    /// 0 for a plain quote and an explosion.
    function usdgCutPct() public view returns (uint256) {
        uint256 kind = _arg(CURVE_ARGS_ETF, 1);
        return kind == 0 || kind == CURVE_KIND_EXPLOSION ? 0 : (kind - 1) * CURVE_CUT_STEP;
    }

    function explodes() public view returns (bool) {
        return _arg(CURVE_ARGS_ETF, 1) == CURVE_KIND_EXPLOSION;
    }

    function graduatesToUsdg() public view returns (bool) {
        return usdgCutPct() != 0;
    }

    /// The bond pool's other currency: USDG for a cut above 0, else the quote.
    function poolCurrency() public view returns (address) {
        return graduatesToUsdg() ? address(USDG) : quote();
    }

    function creatorTaxBps() public view returns (uint256) {
        return _arg(CURVE_ARGS_TAX, 2);
    }

    function threshold() public view returns (uint256) {
        return _arg(CURVE_ARGS_THRESHOLD, 16);
    }

    /// 2/5 of the threshold, so the curve's 5/7 sell for the threshold.
    function phantomQuote() public view returns (uint256) {
        return threshold() * 2 / 5;
    }

    function creator() public view returns (address) {
        return address(uint160(_arg(CURVE_ARGS_CREATOR, 20)));
    }

    function supply() public view returns (uint256) {
        return _arg(CURVE_ARGS_SUPPLY, 12);
    }

    function reserved() public view returns (uint256) {
        return curveReserved(supply());
    }

    function realQuote() public view returns (uint256) {
        return quoteReserve - phantomQuote();
    }

    function getReserves() external view returns (uint256 quoteReserve_, uint256 tokenReserve_) {
        return (quoteReserve, tokenReserve);
    }

    /// Shares held beyond what the curve books (the ETF's management fee, a donation): the next door books them to the creator.
    function unbookedShares() public view returns (uint256) {
        if (!etfQuote() || _bondedToUsdg()) return 0;
        uint256 booked = creatorFees + protocolFees + (bonded ? 0 : realQuote());
        uint256 held = IERC20(quote()).balanceOf(address(this));
        return held > booked ? held - booked : 0;
    }

    function claimableShares() public view returns (uint256) {
        if (!_bondedToUsdg()) return 0;
        uint256 held = IERC20(quote()).balanceOf(address(this));
        return held > protocolShares ? held - protocolShares : 0;
    }

    function price() external view returns (uint256) {
        return Math.mulDiv(quoteReserve, 1e18, tokenReserve);
    }

    function isSnipeExempt(address account) public view returns (bool) {
        return account == creator() || _snipeExempt[account];
    }

    function currentSnipeTaxBps(address buyer) public view returns (uint256) {
        if (isSnipeExempt(buyer)) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        if (elapsed >= SNIPE_TAX_SECONDS) return 0;
        return SNIPE_TAX_START_BPS >> (elapsed * 14 / SNIPE_TAX_SECONDS);
    }

    function previewBuy(uint256 quoteIn, address buyer) external view returns (uint256 tokensOut, uint256 fee, uint256 tax) {
        if (bonded || quoteIn == 0) return (0, 0, 0);
        (uint256 q, uint256 t) = (quoteReserve, tokenReserve);
        uint256 net;
        (tokensOut, fee, tax, net) = curveBuy(q, t, quoteIn, _feeBps(buyer), creatorTaxBps());
        if (!curveFits(q + net, t - tokensOut)) return (0, 0, 0);
    }

    function previewSell(uint256 tokensIn) external view returns (uint256 quoteOut, uint256 fee, uint256 tax) {
        if (bonded || tokensIn == 0 || tokenReserve + tokensIn > supply()) return (0, 0, 0);
        uint256 gross;
        (gross, fee, tax) = curveSell(quoteReserve, tokenReserve, tokensIn, FEE_BPS, creatorTaxBps());
        quoteOut = gross - fee - tax;
    }

    /// The shares a bonding buy's redeem takes and their due, read now.
    function previewBond(uint256 sharesMinted) external view returns (uint256 shares, uint256[] memory due, uint256 usdg) {
        if (!etfQuote()) return (0, due, 0);
        uint256 net = sharesMinted - sharesMinted * (FEE_BPS + creatorTaxBps()) / BPS;
        uint256 real = realQuote() + net;
        if (explodes()) shares = real - real * SET_ASIDE_BPS / BPS;
        else shares = IERC20(quote()).balanceOf(address(this)) + sharesMinted - _sharesPooled(real);
        (due, usdg) = MaidMarianEtfV3(quote()).quoteMint(shares);
    }

    function poolKey() public view returns (IPoolManagerV4.PoolKey memory) {
        return poolKeyIn(poolCurrency());
    }

    function poolId() public view returns (bytes32) {
        return _poolId(poolCurrency());
    }

    /// Sorted, 1 %, spacing 200, `HOOK`.
    function poolKeyIn(address currency) public view returns (IPoolManagerV4.PoolKey memory key) {
        address t = token;
        (address c0, address c1) = t < currency ? (t, currency) : (currency, t);
        key = IPoolManagerV4.PoolKey({ currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: POOL_TICK_SPACING, hooks: HOOK });
    }

    /// What `HOOK` lets this curve initialize.
    function isBondPool(bytes32 id) external view returns (bool) {
        if (!explodes()) return id == poolId() || (_twoPools() && id == _poolId(quote()));
        if (id == _opening) return true;
        if (!bonded) return false;
        address[] memory pools = bondPools();
        for (uint256 i = 0; i < pools.length; i++) {
            if (id == _poolId(pools[i])) return true;
        }
        return false;
    }

    function bondPools() public view returns (address[] memory pools) {
        if (explodes()) {
            MaidMarianEtfFactory.LegSpec[] memory legs = _legsOf(MaidMarianEtfV3(quote()));
            uint256 mask = bonded ? explodedLegs : type(uint16).max;
            pools = new address[](legs.length);
            uint256 k;
            for (uint256 i = 0; i < legs.length; i++) {
                // forge-lint: disable-next-line(incorrect-shift)
                if (mask & (1 << i) != 0) pools[k++] = legs[i].token;
            }
            assembly ("memory-safe") {
                mstore(pools, k)
            }
            return pools;
        }
        pools = new address[](_twoPools() ? 2 : 1);
        if (_twoPools()) (pools[0], pools[1]) = (quote(), address(USDG));
        else pools[0] = poolCurrency();
    }

    function logo() external view returns (bytes memory) {
        return FACTORY.logo(address(this));
    }

    // ------------------------------------------------------------- internal ---

    function _buyInQuote(address buyer, uint256 quoteIn, uint256 minTokensOut) private returns (uint256 tokensOut) {
        if (etfQuote()) revert SharesStayInTheCurve();
        if (quoteIn == 0) revert NothingIn();
        IERC20(quote()).safeTransferFrom(msg.sender, address(this), quoteIn);
        tokensOut = _buy(buyer, quoteIn, 0, minTokensOut);
        if (_bondDue()) _bondInQuote();
    }

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
        // The ETF's first mint refunds nothing: its balance reads are skipped.
        bool first = etf.totalSupply() == 0;
        uint256 shares = etf.mint(usdgIn, routes, minShares);
        if (!first) _sweepMintRefunds(etf);
        tokensOut = _buy(buyer, shares, usdgIn, minTokensOut);
        if (!_bondDue()) return tokensOut;
        if (explodes()) _explode(etf);
        else if (graduatesToUsdg()) _bondToUsdg(etf, bondRoutes, minUsdgAtBond);
        else _bondInQuote();
    }

    function _buy(address buyer, uint256 quoteIn, uint256 usdgIn, uint256 minTokensOut) private returns (uint256 tokensOut) {
        if (bonded) revert AlreadyBonded();
        (uint256 q, uint256 t) = (quoteReserve, tokenReserve);
        (uint256 out, uint256 fee, uint256 tax, uint256 net) = curveBuy(q, t, quoteIn, _feeBps(buyer), creatorTaxBps());
        if (out == 0 || out < minTokensOut) revert TooFewTokens(out, minTokensOut);
        (q, t) = (q + net, t - out);
        if (!curveFits(q, t)) revert BuyTooLarge(q, t);
        (quoteReserve, tokenReserve) = (q, t);
        _takeFees(fee, tax);
        IERC20(token).safeTransfer(buyer, out);
        emit Bought(buyer, quoteIn, usdgIn, out, fee, tax, q, t);
        return out;
    }

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
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        emit Sold(seller, tokensIn, quoteOut, payout, fee, tax, q - gross, t + tokensIn);
    }

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

    function _takeFees(uint256 fee, uint256 tax) private {
        uint256 toProtocol = fee * PROTOCOL_SHARE_BPS / BPS;
        protocolFees += toProtocol;
        creatorFees += fee - toProtocol + tax;
    }

    /// A mint's refunds go to the owner: the buyer gets the tokens alone.
    function _sweepMintRefunds(MaidMarianEtfV3 etf) private {
        address to = FACTORY.owner();
        MaidMarianEtfFactory.LegSpec[] memory legs = _legsOf(etf);
        for (uint256 i = 0; i < legs.length; i++) {
            _sendToOwner(IERC20(legs[i].token), to);
        }
        _sendToOwner(USDG, to);
    }

    function _legsOf(MaidMarianEtfV3 etf) private view returns (MaidMarianEtfFactory.LegSpec[] memory) {
        return MaidMarianEtfFactory(address(etf.FACTORY())).legsOf(address(etf));
    }

    function _bookToOwner(address asset, uint256 amount) private {
        if (amount == 0) return;
        ownerPot[asset] += amount;
        _ownerPotUsed = true;
        emit OwnerPotBooked(asset, amount);
    }

    function _sendToOwner(IERC20 asset, address to) private {
        uint256 pot = _ownerPotUsed ? ownerPot[address(asset)] : 0;
        uint256 held = asset.balanceOf(address(this));
        uint256 left = held > pot ? held - pot : 0;
        if (left == 0 || asset.trySafeTransfer(to, left)) return;
        ownerPot[address(asset)] = pot + left;
        _ownerPotUsed = true;
        emit OwnerPotBooked(address(asset), left);
    }

    function _bookUnbookedShares() private {
        uint256 extra = unbookedShares();
        if (extra > 0) creatorFees += extra;
    }

    /// A redeem stays within the curve's `mintOf`, so it never pays a non-minter penalty.
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

    function _redeem(uint256 amount, address to, uint8 payout, MaidMarianEtfV3.Route[] calldata routes, uint256 minUsdgOut, uint16 allowFail) private {
        if (payout == PAY_QUOTE) revert SharesStayInTheCurve();
        if (payout != PAY_IN_KIND && payout != PAY_USDG) revert BadPayout(payout);
        MaidMarianEtfV3 etf = MaidMarianEtfV3(quote());
        if (etf.NON_MINTER_PENALTY_BPS() != 0) {
            uint256 covered = etf.mintOf(address(this));
            if (amount > covered) revert NotCovered(amount, covered);
        }
        if (payout == PAY_IN_KIND) {
            etf.redeemInKind(amount, to, allowFail);
        } else if (bonded && explodes()) {
            // Once exploded, the 30 % and the pots leave to USDG at the bond's floor.
            for (uint256 i = 0; i < routes.length; i++) {
                if (routes[i].amountIn == 0) revert BondRouteMissing(i);
            }
            (MaidMarianEtfV3.Route[] memory atFloor, uint256 floor) = _bondRoutesAtFloor(etf, amount, routes);
            etf.redeem(amount, atFloor, Math.max(floor, minUsdgOut), to);
        } else {
            etf.redeem(amount, routesAtDue(etf, address(this), amount, routes), minUsdgOut, to);
        }
    }

    function _requireNoHold() private view {
        MaidMarianEtfV3 etf = MaidMarianEtfV3(quote());
        uint256 endsAt = _holdEndsAt(etf);
        if (endsAt > block.timestamp) revert HoldRunning(endsAt);
    }

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

    function _bondInQuote() private {
        _bookUnbookedShares();
        _bond(quoteReserve, realQuote());
    }

    /// Each pot becomes its part of the redeem's USDG, one rate for all.
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
            uint256 left = IERC20(quote()).balanceOf(address(this));
            protocolShares = left;
            emit Bonded(token, _poolId(quote()), quote(), left, sharesTokens, sharesQuote, 0);
        }
        (uint256 poolTokens, uint256 poolQuote) = _openPool(address(USDG), Math.mulDiv(q, usdgOut, shares), Math.mulDiv(usdgOut, budget - kept, shares));
        _closeBond(poolTokens, poolQuote);
    }

    /// Redeems 70 % of the real quote in kind (no swap, nothing to sandwich) and opens one pool per leg,
    /// each sized by its TWAP worth so every pool opens at the same price in USDG, clamped to its weight +- 25 %.
    function _explode(MaidMarianEtfV3 etf) private {
        _bookUnbookedShares();
        uint256 real = realQuote();
        uint256 budget = real - real * SET_ASIDE_BPS / BPS;
        MaidMarianEtfFactory pricer = MaidMarianEtfFactory(address(etf.FACTORY()));
        MaidMarianEtfFactory.LegSpec[] memory specs = pricer.legsOf(address(etf));
        uint256 n = specs.length;
        address[] memory legs = new address[](n);
        (uint256[] memory due, uint256 usdgDue,,) = etf.previewRedeemToUsdg(address(this), budget);
        uint256[] memory got = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            legs[i] = specs[i].token;
            got[i] = IERC20(legs[i]).balanceOf(address(this));
        }
        uint256 usdgBefore = USDG.balanceOf(address(this));
        etf.redeemInKind(budget, address(this), type(uint16).max);
        _bookToOwner(address(USDG), USDG.balanceOf(address(this)) - usdgBefore);
        uint256 value = usdgDue * USDG_UNIT_TO_18;
        uint256[] memory tokens = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            got[i] = IERC20(legs[i]).balanceOf(address(this)) - got[i];
            if (due[i] == 0) continue;
            (uint256 legPrice, uint8 source) = pricer.getTradablePriceUsdg(legs[i]);
            if (legPrice == 0 || source == SOURCE_NONE) revert BondLegUnpriced(i, legs[i]);
            uint256 unit = 10 ** uint256(IERC20Metadata(legs[i]).decimals());
            value += Math.mulDiv(due[i], legPrice, unit);
            tokens[i] = Math.mulDiv(got[i], legPrice, unit);
        }
        bonded = true;
        uint256 tokensAtPrice = Math.mulDiv(budget, tokenReserve, quoteReserve);
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            if (tokens[i] == 0) continue;
            // A pushed TWAP moves a leg's share at most 25 % off its weight.
            uint256 w = Math.mulDiv(tokensAtPrice, specs[i].bps, BPS);
            tokens[i] = Math.min(Math.max(Math.mulDiv(tokensAtPrice, tokens[i], value), w * 3 / 4), w * 5 / 4);
            sum += tokens[i];
        }
        for (uint256 i = 0; i < n; i++) {
            if (tokens[i] == 0) continue;
            uint256 t = sum > tokensAtPrice ? Math.mulDiv(tokens[i], tokensAtPrice, sum) : tokens[i];
            tokens[i] = got[i] > 1 && curveFits(got[i], t) && _poolLiquidity(legs[i], got[i], t) != 0 ? t : 0;
        }
        (uint256[] memory poolTokens, uint256[] memory poolQuote, uint256[] memory rest) =
            abi.decode(POOL_MANAGER.unlock(abi.encode(OP_EXPLODE, address(0), legs, got, tokens)), (uint256[], uint256[], uint256[]));
        uint16 mask;
        uint256 last;
        for (uint256 i = 0; i < n; i++) {
            if (poolTokens[i] != 0) {
                // i < LEGS() <= 10.
                // forge-lint: disable-next-line(incorrect-shift, unsafe-typecast)
                mask |= uint16(1 << i);
                last = i;
            }
            _bookToOwner(legs[i], rest[i]);
        }
        if (mask == 0) revert BondDoesNotFit(quoteReserve, tokenReserve);
        explodedLegs = mask;
        MaidMarianToken launched = MaidMarianToken(token);
        uint256 burned = launched.balanceOf(address(this));
        launched.burn(burned);
        uint256 setAside = IERC20(address(etf)).balanceOf(address(this)) - creatorFees - protocolFees;
        protocolFees += setAside;
        bondSetAside = setAside;
        for (uint256 i = 0; i <= last; i++) {
            if (poolTokens[i] == 0) continue;
            emit Bonded(address(launched), _poolId(legs[i]), legs[i], i == last ? setAside : 0, poolTokens[i], poolQuote[i], i == last ? burned : 0);
        }
    }

    function _poolLiquidity(address currency, uint256 amount, uint256 tokens) private view returns (uint256) {
        uint160 sqrtPrice = _sqrtPriceAt(amount, tokens, currency);
        return token < currency ? _liquidity(sqrtPrice, tokens, amount - 1) : _liquidity(sqrtPrice, amount - 1, tokens);
    }

    function _seedLegPools(address[] memory legs, uint256[] memory got, uint256[] memory tokens) private returns (uint256[] memory poolTokens, uint256[] memory poolQuote, uint256[] memory rest) {
        uint256 n = legs.length;
        (poolTokens, poolQuote, rest) = (new uint256[](n), new uint256[](n), new uint256[](n));
        int256 tokenDelta;
        for (uint256 i = 0; i < n; i++) {
            rest[i] = got[i];
            if (tokens[i] == 0) continue;
            IPoolManagerV4.PoolKey memory key = poolKeyIn(legs[i]);
            // forge-lint: disable-next-line(asm-keccak256)
            bytes32 id = keccak256(abi.encode(key));
            _opening = id;
            POOL_MANAGER.initialize(key, _sqrtPriceAt(got[i], tokens[i], legs[i]));
            int256 dToken;
            int256 dQuote;
            (poolTokens[i], poolQuote[i], dToken, dQuote) = _addAndSwap(key, id, legs[i], _poolLiquidity(legs[i], got[i], tokens[i]), got[i], tokens[i]);
            _settle(legs[i], dQuote);
            tokenDelta += dToken;
            // The leg owed for the position less the swap's output, under what was received.
            // forge-lint: disable-next-line(unsafe-typecast)
            rest[i] = got[i] - uint256(-dQuote);
        }
        _opening = bytes32(0);
        _settle(token, tokenDelta);
    }

    function _addAndSwap(IPoolManagerV4.PoolKey memory key, bytes32 id, address currency, uint256 liquidity, uint256 num, uint256 den)
        private
        returns (uint256 poolTokens, uint256 poolQuote, int256 dToken, int256 dQuote)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        (int256 delta,) = POOL_MANAGER.modifyLiquidity(key, _range(int256(liquidity)), "");
        (dToken, dQuote) = _split(delta, currency);
        // forge-lint: disable-next-line(unsafe-typecast)
        (poolTokens, poolQuote) = (uint256(-dToken), uint256(-dQuote));
        uint256 tokensIn = Math.mulDiv(BOND_SWAP_QUOTE_UNITS, den, num, Math.Rounding.Ceil);
        bool zeroForOne = key.currency0 == token;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 swapDelta = POOL_MANAGER.swap(key, IPoolManagerV4.SwapParams({ zeroForOne: zeroForOne, amountSpecified: -int256(tokensIn), sqrtPriceLimitX96: limit }), "");
        (int256 sToken, int256 sQuote) = _split(swapDelta, currency);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit BondSwapped(id, uint256(-sToken), uint256(sQuote));
        (dToken, dQuote) = (dToken + sToken, dQuote + sQuote);
    }

    function _collectLegPools() private returns (uint256 tokenFees) {
        address[] memory pools = bondPools();
        for (uint256 i = 0; i < pools.length; i++) {
            (uint256 tf, uint256 legFees) = _collect(pools[i]);
            tokenFees += tf;
            if (legFees == 0) continue;
            uint256 toOwner = legFees * PROTOCOL_SHARE_BPS / BPS;
            _bookToOwner(pools[i], toOwner);
            creatorPot[pools[i]] += legFees - toOwner;
            emit CreatorPotBooked(pools[i], legFees - toOwner);
        }
    }

    function _sharesPooled(uint256 real) private view returns (uint256) {
        return (real - real * SET_ASIDE_BPS / BPS) * (CURVE_CUT_ALL - usdgCutPct()) / CURVE_CUT_ALL;
    }

    function _twoPools() private view returns (bool) {
        uint256 cut = usdgCutPct();
        return cut != 0 && cut != CURVE_CUT_ALL;
    }

    function _poolId(address currency) private view returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(poolKeyIn(currency)));
    }

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

    /// The V4 pool when registered, else the V3; a dynamic or unreadable fee counts 0, the strictest floor.
    function _registeredPool(address factory, address legToken) private view returns (bool v4, uint256 fee) {
        (bool ok, bytes memory ret) = factory.staticcall(abi.encodeWithSelector(MaidMarianEtfFactory.poolsOf.selector, legToken));
        if (!ok || ret.length < 128) return (false, 0);
        (, uint256 v3Fee, uint256 v4Fee, int256 v4TickSpacing) = abi.decode(ret, (uint256, uint256, uint256, int256));
        v4 = v4TickSpacing != 0;
        fee = v4 ? v4Fee : v3Fee;
        if (fee >= FEE_UNIT) fee = 0;
    }

    function _bond(uint256 q, uint256 real) private {
        bonded = true;
        (uint256 poolTokens, uint256 poolQuote) = _openPool(quote(), q, real - real * SET_ASIDE_BPS / BPS);
        _closeBond(poolTokens, poolQuote);
    }

    /// Only this curve can initialize it (`HOOK`), so the pool does not exist before.
    function _openPool(address currency, uint256 q, uint256 budget) private returns (uint256 poolTokens, uint256 poolQuote) {
        uint256 t = tokenReserve;
        if (budget < 2 || !curveFits(q, t)) revert BondDoesNotFit(q, t);
        POOL_MANAGER.initialize(poolKeyIn(currency), _sqrtPriceAt(q, t, currency));
        (poolTokens, poolQuote) = abi.decode(POOL_MANAGER.unlock(abi.encode(OP_SEED, currency, q, budget)), (uint256, uint256));
    }

    function _closeBond(uint256 poolTokens, uint256 poolQuote) private {
        MaidMarianToken launched = MaidMarianToken(token);
        uint256 burned = launched.balanceOf(address(this));
        launched.burn(burned);
        address paired = poolCurrency();
        uint256 setAside = IERC20(paired).balanceOf(address(this)) - creatorFees - protocolFees - ownerPot[paired];
        protocolFees += setAside;
        bondSetAside = setAside;
        emit Bonded(address(launched), poolId(), paired, setAside, poolTokens, poolQuote, burned);
    }

    function _collect(address currency) private returns (uint256 tokenFees, uint256 quoteFees) {
        (tokenFees, quoteFees) = abi.decode(POOL_MANAGER.unlock(abi.encode(OP_COLLECT, currency)), (uint256, uint256));
    }

    function _seed(IPoolManagerV4.PoolKey memory key, address currency, uint256 q, uint256 budget) private returns (uint256 poolTokens, uint256 poolQuote) {
        uint256 t = tokenReserve;
        uint256 held = IERC20(token).balanceOf(address(this));
        uint160 sqrtPrice = _sqrtPriceAt(q, t, currency);
        // One unit short of each, so the PoolManager's rounding up stays within it.
        uint256 liquidity = key.currency0 == token ? _liquidity(sqrtPrice, held - 1, budget - 1) : _liquidity(sqrtPrice, budget - 1, held - 1);
        if (liquidity == 0) revert BondDoesNotFit(q, t);
        int256 dToken;
        int256 dQuote;
        (poolTokens, poolQuote, dToken, dQuote) = _addAndSwap(key, _poolId(currency), currency, liquidity, q, t);
        _settle(token, dToken);
        _settle(currency, dQuote);
    }

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

    /// A V4 `BalanceDelta`: amount0 in the high 128 bits.
    function _split(int256 delta, address currency) private view returns (int256 dToken, int256 dQuote) {
        int256 a0 = delta >> 128;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 a1 = int256(int128(delta));
        (dToken, dQuote) = token < currency ? (a0, a1) : (a1, a0);
    }

    function _range(int256 liquidityDelta) private pure returns (IPoolManagerV4.ModifyLiquidityParams memory) {
        return IPoolManagerV4.ModifyLiquidityParams({ tickLower: POOL_TICK_LOWER, tickUpper: POOL_TICK_UPPER, liquidityDelta: liquidityDelta, salt: bytes32(0) });
    }

    function _liquidity(uint160 sqrtPrice, uint256 amount0, uint256 amount1) private pure returns (uint256) {
        uint256 lower = TickMath.getSqrtPriceAtTick(POOL_TICK_LOWER);
        uint256 upper = TickMath.getSqrtPriceAtTick(POOL_TICK_UPPER);
        uint256 l0 = Math.mulDiv(amount0, Math.mulDiv(sqrtPrice, upper, Q96), upper - sqrtPrice);
        uint256 l1 = Math.mulDiv(amount1, Q96, sqrtPrice - lower);
        return Math.min(l0, l1);
    }

    function _sqrtPriceAt(uint256 q, uint256 t, address currency) private view returns (uint160) {
        (uint256 a1, uint256 a0) = token < currency ? (q, t) : (t, q);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(Math.sqrt(Math.mulDiv(a1, 1 << 192, a0)));
    }

    function _arg(uint256 offset, uint256 len) private view returns (uint256 v) {
        assembly ("memory-safe") {
            extcodecopy(address(), 0, add(CLONE_CODE_BYTES, offset), 32)
            v := shr(sub(256, shl(3, len)), mload(0))
        }
    }
}
