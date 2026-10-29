// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IUniversalRouter } from "./MaidMarianSevenMagnificent.sol";
import { MaidMarianBagPoolOracle } from "./MaidMarianBagPoolOracle.sol";

/**
 * @title Maid Marian ETF pool depth
 * @notice How deep a token/USDG Uniswap V3 pool is, as `MaidMarianEtf`'s depth floor reads it, in
 * one place so `script/DeployEtf.s.sol` and the fork claims measure what the contract measures
 * (security review 2026-10-17, second pass, B-1 and B-2: the floor read `USDG.balanceOf(pool)`,
 * which the pool's own `flash` empties for one call and an out-of-range position fills for one).
 *
 * The depth is the USDG that the pool's **time-weighted in-range liquidity** trades between 2 %
 * under its price and 2 % over it - what it pays out to a seller down to -2 % plus what it takes
 * from a buyer up to +2 %. The liquidity is the harmonic mean over the oracle's 30 minutes,
 * `L = 1800 x 2^128 / delta`, `delta` the `secondsPerLiquidityCumulativeX128` gained over
 * `observe([1800, 0])` (Uniswap's `OracleLibrary.consult`); a pool writes its observation with
 * the liquidity from before the first change in a block, so nothing done inside the reading call
 * - a flash, a mint in range or out of it, a swap - moves this L. The price is the TWAP the leg
 * is valued at, `u = twap / scale` raw USDG per raw token, not `slot0`'s spot, which a swap in the
 * same call moves. Uniswap V3's amount of the USDG side between two prices, with USDG token1 (`u`
 * the pool's price) `L x (sqrt(1.02 u) - sqrt(0.98 u))`, with USDG token0 (the pool's price `1 /
 * u`, the band `[1 / 1.02u, 1 / 0.98u]`) `L x (sqrt(1.02) - sqrt(0.98)) / sqrt(1 / u)`: both are
 * `L x sqrt(u) x (sqrt(1.02) - sqrt(0.98))`, so the token order is in `u`, from the TWAP read in
 * the right order, and the formula is one.
 */
library MaidMarianEtfPoolDepth {
    /// `(sqrt(1.02) - sqrt(0.98)) x 1e18`, each root floored to 18 decimals (1 009 950 493 836 207 795
    /// less 989 949 493 661 166 534); the exact value is ...041 261.175.
    uint256 internal constant BAND_E18 = 20_001_000_175_041_261;

    uint32 internal constant WINDOW = 1800;

    /// The harmonic-mean in-range liquidity over the last 30 minutes, a sentinel `(false, 0)` for a
    /// pool that cannot answer `observe([1800, 0])` (too young, or not a pool) or answers a zero
    /// `delta`, which no Uniswap V3 pool can: each second adds `2^128 / max(L, 1) >= 1`.
    function harmonicLiquidity(address pool) internal view returns (bool ok, uint256 liquidity) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = WINDOW;
        (bool answered, bytes memory data) = pool.staticcall(abi.encodeWithSelector(0x883bdbfd, ago)); // observe(uint32[])
        // `MaidMarianBagPoolOracle.tryQuote`'s own test: two arrays of two words, eight words at least.
        if (!answered || data.length < 8 * 32) return (false, 0);
        (, uint160[] memory perLiquidity) = abi.decode(data, (int56[], uint160[]));
        if (perLiquidity.length < 2) return (false, 0);
        uint160 delta;
        // The cumulative wraps by design (Uniswap's own subtraction is unchecked).
        unchecked {
            delta = perLiquidity[1] - perLiquidity[0];
        }
        if (delta == 0) return (false, 0);
        return (true, (uint256(WINDOW) << 128) / delta);
    }

    /// The USDG units `liquidity` holds within 2 % of the price `twap / scale` (raw USDG per raw
    /// token), rounded down. Never reverts: under `u = 2^64` the root is taken at X96, above it (a
    /// price no stock has: 1.8e31 USDG a whole 18-decimal token) at units.
    function usdgWithinTwoPercent(uint256 liquidity, uint256 twap, uint256 scale) internal pure returns (uint256) {
        if (liquidity > type(uint128).max) liquidity = type(uint128).max;
        uint256 lRootU;
        if (twap / scale < 1 << 64) lRootU = Math.mulDiv(liquidity, Math.sqrt(Math.mulDiv(twap, 1 << 192, scale)), 1 << 96);
        else lRootU = liquidity * Math.sqrt(twap / scale);
        return Math.mulDiv(lRootU, BAND_E18, 1e18);
    }

    /// Both: the pool's depth in USDG units at the leg's TWAP, `(false, 0)` when `observe` does not answer.
    function depth(address pool, uint256 twap, uint256 scale) internal view returns (bool ok, uint256 usdg) {
        uint256 liquidity;
        (ok, liquidity) = harmonicLiquidity(pool);
        if (ok) usdg = usdgWithinTwoPercent(liquidity, twap, scale);
    }
}

/**
 * @title Maid Marian ETF
 * @notice One token that holds between 2 and 10 Robinhood Chain stock tokens - its legs - each
 * at a fixed target weight. m7m (`MaidMarianSevenMagnificent`, the seven in equal value) made
 * general: the name, the symbol, the legs, their feeds, their weights and every parameter m7m
 * kept as a constant (fees, times, band, tolerance: `Params`, each bounded) are given at
 * deployment and fixed for life.
 *
 * Weights are in parts: leg i's target is `parts_i / sum of parts` of the fund, so
 * `[1,1,1,1,1,1,1]` is exactly one seventh each and `[40,30,30]` reads as percent.
 *
 * Four doors:
 *  - Mint with USDG: the contract buys the legs for you; you get shares for what you paid,
 *    never more than Chainlink says it is worth.
 *  - Mint with the legs: bring the tokens yourself, with the fund's share of USDG.
 *  - Redeem to USDG: your part of each leg is sold; what is not sold comes to you as tokens.
 *  - Redeem to the legs: you get your part of each token. This door always works, even if
 *    everything else breaks.
 *
 * A mint that would push a leg out of its dead band is refused, so new money cannot make
 * turnover. At most once per `minInterval` the owner or any holder rebalances the fund back
 * to its targets; the contract checks every trade against Chainlink, within `toleranceBps`, and
 * refuses a bad one.
 *
 * Costs, each fixed at deployment: an entry fee, an exit fee, an early-exit penalty that falls
 * linearly to 0 over `holdPeriod` (it stays with the other holders), a management fee a year,
 * and the non-minter exit: shares redeemed beyond those the holder minted and still holds -
 * bought on a pool - pay `nonMinterExitBps` whatever their age, into the fund.
 *
 * Each leg has its price channel, fixed at deployment: a Chainlink feed, or the 30-minute TWAP of
 * its token/USDG Uniswap V3 pool (a TWAP leg), or a feed checked against its pool. Minting with
 * USDG is closed while a feed is older than `mintFeedAge` (nights, weekends, holidays - a basket
 * of TWAP legs only mints day and night), while a held leg is dead (a dead feed, a pool whose
 * 30-minute liquidity holds under `poolDepthFloor` USDG within 2 % of its price or that has no
 * 30 minutes of history, a feed and its pool more than
 * `feedPoolGapBps` apart), and for `feedNotice` after a feed or a pool is replaced.
 *
 * Nobody can change the legs, their weights, the parameters, pause the fund, or touch the
 * holdings outside these doors. The owner can only rebalance (as any holder can), replace a dead
 * feed or a dead pool - by another Uniswap V3 pool of the same pair, which then neither prices a
 * mint nor trades for `feedNotice` - and rescue tokens sent here by mistake.
 *
 * Warning: Robinhood's stock tokens have an admin burn that can take tokens from any holder,
 * this fund included.
 */
