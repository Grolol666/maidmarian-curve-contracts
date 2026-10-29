// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// The Universal Router's entry point, the one function m7m calls.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @title Maid Marian Seven Magnificent (m7m)
 * @notice One token that holds the seven Magnificent Seven stock tokens of Robinhood Chain -
 * AAPL, MSFT, GOOGL, AMZN, NVDA, META and TSLA - in equal value.
 *
 * Four doors:
 *  - Mint with USDG: the contract buys the seven for you; you get shares for what you paid,
 *    never more than Chainlink says it is worth.
 *  - Mint with the seven: bring the tokens yourself, with the fund's share of USDG.
 *  - Redeem to USDG: your part of the seven is sold; what is not sold comes to you as tokens.
 *  - Redeem to the seven: you get your part of each token. This door always works, even if
 *    everything else breaks.
 *
 * At most once a day the owner rebalances the fund back to equal value. The contract checks
 * every price against Chainlink and refuses a bad trade.
 *
 * Costs: 0.1 % to enter, 0.3 % to leave, 1 % if you leave within a day of receiving shares
 * (0.7 % of it stays with the other holders), and 0.3 % a year.
 *
 * Minting with USDG is closed while a price feed is more than 6 hours old (nights, weekends,
 * holidays), while a feed is dead, and for three days after a feed is replaced.
 *
 * Nobody can change the seven, pause the fund, or touch the holdings outside these doors. The
 * owner can only rebalance, replace a dead feed, and rescue tokens sent here by mistake.
 *
 * Warning: Robinhood's stock tokens have an admin burn that can take tokens from any holder,
 * this fund included.
 */
