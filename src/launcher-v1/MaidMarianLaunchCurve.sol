// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { StorageSlot } from "@openzeppelin/contracts/utils/StorageSlot.sol";
import { TickMath } from "./uniswap/TickMath.sol";
import { MaidMarianEtfV3 } from "./MaidMarianEtfV3.sol";
import { MaidMarianEtfFactory } from "./MaidMarianEtfFactory.sol";
import { MaidMarianToken } from "./MaidMarianToken.sol";

/// The curve's shape, the same for every supply: 5/7 of it sold, 2/7 left at the end.
function curveReserved(uint256 supply) pure returns (uint256) {
    return (2 * supply) / 7;
}

uint256 constant CURVE_BPS = 10_000;

/// A buy of `quoteIn` on the reserves `(q, t)`: x * y = k on the quote reserve `q` (phantom plus real)
/// and the token reserve `t`, rounded for the curve. Fee and tax come off `quoteIn` first, outside k.
/// A buy that would take the curve past `reserved` is cut to land on it exactly: `used` is what
/// it pays, the rest of `quoteIn` is refunded. `net` is what enters `q`.
function curveBuy(uint256 q, uint256 t, uint256 quoteIn, uint256 feeBps, uint256 taxBps, uint256 reserved) pure returns (uint256 tokensOut, uint256 used, uint256 fee, uint256 tax, uint256 net) {
    fee = quoteIn * feeBps / CURVE_BPS;
    tax = quoteIn * taxBps / CURVE_BPS;
    net = quoteIn - fee - tax;
    tokensOut = t - Math.ceilDiv(q * t, q + net);
    used = quoteIn;
    if (t - tokensOut <= reserved) {
        uint256 needed = Math.ceilDiv(q * t, reserved) - q;
        used = Math.min(Math.ceilDiv(needed * CURVE_BPS, CURVE_BPS - feeBps - taxBps), quoteIn);
        fee = used * feeBps / CURVE_BPS;
        tax = used * taxBps / CURVE_BPS;
        net = used - fee - tax;
        tokensOut = t - reserved;
    }
}

/// A sale of `tokensIn` on `(q, t)`: `gross` leaves `q`; fee and tax come off it, the seller gets the rest.
function curveSell(uint256 q, uint256 t, uint256 tokensIn, uint256 feeBps, uint256 taxBps) pure returns (uint256 gross, uint256 fee, uint256 tax) {
    gross = q - Math.ceilDiv(q * t, t + tokensIn);
    fee = gross * feeBps / CURVE_BPS;
    tax = gross * taxBps / CURVE_BPS;
}

// The clone's arguments, packed: quote (20 bytes), ETF quote flag (1), creator tax in bps (2), threshold
// (16), creator (20), token (20), supply in raw units (12).
uint256 constant CURVE_ARGS_ETF = 20;
uint256 constant CURVE_ARGS_TAX = 21;
uint256 constant CURVE_ARGS_THRESHOLD = 23;
uint256 constant CURVE_ARGS_CREATOR = 39;
uint256 constant CURVE_ARGS_TOKEN = 59;
uint256 constant CURVE_ARGS_SUPPLY = 79;

function curveCloneArgs(address quote, bool etfQuote, uint16 creatorTaxBps, uint128 threshold, address creator, address token, uint96 supply) pure returns (bytes memory) {
    return abi.encodePacked(quote, etfQuote, creatorTaxBps, threshold, creator, token, supply);
}

/// What a curve reads from its factory.
interface IMaidMarianTokenLauncherReads {
    function owner() external view returns (address);
    function setAsideRecipient() external view returns (address);
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
 *  - `buy`: pay in the quote token (ETF shares or the plain token).
 *  - `buyWithUsdg`: ETF quote only; the curve mints the shares itself with the caller's routes.
 *  - `sell`: the token approved to the curve; paid in the quote token, or for an ETF quote redeemed by
 *    the curve, in kind or to USDG.
 * Fees, on the quote side, outside k: 0.75 % each way, 70 % creator / 30 % protocol (the factory's
 * owner), plus the creator's tax (0 - 10 % each way, all his), plus a snipe tax on buys in the first
 * 3 s (99 %, 6.18 %, 0.19 %), split as the fee; the creator and the addresses he named at launch are
 * exempt from it (`isSnipeExempt`), not from the fee or his tax. The buyer is the caller, or, on
 * `buyFor` / `buyWithUsdgFor`, the address the factory names: the factory alone may name one, the
 * caller of its own doors, which pay and are paid as any caller. Fees are kept in the curve and
 * claimed (`claim`), as the quote token or, for an ETF quote, by the curve's own redeem.
 * Bond: the buy that brings the real quote to the threshold opens a Uniswap V4 pool (1 %, full range)
 * at the curve's last price with 70 % of it, 30 % to the owner's recipient, every token not in the
 * pool burned, the position owned by this contract with no way to remove it. The pool's hook (`HOOK`)
 * lets only this curve initialize it, so no one can open it first, at any price.
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

