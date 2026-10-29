// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { MaidMarianBagPoolOracle, IUniswapV3PoolSlot0 } from "./MaidMarianBagPoolOracle.sol";
import { MaidMarianEtfFactory } from "./MaidMarianEtfFactory.sol";
import { MaidMarianEtfV3 } from "./MaidMarianEtfV3.sol";
import { MaidMarianLaunchCurve, IPoolManagerV4, curveCloneArgs, routesAtDue, CURVE_PAY_IN_KIND, CURVE_PAY_USDG, CURVE_CUT_STEP, CURVE_CUT_ALL } from "./MaidMarianLaunchCurve.sol";
import { MaidMarianLaunchHook, HOOK_BEFORE_INITIALIZE_FLAG, HOOK_ALL_FLAGS_MASK } from "./MaidMarianLaunchHook.sol";
import { MaidMarianToken, tokenCloneArgs } from "./MaidMarianToken.sol";
import { TickMath } from "./uniswap/TickMath.sol";
import { checkTokenName, checkTokenSymbol, checkProfileFields, checkPngLogo, storeLogoAsCode, readLogoCode, BadLogo, BadName, BadSymbol } from "./MaidMarianTokenChecks.sol";

/// Wrapped ether: the calls the launcher makes.
interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * @title Maid Marian token launcher
 * @notice Anyone launches a token on its bonding curve, two ways:
 *  - `launchWithToken` (`launchFee()`): quoted in a token the owner lists with its pool
 *    against USDG (`setTokenQuote`), bonding at the threshold the caller picks from the list the owner
 *    set for it (`quoteThresholds`), with the caller's first buy of at least the minimum the owner set
 *    for that quote;
 *  - `launchWithEtf` (the ETF factory's `creationFee()` only): creates the token's reserve ETF, named
 *    after it, with fixed terms, quotes the curve in its shares (bonding at the threshold the caller picks
 *    from `etfThresholds()`), and makes the caller's USDG (`MIN_ETF_SEED_WHOLE_USDG` at least) his first
 *    buy on it, which is the ETF's first mint.
 * Both first buys are one curve buy from the base price, the creator exempt from the snipe tax.
 * On a WETH curve, `buy` and `launchWithToken`'s first buy may be paid in ether (wrapped here), and
 * `sellForEth` / `claimInEth` pay in ether (unwrapped here).
 * A reserve ETF's shares are its curve's alone, and no door of this launcher leaves one with a user or
 * a fee receiver: the curve mints, holds and redeems them (buys in USDG, sales and fee claims in kind
 * or to USDG), and the reserve ETF's fee recipient is the curve, this launcher its creator for good.
 * The creator of an ETF curve chooses at launch, for good, its USDG cut (`usdgCutPct`): the percent of
 * the bond's pooled quote redeemed to USDG with the last buyer's routes and paired with USDG, 0, 25, 50,
 * 75 or 100, the rest paired with the reserve ETF's shares; both pools open at the same price.
 * `buyAfterBond` and `sellAfterBond` trade a bonded ETF curve's token for USDG in the pool the caller
 * names: against USDG directly in the USDG pool, or through the ETF's own mint and redeem in the shares
 * pool, holding the shares only inside the call. A trade in a shares pool made elsewhere may leave
 * shares with its trader.
 * No door hands a user a leg or USDG he did not ask for: a buy pays the tokens alone (the mint's
 * refunds, the rounding of the buyer's routes, go to the owner), a payout to USDG sells every routed
 * leg whole; in kind only on the in-kind payout and a leg routed at 0. A refund the owner's address
 * refuses (frozen on USDG, blocklisted on a leg) is kept for him (`ownerPot`, `claimOwnerPot`), so it
 * never stops a buy. A last buy is bought whole, past
 * the curve's end: no change, no cut.
 * Each token has a name, a symbol, a PNG logo stored as code and a profile (description, X, Telegram,
 * website) on the ETF factory's allowlists, edited by its creator (`setProfile`, which edits its reserve
 * ETF's too).
 * One approve for every curve: `buy` and `buyWithUsdg` pull the caller's quote (or USDG) here and buy on
 * the curve for him; `buy` is a plain quote's, `buyWithUsdg` an ETF quote's. They spend the caller's
 * allowance only (no `from` anywhere), approve the curve exactly what it pulls, and the curve pays the
 * caller the tokens itself, so nothing of the call stays here. The curve is told the caller is the buyer
 * (`buyFor`, `buyWithUsdgFor`, this launcher's alone), so the snipe tax, its exemptions and the curve's
 * `Bought` are his, as on a direct buy.
 * At launch the creator names up to `MaidMarianLaunchCurve.MAX_SNIPE_EXEMPTIONS` addresses exempted with
 * him from the snipe tax, kept by the curve for good.
 * The owner lists quotes, sets the launch fee, withdraws the launch fees, and claims the protocol's part
 * of every curve's fees and the 30 % each bond books to it. He has nothing over a curve's reserve.
 * Ownership is never renounced.
 * A launch makes two EIP-1167 clones, created and initialized in its transaction: the token, a plain
 * ERC-20 (`TOKEN_IMPLEMENTATION`, its name and symbol appended to its code), and its curve
 * (`CURVE_IMPLEMENTATION`, its terms appended), which holds the whole supply. Each curve keeps the
 * threshold it was launched with, whatever the lists become. Every curve's bond pool carries `HOOK`, deployed by the constructor,
 * which lets only that curve initialize it.
 */
contract MaidMarianTokenLauncher is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------ constants ---

    uint256 public constant INITIAL_LAUNCH_FEE = 0.0005 ether;

    /// `etfThresholds()` at deploy: 8 000 shares alone, whatever they are worth.
    uint128 public constant INITIAL_ETF_THRESHOLD = 8000e18;

    /// Every threshold's bounds, in its quote's raw units (1e9 is 1 000 USDG, 1e33 a quadrillion of an
    /// 18-decimal token): every reserve from the launch to the curve's end passes `curveFits` in the quote,
    /// whatever its decimals and the supply (at the launch the phantom 0.4e9 against at most 1e27 >> 64 =
    /// 5.4e7; at the end 1.4e33 against at least 2/7 of 1e24, a ratio near 2^32).
    uint128 public constant MIN_THRESHOLD = 1e9;
    uint128 public constant MAX_THRESHOLD = 1e33;

    /// An ETF threshold's floor: 100 shares. A bond to USDG opens its pool at the curve's end quote in
    /// USDG, 1.4 x threshold x the USDG a share redeems to, which `curveFits` wants above the tokens left
    /// >> 64 (2/7 of 1e27 >> 64, 15.5 USDG at the largest supply): at 100 shares it fits while a share
    /// redeems to 0.111 USDG or more, a share seeded at 1 USDG. Under that, only a last buy past the
    /// curve's end by enough to reach 15.5 USDG of quote bonds (`BondDoesNotFit` before it).
    uint128 public constant MIN_ETF_THRESHOLD = 100e18;

    /// The most thresholds a quote's list or the ETF list holds: a launch looks its threshold up in at
    /// most 4 storage words (two per word), and a site shows them as one row of choices.
    uint256 public constant MAX_THRESHOLD_CHOICES = 8;

    uint256 public constant MAX_CREATOR_TAX_BPS = 1000;

    /// A launch's logo, at most 10 KiB (a logo costs about 290 gas a byte, calldata included). With a
    /// full profile: `launchWithToken` with its first buy about 3.6 M gas; `launchWithEtf` with its seed
    /// buy about 5.2 M on three legs, 6.3 M on ten; a full snipe exemption list brings it to about 6.7 M,
    /// plus the chain's L1 part (0 to ~0.23 M), near the ~7 M a wallet simulates.
    uint256 public constant MAX_LOGO_BYTES = 10_240;

    /// The least first buy of `launchWithEtf`, in whole USDG. The whole seed is the reserve ETF's first
    /// mint, so a share starts at 1 USDG and nobody else sets its first price.
    uint256 public constant MIN_ETF_SEED_WHOLE_USDG = 10;

    /// The reserve ETF is named the token's name and `ETF_NAME_SUFFIX`, its symbol `ETF_SYMBOL_PREFIX` and
    /// the token's: the ETF factory's 64 and 11 bytes leave the token 60 and 8 on that path.
    string public constant ETF_NAME_SUFFIX = " ETF";
    string public constant ETF_SYMBOL_PREFIX = "etf";
    uint256 public constant MAX_NAME_WITH_ETF_BYTES = 60;
    uint256 public constant MAX_SYMBOL_WITH_ETF_BYTES = 8;

    /// The supplies a launch chooses from, in whole tokens of 18 decimals (`isSupply`).
    uint256 public constant SUPPLY_1M = 1_000_000;
    uint256 public constant SUPPLY_10M = 10_000_000;
    uint256 public constant SUPPLY_100M = 100_000_000;
    uint256 public constant SUPPLY_500M = 500_000_000;
    uint256 public constant SUPPLY_1B = 1_000_000_000;

    // ---------------------------------------------------------------- types ---

    /// A quote ever listed: the V3 pool read at its listing (0 for USDG); `minFirstBuy` the least first buy
    /// of a launch on it. Listed while its thresholds' list is not empty.
    struct QuoteInfo {
        address pool;
        bool known;
        uint128 minFirstBuy;
    }

    struct CurveInfo {
        address creator;
        address quote;
        address token;
        address logoPointer;
        uint64 createdAt;
    }

    /// A launch's terms, in its clone's arguments; `supply` in raw units; `usdgCutPct` an ETF curve's USDG
    /// cut (0, 25, 50, 75, 100), 0 for a plain quote.
    struct Terms {
        address quote;
        bool etfQuote;
        uint128 threshold;
        uint16 creatorTaxBps;
        uint96 supply;
        uint8 usdgCutPct;
    }

    // ----------------------------------------------------------- immutables ---

    IERC20 public immutable USDG;
    IPoolManagerV4 public immutable POOL_MANAGER;
    address public immutable UNISWAP_V3_FACTORY;
    MaidMarianBagPoolOracle public immutable POOL_ORACLE;

    /// Wrapped ether: the quote whose curves also trade in ether through this launcher.
    IWrappedNative public immutable WETH;

    /// Scales a raw USDG amount to 18 decimals.
    uint256 private immutable USDG_UNIT_TO_18;

    /// `MIN_ETF_SEED_WHOLE_USDG` in USDG's raw units.
    uint256 public immutable MIN_ETF_SEED_USDG;

    /// What every curve and every token clone, deployed by the constructor; locked.
    MaidMarianLaunchCurve public immutable CURVE_IMPLEMENTATION;
    MaidMarianToken public immutable TOKEN_IMPLEMENTATION;

    /// The bond pools' hook, deployed by the constructor.
    MaidMarianLaunchHook public immutable HOOK;

    // ---------------------------------------------------------------- state ---

    /// The ETF factory `launchWithEtf` creates reserve ETFs on and `setTokenQuote` asks `isEtf`
    /// (`setEtfFactory`). A launched curve never reads it: its ETF keeps its own factory.
    MaidMarianEtfFactory public etfFactory;

    /// Every factory `etfFactory` has been, in order, once each: `setTokenQuote` asks each `isEtf`.
    /// Unbounded: only the owner appends, one per `setEtfFactory`, and only his `setTokenQuote` loops.
    address[] private _etfFactories;
    mapping(address factory => bool) private _etfFactoryUsed;

    /// What `launchWithToken` must be sent, exactly, beside a first buy paid in ether.
    uint256 public launchFee;

    /// The real quotes, in shares, a curve launched by `launchWithEtf` from now on may bond at, increasing.
    uint128[] private _etfThresholds;

    address[] public quoteList;
    mapping(address token => QuoteInfo) private _quotes;
    /// Each quote's thresholds, its raw units, increasing; empty when not listed.
    mapping(address token => uint128[]) private _quoteThresholds;

    /// What a refund sweep could not send the owner, per asset, kept here for him (`claimOwnerPot`).
    mapping(address asset => uint256) public ownerPot;

    address[] public curves;
    mapping(address curve => CurveInfo) private _curves;
    mapping(address curve => MaidMarianEtfFactory.Profile) private _profiles;
    mapping(address curve => uint256) private _profileUpdatedAt;

    /// Set by `_swapInPool` around its `unlock`: the PoolManager's callback is served only then.
    bool private transient _swapping;

    // --------------------------------------------------------------- events ---

    /// Everything needed to list a curve without reading it.
    event CurveLaunched(
        address indexed curve, address indexed creator, address indexed quote, address token, uint256 index, Terms terms, string name, string symbol, bytes logo, MaidMarianEtfFactory.Profile profile
    );
    event ProfileSet(address indexed curve, address indexed creator, string description, string x, string telegram, string website);
    /// `thresholds` empty: delisted.
    event QuoteSet(address indexed token, address pool, uint256[] thresholds, uint256 minFirstBuy);
    event EtfThresholdsSet(uint256[] thresholds);
    /// A refund the owner's address refused, kept for him; and its claim.
    event OwnerPotBooked(address indexed asset, uint256 amount);
    event OwnerPotClaimed(address indexed asset, address indexed to, uint256 amount);
    event LaunchFeeChanged(uint256 previous, uint256 next);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event EtfFactoryChanged(address previous, address next);
    /// A trade in a bonded ETF curve's pool through `buyAfterBond` / `sellAfterBond`; `shares` the reserve
    /// ETF's shares minted and swapped in, or swapped out and redeemed, 0 in a USDG pool.
    event BoughtAfterBond(address indexed curve, address indexed buyer, uint256 usdgIn, uint256 shares, uint256 tokensOut);
    event SoldAfterBond(address indexed curve, address indexed seller, uint256 tokensIn, uint256 shares, uint256 usdgOut);
    /// A WETH curve's sale or fee claim paid in ether by `sellForEth` / `claimInEth`.
    event PaidInEth(address indexed curve, address indexed by, address indexed to, uint256 amount);

    // --------------------------------------------------------------- errors ---

    error ZeroAddress();
    error NoCode(address account);
    error WrongLaunchFee(uint256 required, uint256 sent);
    error BadQuote(address token);
    error EtfQuoteNeedsForce(address etf);
    error NoPool(address token);
    error BadPool(address pool);
    error ThinOracle(address pool, uint16 cardinalityNext, uint16 minimum);
    error BadThreshold(uint256 threshold);
    /// A thresholds' list empty or longer than `MAX_THRESHOLD_CHOICES`.
    error BadThresholdCount(uint256 count);
    /// Entry `index` of a thresholds' list is not above the one before it.
    error ThresholdsNotIncreasing(uint256 index);
    /// A launch's threshold is not in the list of its quote (`quote` 0 for the ETF list).
    error ThresholdNotOffered(address quote, uint256 threshold);
    error BadSupply(uint256 supply);
    error BadCreatorTax(uint256 bps);
    error NotCurve(address curve);
    error NotCreator(address curve, address caller);
    error NativeTransferFailed(address to, uint256 amount);
    error RenounceForbidden();
    error BadHookAddress(address hook);
    error BadEtfFactory(address factory);
    error NotEtfCurve(address curve);
    error EtfCurveBuysInUsdg(address curve);
    error NotBonded(address curve);
    error NothingIn();
    error TooFewTokens(uint256 tokensOut, uint256 minTokensOut);
    error NotPoolManager();
    error SwapNotFilled(uint256 amountIn, uint256 spent);
    error TooFewShares(uint256 sharesOut, uint256 minSharesOut);
    error TooLittleUsdg(uint256 usdgOut, uint256 minUsdgOut);
    error BadPayout(uint8 payout);
    error SeedTooSmall(uint256 seedUsdg, uint256 minimum);
    error FirstBuyTooSmall(uint256 firstBuy, uint256 minimum);
    error BadMinFirstBuy(uint256 minFirstBuy);
    error NotWethQuote(address quote);
    error WrongValue(uint256 expected, uint256 sent);
    /// A USDG cut other than 0, 25, 50, 75 or 100.
    error BadUsdgCut(uint256 usdgCutPct);
    /// `buyAfterBond` / `sellAfterBond` naming a pool the curve does not have.
    error NoSuchPool(address curve, bool sharesPool);
    error NotWeth(address sender);

    // ---------------------------------------------------------- constructor ---

    /// @dev USDG, the PoolManager, the V3 factory and the TWAP oracle are the first ETF factory's, kept
    /// for good: a later factory must share USDG and the PoolManager (`setEtfFactory`).
    /// @param weth_ Wrapped ether (`deposit`, `withdraw`): the quote `buy`, `launchWithToken`, `sellForEth`
    /// and `claimInEth` wrap and unwrap ether for.
    /// @param hookSalt The CREATE2 salt that puts `HOOK` at an address whose permission bits are
    /// `beforeInitialize` alone (`BadHookAddress` otherwise), mined off-chain for this launcher's address.
    constructor(MaidMarianEtfFactory etfFactory_, address owner_, IWrappedNative weth_, bytes32 hookSalt) Ownable(owner_) {
        if (address(etfFactory_) == address(0) || address(weth_) == address(0)) revert ZeroAddress();
        if (address(etfFactory_).code.length == 0) revert NoCode(address(etfFactory_));
        if (address(weth_).code.length == 0) revert NoCode(address(weth_));
        WETH = weth_;
        USDG = etfFactory_.USDG();
        POOL_MANAGER = IPoolManagerV4(etfFactory_.POOL_MANAGER());
        UNISWAP_V3_FACTORY = etfFactory_.UNISWAP_V3_FACTORY();
        POOL_ORACLE = etfFactory_.POOL_ORACLE();
        _setEtfFactory(etfFactory_);
        uint8 usdgDecimals = IERC20Metadata(address(USDG)).decimals();
        USDG_UNIT_TO_18 = 10 ** (18 - usdgDecimals);
        MIN_ETF_SEED_USDG = MIN_ETF_SEED_WHOLE_USDG * 10 ** usdgDecimals;
        HOOK = new MaidMarianLaunchHook{ salt: hookSalt }(address(POOL_MANAGER));
        if (uint160(address(HOOK)) & HOOK_ALL_FLAGS_MASK != HOOK_BEFORE_INITIALIZE_FLAG) revert BadHookAddress(address(HOOK));
        CURVE_IMPLEMENTATION = new MaidMarianLaunchCurve(USDG, POOL_MANAGER, address(HOOK));
        TOKEN_IMPLEMENTATION = new MaidMarianToken(address(POOL_MANAGER));
        launchFee = INITIAL_LAUNCH_FEE;
        emit LaunchFeeChanged(0, INITIAL_LAUNCH_FEE);
        _etfThresholds.push(INITIAL_ETF_THRESHOLD);
        uint256[] memory initial = new uint256[](1);
        initial[0] = INITIAL_ETF_THRESHOLD;
        emit EtfThresholdsSet(initial);
    }

    // ---------------------------------------------------------------- owner ---

    /**
     * @notice List `token` as a quote for `launchWithToken` with the thresholds a launch picks from
     * (`allowed`), or delist it. Each curve copies its threshold at launch and keeps it: listing again
     * changes new launches only.
     * @dev On listing, `token` must have a pool: the V3 factory's `token`/USDG pool holding the most USDG
     * over the four fee tiers, checked as the ETF factory's `addToken` checks one (at least 1 801
     * observations, a price above 0, TWAP or spot). USDG needs none. An ETF of any factory this launcher
     * has used (`etfFactories`) is refused unless `force`; listed, it is a plain quote, its shares bought
     * and sold as they are, never minted or redeemed by the curve. A curve books the amounts it is sent:
     * a quote with a transfer fee or a rebasing balance breaks its solvency, and a quote that can freeze
     * an address (USDG) can stop every door of a curve it freezes.
     * @param thresholds The real quotes a launch may bond at, in `token`'s raw units (8 000 USDG is 8000e6,
     * 4 WETH 4e18): 1 to `MAX_THRESHOLD_CHOICES` (`BadThresholdCount`), strictly increasing
     * (`ThresholdsNotIncreasing`), each within `MIN_THRESHOLD` - `MAX_THRESHOLD` (`BadThreshold`); the
     * whole list replaced; ignored when delisting.
     * @param minFirstBuy The least first buy of `launchWithToken` on `token`, in its raw units (5 USDG is
     * 5e6), from 1 to the smallest threshold (`BadMinFirstBuy`); ignored when delisting.
     */
    function setTokenQuote(address token, bool allowed, bool force, uint256[] calldata thresholds, uint256 minFirstBuy) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert NoCode(token);
        QuoteInfo storage q = _quotes[token];
        if (!allowed) {
            if (_quoteThresholds[token].length == 0) revert BadQuote(token);
            delete _quoteThresholds[token];
            emit QuoteSet(token, q.pool, new uint256[](0), q.minFirstBuy);
            return;
        }
        if (!force && _isAnyFactoryEtf(token)) revert EtfQuoteNeedsForce(token);
        _storeThresholds(_quoteThresholds[token], thresholds, MIN_THRESHOLD);
        if (minFirstBuy == 0 || minFirstBuy > thresholds[0]) revert BadMinFirstBuy(minFirstBuy);
        address pool = token == address(USDG) ? address(0) : _usdgPool(token);
        if (!q.known) {
            q.known = true;
            quoteList.push(token);
        }
        // Under the smallest threshold, at most `MAX_THRESHOLD`, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        (q.pool, q.minFirstBuy) = (pool, uint128(minFirstBuy));
        emit QuoteSet(token, pool, thresholds, minFirstBuy);
    }

    /// @notice The thresholds, in shares, that curves `launchWithEtf` launches from now on pick from;
    /// launched curves keep theirs. 1 to `MAX_THRESHOLD_CHOICES`, strictly increasing, each within
    /// `MIN_ETF_THRESHOLD` - `MAX_THRESHOLD`; the whole list replaced.
    function setEtfThresholds(uint256[] calldata shares) external onlyOwner {
        _storeThresholds(_etfThresholds, shares, MIN_ETF_THRESHOLD);
        emit EtfThresholdsSet(shares);
    }

    /// @notice Send the refunds kept for the owner in `asset` (`ownerPot`) to `to`, an address of his
    /// choice: the way out for an owner frozen on that asset.
    function claimOwnerPot(address asset, address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = ownerPot[asset];
        if (amount == 0) revert NothingIn();
        ownerPot[asset] = 0;
        IERC20(asset).safeTransfer(to, amount);
        emit OwnerPotClaimed(asset, to, amount);
    }

    /// Replaces `list` with `values`, checked: 1 to `MAX_THRESHOLD_CHOICES`, strictly increasing, each
    /// within `min` - `MAX_THRESHOLD`.
    function _storeThresholds(uint128[] storage list, uint256[] calldata values, uint256 min) private {
        uint256 n = values.length;
        if (n == 0 || n > MAX_THRESHOLD_CHOICES) revert BadThresholdCount(n);
        while (list.length > 0) list.pop();
        for (uint256 i = 0; i < n; i++) {
            uint256 v = values[i];
            if (v < min || v > MAX_THRESHOLD) revert BadThreshold(v);
            if (i > 0 && v <= values[i - 1]) revert ThresholdsNotIncreasing(i);
            // At most `MAX_THRESHOLD`, checked above.
            // forge-lint: disable-next-line(unsafe-typecast)
            list.push(uint128(v));
        }
    }

    /// `threshold` if `list` holds it, else `ThresholdNotOffered`.
    function _pickThreshold(uint128[] storage list, address quote, uint256 threshold) private view returns (uint128) {
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            uint128 v = list[i];
            if (v == threshold) return v;
        }
        revert ThresholdNotOffered(quote, threshold);
    }

    /**
     * @notice The ETF factory of `launchWithEtf` from now on, and of `setTokenQuote`'s `isEtf` check.
     * Launched curves keep the ETF they have: a curve reads from this launcher only `owner()` and its own
     * logo (stored at launch), and its ETF's legs on that ETF's own factory, so a change here touches
     * none of them.
     * @dev Checked: code, the same `USDG()` and `POOL_MANAGER()` as this launcher's (the hook and every
     * curve are bound to them), and one-word answers to `creationFee()`, `isEtf(address)`,
     * `MIN_OBSERVATION_CARDINALITY()` and `MAX_TOKEN_DECIMALS()`. Not checkable without using it:
     * `createEtf`, `etfInfo` and `legsOf`, and that its ETFs answer as `MaidMarianEtfV3` (`setCreator`,
     * `mint`, `redeem`, `redeemInKind`, `mintOf`, `lastMintAt`, the fee and penalty getters, `FACTORY`).
     * A future factory must keep that whole interface; listing one that does not is the owner's error.
     */
    function setEtfFactory(MaidMarianEtfFactory next) external onlyOwner {
        if (address(next) == address(0)) revert ZeroAddress();
        if (address(next).code.length == 0) revert NoCode(address(next));
        _setEtfFactory(next);
    }

    function setLaunchFee(uint256 fee) external onlyOwner {
        emit LaunchFeeChanged(launchFee, fee);
        launchFee = fee;
    }

    /// @notice Send the collected launch fees to `to`.
    function withdrawFees(address payable to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = address(this).balance;
        if (amount > 0) {
            (bool ok,) = to.call{ value: amount }("");
            if (!ok) revert NativeTransferFailed(to, amount);
        }
        emit FeesWithdrawn(to, amount);
    }

    function _setEtfFactory(MaidMarianEtfFactory next) private {
        address f = address(next);
        (bool okUsdg, uint256 usdg) = _readWord(f, abi.encodeWithSelector(0x57ae3a9f)); // USDG()
        (bool okPm, uint256 pm) = _readWord(f, abi.encodeWithSelector(0x62308e85)); // POOL_MANAGER()
        (bool okFee,) = _readWord(f, abi.encodeWithSelector(0xdce0b4e4)); // creationFee()
        (bool okIsEtf, uint256 isEtf_) = _readWord(f, abi.encodeWithSelector(0x2a0b5c78, address(this))); // isEtf(address)
        (bool okCard,) = _readWord(f, abi.encodeWithSelector(0xaaeb763d)); // MIN_OBSERVATION_CARDINALITY()
        (bool okDec,) = _readWord(f, abi.encodeWithSelector(0x598663f0)); // MAX_TOKEN_DECIMALS()
        // forge-lint: disable-next-line(unsafe-typecast)
        if (!okUsdg || address(uint160(usdg)) != address(USDG) || !okPm || address(uint160(pm)) != address(POOL_MANAGER) || !okFee || !okIsEtf || isEtf_ > 1 || !okCard || !okDec) {
            revert BadEtfFactory(f);
        }
        emit EtfFactoryChanged(address(etfFactory), f);
        etfFactory = next;
        if (!_etfFactoryUsed[f]) {
            _etfFactoryUsed[f] = true;
            _etfFactories.push(f);
        }
    }

    /// Whether any factory ever used answers `isEtf(token)` true. A factory that cannot answer counts
    /// as "not an ETF there": the refusal guards the owner's own listing, which `force` lifts anyway.
    function _isAnyFactoryEtf(address token) private view returns (bool) {
        uint256 n = _etfFactories.length;
        for (uint256 i; i < n; ++i) {
            (bool ok, uint256 v) = _readWord(_etfFactories[i], abi.encodeWithSelector(0x2a0b5c78, token)); // isEtf(address)
            if (ok && v == 1) return true;
        }
        return false;
    }

    /// @notice Always reverts: ownership can be transferred, never renounced.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceForbidden();
    }

    // --------------------------------------------------------------- launch ---

    /**
     * @notice Launch a token on its curve, quoted in a listed token, and buy `firstBuy` of it for the
     * caller, its creator, in the same transaction: one curve buy from the base price, no snipe tax, the
     * fee and his tax as any buy. Send `launchFee()`, and on a WETH quote either nothing more (the first
     * buy pulled in WETH, approved to this contract) or exactly `firstBuy` more in ether, wrapped here.
     * Any other quote's first buy is pulled, approved to this contract.
     * @dev `msg.value - launchFee()` is the ether of the first buy: 0, or `firstBuy` on a WETH quote
     * (`WrongValue`, `NotWethQuote` otherwise); under `launchFee()` is `WrongLaunchFee`. A first buy that
     * bonds the curve is bought whole, as any last buy.
     * @param threshold The real quote that bonds the curve, one of `quoteThresholds(quote)` by value
     * (`ThresholdNotOffered` otherwise, `BadQuote` for a quote not listed): a list changed while the
     * launch waits refuses it rather than bonding it elsewhere. Kept by the curve for good.
     * @param creatorTaxBps 0 - 1 000, on each buy and each sale, to the creator.
     * @param supply In whole tokens: 1 000 000, 10 000 000, 100 000 000, 500 000 000 or 1 000 000 000.
     * @param firstBuy In the quote's raw units, at least `quoteMinFirstBuy(quote)` (`FirstBuyTooSmall`).
     * @param snipeExempt Exempted from the snipe tax with the caller, for good: at most
     * `MaidMarianLaunchCurve.MAX_SNIPE_EXEMPTIONS`; `address(0)` refused, a repeat or the caller skipped.
     */
    function launchWithToken(
        string calldata name_,
        string calldata symbol_,
        bytes calldata logoPng,
        MaidMarianEtfFactory.Profile calldata profile,
        address quote,
        uint256 threshold,
        uint16 creatorTaxBps,
        uint256 supply,
        uint256 firstBuy,
        address[] calldata snipeExempt
    ) external payable nonReentrant returns (MaidMarianLaunchCurve curve) {
        uint256 fee = launchFee;
        if (msg.value < fee) revert WrongLaunchFee(fee, msg.value);
        if (logoPng.length > MAX_LOGO_BYTES) revert BadLogo();
        checkPngLogo(logoPng);
        uint128[] storage offered = _quoteThresholds[quote];
        if (offered.length == 0) revert BadQuote(quote);
        uint128 picked = _pickThreshold(offered, quote, threshold);
        uint128 minFirstBuy = _quotes[quote].minFirstBuy;
        if (firstBuy < minFirstBuy) revert FirstBuyTooSmall(firstBuy, minFirstBuy);
        address pointer = logoPng.length == 0 ? address(0) : storeLogoAsCode(logoPng);
        curve = _launch(
            name_, symbol_, pointer, logoPng, profile, Terms({ quote: quote, etfQuote: false, threshold: picked, creatorTaxBps: creatorTaxBps, supply: _rawSupply(supply), usdgCutPct: 0 }), snipeExempt
        );
        // The first buy's tokens out are fixed by the arguments: the curve was created in this call.
        _buyFor(address(curve), quote, firstBuy, 0, msg.value - fee);
    }

    /**
     * @notice Create the token's reserve ETF, launch the token on it, its curve bonding at `threshold`
     * shares, and buy for the caller with his `seedUsdg` (at least `MIN_ETF_SEED_USDG`, `SeedTooSmall`;
     * approved to this contract). Send exactly the ETF factory's `creationFee()`. The caller ends with the
     * tokens of his first buy and no share.
     * @dev The ETF is named after the token: "<name> ETF" and "etf<symbol>" (so a name of at most 60
     * bytes and a symbol of at most 8 here, `BadName` / `BadSymbol` beyond); it shares the token's logo
     * (stored once) and profile; no fee and no penalty: entry, exit, hold, early and non-minter all 0.
     * This launcher stays its creator, with no door to change it, and makes the curve its fee recipient:
     * the creator's part of the ETF's management fee is minted to the curve, booked to the creator's fees.
     * The seed is the curve's `buyWithUsdg` for the caller (`buyWithUsdgFor`), the first door the curve
     * opens: one mint of the whole seed, the ETF's first, its shares in the curve's reserve; one buy from
     * the curve's base price for the caller (snipe-exempt), who pays the fee and his tax as any buyer; the
     * curve pays him the tokens. A first mint refunds nothing; a seed that bonds the curve is bought whole,
     * as any last buy.
     * The bond's pools follow `usdgCutPct`, fixed for good (`usdgCutPct()` on the curve, `Terms.usdgCutPct`
     * in `CurveLaunched`).
     * @param logoPng At most `MAX_LOGO_BYTES`.
     * @param legs As `createEtf`'s.
     * @param threshold One of `etfThresholds()` by value (`ThresholdNotOffered`), as `launchWithToken`'s.
     * @param supply As `launchWithToken`'s.
     * @param seedUsdg The first buy, USDG's raw units, at least `MIN_ETF_SEED_USDG`.
     * @param seedRoutes The first mint's, as the ETF's `mint` takes them (`firstMintSplit(seedUsdg)`):
     * `seedUsdg` less the 0.10 % entry fee, split by the legs' bps, the rounding dust on leg 0, each with
     * the caller's `amountOutMin`.
     * @param minSeedShares The first mint's `minShares`.
     * @param snipeExempt As `launchWithToken`'s.
     * @param usdgCutPct The percent of the bond's pooled quote in a token / USDG pool, the rest in a token /
     * shares pool: 0, 25, 50, 75 or 100 (`BadUsdgCut`).
     * @param bondRoutes, minUsdgAtBond As the curve's `buyWithUsdg`'s: read only when the seed bonds a
     * curve with a USDG cut; empty and 0 otherwise.
     */
    function launchWithEtf(
        string calldata name_,
        string calldata symbol_,
        bytes calldata logoPng,
        MaidMarianEtfFactory.Profile calldata profile,
        MaidMarianEtfFactory.LegSpec[] calldata legs,
        uint16 rebalanceBandBps,
        uint32 rebalanceMinInterval,
        uint256 threshold,
        uint16 creatorTaxBps,
        uint256 supply,
        uint256 seedUsdg,
        MaidMarianEtfV3.Route[] calldata seedRoutes,
        uint256 minSeedShares,
        address[] calldata snipeExempt,
        uint8 usdgCutPct,
        MaidMarianEtfV3.Route[] calldata bondRoutes,
        uint256 minUsdgAtBond
    ) external payable nonReentrant returns (MaidMarianEtfV3 etf, MaidMarianLaunchCurve curve) {
        if (seedUsdg < MIN_ETF_SEED_USDG) revert SeedTooSmall(seedUsdg, MIN_ETF_SEED_USDG);
        if (usdgCutPct % CURVE_CUT_STEP != 0 || usdgCutPct > CURVE_CUT_ALL) revert BadUsdgCut(usdgCutPct);
        if (bytes(name_).length > MAX_NAME_WITH_ETF_BYTES) revert BadName();
        if (bytes(symbol_).length > MAX_SYMBOL_WITH_ETF_BYTES) revert BadSymbol();
        if (logoPng.length > MAX_LOGO_BYTES) revert BadLogo();
        uint96 raw = _rawSupply(supply);
        uint128 picked = _pickThreshold(_etfThresholds, address(0), threshold);
        MaidMarianEtfV3.Params memory p = MaidMarianEtfV3.Params({
            entryFeeBps: 0, exitFeeBps: 0, holdPeriod: 0, earlyPenaltyBps: 0, nonMinterPenaltyBps: 0, rebalanceBandBps: rebalanceBandBps, rebalanceMinInterval: rebalanceMinInterval
        });
        etf = etfFactory.createEtf{ value: msg.value }(string.concat(name_, ETF_NAME_SUFFIX), string.concat(ETF_SYMBOL_PREFIX, symbol_), logoPng, legs, p, profile);
        Terms memory t = Terms({ quote: address(etf), etfQuote: true, threshold: picked, creatorTaxBps: creatorTaxBps, supply: raw, usdgCutPct: usdgCutPct });
        curve = _launch(name_, symbol_, etfFactory.etfInfo(address(etf)).logoPointer, logoPng, profile, t, snipeExempt);
        etf.setFeeRecipient(address(curve));
        _buyWithUsdg(address(curve), seedUsdg, seedRoutes, minSeedShares, 0, bondRoutes, minUsdgAtBond);
    }

    /**
     * @notice `curve.buy` with one approve of its quote to this launcher, for any plain-quote curve it
     * launched (an ETF curve buys in USDG: `EtfCurveBuysInUsdg`): pulls `quoteIn` from the caller, buys for
     * him (`buyFor`: the snipe tax and `Bought` are his, the curve pays him the tokens), all of `quoteIn`
     * bought. On a WETH curve the caller may send `quoteIn` in ether instead (`msg.value` equal to it,
     * `WrongValue` otherwise), wrapped here; ether on any other curve is `NotWethQuote`. This launcher
     * holds nothing of the call: a token sent here before it stays here, out of everyone's reach.
     */
    function buy(address curve, uint256 quoteIn, uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensOut) {
        CurveInfo storage info = _curves[curve];
        if (info.createdAt == 0) revert NotCurve(curve);
        if (MaidMarianLaunchCurve(curve).etfQuote()) revert EtfCurveBuysInUsdg(curve);
        address quote = info.quote;
        tokensOut = _buyFor(curve, quote, quoteIn, minTokensOut, msg.value);
    }

    /**
     * @notice Sell `tokensIn` on a WETH curve and be paid in ether: the curve takes the caller's tokens
     * (`sellFor`, no approve, the `Sold` his) and pays this launcher the WETH, unwrapped and sent to him
     * at once, at least `minEthOut`. A caller that cannot receive ether (`NativeTransferFailed`) sells on
     * the curve itself, paid in WETH.
     */
    function sellForEth(address curve, uint256 tokensIn, uint256 minEthOut) external nonReentrant returns (uint256 ethOut) {
        _wethCurve(curve);
        ethOut = MaidMarianLaunchCurve(curve).sellFor(msg.sender, tokensIn, minEthOut);
        emit PaidInEth(curve, msg.sender, msg.sender, ethOut);
        _unwrapTo(msg.sender, ethOut);
    }

    /**
     * @notice Claim `amount` of a WETH curve's fees in ether to `to`: the creator's (`protocol` false) or
     * the protocol's, the bond's 30 % included (`protocol` true, the owner), checked by the curve as its
     * own `claim` (`claimFor`); the WETH paid here is unwrapped and sent to `to` at once. A `to` that
     * cannot receive ether (`NativeTransferFailed`) is paid in WETH by the curve's own `claim`.
     */
    function claimInEth(address curve, bool protocol, uint256 amount, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _wethCurve(curve);
        MaidMarianLaunchCurve(curve).claimFor(msg.sender, protocol, amount);
        emit PaidInEth(curve, msg.sender, to, amount);
        _unwrapTo(to, amount);
    }

    /// Only WETH's `withdraw` sends ether here, inside `_unwrapTo`.
    receive() external payable {
        if (msg.sender != address(WETH)) revert NotWeth(msg.sender);
    }

    /**
     * @notice `curve.buyWithUsdg` (an ETF quote) with one approve of USDG to this launcher: pulls `usdgIn`
     * from the caller, the curve mints the ETF's shares with `routes` and buys with them for him
     * (`buyWithUsdgFor`), and the curve pays him the tokens; the mint's refunds go to the owner. As `buy`,
     * this launcher holds nothing of the call. `bondRoutes` and `minUsdgAtBond` as the curve's: read only
     * when the buy bonds a curve graduating to USDG.
     */
    function buyWithUsdg(
        address curve,
        uint256 usdgIn,
        MaidMarianEtfV3.Route[] calldata routes,
        uint256 minShares,
        uint256 minTokensOut,
        MaidMarianEtfV3.Route[] calldata bondRoutes,
        uint256 minUsdgAtBond
    ) external nonReentrant returns (uint256 tokensOut) {
        CurveInfo storage info = _curves[curve];
        if (info.createdAt == 0) revert NotCurve(curve);
        if (!MaidMarianLaunchCurve(curve).etfQuote()) revert NotEtfCurve(curve);
        tokensOut = _buyWithUsdg(curve, usdgIn, routes, minShares, minTokensOut, bondRoutes, minUsdgAtBond);
    }

    /**
     * @notice After an ETF curve's bond, buy its token with USDG in the bond pool `sharesPool` names (the
     * shares pool or the USDG pool; `NoSuchPool` for one the curve's cut did not open), one approve of USDG
     * to this launcher: pulls `usdgIn` from the caller and swaps it for the token, the tokens to the caller,
     * at least `minTokensOut`. In the USDG pool directly (`mintRoutes` unread). In the shares pool it first
     * mints the reserve ETF's shares with `mintRoutes` (the ETF's own `mint`, its shares to this launcher),
     * swaps them all, and sends the mint's refunds (each leg and USDG, the rounding of his routes) to the
     * owner, or keeps what his address refuses in `ownerPot`; `minTokensOut` bounds the whole trade, and the shares exist here only inside the call.
     */
    function buyAfterBond(address curve, bool sharesPool, uint256 usdgIn, MaidMarianEtfV3.Route[] calldata mintRoutes, uint256 minTokensOut) external nonReentrant returns (uint256 tokensOut) {
        CurveInfo storage info = _bondedEtfCurve(curve, sharesPool);
        if (!sharesPool) {
            if (usdgIn == 0) revert NothingIn();
            USDG.safeTransferFrom(msg.sender, address(this), usdgIn);
            tokensOut = _swapInPool(curve, address(USDG), address(USDG), usdgIn, msg.sender);
            if (tokensOut < minTokensOut) revert TooFewTokens(tokensOut, minTokensOut);
            emit BoughtAfterBond(curve, msg.sender, usdgIn, 0, tokensOut);
            return tokensOut;
        }
        MaidMarianEtfV3 etf = MaidMarianEtfV3(info.quote);
        address[] memory assets = _usdgAndLegs(etf);
        uint256[] memory before = _balancesOf(assets);
        USDG.safeTransferFrom(msg.sender, address(this), usdgIn);
        USDG.forceApprove(address(etf), usdgIn);
        uint256 shares = etf.mint(usdgIn, mintRoutes, 1);
        tokensOut = _swapInPool(curve, address(etf), address(etf), shares, msg.sender);
        if (tokensOut < minTokensOut) revert TooFewTokens(tokensOut, minTokensOut);
        _sweep(assets, before);
        emit BoughtAfterBond(curve, msg.sender, usdgIn, shares, tokensOut);
    }

    /**
     * @notice After an ETF curve's bond, sell its token in the bond pool `sharesPool` names (`NoSuchPool`
     * for one the curve's cut did not open): pulls `tokensIn` from the caller (the token approved to this
     * launcher) and swaps them all. In the USDG pool the USDG goes to the caller, at least `minUsdgOut`,
     * `payout` `PAY_USDG` only (`minSharesOut`, `redeemRoutes`, `allowFail` unread). In the shares pool
     * they are swapped for the reserve ETF's shares, at
     * least `minSharesOut`, and every share is redeemed to the caller, as the curve's `sell` pays:
     * the curve's `PAY_IN_KIND` by the ETF's `redeemInKind` with `allowFail` (a leg whose token
     * refuses the transfer forfeited to the fund, the rest paid), or `PAY_USDG` by its `redeem` with
     * `redeemRoutes` and `minUsdgOut` (a leg whose route is 0 paid in kind). The shares exist here only
     * inside the call.
     * @dev The due of each leg is fixed by the pool's output at execution, so every route that sells is
     * set to its due, and its `amountOutMin` in the same proportion, rounded up (`routesAtDue`): routes
     * read from a preview run when the pool gives a little more or less, at the price floor the caller
     * wrote, the USDG bounded whole by `minUsdgOut`, and no remainder of a routed leg is paid in kind.
     */
    function sellAfterBond(address curve, bool sharesPool, uint256 tokensIn, uint256 minSharesOut, uint8 payout, MaidMarianEtfV3.Route[] calldata redeemRoutes, uint256 minUsdgOut, uint16 allowFail)
        external
        nonReentrant
        returns (uint256 usdgOut)
    {
        CurveInfo storage info = _bondedEtfCurve(curve, sharesPool);
        if (tokensIn == 0) revert NothingIn();
        if (payout != CURVE_PAY_IN_KIND && payout != CURVE_PAY_USDG) revert BadPayout(payout);
        IERC20(info.token).safeTransferFrom(msg.sender, address(this), tokensIn);
        if (!sharesPool) {
            if (payout != CURVE_PAY_USDG) revert BadPayout(payout);
            usdgOut = _swapInPool(curve, address(USDG), info.token, tokensIn, msg.sender);
            if (usdgOut < minUsdgOut) revert TooLittleUsdg(usdgOut, minUsdgOut);
            emit SoldAfterBond(curve, msg.sender, tokensIn, 0, usdgOut);
            return usdgOut;
        }
        uint256 shares = _swapInPool(curve, info.quote, info.token, tokensIn, address(this));
        if (shares < minSharesOut) revert TooFewShares(shares, minSharesOut);
        MaidMarianEtfV3 etf = MaidMarianEtfV3(info.quote);
        if (payout == CURVE_PAY_IN_KIND) etf.redeemInKind(shares, msg.sender, allowFail);
        else usdgOut = etf.redeem(shares, routesAtDue(etf, address(this), shares, redeemRoutes), minUsdgOut, msg.sender);
        emit SoldAfterBond(curve, msg.sender, tokensIn, shares, usdgOut);
    }

    /**
     * @notice The PoolManager's callback for `_swapInPool`'s `unlock`, and only inside it: one exact-input
     * swap in a bond pool, paid from this launcher's balance, the output taken to the recipient.
     * @dev The whole input must be swapped (`SwapNotFilled` otherwise, so nothing of it is left here): the
     * pool's liquidity is full range, and the price limit is V4's extreme.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER) || !_swapping) revert NotPoolManager();
        (IPoolManagerV4.PoolKey memory key, address tokenIn, uint256 amountIn, address recipient) = abi.decode(data, (IPoolManagerV4.PoolKey, address, uint256, address));
        bool zeroForOne = tokenIn == key.currency0;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // `amountIn` is a balance held here, far under 2^255.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 delta = POOL_MANAGER.swap(key, IPoolManagerV4.SwapParams({ zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit }), "");
        // A V4 `BalanceDelta`: amount0 in the high 128 bits, amount1 in the low.
        int256 a0 = delta >> 128;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 a1 = int256(int128(delta));
        (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (dIn != -int256(amountIn)) revert SwapNotFilled(amountIn, uint256(-dIn));
        POOL_MANAGER.sync(tokenIn);
        IERC20(tokenIn).safeTransfer(address(POOL_MANAGER), amountIn);
        POOL_MANAGER.settle();
        // The output of an exact-input swap is owed to the swapper: `dOut` >= 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 out = uint256(dOut);
        if (out > 0) POOL_MANAGER.take(zeroForOne ? key.currency1 : key.currency0, recipient, out);
        return abi.encode(out);
    }

    /// `curve.buyWithUsdgFor` the caller with `usdgIn` of his USDG: the curve pays him every output.
    function _buyWithUsdg(
        address curve,
        uint256 usdgIn,
        MaidMarianEtfV3.Route[] calldata routes,
        uint256 minShares,
        uint256 minTokensOut,
        MaidMarianEtfV3.Route[] calldata bondRoutes,
        uint256 minUsdgAtBond
    ) private returns (uint256 tokensOut) {
        USDG.safeTransferFrom(msg.sender, address(this), usdgIn);
        USDG.forceApprove(curve, usdgIn);
        tokensOut = MaidMarianLaunchCurve(curve).buyWithUsdgFor(msg.sender, usdgIn, routes, minShares, minTokensOut, bondRoutes, minUsdgAtBond);
    }

    /// `curve.buyFor` the caller with `quoteIn` of `quote`, all of it bought: pulled from him when no ether
    /// is sent (`value` 0), else wrapped from exactly `quoteIn` of ether on WETH only.
    function _buyFor(address curve, address quote, uint256 quoteIn, uint256 minTokensOut, uint256 value) private returns (uint256 tokensOut) {
        if (value == 0) {
            IERC20(quote).safeTransferFrom(msg.sender, address(this), quoteIn);
        } else {
            if (quote != address(WETH)) revert NotWethQuote(quote);
            if (value != quoteIn) revert WrongValue(quoteIn, value);
            WETH.deposit{ value: value }();
        }
        IERC20(quote).forceApprove(curve, quoteIn);
        tokensOut = MaidMarianLaunchCurve(curve).buyFor(msg.sender, quoteIn, minTokensOut);
    }

    /// Refuses anything but a WETH curve of this launcher.
    function _wethCurve(address curve) private view {
        CurveInfo storage info = _curves[curve];
        if (info.createdAt == 0) revert NotCurve(curve);
        if (info.quote != address(WETH)) revert NotWethQuote(info.quote);
    }

    /// Unwraps `amount` of the WETH held here and sends the ether to `to`, the last step of its door.
    function _unwrapTo(address to, uint256 amount) private {
        WETH.withdraw(amount);
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed(to, amount);
    }

    /// USDG and `etf`'s legs (read on the ETF's own factory): what its `mint` may refund.
    function _usdgAndLegs(MaidMarianEtfV3 etf) private view returns (address[] memory assets) {
        MaidMarianEtfFactory.LegSpec[] memory legs = MaidMarianEtfFactory(address(etf.FACTORY())).legsOf(address(etf));
        assets = new address[](legs.length + 1);
        assets[0] = address(USDG);
        for (uint256 i = 0; i < legs.length; i++) {
            assets[i + 1] = legs[i].token;
        }
    }

    /// `curve`'s record, refused unless it is an ETF curve of this launcher that has bonded and has the pool
    /// `sharesPool` names: the shares pool for a cut under 100, the USDG pool for one above 0.
    function _bondedEtfCurve(address curve, bool sharesPool) private view returns (CurveInfo storage info) {
        info = _curves[curve];
        if (info.createdAt == 0) revert NotCurve(curve);
        MaidMarianLaunchCurve c = MaidMarianLaunchCurve(curve);
        if (!c.etfQuote()) revert NotEtfCurve(curve);
        if (!c.bonded()) revert NotBonded(curve);
        uint256 cut = c.usdgCutPct();
        if (sharesPool ? cut == CURVE_CUT_ALL : cut == 0) revert NoSuchPool(curve, sharesPool);
    }

    /// Swaps all `amountIn` of `tokenIn` held here in `curve`'s bond pool of the token and `currency`
    /// through this launcher's own `unlock`, the output to `recipient`; returns the output. Not the
    /// Universal Router: the PoolManager is already the curve's, the swap is one call whose limit and fill
    /// this contract writes and checks, and paying it takes a transfer, not an approval to a router or Permit2.
    function _swapInPool(address curve, address currency, address tokenIn, uint256 amountIn, address recipient) private returns (uint256 out) {
        _swapping = true;
        out = abi.decode(POOL_MANAGER.unlock(abi.encode(MaidMarianLaunchCurve(curve).poolKeyIn(currency), tokenIn, amountIn, recipient)), (uint256));
        _swapping = false;
    }

    function _balancesOf(address[] memory assets) private view returns (uint256[] memory balances) {
        balances = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            balances[i] = IERC20(assets[i]).balanceOf(address(this));
        }
    }

    /// Sends the owner what each asset's balance rose by since `before`: the mint's refunds, which the
    /// buyer did not ask for. A transfer the owner's address refuses (frozen on USDG, blocklisted on a
    /// leg) does not stop the buy: the amount is kept here in `ownerPot` for `claimOwnerPot`.
    function _sweep(address[] memory assets, uint256[] memory before) private {
        address to = owner();
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 now_ = IERC20(assets[i]).balanceOf(address(this));
            if (now_ <= before[i]) continue;
            uint256 amount = now_ - before[i];
            if (!IERC20(assets[i]).trySafeTransfer(to, amount)) {
                ownerPot[assets[i]] += amount;
                emit OwnerPotBooked(assets[i], amount);
            }
        }
    }

    /// @notice Overwrite `curve`'s whole profile; an empty string clears a field. Its creator only. On an ETF
    /// curve, its reserve ETF's profile too, on the ETF's factory (this launcher is that ETF's creator).
    function setProfile(address curve, string calldata description, string calldata x, string calldata telegram, string calldata website) external {
        CurveInfo storage info = _curves[curve];
        address creator = info.creator;
        if (creator == address(0)) revert NotCurve(curve);
        if (creator != msg.sender) revert NotCreator(curve, msg.sender);
        checkProfileFields(description, x, telegram, website);
        _storeProfile(curve, description, x, telegram, website);
        if (MaidMarianLaunchCurve(curve).etfQuote()) {
            address etf = info.quote;
            MaidMarianEtfFactory(address(MaidMarianEtfV3(etf).FACTORY())).setProfile(etf, description, x, telegram, website);
        }
        emit ProfileSet(curve, msg.sender, description, x, telegram, website);
    }

    function _launch(
        string calldata name_,
        string calldata symbol_,
        address logoPointer,
        bytes calldata logoPng,
        MaidMarianEtfFactory.Profile calldata profile,
        Terms memory t,
        address[] calldata snipeExempt
    ) internal returns (MaidMarianLaunchCurve curve) {
        checkTokenName(bytes(name_));
        checkTokenSymbol(bytes(symbol_));
        checkProfileFields(profile.description, profile.x, profile.telegram, profile.website);
        if (t.creatorTaxBps > MAX_CREATOR_TAX_BPS) revert BadCreatorTax(t.creatorTaxBps);
        MaidMarianToken token = MaidMarianToken(Clones.cloneWithImmutableArgs(address(TOKEN_IMPLEMENTATION), tokenCloneArgs(name_, symbol_)));
        curve = MaidMarianLaunchCurve(
            Clones.cloneWithImmutableArgs(address(CURVE_IMPLEMENTATION), curveCloneArgs(t.quote, t.etfQuote, t.usdgCutPct, t.creatorTaxBps, t.threshold, msg.sender, address(token), t.supply))
        );
        token.initialize(address(curve), t.supply);
        curve.initialize(snipeExempt);
        _curves[address(curve)] = CurveInfo({ creator: msg.sender, quote: t.quote, token: address(token), logoPointer: logoPointer, createdAt: uint64(block.timestamp) });
        curves.push(address(curve));
        if (bytes(profile.description).length + bytes(profile.x).length + bytes(profile.telegram).length + bytes(profile.website).length > 0) {
            _storeProfile(address(curve), profile.description, profile.x, profile.telegram, profile.website);
        }
        emit CurveLaunched(address(curve), msg.sender, t.quote, address(token), curves.length - 1, t, name_, symbol_, logoPng, profile);
    }

    function _storeProfile(address curve, string calldata description, string calldata x, string calldata telegram, string calldata website) private {
        MaidMarianEtfFactory.Profile storage s = _profiles[curve];
        (s.description, s.x, s.telegram, s.website) = (description, x, telegram, website);
        _profileUpdatedAt[curve] = block.timestamp;
    }

    /// `supply` whole tokens in raw units, one of the five; `BadSupply` for any other.
    function _rawSupply(uint256 supply) private pure returns (uint96) {
        if (!isSupply(supply)) revert BadSupply(supply);
        // At most 1e27, under 2^96.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(supply * 1e18);
    }

    /// `token`'s pool for `setTokenQuote`: of its V3 pools against USDG, the one holding the most USDG,
    /// with `addToken`'s checks.
    function _usdgPool(address token) private view returns (address pool) {
        uint256 most;
        for (uint256 i = 0; i < 4; i++) {
            // Uniswap V3's fee tiers: 0.01 %, 0.05 %, 0.30 %, 1 %.
            uint24 fee = i == 0 ? 100 : i == 1 ? 500 : i == 2 ? 3000 : 10_000;
            (bool ok, uint256 word) = _readWord(UNISWAP_V3_FACTORY, abi.encodeWithSelector(0x1698ee82, token, address(USDG), fee)); // getPool(address,address,uint24)
            // forge-lint: disable-next-line(unsafe-typecast)
            address candidate = address(uint160(word));
            if (!ok || candidate.code.length == 0) continue;
            (bool okBalance, uint256 held) = _readWord(address(USDG), abi.encodeCall(IERC20.balanceOf, (candidate)));
            if (okBalance && held > most) (pool, most) = (candidate, held);
        }
        if (pool == address(0)) revert NoPool(token);
        (bool success, bytes memory ret) = pool.staticcall(abi.encodeCall(IUniswapV3PoolSlot0.slot0, ()));
        if (!success || ret.length != 7 * 32) revert BadPool(pool);
        (,,,, uint256 next,,) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
        uint16 minimum = etfFactory.MIN_OBSERVATION_CARDINALITY();
        // Below `minimum`, a uint16, when it reverts.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (next < minimum) revert ThinOracle(pool, uint16(next), minimum);
        (bool okDecimals, uint256 decimals) = _readWord(token, abi.encodeWithSelector(0x313ce567)); // decimals()
        if (!okDecimals || decimals > etfFactory.MAX_TOKEN_DECIMALS()) revert BadQuote(token);
        // One whole token's price in 18 decimals, as `addToken` reads it.
        uint256 scale = 10 ** decimals * USDG_UNIT_TO_18;
        (uint256 price, bool priced) = POOL_ORACLE.tryQuote(pool, scale, token, address(USDG));
        if (!priced || price == 0) (price, priced) = POOL_ORACLE.trySpotQuote(pool, scale, token, address(USDG));
        if (!priced || price == 0) revert BadPool(pool);
    }

    /// A one-word answer to a static call; `ok == false` for anything else.
    function _readWord(address target, bytes memory data) private view returns (bool ok, uint256 value) {
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    // ---------------------------------------------------------------- views ---

    /// @notice Every ETF factory this launcher has used, the current one included, in order of first use.
    function etfFactories() external view returns (address[] memory) {
        return _etfFactories;
    }

    /// @notice The thresholds a `launchWithToken` on `token` picks from, increasing; empty when not listed.
    function quoteThresholds(address token) external view returns (uint256[] memory) {
        return _widen(_quoteThresholds[token]);
    }

    /// @notice The thresholds, in shares, a `launchWithEtf` picks from, increasing.
    function etfThresholds() external view returns (uint256[] memory) {
        return _widen(_etfThresholds);
    }

    function _widen(uint128[] storage list) private view returns (uint256[] memory out) {
        out = new uint256[](list.length);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = list[i];
        }
    }

    /// @notice The least first buy of `launchWithToken` on `token`, its raw units; 0 when never listed.
    function quoteMinFirstBuy(address token) external view returns (uint256) {
        return _quotes[token].minFirstBuy;
    }

    /// @notice The V3 pool read at `token`'s last listing; 0 for USDG or a token never listed.
    function quotePool(address token) external view returns (address) {
        return _quotes[token].pool;
    }

    /// @notice Whether a launch may choose `supply` whole tokens.
    function isSupply(uint256 supply) public pure returns (bool) {
        return supply == SUPPLY_1M || supply == SUPPLY_10M || supply == SUPPLY_100M || supply == SUPPLY_500M || supply == SUPPLY_1B;
    }

    function quoteCount() external view returns (uint256) {
        return quoteList.length;
    }

    function isCurve(address curve) external view returns (bool) {
        return _curves[curve].createdAt != 0;
    }

    /// @notice A curve's creator, quote, token, logo pointer and launch time; zeros for any other address.
    function curveInfo(address curve) external view returns (CurveInfo memory) {
        return _curves[curve];
    }

    function curveCount() external view returns (uint256) {
        return curves.length;
    }

    /// @notice A curve's PNG logo; empty when none. A `launchWithEtf` token's is its ETF's, stored once.
    function logo(address curve) external view returns (bytes memory) {
        return readLogoCode(_curves[curve].logoPointer);
    }

    /// @notice `curve`'s profile and when it was last written; empty strings and 0 when it has none.
    function profileOf(address curve) external view returns (string memory description, string memory x, string memory telegram, string memory website, uint256 updatedAt) {
        MaidMarianEtfFactory.Profile storage p = _profiles[curve];
        return (p.description, p.x, p.telegram, p.website, _profileUpdatedAt[curve]);
    }
}
