// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {LpMockPair, LpMockPairFactory} from "../mocks/LpMockPair.sol";
import {GasBurnQuote} from "./GangSplitModule.t.sol";
import {GangCappedSplitter} from "../../src/gang/GangCappedSplitter.sol";
import {GangCappedSplitterFactory} from "../../src/gang/GangCappedSplitterFactory.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {DeployGangCappedSplitterFactory} from "../../script/DeployGangCappedSplitterFactory.s.sol";

/// @dev Answers every view the deploy script's `check` reads like a real factory / implementation, with other code.
contract FakeCappedImpl {
    address public pad;
    address public taxHandler;
    address public factory;
    bytes32 public constant moduleType = "capped-v1";
    address public constant gangQuote = address(0x6A46);

    constructor(address pad_, address handler_) {
        (pad, taxHandler) = (pad_, handler_);
    }

    function setFactory(address f) external {
        factory = f;
    }
}

contract FakeCappedFactory {
    address public pad;
    address public admin;
    address public implementation;

    constructor(address pad_, address admin_, address impl_) {
        (pad, admin, implementation) = (pad_, admin_, impl_);
    }
}

/// @notice GangCappedSplitter (税收封顶) on the whole merged deployment, over pairs that keep the V2 oracle and mint LP
///         as UniswapV2Pair does: the factory's checks, binding (with the cap's quote), the split before, across and
///         after the cap to the wei, payees (owed counts against the cap, release, moving a slot), other assets (all
///         to 0xdead), shortfalls, both chunk kinds, the keeper's plan, the deploy script, the pool tax end to end,
///         and the cap's invariants under random arrivals.
contract GangCappedSplitterTest is GangFixture {
    address keeper = makeAddr("keeper");
    GangHandlerAdmin admin;
    GangCappedSplitterFactory factory;
    uint256 _salt;

    uint16 constant TAX = 300;
    uint256 constant ALL = type(uint256).max;
    address constant GANG = address(0x6A46);
    uint256 constant VALUE = (uint256(1) << 248) - 1;

    function _newPairFactory() internal override returns (address) {
        return address(new LpMockPairFactory());
    }

    function setUp() public {
        _deployGang(keeper);
        admin = new GangHandlerAdmin(owner, address(handler));
        vm.startPrank(owner);
        handler.transferOwnership(address(admin));
        admin.exec(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        vm.stopPrank();
        factory = new GangCappedSplitterFactory(address(pad), address(admin), GANG);
        vm.prank(owner);
        admin.setFactory(address(factory), true);
    }

    // ---------------------------------------------------------------- helpers
    function _list(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        (p[0], p[1]) = (a, b);
    }

    function _shares(uint16 a, uint16 b) internal pure returns (uint16[] memory s) {
        s = new uint16[](2);
        (s[0], s[1]) = (a, b);
    }

    function _one(address a) internal pure returns (address[] memory p, uint16[] memory s) {
        p = new address[](1);
        p[0] = a;
        s = new uint16[](1);
        s[0] = 10_000;
    }

    function _capped(
        address dev,
        address q,
        uint256 cap,
        uint16 pay,
        uint16 bbRest,
        address[] memory p,
        uint16[] memory s
    ) internal returns (GangCappedSplitter m) {
        vm.prank(dev);
        m = GangCappedSplitter(factory.create(q, cap, pay, bbRest, p, s, bytes32(++_salt)));
    }

    /// @dev Cap `cap`, 50% to the payees (the dev 70%, a KOL 30%) until it is reached, the rest 70% buy-back / 30%
    ///      liquidity; a taxed V3 token over `quote` pays it.
    function _setup(address quote, uint256 cap, bool grad)
        internal
        returns (GangCappedSplitter m, address t, address dev, address kol)
    {
        dev = _newAgent();
        kol = makeAddr(string.concat("kol", vm.toString(_salt)));
        m = _capped(dev, quote, cap, 5_000, 7_000, _list(dev, kol), _shares(7_000, 3_000));
        t = _createV3(dev, quote, _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t);
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        if (grad) _graduate(t);
    }

    /// @dev As `_setup` with chosen ratios; graduated.
    function _setupR(uint256 cap, uint16 pay, uint16 bbRest)
        internal
        returns (GangCappedSplitter m, address t, address dev, address kol)
    {
        dev = _newAgent();
        kol = makeAddr(string.concat("kolR", vm.toString(_salt)));
        m = _capped(dev, address(wbnb), cap, pay, bbRest, _list(dev, kol), _shares(5_000, 5_000));
        t = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t);
        _graduate(t);
    }

    function newFactory(address pad_, address admin_) external returns (GangCappedSplitterFactory) {
        return new GangCappedSplitterFactory(pad_, admin_, GANG);
    }

    /// @dev vm.getBlockTimestamp(): the optimizer may reuse an earlier `block.timestamp` read in the same test.
    function _next(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(block.number + 1);
    }

    function _bal(address asset, address who) internal view returns (uint256) {
        return IERC20(asset).balanceOf(who);
    }

    function _lp(address t, address who) internal view returns (uint256) {
        return LpMockPair(_curvePair(t)).balanceOf(who);
    }

    /// @dev The split `_partsOf` makes, recomputed here.
    function _parts(uint256 x, uint256 paid, uint256 cap, uint256 pay, uint256 bbRest)
        internal
        pure
        returns (uint256 toP, uint256 toB, uint256 toL)
    {
        toP = (x * pay) / 10_000;
        if (toP > cap - paid) toP = cap - paid;
        uint256 rest = x - toP;
        toB = (rest * bbRest) / 10_000;
        toL = rest - toB;
    }

    // ---------------------------------------------------------------- factory
    function test_factory_checks() public {
        vm.expectRevert(GangCappedSplitterFactory.ZeroAddress.selector);
        this.newFactory(address(pad), address(0));
        GangHandlerAdmin elsewhere = new GangHandlerAdmin(owner, makeAddr("otherHandler"));
        vm.expectRevert(GangCappedSplitterFactory.WrongHandler.selector);
        this.newFactory(address(pad), address(elsewhere));

        address dev = _newAgent();
        address b = makeAddr("b");
        address w = address(wbnb);
        address[] memory two = _list(dev, b);
        uint16[] memory half = _shares(5_000, 5_000);
        vm.prank(makeAddr("notAgent"));
        vm.expectRevert(GangCappedSplitterFactory.NotAgent.selector);
        factory.create(w, 1 ether, 5_000, 5_000, two, half, bytes32(0));

        vm.startPrank(dev);
        vm.expectRevert(GangCappedSplitter.ZeroAddress.selector);
        factory.create(address(0), 1 ether, 5_000, 5_000, two, half, bytes32(0));
        vm.expectRevert(GangCappedSplitter.BadQuote.selector); // not a quote the keeper serves (audit L-1)
        factory.create(makeAddr("devsOwnQuote"), 1 ether, 5_000, 5_000, two, half, bytes32(0));
        vm.expectRevert(GangCappedSplitter.BadCap.selector);
        factory.create(w, 0, 5_000, 5_000, two, half, bytes32(0));
        vm.expectRevert(GangCappedSplitter.BadBps.selector);
        factory.create(w, 1 ether, 0, 5_000, two, half, bytes32(0));
        vm.expectRevert(GangCappedSplitter.BadBps.selector);
        factory.create(w, 1 ether, 10_001, 5_000, two, half, bytes32(0));
        vm.expectRevert(GangCappedSplitter.BadBps.selector);
        factory.create(w, 1 ether, 5_000, 10_001, two, half, bytes32(0));
        vm.expectRevert(GangCappedSplitter.BadPayees.selector); // no payees
        factory.create(w, 1 ether, 5_000, 5_000, new address[](0), new uint16[](0), bytes32(0));
        vm.expectRevert(GangCappedSplitter.BadPayees.selector);
        factory.create(w, 1 ether, 5_000, 5_000, two, new uint16[](1), bytes32(0));
        address[] memory eleven = new address[](11);
        uint16[] memory elevenS = new uint16[](11);
        for (uint256 i; i < 11; i++) {
            eleven[i] = address(uint160(0x1000 + i));
            elevenS[i] = i == 0 ? 1_000 : 900;
        }
        vm.expectRevert(GangCappedSplitter.BadPayees.selector);
        factory.create(w, 1 ether, 5_000, 5_000, eleven, elevenS, bytes32(0));
        vm.expectRevert(GangCappedSplitter.ZeroAddress.selector);
        factory.create(w, 1 ether, 5_000, 5_000, _list(dev, address(0)), half, bytes32(0));
        vm.expectRevert(GangCappedSplitter.DuplicatePayee.selector);
        factory.create(w, 1 ether, 5_000, 5_000, _list(dev, dev), half, bytes32(0));
        vm.expectRevert(GangCappedSplitter.BadShares.selector);
        factory.create(w, 1 ether, 5_000, 5_000, two, _shares(10_000, 0), bytes32(0));
        vm.expectRevert(GangCappedSplitter.BadShares.selector);
        factory.create(w, 1 ether, 5_000, 5_000, two, _shares(5_000, 4_999), bytes32(0));
        vm.stopPrank();

        bytes32 salt = keccak256("launch-1");
        address predicted = factory.predict(dev, salt);
        vm.expectEmit(address(factory));
        emit GangCappedSplitterFactory.Created(dev, predicted, w, 20 ether, 10_000, 0, two, _shares(6_000, 4_000));
        vm.prank(dev);
        GangCappedSplitter m =
            GangCappedSplitter(factory.create(w, 20 ether, 10_000, 0, two, _shares(6_000, 4_000), salt));
        assertEq(address(m), predicted);
        assertEq(m.moduleType(), bytes32("capped-v1"));
        assertEq(m.dev(), dev);
        assertEq(m.capQuote(), w);
        assertEq(m.capAmount(), 20 ether);
        assertEq(m.payBps(), 10_000);
        assertEq(m.buybackOfRestBps(), 0);
        assertEq(m.paidTotal(), 0);
        assertEq(m.capLeft(), 20 ether);
        assertFalse(m.capReached());
        (address[] memory p, uint16[] memory s) = m.payeesOf();
        assertEq(p.length, 2);
        assertEq(p[1], b);
        assertEq(s[0], 6_000);
        assertEq(admin.moduleOf(address(m)), address(factory));
        assertTrue(handler.isListed(address(m)));
        assertEq(factory.count(), 1);
        vm.prank(dev);
        vm.expectRevert();
        factory.create(w, 20 ether, 10_000, 0, two, _shares(6_000, 4_000), salt); // the address is taken

        // only the factory initializes, once; the implementation never
        vm.expectRevert(GangCappedSplitter.NotFactory.selector);
        m.initialize(dev, w, 1, 1, 0, two, half);
        vm.prank(address(factory));
        vm.expectRevert(GangCappedSplitter.AlreadyInitialized.selector);
        m.initialize(dev, w, 1, 1, 0, two, half);
        GangCappedSplitter impl = GangCappedSplitter(factory.implementation());
        vm.prank(address(factory));
        vm.expectRevert(GangCappedSplitter.NotClone.selector);
        impl.initialize(dev, w, 1, 1, 0, two, half);
    }

    function test_bind_checks() public {
        address dev = _newAgent();
        GangCappedSplitter m =
            _capped(dev, address(wbnb), 1 ether, 5_000, 5_000, _list(dev, makeAddr("k")), _shares(5_000, 5_000));
        address other = _newAgent();
        address t1 = _createV3(other, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        vm.expectRevert(GangCappedSplitter.NotCreator.selector);
        m.bind(t1);
        address t2 = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, dev));
        vm.expectRevert(GangCappedSplitter.NotRecipient.selector);
        m.bind(t2);
        vm.expectRevert(GangCappedSplitter.NotCurve.selector);
        m.bind(makeAddr("nothing"));
        // a token in another quote: the cap would be counted in another unit
        address t4 = _createV3(dev, address(quoteTok), _tax(TAX, TAX, 5_000, address(m)));
        vm.expectRevert(GangCappedSplitter.WrongQuote.selector);
        m.bind(t4);
        address t3 = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t3);
        assertEq(m.token(), t3);
        assertEq(m.quote(), address(wbnb));
        vm.expectRevert(GangCappedSplitter.AlreadyBound.selector);
        m.bind(t3);
    }

    // ---------------------------------------------------------------- the split
    function test_split_beforeCapToTheWei() public {
        (GangCappedSplitter m,, address dev, address kol) = _setup(address(wbnb), 20 ether, false);
        uint256 x = 1 ether + 7;
        uint256 dev0 = _bal(address(wbnb), dev);
        wbnb.mintUnlimited(address(m), x);
        assertEq(m.unsplit(), x);
        (uint256 toP, uint256 toB, uint256 toL) = _parts(x, 0, 20 ether, 5_000, 7_000);
        vm.expectEmit(address(m));
        emit GangCappedSplitter.Split(x, toB, toL, toP);
        m.split();
        assertEq(toP + toB + toL, x);
        assertEq(m.buybackLeft(), toB);
        assertEq(m.lpLeft(), toL);
        assertEq(m.paidTotal(), toP);
        assertEq(m.capLeft(), 20 ether - toP);
        uint256 toKol = (toP * 3_000) / 10_000;
        assertEq(_bal(address(wbnb), kol), toKol, "kol 30% of the payees' part");
        assertEq(_bal(address(wbnb), dev) - dev0, toP - toKol, "dev the rest");
        assertEq(m.unsplit(), 0);
        assertEq(m.lastPaidAt(), block.timestamp);
    }

    /// @dev The split that crosses the cap pays exactly what is left of it; after it, nothing more to the payees.
    function test_split_crossesTheCapExactly() public {
        (GangCappedSplitter m,, address dev, address kol) = _setup(address(wbnb), 1 ether, false);
        uint256 dev0 = _bal(address(wbnb), dev);
        wbnb.mintUnlimited(address(m), 1.2 ether); // 0.6 to the payees, 0.4 left of the cap
        m.split();
        assertEq(m.paidTotal(), 0.6 ether);
        assertFalse(m.capReached());

        wbnb.mintUnlimited(address(m), 3 ether + 1); // would be 1.5: only 0.4 left
        (uint256 toP, uint256 toB, uint256 toL) = _parts(3 ether + 1, 0.6 ether, 1 ether, 5_000, 7_000);
        assertEq(toP, 0.4 ether);
        vm.expectEmit(address(m));
        emit GangCappedSplitter.Split(3 ether + 1, toB, toL, toP);
        vm.expectEmit(address(m));
        emit GangCappedSplitter.CapReached(1 ether);
        m.split();
        assertEq(m.paidTotal(), 1 ether);
        assertTrue(m.capReached());
        assertEq(m.capLeft(), 0);
        assertEq(_bal(address(wbnb), kol) + _bal(address(wbnb), dev) - dev0, 1 ether, "the payees got the cap, all");
        uint64 paidAt = m.lastPaidAt();

        // after the cap: all of it to the buy-back (70%) and liquidity (30%), no CapReached again
        _next(1 hours);
        uint256 bb0 = m.buybackLeft();
        uint256 lp0 = m.lpLeft();
        wbnb.mintUnlimited(address(m), 1 ether);
        vm.recordLogs();
        m.split();
        assertEq(vm.getRecordedLogs().length, 1, "only the Split");
        assertEq(m.buybackLeft() - bb0, 0.7 ether);
        assertEq(m.lpLeft() - lp0, 0.3 ether);
        assertEq(m.paidTotal(), 1 ether);
        assertEq(_bal(address(wbnb), kol) + _bal(address(wbnb), dev) - dev0, 1 ether);
        assertEq(m.lastPaidAt(), paidAt, "nothing paid after the cap");
    }

    function test_split_capUsedUpToTheWeiInOneSplit() public {
        (GangCappedSplitter m,,,) = _setup(address(wbnb), 0.5 ether, false);
        wbnb.mintUnlimited(address(m), 1 ether); // exactly 0.5 to the payees
        vm.expectEmit(address(m));
        emit GangCappedSplitter.CapReached(0.5 ether);
        m.split();
        assertTrue(m.capReached());
        assertEq(m.buybackLeft() + m.lpLeft(), 0.5 ether);
    }

    function test_split_allToPayeesUntilTheCap() public {
        address dev = _newAgent();
        (address[] memory p, uint16[] memory s) = _one(dev);
        GangCappedSplitter m = _capped(dev, address(wbnb), 1 ether, 10_000, 10_000, p, s);
        address t = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t);
        uint256 dev0 = _bal(address(wbnb), dev);
        wbnb.mintUnlimited(address(m), 0.4 ether);
        m.split();
        assertEq(_bal(address(wbnb), dev) - dev0, 0.4 ether);
        assertEq(m.buybackLeft() + m.lpLeft(), 0, "nothing set aside before the cap");
        wbnb.mintUnlimited(address(m), 1 ether);
        m.split();
        assertEq(_bal(address(wbnb), dev) - dev0, 1 ether);
        assertEq(m.buybackLeft(), 0.4 ether, "all of the rest bought back");
        assertEq(m.lpLeft(), 0);
    }

    function test_split_onlyLiquidityAfter() public {
        address dev = _newAgent();
        (address[] memory p, uint16[] memory s) = _one(dev);
        GangCappedSplitter m = _capped(dev, address(wbnb), 1, 5_000, 0, p, s);
        address t = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t);
        wbnb.mintUnlimited(address(m), 7);
        m.split(); // 3 → 1 (the cap) to the dev
        assertEq(m.paidTotal(), 1);
        assertEq(m.lpLeft(), 6);
        assertEq(m.buybackLeft(), 0);
    }

    // ---------------------------------------------------------------- payees
    /// @dev K-6: what a payee is owed counts against the cap when it is split: refusing doesn't keep the cap open.
    function test_payee_owedCountsAgainstTheCap() public {
        (GangCappedSplitter m,, address dev, address kol) = _setup(address(blq), 1 ether, false);
        blq.setBlocked(kol, true);
        uint256 dev0 = _bal(address(blq), dev);
        blq.mint(address(m), 10 ether); // 5 → only 1 (the cap): dev 0.7 pushed, kol 0.3 owed
        vm.expectEmit(address(m));
        emit GangCappedSplitter.CapReached(1 ether);
        m.split();
        assertEq(m.paidTotal(), 1 ether);
        assertTrue(m.capReached());
        assertEq(m.owedOf(address(blq), 1), 0.3 ether);
        assertEq(_bal(address(blq), dev) - dev0, 0.7 ether);
        assertEq(m.buybackLeft() + m.lpLeft(), 9 ether);
        assertEq(m.unsplit(), 0, "owed is held, not split again");

        blq.mint(address(m), 10 ether);
        m.split();
        assertEq(m.owedOf(address(blq), 1), 0.3 ether, "no more owed after the cap");
        vm.expectRevert("blacklisted");
        m.release(address(blq), 1, ALL);
        blq.setBlocked(kol, false);
        assertEq(m.release(address(blq), 1, 0.1 ether), 0.1 ether, "in parts");
        assertEq(m.release(address(blq), 1, ALL), 0.2 ether);
        assertEq(m.paidTotal(), 1 ether, "a release is not a new payout");
        assertEq(_bal(address(blq), kol) + _bal(address(blq), dev) - dev0, 1 ether);
        vm.expectRevert(GangCappedSplitter.NothingOwed.selector);
        m.release(address(blq), 1, ALL);
        vm.expectRevert(GangCappedSplitter.BadIndex.selector);
        m.release(address(blq), 2, ALL);
    }

    function test_payee_owedPaidAtTheNextPush() public {
        (GangCappedSplitter m,,, address kol) = _setup(address(blq), 100 ether, false);
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
        (GangCappedSplitter m,, address dev, address kol) = _setup(address(wbnb), 100 ether, false);
        address kol2 = makeAddr("kol2");
        vm.prank(dev);
        vm.expectRevert(GangCappedSplitter.NotPayee.selector);
        m.setPayee(1, kol2);
        vm.prank(kol);
        vm.expectRevert(GangCappedSplitter.DuplicatePayee.selector);
        m.setPayee(1, dev);
        vm.prank(kol);
        vm.expectRevert(GangCappedSplitter.BadPayee.selector);
        m.setPayee(1, address(m));
        vm.prank(kol);
        vm.expectRevert(GangCappedSplitter.BadIndex.selector);
        m.setPayee(2, kol2);

        // what arrived before the move is split first and paid to the old address; the cap is the same
        wbnb.mintUnlimited(address(m), 1 ether);
        vm.expectEmit(address(m));
        emit GangCappedSplitter.PayeeChanged(1, kol, kol2);
        vm.prank(kol);
        m.setPayee(1, kol2);
        assertEq(_bal(address(wbnb), kol), 0.15 ether);
        wbnb.mintUnlimited(address(m), 1 ether);
        m.split();
        assertEq(_bal(address(wbnb), kol2), 0.15 ether);
        assertEq(m.paidTotal(), 1 ether);
        assertEq(m.capAmount(), 100 ether);
    }

    /// @dev A slot owed after a refused push moves: what it is owed goes to the new address, the cap stays as counted.
    function test_payee_movedSlotTakesWhatItIsOwed() public {
        (GangCappedSplitter m,,, address kol) = _setup(address(blq), 100 ether, false);
        blq.setBlocked(kol, true);
        blq.mint(address(m), 10 ether);
        m.split(); // kol 1.5 owed
        assertEq(m.owedOf(address(blq), 1), 1.5 ether);
        address kol2 = makeAddr("kol2owed");
        vm.prank(kol);
        m.setPayee(1, kol2);
        assertEq(m.owedOf(address(blq), 1), 1.5 ether, "the owed stays with the slot");
        m.release(address(blq), 1, ALL);
        assertEq(_bal(address(blq), kol2), 1.5 ether);
        assertEq(_bal(address(blq), kol), 0);
        assertEq(m.paidTotal(), 5 ether, "counted once");
    }

    // ---------------------------------------------------------------- other assets
    /// @dev K-8: another asset can't count against the cap, so all of it goes to 0xdead and none to the payees.
    function test_otherAsset_allToDead() public {
        (GangCappedSplitter m, address t, address dev, address kol) = _setup(address(wbnb), 100 ether, false);
        quoteTok.mintUnlimited(address(m), 1 ether);
        assertEq(m.undistributed(address(quoteTok)), 1 ether);
        uint256 dead0 = _bal(address(quoteTok), m.DEAD());
        uint256 dev0 = _bal(address(quoteTok), dev);
        vm.expectEmit(address(m));
        emit GangCappedSplitter.Distributed(address(quoteTok), 1 ether, 1 ether);
        assertEq(m.distribute(address(quoteTok)), 1 ether);
        assertEq(_bal(address(quoteTok), m.DEAD()) - dead0, 1 ether);
        assertEq(_bal(address(quoteTok), kol), 0);
        assertEq(_bal(address(quoteTok), dev), dev0);
        assertEq(m.buybackLeft() + m.lpLeft() + m.paidTotal(), 0, "other assets are never set aside or counted");
        assertEq(m.distribute(address(quoteTok)), 0, "nothing left");

        // the token itself, before graduation (transfers locked): it can't reach 0xdead and stays, nothing paid
        deal(t, address(m), 1 ether);
        vm.expectEmit(address(m));
        emit GangCappedSplitter.Distributed(t, 1 ether, 0);
        m.distribute(t);
        assertEq(_bal(t, address(m)), 1 ether);
        _graduate(t);
        m.distribute(t); // after it: burned
        assertEq(_bal(t, address(m)), 0);
        assertEq(_bal(t, m.DEAD()), 1 ether);
        assertEq(_bal(t, address(m)), 0);

        vm.expectRevert(GangCappedSplitter.NothingOwed.selector);
        m.release(address(quoteTok), 0, ALL);
    }

    /// @dev An asset that refuses 0xdead stays here (nothing to the payees); one that burns its gas costs at most
    ///      PUSH_GAS.
    function test_otherAsset_deadRefusedStays() public {
        (GangCappedSplitter m,, address dev, address kol) = _setup(address(wbnb), 100 ether, false);
        GasBurnQuote gb = new GasBurnQuote();
        gb.setBlocked(m.DEAD(), true);
        gb.mint(address(m), 1 ether);
        vm.expectEmit(address(m));
        emit GangCappedSplitter.Distributed(address(gb), 1 ether, 0);
        uint256 g = gasleft();
        m.distribute(address(gb));
        assertLt(g - gasleft(), m.PUSH_GAS() + 100_000, "the dead push at most PUSH_GAS");
        assertEq(gb.balanceOf(address(m)), 1 ether);
        assertEq(gb.balanceOf(kol) + gb.balanceOf(dev), 0);
        assertEq(m.undistributed(address(gb)), 1 ether, "tried again next time");
        gb.setBlocked(m.DEAD(), false);
        m.distribute(address(gb));
        assertEq(gb.balanceOf(m.DEAD()), 1 ether);
    }

    /// @dev The decoy: a dev binds a token D, then launches the real token R in another quote naming the same module;
    ///      R's tax can't skip the cap to reach the dev.
    function test_otherAsset_decoyBindGainsTheDevNothing() public {
        address dev = _newAgent();
        address kol = makeAddr("kolDecoy");
        GangCappedSplitter m =
            _capped(dev, address(wbnb), 1 ether, 5_000, 5_000, _list(dev, kol), _shares(7_000, 3_000));
        address decoy = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        m.bind(decoy);
        _createV3(dev, address(quoteTok), _tax(TAX, TAX, 5_000, address(m)));
        quoteTok.mintUnlimited(address(m), 10 ether); // R's tax, in its quote
        uint256 dev0 = _bal(address(quoteTok), dev);
        m.distribute(address(quoteTok));
        assertEq(_bal(address(quoteTok), dev), dev0, "nothing to the dev");
        assertEq(_bal(address(quoteTok), m.DEAD()), 10 ether);
    }

    /// @dev Before `bind` the quote is not settled: tax that arrived early waits and is split as the quote.
    function test_beforeBind_nothingSplitOrBurned() public {
        address dev = _newAgent();
        GangCappedSplitter m =
            _capped(dev, address(wbnb), 100 ether, 5_000, 5_000, _list(dev, makeAddr("k")), _shares(5_000, 5_000));
        address t = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        wbnb.mintUnlimited(address(m), 1 ether);
        vm.expectRevert(GangCappedSplitter.NotBound.selector);
        m.distribute(address(wbnb));
        vm.expectRevert(GangCappedSplitter.NotBound.selector);
        m.release(address(wbnb), 0, ALL);
        m.split(); // nothing to do before bind
        assertEq(_bal(address(wbnb), address(m)), 1 ether);
        m.bind(t);
        m.split();
        assertEq(m.buybackLeft(), 0.25 ether);
        assertEq(m.lpLeft(), 0.25 ether);
        assertEq(m.paidTotal(), 0.5 ether);
    }

    // ---------------------------------------------------------------- shortfall
    /// @dev K-7: a balance under what is held shrinks every held part; `paidTotal` never goes back.
    function test_shortfall_partsShrinkPaidStays() public {
        (GangCappedSplitter m,,, address kol) = _setup(address(blq), 100 ether, false);
        blq.setBlocked(kol, true);
        blq.mint(address(m), 10 ether);
        m.split(); // 5 to the payees (1.5 owed to kol), 3.5 buy-back, 1.5 liquidity
        assertEq(_bal(address(blq), address(m)), 6.5 ether);
        assertEq(m.paidTotal(), 5 ether);
        deal(address(blq), address(m), 3.25 ether); // half of it taken
        vm.expectEmit(address(m));
        emit GangCappedSplitter.Shortfall(address(blq), 3.25 ether);
        m.split();
        assertEq(m.owedOf(address(blq), 1), 0.75 ether);
        assertEq(m.lpLeft(), 0.75 ether);
        assertEq(m.buybackLeft(), 1.75 ether);
        assertEq(m.buybackLeft() + m.lpLeft() + m.owedTotal(address(blq)), 3.25 ether, "held = balance");
        assertEq(m.paidTotal(), 5 ether, "never rolled back");
        blq.setBlocked(kol, false);
        assertEq(m.release(address(blq), 1, ALL), 0.75 ether);
    }

    // ---------------------------------------------------------------- chunks and the keeper
    function test_chunks_buybackAndLiquidity() public {
        (GangCappedSplitter m, address t,,) = _setup(address(wbnb), 1 ether, true);
        wbnb.mintUnlimited(address(m), 10 ether); // 1 paid; 6.3 buy-back, 2.7 liquidity
        m.chunk(0);
        assertEq(m.buybackLeft(), 6.3 ether);
        assertEq(m.lpLeft(), 2.7 ether);
        _next(10 minutes);
        uint256 dead0 = _bal(t, m.DEAD());
        (,,, uint256 pOut) = m.previewChunk();
        (bool burned,, uint256 tokens,) = m.chunk(pOut);
        assertTrue(burned, "the larger part");
        assertEq(_bal(t, m.DEAD()) - dead0, tokens);
        vm.expectRevert(GangCappedSplitter.ChunkTooSoon.selector);
        m.chunk(0);
    }

    function test_chunks_refusedBeforeGraduation() public {
        (GangCappedSplitter m,,,) = _setup(address(wbnb), 1 ether, false);
        vm.expectRevert(GangCappedSplitter.NothingToChunk.selector);
        m.chunk(0);
        wbnb.mintUnlimited(address(m), 1 ether);
        vm.expectRevert(GangCappedSplitter.NotTradable.selector);
        m.chunk(0);
        (bool due,) = m.previewWork();
        assertFalse(due);
    }

    /// @dev The payees' pending part is due for a split once it is worth a call; after the cap it never is.
    function test_keeper_splitDueOnlyBeforeTheCap() public {
        (GangCappedSplitter m, address t,,) = _setup(address(wbnb), 100 ether, true);
        (, uint256 rQ) = _reserves(t, _curvePair(t));
        uint256 floor = (rQ * m.WORK_MIN_BPS()) / 10_000;
        m.split();
        wbnb.mintUnlimited(address(m), floor * 2 + 10); // the payees' half is at the floor; the chunks under it
        (bool due, uint256 plan) = m.previewWork();
        assertTrue(due);
        assertEq(plan >> 248, 4, "a split");
        m.work(plan);
        assertGt(m.paidTotal(), 0);

        (GangCappedSplitter m2, address t2,,) = _setup(address(wbnb), 1, true);
        (, uint256 rQ2) = _reserves(t2, _curvePair(t2));
        uint256 floor2 = (rQ2 * m2.WORK_MIN_BPS()) / 10_000;
        wbnb.mintUnlimited(address(m2), 2);
        m2.split();
        assertTrue(m2.capReached());
        wbnb.mintUnlimited(address(m2), floor2 / 4); // set-aside under the floor, nothing for the payees
        _next(2 days);
        (due, plan) = m2.previewWork();
        assertTrue(!due || plan >> 248 != 4, "never a split after the cap");
    }

    function test_keeper_notForAQuoteItDoesNotServe() public {
        (GangCappedSplitter m,,,) = _setup(address(quoteTok), 1 ether, true);
        quoteTok.mintUnlimited(address(m), 10 ether);
        (bool due,) = m.previewWork();
        assertTrue(due, "a QuoteRegistry quote is served");
        vm.prank(owner);
        quoteRegistry.setQuote(address(quoteTok), false, 0);
        (due,) = m.previewWork();
        assertFalse(due);
        m.chunk(0); // by hand it still works
        assertGt(m.buybackLeft(), 0);
    }

    // ---------------------------------------------------------------- GangComboSplitter's chunk and keeper tests
    // (the chunk and keeper code is the combo's, unchanged; spec §7 asks for them here too)

    /// @dev Equal parts after the cap: a buy-back first (a tie), then, the buy-back part smaller, a liquidity add —
    ///      each to the wei, one per gap for both kinds.
    function test_chunks_largerPartOnOnePace() public {
        (GangCappedSplitter m, address t,,) = _setupR(1, 1, 5_000);
        address pair = _curvePair(t);
        wbnb.mintUnlimited(address(m), 10 ether + 1); // 1 wei to the payees (the cap), the rest halved
        (bool k0, uint256 q0,,) = m.chunk(0); // splits, records the observation
        assertFalse(k0 && q0 != 0);
        assertEq(q0, 0);
        assertTrue(m.capReached());
        assertEq(m.buybackLeft(), 5 ether);
        assertEq(m.lpLeft(), 5 ether);
        _next(10 minutes);

        (uint256 rT, uint256 rQ) = _reserves(t, pair);
        (bool ok, bool burnKind, uint256 pq, uint256 pOut) = m.previewChunk();
        assertTrue(ok);
        assertTrue(burnKind, "a tie: the buy-back");
        assertEq(pq, (rQ * 50) / 10_000, "capped at 0.5% of the reserve");
        uint256 out = (pq * 9975 * rT) / (rQ * 10_000 + pq * 9975);
        assertEq(pOut, out - (out * TAX) / 10_000);
        uint256 dead0 = _bal(t, m.DEAD());
        (bool burned, uint256 q, uint256 tokens,) = m.chunk(pOut);
        assertTrue(burned);
        assertEq(q, pq);
        assertEq(tokens, pOut);
        assertEq(_bal(t, m.DEAD()) - dead0, tokens);

        (bool ready,,,) = m.previewChunk();
        assertFalse(ready);
        vm.expectRevert(GangCappedSplitter.ChunkTooSoon.selector);
        m.chunk(0);
        _next(4 minutes);

        m.split();
        assertLt(m.buybackLeft(), m.lpLeft());
        uint256 lpLeft0 = m.lpLeft();
        (, bool burnKind2, uint256 chunkAmt, uint256 pOut2) = m.previewChunk();
        assertFalse(burnKind2);
        uint256 supply0 = LpMockPair(pair).totalSupply();
        uint256 lp0 = _lp(t, m.DEAD());
        (bool burned2, uint256 q2, uint256 tokensIn, uint256 liq) = m.chunk(pOut2);
        assertFalse(burned2);
        (uint256 rT1, uint256 rQ1) = _reserves(t, pair);
        uint256 match_ = q2 - chunkAmt / 2;
        assertEq(tokensIn, pOut2 - (pOut2 * TAX) / 10_000, "sell tax on the deposit");
        uint256 rTb = rT1 - tokensIn;
        uint256 rQb = rQ1 - match_;
        assertEq(match_, (tokensIn * rQb + rTb - 1) / rTb, "matched at the reserves after the deposit");
        uint256 lt = (tokensIn * supply0) / rTb;
        uint256 lq = (match_ * supply0) / rQb;
        assertEq(liq, lt < lq ? lt : lq);
        assertEq(_lp(t, m.DEAD()) - lp0, liq);
        assertEq(m.lpLeft(), lpLeft0 - q2);
        assertEq(_bal(t, address(m)), 0);
        assertEq(_lp(t, address(m)), 0);
        assertGt(m.unsplit(), 0, "the deposit let the handler swap back, paying this recipient mid-chunk");
    }

    /// @dev Combo audit 2026-10-31 M-1: dust in the smaller part can't hold the shared pace — whoever calls `chunk`,
    ///      it works the larger part.
    function test_chunks_dustCantStarveTheLargerPart() public {
        (GangCappedSplitter m,,,) = _setupR(1, 1, 7_000);
        wbnb.mintUnlimited(address(m), 1.5 ether);
        m.chunk(0);
        address griefer = _newAgent();
        uint256 chunks;
        for (uint256 i; i < 6; i++) {
            _next(4 minutes + (i == 0 ? 6 minutes : 0));
            uint256 lp0 = m.lpLeft();
            vm.startPrank(griefer);
            wbnb.transfer(address(m), 10);
            (bool burned, uint256 q,,) = m.chunk(0);
            vm.stopPrank();
            assertTrue(burned, "the griefer's call is for the buy-back, the larger part");
            assertGe(m.lpLeft(), lp0, "the smaller part is never chunked");
            if (q != 0) chunks++;
        }
        assertGt(chunks, 2, "the buy-back advanced");
    }

    function test_chunks_skipAfterPump() public {
        (GangCappedSplitter m, address t,,) = _setup(address(wbnb), 1 ether, true);
        wbnb.mintUnlimited(address(m), 10 ether);
        m.chunk(0);
        _next(10 minutes);
        (, uint256 rQ) = _reserves(t, _curvePair(t));
        _poolBuy(t, address(wbnb), _curvePair(t), _newAgent(), (rQ * 5) / 100);
        (bool ready,,,) = m.previewChunk();
        assertFalse(ready);
        (, uint256 q,,) = m.chunk(0);
        assertEq(q, 0);
        assertEq(m.lastChunkAt(), 0, "no chunk counted");
    }

    function test_chunks_slippage() public {
        (GangCappedSplitter m,,,) = _setupR(1, 1, 5_000);
        wbnb.mintUnlimited(address(m), 10 ether + 1);
        m.chunk(0);
        _next(10 minutes);
        (,,, uint256 pOut) = m.previewChunk();
        vm.expectRevert(GangCappedSplitter.Slippage.selector);
        m.chunk(pOut + 1);
        m.chunk(pOut); // a buy-back
        _next(4 minutes);
        m.split();
        (, bool burn,, uint256 pOut2) = m.previewChunk();
        assertFalse(burn);
        vm.expectRevert(GangCappedSplitter.Slippage.selector);
        m.chunk(pOut2 + 1);
    }

    /// @dev LP audit 2026-10-30 L-1, kept: quote left unsynced in the pair before the keeper's call can't fail it.
    function test_chunks_quoteLeftInPairDoesNotFailTheKeeper() public {
        (GangCappedSplitter m, address t,,) = _setup(address(wbnb), 1 ether, true);
        address pair = _curvePair(t);
        (, uint256 rQ) = _reserves(t, pair);
        wbnb.mintUnlimited(address(m), rQ * 2);
        m.chunk(0);
        _next(10 minutes);
        (bool due, uint256 minOut) = m.previewWork();
        assertTrue(due);
        assertGt(minOut, 0);
        address griefer = _newAgent();
        vm.prank(griefer);
        wbnb.transfer(pair, (rQ * 3) / 100);
        m.work(minOut);
        assertEq(m.lastChunkAt(), block.timestamp, "the chunk went through");
    }

    /// @dev The keeper's loop: work(previewWork's minOut) whenever due. The observation comes first; each chunk goes to
    ///      the larger part (checked step by step); nothing is due inside the gap.
    function test_keeper_planFollowsTheLargerPart() public {
        (GangCappedSplitter m, address t,,) = _setupR(100 ether, 3_000, 7_000);
        (bool due, uint256 minOut) = m.previewWork();
        assertFalse(due, "nothing to do");

        wbnb.mintUnlimited(address(m), 10 ether);
        (due, minOut) = m.previewWork();
        assertTrue(due, "the observation the chunks need");
        assertEq(minOut >> 248, 3, "observe");
        m.work(minOut);
        assertEq(m.buybackLeft(), 4.9 ether);
        assertEq(m.lpLeft(), 2.1 ether);
        assertEq(m.paidTotal(), 3 ether);
        assertEq(m.lastChunkAt(), 0);
        (due,) = m.previewWork();
        assertFalse(due, "observed this block");

        _next(10 minutes);
        (due, minOut) = m.previewWork();
        assertTrue(due);
        (,,, uint256 out) = m.previewChunk();
        assertEq(minOut >> 248, 1, "a buy-back: the larger part");
        assertEq(minOut & VALUE, (out * 9_900) / 10_000);
        uint256 bb0 = m.buybackLeft();
        m.work(minOut);
        assertLt(m.buybackLeft(), bb0);
        (due,) = m.previewWork();
        assertFalse(due, "inside the gap");

        uint256 burns;
        uint256 adds;
        for (uint256 i; i < 200; i++) {
            _next(4 minutes);
            (due, minOut) = m.previewWork();
            if (!due) continue;
            m.split();
            uint256 b = m.buybackLeft();
            uint256 l = m.lpLeft();
            m.work(minOut);
            uint8 action = uint8(minOut >> 248);
            if (action == 1) {
                assertGe(b, l, "a buy-back only when it is the larger part");
                assertLt(m.buybackLeft(), b);
                burns++;
            } else if (action == 2) {
                assertGt(l, b, "a liquidity add only when it is the larger part");
                assertLt(m.lpLeft(), l);
                adds++;
            }
        }
        assertGt(burns, 1);
        assertGt(adds, 1);
        (, uint256 rQ) = _reserves(t, _curvePair(t));
        m.split();
        assertLt(m.buybackLeft() * 10_000, rQ * m.WORK_MIN_BPS(), "run down under the floor");
        assertLt(m.lpLeft() * 10_000, rQ * m.WORK_MIN_BPS());
    }

    /// @dev Combo audit 2026-10-31 L-1: a `minOut` planned for another action (the state moved between preview and
    ///      inclusion) makes `work` only split — no chunk with the wrong slippage bound, no revert.
    function test_keeper_workIgnoresAStalePlan() public {
        (GangCappedSplitter m,,,) = _setupR(1, 1, 5_000);
        wbnb.mintUnlimited(address(m), 10 ether + 1);
        (, uint256 obs) = m.previewWork();
        m.work(obs);
        _next(10 minutes);
        (bool due, uint256 burnPlan) = m.previewWork();
        assertTrue(due);
        assertEq(burnPlan >> 248, 1);
        m.chunk(0); // someone does that buy-back first
        _next(4 minutes);
        (, uint256 addPlan) = m.previewWork();
        assertEq(addPlan >> 248, 2, "now the liquidity part is larger");
        uint64 last = m.lastChunkAt();
        m.work(burnPlan); // the stale buy-back plan
        assertEq(m.lastChunkAt(), last, "no chunk");
        m.work(0); // a split-only / nothing plan
        assertEq(m.lastChunkAt(), last, "no chunk without a plan for it");
        m.work(addPlan);
        assertEq(m.lastChunkAt(), block.timestamp, "the current plan runs");
    }

    // ---------------------------------------------------------------- end to end
    /// @dev Pool sells pay the tax; the handler pays the module; the keeper's loop pays the payees up to the cap, then
    ///      only burns and adds liquidity; every wei is accounted for.
    function test_e2e_poolTaxCrossesTheCap() public {
        (GangCappedSplitter m, address t, address dev, address kol) = _setup(address(wbnb), 0.01 ether, true);
        address pair = _curvePair(t);
        uint256 dev0 = _bal(address(wbnb), dev);
        for (uint256 i; i < 24; i++) {
            address seller = _newAgent();
            (uint256 rT,) = _reserves(t, pair);
            deal(t, seller, rT / 40);
            _poolSell(t, pair, seller, rT / 40);
            _next(1 minutes);
            if (i % 8 == 7) {
                uint256 mc = handler.maxChunk(t);
                vm.prank(keeper);
                handler.process(t, mc, 1);
            }
        }
        assertGt(m.unsplit(), 0.02 ether, "enough to cross the cap");

        uint256 dead0 = _bal(t, m.DEAD());
        uint256 lp0 = _lp(t, m.DEAD());
        for (uint256 i; i < 200; i++) {
            (bool due, uint256 minOut) = m.previewWork();
            if (due) m.work(minOut);
            _next(4 minutes);
        }
        m.split();
        assertTrue(m.capReached());
        assertEq(_bal(address(wbnb), kol) + _bal(address(wbnb), dev) - dev0, 0.01 ether, "the payees: the cap, exactly");
        assertGt(_bal(t, m.DEAD()), dead0, "bought back and burned");
        assertGt(_lp(t, m.DEAD()), lp0, "liquidity locked");
        assertEq(_bal(t, address(m)), 0);
        assertEq(_lp(t, address(m)), 0);
        assertEq(_bal(address(wbnb), address(m)), m.buybackLeft() + m.lpLeft() + m.unsplit(), "books = balance");
    }

    // ---------------------------------------------------------------- invariants under random arrivals
    /// @dev Random arrivals, a payee that refuses at random, releases and shortfalls: I-1 paid ≤ cap; I-2 what the
    ///      payees got plus what they are owed = paid less what shortfalls took from the owed; I-3 every split adds up.
    function testFuzz_capHolds(uint256 seed, uint96 cap, uint16 pay, uint16 bbRest) public {
        cap = uint96(bound(cap, 1, 50 ether));
        pay = uint16(bound(pay, 1, 10_000));
        bbRest = uint16(bound(bbRest, 0, 10_000));
        address dev = _newAgent();
        address kol = makeAddr("fuzzKol");
        GangCappedSplitter m = _capped(dev, address(blq), cap, pay, bbRest, _list(dev, kol), _shares(6_000, 4_000));
        address t = _createV3(dev, address(blq), _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t);
        uint256 dev0 = _bal(address(blq), dev);
        uint256 taken; // from the owed by shortfalls
        for (uint256 i; i < 24; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 6;
            if (op == 0) {
                blq.setBlocked(kol, (r >> 8) % 2 == 0);
            } else if (op == 1) {
                uint256 owed0 = m.owedTotal(address(blq));
                uint256 held = m.buybackLeft() + m.lpLeft() + owed0;
                if (held == 0) continue;
                deal(address(blq), address(m), held - ((held * ((r >> 8) % 50)) / 100));
                m.split();
                taken += owed0 - m.owedTotal(address(blq));
            } else if (op == 2) {
                if (m.owedOf(address(blq), 1) != 0) {
                    blq.setBlocked(kol, false);
                    m.release(address(blq), 1, ALL);
                }
            } else {
                uint256 x = (r >> 8) % 20 ether;
                uint256 paid0 = m.paidTotal();
                uint256 bb0 = m.buybackLeft();
                uint256 lp0 = m.lpLeft();
                uint256 unsplit0 = m.unsplit();
                blq.mint(address(m), x);
                m.split();
                uint256 incoming = unsplit0 + x;
                (uint256 toP, uint256 toB, uint256 toL) = _parts(incoming, paid0, cap, pay, bbRest);
                assertEq(m.paidTotal() - paid0, toP, "I-3 payees");
                assertEq(m.buybackLeft() - bb0, toB, "I-3 buy-back");
                assertEq(m.lpLeft() - lp0, toL, "I-3 liquidity");
            }
            assertLe(m.paidTotal(), cap, "I-1");
            uint256 got = _bal(address(blq), kol) + _bal(address(blq), dev) - dev0;
            assertEq(got + m.owedTotal(address(blq)) + taken, m.paidTotal(), "I-2");
        }
    }

    // ---------------------------------------------------------------- deploy script
    function test_script_check() public {
        DeployGangCappedSplitterFactory script = new DeployGangCappedSplitterFactory();
        script.check(address(pad), address(admin), address(factory));
        assertEq(script.pendingBatch(address(admin), address(factory)).length, 0);

        GangHandlerAdmin rogue = new GangHandlerAdmin(makeAddr("notTheSafe"), address(handler));
        GangCappedSplitterFactory rogueFactory = new GangCappedSplitterFactory(address(pad), address(rogue), GANG);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGangCappedSplitterFactory.WiringCheck.selector, "admin.handlerOwner")
        );
        script.check(address(pad), address(rogue), address(rogueFactory));
        vm.expectRevert(abi.encodeWithSelector(DeployGangCappedSplitterFactory.WiringCheck.selector, "factory.admin"));
        script.check(address(pad), address(admin), address(rogueFactory));

        script.checkCode(address(factory));
        FakeCappedImpl fakeImpl = new FakeCappedImpl(address(pad), address(handler));
        FakeCappedFactory fake = new FakeCappedFactory(address(pad), address(admin), address(fakeImpl));
        fakeImpl.setFactory(address(fake));
        script.check(address(pad), address(admin), address(fake));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGangCappedSplitterFactory.WiringCheck.selector, "factory.runtimeCode")
        );
        script.checkCode(address(fake));

        GangCappedSplitterFactory f2 = new GangCappedSplitterFactory(address(pad), address(admin), GANG);
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
    }
}