    /// Part of the real quote sent to the owner's recipient at the bond: 30 %.
    uint256 public constant SET_ASIDE_BPS = 3000;

    /// The pool: 1 %, the tick spacing Uniswap pairs with 1 %, full range.
    uint24 public constant POOL_FEE = 10_000;
    int24 public constant POOL_TICK_SPACING = 200;
    int24 public constant POOL_TICK_LOWER = -887_200;
    int24 public constant POOL_TICK_UPPER = 887_200;

    /// How a sale or a claim is paid. `PAY_QUOTE`: the quote token itself; for an ETF quote also
    /// `PAY_IN_KIND` (`redeemInKind`) and `PAY_USDG` (`redeem` with the caller's routes).
    uint8 public constant PAY_QUOTE = 0;
    uint8 public constant PAY_IN_KIND = 1;
    uint8 public constant PAY_USDG = 2;

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

    // ---------------------------------------------------------------- state ---

    /// The curve's quote reserve, phantom included, and its token reserve.
    uint256 public quoteReserve;
    uint256 public tokenReserve;

    /// Fees kept in the curve, in quote units, until claimed.
    uint256 public creatorFees;
    uint256 public protocolFees;

    /// ETF shares of the set-aside the bond could not redeem without a penalty; released after the hold.
    uint256 public setAsideDue;

    uint64 public launchedAt;
    bool public bonded;
    bool private _initialized;

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
    /// `setAside`: the quote sent (or kept as `setAsideDue`) for the owner's recipient.
    event Bonded(address indexed token, bytes32 indexed poolId, uint256 setAside, uint256 poolTokens, uint256 poolQuote, uint256 burned);
    event SetAsideReleased(address indexed to, uint256 shares);
    event FeesClaimed(address indexed by, address indexed to, bool protocol, uint256 amount, uint8 payout);
    event PoolFeesCollected(uint256 tokenFees, uint256 quoteFees);

    // --------------------------------------------------------------- errors ---

    error ZeroAddress();
    error NotFactory();
    error AlreadyInitialized();
    error NotAClone();
    error AlreadyBonded();
    error NotBonded();
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

    // ---------------------------------------------------------- constructor ---

    /// The implementation, deployed by the factory (`FACTORY = msg.sender`). Locked: never initialized.
    constructor(IERC20 usdg, IPoolManagerV4 poolManager, address hook) {
        if (address(usdg) == address(0) || address(poolManager) == address(0) || hook == address(0)) revert ZeroAddress();
        FACTORY = IMaidMarianTokenLauncherReads(msg.sender);
        USDG = usdg;
        POOL_MANAGER = poolManager;
        HOOK = hook;
        SELF = address(this);
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

    /// @notice Buy with `quoteIn` of the quote token (approved to this contract). A last buy past the
    /// curve's end pays only what it needs, the rest refunded, and bonds.
    function buy(uint256 quoteIn, uint256 minTokensOut) external onlyClone nonReentrant returns (uint256 tokensOut) {
        return _buyInQuote(msg.sender, quoteIn, minTokensOut);
    }

    /// @notice `buy` by the factory for `buyer`, the caller of its own door: the snipe tax and `Bought`
    /// are `buyer`'s, the payment, tokens and refund the factory's. `NotFactory` for any other caller.
    function buyFor(address buyer, uint256 quoteIn, uint256 minTokensOut) external onlyClone nonReentrant returns (uint256 tokensOut) {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        return _buyInQuote(buyer, quoteIn, minTokensOut);
    }

    /// @notice ETF quote: pay `usdgIn` USDG (approved to this contract); the curve mints the ETF's shares
    /// with `routes` and `minShares` (as the ETF's `mint`) and buys with them. What the mint refunds is
    /// passed on; a last buy's excess shares are redeemed in kind to the caller.
    function buyWithUsdg(uint256 usdgIn, MaidMarianEtfV3.Route[] calldata routes, uint256 minShares, uint256 minTokensOut) external onlyClone nonReentrant returns (uint256 tokensOut) {
        return _buyInUsdg(msg.sender, usdgIn, routes, minShares, minTokensOut);
    }

    /// @notice `buyWithUsdg` by the factory for `buyer`, as `buyFor`.
    function buyWithUsdgFor(address buyer, uint256 usdgIn, MaidMarianEtfV3.Route[] calldata routes, uint256 minShares, uint256 minTokensOut)
        external
        onlyClone
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        return _buyInUsdg(buyer, usdgIn, routes, minShares, minTokensOut);
    }

