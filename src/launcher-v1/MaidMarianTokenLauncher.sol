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
import { MaidMarianLaunchCurve, IPoolManagerV4, curveCloneArgs } from "./MaidMarianLaunchCurve.sol";
import { MaidMarianLaunchHook, HOOK_BEFORE_INITIALIZE_FLAG, HOOK_ALL_FLAGS_MASK } from "./MaidMarianLaunchHook.sol";
import { MaidMarianToken, tokenCloneArgs } from "./MaidMarianToken.sol";
import { checkTokenName, checkTokenSymbol, checkProfileFields, checkPngLogo, storeLogoAsCode, readLogoCode, BadLogo, BadName, BadSymbol } from "./MaidMarianTokenChecks.sol";

/**
 * @title Maid Marian token launcher
 * @notice Anyone launches a token on its bonding curve, two ways:
 *  - `launchWithToken` (`launchFee()`): quoted in a token the owner lists with its pool
 *    against USDG (`setTokenQuote`), bonding at the threshold he set for it;
 *  - `launchWithEtf` (the ETF factory's `creationFee()` only): creates the token's reserve ETF, named
 *    after it, with fixed terms, makes its first mint with the caller's `ETF_SEED_WHOLE_USDG` USDG
 *    (a donation to the ETF, later or sent before, lifts the share for its holders on the v3 bis factory; on the v4
 *    it is not counted, and the factory's owner may rescue it), and quotes the curve in its shares
 *    (`etfThreshold()` bond it); the curve mints and redeems them, and the caller ends as the ETF's
 *    creator and holder of the first shares.
 * Each token has a name, a symbol, a PNG logo stored as code and a profile (description, X, Telegram,
 * website) on the ETF factory's allowlists, edited by its creator (`setProfile`).
 * One approve for every curve: `buy` and `buyWithUsdg` pull the caller's quote (or USDG) here, buy on the
 * curve for him and pass him every output and refund in the same call. They spend the caller's allowance
 * only (no `from` anywhere) and forward the rise of every balance they touched. The curve is told the
 * caller is the buyer (`buyFor`, `buyWithUsdgFor`, this launcher's alone), so the snipe tax, its
 * exemptions and the curve's `Bought` are his, as on a direct buy.
 * At launch the creator names up to `MaidMarianLaunchCurve.MAX_SNIPE_EXEMPTIONS` addresses exempted with
 * him from the snipe tax, kept by the curve for good.
 * The owner lists quotes, sets the launch fee and the bond's set-aside recipient (`setTreasury`),
 * withdraws the launch fees, and receives the protocol's part of every curve's fees. He has nothing
 * over a curve's reserve. Ownership is never renounced.
 * A launch makes two EIP-1167 clones, created and initialized in its transaction: the token, a plain
 * ERC-20 (`TOKEN_IMPLEMENTATION`, its name and symbol appended to its code), and its curve
 * (`CURVE_IMPLEMENTATION`, its terms appended), which holds the whole supply. Each curve keeps the
 * threshold it was launched with. Every curve's bond pool carries `HOOK`, deployed by the constructor,
 * which lets only that curve initialize it.
 */
