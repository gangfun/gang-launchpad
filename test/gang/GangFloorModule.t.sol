// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {GasBurnQuote} from "./GangSplitModule.t.sol";
import {GangFloorModule} from "../../src/gang/GangFloorModule.sol";
import {GangFloorModuleFactory} from "../../src/gang/GangFloorModuleFactory.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";

/// @dev The floor module on the whole merged deployment, on GangLaunchpad 3.0 with its CREATE2 (abcd) deployer on: the
///      factory clones a module only there (audit 2026-11-11 M-1), for the address the token will have.
abstract contract FloorBase is GangFixture {
    address keeper = makeAddr("keeper");
    GangHandlerAdmin admin;
    GangFloorModuleFactory factory;
    uint256 _salt;
    Pad3VanityDeployer vanity;
    /// @dev The token planned by `_nextToken` and not created yet.
    uint256 _names;
    string _planName;
    bytes32 _planSalt;
    address _planDev;

    string constant CREATE_SIG = "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))";
    uint16 constant TAX = 300;
    uint16 constant FEE = 200;
    uint256 constant ALL = type(uint256).max;
    address constant GANG = address(0x6A46);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function _newPad() internal virtual override returns (GangLaunchpad) {
        return _newPad3();
    }

    function _deployFloor() internal {
        _deployGang(keeper);
        vanity = new Pad3VanityDeployer(address(pad), address(tokenDeployer), address(flyDeployer));
        vm.prank(owner);
        Pad3Module(payable(address(pad))).enableVanity(address(vanity));
        admin = new GangHandlerAdmin(owner, address(handler));
        vm.startPrank(owner);
        handler.transferOwnership(address(admin));
        admin.exec(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        vm.stopPrank();
        factory = new GangFloorModuleFactory(address(pad), address(admin), GANG);
        vm.prank(owner);
        admin.setFactory(address(factory), true);
    }

    function _list(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        (p[0], p[1]) = (a, b);
    }

    function _shares(uint16 a, uint16 b) internal pure returns (uint16[] memory s) {
        s = new uint16[](2);
        (s[0], s[1]) = (a, b);
    }

    /// @dev As Pad3VanityTest's `_mine`: the first user salt whose address ends in abcd.
    function _mine(bytes32 initHash, address dev) internal view returns (bytes32 salt, address predicted) {
        address deployer = address(vanity);
        bytes memory buffer = new bytes(85);
        for (uint256 i;; i++) {
            uint256 hash;
            assembly ("memory-safe") {
                let ptr := add(buffer, 32)
                mstore(ptr, dev)
                mstore(add(ptr, 32), i)
                let effectiveSalt := keccak256(ptr, 64)
                mstore(ptr, shl(248, 0xff))
                mstore(add(ptr, 1), shl(96, deployer))
                mstore(add(ptr, 21), effectiveSalt)
                mstore(add(ptr, 53), initHash)
                hash := keccak256(ptr, 85)
            }
            if (uint16(hash) == 0xabcd) return (bytes32(i), address(uint160(hash)));
        }
    }

    /// @dev Plan `dev`'s next token (a fresh name, the suite's tax rates) and return the address it will have: what
    ///      the dev computes before cloning the module. `_createT` by the same dev then creates it there.
    function _nextToken(address dev) internal returns (address predicted) {
        _planName = string.concat("Floor", vm.toString(++_names));
        bytes32 h = vanity.tokenInitCodeHash(_planName, "CRV", "meta", address(handler), TAX, TAX, false);
        (_planSalt, predicted) = _mine(h, dev);
        _planDev = dev;
    }

    /// @dev Create the token `creator` planned (or, with none planned, a fresh one) through the abcd deployer.
    function _createT(address creator, address quote, IGangLaunchpad.TaxConfig memory tax)
        internal
        returns (address t)
    {
        if (_planDev != creator) _nextToken(creator);
        bytes memory data =
            abi.encodeWithSignature(CREATE_SIG, _planName, "CRV", "logo", "meta", quote, address(0), tax);
        delete _planDev;
        vm.prank(creator);
        t = Pad3Module(payable(address(pad))).createWithSalt(_planSalt, data);
    }

    function _floor(
        address dev,
        address tok,
        address q,
        uint256 cap,
        uint16 pay,
        uint16 fee,
        address[] memory p,
        uint16[] memory s
    ) internal returns (GangFloorModule m) {
        vm.prank(dev);
        m = GangFloorModule(factory.create(tok, q, cap, pay, fee, p, s, bytes32(++_salt)));
    }

    function _noPayees(address dev, address tok, address q, uint16 fee) internal returns (GangFloorModule m) {
        return _floor(dev, tok, q, 0, 0, fee, new address[](0), new uint16[](0));
    }

    /// @dev A fresh Agent that bought on the curve (the 1% wallet cap truncates) and approved the module.
    function _holder(address t, GangFloorModule m) internal returns (address who) {
        who = _newAgent();
        vm.startPrank(who);
        pad.buy(t, 1 ether, 0);
        IERC20(t).approve(address(m), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Cap `cap`, 50% to the payees (the dev 70%, a KOL 30%) until it is reached, the rest to the treasury, a 2%
    ///      redemption fee; a taxed V3 token over `quote` pays it; `alice` holds some.
    function _setup(address quote, uint256 cap, bool grad)
        internal
        returns (GangFloorModule m, address t, address dev, address kol, address alice)
    {
        dev = _newAgent();
        kol = makeAddr(string.concat("kol", vm.toString(_salt)));
        m = _floor(dev, _nextToken(dev), quote, cap, 5_000, FEE, _list(dev, kol), _shares(7_000, 3_000));
        t = _createT(dev, quote, _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t);
        alice = _holder(t, m);
        if (grad) _graduate(t);
    }

    /// @dev No payees: all of the quote is the treasury; graduated; `alice` and `bob` hold some.
    function _setupPure(address quote, uint16 fee)
        internal
        returns (GangFloorModule m, address t, address alice, address bob)
    {
        address dev = _newAgent();
        m = _noPayees(dev, _nextToken(dev), quote, fee);
        t = _createT(dev, quote, _tax(TAX, TAX, 0, address(m)));
        m.bind(t);
        alice = _holder(t, m);
        bob = _holder(t, m);
        _graduate(t);
    }

    function _next(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(block.number + 1);
    }

    function _bal(address asset, address who) internal view returns (uint256) {
        return IERC20(asset).balanceOf(who);
    }

    /// @dev `_quoteFor`, recomputed here.
    function _quoteFor(uint256 amount, uint256 held, uint256 supply, uint256 fee)
        internal
        pure
        returns (uint256 out, uint256 feeAmt)
    {
        uint256 gross = (amount * held) / supply;
        feeAmt = (gross * fee) / 10_000;
        out = gross - feeAmt;
    }
}

/// @notice GangFloorModule (底价赎回): the factory's checks, binding only the token fixed at clone, the split before,
///         across and after the cap, redemptions to the wei (the fee stays, the floor never falls), the guards, the
///         decoy that gains nothing, payees, other assets, shortfalls, the keeper, the pool tax end to end.
contract GangFloorModuleTest is FloorBase {
    function setUp() public {
        _deployFloor();
    }

    function newFactory(address pad_, address admin_) external returns (GangFloorModuleFactory) {
        return new GangFloorModuleFactory(pad_, admin_, GANG);
    }

    // ---------------------------------------------------------------- factory
    function test_factory_checks() public {
        vm.expectRevert(GangFloorModuleFactory.ZeroAddress.selector);
        this.newFactory(address(pad), address(0));
        GangHandlerAdmin elsewhere = new GangHandlerAdmin(owner, makeAddr("otherHandler"));
        vm.expectRevert(GangFloorModuleFactory.WrongHandler.selector);
        this.newFactory(address(pad), address(elsewhere));

        address dev = _newAgent();
        address b = makeAddr("b");
        address w = address(wbnb);
        address tok = address(uint160(0x7777abcd));
        address[] memory two = _list(dev, b);
        uint16[] memory half = _shares(5_000, 5_000);
        address[] memory none = new address[](0);
        uint16[] memory noneS = new uint16[](0);
        vm.prank(makeAddr("notAgent"));
        vm.expectRevert(GangFloorModuleFactory.NotAgent.selector);
        factory.create(tok, w, 1 ether, 5_000, FEE, two, half, bytes32(0));

        vm.startPrank(dev);
        vm.expectRevert(GangFloorModuleFactory.BadToken.selector); // not an abcd address (0 too)
        factory.create(address(0), w, 1 ether, 5_000, FEE, two, half, bytes32(0));
        vm.expectRevert(GangFloorModuleFactory.BadToken.selector);
        factory.create(makeAddr("tok"), w, 1 ether, 5_000, FEE, two, half, bytes32(0));
        vm.expectRevert(GangFloorModule.ZeroAddress.selector);
        factory.create(tok, address(0), 1 ether, 5_000, FEE, two, half, bytes32(0));
        vm.expectRevert(GangFloorModule.BadQuote.selector);
        factory.create(tok, makeAddr("devsOwnQuote"), 1 ether, 5_000, FEE, two, half, bytes32(0));
        vm.expectRevert(GangFloorModule.BadBps.selector);
        factory.create(tok, w, 1 ether, 10_001, FEE, two, half, bytes32(0));
        vm.expectRevert(GangFloorModule.BadBps.selector); // D-1: at most 5%
        factory.create(tok, w, 1 ether, 5_000, 501, two, half, bytes32(0));
        vm.expectRevert(GangFloorModule.BadCap.selector); // payees need a cap
        factory.create(tok, w, 0, 5_000, FEE, two, half, bytes32(0));
        vm.expectRevert(GangFloorModule.BadCap.selector); // no payees: no cap
        factory.create(tok, w, 1 ether, 0, FEE, none, noneS, bytes32(0));
        vm.expectRevert(GangFloorModule.BadPayees.selector); // no payees: no list
        factory.create(tok, w, 0, 0, FEE, two, half, bytes32(0));
        vm.expectRevert(GangFloorModule.BadPayees.selector); // payees: a list
        factory.create(tok, w, 1 ether, 5_000, FEE, none, noneS, bytes32(0));
        vm.expectRevert(GangFloorModule.BadPayees.selector);
        factory.create(tok, w, 1 ether, 5_000, FEE, two, new uint16[](1), bytes32(0));
        address[] memory eleven = new address[](11);
        uint16[] memory elevenS = new uint16[](11);
        for (uint256 i; i < 11; i++) {
            eleven[i] = address(uint160(0x1000 + i));
            elevenS[i] = i == 0 ? 1_000 : 900;
        }
        vm.expectRevert(GangFloorModule.BadPayees.selector);
        factory.create(tok, w, 1 ether, 5_000, FEE, eleven, elevenS, bytes32(0));
        vm.expectRevert(GangFloorModule.ZeroAddress.selector);
        factory.create(tok, w, 1 ether, 5_000, FEE, _list(dev, address(0)), half, bytes32(0));
        vm.expectRevert(GangFloorModule.DuplicatePayee.selector);
        factory.create(tok, w, 1 ether, 5_000, FEE, _list(dev, dev), half, bytes32(0));
        vm.expectRevert(GangFloorModule.BadShares.selector);
        factory.create(tok, w, 1 ether, 5_000, FEE, two, _shares(10_000, 0), bytes32(0));
        vm.expectRevert(GangFloorModule.BadShares.selector);
        factory.create(tok, w, 1 ether, 5_000, FEE, two, _shares(5_000, 4_999), bytes32(0));
        vm.stopPrank();

        bytes32 salt = keccak256("launch-1");
        address predicted = factory.predict(dev, salt);
        vm.expectEmit(address(factory));
        emit GangFloorModuleFactory.Created(dev, predicted, tok, w, 20 ether, 10_000, 500, two, _shares(6_000, 4_000));
        vm.prank(dev);
        GangFloorModule m =
            GangFloorModule(factory.create(tok, w, 20 ether, 10_000, 500, two, _shares(6_000, 4_000), salt));
        assertEq(address(m), predicted);
        assertEq(m.moduleType(), bytes32("floor-v1"));
        assertEq(m.dev(), dev);
        assertEq(m.floorToken(), tok);
        assertEq(m.token(), address(0), "not bound yet");
        assertEq(m.quote(), address(0));
        assertEq(m.floorQuote(), w);
        assertEq(m.capAmount(), 20 ether);
        assertEq(m.payBps(), 10_000);
        assertEq(m.redeemFeeBps(), 500);
        assertEq(m.paidTotal(), 0);
        assertEq(m.capLeft(), 20 ether);
        assertFalse(m.capReached());
        (address[] memory ps, uint16[] memory ss) = m.payeesOf();
        assertEq(ps.length, 2);
        assertEq(ss[0], 6_000);
        assertTrue(handler.isListed(address(m)));
        assertEq(factory.count(), 1);
        assertEq(factory.modules()[0], address(m));

        // the same salt again: that address is taken
        vm.prank(dev);
        vm.expectRevert();
        factory.create(tok, w, 20 ether, 10_000, 500, two, _shares(6_000, 4_000), salt);

        // a clone is set up once, and only by the factory; the implementation never
        vm.expectRevert(GangFloorModule.NotFactory.selector);
        m.initialize(dev, tok, w, 1 ether, 5_000, FEE, two, half);
        vm.prank(address(factory));
        vm.expectRevert(GangFloorModule.AlreadyInitialized.selector);
        m.initialize(dev, tok, w, 1 ether, 5_000, FEE, two, half);
        GangFloorModule impl = GangFloorModule(factory.implementation());
        vm.prank(address(factory));
        vm.expectRevert(GangFloorModule.NotClone.selector);
        impl.initialize(dev, tok, w, 1 ether, 5_000, FEE, two, half);

        // no payees, no fee: allowed (D-1, D-2)
        vm.prank(dev);
        GangFloorModule pure_ = GangFloorModule(factory.create(tok, w, 0, 0, 0, none, noneS, bytes32("pure")));
        assertTrue(pure_.capReached());
        assertEq(pure_.capLeft(), 0);
        (ps,) = pure_.payeesOf();
        assertEq(ps.length, 0);
    }

    // ---------------------------------------------------------------- bind
    function test_bind_onlyTheTokenFixedAtClone() public {
        address dev = _newAgent();
        address w = address(wbnb);
        address tok = _nextToken(dev);
        GangFloorModule m = _noPayees(dev, tok, w, FEE);
        vm.expectRevert(GangFloorModule.NotCurve.selector); // not created yet
        m.bind(tok);
        vm.expectRevert(GangFloorModule.WrongToken.selector);
        m.bind(makeAddr("another"));
        address t = _createT(dev, w, _tax(TAX, TAX, 0, address(m)));
        assertEq(t, tok);
        // a second token of the same dev, same quote, same recipient: never bound
        address decoy = _createT(dev, w, _tax(TAX, TAX, 0, address(m)));
        vm.expectRevert(GangFloorModule.WrongToken.selector);
        m.bind(decoy);
        vm.expectEmit(address(m));
        emit GangFloorModule.Bound(t, w);
        m.bind(t);
        assertEq(m.token(), t);
        assertEq(m.quote(), w);
        vm.expectRevert(GangFloorModule.AlreadyBound.selector);
        m.bind(t);
    }

    function test_bind_checksTheTokenAtThatAddress() public {
        address dev = _newAgent();
        address w = address(wbnb);
        // cloned for an address only another Agent can create a token at
        address other = _newAgent();
        GangFloorModule m1 = _noPayees(dev, _nextToken(other), w, FEE);
        address t1 = _createT(other, w, _tax(TAX, TAX, 0, address(m1)));
        assertEq(t1, m1.floorToken());
        vm.expectRevert(GangFloorModule.NotCreator.selector);
        m1.bind(t1);
        // another recipient
        GangFloorModule m2 = _noPayees(dev, _nextToken(dev), w, FEE);
        address t2 = _createT(dev, w, _tax(TAX, TAX, 5_000, dev));
        vm.expectRevert(GangFloorModule.NotRecipient.selector);
        m2.bind(t2);
        // another quote: the treasury would be counted in another unit
        GangFloorModule m3 = _noPayees(dev, _nextToken(dev), w, FEE);
        address t3 = _createT(dev, address(quoteTok), _tax(TAX, TAX, 0, address(m3)));
        vm.expectRevert(GangFloorModule.WrongQuote.selector);
        m3.bind(t3);
        // all of the tax to the holders' dividend: nothing would ever reach the module (audit L-1)
        GangFloorModule m4 = _noPayees(dev, _nextToken(dev), w, FEE);
        address t4 = _createT(dev, w, _tax(TAX, TAX, 10_000, address(m4)));
        vm.expectRevert(GangFloorModule.NothingForRecipient.selector);
        m4.bind(t4);
        // a token that already exists can't be named: it was created before the module was listed
        vm.prank(dev);
        vm.expectRevert(GangFloorModuleFactory.BadToken.selector);
        factory.create(t4, w, 0, 0, FEE, new address[](0), new uint16[](0), bytes32("late"));
    }

    /// @dev M-1: a module whose token was never created holds what reaches it (the dev named it as another token's
    ///      recipient) until the token it was cloned for exists; then that is split like any other arrival.
    function test_unbound_whatArrivedWaitsForTheToken() public {
        address dev = _newAgent();
        address w = address(wbnb);
        address planned = _nextToken(dev);
        string memory name = _planName;
        bytes32 salt = _planSalt;
        GangFloorModule m = _noPayees(dev, planned, w, FEE);
        delete _planDev;
        address wrong = _createT(dev, w, _tax(TAX, TAX, 0, address(m))); // another name: another address
        assertTrue(wrong != planned);
        vm.expectRevert(GangFloorModule.WrongToken.selector);
        m.bind(wrong);
        wbnb.mintUnlimited(address(m), 10 ether);
        m.split();
        m.work(0);
        assertEq(m.treasury(), 0);
        vm.expectRevert(GangFloorModule.NotBound.selector);
        m.distribute(w);
        assertEq(_bal(w, address(m)), 10 ether, "it waits");
        // the dev creates the planned token after all
        vm.prank(dev);
        address t = Pad3Module(payable(address(pad)))
            .createWithSalt(
                salt,
                abi.encodeWithSignature(
                    CREATE_SIG, name, "CRV", "logo", "meta", w, address(0), _tax(TAX, TAX, 0, address(m))
                )
            );
        assertEq(t, planned);
        m.bind(t);
        assertEq(m.treasury(), 10 ether);
    }

    /// @dev §6: a dev can't route the real token's tax to a decoy's holders. The module serves the token fixed at
    ///      clone; the tax of any other token naming it is a gift to that token's holders.
    function test_decoy_otherTokensTaxIsAGiftToTheBoundTokensHolders() public {
        address dev = _newAgent();
        address w = address(wbnb);
        GangFloorModule m = _noPayees(dev, _nextToken(dev), w, 0);
        address real = _createT(dev, w, _tax(TAX, TAX, 0, address(m)));
        address decoy = _createT(dev, w, _tax(TAX, TAX, 0, address(m)));
        m.bind(real);
        address alice = _holder(real, m);
        address mallory = _holder(decoy, m);
        _graduate(real);
        _graduate(decoy);
        wbnb.mintUnlimited(address(m), 10 ether); // the decoy's tax, in the same quote
        // the decoy's holders have nothing to redeem with: the module only ever pulls the bound token
        assertEq(_bal(real, mallory), 0);
        vm.prank(mallory);
        IERC20(real).approve(address(m), type(uint256).max);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, mallory, 0, 1 ether));
        m.redeem(1 ether, 0, mallory);
        uint256 a = _bal(real, alice);
        (uint256 out,) = _quoteFor(a, 10 ether, m.floorSupply(), 0);
        vm.prank(alice);
        assertEq(m.redeem(a, 0, alice), out);
        assertGt(out, 0);
        assertEq(_bal(decoy, DEAD), 0, "no decoy token was ever taken");
    }

    // ---------------------------------------------------------------- the split
    function test_split_beforeAcrossAndAfterTheCap() public {
        (GangFloorModule m,, address dev, address kol,) = _setup(address(wbnb), 3 ether, false);
        uint256 dev0 = _bal(address(wbnb), dev);
        wbnb.mintUnlimited(address(m), 2 ether + 1);
        assertEq(m.unsplit(), 2 ether + 1);
        assertEq(m.treasury(), 1 ether + 1, "the view counts what a split would add");
        vm.expectEmit(address(m));
        emit GangFloorModule.Split(2 ether + 1, 1 ether + 1, 1 ether);
        m.split();
        assertEq(m.paidTotal(), 1 ether);
        assertEq(m.treasuryHeld(), 1 ether + 1);
        assertEq(_bal(address(wbnb), kol), 0.3 ether);
        assertEq(_bal(address(wbnb), dev) - dev0, 0.7 ether);
        assertEq(m.unsplit(), 0);

        // crosses the cap: the payees take exactly what is left of it
        wbnb.mintUnlimited(address(m), 10 ether);
        vm.expectEmit(address(m));
        emit GangFloorModule.Split(10 ether, 8 ether, 2 ether);
        vm.expectEmit(address(m));
        emit GangFloorModule.CapReached(3 ether);
        m.split();
        assertEq(m.paidTotal(), 3 ether);
        assertTrue(m.capReached());
        assertEq(m.capLeft(), 0);
        assertEq(_bal(address(wbnb), kol) + _bal(address(wbnb), dev) - dev0, 3 ether);
        assertEq(m.treasuryHeld(), 9 ether + 1);

        // after: all of it
        wbnb.mintUnlimited(address(m), 5 ether);
        assertEq(m.treasury(), 14 ether + 1, "no split needed for the treasury to count it");
        vm.expectEmit(address(m));
        emit GangFloorModule.Split(5 ether, 5 ether, 0);
        m.work(0);
        assertEq(m.treasuryHeld(), 14 ether + 1);
        assertEq(_bal(address(wbnb), kol) + _bal(address(wbnb), dev) - dev0, 3 ether, "not a wei more");
        assertEq(_bal(address(wbnb), address(m)), m.treasuryHeld(), "books = balance");
    }

    function test_split_noPayeesAllToTheTreasury() public {
        (GangFloorModule m,,,) = _setupPure(address(wbnb), FEE);
        wbnb.mintUnlimited(address(m), 7 ether);
        assertEq(m.treasury(), 7 ether);
        m.split();
        assertEq(m.treasuryHeld(), 7 ether);
        assertEq(m.paidTotal(), 0);
        vm.expectRevert(GangFloorModule.BadIndex.selector);
        m.release(address(wbnb), 0, ALL);
        vm.expectRevert(GangFloorModule.BadIndex.selector);
        m.setPayee(0, makeAddr("x"));
    }

    function test_beforeBind_nothingSplitOrSentAway() public {
        address dev = _newAgent();
        GangFloorModule m = _floor(
            dev, _nextToken(dev), address(wbnb), 100 ether, 5_000, FEE, _list(dev, makeAddr("k")), _shares(5_000, 5_000)
        );
        address t = _createT(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        wbnb.mintUnlimited(address(m), 1 ether);
        vm.expectRevert(GangFloorModule.NotBound.selector);
        m.distribute(address(wbnb));
        vm.expectRevert(GangFloorModule.NotBound.selector);
        m.release(address(wbnb), 0, ALL);
        vm.expectRevert(GangFloorModule.NotBound.selector);
        m.redeem(1, 0, dev);
        m.split(); // nothing to do before bind
        assertEq(_bal(address(wbnb), address(m)), 1 ether);
        assertEq(m.treasury(), 0);
        assertEq(m.floorSupply(), 0);
        assertEq(m.floorPrice(), 0);
        (uint256 out, uint256 fee) = m.previewRedeem(1 ether);
        assertEq(out + fee, 0);
        (bool due,) = m.previewWork();
        assertFalse(due);
        m.bind(t);
        m.split();
        assertEq(m.treasuryHeld(), 0.5 ether);
        assertEq(m.paidTotal(), 0.5 ether);
    }

    // ---------------------------------------------------------------- redeem
    function test_redeem_toTheWeiFeeStaysFloorRises() public {
        (GangFloorModule m, address t, address alice, address bob) = _setupPure(address(wbnb), FEE);
        wbnb.mintUnlimited(address(m), 10 ether + 7);
        uint256 supply = m.floorSupply();
        assertEq(supply, IERC20(t).totalSupply() - _bal(t, DEAD));
        uint256 price0 = m.floorPrice();
        assertEq(price0, ((10 ether + 7) * 1e18) / supply);
        uint256 a = _bal(t, alice) / 3;
        (uint256 out, uint256 fee) = _quoteFor(a, 10 ether + 7, supply, FEE);
        (uint256 pOut, uint256 pFee) = m.previewRedeem(a);
        assertEq(pOut, out);
        assertEq(pFee, fee);
        assertGt(fee, 0);

        address to = makeAddr("aliceCold");
        uint256 dead0 = _bal(t, DEAD);
        uint256 handler0 = _bal(t, address(handler));
        vm.expectEmit(address(m));
        emit GangFloorModule.Redeemed(alice, to, a, out, fee, 10 ether + 7 - out, supply - a);
        vm.prank(alice);
        assertEq(m.redeem(a, out, to), out);
        assertEq(_bal(address(wbnb), to), out);
        assertEq(_bal(t, DEAD) - dead0, a, "all of it to 0xdead");
        assertEq(_bal(t, address(handler)), handler0, "no tax on the way");
        assertEq(m.treasuryHeld(), 10 ether + 7 - out);
        assertEq(_bal(address(wbnb), address(m)), m.treasuryHeld(), "books = balance");
        assertEq(m.floorSupply(), supply - a);
        assertGt(m.floorPrice(), price0, "the fee stayed: the floor rose");

        // the next holder is measured against what is left
        uint256 b = _bal(t, bob);
        (uint256 out2,) = _quoteFor(b, m.treasuryHeld(), supply - a, FEE);
        vm.prank(bob);
        assertEq(m.redeem(b, 0, bob), out2);
    }

    function test_redeem_noFeeFloorStays() public {
        (GangFloorModule m, address t, address alice,) = _setupPure(address(wbnb), 0);
        wbnb.mintUnlimited(address(m), 10 ether);
        uint256 held = m.treasury();
        uint256 supply = m.floorSupply();
        uint256 a = _bal(t, alice);
        vm.prank(alice);
        uint256 out = m.redeem(a, 0, alice);
        assertEq(out, (a * held) / supply);
        // never lower per token, to the wei: held' × supply ≥ held × supply'
        assertGe(m.treasury() * supply, held * m.floorSupply());
    }

    /// @dev The quote that arrived before a redemption is split first: the payees' part of it is never redeemed.
    function test_redeem_splitsFirst() public {
        (GangFloorModule m, address t, address dev, address kol, address alice) = _setup(address(wbnb), 100 ether, true);
        uint256 dev0 = _bal(address(wbnb), dev);
        wbnb.mintUnlimited(address(m), 10 ether);
        uint256 supply = m.floorSupply();
        uint256 a = _bal(t, alice);
        (uint256 out,) = _quoteFor(a, 5 ether, supply, FEE);
        (uint256 pOut,) = m.previewRedeem(a);
        assertEq(pOut, out, "the preview splits first too");
        vm.prank(alice);
        assertEq(m.redeem(a, 0, alice), out);
        assertEq(m.paidTotal(), 5 ether, "counted against the cap");
        assertEq(m.payeesPending(), 5 ether, "set aside, not pushed by the redemption");
        assertEq(_bal(address(wbnb), kol) + _bal(address(wbnb), dev) - dev0, 0);
        assertEq(m.treasuryHeld(), 5 ether - out);
        assertEq(m.unsplit(), 0);
        (bool due,) = m.previewWork();
        assertTrue(due, "the keeper pushes it");
        m.work(0);
        assertEq(m.payeesPending(), 0);
        assertEq(_bal(address(wbnb), kol) + _bal(address(wbnb), dev) - dev0, 5 ether);
        assertEq(m.paidTotal(), 5 ether, "not counted twice");
        assertEq(_bal(address(wbnb), address(m)), m.treasuryHeld(), "books = balance");
    }

    /// @dev Audit L-3: a redemption calls no payee — one that refuses or burns gas costs the holder nothing — and
    ///      what was set aside for them shrinks with a shortfall like everything held.
    function test_redeem_neverCallsAPayee() public {
        (GangFloorModule m, address t,, address kol, address alice) = _setup(address(blq), 100 ether, true);
        blq.setBlocked(kol, true);
        blq.mint(address(m), 10 ether);
        vm.prank(alice);
        m.redeem(1 ether, 0, alice);
        assertEq(m.owedTotal(address(blq)), 0, "nobody was pushed, so nobody is owed");
        assertEq(m.payeesPending(), 5 ether);

        // a shortfall before the push: the treasury and the set-aside part shrink in proportion; the preview agrees
        uint256 bal = _bal(address(blq), address(m));
        uint256 held = m.treasuryHeld();
        deal(address(blq), address(m), bal / 2);
        assertEq(m.treasury(), bal / 2 - (5 ether * (bal / 2)) / bal);
        uint256 a = _bal(t, alice);
        (uint256 pOut,) = m.previewRedeem(a);
        vm.prank(alice);
        assertEq(m.redeem(a, 0, alice), pOut, "the preview matches under a shortfall");
        assertEq(m.payeesPending(), (5 ether * (bal / 2)) / bal);
        assertLt(m.treasuryHeld(), held);
        assertEq(m.paidTotal(), 5 ether, "never rolled back");

        // the push: the one that refuses is owed
        uint256 pend = m.payeesPending();
        m.split();
        assertEq(m.payeesPending(), 0);
        assertEq(m.owedOf(address(blq), 1), (pend * 3_000) / 10_000);
        assertEq(_bal(address(blq), address(m)), m.treasuryHeld() + m.owedTotal(address(blq)), "books = balance");
    }

    /// @dev From the audit: any `to` (a payee, the pair, the handler, 0xdead) gets exactly the share, the books stay
    ///      whole, and fifty pieces never pay more than the share before the fee.
    function test_redeem_anyToAndManyPieces() public {
        (GangFloorModule m, address t,, address kol, address alice) = _setup(address(wbnb), 1 ether, true);
        address w = address(wbnb);
        wbnb.mintUnlimited(address(m), 50 ether);
        m.split();
        address[4] memory tos = [kol, _curvePair(t), address(handler), DEAD];
        for (uint256 i; i < 4; i++) {
            uint256 price0 = m.floorPrice();
            (uint256 out,) = m.previewRedeem(1 ether);
            uint256 b0 = _bal(w, tos[i]);
            vm.prank(alice);
            assertEq(m.redeem(1 ether, out, tos[i]), out);
            assertEq(_bal(w, tos[i]) - b0, out);
            assertGe(m.floorPrice(), price0);
            assertEq(_bal(w, address(m)), m.treasuryHeld() + m.owedTotal(w));
        }
        uint256 a = _bal(t, alice);
        uint256 held = m.treasury();
        uint256 supply = m.floorSupply();
        uint256 got;
        vm.startPrank(alice);
        for (uint256 i; i < 50; i++) {
            uint256 part = i == 49 ? _bal(t, alice) : a / 50;
            got += m.redeem(part, 0, alice);
        }
        vm.stopPrank();
        assertLe(got * supply, a * held);
    }

    function test_redeem_guards() public {
        (GangFloorModule m, address t,,, address alice) = _setup(address(blq), 100 ether, false);
        blq.mint(address(m), 10 ether);
        vm.startPrank(alice);
        vm.expectRevert(GangFloorModule.ZeroAmount.selector);
        m.redeem(0, 0, alice);
        vm.expectRevert(GangFloorModule.ZeroAddress.selector);
        m.redeem(1 ether, 0, address(0));
        vm.expectRevert(GangFloorModule.BadTo.selector);
        m.redeem(1 ether, 0, address(m));
        vm.expectRevert(GangFloorModule.NotTradable.selector); // K-10: not before graduation
        m.redeem(1 ether, 0, alice);
        vm.stopPrank();
        (uint256 p,) = m.previewRedeem(1 ether);
        assertEq(p, 0, "no preview before graduation either");
        assertEq(_bal(address(blq), address(m)), 10 ether, "nothing left before graduation");

        _graduate(t);
        uint256 a = _bal(t, alice);
        (uint256 out,) = m.previewRedeem(a);
        vm.startPrank(alice);
        vm.expectRevert(GangFloorModule.Slippage.selector);
        m.redeem(a, out + 1, alice);
        vm.expectRevert(GangFloorModule.NothingToRedeem.selector); // rounds to nothing
        m.redeem(1, 0, alice);
        vm.stopPrank();
        (p,) = m.previewRedeem(m.floorSupply() + 1);
        assertEq(p, 0, "more than there is");

        // a `to` that can't receive: the whole redemption reverts, nothing moves
        address frozen = makeAddr("frozen");
        blq.setBlocked(frozen, true);
        vm.prank(alice);
        vm.expectRevert("blacklisted");
        m.redeem(a, 0, frozen);
        assertEq(_bal(t, alice), a);

        // without the allowance, or the balance
        address carol = _newAgent();
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(m), 0, 5 ether)
        );
        m.redeem(5 ether, 0, carol);

        vm.prank(alice);
        assertEq(m.redeem(a, out, alice), out);
    }

    function test_redeem_emptyTreasury() public {
        (GangFloorModule m, address t, address alice,) = _setupPure(address(wbnb), FEE);
        assertEq(m.floorPrice(), 0);
        uint256 a = _bal(t, alice);
        vm.prank(alice);
        vm.expectRevert(GangFloorModule.NothingToRedeem.selector);
        m.redeem(a, 0, alice);
    }

    /// @dev K-6: quote sent straight to the module is a gift to every holder; tokens sent to 0xdead by anyone too.
    function test_floor_giftsAndBurnsRaiseIt() public {
        (GangFloorModule m, address t, address alice, address bob) = _setupPure(address(wbnb), FEE);
        wbnb.mintUnlimited(address(m), 1 ether);
        uint256 p0 = m.floorPrice();
        wbnb.mintUnlimited(address(m), 1 ether);
        uint256 p1 = m.floorPrice();
        assertGt(p1, p0);
        uint256 burn = _bal(t, bob);
        vm.prank(bob);
        IERC20(t).transfer(DEAD, burn);
        assertGt(m.floorPrice(), p1);
        // the token itself sent to the module: `distribute` sends it to 0xdead
        uint256 half = _bal(t, alice) / 2;
        vm.prank(alice);
        IERC20(t).transfer(address(m), half);
        uint256 p2 = m.floorPrice();
        vm.expectEmit(address(m));
        emit GangFloorModule.Distributed(t, half, half);
        m.distribute(t);
        assertGt(m.floorPrice(), p2);
        assertEq(_bal(t, address(m)), 0);
    }

    /// @dev I-4: a redemption never uses what payees are owed; a release never uses the treasury.
    function test_redeem_owedIsNotTheTreasury() public {
        (GangFloorModule m, address t,, address kol, address alice) = _setup(address(blq), 100 ether, true);
        blq.setBlocked(kol, true);
        blq.mint(address(m), 10 ether); // 5 to the payees (1.5 owed to kol), 5 to the treasury
        m.split();
        assertEq(m.owedOf(address(blq), 1), 1.5 ether);
        assertEq(m.treasury(), 5 ether);
        assertEq(m.unsplit(), 0, "owed is held, not split again");
        uint256 a = _bal(t, alice);
        (uint256 out,) = _quoteFor(a, 5 ether, m.floorSupply(), FEE);
        vm.prank(alice);
        assertEq(m.redeem(a, 0, alice), out);
        assertEq(m.owedOf(address(blq), 1), 1.5 ether);
        assertEq(_bal(address(blq), address(m)), 5 ether - out + 1.5 ether);

        blq.setBlocked(kol, false);
        uint256 held = m.treasuryHeld();
        assertEq(m.release(address(blq), 1, ALL), 1.5 ether);
        assertEq(m.treasuryHeld(), held);
        assertEq(_bal(address(blq), address(m)), held, "books = balance");
        assertEq(m.paidTotal(), 5 ether, "a release is not a new payout");
        vm.expectRevert(GangFloorModule.NothingOwed.selector);
        m.release(address(blq), 1, ALL);
        vm.expectRevert(GangFloorModule.NothingOwed.selector);
        m.release(address(wbnb), 1, ALL);
        vm.expectRevert(GangFloorModule.BadIndex.selector);
        m.release(address(blq), 2, ALL);
    }

    // ---------------------------------------------------------------- payees
    function test_payee_owedCountsAgainstTheCap() public {
        (GangFloorModule m,, address dev, address kol,) = _setup(address(blq), 1 ether, false);
        blq.setBlocked(kol, true);
        uint256 dev0 = _bal(address(blq), dev);
        blq.mint(address(m), 10 ether); // 5 → only 1 (the cap): dev 0.7 pushed, kol 0.3 owed
        vm.expectEmit(address(m));
        emit GangFloorModule.CapReached(1 ether);
        m.split();
        assertEq(m.paidTotal(), 1 ether);
        assertEq(m.owedOf(address(blq), 1), 0.3 ether);
        assertEq(_bal(address(blq), dev) - dev0, 0.7 ether);
        assertEq(m.treasuryHeld(), 9 ether);
        blq.mint(address(m), 10 ether);
        m.split();
        assertEq(m.owedOf(address(blq), 1), 0.3 ether, "no more owed after the cap");
        assertEq(m.treasuryHeld(), 19 ether);
    }

    function test_payee_owedPaidAtTheNextPush() public {
        (GangFloorModule m,,, address kol,) = _setup(address(blq), 100 ether, false);
        blq.setBlocked(kol, true);
        blq.mint(address(m), 10 ether);
        m.split();
        blq.setBlocked(kol, false);
        blq.mint(address(m), 10 ether);
        m.split();
        assertEq(m.owedTotal(address(blq)), 0);
        assertEq(_bal(address(blq), kol), 3 ether);
        assertEq(m.paidTotal(), 10 ether);
    }

    function test_payee_movesOnlyItsOwnSlot() public {
        (GangFloorModule m,, address dev, address kol,) = _setup(address(wbnb), 100 ether, false);
        address kol2 = makeAddr("kol2");
        vm.expectRevert(GangFloorModule.NotPayee.selector);
        m.setPayee(1, kol2);
        vm.startPrank(kol);
        vm.expectRevert(GangFloorModule.BadIndex.selector);
        m.setPayee(2, kol2);
        vm.expectRevert(GangFloorModule.NotPayee.selector);
        m.setPayee(0, kol2);
        vm.expectRevert(GangFloorModule.ZeroAddress.selector);
        m.setPayee(1, address(0));
        vm.expectRevert(GangFloorModule.BadPayee.selector);
        m.setPayee(1, address(m));
        vm.expectRevert(GangFloorModule.DuplicatePayee.selector);
        m.setPayee(1, dev);
        vm.stopPrank();
        wbnb.mintUnlimited(address(m), 10 ether); // arrived before the move: paid to the old address
        vm.expectEmit(address(m));
        emit GangFloorModule.PayeeChanged(1, kol, kol2);
        vm.prank(kol);
        m.setPayee(1, kol2);
        assertEq(_bal(address(wbnb), kol), 1.5 ether);
        wbnb.mintUnlimited(address(m), 10 ether);
        m.split();
        assertEq(_bal(address(wbnb), kol), 1.5 ether);
        assertEq(_bal(address(wbnb), kol2), 1.5 ether);
        assertEq(m.capAmount(), 100 ether, "the cap stays");
        assertEq(m.treasuryHeld(), 10 ether);
    }

    /// @dev MAX_PAYEES payees, each push with its own PUSH_GAS: a split without the gas for a whole push reverts
    ///      PushStarved and changes nothing; a redemption in the same state pushes nobody, so it needs no such gas;
    ///      every payee that refuses is owed its exact share, and the cap counts all of it.
    function test_payee_tenPayeesPushStarvedAndRedeemUnaffected() public {
        address dev = _newAgent();
        address[] memory ps = new address[](10);
        uint16[] memory ss = new uint16[](10);
        for (uint256 i; i < 10; i++) {
            ps[i] = makeAddr(string.concat("p", vm.toString(i)));
            ss[i] = 1_000;
            if (i % 2 == 1) blq.setBlocked(ps[i], true);
        }
        GangFloorModule m = _floor(dev, _nextToken(dev), address(blq), 100 ether, 5_000, FEE, ps, ss);
        address t = _createT(dev, address(blq), _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t);
        address alice = _holder(t, m);
        _graduate(t);
        blq.mint(address(m), 20 ether);

        uint256 starved = (m.PUSH_GAS() * 64) / 63 + m.PUSH_RESERVE();
        try m.split{gas: starved}() {
            fail("a split without the gas for a push");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), GangFloorModule.PushStarved.selector);
        }
        assertEq(m.paidTotal(), 0, "nothing changed");
        assertEq(m.unsplit(), 20 ether);

        // the same gas is plenty for a redemption: it calls no payee
        (uint256 out,) = m.previewRedeem(1 ether);
        vm.prank(alice);
        assertEq(m.redeem{gas: starved}(1 ether, out, alice), out);
        assertEq(m.payeesPending(), 10 ether);
        assertEq(m.paidTotal(), 10 ether);
        for (uint256 i; i < 10; i++) {
            assertEq(_bal(address(blq), ps[i]), 0, "nobody pushed by the redemption");
        }

        m.split();
        assertEq(m.payeesPending(), 0);
        for (uint256 i; i < 10; i++) {
            assertEq(_bal(address(blq), ps[i]), i % 2 == 1 ? 0 : 1 ether);
            assertEq(m.owedOf(address(blq), i), i % 2 == 1 ? 1 ether : 0);
        }
        assertEq(m.owedTotal(address(blq)), 5 ether);
        assertEq(_bal(address(blq), address(m)), m.treasuryHeld() + 5 ether, "books = balance");
        for (uint256 i = 1; i < 10; i += 2) {
            blq.setBlocked(ps[i], false);
            assertEq(m.release(address(blq), i, ALL), 1 ether);
        }
        assertEq(m.paidTotal(), 10 ether, "releases are not new payouts");
        assertEq(_bal(address(blq), address(m)), m.treasuryHeld(), "books = balance");
    }

    // ---------------------------------------------------------------- other assets
    function test_otherAsset_allToDead() public {
        (GangFloorModule m,, address dev, address kol, address alice) = _setup(address(wbnb), 100 ether, true);
        quoteTok.mintUnlimited(address(m), 1 ether);
        assertEq(m.undistributed(address(quoteTok)), 1 ether);
        uint256 dev0 = _bal(address(quoteTok), dev);
        uint256 alice0 = _bal(address(quoteTok), alice);
        vm.expectEmit(address(m));
        emit GangFloorModule.Distributed(address(quoteTok), 1 ether, 1 ether);
        assertEq(m.distribute(address(quoteTok)), 1 ether);
        assertEq(_bal(address(quoteTok), DEAD), 1 ether);
        assertEq(_bal(address(quoteTok), kol), 0);
        assertEq(_bal(address(quoteTok), dev), dev0);
        assertEq(m.treasury() + m.paidTotal(), 0, "other assets are never the treasury or counted");
        assertEq(m.distribute(address(quoteTok)), 0, "nothing left");
        // and a redemption never pays one
        wbnb.mintUnlimited(address(m), 1 ether);
        quoteTok.mintUnlimited(address(m), 1 ether);
        vm.prank(alice);
        m.redeem(1 ether, 0, alice);
        assertEq(_bal(address(quoteTok), alice), alice0);
    }

    function test_otherAsset_deadRefusedStays() public {
        (GangFloorModule m,, address dev, address kol,) = _setup(address(wbnb), 100 ether, false);
        GasBurnQuote gb = new GasBurnQuote();
        gb.setBlocked(DEAD, true);
        gb.mint(address(m), 1 ether);
        vm.expectEmit(address(m));
        emit GangFloorModule.Distributed(address(gb), 1 ether, 0);
        uint256 g = gasleft();
        m.distribute(address(gb));
        assertLt(g - gasleft(), m.PUSH_GAS() + 100_000, "the dead push at most PUSH_GAS");
        assertEq(gb.balanceOf(address(m)), 1 ether);
        assertEq(gb.balanceOf(kol) + gb.balanceOf(dev), 0);
        gb.setBlocked(DEAD, false);
        m.distribute(address(gb));
        assertEq(gb.balanceOf(DEAD), 1 ether);
    }

    // ---------------------------------------------------------------- shortfall
    /// @dev K-7: a balance under what is held shrinks the treasury and the owed in proportion; `paidTotal` stays.
    function test_shortfall_treasuryAndOwedShrink() public {
        (GangFloorModule m, address t,, address kol, address alice) = _setup(address(blq), 100 ether, true);
        blq.setBlocked(kol, true);
        blq.mint(address(m), 10 ether);
        m.split(); // 5 to the payees (1.5 owed to kol), 5 to the treasury
        assertEq(_bal(address(blq), address(m)), 6.5 ether);
        deal(address(blq), address(m), 3.25 ether); // half of it taken
        assertEq(m.treasury(), 2.5 ether, "the view sees it");
        vm.expectEmit(address(m));
        emit GangFloorModule.Shortfall(address(blq), 3.25 ether);
        m.split();
        assertEq(m.owedOf(address(blq), 1), 0.75 ether);
        assertEq(m.treasuryHeld(), 2.5 ether);
        assertEq(m.paidTotal(), 5 ether, "never rolled back");
        // a redemption is measured against what is really there
        uint256 a = _bal(t, alice);
        (uint256 out,) = _quoteFor(a, 2.5 ether, m.floorSupply(), FEE);
        vm.prank(alice);
        assertEq(m.redeem(a, 0, alice), out);
        blq.setBlocked(kol, false);
        assertEq(m.release(address(blq), 1, ALL), 0.75 ether);
        assertEq(_bal(address(blq), address(m)), m.treasuryHeld());
    }

    // ---------------------------------------------------------------- the keeper
    function test_keeper_dueOnlyForThePayeesPart() public {
        (GangFloorModule m, address t,,,) = _setup(address(wbnb), 100 ether, true);
        (, uint256 rQ) = _reserves(t, _curvePair(t));
        uint256 floor = (rQ * m.WORK_MIN_BPS()) / 10_000;
        (bool due, uint256 minOut) = m.previewWork();
        assertFalse(due, "nothing arrived");
        wbnb.mintUnlimited(address(m), floor); // the payees' half is under the floor
        (due,) = m.previewWork();
        assertFalse(due);
        _next(2 days); // idle long enough: 1/100 of the floor is enough
        (due, minOut) = m.previewWork();
        assertTrue(due);
        assertEq(minOut, 0);
        m.work(minOut);
        assertGt(m.paidTotal(), 0);
        wbnb.mintUnlimited(address(m), floor * 2 + 10); // at the floor
        (due,) = m.previewWork();
        assertTrue(due);

        // after the cap (nothing set aside by a redemption), and with no payees: never — the treasury needs no keeper
        (GangFloorModule m2,,,,) = _setup(address(wbnb), 1, true);
        wbnb.mintUnlimited(address(m2), 2);
        m2.split();
        assertTrue(m2.capReached());
        wbnb.mintUnlimited(address(m2), 100 ether);
        _next(2 days);
        (due,) = m2.previewWork();
        assertFalse(due);
        (GangFloorModule m3,,,) = _setupPure(address(wbnb), FEE);
        wbnb.mintUnlimited(address(m3), 100 ether);
        _next(2 days);
        (due,) = m3.previewWork();
        assertFalse(due);
    }

    function test_keeper_notBeforeGraduationNorForAQuoteItDoesNotServe() public {
        (GangFloorModule m,,,,) = _setup(address(wbnb), 100 ether, false);
        wbnb.mintUnlimited(address(m), 100 ether);
        (bool due,) = m.previewWork();
        assertFalse(due, "not before graduation");

        (GangFloorModule m2,,,,) = _setup(address(quoteTok), 100 ether, true);
        quoteTok.mintUnlimited(address(m2), 100 ether);
        (due,) = m2.previewWork();
        assertTrue(due, "a QuoteRegistry quote is served");
        vm.prank(owner);
        quoteRegistry.setQuote(address(quoteTok), false, 0);
        (due,) = m2.previewWork();
        assertFalse(due);
        m2.split(); // by hand it still works
        assertGt(m2.treasuryHeld(), 0);
    }

    // ---------------------------------------------------------------- end to end
    /// @dev The pool tax reaches the module in the quote, crosses the cap, and a holder redeems against it.
    function test_e2e_poolTaxFillsTheTreasury() public {
        (GangFloorModule m, address t, address dev, address kol, address alice) =
            _setup(address(wbnb), 0.01 ether, true);
        address pair = _curvePair(t);
        uint256 dev0 = _bal(address(wbnb), dev);
        for (uint256 i; i < 24; i++) {
            address seller = _newAgent();
            (uint256 rT,) = _reserves(t, pair);
            deal(t, seller, rT / 40, true);
            _poolSell(t, pair, seller, rT / 40);
            _next(1 minutes);
            if (i % 8 == 7) {
                uint256 mc = handler.maxChunk(t);
                vm.prank(keeper);
                handler.process(t, mc, 1);
            }
        }
        assertGt(m.unsplit(), 0.02 ether, "enough to cross the cap");
        (bool due, uint256 minOut) = m.previewWork();
        assertTrue(due);
        m.work(minOut);
        assertTrue(m.capReached());
        assertEq(_bal(address(wbnb), kol) + _bal(address(wbnb), dev) - dev0, 0.01 ether, "the payees: the cap, exactly");
        assertGt(m.treasuryHeld(), 0.01 ether);
        assertEq(_bal(address(wbnb), address(m)), m.treasuryHeld(), "books = balance");

        uint256 a = _bal(t, alice);
        uint256 price0 = m.floorPrice();
        (uint256 out,) = m.previewRedeem(a);
        uint256 alice0 = _bal(address(wbnb), alice);
        vm.prank(alice);
        m.redeem(a, out, alice);
        assertEq(_bal(address(wbnb), alice) - alice0, out);
        assertGt(out, 0);
        assertGe(m.floorPrice(), price0);
    }
}