    /// @notice Sell `tokensIn`, paid `PAY_QUOTE`, or for an ETF quote `PAY_IN_KIND` / `PAY_USDG` by the
    /// curve's own redeem (`routes`, `minUsdgOut` as the ETF's `redeem`). `minQuoteOut` bounds the quote
    /// paid out, before any redeem. A redeem is never beyond the curve's `mintOf` (`NotCovered`).
    /// No approve: the token lets this curve take the caller's tokens for his own sale (`takeForSale`).
    function sell(uint256 tokensIn, uint256 minQuoteOut, uint8 payout, MaidMarianEtfV3.Route[] calldata routes, uint256 minUsdgOut) external onlyClone nonReentrant returns (uint256 quoteOut) {
        if (bonded) revert AlreadyBonded();
        if (tokensIn == 0) revert NothingIn();
        (uint256 q, uint256 t) = (quoteReserve, tokenReserve);
        (uint256 gross, uint256 fee, uint256 tax) = curveSell(q, t, tokensIn, FEE_BPS, creatorTaxBps());
        quoteOut = gross - fee - tax;
        if (quoteOut < minQuoteOut) revert TooLittleQuote(quoteOut, minQuoteOut);
        (quoteReserve, tokenReserve) = (q - gross, t + tokensIn);
        _takeFees(fee, tax);
        MaidMarianToken(token()).takeForSale(msg.sender, tokensIn);
        _payOut(quoteOut, msg.sender, payout, routes, minUsdgOut, true);
        emit Sold(msg.sender, tokensIn, quoteOut, payout, fee, tax, q - gross, t + tokensIn);
    }