contract MaidMarianSevenMagnificent is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------ constants ---

    /// The seven legs, fixed.
    uint256 public constant LEGS = 7;

    /// A rebalance leg must deliver at least Chainlink value x 99 % (author, 2026-10-15: 1 %).
    uint256 public constant TOLERANCE_BPS = 100;

    /// A leg within 2 % of its target is not traded (author, 2026-10-15: 2 %).
    uint256 public constant DEAD_BAND_BPS = 200;

    /// At most one rebalance per day (author, 2026-10-15: 20 hours, so the New York open can
    /// drift an hour either way with DST and a rebalance sent around it always passes).
    uint256 public constant MIN_INTERVAL = 20 hours;

    /// A feed older than this, answering <= 0, or not answering, is dead (author, 2026-10-15:
    /// 7 days; a weekend plus a holiday is at most four days without a round).
    uint256 public constant DEAD_FEED_AGE = 7 days;

    /// 0.3 % of the supply a year, in new shares to the owner, accrued at each rebalance
    /// (author, 2026-10-15).
    uint256 public constant MANAGEMENT_FEE_BPS = 30;

    /// The entry fee, 0.1 %: of `usdgIn` in USDG on `mint`, of the shares on `mintInKind`, to the
    /// owner (author, 2026-10-15, second amendment: entry cheap, exit paid, early exit paid more).
    uint256 public constant ENTRY_FEE_BPS = 10;

    /// The exit fee to the owner, 0.3 % of the shares redeemed, on both redeems (author,
    /// 2026-10-15; in shares on `redeem` too since the security review: a USDG fee measured on
    /// what the routes brought could be routed around).
    uint256 public constant EXIT_FEE_BPS = 30;

    /// The early-exit penalty on top, 0.7 % of the shares, within `HOLD_PERIOD`: burned without
    /// payout, so the holders who stay get it (author, 2026-10-15: the 100 bps early, sent to everyone; 30 + 70 = 100).
    uint256 public constant EARLY_EXIT_PENALTY_BPS = 70;

    /// How young a balance-weighted `heldSince` makes an exit early (author, 2026-10-15: one day -
    /// "if you have just minted it is 1 %, otherwise 0.3 % after 1 day"; was 3 days the same day).
    uint256 public constant HOLD_PERIOD = 1 days;

    /// A mint needs every live feed's last round younger than this (security review 2026-10-15,
    /// M8: a stale feed made minting a one-way discount). Measured over 92 days to 2026-10-15
    /// (every round of the seven on publicnode, sessions 13:30-20:00 UTC):
    /// the largest staleness inside a session is 5h53 (META) to 6h25 (AAPL); the share of session
    /// minutes a mint would be closed is 58.2 % at 2 h, 22.3 % at 4 h, 4.2 % at 6 h, 2.8 % at 8 h.
    /// 6 hours was chosen from that table.
    uint256 public constant MINT_FEED_AGE = 6 hours;

    /// How long `mint` stays closed after the owner replaces a dead feed (second review pass,
    /// M-a: the owner's own feed is a price with no notice): long enough for any holder who
    /// distrusts the new feed to leave in kind first. Both redeems, `mintInKind` and `rebalance`
    /// are not held back.
    uint256 public constant FEED_NOTICE = 3 days;

    uint256 private constant BPS = 10_000;
    uint256 private constant YEAR = 365 days;

    // ---------------------------------------------------------------- types ---

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

    /// One leg as `legs()` shows it. `avgCost` is USDG (6 decimals) paid per whole token.
    struct Leg {
        address token;
        address feed;
        uint8 feedDecimals;
        uint256 held;
        int256 answer;
        uint256 updatedAt;
        bool live;
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

    /// Which sensor holds `rebalance` back, as `canRebalance()` says it.
    /// Why `mint` is closed, as `canMint()` says it; `Open` when it is not.
    enum MintGuard {
        Open,
        LegDead,
        FeedStale,
        FeedNotice
    }

    enum Sensor {
        Ready,
        TooSoon,
        FeedNotMoved
    }

    /// One leg read at one instant: the balance, the feed, and what follows from them.
    struct State {
        uint256 held;
        int256 answer;
        uint256 updatedAt;
        uint256 roundId;
        bool live;
        uint256 value;
    }

    /// The fund read at one instant, everything `rebalance` and `plan` decide from.
    struct Snapshot {
        State[LEGS] legs;
        uint256 usdgHeld;
        uint256 nav;
        uint256 liveCount;
        uint256 target;
    }

    // ----------------------------------------------------------- immutables ---

    /// The quote currency, 6 decimals on chain 4663.
    IERC20 public immutable USDG;

    /// The official Uniswap Universal Router every swap runs on, pre-funded by a plain transfer.
    IUniversalRouter public immutable UNIVERSAL_ROUTER;

    // ---------------------------------------------------------------- legs ---

    /// One leg as stored. Its value is `rawBalance x answer / scale`, in USDG (6 decimals), with
    /// `scale = 10^(feedDecimals + tokenDecimals - 6)`; Chainlink stock answers already include
    /// `uiMultiplier()` (ERC-8056), so m7m never reads or applies it. A feed that
    /// does not answer five words, answers <= 0, or has not written for `DEAD_FEED_AGE` is dead:
    /// its leg is not valued, not traded, not waited for. `token`, `tokenDecimals` and `scale` are
    /// write-once storage: written in
    /// the constructor and by no function after it - the compiler cannot enforce it, the absence
    /// of any writer and `test_TheSevenLegsReadBackAsConstructedAfterAFullDay` do. `feed` and
    /// `feedDecimals` change only through `replaceFeed`, over a dead feed.
    /// `scale = 10^(feedDecimals + tokenDecimals - 6)`: `raw x answer / scale` is USDG units.
    struct LegConfig {
        IERC20 token;
        uint8 feedDecimals;
        uint8 tokenDecimals;
        address feed;
        uint256 scale;
    }

    LegConfig[LEGS] private _legs;

    /// When the owner last replaced each leg's feed (`replaceFeed`); 0 if never. `mint` waits
    /// `FEED_NOTICE` after it.
    uint256[LEGS] public feedReplacedAt;

    // ---------------------------------------------------------------- state ---

    /// When the last rebalance ran; 0 at birth, so the first one needs no wait.
    uint256 public lastRebalanceAt;

    /// When the management fee was last accrued; the deploy time at birth.
    uint256 public lastAccrualAt;

    uint256[LEGS] private _cost;
    uint256[LEGS] private _roundAt;
    uint256 private _lastNav;
    uint8 private _lastLiveCount;
    uint8 private _lastLegsTraded;

    /// Each address's balance-weighted acquisition time: on receiving `amount` with `bal` held,
    /// `(bal x heldSince + amount x now) / (bal + amount)`. An exit before `HOLD_PERIOD` after it
    /// pays `EARLY_EXIT_PENALTY_BPS` on top of `EXIT_FEE_BPS`.
    mapping(address holder => uint256) public heldSince;

    // --------------------------------------------------------------- events ---

    /// `credit` is what the legs were credited at Chainlink, `navAt` the nav the shares were priced
    /// at (both 0 on the first mint, priced at one share per USDG).
    event Minted(address indexed by, address indexed to, uint256 usdgIn, uint256 shares, uint256 feeUsdg, uint256 credit, uint256 navAt);
    event MintedInKind(address indexed by, address indexed to, uint256[LEGS] amounts, uint256 usdgIn, uint256 shares, uint256 feeShares);
    /// `inKind[i]` is the unsold remainder of leg i paid as tokens; `usdgOut` all the USDG paid.
    event Redeemed(address indexed by, address indexed to, uint256 shares, uint256 usdgOut, uint256 feeShares, uint256 penaltyShares, uint256[LEGS] inKind);
    /// `amounts[i]` and `usdgOut` are what was paid (0 where forfeited); `forfeited` the mask.
    event RedeemedInKind(address indexed by, address indexed to, uint256 shares, uint256 feeShares, uint256 penaltyShares, uint256[LEGS] amounts, uint256 usdgOut, uint8 forfeited);
    event Rebalanced(uint256 nav, uint256 liveCount, uint256 legsTraded, uint256 feeShares);
    event LegTraded(address indexed token, bool sell, uint256 amountIn, uint256 amountOut, int256 answer);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event FeedReplaced(uint8 indexed leg, address oldFeed, address newFeed);

    // --------------------------------------------------------------- errors ---

    error ZeroAddress();
    error NoCode(address account);
    error BadToken(address token);
    error BadFeed(address feed);
    error DuplicateToken(address token);
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
    error FirstMintUnderDelivered(address token, uint256 value, uint256 amountIn);

    // ---------------------------------------------------------- constructor ---

    /**
     * @param tokens The seven stock tokens, in leg order. Each must have code, answer
     * `decimals()`, differ from the others and from USDG.
     * @param feeds Leg i's Chainlink feed. Each must answer `decimals()` and `latestRoundData()`
     * with five words; its decimals are stored once.
     * @param usdg The quote currency.
     * @param router The Universal Router; must have code.
     * @param owner_ Receives the fees in shares; can rescue strangers' tokens, nothing else.
     */
    constructor(address[LEGS] memory tokens, address[LEGS] memory feeds, IERC20 usdg, IUniversalRouter router, address owner_) ERC20("Maid Marian Seven Magnificent", "m7m") Ownable(owner_) {
        if (address(usdg) == address(0) || address(router) == address(0)) revert ZeroAddress();
        if (address(usdg).code.length == 0) revert NoCode(address(usdg));
        if (address(router).code.length == 0) revert NoCode(address(router));

        for (uint256 i = 0; i < LEGS; i++) {
            address token = tokens[i];
            address feed = feeds[i];
            if (token == address(0) || feed == address(0)) revert ZeroAddress();
            if (token.code.length == 0) revert NoCode(token);
            if (token == address(usdg)) revert DuplicateToken(token);
            for (uint256 j = 0; j < i; j++) {
                if (tokens[j] == token) revert DuplicateToken(token);
            }

            (bool tokenOk, uint256 tokenDecimals) = _readUint(token, 0x313ce567); // decimals()
            if (!tokenOk || tokenDecimals > 36) revert BadToken(token);
            uint256 feedDecimals = _checkFeed(feed);
            if (feedDecimals + tokenDecimals < 6) revert BadToken(token);

            // Both are <= 36, checked above, so the casts keep their values.
            // forge-lint: disable-next-line(unsafe-typecast)
            _legs[i] = LegConfig({ token: IERC20(token), feedDecimals: uint8(feedDecimals), tokenDecimals: uint8(tokenDecimals), feed: feed, scale: 10 ** (feedDecimals + tokenDecimals - 6) });
        }

        USDG = usdg;
        UNIVERSAL_ROUTER = router;

        lastAccrualAt = block.timestamp;
    }

    // ---------------------------------------------------------------- doors ---

    /**
     * @notice Buy into the fund with USDG - and rebalance it, since new money can go where it is
     * missing (author, 2026-10-15: the rebalancing happens at the moment of purchase). The entry
     * fee, `ENTRY_FEE_BPS` of `usdgIn`, goes to the owner in USDG before any route runs; each
     * `routes[i].amountIn` of the rest is swapped into leg i on the router (0 skips the leg),
     * and they must sum to exactly `usdgIn - fee` (`RoutesDoNotSpendInput`). The split is the
     * caller's: `mintPlan` advises one, the contract enforces none, and no per-leg floor is
     * applied.
     *
     * Shares: the first mint gives one share per USDG that reaches the fund (`(usdgIn - fee) x
     * 1e12`). Afterwards, with `nav` read as `rebalance` reads it (live legs at Chainlink plus
     * USDG held, before this USDG arrives), each leg credits `min(amountIn, delivered x answer /
     * scale)` - you are credited what you paid, never more than it is worth - and `shares = sum
     * of credits x totalSupply / nav`, never more than it is worth.
     *
     * Closed (security review 2026-10-15) while a held leg's feed is dead (`LegDead`: its leg
     * would be out of `nav` and the minter would buy the fund at 6/7) or any live feed's last
     * round is older than `MINT_FEED_AGE` (`FeedStale`: creations during market hours), and for
     * `FEED_NOTICE` after the owner replaced a feed (`FeedNotice`). The first mint needs all seven
     * feeds live and fresh and must deliver on all seven legs at least 99 % of each route's cost
     * at Chainlink (`NothingDelivered`, `FirstMintUnderDelivered`: shares with nothing behind them
     * would brick every later mint), and starts the management fee clock.
     * `minShares` applies to what `to` receives; zero shares are refused.
     */
    function mint(uint256 usdgIn, Route[LEGS] calldata routes, uint256 minShares, address to) external nonReentrant returns (uint256 shares) {
        if (to == address(0)) revert ZeroAddress();
        if (usdgIn == 0) revert NothingToMint();
        uint256 feeUsdg = usdgIn * ENTRY_FEE_BPS / BPS;
        uint256 net = usdgIn - feeUsdg;
        uint256 routed;
        for (uint256 i = 0; i < LEGS; i++) {
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
            if (guard == MintGuard.LegDead) revert LegDead(token);
            revert FeedStale(token, s.legs[leg].updatedAt);
        }
        USDG.safeTransferFrom(msg.sender, address(this), net);
        if (feeUsdg > 0) USDG.safeTransferFrom(msg.sender, owner(), feeUsdg);

        uint256 credit;
        for (uint256 i = 0; i < LEGS; i++) {
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
            }
            _cost[i] += amountIn;
            if (s.legs[i].live) credit += Math.min(amountIn, Math.mulDiv(delivered, uint256(s.legs[i].answer), scale));
        }

        if (supply == 0) {
            for (uint256 i = 0; i < LEGS; i++) {
                if (routes[i].amountIn == 0) revert NothingDelivered(address(_legs[i].token));
            }
            lastAccrualAt = block.timestamp;
        }
        if (supply == 0) credit = 0;
        shares = supply == 0 ? net * 1e12 : (s.nav == 0 ? 0 : Math.mulDiv(credit, supply, s.nav));
        if (shares == 0 || shares < minShares) revert TooFewShares(shares, minShares);
        _mint(to, shares);
        emit Minted(msg.sender, to, usdgIn, shares, feeUsdg, credit, supply == 0 ? 0 : s.nav);
    }

    /**
     * @notice Bring the seven instead of buying them. `amounts[i]` of leg i is pulled from the
     * caller; shares are `totalSupply x min over legs held of (brought / held)`, no oracle - the
     * excess on other legs stays in the fund, for every holder. The fund's USDG is the eighth
     * balance: `usdgHeld x shares / totalSupply` is pulled too, rounded up (security review
     * 2026-10-15, M6: without it the mint took a share of USDG it never brought). The entry fee
     * is `ENTRY_FEE_BPS` of the shares, minted to the owner. Never the first mint
     * (`FirstMintIsUsdg`): the first share is born at 1 USDG through `mint`, and only there. No
     * swap, no route; the feeds are read only to book what came in at Chainlink value (`cost`),
     * 0 for a dead feed.
     */
    function mintInKind(uint256[LEGS] calldata amounts, uint256 minShares, address to) external nonReentrant returns (uint256 shares) {
        if (to == address(0)) revert ZeroAddress();
        uint256 supply = totalSupply();
        if (supply == 0) revert FirstMintIsUsdg();

        uint256[LEGS] memory held = _heldAll();
        uint256[LEGS] memory received;
        for (uint256 i = 0; i < LEGS; i++) {
            LegConfig memory c = _legs[i];
            (IERC20 token, address feed, uint256 scale) = (c.token, c.feed, c.scale);
            if (amounts[i] == 0) {
                if (held[i] > 0) revert LegNotBrought(address(token));
                continue;
            }
            token.safeTransferFrom(msg.sender, address(this), amounts[i]);
            received[i] = token.balanceOf(address(this)) - held[i];
            (bool ok,, int256 answer, uint256 updatedAt) = _readFeed(feed);
            // A live answer is > 0 (`_isLive`), so the cast keeps its value.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (_isLive(ok, answer, updatedAt)) _cost[i] += Math.mulDiv(received[i], uint256(answer), scale);
        }

        uint256 gross = _ratioShares(supply, held, received);
        uint256 usdgIn = Math.mulDiv(USDG.balanceOf(address(this)), gross, supply, Math.Rounding.Ceil);
        if (usdgIn > 0) USDG.safeTransferFrom(msg.sender, address(this), usdgIn);
        uint256 feeShares = gross * ENTRY_FEE_BPS / BPS;
        shares = gross - feeShares;
        if (shares == 0 || shares < minShares) revert TooFewShares(shares, minShares);
        if (feeShares > 0) _mint(owner(), feeShares);
        _mint(to, shares);
        emit MintedInKind(msg.sender, to, amounts, usdgIn, shares, feeShares);
    }

    /**
     * @notice Leave for USDG. The exit fee comes first, in shares, as in `redeemInKind`:
     * `EXIT_FEE_BPS` of `shares` to the owner, `EARLY_EXIT_PENALTY_BPS` more burned without
     * payout on an early exit (security review 2026-10-15, H1: a fee measured on the USDG the
     * routes brought was 0 for routes paying the redeemer directly). The rest, `paid`, is burned
     * and `due[i] = held[i] x paid / totalSupply`; `routes[i]` sells `amountIn <= due[i]` of leg
     * i to USDG and the remainder goes to `to` in kind, so a holding that moved between a preview
     * and the transaction never makes this revert. The fund's own USDG is paid pro rata too. No
     * feed read. `minUsdgOut` floors the USDG `to` receives.
     */
    function redeem(uint256 shares, Route[LEGS] calldata routes, uint256 minUsdgOut, address to) external nonReentrant returns (uint256 usdgOut) {
        if (to == address(0)) revert ZeroAddress();
        (uint256 paid, uint256 supply, uint256 feeShares, uint256 penaltyShares) = _exit(shares);
        uint256[LEGS] memory held = _heldAll();
        usdgOut = Math.mulDiv(USDG.balanceOf(address(this)), paid, supply);
        _burn(msg.sender, paid + penaltyShares);

        uint256[LEGS] memory inKind;
        for (uint256 i = 0; i < LEGS; i++) {
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
        emit Redeemed(msg.sender, to, shares, usdgOut, feeShares, penaltyShares, inKind);
    }

    /**
     * @notice Leave in kind. No USDG flows, so the exit fee is in shares: `EXIT_FEE_BPS` of
     * `shares` move from the caller to the owner; on an early exit `EARLY_EXIT_PENALTY_BPS` of
     * them are burned without payout, which raises every remaining holder's part; the rest is
     * burned and paid as `held[i] x paid / totalSupply` of each of the seven and the same share
     * of the fund's USDG. No route, no feed, no router, nothing that can be paused: the door that
     * always works.
     *
     * `allowFail` makes it work even when a token does not (author, 2026-10-15: the mechanism
     * must never jam): bit i for leg i, bit 7 for USDG, meaning "I accept that this transfer may
     * fail". Every transfer is always attempted. Bit unset: `safeTransfer`, a failure reverts the
     * whole redeem. Bit set: a low-level `transfer(to, amount)` whose revert or false return is a
     * sentinel - the amount stays in the fund for the remaining holders, the redeem goes on, and
     * `forfeited` in `RedeemedInKind` names the legs. A transfer that succeeds always delivers,
     * whatever the mask: a frozen token can be waived, never a working one.
     */
    function redeemInKind(uint256 shares, address to, uint8 allowFail) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        (uint256 paid, uint256 supply, uint256 feeShares, uint256 penaltyShares) = _exit(shares);
        uint256[LEGS] memory held = _heldAll();
        uint256 usdgOut = Math.mulDiv(USDG.balanceOf(address(this)), paid, supply);
        _burn(msg.sender, paid + penaltyShares);

        uint8 forfeited;
        uint256[LEGS] memory amounts;
        for (uint256 i = 0; i < LEGS; i++) {
            uint256 due = Math.mulDiv(held[i], paid, supply);
            if (due == 0) continue;
            if (!_pay(_legs[i].token, to, due, allowFail, i)) {
                forfeited |= uint8(1 << i);
                continue;
            }
            amounts[i] = due;
            _cost[i] -= Math.mulDiv(_cost[i], due, held[i]);
        }
        if (usdgOut > 0 && !_pay(USDG, to, usdgOut, allowFail, 7)) {
            forfeited |= uint8(1 << 7);
            usdgOut = 0;
        }
        emit RedeemedInKind(msg.sender, to, shares, feeShares, penaltyShares, amounts, usdgOut, forfeited);
    }

    /// `mint`'s three guards, leg by leg, the first one that closes it: a feed notice running
    /// after a replacement, a dead feed on a held leg (any leg on the first mint), a live feed
    /// older than `MINT_FEED_AGE`. `readyAt` is when a notice ends; 0 otherwise (a stale feed
    /// opens at its next round, which nobody can date).
    function _mintGuard(Snapshot memory s, uint256 supply) private view returns (MintGuard guard, uint256 leg, uint256 readyAt) {
        for (uint256 i = 0; i < LEGS; i++) {
            State memory l = s.legs[i];
            uint256 noticeEnds = feedReplacedAt[i] + FEED_NOTICE;
            if (feedReplacedAt[i] > 0 && block.timestamp < noticeEnds) return (MintGuard.FeedNotice, i, noticeEnds);
            if (!l.live) {
                if (l.held > 0 || supply == 0) return (MintGuard.LegDead, i, 0);
            } else if (l.updatedAt < block.timestamp && block.timestamp - l.updatedAt > MINT_FEED_AGE) {
                return (MintGuard.FeedStale, i, 0);
            }
        }
        return (MintGuard.Open, 0, 0);
    }

    /// Both redeems' fee, in shares and before anything else: `EXIT_FEE_BPS` of `shares` moved
    /// to the owner, the early penalty left to be burned with the rest. Returns what is paid out
    /// (`paid`), the supply it is a share of, and the two fee amounts.
    function _exit(uint256 shares) private returns (uint256 paid, uint256 supply, uint256 feeShares, uint256 penaltyShares) {
        if (shares == 0) revert NothingToRedeem();
        feeShares = shares * EXIT_FEE_BPS / BPS;
        penaltyShares = shares * _penaltyBps(msg.sender) / BPS;
        if (feeShares > 0) _transfer(msg.sender, owner(), feeShares);
        paid = shares - feeShares - penaltyShares;
        supply = totalSupply();
    }

    /// @notice All a redeem by `holder` would cost now, in basis points: `EXIT_FEE_BPS` (30) to
    /// the owner, plus `EARLY_EXIT_PENALTY_BPS` (70) to the fund within `HOLD_PERIOD` of
    /// `heldSince(holder)` - 30 or 100.
    function exitFeeBps(address holder) external view returns (uint256) {
        return EXIT_FEE_BPS + _penaltyBps(holder);
    }

    /// The early-exit penalty `holder` would leave in the fund now: 70 bps or 0.
    function _penaltyBps(address holder) private view returns (uint256) {
        return block.timestamp < heldSince[holder] + HOLD_PERIOD ? EARLY_EXIT_PENALTY_BPS : 0;
    }

    /// Every share movement. A receiver's clock moves to the balance-weighted mean of what it held
    /// and what arrives (mints and transfers alike, fees included), so 1 wei from a stranger
    /// cannot restart it and a whole balance moved to a fresh address starts a fresh clock. What
    /// was held counts as at most one `HOLD_PERIOD` old in the mean (security review 2026-10-15,
    /// M7: an old small balance otherwise banked enough age to launder any fresh mint). Burns and
    /// sends leave the sender's clock alone; a transfer to oneself changes nothing.
    function _update(address from, address to, uint256 value) internal override {
        uint256 bal = to == address(0) ? 0 : balanceOf(to);
        super._update(from, to, value);
        if (to == address(0) || value == 0 || from == to) return;
        uint256 since = Math.max(heldSince[to], block.timestamp - HOLD_PERIOD);
        heldSince[to] = bal == 0 ? block.timestamp : (bal * since + value * block.timestamp) / (bal + value);
    }

    // ------------------------------------------------------------ rebalance ---

    /**
     * @notice Bring the live legs back toward `nav / liveCount`. The owner only - the author's
     * PC around the New York open (security review 2026-10-15, M3: a stranger's routes could keep
     * everything above the 1 % floor) - with the Trading API's routes. In order:
     *  1. at least `MIN_INTERVAL` since the last rebalance, or `TooSoon(readyAt)`;
     *  2. the management fee accrued since `lastAccrualAt`, minted to the owner; then every
     *     live feed must have a round newer than the one recorded last time (`FeedNotMoved`) -
     *     weekends and holidays write none, so nothing rebalances on them;
     *  3. `nav = sum of live values + USDG held`, `target = nav / liveCount`; a leg within
     *     `DEAD_BAND_BPS` of its target is in band;
     *  4. each route: a live leg out of band on the side of its delta (`LegNotDue`), at most
     *     one per leg (`DuplicateLeg`), sells before buys (`SellsFirst`), never past the target
     *     (`OverTrade`), floored at Chainlink value minus `TOLERANCE_BPS` on what arrived
     *     (`InsufficientOutput`);
     *  5. the rounds and the time recorded.
     * Fewer routes than legs out of band, or smaller amounts, are allowed: the fund ends the
     * day a little off and finishes tomorrow. An empty `routes` passes the sensors and consumes
     * the day.
     */
    function rebalance(Route[] calldata routes) external onlyOwner nonReentrant {
        uint256 readyAt = lastRebalanceAt + MIN_INTERVAL;
        if (block.timestamp < readyAt) revert TooSoon(readyAt);

        uint256 feeShares = pendingManagementFee();
        lastAccrualAt = block.timestamp;
        if (feeShares > 0) _mint(owner(), feeShares);

        Snapshot memory s = _snapshot();
        for (uint256 i = 0; i < LEGS; i++) {
            if (s.legs[i].live && s.legs[i].roundId <= _roundAt[i]) {
                IERC20 token = _legs[i].token;
                revert FeedNotMoved(address(token));
            }
        }

        uint256 seen;
        bool buying;
        for (uint256 k = 0; k < routes.length; k++) {
            Route calldata r = routes[k];
            if (r.leg >= LEGS) revert UnknownLeg(r.leg);
            LegConfig memory c = _legs[r.leg];
            (IERC20 token, uint256 scale) = (c.token, c.scale);
            // One bit per leg: 1 shifted left by the leg's index (< 7), the order the lint doubts.
            // forge-lint: disable-next-line(incorrect-shift)
            uint256 bit = 1 << r.leg;
            if (seen & bit != 0) revert DuplicateLeg(address(token));
            seen |= bit;
            if (r.sell && buying) revert SellsFirst();
            buying = !r.sell;

            State memory l = s.legs[r.leg];
            (bool due, bool sell, uint256 gap) = _due(l, s.target);
            if (!due || sell != r.sell) revert LegNotDue(address(token));

            uint256 answer = uint256(l.answer);
            uint256 amountOut;
            if (r.sell) {
                uint256 max = Math.mulDiv(gap, scale, answer);
                if (r.amountIn > max) revert OverTrade(address(token), r.amountIn, max);
                amountOut = _swap(token, USDG, r.amountIn, _sellFloor(r.amountIn, answer, scale), r);
                _cost[r.leg] -= Math.mulDiv(_cost[r.leg], r.amountIn, l.held);
            } else {
                if (r.amountIn > gap) revert OverTrade(address(token), r.amountIn, gap);
                amountOut = _swap(USDG, token, r.amountIn, _buyFloor(r.amountIn, answer, scale), r);
                _cost[r.leg] += r.amountIn;
            }
            emit LegTraded(address(token), r.sell, r.amountIn, amountOut, l.answer);
        }

        for (uint256 i = 0; i < LEGS; i++) {
            _roundAt[i] = s.legs[i].roundId;
        }
        lastRebalanceAt = block.timestamp;
        _lastNav = s.nav;
        _lastLiveCount = uint8(s.liveCount);
        _lastLegsTraded = uint8(routes.length);
        emit Rebalanced(s.nav, s.liveCount, routes.length, feeShares);
    }

    // ---------------------------------------------------------------- owner ---

    /// @notice Send this contract's whole balance of a stranger token to `to`. The seven and
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
     * old feed's counter. `mint` then waits `FEED_NOTICE` (3 days): the new feed is the owner's
     * choice, and holders who distrust it can redeem in kind before anyone mints against it.
     */
    function replaceFeed(uint8 leg, address feed) external onlyOwner {
        if (leg >= LEGS) revert UnknownLeg(leg);
        if (feed == address(0)) revert ZeroAddress();
        LegConfig storage c = _legs[leg];
        address old = c.feed;
        (bool ok,, int256 answer, uint256 updatedAt) = _readFeed(old);
        if (_isLive(ok, answer, updatedAt)) revert FeedStillLive(leg);
        if (_checkFeed(feed) != c.feedDecimals) revert BadFeed(feed);
        c.feed = feed;
        _roundAt[leg] = 0;
        feedReplacedAt[leg] = block.timestamp;
        emit FeedReplaced(leg, old, feed);
    }

    /// @notice Always reverts: ownership can be transferred, never renounced.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceForbidden();
    }

    // ---------------------------------------------------------------- views ---

    /// @notice The seven legs as they stand: holdings, feeds, value, and what was paid for them.
    function legs() external view returns (Leg[LEGS] memory out) {
        Snapshot memory s = _snapshot();
        for (uint256 i = 0; i < LEGS; i++) {
            LegConfig memory c = _legs[i];
            (IERC20 token, address feed) = (c.token, c.feed);
            State memory l = s.legs[i];
            out[i] = Leg({
                token: address(token),
                feed: feed,
                feedDecimals: c.feedDecimals,
                held: l.held,
                answer: l.answer,
                updatedAt: l.updatedAt,
                live: l.live,
                cost: _cost[i],
                avgCost: l.held == 0 ? 0 : Math.mulDiv(_cost[i], 10 ** c.tokenDecimals, l.held),
                value: l.value
            });
        }
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
     * whole plan, run as listed, is funded. `deviationBps` is `(value - target) / target`.
     */
    function plan() external view returns (PlanLeg[] memory out) {
        Snapshot memory s = _snapshot();
        PlanLeg[LEGS] memory rows;
        uint256 n;
        uint256 usdgAvailable = s.usdgHeld;
        for (uint256 pass = 0; pass < 2; pass++) {
            bool wantSell = pass == 0;
            for (uint256 i = 0; i < LEGS; i++) {
                (bool due, bool sell, uint256 gap) = _due(s.legs[i], s.target);
                if (!due || sell != wantSell) continue;
                LegConfig memory c = _legs[i];
                (IERC20 token, uint256 scale) = (c.token, c.scale);
                uint256 answer = uint256(s.legs[i].answer);
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
                int256 deviation = (int256(s.legs[i].value) - int256(s.target)) * int256(BPS) / int256(s.target);
                // forge-lint: disable-next-line(unsafe-typecast)
                rows[n++] = PlanLeg({ leg: uint8(i), token: address(token), sell: sell, amountIn: amountIn, minOut: minOut, deviationBps: deviation });
            }
        }
        out = new PlanLeg[](n);
        for (uint256 k = 0; k < n; k++) {
            out[k] = rows[k];
        }
    }

    /**
     * @notice How to split `mint(usdgIn, ...)`'s routes so the new money goes where it is
     * missing - advice for the page; `mint` accepts any split. The amounts split `net = usdgIn -
     * entry fee`, what the routes must spend. With `nav' = nav + net` and `target' = nav' /
     * liveCount`,
     * each live leg's deficit is `max(0, target' - value)`; deficits summing to more than `net`
     * are scaled down proportionally, a remainder is spread equally over the live legs (by
     * construction only `target'`'s rounding: the deficits sum to at least USDG held plus
     * `net`). Dead legs get 0. The amounts sum to `net` exactly, the rounding dust on the first
     * live leg. With no share yet, `net / liveCount` each. No live leg: all zero.
     */
    function mintPlan(uint256 usdgIn) external view returns (uint256[LEGS] memory amounts) {
        usdgIn -= usdgIn * ENTRY_FEE_BPS / BPS;
        Snapshot memory s = _snapshot();
        if (s.liveCount == 0) return amounts;
        uint256 first = LEGS;
        uint256 sum;
        if (totalSupply() == 0) {
            for (uint256 i = 0; i < LEGS; i++) {
                if (!s.legs[i].live) continue;
                if (first == LEGS) first = i;
                amounts[i] = usdgIn / s.liveCount;
                sum += amounts[i];
            }
        } else {
            uint256 target = (s.nav + usdgIn) / s.liveCount;
            uint256 deficits;
            for (uint256 i = 0; i < LEGS; i++) {
                if (!s.legs[i].live) continue;
                if (first == LEGS) first = i;
                if (target > s.legs[i].value) amounts[i] = target - s.legs[i].value;
                deficits += amounts[i];
            }
            uint256 spread = deficits < usdgIn ? (usdgIn - deficits) / s.liveCount : 0;
            for (uint256 i = 0; i < LEGS; i++) {
                if (!s.legs[i].live) continue;
                amounts[i] = deficits > usdgIn ? Math.mulDiv(amounts[i], usdgIn, deficits) : amounts[i] + spread;
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
        for (uint256 i = 0; i < LEGS; i++) {
            LegConfig memory c = _legs[i];
            (IERC20 t, address feed) = (c.token, c.feed);
            (bool ok, uint256 roundId, int256 answer, uint256 updatedAt) = _readFeed(feed);
            if (_isLive(ok, answer, updatedAt) && roundId <= _roundAt[i]) return (false, Sensor.FeedNotMoved, address(t), readyAt);
        }
        return (true, Sensor.Ready, address(0), readyAt);
    }

    /// @notice The last rebalance: when, the nav it saw, how many feeds were live, how many legs traded.
    function lastRebalance() external view returns (uint256 timestamp, uint256 navAt, uint256 liveCount, uint256 legsTraded) {
        return (lastRebalanceAt, _lastNav, _lastLiveCount, _lastLegsTraded);
    }

    /// @notice What either redeem door does now for `holder` redeeming `shares`: the shares paid
    /// out after the fee, the owner's fee and the early penalty (from `exitFeeBps(holder)`), and
    /// what the paid shares are due - each leg's amount and the USDG. `redeemInKind` pays exactly
    /// these; `redeem` sells what its routes name of `amounts` and pays the rest in kind.
    function previewRedeem(address holder, uint256 shares) external view returns (uint256 paid, uint256 feeShares, uint256 penaltyShares, uint256[LEGS] memory amounts, uint256 usdg) {
        uint256 supply = totalSupply();
        if (supply == 0 || shares == 0) return (0, 0, 0, amounts, 0);
        feeShares = shares * EXIT_FEE_BPS / BPS;
        penaltyShares = shares * _penaltyBps(holder) / BPS;
        paid = shares - feeShares - penaltyShares;
        uint256[LEGS] memory held = _heldAll();
        for (uint256 i = 0; i < LEGS; i++) {
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
    /// the USDG it pulls with the seven.
    function previewMintInKind(uint256[LEGS] calldata amounts) external view returns (uint256 shares, uint256 feeShares, uint256 usdgIn) {
        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0, 0);
        uint256 gross = _ratioShares(supply, _heldAll(), amounts);
        usdgIn = Math.mulDiv(USDG.balanceOf(address(this)), gross, supply, Math.Rounding.Ceil);
        feeShares = gross * ENTRY_FEE_BPS / BPS;
        shares = gross - feeShares;
    }

    /// @notice The management fee `rebalance` would mint to the owner now, in shares.
    function pendingManagementFee() public view returns (uint256) {
        return Math.mulDiv(totalSupply(), MANAGEMENT_FEE_BPS * (block.timestamp - lastAccrualAt), BPS * YEAR);
    }

    /// @notice The seven round ids recorded at the last rebalance (0 before the first one, or
    /// for a feed that did not answer then).
    function roundAtLastRebalance() external view returns (uint256[LEGS] memory) {
        return _roundAt;
    }

    // ------------------------------------------------------------- internal ---

    /// A feed m7m can read: code, a one-word `decimals()` <= 36, five words from
    /// `latestRoundData()`. Returns its decimals; refuses with `BadFeed` otherwise.
    function _checkFeed(address feed) private view returns (uint256 feedDecimals) {
        bool ok;
        (ok, feedDecimals) = _readUint(feed, 0x313ce567); // decimals()
        if (!ok || feedDecimals > 36) revert BadFeed(feed);
        (bool answers,,,) = _readFeed(feed);
        if (!answers) revert BadFeed(feed);
    }

    function _heldAll() private view returns (uint256[LEGS] memory held) {
        for (uint256 i = 0; i < LEGS; i++) {
            IERC20 token = _legs[i].token;
            held[i] = token.balanceOf(address(this));
        }
    }

    /// The fund at this instant: each leg's balance and feed, the live values, nav and target.
    function _snapshot() private view returns (Snapshot memory s) {
        s.usdgHeld = USDG.balanceOf(address(this));
        s.nav = s.usdgHeld;
        for (uint256 i = 0; i < LEGS; i++) {
            LegConfig memory c = _legs[i];
            (IERC20 token, address feed, uint256 scale) = (c.token, c.feed, c.scale);
            State memory l = s.legs[i];
            l.held = token.balanceOf(address(this));
            bool ok;
            (ok, l.roundId, l.answer, l.updatedAt) = _readFeed(feed);
            l.live = _isLive(ok, l.answer, l.updatedAt);
            if (!l.live) continue;
            l.value = Math.mulDiv(l.held, uint256(l.answer), scale);
            s.nav += l.value;
            s.liveCount++;
        }
        if (s.liveCount > 0) s.target = s.nav / s.liveCount;
    }

    /// Whether a live leg is out of band, on which side, and by how much (USDG).
    function _due(State memory l, uint256 target) private pure returns (bool due, bool sell, uint256 gap) {
        if (!l.live) return (false, false, 0);
        sell = l.value > target;
        gap = sell ? l.value - target : target - l.value;
        due = gap > 0 && gap >= target * DEAD_BAND_BPS / BPS;
    }

    /// The least USDG a sell of `amountIn` tokens must bring: Chainlink value less the tolerance.
    function _sellFloor(uint256 amountIn, uint256 answer, uint256 scale) private pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(amountIn, answer, scale), BPS - TOLERANCE_BPS, BPS);
    }

    /// The fewest tokens a buy of `amountIn` USDG must bring: Chainlink quantity less the tolerance.
    function _buyFloor(uint256 amountIn, uint256 answer, uint256 scale) private pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(amountIn, scale, answer), BPS - TOLERANCE_BPS, BPS);
    }

    /// `supply x min over legs with held > 0 of (incoming / held)`; 0 when no leg is held.
    function _ratioShares(uint256 supply, uint256[LEGS] memory held, uint256[LEGS] memory incoming) private pure returns (uint256 shares) {
        shares = type(uint256).max;
        for (uint256 i = 0; i < LEGS; i++) {
            if (held[i] == 0) continue;
            shares = Math.min(shares, Math.mulDiv(supply, incoming[i], held[i]));
        }
        if (shares == type(uint256).max) shares = 0;
    }

    /// One swap. The contract never encodes a route: the caller brings Uniswap's Trading API
    /// bytes, rewritten with m7m as payer (`payerIsUser: false`) and recipient. `amountIn` is
    /// transferred straight into the official Universal Router - no intermediate contract, no
    /// approval to anyone (author, 2026-10-15) - the bytes run, and what arrived here is measured
    /// as a balance difference and floored by `minOut`: the recipe `UniswapPermit2Gate` proved to
    /// the wei on fork, inline. The security is in that measured output, never in the bytes.
    /// Input a route does not consume stays in the router. m7m has no `receive()`: a route ending
    /// in native ETH delivers nothing here and fails its floor.
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
    function _pay(IERC20 token, address to, uint256 amount, uint8 allowFail, uint256 bit) private returns (bool) {
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
