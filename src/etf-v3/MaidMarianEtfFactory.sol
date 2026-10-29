// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IUniversalRouter } from "./MaidMarianSevenMagnificent.sol";
import { MaidMarianBagPoolOracle, IUniswapV3PoolSlot0 } from "./MaidMarianBagPoolOracle.sol";
import {
    MaidMarianEtfV3,
    etfV3ParamBounds,
    etfV3CloneArgs,
    SOURCE_NONE,
    SOURCE_POOL,
    SOURCE_NAV,
    SOURCE_SPOT,
    ETF_V3_CREATOR_MANAGEMENT_FEE_BPS,
    ETF_V3_PROTOCOL_MANAGEMENT_FEE_BPS,
    ETF_V3_TOLERANCE_BPS,
    ETF_V3_PROTOCOL_CUT_BPS,
    ETF_V3_PROTOCOL_MIN_ENTRY_BPS
} from "./MaidMarianEtfV3.sol";

/**
 * @title Maid Marian ETF factory
 * @notice Anyone creates an ETF (`createEtf`) for `creationFee()`: a name, a symbol, a PNG logo and 1 to
 * `MAX_LEGS` legs in bps among the tokens the owner lists. A listed factory ETF can be a leg (`MAX_DEPTH`).
 * Each ETF has a profile (description, X, Telegram, website), given at creation and edited by its
 * creator (`setProfile`), every field on an ASCII allowlist.
 * The factory is the ETFs' price helper, in USDG (`getPriceUsdg`): an ETF's NAV, else its pool's 30 min
 * TWAP, else the pool's spot. Rebalances read `getTradablePriceUsdg`, the same without any spot; mint and
 * redeem read no price.
 * The owner lists tokens with their V3 pool, may give each a hookless V4 pool, sets and withdraws the
 * creation fee, and receives the protocol's fees. Every swap of every ETF runs through one of these
 * pools (`poolsOf`). He has nothing over any ETF's holdings. Ownership is never renounced.
 * Danger: the owner chooses each token's pools, so where every swap of every ETF executes and the price
 * every rebalance trades at (`setTokenSources`, `setTokenV4Pool`). A caller is protected by his own
 * `amountOutMin`, the fund by the rebalance's floor, the holders by the in-kind formula.
 * Every ETF is an EIP-1167 clone of `ETF_IMPLEMENTATION`, deployed by the constructor, its legs,
 * parameters, name and symbol appended to the clone's code; `createEtf` creates and initializes it in
 * one transaction.
 */