    /// @notice Claim `amount` of the creator's fees (`protocol` false, the creator only) or of the
    /// protocol's (`protocol` true, the factory's owner only) to `to`. An ETF quote's redeem
    /// (`PAY_IN_KIND`, `PAY_USDG`) never runs while the ETF's hold period on the curve's last mint runs;
    /// its shares (`PAY_QUOTE`) are paid only when the ETF has no non-minter penalty.
    function claim(bool protocol, uint256 amount, address to, uint8 payout, MaidMarianEtfV3.Route[] calldata routes, uint256 minUsdgOut) external onlyClone nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 available;
        if (protocol) {
            if (msg.sender != FACTORY.owner()) revert NotOwner();
            available = protocolFees;
            if (amount > available) revert TooMuch(amount, available);
            protocolFees = available - amount;
        } else {
            if (msg.sender != creator()) revert NotCreator();
            available = creatorFees;
            if (amount > available) revert TooMuch(amount, available);
            creatorFees = available - amount;
        }
        if (amount == 0) revert NothingIn();
        if (etfQuote() && payout != PAY_QUOTE) _requireNoHold();
        _payOut(amount, to, payout, routes, minUsdgOut, false);
        emit FeesClaimed(msg.sender, to, protocol, amount, payout);
    }

    /// @notice After a bond whose set-aside fell inside the ETF's hold period: redeem it in kind to the
    /// owner's recipient once the hold has ended. Anyone.
    function releaseSetAside() external onlyClone nonReentrant {
        uint256 shares = setAsideDue;
        if (shares == 0) revert NothingIn();
        _requireNoHold();
        setAsideDue = 0;
        address to = FACTORY.setAsideRecipient();
        _sendSetAside(MaidMarianEtfV3(quote()), shares, to);
        emit SetAsideReleased(to, shares);
    }

    /// @notice After the bond: collect the pool position's fees, the tokens' 70 % to the creator and 30 %
    /// to the factory's owner, the quote's into `creatorFees` / `protocolFees`. Anyone.
    function collectPoolFees() external onlyClone nonReentrant returns (uint256 tokenFees, uint256 quoteFees) {
        if (!bonded) revert NotBonded();
        (tokenFees, quoteFees) = abi.decode(POOL_MANAGER.unlock(abi.encode(OP_COLLECT)), (uint256, uint256));
        if (tokenFees > 0) {
            uint256 toProtocol = tokenFees * PROTOCOL_SHARE_BPS / BPS;
            IERC20(token()).safeTransfer(FACTORY.owner(), toProtocol);
            IERC20(token()).safeTransfer(creator(), tokenFees - toProtocol);
        }
        if (quoteFees > 0) _takeFees(quoteFees, 0);
        emit PoolFeesCollected(tokenFees, quoteFees);
    }

    /// @notice The PoolManager's callback, for the bond's seeding and the fee collection only.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        IPoolManagerV4.PoolKey memory key = poolKey();
        if (abi.decode(data, (uint8)) == OP_SEED) {
            (uint256 poolTokens, uint256 poolQuote) = _seed(key);
            return abi.encode(poolTokens, poolQuote);
        }
        (int256 delta,) = POOL_MANAGER.modifyLiquidity(key, _range(0), "");
        (int256 dToken, int256 dQuote) = _split(delta);
        // Fees only: both deltas are owed to the curve.
        // forge-lint: disable-next-line(unsafe-typecast)
        (uint256 tokenFees, uint256 quoteFees) = (uint256(dToken), uint256(dQuote));
        if (tokenFees > 0) POOL_MANAGER.take(token(), address(this), tokenFees);
        if (quoteFees > 0) POOL_MANAGER.take(quote(), address(this), quoteFees);
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

    /// What `buy(quoteIn)` by `buyer` would do now: tokens out, quote used (the rest refunded), fee
    /// (snipe tax in) and tax. Zeros once bonded.
    function previewBuy(uint256 quoteIn, address buyer) external view returns (uint256 tokensOut, uint256 used, uint256 fee, uint256 tax) {
        if (bonded || quoteIn == 0) return (0, 0, 0, 0);
        (tokensOut, used, fee, tax,) = curveBuy(quoteReserve, tokenReserve, quoteIn, _feeBps(buyer), creatorTaxBps(), reserved());
    }

    /// What `sell(tokensIn)` would pay now in quote units, and its fee and tax. Zeros once bonded or
    /// for more than was ever sold.
    function previewSell(uint256 tokensIn) external view returns (uint256 quoteOut, uint256 fee, uint256 tax) {
        if (bonded || tokensIn == 0 || tokenReserve + tokensIn > supply()) return (0, 0, 0);
        uint256 gross;
        (gross, fee, tax) = curveSell(quoteReserve, tokenReserve, tokensIn, FEE_BPS, creatorTaxBps());
        quoteOut = gross - fee - tax;
    }

    /// The bond's pool: the token and the quote, sorted, 1 %, spacing 200, `HOOK`.
    function poolKey() public view returns (IPoolManagerV4.PoolKey memory key) {
        (address t, address q) = (token(), quote());
        (address c0, address c1) = t < q ? (t, q) : (q, t);
        key = IPoolManagerV4.PoolKey({ currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: POOL_TICK_SPACING, hooks: HOOK });
    }

    function poolId() public view returns (bytes32) {
        // A few reads per bond: plain `keccak256` for readability.
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(poolKey()));
    }

    /// The token's PNG logo, stored by the factory; empty if none.
    function logo() external view returns (bytes memory) {
        return FACTORY.logo(address(this));
    }

    // ------------------------------------------------------------- internal ---

    /// `buy` for `buyer`, paid and paid back by the caller.
    function _buyInQuote(address buyer, uint256 quoteIn, uint256 minTokensOut) private returns (uint256 tokensOut) {
        if (quoteIn == 0) revert NothingIn();
        IERC20(quote()).safeTransferFrom(msg.sender, address(this), quoteIn);
        uint256 refund;
        (tokensOut, refund) = _buy(buyer, quoteIn, 0, minTokensOut);
        if (refund > 0) IERC20(quote()).safeTransfer(msg.sender, refund);
        _bondIfDue();
    }

    /// `buyWithUsdg` for `buyer`, paid and paid back by the caller.
    function _buyInUsdg(address buyer, uint256 usdgIn, MaidMarianEtfV3.Route[] calldata routes, uint256 minShares, uint256 minTokensOut) private returns (uint256 tokensOut) {
        if (!etfQuote()) revert NotEtfQuote();
        if (usdgIn == 0) revert NothingIn();
        MaidMarianEtfV3 etf = MaidMarianEtfV3(quote());
        USDG.safeTransferFrom(msg.sender, address(this), usdgIn);
        USDG.forceApprove(address(etf), usdgIn);
        uint256 shares = etf.mint(usdgIn, routes, minShares);
        _passOnMintRefunds(etf);
        uint256 refund;
        (tokensOut, refund) = _buy(buyer, shares, usdgIn, minTokensOut);
        if (refund > 0) etf.redeemInKind(refund, msg.sender, 0);
        _bondIfDue();
    }

    /// The curve step of both buys: `quoteIn` is already in the contract, the snipe tax is `buyer`'s, the
    /// tokens go to the caller. Returns the tokens and the refund.
    function _buy(address buyer, uint256 quoteIn, uint256 usdgIn, uint256 minTokensOut) private returns (uint256 tokensOut, uint256 refund) {
        if (bonded) revert AlreadyBonded();
        (uint256 q, uint256 t) = (quoteReserve, tokenReserve);
        (uint256 out, uint256 used, uint256 fee, uint256 tax, uint256 net) = curveBuy(q, t, quoteIn, _feeBps(buyer), creatorTaxBps(), reserved());
        if (out == 0 || out < minTokensOut) revert TooFewTokens(out, minTokensOut);
        (quoteReserve, tokenReserve) = (q + net, t - out);
        _takeFees(fee, tax);
        IERC20(token()).safeTransfer(msg.sender, out);
        emit Bought(buyer, used, usdgIn, out, fee, tax, q + net, t - out);
        return (out, quoteIn - used);
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

    /// Every leg and USDG the curve holds after a mint is what the mint refunded: passed on to the buyer.
    /// The legs are read on the ETF's own factory, fixed for that ETF.
    function _passOnMintRefunds(MaidMarianEtfV3 etf) private {
        MaidMarianEtfFactory.LegSpec[] memory legs = MaidMarianEtfFactory(address(etf.FACTORY())).legsOf(address(etf));
        for (uint256 i = 0; i < legs.length; i++) {
            IERC20 leg = IERC20(legs[i].token);
            uint256 left = leg.balanceOf(address(this));
            if (left > 0) leg.safeTransfer(msg.sender, left);
        }
        uint256 usdgLeft = USDG.balanceOf(address(this));
        if (usdgLeft > 0) USDG.safeTransfer(msg.sender, usdgLeft);
    }

    /// Pays `amount` of quote to `to`: as the quote token, or for an ETF quote by the curve's redeem, in
    /// kind or to USDG. On an ETF with a non-minter penalty, shares go to a seller only (`asShares`) and
    /// a redeem stays within the curve's `mintOf`, so the curve never pays that penalty.
    function _payOut(uint256 amount, address to, uint8 payout, MaidMarianEtfV3.Route[] calldata routes, uint256 minUsdgOut, bool asShares) private {
        bool free = !etfQuote() || MaidMarianEtfV3(quote()).NON_MINTER_PENALTY_BPS() == 0;
        if (payout == PAY_QUOTE && (asShares || free)) {
            IERC20(quote()).safeTransfer(to, amount);
            return;
        }
        if (!etfQuote() || (payout != PAY_IN_KIND && payout != PAY_USDG)) revert BadPayout(payout);
        MaidMarianEtfV3 etf = MaidMarianEtfV3(quote());
        if (!free) {
            uint256 covered = etf.mintOf(address(this));
            if (amount > covered) revert NotCovered(amount, covered);
        }
        if (payout == PAY_IN_KIND) etf.redeemInKind(amount, to, 0);
        else etf.redeem(amount, routes, minUsdgOut, to);
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

    /// The set-aside in kind to `to`; on an ETF with a non-minter penalty only within the curve's
    /// `mintOf`, any beyond it as shares. A leg that cannot be paid stays in the ETF (`allowFail` on
    /// every bit), so the bond never reverts on it.
    function _sendSetAside(MaidMarianEtfV3 etf, uint256 shares, address to) private {
        uint256 covered = etf.NON_MINTER_PENALTY_BPS() == 0 ? shares : Math.min(shares, etf.mintOf(address(this)));
        if (covered > 0) etf.redeemInKind(covered, to, type(uint16).max);
        if (shares > covered) IERC20(address(etf)).safeTransfer(to, shares - covered);
    }

    function _bondIfDue() private {
        if (realQuote() >= threshold() || tokenReserve == reserved()) _bond();
    }

    /// Opens the pool at the curve's last price with 70 % of the real quote, sends 30 % (and any dust)
    /// to the owner's recipient, burns every token left. The pool does not exist before: `HOOK` lets
    /// only this curve initialize it, and this is the curve's one call to `initialize`.
    function _bond() private {
        bonded = true;
        POOL_MANAGER.initialize(poolKey(), _sqrtPriceAt(quoteReserve, tokenReserve));
        (uint256 poolTokens, uint256 poolQuote) = abi.decode(POOL_MANAGER.unlock(abi.encode(OP_SEED)), (uint256, uint256));
        MaidMarianToken launched = MaidMarianToken(token());
        uint256 burned = launched.balanceOf(address(this));
        launched.burn(burned);

        IERC20 quoteToken = IERC20(quote());
        uint256 setAside = quoteToken.balanceOf(address(this)) - creatorFees - protocolFees;
        address to = FACTORY.setAsideRecipient();
        if (etfQuote()) {
            MaidMarianEtfV3 etf = MaidMarianEtfV3(address(quoteToken));
            if (_holdEndsAt(etf) > block.timestamp) setAsideDue = setAside;
            else _sendSetAside(etf, setAside, to);
        } else if (!quoteToken.trySafeTransfer(to, setAside)) {
            protocolFees += setAside;
        }
        emit Bonded(address(launched), poolId(), setAside, poolTokens, poolQuote, burned);
    }

    /// Inside the unlock: adds the full-range position to the pool just initialized at the curve's
    /// price, and settles.
    function _seed(IPoolManagerV4.PoolKey memory key) private returns (uint256 poolTokens, uint256 poolQuote) {
        (uint256 q, uint256 t) = (quoteReserve, tokenReserve);
        uint256 real = q - phantomQuote();
        uint256 budget = real - real * SET_ASIDE_BPS / BPS;
        uint160 sqrtPrice = _sqrtPriceAt(q, t);
        // What the position may take, one unit short of each so the PoolManager's rounding up stays within it.
        uint256 liquidity = key.currency0 == token() ? _liquidity(sqrtPrice, t - 1, budget - 1) : _liquidity(sqrtPrice, budget - 1, t - 1);
        // forge-lint: disable-next-line(unsafe-typecast)
        (int256 delta,) = POOL_MANAGER.modifyLiquidity(key, _range(int256(liquidity)), "");
        (int256 dToken, int256 dQuote) = _split(delta);
        // forge-lint: disable-next-line(unsafe-typecast)
        (poolTokens, poolQuote) = (uint256(-dToken), uint256(-dQuote));
        _settle(token(), dToken);
        _settle(quote(), dQuote);
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

    /// A V4 `BalanceDelta` as (the token's, the quote's): amount0 in the high 128 bits, amount1 in the low.
    function _split(int256 delta) private view returns (int256 dToken, int256 dQuote) {
        int256 a0 = delta >> 128;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 a1 = int256(int128(delta));
        (dToken, dQuote) = token() < quote() ? (a0, a1) : (a1, a0);
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

    /// `sqrtPriceX96` of the price `q` quote per `t` tokens, as currency1 per currency0. The factory's
    /// threshold bounds keep the ratio under 2^64, so `ratio x 2^192` fits.
    function _sqrtPriceAt(uint256 q, uint256 t) private view returns (uint160) {
        (uint256 a1, uint256 a0) = token() < quote() ? (q, t) : (t, q);
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
