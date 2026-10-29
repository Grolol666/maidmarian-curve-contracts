// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test, console2, stdStorage, StdStorage } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IUniversalRouter } from "../src/MaidMarianSevenMagnificent.sol";
import { TickMath } from "../src/uniswap/TickMath.sol";
import { MaidMarianEtfFactoryV4 as Factory } from "../src/MaidMarianEtfFactoryV4.sol";
import { MaidMarianBagPoolOracle } from "../src/MaidMarianBagPoolOracle.sol";
import { MaidMarianEtfV4 as Etf } from "../src/MaidMarianEtfV4.sol";
import { SOURCE_NONE, SOURCE_POOL, SOURCE_NAV, SOURCE_SPOT } from "../src/MaidMarianEtfV3.sol";
import { TokenMock, FreezableTokenMock, PoolMock, UniversalRouterMock, UniswapV3FactoryMock, BrickableTokenMock, V4KeyMock, V4SingleMock, PoolManagerMock } from "./Mocks.sol";

/**
 * The v3 bis suite (`MaidMarianEtfV3.t.sol`) ported to the ETF v4 and its factory: the same
 * claims on the same mocks, each test unchanged but where the v4 differs - a V4 pool registered with its
 * hook (`setTokenV4Pool` takes four arguments, `poolsOf` returns five), a rebalance test's overweight
 * leg made a counted holding (`_credit`) where the v3's was a donation, and the four final-review
 * claims about donations and an unread leg now the v4's. The v4's own claims (the count, the rescue,
 * hooked routes) are `MaidMarianEtfV4Count.t.sol`. The v3 bis header follows.
 *
 * Offline, on `test/Mocks.sol`: the factory's doors and
 * bounds (the adjustable creation fee, symbols, legs, depth 2, logo, the token list with ETFs
 * listed like tokens, each with its pool and an oracle of 1 801 observations at least,
 * `getPriceUsdg`'s one order NAV / TWAP / spot in USDG, `paramBounds()` and the fixed rules answered
 * before any ETF, `oracleOf`) and the ETF v3's (the in-kind mint formula and its claim that
 * holders never lose to a minter, the first mint's split, the refunds to the minter, every mint
 * raising its caller's own `mintOf`, both redeems and their three cases, the rebalance with its
 * floor written into the swap, the fixed management fee split, an ETF leg bought and sold through
 * its pool at its NAV; the band in points of the NAV and no floor, a min interval of 0, the entry
 * fee in USDG on `mint` and in shares on `mintInKind`, the exit fee and the penalties in shares on
 * both redeems, each split with the protocol (30 %, 0.10 % at least at entry), every fee share in
 * its receiver's `mintOf`, and a frozen USDG recipient blocking `mint`, the one door that pushes
 * USDG to it, until its holder moves it - USDG's mock freezes like the real one; and every
 * swap's router call written whole by the contract, V3 or hookless V4, nothing a router sends
 * beyond the swap credited, a spot never traded on, no NAV inside an ETF's own door, the early
 * penalty at most the non-minter one, symbols not unique; and the management fee accrued at every
 * door, before any share is minted or burned, its rest short of a share carried). These prove the contracts' arithmetic and refusals against mocks; that real
 * pools and routes behave as the mocks do is `MaidMarianEtfFactoryV4.fork.t.sol`.
 *
 * The router trades each token at a round price of the form 2^a 5^b USDG (so `1e30 / price` is
 * exact and every holding is to the wei), and its pool's tick is the nearest at or below that
 * price, so the factory reads it within one tick, 1 bp: holdings and shares are asserted to the
 * wei, values and floors to 1 bp. Tokens 18 decimals, USDG 6. The router mock enforces
 * `amountOutMin` as the real one does (`V3TooLittleReceived`).
 */
contract MaidMarianEtfV4Base is Test {
    TokenMock internal usdg;
    UniversalRouterMock internal router;
    UniswapV3FactoryMock internal v3;
    Factory internal factory;

    address internal owner = makeAddr("owner");
    address internal maker = makeAddr("maker"); // the creator
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol"); // receives only what a door pays

    uint256 internal constant FEE = 0.01 ether;
    int24 internal constant TICK_100_USD = -230_259; // 1.0001^-230259 ~ 1e-10 USDG unit per raw unit

    function setUp() public virtual {
        vm.warp(1_790_000_000);
        usdg = new FreezableTokenMock("USDG", "USDG", 6);
        router = new UniversalRouterMock();
        router.setSink(makeAddr("pools")); // the input leaves the router, as for a pool
        v3 = new UniswapV3FactoryMock();
        factory = new Factory(IERC20(address(usdg)), IUniversalRouter(address(router)), address(v3), owner);
        usdg.mint(address(router), 1e30);
        for (uint256 i = 0; i < 3; i++) {
            address who = i == 0 ? alice : i == 1 ? bob : maker;
            usdg.mint(who, 1e15);
            vm.deal(who, 1 ether);
        }
    }

    /// One tick, the most the factory's TWAP reading sits under the router's round price.
    uint256 internal constant ONE_BP = 1e14;

    // ------------------------------------------------------------ helpers ---

    /// A listed 18-decimal token whose pool's TWAP prices it at `price` USDG (to one tick below),
    /// the router trading it at exactly `price` both ways.
    function _token(string memory name, uint256 price) internal returns (TokenMock t, PoolMock p) {
        t = new TokenMock(name, name, 18);
        t.mint(address(router), 1e30);
        p = _pool(address(t), _tickAt(price * 1e18));
        vm.prank(owner);
        factory.addToken(address(t), address(p));
        _routerAt(address(t), price * 1e18);
    }

    /// The tick, for an 18-decimal token as token0 against USDG's 6, at or just under `price18`
    /// (USDG per whole token, 18 decimals): `sqrtPriceX96 = sqrt(price18 x 2^192 / 1e30)`.
    function _tickAt(uint256 price18) internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(Math.mulDiv(price18, 1 << 192, 1e30))));
    }

    /// A token/USDG pool mock at the 0.3 % tier whose mean tick prices `token` (as token0) at
    /// `tickForToken0`, registered in the Uniswap V3 factory mock.
    function _pool(address token, int24 tickForToken0) internal returns (PoolMock p) {
        return _poolAt(token, tickForToken0, 3000);
    }

    /// The same at fee tier `fee`, so a test can hold two pools of one pair.
    function _poolAt(address token, int24 tickForToken0, uint24 fee) internal returns (PoolMock p) {
        bool tokenFirst = token < address(usdg);
        p = tokenFirst ? new PoolMock(token, address(usdg)) : new PoolMock(address(usdg), token);
        p.setFee(fee);
        p.setAverageTick(tokenFirst ? tickForToken0 : -tickForToken0);
        v3.setPool(p);
    }

    /// What the router delivers of `tokenOut` for `amountIn` of `tokenIn`, at its set rate.
    function _out(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        return amountIn * router.pairRate(tokenIn, tokenOut) / 1e18;
    }

    /// `slot0`'s `sqrtPriceX96` for a spot of 100 USDG per whole 18-decimal token against USDG's 6:
    /// 1e-10 USDG unit per raw unit, so sqrt is 1e-5 (token first) or 1e5 (USDG first).
    function _spot100(address token) internal view returns (uint160) {
        return token < address(usdg) ? uint160((uint256(1) << 96) / 1e5) : uint160((uint256(1) << 96) * 1e5);
    }

    /// The router trades `token` at `price18` (USDG per whole token, 18 decimals) both ways.
    function _routerAt(address token, uint256 price18) internal {
        router.setPairRate(address(usdg), token, 1e48 / price18);
        router.setPairRate(token, address(usdg), price18 / 1e12);
    }

    function _params() internal pure returns (Etf.Params memory) {
        return Etf.Params({ entryFeeBps: 20, exitFeeBps: 0, holdPeriod: 1 hours, earlyPenaltyBps: 100, nonMinterPenaltyBps: 200, rebalanceBandBps: 200, rebalanceMinInterval: 1 hours });
    }

    function _noProfile() internal pure returns (Factory.Profile memory) {
        return Factory.Profile({ description: "", x: "", telegram: "", website: "" });
    }

    function _spec(address[] memory tokens, uint16[] memory bps) internal pure returns (Factory.LegSpec[] memory l) {
        l = new Factory.LegSpec[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            l[i] = Factory.LegSpec({ token: tokens[i], bps: bps[i] });
        }
    }

    function _create(string memory symbol, address[] memory tokens, uint16[] memory bps) internal returns (Etf etf) {
        return _createWith(symbol, tokens, bps, _params());
    }

    function _createWith(string memory symbol, address[] memory tokens, uint16[] memory bps, Etf.Params memory p) internal returns (Etf etf) {
        vm.prank(maker);
        etf = factory.createEtf{ value: FEE }(string.concat("Maid Marian ", symbol), symbol, "", _spec(tokens, bps), p, _noProfile());
        for (uint256 i = 0; i < 3; i++) {
            address who = i == 0 ? alice : i == 1 ? bob : maker;
            vm.prank(who);
            usdg.approve(address(etf), type(uint256).max);
        }
    }

    /// List a factory ETF as a token, with a pool of it against USDG at `tick` (its NAV is its price).
    function _listEtf(Etf etf, int24 tick) internal returns (PoolMock p) {
        p = _pool(address(etf), tick);
        vm.prank(owner);
        factory.addToken(address(etf), address(p));
    }

    function _two(address a, address b) internal pure returns (address[] memory t) {
        t = new address[](2);
        (t[0], t[1]) = (a, b);
    }

    function _bps2(uint16 a, uint16 b) internal pure returns (uint16[] memory w) {
        w = new uint16[](2);
        (w[0], w[1]) = (a, b);
    }

    function _one(address a) internal pure returns (address[] memory t) {
        t = new address[](1);
        t[0] = a;
    }

    function _all() internal pure returns (uint16[] memory w) {
        w = new uint16[](1);
        w[0] = 10_000;
    }

    /// A route through the leg's registered V3 pool, a minimum of 0.
    function _swapRoute(uint8 leg, bool sell, uint256 amountIn) internal view returns (Etf.Route memory r) {
        r = Etf.Route({ leg: leg, sell: sell, v4: false, amountIn: amountIn, amountOutMin: 0, deadline: block.timestamp + 60 });
    }

    /// A route through the leg's registered V4 pool, a minimum of 0.
    function _v4Route(uint8 leg, bool sell, uint256 amountIn) internal view returns (Etf.Route memory r) {
        r = Etf.Route({ leg: leg, sell: sell, v4: true, amountIn: amountIn, amountOutMin: 0, deadline: block.timestamp + 60 });
    }

    /// The V4 key of `token` and USDG, sorted, at `fee` / `spacing` with `hooks`.
    function _v4Key(address token, uint24 fee, int24 spacing, address hooks) internal view returns (V4KeyMock memory) {
        (address c0, address c1) = token < address(usdg) ? (token, address(usdg)) : (address(usdg), token);
        return V4KeyMock({ currency0: c0, currency1: c1, fee: fee, tickSpacing: spacing, hooks: hooks });
    }

    /// A hookless V4 pool of `token` and USDG initialised on the router's PoolManager and registered by the owner.
    function _v4Pool(address token, uint24 fee, int24 spacing) internal {
        _v4PoolHooked(token, fee, spacing, address(0));
    }

    /// The same with `hooks`, which the factory does not check.
    function _v4PoolHooked(address token, uint24 fee, int24 spacing, address hooks) internal {
        PoolManagerMock(router.poolManager()).initialize(_v4Key(token, fee, spacing, hooks), _spot100(token));
        vm.prank(owner);
        factory.setTokenV4Pool(token, fee, spacing, hooks);
    }

    /// Buy routes for a mint of `amount` USDG on `etf`'s legs by their bps - the first mint's exact
    /// split of what the entry fee leaves (`firstMintSplit(amount)`) when `exact`, else 99 % of
    /// `amount` split by the bps, so the routes leave the fund its USDG part once a fee of at most
    /// 1 % is taken.
    function _buyRoutes(Etf etf, uint256 amount, bool exact) internal view returns (Etf.Route[] memory r) {
        Etf.Leg[] memory legs = etf.legs();
        uint256[] memory split = new uint256[](legs.length);
        if (exact) {
            split = etf.firstMintSplit(amount);
        } else {
            uint256 spend = amount - amount / 100;
            uint256 sum;
            for (uint256 i = 0; i < legs.length; i++) {
                split[i] = spend * legs[i].bps / 10_000;
                sum += split[i];
            }
            split[0] += spend - sum;
        }
        r = new Etf.Route[](legs.length);
        for (uint256 i = 0; i < legs.length; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            r[i] = _swapRoute(uint8(i), false, split[i]);
        }
    }

    /// Sell routes for `amounts` of each leg.
    function _sellRoutes(Etf etf, uint256[] memory amounts) internal view returns (Etf.Route[] memory r) {
        Etf.Leg[] memory legs = etf.legs();
        r = new Etf.Route[](legs.length);
        for (uint256 i = 0; i < legs.length; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            r[i] = _swapRoute(uint8(i), true, amounts[i]);
        }
    }

    function _mint(Etf etf, address who, uint256 usdgIn) internal returns (uint256 shares) {
        Etf.Route[] memory r = _buyRoutes(etf, usdgIn, etf.totalSupply() == 0);
        vm.prank(who);
        shares = etf.mint(usdgIn, r, 1);
    }

    /// Where the ETF keeps its counts (`forge inspect MaidMarianEtfV4 storageLayout`): leg i at
    /// `COUNT_SLOT + i`, the USDG at `USDG_COUNT_SLOT`; `test_TheCountSlotsAreTheOnesTheTestsWrite` checks them.
    uint256 internal constant COUNT_SLOT = 15;
    uint256 internal constant USDG_COUNT_SLOT = 25;

    /// A holding the fund counts, as a door would leave it - what a rebalance test starts from: `amount`
    /// of `token` minted to the fund and added to its count. A plain transfer to the fund is a donation,
    /// which no door counts.
    function _credit(Etf etf, address token, uint256 amount) internal {
        TokenMock(token).mint(address(etf), amount);
        _addCount(etf, token, amount);
    }

    /// `amount` added to the fund's count of `token`, for units already sent to it.
    function _addCount(Etf etf, address token, uint256 amount) internal {
        bytes32 slot = bytes32(token == address(usdg) ? USDG_COUNT_SLOT : COUNT_SLOT + _legIndex(etf, token));
        vm.store(address(etf), slot, bytes32(uint256(vm.load(address(etf), slot)) + amount));
    }

    function _legIndex(Etf etf, address token) internal view returns (uint256) {
        Etf.Leg[] memory legs = etf.legs();
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].token == token) return i;
        }
        revert("not a leg");
    }

    /// Each leg's holding and the USDG, per 1e18 shares, at 1e18 precision.
    function _perShare(Etf etf) internal view returns (uint256[] memory out) {
        Etf.Leg[] memory legs = etf.legs();
        out = new uint256[](legs.length + 1);
        uint256 supply = etf.totalSupply();
        for (uint256 i = 0; i < legs.length; i++) {
            out[i] = IERC20(legs[i].token).balanceOf(address(etf)) * 1e36 / supply;
        }
        out[legs.length] = usdg.balanceOf(address(etf)) * 1e36 / supply;
    }

    function _planRoutes(Etf.PlanLeg[] memory p) internal view returns (Etf.Route[] memory r) {
        r = new Etf.Route[](p.length);
        for (uint256 k = 0; k < p.length; k++) {
            r[k] = _swapRoute(p[k].leg, p[k].sell, p[k].amountIn);
        }
    }

    /// A PNG header the factory accepts: the signature, an IHDR of `w` x `h`, padded to `size`.
    function _png(uint32 w, uint32 h, uint256 size) internal pure returns (bytes memory png) {
        png = new bytes(size);
        bytes memory head = abi.encodePacked(hex"89504e470d0a1a0a", uint32(13), "IHDR", w, h, hex"0806000000");
        for (uint256 i = 0; i < head.length; i++) {
            png[i] = head[i];
        }
        for (uint256 i = head.length; i < size; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            png[i] = bytes1(uint8(i * 31));
        }
    }
}

