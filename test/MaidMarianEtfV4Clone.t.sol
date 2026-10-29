// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { MaidMarianEtfFactoryV4 as Factory } from "../src/MaidMarianEtfFactoryV4.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { MaidMarianEtfV4 as Etf, etfV4CloneArgs } from "../src/MaidMarianEtfV4.sol";
import { SOURCE_NONE } from "../src/MaidMarianEtfV3.sol";
import { TokenMock, PoolMock } from "./Mocks.sol";
import { EtfV4BisBase } from "./MaidMarianEtfV4Bis.t.sol";

/**
 * Gas of `createEtf` and of every door, each call measured with every account it touches cooled
 * first (`vm.cool`), so a call pays its cold reads as in its own transaction. On mocks: the numbers
 * compare two builds of the contracts, not the chain's prices.
 */
contract MaidMarianEtfV4GasTest is EtfV4BisBase {
    TokenMock[] internal extra;
    PoolMock[] internal extraPools;

    function _cool(address etf_) internal {
        address[13] memory touched = [
            etf_,
            address(factory),
            address(usdg),
            address(a),
            address(b),
            address(c),
            address(pa),
            address(pb),
            address(pc),
            address(router),
            router.poolManager(),
            address(factory.POOL_ORACLE()),
            address(factory.ETF_IMPLEMENTATION())
        ];
        for (uint256 i = 0; i < touched.length; i++) {
            if (touched[i] != address(0)) vm.cool(touched[i]);
        }
        for (uint256 i = 0; i < extra.length; i++) {
            vm.cool(address(extra[i]));
            vm.cool(address(extraPools[i]));
        }
    }

    function _legsN(uint256 n) internal returns (Factory.LegSpec[] memory l) {
        uint256[7] memory prices = [uint256(100), 200, 400, 50, 1000, 80, 20];
        while (extra.length < 7) {
            (TokenMock t, PoolMock p) = _token(string.concat("X", vm.toString(extra.length)), prices[extra.length]);
            extra.push(t);
            extraPools.push(p);
        }
        address[10] memory all =
            [address(a), address(b), address(c), address(extra[0]), address(extra[1]), address(extra[2]), address(extra[3]), address(extra[4]), address(extra[5]), address(extra[6])];
        l = new Factory.LegSpec[](n);
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            l[i] = Factory.LegSpec({ token: all[i], bps: uint16(10_000 / n) });
            sum += 10_000 / n;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        l[0].bps += uint16(10_000 - sum);
    }

    function _createGas(string memory symbol, bytes memory logo, Factory.LegSpec[] memory l) internal returns (uint256 used) {
        _cool(address(0));
        vm.prank(maker);
        uint256 g = gasleft();
        factory.createEtf{ value: FEE }(string.concat("Maid Marian ", symbol), symbol, logo, l, _params(), _noProfile());
        used = g - gasleft();
    }

    /// `createEtf` with 1 leg and no logo, 4 legs, 10 legs, and 1 leg with a 16 KiB logo.
    function test_gas_CreateEtf() public {
        Factory.LegSpec[] memory one = _legsN(1);
        emit log_named_uint("createEtf, 1 leg, no logo", _createGas("G1", "", one));
        emit log_named_uint("createEtf, 4 legs, no logo", _createGas("G4", "", _legsN(4)));
        emit log_named_uint("createEtf, 10 legs, no logo", _createGas("G10", "", _legsN(10)));
        emit log_named_uint("createEtf, 1 leg, 16 KiB logo", _createGas("GL", _png(256, 256, 16_384), one));
    }

    /// Every door of a three-leg ETF, in the parity test's order.
    function test_gas_EveryDoor() public {
        (address[] memory t, uint16[] memory w) = _legs3();
        Etf etf = _create("GAS", t, w);
        _approveLegs(alice, address(etf));
        _approveLegs(bob, address(etf));
        _approveLegs(carol, address(etf));

        Etf.Route[] memory r = _buyRoutes(etf, 1000e6, true);
        _cool(address(etf));
        vm.prank(alice);
        uint256 g = gasleft();
        etf.mint(1000e6, r, 1);
        emit log_named_uint("mint, first", g - gasleft());

        vm.warp(vm.getBlockTimestamp() + 1 days);
        r = _buyRoutes(etf, 500e6, false);
        _cool(address(etf));
        vm.prank(bob);
        g = gasleft();
        etf.mint(500e6, r, 1);
        emit log_named_uint("mint", g - gasleft());

        (uint256[] memory need,) = etf.quoteMint(50e18);
        a.mint(bob, need[0]);
        b.mint(bob, need[1]);
        c.mint(bob, need[2]);
        _cool(address(etf));
        vm.prank(bob);
        g = gasleft();
        etf.mintInKind(need, 0, 1);
        emit log_named_uint("mintInKind", g - gasleft());

        pa.setAverageTick(address(a) < address(usdg) ? _tickAt(300e18) : -_tickAt(300e18));
        _routerAt(address(a), 300e18);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        Etf.Route[] memory plan = _planRoutes(etf.plan());
        _cool(address(etf));
        vm.prank(carol);
        g = gasleft();
        etf.rebalance(plan);
        emit log_named_uint("rebalance", g - gasleft());

        (uint256[] memory due,,,) = etf.previewRedeemToUsdg(alice, 200e18);
        for (uint256 i = 0; i < 3; i++) {
            due[i] /= 2;
        }
        Etf.Route[] memory sell = _sellRoutes(etf, due);
        _cool(address(etf));
        vm.prank(alice);
        g = gasleft();
        etf.redeem(200e18, sell, 0, alice);
        emit log_named_uint("redeem", g - gasleft());

        _cool(address(etf));
        vm.prank(bob);
        g = gasleft();
        etf.redeemInKind(5e18, bob, 0);
        emit log_named_uint("redeemInKind", g - gasleft());
    }
}

