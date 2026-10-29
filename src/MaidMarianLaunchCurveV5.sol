// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { StorageSlot } from "@openzeppelin/contracts/utils/StorageSlot.sol";
import { TickMath } from "./uniswap/TickMath.sol";
import { IUniversalRouter } from "./MaidMarianSevenMagnificent.sol";
import { poolTwapSqrtPrice, poolSpotSqrtPrice, poolValueAt } from "./MaidMarianPoolPrice.sol";
import {
    UR_V3_SWAP_EXACT_IN,
    UR_V4_SWAP,
    v4PoolId,
    v4Amounts,
    v4AddDeltas,
    floorTick,
    ceilTick,
    sqrtPriceOfAmounts,
    rangeLiquidity,
    singleSidedLiquidity,
    v3SwapInput,
    v4SwapInput
} from "./MaidMarianUniswapV5.sol";
import { MaidMarianToken2 } from "./MaidMarianToken2.sol";
import { IPoolManagerV4, curveBuy, curveSell, curveFits } from "./MaidMarianLaunchCurve.sol";

uint256 constant MAX_STOCKS = 10;

// CLONE INIT DATA STRUCT
// Packed clone arguments: creator 20, target 16, creator tax 2, supply 12, stock count 1, then per stock its
// address 20 and its weight 2.
uint256 constant CURVE_V5_ARGS_TARGET = 20;
uint256 constant CURVE_V5_ARGS_TAX = 36;
uint256 constant CURVE_V5_ARGS_SUPPLY = 38;
uint256 constant CURVE_V5_ARGS_COUNT = 50;
uint256 constant CURVE_V5_ARGS_STOCKS = 51;
uint256 constant CURVE_V5_STOCK_BYTES = 22;

/// One stock of a basket and its weight in bps.
struct BasketStock {
    address token;
    uint16 bps;
}

function curveV5CloneArgs(address creator, uint128 target, uint16 creatorTaxBps, uint96 supply, BasketStock[] calldata stocks) pure returns (bytes memory args) {
    args = abi.encodePacked(creator, target, creatorTaxBps, supply, uint8(stocks.length));
    for (uint256 i = 0; i < stocks.length; i++) {
        args = abi.encodePacked(args, stocks[i].token, stocks[i].bps);
    }
}

interface IMaidMarianTokenLauncherV5Reads {
    function owner() external view returns (address);
    function logo(address curve) external view returns (bytes memory);
    function poolsOf(address token) external view returns (address pool, uint24 fee, uint24 v4Fee, int24 v4TickSpacing, address v4Hooks);
}

/**
 * @title Maid Marian launch curve v5, "STOCKS are SEED"
 * @notice One token's bonding curve. Its reserve is the stock tokens it holds, counted in basket units: a unit is a
 * pro-rata claim on every stock. It bonds into one token / stock V4 pool per stock once its stocks are worth the
 * target at their 30 min TWAP. Traded directly or through its launcher (one approve for every curve).
 * @dev An EIP-1167 clone, initialized by its launcher.
 */
