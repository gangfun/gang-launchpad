// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {TwapMockPairFactory} from "../mocks/TwapMockPair.sol";
import {GangSplitModule} from "../../src/gang/GangSplitModule.sol";
import {GangSplitModuleFactory} from "../../src/gang/GangSplitModuleFactory.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {DeployGangSplitModuleFactory} from "../../script/DeployGangSplitModuleFactory.s.sol";

/// @dev A quote that refuses a blocked receiver by burning all the gas it gets (an `invalid` opcode).
contract GasBurnQuote is ERC20("Gas Burn", "GB") {
    mapping(address => bool) public blocked;

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[to]) {
            assembly {
                invalid()
            }
        }
        super._update(from, to, value);
    }
}

/// @dev A quote refusing any single transfer over `maxTx` (a per-transfer cap), and refusing blocked receivers.
contract MaxTxQuote is ERC20("Max Tx", "MTX") {
    uint256 public maxTx = 5 ether;
    mapping(address => bool) public blocked;

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) {
            require(!blocked[to], "blacklisted");
            require(value <= maxTx, "maxTx");
        }
        super._update(from, to, value);
    }
}

/// @dev A quote whose successful transfer costs ≈ 250k gas (a heavy hook); blocked receivers are refused.
contract HeavyQuote is ERC20("Heavy", "HV") {
    mapping(address => bool) public blocked;

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) {
            require(!blocked[to], "blacklisted");
            uint256 g = gasleft();
            while (g - gasleft() < 250_000) {}
        }
        super._update(from, to, value);
    }
}

/// @dev Moves the coins on transfer, then returns `len` bytes whose first word is `w`.
contract RetShapeQuote is ERC20("Ret", "RET") {
    uint256 public len;
    uint256 public w;

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function set(uint256 l, uint256 w_) external {
        (len, w) = (l, w_);
    }

    function transfer(address to, uint256 v) public override returns (bool) {
        _transfer(msg.sender, to, v);
        uint256 l = len;
        uint256 ww = w;
        assembly {
            let p := mload(0x40)
            mstore(p, ww)
            mstore(add(p, 32), 0xdead)
            return(p, l)
        }
    }
}

/// @dev Returns a huge blob from transfer (a return-data bomb).
contract ReturnBombAsset {
    function balanceOf(address) external pure returns (uint256) {
        return 10 ether;
    }

    function transfer(address, uint256) external pure returns (bool) {
        assembly {
            return(0, 200000)
        }
    }
}

/// @dev Answers every view the deploy script's `check` reads like a real factory / implementation, with other code.
contract FakeSplitImpl {
    address public pad;
    address public taxHandler;
    address public factory;
    bytes32 public constant moduleType = "split-v1";
    address public constant gangQuote = address(0x6A46);

    constructor(address pad_, address handler_) {
        (pad, taxHandler) = (pad_, handler_);
    }

    function setFactory(address f) external {
        factory = f;
    }
}

contract FakeSplitFactory {
    address public pad;
    address public admin;
    address public implementation;

    constructor(address pad_, address admin_, address impl_) {
        (pad, admin, implementation) = (pad_, admin_, impl_);
    }
}

