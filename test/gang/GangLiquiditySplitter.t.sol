// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {LpMockPair, LpMockPairFactory} from "../mocks/LpMockPair.sol";
import {GangLiquiditySplitter} from "../../src/gang/GangLiquiditySplitter.sol";
import {GangLiquiditySplitterFactory} from "../../src/gang/GangLiquiditySplitterFactory.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {DeployGangLiquiditySplitterFactory} from "../../script/DeployGangLiquiditySplitterFactory.s.sol";

/// @dev Answers every view the deploy script's `check` reads like a real factory / implementation, with other code.
contract FakeLpImpl {
    address public pad;
    address public taxHandler;
    address public factory;
    bytes32 public constant moduleType = "lp-burn-v1";

    constructor(address pad_, address handler_) {
        (pad, taxHandler) = (pad_, handler_);
    }

    function setFactory(address f) external {
        factory = f;
    }
}

contract FakeLpFactory {
    address public pad;
    address public admin;
    address public implementation;

    constructor(address pad_, address admin_, address impl_) {
        (pad, admin, implementation) = (pad_, admin_, impl_);
    }
}

/// @notice GangLiquiditySplitter (dev 税按比例自动加池子) on the whole merged deployment, over pairs that keep the V2
///         oracle and mint LP as UniswapV2Pair does: the factory, binding, the split, ratio changes (raise now / cut
///         after notice), the chunked liquidity add (buy half, deposit, match, LP to 0xdead) with its pace and TWAP
///         check and the keeper's previewWork / work, owed and shortfall, sweep, the deploy script, and the pool tax
///         paying it end to end. The parts that are GangBuybackSplitter's are ported from its tests.
contract GangLiquiditySplitterTest is GangFixture {
    address keeper = makeAddr("keeper");
    GangHandlerAdmin admin;
    GangLiquiditySplitterFactory factory;
    uint256 _salt;

    uint16 constant TAX = 300;

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
        factory = new GangLiquiditySplitterFactory(address(pad), address(admin));
        vm.prank(owner);
        admin.setFactory(address(factory), true);
    }

    // ---------------------------------------------------------------- helpers
    /// @dev The dev's splitter, from the factory (listed by the admin).
    function _splitter(address dev, uint16 bps) internal returns (GangLiquiditySplitter s) {
        vm.prank(dev);
        s = GangLiquiditySplitter(factory.create(bps, bytes32(++_salt), address(0)));
    }

    /// @dev The dev gets a splitter, creates a taxed V3 token paying it, buys on the curve, and anyone binds it.
    function _setup(address quote, uint16 bps, bool grad)
        internal
        returns (GangLiquiditySplitter s, address t, address dev)
    {
        dev = _newAgent();
        s = _splitter(dev, bps);
        t = _createV3(dev, quote, _tax(TAX, TAX, 5_000, address(s)));
        s.bind(t);
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        if (grad) _graduate(t);
    }

    /// @dev Deploys behind an external call: `src/gang/**` builds via-ir, so a `new` of it here is a vm.deployCode,
    ///      which vm.expectRevert does not see (the revert would end the test as a pass).
    function newFactory(address pad_, address admin_) external returns (GangLiquiditySplitterFactory) {
        return new GangLiquiditySplitterFactory(pad_, admin_);
    }

    function newAdmin(address owner_, address handler_) external returns (GangHandlerAdmin) {
        return new GangHandlerAdmin(owner_, handler_);
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
        GangHandlerAdmin elsewhere = new GangHandlerAdmin(owner, makeAddr("otherHandler"));
        vm.expectRevert(GangLiquiditySplitterFactory.WrongHandler.selector);
        this.newFactory(address(pad), address(elsewhere));
        vm.expectRevert(GangLiquiditySplitterFactory.ZeroAddress.selector);
        this.newFactory(address(pad), address(0));
        vm.expectRevert(GangHandlerAdmin.ZeroAddress.selector);
        this.newAdmin(owner, address(0));

        // only an Agent (only an Agent can create the token)
        vm.prank(makeAddr("notAgent"));
        vm.expectRevert(GangLiquiditySplitterFactory.NotAgent.selector);
        factory.create(5_000, bytes32(0), address(0));
        address dev = _newAgent();
        vm.prank(dev);
        vm.expectRevert(GangLiquiditySplitter.BadBps.selector);
        factory.create(10_001, bytes32(0), address(0));

        // the address is known before the clone, and is the dev's own: a salt is per dev, once
        bytes32 salt = keccak256("launch-1");
        address predicted = factory.predict(dev, salt);
        assertEq(predicted.code.length, 0);
        vm.prank(dev);
        address s = factory.create(10_000, salt, address(0));
        assertEq(s, predicted);
        vm.prank(dev);
        vm.expectRevert(Errors.FailedDeployment.selector);
        factory.create(10_000, salt, address(0));
        address other = _newAgent();
        assertTrue(factory.predict(other, salt) != s);
        vm.prank(other);
        assertEq(factory.create(1, salt, address(0)), factory.predict(other, salt));
        GangLiquiditySplitter sp = GangLiquiditySplitter(s);
        assertEq(sp.dev(), dev);
        assertEq(sp.lpBps(), 10_000);
        assertEq(sp.token(), address(0));
        assertEq(sp.pad(), address(pad));
        assertEq(sp.taxHandler(), address(handler));
        assertEq(sp.factory(), address(factory));
        assertEq(sp.moduleType(), bytes32("lp-burn-v1"));
        assertEq(sp.payee(), dev, "payee defaults to the dev");
        assertTrue(handler.isListed(s));
        assertEq(admin.moduleOf(s), address(factory));
        assertEq(factory.count(), 2);
        assertEq(factory.splitters()[0], s);

        // the implementation is never initialized; a clone only once, only by the factory
        // a clone can't be its own payee (its predicted address)
        bytes32 selfSalt = keccak256("self-payee");
        address selfAt = factory.predict(dev, selfSalt);
        vm.prank(dev);
        vm.expectRevert(GangLiquiditySplitter.BadPayee.selector);
        factory.create(5_000, selfSalt, selfAt);

        GangLiquiditySplitter impl = GangLiquiditySplitter(factory.implementation());
        vm.expectRevert(GangLiquiditySplitter.NotClone.selector);
        impl.initialize(dev, 1, address(0));
        vm.expectRevert(GangLiquiditySplitter.NotFactory.selector);
        sp.initialize(dev, 1, address(0));
        vm.prank(address(factory));
        vm.expectRevert(GangLiquiditySplitter.AlreadyInitialized.selector);
        sp.initialize(dev, 1, address(0));
    }

    // ---------------------------------------------------------------- payee
    /// @dev The dev's part goes to the payee: named at create, changed by the dev at once; quote that arrived before a
    ///      change goes to the old payee, what is owed and swept to the payee of that moment.
    function test_payee_atCreateAndChanged() public {
        address dev = _newAgent();
        address treasury = makeAddr("treasury");
        vm.prank(dev);
        GangLiquiditySplitter s = GangLiquiditySplitter(factory.create(3_000, bytes32(++_salt), treasury));
        assertEq(s.payee(), treasury);
        address t = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(s)));
        s.bind(t);

        uint256 dev0 = _bal(address(wbnb), dev);
        wbnb.mintUnlimited(address(s), 10 ether);
        s.split();
        assertEq(_bal(address(wbnb), treasury), 7 ether, "the dev part to the payee");
        assertEq(_bal(address(wbnb), dev), dev0, "nothing to the dev");
        assertEq(s.lpLeft(), 3 ether);

        // only the dev changes it, never to 0
        vm.prank(treasury);
        vm.expectRevert(GangLiquiditySplitter.NotDev.selector);
        s.setPayee(treasury);
        vm.prank(dev);
        vm.expectRevert(GangLiquiditySplitter.ZeroAddress.selector);
        s.setPayee(address(0));
        vm.prank(dev);
        vm.expectRevert(GangLiquiditySplitter.BadPayee.selector);
        s.setPayee(address(s));

        // what arrived before the change is split to the old payee first
        address next = makeAddr("next");
        wbnb.mintUnlimited(address(s), 10 ether);
        vm.expectEmit(address(s));
        emit GangLiquiditySplitter.PayeeSet(treasury, next);
        vm.prank(dev);
        s.setPayee(next);
        assertEq(_bal(address(wbnb), treasury), 14 ether);
        assertEq(_bal(address(wbnb), next), 0);
        wbnb.mintUnlimited(address(s), 10 ether);
        s.split();
        assertEq(_bal(address(wbnb), next), 7 ether);

        // swept assets go to the payee too
        quoteTok.mintUnlimited(address(s), 2 ether);
        s.sweep(address(quoteTok));
        assertEq(_bal(address(quoteTok), next), 2 ether);
    }

    /// @dev A payee the quote blacklists is owed, the LP part is not held up; the owed part goes to the payee the dev
    ///      names next.
    function test_payee_owedGoesToTheCurrentPayee() public {
        address dev = _newAgent();
        address blocked = makeAddr("blocked");
        vm.prank(dev);
        GangLiquiditySplitter s = GangLiquiditySplitter(factory.create(5_000, bytes32(++_salt), blocked));
        address t = _createV3(dev, address(blq), _tax(TAX, TAX, 5_000, address(s)));
        s.bind(t);
        blq.setBlocked(blocked, true);
        blq.mint(address(s), 4 ether);
        vm.expectEmit(address(s));
        emit GangLiquiditySplitter.DevOwed(2 ether);
        s.split();
        assertEq(s.devOwed(), 2 ether);
        assertEq(s.lpLeft(), 2 ether);
        vm.expectRevert("blacklisted");
        s.releaseDev();

        address fresh = makeAddr("fresh");
        vm.prank(dev);
        s.setPayee(fresh);
        assertEq(s.releaseDev(), 2 ether);
        assertEq(_bal(address(blq), fresh), 2 ether);
        assertEq(s.devOwed(), 0);
    }

    // ---------------------------------------------------------------- bind
    function test_bind_checks() public {
        address dev = _newAgent();
        GangLiquiditySplitter s = _splitter(dev, 5_000);

        vm.expectRevert(GangLiquiditySplitter.NotCurve.selector);
        s.bind(makeAddr("nope"));
        address fair = _createFair(dev, address(wbnb), 100);
        vm.expectRevert(GangLiquiditySplitter.NotCurve.selector);
        s.bind(fair);

        // a listed recipient is open to every creator: another creator's token can't take the binding
        address other = _createV3(_newAgent(), address(wbnb), _tax(TAX, TAX, 5_000, address(s)));
        vm.expectRevert(GangLiquiditySplitter.NotCreator.selector);
        s.bind(other);

        // the dev's token paying someone else
        address own = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, dev));
        vm.expectRevert(GangLiquiditySplitter.NotRecipient.selector);
        s.bind(own);

        // anyone binds the right one, once
        address t = _createV3(dev, address(quoteTok), _tax(TAX, TAX, 5_000, address(s)));
        vm.expectEmit(address(s));
        emit GangLiquiditySplitter.Bound(t, address(quoteTok));
        vm.prank(makeAddr("stranger"));
        s.bind(t);
        assertEq(s.token(), t);
        assertEq(s.quote(), address(quoteTok));
        vm.expectRevert(GangLiquiditySplitter.AlreadyBound.selector);
        s.bind(t);
    }

    // ---------------------------------------------------------------- split
    function test_split_byRatio() public {
        (GangLiquiditySplitter s,, address dev) = _setup(address(wbnb), 3_000, false);
        uint256 dev0 = _bal(address(wbnb), dev);
        wbnb.mintUnlimited(address(s), 10 ether);
        assertEq(s.unsplit(), 10 ether);

        vm.expectEmit(address(s));
        emit GangLiquiditySplitter.Split(10 ether, 3 ether, 7 ether);
        vm.prank(makeAddr("anyone"));
        s.split();
        assertEq(_bal(address(wbnb), dev) - dev0, 7 ether);
        assertEq(s.lpLeft(), 3 ether);
        assertEq(_bal(address(wbnb), address(s)), 3 ether);
        assertEq(s.unsplit(), 0);

        // nothing new: a no-op
        s.split();
        assertEq(s.lpLeft(), 3 ether);
    }

    function test_split_edges() public {
        (GangLiquiditySplitter all,, address devA) = _setup(address(wbnb), 10_000, false);
        wbnb.mintUnlimited(address(all), 1 ether);
        uint256 a0 = _bal(address(wbnb), devA);
        all.split();
        assertEq(all.lpLeft(), 1 ether);
        assertEq(_bal(address(wbnb), devA), a0);

        (GangLiquiditySplitter none,, address devB) = _setup(address(wbnb), 0, false);
        wbnb.mintUnlimited(address(none), 1 ether);
        uint256 b0 = _bal(address(wbnb), devB);
        none.split();
        assertEq(none.lpLeft(), 0);
        assertEq(_bal(address(wbnb), devB) - b0, 1 ether);
    }

    // ---------------------------------------------------------------- ratio changes
    function test_raise_appliesNow_oldQuoteKeepsOldRatio() public {
        (GangLiquiditySplitter s,, address dev) = _setup(address(wbnb), 2_000, false);
        uint256 dev0 = _bal(address(wbnb), dev);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(GangLiquiditySplitter.NotDev.selector);
        s.setLpBps(5_000);
        vm.prank(dev);
        vm.expectRevert(GangLiquiditySplitter.BadBps.selector);
        s.setLpBps(10_001);

        wbnb.mintUnlimited(address(s), 10 ether);
        vm.expectEmit(address(s));
        emit GangLiquiditySplitter.LpBpsSet(2_000, 5_000);
        vm.prank(dev);
        s.setLpBps(5_000);
        assertEq(s.lpBps(), 5_000);
        // the 10 that came before the raise went at 20%
        assertEq(s.lpLeft(), 2 ether);
        assertEq(_bal(address(wbnb), dev) - dev0, 8 ether);

        wbnb.mintUnlimited(address(s), 10 ether);
        s.split();
        assertEq(s.lpLeft(), 7 ether);
        assertEq(_bal(address(wbnb), dev) - dev0, 13 ether);
    }

    function test_lower_waitsForNotice() public {
        (GangLiquiditySplitter s,, address dev) = _setup(address(wbnb), 5_000, false);
        uint256 dev0 = _bal(address(wbnb), dev);

        vm.expectRevert(GangLiquiditySplitter.NoProposal.selector);
        s.applyLpBps();

        uint64 at = uint64(block.timestamp + 3 days);
        vm.expectEmit(address(s));
        emit GangLiquiditySplitter.LpBpsProposed(1_000, at);
        vm.prank(dev);
        s.setLpBps(1_000);
        assertEq(s.lpBps(), 5_000, "not yet");
        assertEq(s.pendingBps(), 1_000);
        assertEq(s.pendingAt(), at);

        // during the notice the old share holds
        wbnb.mintUnlimited(address(s), 10 ether);
        s.split();
        assertEq(s.lpLeft(), 5 ether);

        vm.warp(at - 1);
        vm.expectRevert(GangLiquiditySplitter.NotDue.selector);
        s.applyLpBps();

        // quote that arrived before the cut is split at the old share first
        vm.warp(at);
        wbnb.mintUnlimited(address(s), 10 ether);
        vm.prank(makeAddr("anyone"));
        s.applyLpBps();
        assertEq(s.lpBps(), 1_000);
        assertEq(s.pendingAt(), 0);
        assertEq(s.lpLeft(), 10 ether);
        assertEq(_bal(address(wbnb), dev) - dev0, 10 ether);

        wbnb.mintUnlimited(address(s), 10 ether);
        s.split();
        assertEq(s.lpLeft(), 11 ether);
        assertEq(_bal(address(wbnb), dev) - dev0, 19 ether);

        vm.expectRevert(GangLiquiditySplitter.NoProposal.selector);
        s.applyLpBps();
    }

    function test_lower_lapsesAfterTtl() public {
        (GangLiquiditySplitter s,, address dev) = _setup(address(wbnb), 5_000, false);
        vm.prank(dev);
        s.setLpBps(0);
        uint64 at = s.pendingAt();

        // the last moment still applies; one second later the cut has lapsed
        uint256 snap = vm.snapshotState();
        vm.warp(at + s.CUT_TTL());
        s.applyLpBps();
        assertEq(s.lpBps(), 0);
        vm.revertToState(snap);

        (bool live, uint16 bps, uint64 when) = s.pendingCut();
        assertTrue(live);
        assertEq(bps, 0);
        assertEq(when, at);

        vm.warp(at + s.CUT_TTL() + 1);
        vm.expectRevert(GangLiquiditySplitter.CutLapsed.selector);
        s.applyLpBps();
        assertEq(s.lpBps(), 5_000);
        (live, bps, when) = s.pendingCut();
        assertFalse(live);
        assertEq(when, 0);

        // a raise clears the lapsed request without a cancel event (it was already dead)
        uint256 snap2 = vm.snapshotState();
        vm.recordLogs();
        vm.prank(dev);
        s.setLpBps(5_000);
        assertEq(vm.getRecordedLogs().length, 1, "only LpBpsSet");
        assertEq(s.pendingAt(), 0);
        vm.revertToState(snap2);

        // a new request starts a new notice
        vm.prank(dev);
        s.setLpBps(0);
        vm.warp(block.timestamp + 3 days);
        s.applyLpBps();
        assertEq(s.lpBps(), 0);
    }

    function test_lower_cancelledByCurrentOrHigher() public {
        (GangLiquiditySplitter s,, address dev) = _setup(address(wbnb), 5_000, false);
        vm.startPrank(dev);
        s.setLpBps(0);
        // asking again replaces the cut and restarts the notice
        _next(2 days);
        s.setLpBps(2_000);
        assertEq(s.pendingBps(), 2_000);
        assertEq(s.pendingAt(), block.timestamp + 3 days);

        vm.expectEmit(address(s));
        emit GangLiquiditySplitter.LpBpsProposalCancelled(2_000);
        s.setLpBps(5_000);
        vm.stopPrank();
        assertEq(s.pendingAt(), 0);
        assertEq(s.lpBps(), 5_000);
        _next(3 days);
        vm.expectRevert(GangLiquiditySplitter.NoProposal.selector);
        s.applyLpBps();
    }

    /// @dev Review: a quote that blacklists the dev must not freeze the LP part (every path splits first).
    function test_devBlacklisted_owedNotBlocking() public {
        (GangLiquiditySplitter s, address t, address dev) = _setup(address(blq), 5_000, true);
        blq.setBlocked(dev, true);
        blq.mint(address(s), 1 ether);

        vm.expectEmit(address(s));
        emit GangLiquiditySplitter.DevOwed(0.5 ether);
        s.addChunk(0); // splits (the dev's push fails, owed), records the observation
        assertEq(s.devOwed(), 0.5 ether);
        assertEq(s.lpLeft(), 0.5 ether);
        assertEq(s.unsplit(), 0);

        // owed quote is never added to the pool, and the chunks run
        _next(10 minutes);
        uint256 lp0 = LpMockPair(_curvePair(t)).balanceOf(s.DEAD());
        (uint256 q,, uint256 liq) = s.addChunk(0);
        assertGt(q, 0);
        assertGt(liq, 0);
        assertEq(LpMockPair(_curvePair(t)).balanceOf(s.DEAD()) - lp0, liq);
        assertEq(s.devOwed(), 0.5 ether);
        // the deposit let the handler sell a chunk of its tax, paying this recipient: that quote waits unsplit
        assertGt(s.unsplit(), 0);
        assertEq(_bal(address(blq), address(s)), s.lpLeft() + 0.5 ether + s.unsplit());

        // ratio changes still work (they split first: the dev's part of what was paid in is owed too)
        vm.prank(dev);
        s.setLpBps(6_000);
        uint256 owed = s.devOwed();
        assertGt(owed, 0.5 ether);

        vm.expectRevert("blacklisted");
        s.releaseDev();
        blq.setBlocked(dev, false);
        uint256 dev0 = _bal(address(blq), dev);
        vm.expectEmit(address(s));
        emit GangLiquiditySplitter.DevReleased(owed);
        vm.prank(makeAddr("anyone"));
        assertEq(s.releaseDev(), owed);
        assertEq(_bal(address(blq), dev) - dev0, owed);
        assertEq(s.devOwed(), 0);
        vm.expectRevert(GangLiquiditySplitter.NothingOwed.selector);
        s.releaseDev();
    }

    /// @dev Review: a quote balance that shrinks below what is held must not lock the splitter (unsplit underflow).
    function test_shortfall_sharedInProportion() public {
        (GangLiquiditySplitter s,, address dev) = _setup(address(blq), 5_000, true);
        blq.setBlocked(dev, true);
        blq.mint(address(s), 4 ether);
        s.split(); // 2 to the LP part, 2 owed
        assertEq(s.lpLeft(), 2 ether);
        assertEq(s.devOwed(), 2 ether);

        // the quote takes half of the splitter's balance
        deal(address(blq), address(s), 2 ether);
        assertEq(s.unsplit(), 0);
        vm.expectEmit(address(s));
        emit GangLiquiditySplitter.Shortfall(2 ether);
        s.split();
        assertEq(s.lpLeft(), 1 ether);
        assertEq(s.devOwed(), 1 ether);

        // and keeps working: new quote splits, the LP part runs, the owed part is released
        blq.mint(address(s), 2 ether);
        s.addChunk(0);
        assertEq(s.lpLeft(), 2 ether);
        assertEq(s.devOwed(), 2 ether);
        _next(10 minutes);
        (uint256 q,,) = s.addChunk(0);
        assertGt(q, 0);
        blq.setBlocked(dev, false);
        assertEq(s.releaseDev(), 2 ether);
    }

    /// @dev Review: with a shortfall nobody split yet, `releaseDev` shares it first — the dev can't take the whole owed
    ///      part and leave the loss to the LP part; `previewAdd` sees the shared amount too.
    function test_shortfall_releaseDevSharesFirst() public {
        (GangLiquiditySplitter s, address t, address dev) = _setup(address(blq), 5_000, true);
        blq.setBlocked(dev, true);
        blq.mint(address(s), 4 ether);
        s.addChunk(0); // 2 to the pool, 2 owed; records the observation
        _next(10 minutes);

        deal(address(blq), address(s), 2.5 ether); // 1.5 taken
        (, uint256 pq,) = s.previewAdd();
        (, uint256 rQ) = _reserves(t, s.pair());
        uint256 shared = 2.5 ether - (2 ether * 2.5 ether) / 4 ether; // the LP part's 1.25
        assertEq(pq, shared < (rQ * 50) / 10_000 ? shared : (rQ * 50) / 10_000, "preview after the shortfall");

        blq.setBlocked(dev, false);
        uint256 dev0 = _bal(address(blq), dev);
        assertEq(s.releaseDev(), 1.25 ether);
        assertEq(_bal(address(blq), dev) - dev0, 1.25 ether);
        assertEq(s.lpLeft(), 1.25 ether);
        assertEq(_bal(address(blq), address(s)), 1.25 ether);

        // all of it taken: the owed part is gone too, nothing to release
        blq.setBlocked(dev, true);
        blq.mint(address(s), 2 ether); // 1 more each
        s.split();
        assertEq(s.devOwed(), 1 ether);
        deal(address(blq), address(s), 0);
        blq.setBlocked(dev, false);
        vm.expectRevert(GangLiquiditySplitter.NothingOwed.selector);
        s.releaseDev();
    }

    // ---------------------------------------------------------------- sweep
    function test_sweep() public {
        address dev = _newAgent();
        GangLiquiditySplitter s = _splitter(dev, 5_000);
        wbnb.mintUnlimited(address(s), 1 ether);
        // unbound: nothing leaves (a dev can't skip the binding and take the tax)
        vm.expectRevert(GangLiquiditySplitter.NotBound.selector);
        s.sweep(address(wbnb));

        address t = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(s)));
        s.bind(t);
        vm.expectRevert(GangLiquiditySplitter.NotSweepable.selector);
        s.sweep(address(wbnb));

        // another token's tax in another quote goes to the dev whole
        quoteTok.mintUnlimited(address(s), 2 ether);
        uint256 dev0 = _bal(address(quoteTok), dev);
        vm.prank(makeAddr("anyone"));
        s.sweep(address(quoteTok));
        assertEq(_bal(address(quoteTok), dev) - dev0, 2 ether);

        // what arrived before the binding is split like the rest
        s.split();
        assertEq(s.lpLeft(), 0.5 ether);
    }

    // ---------------------------------------------------------------- the chunk
    function _lp(address t, address who) internal view returns (uint256) {
        return LpMockPair(_curvePair(t)).balanceOf(who);
    }

    function test_add_refusedBeforeGraduationOrEmpty() public {
        (GangLiquiditySplitter s,,) = _setup(address(wbnb), 5_000, false);
        vm.expectRevert(GangLiquiditySplitter.NothingToAdd.selector);
        s.addChunk(0);

        wbnb.mintUnlimited(address(s), 1 ether);
        (bool ready,,) = s.previewAdd();
        assertFalse(ready);
        (bool due,) = s.previewWork();
        assertFalse(due);
        vm.expectRevert(GangLiquiditySplitter.NotTradable.selector);
        s.addChunk(0);
    }

    /// @dev Each chunk: half buys (buy tax), all of it goes back into the pair (sell tax, the handler's swap-back
    ///      first), the quote matching it at the reserves of that moment follows, the LP goes to 0xdead. Checked to the
    ///      wei from the pair's reserves after the mint (= the reserves before the deposit + what was deposited).
    function test_add_chunksUntilDone() public {
        (GangLiquiditySplitter s, address t, address dev) = _setup(address(wbnb), 5_000, true);
        wbnb.mintUnlimited(address(s), 1 ether);
        uint256 dev0 = _bal(address(wbnb), dev);

        // first call splits and records the observation only
        (uint256 q0, uint256 t0, uint256 l0) = s.addChunk(0);
        assertEq(q0 + t0 + l0, 0);
        assertEq(s.lpLeft(), 0.5 ether);
        assertEq(_bal(address(wbnb), dev) - dev0, 0.5 ether);
        address pair = s.pair();
        assertEq(pair, _curvePair(t));
        _next(5 minutes);
        (q0,,) = s.addChunk(0);
        assertEq(q0, 0, "window not passed");

        uint256 deadLp0 = _lp(t, s.DEAD());
        uint256 spent;
        uint256 minted;
        uint256 chunks;
        uint256 paidIn; // LP share of what the handler's swap-backs paid in mid-chunk (split at the next call)
        while (s.lpLeft() > 1e9) {
            _next(10 minutes);
            uint256 before = s.lpLeft();
            s.split();
            paidIn += s.lpLeft() - before;
            (, uint256 rQ0) = _reserves(t, pair);
            (bool ok, uint256 chunk, uint256 pOut) = s.previewAdd();
            assertTrue(ok);
            assertLe(chunk, (rQ0 * 50) / 10_000, "chunk cap");
            uint256 supply0 = LpMockPair(pair).totalSupply();
            uint256 left0 = s.lpLeft();
            (uint256 q, uint256 tokensIn, uint256 liq) = s.addChunk(pOut);
            (uint256 rT1, uint256 rQ1) = _reserves(t, pair);
            uint256 half = chunk / 2;
            assertGt(q, half, "the buy and a deposit");
            assertLe(q, chunk, "within the chunk");
            assertLt(tokensIn, pOut, "the sell tax on the deposit");
            assertEq(tokensIn, pOut - (pOut * TAX) / 10_000, "sell tax only");
            // reserves before the deposit = after the mint less the deposit; the quote matched them, rounded up
            uint256 match_ = q - half;
            uint256 rT = rT1 - tokensIn;
            uint256 rQ = rQ1 - match_;
            assertEq(match_, (tokensIn * rQ + rT - 1) / rT, "matched at the reserves after the deposit");
            uint256 lt = (tokensIn * supply0) / rT;
            uint256 lq = (match_ * supply0) / rQ;
            assertEq(liq, lt < lq ? lt : lq, "UniswapV2 mint");
            assertEq(s.lpLeft(), left0 - q, "the rest stays set aside");
            assertEq(_bal(t, address(s)), 0, "holds no token");
            assertEq(_lp(t, address(s)), 0, "holds no LP");
            spent += q;
            minted += liq;
            chunks++;
            if (s.lpLeft() > 0) {
                vm.expectRevert(GangLiquiditySplitter.AddTooSoon.selector);
                s.addChunk(0);
            }
        }
        assertGt(chunks, 2);
        assertGt(paidIn, 0, "the deposits let the handler sell its tax, paying this recipient");
        assertEq(spent + s.lpLeft(), 0.5 ether + paidIn, "every wei spent or set aside");
        assertEq(_lp(t, s.DEAD()) - deadLp0, minted, "all LP at 0xdead");
    }

    /// @dev The last wei never reverts: 3 wei still add (a wei buys many token units at a curve's price), 1 wei has
    ///      no half and waits.
    function test_add_dustNeverReverts() public {
        (GangLiquiditySplitter s,,) = _setup(address(wbnb), 10_000, true);
        wbnb.mintUnlimited(address(s), 3);
        s.addChunk(0);
        _next(10 minutes);
        (uint256 q, uint256 tokensIn, uint256 liq) = s.addChunk(0);
        assertEq(q, 2, "1 wei buys, 1 wei matches");
        assertGt(tokensIn, 0);
        assertGt(liq, 0);

        (GangLiquiditySplitter s1,,) = _setup(address(wbnb), 10_000, true);
        wbnb.mintUnlimited(address(s1), 1);
        s1.addChunk(0);
        _next(10 minutes);
        (bool ready,,) = s1.previewAdd();
        assertFalse(ready, "no half");
        (q, tokensIn, liq) = s1.addChunk(0);
        assertEq(q + tokensIn + liq, 0, "waits");
        assertEq(s1.lpLeft(), 1);
        assertEq(s1.lastAddAt(), 0, "no chunk counted");
    }

    /// @dev Tokens someone left in the pair (unsynced) go into its reserves at the buy: nothing for anyone, no revert.
    function test_add_tokensLeftInPairOnlyDeepenThePool() public {
        (GangLiquiditySplitter s, address t,) = _setup(address(wbnb), 10_000, true);
        address pair = _curvePair(t);
        wbnb.mintUnlimited(address(s), 10 ether);
        s.addChunk(0);
        _next(10 minutes);
        (uint256 rT,) = _reserves(t, pair);
        address donor = _newAgent();
        deal(t, donor, rT / 100);
        vm.prank(donor);
        IERC20(t).transfer(pair, rT / 100); // taxed, unsynced
        // the buy swap takes the unsynced tokens into the reserves (UniswapV2 prices on balances): the donor sold them
        // for nothing, the deposit is matched as usual
        (uint256 q, uint256 tokensIn, uint256 liq) = s.addChunk(0);
        assertGt(q, 0);
        assertGt(tokensIn, 0);
        assertGt(liq, 0);
        assertEq(_bal(t, address(s)), 0);
        assertEq(_lp(t, donor), 0);
    }

    /// @dev LP audit 2026-10-30 L-1: quote left in the pair just before the keeper's call (to be skimmed back after)
    ///      must not fail `work(previewWork().minOut)`: the bar is scaled down for a quote that delivers less, never up.
    function test_add_quoteLeftInPairDoesNotFailTheKeeper() public {
        (GangLiquiditySplitter s, address t,) = _setup(address(wbnb), 10_000, true);
        address pair = _curvePair(t);
        (, uint256 rQ) = _reserves(t, pair);
        wbnb.mintUnlimited(address(s), rQ);
        s.addChunk(0);
        _next(10 minutes);
        (bool due, uint256 minOut) = s.previewWork();
        assertTrue(due);
        assertGt(minOut, 0);
        address griefer = _newAgent();
        vm.prank(griefer);
        wbnb.transfer(pair, (rQ * 3) / 100);
        vm.prank(keeper);
        s.work(minOut);
        assertEq(s.lastAddAt(), block.timestamp, "the chunk went through");
    }

    /// @dev LP audit 2026-10-30 I-3: unsynced quote in the pair makes the match reach the other half; capped there, no
    ///      revert, the pair ends synced.
    function test_add_quoteLeftInPairCapsTheMatch() public {
        (GangLiquiditySplitter s, address t,) = _setup(address(wbnb), 10_000, true);
        address pair = _curvePair(t);
        (, uint256 rQ) = _reserves(t, pair);
        wbnb.mintUnlimited(address(s), rQ);
        s.addChunk(0);
        _next(10 minutes);
        (, uint256 chunk,) = s.previewAdd();
        address donor = _newAgent();
        vm.prank(donor);
        wbnb.transfer(pair, rQ / 100);
        (uint256 q, uint256 tokensIn, uint256 liq) = s.addChunk(0);
        assertEq(q, chunk, "matched quote capped at the other half");
        assertGt(tokensIn, 0);
        assertGt(liq, 0);
        (uint256 rT1, uint256 rQ1) = _reserves(t, pair);
        assertEq(IERC20(t).balanceOf(pair), rT1, "synced");
        assertEq(wbnb.balanceOf(pair), rQ1, "synced");
    }

    /// @dev GangBond audit 2026-10-29 H-1, as for the buy-back: one chunk per CHUNK_GAP.
    function test_add_oneChunkPerGap() public {
        (GangLiquiditySplitter s,,) = _setup(address(wbnb), 10_000, true);
        wbnb.mintUnlimited(address(s), 1 ether);
        s.addChunk(0);
        _next(10 minutes);
        (uint256 q,,) = s.addChunk(0);
        assertGt(q, 0);
        assertEq(s.lastAddAt(), block.timestamp);
        uint256 last = s.lastAddAt();
        uint64 gap = s.CHUNK_GAP();
        for (uint256 i = 1; i < gap; i += 12) {
            vm.warp(last + i);
            vm.roll(block.number + 1);
            (bool ready,,) = s.previewAdd();
            assertFalse(ready);
            (bool due,) = s.previewWork();
            assertFalse(due);
            vm.expectRevert(GangLiquiditySplitter.AddTooSoon.selector);
            s.addChunk(0);
            vm.expectRevert(GangLiquiditySplitter.AddTooSoon.selector);
            s.work(0);
        }
        vm.warp(last + gap);
        vm.roll(block.number + 1);
        (bool ok,,) = s.previewAdd();
        assertTrue(ok);
        (q,,) = s.addChunk(0);
        assertGt(q, 0);
    }

    /// @dev A price lifted more than 2% above the pair's TWAP: no chunk (no buy at the top, no deposit at that ratio)
    ///      until the high price is the average.
    function test_add_skipsAfterPump() public {
        (GangLiquiditySplitter s, address t,) = _setup(address(wbnb), 10_000, true);
        wbnb.mintUnlimited(address(s), 1 ether);
        s.addChunk(0);
        address pair = s.pair();
        _next(10 minutes);
        (, uint256 rQ) = _reserves(t, pair);
        _poolBuy(t, address(wbnb), pair, _newAgent(), (rQ * 5) / 100);
        uint256 left = s.lpLeft();
        (bool ready,,) = s.previewAdd();
        assertFalse(ready);
        (uint256 q, uint256 tokensIn, uint256 liq) = s.addChunk(0);
        assertEq(q + tokensIn + liq, 0);
        assertEq(s.lpLeft(), left);
        for (uint256 i; i < 6 && q == 0; i++) {
            _next(10 minutes);
            (q,,) = s.addChunk(0);
        }
        assertGt(q, 0);
    }

    /// @dev H-1 replayed on the LP part: pumped and held, then the attacker sells back every block — one chunk a minute.
    function test_add_pumpAndHoldGetsOneChunkPerGap() public {
        (GangLiquiditySplitter s, address t,) = _setup(address(wbnb), 10_000, true);
        address pair = _curvePair(t);
        (, uint256 rQ) = _reserves(t, pair);
        wbnb.mintUnlimited(address(s), rQ / 5);
        address attacker = _newAgent();
        _poolBuy(t, address(wbnb), pair, attacker, (rQ * 414) / 1000);
        s.addChunk(0);
        _next(10 minutes);
        uint256 start = vm.getBlockTimestamp();
        uint256 left0 = s.lpLeft();
        uint256 chunks;
        for (uint256 i; i < 133; i++) {
            vm.warp(start + (i * 45) / 100);
            vm.roll(block.number + 1);
            try s.addChunk(0) returns (uint256 q, uint256, uint256) {
                if (q != 0) chunks++;
            } catch (bytes memory err) {
                assertEq(bytes4(err), GangLiquiditySplitter.AddTooSoon.selector);
            }
        }
        assertEq(chunks, 1);
        assertLe(left0 - s.lpLeft(), (rQ * 2 * 50) / 10_000, "one chunk of the pumped reserve");
    }

    function test_add_slippage() public {
        (GangLiquiditySplitter s,,) = _setup(address(wbnb), 10_000, true);
        wbnb.mintUnlimited(address(s), 1 ether);
        s.addChunk(0);
        _next(10 minutes);
        (bool ok,, uint256 pOut) = s.previewAdd();
        assertTrue(ok);
        vm.expectRevert(GangLiquiditySplitter.Slippage.selector);
        s.addChunk(pOut + 1);
        (uint256 q,,) = s.addChunk(pOut);
        assertGt(q, 0);
    }

    function test_add_erc20Quote() public {
        (GangLiquiditySplitter s, address t, address dev) = _setup(address(quoteTok), 4_000, true);
        quoteTok.mintUnlimited(address(s), 1 ether);
        uint256 dev0 = _bal(address(quoteTok), dev);
        s.addChunk(0);
        assertEq(_bal(address(quoteTok), dev) - dev0, 0.6 ether);
        _next(10 minutes);
        uint256 lp0 = _lp(t, s.DEAD());
        (bool ok, uint256 chunk, uint256 pOut) = s.previewAdd();
        assertTrue(ok);
        (uint256 q,, uint256 liq) = s.addChunk(pOut);
        assertGt(q, chunk / 2);
        assertGt(liq, 0);
        assertEq(_lp(t, s.DEAD()) - lp0, liq);
    }

    /// @dev Not excluded from the dividend vault, a chunk leaves the splitter no share and nothing pending.
    function test_add_noDividendWithoutExclusion() public {
        (GangLiquiditySplitter s, address t,) = _setup(address(wbnb), 10_000, true);
        assertFalse(divVault.excluded(address(s)));
        wbnb.mintUnlimited(address(s), 1 ether);
        s.addChunk(0);
        _next(10 minutes);
        (, uint256 tokensIn,) = s.addChunk(0);
        assertGt(tokensIn, 0);
        address seller = _newAgent();
        (uint256 rT,) = _reserves(t, s.pair());
        deal(t, seller, rT / 50);
        _poolSell(t, s.pair(), seller, rT / 50);
        assertEq(divVault.shares(t, address(s)), 0);
        assertEq(divVault.pending(t, address(s)), 0);
    }

    // ---------------------------------------------------------------- keeper hook
    function test_work_dueWhenItActs() public {
        (GangLiquiditySplitter s, address t,) = _setup(address(wbnb), 10_000, true);
        (bool due, uint256 minOut) = s.previewWork();
        assertFalse(due, "nothing to add");

        wbnb.mintUnlimited(address(s), 1 ether);
        (due, minOut) = s.previewWork();
        assertTrue(due, "first observation");
        assertEq(minOut, 0);
        s.work(minOut);
        assertEq(s.lpLeft(), 1 ether);
        (due,) = s.previewWork();
        assertFalse(due, "same block");

        _next(5 minutes);
        (due,) = s.previewWork();
        assertFalse(due, "window not passed");

        _next(5 minutes);
        (bool ready,, uint256 pOut) = s.previewAdd();
        assertTrue(ready);
        (due, minOut) = s.previewWork();
        assertTrue(due);
        assertEq(minOut, (pOut * 9_900) / 10_000);
        uint256 lp0 = _lp(t, s.DEAD());
        s.work(minOut);
        assertGt(_lp(t, s.DEAD()), lp0);
        (due,) = s.previewWork();
        assertFalse(due, "added this block");

        _next(10 minutes);
        (, uint256 rQ) = _reserves(t, s.pair());
        _poolBuy(t, address(wbnb), s.pair(), _newAgent(), (rQ * 5) / 100);
        (ready,,) = s.previewAdd();
        assertFalse(ready);
        (due, minOut) = s.previewWork();
        assertTrue(due, "rolls the observation");
        assertEq(minOut, 0);
        s.split(); // the last chunk's swap-back paid in
        uint256 left = s.lpLeft();
        s.work(0);
        assertEq(s.lpLeft(), left);
    }

    function test_work_notDueBelowMinimum() public {
        (GangLiquiditySplitter s, address t,) = _setup(address(wbnb), 10_000, true);
        (, uint256 rQ) = _reserves(t, _curvePair(t));
        uint256 floor = (rQ * s.WORK_MIN_BPS()) / 10_000;
        wbnb.mintUnlimited(address(s), floor - 1);
        (bool due,) = s.previewWork();
        assertFalse(due, "under the floor: no observation call either");
        s.addChunk(0);
        _next(10 minutes);
        (bool ready,,) = s.previewAdd();
        assertTrue(ready);
        (due,) = s.previewWork();
        assertFalse(due, "under the floor: no chunk either");
        wbnb.mintUnlimited(address(s), 2);
        (due,) = s.previewWork();
        assertTrue(due);
    }

    /// @dev Pool sells pay the tax, the keeper processes it, the recipient part arrives, is split, and goes into the
    ///      pool with its LP at 0xdead.
    function test_e2e_poolTaxPaysSplitter() public {
        (GangLiquiditySplitter s, address t, address dev) = _setup(address(wbnb), 6_000, true);
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
        uint256 got = s.unsplit();
        assertGt(got, 0, "recipient part arrived");

        s.addChunk(0);
        assertEq(s.lpLeft(), (got * 6_000) / 10_000);
        assertEq(_bal(address(wbnb), dev) - dev0, got - (got * 6_000) / 10_000);

        uint256 lp0 = _lp(t, s.DEAD());
        _next(10 minutes);
        (uint256 q, uint256 tokensIn, uint256 liq) = s.addChunk(0);
        assertGt(q, 0);
        assertGt(tokensIn, 0);
        assertEq(_lp(t, s.DEAD()) - lp0, liq);
    }

    // ---------------------------------------------------------------- deploy script
    function test_script_check() public {
        DeployGangLiquiditySplitterFactory script = new DeployGangLiquiditySplitterFactory();
        script.check(address(pad), address(admin), address(factory));
        assertEq(script.pendingBatch(address(admin), address(factory)).length, 0);

        GangHandlerAdmin rogue = new GangHandlerAdmin(makeAddr("notTheSafe"), address(handler));
        GangLiquiditySplitterFactory rogueFactory = new GangLiquiditySplitterFactory(address(pad), address(rogue));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGangLiquiditySplitterFactory.WiringCheck.selector, "admin.handlerOwner")
        );
        script.check(address(pad), address(rogue), address(rogueFactory));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGangLiquiditySplitterFactory.WiringCheck.selector, "factory.admin")
        );
        script.check(address(pad), address(admin), address(rogueFactory));
        vm.expectRevert(abi.encodeWithSelector(DeployGangLiquiditySplitterFactory.WiringCheck.selector, "factory.code"));
        script.check(address(pad), address(admin), makeAddr("eoa"));

        // the runtime code: the real factory passes; a look-alike answering every view the same does not (audit L-4)
        script.checkCode(address(factory));
        FakeLpImpl fakeImpl = new FakeLpImpl(address(pad), address(handler));
        FakeLpFactory fake = new FakeLpFactory(address(pad), address(admin), address(fakeImpl));
        fakeImpl.setFactory(address(fake));
        script.check(address(pad), address(admin), address(fake));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGangLiquiditySplitterFactory.WiringCheck.selector, "factory.runtimeCode")
        );
        script.checkCode(address(fake));

        // a new factory on the live admin: one Safe call, and it works as printed
        GangLiquiditySplitterFactory f2 = new GangLiquiditySplitterFactory(address(pad), address(admin));
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
        vm.expectRevert(
            abi.encodeWithSelector(DeployGangLiquiditySplitterFactory.WiringCheck.selector, "admin.handlerOwner")
        );
        script.check(address(pad), address(admin), address(factory));
    }
}
