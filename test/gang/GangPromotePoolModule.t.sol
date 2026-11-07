// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Vm} from "forge-std/Vm.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {TwapMockPairFactory} from "../mocks/TwapMockPair.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {GangPromotePoolModule as M} from "../../src/gang/GangPromotePoolModule.sol";
import {GangPromotePoolModuleFactory as F} from "../../src/gang/GangPromotePoolModuleFactory.sol";
import {DeployGangPromotePoolModuleFactory as D} from "../../script/DeployGangPromotePoolModuleFactory.s.sol";

/// @notice The pool side of the promoter share (docs/SPEC-PROMOTER-POOL-SHARE-2026-11-05.md) on the whole deployment.
contract GangPromotePoolModuleTest is GangFixture {
    uint16 internal constant TAX = 300;
    uint16 internal constant SHARE = 2_000;
    uint32 internal constant WINDOW = 30 days;
    uint256 internal constant BPS = 10_000;

    address internal keeper = makeAddr("keeper");
    address internal settler = makeAddr("settler");
    address internal safe = makeAddr("safe");
    address internal constant GANG = address(0x6A46);
    GangHandlerAdmin internal admin;
    F internal factory;
    Pad3Module internal pm;
    uint256 internal _salt;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function _newPairFactory() internal override returns (address) {
        return address(new TwapMockPairFactory());
    }

    function setUp() public {
        _deployGang(keeper);
        pm = Pad3Module(payable(address(pad)));
        admin = new GangHandlerAdmin(owner, address(handler));
        vm.startPrank(owner);
        handler.transferOwnership(address(admin));
        admin.exec(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        vm.stopPrank();
        factory = new F(address(pad), address(admin), GANG, safe, settler);
        vm.prank(owner);
        admin.setFactory(address(factory), true);
    }

    // ---------------------------------------------------------------- helpers
    function _module(address dev) internal returns (M m) {
        vm.prank(dev);
        m = M(factory.create(bytes32(++_salt)));
    }

    function _token(address dev, M m, address quote, uint16 dividendBps) internal returns (address t) {
        vm.prank(dev);
        t = pm.createWithPromote(
            "P", "P", "l", "m", quote, address(0), _tax(TAX, TAX, dividendBps, address(m)), 9 ether, SHARE, WINDOW
        );
    }

    function _bound(address quote) internal returns (M m, address t, address dev) {
        dev = _newAgent();
        m = _module(dev);
        t = _token(dev, m, quote, 0);
        m.bind(t);
    }

    /// @dev The optimizer treats block.number as fixed within a tx: read it through a call after a roll.
    function bn() external view returns (uint256) {
        return block.number;
    }

    function _next(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(this.bn() + 1);
    }

    function _leaf(address a, uint256 c) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, c))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    /// @dev Post a two-leaf root and wait out the dispute window.
    function _settle(M m, address a, uint256 ca, address b, uint256 cb, uint256 allocated)
        internal
        returns (bytes32 la, bytes32 lb)
    {
        la = _leaf(a, ca);
        lb = _leaf(b, cb);
        vm.roll(this.bn() + 1);
        uint64 through = uint64(this.bn() - 1);
        vm.prank(settler);
        m.post(_pair(la, lb), allocated, through, "uri");
        _next(m.DISPUTE_WINDOW());
    }

    // ---------------------------------------------------------------- factory
    function test_factory_create() public {
        address dev = _newAgent();
        vm.prank(makeAddr("notAgent"));
        vm.expectRevert(F.NotAgent.selector);
        factory.create(bytes32(0));

        address want = factory.predict(dev, bytes32(uint256(7)));
        vm.prank(dev);
        address got = factory.create(bytes32(uint256(7)));
        assertEq(got, want);
        assertEq(M(got).dev(), dev);
        assertEq(M(got).moduleType(), bytes32("promote-pool-v1"));
        assertTrue(handler.isListed(got));
        assertEq(admin.moduleOf(got), address(factory));
        assertEq(factory.count(), 1);
        assertEq(factory.modules()[0], got);

        vm.prank(dev);
        vm.expectRevert();
        factory.create(bytes32(uint256(7)));
    }

    function newFactory(address p, address a, address o, address s) external returns (F) {
        return new F(p, a, GANG, o, s);
    }

    function test_factory_constructorChecks() public {
        vm.expectRevert(F.ZeroAddress.selector);
        this.newFactory(address(0), address(admin), safe, settler);
        vm.expectRevert(F.ZeroAddress.selector);
        this.newFactory(address(pad), address(0), safe, settler);
        vm.expectRevert(F.ZeroAddress.selector);
        this.newFactory(address(pad), address(admin), safe, address(0));
        GangHandlerAdmin elsewhere = new GangHandlerAdmin(owner, makeAddr("otherHandler"));
        vm.expectRevert(F.WrongHandler.selector);
        this.newFactory(address(pad), address(elsewhere), safe, settler);
        // a pad without the promoter share: no promoteOf
        address p = address(pad);
        vm.mockCallRevert(p, abi.encodeWithSignature("promoteOf(address)", address(0)), "");
        vm.expectRevert();
        this.newFactory(p, address(admin), safe, settler);
    }

    function test_factory_setSettler() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.setSettler(makeAddr("x"));
        vm.prank(safe);
        vm.expectRevert(F.ZeroAddress.selector);
        factory.setSettler(address(0));
        vm.prank(safe);
        factory.setSettler(makeAddr("x"));
        assertEq(factory.settler(), makeAddr("x"));
    }

    function test_initialize_guards() public {
        M impl = M(factory.implementation());
        vm.expectRevert(M.NotClone.selector);
        impl.initialize(address(1));
        M m = _module(_newAgent());
        vm.expectRevert(M.NotFactory.selector);
        m.initialize(address(1));
        vm.prank(address(factory));
        vm.expectRevert(M.AlreadyInitialized.selector);
        m.initialize(address(1));
    }

    // ---------------------------------------------------------------- bind
    function test_bind_anyoneOnce() public {
        address dev = _newAgent();
        M m = _module(dev);
        address t = _token(dev, m, address(quoteTok), 0);
        vm.expectEmit(address(m));
        emit M.Bound(t, address(quoteTok), SHARE, WINDOW);
        vm.prank(makeAddr("anyone"));
        m.bind(t);
        assertEq(m.token(), t);
        assertEq(m.quote(), address(quoteTok));
        assertEq(m.shareBps(), SHARE);
        assertEq(m.window(), WINDOW);
        vm.expectRevert(M.AlreadyBound.selector);
        m.bind(t);
    }

    function test_bind_refusals() public {
        address dev = _newAgent();
        M m = _module(dev);
        vm.expectRevert(M.NotCurve.selector);
        m.bind(makeAddr("notAToken"));

        address other = _newAgent();
        M otherM = _module(other);
        address notMine = _token(other, otherM, address(quoteTok), 0);
        vm.expectRevert(M.NotCreator.selector);
        m.bind(notMine);

        // the dev's token, paying someone else
        vm.prank(dev);
        address elsewhere = pm.createWithPromote(
            "P", "P", "l", "m", address(quoteTok), address(0), _tax(TAX, TAX, 0, dev), 9 ether, SHARE, WINDOW
        );
        vm.expectRevert(M.NotRecipient.selector);
        m.bind(elsewhere);

        // a token with this recipient and no promoter terms
        address plain = _createV3(dev, address(quoteTok), _tax(TAX, TAX, 0, address(m)));
        vm.expectRevert(M.NotPromoted.selector);
        m.bind(plain);

        // every bit of the tax to holders: nothing would ever reach the module
        address allDiv = _token(dev, m, address(quoteTok), 10_000);
        vm.expectRevert(M.AllDividends.selector);
        m.bind(allDiv);
    }

    /// @dev Re-review M-A: bound after graduation, pool tax from before the bind would be missing from the settlement.
    function test_bind_notAfterGraduation() public {
        address dev = _newAgent();
        M m = _module(dev);
        address t = _token(dev, m, address(quoteTok), 0);
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
        vm.expectRevert(M.AlreadyGraduated.selector);
        m.bind(t);
        // nothing is stuck: the dev takes the income of an unbound module
        uint256 d0 = quoteTok.balanceOf(dev);
        quoteTok.mint(address(m), 1 ether);
        m.sweep(address(quoteTok));
        assertEq(quoteTok.balanceOf(dev) - d0, 1 ether);
    }

    /// @dev Re-review L-3: a post before graduation doesn't open a reclaim while no pool tax can have arrived.
    function test_reclaim_notBeforeGraduation() public {
        (M m,, address dev) = _bound(address(quoteTok));
        quoteTok.mint(address(m), 10 ether);
        vm.roll(this.bn() + 2);
        vm.prank(settler);
        m.post(bytes32(uint256(1)), 0, 1, "");
        _next(m.DISPUTE_WINDOW() + m.SETTLER_SILENCE());
        vm.prank(dev);
        vm.expectRevert(M.StillActive.selector);
        m.reclaim(dev);
        assertFalse(m.closed());
    }

    // ---------------------------------------------------------------- the split
    function test_split_escrowAndDev() public {
        (M m,, address dev) = _bound(address(quoteTok));
        uint256 d0 = quoteTok.balanceOf(dev);
        quoteTok.mint(address(m), 10 ether);
        assertEq(m.undistributed(), 10 ether);
        vm.expectEmit(address(m));
        emit M.Split(10 ether, 2 ether, 8 ether);
        m.work(0);
        assertEq(quoteTok.balanceOf(dev) - d0, 8 ether);
        assertEq(quoteTok.balanceOf(address(m)), 2 ether);
        assertEq(m.escrowIn(), 2 ether);
        assertEq(m.held(), 2 ether);
        assertEq(m.undistributed(), 0);
        // nothing new: nothing moves
        m.work(0);
        assertEq(m.escrowIn(), 2 ether);
    }

    /// @dev Conservation for any amounts: whatever arrives is escrow + dev, and the escrow never exceeds the share.
    function testFuzz_split_conserves(uint256 a, uint256 b) public {
        a = bound(a, 0, 500 ether);
        b = bound(b, 0, 500 ether);
        (M m,, address dev) = _bound(address(quoteTok));
        uint256 d0 = quoteTok.balanceOf(dev);
        quoteTok.mint(address(m), a);
        m.work(0);
        quoteTok.mint(address(m), b);
        m.work(0);
        uint256 total = a + b;
        assertEq(m.escrowIn() + quoteTok.balanceOf(dev) - d0, total);
        assertLe(m.escrowIn(), (total * SHARE) / BPS);
        assertEq(quoteTok.balanceOf(address(m)), m.held());
    }

    function test_split_stopsAfterEveryWindow() public {
        (M m, address t, address dev) = _bound(address(quoteTok));
        assertTrue(m.escrowOpen());
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
        m.work(0);
        uint64 seen = m.firstGradSeenAt();
        assertEq(seen, block.timestamp);

        vm.warp(uint256(seen) + WINDOW + m.ESCROW_GRACE() - 1);
        assertTrue(m.escrowOpen());
        quoteTok.mint(address(m), 10 ether);
        m.work(0);
        assertEq(m.escrowIn(), 2 ether, "still escrowed in the last second");

        vm.warp(uint256(seen) + WINDOW + m.ESCROW_GRACE());
        assertFalse(m.escrowOpen());
        uint256 d0 = quoteTok.balanceOf(dev);
        quoteTok.mint(address(m), 10 ether);
        m.work(0);
        assertEq(m.escrowIn(), 2 ether, "no more escrow");
        assertEq(quoteTok.balanceOf(dev) - d0, 10 ether, "all of it to the dev");
    }

    /// @dev A dev the quote refuses doesn't hold up the escrow; the dev's part waits and is sent on request.
    function test_split_blockedDevIsOwed() public {
        (M m,, address dev) = _bound(address(blq));
        blq.setBlocked(dev, true);
        blq.mint(address(m), 10 ether);
        vm.expectEmit(address(m));
        emit M.DevOwed(8 ether);
        m.work(0);
        assertEq(m.devOwed(), 8 ether);
        assertEq(m.escrowIn(), 2 ether);
        assertEq(m.held(), 10 ether);
        assertEq(m.undistributed(), 0, "owed is not split again");

        vm.expectRevert(M.NotDev.selector);
        m.releaseDev(dev);
        address to = makeAddr("devOther");
        vm.prank(dev);
        vm.expectRevert(M.BadReceiver.selector);
        m.releaseDev(address(m));
        vm.prank(dev);
        m.releaseDev(to);
        assertEq(blq.balanceOf(to), 8 ether);
        assertEq(m.devOwed(), 0);
        vm.prank(dev);
        vm.expectRevert(M.NothingOwed.selector);
        m.releaseDev(to);
    }

    // ---------------------------------------------------------------- post / veto / activate
    function test_post_refusals() public {
        address dev = _newAgent();
        M unbound = _module(dev);
        vm.prank(settler);
        vm.expectRevert(M.NotBound.selector);
        unbound.post(bytes32(uint256(1)), 0, 1, "");

        (M m,,) = _bound(address(quoteTok));
        quoteTok.mint(address(m), 10 ether);
        vm.roll(this.bn() + 5);
        uint64 through = uint64(this.bn() - 1);

        vm.expectRevert(M.NotSettler.selector);
        m.post(bytes32(uint256(1)), 1 ether, through, "");

        vm.startPrank(settler);
        vm.expectRevert(M.BadRoot.selector);
        m.post(bytes32(0), 1 ether, through, "");
        // the split runs first, so 2 ether counts and a wei over doesn't
        vm.expectRevert(M.BadAllocated.selector);
        m.post(bytes32(uint256(1)), 2 ether + 1, through, "");
        vm.expectRevert(M.BadThroughBlock.selector);
        m.post(bytes32(uint256(1)), 1 ether, through + 1, "");
        vm.expectRevert(M.BadThroughBlock.selector);
        m.post(bytes32(uint256(1)), 1 ether, 0, "");

        m.post(bytes32(uint256(1)), 1 ether, through, "uri");
        vm.expectRevert(M.PostPending.selector);
        m.post(bytes32(uint256(2)), 1 ether, through + 1, "");
        vm.stopPrank();

        // after the window: a new post first activates the old one, then allocation and block must move forward
        _next(m.DISPUTE_WINDOW());
        vm.roll(this.bn() + 2);
        uint64 later = uint64(this.bn() - 1);
        vm.startPrank(settler);
        vm.expectRevert(M.BadAllocated.selector);
        m.post(bytes32(uint256(2)), 1 ether - 1, later, "");
        vm.expectRevert(M.BadThroughBlock.selector);
        m.post(bytes32(uint256(2)), 1 ether, through, "");
        m.post(bytes32(uint256(2)), 1 ether, later, "");
        vm.stopPrank();
        assertEq(m.root(), bytes32(uint256(1)), "the first root took effect");
        assertEq(m.pendingRoot(), bytes32(uint256(2)));
    }

    function test_activate_afterTheWindowOnly() public {
        (M m,,) = _bound(address(quoteTok));
        vm.expectRevert(M.NothingPending.selector);
        m.activate();
        quoteTok.mint(address(m), 10 ether);
        vm.roll(this.bn() + 2);
        vm.prank(settler);
        m.post(bytes32(uint256(1)), 1 ether, 1, "");
        assertEq(m.root(), bytes32(0));

        vm.warp(block.timestamp + m.DISPUTE_WINDOW() - 1);
        vm.expectRevert(M.TooEarly.selector);
        m.activate();
        vm.warp(block.timestamp + 1);
        vm.expectEmit(address(m));
        emit M.RootActivated(bytes32(uint256(1)), 1 ether, 1);
        m.activate();
        assertEq(m.root(), bytes32(uint256(1)));
        assertEq(m.allocatedTotal(), 1 ether);
        assertEq(m.throughBlock(), 1);
        assertEq(m.pendingRoot(), bytes32(0));
        assertEq(m.pendingActiveAt(), 0);
    }

    function test_veto_ownerInTheWindow() public {
        (M m,,) = _bound(address(quoteTok));
        quoteTok.mint(address(m), 10 ether);
        vm.roll(this.bn() + 2);
        vm.expectRevert(M.NotVetoer.selector);
        m.veto();
        vm.prank(safe);
        vm.expectRevert(M.NothingPending.selector);
        m.veto();

        vm.prank(settler);
        m.post(bytes32(uint256(1)), 1 ether, 1, "");
        vm.prank(settler);
        vm.expectRevert(M.NotVetoer.selector);
        m.veto();
        vm.expectEmit(address(m));
        emit M.RootVetoed(bytes32(uint256(1)));
        vm.prank(safe);
        m.veto();
        assertEq(m.pendingRoot(), bytes32(0));
        _next(m.DISPUTE_WINDOW());
        assertEq(m.root(), bytes32(0), "a vetoed root never takes effect");

        // a new post is free again, and past the window a veto is too late
        vm.prank(settler);
        m.post(bytes32(uint256(2)), 1 ether, 1, "");
        _next(m.DISPUTE_WINDOW());
        vm.prank(safe);
        vm.expectRevert(M.TooLate.selector);
        m.veto();
    }

    // ---------------------------------------------------------------- claim
    function test_claim_cumulativeAcrossRoots() public {
        (M m,, address dev) = _bound(address(quoteTok));
        address promoter = makeAddr("promoter");
        quoteTok.mint(address(m), 10 ether); // 2 ether of escrow
        m.work(0);
        (bytes32 lp, bytes32 ld) = _settle(m, promoter, 1.5 ether, dev, 0.5 ether, 2 ether);

        address to = makeAddr("to");
        vm.startPrank(promoter);
        vm.expectRevert(M.BadReceiver.selector);
        m.claim(1.5 ether, _proof(ld), address(0));
        vm.expectRevert(M.BadReceiver.selector);
        m.claim(1.5 ether, _proof(ld), address(m));
        vm.expectRevert(M.BadProof.selector);
        m.claim(2 ether, _proof(ld), to);
        vm.expectEmit(address(m));
        emit M.Claimed(promoter, to, 1.5 ether);
        m.claim(1.5 ether, _proof(ld), to);
        assertEq(quoteTok.balanceOf(to), 1.5 ether);
        vm.expectRevert(M.NothingToClaim.selector);
        m.claim(1.5 ether, _proof(ld), to);
        vm.stopPrank();

        // someone else can't use the promoter's leaf
        vm.prank(makeAddr("thief"));
        vm.expectRevert(M.BadProof.selector);
        m.claim(1.5 ether, _proof(ld), to);

        // the dev's own part, out of the escrow
        uint256 d0 = quoteTok.balanceOf(dev);
        vm.prank(dev);
        m.claim(0.5 ether, _proof(lp), dev);
        assertEq(quoteTok.balanceOf(dev) - d0, 0.5 ether);
        assertEq(m.claimedTotal(), 2 ether);
        assertEq(m.held(), 0);

        // the next round: cumulative amounts, only the difference moves
        quoteTok.mint(address(m), 5 ether); // 1 ether more
        (, bytes32 ld2) = _settle(m, promoter, 2.25 ether, dev, 0.75 ether, 3 ether);
        vm.prank(promoter);
        uint256 got = m.claim(2.25 ether, _proof(ld2), to);
        assertEq(got, 0.75 ether);
        assertEq(quoteTok.balanceOf(to), 2.25 ether);
    }

    /// @dev A root whose leaves add up to more than it declared can't pay more than it declared.
    function test_claim_rootCannotOverpay() public {
        (M m,, address dev) = _bound(address(quoteTok));
        address a = makeAddr("a");
        address b = makeAddr("b");
        uint256 d0 = quoteTok.balanceOf(dev);
        quoteTok.mint(address(m), 10 ether); // 2 ether of escrow, 8 pushed to the dev
        (bytes32 la, bytes32 lb) = _settle(m, a, 2 ether, b, 2 ether, 2 ether);
        vm.prank(a);
        m.claim(2 ether, _proof(lb), a);
        vm.prank(b);
        vm.expectRevert(M.OverAllocated.selector);
        m.claim(2 ether, _proof(la), b);
        assertEq(quoteTok.balanceOf(address(m)), 0);
        assertEq(quoteTok.balanceOf(dev) - d0, 8 ether, "what the dev got is out of reach");
    }

    /// @dev What a dev already got, and what later arrives for the dev, can't be reached by any root.
    function test_claim_rootCapIsTheEscrow() public {
        (M m,, address dev) = _bound(address(blq));
        blq.setBlocked(dev, true);
        blq.mint(address(m), 10 ether); // 8 owed to the dev, 2 of escrow
        m.work(0);
        vm.roll(this.bn() + 2);
        vm.prank(settler);
        vm.expectRevert(M.BadAllocated.selector);
        m.post(bytes32(uint256(1)), 2 ether + 1, 1, "");
        assertEq(m.devOwed(), 8 ether);
    }

    function test_claim_activatesADueRoot() public {
        (M m,,) = _bound(address(quoteTok));
        address a = makeAddr("a");
        address b = makeAddr("b");
        quoteTok.mint(address(m), 10 ether);
        (, bytes32 lb) = _settle(m, a, 1 ether, b, 1 ether, 2 ether);
        assertEq(m.root(), bytes32(0), "still pending in storage");
        vm.prank(a);
        m.claim(1 ether, _proof(lb), a);
        assertTrue(m.root() != bytes32(0));
    }

    function test_claim_pendingRootPaysNothing() public {
        (M m,,) = _bound(address(quoteTok));
        address a = makeAddr("a");
        address b = makeAddr("b");
        quoteTok.mint(address(m), 10 ether);
        bytes32 la = _leaf(a, 1 ether);
        bytes32 lb = _leaf(b, 1 ether);
        vm.roll(this.bn() + 2);
        vm.prank(settler);
        m.post(_pair(la, lb), 2 ether, 1, "");
        vm.warp(block.timestamp + m.DISPUTE_WINDOW() - 1);
        vm.prank(a);
        vm.expectRevert(M.BadProof.selector);
        m.claim(1 ether, _proof(lb), a);
    }

    /// @dev The tree scripts/promote-settle builds (PRINT_VECTOR=1 node settle.test.mjs), claimed for real.
    function test_claim_scriptTree() public {
        (M m,,) = _bound(address(quoteTok));
        quoteTok.mint(address(m), 10 ether); // 2 ether of escrow
        vm.roll(this.bn() + 2);
        vm.prank(settler);
        m.post(0x3b67e751eafc0b1702a1b8eba65021821e904fad3de2b5198b42be7479ae83e7, 2 ether, 1, "");
        _next(m.DISPUTE_WINDOW());

        bytes32[] memory p = new bytes32[](2);
        p[0] = 0x541026791fa0f95f056cabc6a668789c9ff34b847c529db95b7be13795aeb8d8;
        p[1] = 0xa163b0521d3a97caf321e75cbdd5a6fe30562fab80820b6bbaa28a2a2f14ebe5;
        vm.prank(address(0xd00));
        m.claim(1.2 ether, p, address(0xd00));

        p[0] = 0x0b2224c9f64280a2cb7ced203c28c8370a83f61919c431cd5b1a8b30371b0db1;
        vm.prank(address(0x12));
        m.claim(0.5 ether, p, address(0x12));

        vm.prank(address(0x11));
        m.claim(0.3 ether, _proof(0xb98735b3e6503353711a9ae3b706876bf814c6da72b3c9b53ea640b39dd205d7), address(0x11));
        assertEq(m.claimedTotal(), 2 ether);
        assertEq(quoteTok.balanceOf(address(m)), 0);
    }

    // ---------------------------------------------------------------- reclaim
    function test_reclaim_afterSilence() public {
        (M m, address t, address dev) = _bound(address(quoteTok));
        vm.expectRevert(M.NotDev.selector);
        m.reclaim(dev);
        vm.prank(dev);
        vm.expectRevert(M.StillActive.selector);
        m.reclaim(dev); // not graduated: never
        vm.prank(dev);
        vm.expectRevert(M.BadReceiver.selector);
        m.reclaim(address(0));
        vm.prank(dev);
        vm.expectRevert(M.BadReceiver.selector);
        m.reclaim(address(m));

        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
        quoteTok.mint(address(m), 10 ether);
        m.work(0);
        uint64 seen = m.firstGradSeenAt();

        vm.warp(uint256(seen) + m.SETTLER_SILENCE() - 1);
        vm.prank(dev);
        vm.expectRevert(M.StillActive.selector);
        m.reclaim(dev);

        vm.warp(uint256(seen) + m.SETTLER_SILENCE());
        address to = makeAddr("devOther");
        vm.expectEmit(address(m));
        emit M.Reclaimed(to, 2 ether);
        vm.prank(dev);
        assertEq(m.reclaim(to), 2 ether);
        assertEq(quoteTok.balanceOf(to), 2 ether);
        assertEq(m.reclaimed(), 2 ether);
        assertEq(m.held(), 0);
        assertTrue(m.closed());
        assertFalse(m.escrowOpen());
    }

    /// @dev Audit M-1: after a reclaim the module is closed, so no later root can pay the same escrow twice or fail
    ///      forever against a smaller cap, and every later arrival goes straight to the dev.
    function test_reclaim_closesForGood() public {
        (M m, address t, address dev) = _bound(address(quoteTok));
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
        quoteTok.mint(address(m), 10 ether);
        m.work(0);
        vm.warp(uint256(m.firstGradSeenAt()) + m.SETTLER_SILENCE());
        vm.prank(dev);
        m.reclaim(dev);

        vm.roll(this.bn() + 2);
        vm.prank(settler);
        vm.expectRevert(M.Closed.selector);
        m.post(bytes32(uint256(1)), 0, 1, "");
        vm.prank(dev);
        vm.expectRevert(M.Closed.selector);
        m.reclaim(dev);

        uint256 d0 = quoteTok.balanceOf(dev);
        quoteTok.mint(address(m), 5 ether);
        m.work(0);
        assertEq(quoteTok.balanceOf(dev) - d0, 5 ether);
        assertEq(m.escrowIn(), 2 ether);
    }

    /// @dev A root in effect keeps what it allocated; a recent post or a root still pending holds a reclaim back.
    function test_reclaim_keepsAllocated() public {
        (M m, address t, address dev) = _bound(address(quoteTok));
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
        address a = makeAddr("a");
        quoteTok.mint(address(m), 10 ether); // 2 ether of escrow
        m.work(0);
        (, bytes32 lb) = _settle(m, a, 0.5 ether, makeAddr("b"), 0.5 ether, 1 ether);
        uint64 posted = m.lastPostAt();

        vm.warp(uint256(posted) + m.SETTLER_SILENCE() - 1);
        vm.prank(dev);
        vm.expectRevert(M.StillActive.selector);
        m.reclaim(dev);

        // Audit M-2: a post with nothing new still counts, so a quiet period doesn't open a reclaim
        vm.roll(this.bn() + 2);
        uint64 through = uint64(this.bn() - 1);
        vm.prank(settler);
        m.post(_pair(_leaf(a, 0.5 ether), lb), 1 ether, through, "");
        vm.warp(block.timestamp + 1);
        vm.prank(dev);
        vm.expectRevert(M.PostPending.selector);
        m.reclaim(dev);
        _next(m.DISPUTE_WINDOW());
        vm.prank(dev);
        vm.expectRevert(M.StillActive.selector);
        m.reclaim(dev);

        vm.warp(uint256(m.lastPostAt()) + m.SETTLER_SILENCE());
        vm.prank(dev);
        assertEq(m.reclaim(dev), 1 ether, "only what no root allocated");
        vm.prank(a);
        m.claim(0.5 ether, _proof(lb), a);
        assertEq(quoteTok.balanceOf(a), 0.5 ether, "the allocated part is still there");
    }

    /// @dev Nothing allocated yet: the settler's placeholder root is a valid post that keeps the module from going silent.
    function test_post_placeholderRoot() public {
        (M m,,) = _bound(address(quoteTok));
        vm.roll(this.bn() + 2);
        vm.prank(settler);
        m.post(keccak256("promote-pool-v1: nothing allocated"), 0, 1, "");
        assertEq(m.lastPostAt(), block.timestamp);
    }

    // ---------------------------------------------------------------- sweep and decoys
    function test_sweep_otherAssetsToTheDev() public {
        (M m,, address dev) = _bound(address(quoteTok));
        uint256 d0 = blq.balanceOf(dev);
        blq.mint(address(m), 3 ether);
        vm.prank(makeAddr("anyone"));
        assertEq(m.sweep(address(blq)), 3 ether);
        assertEq(blq.balanceOf(dev) - d0, 3 ether);
        vm.expectRevert(M.NothingOwed.selector);
        m.sweep(address(blq));
        quoteTok.mint(address(m), 1 ether);
        vm.expectRevert(M.BoundQuote.selector);
        m.sweep(address(quoteTok));
    }

    function test_sweep_unboundAnyAsset() public {
        address dev = _newAgent();
        M m = _module(dev);
        uint256 d0 = quoteTok.balanceOf(dev);
        quoteTok.mint(address(m), 3 ether);
        assertEq(m.undistributed(), 0);
        m.work(0);
        assertEq(m.escrowIn(), 0);
        m.sweep(address(quoteTok));
        assertEq(quoteTok.balanceOf(dev) - d0, 3 ether);
    }

    /// @dev A dev pointing a real token at a module bound to a decoy: `token()` shows it, so nothing advertises a pool
    ///      share for the real token, and bind refuses the real token.
    function test_decoy_isVisibleAndCannotRebind() public {
        address dev = _newAgent();
        M m = _module(dev);
        address decoy = _token(dev, m, address(quoteTok), 0);
        m.bind(decoy);
        address real = _token(dev, m, address(blq), 0);
        assertEq(m.token(), decoy);
        assertTrue(m.token() != real);
        vm.expectRevert(M.AlreadyBound.selector);
        m.bind(real);
    }

    // ---------------------------------------------------------------- previewWork
    function test_previewWork() public {
        (M m, address t, address dev) = _bound(address(quoteTok));
        (bool due,) = m.previewWork();
        assertFalse(due, "nothing");
        quoteTok.mint(address(m), 1 ether);
        (due,) = m.previewWork();
        assertFalse(due, "not graduated");
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
        (due,) = m.previewWork();
        assertTrue(due, "over the floor");
        m.work(0);
        (due,) = m.previewWork();
        assertFalse(due, "split");
        M unserved = _module(dev);
        (due,) = unserved.previewWork();
        assertFalse(due, "unbound");
    }

    // ---------------------------------------------------------------- the deploy script's checks
    function test_deployChecks() public {
        D d = new D();
        d.check(address(pad), address(admin), address(factory));
        d.checkCode(address(factory));
        assertEq(d.pendingBatch(address(admin), address(factory)).length, 0);
        vm.prank(owner);
        admin.setFactory(address(factory), false);
        assertEq(d.pendingBatch(address(admin), address(factory)).length, 1);
        // a pad over the same handler, but not this factory's
        address other = makeAddr("other");
        vm.mockCall(other, abi.encodeWithSignature("taxHandler()"), abi.encode(address(handler)));
        vm.expectRevert(abi.encodeWithSelector(D.WiringCheck.selector, "factory.pad"));
        d.check(other, address(admin), address(factory));
    }

    /// @dev §4, first in, first out: tokens taxed and tokens sold in chain order; each chunk's recipient quote goes by the
    ///      trades whose tokens it sold (one rate here, so tokens stand in for weights).
    struct Fifo {
        uint256[] tokens;
        bool[] bound;
        uint256 head;
        uint256 tail;
        uint256 toRecipient;
        uint256 due;
    }

    function _fifoDue(Vm.Log[] memory logs, address t, address pair, address promoter) internal view returns (uint256) {
        Fifo memory q;
        q.tokens = new uint256[](logs.length);
        q.bound = new bool[](logs.length);
        for (uint256 i; i < logs.length; i++) {
            bytes32 sig = logs[i].topics.length == 0 ? bytes32(0) : logs[i].topics[0];
            if (logs[i].emitter == t && sig == keccak256("OuterTax(address,address,uint256,uint256)")) {
                _fifoTrade(q, logs[i], t, pair, promoter);
            } else if (logs[i].emitter != address(handler)) {
                continue;
            } else if (sig == keccak256("TaxDistributed(address,uint8,uint256,uint256,uint256,uint256)")) {
                (,,,, q.toRecipient) = abi.decode(logs[i].data, (uint8, uint256, uint256, uint256, uint256));
            } else if (sig == keccak256("TaxChunkSold(address,uint256,uint256,uint256,bool)")) {
                (uint256 sold,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool));
                _fifoChunk(q, sold);
            }
        }
        return q.due;
    }

    function _fifoTrade(Fifo memory q, Vm.Log memory l, address t, address pair, address promoter) internal view {
        (uint256 taxed,) = abi.decode(l.data, (uint256, uint256));
        address from = address(uint160(uint256(l.topics[1])));
        address to = address(uint160(uint256(l.topics[2])));
        (address p,,) = pm.bindingOf(t, from == pair ? to : from);
        q.tokens[q.tail] = taxed;
        q.bound[q.tail++] = p == promoter;
    }

    function _fifoChunk(Fifo memory q, uint256 sold) internal pure {
        uint256 left = sold;
        uint256 boundTokens;
        while (left > 0) {
            uint256 take = q.tokens[q.head] < left ? q.tokens[q.head] : left;
            if (q.bound[q.head]) boundTokens += take;
            q.tokens[q.head] -= take;
            left -= take;
            if (q.tokens[q.head] == 0) q.head++;
        }
        q.due += (q.toRecipient * SHARE * boundTokens) / (BPS * sold);
    }

    // ---------------------------------------------------------------- end to end, by the spec's settlement rule
    /// @dev Binds on the curve, trades in the pool, the tax reaches the module, and the settlement rule in §4 of the
    ///      spec is applied to the recorded OuterTax logs. Curve income stays with the pad, unaffected.
    function test_e2e_curveBindPoolTaxSettled() public {
        address dev = _newAgent();
        M m = _module(dev);
        address t = _token(dev, m, address(quoteTok), 0);
        m.bind(t);

        address promoter = _newAgent();
        address bound = _newAgent();
        address unbound = _newAgent();
        vm.prank(bound, bound);
        pm.buyWithPromoter(t, 0.5 ether, 0, promoter);
        vm.prank(unbound, unbound);
        pm.buyWithPromoter(t, 0.5 ether, 0, address(0));
        uint256 curveFee = pm.promoterFeeOf(t, promoter);
        assertGt(curveFee, 0, "curve share accrues on the pad");
        _graduate(t);
        address pair = _curvePair(t);

        vm.recordLogs();
        // a buy and sells, bound and not: the tax of each waits in the handler, oldest first
        _poolBuy(t, address(quoteTok), pair, bound, 0.1 ether);
        _next(1 minutes);
        for (uint256 i; i < 4; i++) {
            address seller = i % 2 == 0 ? bound : unbound;
            (uint256 rT,) = _reserves(t, pair);
            deal(t, seller, rT / 50);
            _poolSell(t, pair, seller, rT / 50);
            _next(1 minutes);
        }
        uint256 chunk = handler.maxChunk(t);
        vm.prank(keeper);
        handler.process(t, chunk, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        m.work(0);
        uint256 x = m.escrowIn();
        assertGt(x, 0, "tax reached the escrow");
        assertEq(pm.promoterFeeOf(t, promoter), curveFee, "the pool side leaves the curve share alone");

        uint256 toPromoter = _fifoDue(logs, t, pair, promoter);
        assertGt(toPromoter, 0);
        assertLt(toPromoter, x);
        uint256 toDev = x - toPromoter;

        (bytes32 lp, bytes32 ld) = _settle(m, promoter, toPromoter, dev, toDev, x);
        uint256 p0 = quoteTok.balanceOf(promoter);
        vm.prank(promoter);
        m.claim(toPromoter, _proof(ld), promoter);
        assertEq(quoteTok.balanceOf(promoter) - p0, toPromoter);
        uint256 d0 = quoteTok.balanceOf(dev);
        vm.prank(dev);
        m.claim(toDev, _proof(lp), dev);
        assertEq(quoteTok.balanceOf(dev) - d0, toDev);
        assertEq(m.held(), 0, "nothing left behind");
        assertEq(quoteTok.balanceOf(address(m)), 0);
    }

    /// @dev Part of the tax goes to holders first: only the recipient's rest reaches the module.
    function test_e2e_dividendsUntouched() public {
        address dev = _newAgent();
        M m = _module(dev);
        address t = _token(dev, m, address(quoteTok), 5_000);
        m.bind(t);
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
        address pair = _curvePair(t);
        for (uint256 i; i < 3; i++) {
            address seller = _newAgent();
            (uint256 rT,) = _reserves(t, pair);
            deal(t, seller, rT / 50);
            _poolSell(t, pair, seller, rT / 50);
            _next(1 minutes);
        }
        uint256 chunk = handler.maxChunk(t);
        vm.prank(keeper);
        handler.process(t, chunk, 1);
        uint256 got = m.undistributed();
        assertGt(got, 0);
        uint256 d0 = quoteTok.balanceOf(dev);
        m.work(0);
        assertEq(m.escrowIn(), (got * SHARE) / BPS);
        assertEq(quoteTok.balanceOf(dev) - d0, got - m.escrowIn());
    }
}