contract MaidMarianLaunchCurveV5 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------ constants ---

    uint256 public constant FEE_BPS = 75;

    /// The protocol's part of the trade fee and of the bond pools' fees.
    uint256 public constant PROTOCOL_SHARE_BPS = 3000;

    /// `9 900 >> (s x 14 / 5)` bps `s` seconds after the launch, 0 from 5 s.
    uint256 public constant SNIPE_TAX_START_BPS = 9900;
    uint256 public constant SNIPE_TAX_SECONDS = 5;

    uint256 public constant MAX_SNIPE_EXEMPTIONS = 10;

    /// 1 %, full range.
    uint24 public constant POOL_FEE = 10_000;
    int24 public constant POOL_TICK_SPACING = 200;
    int24 public constant POOL_TICK_LOWER = -887_200;
    int24 public constant POOL_TICK_UPPER = 887_200;

    /// One swap in each pool at its bond, so an indexer lists every pool at once.
    uint256 public constant BOND_SWAP_QUOTE_UNITS = 16;

    /// Where the bond's rounding dust goes: the token has no burn.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// The range above the opening price holds the tokens left, up to 10x it: 1.0001^23027 = 10.0004.
    int24 public constant ABOVE_RANGE_TICKS = 23_027;

    uint256 private constant BPS = 10_000;
    uint256 private constant CLONE_CODE_BYTES = 0x2d;
    uint8 private constant OP_COLLECT = 2;
    uint8 private constant OP_EXPLODE = 3;

    // ----------------------------------------------------------- immutables ---

    IMaidMarianTokenLauncherV5Reads public immutable FACTORY;
    IERC20 public immutable USDG;
    IUniversalRouter public immutable UNIVERSAL_ROUTER;
    IPoolManagerV4 public immutable POOL_MANAGER;
    address public immutable HOOK;
    address private immutable SELF;

    // ---------------------------------------------------------------- state ---

    /// The phantom plus the real basket units.
    uint256 public quoteReserve;
    uint256 public tokenReserve;

    /// Each stock the reserve counts: each unit claims `held(i) / realUnits()` of stock i.
    uint256[MAX_STOCKS] public held;

    address public token;

    uint64 public launchedAt;
    bool public bonded;
    /// Bit i set when stock i's pool was opened.
    uint16 public bondedStocks;
    /// The protocol's share of the reserve at the bond.
    uint16 public bondShareBps;

    /// Each pool's range above its opening price, `lower << 24 | upper` as uint24s: five to a storage slot.
    uint48[MAX_STOCKS] private _aboveRange;

    mapping(address asset => uint256) public ownerPot;

    mapping(address asset => uint256) public creatorPot;

    /// The pool the bond is opening, for the hook.
    bytes32 private transient _opening;

    /// The creator is exempt without an entry.
    mapping(address account => bool) private _snipeExempt;

    // --------------------------------------------------------------- events ---

    event Bought(address indexed buyer, uint256 usdgIn, uint256 fee, uint256 tax, uint256 units, uint256 tokensOut, uint256 quoteReserve, uint256 tokenReserve);
    event Sold(address indexed seller, uint256 tokensIn, uint256 units, uint256 usdgOut, uint256 fee, uint256 tax, uint256 quoteReserve, uint256 tokenReserve);
    /// One per pool the bond opens; `value` and `dust` (the rounding sent to `DEAD`) on the last one.
    event Bonded(address indexed token, bytes32 indexed poolId, address stock, uint256 poolTokens, uint256 poolStock, uint256 aboveTokens, uint256 protocolStock, uint256 value, uint256 dust);
    event BondSwapped(bytes32 indexed poolId, uint256 tokensIn, uint256 stockOut);
    event PoolFeesCollected(uint256 tokenFees);
    event ProtocolShareLowered(uint256 from, uint256 to);
    event OwnerPotBooked(address indexed asset, uint256 amount);
    event OwnerPotClaimed(address indexed asset, address indexed to, uint256 amount);
    event CreatorPotBooked(address indexed asset, uint256 amount);
    event CreatorPotClaimed(address indexed asset, address indexed to, uint256 amount);

    // --------------------------------------------------------------- errors ---

    error ZeroAddress();
    error NotFactory();
    error AlreadyInitialized();
    error NotAClone();
    error AlreadyBonded();
    error NotBonded();
    error NothingIn();
    error TooFewTokens(uint256 tokensOut, uint256 minTokensOut);
    error TooLittleUsdg(uint256 usdgOut, uint256 minUsdgOut);
    error NotCreator();
    error NotOwner();
    error NotPoolManager();
    error TooManyExemptions(uint256 count, uint256 max);
    /// Only the `curveFits` math bound: 2^64 between the reserves.
    error BuyTooLarge(uint256 quoteReserve, uint256 tokenReserve);
    error EmptyStock(uint256 stock);
    error NotDue();
    error ShareNotLower(uint256 current, uint256 bps);
    error StockUnpriced(uint256 stock, address token);
    error BondStockUnpriced(uint256 stock, address token);
    error BondDoesNotFit(uint256 quoteReserve, uint256 tokenReserve);
    error NoV4Pool(address token);
    error InputNotSpent(address token);
    error BadSwap(uint256 amount);

    // ---------------------------------------------------------- constructor ---

    /// The implementation; it holds nothing and is never initialized (`onlyClone`).
    constructor(IERC20 usdg, IUniversalRouter router, IPoolManagerV4 poolManager, address hook) {
        if (address(usdg) == address(0) || address(router) == address(0) || address(poolManager) == address(0) || hook == address(0)) revert ZeroAddress();
        FACTORY = IMaidMarianTokenLauncherV5Reads(msg.sender);
        USDG = usdg;
        UNIVERSAL_ROUTER = router;
        POOL_MANAGER = poolManager;
        HOOK = hook;
        SELF = address(this);
    }

    /// @notice Called once by the launcher: creates the token, its whole supply here.
    function initialize(address[] calldata snipeExempt, string calldata name_, string calldata symbol_, uint16 bondShare) external onlyClone {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        if (token != address(0)) revert AlreadyInitialized();
        if (snipeExempt.length > MAX_SNIPE_EXEMPTIONS) revert TooManyExemptions(snipeExempt.length, MAX_SNIPE_EXEMPTIONS);
        token = address(new MaidMarianToken2(name_, symbol_, supply()));
        launchedAt = uint64(block.timestamp);
        quoteReserve = phantomQuote();
        tokenReserve = supply();
        bondShareBps = bondShare;
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

    /**
     * @notice Buy with USDG. The curve splits it: the first buy by the weights, later ones by the reserve's mix at
     * spot, so nobody reshapes the reserve.
     * @param v4Mask Bit i: stock i through its V4 pool, else its V3 pool.
     * @param minTokensOut The buyer's only protection.
     */
    function buy(uint256 usdgIn, uint16 v4Mask, uint256 minTokensOut) external onlyClone nonReentrant returns (uint256 tokensOut) {
        return _buy(msg.sender, usdgIn, v4Mask, minTokensOut);
    }

    /// @notice `buy` by the launcher for `buyer`.
    function buyFor(address buyer, uint256 usdgIn, uint16 v4Mask, uint256 minTokensOut) external onlyClone nonReentrant returns (uint256 tokensOut) {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        return _buy(buyer, usdgIn, v4Mask, minTokensOut);
    }

    /// @notice Sell: each stock's share of the units sold at spot.
    function sell(uint256 tokensIn, uint16 v4Mask, uint256 minUsdgOut) external onlyClone nonReentrant returns (uint256 usdgOut) {
        return _sell(msg.sender, tokensIn, v4Mask, minUsdgOut);
    }

    /// @notice `sell` by the launcher for `seller`.
    function sellFor(address seller, uint256 tokensIn, uint16 v4Mask, uint256 minUsdgOut) external onlyClone nonReentrant returns (uint256 usdgOut) {
        if (msg.sender != address(FACTORY)) revert NotFactory();
        return _sell(seller, tokensIn, v4Mask, minUsdgOut);
    }

    /// @notice The launcher's owner lowers the protocol's share at the bond, before the bond; never raises it.
    function lowerProtocolShare(uint16 bps) external onlyClone nonReentrant {
        if (msg.sender != FACTORY.owner()) revert NotOwner();
        if (bonded) revert AlreadyBonded();
        uint16 from = bondShareBps;
        if (bps >= from) revert ShareNotLower(from, bps);
        bondShareBps = bps;
        emit ProtocolShareLowered(from, bps);
    }

    /// @notice Bond once the reserve is worth the target at TWAP. Anyone, no reward.
    function bond() external onlyClone nonReentrant {
        uint160[] memory prices = _twapPrices(_pools());
        if (!_bondDueAt(prices)) revert NotDue();
        _bond(prices);
    }

    function claimOwnerPot(address asset, address to) external onlyClone nonReentrant returns (uint256) {
        if (msg.sender != FACTORY.owner()) revert NotOwner();
        return _claim(true, asset, to);
    }

    function claimCreatorPot(address asset, address to) external onlyClone nonReentrant returns (uint256) {
        if (msg.sender != creator()) revert NotCreator();
        return _claim(false, asset, to);
    }

    /// @notice After the bond, every pool's fees: 30 % owner, 70 % creator. Anyone.
    function collectPoolFees() external onlyClone nonReentrant returns (uint256 tokenFees) {
        if (!bonded) revert NotBonded();
        uint256 n = stockCount();
        uint256 mask = bondedStocks;
        for (uint256 i = 0; i < n; i++) {
            // forge-lint: disable-next-line(incorrect-shift)
            if (mask & (1 << i) == 0) continue;
            (address stock,) = stockAt(i);
            (int24 lower, int24 upper) = aboveRange(i);
            (uint256 tf, uint256 stockFees) = abi.decode(POOL_MANAGER.unlock(abi.encode(OP_COLLECT, stock, lower, upper)), (uint256, uint256));
            tokenFees += tf;
            if (stockFees == 0) continue;
            uint256 toOwner = stockFees * PROTOCOL_SHARE_BPS / BPS;
            _bookToOwner(stock, toOwner);
            _bookToCreator(stock, stockFees - toOwner);
        }
        if (tokenFees > 0) {
            uint256 toProtocol = tokenFees * PROTOCOL_SHARE_BPS / BPS;
            IERC20(token).safeTransfer(FACTORY.owner(), toProtocol);
            IERC20(token).safeTransfer(creator(), tokenFees - toProtocol);
        }
        emit PoolFeesCollected(tokenFees);
    }

    /// @notice The PoolManager's callback: the bond's seeding and the fee collection.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        uint8 op = abi.decode(data, (uint8));
        if (op == OP_EXPLODE) {
            (, address[] memory list, uint256[] memory got, uint256[] memory tokens, uint160[] memory sqrtPrices, uint256[] memory liquidities) =
                abi.decode(data, (uint8, address[], uint256[], uint256[], uint160[], uint256[]));
            return _seedPools(list, got, tokens, sqrtPrices, liquidities);
        }
        (, address stock, int24 lower, int24 upper) = abi.decode(data, (uint8, address, int24, int24));
        IPoolManagerV4.PoolKey memory key = poolKeyIn(stock);
        (int256 delta,) = POOL_MANAGER.modifyLiquidity(key, _range(POOL_TICK_LOWER, POOL_TICK_UPPER, 0), "");
        if (lower != upper) {
            (int256 aboveDelta,) = POOL_MANAGER.modifyLiquidity(key, _range(lower, upper, 0), "");
            delta = v4AddDeltas(delta, aboveDelta);
        }
        (int256 dToken, int256 dStock) = _split(delta, stock);
        // Fees only: both deltas are owed to the curve.
        // forge-lint: disable-next-line(unsafe-typecast)
        (uint256 tokenFees, uint256 stockFees) = (uint256(dToken), uint256(dStock));
        if (tokenFees > 0) POOL_MANAGER.take(token, address(this), tokenFees);
        if (stockFees > 0) POOL_MANAGER.take(stock, address(this), stockFees);
        return abi.encode(tokenFees, stockFees);
    }

    // ---------------------------------------------------------------- views ---

    function creator() public view returns (address) {
        return address(uint160(_arg(0, 20)));
    }

    /// The reserve's value at TWAP that bonds the curve, raw USDG.
    function target() public view returns (uint256) {
        return _arg(CURVE_V5_ARGS_TARGET, 16);
    }

    function creatorTaxBps() public view returns (uint256) {
        return _arg(CURVE_V5_ARGS_TAX, 2);
    }

    function supply() public view returns (uint256) {
        return _arg(CURVE_V5_ARGS_SUPPLY, 12);
    }

    function stockCount() public view returns (uint256) {
        return _arg(CURVE_V5_ARGS_COUNT, 1);
    }

    function stockAt(uint256 i) public view returns (address stock, uint256 bps) {
        uint256 pos = CURVE_V5_ARGS_STOCKS + i * CURVE_V5_STOCK_BYTES;
        return (address(uint160(_arg(pos, 20))), _arg(pos + 20, 2));
    }

    function stocks() public view returns (BasketStock[] memory out) {
        uint256 n = stockCount();
        out = new BasketStock[](n);
        for (uint256 i = 0; i < n; i++) {
            (address s, uint256 bps) = stockAt(i);
            // Two bytes of clone arguments.
            // forge-lint: disable-next-line(unsafe-typecast)
            out[i] = BasketStock({ token: s, bps: uint16(bps) });
        }
    }

    /// 1/3 of the target, so 3/4 of the supply sell for the target (one unit is about one raw USDG).
    function phantomQuote() public view returns (uint256) {
        return target() / 3;
    }

    function realUnits() public view returns (uint256) {
        return quoteReserve - phantomQuote();
    }

    /// The quarter the curve still holds when its units reach the target; a buy may go past it.
    function reserved() public view returns (uint256) {
        return supply() / 4;
    }

    /// Units per token, 18 decimals.
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

    /// A buy's fee (snipe tax included) and creator tax on `usdgIn`, and the USDG swapped into stocks.
    function buyFees(uint256 usdgIn, address buyer) public view returns (uint256 fee, uint256 tax, uint256 net) {
        return _fees(usdgIn, _feeBps(buyer));
    }

    /// The tokens `units` buy now; 0 past what a pool can open at, or once bonded.
    function previewBuyUnits(uint256 units) external view returns (uint256 tokensOut) {
        if (bonded || units == 0) return 0;
        (uint256 q, uint256 t) = (quoteReserve, tokenReserve);
        (tokensOut,,,) = curveBuy(q, t, units, 0, 0);
        if (!curveFits(q + units, t - tokensOut)) return 0;
    }

    /// The units `tokensIn` sell for and each stock they take from the reserve.
    function previewSell(uint256 tokensIn) external view returns (uint256 units, uint256[] memory amounts) {
        uint256 n = stockCount();
        amounts = new uint256[](n);
        if (bonded || tokensIn == 0 || tokenReserve + tokensIn > supply()) return (0, amounts);
        (units,,) = curveSell(quoteReserve, tokenReserve, tokensIn, 0, 0);
        uint256 real = realUnits();
        if (units == 0) return (0, amounts);
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = Math.mulDiv(held[i], units, real);
        }
    }

    /// The reserve's value at each stock's 30 min TWAP, raw USDG; `ok` false when a held stock has none.
    function reserveValueUsdg() public view returns (uint256 value, bool ok) {
        return _reserveValueAt(_twapPrices(_pools()));
    }

    /// The reserve worth the target at TWAP: the next trade, or anyone's `bond()`, bonds.
    function bondDue() public view returns (bool) {
        return _bondDueAt(_twapPrices(_pools()));
    }

    /// Sorted, 1 %, spacing 200, `HOOK`.
    function poolKeyIn(address stock) public view returns (IPoolManagerV4.PoolKey memory key) {
        address t = token;
        (address c0, address c1) = t < stock ? (t, stock) : (stock, t);
        key = IPoolManagerV4.PoolKey({ currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: POOL_TICK_SPACING, hooks: HOOK });
    }

    /// What `HOOK` lets this curve initialize: the pool its bond is opening.
    function isBondPool(bytes32 id) external view returns (bool) {
        return id == _opening;
    }

    /// The stocks whose pool the bond opened, by their other currency; every stock before the bond.
    function bondPools() public view returns (address[] memory pools) {
        uint256 n = stockCount();
        uint256 mask = bonded ? bondedStocks : type(uint16).max;
        pools = new address[](n);
        uint256 k;
        for (uint256 i = 0; i < n; i++) {
            // forge-lint: disable-next-line(incorrect-shift)
            if (mask & (1 << i) != 0) (pools[k++],) = stockAt(i);
        }
        assembly ("memory-safe") {
            mstore(pools, k)
        }
    }

    function logo() external view returns (bytes memory) {
        return FACTORY.logo(address(this));
    }

    /// Stock i's pool's range above its opening price; equal ticks when none.
    function aboveRange(uint256 i) public view returns (int24 lower, int24 upper) {
        uint48 packed = _aboveRange[i];
        // forge-lint: disable-next-line(unsafe-typecast)
        (lower, upper) = (int24(uint24(packed >> 24)), int24(uint24(packed)));
    }

    // ------------------------------------------------------------- internal ---

    function _buy(address buyer, uint256 usdgIn, uint16 v4Mask, uint256 minTokensOut) private returns (uint256 tokensOut) {
        if (bonded) revert AlreadyBonded();
        if (usdgIn == 0) revert NothingIn();
        uint256 n = stockCount();
        USDG.safeTransferFrom(msg.sender, address(this), usdgIn);
        (uint256 fee, uint256 tax, uint256 net) = buyFees(usdgIn, buyer);
        _takeFees(fee, tax);
        uint256 real = realUnits();
        // The TWAP for the first buy's units and the bond check, the spot for the split: one read each a stock.
        address[] memory pools = _pools();
        uint160[] memory prices = _twapPrices(pools);
        uint256[] memory alloc = _allocate(net, real, n, pools);
        // The first buy defines the unit: what it got at TWAP, at most one per raw USDG paid, so a sandwiched
        // launch is credited what it got. Later buys get the fewest units any stock brought.
        uint256 units = real == 0 ? 0 : type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            uint256 got;
            (address stock,) = stockAt(i);
            // forge-lint: disable-next-line(incorrect-shift)
            if (alloc[i] != 0) got = _swap(address(USDG), stock, alloc[i], v4Mask & (1 << i) != 0);
            uint256 h = held[i];
            if (real == 0) {
                if (got == 0) revert EmptyStock(i);
                if (prices[i] == 0) revert StockUnpriced(i, stock);
                units += _valueAt(prices[i], got, stock);
            } else {
                // `h` > 0 while units are out: a sale takes `h x units / real`, below `h` until the last unit.
                units = Math.min(units, Math.mulDiv(real, got, h));
            }
            held[i] = h + got;
        }
        if (real == 0 && units > net) units = net;
        (uint256 q, uint256 t) = (quoteReserve, tokenReserve);
        (tokensOut,,,) = curveBuy(q, t, units, 0, 0);
        if (tokensOut == 0 || tokensOut < minTokensOut) revert TooFewTokens(tokensOut, minTokensOut);
        (q, t) = (q + units, t - tokensOut);
        if (!curveFits(q, t)) revert BuyTooLarge(q, t);
        (quoteReserve, tokenReserve) = (q, t);
        IERC20(token).safeTransfer(buyer, tokensOut);
        emit Bought(buyer, usdgIn, fee, tax, units, tokensOut, q, t);
        if (_bondDueAt(prices)) _bond(prices);
    }

    /// The weights when no unit is out, else each held stock's value at spot, what its swap pays: a spot moved
    /// against the TWAP costs only the mover. A reserve with a held stock worth 0 (dust after a sell-out) goes
    /// back to the weights, so a near-empty curve still buys.
    function _allocate(uint256 net, uint256 real, uint256 n, address[] memory pools) private view returns (uint256[] memory alloc) {
        alloc = new uint256[](n);
        uint256[] memory w = new uint256[](n);
        uint256 sum;
        if (real != 0) {
            bool dust;
            for (uint256 i = 0; i < n; i++) {
                uint256 h = held[i];
                if (h == 0) continue;
                (address stock,) = stockAt(i);
                uint160 spot = poolSpotSqrtPrice(pools[i]);
                if (spot == 0) revert StockUnpriced(i, stock);
                w[i] = _valueAt(spot, h, stock);
                if (w[i] == 0) dust = true;
                sum += w[i];
            }
            if (dust) sum = 0;
        }
        if (sum == 0) {
            for (uint256 i = 0; i < n; i++) {
                (, w[i]) = stockAt(i);
                sum += w[i];
            }
        }
        uint256 big;
        uint256 given;
        for (uint256 i = 0; i < n; i++) {
            if (w[i] > w[big]) big = i;
            alloc[i] = Math.mulDiv(net, w[i], sum);
            given += alloc[i];
        }
        alloc[big] += net - given;
    }

    function _sell(address seller, uint256 tokensIn, uint16 v4Mask, uint256 minUsdgOut) private returns (uint256 usdgOut) {
        if (bonded) revert AlreadyBonded();
        if (tokensIn == 0) revert NothingIn();
        (uint256 q, uint256 t) = (quoteReserve, tokenReserve);
        (uint256 units,,) = curveSell(q, t, tokensIn, 0, 0);
        if (units == 0) revert TooLittleUsdg(0, minUsdgOut);
        uint256 real = q - phantomQuote();
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        (quoteReserve, tokenReserve) = (q - units, t + tokensIn);
        uint256 n = stockCount();
        uint256 gross;
        for (uint256 i = 0; i < n; i++) {
            uint256 h = held[i];
            // Rounded down: what stays behind each unit never shrinks.
            uint256 pay = Math.mulDiv(h, units, real);
            if (pay == 0) continue;
            held[i] = h - pay;
            (address stock,) = stockAt(i);
            // forge-lint: disable-next-line(incorrect-shift)
            gross += _swap(stock, address(USDG), pay, v4Mask & (1 << i) != 0);
        }
        uint256 fee;
        uint256 tax;
        (fee, tax, usdgOut) = _fees(gross, FEE_BPS);
        if (usdgOut < minUsdgOut) revert TooLittleUsdg(usdgOut, minUsdgOut);
        _takeFees(fee, tax);
        USDG.safeTransfer(seller, usdgOut);
        emit Sold(seller, tokensIn, units, usdgOut, fee, tax, q - units, t + tokensIn);
        uint160[] memory prices = _twapPrices(_pools());
        if (_bondDueAt(prices)) _bond(prices);
    }

    /// The fee at `feeBps` and the creator tax on `amount`, and what is left.
    function _fees(uint256 amount, uint256 feeBps) private view returns (uint256 fee, uint256 tax, uint256 rest) {
        fee = amount * feeBps / BPS;
        tax = amount * creatorTaxBps() / BPS;
        rest = amount - fee - tax;
    }

    function _feeBps(address buyer) private view returns (uint256) {
        // Capped so fee, snipe and tax never pass 100 %.
        return FEE_BPS + Math.min(currentSnipeTaxBps(buyer), BPS - FEE_BPS - creatorTaxBps());
    }

    function _takeFees(uint256 fee, uint256 tax) private {
        uint256 toProtocol = fee * PROTOCOL_SHARE_BPS / BPS;
        address usdg = address(USDG);
        ownerPot[usdg] += toProtocol;
        creatorPot[usdg] += fee - toProtocol + tax;
    }

    function _bookToOwner(address asset, uint256 amount) private {
        if (amount == 0) return;
        ownerPot[asset] += amount;
        emit OwnerPotBooked(asset, amount);
    }

    function _bookToCreator(address asset, uint256 amount) private {
        if (amount == 0) return;
        creatorPot[asset] += amount;
        emit CreatorPotBooked(asset, amount);
    }

    function _claim(bool toOwner, address asset, address to) private returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        mapping(address => uint256) storage pot = toOwner ? ownerPot : creatorPot;
        amount = pot[asset];
        if (amount == 0) revert NothingIn();
        pot[asset] = 0;
        IERC20(asset).safeTransfer(to, amount);
        if (toOwner) emit OwnerPotClaimed(asset, to, amount);
        else emit CreatorPotClaimed(asset, to, amount);
    }

    /// `ok` false when a held stock has no price or is worth 0.
    function _reserveValueAt(uint160[] memory prices) private view returns (uint256 value, bool ok) {
        uint256 n = prices.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 h = held[i];
            if (h == 0) continue;
            (address stock,) = stockAt(i);
            uint256 v = prices[i] == 0 ? 0 : _valueAt(prices[i], h, stock);
            if (v == 0) return (0, false);
            value += v;
        }
        return (value, true);
    }

    function _bondDueAt(uint160[] memory prices) private view returns (bool) {
        if (bonded) return false;
        (uint256 value, bool ok) = _reserveValueAt(prices);
        return ok && value >= target();
    }

    /// Each stock's registered V3 pool.
    function _pools() private view returns (address[] memory pools) {
        uint256 n = stockCount();
        pools = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            (address stock,) = stockAt(i);
            (pools[i],,,,) = FACTORY.poolsOf(stock);
        }
    }

    /// Each stock's TWAP `sqrtPriceX96`, 0 when its pool cannot answer; read once a transaction.
    function _twapPrices(address[] memory pools) private view returns (uint160[] memory prices) {
        prices = new uint160[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            prices[i] = poolTwapSqrtPrice(pools[i]);
        }
    }

    function _valueAt(uint160 sqrtPriceX96, uint256 amount, address stock) private view returns (uint256) {
        return poolValueAt(sqrtPriceX96, amount, stock, address(USDG));
    }

    /**
     * The protocol's share to the owner's pot, the rest into one pool per stock sized by its TWAP value, so every
     * pool opens at one price; the tokens left above that price. The pools always have their tokens: the curve
     * holds t = k / q, the pools need (1 - s)(q - q0) t / q, and q / ((1 - s)(q - q0)) > 1.
     */
    function _bond(uint160[] memory prices) private {
        uint256 n = stockCount();
        uint256 share = bondShareBps;
        uint256 real = realUnits();
        uint256 tokensAtPrice = Math.mulDiv(real - real * share / BPS, tokenReserve, quoteReserve);
        address[] memory list = new address[](n);
        uint256[] memory got = new uint256[](n);
        uint256[] memory tokens = new uint256[](n);
        uint256[] memory protocolStock = new uint256[](n);
        uint256 value;
        for (uint256 i = 0; i < n; i++) {
            (list[i],) = stockAt(i);
            uint256 h = held[i];
            held[i] = 0;
            protocolStock[i] = h * share / BPS;
            got[i] = h - protocolStock[i];
            _bookToOwner(list[i], protocolStock[i]);
            if (got[i] == 0) continue;
            tokens[i] = prices[i] == 0 ? 0 : _valueAt(prices[i], got[i], list[i]);
            if (tokens[i] == 0) revert BondStockUnpriced(i, list[i]);
            value += tokens[i];
        }
        bonded = true;
        uint160[] memory sqrtPrices = new uint160[](n);
        uint256[] memory liquidities = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            if (tokens[i] == 0) continue;
            uint256 t = Math.mulDiv(tokensAtPrice, tokens[i], value);
            if (got[i] > 1 && curveFits(got[i], t)) (sqrtPrices[i], liquidities[i]) = _openingOf(list[i], got[i], t);
            tokens[i] = liquidities[i] != 0 ? t : 0;
        }
        (uint256[] memory poolTokens, uint256[] memory poolStock, uint256[] memory rest, uint256[] memory above) =
            abi.decode(POOL_MANAGER.unlock(abi.encode(OP_EXPLODE, list, got, tokens, sqrtPrices, liquidities)), (uint256[], uint256[], uint256[], uint256[]));
        uint16 mask;
        uint256 last;
        for (uint256 i = 0; i < n; i++) {
            if (poolTokens[i] != 0) {
                // i < MAX_STOCKS = 10.
                // forge-lint: disable-next-line(incorrect-shift, unsafe-typecast)
                mask |= uint16(1 << i);
                last = i;
            }
            _bookToOwner(list[i], rest[i]);
        }
        if (mask == 0) revert BondDoesNotFit(quoteReserve, tokenReserve);
        bondedStocks = mask;
        IERC20 launched = IERC20(token);
        uint256 dust = launched.balanceOf(address(this));
        if (dust > 0) launched.safeTransfer(DEAD, dust);
        for (uint256 i = 0; i <= last; i++) {
            if (poolTokens[i] == 0) continue;
            bool isLast = i == last;
            emit Bonded(address(launched), _poolId(list[i]), list[i], poolTokens[i], poolStock[i], above[i], protocolStock[i], isLast ? value : 0, isLast ? dust : 0);
        }
    }

    /// The opening `sqrtPriceX96` of `amount` stock against `tokens`, and the full range's liquidity they give.
    function _openingOf(address stock, uint256 amount, uint256 tokens) private view returns (uint160 sqrtPrice, uint256 liquidity) {
        bool tokenFirst = token < stock;
        sqrtPrice = tokenFirst ? sqrtPriceOfAmounts(amount, tokens) : sqrtPriceOfAmounts(tokens, amount);
        // One unit short, so the PoolManager's rounding up stays within it.
        liquidity = tokenFirst ? rangeLiquidity(sqrtPrice, tokens, amount - 1, POOL_TICK_LOWER, POOL_TICK_UPPER) : rangeLiquidity(sqrtPrice, amount - 1, tokens, POOL_TICK_LOWER, POOL_TICK_UPPER);
    }

    /// Opens every pool, then the tokens left above each opening price, split as the pools' tokens.
    function _seedPools(address[] memory list, uint256[] memory got, uint256[] memory tokens, uint160[] memory sqrtPrices, uint256[] memory liquidities) private returns (bytes memory) {
        uint256 n = list.length;
        (uint256[] memory poolTokens, uint256[] memory poolStock, uint256[] memory rest) = (new uint256[](n), new uint256[](n), new uint256[](n));
        uint256[] memory above = new uint256[](n);
        int256 tokenDelta;
        uint256 opened;
        for (uint256 i = 0; i < n; i++) {
            rest[i] = got[i];
            if (tokens[i] == 0) continue;
            int256 dToken;
            (poolTokens[i], poolStock[i], dToken, rest[i]) = _seedPool(list[i], got[i], tokens[i], sqrtPrices[i], liquidities[i]);
            tokenDelta += dToken;
            opened += poolTokens[i];
        }
        _opening = bytes32(0);
        // What the positions and the display swaps owe is still here: the rest is the tokens left.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 left = IERC20(token).balanceOf(address(this)) - uint256(-tokenDelta);
        for (uint256 i = 0; i < n && opened != 0; i++) {
            if (poolTokens[i] == 0) continue;
            int256 dToken;
            (dToken, above[i]) = _seedAbove(i, list[i], sqrtPrices[i], Math.mulDiv(left, poolTokens[i], opened));
            tokenDelta += dToken;
        }
        _settle(token, tokenDelta);
        return abi.encode(poolTokens, poolStock, rest, above);
    }

    /// Opens `stock`'s pool at `sqrtPrice`, the full range and the display swap.
    function _seedPool(address stock, uint256 amount, uint256 tokens, uint160 sqrtPrice, uint256 liquidity) private returns (uint256 poolTokens, uint256 poolStock, int256 dToken, uint256 rest) {
        IPoolManagerV4.PoolKey memory key = poolKeyIn(stock);
        bytes32 id = v4PoolId(key);
        _opening = id;
        POOL_MANAGER.initialize(key, sqrtPrice);
        int256 dStock;
        (poolTokens, poolStock, dToken, dStock) = _addAndSwap(key, id, stock, liquidity, amount, tokens);
        _settle(stock, dStock);
        // The stock owed for the position less the swap's output, under what was set for the pool.
        // forge-lint: disable-next-line(unsafe-typecast)
        rest = amount - uint256(-dStock);
    }

    /// `amount` tokens alone from just above the opening price to 10x it: above the tick when the token is
    /// currency0, below it when currency1, so out of range and tokens only.
    function _seedAbove(uint256 i, address stock, uint160 sqrtPrice, uint256 amount) private returns (int256 dToken, uint256 placed) {
        int24 open = TickMath.getTickAtSqrtPrice(sqrtPrice);
        bool tokenFirst = token < stock;
        (int24 lower, int24 upper) = tokenFirst
            ? (ceilTick(open + 1, POOL_TICK_SPACING), floorTick(open + ABOVE_RANGE_TICKS, POOL_TICK_SPACING))
            : (ceilTick(open - ABOVE_RANGE_TICKS, POOL_TICK_SPACING), floorTick(open, POOL_TICK_SPACING));
        if (lower < POOL_TICK_LOWER) lower = POOL_TICK_LOWER;
        if (upper > POOL_TICK_UPPER) upper = POOL_TICK_UPPER;
        if (lower >= upper || amount < 2) return (0, 0);
        // One unit short, so the PoolManager's rounding up stays within it.
        uint256 liquidity = singleSidedLiquidity(amount - 1, tokenFirst, lower, upper);
        if (liquidity == 0) return (0, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        (int256 delta,) = POOL_MANAGER.modifyLiquidity(poolKeyIn(stock), _range(lower, upper, int256(liquidity)), "");
        (dToken,) = _split(delta, stock);
        // forge-lint: disable-next-line(unsafe-typecast)
        placed = uint256(-dToken);
        // forge-lint: disable-next-line(unsafe-typecast)
        _aboveRange[i] = (uint48(uint24(lower)) << 24) | uint48(uint24(upper));
    }

    function _addAndSwap(IPoolManagerV4.PoolKey memory key, bytes32 id, address stock, uint256 liquidity, uint256 num, uint256 den)
        private
        returns (uint256 poolTokens, uint256 poolStock, int256 dToken, int256 dStock)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        (int256 delta,) = POOL_MANAGER.modifyLiquidity(key, _range(POOL_TICK_LOWER, POOL_TICK_UPPER, int256(liquidity)), "");
        (dToken, dStock) = _split(delta, stock);
        // forge-lint: disable-next-line(unsafe-typecast)
        (poolTokens, poolStock) = (uint256(-dToken), uint256(-dStock));
        uint256 tokensIn = Math.mulDiv(BOND_SWAP_QUOTE_UNITS, den, num, Math.Rounding.Ceil);
        bool zeroForOne = key.currency0 == token;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 swapDelta = POOL_MANAGER.swap(key, IPoolManagerV4.SwapParams({ zeroForOne: zeroForOne, amountSpecified: -int256(tokensIn), sqrtPriceLimitX96: limit }), "");
        (int256 sToken, int256 sStock) = _split(swapDelta, stock);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit BondSwapped(id, uint256(-sToken), uint256(sStock));
        (dToken, dStock) = (dToken + sToken, dStock + sStock);
    }

    function _poolId(address stock) private view returns (bytes32) {
        return v4PoolId(poolKeyIn(stock));
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

    /// A `BalanceDelta` as the token's and the stock's halves.
    function _split(int256 delta, address stock) private view returns (int256 dToken, int256 dStock) {
        (int256 a0, int256 a1) = v4Amounts(delta);
        (dToken, dStock) = token < stock ? (a0, a1) : (a1, a0);
    }

    function _range(int24 lower, int24 upper, int256 liquidityDelta) private pure returns (IPoolManagerV4.ModifyLiquidityParams memory) {
        return IPoolManagerV4.ModifyLiquidityParams({ tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: bytes32(0) });
    }

    /// One exact-in swap through the registered pool, the router pre-funded; returns the rise of `tokenOut`.
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, bool v4) private returns (uint256 amountOut) {
        address stock = tokenIn == address(USDG) ? tokenOut : tokenIn;
        (, uint24 fee, uint24 v4Fee, int24 v4TickSpacing, address v4Hooks) = FACTORY.poolsOf(stock);
        bytes[] memory inputs = new bytes[](1);
        bytes1 command;
        if (v4) {
            if (v4TickSpacing == 0) revert NoV4Pool(stock);
            if (amountIn > type(uint128).max) revert BadSwap(amountIn);
            command = UR_V4_SWAP;
            // forge-lint: disable-next-line(unsafe-typecast)
            inputs[0] = v4SwapInput(address(this), tokenIn, tokenOut, v4Fee, v4TickSpacing, v4Hooks, uint128(amountIn));
        } else {
            command = UR_V3_SWAP_EXACT_IN;
            inputs[0] = v3SwapInput(address(this), tokenIn, fee, tokenOut, amountIn);
        }
        address router = address(UNIVERSAL_ROUTER);
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 routerBefore = IERC20(tokenIn).balanceOf(router);
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).safeTransfer(router, amountIn);
        UNIVERSAL_ROUTER.execute(abi.encodePacked(command), inputs, block.timestamp);
        if (IERC20(tokenIn).balanceOf(address(this)) + amountIn != inBefore || IERC20(tokenIn).balanceOf(router) != routerBefore) revert InputNotSpent(tokenIn);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
    }

    function _arg(uint256 offset, uint256 len) private view returns (uint256 v) {
        assembly ("memory-safe") {
            extcodecopy(address(), 0, add(CLONE_CODE_BYTES, offset), 32)
            v := shr(sub(256, shl(3, len)), mload(0))
        }
    }
}
