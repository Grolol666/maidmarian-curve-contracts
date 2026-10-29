// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IUniversalRouter } from "./MaidMarianSevenMagnificent.sol";
import { poolTwapSqrtPrice, poolSpotSqrtPrice, poolValueAt, poolCardinalityNext } from "./MaidMarianPoolPrice.sol";
import { readWord, v4PoolId, v4SqrtPriceOf } from "./MaidMarianUniswapV5.sol";
import { IPoolManagerV4 } from "./MaidMarianLaunchCurve.sol";
import { MaidMarianLaunchCurveV5, BasketStock, curveV5CloneArgs, MAX_STOCKS } from "./MaidMarianLaunchCurveV5.sol";
import { MaidMarianLaunchHook, HOOK_BEFORE_INITIALIZE_FLAG, HOOK_ALL_FLAGS_MASK } from "./MaidMarianLaunchHook.sol";
import { checkTokenName, checkTokenSymbol, checkProfile, checkPngLogo, storeLogoAsCode, readLogoCode, BadLogo } from "./MaidMarianTokenChecks.sol";

/**
 * @title Maid Marian token launcher v5, "STOCKS are SEED"
 * @notice A token on a bonding curve whose reserve is a basket of stock tokens (2 to 10, owner-listed).
 * Buy in USDG: the curve buys the stocks at spot. Sell: it sells your share of them at spot.
 * It bonds when its stocks are worth the target at their 30 min TWAP: one token / stock V4 pool per stock.
 * Rules and reasons: launcher-v5.md.
 */