contract MaidMarianTokenLauncher is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------ constants ---

    uint256 public constant INITIAL_LAUNCH_FEE = 0.0005 ether;

    /// `etfThreshold()` at deploy: 8 000 shares, whatever they are worth.
    uint128 public constant INITIAL_ETF_THRESHOLD = 8000e18;

    /// Every threshold's bounds, in its quote's raw units (1e9 is 1 000 USDG, 1e33 a quadrillion of an
    /// 18-decimal token): the bond's pool price stays inside what `sqrtPriceX96` can carry for the 2/7
    /// of the supply left.
    uint128 public constant MIN_THRESHOLD = 1e9;
    uint128 public constant MAX_THRESHOLD = 1e33;

    uint256 public constant MAX_CREATOR_TAX_BPS = 1000;

    /// A launch's logo, at most 10 KiB (a logo costs about 290 gas a byte, calldata included). With a
    /// full profile: `launchWithToken` about 3.5 M gas; `launchWithEtf` and its first mint about 5.1 M on
    /// three legs, 6.2 M on ten; a full snipe exemption list brings it to about 6.7 M, plus the chain's L1
    /// part (0 to ~0.23 M), near the ~7 M a wallet simulates.
    uint256 public constant MAX_LOGO_BYTES = 10_240;

    /// The reserve ETF's first mint, made by `launchWithEtf` with the caller's USDG, in whole USDG: a
    /// share starts at 1 USDG, and moving its price x10 then takes a donation of 9 times this to the ETF.
    uint256 public constant ETF_SEED_WHOLE_USDG = 10;

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

    /// A listed quote: the V3 pool its threshold was read at (0 for USDG); `threshold` 0 when not listed.
    struct QuoteInfo {
        address pool;
        bool known;
        uint128 threshold;
    }

    struct CurveInfo {
        address creator;
        address quote;
        address token;
        address logoPointer;
        uint64 createdAt;
    }

    /// A launch's terms, in its clone's arguments; `supply` in raw units.
    struct Terms {
        address quote;
        bool etfQuote;
        uint128 threshold;
        uint16 creatorTaxBps;
        uint96 supply;
    }

    // ----------------------------------------------------------- immutables ---

    IERC20 public immutable USDG;
    IPoolManagerV4 public immutable POOL_MANAGER;
    address public immutable UNISWAP_V3_FACTORY;
    MaidMarianBagPoolOracle public immutable POOL_ORACLE;

    /// Scales a raw USDG amount to 18 decimals.
    uint256 private immutable USDG_UNIT_TO_18;

    /// `ETF_SEED_WHOLE_USDG` in USDG's raw units.
    uint256 public immutable ETF_SEED_USDG;

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

    /// What `launchWithToken` must be sent, exactly.
    uint256 public launchFee;

    /// Receives the bond's set-aside; the owner when 0.
    address public treasury;

    /// The real quote, in shares, that bonds a curve launched by `launchWithEtf` from now on.
    uint128 public etfThreshold;

    address[] public quoteList;
    mapping(address token => QuoteInfo) private _quotes;

    address[] public curves;
    mapping(address curve => CurveInfo) private _curves;
    mapping(address curve => MaidMarianEtfFactory.Profile) private _profiles;
    mapping(address curve => uint256) private _profileUpdatedAt;

    // --------------------------------------------------------------- events ---

    /// Everything needed to list a curve without reading it.
    event CurveLaunched(
        address indexed curve, address indexed creator, address indexed quote, address token, uint256 index, Terms terms, string name, string symbol, bytes logo, MaidMarianEtfFactory.Profile profile
    );
    event ProfileSet(address indexed curve, address indexed creator, string description, string x, string telegram, string website);
    /// `threshold` 0: delisted.
    event QuoteSet(address indexed token, address pool, uint256 threshold);
    event EtfThresholdChanged(uint256 previous, uint256 next);
    event LaunchFeeChanged(uint256 previous, uint256 next);
    event TreasuryChanged(address previous, address next);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event EtfFactoryChanged(address previous, address next);

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
    error BadSupply(uint256 supply);
    error BadCreatorTax(uint256 bps);
    error NotCurve(address curve);
    error NotCreator(address curve, address caller);
    error NativeTransferFailed(address to, uint256 amount);
    error RenounceForbidden();
    error BadHookAddress(address hook);
    error BadEtfFactory(address factory);
    error NotEtfCurve(address curve);

    // ---------------------------------------------------------- constructor ---

    /// @dev USDG, the PoolManager, the V3 factory and the TWAP oracle are the first ETF factory's, kept
    /// for good: a later factory must share USDG and the PoolManager (`setEtfFactory`).
    /// @param hookSalt The CREATE2 salt that puts `HOOK` at an address whose permission bits are
    /// `beforeInitialize` alone (`BadHookAddress` otherwise), mined off-chain for this launcher's address.
    constructor(MaidMarianEtfFactory etfFactory_, address owner_, bytes32 hookSalt) Ownable(owner_) {
        if (address(etfFactory_) == address(0)) revert ZeroAddress();
        if (address(etfFactory_).code.length == 0) revert NoCode(address(etfFactory_));
        USDG = etfFactory_.USDG();
        POOL_MANAGER = IPoolManagerV4(etfFactory_.POOL_MANAGER());
        UNISWAP_V3_FACTORY = etfFactory_.UNISWAP_V3_FACTORY();
        POOL_ORACLE = etfFactory_.POOL_ORACLE();
        _setEtfFactory(etfFactory_);
        uint8 usdgDecimals = IERC20Metadata(address(USDG)).decimals();
        USDG_UNIT_TO_18 = 10 ** (18 - usdgDecimals);
        ETF_SEED_USDG = ETF_SEED_WHOLE_USDG * 10 ** usdgDecimals;
        HOOK = new MaidMarianLaunchHook{ salt: hookSalt }(address(POOL_MANAGER));
        if (uint160(address(HOOK)) & HOOK_ALL_FLAGS_MASK != HOOK_BEFORE_INITIALIZE_FLAG) revert BadHookAddress(address(HOOK));
        CURVE_IMPLEMENTATION = new MaidMarianLaunchCurve(USDG, POOL_MANAGER, address(HOOK));
        TOKEN_IMPLEMENTATION = new MaidMarianToken(address(POOL_MANAGER));
        launchFee = INITIAL_LAUNCH_FEE;
        emit LaunchFeeChanged(0, INITIAL_LAUNCH_FEE);
        etfThreshold = INITIAL_ETF_THRESHOLD;
        emit EtfThresholdChanged(0, INITIAL_ETF_THRESHOLD);
    }

    // ---------------------------------------------------------------- owner ---

    /**
     * @notice List `token` as a quote for `launchWithToken` at `threshold` (`allowed`), or delist it.
     * Each curve copies the threshold at launch and keeps it: listing again changes new launches only.
     * @dev On listing, `token` must have a pool: the V3 factory's `token`/USDG pool holding the most USDG
     * over the four fee tiers, checked as the ETF factory's `addToken` checks one (at least 1 801
     * observations, a price above 0, TWAP or spot). USDG needs none. An ETF of any factory this launcher
     * has used (`etfFactories`) is refused unless `force`; listed, it is a plain quote, its shares bought
     * and sold as they are, never minted or redeemed by the curve. A curve books the amounts it is sent:
     * a quote with a transfer fee or a rebasing balance breaks its solvency, and a quote that can freeze
     * an address (USDG) can stop every door of a curve it freezes.
     * @param threshold The real quote that bonds a curve, in `token`'s raw units (8 000 USDG is 8000e6,
     * 4 WETH 4e18), within `MIN_THRESHOLD` - `MAX_THRESHOLD`; ignored when delisting.
     */
    function setTokenQuote(address token, bool allowed, bool force, uint256 threshold) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert NoCode(token);
        QuoteInfo storage q = _quotes[token];
        if (!allowed) {
            if (q.threshold == 0) revert BadQuote(token);
            q.threshold = 0;
            emit QuoteSet(token, q.pool, 0);
            return;
        }
        if (!force && _isAnyFactoryEtf(token)) revert EtfQuoteNeedsForce(token);
        if (threshold < MIN_THRESHOLD || threshold > MAX_THRESHOLD) revert BadThreshold(threshold);
        address pool = token == address(USDG) ? address(0) : _usdgPool(token);
        if (!q.known) {
            q.known = true;
            quoteList.push(token);
        }
        // At most `MAX_THRESHOLD`, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        (q.pool, q.threshold) = (pool, uint128(threshold));
        emit QuoteSet(token, pool, threshold);
    }

    /// @notice The threshold, in shares, of curves `launchWithEtf` launches from now on; launched curves
    /// keep theirs. Within `MIN_THRESHOLD` - `MAX_THRESHOLD`.
    function setEtfThreshold(uint256 shares) external onlyOwner {
        if (shares < MIN_THRESHOLD || shares > MAX_THRESHOLD) revert BadThreshold(shares);
        emit EtfThresholdChanged(etfThreshold, shares);
        // At most `MAX_THRESHOLD`, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        etfThreshold = uint128(shares);
    }

    /**
     * @notice The ETF factory of `launchWithEtf` from now on, and of `setTokenQuote`'s `isEtf` check.
     * Launched curves keep the ETF they have: a curve reads from this launcher only `owner()`,
     * `setAsideRecipient()` and its own logo (stored at launch), and its ETF's legs on that ETF's own
     * factory, so a change here touches none of them.
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

    /// @notice Where the bonds' set-asides go; 0 for the owner.
    function setTreasury(address next) external onlyOwner {
        emit TreasuryChanged(treasury, next);
        treasury = next;
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
     * @notice Launch a token on its curve, quoted in a listed token; the caller is its creator. Send
     * exactly `launchFee()`.
     * @param creatorTaxBps 0 - 1 000, on each buy and each sale, to the creator.
     * @param supply In whole tokens: 1 000 000, 10 000 000, 100 000 000, 500 000 000 or 1 000 000 000.
     * @param snipeExempt Exempted from the snipe tax with the caller, for good: at most
     * `MaidMarianLaunchCurve.MAX_SNIPE_EXEMPTIONS`; `address(0)` refused, a repeat or the caller skipped.
     */
    function launchWithToken(
        string calldata name_,
        string calldata symbol_,
        bytes calldata logoPng,
        MaidMarianEtfFactory.Profile calldata profile,
        address quote,
        uint16 creatorTaxBps,
        uint256 supply,
        address[] calldata snipeExempt
    ) external payable returns (MaidMarianLaunchCurve curve) {
        uint256 fee = launchFee;
        if (msg.value != fee) revert WrongLaunchFee(fee, msg.value);
        if (logoPng.length > MAX_LOGO_BYTES) revert BadLogo();
        checkPngLogo(logoPng);
        uint128 threshold = _quotes[quote].threshold;
        if (threshold == 0) revert BadQuote(quote);
        address pointer = logoPng.length == 0 ? address(0) : storeLogoAsCode(logoPng);
        curve =
            _launch(name_, symbol_, pointer, logoPng, profile, Terms({ quote: quote, etfQuote: false, threshold: threshold, creatorTaxBps: creatorTaxBps, supply: _rawSupply(supply) }), snipeExempt);
    }

    /**
     * @notice Create the token's reserve ETF and launch the token on it, its curve bonding at
     * `etfThreshold()` shares. Send exactly the ETF factory's `creationFee()`. The caller ends as the ETF's creator and
     * `feeRecipient`.
     * @dev The ETF is named after the token: "<name> ETF" and "etf<symbol>" (so a name of at most 60
     * bytes and a symbol of at most 8 here, `BadName` / `BadSymbol` beyond); it shares the token's logo
     * (stored once) and profile; no fee and no penalty: entry, exit, hold, early and non-minter
     * all 0, so any holder of its shares redeems them free. Its first mint is the caller's
     * `ETF_SEED_USDG` (approved to this contract), the shares sent to him; a first mint keeps all it
     * buys, so nothing is refunded.
     * @param logoPng At most `MAX_LOGO_BYTES`.
     * @param legs As `createEtf`'s.
     * @param supply As `launchWithToken`'s.
     * @param seedRoutes The first mint's, as the ETF's `mint` takes them: amounts of `ETF_SEED_USDG` less
     * the 0.10 % entry fee, split by the legs' bps, the rounding dust on leg 0.
     * @param minSeedShares The first mint's `minShares`.
     * @param snipeExempt As `launchWithToken`'s.
     */
    function launchWithEtf(
        string calldata name_,
        string calldata symbol_,
        bytes calldata logoPng,
        MaidMarianEtfFactory.Profile calldata profile,
        MaidMarianEtfFactory.LegSpec[] calldata legs,
        uint16 rebalanceBandBps,
        uint32 rebalanceMinInterval,
        uint16 creatorTaxBps,
        uint256 supply,
        MaidMarianEtfV3.Route[] calldata seedRoutes,
        uint256 minSeedShares,
        address[] calldata snipeExempt
    ) external payable returns (MaidMarianEtfV3 etf, MaidMarianLaunchCurve curve) {
        if (bytes(name_).length > MAX_NAME_WITH_ETF_BYTES) revert BadName();
        if (bytes(symbol_).length > MAX_SYMBOL_WITH_ETF_BYTES) revert BadSymbol();
        if (logoPng.length > MAX_LOGO_BYTES) revert BadLogo();
        uint96 raw = _rawSupply(supply);
        MaidMarianEtfV3.Params memory p = MaidMarianEtfV3.Params({
            entryFeeBps: 0, exitFeeBps: 0, holdPeriod: 0, earlyPenaltyBps: 0, nonMinterPenaltyBps: 0, rebalanceBandBps: rebalanceBandBps, rebalanceMinInterval: rebalanceMinInterval
        });
        etf = etfFactory.createEtf{ value: msg.value }(string.concat(name_, ETF_NAME_SUFFIX), string.concat(ETF_SYMBOL_PREFIX, symbol_), logoPng, legs, p, profile);
        etf.setCreator(msg.sender);
        uint256 seed = ETF_SEED_USDG;
        USDG.safeTransferFrom(msg.sender, address(this), seed);
        USDG.forceApprove(address(etf), seed);
        IERC20(address(etf)).safeTransfer(msg.sender, etf.mint(seed, seedRoutes, minSeedShares));
        Terms memory t = Terms({ quote: address(etf), etfQuote: true, threshold: etfThreshold, creatorTaxBps: creatorTaxBps, supply: raw });
        curve = _launch(name_, symbol_, etfFactory.etfInfo(address(etf)).logoPointer, logoPng, profile, t, snipeExempt);
    }

    /**
     * @notice `curve.buy` with one approve of its quote to this launcher, for any curve it launched: pulls
     * `quoteIn` from the caller, buys for him (`buyFor`: the snipe tax and `Bought` are his), sends him the
     * tokens and the refund of a last buy.
     * @dev Sends the caller the rise of this launcher's quote and token balances over the call: what his buy
     * produced, nothing more. A token sent here before the call stays here, out of everyone's reach.
     */
    function buy(address curve, uint256 quoteIn, uint256 minTokensOut) external nonReentrant returns (uint256 tokensOut) {
        CurveInfo storage info = _curves[curve];
        if (info.createdAt == 0) revert NotCurve(curve);
        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (info.quote, info.token);
        uint256[] memory before = _balancesOf(assets);
        IERC20(info.quote).safeTransferFrom(msg.sender, address(this), quoteIn);
        IERC20(info.quote).forceApprove(curve, quoteIn);
        tokensOut = MaidMarianLaunchCurve(curve).buyFor(msg.sender, quoteIn, minTokensOut);
        _passOn(assets, before);
    }

    /**
     * @notice `curve.buyWithUsdg` (an ETF quote) with one approve of USDG to this launcher: pulls `usdgIn`
     * from the caller, the curve mints the ETF's shares with `routes` and buys with them for him
     * (`buyWithUsdgFor`), and the caller gets the tokens, the mint's refunds (each leg and USDG) and a last
     * buy's excess shares redeemed in kind.
     * @dev As `buy`: sends the caller the rise of every balance it touched (the launched token, USDG and the
     * ETF's legs, read on the ETF's own factory).
     */
    function buyWithUsdg(address curve, uint256 usdgIn, MaidMarianEtfV3.Route[] calldata routes, uint256 minShares, uint256 minTokensOut) external nonReentrant returns (uint256 tokensOut) {
        CurveInfo storage info = _curves[curve];
        if (info.createdAt == 0) revert NotCurve(curve);
        if (!MaidMarianLaunchCurve(curve).etfQuote()) revert NotEtfCurve(curve);
        MaidMarianEtfFactory.LegSpec[] memory legs = MaidMarianEtfFactory(address(MaidMarianEtfV3(info.quote).FACTORY())).legsOf(info.quote);
        address[] memory assets = new address[](legs.length + 2);
        (assets[0], assets[1]) = (info.token, address(USDG));
        for (uint256 i = 0; i < legs.length; i++) {
            assets[i + 2] = legs[i].token;
        }
        uint256[] memory before = _balancesOf(assets);
        USDG.safeTransferFrom(msg.sender, address(this), usdgIn);
        USDG.forceApprove(curve, usdgIn);
        tokensOut = MaidMarianLaunchCurve(curve).buyWithUsdgFor(msg.sender, usdgIn, routes, minShares, minTokensOut);
        _passOn(assets, before);
    }

    function _balancesOf(address[] memory assets) private view returns (uint256[] memory balances) {
        balances = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            balances[i] = IERC20(assets[i]).balanceOf(address(this));
        }
    }

    /// Sends the caller what each asset's balance rose by since `before`.
    function _passOn(address[] memory assets, uint256[] memory before) private {
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 now_ = IERC20(assets[i]).balanceOf(address(this));
            if (now_ > before[i]) IERC20(assets[i]).safeTransfer(msg.sender, now_ - before[i]);
        }
    }

    /// @notice Overwrite `curve`'s whole profile; an empty string clears a field. Its creator only.
    function setProfile(address curve, string calldata description, string calldata x, string calldata telegram, string calldata website) external {
        address creator = _curves[curve].creator;
        if (creator == address(0)) revert NotCurve(curve);
        if (creator != msg.sender) revert NotCreator(curve, msg.sender);
        checkProfileFields(description, x, telegram, website);
        _storeProfile(curve, description, x, telegram, website);
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
    ) private returns (MaidMarianLaunchCurve curve) {
        checkTokenName(bytes(name_));
        checkTokenSymbol(bytes(symbol_));
        checkProfileFields(profile.description, profile.x, profile.telegram, profile.website);
        if (t.creatorTaxBps > MAX_CREATOR_TAX_BPS) revert BadCreatorTax(t.creatorTaxBps);
        MaidMarianToken token = MaidMarianToken(Clones.cloneWithImmutableArgs(address(TOKEN_IMPLEMENTATION), tokenCloneArgs(name_, symbol_)));
        curve = MaidMarianLaunchCurve(
            Clones.cloneWithImmutableArgs(address(CURVE_IMPLEMENTATION), curveCloneArgs(t.quote, t.etfQuote, t.creatorTaxBps, t.threshold, msg.sender, address(token), t.supply))
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

    /// @notice Who receives the bonds' set-asides: `treasury`, else the owner.
    function setAsideRecipient() external view returns (address) {
        address t = treasury;
        return t == address(0) ? owner() : t;
    }

    /// @notice `token`'s threshold as a quote; 0 when not listed.
    function quoteThreshold(address token) external view returns (uint256) {
        return _quotes[token].threshold;
    }

    /// @notice The V3 pool `token`'s threshold was last read at; 0 for USDG or a token never listed.
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