/// @notice The floor's invariants under random arrivals, redemptions, refusals and releases (spec §5), on three
///         graduated modules set up once: payees with a small cap, payees with a large one, no payees and no fee.
contract GangFloorModuleFuzzTest is FloorBase {
    GangFloorModule[3] ms;
    address[3] ts;
    address[3][3] holders;
    address fDev;
    address fKol;

    function setUp() public {
        _deployFloor();
        fDev = _newAgent();
        fKol = makeAddr("fuzzKol");
        for (uint256 k; k < 3; k++) {
            GangFloorModule m = k == 2
                ? _noPayees(fDev, _nextToken(fDev), address(blq), 0)
                : _floor(
                    fDev,
                    _nextToken(fDev),
                    address(blq),
                    k == 0 ? 3 ether : 1_000 ether,
                    k == 0 ? 10_000 : 3_333,
                    k == 0 ? 500 : 137,
                    _list(fDev, fKol),
                    _shares(6_000, 4_000)
                );
            address t = _createT(fDev, address(blq), _tax(TAX, TAX, 0, address(m)));
            m.bind(t);
            for (uint256 h; h < 3; h++) {
                holders[k][h] = _holder(t, m);
            }
            _graduate(t);
            (ms[k], ts[k]) = (m, t);
        }
    }

    /// @dev I-1 paid ≤ cap; I-2 the treasury per token never falls; I-3 a redemption pays at most its share; I-4 the
    ///      books equal the balance (so a redemption can't use the owed, nor a release the treasury); I-6 the preview
    ///      matches.
    function testFuzz_floorHolds(uint256 seed) public {
        uint256 k = seed % 3;
        GangFloorModule m = ms[k];
        address t = ts[k];
        address q = address(blq);
        uint256 cap = m.capAmount();
        for (uint256 i; i < 32; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 8;
            uint256 held0 = m.treasury();
            uint256 supply0 = m.floorSupply();
            if (op == 0) {
                blq.setBlocked(fKol, (r >> 8) % 2 == 0);
            } else if (op == 1) {
                if (k != 2 && m.owedOf(q, 1) != 0) {
                    blq.setBlocked(fKol, false);
                    // the split it starts with may already have pushed what was owed
                    try m.release(q, 1, ALL) {} catch {}
                }
            } else if (op <= 4) {
                address who = holders[k][(r >> 8) % 3];
                uint256 bal = _bal(t, who);
                if (bal == 0) continue;
                uint256 a = 1 + ((r >> 16) % bal);
                (uint256 pOut, uint256 pFee) = m.previewRedeem(a);
                if (pOut == 0) continue;
                address to = makeAddr("fuzzTo");
                uint256 to0 = _bal(q, to);
                vm.prank(who);
                uint256 out = m.redeem(a, pOut, to);
                assertEq(out, pOut, "I-6");
                assertEq(_bal(q, to) - to0, out);
                assertLe((out + pFee) * supply0, a * held0, "I-3");
                assertEq(m.floorSupply(), supply0 - a);
            } else if (op == 5) {
                m.split();
            } else if (op == 6) {
                // anyone sends tokens to 0xdead: the floor only rises
                address who = holders[k][(r >> 8) % 3];
                uint256 bal = _bal(t, who);
                if (bal == 0) continue;
                vm.prank(who);
                IERC20(t).transfer(DEAD, 1 + ((r >> 16) % bal) / 4);
            } else {
                blq.mint(address(m), (r >> 8) % 20 ether);
                if ((r >> 4) % 2 == 0) m.split();
            }
            assertLe(m.paidTotal(), cap, "I-1");
            assertGe(m.treasury() * supply0, held0 * m.floorSupply(), "I-2");
            assertEq(_bal(q, address(m)), m.treasuryHeld() + m.owedTotal(q) + m.payeesPending() + m.unsplit(), "I-4");
        }
    }

    /// @dev A redemption that rounds to nothing is the only revert these runs may skip: any other is a failure.
    function _onlyNothingToRedeem(bytes memory reason) internal pure {
        assertEq(bytes4(reason), GangFloorModule.NothingToRedeem.selector, "unexpected revert");
    }

    /// @dev I-5: a redemption in two parts never pays more than the whole amount's share before the fee; with no fee,
    ///      never more than in one. (With a fee the second part gets back a little of the first part's fee, as every
    ///      holder who stays does.)
    function testFuzz_splitRedemptionPaysNoMore(uint256 seed, uint96 arrived, uint256 a, uint256 cut) public {
        uint256 k = seed % 3;
        GangFloorModule m = ms[k];
        address t = ts[k];
        address who = holders[k][0];
        blq.mint(address(m), bound(arrived, 1, 1_000_000 ether));
        a = bound(a, 2, _bal(t, who));
        cut = bound(cut, 1, a - 1);
        uint256 held = m.treasury();
        uint256 supply = m.floorSupply();
        uint256 snap = vm.snapshotState();
        vm.prank(who);
        uint256 once;
        try m.redeem(a, 0, who) returns (uint256 o) {
            once = o;
        } catch (bytes memory reason) {
            _onlyNothingToRedeem(reason);
            return; // rounds to nothing
        }
        vm.revertToState(snap);
        uint256 twice;
        vm.startPrank(who);
        try m.redeem(cut, 0, who) returns (uint256 o) {
            twice += o;
        } catch (bytes memory reason) {
            _onlyNothingToRedeem(reason);
        }
        try m.redeem(a - cut, 0, who) returns (uint256 o) {
            twice += o;
        } catch (bytes memory reason) {
            _onlyNothingToRedeem(reason);
        }
        vm.stopPrank();
        assertLe(twice * supply, a * held, "I-5");
        if (m.redeemFeeBps() == 0) assertLe(twice, once, "I-5, no fee");
    }
}