/// @notice GangSplitModule (多人分账) on the whole merged deployment: the factory (Agent only, listed by
///         GangHandlerAdmin), the fixed payee list, binding, the split, owed pushes, a payee moving its own address,
///         shortfalls, any asset split alike, the keeper's previewWork / work, the deploy script's check, and the pool tax end to end.
contract GangSplitModuleTest is GangFixture {
    address keeper = makeAddr("keeper");
    GangHandlerAdmin admin;
    GangSplitModuleFactory factory;
    uint256 _salt;

    uint16 constant TAX = 300;
    address BQ;
    uint256 constant ALL = type(uint256).max;
    address constant GANG = address(0x6A46);

    function _newPairFactory() internal override returns (address) {
        return address(new TwapMockPairFactory());
    }

    function setUp() public {
        _deployGang(keeper);
        BQ = address(blq);
        admin = new GangHandlerAdmin(owner, address(handler));
        vm.startPrank(owner);
        handler.transferOwnership(address(admin));
        admin.exec(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        vm.stopPrank();
        factory = new GangSplitModuleFactory(address(pad), address(admin), GANG);
        vm.prank(owner);
        admin.setFactory(address(factory), true);
    }

    // ---------------------------------------------------------------- helpers
    function _list3(address a, address b, address c) internal pure returns (address[] memory p) {
        p = new address[](3);
        (p[0], p[1], p[2]) = (a, b, c);
    }

    function _shares3(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory s) {
        s = new uint16[](3);
        (s[0], s[1], s[2]) = (a, b, c);
    }

    function _module(address dev, address[] memory p, uint16[] memory s) internal returns (GangSplitModule m) {
        vm.prank(dev);
        m = GangSplitModule(factory.create(p, s, bytes32(++_salt)));
    }

    /// @dev The dev (first payee) splits 60 / 30 / 10 with two partners; a taxed V3 token pays it; anyone binds it.
    function _setup(address quote, bool grad)
        internal
        returns (GangSplitModule m, address t, address dev, address b, address c)
    {
        dev = _newAgent();
        b = makeAddr(string.concat("kol", vm.toString(_salt)));
        c = makeAddr(string.concat("dao", vm.toString(_salt)));
        m = _module(dev, _list3(dev, b, c), _shares3(6_000, 3_000, 1_000));
        t = _createV3(dev, quote, _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t);
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        if (grad) _graduate(t);
    }

    function newFactory(address pad_, address admin_) external returns (GangSplitModuleFactory) {
        return new GangSplitModuleFactory(pad_, admin_, GANG);
    }

    function _next(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
    }

    function _bal(address asset, address who) internal view returns (uint256) {
        return IERC20(asset).balanceOf(who);
    }

    // ---------------------------------------------------------------- factory
    function test_factory_create() public {
        vm.expectRevert(GangSplitModuleFactory.ZeroAddress.selector);
        this.newFactory(address(pad), address(0));
        GangHandlerAdmin elsewhere = new GangHandlerAdmin(owner, makeAddr("otherHandler"));
        vm.expectRevert(GangSplitModuleFactory.WrongHandler.selector);
        this.newFactory(address(pad), address(elsewhere));

        address dev = _newAgent();
        address b = makeAddr("b");
        address c = makeAddr("c");
        vm.prank(makeAddr("notAgent"));
        vm.expectRevert(GangSplitModuleFactory.NotAgent.selector);
        factory.create(_list3(dev, b, c), _shares3(6_000, 3_000, 1_000), bytes32(0));

        bytes32 salt = keccak256("launch-1");
        address predicted = factory.predict(dev, salt);
        assertTrue(factory.predict(_newAgent(), salt) != predicted, "a salt is per dev");
        vm.expectEmit(address(factory));
        emit GangSplitModuleFactory.Created(dev, predicted, _list3(dev, b, c), _shares3(6_000, 3_000, 1_000));
        vm.prank(dev);
        address m = factory.create(_list3(dev, b, c), _shares3(6_000, 3_000, 1_000), salt);
        assertEq(m, predicted);
        vm.prank(dev);
        vm.expectRevert(Errors.FailedDeployment.selector);
        factory.create(_list3(dev, b, c), _shares3(6_000, 3_000, 1_000), salt);

        GangSplitModule sm = GangSplitModule(m);
        assertEq(sm.dev(), dev);
        assertEq(sm.token(), address(0));
        assertEq(sm.pad(), address(pad));
        assertEq(sm.taxHandler(), address(handler));
        assertEq(sm.factory(), address(factory));
        assertEq(sm.moduleType(), bytes32("split-v1"));
        assertEq(sm.gangQuote(), GANG);
        (address[] memory p, uint16[] memory s) = sm.payeesOf();
        assertEq(p.length, 3);
        assertEq(p[1], b);
        assertEq(s[1], 3_000);
        assertEq(sm.payeeCount(), 3);
        assertTrue(handler.isListed(m));
        assertEq(admin.moduleOf(m), address(factory));
        assertEq(factory.count(), 1);
        assertEq(factory.modules()[0], m);

        // the implementation is never initialized; a clone only once, only by the factory
        GangSplitModule impl = GangSplitModule(factory.implementation());
        vm.expectRevert(GangSplitModule.NotClone.selector);
        impl.initialize(dev, p, s);
        vm.expectRevert(GangSplitModule.NotFactory.selector);
        sm.initialize(dev, p, s);
        vm.prank(address(factory));
        vm.expectRevert(GangSplitModule.AlreadyInitialized.selector);
        sm.initialize(dev, p, s);
    }

    function test_factory_badLists() public {
        address dev = _newAgent();
        address b = makeAddr("b");
        address c = makeAddr("c");
        vm.startPrank(dev);

        vm.expectRevert(GangSplitModule.BadPayees.selector);
        factory.create(new address[](0), new uint16[](0), bytes32(uint256(1)));
        vm.expectRevert(GangSplitModule.BadPayees.selector);
        factory.create(_list3(dev, b, c), new uint16[](2), bytes32(uint256(2)));

        address[] memory eleven = new address[](11);
        uint16[] memory elevenS = new uint16[](11);
        for (uint256 i; i < 11; i++) {
            eleven[i] = address(uint160(0x1000 + i));
            elevenS[i] = 909;
        }
        elevenS[10] = 910;
        vm.expectRevert(GangSplitModule.BadPayees.selector);
        factory.create(eleven, elevenS, bytes32(uint256(3)));

        vm.expectRevert(GangSplitModule.BadShares.selector);
        factory.create(_list3(dev, b, c), _shares3(6_000, 3_000, 999), bytes32(uint256(4)));
        vm.expectRevert(GangSplitModule.BadShares.selector);
        factory.create(_list3(dev, b, c), _shares3(7_000, 3_000, 0), bytes32(uint256(5)));
        vm.expectRevert(GangSplitModule.ZeroAddress.selector);
        factory.create(_list3(dev, address(0), c), _shares3(6_000, 3_000, 1_000), bytes32(uint256(6)));
        vm.expectRevert(GangSplitModule.DuplicatePayee.selector);
        factory.create(_list3(dev, b, dev), _shares3(6_000, 3_000, 1_000), bytes32(uint256(7)));
        address selfAt = factory.predict(dev, bytes32(uint256(8)));
        vm.expectRevert(GangSplitModule.BadPayee.selector);
        factory.create(_list3(dev, b, selfAt), _shares3(6_000, 3_000, 1_000), bytes32(uint256(8)));

        // ten payees and one at 100% both work
        eleven[9] = address(uint160(0x2000));
        address[] memory ten = new address[](10);
        uint16[] memory tenS = new uint16[](10);
        for (uint256 i; i < 10; i++) {
            ten[i] = eleven[i];
            tenS[i] = 1_000;
        }
        factory.create(ten, tenS, bytes32(uint256(9)));
        address[] memory one = new address[](1);
        one[0] = dev;
        uint16[] memory oneS = new uint16[](1);
        oneS[0] = 10_000;
        factory.create(one, oneS, bytes32(uint256(10)));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- bind
    function test_bind_checks() public {
        address dev = _newAgent();
        GangSplitModule m = _module(dev, _list3(dev, makeAddr("b"), makeAddr("c")), _shares3(6_000, 3_000, 1_000));

        vm.expectRevert(GangSplitModule.NotCurve.selector);
        m.bind(makeAddr("nope"));
        address fair = _createFair(dev, address(wbnb), 100);
        vm.expectRevert(GangSplitModule.NotCurve.selector);
        m.bind(fair);
        address other = _createV3(_newAgent(), address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        vm.expectRevert(GangSplitModule.NotCreator.selector);
        m.bind(other);
        address own = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, dev));
        vm.expectRevert(GangSplitModule.NotRecipient.selector);
        m.bind(own);

        address t = _createV3(dev, address(quoteTok), _tax(TAX, TAX, 5_000, address(m)));
        vm.expectEmit(address(m));
        emit GangSplitModule.Bound(t, address(quoteTok));
        vm.prank(makeAddr("stranger"));
        m.bind(t);
        assertEq(m.token(), t);
        assertEq(m.quote(), address(quoteTok));
        vm.expectRevert(GangSplitModule.AlreadyBound.selector);
        m.bind(t);
    }

    // ---------------------------------------------------------------- distribute
    function test_distribute_byShares() public {
        (GangSplitModule m,, address dev, address b, address c) = _setup(address(wbnb), false);
        uint256 dev0 = _bal(address(wbnb), dev);
        wbnb.mintUnlimited(address(m), 10 ether);
        assertEq(m.undistributed(address(wbnb)), 10 ether);

        vm.expectEmit(address(m));
        emit GangSplitModule.Distributed(address(wbnb), 10 ether);
        vm.prank(makeAddr("anyone"));
        assertEq(m.distribute(address(wbnb)), 10 ether);
        assertEq(_bal(address(wbnb), dev) - dev0, 6 ether);
        assertEq(_bal(address(wbnb), b), 3 ether);
        assertEq(_bal(address(wbnb), c), 1 ether);
        assertEq(_bal(address(wbnb), address(m)), 0);
        assertEq(m.undistributed(address(wbnb)), 0);
        assertEq(m.lastDistributedAt(), block.timestamp);

        // nothing new: a no-op
        assertEq(m.distribute(address(wbnb)), 0);
    }

    /// @dev Rounding: the first payee takes what the others' rounded-down parts leave, nothing stays behind.
    function test_distribute_remainderToFirst() public {
        (GangSplitModule m,, address dev, address b, address c) = _setup(address(wbnb), false);
        uint256 dev0 = _bal(address(wbnb), dev);
        wbnb.mintUnlimited(address(m), 7);
        m.distribute(address(wbnb));
        // 7 × 30% = 2.1 → 2, 7 × 10% = 0.7 → 0, the first gets 5
        assertEq(_bal(address(wbnb), b), 2);
        assertEq(_bal(address(wbnb), c), 0);
        assertEq(_bal(address(wbnb), dev) - dev0, 5);
        assertEq(_bal(address(wbnb), address(m)), 0);
    }

    /// @dev Every asset splits at the same shares, bound or not: a stray asset before the binding too.
    function test_distribute_anyAssetAnyTime() public {
        address dev = _newAgent();
        address b = makeAddr("b");
        GangSplitModule m = _module(dev, _list3(dev, b, makeAddr("c")), _shares3(6_000, 3_000, 1_000));
        quoteTok.mintUnlimited(address(m), 10 ether);
        (bool due,) = m.previewWork();
        assertFalse(due, "unbound: nothing for the keeper");
        vm.prank(makeAddr("anyone"));
        assertEq(m.distribute(address(quoteTok)), 10 ether);
        assertEq(_bal(address(quoteTok), b), 3 ether);
        assertEq(m.lastDistributedAt(), 0, "the keeper clock is the bound quote's");
    }

    /// @dev Audit 2026-10-30 M-1: a dev binds a decoy token, then points the real token (another quote) at the same
    ///      module. Its tax still splits at the shares — the first payee can't take it all.
    function test_decoyBind_realTokenTaxStillSplit() public {
        address dev = _newAgent();
        address partner = makeAddr("partner");
        address[] memory p = new address[](2);
        (p[0], p[1]) = (dev, partner);
        uint16[] memory sh = new uint16[](2);
        (sh[0], sh[1]) = (1_000, 9_000);
        GangSplitModule m = _module(dev, p, sh);
        address decoy = _createV3(dev, address(wbnb), _tax(TAX, TAX, 0, address(m)));
        m.bind(decoy);
        address t = _createV3(dev, address(quoteTok), _tax(TAX, TAX, 0, address(m)));
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
        address pair = _curvePair(t);
        for (uint256 i; i < 5; i++) {
            address seller = _newAgent();
            (uint256 rT,) = _reserves(t, pair);
            deal(t, seller, rT / 50);
            _poolSell(t, pair, seller, rT / 50);
            _next(1 minutes);
        }
        uint256 chunk = handler.maxChunk(t);
        vm.prank(keeper);
        handler.process(t, chunk, 1);
        uint256 got = m.undistributed(address(quoteTok));
        assertGt(got, 0, "the real token's tax arrived");
        m.distribute(address(quoteTok));
        assertEq(_bal(address(quoteTok), partner), (got * 9_000) / 10_000, "the partner's 90%");
    }

    // ---------------------------------------------------------------- owed
    /// @dev A payee the quote blacklists is owed; the others are paid; release pushes it once it can receive.
    function test_owed_blockedPayeeDoesNotBlockOthers() public {
        (GangSplitModule m,, address dev, address b, address c) = _setup(BQ, false);
        blq.setBlocked(b, true);
        blq.mint(address(m), 10 ether);
        uint256 dev0 = _bal(BQ, dev);

        vm.expectEmit(address(m));
        emit GangSplitModule.PayeeOwed(BQ, 1, 3 ether);
        m.distribute(BQ);
        assertEq(_bal(BQ, dev) - dev0, 6 ether);
        assertEq(_bal(BQ, c), 1 ether);
        assertEq(m.owedOf(BQ, 1), 3 ether);
        assertEq(m.owedTotal(BQ), 3 ether);
        assertEq(m.undistributed(BQ), 0, "owed quote is not split again");

        // more tax: split again, b's part adds up
        blq.mint(address(m), 10 ether);
        m.distribute(BQ);
        assertEq(m.owedOf(BQ, 1), 6 ether);

        vm.expectRevert("blacklisted");
        m.release(BQ, 1, ALL);
        vm.expectRevert(GangSplitModule.NothingOwed.selector);
        m.release(BQ, 0, ALL);
        vm.expectRevert(GangSplitModule.BadIndex.selector);
        m.release(BQ, 3, ALL);

        blq.setBlocked(b, false);
        vm.expectEmit(address(m));
        emit GangSplitModule.PayeeReleased(BQ, 1, 6 ether);
        vm.prank(makeAddr("anyone"));
        assertEq(m.release(BQ, 1, ALL), 6 ether);
        assertEq(_bal(BQ, b), 6 ether);
        assertEq(m.owedTotal(BQ), 0);
    }

    /// @dev Audit L-3: a slot that can receive again gets what it is owed with its next push, no release needed.
    function test_owed_goesOutWithTheNextPush() public {
        (GangSplitModule m,,, address b,) = _setup(BQ, false);
        blq.setBlocked(b, true);
        blq.mint(address(m), 10 ether);
        m.distribute(BQ);
        assertEq(m.owedOf(BQ, 1), 3 ether);
        blq.setBlocked(b, false);
        blq.mint(address(m), 10 ether);
        vm.expectEmit(address(m));
        emit GangSplitModule.PayeeReleased(BQ, 1, 3 ether);
        m.distribute(BQ);
        assertEq(_bal(BQ, b), 6 ether);
        assertEq(m.owedOf(BQ, 1), 0);
        assertEq(m.owedTotal(BQ), 0);
        assertEq(_bal(BQ, address(m)), 0);
    }

    /// @dev Audit L-1: a quote whose refusal burns all the gas it gets costs at most PUSH_GAS per payee; the split
    ///      fits a normal gas limit and the other payees are paid.
    function test_owed_gasBurningRefusalIsCapped() public {
        address dev = _newAgent();
        address[] memory p = new address[](10);
        uint16[] memory sh = new uint16[](10);
        for (uint256 i; i < 10; i++) {
            p[i] = i == 0 ? dev : address(uint160(0xA000 + i));
            sh[i] = 1_000;
        }
        GangSplitModule m = _module(dev, p, sh);
        GasBurnQuote g = new GasBurnQuote();
        g.setBlocked(p[3], true);
        g.mint(address(m), 10 ether);
        m.distribute{gas: 2_000_000}(address(g));
        assertEq(m.owedOf(address(g), 3), 1 ether);
        assertEq(g.balanceOf(p[4]), 1 ether);
        assertEq(g.balanceOf(dev), 1 ether);
    }

    /// @dev Re-review NEW-1: with a per-transfer cap, an owed amount too big to move at once must not hold up the
    ///      slot's new parts; it can be released in parts.
    function test_owed_overCapDoesNotLockTheSlot() public {
        address dev = _newAgent();
        address b = makeAddr("capped");
        address[] memory p = new address[](2);
        (p[0], p[1]) = (dev, b);
        uint16[] memory sh = new uint16[](2);
        (sh[0], sh[1]) = (5_000, 5_000);
        GangSplitModule m = _module(dev, p, sh);
        MaxTxQuote q = new MaxTxQuote();
        q.setBlocked(b, true);
        for (uint256 i; i < 3; i++) {
            q.mint(address(m), 4 ether);
            m.distribute(address(q));
        }
        assertEq(m.owedOf(address(q), 1), 6 ether, "over the 5 cap");
        q.setBlocked(b, false);

        // new parts go through; the owed 6 can't move at once and stays owed
        q.mint(address(m), 4 ether);
        m.distribute(address(q));
        assertEq(q.balanceOf(b), 2 ether);
        assertEq(m.owedOf(address(q), 1), 6 ether);
        vm.expectRevert("maxTx");
        m.release(address(q), 1, ALL);
        // in parts it does
        assertEq(m.release(address(q), 1, 5 ether), 5 ether);
        assertEq(m.owedOf(address(q), 1), 1 ether);
        // and the rest goes with the next push
        q.mint(address(m), 4 ether);
        m.distribute(address(q));
        assertEq(q.balanceOf(b), 10 ether);
        assertEq(m.owedTotal(address(q)), 0);
    }

    /// @dev Re-review NEW-2: a GangToken (dividend sync on transfer, ≈ 121k gas) fits PUSH_GAS and is paid, not owed.
    function test_distribute_gangTokenAsAsset() public {
        (GangSplitModule m, address t, address dev, address b,) = _setup(address(wbnb), true);
        uint256 amt = IERC20(t).balanceOf(dev) / 2;
        vm.prank(dev);
        IERC20(t).transfer(address(m), amt);
        uint256 dev0 = IERC20(t).balanceOf(dev);
        m.distribute(t);
        assertEq(m.owedTotal(t), 0, "nothing owed");
        assertEq(IERC20(t).balanceOf(b), (amt * 3_000) / 10_000);
        assertGt(IERC20(t).balanceOf(dev), dev0);
    }

    /// @dev Re-review I-1: a hostile asset returning a huge blob costs its split little (≤ 32 bytes copied).
    function test_distribute_returnBombIsCheap() public {
        address dev = _newAgent();
        address[] memory p = new address[](10);
        uint16[] memory sh = new uint16[](10);
        for (uint256 i; i < 10; i++) {
            p[i] = i == 0 ? dev : address(uint160(0xC000 + i));
            sh[i] = 1_000;
        }
        GangSplitModule m = _module(dev, p, sh);
        ReturnBombAsset bomb = new ReturnBombAsset();
        uint256 g = gasleft();
        m.distribute(address(bomb));
        assertLt(g - gasleft(), 2_000_000, "bounded");
        assertEq(m.owedTotal(address(bomb)), 10 ether, "a garbage return is a failure: owed");
    }

    /// @dev Re-review 2 Info-1: at no gas limit does a split succeed with a push starved by 63/64 (a heavy token's
    ///      owed push included): it reverts instead, so the owed part is never skipped by a tight gas limit.
    function test_owed_pushCantBeStarved() public {
        _assertNoStarvedPush(new HeavyQuote());
    }

    /// @dev Pre-testnet review L-1: the same through a proxy (the outer frame hands back the inner 1/64, which fooled
    ///      a check after the call).
    function test_owed_pushCantBeStarvedBehindProxy() public {
        _assertNoStarvedPush(HeavyQuote(address(new ERC1967Proxy(address(new HeavyQuote()), ""))));
    }

    function _assertNoStarvedPush(HeavyQuote q) internal {
        address dev = _newAgent();
        address[] memory p = new address[](2);
        (p[0], p[1]) = (dev, makeAddr("hb"));
        uint16[] memory sh = new uint16[](2);
        (sh[0], sh[1]) = (5_000, 5_000);
        GangSplitModule m = _module(dev, p, sh);
        q.setBlocked(dev, true);
        q.mint(address(m), 8 ether);
        m.distribute(address(q));
        assertEq(m.owedOf(address(q), 0), 4 ether);
        q.setBlocked(dev, false);
        q.mint(address(m), 2 ether);
        uint256 firstOk;
        for (uint256 g = 500_000; g <= 1_200_000; g += 1_000) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(m).call{gas: g}(abi.encodeCall(GangSplitModule.distribute, (address(q))));
            if (ok) {
                if (firstOk == 0) firstOk = g;
                assertEq(m.owedOf(address(q), 0), 0, "succeeded with the owed push starved");
            }
            vm.revertToState(snap);
        }
        assertGt(firstOk, 0, "some limit works");
    }

    /// @dev What `_tryTransfer` counts as a transfer: no return data (USDT-style), a 32-byte (or longer) word 1; a
    ///      word 2, false or 31 bytes is booked as owed (the coins moved anyway: the next split's shortfall
    ///      corrects it).
    function test_tryTransfer_returnShapes() public {
        assertEq(_shapeOwed(0, 0), 0, "no return data");
        assertEq(_shapeOwed(32, 1), 0, "32 bytes true");
        assertEq(_shapeOwed(64, 1), 0, "64 bytes, first word 1");
        assertEq(_shapeOwed(32, 2), 10 ether, "word 2");
        assertEq(_shapeOwed(32, 0), 10 ether, "false");
        assertEq(_shapeOwed(31, 0), 10 ether, "31 bytes");
    }

    function _shapeOwed(uint256 len, uint256 w) internal returns (uint256) {
        address dev = _newAgent();
        address[] memory p = new address[](2);
        (p[0], p[1]) = (dev, makeAddr(string.concat("rs", vm.toString(len), "_", vm.toString(w))));
        uint16[] memory sh = new uint16[](2);
        (sh[0], sh[1]) = (5_000, 5_000);
        GangSplitModule m = _module(dev, p, sh);
        RetShapeQuote r = new RetShapeQuote();
        r.set(len, w);
        r.mint(address(m), 10 ether);
        m.distribute(address(r));
        return m.owedTotal(address(r));
    }

    // ---------------------------------------------------------------- setPayee
    function test_setPayee_onlyThatPayee() public {
        (GangSplitModule m,, address dev, address b, address c) = _setup(BQ, false);
        address fresh = makeAddr("fresh");

        // not the dev, not another payee, only b itself
        vm.prank(dev);
        vm.expectRevert(GangSplitModule.NotPayee.selector);
        m.setPayee(1, fresh);
        vm.prank(c);
        vm.expectRevert(GangSplitModule.NotPayee.selector);
        m.setPayee(1, fresh);
        vm.startPrank(b);
        vm.expectRevert(GangSplitModule.BadIndex.selector);
        m.setPayee(3, fresh);
        vm.expectRevert(GangSplitModule.ZeroAddress.selector);
        m.setPayee(1, address(0));
        vm.expectRevert(GangSplitModule.BadPayee.selector);
        m.setPayee(1, address(m));
        vm.expectRevert(GangSplitModule.DuplicatePayee.selector);
        m.setPayee(1, c);
        vm.stopPrank();

        // b blacklisted: owed; what arrived before the move is split first; the owed part follows b to the new address
        blq.setBlocked(b, true);
        blq.mint(address(m), 10 ether);
        m.distribute(BQ);
        assertEq(m.owedOf(BQ, 1), 3 ether);
        blq.mint(address(m), 10 ether);
        vm.expectEmit(address(m));
        emit GangSplitModule.PayeeChanged(1, b, fresh);
        vm.prank(b);
        m.setPayee(1, fresh);
        assertEq(m.owedOf(BQ, 1), 6 ether, "split before the move: b's part owed");
        assertEq(m.release(BQ, 1, ALL), 6 ether);
        assertEq(_bal(BQ, fresh), 6 ether);

        // the share stays with the slot
        blq.mint(address(m), 10 ether);
        m.distribute(BQ);
        assertEq(_bal(BQ, fresh), 9 ether);
        (address[] memory p, uint16[] memory s) = m.payeesOf();
        assertEq(p[1], fresh);
        assertEq(s[1], 3_000);
        // b can't move it any more
        vm.prank(b);
        vm.expectRevert(GangSplitModule.NotPayee.selector);
        m.setPayee(1, b);
    }

    // ---------------------------------------------------------------- shortfall
    /// @dev A quote balance that shrinks below what is owed must not lock the module: the owed parts shrink in
    ///      proportion, and release shares a shortfall nobody split yet before paying.
    function test_shortfall_sharedInProportion() public {
        (GangSplitModule m,, address dev, address b, address c) = _setup(BQ, false);
        blq.setBlocked(b, true);
        blq.setBlocked(c, true);
        blq.mint(address(m), 10 ether);
        m.distribute(BQ); // 3 owed to b, 1 to c
        assertEq(m.owedTotal(BQ), 4 ether);

        deal(BQ, address(m), 2 ether); // half taken
        assertEq(m.undistributed(BQ), 0);
        blq.setBlocked(b, false);
        // release splits first: b gets its shrunk part, not all of it at c's expense
        assertEq(m.release(BQ, 1, ALL), 1.5 ether);
        assertEq(m.owedOf(BQ, 2), 0.5 ether);
        assertEq(m.owedTotal(BQ), 0.5 ether);
        assertEq(_bal(BQ, address(m)), 0.5 ether);

        // and keeps working
        blq.mint(address(m), 10 ether);
        uint256 dev0 = _bal(BQ, dev);
        m.distribute(BQ);
        assertEq(_bal(BQ, dev) - dev0, 6 ether);
        assertEq(m.owedOf(BQ, 2), 1.5 ether);

        // all of it taken: nothing owed is left
        deal(BQ, address(m), 0);
        vm.expectEmit(address(m));
        emit GangSplitModule.Shortfall(BQ, 1.5 ether);
        m.distribute(BQ);
        assertEq(m.owedTotal(BQ), 0);
        blq.setBlocked(c, false);
        vm.expectRevert(GangSplitModule.NothingOwed.selector);
        m.release(BQ, 2, ALL);
    }

    // ---------------------------------------------------------------- invariant
    /// @dev For any shares and arrivals, with some payees blocked: what went out plus what is owed is what came in,
    ///      owedTotal is the sum of the slots, and the module holds exactly what it owes.
    function testFuzz_accountsAddUp(uint256 seed, uint96 a1, uint96 a2, uint8 blockedMask) public {
        address dev = _newAgent();
        uint256 n = 1 + (seed % 10);
        address[] memory p = new address[](n);
        uint16[] memory sh = new uint16[](n);
        uint256 left = 10_000;
        for (uint256 i; i < n; i++) {
            p[i] = i == 0 ? dev : address(uint160(0xB000 + i));
            uint256 x = i == n - 1 ? left : 1 + (uint256(keccak256(abi.encode(seed, i))) % (left - (n - 1 - i)));
            sh[i] = uint16(x);
            left -= x;
        }
        GangSplitModule m = _module(dev, p, sh);
        for (uint256 i; i < n; i++) {
            if (blockedMask & (1 << (i % 8)) != 0) blq.setBlocked(p[i], true);
        }
        uint256 paidBefore;
        for (uint256 i; i < n; i++) {
            paidBefore += _bal(BQ, p[i]);
        }
        blq.mint(address(m), a1);
        m.distribute(BQ);
        blq.mint(address(m), a2);
        m.distribute(BQ);
        uint256 paid;
        uint256 owed;
        for (uint256 i; i < n; i++) {
            paid += _bal(BQ, p[i]);
            owed += m.owedOf(BQ, i);
        }
        assertEq(paid - paidBefore + owed, uint256(a1) + a2, "in = out + owed");
        assertEq(m.owedTotal(BQ), owed, "owedTotal = sum of slots");
        assertEq(_bal(BQ, address(m)), owed, "holds what it owes");
    }

    /// @dev Re-review 2: many rounds with payees blocked and unblocked at random (both the owed push that works and
    ///      the one too big for the cap) and partial releases: in = out + owed and owedTotal = Σ slots every round.
    function testFuzz_roundsAddUp(uint256 seed) public {
        address dev = _newAgent();
        uint256 n = 1 + (seed % 10);
        address[] memory p = new address[](n);
        uint16[] memory sh = new uint16[](n);
        uint256 left = 10_000;
        for (uint256 i; i < n; i++) {
            p[i] = i == 0 ? dev : address(uint160(0xF000 + i));
            uint256 x = i == n - 1 ? left : 1 + (uint256(keccak256(abi.encode(seed, i))) % (left - (n - 1 - i)));
            sh[i] = uint16(x);
            left -= x;
        }
        GangSplitModule m = _module(dev, p, sh);
        MaxTxQuote q = new MaxTxQuote();
        uint256 minted;
        for (uint256 r; r < 8; r++) {
            uint256 h = uint256(keccak256(abi.encode(seed, r, "r")));
            for (uint256 i; i < n; i++) {
                q.setBlocked(p[i], (h >> i) & 1 == 1);
            }
            uint256 a = (h >> 32) % 12 ether;
            q.mint(address(m), a);
            minted += a;
            m.distribute(address(q));
            uint256 idx = (h >> 100) % n;
            uint256 mx = (h >> 140) % 7 ether;
            uint256 o = m.owedOf(address(q), idx);
            if (!q.blocked(p[idx]) && o != 0 && mx != 0 && (o < mx ? o : mx) <= 5 ether) {
                m.release(address(q), idx, mx);
            }
            uint256 owed;
            uint256 paid;
            for (uint256 i; i < n; i++) {
                owed += m.owedOf(address(q), i);
                paid += q.balanceOf(p[i]);
            }
            assertEq(m.owedTotal(address(q)), owed, "owedTotal = sum");
            assertEq(q.balanceOf(address(m)), owed, "held = owed");
            assertEq(paid + owed, minted, "in = out + owed");
        }
    }

    // ---------------------------------------------------------------- keeper
    function test_work_dueAboveMinimumOrAfterIdle() public {
        (GangSplitModule m, address t,,,) = _setup(address(wbnb), false);
        wbnb.mintUnlimited(address(m), 1 ether);
        (bool due,) = m.previewWork();
        assertFalse(due, "not before graduation");

        _graduate(t);
        (, uint256 rQ) = _reserves(t, _curvePair(t));
        uint256 min = (rQ * m.WORK_MIN_BPS()) / 10_000;
        // over the minimum: due
        (due,) = m.previewWork();
        assertTrue(due);
        m.work(0);
        assertEq(m.undistributed(address(wbnb)), 0);

        // under the minimum: not due until WORK_MAX_IDLE since the last one
        wbnb.mintUnlimited(address(m), min - 1);
        (due,) = m.previewWork();
        assertFalse(due);
        _next(m.WORK_MAX_IDLE() - 1);
        (due,) = m.previewWork();
        assertFalse(due);
        _next(1);
        (due,) = m.previewWork();
        assertTrue(due);
        m.work(0);

        // dust (under 1/WORK_IDLE_DIV of the minimum) is never due, not even idle (audit L-2)
        wbnb.mintUnlimited(address(m), min / m.WORK_IDLE_DIV() - 1);
        _next(m.WORK_MAX_IDLE());
        (due,) = m.previewWork();
        assertFalse(due, "dust");
        m.distribute(address(wbnb));

        // at the minimum: due at once
        wbnb.mintUnlimited(address(m), min);
        uint256 minOut;
        (due, minOut) = m.previewWork();
        assertTrue(due);
        assertEq(minOut, 0);
        vm.prank(keeper);
        m.work(0);
        (due,) = m.previewWork();
        assertFalse(due, "nothing left");
    }

    /// @dev Pre-testnet review M-1: the keeper serves only WBNB, GANG and QuoteRegistry quotes; a module bound to
    ///      any other quote is never due (a quote lying about its balance can't make every round a split), and is
    ///      still split by hand.
    function test_work_onlyServedQuotes() public {
        (GangSplitModule m,,,,) = _setup(address(quoteTok), true);
        assertTrue(m.keeperServes(address(wbnb)));
        assertTrue(m.keeperServes(GANG));
        assertTrue(m.keeperServes(address(quoteTok)), "a QuoteRegistry quote");
        assertFalse(m.keeperServes(makeAddr("other")));
        assertFalse(m.keeperServes(address(0)));
        quoteTok.mintUnlimited(address(m), 1 ether);
        (bool due,) = m.previewWork();
        assertTrue(due);

        // the same quote off the registry: never due, not even idle; distribute still works
        vm.prank(owner);
        quoteRegistry.setQuote(address(quoteTok), false, 0);
        assertFalse(m.keeperServes(address(quoteTok)));
        (due,) = m.previewWork();
        assertFalse(due);
        _next(m.WORK_MAX_IDLE());
        (due,) = m.previewWork();
        assertFalse(due);
        assertEq(m.distribute(address(quoteTok)), 1 ether);
    }

    function test_work_listedForTheKeeper() public {
        (GangSplitModule m,,,,) = _setup(address(wbnb), false);
        address[] memory mods = admin.modules();
        assertEq(mods[mods.length - 1], address(m));
    }

    // ---------------------------------------------------------------- deploy script
    function test_script_check() public {
        DeployGangSplitModuleFactory script = new DeployGangSplitModuleFactory();
        script.check(address(pad), address(admin), address(factory));
        assertEq(script.pendingBatch(address(admin), address(factory)).length, 0);

        GangHandlerAdmin rogue = new GangHandlerAdmin(makeAddr("notTheSafe"), address(handler));
        GangSplitModuleFactory rogueFactory = new GangSplitModuleFactory(address(pad), address(rogue), GANG);
        vm.expectRevert(abi.encodeWithSelector(DeployGangSplitModuleFactory.WiringCheck.selector, "admin.handlerOwner"));
        script.check(address(pad), address(rogue), address(rogueFactory));
        vm.expectRevert(abi.encodeWithSelector(DeployGangSplitModuleFactory.WiringCheck.selector, "factory.admin"));
        script.check(address(pad), address(admin), address(rogueFactory));
        vm.expectRevert(abi.encodeWithSelector(DeployGangSplitModuleFactory.WiringCheck.selector, "factory.code"));
        script.check(address(pad), address(admin), makeAddr("eoa"));

        // the runtime code: the real factory passes; a look-alike answering every view the same does not (audit L-4)
        script.checkCode(address(factory));
        FakeSplitImpl fakeImpl = new FakeSplitImpl(address(pad), address(handler));
        FakeSplitFactory fake = new FakeSplitFactory(address(pad), address(admin), address(fakeImpl));
        fakeImpl.setFactory(address(fake));
        script.check(address(pad), address(admin), address(fake));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGangSplitModuleFactory.WiringCheck.selector, "factory.runtimeCode")
        );
        script.checkCode(address(fake));

        // a new factory on the live admin: one Safe call, and it works as printed
        GangSplitModuleFactory f2 = new GangSplitModuleFactory(address(pad), address(admin), GANG);
        bytes[] memory batch = script.pendingBatch(address(admin), address(f2));
        assertEq(batch.length, 1);
        bytes memory c = batch[0];
        address to;
        assembly ("memory-safe") {
            to := shr(96, mload(add(c, 32)))
        }
        bytes memory data = new bytes(c.length - 20);
        for (uint256 j; j < data.length; j++) {
            data[j] = c[j + 20];
        }
        assertEq(to, address(admin));
        vm.prank(owner);
        (bool ok,) = to.call(data);
        assertTrue(ok);
        assertTrue(admin.isFactory(address(f2)));
        assertEq(script.pendingBatch(address(admin), address(f2)).length, 0);

        // an admin that doesn't own the handler yet is refused (the buy-back script does the takeover)
        vm.startPrank(owner);
        admin.exec(abi.encodeWithSignature("transferOwnership(address)", owner));
        handler.acceptOwnership();
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(DeployGangSplitModuleFactory.WiringCheck.selector, "admin.handlerOwner"));
        script.check(address(pad), address(admin), address(factory));
    }

    // ---------------------------------------------------------------- end to end
    /// @dev Pool sells pay the tax; the handler's chunks pay the module; the keeper's work splits it 60 / 30 / 10.
    function test_e2e_poolTaxPaysSplit() public {
        (GangSplitModule m, address t, address dev, address b, address c) = _setup(address(wbnb), true);
        address pair = _curvePair(t);
        uint256 dev0 = _bal(address(wbnb), dev);

        for (uint256 i; i < 5; i++) {
            address seller = _newAgent();
            (uint256 rT,) = _reserves(t, pair);
            deal(t, seller, rT / 50);
            _poolSell(t, pair, seller, rT / 50);
            _next(1 minutes);
        }
        uint256 chunk = handler.maxChunk(t);
        vm.prank(keeper);
        handler.process(t, chunk, 1);
        uint256 got = m.undistributed(address(wbnb));
        assertGt(got, 0, "recipient part arrived");

        (bool due, uint256 minOut) = m.previewWork();
        assertTrue(due);
        vm.prank(keeper);
        m.work(minOut);
        uint256 toB = (got * 3_000) / 10_000;
        uint256 toC = (got * 1_000) / 10_000;
        assertEq(_bal(address(wbnb), b), toB);
        assertEq(_bal(address(wbnb), c), toC);
        assertEq(_bal(address(wbnb), dev) - dev0, got - toB - toC);
        assertEq(_bal(address(wbnb), address(m)), 0);
    }
}
