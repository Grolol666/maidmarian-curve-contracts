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
import { MaidMarianLaunchCurve, IPoolManagerV4, curveCloneArgs, routesAtDue, CURVE_PAY_IN_KIND, CURVE_PAY_USDG, CURVE_CUT_STEP, CURVE_CUT_ALL, CURVE_EXPLOSION } from "./MaidMarianLaunchCurve.sol";
import { MaidMarianLaunchHook, HOOK_BEFORE_INITIALIZE_FLAG, HOOK_ALL_FLAGS_MASK } from "./MaidMarianLaunchHook.sol";
import { TickMath } from "./uniswap/TickMath.sol";
import { checkTokenName, checkTokenSymbol, checkProfileFields, checkPngLogo, isAsciiAlnum, storeLogoAsCode, readLogoCode, BadLogo, BadName, BadSymbol } from "./MaidMarianTokenChecks.sol";

interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * @title Maid Marian token launcher
 * @notice Launches a token on its bonding curve, quoted in a listed token (`launchWithToken`) or in a
 * reserve ETF created with it (`launchWithEtf`); one approve here buys and sells on every curve.
 */
contract MaidMarianTokenLauncher is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------ constants ---

    uint256 public constant INITIAL_LAUNCH_FEE = 0.0005 ether;

    /// The ETF list at deploy: 8 000 shares.
    uint128 public constant INITIAL_ETF_THRESHOLD = 8000e18;

    /// A threshold's bounds in its quote's raw units, so every reserve passes `curveFits` whatever the
    /// decimals and the supply.
    uint128 public constant MIN_THRESHOLD = 1e9;
    uint128 public constant MAX_THRESHOLD = 1e33;

    /// 100 shares: a bond to USDG fits while a share redeems to 0.111 USDG or more.
    uint128 public constant MIN_ETF_THRESHOLD = 100e18;

    uint256 public constant MAX_THRESHOLD_CHOICES = 8;

    uint256 public constant MAX_CREATOR_TAX_BPS = 1000;

    /// Every reserve ETF may explode: ten legs bond in 6.14 M gas, under the ~7 M a wallet simulates.
    uint256 public constant MAX_EXPLOSION_LEGS = 10;

    /// About 240 gas a byte: a heavy launch goes without its logo and sets it after (`setLogo`).
    uint256 public constant MAX_LOGO_BYTES = 10_240;

    uint256 public constant MIN_ETF_SEED_WHOLE_USDG = 10;

    /// The ETF factory's 64 and 11 bytes leave the token 60 and 8 after the suffix and prefix.
    string public constant ETF_NAME_SUFFIX = " ETF";
    string public constant ETF_SYMBOL_PREFIX = "etf";
    uint256 public constant MAX_NAME_WITH_ETF_BYTES = 60;
    uint256 public constant MAX_SYMBOL_WITH_ETF_BYTES = 8;

    uint256 public constant SUPPLY_1M = 1_000_000;
    uint256 public constant SUPPLY_10M = 10_000_000;
    uint256 public constant SUPPLY_100M = 100_000_000;
    uint256 public constant SUPPLY_500M = 500_000_000;
    uint256 public constant SUPPLY_1B = 1_000_000_000;

    // ---------------------------------------------------------------- types ---

    /// `minFirstBuy`: the least first buy of a launch on the quote; listed while its thresholds are not empty.
    struct QuoteInfo {
        address pool;
        bool known;
        uint128 minFirstBuy;
    }

    struct Profile {
        string description;
        string x;
        string telegram;
        string website;
        string discord;
    }

    struct CurveInfo {
        address creator;
        address quote;
        address token;
        address logoPointer;
        uint64 createdAt;
    }

    /// `usdgCutPct`: 0, 25, 50, 75, 100 or `CURVE_EXPLOSION`; 0 for a plain quote.
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

    IWrappedNative public immutable WETH;

    uint256 private immutable USDG_UNIT_TO_18;

    uint256 public immutable MIN_ETF_SEED_USDG;

    MaidMarianLaunchCurve public immutable CURVE_IMPLEMENTATION;

    MaidMarianLaunchHook public immutable HOOK;

    // ---------------------------------------------------------------- state ---

    MaidMarianEtfFactory public etfFactory;

    /// Unbounded: only the owner appends, one per `setEtfFactory`.
    address[] private _etfFactories;
    mapping(address factory => bool) private _etfFactoryUsed;

    uint256 public launchFee;

    uint128[] private _etfThresholds;

    address[] public quoteList;
    mapping(address token => QuoteInfo) private _quotes;
    mapping(address token => uint128[]) private _quoteThresholds;

    /// Refunds the owner's address refused, kept for `claimOwnerPot`.
    mapping(address asset => uint256) public ownerPot;

    address[] public curves;
    mapping(address curve => CurveInfo) private _curves;
    mapping(address curve => Profile) private _profiles;
    mapping(address curve => uint256) private _profileUpdatedAt;

    /// Set by `_swapInPool` around its `unlock`: the callback is served only then.
    bool private transient _swapping;

    // --------------------------------------------------------------- events ---

    event CurveLaunched(
        address indexed curve, address indexed creator, address indexed quote, address token, uint256 index, Terms terms, string name, string symbol, bytes logo, Profile profile
    );
    event ProfileSet(address indexed curve, address indexed creator, Profile profile);
    event LogoSet(address indexed curve, address indexed creator, bytes logo);
    event QuoteSet(address indexed token, address pool, uint256[] thresholds, uint256 minFirstBuy);
    event EtfThresholdsSet(uint256[] thresholds);
    event OwnerPotBooked(address indexed asset, uint256 amount);
    event OwnerPotClaimed(address indexed asset, address indexed to, uint256 amount);
    event LaunchFeeChanged(uint256 previous, uint256 next);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event EtfFactoryChanged(address previous, address next);
    /// `pool` names the bond pool by its other currency.
    event BoughtAfterBond(address indexed curve, address indexed buyer, address pool, uint256 amountIn, uint256 shares, uint256 tokensOut);
    event SoldAfterBond(address indexed curve, address indexed seller, address pool, uint256 tokensIn, uint256 shares, uint256 amountOut);
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
    error BadThresholdCount(uint256 count);
    error ThresholdsNotIncreasing(uint256 index);
    /// `quote` 0 for the ETF list.
    error ThresholdNotOffered(address quote, uint256 threshold);
    error BadSupply(uint256 supply);
    error BadCreatorTax(uint256 bps);
    error NotCurve(address curve);
    error NotCreator(address curve, address caller);
    error BadDiscord();
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
    error BadUsdgCut(uint256 usdgCutPct);
    error TooManyLegsToExplode(uint256 legs, uint256 max);
    error NoSuchPool(address curve, address pool);
    error TooLittleOut(uint256 amountOut, uint256 minAmountOut);
    error NotWeth(address sender);

    // ---------------------------------------------------------- constructor ---

    /// @param hookSalt Puts `HOOK` at an address whose permission bits are `beforeInitialize` alone.
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
        launchFee = INITIAL_LAUNCH_FEE;
        emit LaunchFeeChanged(0, INITIAL_LAUNCH_FEE);
        _etfThresholds.push(INITIAL_ETF_THRESHOLD);
        uint256[] memory initial = new uint256[](1);
        initial[0] = INITIAL_ETF_THRESHOLD;
        emit EtfThresholdsSet(initial);
    }

    // ---------------------------------------------------------------- owner ---

    /**
     * @notice List `token` as a `launchWithToken` quote with its thresholds, or delist it; launched curves keep
     * theirs. A quote with a transfer fee or a rebasing balance breaks a curve's solvency.
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
        // forge-lint: disable-next-line(unsafe-typecast)
        (q.pool, q.minFirstBuy) = (pool, uint128(minFirstBuy));
        emit QuoteSet(token, pool, thresholds, minFirstBuy);
    }

    /// @notice Replace the thresholds, in shares, `launchWithEtf` picks from.
    function setEtfThresholds(uint256[] calldata shares) external onlyOwner {
        _storeThresholds(_etfThresholds, shares, MIN_ETF_THRESHOLD);
        emit EtfThresholdsSet(shares);
    }

    /// @notice Send the refunds kept for the owner in `asset` to `to`.
    function claimOwnerPot(address asset, address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = ownerPot[asset];
        if (amount == 0) revert NothingIn();
        ownerPot[asset] = 0;
        IERC20(asset).safeTransfer(to, amount);
        emit OwnerPotClaimed(asset, to, amount);
    }

    function _storeThresholds(uint128[] storage list, uint256[] calldata values, uint256 min) private {
        uint256 n = values.length;
        if (n == 0 || n > MAX_THRESHOLD_CHOICES) revert BadThresholdCount(n);
        while (list.length > 0) list.pop();
        for (uint256 i = 0; i < n; i++) {
            uint256 v = values[i];
            if (v < min || v > MAX_THRESHOLD) revert BadThreshold(v);
            if (i > 0 && v <= values[i - 1]) revert ThresholdsNotIncreasing(i);
            // forge-lint: disable-next-line(unsafe-typecast)
            list.push(uint128(v));
        }
    }

    function _pickThreshold(uint128[] storage list, address quote, uint256 threshold) private view returns (uint128) {
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            uint128 v = list[i];
            if (v == threshold) return v;
        }
        revert ThresholdNotOffered(quote, threshold);
    }

    /// @notice The ETF factory of future launches; launched curves keep their ETF's. Its whole interface
    /// cannot be checked here: listing one that does not keep it is the owner's error.
    function setEtfFactory(MaidMarianEtfFactory next) external onlyOwner {
        if (address(next) == address(0)) revert ZeroAddress();
        if (address(next).code.length == 0) revert NoCode(address(next));
        _setEtfFactory(next);
    }

    function setLaunchFee(uint256 fee) external onlyOwner {
        emit LaunchFeeChanged(launchFee, fee);
        launchFee = fee;
    }

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
     * @notice Launch a token quoted in a listed `quote` and buy `firstBuy` of it for the caller, its creator.
     * Send `launchFee()`, plus exactly `firstBuy` in ether on a WETH quote to pay it in ether.
     * @param logoPng Empty, or a PNG of at most `MAX_LOGO_BYTES`.
     * @param profile `discord` empty, or `https://discord.gg/` / `https://discord.com/invite/` and 2 - 32 of
     * `[A-Za-z0-9-]`; the other fields on the ETF factory's rules.
     */
    function launchWithToken(
        string calldata name_,
        string calldata symbol_,
        bytes calldata logoPng,
        Profile calldata profile,
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
        _buyFor(address(curve), quote, firstBuy, 0, msg.value - fee);
    }

    /**
     * @notice Create the token's reserve ETF (no fee, this launcher its creator, the curve its fee recipient),
     * launch the token on it and buy for the caller with `seedUsdg`, the ETF's first mint. Send the ETF
     * factory's `creationFee()`. The profile is stored on the ETF, but Discord, kept here.
     * @param usdgCutPct 0, 25, 50, 75, 100, or `CURVE_EXPLOSION` (255).
     * @param bondRoutes, minUsdgAtBond Read only when the seed bonds a curve with a USDG cut.
     */
    function launchWithEtf(
        string calldata name_,
        string calldata symbol_,
        bytes calldata logoPng,
        Profile calldata profile,
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
        if (usdgCutPct == CURVE_EXPLOSION) {
            if (legs.length > MAX_EXPLOSION_LEGS) revert TooManyLegsToExplode(legs.length, MAX_EXPLOSION_LEGS);
        } else if (usdgCutPct % CURVE_CUT_STEP != 0 || usdgCutPct > CURVE_CUT_ALL) {
            revert BadUsdgCut(usdgCutPct);
        }
        if (bytes(name_).length > MAX_NAME_WITH_ETF_BYTES) revert BadName();
        if (bytes(symbol_).length > MAX_SYMBOL_WITH_ETF_BYTES) revert BadSymbol();
        if (logoPng.length > MAX_LOGO_BYTES) revert BadLogo();
        uint96 raw = _rawSupply(supply);
        uint128 picked = _pickThreshold(_etfThresholds, address(0), threshold);
        MaidMarianEtfV3.Params memory p = MaidMarianEtfV3.Params({
            entryFeeBps: 0, exitFeeBps: 0, holdPeriod: 0, earlyPenaltyBps: 0, nonMinterPenaltyBps: 0, rebalanceBandBps: rebalanceBandBps, rebalanceMinInterval: rebalanceMinInterval
        });
        etf = etfFactory.createEtf{ value: msg.value }(string.concat(name_, ETF_NAME_SUFFIX), string.concat(ETF_SYMBOL_PREFIX, symbol_), logoPng, legs, p, MaidMarianEtfFactory.Profile(profile.description, profile.x, profile.telegram, profile.website));
        Terms memory t = Terms({ quote: address(etf), etfQuote: true, threshold: picked, creatorTaxBps: creatorTaxBps, supply: raw, usdgCutPct: usdgCutPct });
        curve = _launch(name_, symbol_, etfFactory.etfInfo(address(etf)).logoPointer, logoPng, profile, t, snipeExempt);
        etf.setFeeRecipient(address(curve));
        _buyWithUsdg(address(curve), seedUsdg, seedRoutes, minSeedShares, 0, bondRoutes, minUsdgAtBond);
    }

    /// @notice `curve.buy` for the caller with one approve of its quote here; ether on a WETH curve.
    function buy(address curve, uint256 quoteIn, uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensOut) {
        CurveInfo storage info = _curves[curve];
        if (info.createdAt == 0) revert NotCurve(curve);
        if (MaidMarianLaunchCurve(curve).etfQuote()) revert EtfCurveBuysInUsdg(curve);
        address quote = info.quote;
        tokensOut = _buyFor(curve, quote, quoteIn, minTokensOut, msg.value);
    }

    /// @notice Sell on a WETH curve, paid in ether.
    function sellForEth(address curve, uint256 tokensIn, uint256 minEthOut) external nonReentrant returns (uint256 ethOut) {
        _wethCurve(curve);
        address token = _curves[curve].token;
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        IERC20(token).forceApprove(curve, tokensIn);
        ethOut = MaidMarianLaunchCurve(curve).sellFor(msg.sender, tokensIn, minEthOut);
        emit PaidInEth(curve, msg.sender, msg.sender, ethOut);
        _unwrapTo(msg.sender, ethOut);
    }

    /// @notice Claim a WETH curve's fees in ether: the creator's, or the protocol's (the owner).
    function claimInEth(address curve, bool protocol, uint256 amount, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _wethCurve(curve);
        MaidMarianLaunchCurve(curve).claimFor(msg.sender, protocol, amount);
        emit PaidInEth(curve, msg.sender, to, amount);
        _unwrapTo(to, amount);
    }

    /// Only WETH's `withdraw` sends ether here.
    receive() external payable {
        if (msg.sender != address(WETH)) revert NotWeth(msg.sender);
    }

    /// @notice `curve.buyWithUsdg` for the caller with one approve of USDG here; the mint's refunds go to the owner.
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

    /// @notice After the bond, buy the token in the pool named by its other currency; in the shares pool
    /// `amountIn` is USDG, minted into shares inside the call.
    function buyAfterBond(address curve, address pool, uint256 amountIn, MaidMarianEtfV3.Route[] calldata mintRoutes, uint256 minTokensOut) external nonReentrant returns (uint256 tokensOut) {
        CurveInfo storage info = _bondedEtfCurve(curve, pool);
        if (pool != info.quote) {
            if (amountIn == 0) revert NothingIn();
            IERC20(pool).safeTransferFrom(msg.sender, address(this), amountIn);
            tokensOut = _swapInPool(curve, pool, pool, amountIn, msg.sender);
            if (tokensOut < minTokensOut) revert TooFewTokens(tokensOut, minTokensOut);
            emit BoughtAfterBond(curve, msg.sender, pool, amountIn, 0, tokensOut);
            return tokensOut;
        }
        MaidMarianEtfV3 etf = MaidMarianEtfV3(info.quote);
        address[] memory assets = _usdgAndLegs(etf);
        uint256[] memory before = _balancesOf(assets);
        USDG.safeTransferFrom(msg.sender, address(this), amountIn);
        USDG.forceApprove(address(etf), amountIn);
        uint256 shares = etf.mint(amountIn, mintRoutes, 1);
        tokensOut = _swapInPool(curve, address(etf), address(etf), shares, msg.sender);
        if (tokensOut < minTokensOut) revert TooFewTokens(tokensOut, minTokensOut);
        _sweep(assets, before);
        emit BoughtAfterBond(curve, msg.sender, pool, amountIn, shares, tokensOut);
    }

    /// @notice After the bond, sell the token in the pool named by its other currency; in the shares pool
    /// the shares are redeemed to the caller inside the call.
    function sellAfterBond(address curve, address pool, uint256 tokensIn, uint256 minSharesOut, uint8 payout, MaidMarianEtfV3.Route[] calldata redeemRoutes, uint256 minOut, uint16 allowFail)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        CurveInfo storage info = _bondedEtfCurve(curve, pool);
        if (tokensIn == 0) revert NothingIn();
        if (payout != CURVE_PAY_IN_KIND && payout != CURVE_PAY_USDG) revert BadPayout(payout);
        IERC20(info.token).safeTransferFrom(msg.sender, address(this), tokensIn);
        if (pool != info.quote) {
            bool inUsdg = pool == address(USDG);
            if (payout != (inUsdg ? CURVE_PAY_USDG : CURVE_PAY_IN_KIND)) revert BadPayout(payout);
            amountOut = _swapInPool(curve, pool, info.token, tokensIn, msg.sender);
            if (amountOut < minOut) {
                if (inUsdg) revert TooLittleUsdg(amountOut, minOut);
                revert TooLittleOut(amountOut, minOut);
            }
            emit SoldAfterBond(curve, msg.sender, pool, tokensIn, 0, amountOut);
            return amountOut;
        }
        uint256 shares = _swapInPool(curve, info.quote, info.token, tokensIn, address(this));
        if (shares < minSharesOut) revert TooFewShares(shares, minSharesOut);
        MaidMarianEtfV3 etf = MaidMarianEtfV3(info.quote);
        if (payout == CURVE_PAY_IN_KIND) etf.redeemInKind(shares, msg.sender, allowFail);
        else amountOut = etf.redeem(shares, routesAtDue(etf, address(this), shares, redeemRoutes), minOut, msg.sender);
        emit SoldAfterBond(curve, msg.sender, pool, tokensIn, shares, amountOut);
    }

    /// @notice The PoolManager's callback, inside `_swapInPool`'s `unlock` only.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER) || !_swapping) revert NotPoolManager();
        (IPoolManagerV4.PoolKey memory key, address tokenIn, uint256 amountIn, address recipient) = abi.decode(data, (IPoolManagerV4.PoolKey, address, uint256, address));
        bool zeroForOne = tokenIn == key.currency0;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 delta = POOL_MANAGER.swap(key, IPoolManagerV4.SwapParams({ zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit }), "");
        // A V4 `BalanceDelta`: amount0 in the high 128 bits.
        int256 a0 = delta >> 128;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 a1 = int256(int128(delta));
        (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (dIn != -int256(amountIn)) revert SwapNotFilled(amountIn, uint256(-dIn));
        POOL_MANAGER.sync(tokenIn);
        IERC20(tokenIn).safeTransfer(address(POOL_MANAGER), amountIn);
        POOL_MANAGER.settle();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 out = uint256(dOut);
        if (out > 0) POOL_MANAGER.take(zeroForOne ? key.currency1 : key.currency0, recipient, out);
        return abi.encode(out);
    }

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

    function _wethCurve(address curve) private view {
        CurveInfo storage info = _curves[curve];
        if (info.createdAt == 0) revert NotCurve(curve);
        if (info.quote != address(WETH)) revert NotWethQuote(info.quote);
    }

    function _unwrapTo(address to, uint256 amount) private {
        WETH.withdraw(amount);
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed(to, amount);
    }

    function _usdgAndLegs(MaidMarianEtfV3 etf) private view returns (address[] memory assets) {
        MaidMarianEtfFactory.LegSpec[] memory legs = MaidMarianEtfFactory(address(etf.FACTORY())).legsOf(address(etf));
        assets = new address[](legs.length + 1);
        assets[0] = address(USDG);
        for (uint256 i = 0; i < legs.length; i++) {
            assets[i + 1] = legs[i].token;
        }
    }

    /// The pool is initialized only if `HOOK` let the curve open it at its bond (`slot0` at `keccak256(id, 6)`).
    function _bondedEtfCurve(address curve, address pool) private view returns (CurveInfo storage info) {
        info = _curves[curve];
        if (info.createdAt == 0) revert NotCurve(curve);
        MaidMarianLaunchCurve c = MaidMarianLaunchCurve(curve);
        if (!c.etfQuote()) revert NotEtfCurve(curve);
        if (!c.bonded()) revert NotBonded(curve);
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 id = keccak256(abi.encode(c.poolKeyIn(pool)));
        if (POOL_MANAGER.extsload(keccak256(abi.encode(id, uint256(6)))) == 0) revert NoSuchPool(curve, pool);
    }

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

    /// A refund the owner's address refuses is kept in `ownerPot`, so it never stops a buy.
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

    /// @notice Overwrite `curve`'s whole profile, its creator only; on its reserve ETF, but Discord.
    function setProfile(address curve, Profile calldata profile) external {
        CurveInfo storage info = _curveOf(curve);
        _checkProfile(profile);
        if (MaidMarianLaunchCurve(curve).etfQuote()) {
            address etf = info.quote;
            MaidMarianEtfFactory(address(MaidMarianEtfV3(etf).FACTORY())).setProfile(etf, profile.description, profile.x, profile.telegram, profile.website);
            _storeDiscord(curve, profile.discord);
        } else {
            _storeProfile(curve, profile);
        }
        emit ProfileSet(curve, msg.sender, profile);
    }

    /// @notice Replace `curve`'s logo, its creator only, any time; the launch's checks, an empty PNG refused.
    /// The reserve ETF keeps its own.
    function setLogo(address curve, bytes calldata png) external {
        CurveInfo storage info = _curveOf(curve);
        if (png.length == 0 || png.length > MAX_LOGO_BYTES) revert BadLogo();
        checkPngLogo(png);
        info.logoPointer = storeLogoAsCode(png);
        emit LogoSet(curve, msg.sender, png);
    }

    function _curveOf(address curve) private view returns (CurveInfo storage info) {
        info = _curves[curve];
        address creator = info.creator;
        if (creator == address(0)) revert NotCurve(curve);
        if (creator != msg.sender) revert NotCreator(curve, msg.sender);
    }

    function _checkProfile(Profile calldata profile) private pure {
        checkProfileFields(profile.description, profile.x, profile.telegram, profile.website);
        _checkDiscord(bytes(profile.discord));
    }

    function _checkDiscord(bytes calldata s) private pure {
        uint256 n = s.length;
        if (n == 0) return;
        uint256 p = _startsWith(s, "https://discord.gg/") ? 19 : _startsWith(s, "https://discord.com/invite/") ? 27 : 0;
        if (p == 0 || n < p + 2 || n > p + 32) revert BadDiscord();
        for (uint256 i = p; i < n; i++) {
            if (!isAsciiAlnum(s[i]) && s[i] != "-") revert BadDiscord();
        }
    }

    function _startsWith(bytes calldata s, bytes memory prefix) private pure returns (bool) {
        if (s.length < prefix.length) return false;
        for (uint256 i = 0; i < prefix.length; i++) {
            if (s[i] != prefix[i]) return false;
        }
        return true;
    }

    function _launch(
        string calldata name_,
        string calldata symbol_,
        address logoPointer,
        bytes calldata logoPng,
        Profile calldata profile,
        Terms memory t,
        address[] calldata snipeExempt
    ) internal returns (MaidMarianLaunchCurve curve) {
        checkTokenName(bytes(name_));
        checkTokenSymbol(bytes(symbol_));
        _checkProfile(profile);
        if (t.creatorTaxBps > MAX_CREATOR_TAX_BPS) revert BadCreatorTax(t.creatorTaxBps);
        curve = MaidMarianLaunchCurve(
            Clones.cloneWithImmutableArgs(address(CURVE_IMPLEMENTATION), curveCloneArgs(t.quote, t.etfQuote, t.usdgCutPct, t.creatorTaxBps, t.threshold, msg.sender, t.supply))
        );
        curve.initialize(snipeExempt, name_, symbol_);
        address token = curve.token();
        _curves[address(curve)] = CurveInfo({ creator: msg.sender, quote: t.quote, token: token, logoPointer: logoPointer, createdAt: uint64(block.timestamp) });
        curves.push(address(curve));
        if (t.etfQuote) {
            if (bytes(profile.discord).length > 0) _storeDiscord(address(curve), profile.discord);
        } else if (bytes(profile.description).length + bytes(profile.x).length + bytes(profile.telegram).length + bytes(profile.website).length + bytes(profile.discord).length > 0) {
            _storeProfile(address(curve), profile);
        }
        emit CurveLaunched(address(curve), msg.sender, t.quote, token, curves.length - 1, t, name_, symbol_, logoPng, profile);
    }

    function _storeProfile(address curve, Profile calldata profile) private {
        _profiles[curve] = profile;
        _profileUpdatedAt[curve] = block.timestamp;
    }

    function _storeDiscord(address curve, string calldata discord) private {
        _profiles[curve].discord = discord;
        _profileUpdatedAt[curve] = block.timestamp;
    }

    function _rawSupply(uint256 supply) private pure returns (uint96) {
        if (!isSupply(supply)) revert BadSupply(supply);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(supply * 1e18);
    }

    function _usdgPool(address token) private view returns (address pool) {
        uint256 most;
        for (uint256 i = 0; i < 4; i++) {
            // Uniswap V3's fee tiers.
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
        // forge-lint: disable-next-line(unsafe-typecast)
        if (next < minimum) revert ThinOracle(pool, uint16(next), minimum);
        (bool okDecimals, uint256 decimals) = _readWord(token, abi.encodeWithSelector(0x313ce567)); // decimals()
        if (!okDecimals || decimals > etfFactory.MAX_TOKEN_DECIMALS()) revert BadQuote(token);
        uint256 scale = 10 ** decimals * USDG_UNIT_TO_18;
        (uint256 price, bool priced) = POOL_ORACLE.tryQuote(pool, scale, token, address(USDG));
        if (!priced || price == 0) (price, priced) = POOL_ORACLE.trySpotQuote(pool, scale, token, address(USDG));
        if (!priced || price == 0) revert BadPool(pool);
    }

    function _readWord(address target, bytes memory data) private view returns (bool ok, uint256 value) {
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    // ---------------------------------------------------------------- views ---

    function etfFactories() external view returns (address[] memory) {
        return _etfFactories;
    }

    function quoteThresholds(address token) external view returns (uint256[] memory) {
        return _widen(_quoteThresholds[token]);
    }

    function etfThresholds() external view returns (uint256[] memory) {
        return _widen(_etfThresholds);
    }

    function _widen(uint128[] storage list) private view returns (uint256[] memory out) {
        out = new uint256[](list.length);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = list[i];
        }
    }

    function quoteMinFirstBuy(address token) external view returns (uint256) {
        return _quotes[token].minFirstBuy;
    }

    function quotePool(address token) external view returns (address) {
        return _quotes[token].pool;
    }

    function isSupply(uint256 supply) public pure returns (bool) {
        return supply == SUPPLY_1M || supply == SUPPLY_10M || supply == SUPPLY_100M || supply == SUPPLY_500M || supply == SUPPLY_1B;
    }

    function quoteCount() external view returns (uint256) {
        return quoteList.length;
    }

    function isCurve(address curve) external view returns (bool) {
        return _curves[curve].createdAt != 0;
    }

    function curveInfo(address curve) external view returns (CurveInfo memory) {
        return _curves[curve];
    }

    function curveCount() external view returns (uint256) {
        return curves.length;
    }

    /// @notice A curve's PNG logo; empty when none.
    function logo(address curve) external view returns (bytes memory) {
        return readLogoCode(_curves[curve].logoPointer);
    }

    /// @notice `curve`'s profile; for a reserve-ETF curve, read on the ETF, but Discord.
    function profileOf(address curve) external view returns (Profile memory profile, uint256 updatedAt) {
        profile = _profiles[curve];
        updatedAt = _profileUpdatedAt[curve];
        address etf = _curves[curve].quote;
        if (etf == address(0) || !MaidMarianLaunchCurve(curve).etfQuote()) return (profile, updatedAt);
        uint256 etfAt;
        (profile.description, profile.x, profile.telegram, profile.website, etfAt) = MaidMarianEtfFactory(address(MaidMarianEtfV3(etf).FACTORY())).profileOf(etf);
        if (etfAt > updatedAt) updatedAt = etfAt;
    }
}