/**
 * Each ETF is a clone of the factory's one implementation, its legs, parameters, name and symbol
 * appended to its code: what the clone carries, who may initialize it and when, and the locked
 * implementation. On mocks; the clone's code is the EVM's, the same on the chain.
 */
contract MaidMarianEtfV4CloneTest is EtfV4BisBase {
    Etf internal etf;
    Etf internal impl;

    function setUp() public override {
        super.setUp();
        (address[] memory t, uint16[] memory w) = _legs3();
        etf = _create("CLN", t, w);
        impl = factory.ETF_IMPLEMENTATION();
    }

    /// The clone's code is the 45-byte EIP-1167 proxy to the implementation, then `etfV4CloneArgs` of what
    /// `createEtf` was given, the decimals read by the factory.
    function test_ACloneIsTheMinimalProxyToTheImplementationAndItsArguments() public view {
        bytes memory proxy = abi.encodePacked(hex"363d3d373d3d3d363d73", address(impl), hex"5af43d82803e903d91602b57fd5bf3");
        (address[] memory t, uint16[] memory w) = _legs3();
        Etf.LegInit[] memory l = new Etf.LegInit[](3);
        for (uint256 i = 0; i < 3; i++) {
            l[i] = Etf.LegInit({ token: t[i], bps: w[i], decimals: 18 });
        }
        bytes memory args = etfV4CloneArgs("Maid Marian CLN", "CLN", l, _params());
        assertEq(address(etf).code, abi.encodePacked(proxy, args));
        assertEq(Clones.fetchCloneArgs(address(etf)), args);
    }

    /// Every per-ETF value answers under its getter, per clone: two ETFs of one implementation
    /// keep their own name, symbol, legs and parameters.
    function test_EachCloneAnswersItsOwnNameSymbolLegsAndParams() public {
        Etf.Params memory p =
            Etf.Params({ entryFeeBps: 500, exitFeeBps: 400, holdPeriod: 30 days, earlyPenaltyBps: 777, nonMinterPenaltyBps: 9600, rebalanceBandBps: 5000, rebalanceMinInterval: 24 hours });
        Etf other = _createWith("OTHER2", _one(address(b)), _all(), p);
        assertEq(etf.name(), "Maid Marian CLN");
        assertEq(etf.symbol(), "CLN");
        assertEq(other.name(), "Maid Marian OTHER2");
        assertEq(other.symbol(), "OTHER2");
        assertEq(etf.decimals(), 18);
        assertEq(abi.encode(etf.params()), abi.encode(_params()));
        assertEq(abi.encode(other.params()), abi.encode(p));
        assertEq(
            abi.encode(
                other.LEGS(),
                other.ENTRY_FEE_BPS(),
                other.EXIT_FEE_BPS(),
                other.HOLD_PERIOD(),
                other.EARLY_PENALTY_BPS(),
                other.NON_MINTER_PENALTY_BPS(),
                other.REBALANCE_BAND_BPS(),
                other.REBALANCE_MIN_INTERVAL()
            ),
            abi.encode(1, 500, 400, 30 days, 777, 9600, 5000, 24 hours)
        );
        assertEq(etf.LEGS(), 3);
        Etf.Leg[] memory l = etf.legs();
        (address[] memory t, uint16[] memory w) = _legs3();
        for (uint256 i = 0; i < 3; i++) {
            assertEq(abi.encode(l[i].token, l[i].bps, l[i].decimals), abi.encode(t[i], w[i], 18));
        }
        assertEq(other.legs()[0].token, address(b));
        assertEq(address(etf.FACTORY()), address(factory));
        assertEq(address(etf.USDG()), address(usdg));
        assertEq(address(etf.UNIVERSAL_ROUTER()), address(router));
        assertEq(address(other.FACTORY()), address(factory));
    }

    /// The longest name and symbol the factory accepts, and ten legs, read back whole.
    function test_TheLongestNameAndSymbolAndTenLegsReadBack() public {
        string memory longName = "Ab-.&' 0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRS";
        assertEq(bytes(longName).length, 64);
        address[] memory t = new address[](10);
        uint16[] memory w = new uint16[](10);
        for (uint256 i = 0; i < 10; i++) {
            (TokenMock x,) = _token(string.concat("T", vm.toString(i)), 100);
            (t[i], w[i]) = (address(x), 1000);
        }
        vm.prank(maker);
        Etf e = factory.createEtf{ value: FEE }(longName, "ABCDEFGHIJK", "", _spec(t, w), _params(), _noProfile());
        assertEq(e.name(), longName);
        assertEq(e.symbol(), "ABCDEFGHIJK");
        Etf.Leg[] memory l = e.legs();
        assertEq(l.length, 10);
        for (uint256 i = 0; i < 10; i++) {
            assertEq(l[i].token, t[i]);
            assertEq(l[i].bps, 1000);
        }
    }

    /// Only the factory initializes a clone, and `createEtf` already did: a second call reverts, from the
    /// factory as from anyone.
    function test_OnlyTheFactoryInitializesACloneAndOnlyOnce() public {
        vm.prank(alice);
        vm.expectRevert(Etf.NotFactory.selector);
        etf.initialize(alice);
        vm.prank(address(factory));
        vm.expectRevert(Etf.AlreadyInitialized.selector);
        etf.initialize(alice);
        assertEq(etf.creator(), maker);
        assertEq(etf.feeRecipient(), maker);
    }

    /// The implementation was locked at construction: not even its factory initializes it, and every door
    /// refuses to run on it; it holds nothing and its creator is nobody.
    function test_TheImplementationIsLockedAndRefusesEveryDoor() public {
        vm.prank(address(factory));
        vm.expectRevert(Etf.AlreadyInitialized.selector);
        impl.initialize(alice);
        vm.prank(alice);
        vm.expectRevert(Etf.NotFactory.selector);
        impl.initialize(alice);
        Etf.Route[] memory none = new Etf.Route[](0);
        vm.startPrank(alice);
        vm.expectRevert(Etf.NotAClone.selector);
        impl.mint(1e6, none, 0);
        vm.expectRevert(Etf.NotAClone.selector);
        impl.mintInKind(new uint256[](0), 0, 0);
        vm.expectRevert(Etf.NotAClone.selector);
        impl.redeem(1, none, 0, alice);
        vm.expectRevert(Etf.NotAClone.selector);
        impl.redeemInKind(1, alice, 0);
        vm.expectRevert(Etf.NotAClone.selector);
        impl.rebalance(none);
        vm.expectRevert(Etf.NotCreator.selector);
        impl.setCreator(alice);
        vm.expectRevert(Etf.NotCreator.selector);
        impl.setFeeRecipient(alice);
        vm.stopPrank();
        assertEq(impl.creator(), address(0));
        assertEq(impl.totalSupply(), 0);
        assertEq(address(impl.FACTORY()), address(factory));
    }

    /// A fresh clone's guard is set, not left at 0: `entered()` is false, the slot holds NOT_ENTERED (1),
    /// and the first door runs and leaves it at 1. A door inside a door still reverts
    /// (`test_NoNavIsGivenForAnEtfInsideItsOwnDoor`).
    function test_AFreshClonesReentrancyGuardIsSetAndItsFirstDoorRuns() public {
        bytes32 slot = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
        assertEq(uint256(vm.load(address(etf), slot)), 1);
        assertFalse(etf.entered());
        _mint(etf, alice, 1000e6);
        assertEq(uint256(vm.load(address(etf), slot)), 1);
        assertGt(etf.balanceOf(alice), 0);
    }

    /// `isEtf` holds for the factory's clones only: not the implementation, and not a clone of it made by
    /// anyone else, which nobody can initialize and the factory never prices at a NAV.
    function test_IsEtfHoldsOnlyForTheFactorysOwnClones() public {
        assertTrue(factory.isEtf(address(etf)));
        assertFalse(factory.isEtf(address(impl)));
        Etf rogue = Etf(Clones.cloneWithImmutableArgs(address(impl), Clones.fetchCloneArgs(address(etf))));
        assertFalse(factory.isEtf(address(rogue)));
        vm.expectRevert(Etf.NotFactory.selector);
        rogue.initialize(address(this));
        assertEq(rogue.creator(), address(0));
        (, uint8 source) = factory.getPriceUsdg(address(rogue));
        assertEq(source, SOURCE_NONE);
    }

    /// The logo and the profile stay the factory's, keyed by the clone's address.
    function test_TheLogoAndTheProfileAreTheClonesOwn() public {
        bytes memory png = _png(64, 64, 1000);
        vm.prank(maker);
        Etf e = factory.createEtf{ value: FEE }(
            "Logo", "LG", png, _spec(_two(address(a), address(b)), _bps2(5000, 5000)), _params(), Factory.Profile({ description: "Kept.", x: "", telegram: "", website: "" })
        );
        assertEq(e.logo(), png);
        assertEq(etf.logo(), "");
        (string memory d,,,,) = factory.profileOf(address(e));
        assertEq(d, "Kept.");
    }
}