contract MaidMarianEtf is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------ constants ---

    /// The most legs an ETF can hold. The storage arrays are sized to it.
    uint256 public constant MAX_LEGS = 10;

    /// The least USDG (6 decimals) the first mint routes to each leg: 1 USDG (security review
    /// 2026-10-17, R1: a first mint of one unit a leg passed the 99 % floors, which round to 0
    /// on dust, left `nav` at 0 and made every later `mint` revert).
    uint256 public constant MIN_FIRST_MINT_PER_LEG = 1e6;

    /// `redeemInKind`'s `allowFail` bit for USDG, whatever the leg count (author, 2026-10-17;
    /// security review 2026-10-17, I2: on bit `LEGS` a mask built for one fund - `0x80`, USDG on
    /// m7m - forfeited leg 7 of a ten-leg one). Bits `LEGS` to 14 are not read.
    uint256 public constant USDG_BIT = 15;

    uint256 private constant BPS = 10_000;
    uint256 private constant YEAR = 365 days;

    // ---------------------------------------------------------------- types ---

    /**
     * One leg as given to the constructor, with its price channel - part of the ETF, as its name and
     * its symbol are:
     *  - `feed` alone: the leg is priced by that Chainlink feed (m7m's channel);
     *  - `pool` alone: a TWAP leg, priced by the 30-minute TWAP of that token/USDG Uniswap V3
     *    pool, which must be the Uniswap V3 factory's pool of the pair at its fee, be
     *    `poolDepthFloor` deep (`MaidMarianEtfPoolDepth`) and answer `observe([1800, 0])`;
     *  - both: priced by the feed, and dead while the pool, as deep and as observable, disagrees
     *    with it by more than `feedPoolGapBps` (security review 2026-10-17, R3).
     * At least one of the two (`ZeroAddress`). `parts` is the leg's weight, at least 1.
     */
    struct LegInit {
        address token;
        address feed;
        address pool;
        uint16 parts;
    }

    /**
     * What the deployer chooses besides the legs: every constant of m7m, each
     * checked against its bounds in the constructor (`ParamOutOfBounds(name)`) and then
     * immutable. m7m's value and the bounds, in that order:
     *  - `entryFeeBps` (10; 0 - 100): of `usdgIn` in USDG on `mint`, of the shares on
     *    `mintInKind`, to the owner.
     *  - `exitFeeBps` (30; 0 - 200): of the shares redeemed, to the owner, on both redeems (in
     *    shares on `redeem` too since the 2026-10-15 review, H1: a USDG fee could be routed around).
     *  - `earlyExitPenaltyBps` (70 flat; 0 - 2 000) and `holdPeriod` (1 day; 0 - 30 days): an exit
     *    at age `a < holdPeriod` of the holder's `heldSince` burns `earlyExitPenaltyBps x
     *    (holdPeriod - a) / holdPeriod` of its minted shares without payout, for the holders who
     *    stay (author, 2026-10-17: linear, "10 % la premiere heure, 0 % au bout de n temps"); at
     *    `a >= holdPeriod` nothing. m7m's flat 70 bps is not reproduced: m7m stays the v1.
     *  - `managementFeeBps` (30; 0 - 300): of the supply a year, in new shares to the owner,
     *    accrued at each rebalance.
     *  - `nonMinterExitBps` (none; 0 - 10 000, author 2026-10-17: "mets la borne 0 - 100 %"):
     *    shares redeemed beyond `mintedBy` - bought on a pool - burn this much whatever their age,
     *    for the holders, instead of the early penalty. With the exit fee it must leave something
     *    to burn: `exitFeeBps + nonMinterExitBps <= 10 000`, else `nonMinterExitBps` is out.
     *  - `deadBandBps` (200; 100 - 5 000) and `deadBandFloorBps` (0; 0 - 500): a leg is due for a
     *    trade when its distance to its target, in USDG, is at least `max(deadBandBps x target /
     *    10 000, deadBandFloorBps x nav / 10 000)` (author, 2026-10-17: m7m's 200 / 0 is the
     *    default). Under 10 000 a band always lets an empty leg be bought (security review
     *    2026-10-17, I1); a leg whose target is under the floor never trades and is filled by
     *    `mintPlan` and the mints alone.
     *  - `toleranceBps` (100; 20 - 500): a rebalance trade must bring the value at its leg's
     *    channel (the feed, or the TWAP) less this (author, 2026-10-17: 50 by default).
     *  - `mintFeedAge` (6 hours; 1 hour - 7 days): a mint needs every live feed's last round
     *    younger than this (review 2026-10-15, M8); a TWAP leg has no round and no age. Measured over 92 days to 2026-10-15
     *    (m7m's seven feeds, sessions 13:30-20:00 UTC): the largest staleness in
     *    a session is 5h53 (META) to 6h25 (AAPL); a mint is closed 58.2 % of session minutes at
     *    2 h, 22.3 % at 4 h, 4.2 % at 6 h, 2.8 % at 8 h. Not measured for any other feed.
     *  - `minInterval` (20 hours; 1 hour - 7 days): between two rebalances (author, 2026-10-15: so
     *    the New York open can drift an hour with DST and a rebalance around it passes).
     *  - `deadFeedAge` (7 days; 1 - 30 days): a feed older than this, answering <= 0, or not
     *    answering, is dead (a weekend plus a holiday is at most four days without a round).
     *  - `feedNotice` (3 days; 0 - 14 days): `mint` stays closed this long after the owner
     *    replaces a dead feed (review 2026-10-15, M-a), so holders who distrust it leave first.
     *  - `poolDepthFloor` (none; at least 10 000 USDG, 6 decimals): how deep a leg's pool must be,
     *    at construction and at every read, for the leg to be live: the USDG its
     *    30-minute harmonic-mean in-range liquidity holds within 2 % of the TWAP on either side
     *    (`MaidMarianEtfPoolDepth`; security review 2026-10-17, second pass, B-1 / B-2: the
     *    pool's USDG balance, read until then, was lent or emptied for one call).
     *  - `feedPoolGapBps` (none; 100 - 2 000): how far a feed may stand from its leg's pool TWAP,
     *    in bps of the TWAP, before the leg is dead (lot B, security review 2026-10-17, R3).
     */
    struct Params {
        uint16 entryFeeBps;
        uint16 exitFeeBps;
        uint16 earlyExitPenaltyBps;
        uint32 holdPeriod;
        uint16 managementFeeBps;
        uint16 nonMinterExitBps;
        uint16 deadBandBps;
        uint16 deadBandFloorBps;
        uint16 toleranceBps;
        uint32 mintFeedAge;
        uint32 minInterval;
        uint32 deadFeedAge;
        uint32 feedNotice;
        uint96 poolDepthFloor;
        uint16 feedPoolGapBps;
    }

    /**
     * One swap on the Universal Router. In `rebalance`, `leg` names the leg and `sell` its side; in
     * `mint` and `redeem` the array position is the leg and the side is the door's, so `leg`
     * and `sell` are not read there.
     */
    struct Route {
        uint8 leg;
        bool sell;
        uint256 amountIn;
        bytes commands;
        bytes[] inputs;
        uint256 deadline;
    }

    /// One leg as `legs()` shows it. `avgCost` is USDG (6 decimals) paid per whole token;
    /// `parts` the weight given at deployment, `targetBps` the same as a share of the fund
    /// (`parts x 10 000 / sum of parts`, rounded down). `answer` is the price the leg is valued
    /// at, in `feedDecimals` (18 for a TWAP leg, whose `updatedAt` is now); `twap` the pool's
    /// price in the same units, 0 without a pool or while it is dead; `disagrees` true while a
    /// live feed stands more than `FEED_POOL_GAP_BPS` from a pool, or its pool is dead.
    struct Leg {
        address token;
        address feed;
        address pool;
        uint8 feedDecimals;
        uint16 parts;
        uint256 targetBps;
        uint256 held;
        int256 answer;
        uint256 twap;
        uint256 updatedAt;
        bool live;
        bool disagrees;
        uint256 cost;
        uint256 avgCost;
        uint256 value;
    }

    /// One trade `rebalance` would accept today, as `plan()` lists it.
    struct PlanLeg {
        uint8 leg;
        address token;
        bool sell;
        uint256 amountIn;
        uint256 minOut;
        int256 deviationBps;
    }

    /// Why `mint` is closed, as `canMint()` says it; `Open` when it is not.
    enum MintGuard {
        Open,
        LegDead,
        FeedStale,
        FeedNotice,
        LegDisagrees
    }

    /// A redeem's split of `shares` (`_exitSplit`): the shares paid out, the supply they are a
    /// share of (set by `_exit`), the owner's fee, the minted part, its early penalty, and the
    /// non-minter shares burned on the rest.
    struct Exit {
        uint256 paid;
        uint256 supply;
        uint256 feeShares;
        uint256 covered;
        uint256 penaltyShares;
        uint256 nonMinterShares;
    }

    /// Which sensor holds `rebalance` back, as `canRebalance()` says it.
    enum Sensor {
        Ready,
        TooSoon,
        FeedNotMoved
    }

    /// One leg read at one instant: the balance, the channel, and what follows from them.
    /// `target` is the leg's share of `nav` by its parts among the live legs' parts; 0 for a dead
    /// leg. `hasFeed` says the leg has a feed, whose round the rebalance sensor waits for;
    /// `frozen` that `rebalance` and `plan` hold a live leg as dead for its replacement's notice.
    struct State {
        uint256 held;
        int256 answer;
        uint256 updatedAt;
        uint256 roundId;
        bool live;
        bool hasFeed;
        bool disagrees;
        bool frozen;
        uint256 twap;
        uint256 value;
        uint256 target;
    }

    /// The fund read at one instant, everything `rebalance` and `plan` decide from.
    struct Snapshot {
        State[] legs;
        uint256 usdgHeld;
        uint256 nav;
        uint256 liveCount;
        uint256 liveParts;
    }

    // ----------------------------------------------------------- immutables ---

    /// The quote currency, 6 decimals on chain 4663.
    IERC20 public immutable USDG;

    /// The official Uniswap Universal Router every swap runs on, pre-funded by a plain transfer.
    IUniversalRouter public immutable UNIVERSAL_ROUTER;

    /// The Uniswap V3 factory a leg's pool must come from: `getPool(token, USDG, pool.fee())`
    /// names it (security review 2026-10-17, second pass, B-1: without it the owner replaced GLD's
    /// pool by a contract with the two tokens, the USDG and the mean tick he wrote). Given at
    /// deployment from `script/etfs/index.json`, never written in this source.
    address public immutable UNISWAP_V3_FACTORY;

    /// The TWAP reader, `MaidMarianPriceRegistry`'s own (`MaidMarianBagPoolOracle`: `observe([1800,
    /// 0])`, the mean tick rounded down, the tick to a price in `FullMath`), deployed by this
    /// constructor as the registry's deploys it, so the ETF has no second TWAP and no address
    /// to trust: a sentinel `(0, false)` for a pool that cannot answer.
    MaidMarianBagPoolOracle public immutable POOL_ORACLE;

    /// How many legs this ETF holds, 2 to `MAX_LEGS`.
    uint256 public immutable LEGS;

    /// The sum of the legs' parts: leg i's target is `parts_i / TOTAL_PARTS` of the fund.
    uint256 public immutable TOTAL_PARTS;

    /// The parameters (`Params`, which says what each one does), immutable after the constructor.
    uint256 public immutable ENTRY_FEE_BPS;
    uint256 public immutable EXIT_FEE_BPS;
    uint256 public immutable EARLY_EXIT_PENALTY_BPS;
    uint256 public immutable HOLD_PERIOD;
    uint256 public immutable MANAGEMENT_FEE_BPS;
    uint256 public immutable NON_MINTER_EXIT_BPS;
    uint256 public immutable DEAD_BAND_BPS;
    uint256 public immutable DEAD_BAND_FLOOR_BPS;
    uint256 public immutable TOLERANCE_BPS;
    uint256 public immutable MINT_FEED_AGE;
    uint256 public immutable MIN_INTERVAL;
    uint256 public immutable DEAD_FEED_AGE;
    uint256 public immutable FEED_NOTICE;
    uint256 public immutable POOL_DEPTH_FLOOR;
    uint256 public immutable FEED_POOL_GAP_BPS;

    // ---------------------------------------------------------------- legs ---

    /**
     * One leg as stored. Its value is `rawBalance x answer / scale`, in USDG (6 decimals), with
     * `scale = 10^(feedDecimals + tokenDecimals - 6)`. A feed leg's `answer` is the feed's;
     * Chainlink stock answers already include `uiMultiplier()` (ERC-8056). A
     * TWAP leg's is the pool's price of `scale` raw units, in USDG units, with `feedDecimals` set
     * to 18 - a price in 18 decimals, so the same formula values it; a pool trades raw units, so
     * its price is already per raw unit, as the feed's answer is, and `uiMultiplier()` is applied
     * by neither, as `MaidMarianPriceRegistry` applies it to neither (doing it would be the
     * quadratic error).
     *
     * Dead: a feed that does not answer five words, answers <= 0, or has not written for
     * `DEAD_FEED_AGE`; a pool under `POOL_DEPTH_FLOOR` deep (`MaidMarianEtfPoolDepth`), or whose `observe` cannot
     * reach 30 minutes back; a feed leg with a pool that is dead or more than `FEED_POOL_GAP_BPS`
     * from the feed. A dead leg is not valued, not traded, not waited for, and the live legs
     * share the NAV by their parts. `token`, `tokenDecimals`, `parts` and `scale` are write-once
     * storage: written in the constructor and by no function after it - the compiler cannot
     * enforce it, the absence of any writer and `test_TheSevenLegsReadBackAsConstructedAfterAFullDay`
     * do. `feed` and `feedDecimals` change only through `replaceFeed`, over a dead feed; `pool`
     * only through `replacePool`, over a dead pool. Four slots a leg (m7m's three and the pool).
     */
    struct LegConfig {
        IERC20 token;
        uint8 feedDecimals;
        uint8 tokenDecimals;
        uint16 parts;
        address feed;
        uint256 scale;
        address pool;
    }

    LegConfig[MAX_LEGS] private _legs;

    /// When the owner last replaced each leg's feed or pool (`replaceFeed`, `replacePool`); 0 if
    /// never. `mint` waits `FEED_NOTICE` after it. The name is m7m's, kept for its readers.
    uint256[MAX_LEGS] public feedReplacedAt;

    // ---------------------------------------------------------------- state ---

    /// When the last rebalance ran; 0 at birth, so the first one needs no wait.
    uint256 public lastRebalanceAt;

    /// When the management fee was last accrued; the deploy time at birth, the first mint's
    /// time after it.
    uint256 public lastAccrualAt;

    uint256[MAX_LEGS] private _cost;
    uint256[MAX_LEGS] private _roundAt;
    uint256 private _lastNav;
    uint8 private _lastLiveCount;
    uint8 private _lastLegsTraded;

    /// Each address's balance-weighted acquisition time: on receiving `amount` with `bal` held,
    /// `(bal x heldSince + amount x now) / (bal + amount)`. An exit before `HOLD_PERIOD` after it
    /// pays the early penalty, falling linearly from `EARLY_EXIT_PENALTY_BPS`, on its minted shares.
    mapping(address holder => uint256) public heldSince;

    /// The shares each address minted and still holds:
    /// `+shares` at every mint to it - the doors' and the owner's
    /// fees, which are shares the contract created, not shares bought on a pool; the exit fee the
    /// owner receives in shares counts likewise - `-min(mintedBy, amount)` on every transfer out,
    /// so a minter who sold on a pool cannot launder pool-bought shares under an old counter, and
    /// `-covered` at a redeem. A redeem of `s` shares is `covered = min(s, mintedBy)` under the
    /// normal rules and `s - covered` that pay `NON_MINTER_EXIT_BPS` whatever their age.
    mapping(address holder => uint256) public mintedBy;

    // --------------------------------------------------------------- events ---

    /// `credit` is what the legs were credited at Chainlink, `navAt` the nav the shares were priced
    /// at (both 0 on the first mint, priced at one share per USDG).
    event Minted(address indexed by, address indexed to, uint256 usdgIn, uint256 shares, uint256 feeUsdg, uint256 credit, uint256 navAt);
    event MintedInKind(address indexed by, address indexed to, uint256[] amounts, uint256 usdgIn, uint256 shares, uint256 feeShares);
    /// Both redeems say both parts of `shares`: `covered`, the shares the redeemer had minted
    /// (`mintedBy`), which pay the early penalty `penaltyShares` by age, and `shares - covered`,
    /// which pay `nonMinterShares`; `feeShares` is the owner's, on all of them. `inKind[i]` is
    /// the unsold remainder of leg i paid as tokens; `usdgOut` all the USDG paid.
    event Redeemed(address indexed by, address indexed to, uint256 shares, uint256 usdgOut, uint256 feeShares, uint256 covered, uint256 penaltyShares, uint256 nonMinterShares, uint256[] inKind);
    /// `amounts[i]` and `usdgOut` are what was paid (0 where forfeited); `forfeited` the mask.
    event RedeemedInKind(
        address indexed by, address indexed to, uint256 shares, uint256 feeShares, uint256 covered, uint256 penaltyShares, uint256 nonMinterShares, uint256[] amounts, uint256 usdgOut, uint16 forfeited
    );
    event Rebalanced(uint256 nav, uint256 liveCount, uint256 legsTraded, uint256 feeShares);
    event LegTraded(address indexed token, bool sell, uint256 amountIn, uint256 amountOut, int256 answer);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event FeedReplaced(uint8 indexed leg, address oldFeed, address newFeed);
    event PoolReplaced(uint8 indexed leg, address oldPool, address newPool);

    // --------------------------------------------------------------- errors ---

    error ZeroAddress();
    error NoCode(address account);
    error BadToken(address token);
    error BadFeed(address feed);
    error DuplicateToken(address token);
    error BadLegCount(uint256 count);
    error BadParts(address token);
    error BadPool(address pool);
    error WrongLength(uint256 length, uint256 legs);
    error NothingToMint();
    error NothingToRedeem();
    error RoutesDoNotSpendInput(uint256 routed, uint256 net);
    error TooFewShares(uint256 shares, uint256 minShares);
    error FirstMintIsUsdg();
    error OverRedeem(address token, uint256 amountIn, uint256 due);
    error TooLittleOut(uint256 usdgOut, uint256 minUsdgOut);
    error TooSoon(uint256 readyAt);
    error FeedNotMoved(address token);
    error UnknownLeg(uint8 leg);
    error LegNotDue(address token);
    error DuplicateLeg(address token);
    error SellsFirst();
    error OverTrade(address token, uint256 amountIn, uint256 max);
    error NotRescuable(address token);
    error NativeTransferFailed(address to, uint256 amount);
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    error RenounceForbidden();
    error FeedStillLive(uint8 leg);
    error LegDead(address token);
    error FeedStale(address token, uint256 updatedAt);
    error NothingDelivered(address token);
    error FeedNotice(uint8 leg, uint256 readyAt);
    error LegNotBrought(address token);
    error FirstMintUnderDelivered(address token, uint256 value, uint256 floorOf);
    error FirstMintTooSmall(address token, uint256 amountIn, uint256 minimum);
    error MintUnbalances(address token);
    error ParamOutOfBounds(string name);
    error NotHolder();
    error LegDisagrees(uint8 leg);
    error PoolStillLive(uint8 leg);
    error NoFeed(uint8 leg);
    error NoPool(uint8 leg);

    // ---------------------------------------------------------- constructor ---

    /**
     * @param name_ The share token's name.
     * @param symbol_ The share token's symbol.
     * @param legs_ The legs, in order, 2 to `MAX_LEGS` (`BadLegCount`). Each token must have
     * code, answer `decimals()`, differ from the others and from USDG; a feed must answer
     * `decimals()` and `latestRoundData()` with five words, its decimals stored once; a pool must
     * be the token against USDG (`token0` / `token1`), `factory`'s `getPool(token, USDG, fee())`,
     * `poolDepthFloor` deep and answer a 30-minute TWAP above 0 (`BadPool`); a feed or a pool or
     * both (`ZeroAddress`); `parts` at least 1 (`BadParts`).
     * @param p The parameters (see `Params`), each within its bounds (`ParamOutOfBounds(name)`),
     * fixed for life.
     * @param usdg The quote currency.
     * @param router The Universal Router; must have code.
     * @param factory The Uniswap V3 factory every pool must come from; must have code.
     * @param owner_ Receives the fees; rebalances, replaces a dead feed, rescues strangers' tokens, nothing
     * else.
     */
    constructor(string memory name_, string memory symbol_, LegInit[] memory legs_, Params memory p, IERC20 usdg, IUniversalRouter router, address factory, address owner_)
        ERC20(name_, symbol_)
        Ownable(owner_)
    {
        if (address(usdg) == address(0) || address(router) == address(0) || factory == address(0)) revert ZeroAddress();
        if (address(usdg).code.length == 0) revert NoCode(address(usdg));
        if (address(router).code.length == 0) revert NoCode(address(router));
        if (factory.code.length == 0) revert NoCode(factory);
        _checkParams(p);
        uint256 n = legs_.length;
        if (n < 2 || n > MAX_LEGS) revert BadLegCount(n);
        // The immutables cannot be read before the constructor ends, so the pool checks below
        // take the oracle, the factory and the floor as arguments.
        MaidMarianBagPoolOracle oracle = new MaidMarianBagPoolOracle();

        uint256 totalParts;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < i; j++) {
                if (legs_[j].token == legs_[i].token) revert DuplicateToken(legs_[i].token);
            }
            _initLeg(i, legs_[i], usdg, oracle, factory, p.poolDepthFloor);
            totalParts += legs_[i].parts;
        }

        USDG = usdg;
        UNIVERSAL_ROUTER = router;
        UNISWAP_V3_FACTORY = factory;
        POOL_ORACLE = oracle;
        LEGS = n;
        TOTAL_PARTS = totalParts;
        ENTRY_FEE_BPS = p.entryFeeBps;
        EXIT_FEE_BPS = p.exitFeeBps;
        EARLY_EXIT_PENALTY_BPS = p.earlyExitPenaltyBps;
        HOLD_PERIOD = p.holdPeriod;
        MANAGEMENT_FEE_BPS = p.managementFeeBps;
        NON_MINTER_EXIT_BPS = p.nonMinterExitBps;
        DEAD_BAND_BPS = p.deadBandBps;
        DEAD_BAND_FLOOR_BPS = p.deadBandFloorBps;
        TOLERANCE_BPS = p.toleranceBps;
        MINT_FEED_AGE = p.mintFeedAge;
        MIN_INTERVAL = p.minInterval;
        DEAD_FEED_AGE = p.deadFeedAge;
        FEED_NOTICE = p.feedNotice;
        POOL_DEPTH_FLOOR = p.poolDepthFloor;
        FEED_POOL_GAP_BPS = p.feedPoolGapBps;

        lastAccrualAt = block.timestamp;
    }

    /// One leg's checks and its write-once storage (the constructor's loop body, apart so the
    /// constructor's stack holds).
    function _initLeg(uint256 i, LegInit memory leg, IERC20 usdg, MaidMarianBagPoolOracle oracle, address factory, uint256 floor) private {
        (address token, address feed, address pool) = (leg.token, leg.feed, leg.pool);
        if (token == address(0) || (feed == address(0) && pool == address(0))) revert ZeroAddress();
        if (leg.parts == 0) revert BadParts(token);
        if (token.code.length == 0) revert NoCode(token);
        if (token == address(usdg)) revert DuplicateToken(token);

        (bool tokenOk, uint256 tokenDecimals) = _readUint(token, 0x313ce567); // decimals()
        if (!tokenOk || tokenDecimals > 36) revert BadToken(token);
        // A TWAP leg's price is carried in 18 decimals (`LegConfig`).
        uint256 feedDecimals = feed == address(0) ? 18 : _checkFeed(feed);
        if (feedDecimals + tokenDecimals < 6) revert BadToken(token);
        uint256 scale = 10 ** (feedDecimals + tokenDecimals - 6);
        if (pool != address(0)) _checkPool(oracle, usdg, factory, floor, pool, token, scale);

        // Both are <= 36, checked above, so the casts keep their values.
        _legs[i] = LegConfig({
            token: IERC20(token),
            // forge-lint: disable-next-line(unsafe-typecast)
            feedDecimals: uint8(feedDecimals),
            // forge-lint: disable-next-line(unsafe-typecast)
            tokenDecimals: uint8(tokenDecimals),
            parts: leg.parts,
            feed: feed,
            scale: scale,
            pool: pool
        });
    }

    /// Every parameter against its bounds, by name.
    function _checkParams(Params memory p) private pure {
        _bound(p.entryFeeBps, 0, 100, "entryFeeBps");
        _bound(p.exitFeeBps, 0, 200, "exitFeeBps");
        _bound(p.earlyExitPenaltyBps, 0, 2000, "earlyExitPenaltyBps");
        _bound(p.holdPeriod, 0, 30 days, "holdPeriod");
        _bound(p.managementFeeBps, 0, 300, "managementFeeBps");
        _bound(p.nonMinterExitBps, 0, BPS - p.exitFeeBps, "nonMinterExitBps");
        _bound(p.deadBandBps, 100, 5000, "deadBandBps");
        _bound(p.deadBandFloorBps, 0, 500, "deadBandFloorBps");
        _bound(p.toleranceBps, 20, 500, "toleranceBps");
        _bound(p.mintFeedAge, 1 hours, 7 days, "mintFeedAge");
        _bound(p.minInterval, 1 hours, 7 days, "minInterval");
        _bound(p.deadFeedAge, 1 days, 30 days, "deadFeedAge");
        _bound(p.feedNotice, 0, 14 days, "feedNotice");
        _bound(p.poolDepthFloor, 10_000e6, type(uint96).max, "poolDepthFloor");
        _bound(p.feedPoolGapBps, 100, 2000, "feedPoolGapBps");
    }

    function _bound(uint256 value, uint256 lo, uint256 hi, string memory name) private pure {
        if (value < lo || value > hi) revert ParamOutOfBounds(name);
    }

    // ---------------------------------------------------------------- doors ---

    /**
     * @notice Buy into the fund with USDG - and rebalance it, since new money can go where it is
     * missing (author, 2026-10-15: the rebalancing happens at the moment of purchase). The entry
     * fee, `ENTRY_FEE_BPS` of `usdgIn`, goes to the owner in USDG before any route runs; each
     * `routes[i].amountIn` of the rest is swapped into leg i on the router (0 skips the leg),
     * and they must sum to exactly `usdgIn - fee` (`RoutesDoNotSpendInput`); one route a leg
     * (`WrongLength`). The split is the caller's - `mintPlan` advises one - within one rule: no
     * leg may end out of its dead band unless it was already out on the same side and its gap,
     * as a share of `nav`, did not grow (`MintUnbalances`; author, 2026-10-17, R2: "on se protege
     * de soi-meme" - new money cannot make the turnover the next rebalance would pay at the
     * tolerance).
     *
     * Shares: the first mint gives one share per USDG that reaches the fund (`(usdgIn - fee) x
     * 1e12`). Afterwards, with `nav` read as `rebalance` reads it (live legs at Chainlink plus
     * USDG held, before this USDG arrives), each leg credits `min(amountIn, delivered x answer /
     * scale)` - you are credited what you paid, never more than it is worth - and `shares = sum
     * of credits x totalSupply / nav`, never more than it is worth.
     *
     * Closed (security review 2026-10-15) while a held leg is dead (`LegDead`: its leg would be
     * out of `nav` and the minter would buy the rest of the fund at a discount) - a held feed leg
     * whose pool is dead or disagrees with the feed says `LegDisagrees` (review 2026-10-17, R3) -
     * or any live feed's last round is older than `MINT_FEED_AGE` (`FeedStale`: creations during
     * market hours; a TWAP leg has no age), and for `FEED_NOTICE` after the owner replaced a feed
     * or a pool (`FeedNotice`). "Chainlink" below is the leg's channel: its feed, or its TWAP.
     * The first mint needs every leg live and fresh, a route of at least `MIN_FIRST_MINT_PER_LEG` (1 USDG) on
     * every leg (`NothingDelivered`, `FirstMintTooSmall`), each leg's delivery worth at Chainlink
     * at least 99 % of both its route's cost and its target share of the net
     * (`FirstMintUnderDelivered`: shares with nothing behind them would brick every later mint),
     * and every leg in its band after it (the fund is born at its weights); it starts the
     * management fee clock.
     * `minShares` applies to what `to` receives; zero shares are refused.
     */
    function mint(uint256 usdgIn, Route[] calldata routes, uint256 minShares, address to) external nonReentrant returns (uint256 shares) {
        if (to == address(0)) revert ZeroAddress();
        if (usdgIn == 0) revert NothingToMint();
        uint256 n = LEGS;
        if (routes.length != n) revert WrongLength(routes.length, n);
        uint256 feeUsdg = usdgIn * ENTRY_FEE_BPS / BPS;
        uint256 net = usdgIn - feeUsdg;
        uint256 routed;
        for (uint256 i = 0; i < n; i++) {
            routed += routes[i].amountIn;
        }
        if (routed != net) revert RoutesDoNotSpendInput(routed, net);

        uint256 supply = totalSupply();
        Snapshot memory s = _snapshot();
        (MintGuard guard, uint256 leg, uint256 readyAt) = _mintGuard(s, supply);
        if (guard != MintGuard.Open) {
            address token = address(_legs[leg].token);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (guard == MintGuard.FeedNotice) revert FeedNotice(uint8(leg), readyAt);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (guard == MintGuard.LegDisagrees) revert LegDisagrees(uint8(leg));
            if (guard == MintGuard.LegDead) revert LegDead(token);
            revert FeedStale(token, s.legs[leg].updatedAt);
        }
        if (supply == 0) {
            for (uint256 i = 0; i < n; i++) {
                uint256 amountIn = routes[i].amountIn;
                if (amountIn == 0) revert NothingDelivered(address(_legs[i].token));
                if (amountIn < MIN_FIRST_MINT_PER_LEG) revert FirstMintTooSmall(address(_legs[i].token), amountIn, MIN_FIRST_MINT_PER_LEG);
            }
        }
        USDG.safeTransferFrom(msg.sender, address(this), net);
        if (feeUsdg > 0) USDG.safeTransferFrom(msg.sender, owner(), feeUsdg);

        uint256 credit;
        uint256[] memory values = new uint256[](supply == 0 ? n : 0);
        for (uint256 i = 0; i < n; i++) {
            uint256 amountIn = routes[i].amountIn;
            if (amountIn == 0) continue;
            LegConfig memory c = _legs[i];
            (IERC20 token, uint256 scale) = (c.token, c.scale);
            uint256 delivered = _swap(USDG, token, amountIn, 0, routes[i]);
            if (supply == 0) {
                if (delivered == 0) revert NothingDelivered(address(token));
                // The first mint prices every share; each leg must bring at least 99 % of what it
                // cost at Chainlink, or a 1-wei delivery would leave shares over nothing (second
                // review pass, L-a). The feed is live and fresh: checked above.
                uint256 value = Math.mulDiv(delivered, uint256(s.legs[i].answer), scale);
                if (value < amountIn * 99 / 100) revert FirstMintUnderDelivered(address(token), value, amountIn);
                values[i] = value;
            }
            // The leg's credit is also its cost, not `amountIn` (security review 2026-10-17, R5: a
            // route that swapped 1 USDG and swept 99 back to the minter booked 100 for 1 of value).
            // A dead leg is credited and booked 0, as `mintInKind` books it.
            uint256 worth = s.legs[i].live ? Math.min(amountIn, Math.mulDiv(delivered, uint256(s.legs[i].answer), scale)) : 0;
            _cost[i] += worth;
            credit += worth;
        }

        if (supply == 0) {
            // And at least 99 % of its target share of the net: the fund is born
            // at its weights, whatever split the first minter chose.
            for (uint256 i = 0; i < n; i++) {
                uint256 targetIn = Math.mulDiv(net, _legs[i].parts, TOTAL_PARTS);
                if (values[i] < targetIn * 99 / 100) revert FirstMintUnderDelivered(address(_legs[i].token), values[i], targetIn);
            }
            lastAccrualAt = block.timestamp;
        }
        _checkBalanced(s, supply == 0);
        if (supply == 0) credit = 0;
        shares = supply == 0 ? net * 1e12 : (s.nav == 0 ? 0 : Math.mulDiv(credit, supply, s.nav));
        if (shares == 0 || shares < minShares) revert TooFewShares(shares, minShares);
        _mint(to, shares);
        emit Minted(msg.sender, to, usdgIn, shares, feeUsdg, credit, supply == 0 ? 0 : s.nav);
    }

    /**
     * @notice Bring the legs instead of buying them. `amounts[i]` of leg i is pulled from the
     * caller; shares are `totalSupply x min over legs held of (brought / held)`, no oracle - the
     * excess on other legs stays in the fund, for every holder. The fund's USDG is one more
     * balance: `usdgHeld x shares / totalSupply` is pulled too, rounded up (security review
     * 2026-10-15, M6: without it the mint took a share of USDG it never brought). The entry fee
     * is `ENTRY_FEE_BPS` of the shares, minted to the owner. Never the first mint
     * (`FirstMintIsUsdg`): the first share is born at 1 USDG through `mint`, and only there. No
     * swap, no route; the feeds are read to book what came in at Chainlink value (`cost`), 0 for
     * a dead feed, and to refuse an excess that would push a live leg out of its band
     * (`MintUnbalances`, as `mint`).
     */
    function mintInKind(uint256[] calldata amounts, uint256 minShares, address to) external nonReentrant returns (uint256 shares) {
        if (to == address(0)) revert ZeroAddress();
        uint256 n = LEGS;
        if (amounts.length != n) revert WrongLength(amounts.length, n);
        uint256 supply = totalSupply();
        if (supply == 0) revert FirstMintIsUsdg();

        Snapshot memory s = _snapshot();
        uint256[] memory held = new uint256[](n);
        uint256[] memory received = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            LegConfig memory c = _legs[i];
            (IERC20 token, uint256 scale) = (c.token, c.scale);
            held[i] = s.legs[i].held;
            if (amounts[i] == 0) {
                if (held[i] > 0) revert LegNotBrought(address(token));
                continue;
            }
            token.safeTransferFrom(msg.sender, address(this), amounts[i]);
            received[i] = token.balanceOf(address(this)) - held[i];
            // A live answer is > 0 (`_isLive`), so the cast keeps its value.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (s.legs[i].live) _cost[i] += Math.mulDiv(received[i], uint256(s.legs[i].answer), scale);
        }

        uint256 gross = _ratioShares(supply, held, received);
        uint256 usdgIn = Math.mulDiv(s.usdgHeld, gross, supply, Math.Rounding.Ceil);
        if (usdgIn > 0) USDG.safeTransferFrom(msg.sender, address(this), usdgIn);
        _checkBalanced(s, false);
        uint256 feeShares = gross * ENTRY_FEE_BPS / BPS;
        shares = gross - feeShares;
        if (shares == 0 || shares < minShares) revert TooFewShares(shares, minShares);
        if (feeShares > 0) _mint(owner(), feeShares);
        _mint(to, shares);
        emit MintedInKind(msg.sender, to, amounts, usdgIn, shares, feeShares);
    }

    /**
     * @notice Leave for USDG. The exit fee comes first, in shares, as in `redeemInKind`:
     * `EXIT_FEE_BPS` of `shares` to the owner, and burned without payout the early penalty on
     * the minted part and `NON_MINTER_EXIT_BPS` on the rest (`_exit`; security review
     * 2026-10-15, H1: a fee measured on the USDG the routes brought was 0 for routes paying
     * the redeemer directly). The rest, `paid`, is burned
     * and `due[i] = held[i] x paid / totalSupply`; `routes[i]` sells `amountIn <= due[i]` of leg
     * i to USDG and the remainder goes to `to` in kind, so a holding that moved between a preview
     * and the transaction never makes this revert. The fund's own USDG is paid pro rata too. No
     * feed read. `minUsdgOut` floors the USDG `to` receives. One route a leg (`WrongLength`).
     */
    function redeem(uint256 shares, Route[] calldata routes, uint256 minUsdgOut, address to) external nonReentrant returns (uint256 usdgOut) {
        if (to == address(0)) revert ZeroAddress();
        uint256 n = LEGS;
        if (routes.length != n) revert WrongLength(routes.length, n);
        Exit memory e = _exit(shares);
        (uint256 paid, uint256 supply) = (e.paid, e.supply);
        uint256[] memory held = _heldAll();
        usdgOut = Math.mulDiv(USDG.balanceOf(address(this)), paid, supply);
        _burn(msg.sender, paid + e.penaltyShares + e.nonMinterShares);

        uint256[] memory inKind = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            IERC20 token = _legs[i].token;
            uint256 due = Math.mulDiv(held[i], paid, supply);
            uint256 amountIn = routes[i].amountIn;
            if (amountIn > due) revert OverRedeem(address(token), amountIn, due);
            if (due == 0) continue;
            _cost[i] -= Math.mulDiv(_cost[i], due, held[i]);
            if (amountIn > 0) usdgOut += _swap(token, USDG, amountIn, 0, routes[i]);
            inKind[i] = due - amountIn;
            if (inKind[i] > 0) token.safeTransfer(to, inKind[i]);
        }

        if (usdgOut < minUsdgOut) revert TooLittleOut(usdgOut, minUsdgOut);
        if (usdgOut > 0) USDG.safeTransfer(to, usdgOut);
        emit Redeemed(msg.sender, to, shares, usdgOut, e.feeShares, e.covered, e.penaltyShares, e.nonMinterShares, inKind);
    }

    /**
     * @notice Leave in kind. No USDG flows, so the exit fee is in shares: `EXIT_FEE_BPS` of
     * `shares` move from the caller to the owner; the early penalty on the minted part and
     * `NON_MINTER_EXIT_BPS` on the rest are burned without payout, which raises every remaining
     * holder's part (`_exit`); the rest is
     * burned and paid as `held[i] x paid / totalSupply` of each leg and the same share of the
     * fund's USDG. No route, no feed, no router, nothing that can be paused: the door that
     * always works.
     *
     * `allowFail` makes it work even when a token does not (author, 2026-10-15: the mechanism
     * must never jam): bit i for leg i, bit `USDG_BIT` (15) for USDG whatever the leg count (m7m
     * had it on bit 7), meaning "I accept that this transfer may fail". Every transfer is always attempted. Bit
     * unset: `safeTransfer`, a failure reverts the whole redeem. Bit set: a low-level
     * `transfer(to, amount)` whose revert or false return is a sentinel - the amount stays in the
     * fund for the remaining holders, the redeem goes on, and `forfeited` in `RedeemedInKind`
     * names the legs. A transfer that succeeds always delivers, whatever the mask: a frozen token
     * can be waived, never a working one.
     */
    function redeemInKind(uint256 shares, address to, uint16 allowFail) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 n = LEGS;
        Exit memory e = _exit(shares);
        (uint256 paid, uint256 supply) = (e.paid, e.supply);
        uint256[] memory held = _heldAll();
        uint256 usdgOut = Math.mulDiv(USDG.balanceOf(address(this)), paid, supply);
        _burn(msg.sender, paid + e.penaltyShares + e.nonMinterShares);

        uint16 forfeited;
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 due = Math.mulDiv(held[i], paid, supply);
            if (due == 0) continue;
            if (!_pay(_legs[i].token, to, due, allowFail, i)) {
                forfeited |= uint16(1 << i);
                continue;
            }
            amounts[i] = due;
            _cost[i] -= Math.mulDiv(_cost[i], due, held[i]);
        }
        if (usdgOut > 0 && !_pay(USDG, to, usdgOut, allowFail, USDG_BIT)) {
            forfeited |= uint16(1 << USDG_BIT);
            usdgOut = 0;
        }
        emit RedeemedInKind(msg.sender, to, shares, e.feeShares, e.covered, e.penaltyShares, e.nonMinterShares, amounts, usdgOut, forfeited);
    }

    /// `mint`'s guards, leg by leg, the first one that closes it: a notice running after a feed
    /// or a pool was replaced, a dead leg that is held (any leg on the first mint) - `LegDisagrees`
    /// when it is a live feed its pool does not vouch for -, a live feed older than
    /// `MINT_FEED_AGE`. `readyAt` is when a notice ends; 0 otherwise (a stale feed opens at its
    /// next round, which nobody can date). A TWAP leg's `updatedAt` is now: it is never stale.
    function _mintGuard(Snapshot memory s, uint256 supply) private view returns (MintGuard guard, uint256 leg, uint256 readyAt) {
        for (uint256 i = 0; i < LEGS; i++) {
            State memory l = s.legs[i];
            if (_noticeRunning(i)) return (MintGuard.FeedNotice, i, feedReplacedAt[i] + FEED_NOTICE);
            if (!l.live) {
                if (l.held > 0 || supply == 0) return (l.disagrees ? MintGuard.LegDisagrees : MintGuard.LegDead, i, 0);
            } else if (l.updatedAt < block.timestamp && block.timestamp - l.updatedAt > MINT_FEED_AGE) {
                return (MintGuard.FeedStale, i, 0);
            }
        }
        return (MintGuard.Open, 0, 0);
    }

    /// Both redeems' fees, in shares and before anything else (`_exitSplit`): the exit fee moved
    /// to the owner and counted as minted by him, the redeemer's counter down by `covered`, the
    /// early penalty and the non-minter shares left to be burned with the rest.
    function _exit(uint256 shares) private returns (Exit memory e) {
        if (shares == 0) revert NothingToRedeem();
        e = _exitSplit(msg.sender, shares);
        uint256 minted = mintedBy[msg.sender];
        address owner_ = owner();
        // The fee's transfer runs `_update`'s transfer-out rule on the redeemer's counter; the
        // line after it sets the counter to what the redeem leaves, whatever that rule did.
        if (e.feeShares > 0) _transfer(msg.sender, owner_, e.feeShares);
        mintedBy[msg.sender] = minted - e.covered;
        if (e.feeShares > 0) mintedBy[owner_] += e.feeShares;
        e.supply = totalSupply();
    }

    /// What a redeem of `shares` by `holder` pays now: `covered = min(shares, mintedBy)`;
    /// `EXIT_FEE_BPS` of all the shares to the owner; the early penalty on `covered`,
    /// `EARLY_EXIT_PENALTY_BPS x (HOLD_PERIOD - age) / HOLD_PERIOD` with `age` from
    /// `heldSince`, 0 at `age >= HOLD_PERIOD`; `NON_MINTER_EXIT_BPS` on `shares - covered`,
    /// whatever their age. Each rounded down, so the fund never takes more than its rate; the
    /// constructor's `exitFeeBps + nonMinterExitBps <= 10 000` keeps `paid` from going below 0.
    function _exitSplit(address holder, uint256 shares) private view returns (Exit memory e) {
        e.covered = Math.min(shares, mintedBy[holder]);
        e.feeShares = shares * EXIT_FEE_BPS / BPS;
        uint256 since = heldSince[holder];
        if (block.timestamp < since + HOLD_PERIOD) {
            e.penaltyShares = Math.mulDiv(e.covered, EARLY_EXIT_PENALTY_BPS * (since + HOLD_PERIOD - block.timestamp), HOLD_PERIOD * BPS);
        }
        e.nonMinterShares = (shares - e.covered) * NON_MINTER_EXIT_BPS / BPS;
        e.paid = shares - e.feeShares - e.penaltyShares - e.nonMinterShares;
    }

    /// @notice What a redeem of minted shares by `holder` would cost now, in basis points,
    /// rounded down: `EXIT_FEE_BPS` to the owner plus the early penalty to the fund, falling
    /// linearly from `EARLY_EXIT_PENALTY_BPS` to 0 over `HOLD_PERIOD` of `heldSince(holder)`.
    /// Shares beyond `mintedBy(holder)` pay `EXIT_FEE_BPS + NON_MINTER_EXIT_BPS` instead.
    function exitFeeBps(address holder) external view returns (uint256) {
        uint256 since = heldSince[holder];
        if (block.timestamp >= since + HOLD_PERIOD) return EXIT_FEE_BPS;
        return EXIT_FEE_BPS + EARLY_EXIT_PENALTY_BPS * (since + HOLD_PERIOD - block.timestamp) / HOLD_PERIOD;
    }

    /// Every share movement. A receiver's clock moves to the balance-weighted mean of what it held
    /// and what arrives (mints and transfers alike, fees included), so 1 wei from a stranger
    /// cannot restart it and a whole balance moved to a fresh address starts a fresh clock. What
    /// was held counts as at most one `HOLD_PERIOD` old in the mean (security review 2026-10-15,
    /// M7: an old small balance otherwise banked enough age to launder any fresh mint). Burns and
    /// sends leave the sender's clock alone; a transfer to oneself changes nothing. A mint adds to
    /// the receiver's `mintedBy`; a transfer out takes `min(mintedBy, value)` from the sender's
    /// (the receiver's counter does not move: shares bought are not shares minted); a burn leaves
    /// it to the redeem, which sets it.
    function _update(address from, address to, uint256 value) internal override {
        uint256 bal = to == address(0) ? 0 : balanceOf(to);
        super._update(from, to, value);
        if (to == address(0) || value == 0 || from == to) return;
        if (from == address(0)) {
            mintedBy[to] += value;
        } else {
            uint256 minted = mintedBy[from];
            if (minted > 0) mintedBy[from] = minted - Math.min(minted, value);
        }
        uint256 since = Math.max(heldSince[to], block.timestamp - HOLD_PERIOD);
        heldSince[to] = bal == 0 ? block.timestamp : (bal * since + value * block.timestamp) / (bal + value);
    }

    // ------------------------------------------------------------ rebalance ---

    /**
     * @notice Bring the live legs back toward their targets, `nav x parts / live parts`. The owner
     * or any holder - an address holding shares at the call - and nobody else (`NotHolder`;
     * author, 2026-10-17, lot C rule 4: m7m's M3 of 2026-10-15 kept strangers out, whose routes
     * could keep everything above the floor), with routes of their own. A caller's routes can keep
     * at most `TOLERANCE_BPS` of the turnover (50 bps by default), a loss shared by the caller's own
     * shares, and since a mint cannot push a leg out of band (`MintUnbalances`, R2: "on se protege
     * de soi-meme") nobody can make that turnover with a mint. A TWAP leg's turnover can be made by
     * pushing its pool for 30 minutes (security review 2026-10-17, second pass, B-3: 3.1 bps of NAV
     * a 10 % push on mGOIL's shape, a holder trading at the band's room): a holder's trade is held
     * to `plan()`'s size, the gap, and the half band of room is the owner's alone. In order:
     *  1. at least `MIN_INTERVAL` since the last pass that closed the window (5.), or
     *     `TooSoon(readyAt)`;
     *  2. the management fee accrued since `lastAccrualAt`, minted to the owner; then every
     *     live feed must have a round newer than the one recorded last time (`FeedNotMoved`) -
     *     weekends and holidays write none, so nothing rebalances on them; a TWAP leg has no
     *     round, so a basket without a live feed waits on `MIN_INTERVAL` alone;
     *  3. `nav = sum of live values + USDG held`, each live leg's target its parts' share of it;
     *     a leg closer to its target than the dead band (`Params`) is in band; a dead leg (a
     *     dead feed, a dead pool, a feed its pool disagrees with) is skipped, and so is a leg
     *     whose feed or pool was replaced less than `FEED_NOTICE` ago - not valued, not waited
     *     for, and a route on it refused `FeedNotice(leg, readyAt)` (B-1 (b): a replaced source
     *     gives nothing at once);
     *  4. each route: a live leg out of band on the side of its delta (`LegNotDue`), at most
     *     one per leg (`DuplicateLeg`), sells before buys (`SellsFirst`), at most the leg's gap
     *     for a holder and never past the target by more than half the leg's band for the owner
     *     (`OverTrade`; security review 2026-10-17, R4: at exactly the target, the plan's own
     *     sizes reverted the pass after any redeem between the read and the transaction - half a
     *     band of room keeps them valid through a redeem of up to `band / (2 x gap)` of the fund,
     *     and leaves the leg in band; a holder's plan-sized pass reverts on such a redeem and is
     *     sent again), floored at the value at its channel minus `TOLERANCE_BPS` on what arrived
     *     (`InsufficientOutput`);
     *  5. the window closes - the rounds and the time recorded - only when at least one route ran
     *     and no live leg is left out of band, re-read at the answers of 3. (B-4: an empty pass,
     *     or one dust trade, took the window, so a 1-wei holder sending one at each `readyAt`
     *     kept every real pass at `TooSoon`).
     * Fewer routes than legs out of band, or smaller amounts, are allowed and leave the window
     * open: the next pass may finish the job at once. An empty `routes` passes the sensors,
     * accrues the fee and changes nothing else. A route that fails - a router revert, an output
     * under its floor - reverts the whole pass: nothing traded, nothing accrued, the window as it
     * was.
     */
    function rebalance(Route[] calldata routes) external nonReentrant {
        bool byOwner = msg.sender == owner();
        if (!byOwner && balanceOf(msg.sender) == 0) revert NotHolder();
        uint256 readyAt = lastRebalanceAt + MIN_INTERVAL;
        if (block.timestamp < readyAt) revert TooSoon(readyAt);

        uint256 feeShares = pendingManagementFee();
        lastAccrualAt = block.timestamp;
        if (feeShares > 0) _mint(owner(), feeShares);

        uint256 n = LEGS;
        Snapshot memory s = _snapshot();
        _freezeNoticed(s);
        for (uint256 i = 0; i < n; i++) {
            if (_waitsForRound(s.legs[i], i)) {
                IERC20 token = _legs[i].token;
                revert FeedNotMoved(address(token));
            }
        }

        uint256 seen;
        bool buying;
        for (uint256 k = 0; k < routes.length; k++) {
            Route calldata r = routes[k];
            if (r.leg >= n) revert UnknownLeg(r.leg);
            LegConfig memory c = _legs[r.leg];
            (IERC20 token, uint256 scale) = (c.token, c.scale);
            // One bit per leg: 1 shifted left by the leg's index (< 10), the order the lint doubts.
            // forge-lint: disable-next-line(incorrect-shift)
            uint256 bit = 1 << r.leg;
            if (seen & bit != 0) revert DuplicateLeg(address(token));
            seen |= bit;
            if (r.sell && buying) revert SellsFirst();
            buying = !r.sell;

            State memory l = s.legs[r.leg];
            if (l.frozen) revert FeedNotice(r.leg, feedReplacedAt[r.leg] + FEED_NOTICE);
            (bool due, bool sell, uint256 gap, uint256 band) = _due(l, s.nav);
            if (!due || sell != r.sell) revert LegNotDue(address(token));

            uint256 answer = uint256(l.answer);
            uint256 room = byOwner ? gap + band / 2 : gap;
            uint256 amountOut;
            if (r.sell) {
                // Never more than held: the room can pass the holding on a leg whose target is 0,
                // and the cost below takes `amountIn / held` of the leg's cost.
                uint256 max = Math.min(Math.mulDiv(room, scale, answer), l.held);
                if (r.amountIn > max) revert OverTrade(address(token), r.amountIn, max);
                amountOut = _swap(token, USDG, r.amountIn, _sellFloor(r.amountIn, answer, scale), r);
                _cost[r.leg] -= Math.mulDiv(_cost[r.leg], r.amountIn, l.held);
            } else {
                if (r.amountIn > room) revert OverTrade(address(token), r.amountIn, room);
                amountOut = _swap(USDG, token, r.amountIn, _buyFloor(r.amountIn, answer, scale), r);
                _cost[r.leg] += r.amountIn;
            }
            emit LegTraded(address(token), r.sell, r.amountIn, amountOut, l.answer);
        }

        if (routes.length > 0 && _noneDueAfter(s)) {
            for (uint256 i = 0; i < n; i++) {
                _roundAt[i] = s.legs[i].roundId;
            }
            lastRebalanceAt = block.timestamp;
            _lastNav = s.nav;
            // At most `MAX_LEGS` (10) live legs; the route count is the owner's, recorded as m7m did.
            // forge-lint: disable-next-line(unsafe-typecast)
            _lastLiveCount = uint8(s.liveCount);
            // forge-lint: disable-next-line(unsafe-typecast)
            _lastLegsTraded = uint8(routes.length);
        }
        emit Rebalanced(s.nav, s.liveCount, routes.length, feeShares);
    }

    // ---------------------------------------------------------------- owner ---

    /// @notice Send this contract's whole balance of a stranger token to `to`. The legs and
    /// USDG are the fund's and are refused (`NotRescuable`).
    function rescueToken(IERC20 token, address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        if (address(token) == address(USDG)) revert NotRescuable(address(token));
        for (uint256 i = 0; i < LEGS; i++) {
            IERC20 leg = _legs[i].token;
            if (address(token) == address(leg)) revert NotRescuable(address(token));
        }
        amount = token.balanceOf(address(this));
        if (amount > 0) token.safeTransfer(to, amount);
        emit Rescued(address(token), to, amount);
    }

    /// @notice Send this contract's whole ETH balance to `to` (it has no `receive`, so only a
    /// forced send can leave any).
    function rescueNative(address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = address(this).balance;
        if (amount > 0) {
            (bool ok,) = to.call{ value: amount }("");
            if (!ok) revert NativeTransferFailed(to, amount);
        }
        emit Rescued(address(0), to, amount);
    }

    /**
     * @notice Replace `leg`'s feed, only once it is dead (`DEAD_FEED_AGE`, no answer, answer
     * <= 0) - the owner cannot touch a live price (security review 2026-10-15, M4 + M5: a
     * delayed replacement of live feeds let the owner reprice six legs and take the fund). The
     * new feed must pass the constructor's checks and keep the leg's decimals, so its scale does
     * not move. The leg's recorded round goes back to 0, so the round sensor does not wait on the
     * old feed's counter. `mint` then waits `FEED_NOTICE` (3 days), and `rebalance` does not trade
     * the leg nor value it (security review 2026-10-17, second pass, B-1 (b)): the new feed is the
     * owner's choice, and holders who distrust it can redeem in kind before it prices anything. A
     * TWAP leg has no feed to replace (`NoFeed`): its channel is fixed at deployment.
     */
    function replaceFeed(uint8 leg, address feed) external onlyOwner {
        if (leg >= LEGS) revert UnknownLeg(leg);
        if (feed == address(0)) revert ZeroAddress();
        LegConfig storage c = _legs[leg];
        address old = c.feed;
        if (old == address(0)) revert NoFeed(leg);
        (bool ok,, int256 answer, uint256 updatedAt) = _readFeed(old);
        if (_isLive(ok, answer, updatedAt)) revert FeedStillLive(leg);
        if (_checkFeed(feed) != c.feedDecimals) revert BadFeed(feed);
        c.feed = feed;
        _roundAt[leg] = 0;
        feedReplacedAt[leg] = block.timestamp;
        emit FeedReplaced(leg, old, feed);
    }

    /**
     * @notice Replace `leg`'s pool, only once it is dead - under `POOL_DEPTH_FLOOR` deep, or
     * unable to answer a 30-minute TWAP. A pool that answers is never replaced, even one that
     * disagrees with its leg's feed (`PoolStillLive`): the owner cannot pick the price that
     * vouches for a feed. Dead is a state of the last 30 minutes, not of the call (security review
     * 2026-10-17, second pass, B-1: under the balance rule the owner emptied GLD's live pool for
     * one call with its own `flash`, 1 596.07 USDG of fee, and replaced it). The new pool passes the
     * constructor's checks (`BadPool`), the factory's among them; then for `FEED_NOTICE` the leg
     * neither opens `mint` nor trades in `rebalance` (B-1 (b)), as after `replaceFeed`. A leg
     * without a pool has none to replace (`NoPool`).
     */
    function replacePool(uint8 leg, address pool) external onlyOwner {
        if (leg >= LEGS) revert UnknownLeg(leg);
        if (pool == address(0)) revert ZeroAddress();
        LegConfig storage c = _legs[leg];
        address old = c.pool;
        if (old == address(0)) revert NoPool(leg);
        (IERC20 token, uint256 scale) = (c.token, c.scale);
        (bool live,) = _readPool(POOL_ORACLE, USDG, POOL_DEPTH_FLOOR, old, address(token), scale);
        if (live) revert PoolStillLive(leg);
        _checkPool(POOL_ORACLE, USDG, UNISWAP_V3_FACTORY, POOL_DEPTH_FLOOR, pool, address(token), scale);
        c.pool = pool;
        feedReplacedAt[leg] = block.timestamp;
        emit PoolReplaced(leg, old, pool);
    }

    /// @notice Always reverts: ownership can be transferred, never renounced.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceForbidden();
    }

    // ---------------------------------------------------------------- views ---

    /// @notice The legs as they stand: weights, holdings, feeds, value, and what was paid for them.
    function legs() external view returns (Leg[] memory out) {
        Snapshot memory s = _snapshot();
        uint256 n = LEGS;
        out = new Leg[](n);
        for (uint256 i = 0; i < n; i++) {
            LegConfig memory c = _legs[i];
            State memory l = s.legs[i];
            out[i] = Leg({
                token: address(c.token),
                feed: c.feed,
                pool: c.pool,
                feedDecimals: c.feedDecimals,
                parts: c.parts,
                targetBps: uint256(c.parts) * BPS / TOTAL_PARTS,
                held: l.held,
                answer: l.answer,
                twap: l.twap,
                updatedAt: l.updatedAt,
                live: l.live,
                disagrees: l.disagrees,
                cost: _cost[i],
                avgCost: l.held == 0 ? 0 : Math.mulDiv(_cost[i], 10 ** c.tokenDecimals, l.held),
                value: l.value
            });
        }
    }

    /// @notice The parameters as constructed (`Params`), read back from the immutables.
    function params() external view returns (Params memory p) {
        // Each immutable was a `Params` field checked against its bounds, so every cast keeps its value.
        // forge-lint: disable-start(unsafe-typecast)
        p = Params({
            entryFeeBps: uint16(ENTRY_FEE_BPS),
            exitFeeBps: uint16(EXIT_FEE_BPS),
            earlyExitPenaltyBps: uint16(EARLY_EXIT_PENALTY_BPS),
            holdPeriod: uint32(HOLD_PERIOD),
            managementFeeBps: uint16(MANAGEMENT_FEE_BPS),
            nonMinterExitBps: uint16(NON_MINTER_EXIT_BPS),
            deadBandBps: uint16(DEAD_BAND_BPS),
            deadBandFloorBps: uint16(DEAD_BAND_FLOOR_BPS),
            toleranceBps: uint16(TOLERANCE_BPS),
            mintFeedAge: uint32(MINT_FEED_AGE),
            minInterval: uint32(MIN_INTERVAL),
            deadFeedAge: uint32(DEAD_FEED_AGE),
            feedNotice: uint32(FEED_NOTICE),
            poolDepthFloor: uint96(POOL_DEPTH_FLOOR),
            feedPoolGapBps: uint16(FEED_POOL_GAP_BPS)
        });
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice What the holdings cost, in USDG: the sum of every leg's `cost`.
    function totalCost() external view returns (uint256 total) {
        for (uint256 i = 0; i < LEGS; i++) {
            total += _cost[i];
        }
    }

    /// @notice The fund's value in USDG (6 decimals): live legs at Chainlink plus USDG held.
    function nav() external view returns (uint256) {
        return _snapshot().nav;
    }

    /// @notice USDG (6 decimals) per whole share (1e18); 0 while there is no share.
    function navPerShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? 0 : Math.mulDiv(_snapshot().nav, 1e18, supply);
    }

    /**
     * @notice The trades `rebalance` would accept now, sells first then buys, each at its
     * largest size: a sell down to the target, a buy up to it but never beyond the USDG the
     * fund holds plus what the sells listed before it must bring at their floor - so the
     * whole plan, run as listed, is funded. `deviationBps` is `(value - target) / target`,
     * the leg's own target; `type(int256).max` for a target of 0 (a sentinel: security review
     * 2026-10-17, R6, `nav x parts` under the live parts made this view panic). `rebalance`
     * accepts each amount up to half a band more (R4), so the plan survives a redeem between
     * this read and the transaction.
     */
    function plan() external view returns (PlanLeg[] memory out) {
        Snapshot memory s = _snapshot();
        _freezeNoticed(s);
        uint256 n = LEGS;
        PlanLeg[] memory rows = new PlanLeg[](n);
        uint256 count;
        uint256 usdgAvailable = s.usdgHeld;
        for (uint256 pass = 0; pass < 2; pass++) {
            bool wantSell = pass == 0;
            for (uint256 i = 0; i < n; i++) {
                State memory l = s.legs[i];
                (bool due, bool sell, uint256 gap,) = _due(l, s.nav);
                if (!due || sell != wantSell) continue;
                LegConfig memory c = _legs[i];
                (IERC20 token, uint256 scale) = (c.token, c.scale);
                uint256 answer = uint256(l.answer);
                uint256 amountIn;
                uint256 minOut;
                if (sell) {
                    amountIn = Math.mulDiv(gap, scale, answer);
                    minOut = _sellFloor(amountIn, answer, scale);
                    usdgAvailable += minOut;
                } else {
                    amountIn = Math.min(gap, usdgAvailable);
                    if (amountIn == 0) continue;
                    usdgAvailable -= amountIn;
                    minOut = _buyFloor(amountIn, answer, scale);
                }
                // forge-lint: disable-next-line(unsafe-typecast)
                int256 deviation = l.target == 0 ? type(int256).max : (int256(l.value) - int256(l.target)) * int256(BPS) / int256(l.target);
                // forge-lint: disable-next-line(unsafe-typecast)
                rows[count++] = PlanLeg({ leg: uint8(i), token: address(token), sell: sell, amountIn: amountIn, minOut: minOut, deviationBps: deviation });
            }
        }
        out = new PlanLeg[](count);
        for (uint256 k = 0; k < count; k++) {
            out[k] = rows[k];
        }
    }

    /**
     * @notice How to split `mint(usdgIn, ...)`'s routes so the new money goes where it is
     * missing - advice for the page; `mint` accepts any split that keeps rule 4 (`MintUnbalances`).
     * The amounts split `net = usdgIn - entry fee`, what the routes must spend. With `nav' = nav +
     * net`, each live leg's target' is `nav' x parts / live parts` and its deficit `max(0,
     * target' - value)`. Two steps (security review 2026-10-17, lot C: one proportional step could
     * propose what rule 4 refuses - on a fund with one leg slightly under its target and another
     * far under, the slightly-under leg's share of the money was less than its target grew by, and
     * it left its band):
     *  1. each leg first gets its need, the least that keeps it acceptable to rule 4: its deficit
     *     less what rule 4 lets it keep - its band less one unit, or for a leg already under and
     *     out of band its gap scaled to `nav'` (its share of the fund unchanged). The needs never
     *     sum to more than `net`: the mint pro rata of the legs' values keeps every leg's share,
     *     so it is acceptable, and each need is at most that leg's pro rata;
     *  2. the rest of `net` goes to the deficits beyond the needs, scaled down proportionally
     *     when they sum to more; a remainder after them is spread over the live legs by their
     *     parts (by construction only the targets' rounding: the deficits sum to at least USDG
     *     held plus `net`).
     * Where no need binds this is the one proportional step of lot A, to the unit. Dead legs get
     * 0. The amounts sum to `net` exactly, the rounding dust on the first live leg. With no
     * share yet, `net x parts / live parts` each. No live leg: all zero. The plan prices every
     * leg at its channel: a route that delivers less than that (its pool's fee and impact) can
     * still leave a leg at its band's edge out of it, by the shortfall.
     */
    function mintPlan(uint256 usdgIn) external view returns (uint256[] memory amounts) {
        usdgIn -= usdgIn * ENTRY_FEE_BPS / BPS;
        uint256 n = LEGS;
        amounts = new uint256[](n);
        Snapshot memory s = _snapshot();
        if (s.liveCount == 0) return amounts;
        uint256 first = n;
        uint256 sum;
        if (totalSupply() == 0) {
            for (uint256 i = 0; i < n; i++) {
                if (!s.legs[i].live) continue;
                if (first == n) first = i;
                amounts[i] = Math.mulDiv(usdgIn, _legs[i].parts, s.liveParts);
                sum += amounts[i];
            }
        } else {
            uint256 navAfter = s.nav + usdgIn;
            uint256[] memory beyond = new uint256[](n);
            uint256 needs;
            uint256 deficits;
            for (uint256 i = 0; i < n; i++) {
                State memory l = s.legs[i];
                if (!l.live) continue;
                if (first == n) first = i;
                uint256 target = Math.mulDiv(navAfter, _legs[i].parts, s.liveParts);
                if (target <= l.value) continue;
                uint256 deficit = target - l.value;
                // What rule 4 (`_checkBalanced`) lets the leg keep: in band is a gap under the band.
                uint256 band = Math.max(target * DEAD_BAND_BPS / BPS, navAfter * DEAD_BAND_FLOOR_BPS / BPS);
                uint256 keep = band == 0 ? 0 : band - 1;
                (bool due, bool sell, uint256 gap,) = _due(l, s.nav);
                if (due && !sell) keep = Math.max(keep, Math.mulDiv(gap, navAfter, s.nav));
                amounts[i] = deficit > keep ? deficit - keep : 0;
                beyond[i] = deficit - amounts[i];
                needs += amounts[i];
                deficits += beyond[i];
            }
            // `needs > usdgIn` is the rounding of the targets only (step 1 above).
            uint256 extra = needs < usdgIn ? usdgIn - needs : 0;
            uint256 rest = deficits < extra ? extra - deficits : 0;
            for (uint256 i = 0; i < n; i++) {
                if (!s.legs[i].live) continue;
                if (needs > usdgIn) amounts[i] = Math.mulDiv(amounts[i], usdgIn, needs);
                else amounts[i] += deficits > extra ? Math.mulDiv(beyond[i], extra, deficits) : beyond[i] + Math.mulDiv(rest, _legs[i].parts, s.liveParts);
                sum += amounts[i];
            }
        }
        amounts[first] += usdgIn - sum;
    }

    /// @notice Whether `rebalance` would pass its two sensors now; if not, which one says no
    /// (and for `FeedNotMoved`, the first leg's token still waiting). `readyAt` is when the
    /// time sensor opens.
    function canRebalance() external view returns (bool ready, Sensor sensor, address token, uint256 readyAt) {
        readyAt = lastRebalanceAt + MIN_INTERVAL;
        if (block.timestamp < readyAt) return (false, Sensor.TooSoon, address(0), readyAt);
        Snapshot memory s = _snapshot();
        _freezeNoticed(s);
        for (uint256 i = 0; i < LEGS; i++) {
            if (_waitsForRound(s.legs[i], i)) return (false, Sensor.FeedNotMoved, address(_legs[i].token), readyAt);
        }
        return (true, Sensor.Ready, address(0), readyAt);
    }

    /// @notice The last rebalance: when, the nav it saw, how many feeds were live, how many legs traded.
    function lastRebalance() external view returns (uint256 timestamp, uint256 navAt, uint256 liveCount, uint256 legsTraded) {
        return (lastRebalanceAt, _lastNav, _lastLiveCount, _lastLegsTraded);
    }

    /// @notice What either redeem door does now for `holder` redeeming `shares`: the shares paid
    /// out after the fee, the owner's fee, the shares burned for the holders - the early penalty
    /// on the minted part plus the non-minter exit on the rest, as the events split them - and
    /// what the paid shares are due - each leg's amount and the USDG. `redeemInKind` pays exactly
    /// these; `redeem` sells what its routes name of `amounts` and pays the rest in kind.
    function previewRedeem(address holder, uint256 shares) external view returns (uint256 paid, uint256 feeShares, uint256 penaltyShares, uint256[] memory amounts, uint256 usdg) {
        uint256 n = LEGS;
        amounts = new uint256[](n);
        uint256 supply = totalSupply();
        if (supply == 0 || shares == 0) return (0, 0, 0, amounts, 0);
        Exit memory e = _exitSplit(holder, shares);
        (paid, feeShares, penaltyShares) = (e.paid, e.feeShares, e.penaltyShares + e.nonMinterShares);
        uint256[] memory held = _heldAll();
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = Math.mulDiv(held[i], paid, supply);
        }
        usdg = Math.mulDiv(USDG.balanceOf(address(this)), paid, supply);
    }

    /// @notice Whether `mint` is open now; if not, which guard closes it, for which leg's token,
    /// and when it opens again (`readyAt`, for a feed notice; 0 for a dead or stale feed, which
    /// waits for Chainlink). The same check `mint` runs.
    function canMint() external view returns (bool open, MintGuard reason, address token, uint256 readyAt) {
        uint256 leg;
        (reason, leg, readyAt) = _mintGuard(_snapshot(), totalSupply());
        open = reason == MintGuard.Open;
        if (!open) token = address(_legs[leg].token);
    }

    /// @notice What `mintInKind(amounts, ...)` mints now: the minter's shares, the owner's fee, and
    /// the USDG it pulls with the legs. Zeros for an empty fund or a wrong length (a sentinel:
    /// `mintInKind` reverts on both).
    function previewMintInKind(uint256[] calldata amounts) external view returns (uint256 shares, uint256 feeShares, uint256 usdgIn) {
        uint256 supply = totalSupply();
        if (supply == 0 || amounts.length != LEGS) return (0, 0, 0);
        uint256 gross = _ratioShares(supply, _heldAll(), amounts);
        usdgIn = Math.mulDiv(USDG.balanceOf(address(this)), gross, supply, Math.Rounding.Ceil);
        feeShares = gross * ENTRY_FEE_BPS / BPS;
        shares = gross - feeShares;
    }

    /// @notice The management fee `rebalance` would mint to the owner now, in shares.
    function pendingManagementFee() public view returns (uint256) {
        return Math.mulDiv(totalSupply(), MANAGEMENT_FEE_BPS * (block.timestamp - lastAccrualAt), BPS * YEAR);
    }

    /// @notice The legs' round ids recorded at the last rebalance (0 before the first one, or
    /// for a feed that did not answer then).
    function roundAtLastRebalance() external view returns (uint256[] memory rounds) {
        uint256 n = LEGS;
        rounds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            rounds[i] = _roundAt[i];
        }
    }

    // ------------------------------------------------------------- internal ---

    /// A feed the ETF can read: code, a one-word `decimals()` <= 36, five words from
    /// `latestRoundData()`. Returns its decimals; refuses with `BadFeed` otherwise.
    function _checkFeed(address feed) private view returns (uint256 feedDecimals) {
        bool ok;
        (ok, feedDecimals) = _readUint(feed, 0x313ce567); // decimals()
        if (!ok || feedDecimals > 36) revert BadFeed(feed);
        (bool answers,,,) = _readFeed(feed);
        if (!answers) revert BadFeed(feed);
    }

    function _heldAll() private view returns (uint256[] memory held) {
        uint256 n = LEGS;
        held = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            IERC20 token = _legs[i].token;
            held[i] = token.balanceOf(address(this));
        }
    }

    /// The fund at this instant: each leg's balance and channel, the live values, nav, and each
    /// live leg's target, `nav x parts / live parts` (m7m's `nav / liveCount` when every part is
    /// 1). A feed leg reads its feed, and its pool if it has one (only while the feed is live:
    /// a dead feed is dead whatever its pool says); a TWAP leg reads its pool, answers its TWAP
    /// and is dated now.
    function _snapshot() private view returns (Snapshot memory s) {
        uint256 n = LEGS;
        s.legs = new State[](n);
        s.usdgHeld = USDG.balanceOf(address(this));
        s.nav = s.usdgHeld;
        for (uint256 i = 0; i < n; i++) {
            LegConfig memory c = _legs[i];
            State memory l = s.legs[i];
            l.held = c.token.balanceOf(address(this));
            l.hasFeed = c.feed != address(0);
            if (l.hasFeed) {
                bool ok;
                (ok, l.roundId, l.answer, l.updatedAt) = _readFeed(c.feed);
                l.live = _isLive(ok, l.answer, l.updatedAt);
            }
            if (c.pool != address(0) && (l.live || !l.hasFeed)) {
                (bool poolLive, uint256 twap) = _readPool(POOL_ORACLE, USDG, POOL_DEPTH_FLOOR, c.pool, address(c.token), c.scale);
                l.twap = twap;
                if (!l.hasFeed) {
                    l.live = poolLive;
                    // `_readPool` keeps a live TWAP under `type(int256).max`.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    l.answer = int256(twap);
                    l.updatedAt = block.timestamp;
                } else if (!poolLive || _disagree(uint256(l.answer), twap)) {
                    // R3 of the security review 2026-10-17: a fresh but wrong feed would price every
                    // other leg's mint; its pool, as deep as the floor, must vouch for it.
                    l.live = false;
                    l.disagrees = true;
                }
            }
            if (l.live) l.value = Math.mulDiv(l.held, uint256(l.answer), c.scale);
        }
        _total(s);
    }

    /// `nav`, the live count and parts, and each live leg's target, from the live legs' values and
    /// the USDG held; a leg not live has a target of 0.
    function _total(Snapshot memory s) private view {
        uint256 n = LEGS;
        s.nav = s.usdgHeld;
        s.liveCount = 0;
        s.liveParts = 0;
        for (uint256 i = 0; i < n; i++) {
            if (!s.legs[i].live) continue;
            s.nav += s.legs[i].value;
            s.liveCount++;
            s.liveParts += _legs[i].parts;
        }
        for (uint256 i = 0; i < n; i++) {
            s.legs[i].target = s.legs[i].live ? Math.mulDiv(s.nav, _legs[i].parts, s.liveParts) : 0;
        }
    }

    /// Whether leg `i`'s feed or pool was replaced less than `FEED_NOTICE` ago.
    function _noticeRunning(uint256 i) private view returns (bool) {
        uint256 replacedAt = feedReplacedAt[i];
        return replacedAt > 0 && block.timestamp < replacedAt + FEED_NOTICE;
    }

    /// `rebalance`'s and `plan`'s view of the fund (security review 2026-10-17, second pass, B-1
    /// (b)): a leg under its replacement's notice is held as a dead leg - not valued, not traded,
    /// not waited for - so the source the owner chose prices nothing before holders could leave.
    function _freezeNoticed(Snapshot memory s) private view {
        bool any;
        for (uint256 i = 0; i < LEGS; i++) {
            State memory l = s.legs[i];
            if (!l.live || !_noticeRunning(i)) continue;
            l.live = false;
            l.frozen = true;
            any = true;
        }
        if (any) _total(s);
    }

    /// Whether a live leg is out of band, on which side, by how much (USDG), and the band. The
    /// band is `max(DEAD_BAND_BPS of the leg's target, DEAD_BAND_FLOOR_BPS of nav)`; at or past it
    /// the leg is due, as in m7m (`gap >= band`, a zero gap never).
    function _due(State memory l, uint256 nav_) private view returns (bool due, bool sell, uint256 gap, uint256 band) {
        if (!l.live) return (false, false, 0, 0);
        uint256 target = l.target;
        sell = l.value > target;
        gap = sell ? l.value - target : target - l.value;
        band = Math.max(target * DEAD_BAND_BPS / BPS, nav_ * DEAD_BAND_FLOOR_BPS / BPS);
        due = gap > 0 && gap >= band;
    }

    /// The rebalance sensor's question for one leg: a live feed whose round is not newer than the
    /// one recorded at the last rebalance. A TWAP leg has no round and never waits; a dead leg
    /// (feed, pool or their disagreement) is not waited for, as m7m did not wait for a dead feed.
    function _waitsForRound(State memory l, uint256 i) private view returns (bool) {
        return l.live && l.hasFeed && l.roundId <= _roundAt[i];
    }

    /// A feed's answer and its pool's TWAP, both the price of `scale` raw units in USDG units, more
    /// than `FEED_POOL_GAP_BPS` apart, in bps of the TWAP: `|answer - twap| > twap x gap / 10 000`,
    /// exact (an integer passes the floor of a bound exactly when it passes the bound).
    function _disagree(uint256 answer, uint256 twap) private view returns (bool) {
        uint256 diff = answer > twap ? answer - twap : twap - answer;
        return diff > Math.mulDiv(twap, FEED_POOL_GAP_BPS, BPS);
    }

    /**
     * A pool's 30-minute TWAP as a leg's answer: the USDG units `scale` raw units of `token` are
     * worth at the mean tick, by `MaidMarianBagPoolOracle.tryQuote` - the registry's reader, which
     * answers `(0, false)` rather than revert for a pool whose `observe` cannot reach 1 800 s back.
     * Live when the quote is above 0 and fits an `int256`, and the pool is at least `floor` deep at
     * it: the USDG its 30-minute harmonic-mean in-range liquidity holds within 2 % of the TWAP
     * (`MaidMarianEtfPoolDepth`; security review 2026-10-17, second pass, B-1 / B-2 - nothing done
     * inside one call moves that figure, where the pool's USDG balance, read until then, moved by
     * a `flash` or an out-of-range position). `(false, 0)` otherwise, a sentinel. Every argument is
     * passed, so the constructor can call it before its immutables exist.
     */
    function _readPool(MaidMarianBagPoolOracle oracle, IERC20 usdg, uint256 floor, address pool, address token, uint256 scale) private view returns (bool live, uint256 twap) {
        bool ok;
        (twap, ok) = oracle.tryQuote(pool, scale, token, address(usdg));
        if (!ok || twap == 0 || twap > uint256(type(int256).max)) return (false, 0);
        uint256 depth;
        (ok, depth) = MaidMarianEtfPoolDepth.depth(pool, twap, scale);
        if (!ok || depth < floor) return (false, 0);
        return (true, twap);
    }

    /// A pool the ETF can price a leg by: code, the Uniswap V3 factory's own pool of the pair at
    /// the pool's `fee()` (`getPool(token, USDG, fee) == pool`, security review 2026-10-17, second
    /// pass, B-1: a contract with the two tokens and a written tick passed every other check),
    /// `token0` / `token1` the leg's token and USDG in either order, and live by `_readPool` (deep
    /// enough, 30 minutes of history, a price above 0); `BadPool` otherwise. The constructor's and
    /// `replacePool`'s one check.
    function _checkPool(MaidMarianBagPoolOracle oracle, IERC20 usdg, address factory, uint256 floor, address pool, address token, uint256 scale) private view {
        if (pool.code.length == 0) revert BadPool(pool);
        (bool okFee, uint256 fee) = _readUint(pool, 0xddca3f43); // fee()
        if (!okFee || fee > type(uint24).max) revert BadPool(pool);
        // forge-lint: disable-next-line(unsafe-typecast)
        (bool known, bytes memory ret) = factory.staticcall(abi.encodeWithSelector(0x1698ee82, token, address(usdg), uint24(fee))); // getPool(address,address,uint24)
        if (!known || ret.length != 32 || abi.decode(ret, (uint256)) != uint256(uint160(pool))) revert BadPool(pool);
        (bool ok0, uint256 t0) = _readUint(pool, 0x0dfe1681); // token0()
        (bool ok1, uint256 t1) = _readUint(pool, 0xd21220a7); // token1()
        (uint256 a, uint256 u) = (uint256(uint160(token)), uint256(uint160(address(usdg))));
        if (!ok0 || !ok1 || !((t0 == a && t1 == u) || (t0 == u && t1 == a))) revert BadPool(pool);
        (bool live,) = _readPool(oracle, usdg, floor, pool, token, scale);
        if (!live) revert BadPool(pool);
    }

    /**
     * A mint's band rule: the fund re-read after the
     * mint - each balance again, at the answers `before` read, so no feed is called twice - and
     * every live leg that `_due` finds out of band must have been out of band before, on the
     * same side, with a gap that did not grow as a share of `nav`: `gap / nav <= gapBefore /
     * navBefore`, compared multiplied out with one USDG unit of slack on `gapBefore` for the
     * floors of the values (a mint in kind at the fund's exact ratio moves each floored value
     * by up to one unit). The first mint has no before: every leg must end in band. Otherwise
     * `MintUnbalances(token)`, the first such leg.
     */
    function _checkBalanced(Snapshot memory before, bool first) private view {
        if (before.liveCount == 0) return;
        uint256 n = LEGS;
        (State[] memory afterLegs, uint256 navAfter) = _after(before);
        for (uint256 i = 0; i < n; i++) {
            State memory a = afterLegs[i];
            if (!a.live) continue;
            (bool due, bool sell, uint256 gap,) = _due(a, navAfter);
            if (!due) continue;
            if (!first) {
                (bool dueBefore, bool sellBefore, uint256 gapBefore,) = _due(before.legs[i], before.nav);
                if (dueBefore && sellBefore == sell && gap * before.nav <= (gapBefore + 1) * navAfter) continue;
            }
            revert MintUnbalances(address(_legs[i].token));
        }
    }

    /// The fund re-read now at the answers `before` read: each live leg's balance again, its value
    /// and its target among `before`'s live parts, and the nav they sum to with the USDG held.
    function _after(Snapshot memory before) private view returns (State[] memory afterLegs, uint256 navAfter) {
        uint256 n = LEGS;
        afterLegs = new State[](n);
        navAfter = USDG.balanceOf(address(this));
        for (uint256 i = 0; i < n; i++) {
            State memory b = before.legs[i];
            if (!b.live) continue;
            LegConfig memory c = _legs[i];
            State memory a = afterLegs[i];
            a.live = true;
            a.value = Math.mulDiv(c.token.balanceOf(address(this)), uint256(b.answer), c.scale);
            navAfter += a.value;
        }
        for (uint256 i = 0; i < n; i++) {
            State memory a = afterLegs[i];
            if (a.live) a.target = Math.mulDiv(navAfter, _legs[i].parts, before.liveParts);
        }
    }

    /// Whether a pass left every leg `before` held live in band (`rebalance`'s step 5, B-4).
    function _noneDueAfter(Snapshot memory before) private view returns (bool) {
        if (before.liveCount == 0) return true;
        (State[] memory afterLegs, uint256 navAfter) = _after(before);
        for (uint256 i = 0; i < LEGS; i++) {
            (bool due,,,) = _due(afterLegs[i], navAfter);
            if (due) return false;
        }
        return true;
    }

    /// The least USDG a sell of `amountIn` tokens must bring: Chainlink value less the tolerance.
    function _sellFloor(uint256 amountIn, uint256 answer, uint256 scale) private view returns (uint256) {
        return Math.mulDiv(Math.mulDiv(amountIn, answer, scale), BPS - TOLERANCE_BPS, BPS);
    }

    /// The fewest tokens a buy of `amountIn` USDG must bring: Chainlink quantity less the tolerance.
    function _buyFloor(uint256 amountIn, uint256 answer, uint256 scale) private view returns (uint256) {
        return Math.mulDiv(Math.mulDiv(amountIn, scale, answer), BPS - TOLERANCE_BPS, BPS);
    }

    /// `supply x min over legs with held > 0 of (incoming / held)`; 0 when no leg is held.
    function _ratioShares(uint256 supply, uint256[] memory held, uint256[] memory incoming) private pure returns (uint256 shares) {
        shares = type(uint256).max;
        for (uint256 i = 0; i < held.length; i++) {
            if (held[i] == 0) continue;
            shares = Math.min(shares, Math.mulDiv(supply, incoming[i], held[i]));
        }
        if (shares == type(uint256).max) shares = 0;
    }

    /// One swap. The contract never encodes a route: the caller brings Uniswap's Trading API
    /// bytes, rewritten with the ETF as payer (`payerIsUser: false`) and recipient. `amountIn` is
    /// transferred straight into the official Universal Router - no intermediate contract, no
    /// approval to anyone (author, 2026-10-15) - the bytes run, and what arrived here is measured
    /// as a balance difference and floored by `minOut`: the recipe `UniswapPermit2Gate` proved to
    /// the wei on fork, inline. The security is in that measured output, never in the bytes.
    /// Input a route does not consume stays in the router. The ETF has no `receive()`: a route
    /// ending in native ETH delivers nothing here and fails its floor.
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 minOut, Route calldata r) private returns (uint256 amountOut) {
        uint256 before = tokenOut.balanceOf(address(this));
        tokenIn.safeTransfer(address(UNIVERSAL_ROUTER), amountIn);
        UNIVERSAL_ROUTER.execute(r.commands, r.inputs, r.deadline);
        amountOut = tokenOut.balanceOf(address(this)) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }

    /// One payout of `redeemInKind`. With `bit` unset in `allowFail`, `safeTransfer`: true or a
    /// revert. With it set, a low-level `transfer` whose failure (a revert, or a return that is
    /// not empty and not the word 1 - SafeERC20's own test) returns false, the amount untouched.
    function _pay(IERC20 token, address to, uint256 amount, uint16 allowFail, uint256 bit) private returns (bool) {
        if (allowFail & (1 << bit) == 0) {
            token.safeTransfer(to, amount);
            return true;
        }
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (uint256)) == 1));
    }

    /// A feed's latest round, the `StockTokenLens.readFeeds` way: a low-level `staticcall`,
    /// exactly five words or `ok == false`. Decoded as plain words so a malformed round id
    /// is a value to compare, never a decoding revert.
    function _readFeed(address feed) private view returns (bool ok, uint256 roundId, int256 answer, uint256 updatedAt) {
        (bool success, bytes memory ret) = feed.staticcall(abi.encodeWithSelector(0xfeaf968c)); // latestRoundData()
        if (!success || ret.length != 160) return (false, 0, 0, 0);
        (roundId, answer,, updatedAt,) = abi.decode(ret, (uint256, int256, uint256, uint256, uint256));
        ok = true;
    }

    /// Live: it answered, the answer is positive, and its last round is under `DEAD_FEED_AGE` old.
    function _isLive(bool ok, int256 answer, uint256 updatedAt) private view returns (bool) {
        return ok && answer > 0 && (updatedAt >= block.timestamp || block.timestamp - updatedAt <= DEAD_FEED_AGE);
    }

    /// A one-word answer to a no-argument call; `ok == false` for anything else.
    function _readUint(address target, bytes4 selector) private view returns (bool ok, uint256 value) {
        (bool success, bytes memory ret) = target.staticcall(abi.encodeWithSelector(selector));
        if (!success || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }
}