/// @notice Audit M-1: no module on a pad whose tokens' addresses the dev can't fix in advance.
contract GangFloorModuleNoVanityTest is GangFixture {
    function test_create_refusedOnAPadWithoutTheDeployer() public {
        _deployGang(makeAddr("keeper")); // GangLaunchpad 2.0: no `vanityDeployer` at all
        _refused();
    }

    function _refused() internal {
        GangHandlerAdmin admin = new GangHandlerAdmin(owner, address(handler));
        vm.startPrank(owner);
        handler.transferOwnership(address(admin));
        admin.exec(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        vm.stopPrank();
        GangFloorModuleFactory factory = new GangFloorModuleFactory(address(pad), address(admin), address(0));
        vm.prank(owner);
        admin.setFactory(address(factory), true);
        assertFalse(factory.vanityEnabled());
        address dev = _newAgent();
        vm.prank(dev);
        vm.expectRevert(GangFloorModuleFactory.NoVanityDeployer.selector);
        factory.create(
            address(uint160(0x7777abcd)), address(wbnb), 0, 0, 200, new address[](0), new uint16[](0), bytes32(0)
        );
    }
}

contract GangFloorModuleVanityOffTest is GangFloorModuleNoVanityTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3(); // 3.0 before `enableVanity`
    }
}