contract MaidMarianTokenLauncherV5 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------ constants ---

    uint256 public constant INITIAL_LAUNCH_FEE = 0.0005 ether;

    uint256 public constant INITIAL_BOND_PROTOCOL_BPS = 2500;

    uint256 public constant MIN_STOCKS = 2;

    uint256 public constant MIN_FIRST_BUY_WHOLE_USDG = 10;

    /// Raw USDG. The floor keeps the phantom over `supply >> 64`, so every reserve passes `curveFits`.
    uint256 public constant MIN_TARGET = 1e9;
    uint256 public constant MAX_TARGET = 1e15;

    uint256 public constant MAX_TARGET_CHOICES = 8;

    uint256 public constant MAX_CREATOR_TAX_BPS = 1000;

    /// 30 min at one observation a second, so `observe([1800, 0])` always answers.
    uint16 public constant MIN_OBSERVATION_CARDINALITY = 1801;

    uint256 public constant SUPPLY_1M = 1_000_000;
    uint256 public constant SUPPLY_10M = 10_000_000;
    uint256 public constant SUPPLY_100M = 100_000_000;
    uint256 public constant SUPPLY_500M = 500_000_000;
    uint256 public constant SUPPLY_1B = 1_000_000_000;

    uint256 private constant BPS = 10_000;

    // ---------------------------------------------------------------- types ---

    /// `pool` the V3 pool at `fee`; the V4 pool at `v4Fee` / `v4TickSpacing` / `v4Hooks`, spacing 0 when none.
    struct TokenInfo {
        address pool;
        uint24 fee;
        uint8 decimals;
        bool eligible;
        bool known;
        uint24 v4Fee;
        int24 v4TickSpacing;
        address v4Hooks;
    }

    struct Profile {
        string description;
        string x;
        string telegram;
        string website;
        string discord;
    }

    /// A launched curve has a creator.
    struct CurveInfo {
        address creator;
        address logoPointer;
    }

    /// `v4Mask` and `minTokensOut` are the first buy's.
    struct Launch {
        string name;
        string symbol;
        bytes logoPng;
        Profile profile;
        BasketStock[] stocks;
        uint256 target;
        uint16 creatorTaxBps;
        uint256 supply;
        uint256 firstBuy;
        uint16 v4Mask;
        uint256 minTokensOut;
        address[] snipeExempt;
    }

    // ----------------------------------------------------------- immutables ---

    IERC20 public immutable USDG;
    IUniversalRouter public immutable UNIVERSAL_ROUTER;
    IPoolManagerV4 public immutable POOL_MANAGER;
    address public immutable UNISWAP_V3_FACTORY;
    MaidMarianLaunchCurveV5 public immutable CURVE_IMPLEMENTATION;
    MaidMarianLaunchHook public immutable HOOK;

    /// Keeps a quote of one whole token from overflowing.
    uint256 public immutable MAX_TOKEN_DECIMALS;

    uint256 public immutable MIN_FIRST_BUY_USDG;

    // ---------------------------------------------------------------- state ---

    uint256 public launchFee;

    /// Copied into each curve at its launch.
    uint256 public bondProtocolBps;

    uint128[] private _targets;

    address[] public tokenList;
    mapping(address token => TokenInfo) private _tokens;

    address[] public curves;
    mapping(address curve => CurveInfo) private _curves;
    mapping(address curve => Profile) private _profiles;
    mapping(address curve => uint256) private _profileUpdatedAt;

    // --------------------------------------------------------------- events ---

    event CurveLaunched(
        address indexed curve,
        address indexed creator,
        address token,
        uint256 index,
        BasketStock[] stocks,
        uint256 target,
        uint256 creatorTaxBps,
        uint256 supply,
        uint256 bondProtocolBps,
        string name,
        string symbol,
        bytes logo,
        Profile profile
    );
    event ProfileSet(address indexed curve, address indexed creator, Profile profile);
    event LogoSet(address indexed curve, address indexed creator, bytes logo);
    event TokenAdded(address indexed token, address pool, uint8 decimals);
    event TokenRemoved(address indexed token);
    event TokenSourcesChanged(address indexed token, address oldPool, address pool);
    event TokenV4PoolChanged(address indexed token, uint24 fee, int24 tickSpacing, address hooks);
    event TargetsSet(uint256[] targets);
    event BondProtocolBpsChanged(uint256 previous, uint256 next);
    event LaunchFeeChanged(uint256 previous, uint256 next);
    event FeesWithdrawn(address indexed to, uint256 amount);

    // --------------------------------------------------------------- errors ---

    error ZeroAddress();
    error NoCode(address account);
    error WrongLaunchFee(uint256 required, uint256 sent);
    error BadToken(address token);
    error NoSource(address token);
    error BadPool(address pool);
    error BadV4Pool(address token, uint24 fee, int24 tickSpacing, address hooks);
    error ThinOracle(address pool, uint16 cardinalityNext, uint16 minimum);
    error AlreadyEligible(address token);
    error UnknownToken(address token);
    error NotEligible(address token);
    error DuplicateToken(address token);
    error BadStockCount(uint256 count);
    error BadBps(uint256 total);
    error BadTarget(uint256 target);
    error BadTargetCount(uint256 count);
    error TargetsNotIncreasing(uint256 index);
    error TargetNotOffered(uint256 target);
    error BadBondProtocolBps(uint256 bps);
    error BadSupply(uint256 supply);
    error BadCreatorTax(uint256 bps);
    error FirstBuyTooSmall(uint256 firstBuy, uint256 minimum);
    error NotCurve(address curve);
    error NotCreator(address curve, address caller);
    error NativeTransferFailed(address to, uint256 amount);
    error RenounceForbidden();
    error BadHookAddress(address hook);

    // ---------------------------------------------------------- constructor ---

    /// @param hookSalt Puts `HOOK` at an address whose permission bits are `beforeInitialize` alone.
    constructor(IERC20 usdg, IUniversalRouter router, address v3Factory, address owner_, bytes32 hookSalt) Ownable(owner_) {
        if (address(usdg) == address(0) || address(router) == address(0) || v3Factory == address(0)) revert ZeroAddress();
        if (address(usdg).code.length == 0) revert NoCode(address(usdg));
        if (address(router).code.length == 0) revert NoCode(address(router));
        if (v3Factory.code.length == 0) revert NoCode(v3Factory);
        (bool ok, uint256 usdgDecimals) = readWord(address(usdg), abi.encodeWithSelector(0x313ce567)); // decimals()
        if (!ok || usdgDecimals > 18) revert BadToken(address(usdg));
        (bool okManager, uint256 manager) = readWord(address(router), abi.encodeWithSelector(0xdc4c90d3)); // poolManager()
        // forge-lint: disable-next-line(unsafe-typecast)
        if (!okManager || manager > type(uint160).max || address(uint160(manager)).code.length == 0) revert NoCode(address(uint160(manager)));
        USDG = usdg;
        UNIVERSAL_ROUTER = router;
        // `manager <= type(uint160).max`, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        POOL_MANAGER = IPoolManagerV4(address(uint160(manager)));
        UNISWAP_V3_FACTORY = v3Factory;
        MAX_TOKEN_DECIMALS = 20 + usdgDecimals;
        MIN_FIRST_BUY_USDG = MIN_FIRST_BUY_WHOLE_USDG * 10 ** usdgDecimals;
        HOOK = new MaidMarianLaunchHook{ salt: hookSalt }(address(POOL_MANAGER));
        if (uint160(address(HOOK)) & HOOK_ALL_FLAGS_MASK != HOOK_BEFORE_INITIALIZE_FLAG) revert BadHookAddress(address(HOOK));
        CURVE_IMPLEMENTATION = new MaidMarianLaunchCurveV5(usdg, router, POOL_MANAGER, address(HOOK));
        launchFee = INITIAL_LAUNCH_FEE;
        emit LaunchFeeChanged(0, INITIAL_LAUNCH_FEE);
        bondProtocolBps = INITIAL_BOND_PROTOCOL_BPS;
        emit BondProtocolBpsChanged(0, INITIAL_BOND_PROTOCOL_BPS);
        uint256[] memory initial = new uint256[](6);
        (initial[0], initial[1], initial[2], initial[3], initial[4], initial[5]) = (5000, 8000, 15_000, 20_000, 25_000, 30_000);
        for (uint256 i = 0; i < 6; i++) {
            initial[i] *= 10 ** usdgDecimals;
            // forge-lint: disable-next-line(unsafe-typecast)
            _targets.push(uint128(initial[i]));
        }
        emit TargetsSet(initial);
    }

    // ---------------------------------------------------------------- owner ---

    /// @notice List `token` with its V3 token/USDG pool.
    function addToken(address token, address pool) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (token == address(USDG)) revert BadToken(token);
        TokenInfo storage t = _tokens[token];
        if (t.eligible) revert AlreadyEligible(token);
        if (token.code.length == 0) revert NoCode(token);
        (bool ok, uint256 decimals) = readWord(token, abi.encodeWithSelector(0x313ce567)); // decimals()
        if (!ok || decimals > MAX_TOKEN_DECIMALS) revert BadToken(token);
        uint24 fee = _checkPool(token, decimals, pool);
        if (!t.known) tokenList.push(token);
        // `decimals` is at most `MAX_TOKEN_DECIMALS`, 38 at most, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        (t.pool, t.fee, t.decimals, t.eligible, t.known) = (pool, fee, uint8(decimals), true, true);
        emit TokenAdded(token, pool, t.decimals);
    }

    /// @notice Stop new curves choosing `token`; curves holding it keep it.
    function removeToken(address token) external onlyOwner {
        TokenInfo storage t = _tokens[token];
        if (!t.eligible) revert UnknownToken(token);
        t.eligible = false;
        emit TokenRemoved(token);
    }

    /// @notice Replace `token`'s V3 pool. Danger: every curve holding it trades and values it there.
    function setTokenSources(address token, address pool) external onlyOwner {
        TokenInfo storage t = _tokens[token];
        if (!t.known) revert UnknownToken(token);
        uint24 fee = _checkPool(token, t.decimals, pool);
        emit TokenSourcesChanged(token, t.pool, pool);
        (t.pool, t.fee) = (pool, fee);
    }

    /// @notice Set, or clear with `(0, 0, 0)`, `token`'s V4 pool; the TWAP stays the V3 pool's.
    function setTokenV4Pool(address token, uint24 fee, int24 tickSpacing, address hooks) external onlyOwner {
        TokenInfo storage t = _tokens[token];
        if (!t.known) revert UnknownToken(token);
        if ((fee != 0 || tickSpacing != 0 || hooks != address(0)) && _v4SqrtPrice(token, fee, tickSpacing, hooks) == 0) revert BadV4Pool(token, fee, tickSpacing, hooks);
        (t.v4Fee, t.v4TickSpacing, t.v4Hooks) = (fee, tickSpacing, hooks);
        emit TokenV4PoolChanged(token, fee, tickSpacing, hooks);
    }

    /// @notice The bond targets a launch picks from, raw USDG.
    function setTargets(uint256[] calldata values) external onlyOwner {
        uint256 n = values.length;
        if (n == 0 || n > MAX_TARGET_CHOICES) revert BadTargetCount(n);
        while (_targets.length > 0) _targets.pop();
        for (uint256 i = 0; i < n; i++) {
            uint256 v = values[i];
            if (v < MIN_TARGET || v > MAX_TARGET) revert BadTarget(v);
            if (i > 0 && v <= values[i - 1]) revert TargetsNotIncreasing(i);
            // forge-lint: disable-next-line(unsafe-typecast)
            _targets.push(uint128(v));
        }
        emit TargetsSet(values);
    }

    /// @notice The protocol's share at the bond, for future launches.
    function setBondProtocolBps(uint256 bps) external onlyOwner {
        if (bps >= BPS) revert BadBondProtocolBps(bps);
        emit BondProtocolBpsChanged(bondProtocolBps, bps);
        bondProtocolBps = bps;
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

    /// @notice Always reverts: ownership can be transferred, never renounced.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceForbidden();
    }

    // ---------------------------------------------------------------- doors ---

    /// @notice Launch a token and buy `firstBuy` USDG of it for the caller, its creator. Send exactly `launchFee()`.
    function launch(Launch calldata l) external payable nonReentrant returns (MaidMarianLaunchCurveV5 curve) {
        uint256 fee = launchFee;
        if (msg.value != fee) revert WrongLaunchFee(fee, msg.value);
        checkPngLogo(l.logoPng);
        checkTokenName(bytes(l.name));
        checkTokenSymbol(bytes(l.symbol));
        checkProfile(l.profile.description, l.profile.x, l.profile.telegram, l.profile.website, l.profile.discord);
        if (l.creatorTaxBps > MAX_CREATOR_TAX_BPS) revert BadCreatorTax(l.creatorTaxBps);
        if (l.firstBuy < MIN_FIRST_BUY_USDG) revert FirstBuyTooSmall(l.firstBuy, MIN_FIRST_BUY_USDG);
        _checkStocks(l.stocks);
        curve = _newCurve(l);
        address pointer = l.logoPng.length == 0 ? address(0) : storeLogoAsCode(l.logoPng);
        _curves[address(curve)] = CurveInfo({ creator: msg.sender, logoPointer: pointer });
        curves.push(address(curve));
        Profile calldata p = l.profile;
        if (bytes(p.description).length + bytes(p.x).length + bytes(p.telegram).length + bytes(p.website).length + bytes(p.discord).length > 0) _storeProfile(address(curve), p);
        _emitLaunched(curve, l);
        _buy(address(curve), l.firstBuy, l.v4Mask, l.minTokensOut);
    }

    function _emitLaunched(MaidMarianLaunchCurveV5 curve, Launch calldata l) private {
        address token = curve.token();
        uint256 target = curve.target();
        uint256 supply = curve.supply();
        uint256 share = curve.bondShareBps();
        emit CurveLaunched(address(curve), msg.sender, token, curves.length - 1, l.stocks, target, l.creatorTaxBps, supply, share, l.name, l.symbol, l.logoPng, l.profile);
    }

    function _newCurve(Launch calldata l) private returns (MaidMarianLaunchCurveV5 curve) {
        uint128 picked = _pickTarget(l.target);
        uint96 raw = _rawSupply(l.supply);
        curve = MaidMarianLaunchCurveV5(Clones.cloneWithImmutableArgs(address(CURVE_IMPLEMENTATION), curveV5CloneArgs(msg.sender, picked, l.creatorTaxBps, raw, l.stocks)));
        // forge-lint: disable-next-line(unsafe-typecast)
        curve.initialize(l.snipeExempt, l.name, l.symbol, uint16(bondProtocolBps));
    }

    /// @notice Buy on `curve` with one approve of USDG here.
    function buy(address curve, uint256 usdgIn, uint16 v4Mask, uint256 minTokensOut) external nonReentrant returns (uint256 tokensOut) {
        if (_curves[curve].creator == address(0)) revert NotCurve(curve);
        tokensOut = _buy(curve, usdgIn, v4Mask, minTokensOut);
    }

    /// @notice Sell on `curve` with one approve of the token here.
    function sell(address curve, uint256 tokensIn, uint16 v4Mask, uint256 minUsdgOut) external nonReentrant returns (uint256 usdgOut) {
        if (_curves[curve].creator == address(0)) revert NotCurve(curve);
        IERC20 token = IERC20(MaidMarianLaunchCurveV5(curve).token());
        token.safeTransferFrom(msg.sender, address(this), tokensIn);
        token.forceApprove(curve, tokensIn);
        usdgOut = MaidMarianLaunchCurveV5(curve).sellFor(msg.sender, tokensIn, v4Mask, minUsdgOut);
    }

    function _buy(address curve, uint256 usdgIn, uint16 v4Mask, uint256 minTokensOut) private returns (uint256 tokensOut) {
        USDG.safeTransferFrom(msg.sender, address(this), usdgIn);
        USDG.forceApprove(curve, usdgIn);
        tokensOut = MaidMarianLaunchCurveV5(curve).buyFor(msg.sender, usdgIn, v4Mask, minTokensOut);
    }

    /// @notice Overwrite `curve`'s whole profile, its creator only.
    function setProfile(address curve, Profile calldata profile) external {
        _curveOf(curve);
        checkProfile(profile.description, profile.x, profile.telegram, profile.website, profile.discord);
        _storeProfile(curve, profile);
        emit ProfileSet(curve, msg.sender, profile);
    }

    /// @notice Replace `curve`'s logo, its creator only.
    function setLogo(address curve, bytes calldata png) external {
        CurveInfo storage info = _curveOf(curve);
        if (png.length == 0) revert BadLogo();
        checkPngLogo(png);
        info.logoPointer = storeLogoAsCode(png);
        emit LogoSet(curve, msg.sender, png);
    }

    // ------------------------------------------------------------- internal ---

    function _checkStocks(BasketStock[] calldata stocks_) private view {
        uint256 n = stocks_.length;
        if (n < MIN_STOCKS || n > MAX_STOCKS) revert BadStockCount(n);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            address token = stocks_[i].token;
            if (stocks_[i].bps == 0) revert BadBps(0);
            for (uint256 j = 0; j < i; j++) {
                if (stocks_[j].token == token) revert DuplicateToken(token);
            }
            if (!_tokens[token].eligible) revert NotEligible(token);
            total += stocks_[i].bps;
        }
        if (total != BPS) revert BadBps(total);
    }

    function _pickTarget(uint256 value) private view returns (uint128) {
        uint256 n = _targets.length;
        for (uint256 i = 0; i < n; i++) {
            uint128 v = _targets[i];
            if (v == value) return v;
        }
        revert TargetNotOffered(value);
    }

    function _curveOf(address curve) private view returns (CurveInfo storage info) {
        info = _curves[curve];
        address creator = info.creator;
        if (creator == address(0)) revert NotCurve(curve);
        if (creator != msg.sender) revert NotCreator(curve, msg.sender);
    }

    function _storeProfile(address curve, Profile calldata profile) private {
        _profiles[curve] = profile;
        _profileUpdatedAt[curve] = block.timestamp;
    }

    function _rawSupply(uint256 supply) private pure returns (uint96) {
        if (!isSupply(supply)) revert BadSupply(supply);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(supply * 1e18);
    }

    /// The V3 factory's own pool of the pair, 1 801 observations, a price above 0. Returns its fee.
    function _checkPool(address token, uint256 decimals, address pool) private view returns (uint24) {
        if (pool == address(0)) revert NoSource(token);
        if (pool.code.length == 0) revert BadPool(pool);
        (bool okFee, uint256 fee) = readWord(pool, abi.encodeWithSelector(0xddca3f43)); // fee()
        if (!okFee || fee > type(uint24).max) revert BadPool(pool);
        // forge-lint: disable-next-line(unsafe-typecast)
        (bool known, uint256 named) = readWord(UNISWAP_V3_FACTORY, abi.encodeWithSelector(0x1698ee82, token, address(USDG), uint24(fee))); // getPool(address,address,uint24)
        if (!known || named != uint256(uint160(pool))) revert BadPool(pool);
        (bool ok0, uint256 t0) = readWord(pool, abi.encodeWithSelector(0x0dfe1681)); // token0()
        (bool ok1, uint256 t1) = readWord(pool, abi.encodeWithSelector(0xd21220a7)); // token1()
        (uint256 a, uint256 u) = (uint256(uint160(token)), uint256(uint160(address(USDG))));
        if (!ok0 || !ok1 || !((t0 == a && t1 == u) || (t0 == u && t1 == a))) revert BadPool(pool);
        (bool okSlot0, uint16 next) = poolCardinalityNext(pool);
        if (!okSlot0) revert BadPool(pool);
        if (next < MIN_OBSERVATION_CARDINALITY) revert ThinOracle(pool, next, MIN_OBSERVATION_CARDINALITY);
        // A pool under 30 min old has no TWAP yet: its spot. Priced as `twapPriceUsdg`: one whole token.
        uint256 whole = 10 ** decimals;
        uint160 price = poolTwapSqrtPrice(pool);
        if (price == 0 || poolValueAt(price, whole, token, address(USDG)) == 0) price = poolSpotSqrtPrice(pool);
        if (price == 0 || poolValueAt(price, whole, token, address(USDG)) == 0) revert BadPool(pool);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(fee);
    }

    function _v4SqrtPrice(address token, uint24 fee, int24 tickSpacing, address hooks) private view returns (uint160) {
        (address c0, address c1) = token < address(USDG) ? (token, address(USDG)) : (address(USDG), token);
        return v4SqrtPriceOf(address(POOL_MANAGER), v4PoolId(IPoolManagerV4.PoolKey({ currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: hooks })));
    }

    // ---------------------------------------------------------------- views ---

    /// @notice The pools every curve swaps `token` through against USDG.
    function poolsOf(address token) external view returns (address pool, uint24 fee, uint24 v4Fee, int24 v4TickSpacing, address v4Hooks) {
        TokenInfo storage t = _tokens[token];
        return (t.pool, t.fee, t.v4Fee, t.v4TickSpacing, t.v4Hooks);
    }

    function tokenInfo(address token) external view returns (TokenInfo memory) {
        return _tokens[token];
    }

    function isEligible(address token) external view returns (bool) {
        return _tokens[token].eligible;
    }

    function tokenCount() external view returns (uint256) {
        return tokenList.length;
    }

    /// @notice One whole `token` at its V3 pool's 30 min TWAP, raw USDG; `ok` false when it has none.
    function twapPriceUsdg(address token) external view returns (uint256 price, bool ok) {
        TokenInfo storage t = _tokens[token];
        if (!t.known) return (0, false);
        uint160 sqrtPrice = poolTwapSqrtPrice(t.pool);
        if (sqrtPrice == 0) return (0, false);
        return (poolValueAt(sqrtPrice, 10 ** uint256(t.decimals), token, address(USDG)), true);
    }

    function targets() external view returns (uint256[] memory out) {
        out = new uint256[](_targets.length);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = _targets[i];
        }
    }

    function isSupply(uint256 supply) public pure returns (bool) {
        return supply == SUPPLY_1M || supply == SUPPLY_10M || supply == SUPPLY_100M || supply == SUPPLY_500M || supply == SUPPLY_1B;
    }

    function isCurve(address curve) external view returns (bool) {
        return _curves[curve].creator != address(0);
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

    function profileOf(address curve) external view returns (Profile memory profile, uint256 updatedAt) {
        return (_profiles[curve], _profileUpdatedAt[curve]);
    }
}