contract MaidMarianEtfFactoryV4Test is MaidMarianEtfV4Base {
    TokenMock internal a;
    TokenMock internal b;
    PoolMock internal pa;
    PoolMock internal pb;

    function setUp() public override {
        super.setUp();
        (a, pa) = _token("AAA", 250);
        (b, pb) = _token("BBB", 500);
    }

    // ---------------------------------------------------------- creation ---

    /// The creation costs exactly `creationFee()`, 0.01 ETH at deploy, by anyone; the fee stays in
    /// the factory until the owner pulls it, and nobody else can.
    function test_AnyoneCreatesAnEtfForExactlyTheCreationFeeWhichTheOwnerPulls() public {
        assertEq(factory.creationFee(), FEE);
        assertEq(factory.INITIAL_CREATION_FEE(), FEE);
        Factory.LegSpec[] memory l = _spec(_two(address(a), address(b)), _bps2(6000, 4000));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Factory.WrongCreationFee.selector, FEE, 0));
        factory.createEtf("x", "X", "", l, _params(), _noProfile());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Factory.WrongCreationFee.selector, FEE, 2 * FEE));
        factory.createEtf{ value: 2 * FEE }("x", "X", "", l, _params(), _noProfile());

        vm.prank(alice);
        Etf etf = factory.createEtf{ value: FEE }("Maid Marian X", "X", "", l, _params(), _noProfile());
        assertEq(address(factory).balance, FEE);
        assertEq(etf.creator(), alice);
        assertEq(factory.etfCount(), 1);
        assertEq(factory.etfs(0), address(etf));
        assertTrue(factory.isEtf(address(etf)));
        assertFalse(factory.isEligible(address(etf)), "an ETF is a leg only once the owner lists it");
        assertEq(factory.etfInfo(address(etf)).depth, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.withdrawFees(payable(alice));
        vm.prank(owner);
        assertEq(factory.withdrawFees(payable(carol)), FEE);
        assertEq(carol.balance, FEE);
        assertEq(address(factory).balance, 0);
    }

    /// The creation fee is the owner's to set, at once, with an event; `createEtf` then takes the
    /// new value exactly and refuses the old one, so a change can make a pending creation revert,
    /// never charge it more than it sent. Zero is a fee too.
    function test_TheOwnerSetsTheCreationFeeAndCreationTakesExactlyTheNewOne() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setCreationFee(1 ether);
        vm.expectEmit(false, false, false, true, address(factory));
        emit Factory.CreationFeeChanged(FEE, 0.05 ether);
        vm.prank(owner);
        factory.setCreationFee(0.05 ether);
        assertEq(factory.creationFee(), 0.05 ether);

        Factory.LegSpec[] memory l = _spec(_two(address(a), address(b)), _bps2(5000, 5000));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Factory.WrongCreationFee.selector, 0.05 ether, FEE));
        factory.createEtf{ value: FEE }("n", "OLD", "", l, _params(), _noProfile());
        vm.prank(alice);
        factory.createEtf{ value: 0.05 ether }("n", "NEW", "", l, _params(), _noProfile());

        vm.prank(owner);
        factory.setCreationFee(0);
        vm.prank(alice);
        factory.createEtf("n", "FREE", "", l, _params(), _noProfile());
        assertEq(address(factory).balance, 0.05 ether);
    }

    /// The event carries what a page lists an ETF by: its index, name, symbol, legs, params, depth, logo, profile.
    function test_TheCreationEventCarriesEverythingAListNeeds() public {
        Factory.LegSpec[] memory l = _spec(_two(address(a), address(b)), _bps2(6000, 4000));
        bytes memory png = _png(64, 64, 200);
        Factory.Profile memory pro = Factory.Profile({ description: "A basket.", x: "https://x.com/abc", telegram: "", website: "https://example.com" });
        address next = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.expectEmit(true, true, false, true, address(factory));
        emit Factory.EtfCreated(next, alice, 0, "Maid Marian X", "X", l, _params(), 1, png, pro);
        vm.prank(alice);
        factory.createEtf{ value: FEE }("Maid Marian X", "X", png, l, _params(), pro);
    }

    /// Symbols are not unique (author, 2026-10-19): the ETF's address identifies it, as for any
    /// ERC-20. `MAI` twice and `mai` once, by two creators, are three ETFs, each keeping its symbol
    /// as typed; the allowlist still applies.
    function test_TwoEtfsMayShareASymbol() public {
        Etf first = _create("MAI", _two(address(a), address(b)), _bps2(5000, 5000));
        Factory.LegSpec[] memory l = _spec(_two(address(a), address(b)), _bps2(5000, 5000));
        vm.prank(bob);
        Etf second = factory.createEtf{ value: FEE }("y", "MAI", "", l, _params(), _noProfile());
        vm.prank(bob);
        Etf third = factory.createEtf{ value: FEE }("y", "mai", "", l, _params(), _noProfile());
        assertTrue(address(first) != address(second) && address(second) != address(third));
        assertEq(first.symbol(), "MAI");
        assertEq(second.symbol(), "MAI");
        assertEq(third.symbol(), "mai", "the symbol as its creator typed it");
        assertEq(factory.etfCount(), 3);
        assertTrue(factory.isEtf(address(second)));
    }

    /// The symbol: 1 to 11 bytes of [A-Za-z0-9]. Empty, 12 bytes, a dot, a dash, a space, a control
    /// character, an accent, an emoji and a zero-width space are each refused; 11 passes.
    function test_ASymbolIsOneToElevenLettersOrDigits() public {
        Factory.LegSpec[] memory l = _spec(_two(address(a), address(b)), _bps2(5000, 5000));
        string[9] memory refused = ["", "ABCDEFGHIJKL", "m.AI", "m-AI", "m AI", "mAI\n", unicode"mAÉ", unicode"m🚀", string(hex"6de2808b4149")];
        vm.startPrank(bob);
        for (uint256 i = 0; i < refused.length; i++) {
            vm.expectRevert(Factory.BadSymbol.selector);
            factory.createEtf{ value: FEE }("Fine Name", refused[i], "", l, _params(), _noProfile());
        }
        factory.createEtf{ value: FEE }("Fine Name", "ABCDEFGHIJK", "", l, _params(), _noProfile());
        vm.stopPrank();
    }

    /// The name: 1 to 64 bytes of [A-Za-z0-9], space, - . & ' ; no space first or last, no two in a
    /// row. Each refusal by `BadName` - empty, a space first, last or doubled, a tab, a NUL, an
    /// accent, an emoji, a zero-width space, a slash, 65 bytes; every allowed sign and 64 bytes pass.
    function test_ANameIsLettersDigitsAndFiveSignsWithSingleInnerSpaces() public {
        Factory.LegSpec[] memory l = _spec(_two(address(a), address(b)), _bps2(5000, 5000));
        string[11] memory refused = [
            "",
            " Gold",
            "Gold ",
            "Gold  Oil",
            "Gold\tOil",
            "Gold\x00",
            unicode"Gold é",
            unicode"Gold 🥇",
            string(hex"476f6c64e2808b4f696c"),
            "Gold/Oil",
            "12345678901234567890123456789012345678901234567890123456789012345"
        ];
        vm.startPrank(bob);
        for (uint256 i = 0; i < refused.length; i++) {
            vm.expectRevert(Factory.BadName.selector);
            factory.createEtf{ value: FEE }(refused[i], string.concat("N", vm.toString(i)), "", l, _params(), _noProfile());
        }
        Etf ok = factory.createEtf{ value: FEE }("Maid Marian Gold & Oil - J.P.'s 2", "GOIL", "", l, _params(), _noProfile());
        factory.createEtf{ value: FEE }("1234567890123456789012345678901234567890123456789012345678901234", "LONG", "", l, _params(), _noProfile());
        vm.stopPrank();
        assertEq(ok.name(), "Maid Marian Gold & Oil - J.P.'s 2");
    }

    /// Legs: eligible only, no duplicate, bps above 0 summing to 10 000, 1 to 10 of them.
    function test_LegsMustBeEligibleDistinctAndSumToTenThousandBps() public {
        TokenMock stranger = new TokenMock("S", "S", 18);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Factory.NotEligible.selector, address(stranger)));
        factory.createEtf{ value: FEE }("n", "N1", "", _spec(_two(address(a), address(stranger)), _bps2(5000, 5000)), _params(), _noProfile());
        vm.expectRevert(abi.encodeWithSelector(Factory.DuplicateToken.selector, address(a)));
        factory.createEtf{ value: FEE }("n", "N2", "", _spec(_two(address(a), address(a)), _bps2(5000, 5000)), _params(), _noProfile());
        vm.expectRevert(abi.encodeWithSelector(Factory.BadBps.selector, 9999));
        factory.createEtf{ value: FEE }("n", "N3", "", _spec(_two(address(a), address(b)), _bps2(5000, 4999)), _params(), _noProfile());
        vm.expectRevert(abi.encodeWithSelector(Factory.BadBps.selector, 0));
        factory.createEtf{ value: FEE }("n", "N4", "", _spec(_two(address(a), address(b)), _bps2(10_000, 0)), _params(), _noProfile());
        vm.expectRevert(abi.encodeWithSelector(Factory.BadLegCount.selector, 0));
        factory.createEtf{ value: FEE }("n", "N5", "", new Factory.LegSpec[](0), _params(), _noProfile());
        vm.stopPrank();

        Etf single = _create("ONE", _one(address(a)), _all());
        assertEq(single.LEGS(), 1, "a single leg is an ETF too");

        address[] memory eleven = new address[](11);
        uint16[] memory w = new uint16[](11);
        for (uint256 i = 0; i < 11; i++) {
            (TokenMock t,) = _token(string.concat("T", vm.toString(i)), 100);
            eleven[i] = address(t);
            w[i] = i == 0 ? 1000 : 900;
        }
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Factory.BadLegCount.selector, 11));
        factory.createEtf{ value: FEE }("n", "N6", "", _spec(eleven, w), _params(), _noProfile());
    }

    /// An ETF of ETFs is depth 2 and allowed; one more level is `TooDeep(3)` (`MAX_DEPTH = 2`). An
    /// ETF is a leg only once the owner lists it with a pool: before, `NotEligible`.
    function test_EtfsNestTwoDeepAndNoFurther() public {
        assertEq(factory.MAX_DEPTH(), 2);
        Etf one = _create("D1", _two(address(a), address(b)), _bps2(5000, 5000));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Factory.NotEligible.selector, address(one)));
        factory.createEtf{ value: FEE }("n", "D2", "", _spec(_two(address(one), address(a)), _bps2(5000, 5000)), _params(), _noProfile());
        _listEtf(one, TICK_100_USD);
        assertTrue(factory.isEligible(address(one)));
        Etf two = _create("D2", _two(address(one), address(a)), _bps2(5000, 5000));
        assertEq(factory.etfInfo(address(two)).depth, 2);
        _listEtf(two, TICK_100_USD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Factory.TooDeep.selector, 3));
        factory.createEtf{ value: FEE }("n", "D3", "", _spec(_two(address(two), address(b)), _bps2(5000, 5000)), _params(), _noProfile());
    }

    /// No cycle can exist: a leg is eligible only once it exists and is listed, so the address the
    /// next ETF will take is refused as its own leg, and an ETF's legs never change after.
    function test_AnEtfCannotHoldItselfBecauseItsAddressIsNotEligibleBeforeItExists() public {
        address next = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Factory.NotEligible.selector, next));
        factory.createEtf{ value: FEE }("n", "SELF", "", _spec(_two(address(a), next), _bps2(5000, 5000)), _params(), _noProfile());
        Etf made = _create("SELF", _two(address(a), address(b)), _bps2(5000, 5000));
        assertTrue(address(made) == next, "the refused address is the one the ETF then took");
        Factory.LegSpec[] memory legs = factory.legsOf(address(made));
        assertEq(legs[0].token, address(a));
        assertEq(legs[1].token, address(b));
    }

    // -------------------------------------------------------------- logo ---

    /// A PNG is stored once as code and read back byte for byte; empty is allowed and reads empty.
    function test_APngLogoIsStoredAndReadBackAndAnEmptyOneIsAllowed() public {
        bytes memory png = _png(256, 128, 1000);
        Factory.LegSpec[] memory l = _spec(_two(address(a), address(b)), _bps2(5000, 5000));
        vm.prank(alice);
        Etf etf = factory.createEtf{ value: FEE }("L", "L", png, l, _params(), _noProfile());
        assertEq(factory.logo(address(etf)), png);
        assertEq(etf.logo(), png);
        Etf bare = _create("BARE", _two(address(a), address(b)), _bps2(5000, 5000));
        assertEq(bare.logo().length, 0);
        assertEq(factory.etfInfo(address(bare)).logoPointer, address(0));
    }

    /// The factory refuses what is not a PNG it accepts: a wrong signature, no IHDR first, a side of
    /// 0 or over 256, more than 16 KiB; 16 KiB exactly passes.
    function test_ALogoMustBeAPngOfAtMost256PixelsAndSixteenKibibytes() public {
        Factory.LegSpec[] memory l = _spec(_two(address(a), address(b)), _bps2(5000, 5000));
        bytes memory bad = _png(64, 64, 100);
        bad[1] = "Q";
        bytes memory noIhdr = _png(64, 64, 100);
        noIhdr[12] = "X";
        bytes[5] memory refused = [bad, noIhdr, _png(257, 64, 100), _png(64, 0, 100), _png(64, 64, 16_385)];
        vm.startPrank(alice);
        for (uint256 i = 0; i < refused.length; i++) {
            vm.expectRevert(Factory.BadLogo.selector);
            factory.createEtf{ value: FEE }("L", string.concat("L", vm.toString(i)), refused[i], l, _params(), _noProfile());
        }
        vm.expectRevert(Factory.BadLogo.selector);
        factory.createEtf{ value: FEE }("L", "SHORT", hex"89504e470d0a1a0a", l, _params(), _noProfile());
        Etf etf = factory.createEtf{ value: FEE }("L", "BIG", _png(256, 256, 16_384), l, _params(), _noProfile());
        vm.stopPrank();
        assertEq(etf.logo().length, 16_384);
    }

    // ------------------------------------------------------------ tokens ---

    /// The owner alone lists, removes and re-sources tokens and sets the fee; renouncing reverts.
    function test_OnlyTheOwnerListsTokensAndOwnershipIsNeverRenounced() public {
        TokenMock t = new TokenMock("T", "T", 18);
        PoolMock tp = _pool(address(t), TICK_100_USD);
        PoolMock other = _poolAt(address(a), _tickAt(250e18), 500);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.addToken(address(t), address(tp));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.removeToken(address(a));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setTokenSources(address(a), address(other));
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(Factory.RenounceForbidden.selector);
        factory.renounceOwnership();
        assertEq(factory.owner(), owner);
    }

    /// The V4 pool a token may have (`setTokenV4Pool`), by the owner alone: its key is the token and
    /// USDG sorted, the fee, spacing and hooks given, the hook not checked, the pool checked initialised
    /// on the router's own PoolManager (`POOL_MANAGER`, read from `poolManager()`). Refused: an unknown
    /// token, a key no pool was initialised at - the hookless key at a hooked pool's fee and spacing, and
    /// that pool's key under another hook, name nothing. Registered hooked, then hookless, then cleared
    /// with `(0, 0, 0)`, each with its event; `poolsOf` and `tokenInfo` give both pools and the hook. A
    /// listed factory ETF takes one the same way.
    function test_TheOwnerRegistersAnInitialisedV4PoolWithOrWithoutAHookAndClearsIt() public {
        PoolManagerMock manager = PoolManagerMock(router.poolManager());
        assertEq(factory.POOL_MANAGER(), address(manager));
        address hook = makeAddr("hook");
        manager.initialize(_v4Key(address(a), 500, 10, hook), _spot100(address(a)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setTokenV4Pool(address(a), 500, 10, hook);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(Factory.UnknownToken.selector, makeAddr("stranger")));
        factory.setTokenV4Pool(makeAddr("stranger"), 100, 1, address(0));
        vm.expectRevert(abi.encodeWithSelector(Factory.BadV4Pool.selector, address(a), uint24(100), int24(1), address(0)));
        factory.setTokenV4Pool(address(a), 100, 1, address(0)); // not initialised
        vm.expectRevert(abi.encodeWithSelector(Factory.BadV4Pool.selector, address(a), uint24(500), int24(10), address(0)));
        factory.setTokenV4Pool(address(a), 500, 10, address(0)); // the hookless key of a hooked pool
        vm.expectRevert(abi.encodeWithSelector(Factory.BadV4Pool.selector, address(a), uint24(500), int24(10), makeAddr("other hook")));
        factory.setTokenV4Pool(address(a), 500, 10, makeAddr("other hook"));
        vm.expectRevert(abi.encodeWithSelector(Factory.BadV4Pool.selector, address(a), uint24(0), int24(0), hook));
        factory.setTokenV4Pool(address(a), 0, 0, hook); // no clear with a hook
        vm.stopPrank();

        vm.expectEmit(true, false, false, true, address(factory));
        emit Factory.TokenV4PoolChanged(address(a), 500, 10, hook);
        vm.prank(owner);
        factory.setTokenV4Pool(address(a), 500, 10, hook);
        (address pool, uint24 fee, uint24 v4Fee, int24 v4Spacing, address v4Hooks) = factory.poolsOf(address(a));
        assertEq(pool, address(pa));
        assertEq(fee, 3000);
        assertEq(v4Fee, 500);
        assertEq(v4Spacing, 10);
        assertEq(v4Hooks, hook, "the hook registered as given");

        manager.initialize(_v4Key(address(a), 100, 1, address(0)), _spot100(address(a)));
        vm.expectEmit(true, false, false, true, address(factory));
        emit Factory.TokenV4PoolChanged(address(a), 100, 1, address(0));
        vm.prank(owner);
        factory.setTokenV4Pool(address(a), 100, 1, address(0));
        (pool, fee, v4Fee, v4Spacing, v4Hooks) = factory.poolsOf(address(a));
        assertEq(v4Fee, 100);
        assertEq(v4Spacing, 1);
        assertEq(v4Hooks, address(0));
        Factory.TokenInfo memory info = factory.tokenInfo(address(a));
        assertEq(info.pool, address(pa));
        assertEq(info.fee, 3000);
        assertEq(info.v4Fee, 100);
        assertEq(info.v4TickSpacing, 1);
        assertEq(info.v4Hooks, address(0));

        vm.prank(owner);
        factory.setTokenV4Pool(address(a), 500, 10, hook);
        vm.expectEmit(true, false, false, true, address(factory));
        emit Factory.TokenV4PoolChanged(address(a), 0, 0, address(0));
        vm.prank(owner);
        factory.setTokenV4Pool(address(a), 0, 0, address(0));
        (,, v4Fee, v4Spacing, v4Hooks) = factory.poolsOf(address(a));
        assertEq(v4Fee, 0);
        assertEq(v4Spacing, 0, "cleared: no V4 route on a");
        assertEq(v4Hooks, address(0), "cleared with its hook");

        Etf etf = _create("E", _two(address(a), address(b)), _bps2(5000, 5000));
        _mint(etf, alice, 1000e6);
        _listEtf(etf, TICK_100_USD);
        manager.initialize(_v4Key(address(etf), 3000, 60, hook), _spot100(address(etf)));
        vm.prank(owner);
        factory.setTokenV4Pool(address(etf), 3000, 60, hook);
        (,, v4Fee, v4Spacing, v4Hooks) = factory.poolsOf(address(etf));
        assertEq(v4Fee, 3000);
        assertEq(v4Spacing, 60);
        assertEq(v4Hooks, hook);
    }

    /// `addToken`'s refusals: no pool (a pool is required, no feed exists), a pool the Uniswap V3
    /// factory does not name or of another pair, a pool with neither TWAP nor spot, USDG, a token
    /// already listed; and for a factory ETF, no pool.
    function test_AddTokenRefusesWhatCannotPriceIt() public {
        TokenMock t = new TokenMock("T", "T", 18);
        bool tokenFirst = address(t) < address(usdg);
        PoolMock stray = tokenFirst ? new PoolMock(address(t), address(usdg)) : new PoolMock(address(usdg), address(t));
        stray.setAverageTick(0);
        PoolMock wrongPair = new PoolMock(address(a), address(usdg));
        wrongPair.setAverageTick(0);
        v3.setPool(wrongPair);
        Etf etf = _create("E", _two(address(a), address(b)), _bps2(5000, 5000));
        PoolMock etfPool = _pool(address(etf), TICK_100_USD);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(Factory.NoSource.selector, address(t)));
        factory.addToken(address(t), address(0));
        vm.expectRevert(abi.encodeWithSelector(Factory.BadPool.selector, address(stray)));
        factory.addToken(address(t), address(stray)); // not registered in the V3 factory
        vm.expectRevert(abi.encodeWithSelector(Factory.BadPool.selector, address(wrongPair)));
        factory.addToken(address(t), address(wrongPair));
        vm.expectRevert(abi.encodeWithSelector(Factory.BadToken.selector, address(usdg)));
        factory.addToken(address(usdg), address(pa));
        vm.expectRevert(abi.encodeWithSelector(Factory.AlreadyEligible.selector, address(a)));
        factory.addToken(address(a), address(pa));
        vm.expectRevert(abi.encodeWithSelector(Factory.NoSource.selector, address(etf)));
        factory.addToken(address(etf), address(0));
        etfPool.setNoHistory(true);
        vm.expectRevert(abi.encodeWithSelector(Factory.BadPool.selector, address(etfPool)));
        factory.addToken(address(etf), address(etfPool)); // no TWAP, spot 0: no price
        vm.stopPrank();
    }

    /// A pool whose oracle is set to keep fewer than 1 801 observations is refused, by `addToken`
    /// and by `setTokenSources` (`ThinOracle`): with fewer, N swaps in N distinct seconds overwrite
    /// the observation 30 minutes back and the price falls to the spot (`MIN_OBSERVATION_CARDINALITY`'s
    /// note). `observationCardinalityNext` is what counts: a pool raised to 1 801 just before its
    /// listing passes while it still keeps one, as its swaps fill the rest.
    function test_APoolWhoseOracleKeepsFewerThan1801ObservationsIsRefused() public {
        assertEq(factory.MIN_OBSERVATION_CARDINALITY(), 1801);
        TokenMock t = new TokenMock("T", "T", 18);
        PoolMock p = _pool(address(t), TICK_100_USD);
        p.setCardinality(1800, 1800);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Factory.ThinOracle.selector, address(p), uint16(1800), uint16(1801)));
        factory.addToken(address(t), address(p));
        p.setCardinality(1, 1801); // `increaseObservationCardinalityNext(1801)` called, no swap since
        vm.prank(owner);
        factory.addToken(address(t), address(p));
        assertTrue(factory.isEligible(address(t)));

        PoolMock thin = _poolAt(address(t), TICK_100_USD, 500);
        thin.setCardinality(1, 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Factory.ThinOracle.selector, address(thin), uint16(1), uint16(1801)));
        factory.setTokenSources(address(t), address(thin));
        assertEq(factory.tokenInfo(address(t)).pool, address(p), "the listed pool unchanged");
    }

    /// A pool younger than the TWAP's 30 minutes - a new ETF's own market - is accepted on its spot,
    /// the source `getPriceUsdg` falls to for it.
    function test_APoolWithoutTwapHistoryIsListedOnItsSpot() public {
        TokenMock t = new TokenMock("T", "T", 18);
        PoolMock p = _pool(address(t), TICK_100_USD);
        p.setNoHistory(true);
        p.setSpotSqrtPrice(_spot100(address(t)));
        vm.prank(owner);
        factory.addToken(address(t), address(p));
        (uint256 price, uint8 source) = factory.getPriceUsdg(address(t));
        assertEq(source, SOURCE_SPOT);
        assertApproxEqRel(price, 100e18, 1e9, "the spot, to 1e-9");
    }

    /// Removing a token stops new ETFs from choosing it; the ETF that holds it keeps it, still
    /// priced, and it can be listed again.
    function test_ARemovedTokenStaysInTheEtfsThatHoldItAndStillPrices() public {
        Etf etf = _create("E", _two(address(a), address(b)), _bps2(5000, 5000));
        _mint(etf, alice, 1000e6);
        vm.prank(owner);
        factory.removeToken(address(a));
        assertFalse(factory.isEligible(address(a)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Factory.NotEligible.selector, address(a)));
        factory.createEtf{ value: FEE }("n", "N", "", _spec(_two(address(a), address(b)), _bps2(5000, 5000)), _params(), _noProfile());
        (uint256 price, uint8 source) = factory.getPriceUsdg(address(a));
        assertApproxEqRel(price, 250e18, ONE_BP);
        assertEq(source, SOURCE_POOL);
        assertGt(etf.legs()[0].value, 0, "still valued in the ETF");
        vm.prank(owner);
        factory.addToken(address(a), address(pa));
        assertTrue(factory.isEligible(address(a)));
        assertEq(factory.tokenCount(), 2, "listed once in the list");
    }

    // -------------------------------------------------------------- price ---

    /// `getPriceUsdg`'s one order, in USDG and with no feed anywhere: the pool's 30-minute TWAP while its oracle answers; then the pool's spot; then
    /// `(0, NONE)`, never a revert. The order is the factory's, the same for every token;
    /// `setTokenSources` replaces the pool at once, with `TokenSourcesChanged`.
    function test_GetPriceUsdgTakesTheTwapThenTheSpotThenNothing() public {
        (TokenMock t, PoolMock p) = _token("P", 100);
        (uint256 price, uint8 source) = factory.getPriceUsdg(address(t));
        assertEq(source, SOURCE_POOL, "the TWAP first");
        assertApproxEqRel(price, 100e18, ONE_BP, "the tick at 100 USDG, to one tick");

        PoolMock q = _poolAt(address(t), _tickAt(200e18), 10_000);
        vm.expectEmit(true, false, false, true, address(factory));
        emit Factory.TokenSourcesChanged(address(t), address(p), address(q));
        vm.prank(owner);
        factory.setTokenSources(address(t), address(q));
        (price, source) = factory.getPriceUsdg(address(t));
        assertEq(source, SOURCE_POOL);
        assertApproxEqRel(price, 200e18, ONE_BP, "the new pool, at once");
        vm.prank(owner);
        factory.setTokenSources(address(t), address(p));

        p.setNoHistory(true);
        p.setSpotSqrtPrice(_spot100(address(t)));
        (price, source) = factory.getPriceUsdg(address(t));
        assertEq(source, SOURCE_SPOT, "no TWAP: the spot");
        assertApproxEqRel(price, 100e18, 1e9);
        p.setSpotSqrtPrice(0);
        (price, source) = factory.getPriceUsdg(address(t));
        assertEq(price, 0, "nothing answers: NONE, never a revert");
        assertEq(source, SOURCE_NONE, "nothing answers: NONE, never a revert");
        (price, source) = factory.getPriceUsdg(address(0xdead));
        assertEq(price, 0, "an unknown token");
        assertEq(source, SOURCE_NONE, "an unknown token");
    }

    /// An ETF's price is its NAV per whole share, `(legs at their price + USDG) x 1e18 / supply`,
    /// whatever its pool says once listed; no share or one unpriced leg: no NAV, and then its own
    /// pool's TWAP if it is listed, else nothing.
    function test_AnEtfIsPricedAtItsNavFirstWhateverItsPoolSays() public {
        Etf etf = _create("E", _two(address(a), address(b)), _bps2(6000, 4000));
        (, uint8 source) = factory.getPriceUsdg(address(etf));
        assertEq(source, SOURCE_NONE, "no share yet, not listed");
        _mint(etf, alice, 1000e6);
        (uint256 price, uint8 s) = factory.getPriceUsdg(address(etf));
        assertEq(s, SOURCE_NAV);
        (uint256 priceA,) = factory.getPriceUsdg(address(a));
        (uint256 priceB,) = factory.getPriceUsdg(address(b));
        uint256 value = usdg.balanceOf(address(etf)) * 1e12 + Math.mulDiv(a.balanceOf(address(etf)), priceA, 1e18) + Math.mulDiv(b.balanceOf(address(etf)), priceB, 1e18);
        assertEq(price, Math.mulDiv(value, 1e18, etf.totalSupply()));
        assertApproxEqRel(price, 1e18, ONE_BP, "the legs bought at their pools' price: one USDG a share");

        _listEtf(etf, TICK_100_USD); // a pool that says about 100 USDG a share
        uint256 nav = price;
        (price, s) = factory.getPriceUsdg(address(etf));
        assertEq(price, nav, "the NAV, not the pool");
        assertEq(s, SOURCE_NAV);
        pb.setNoHistory(true); // b's pool answers nothing: no TWAP, spot 0
        (price, s) = factory.getPriceUsdg(address(etf));
        assertEq(s, SOURCE_POOL, "one leg without a price: no NAV, the listed pool's TWAP");
        assertApproxEqRel(price, 100e18, 0.005e18);
    }

    /// The factory answers the bounds and the fixed rules before any ETF exists, and they are the ones its ETFs check and say: one source, `etfV3ParamBounds()` and the
    /// file-level constants of `MaidMarianEtfV3.sol`.
    function test_TheFactoryAnswersTheSameBoundsAndFixedRulesAsItsEtfs() public {
        assertEq(factory.etfCount(), 0, "no ETF yet");
        (Etf.Params memory flo, Etf.Params memory fhi) = factory.paramBounds();
        assertEq(fhi.earlyPenaltyBps, 5000);
        assertEq(factory.CREATOR_MANAGEMENT_FEE_BPS(), 30);
        assertEq(factory.PROTOCOL_MANAGEMENT_FEE_BPS(), 20);
        assertEq(factory.TOLERANCE_BPS(), 50);
        assertEq(factory.PROTOCOL_CUT_BPS(), 3000);
        assertEq(factory.PROTOCOL_MIN_ENTRY_BPS(), 10);

        Etf etf = _create("B", _two(address(a), address(b)), _bps2(5000, 5000));
        (Etf.Params memory lo, Etf.Params memory hi) = etf.paramBounds();
        assertEq(abi.encode(flo), abi.encode(lo), "the same least values");
        assertEq(abi.encode(fhi), abi.encode(hi), "the same most values");
        assertEq(factory.CREATOR_MANAGEMENT_FEE_BPS(), etf.CREATOR_MANAGEMENT_FEE_BPS());
        assertEq(factory.PROTOCOL_MANAGEMENT_FEE_BPS(), etf.PROTOCOL_MANAGEMENT_FEE_BPS());
        assertEq(factory.TOLERANCE_BPS(), etf.TOLERANCE_BPS());
        assertEq(factory.PROTOCOL_CUT_BPS(), etf.PROTOCOL_CUT_BPS());
        assertEq(factory.PROTOCOL_MIN_ENTRY_BPS(), etf.PROTOCOL_MIN_ENTRY_BPS());
    }

    /// `oracleOf` gives a page what a token's price rests on: its pool, the pool oracle's current
    /// and next cardinality as `slot0` reports them, and whether a 30-minute `observe` answers now
    /// - false once it fails, when `getPriceUsdg` falls to the spot. Zeros for a token never added.
    function test_OracleOfShowsThePoolsCardinalityAndWhetherItsTwapAnswersNow() public {
        (address pool, uint16 cardinality, uint16 next, bool twapNow) = factory.oracleOf(address(a));
        assertEq(pool, address(pa));
        assertEq(cardinality, 1801);
        assertEq(next, 1801);
        assertTrue(twapNow);
        pa.setCardinality(1801, 7200);
        (, cardinality, next,) = factory.oracleOf(address(a));
        assertEq(cardinality, 1801, "kept now");
        assertEq(next, 7200, "what it grows to");
        pa.setNoHistory(true);
        (,,, twapNow) = factory.oracleOf(address(a));
        assertFalse(twapNow, "the TWAP fails: the price is the spot's, or none");
        (pool, cardinality, next, twapNow) = factory.oracleOf(address(0xdead));
        assertEq(pool, address(0));
        assertEq(uint256(cardinality) + next, 0);
        assertFalse(twapNow);
    }
}