contract MaidMarianEtfFactory is Ownable {
    // ------------------------------------------------------------ constants ---

    uint256 public constant INITIAL_CREATION_FEE = 0.01 ether;

    uint256 public constant MAX_LEGS = 10;

    /// Deepest ETF of ETFs: a token is depth 0, an ETF one more than its deepest leg.
    uint256 public constant MAX_DEPTH = 2;

    uint256 public constant MAX_LOGO_BYTES = 16_384;

    /// Largest logo side, in pixels (PNG IHDR).
    uint256 public constant MAX_LOGO_SIDE = 256;

    /// Least `observationCardinalityNext` a listed pool must have: 1 801 observations = 30 min at one per
    /// second, so `observe([1800, 0])` always answers; with fewer, swaps overwrite the window and the price
    /// falls back to the spot. Anyone can raise it: `increaseObservationCardinalityNext(1801)` on the pool.
    uint16 public constant MIN_OBSERVATION_CARDINALITY = 1801;

    /// Rules fixed for every ETF: the same constants as `MaidMarianEtfV3`'s, readable before any ETF exists.
    uint256 public constant CREATOR_MANAGEMENT_FEE_BPS = ETF_V3_CREATOR_MANAGEMENT_FEE_BPS;
    uint256 public constant PROTOCOL_MANAGEMENT_FEE_BPS = ETF_V3_PROTOCOL_MANAGEMENT_FEE_BPS;
    uint256 public constant TOLERANCE_BPS = ETF_V3_TOLERANCE_BPS;
    uint256 public constant PROTOCOL_CUT_BPS = ETF_V3_PROTOCOL_CUT_BPS;
    uint256 public constant PROTOCOL_MIN_ENTRY_BPS = ETF_V3_PROTOCOL_MIN_ENTRY_BPS;

    /// Longest name: `[A-Za-z0-9]`, space, `-`, `.`, `&`, `'`; no space first, last or doubled.
    uint256 public constant MAX_NAME_BYTES = 64;

    /// Longest symbol: `[A-Za-z0-9]` only.
    uint256 public constant MAX_SYMBOL_BYTES = 11;

    uint256 public constant MAX_DESCRIPTION_BYTES = 280;
    uint256 public constant MAX_WEBSITE_BYTES = 100;

    uint256 private constant BPS = 10_000;

    // ---------------------------------------------------------------- types ---

    struct LegSpec {
        address token;
        uint16 bps;
    }

    /// A listed token. `pool` its V3 pool, at `fee`; `v4Fee` / `v4TickSpacing` its hookless V4 pool,
    /// spacing 0 when none. `known`: ever added; a removed token keeps its pools for the ETFs that hold it.
    struct TokenInfo {
        address pool;
        uint24 fee;
        uint8 decimals;
        bool eligible;
        bool known;
        uint24 v4Fee;
        int24 v4TickSpacing;
    }

    /// An ETF's profile; an empty string is an empty field. Each byte on an ASCII allowlist:
    ///  - `description`: at most 280 bytes, 0x20 - 0x7E;
    ///  - `x`: `https://x.com/` and 1 - 15 of `[A-Za-z0-9_]`, nothing after;
    ///  - `telegram`: `https://t.me/` and 5 - 32 of `[A-Za-z0-9_]`, nothing after;
    ///  - `website`: `https://`, at most 100 bytes, each byte `[A-Za-z0-9]` or one of `-._~/:?=&%#`,
    ///    a host of at least one byte before the first `/`, `?` or `#`.
    struct Profile {
        string description;
        string x;
        string telegram;
        string website;
    }

    struct EtfInfo {
        address creator;
        uint8 depth;
        address logoPointer;
        uint64 createdAt;
    }

    // ----------------------------------------------------------- immutables ---

    /// The quote currency, every pool's other side.
    IERC20 public immutable USDG;

    IUniversalRouter public immutable UNIVERSAL_ROUTER;

    /// The router's own V4 `poolManager()`, where a V4 pool is checked.
    address public immutable POOL_MANAGER;

    /// Every listed pool must be this factory's `getPool`.
    address public immutable UNISWAP_V3_FACTORY;

    /// The TWAP reader, deployed by the constructor.
    MaidMarianBagPoolOracle public immutable POOL_ORACLE;

    /// What every ETF clones, deployed by the constructor; locked, it holds nothing and runs no door.
    MaidMarianEtfV3 public immutable ETF_IMPLEMENTATION;

    /// `10 ** (18 - USDG decimals)`.
    uint256 private immutable USDG_UNIT_TO_18;

    /// Most decimals a listed token may have, 20 + USDG's (26 for 6): a price quotes
    /// `10 ** (decimals + 18 - USDG decimals)` raw units, which must stay at or under 10^38 so that times
    /// the highest ratio a Uniswap price can carry (under 2^128) it fits 256 bits and the quote cannot revert.
    uint256 public immutable MAX_TOKEN_DECIMALS;

    // ---------------------------------------------------------------- state ---

    /// What `createEtf` must be sent, exactly: a change makes a pending creation revert, never overpay.
    uint256 public creationFee;

    /// Every token ever added, removed ones included.
    address[] public tokenList;

    mapping(address token => TokenInfo) private _tokens;

    address[] public etfs;

    mapping(address etf => EtfInfo) private _etfs;
    mapping(address etf => LegSpec[]) private _legsOf;
    mapping(address etf => Profile) private _profiles;
    mapping(address etf => uint256) private _profileUpdatedAt;

    // --------------------------------------------------------------- events ---

    event TokenAdded(address indexed token, address pool, uint8 decimals);
    event TokenRemoved(address indexed token);
    event TokenSourcesChanged(address indexed token, address oldPool, address pool);
    /// `tickSpacing` 0: the V4 pool cleared.
    event TokenV4PoolChanged(address indexed token, uint24 fee, int24 tickSpacing);
    /// Everything needed to list an ETF without reading it.
    event EtfCreated(address indexed etf, address indexed creator, uint256 index, string name, string symbol, LegSpec[] legs, MaidMarianEtfV3.Params params, uint8 depth, bytes logo, Profile profile);
    /// A profile edited after creation.
    event ProfileSet(address indexed etf, address indexed creator, string description, string x, string telegram, string website);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event CreationFeeChanged(uint256 previous, uint256 next);

    // --------------------------------------------------------------- errors ---

    error ZeroAddress();
    error NoCode(address account);
    error NoSource(address token);
    error BadToken(address token);
    error BadPool(address pool);
    error BadV4Pool(address token, uint24 fee, int24 tickSpacing);
    error ThinOracle(address pool, uint16 cardinalityNext, uint16 minimum);
    error AlreadyEligible(address token);
    error UnknownToken(address token);
    error WrongCreationFee(uint256 required, uint256 sent);
    error BadName();
    error BadSymbol();
    error BadLegCount(uint256 count);
    error NotEligible(address token);
    error DuplicateToken(address token);
    error BadBps(uint256 total);
    error TooDeep(uint256 depth);
    error BadLogo();
    error NativeTransferFailed(address to, uint256 amount);
    error RenounceForbidden();
    error NotFactoryEtf(address etf);
    error NotCreator(address etf, address caller);
    error BadDescription();
    error BadX();
    error BadTelegram();
    error BadWebsite();

    // ---------------------------------------------------------- constructor ---

    /// @dev USDG, the router, its `poolManager()` and the V3 factory must have code; USDG decimals <= 18.
    constructor(IERC20 usdg, IUniversalRouter router, address v3Factory, address owner_) Ownable(owner_) {
        if (address(usdg) == address(0) || address(router) == address(0) || v3Factory == address(0)) revert ZeroAddress();
        if (address(usdg).code.length == 0) revert NoCode(address(usdg));
        if (address(router).code.length == 0) revert NoCode(address(router));
        if (v3Factory.code.length == 0) revert NoCode(v3Factory);
        (bool ok, uint256 usdgDecimals) = _readWord(address(usdg), abi.encodeWithSelector(0x313ce567)); // decimals()
        if (!ok || usdgDecimals > 18) revert BadToken(address(usdg));
        (bool okManager, uint256 manager) = _readWord(address(router), abi.encodeWithSelector(0xdc4c90d3)); // poolManager()
        // The cast is read only once `manager <= type(uint160).max` held; the error's copy only names it.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (!okManager || manager > type(uint160).max || address(uint160(manager)).code.length == 0) revert NoCode(address(uint160(manager)));
        USDG = usdg;
        UNIVERSAL_ROUTER = router;
        // `manager <= type(uint160).max`, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        POOL_MANAGER = address(uint160(manager));
        UNISWAP_V3_FACTORY = v3Factory;
        POOL_ORACLE = new MaidMarianBagPoolOracle();
        ETF_IMPLEMENTATION = new MaidMarianEtfV3(usdg, router);
        USDG_UNIT_TO_18 = 10 ** (18 - usdgDecimals);
        MAX_TOKEN_DECIMALS = 20 + usdgDecimals;
        creationFee = INITIAL_CREATION_FEE;
        emit CreationFeeChanged(0, INITIAL_CREATION_FEE);
    }

    // ---------------------------------------------------------------- owner ---

    /// @notice List `token` for new ETFs, with its Uniswap V3 token/USDG pool (required).
    /// @dev The pool must be the V3 factory's own, price above 0, and keep at least 1 801 observations
    /// (`ThinOracle`). A factory ETF is listed the same way; its new pool prices at spot until 30 min old.
    function addToken(address token, address pool) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (token == address(USDG)) revert BadToken(token);
        TokenInfo storage t = _tokens[token];
        if (t.eligible) revert AlreadyEligible(token);
        if (token.code.length == 0) revert NoCode(token);
        (bool ok, uint256 decimals) = _readWord(token, abi.encodeWithSelector(0x313ce567)); // decimals()
        if (!ok || decimals > MAX_TOKEN_DECIMALS) revert BadToken(token);
        uint24 fee = _checkPool(token, decimals, pool);
        if (!t.known) tokenList.push(token);
        // `decimals` is at most `MAX_TOKEN_DECIMALS`, 38 at most, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        (t.pool, t.fee, t.decimals, t.eligible, t.known) = (pool, fee, uint8(decimals), true, true);
        emit TokenAdded(token, pool, t.decimals);
    }

    /// @notice Stop new ETFs choosing `token`. ETFs holding it keep it, and its pool.
    function removeToken(address token) external onlyOwner {
        TokenInfo storage t = _tokens[token];
        if (!t.eligible) revert UnknownToken(token);
        t.eligible = false;
        emit TokenRemoved(token);
    }

    /// @notice Replace `token`'s V3 pool, with `addToken`'s checks, at once.
    /// @dev Danger: every ETF holding the token rebalances at this pool's price and swaps through it.
    function setTokenSources(address token, address pool) external onlyOwner {
        TokenInfo storage t = _tokens[token];
        if (!t.known) revert UnknownToken(token);
        uint24 fee = _checkPool(token, t.decimals, pool);
        emit TokenSourcesChanged(token, t.pool, pool);
        (t.pool, t.fee) = (pool, fee);
    }

    /// @notice Give `token` the hookless V4 pool `(token and USDG sorted, fee, tickSpacing, hooks 0)`,
    /// or clear it with `(0, 0)`. Routes may then swap through it; prices still come from the V3 pool.
    /// @dev The pool must be initialised on `POOL_MANAGER` (price above 0). A hooked pool is never this key.
    function setTokenV4Pool(address token, uint24 fee, int24 tickSpacing) external onlyOwner {
        TokenInfo storage t = _tokens[token];
        if (!t.known) revert UnknownToken(token);
        if ((fee != 0 || tickSpacing != 0) && _v4SqrtPrice(token, fee, tickSpacing) == 0) revert BadV4Pool(token, fee, tickSpacing);
        (t.v4Fee, t.v4TickSpacing) = (fee, tickSpacing);
        emit TokenV4PoolChanged(token, fee, tickSpacing);
    }

    /// @notice Send the collected creation fees to `to`. Pulled, so a creation never calls the owner.
    function withdrawFees(address payable to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = address(this).balance;
        if (amount > 0) {
            (bool ok,) = to.call{ value: amount }("");
            if (!ok) revert NativeTransferFailed(to, amount);
        }
        emit FeesWithdrawn(to, amount);
    }

    function setCreationFee(uint256 fee) external onlyOwner {
        emit CreationFeeChanged(creationFee, fee);
        creationFee = fee;
    }

    /// @notice Always reverts: ownership can be transferred, never renounced.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceForbidden();
    }

    // --------------------------------------------------------------- create ---

    /**
     * @notice Create an ETF; the caller is its creator and first `feeRecipient`. Send exactly `creationFee()`.
     * @param name_ 1 to 64 bytes: `[A-Za-z0-9]`, space, `-`, `.`, `&`, `'`; no space first, last or doubled.
     * @param symbol_ 1 to 11 bytes of `[A-Za-z0-9]`. Not unique: the ETF's address is what identifies it.
     * @param logoPng Empty, or a PNG of at most 16 KiB and 256 x 256 px.
     * @param legs_ 1 to 10 eligible tokens, no duplicate, bps above 0 summing to 10 000, depth at most 2.
     * @param p Checked by the ETF against `paramBounds()`.
     * @param profile Every field optional, checked as `Profile` says; stored when one is set.
     */
    function createEtf(string calldata name_, string calldata symbol_, bytes calldata logoPng, LegSpec[] calldata legs_, MaidMarianEtfV3.Params calldata p, Profile calldata profile)
        external
        payable
        returns (MaidMarianEtfV3 etf)
    {
        uint256 fee = creationFee;
        if (msg.value != fee) revert WrongCreationFee(fee, msg.value);
        _checkName(bytes(name_));
        _checkSymbol(bytes(symbol_));
        _checkPng(logoPng);
        _checkProfile(profile.description, profile.x, profile.telegram, profile.website);
        (MaidMarianEtfV3.LegInit[] memory inits, uint8 depth) = _legInits(legs_);

        // Not the deterministic form: the address is returned and in `EtfCreated`, and a salt would only
        // add a collision to rule out.
        etf = MaidMarianEtfV3(Clones.cloneWithImmutableArgs(address(ETF_IMPLEMENTATION), etfV3CloneArgs(name_, symbol_, inits, p)));
        etf.initialize(msg.sender);
        address pointer = logoPng.length == 0 ? address(0) : _storeLogo(logoPng);
        _etfs[address(etf)] = EtfInfo({ creator: msg.sender, depth: depth, logoPointer: pointer, createdAt: uint64(block.timestamp) });
        for (uint256 i = 0; i < legs_.length; i++) {
            _legsOf[address(etf)].push(legs_[i]);
        }
        etfs.push(address(etf));
        if (bytes(profile.description).length + bytes(profile.x).length + bytes(profile.telegram).length + bytes(profile.website).length > 0) {
            _storeProfile(address(etf), profile.description, profile.x, profile.telegram, profile.website);
        }
        emit EtfCreated(address(etf), msg.sender, etfs.length - 1, name_, symbol_, legs_, p, depth, logoPng, profile);
    }

    /// @notice Overwrite `etf`'s whole profile; an empty string clears a field. Only its creator, read on
    /// the ETF (`creator()`), so the profile moves with the role (`setCreator`).
    function setProfile(address etf, string calldata description, string calldata x, string calldata telegram, string calldata website) external {
        if (_etfs[etf].createdAt == 0) revert NotFactoryEtf(etf);
        if (MaidMarianEtfV3(etf).creator() != msg.sender) revert NotCreator(etf, msg.sender);
        _checkProfile(description, x, telegram, website);
        _storeProfile(etf, description, x, telegram, website);
        emit ProfileSet(etf, msg.sender, description, x, telegram, website);
    }

    function _storeProfile(address etf, string calldata description, string calldata x, string calldata telegram, string calldata website) private {
        Profile storage s = _profiles[etf];
        (s.description, s.x, s.telegram, s.website) = (description, x, telegram, website);
        _profileUpdatedAt[etf] = block.timestamp;
    }

    /// The legs for the ETF's clone arguments, and its depth: one more than its deepest leg.
    function _legInits(LegSpec[] calldata legs_) private view returns (MaidMarianEtfV3.LegInit[] memory inits, uint8 depth) {
        uint256 n = legs_.length;
        if (n == 0 || n > MAX_LEGS) revert BadLegCount(n);
        inits = new MaidMarianEtfV3.LegInit[](n);
        uint256 total;
        depth = 1;
        for (uint256 i = 0; i < n; i++) {
            address token = legs_[i].token;
            if (legs_[i].bps == 0) revert BadBps(0);
            for (uint256 j = 0; j < i; j++) {
                if (legs_[j].token == token) revert DuplicateToken(token);
            }
            TokenInfo memory t = _tokens[token];
            if (!t.eligible) revert NotEligible(token);
            EtfInfo memory e = _etfs[token];
            if (e.createdAt != 0 && e.depth + 1 > depth) depth = e.depth + 1;
            inits[i] = MaidMarianEtfV3.LegInit({ token: token, bps: legs_[i].bps, decimals: t.decimals });
            total += legs_[i].bps;
        }
        if (total != BPS) revert BadBps(total);
        if (depth > MAX_DEPTH) revert TooDeep(depth);
    }

    // ---------------------------------------------------------------- price ---

    /// @notice `token`'s price in USDG per whole token, 18 decimals, and its source: a factory ETF's NAV,
    /// else its pool's 30 min TWAP, else the pool's spot, else `(0, SOURCE_NONE)`. Never reverts.
    /// @dev The spot can be moved within one transaction. `uiMultiplier()` is not applied: pools trade raw units.
    function getPriceUsdg(address token) external view returns (uint256 price, uint8 source) {
        return _price(token, false);
    }

    /// @notice `getPriceUsdg` without any spot, what a rebalance trades at: an ETF's NAV only if every leg
    /// has such a price, else its pool's TWAP; else `(0, SOURCE_NONE)`.
    function getTradablePriceUsdg(address token) external view returns (uint256 price, uint8 source) {
        return _price(token, true);
    }

    /// `tradable`: no spot, here or in any NAV below.
    function _price(address token, bool tradable) private view returns (uint256 price, uint8 source) {
        if (_etfs[token].createdAt != 0) {
            (price, source) = _navPrice(token, tradable);
            if (source != SOURCE_NONE) return (price, source);
        }
        TokenInfo memory t = _tokens[token];
        // A known token always has a pool: `addToken` and `setTokenSources` require one.
        if (!t.known) return (0, SOURCE_NONE);
        uint256 unit = 10 ** uint256(t.decimals);
        // Quoting `scale = 10 ** (decimals + 18 - USDG decimals)` raw units gives one whole token's price in 18 decimals.
        uint256 scale = unit * USDG_UNIT_TO_18;
        (uint256 quote, bool ok) = POOL_ORACLE.tryQuote(t.pool, scale, token, address(USDG));
        if (ok && quote > 0) return (quote, SOURCE_POOL);
        if (tradable) return (0, SOURCE_NONE);
        (quote, ok) = POOL_ORACLE.trySpotQuote(t.pool, scale, token, address(USDG));
        if (ok && quote > 0) return (quote, SOURCE_SPOT);
        return (0, SOURCE_NONE);
    }

    /// An ETF's NAV per whole share, 18 decimals, over its supply once its management fee is minted
    /// (`accruedSupply()`); no price if a read fails, that supply is 0, a leg is unpriced, or the ETF is
    /// inside one of its doors (`entered()`), where shares and holdings move apart.
    function _navPrice(address etf, bool tradable) private view returns (uint256, uint8) {
        (bool ok, uint256 busy) = _readWord(etf, abi.encodeWithSelector(MaidMarianEtfV3.entered.selector));
        if (!ok || busy != 0) return (0, SOURCE_NONE);
        uint256 supply;
        (ok, supply) = _readWord(etf, abi.encodeWithSelector(MaidMarianEtfV3.accruedSupply.selector));
        if (!ok || supply == 0) return (0, SOURCE_NONE);
        uint256 usdgHeld;
        (ok, usdgHeld) = _readWord(address(USDG), abi.encodeWithSelector(0x70a08231, etf)); // balanceOf(address)
        if (!ok) return (0, SOURCE_NONE);
        uint256 value = usdgHeld * USDG_UNIT_TO_18;
        LegSpec[] storage l = _legsOf[etf];
        for (uint256 i = 0; i < l.length; i++) {
            address token = l[i].token;
            (uint256 price, uint8 source) = _price(token, tradable);
            if (source == SOURCE_NONE) return (0, SOURCE_NONE);
            uint256 held;
            (ok, held) = _readWord(token, abi.encodeWithSelector(0x70a08231, etf));
            if (!ok) return (0, SOURCE_NONE);
            // Every leg was listed at creation, so its decimals are known.
            value += Math.mulDiv(held, price, 10 ** uint256(_tokens[token].decimals));
        }
        return (Math.mulDiv(value, 1e18, supply), SOURCE_NAV);
    }

    // ---------------------------------------------------------------- views ---

    /// @notice A token's registration; all zero for a token never added.
    function tokenInfo(address token) external view returns (TokenInfo memory) {
        return _tokens[token];
    }

    /// @notice The pools every ETF swaps `token` through against USDG: its V3 `pool` at `fee`, and its
    /// hookless V4 pool at `v4Fee` / `v4TickSpacing` (spacing 0: none). Zeros for a token never added.
    function poolsOf(address token) external view returns (address pool, uint24 fee, uint24 v4Fee, int24 v4TickSpacing) {
        TokenInfo storage t = _tokens[token];
        return (t.pool, t.fee, t.v4Fee, t.v4TickSpacing);
    }

    /// @notice Whether a new ETF may choose `token`.
    function isEligible(address token) external view returns (bool) {
        return _tokens[token].eligible;
    }

    function isEtf(address etf) external view returns (bool) {
        return _etfs[etf].createdAt != 0;
    }

    /// @notice An ETF's creator, depth, logo pointer and creation time; zeros for any other address.
    function etfInfo(address etf) external view returns (EtfInfo memory) {
        return _etfs[etf];
    }

    function legsOf(address etf) external view returns (LegSpec[] memory) {
        return _legsOf[etf];
    }

    /// @notice An ETF's logo, the PNG given at creation; empty when none was.
    function logo(address etf) external view returns (bytes memory out) {
        address pointer = _etfs[etf].logoPointer;
        if (pointer == address(0)) return out;
        uint256 size = pointer.code.length - 1;
        out = new bytes(size);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(out, 32), 1, size)
        }
    }

    /// @notice `etf`'s profile and when it was last written; empty strings and 0 when it has none.
    function profileOf(address etf) external view returns (string memory description, string memory x, string memory telegram, string memory website, uint256 updatedAt) {
        Profile storage p = _profiles[etf];
        return (p.description, p.x, p.telegram, p.website, _profileUpdatedAt[etf]);
    }

    function etfCount() external view returns (uint256) {
        return etfs.length;
    }

    function tokenCount() external view returns (uint256) {
        return tokenList.length;
    }

    /// @notice The source codes, for readers that do not import the ETF's file. 1 is not used.
    function sources() external pure returns (uint8 none, uint8 pool, uint8 nav, uint8 spot) {
        return (SOURCE_NONE, SOURCE_POOL, SOURCE_NAV, SOURCE_SPOT);
    }

    /// @notice Every ETF parameter's bounds, the same as `MaidMarianEtfV3.paramBounds()`.
    function paramBounds() external pure returns (MaidMarianEtfV3.Params memory lo, MaidMarianEtfV3.Params memory hi) {
        return etfV3ParamBounds();
    }

    /// @notice `token`'s pool, its `observationCardinality` and `observationCardinalityNext`, and whether a
    /// 30 min `observe` answers now (`twapNow`). The cardinality is the test: a one-observation pool
    /// answers until its next swap.
    function oracleOf(address token) external view returns (address pool, uint16 cardinality, uint16 cardinalityNext, bool twapNow) {
        TokenInfo memory t = _tokens[token];
        if (!t.known) return (address(0), 0, 0, false);
        pool = t.pool;
        (, cardinality, cardinalityNext) = _cardinalityOf(pool);
        (uint256 quote, bool ok) = POOL_ORACLE.tryQuote(pool, 10 ** uint256(t.decimals) * USDG_UNIT_TO_18, token, address(USDG));
        twapNow = ok && quote > 0;
    }

    // ------------------------------------------------------------- internal ---

    /// A pool `addToken` accepts: the V3 factory's own pool of the pair at its `fee()`, at least 1 801
    /// observations, and a price above 0 (TWAP, or spot for a pool under 30 min old). Returns the fee.
    function _checkPool(address token, uint256 decimals, address pool) private view returns (uint24) {
        if (pool == address(0)) revert NoSource(token);
        if (pool.code.length == 0) revert BadPool(pool);
        (bool okFee, uint256 fee) = _readWord(pool, abi.encodeWithSelector(0xddca3f43)); // fee()
        if (!okFee || fee > type(uint24).max) revert BadPool(pool);
        // forge-lint: disable-next-line(unsafe-typecast)
        (bool known, uint256 named) = _readWord(UNISWAP_V3_FACTORY, abi.encodeWithSelector(0x1698ee82, token, address(USDG), uint24(fee))); // getPool(address,address,uint24)
        if (!known || named != uint256(uint160(pool))) revert BadPool(pool);
        (bool ok0, uint256 t0) = _readWord(pool, abi.encodeWithSelector(0x0dfe1681)); // token0()
        (bool ok1, uint256 t1) = _readWord(pool, abi.encodeWithSelector(0xd21220a7)); // token1()
        (uint256 a, uint256 u) = (uint256(uint160(token)), uint256(uint160(address(USDG))));
        if (!ok0 || !ok1 || !((t0 == a && t1 == u) || (t0 == u && t1 == a))) revert BadPool(pool);
        (bool okSlot0,, uint16 next) = _cardinalityOf(pool);
        if (!okSlot0) revert BadPool(pool);
        if (next < MIN_OBSERVATION_CARDINALITY) revert ThinOracle(pool, next, MIN_OBSERVATION_CARDINALITY);
        uint256 scale = 10 ** decimals * USDG_UNIT_TO_18;
        (uint256 quote, bool ok) = POOL_ORACLE.tryQuote(pool, scale, token, address(USDG));
        if (!ok || quote == 0) (quote, ok) = POOL_ORACLE.trySpotQuote(pool, scale, token, address(USDG));
        if (!ok || quote == 0) revert BadPool(pool);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(fee);
    }

    /// The hookless V4 pool's `sqrtPriceX96` on `POOL_MANAGER`, 0 when uninitialised or unread. As v4's
    /// `StateLibrary`: the id is the hash of the key, the pool's state at `keccak256(id, 6)`, `sqrtPriceX96`
    /// the low 160 bits of its first word.
    function _v4SqrtPrice(address token, uint24 fee, int24 tickSpacing) private view returns (uint160) {
        (address c0, address c1) = token < address(USDG) ? (token, address(USDG)) : (address(USDG), token);
        // A view read, once per call: plain `keccak256` for readability.
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 id = keccak256(abi.encode(c0, c1, fee, tickSpacing, address(0)));
        (bool ok, uint256 word) = _readWord(POOL_MANAGER, abi.encodeWithSelector(0x1e2eaeaf, keccak256(abi.encode(id, uint256(6))))); // extsload(bytes32)
        // forge-lint: disable-next-line(unsafe-typecast)
        return ok ? uint160(word) : 0;
    }

    /// ASCII allowlist, byte by byte, so no Unicode look-alike or control character can pass.
    function _checkName(bytes calldata name_) private pure {
        uint256 n = name_.length;
        if (n == 0 || n > MAX_NAME_BYTES || name_[0] == " " || name_[n - 1] == " ") revert BadName();
        for (uint256 i = 0; i < n; i++) {
            bytes1 ch = name_[i];
            if (ch == " ") {
                if (name_[i - 1] == " ") revert BadName();
                continue;
            }
            if (!_isAlnum(ch) && ch != "-" && ch != "." && ch != "&" && ch != "'") revert BadName();
        }
    }

    function _checkSymbol(bytes calldata symbol_) private pure {
        uint256 n = symbol_.length;
        if (n == 0 || n > MAX_SYMBOL_BYTES) revert BadSymbol();
        for (uint256 i = 0; i < n; i++) {
            if (!_isAlnum(symbol_[i])) revert BadSymbol();
        }
    }

    function _checkProfile(string calldata description, string calldata x, string calldata telegram, string calldata website) private pure {
        _checkDescription(bytes(description));
        _checkHandleUrl(bytes(x), "https://x.com/", 1, 15, BadX.selector);
        _checkHandleUrl(bytes(telegram), "https://t.me/", 5, 32, BadTelegram.selector);
        _checkWebsite(bytes(website));
    }

    function _checkDescription(bytes calldata s) private pure {
        uint256 n = s.length;
        if (n > MAX_DESCRIPTION_BYTES) revert BadDescription();
        for (uint256 i = 0; i < n; i++) {
            if (s[i] < 0x20 || s[i] > 0x7E) revert BadDescription();
        }
    }

    /// Empty, or exactly `prefix` and `min` - `max` of `[A-Za-z0-9_]`.
    function _checkHandleUrl(bytes calldata s, bytes memory prefix, uint256 min, uint256 max, bytes4 err) private pure {
        uint256 n = s.length;
        if (n == 0) return;
        uint256 p = prefix.length;
        if (n < p + min || n > p + max) _revert(err);
        for (uint256 i = 0; i < p; i++) {
            if (s[i] != prefix[i]) _revert(err);
        }
        for (uint256 i = p; i < n; i++) {
            if (!_isAlnum(s[i]) && s[i] != "_") _revert(err);
        }
    }

    function _checkWebsite(bytes calldata s) private pure {
        uint256 n = s.length;
        if (n == 0) return;
        bytes memory prefix = "https://";
        if (n > MAX_WEBSITE_BYTES || n <= prefix.length) revert BadWebsite();
        for (uint256 i = 0; i < prefix.length; i++) {
            if (s[i] != prefix[i]) revert BadWebsite();
        }
        bytes1 first = s[prefix.length];
        if (first == "/" || first == "?" || first == "#") revert BadWebsite();
        for (uint256 i = prefix.length; i < n; i++) {
            bytes1 ch = s[i];
            if (_isAlnum(ch)) continue;
            if (ch != "-" && ch != "." && ch != "_" && ch != "~" && ch != "/" && ch != ":" && ch != "?" && ch != "=" && ch != "&" && ch != "%" && ch != "#") revert BadWebsite();
        }
    }

    /// Reverts with the bare selector `err`.
    function _revert(bytes4 err) private pure {
        assembly ("memory-safe") {
            mstore(0, err)
            revert(0, 4)
        }
    }

    function _isAlnum(bytes1 ch) private pure returns (bool) {
        return (ch >= "0" && ch <= "9") || (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z");
    }

    /// Checks the PNG signature and the IHDR size only: the bytes are stored, never decoded on chain.
    /// A PNG carries no script, unlike an SVG.
    function _checkPng(bytes calldata png) private pure {
        if (png.length == 0) return;
        if (png.length > MAX_LOGO_BYTES || png.length < 33) revert BadLogo();
        if (bytes8(png[0:8]) != bytes8(0x89504E470D0A1A0A)) revert BadLogo();
        // "IHDR" is exactly 4 bytes.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint32(bytes4(png[8:12])) != 13 || bytes4(png[12:16]) != bytes4("IHDR")) revert BadLogo();
        uint256 width = uint32(bytes4(png[16:20]));
        uint256 height = uint32(bytes4(png[20:24]));
        if (width == 0 || height == 0 || width > MAX_LOGO_SIDE || height > MAX_LOGO_SIDE) revert BadLogo();
    }

    /// SSTORE2-style: the logo as a contract's code behind a `0x00` (STOP), so it never runs. The init
    /// code returns what follows its 14 bytes.
    function _storeLogo(bytes calldata png) private returns (address pointer) {
        bytes memory init = abi.encodePacked(hex"63", uint32(png.length + 1), hex"80600e6000396000f3", hex"00", png);
        assembly ("memory-safe") {
            pointer := create(0, add(init, 32), mload(init))
        }
        if (pointer == address(0)) revert BadLogo();
    }

    /// `slot0()`'s 4th and 5th words, range-checked; `ok == false` for any other answer, never a revert.
    function _cardinalityOf(address pool) private view returns (bool ok, uint16 cardinality, uint16 next) {
        (bool success, bytes memory ret) = pool.staticcall(abi.encodeCall(IUniswapV3PoolSlot0.slot0, ()));
        if (!success || ret.length != 7 * 32) return (false, 0, 0);
        (,,, uint256 c, uint256 n,,) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
        if (c > type(uint16).max || n > type(uint16).max) return (false, 0, 0);
        // Both checked under 2^16 above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, uint16(c), uint16(n));
    }

    /// A one-word answer to a static call; `ok == false` for anything else.
    function _readWord(address target, bytes memory data) private view returns (bool ok, uint256 value) {
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }
}