contract MaidMarianEtfV4Test is MaidMarianEtfV4Base {
    using stdStorage for StdStorage;

    TokenMock internal a;
    TokenMock internal b;
    TokenMock internal c;
    PoolMock internal pa;
    PoolMock internal pb;
    PoolMock internal pc;
    Etf internal etf;

    function setUp() public override {
        super.setUp();
        (a, pa) = _token("AAA", 250);
        (b, pb) = _token("BBB", 500);
        (c, pc) = _token("CCC", 125);
        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (address(a), address(b), address(c));
        uint16[] memory w = new uint16[](3);
        (w[0], w[1], w[2]) = (5000, 3000, 2000);
        etf = _create("M3", t, w);
        _v4Pool(address(c), 100, 1);
    }

    // ------------------------------------------------------- params, rules ---

    /// `paramBounds()` is what the constructor checks: every field at its bounds passes, one past
    /// either refuses by name; the entry and exit fees stop at 500 bps (501 refused);
    /// `nonMinterPenaltyBps` is bounded by 10 000 less `exitFeeBps`, `earlyPenaltyBps` by
    /// `nonMinterPenaltyBps` (a transfer to a fresh address never pays less); the band runs 10 - 5 000
    /// points of the NAV, the min interval 0 - 86 400 seconds.
    function test_TheParamBoundsViewIsWhatTheConstructorChecks() public {
        (Etf.Params memory lo, Etf.Params memory hi) = etf.paramBounds();
        assertEq(hi.entryFeeBps, 500);
        assertEq(hi.exitFeeBps, 500);
        assertEq(hi.holdPeriod, 30 days);
        assertEq(hi.earlyPenaltyBps, 5000);
        assertEq(hi.nonMinterPenaltyBps, 10_000);
        assertEq(lo.rebalanceBandBps, 10);
        assertEq(hi.rebalanceBandBps, 5000);
        assertEq(lo.rebalanceMinInterval, 0);
        assertEq(hi.rebalanceMinInterval, 86_400);
        _createWith("LO", _two(address(a), address(b)), _bps2(5000, 5000), lo);
        Etf.Params memory top = hi;
        top.nonMinterPenaltyBps = 10_000 - top.exitFeeBps;
        Etf topped = _createWith("HI", _two(address(a), address(b)), _bps2(5000, 5000), top);
        assertEq(topped.ENTRY_FEE_BPS(), 500, "500 bps passes");
        assertEq(topped.EXIT_FEE_BPS(), 500, "500 bps passes");

        string[9] memory names =
            ["entryFeeBps", "exitFeeBps", "holdPeriod", "earlyPenaltyBps", "nonMinterPenaltyBps", "rebalanceBandBps", "rebalanceBandBps", "rebalanceMinInterval", "earlyPenaltyBps"];
        for (uint256 i = 0; i < names.length; i++) {
            Etf.Params memory over = _params();
            if (i == 0) over.entryFeeBps = 501;
            if (i == 1) over.exitFeeBps = 501;
            if (i == 2) over.holdPeriod = hi.holdPeriod + 1;
            if (i == 3) over.earlyPenaltyBps = hi.earlyPenaltyBps + 1;
            if (i == 4) (over.exitFeeBps, over.nonMinterPenaltyBps) = (100, 9901);
            if (i == 5) over.rebalanceBandBps = lo.rebalanceBandBps - 1;
            if (i == 6) over.rebalanceBandBps = hi.rebalanceBandBps + 1;
            if (i == 7) over.rebalanceMinInterval = hi.rebalanceMinInterval + 1;
            if (i == 8) over.earlyPenaltyBps = over.nonMinterPenaltyBps + 1; // early above non-minter
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(Etf.ParamOutOfBounds.selector, names[i]));
            factory.createEtf{ value: FEE }("p", string.concat("P", vm.toString(i)), "", _spec(_two(address(a), address(b)), _bps2(5000, 5000)), over, _noProfile());
        }
        Etf.Params memory back = etf.params();
        assertEq(abi.encode(back), abi.encode(_params()), "params() reads back what was given");
    }

    /// The rules fixed for every ETF of the factory are constants:
    /// management 0.50 % a year, 0.30 % to the creator and 0.20 % to the
    /// protocol; tolerance 0.5 %; the protocol's cut 30 % of the creator's entry and exit fees, at
    /// least 0.10 % at entry.
    function test_TheFixedRulesAreConstants() public view {
        assertEq(etf.MANAGEMENT_FEE_BPS(), 50);
        assertEq(etf.CREATOR_MANAGEMENT_FEE_BPS(), 30);
        assertEq(etf.PROTOCOL_MANAGEMENT_FEE_BPS(), 20);
        assertEq(etf.CREATOR_MANAGEMENT_FEE_BPS() + etf.PROTOCOL_MANAGEMENT_FEE_BPS(), etf.MANAGEMENT_FEE_BPS());
        assertEq(etf.TOLERANCE_BPS(), 50);
        assertEq(etf.PROTOCOL_CUT_BPS(), 3000);
        assertEq(etf.PROTOCOL_MIN_ENTRY_BPS(), 10);
    }

    // ------------------------------------------------------------- mints ---

    /// The first mint takes the entry fee in USDG first (20 bps: 2 USDG of 1 000, 1 to the
    /// protocol's least and 1 to the creator), splits the 998 left by the bps exactly
    /// (`FirstMintSplit` otherwise; `firstMintSplit(1 000)` gives it), keeps all that arrives, and
    /// gives one share per USDG that reached the fund, all to the minter but the 0.001 locked at `DEAD`.
    function test_TheFirstMintSplitsByTheBpsAndGivesOneSharePerUsdg() public {
        Etf.Route[] memory r = _buyRoutes(etf, 1000e6, true);
        assertEq(r[1].amountIn, 299.4e6, "30 % of the 998 left after the fee");
        r[1].amountIn += 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Etf.FirstMintSplit.selector, uint8(1), uint256(299.4e6 + 1), uint256(299.4e6)));
        etf.mint(1000e6, r, 1);

        uint256 makerUsdg = usdg.balanceOf(maker);
        uint256 shares = _mint(etf, alice, 1000e6);
        assertEq(shares, 998e18 - 1e15, "one share per USDG in the fund: 1 000 less the 20 bps fee, less the dead shares");
        assertEq(etf.balanceOf(etf.DEAD()), etf.DEAD_SHARES(), "0.001 share locked");
        assertEq(etf.totalSupply(), 998e18, "no fee in shares on a USDG mint");
        assertEq(usdg.balanceOf(owner), 1e6, "the protocol: max(10 bps, 30 % of 20 bps) = 10 bps, in USDG");
        assertEq(usdg.balanceOf(maker) - makerUsdg, 1e6, "the creator: the other 10 bps, in USDG");
        assertEq(etf.mintOf(alice), shares, "her mint: counted");
        assertEq(etf.lastMintAt(alice), block.timestamp);
        assertEq(a.balanceOf(address(etf)), 1.996e18, "499 USDG of a at 250");
        assertEq(b.balanceOf(address(etf)), 0.5988e18);
        assertEq(c.balanceOf(address(etf)), 1.5968e18);
        assertEq(usdg.balanceOf(address(etf)), 0, "every unit of the 998 bought a leg");
        (uint256 value, bool complete) = etf.nav();
        assertApproxEqRel(value, 998e6, ONE_BP, "the legs at their pools' TWAP, a tick under the router's price");
        assertTrue(complete);
    }

    /// A first mint whose route delivers nothing of a leg is refused: no share over a missing leg.
    function test_AFirstMintThatDeliversNothingOfALegIsRefused() public {
        router.setPairRate(address(usdg), address(c), 1); // 1e-18 of a token per USDG unit: rounds to 0
        Etf.Route[] memory r = _buyRoutes(etf, 1000e6, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Etf.NothingDelivered.selector, address(c)));
        etf.mint(1000e6, r, 1);
    }

    /// A later mint gets `supply x min(received / held)`: at fair routes, 1 000 USDG brought to a
    /// fund of 998 USDG of legs - 2 to the fee, 990 routed, 8 left - buys 990 shares, and the 8
    /// unused come back to the minter - there is no `refundTo`. Routes
    /// spending more than the 998 left after the fee are refused (`RoutesOverspend`).
    function test_ALaterMintGetsSharesByTheScarcestLegAndTheExcessComesBack() public {
        _mint(etf, alice, 1000e6);
        uint256 supply = etf.totalSupply();
        uint256 before = usdg.balanceOf(bob);
        Etf.Route[] memory over = _buyRoutes(etf, 1000e6, false);
        over[0].amountIn += 8e6 + 1;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Etf.RoutesOverspend.selector, uint256(998e6 + 1), uint256(998e6)));
        etf.mint(1000e6, over, 1);

        Etf.Route[] memory r = _buyRoutes(etf, 1000e6, false);
        vm.prank(bob);
        uint256 shares = etf.mint(1000e6, r, 1);
        assertEq(shares, supply * 990 / 998, "990 USDG of legs for a 998 USDG fund");
        assertEq(before - usdg.balanceOf(bob), 992e6, "1 000 pulled, the 8 the routes left back to the minter (the fund held none)");
        assertEq(etf.balanceOf(bob), shares);
    }

    /// The claim of the brief: existing holders can never lose to a minter's price. A route through
    /// a pool pushed 50 % against the minter on leg b delivers half; the minter gets shares by b,
    /// the excess of a and c comes back to him, and every leg per share is the same or more.
    function test_AManipulatedPoolCostsOnlyItsMinterAndNoHolderLoses() public {
        _mint(etf, alice, 1000e6);
        uint256[] memory perShare = _perShare(etf);
        router.setPairRate(address(usdg), address(b), 1e48 / 500e18 / 2);
        Etf.Route[] memory r = _buyRoutes(etf, 1000e6, false);
        vm.prank(bob);
        uint256 shares = etf.mint(1000e6, r, 1);
        assertApproxEqRel(shares, 495e18, 0.001e18, "half the shares: b's half delivery binds");
        assertGt(a.balanceOf(bob), 0, "a's excess back to the minter");
        assertGt(c.balanceOf(bob), 0, "c's excess back to the minter");
        uint256[] memory after_ = _perShare(etf);
        for (uint256 i = 0; i < after_.length; i++) {
            assertGe(after_[i], perShare[i], "no leg per share went down");
        }
    }

    /// The same claim, fuzzed: any rates on the three routes, any amount, a fund holding USDG -
    /// every leg and the USDG per share are the same or more after the mint.
    function testFuzz_NoMintLowersAnyHoldingPerShare(uint256 amount, uint16 ra, uint16 rb, uint16 rc) public {
        _mint(etf, alice, 1000e6);
        _credit(etf, address(usdg), 3e6); // the fund holds USDG, as after a rebalance
        amount = bound(amount, 1e6, 1e12);
        router.setPairRate(address(usdg), address(a), 1e48 / 250e18 * bound(ra, 1, 20_000) / 10_000);
        router.setPairRate(address(usdg), address(b), 1e48 / 500e18 * bound(rb, 1, 20_000) / 10_000);
        router.setPairRate(address(usdg), address(c), 1e48 / 125e18 * bound(rc, 1, 20_000) / 10_000);
        uint256[] memory perShare = _perShare(etf);
        Etf.Route[] memory r = _buyRoutes(etf, amount, false);
        vm.prank(bob);
        (bool ok,) = address(etf).call(abi.encodeCall(Etf.mint, (amount, r, 0)));
        vm.assume(ok); // a mint of 0 shares is refused, and proves nothing
        uint256[] memory after_ = _perShare(etf);
        for (uint256 i = 0; i < after_.length; i++) {
            assertGe(after_[i], perShare[i]);
        }
    }

    /// Mint and redeem read no price: with every pool answering nothing (no TWAP, no spot) and the
    /// factory answering NONE, a mint, a redeem to USDG and an in-kind redeem all run.
    function test_MintAndRedeemReadNoPrice() public {
        _mint(etf, alice, 1000e6);
        pa.setNoHistory(true);
        pb.setNoHistory(true);
        pc.setNoHistory(true);
        (, uint8 source) = factory.getPriceUsdg(address(a));
        assertEq(source, SOURCE_NONE);
        assertGt(_mint(etf, bob, 500e6), 0, "minted with no price anywhere");
        vm.warp(block.timestamp + 2 hours);
        uint256 half = etf.balanceOf(bob) / 2;
        (,,, uint256[] memory due,) = etf.previewRedeem(bob, half);
        Etf.Route[] memory r = _sellRoutes(etf, due);
        vm.prank(bob);
        assertGt(etf.redeem(half, r, 1, bob), 0, "redeemed to USDG with no price");
        uint256 rest = etf.balanceOf(bob);
        vm.prank(bob);
        etf.redeemInKind(rest, bob, 0);
        assertEq(etf.balanceOf(bob), 0);
    }

    /// `mintInKind` takes the legs and the USDG part, mints by the scarcest, and returns the rest;
    /// it is never the first mint; `previewMintInKind` and `quoteMint` say the same thing.
    function test_AMintInKindReturnsTheExcessAndMatchesItsPreview() public {
        uint256[] memory three = new uint256[](3);
        vm.prank(bob);
        vm.expectRevert(Etf.FirstMintIsUsdg.selector);
        etf.mintInKind(three, 0, 1);
        _mint(etf, alice, 1000e6);

        (uint256[] memory need,) = etf.quoteMint(100e18);
        uint256[] memory bring = new uint256[](3);
        (bring[0], bring[1], bring[2]) = (need[0] * 2, need[1], need[2] * 3);
        a.mint(bob, bring[0]);
        b.mint(bob, bring[1]);
        c.mint(bob, bring[2]);
        vm.startPrank(bob);
        a.approve(address(etf), type(uint256).max);
        b.approve(address(etf), type(uint256).max);
        c.approve(address(etf), type(uint256).max);
        (uint256 preview, uint256 protocolFee, uint256 creatorFee) = etf.previewMintInKind(bring, 0);
        uint256 shares = etf.mintInKind(bring, 0, 1);
        vm.stopPrank();
        assertEq(shares, preview);
        assertEq(shares + protocolFee + creatorFee, 100e18, "b binds: exactly the 100 shares quoted");
        assertEq(protocolFee, 0.1e18, "the protocol's least, 10 bps, in shares");
        assertEq(creatorFee, 0.1e18, "the creator's 20 bps less the protocol's 10, in shares");
        assertEq(etf.balanceOf(bob), shares, "the shares to the caller");
        assertEq(etf.mintOf(bob), shares, "an in-kind mint counts as a mint");
        assertEq(a.balanceOf(bob), need[0], "a's excess back");
        assertEq(c.balanceOf(bob), need[2] * 2, "c's excess back");
        assertEq(b.balanceOf(bob), 0);
    }

    // ----------------------------------------------------------- redeems ---

    /// The in-kind redeem always works: a leg whose token stops transferring is waived by its bit,
    /// stays in the fund, and the others are paid.
    function test_TheInKindRedeemWorksWhenALegTokenStopsTransferring() public {
        BrickableTokenMock brick = new BrickableTokenMock();
        brick.mint(address(router), 1e30);
        PoolMock pk = _pool(address(brick), _tickAt(100e18));
        vm.prank(owner);
        factory.addToken(address(brick), address(pk));
        _routerAt(address(brick), 100e18);
        Etf withBrick = _create("BR", _two(address(a), address(brick)), _bps2(5000, 5000));
        _mint(withBrick, alice, 1000e6);
        brick.brick(false, true, false);
        uint256 shares = withBrick.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        withBrick.redeemInKind(shares, alice, 0);
        vm.prank(alice);
        withBrick.redeemInKind(shares, alice, 1 << 1);
        assertGt(a.balanceOf(alice), 0, "the working leg paid");
        assertGt(brick.balanceOf(address(withBrick)), 0, "the frozen leg stays for those who stay");
    }

    /// `redeem` refuses a route above a leg's due and pays the rest in kind; `minUsdgOut` floors it.
    function test_RedeemToUsdgSellsAtMostTheDueAndFloorsTheOutput() public {
        _mint(etf, alice, 1000e6);
        vm.warp(block.timestamp + 2 hours);
        uint256 shares = etf.balanceOf(alice) / 2;
        (,,, uint256[] memory due,) = etf.previewRedeem(alice, shares);
        uint256[] memory over = new uint256[](3);
        (over[0], over[1], over[2]) = (due[0] + 1, due[1], due[2]);
        Etf.Route[] memory bad = _sellRoutes(etf, over);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Etf.OverRedeem.selector, address(a), due[0] + 1, due[0]));
        etf.redeem(shares, bad, 0, alice);

        uint256[] memory part = new uint256[](3);
        (part[0], part[1]) = (due[0], due[1]);
        Etf.Route[] memory r = _sellRoutes(etf, part);
        vm.prank(alice);
        vm.expectRevert();
        etf.redeem(shares, r, 1000e6, alice);
        vm.prank(alice);
        uint256 out = etf.redeem(shares, r, 1, carol);
        assertEq(usdg.balanceOf(carol), out);
        assertEq(c.balanceOf(carol), due[2], "the leg not sold, in kind");
    }

    /// The worked example (exit 0.10 %, early 1 %, non-minter 2 %), within the hold period: alice
    /// minted 10 and received 5 (minted by bob); redeeming all 15 pays 10 x 1.10 % + 5 x 2.10 % =
    /// 0.215 shares - minted shares first, rates added on their own parts - and is paid 14.785
    /// shares' worth. The 0.015 exit fee and the 0.2 of penalties are moved in shares, 0.0645 (30 %)
    /// to the factory's owner and 0.1505 to the creator's recipient; only the 14.785 are burned.
    function test_WithinTheHoldPeriodMintedSharesPayTheEarlyPenaltyAndTheRestTheNonMinterOne() public {
        Etf one = _worked();
        uint256 supply = one.totalSupply();
        uint256 held = a.balanceOf(address(one));
        (uint256 paid, uint256 fee, uint256 burned,,) = one.previewRedeem(alice, 15e18);
        assertEq(paid, 14.785e18);
        assertEq(fee, 0.015e18);
        assertEq(burned, 0.2e18, "0.1 early + 0.1 non-minter");
        (uint256 coveredBps, uint256 otherBps, uint256 covered,) = one.exitRates(alice);
        assertEq(coveredBps, 110);
        assertEq(otherBps, 210);
        assertEq(covered, 10e18);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = held * 14.785e18 / supply;
        vm.expectEmit(true, true, false, true, address(one));
        emit Etf.RedeemedInKind(alice, alice, 15e18, 0.0645e18, 0.1505e18, 10e18, 0.1e18, 0.1e18, amounts, 0, 0);
        vm.prank(alice);
        one.redeemInKind(15e18, alice, 0);
        assertEq(a.balanceOf(alice), amounts[0]);
        assertEq(one.mintOf(alice), 0);
        assertEq(one.balanceOf(maker), 0.1505e18, "70 % of the exit fee and the penalties to the creator");
        assertEq(one.balanceOf(owner), 0.0645e18, "30 % to the factory's owner");
        assertEq(one.mintOf(maker), 0.1505e18, "a fee counts as minted");
        assertEq(one.mintOf(owner), 0.0645e18, "a fee counts as minted");
        assertEq(one.totalSupply(), 0.215e18 + 1e15, "the fee and penalty shares, and the dead shares");
        assertEq(a.balanceOf(address(one)), held - amounts[0]);
        assertGe(a.balanceOf(address(one)) * 1e18 / one.totalSupply(), held * 1e18 / supply, "no holder loses: the penalties are shares, not a gift to the fund");
    }

    /// The same, after the hold period: 15 cost 10 x 0.10 % + 5 x 2.10 % = 0.115 shares; a redeem
    /// of 5 of the 15 is all covered (no non-minter penalty) and leaves `mintOf` at 5; the next 10
    /// are then 5 covered and 5 beyond.
    function test_AfterTheHoldPeriodOnlyTheExitFeeAndTheNonMinterPenaltyRemain() public {
        Etf one = _worked();
        vm.warp(block.timestamp + 1 hours); // the hold ends at lastMintAt + 1 hour, exclusive
        (uint256 paid,, uint256 burned,,) = one.previewRedeem(alice, 15e18);
        assertEq(paid, 14.885e18, "0.115 kept");
        assertEq(burned, 0.1e18);
        (uint256 mc, uint256 mp) = one.pendingManagementFee(); // an hour's management fee, accrued first
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = a.balanceOf(address(one)) * 4.995e18 / (one.totalSupply() + mc + mp);
        vm.expectEmit(true, true, false, true, address(one));
        emit Etf.RedeemedInKind(alice, alice, 5e18, 0.0015e18, 0.0035e18, 5e18, 0, 0, amounts, 0, 0);
        vm.prank(alice);
        one.redeemInKind(5e18, alice, 0);
        assertEq(one.mintOf(alice), 5e18, "minted shares go first: 10 - 5");
        (paid,, burned,,) = one.previewRedeem(alice, 10e18);
        assertEq(burned, 0.1e18, "5 covered, 5 beyond at 2 %");
        assertEq(paid, 10e18 - 0.01e18 - 0.1e18);
    }

    /// A transfer moves `balanceOf`, never `mintOf`: the sender keeps its counter, the receiver
    /// gets none, and the receiver's redeem pays the non-minter penalty on all of it.
    function test_ATransferLeavesMintOfAsItIs() public {
        _mint(etf, alice, 1000e6);
        uint256 minted = etf.mintOf(alice);
        vm.prank(alice);
        assertTrue(etf.transfer(bob, 100e18));
        assertEq(etf.mintOf(alice), minted, "the sender's counter unchanged");
        assertEq(etf.mintOf(bob), 0, "the receiver minted nothing");
        vm.warp(block.timestamp + 2 hours);
        (uint256 paid,, uint256 burned,,) = etf.previewRedeem(bob, 100e18);
        assertEq(burned, 2e18, "200 bps non-minter penalty on shares bob did not mint");
        assertEq(paid, 98e18);
        (,, uint256 aliceBurned,,) = etf.previewRedeem(alice, etf.balanceOf(alice));
        assertEq(aliceBurned, 0, "minted and past the hold period: nothing");
    }

    /// Every mint raises its caller's own `mintOf` and restarts its own clock - a dust mint
    /// included, through either door - and nobody else's: the shares go to the caller, there is no
    /// `to` (author, 2026-10-19: "oui on retire to du mint"). A gift is a mint then a transfer, and
    /// the receiver's shares are beyond its `mintOf`: they pay the non-minter penalty.
    function test_EveryMintRaisesTheCallersOwnMintOfAndRestartsItsClockADustMintIncluded() public {
        uint256 first = _mint(etf, alice, 1000e6);
        assertEq(etf.balanceOf(alice), first);
        assertEq(etf.mintOf(alice), first);
        uint256 since = etf.lastMintAt(alice);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        (,, uint256 burned,,) = etf.previewRedeem(alice, first);
        assertEq(burned, 0, "past her hold period: nothing");

        uint256 dust = _mint(etf, alice, 1e6);
        assertGt(dust, 0);
        assertEq(etf.balanceOf(alice), first + dust, "the shares to the caller");
        assertEq(etf.mintOf(alice), first + dust, "the dust mint counted");
        assertEq(etf.lastMintAt(alice), block.timestamp, "and restarted her clock");
        assertGt(etf.lastMintAt(alice), since);
        (,, burned,,) = etf.previewRedeem(alice, first);
        assertEq(burned, first * 100 / 10_000, "her own dust mint put her minted shares back under the early penalty");

        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256 aliceAt = etf.lastMintAt(alice);
        uint256 gift = _mint(etf, bob, 100e6);
        assertEq(etf.mintOf(bob), gift, "bob's mint is bob's");
        assertEq(etf.lastMintAt(bob), block.timestamp);
        assertEq(etf.mintOf(alice), first + dust, "alice's counter untouched");
        assertEq(etf.lastMintAt(alice), aliceAt, "alice's clock untouched");
        vm.prank(bob);
        assertTrue(etf.transfer(carol, gift));
        assertEq(etf.mintOf(carol), 0);
        assertEq(etf.lastMintAt(carol), 0);
        (,, uint256 carolBurned,,) = etf.previewRedeem(carol, gift);
        assertEq(carolBurned, gift * 200 / 10_000, "a gift pays the non-minter penalty, not a way around the early one");

        vm.warp(vm.getBlockTimestamp() + 2 hours);
        (uint256[] memory need, uint256 usdgNeed) = etf.quoteMint(1e15);
        a.mint(bob, need[0]);
        b.mint(bob, need[1]);
        c.mint(bob, need[2]);
        vm.startPrank(bob);
        a.approve(address(etf), type(uint256).max);
        b.approve(address(etf), type(uint256).max);
        c.approve(address(etf), type(uint256).max);
        uint256 inKind = etf.mintInKind(need, usdgNeed, 1);
        vm.stopPrank();
        assertGt(inKind, 0);
        assertEq(etf.mintOf(bob), gift + inKind, "a dust mint in kind counted");
        assertEq(etf.lastMintAt(bob), block.timestamp, "and restarted bob's clock");
    }

    // --------------------------------------------------------- rebalance ---

    /// Anyone rebalances - a stranger holding nothing - at most once per `minInterval`; the
    /// management fee is minted 0.30 % a year to the creator and 0.20 % to the factory's owner;
    /// an out-of-band leg is sold at its floor.
    function test_AnyoneRebalancesOncePerIntervalAndTheManagementFeeIsSplit() public {
        _mint(etf, alice, 1000e6);
        _credit(etf, address(a), 1e18); // a is 250 USDG over
        uint256 supply = etf.totalSupply();
        vm.warp(block.timestamp + 365 days);
        (uint256 creatorFee, uint256 protocolFee) = etf.pendingManagementFee();
        assertEq(creatorFee, supply * 30 / 10_000, "0.30 % of a year");
        assertEq(protocolFee, supply * 20 / 10_000, "0.20 % of a year");
        Etf.PlanLeg[] memory p = etf.plan();
        assertTrue(p.length > 0 && p[0].sell && p[0].leg == 0);
        Etf.Route[] memory r = _planRoutes(p);
        uint256 makerBefore = etf.balanceOf(maker);
        vm.prank(carol);
        etf.rebalance(r);
        assertEq(etf.balanceOf(maker) - makerBefore, creatorFee, "the creator's part, in shares");
        assertEq(etf.balanceOf(owner), protocolFee, "the protocol's part, to the factory's owner");
        assertEq(etf.mintOf(owner), protocolFee, "fee shares count as minted");
        assertEq(etf.lastRebalanceAt(), block.timestamp, "the window closed: no leg out of band");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Etf.TooSoon.selector, block.timestamp + 1 hours));
        etf.rebalance(r);
    }

    /// The rebalance's route rules, each by name: a leg in band, over the gap, a leg out of range,
    /// a leg twice, sells first, and a V4 route on a leg the factory gave no V4 pool (`NoV4Pool`).
    function test_TheRebalanceRefusesARouteOutsideItsRules() public {
        _mint(etf, alice, 1000e6);
        _credit(etf, address(a), 1e18);
        Etf.PlanLeg[] memory p = etf.plan();
        Etf.Route[] memory one = new Etf.Route[](1);

        one[0] = _swapRoute(0, false, 1e6);
        vm.expectRevert(abi.encodeWithSelector(Etf.LegNotDue.selector, address(a)));
        etf.rebalance(one);
        one[0] = _swapRoute(0, true, p[0].amountIn + 1);
        vm.expectRevert(abi.encodeWithSelector(Etf.OverTrade.selector, address(a), p[0].amountIn + 1, p[0].amountIn));
        etf.rebalance(one);
        one[0] = _swapRoute(9, true, 1);
        vm.expectRevert(abi.encodeWithSelector(Etf.UnknownLeg.selector, uint8(9)));
        etf.rebalance(one);

        one[0] = _v4Route(0, true, p[0].amountIn); // a has no V4 pool
        vm.expectRevert(abi.encodeWithSelector(Etf.NoV4Pool.selector, address(a)));
        etf.rebalance(one);

        Etf.Route[] memory twice = new Etf.Route[](2);
        twice[0] = _swapRoute(0, true, 1);
        twice[1] = _swapRoute(0, true, 1);
        vm.expectRevert(abi.encodeWithSelector(Etf.DuplicateLeg.selector, address(a)));
        etf.rebalance(twice);
        _credit(etf, address(usdg), 10e6); // so the first route, a buy, can run before the sale is refused
        Etf.Route[] memory order = new Etf.Route[](2);
        order[0] = _swapRoute(1, false, 1);
        order[1] = _swapRoute(0, true, 1);
        vm.expectRevert(Etf.SellsFirst.selector);
        etf.rebalance(order);
    }

    /// The brief's claim (author, 2026-10-18: "surtout un amountMin correct dans le swap"): a
    /// rebalance route's `amountOutMin` is ignored, not refused. The swap the router runs carries
    /// the contract's floor, the plan's `minOut` (the leg's one price less 0.5 %), and the USDG
    /// lands in the fund.
    function test_ACallersZeroMinimumIsOverwrittenWithTheContractsFloor() public {
        _mint(etf, alice, 1000e6);
        _credit(etf, address(a), 1e18);
        Etf.PlanLeg[] memory p = etf.plan();
        Etf.Route[] memory one = new Etf.Route[](1);
        one[0] = _swapRoute(0, true, p[0].amountIn); // minimum 0
        assertApproxEqRel(p[0].minOut, uint256(125e6) * 9950 / 10_000, 2 * ONE_BP, "a 125 USDG over its 625 target, less 50 bps");
        uint256 price = etf.legs()[0].price;
        uint256 out = _out(address(a), address(usdg), p[0].amountIn);
        uint256 before = usdg.balanceOf(address(etf));
        vm.expectEmit(true, false, false, true, address(etf));
        emit Etf.LegTraded(address(a), true, p[0].amountIn, out, p[0].minOut, price, SOURCE_POOL);
        vm.prank(bob);
        etf.rebalance(one);
        assertEq(router.lastAmountOutMin(), p[0].minOut, "the router ran the contract's floor, not the caller's 0");
        assertEq(usdg.balanceOf(address(etf)) - before, out, "the fund received");
    }

    /// A sandwich on a rebalance swap reverts: the pool pushed 1 % against the fund before its
    /// sale (here the router's rate), the router refuses to deliver under the floor written into
    /// the swap (`V3TooLittleReceived`) - nothing is traded; and a router that delivered less without
    /// checking is caught by the balance check after it (`InsufficientOutput`).
    function test_ASandwichOnARebalanceSwapReverts() public {
        _mint(etf, alice, 1000e6);
        _credit(etf, address(a), 1e18);
        Etf.PlanLeg[] memory p = etf.plan();
        Etf.Route[] memory one = _planRoutes(p);
        router.setPairRate(address(a), address(usdg), uint256(250e6) * 9900 / 10_000); // the front-run
        vm.expectRevert(UniversalRouterMock.V3TooLittleReceived.selector);
        etf.rebalance(one);

        router.setPairRate(address(a), address(usdg), 250e6);
        router.setPayNothing(true); // a router that keeps the tokens and checks nothing
        vm.expectRevert(abi.encodeWithSelector(Etf.InsufficientOutput.selector, 0, p[0].minOut));
        etf.rebalance(one);
    }

    /// A leg without a price is left as it is for the pass: out of nav and targets, a route on it
    /// refused, `LegUnpriced` said - and mint and redeem stay open.
    function test_AnUnpricedLegIsLeftAsItIsAndTheOthersBalanceAmongThemselves() public {
        _mint(etf, alice, 1000e6);
        pc.setNoHistory(true); // c's pool answers nothing: no TWAP, spot 0
        _credit(etf, address(a), 1e18);
        Etf.Leg[] memory l = etf.legs();
        assertEq(l[2].source, SOURCE_NONE);
        assertEq(l[2].target, 0);
        (uint256 value, bool complete) = etf.nav();
        assertFalse(complete);
        assertApproxEqRel(value, 1048.4e6, ONE_BP, "a 749 + b 299.4: c left out");
        Etf.Route[] memory one = new Etf.Route[](1);
        one[0] = _swapRoute(2, true, 1);
        vm.expectRevert(abi.encodeWithSelector(Etf.LegUnpricedNow.selector, uint8(2)));
        etf.rebalance(one);
        vm.expectEmit(true, true, false, false, address(etf));
        emit Etf.LegUnpriced(2, address(c));
        etf.rebalance(_planRoutes(etf.plan()));
        assertGt(_mint(etf, bob, 100e6), 0, "mint still open");
    }

    /// A leg priced by its pool's spot alone (no TWAP history) is shown at that spot by `legs()` and
    /// skipped by the rebalance like an unpriced leg (author, 2026-10-19): out of the plan, a route
    /// on it refused (`LegUnpricedNow`), `LegUnpriced` said. A spot pushed 20 % down in the same
    /// transaction then plans nothing.
    function test_ASpotPricedLegIsShownButSkippedByTheRebalance() public {
        TokenMock s = new TokenMock("SPT", "SPT", 18);
        s.mint(address(router), 1e30);
        PoolMock p = _pool(address(s), TICK_100_USD);
        p.setNoHistory(true);
        p.setSpotSqrtPrice(_spot100(address(s)));
        vm.prank(owner);
        factory.addToken(address(s), address(p));
        _routerAt(address(s), 100e18);
        Etf withSpot = _create("SPOT", _two(address(a), address(s)), _bps2(5000, 5000));
        _mint(withSpot, alice, 1000e6);
        Etf.Leg[] memory shown = withSpot.legs();
        assertEq(shown[1].source, SOURCE_SPOT, "legs() shows the spot");
        assertApproxEqRel(shown[1].value, 499e6, ONE_BP, "and the leg's value at it");
        (uint256 price, uint8 source) = factory.getTradablePriceUsdg(address(s));
        assertEq(price, 0, "no tradable price");
        assertEq(source, SOURCE_NONE, "no tradable price");

        // The push: sqrt(0.8) of the price's root, the spot 20 % under - one swap's work.
        uint256 root = _spot100(address(s));
        // forge-lint: disable-next-line(unsafe-typecast)
        p.setSpotSqrtPrice(address(s) < address(usdg) ? uint160(root * 894_427_191 / 1e9) : uint160(root * 1e9 / 894_427_191));
        assertEq(withSpot.legs()[1].source, SOURCE_SPOT);
        assertEq(withSpot.plan().length, 0, "the pushed spot plans nothing");
        Etf.Route[] memory one = new Etf.Route[](1);
        one[0] = _swapRoute(1, false, 1e6);
        vm.expectRevert(abi.encodeWithSelector(Etf.LegUnpricedNow.selector, uint8(1)));
        withSpot.rebalance(one);
        vm.expectEmit(true, true, false, false, address(withSpot));
        emit Etf.LegUnpriced(1, address(s));
        withSpot.rebalance(new Etf.Route[](0));
    }

    /// An ETF with a leg on spot is never traded at its NAV: `getPriceUsdg` shows the NAV (the spot
    /// inside it), `getTradablePriceUsdg` skips it to the ETF's own pool TWAP once listed, and gives
    /// nothing when that pool has no TWAP either.
    function test_AnEtfWithALegOnSpotIsNeverTradedAtItsNav() public {
        TokenMock s = new TokenMock("SPT", "SPT", 18);
        s.mint(address(router), 1e30);
        PoolMock p = _pool(address(s), TICK_100_USD);
        p.setNoHistory(true);
        p.setSpotSqrtPrice(_spot100(address(s)));
        vm.prank(owner);
        factory.addToken(address(s), address(p));
        _routerAt(address(s), 100e18);
        Etf child = _create("KID", _two(address(a), address(s)), _bps2(5000, 5000));
        _mint(child, alice, 1000e6);
        (uint256 shown, uint8 source) = factory.getPriceUsdg(address(child));
        assertEq(source, SOURCE_NAV, "shown at its NAV");
        assertApproxEqRel(shown, 1e18, 2 * ONE_BP);
        (, source) = factory.getTradablePriceUsdg(address(child));
        assertEq(source, SOURCE_NONE, "not listed: nothing to trade at");

        PoolMock cp = _listEtf(child, TICK_100_USD);
        (uint256 tradable, uint8 tsource) = factory.getTradablePriceUsdg(address(child));
        assertEq(tsource, SOURCE_POOL, "its own pool's TWAP, not the NAV");
        assertApproxEqRel(tradable, 100e18, 0.005e18);
        (, source) = factory.getPriceUsdg(address(child));
        assertEq(source, SOURCE_NAV, "the display keeps the NAV");
        cp.setNoHistory(true);
        (, tsource) = factory.getTradablePriceUsdg(address(child));
        assertEq(tsource, SOURCE_NONE, "no TWAP either: nothing");
    }

    // ----------------------------------------------------- an ETF as a leg ---

    /// An ETF inside an ETF is a token like the others (author, 2026-10-18): listed by the owner
    /// with a pool, bought by the parent's mint through that pool, priced at its NAV (whatever the
    /// pool's tick says, here about 100 USDG against a NAV of about 1), bought and sold by the
    /// rebalance through the pool with floors from that NAV. No nested mint or redeem: the parent
    /// never touches the child's doors.
    function test_AnEtfLegIsBoughtAndSoldThroughItsPoolAndPricedAtItsNav() public {
        Etf kid = _create("KID", _two(address(a), address(b)), _bps2(5000, 5000));
        _mint(kid, alice, 10_000e6);
        vm.prank(alice);
        assertTrue(kid.transfer(address(router), 5000e18)); // the pool's inventory of the child's shares
        _listEtf(kid, TICK_100_USD);
        (uint256 nav, uint8 source) = factory.getPriceUsdg(address(kid));
        assertEq(source, SOURCE_NAV);
        assertApproxEqRel(nav, 1e18, ONE_BP, "9 980 USDG of legs for 9 980 shares");
        _routerAt(address(kid), nav);

        Etf mom = _create("MOM", _two(address(kid), address(c)), _bps2(5000, 5000));
        assertEq(factory.etfInfo(address(mom)).depth, 2);
        assertEq(_mint(mom, bob, 1000e6), 998e18 - 1e15, "the first mint buys the child through its pool");
        assertEq(kid.balanceOf(address(mom)), _out(address(usdg), address(kid), 499e6), "half the 998 left after the fee");
        Etf.Leg memory leg = mom.legs()[0];
        assertEq(leg.source, SOURCE_NAV);
        assertEq(leg.price, nav);
        uint256 supplyBefore = kid.totalSupply();

        _credit(mom, address(c), 4e18); // c 500 USDG over: sell c, buy the child
        Etf.PlanLeg[] memory p = mom.plan();
        assertEq(p.length, 2);
        assertTrue(p[0].sell && p[0].leg == 1 && !p[1].sell && p[1].leg == 0);
        assertEq(p[1].minOut, Math.mulDiv(Math.mulDiv(p[1].amountIn, 1e30, nav), 9950, 10_000), "the child's floor from its NAV");
        uint256 kidBefore = kid.balanceOf(address(mom));
        mom.rebalance(_planRoutes(p));
        assertEq(router.lastAmountOutMin(), p[1].minOut);
        assertEq(kid.balanceOf(address(mom)), kidBefore + _out(address(usdg), address(kid), p[1].amountIn), "bought through the pool");

        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        assertTrue(kid.transfer(address(mom), 500e18)); // now the child is over
        _addCount(mom, address(kid), 500e18);
        p = mom.plan();
        assertTrue(p[0].sell && p[0].leg == 0, "sell the child");
        Etf.Route[] memory one = new Etf.Route[](1);
        one[0] = _swapRoute(0, true, p[0].amountIn);
        uint256 usdgBefore = usdg.balanceOf(address(mom));
        mom.rebalance(one);
        assertEq(usdg.balanceOf(address(mom)) - usdgBefore, _out(address(kid), address(usdg), p[0].amountIn), "sold through the pool at the NAV");
        assertEq(kid.totalSupply(), supplyBefore, "the child's doors were never called");
    }

    // -------------------------------------------------------------- band ---

    /// The band is in points of the NAV, the same for every leg:
    /// band 2 %, a 50 % leg is due only outside
    /// 48 - 52 % and a 10 % leg only outside 8 - 12 %. Each leg is pushed by a counted holding of itself
    /// to 51.9 % / 11.9 % - in band, nothing planned, where the band relative to the target that
    /// this replaces would have traded the 10 % leg from 10.2 % - and to 52.1 % / 12.1 %: due
    /// alone, one sale, its deviation 210 points. The other legs, diluted by it, stay
    /// within 2 points of their weights.
    function test_ALegIsDueOnlyWhenItsWeightLeavesTheBandInPoints() public {
        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (address(a), address(b), address(c));
        uint16[] memory w = new uint16[](3);
        (w[0], w[1], w[2]) = (5000, 4000, 1000);
        Etf fund = _create("BAND", t, w);
        assertEq(fund.REBALANCE_BAND_BPS(), 200);
        _mint(fund, alice, 1000e6);
        assertEq(fund.plan().length, 0, "at its weights");
        uint256 snap = vm.snapshotState();

        _pushWeight(fund, 0, 5190);
        assertEq(fund.plan().length, 0, "the 50 % leg at 51.9 %: in band");
        vm.revertToState(snap);
        _pushWeight(fund, 0, 5210);
        Etf.PlanLeg[] memory p = fund.plan();
        assertEq(p.length, 1, "the 50 % leg at 52.1 %: due, alone");
        assertTrue(p[0].leg == 0 && p[0].sell);
        assertApproxEqAbs(p[0].deviationBps, int256(210), 1, "210 points over its weight");

        vm.revertToState(snap);
        _pushWeight(fund, 2, 1190);
        assertEq(fund.plan().length, 0, "the 10 % leg at 11.9 %: in band");
        vm.revertToState(snap);
        _pushWeight(fund, 2, 1210);
        p = fund.plan();
        assertEq(p.length, 1, "the 10 % leg at 12.1 %: due, alone");
        assertTrue(p[0].leg == 2 && p[0].sell);
        assertApproxEqAbs(p[0].deviationBps, int256(210), 1, "210 points over its weight");
    }

    /// The floor is gone and the old names with it: neither the ETF nor
    /// the factory answers `DEAD_BAND_FLOOR_BPS()`, the ETF no longer answers `DEAD_BAND_BPS()` or
    /// `MIN_INTERVAL()`; `REBALANCE_BAND_BPS` and `REBALANCE_MIN_INTERVAL` are what it was built with.
    function test_TheBandFloorIsGoneAndTheOldNamesWithIt() public view {
        string[3] memory gone = ["DEAD_BAND_FLOOR_BPS()", "DEAD_BAND_BPS()", "MIN_INTERVAL()"];
        for (uint256 i = 0; i < gone.length; i++) {
            (bool ok,) = address(etf).staticcall(abi.encodeWithSignature(gone[i]));
            assertFalse(ok, gone[i]);
        }
        (bool answered,) = address(factory).staticcall(abi.encodeWithSignature("DEAD_BAND_FLOOR_BPS()"));
        assertFalse(answered, "the factory's floor");
        assertEq(etf.REBALANCE_BAND_BPS(), 200);
        assertEq(etf.REBALANCE_MIN_INTERVAL(), 1 hours);
    }

    /// `rebalanceMinInterval` 0 is allowed (author, 2026-10-19; a danger the page shows, never a
    /// refusal): the time sensor is always open, and a stranger rebalances again in the same second
    /// as the last rebalance, on a leg out of band.
    function test_AMinIntervalOfZeroLetsAnyoneRebalanceAtAnyTime() public {
        Etf.Params memory p = _params();
        p.rebalanceMinInterval = 0;
        Etf fast = _createWith("FAST", _two(address(a), address(b)), _bps2(5000, 5000), p);
        assertEq(fast.REBALANCE_MIN_INTERVAL(), 0);
        _mint(fast, alice, 1000e6);
        _credit(fast, address(a), 1e18);
        fast.rebalance(_planRoutes(fast.plan()));
        assertEq(fast.lastRebalanceAt(), block.timestamp, "closed");
        (bool ready, uint256 readyAt) = fast.canRebalance();
        assertTrue(ready);
        assertEq(readyAt, block.timestamp);
        _credit(fast, address(b), 1e18);
        Etf.PlanLeg[] memory again = fast.plan();
        assertGt(again.length, 0);
        vm.prank(carol);
        fast.rebalance(_planRoutes(again));
        assertEq(fast.lastRebalanceAt(), block.timestamp, "the second one, the same second");
    }

    // -------------------------------------------------------------- fees ---

    /// The entry fee is paid in USDG, out of `usdgIn` before the legs are bought, and pushed at
    /// the mint: the protocol's part to the factory's `owner()`, the creator's to `feeRecipient`.
    /// On 1 000 USDG: E = 0 -> 1 paid, all to the
    /// protocol; E = 10 -> 1, all to the protocol; E = 100 -> 10, 3 to the protocol and 7 to the
    /// creator. The shares are the USDG that reached the fund, all the minter's; no fee share.
    /// `entryFee(10 000)` gives the same rates in bps.
    function test_TheEntryFeeIsPaidInUsdgAndSplitWithTheProtocolsLeast() public {
        uint16[3] memory creatorFees = [uint16(0), 10, 100];
        uint256[3] memory toProtocol = [uint256(1e6), 1e6, 3e6];
        uint256[3] memory toCreator = [uint256(0), 0, 7e6];
        for (uint256 i = 0; i < 3; i++) {
            Etf.Params memory p = _params();
            p.entryFeeBps = creatorFees[i];
            Etf e = _createWith(string.concat("E", vm.toString(i)), _two(address(a), address(b)), _bps2(5000, 5000), p);
            (uint256 total, uint256 protocol, uint256 creatorPart) = e.entryFee(10_000);
            assertEq(protocol, toProtocol[i] / 1e5, "the protocol's rate, bps");
            assertEq(creatorPart, toCreator[i] / 1e5, "the creator's rate, bps");
            assertEq(total, protocol + creatorPart, "what the minter pays: max(E, 10)");
            uint256 ownerBefore = usdg.balanceOf(owner);
            uint256 makerBefore = usdg.balanceOf(maker);
            uint256 aliceBefore = usdg.balanceOf(alice);
            uint256 shares = _mint(e, alice, 1000e6);
            assertEq(aliceBefore - usdg.balanceOf(alice), 1000e6);
            assertEq(usdg.balanceOf(owner) - ownerBefore, toProtocol[i], "pushed to the factory's owner");
            assertEq(usdg.balanceOf(maker) - makerBefore, toCreator[i], "pushed to the creator's recipient");
            assertEq(shares, (1000e6 - toProtocol[i] - toCreator[i]) * 1e12 - 1e15, "one share per USDG that reached the fund, less the dead shares");
            assertEq(e.totalSupply(), shares + 1e15, "no fee share on a USDG mint");
        }
    }

    /// The exit fee is taken in shares on both redeems, before anything is paid: 30 % moved to the
    /// factory's owner, 70 % to the creator's recipient, only the rest burned, and no USDG to either.
    /// Exit 1 %, past the hold: alice redeems 100 shares to USDG, the legs of the 99 paid sold, all
    /// the USDG out hers; then 100 more in kind, the same split, and both doors pay the same per share.
    function test_TheExitFeeIsInSharesOnBothRedeems() public {
        Etf.Params memory p = _params();
        p.exitFeeBps = 100;
        Etf f = _createWith("EXIT", _two(address(a), address(b)), _bps2(5000, 5000), p);
        _mint(f, alice, 1000e6);
        vm.warp(block.timestamp + 2 hours);
        (uint256[] memory due, uint256 usdgPart, uint256 feeShares, uint256 paid) = f.previewRedeemToUsdg(alice, 100e18);
        assertEq(feeShares, 1e18);
        assertEq(paid, 99e18, "the legs of the 99 paid are sold, never the fee's");
        assertEq(usdgPart, 0);
        (,,, uint256[] memory inKind,) = f.previewRedeem(alice, 100e18);
        assertEq(due[0], inKind[0], "the same payout as in kind");
        assertEq(due[1], inKind[1]);
        uint256 sold = _out(address(a), address(usdg), due[0]) + _out(address(b), address(usdg), due[1]);
        uint256 ownerBefore = usdg.balanceOf(owner);
        uint256 makerBefore = usdg.balanceOf(maker);
        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 supply = f.totalSupply();
        (uint256 mc, uint256 mp) = f.pendingManagementFee(); // two hours' management fee, accrued first
        Etf.Route[] memory sells = _sellRoutes(f, due);
        vm.prank(alice);
        uint256 out = f.redeem(100e18, sells, 1, alice);
        assertEq(out, sold, "every USDG the sale brought");
        assertEq(usdg.balanceOf(alice) - aliceBefore, out);
        assertEq(usdg.balanceOf(owner), ownerBefore, "no USDG fee");
        assertEq(usdg.balanceOf(maker), makerBefore);
        assertEq(f.totalSupply(), supply + mc + mp - 99e18, "only the 99 paid burned");
        assertEq(f.balanceOf(owner), mp + 0.3e18, "30 % of the 1 share to the owner");
        assertEq(f.balanceOf(maker), mc + 0.7e18, "70 % to the creator's recipient");

        vm.prank(alice);
        f.redeemInKind(100e18, alice, 0);
        assertEq(f.balanceOf(owner), mp + 0.6e18, "the same on the in-kind door");
        assertEq(f.balanceOf(maker), mc + 1.4e18);
        assertEq(usdg.balanceOf(owner), ownerBefore, "no USDG on either door");
        assertEq(usdg.balanceOf(maker), makerBefore);
    }

    /// The penalties are moved in shares on `redeem` too, as the exit fee: the worked example's 15
    /// shares within the hold (0.1 early + 0.1 non-minter + 0.015 exit), another holder in the fund.
    /// `previewRedeemToUsdg` lets the routes sell the legs of the 14.785 paid, never more; the 0.215
    /// go 30 / 70 to the owner and the creator's recipient in shares, all the USDG out to alice, and
    /// the holder who stays keeps exactly its tokens per share.
    function test_ARedeemToUsdgMovesThePenaltiesInSharesAsTheExitFee() public {
        Etf one = _worked();
        _mint(one, maker, 10_010_010);
        uint256 makerShares = one.balanceOf(maker);
        uint256 supply = one.totalSupply();
        uint256 held = a.balanceOf(address(one));
        (uint256[] memory due, uint256 usdgPart, uint256 feeShares, uint256 paid) = one.previewRedeemToUsdg(alice, 15e18);
        assertEq(paid, 14.785e18, "15 less the exit fee and the penalties");
        assertEq(feeShares, 0.215e18);
        assertEq(usdgPart, 0);
        assertEq(due[0], held * 14.785e18 / supply, "the legs of 14.785 shares, no more");
        uint256 sold = _out(address(a), address(usdg), due[0]);
        uint256 ownerBefore = usdg.balanceOf(owner);
        Etf.Route[] memory sells = _sellRoutes(one, due);
        vm.prank(alice);
        uint256 out = one.redeem(15e18, sells, 1, alice);
        assertEq(out, sold);
        assertEq(usdg.balanceOf(owner), ownerBefore, "no USDG fee");
        assertEq(one.balanceOf(owner), 0.0645e18);
        assertEq(one.balanceOf(maker) - makerShares, 0.1505e18);
        assertEq(one.mintOf(alice), 0);
        assertEq(one.totalSupply(), supply - 14.785e18, "the 14.785 burned");
        assertEq(a.balanceOf(address(one)), held - due[0]);
        assertGe(a.balanceOf(address(one)) * 1e18 / one.totalSupply(), held * 1e18 / supply, "the holder who stays keeps its tokens per share");
    }

    /// Every fee share goes into its receiver's `mintOf` without moving its clock,
    /// for the creator's recipient and the factory's owner alike: the entry fee of a mint in
    /// kind (1 %: 0.3 / 0.7 of 100 shares), the exit fee of a redeem in kind (1 % of 10: 0.03 /
    /// 0.07) and the management fee. Each then redeems all its shares paying the exit fee alone -
    /// covered, its clock never started - and no penalty spares a receiver that mints ("pas
    /// fair-play"): the creator's own mint restarts its clock over its fee shares too.
    function test_FeeSharesCountInTheReceiversMintOfAndNeverMoveItsClock() public {
        Etf.Params memory p = _params();
        (p.entryFeeBps, p.exitFeeBps) = (100, 100);
        Etf f = _createWith("FEES", _two(address(a), address(b)), _bps2(5000, 5000), p);
        _mint(f, alice, 1000e6);
        (uint256[] memory need, uint256 usdgNeed) = f.quoteMint(100e18);
        a.mint(bob, need[0]);
        b.mint(bob, need[1]);
        vm.startPrank(bob);
        a.approve(address(f), type(uint256).max);
        b.approve(address(f), type(uint256).max);
        f.mintInKind(need, usdgNeed, 1);
        vm.stopPrank();
        assertEq(f.balanceOf(owner), 0.3e18, "the entry fee in shares, 30 % to the owner");
        assertEq(f.balanceOf(maker), 0.7e18, "70 % to the creator's recipient");
        assertEq(f.mintOf(owner), 0.3e18);
        assertEq(f.mintOf(maker), 0.7e18);

        vm.warp(block.timestamp + 2 hours);
        (uint256 mc, uint256 mp) = f.pendingManagementFee(); // two hours' management fee, accrued first
        vm.prank(bob);
        f.redeemInKind(10e18, bob, 0);
        assertEq(f.mintOf(owner), 0.33e18 + mp, "the exit fee in shares, counted");
        assertEq(f.mintOf(maker), 0.77e18 + mc);

        vm.warp(block.timestamp + 365 days);
        (uint256 creatorFee, uint256 protocolFee) = f.pendingManagementFee();
        f.rebalance(new Etf.Route[](0));
        assertEq(f.mintOf(owner), 0.33e18 + mp + protocolFee, "the management fee, counted");
        assertEq(f.mintOf(maker), 0.77e18 + mc + creatorFee);
        assertEq(f.lastMintAt(owner), 0, "no fee moved the owner's clock");
        assertEq(f.lastMintAt(maker), 0, "nor the creator's");

        address[2] memory receivers = [owner, maker];
        for (uint256 i = 0; i < 2; i++) {
            uint256 all = f.balanceOf(receivers[i]);
            (uint256 paid, uint256 fee, uint256 burned,,) = f.previewRedeem(receivers[i], all);
            assertEq(burned, 0, "no penalty: covered, the hold never started");
            assertEq(fee, all / 100, "the exit fee, like anyone");
            assertEq(paid, all - fee);
        }

        uint256 makerShares = f.balanceOf(maker);
        _mint(f, maker, 10e6);
        (,, uint256 penalty,,) = f.previewRedeem(maker, makerShares);
        assertEq(penalty, makerShares * 100 / 10_000, "its own mint put its fee shares under the early penalty too");
    }

    /// A frozen fee recipient blocks the one door that pushes USDG to it, `mint`, never the others,
    /// and its holder unblocks it by moving it (USDG's `freeze`, measured on chain 4663 at block
    /// 92 604 149; the mock reverts any transfer to a frozen address). The creator's recipient
    /// frozen: `mint` reverts, `redeem`, `mintInKind` and `redeemInKind` run;
    /// `setFeeRecipient` moves it and `mint` runs again, its 0.7 % to the new recipient. The
    /// factory's owner frozen: `mint` reverts until `transferOwnership` moves it, the 0.3 % then to
    /// the new owner.
    function test_AFrozenFeeRecipientBlocksMintsUntilItsHolderMovesIt() public {
        Etf.Params memory p = _params();
        (p.entryFeeBps, p.exitFeeBps) = (100, 100);
        Etf f = _createWith("FRZ", _two(address(a), address(b)), _bps2(5000, 5000), p);
        _mint(f, alice, 1000e6);
        vm.warp(block.timestamp + 2 hours);
        Etf.Route[] memory buy = _buyRoutes(f, 100e6, false);
        (uint256[] memory due,,,) = f.previewRedeemToUsdg(alice, 10e18);
        Etf.Route[] memory sell = _sellRoutes(f, due);

        FreezableTokenMock(address(usdg)).freeze(maker, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FreezableTokenMock.AddressFrozen.selector, maker));
        f.mint(100e6, buy, 1);
        vm.prank(alice);
        assertGt(f.redeem(10e18, sell, 1, alice), 0, "the exit fee in shares: redeem stays open");

        (uint256[] memory need, uint256 usdgNeed) = f.quoteMint(10e18);
        a.mint(bob, need[0]);
        b.mint(bob, need[1]);
        vm.startPrank(bob);
        a.approve(address(f), type(uint256).max);
        b.approve(address(f), type(uint256).max);
        assertGt(f.mintInKind(need, usdgNeed, 1), 0, "the in-kind mint pushes no USDG: open");
        vm.stopPrank();
        vm.prank(alice);
        f.redeemInKind(10e18, alice, 0);

        vm.prank(maker);
        f.setFeeRecipient(carol);
        vm.prank(bob);
        f.mint(100e6, buy, 1);
        assertEq(usdg.balanceOf(carol), 0.7e6, "the creator's 0.7 % to the recipient he moved it to");

        address treasury = makeAddr("treasury");
        FreezableTokenMock(address(usdg)).freeze(owner, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FreezableTokenMock.AddressFrozen.selector, owner));
        f.mint(100e6, buy, 1);
        vm.prank(owner);
        factory.transferOwnership(treasury);
        vm.prank(bob);
        f.mint(100e6, buy, 1);
        assertEq(usdg.balanceOf(treasury), 0.3e6, "the protocol's 0.3 % to the owner it moved to");
    }

    /// Credit leg `i` of `fund` until its weight is `weightBps` of the NAV, at the price `legs()`
    /// reads it: `x = (w x nav - value) / (1 - w)` USDG of it.
    function _pushWeight(Etf fund, uint256 i, uint256 weightBps) internal {
        (uint256 nav,) = fund.nav();
        Etf.Leg memory l = fund.legs()[i];
        uint256 add = (weightBps * nav - l.value * 10_000) / (10_000 - weightBps);
        _credit(fund, l.token, add * 1e30 / l.price);
    }

    // ------------------------------------------------------------ creator ---

    /// The creator alone hands the role on, and the fees go with it: `setCreator` makes the new creator
    /// the `feeRecipient` too; only the creator moves it after; the old one no longer can.
    function test_TheCreatorHandsTheRoleOnAndOnlyTheCreatorSetsTheFeeRecipient() public {
        assertEq(etf.feeRecipient(), maker, "the creator at birth");
        vm.prank(alice);
        vm.expectRevert(Etf.NotCreator.selector);
        etf.setCreator(alice);
        vm.prank(alice);
        vm.expectRevert(Etf.NotCreator.selector);
        etf.setFeeRecipient(alice);
        vm.prank(maker);
        etf.setCreator(carol);
        assertEq(etf.creator(), carol);
        assertEq(etf.feeRecipient(), carol, "the new creator receives the fees by default");
        vm.prank(maker);
        vm.expectRevert(Etf.NotCreator.selector);
        etf.setFeeRecipient(maker);
        vm.prank(carol);
        vm.expectRevert(Etf.ZeroAddress.selector);
        etf.setFeeRecipient(address(0));
        vm.expectEmit(true, true, false, false, address(etf));
        address chosen = makeAddr("chosen recipient");
        emit Etf.FeeRecipientChanged(carol, chosen);
        vm.prank(carol);
        etf.setFeeRecipient(chosen);
        _mint(etf, alice, 1000e6);
        assertEq(usdg.balanceOf(chosen), 1e6, "the creator's part of the entry fee, in USDG, to the recipient the new creator chose");
    }

    // ------------------------------------------------------------ routes ---

    /// Every swap's router call is the contract's, whole: one command, nothing a caller can add - so
    /// no `SWEEP` in, no `TRANSFER` out, no second swap, no pool. V3: `V3_SWAP_EXACT_IN(fund, amountIn,
    /// amountOutMin, token fee USDG, false, "")` at the registered pool's fee. V4: `V4_SWAP` holding
    /// `SWAP_EXACT_IN_SINGLE` on the registered key (c: fee 100, spacing 1), the two tokens sorted,
    /// its hooks (0 here) and empty hook data, then `SETTLE(tokenIn, amountIn, false)` from the router's
    /// balance and `TAKE(tokenOut, fund, 0)`. Once the owner gives c a hooked pool, the same route carries
    /// that hook in its key, the hook data still empty.
    function test_TheRouterCallIsWrittenWholeOneCommandAndAV4KeyCarriesTheRegisteredHook() public {
        _mint(etf, alice, 1000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 100e6, false);
        uint256 amount = r[2].amountIn;
        r[2] = _v4Route(2, false, amount);
        r[2].amountOutMin = 7;
        router.setRecord(true);
        vm.prank(bob);
        uint256 shares = etf.mint(100e6, r, 1);
        assertEq(router.lastCommands(), hex"10", "one command: V4_SWAP");
        bool zeroForOne = address(usdg) < address(c);
        V4KeyMock memory key = V4KeyMock({ currency0: zeroForOne ? address(usdg) : address(c), currency1: zeroForOne ? address(c) : address(usdg), fee: 100, tickSpacing: 1, hooks: address(0) });
        bytes[] memory params = new bytes[](3);
        // forge-lint: disable-next-line(unsafe-typecast)
        params[0] = abi.encode(V4SingleMock({ poolKey: key, zeroForOne: zeroForOne, amountIn: uint128(amount), amountOutMinimum: 7, minHopPriceX36: 0, hookData: "" }));
        params[1] = abi.encode(address(usdg), amount, false);
        params[2] = abi.encode(address(c), address(etf), uint256(0));
        bytes memory actions = hex"060b0e";
        assertEq(router.lastInput(), abi.encode(actions, params), "swap, settle, take: nothing else");
        assertEq(router.lastHooks(), address(0), "no hook");

        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(bob, shares);
        Etf.Route[] memory sells = _sellRoutes(etf, due);
        sells[2].amountOutMin = 3;
        vm.prank(bob);
        etf.redeem(shares, sells, 1, bob);
        assertEq(router.lastCommands(), hex"00", "one command: V3_SWAP_EXACT_IN");
        assertEq(router.lastInput(), abi.encode(address(etf), due[2], uint256(3), abi.encodePacked(address(c), uint24(3000), address(usdg)), false, bytes("")));

        address hook = makeAddr("hook");
        _v4PoolHooked(address(c), 500, 10, hook);
        r = _buyRoutes(etf, 100e6, false);
        amount = r[2].amountIn;
        r[2] = _v4Route(2, false, amount);
        vm.prank(bob);
        etf.mint(100e6, r, 1);
        key = V4KeyMock({ currency0: key.currency0, currency1: key.currency1, fee: 500, tickSpacing: 10, hooks: hook });
        // forge-lint: disable-next-line(unsafe-typecast)
        params[0] = abi.encode(V4SingleMock({ poolKey: key, zeroForOne: zeroForOne, amountIn: uint128(amount), amountOutMinimum: 0, minHopPriceX36: 0, hookData: "" }));
        params[1] = abi.encode(address(usdg), amount, false);
        assertEq(router.lastInput(), abi.encode(actions, params), "the hooked key, empty hook data");
        assertEq(router.lastHooks(), hook);
    }

    /// A route names no pool: whatever pools of the pair exist, the swap runs through the one the
    /// factory registered. Other pools of a's pair - V3 at 0.05 % and 1 %, a hookless V4 pool at
    /// 3000 / 60 - priced ten times better for the buyer by the router are never reached: the mint gets
    /// exactly the shares of the registered pools, the router saw fee 3000. Once the owner moves a to
    /// its 0.05 % pool (`setTokenSources`), the same route runs there. A V4 route on a, which has no V4
    /// pool, is refused (`NoV4Pool`), in a mint and in a redeem; on c it runs at c's registered key.
    function test_ARouteRunsOnlyThroughTheTokensRegisteredPool() public {
        _mint(etf, alice, 1000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 100e6, false);
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        uint256 shares = etf.mint(100e6, r, 1);
        uint256 aBack = a.balanceOf(bob);
        vm.revertToState(snap);

        uint256 cheap = 1e48 / 25e18; // a at 25 USDG instead of 250
        router.setPoolRate(address(usdg), address(a), false, 500, 0, cheap);
        router.setPoolRate(address(usdg), address(a), false, 10_000, 0, cheap);
        router.setPoolRate(address(usdg), address(a), true, 3000, 60, cheap);
        PoolManagerMock(router.poolManager()).initialize(_v4Key(address(a), 3000, 60, address(0)), _spot100(address(a)));
        PoolMock pa500 = _poolAt(address(a), _tickAt(250e18), 500);
        snap = vm.snapshotState();
        router.setRecord(true);
        vm.prank(bob);
        assertEq(etf.mint(100e6, r, 1), shares, "the same shares as with no other pool at all");
        assertEq(a.balanceOf(bob), aBack, "the same a refunded: the cheap pools were not reached");
        (address pool, uint24 fee,,,) = factory.poolsOf(address(a));
        assertEq(pool, address(pa));
        assertEq(fee, 3000);
        vm.revertToState(snap);

        vm.prank(owner);
        factory.setTokenSources(address(a), address(pa500));
        (pool, fee,,,) = factory.poolsOf(address(a));
        assertEq(pool, address(pa500));
        assertEq(fee, 500, "the factory's record follows the pool");
        vm.prank(bob);
        etf.mint(100e6, r, 1);
        assertGt(a.balanceOf(bob), 1.5e18, "now through the 0.05 % pool: ten times the a, the excess refunded");
        vm.revertToState(snap);

        r[0] = _v4Route(0, false, r[0].amountIn);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Etf.NoV4Pool.selector, address(a)));
        etf.mint(100e6, r, 1);
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(alice, 10e18);
        Etf.Route[] memory sells = _sellRoutes(etf, due);
        sells[0] = _v4Route(0, true, due[0]);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Etf.NoV4Pool.selector, address(a)));
        etf.redeem(10e18, sells, 1, alice);
    }

    /// A router that sends the fund more than the swap - what a sweep into it once did - changes
    /// nothing credited. Leg b sent during leg a's swap, in a mint and in a redeem: the same shares,
    /// the same USDG out, the entry fee on the real `usdgIn`, the same exit fee shares; the
    /// extra b stays in the fund, for the holders. USDG sent during a mint's swap, the token the
    /// fund pays with, reverts it: the fund's USDG did not fall by exactly `amountIn`. Entry 1 %,
    /// exit 1 %.
    function test_ExtraTokensARouterSendsAreNotCreditedAndTheFeesFollowTheRealAmounts() public {
        Etf.Params memory p = _params();
        (p.entryFeeBps, p.exitFeeBps) = (100, 100);
        Etf fund = _createWith("FEES", _two(address(a), address(b)), _bps2(5000, 5000), p);
        _mint(fund, alice, 1000e6);
        Etf.Route[] memory r = _buyRoutes(fund, 100e6, false);
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        uint256 fair = fund.mint(100e6, r, 1);
        vm.revertToState(snap);

        router.setGift(address(usdg), 50e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Etf.InputNotSpent.selector, address(usdg)));
        fund.mint(100e6, r, 1);

        router.setGift(address(b), 1e18); // one b to the fund during a's swap
        uint256 makerBefore = usdg.balanceOf(maker);
        uint256 ownerBefore = usdg.balanceOf(owner);
        uint256 fundB = b.balanceOf(address(fund));
        vm.prank(bob);
        uint256 shares = fund.mint(100e6, r, 1);
        assertGe(b.balanceOf(address(fund)), fundB + 1e18, "the gift stays in the fund");
        assertEq(shares, fair, "the gift buys no share");
        (uint256 total, uint256 protocol, uint256 creator_) = fund.entryFee(100e6);
        assertEq(total, 1e6);
        assertEq(usdg.balanceOf(owner) - ownerBefore, protocol, "the protocol's part of the fee on 100 USDG");
        assertEq(usdg.balanceOf(maker) - makerBefore, creator_, "the creator's part of the fee on 100 USDG");
        assertEq(b.balanceOf(bob), 0, "nothing of the gift refunded either");

        (uint256[] memory due,,,) = fund.previewRedeemToUsdg(bob, shares);
        Etf.Route[] memory sells = _sellRoutes(fund, due);
        snap = vm.snapshotState();
        uint256 feesBefore = fund.balanceOf(owner) + fund.balanceOf(maker);
        vm.prank(bob);
        uint256 fairOut = fund.redeem(shares, sells, 1, bob);
        uint256 fairExitFee = fund.balanceOf(owner) + fund.balanceOf(maker) - feesBefore;
        vm.revertToState(snap);
        router.setGift(address(b), 1e18); // one more b during a's sale
        fundB = b.balanceOf(address(fund));
        vm.prank(bob);
        uint256 out = fund.redeem(shares, sells, 1, bob);
        assertEq(out, fairOut, "the same USDG out");
        assertEq(fund.balanceOf(owner) + fund.balanceOf(maker) - feesBefore, fairExitFee, "the same exit fee shares");
        assertGt(fairExitFee, 0);
        assertEq(b.balanceOf(bob), 0);
        assertEq(b.balanceOf(address(fund)), fundB - due[1] + 1e18, "the gift stays in the fund");
    }

    /// The fund gives exactly `amountIn` and the router keeps none of it: a router that keeps 1 % of
    /// the input unswapped, or hands 10 % of it back, reverts the door (`InputNotSpent`).
    function test_ARouterThatKeepsOrHandsBackPartOfTheInputReverts() public {
        _mint(etf, alice, 1000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 100e6, false);
        router.setKeepBps(100);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Etf.InputNotSpent.selector, address(usdg)));
        etf.mint(100e6, r, 1);
        router.setKeepBps(0);
        router.setTakeBps(9000);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Etf.InputNotSpent.selector, address(usdg)));
        etf.mint(100e6, r, 1);

        router.setTakeBps(10_000);
        router.setKeepBps(100);
        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(alice, 10e18);
        Etf.Route[] memory sells = _sellRoutes(etf, due);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Etf.InputNotSpent.selector, address(a)));
        etf.redeem(10e18, sells, 1, alice);
    }

    /// A mint's and a redeem's `amountOutMin` is the caller's and binds: written into the swap, so
    /// the router refuses under it (`V3TooLittleReceived`), and checked again on the fund's balance
    /// (`InsufficientOutput`) against a router that delivers nothing.
    function test_TheCallersMinimumBindsAMintAndARedeem() public {
        _mint(etf, alice, 1000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 100e6, false);
        uint256 out = _out(address(usdg), address(a), r[0].amountIn);
        r[0].amountOutMin = out + 1;
        vm.prank(bob);
        vm.expectRevert(UniversalRouterMock.V3TooLittleReceived.selector);
        etf.mint(100e6, r, 1);
        r[0].amountOutMin = out;
        router.setPayNothing(true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Etf.InsufficientOutput.selector, 0, out));
        etf.mint(100e6, r, 1);
    }

    /// Inside one of an ETF's doors its shares and holdings move apart (a mint has bought legs and
    /// not yet minted), so the factory gives no NAV for it then: read mid-swap, `getPriceUsdg` answers
    /// nothing for an unlisted ETF and its pool's TWAP for a listed one, and `entered()` is true. A
    /// parent's rebalance called from inside a child's door cannot trade the child at its NAV.
    function test_NoNavIsGivenForAnEtfInsideItsOwnDoor() public {
        _mint(etf, alice, 1000e6);
        (uint256 nav, uint8 source) = factory.getPriceUsdg(address(etf));
        assertEq(source, SOURCE_NAV);
        Etf.Route[] memory r = _buyRoutes(etf, 100e6, false);
        router.setProbe(address(factory), abi.encodeCall(Factory.getPriceUsdg, (address(etf))));
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        etf.mint(100e6, r, 1);
        (uint256 price, uint8 mid) = abi.decode(router.probeAnswer(), (uint256, uint8));
        assertEq(mid, SOURCE_NONE, "mid-door: no NAV, and no pool to fall to");
        assertEq(price, 0);
        (, source) = factory.getPriceUsdg(address(etf));
        assertEq(source, SOURCE_NAV, "the door closed: the NAV again");

        vm.revertToState(snap);
        _listEtf(etf, TICK_100_USD);
        vm.prank(bob);
        etf.mint(100e6, r, 1);
        (price, mid) = abi.decode(router.probeAnswer(), (uint256, uint8));
        assertEq(mid, SOURCE_POOL, "mid-door, listed: its pool's TWAP");
        assertApproxEqRel(price, 100e18, 0.005e18);
        assertApproxEqRel(nav, 1e18, 2 * ONE_BP);

        router.setProbe(address(etf), abi.encodeCall(Etf.entered, ()));
        vm.prank(bob);
        etf.mint(100e6, r, 1);
        assertTrue(abi.decode(router.probeAnswer(), (bool)), "entered() mid-door");
        assertFalse(etf.entered());
    }

    /// The attack ad7cbfe showed is gone: a pool of the caller's own, selling every leg at a tenth of
    /// its price, made a mint of 100 USDG worth ten times that in shares at the fee on 100 USDG. Here
    /// bob's pools exist - V3 at 1 % and hookless V4 at 3000 / 60 for each leg, the router filling
    /// them at a tenth - and his mint, V3 or V4, cannot reach them: it gets the fair shares of the
    /// registered pools, or `NoV4Pool` on a leg without a V4 pool; a hooked pool of his own is no V4
    /// pool he can register (the owner's `setTokenV4Pool`).
    function test_APoolOfTheCallersOwnIsOutOfReachSoMintStaysAtTheFairShares() public {
        _mint(etf, alice, 1000e6);
        Etf.Route[] memory r = _buyRoutes(etf, 100e6, false);
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        uint256 fair = etf.mint(100e6, r, 1);
        vm.revertToState(snap);
        address[3] memory legs = [address(a), address(b), address(c)];
        uint256[3] memory tenth = [uint256(25e18), 50e18, 12.5e18];
        for (uint256 i = 0; i < 3; i++) {
            router.setPoolRate(address(usdg), legs[i], false, 10_000, 0, 1e48 / tenth[i]);
            router.setPoolRate(address(usdg), legs[i], true, 3000, 60, 1e48 / tenth[i]);
            PoolManagerMock(router.poolManager()).initialize(_v4Key(legs[i], 3000, 60, address(0)), _spot100(legs[i]));
        }
        vm.prank(bob);
        assertEq(etf.mint(100e6, r, 1), fair, "the fair shares, not ten times them");
        vm.revertToState(snap);
        r[0] = _v4Route(0, false, r[0].amountIn);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Etf.NoV4Pool.selector, address(a)));
        etf.mint(100e6, r, 1);

        PoolManagerMock(router.poolManager()).initialize(_v4Key(address(a), 500, 10, makeAddr("bob's hook")), _spot100(address(a)));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        factory.setTokenV4Pool(address(a), 500, 10, makeAddr("bob's hook"));
    }

    // ---------------------------------------------------------------- gas ---

    /// A full ten-leg ETF: the first mint and a later mint, each as its own call, on the mocks
    /// (`forge test --match-test test_gas_ATenLegMint -vv` logs them).
    function test_gas_ATenLegMint() public {
        address[] memory t = new address[](10);
        uint16[] memory w = new uint16[](10);
        for (uint256 i = 0; i < 10; i++) {
            (TokenMock x,) = _token(string.concat("G", vm.toString(i)), 100);
            t[i] = address(x);
            w[i] = 1000;
        }
        Etf ten = _create("TEN", t, w);
        Etf.Route[] memory r = _buyRoutes(ten, 10_000e6, true);
        vm.prank(alice);
        uint256 g = gasleft();
        ten.mint(10_000e6, r, 1);
        console2.log("ten legs, first mint, gas", g - gasleft());
        r = _buyRoutes(ten, 10_000e6, false);
        vm.prank(bob);
        g = gasleft();
        ten.mint(10_000e6, r, 1);
        console2.log("ten legs, later mint with refunds, gas", g - gasleft());
    }

    // ------------------------------------------------------ management fee ---

    /// Bob mints 30 days after alice, no rebalance between: the 30 days' fee, on alice's supply, is
    /// minted before his shares, so his part of the fund is what he brought and he pays none of it.
    /// Against the same mint with no accrual at the door (the clock set to now by hand, then the 30
    /// days accrued after it on the larger supply), his part is 30 x 0.50 % / 365 = 0.041 % larger.
    function test_AMinterPaysNoneOfTheManagementFeeDueBeforeHisMint() public {
        _mint(etf, alice, 1000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 supply = etf.totalSupply();
        (uint256 creatorFee, uint256 protocolFee) = etf.pendingManagementFee();
        assertGt(protocolFee, 0);
        Etf.Route[] memory r = _buyRoutes(etf, 1000e6, false);

        uint256 snap = vm.snapshotState();
        uint256 slot = stdstore.target(address(etf)).sig("lastAccrualAt()").find();
        uint256 since = etf.lastAccrualAt();
        vm.store(address(etf), bytes32(slot), bytes32(vm.getBlockTimestamp()));
        vm.prank(bob);
        uint256 lateShares = etf.mint(1000e6, r, 1);
        vm.store(address(etf), bytes32(slot), bytes32(since));
        etf.rebalance(new Etf.Route[](0));
        uint256 latePart = lateShares * 1e18 / etf.totalSupply();
        vm.revertToState(snap);

        uint256 heldBefore = a.balanceOf(address(etf));
        vm.prank(bob);
        uint256 shares = etf.mint(1000e6, r, 1);
        assertEq(etf.balanceOf(maker), creatorFee, "the creator's part, minted at bob's door");
        assertEq(etf.balanceOf(owner), protocolFee, "the protocol's part");
        assertEq(etf.totalSupply(), supply + creatorFee + protocolFee + shares, "the fee before his shares");
        assertEq(etf.lastAccrualAt(), vm.getBlockTimestamp());
        uint256 kept = a.balanceOf(address(etf)) - heldBefore;
        uint256 claim = Math.mulDiv(a.balanceOf(address(etf)), shares, etf.totalSupply());
        assertApproxEqRel(claim, kept, 1e9, "his part of leg a is what his mint kept of it");
        uint256 part = shares * 1e18 / etf.totalSupply();
        assertGt(part, latePart);
        assertApproxEqRel(part - latePart, part * 50 * 30 / (10_000 * 365), 1e16, "30 days' fee he no longer pays");
    }

    /// Alice redeems in kind 29 days after the last accrual: the 29 days' fee is minted first, on
    /// the supply she is still in, so each leg pays her `held x paid / (supply + fee)`, not
    /// `/ supply`, and the receivers hold the fee.
    function test_ARedeemPaysItsPartOfTheManagementFeeFirst() public {
        _mint(etf, alice, 1000e6);
        _mint(etf, bob, 500e6);
        vm.warp(vm.getBlockTimestamp() + 29 days);
        uint256 supply = etf.totalSupply();
        (uint256 creatorFee, uint256 protocolFee) = etf.pendingManagementFee();
        assertGt(protocolFee, 0);
        uint256 shares = etf.balanceOf(alice);
        (uint256 paid,,,,) = etf.previewRedeem(alice, shares);
        uint256[3] memory held = [a.balanceOf(address(etf)), b.balanceOf(address(etf)), c.balanceOf(address(etf))];
        vm.prank(alice);
        etf.redeemInKind(shares, alice, 0);
        TokenMock[3] memory t = [a, b, c];
        for (uint256 i = 0; i < 3; i++) {
            assertEq(t[i].balanceOf(alice), Math.mulDiv(held[i], paid, supply + creatorFee + protocolFee), "her part after the fee");
            assertLt(t[i].balanceOf(alice), Math.mulDiv(held[i], paid, supply), "less than before it");
        }
        assertEq(etf.balanceOf(maker), creatorFee);
        assertEq(etf.balanceOf(owner), protocolFee);
    }

    /// A door every second for an hour on the smallest fund there can be (one leg, min interval 0,
    /// everyone gone but the dead shares and the fee shares, about 1e15 share units: some 95 000 creator
    /// and 63 000 protocol units a second, never whole) mints at least the fee of one accrual at
    /// the end, less 1 unit per part, plus only the fee on the fee shares minted along the way (under
    /// a millionth): every door moves the clock, and each part's remainder is carried, so no fee is
    /// rounded away.
    function test_FrequentDoorsOnASmallFundRoundNoManagementFeeAway() public {
        Etf.Params memory p = _params();
        p.rebalanceMinInterval = 0;
        Etf f = _createWith("DUST", _one(address(a)), _all(), p);
        _mint(f, alice, 1e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        uint256 out = f.balanceOf(alice);
        vm.prank(alice);
        f.redeemInKind(out, alice, 0);
        assertLt(f.totalSupply(), 2e15, "the dead shares and two hours of fee on 1 share");
        uint256 start = vm.getBlockTimestamp();
        uint256 creatorStart = f.balanceOf(maker);
        uint256 protocolStart = f.balanceOf(owner);

        uint256 snap = vm.snapshotState();
        vm.warp(start + 1);
        f.rebalance(new Etf.Route[](0));
        assertEq(f.lastAccrualAt(), start + 1, "every door moves the clock");
        for (uint256 s = 2; s <= 1 hours; s++) {
            vm.warp(start + s);
            f.rebalance(new Etf.Route[](0));
        }
        uint256 creatorFrequent = f.balanceOf(maker) - creatorStart;
        uint256 protocolFrequent = f.balanceOf(owner) - protocolStart;
        vm.revertToState(snap);

        vm.warp(start + 1 hours);
        f.rebalance(new Etf.Route[](0));
        uint256 creatorOnce = f.balanceOf(maker) - creatorStart;
        uint256 protocolOnce = f.balanceOf(owner) - protocolStart;
        assertGt(protocolOnce, 100);
        assertGe(creatorFrequent + 1, creatorOnce, "the creator's part: nothing rounded away");
        assertGe(protocolFrequent + 1, protocolOnce, "the protocol's part: nothing rounded away");
        assertApproxEqRel(creatorFrequent, creatorOnce, 1e12, "only the fee on the fee shares on top");
        assertApproxEqRel(protocolFrequent, protocolOnce, 1e12);
    }

    /// Gas of a later mint and a redeem to USDG on the three-leg fund, each a day after the last
    /// door, the fee's receivers already holding shares (so the management fee is accrued inside it
    /// on warm balances), then the same door again in the same second (nothing to accrue).
    function test_gas_AMintAndARedeemADayAfterTheLastDoor() public {
        _mint(etf, alice, 1000e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        etf.rebalance(new Etf.Route[](0));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        Etf.Route[] memory r = _buyRoutes(etf, 1000e6, false);
        vm.prank(bob);
        uint256 g = gasleft();
        etf.mint(1000e6, r, 1);
        console2.log("later mint, a day after, gas", g - gasleft());
        r = _buyRoutes(etf, 1000e6, false);
        vm.prank(bob);
        g = gasleft();
        etf.mint(1000e6, r, 1);
        console2.log("later mint, same second, gas", g - gasleft());

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 shares = etf.balanceOf(alice) / 4;
        (,,, uint256[] memory due,) = etf.previewRedeem(alice, shares);
        r = _sellRoutes(etf, due);
        vm.prank(alice);
        g = gasleft();
        etf.redeem(shares, r, 1, alice);
        console2.log("redeem, a day after, gas", g - gasleft());
        (,,, due,) = etf.previewRedeem(alice, shares);
        r = _sellRoutes(etf, due);
        vm.prank(alice);
        g = gasleft();
        etf.redeem(shares, r, 1, alice);
        console2.log("redeem, same second, gas", g - gasleft());
    }

    // ------------------------------------------------------------ helpers ---

    /// The worked example's fund: one leg (a at 250), entry fee 0, exit 0.10 %, hold 1 hour, early
    /// 1 %, non-minter 2 %; alice mints 10 shares, bob mints 5 and sends them to her. With an entry
    /// fee of 0 the minter still pays the protocol's 0.10 %, rounded down: 10.011011 USDG brings
    /// 10.001 to the fund, 10 shares to alice and 0.001 locked at `DEAD`; 5.005005 brings 5.
    function _worked() internal returns (Etf one) {
        Etf.Params memory p = Etf.Params({ entryFeeBps: 0, exitFeeBps: 10, holdPeriod: 1 hours, earlyPenaltyBps: 100, nonMinterPenaltyBps: 200, rebalanceBandBps: 200, rebalanceMinInterval: 1 hours });
        one = _createWith("WORK", _one(address(a)), _all(), p);
        assertEq(_mint(one, alice, 10_011_011), 10e18);
        Etf.Route[] memory r = _buyRoutes(one, 5_005_005, true);
        vm.prank(bob);
        assertEq(one.mint(5_005_005, r, 1), 5e18);
        vm.prank(bob);
        assertTrue(one.transfer(alice, 5e18));
        assertEq(one.balanceOf(alice), 15e18);
        assertEq(one.mintOf(alice), 10e18, "minted 10, received 5");
    }
}

/**
 * The final review's findings, each as the claim its fix makes, offline on `test/Mocks.sol`: the exit
 * fee and the penalties moved in shares on both redeems (a whale leaving in many redeems pays all of
 * them, a bad sale shrinks none), the dead shares of the first mint (the fee clock never stalls, no
 * later minter takes what the fund holds, no dust supply prices small mints out), `redeemInKind`
 * past a leg whose balance cannot be read (paid from its count), a donated USDG unit that no longer
 * blocks a mint routing all its net, the factory's decimals cap against an overflowing quote, and an ETF's
 * NAV over its supply once its management fee is minted.
 */
contract MaidMarianEtfV4FinalTest is MaidMarianEtfV4Base {
    TokenMock internal a;
    TokenMock internal b;

    function setUp() public override {
        super.setUp();
        (a,) = _token("AAA", 250);
        (b,) = _token("BBB", 500);
    }

    /// No sale on any leg: `redeem` pays all in kind.
    function _noRoutes(uint256 n) internal view returns (Etf.Route[] memory r) {
        r = new Etf.Route[](n);
        for (uint256 i = 0; i < n; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            r[i] = _swapRoute(uint8(i), true, 0);
        }
    }

    function _bare() internal pure returns (Etf.Params memory p) {
        p = Etf.Params({ entryFeeBps: 0, exitFeeBps: 0, holdPeriod: 0, earlyPenaltyBps: 0, nonMinterPenaltyBps: 0, rebalanceBandBps: 200, rebalanceMinInterval: 0 });
    }

    /// A 5 % exit fee, the whale holding all but the dead shares leaves through `redeem` with no route
    /// in 21 steps (half of what she holds, twenty times, then the rest). Every step moves its fee in
    /// shares, 30 % to the factory's owner and 70 % to the creator's recipient: together 5 % of her
    /// shares to within a wei a step, and she leaves with 95 % of her part of leg A, not 99.99 %. No
    /// USDG goes to either.
    function test_AWhaleLeavingInTwentyOneRedeemsPaysTheWholeExitFee() public {
        Etf.Params memory p = _bare();
        p.exitFeeBps = 500;
        Etf f = _createWith("DODGE", _two(address(a), address(b)), _bps2(5000, 5000), p);
        _mint(f, alice, 1000e6);
        uint256 aliceShares = f.balanceOf(alice);
        uint256 supply = f.totalSupply();
        uint256 heldA = a.balanceOf(address(f));
        uint256 aliceA = a.balanceOf(alice);
        (uint256 ownerUsdg, uint256 makerUsdg) = (usdg.balanceOf(owner), usdg.balanceOf(maker));
        uint256 fees;
        for (uint256 k = 0; k < 21; k++) {
            uint256 s = k < 20 ? f.balanceOf(alice) / 2 : f.balanceOf(alice);
            fees += s * 500 / 10_000;
            Etf.Route[] memory r = _noRoutes(2);
            vm.prank(alice);
            f.redeem(s, r, 0, alice);
        }
        assertEq(f.balanceOf(alice), 0);
        assertEq(f.balanceOf(owner) + f.balanceOf(maker), fees, "every step's fee moved in shares");
        assertApproxEqAbs(fees, aliceShares * 500 / 10_000, 21, "5 % of her shares");
        assertApproxEqAbs(f.balanceOf(owner), fees * 3000 / 10_000, 42, "30 % to the factory's owner");
        uint256 got = a.balanceOf(alice) - aliceA;
        assertApproxEqAbs(got, Math.mulDiv(heldA, aliceShares - fees, supply), 100, "95 % of her part of leg A");
        assertEq(usdg.balanceOf(owner), ownerUsdg, "no USDG fee");
        assertEq(usdg.balanceOf(maker), makerUsdg);
    }

    /// A sale pushed to almost nothing (the router paying 1 % of the price, as a self-sandwich in the
    /// registered pool would) moves the same exit fee shares as no sale at all: the fee is taken in
    /// shares before the routes run.
    function test_AnExitFeeInSharesCannotBeShrunkByABadSale() public {
        Etf.Params memory p = _bare();
        p.exitFeeBps = 500;
        Etf f = _createWith("SAND", _two(address(a), address(b)), _bps2(5000, 5000), p);
        _mint(f, alice, 1000e6);
        uint256 snap = vm.snapshotState();
        Etf.Route[] memory none = _noRoutes(2);
        vm.prank(alice);
        f.redeem(100e18, none, 0, alice);
        uint256 fair = f.balanceOf(owner) + f.balanceOf(maker);
        vm.revertToState(snap);

        router.setPairRate(address(a), address(usdg), 250e6 / 100);
        router.setPairRate(address(b), address(usdg), 500e6 / 100);
        (uint256[] memory due,,,) = f.previewRedeemToUsdg(alice, 100e18);
        Etf.Route[] memory sells = _sellRoutes(f, due);
        vm.prank(alice);
        f.redeem(100e18, sells, 0, alice);
        assertEq(f.balanceOf(owner) + f.balanceOf(maker), fair, "the same fee shares");
        assertEq(fair, 5e18);
    }

    /// Leave `total` of `who`'s shares in `steps` equal redeems, in kind or through `redeem` with no
    /// route; returns leg A received and the shares moved to the two recipients.
    function _leave(Etf f, address who, uint256 total, uint256 steps, bool inKind) internal returns (uint256 got, uint256 moved) {
        uint256 before = a.balanceOf(who);
        Etf.Route[] memory r = _noRoutes(2);
        for (uint256 k = 0; k < steps; k++) {
            vm.prank(who);
            if (inKind) f.redeemInKind(total / steps, who, 0);
            else f.redeem(total / steps, r, 0, who);
        }
        got = a.balanceOf(who) - before;
        moved = f.balanceOf(owner) + f.balanceOf(maker);
    }

    /// The penalties are moved in shares like the exit fee, so leaving in pieces saves none of them:
    /// 990 of the fund's 1 000 shares redeemed at 5 % in 1, 10 or 100 redeems move exactly 49.5 shares
    /// to the recipients (30 / 70) and pay the same leg A to within rounding. The non-minter penalty on
    /// shares received by transfer, through `redeemInKind`; the early penalty on minted shares within
    /// the hold, through `redeem`.
    function test_AWhaleLeavingInOneTenOrAHundredRedeemsPaysTheSamePenalty() public {
        Etf.Params memory p = _bare();
        (p.holdPeriod, p.earlyPenaltyBps, p.nonMinterPenaltyBps) = (1 hours, 500, 500);
        Etf f = _createWith("PEN", _two(address(a), address(b)), _bps2(5000, 5000), p);
        _mint(f, alice, 1000e6);
        uint16[3] memory steps = [uint16(1), 10, 100];
        for (uint256 door = 0; door < 2; door++) {
            bool inKind = door == 0;
            uint256 start = vm.snapshotState();
            address who = alice;
            if (inKind) {
                vm.prank(alice);
                assertTrue(f.transfer(carol, 990e18)); // beyond carol's `mintOf`: the non-minter penalty
                who = carol;
            }
            uint256 got1;
            for (uint256 i = 0; i < 3; i++) {
                uint256 snap = vm.snapshotState();
                (uint256 got, uint256 moved) = _leave(f, who, 990e18, steps[i], inKind);
                assertEq(moved, 49.5e18, "5 % of 990, whatever the steps");
                assertEq(f.balanceOf(owner), 14.85e18, "30 % to the factory's owner");
                if (i == 0) got1 = got;
                assertApproxEqAbs(got, got1, 100, "the same leg A in 1, 10 or 100 redeems");
                vm.revertToState(snap);
            }
            vm.revertToState(start);
        }
    }

    /// The fee clock never stalls: emptied in the second of its first mint, a fund keeps its 0.001
    /// dead share, and a door a year later moves the clock and mints the year's 0.50 % of it (3e12
    /// and 2e12 share units). Bob, minting after, owes a second's fee one second later, not a year's.
    function test_AnIdleFundStillMovesItsClockAndTheNextMinterPaysNoIdleYear() public {
        Etf f = _createWith("IDLE", _two(address(a), address(b)), _bps2(5000, 5000), _bare());
        _mint(f, alice, 1000e6);
        uint256 out = f.balanceOf(alice);
        vm.prank(alice);
        f.redeemInKind(out, alice, 0);
        assertEq(f.totalSupply(), f.DEAD_SHARES(), "never back to 0");
        vm.warp(block.timestamp + 365 days);
        f.rebalance(new Etf.Route[](0));
        assertEq(f.lastAccrualAt(), block.timestamp, "the clock moved");
        assertEq(f.balanceOf(maker), 3e12, "0.30 % of 1e15 for the year");
        assertEq(f.balanceOf(owner), 2e12, "0.20 %");

        uint256 shares = _mint(f, bob, 1000e6);
        vm.warp(block.timestamp + 1);
        (uint256 c, uint256 pr) = f.pendingManagementFee();
        assertLt(c + pr, shares / 1e8, "a second's fee on his shares, not a year's");
    }

    /// Nobody takes what an emptied fund holds: a 20 % non-minter penalty goes in shares to the
    /// recipients (the fund is not empty), and once they leave too the dead shares own what is left.
    /// A leftover (one A donated, 250 USDG) is no holding: Bob's 10 USDG mint takes the in-kind formula
    /// on what the fund counts, his shares claim no more A than he brought, and the A donated stays
    /// outside every share, rescuable.
    function test_TheNextMinterOfAnEmptiedFundTakesNoneOfItsLeftovers() public {
        Etf.Params memory p = _bare();
        p.nonMinterPenaltyBps = 2000;
        Etf f = _createWith("LEFT", _two(address(a), address(b)), _bps2(5000, 5000), p);
        _mint(f, alice, 1000e6);
        uint256 all = f.balanceOf(alice);
        vm.prank(alice);
        assertTrue(f.transfer(carol, all));
        vm.prank(carol);
        f.redeemInKind(all, carol, 0);
        assertEq(f.balanceOf(owner) + f.balanceOf(maker), all * 2000 / 10_000, "the penalty in shares, theirs");
        assertEq(f.totalSupply(), f.DEAD_SHARES() + all * 2000 / 10_000);
        address[2] memory recipients = [owner, maker];
        for (uint256 i = 0; i < 2; i++) {
            uint256 s = f.balanceOf(recipients[i]);
            vm.prank(recipients[i]);
            f.redeemInKind(s, recipients[i], 0);
        }
        assertEq(f.totalSupply(), f.DEAD_SHARES(), "only the dead shares left");

        uint256 heldA = f.legHeld(0);
        a.mint(address(f), 1e18); // a leftover: 250 USDG of A
        assertEq(f.legHeld(0), heldA, "a donation is no holding");
        Etf.Route[] memory r = _buyRoutes(f, 10e6, false);
        uint256 bought = _out(address(usdg), address(a), r[0].amountIn);
        vm.prank(bob);
        uint256 shares = f.mint(10e6, r, 1);
        uint256 claimA = Math.mulDiv(shares, f.legHeld(0), f.totalSupply());
        assertLe(claimA, bought, "no more A than his route bought");
        assertEq(f.rescuable(address(a)), 1e18, "the leftover outside every share");
    }

    /// A griefer who first-mints 1 USDG, leaves at once and donates 10 000 USDG of legs moves nothing:
    /// no count rises, so Bob's 1 USDG mint gets the shares he would have got without the donation and
    /// keeps what his shares claim to 0.01 %; the donation stays outside, rescuable.
    function test_ADustSupplyCannotPriceSmallMintsOut() public {
        Etf f = _createWith("GRIEF", _two(address(a), address(b)), _bps2(5000, 5000), _bare());
        _mint(f, alice, 1e6);
        uint256 out = f.balanceOf(alice);
        vm.prank(alice);
        f.redeemInKind(out, alice, 0);
        uint256 snap = vm.snapshotState();
        uint256 fair = _mint(f, bob, 1e6);
        vm.revertToState(snap);
        a.mint(address(f), 20e18);
        b.mint(address(f), 10e18);
        uint256 heldA = f.legHeld(0);
        uint256 heldB = f.legHeld(1);
        uint256 shares = _mint(f, bob, 1e6);
        assertEq(shares, fair, "the donation moved no share's price");
        uint256 supply = f.totalSupply();
        uint256 keptA = f.legHeld(0) - heldA;
        uint256 keptB = f.legHeld(1) - heldB;
        assertApproxEqRel(Math.mulDiv(shares, f.legHeld(0), supply), keptA, 1e14, "his A, claimed back");
        assertApproxEqRel(Math.mulDiv(shares, f.legHeld(1), supply), keptB, 1e14, "his B");
        assertEq(f.rescuable(address(a)), 20e18);
        assertEq(f.rescuable(address(b)), 10e18);
    }

    /// A leg whose `balanceOf` reverts (an issuer's upgrade, a destroyed proxy logic) never closes
    /// `redeemInKind`, and no longer costs the holder that leg: it is paid from its count when its
    /// `transfer` still works, `allowFail` 0; when the transfer fails too, it is named forfeited (bit
    /// 1) whatever `allowFail` says, its holding staying in the fund and in its count; leg A and the fee
    /// shares are paid as before.
    function test_ALegWhoseBalanceReadRevertsIsStillPaidFromItsCount() public {
        BrickableTokenMock brick = new BrickableTokenMock();
        brick.mint(address(router), 1e30);
        PoolMock pk = _pool(address(brick), _tickAt(100e18));
        vm.prank(owner);
        factory.addToken(address(brick), address(pk));
        _routerAt(address(brick), 100e18);
        Etf f = _create("BRB", _two(address(a), address(brick)), _bps2(5000, 5000));
        _mint(f, alice, 1000e6);
        _mint(f, bob, 1000e6);
        uint256 shares = f.balanceOf(alice);
        (, uint256 feeShares, uint256 penaltyShares, uint256[] memory amounts,) = f.previewRedeem(alice, shares);
        uint256 moved = feeShares + penaltyShares;
        uint256 brickHeld = brick.balanceOf(address(f));
        brick.brick(true, false, false);

        vm.expectEmit(true, true, false, true, address(f));
        emit Etf.RedeemedInKind(alice, alice, shares, moved * 3000 / 10_000, moved - moved * 3000 / 10_000, shares, penaltyShares, 0, amounts, 0, 0);
        vm.prank(alice);
        f.redeemInKind(shares, alice, 0);
        assertEq(a.balanceOf(alice), amounts[0]);
        brick.brick(false, false, false);
        assertEq(brick.balanceOf(alice), amounts[1], "the unread leg paid from its count");
        assertEq(f.legHeld(1), brickHeld - amounts[1]);

        shares = f.balanceOf(bob);
        (, feeShares, penaltyShares, amounts,) = f.previewRedeem(bob, shares);
        moved = feeShares + penaltyShares;
        uint256 left = brick.balanceOf(address(f));
        brick.brick(true, true, false);
        uint256[] memory paid = new uint256[](2);
        paid[0] = amounts[0];
        vm.expectEmit(true, true, false, true, address(f));
        emit Etf.RedeemedInKind(bob, bob, shares, moved * 3000 / 10_000, moved - moved * 3000 / 10_000, shares, penaltyShares, 0, paid, 0, 2);
        vm.prank(bob);
        f.redeemInKind(shares, bob, 0);
        assertEq(a.balanceOf(bob), amounts[0]);
        brick.brick(false, false, false);
        assertEq(brick.balanceOf(address(f)), left, "unread and untransferable: stays in the fund");
        assertEq(f.legHeld(1), left, "and in its count");
    }

    /// One USDG unit donated to a fund holding none no longer caps later mints: no count rises, so a
    /// mint whose routes spend all its net runs, and the unit stays outside, rescuable.
    function test_AUsdgDonationNoLongerRevertsAMintThatRoutesAllItsNet() public {
        Etf f = _create("DUSTU", _two(address(a), address(b)), _bps2(5000, 5000));
        _mint(f, alice, 1000e6);
        assertEq(usdg.balanceOf(address(f)), 0);
        usdg.mint(address(f), 1);
        assertEq(f.usdgHeld(), 0);
        (uint256 fee,,) = f.entryFee(100e6);
        uint256 net = 100e6 - fee;
        Etf.Route[] memory r = new Etf.Route[](2);
        r[0] = _swapRoute(0, false, net / 2);
        r[1] = _swapRoute(1, false, net - net / 2);
        vm.prank(bob);
        assertGt(f.mint(100e6, r, 1), 0, "every unit of the net routed");
        assertEq(f.usdgHeld(), 0);
        assertEq(f.rescuable(address(usdg)), 1);
    }

    /// The factory lists no token whose price quote could overflow: a quote is of
    /// `10 ** (decimals + 12)` raw units against USDG's 6, and Uniswap's highest price is under 2^128,
    /// so 26 decimals (1e38 units) is the most that fits 256 bits. A 26-decimal token whose pool sits
    /// at tick 887 000 lists and prices; the same quote at 27 decimals reverts in the oracle; a
    /// 27-decimal token is refused.
    function test_TheFactoryListsNoTokenWhosePriceQuoteCouldOverflow() public {
        assertEq(factory.MAX_TOKEN_DECIMALS(), 26);
        TokenMock t26 = new TokenMock("T26", "T26", 26);
        PoolMock p26 = _pool(address(t26), 887_000);
        vm.prank(owner);
        factory.addToken(address(t26), address(p26));
        (uint256 price, uint8 source) = factory.getPriceUsdg(address(t26));
        assertEq(source, SOURCE_POOL);
        assertGt(price, 1e76, "near the top of what a pool can say");

        MaidMarianBagPoolOracle oracle = factory.POOL_ORACLE();
        vm.expectRevert();
        oracle.tryQuote(address(p26), 1e39, address(t26), address(usdg));

        TokenMock t27 = new TokenMock("T27", "T27", 27);
        PoolMock p27 = _pool(address(t27), 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Factory.BadToken.selector, address(t27)));
        factory.addToken(address(t27), address(p27));
    }

    /// An ETF's NAV, for its parent, is divided by its supply once its management fee is minted
    /// (`accruedSupply()`): a child idle for a year is priced 0.50 % under its legs per share now,
    /// and the same after a door mints that fee.
    function test_AnEtfsNavCountsItsPendingManagementFee() public {
        Etf kid = _create("KID", _two(address(a), address(b)), _bps2(5000, 5000));
        _mint(kid, alice, 1000e6);
        vm.warp(block.timestamp + 365 days);
        (uint256 price, uint8 source) = factory.getPriceUsdg(address(kid));
        assertEq(source, SOURCE_NAV);
        (uint256 priceA,) = factory.getPriceUsdg(address(a));
        (uint256 priceB,) = factory.getPriceUsdg(address(b));
        uint256 value = usdg.balanceOf(address(kid)) * 1e12 + Math.mulDiv(a.balanceOf(address(kid)), priceA, 1e18) + Math.mulDiv(b.balanceOf(address(kid)), priceB, 1e18);
        assertEq(price, Math.mulDiv(value, 1e18, kid.accruedSupply()));
        assertApproxEqRel(price, Math.mulDiv(value, 1e18, kid.totalSupply()) * 9950 / 10_000, 1e14, "0.50 % a year under");
        kid.rebalance(new Etf.Route[](0));
        (uint256 after_,) = factory.getPriceUsdg(address(kid));
        assertEq(after_, price, "the same once the fee is minted");
    }
}
