// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {TwapMockPairFactory} from "../mocks/TwapMockPair.sol";
import {GangBuybackSplitter} from "../../src/gang/GangBuybackSplitter.sol";
import {GangBuybackSplitterFactory} from "../../src/gang/GangBuybackSplitterFactory.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {DeployGangBuybackSplitterFactory} from "../../script/DeployGangBuybackSplitterFactory.s.sol";

/// @notice GangBuybackSplitter (dev 税按比例回购销毁) on the whole merged deployment, over pairs that keep the V2 oracle:
///         GangHandlerAdmin (the handler's owner, lists what allowed factories clone), the factory, binding, the split,
///         ratio changes (raise now / cut after notice), the chunked buy-back with its TWAP check and the keeper's
///         previewWork / work, sweep, the deploy script, and the pool tax paying it end to end.
contract GangBuybackSplitterTest is GangFixture {
    address keeper = makeAddr("keeper");
    GangHandlerAdmin admin;
    GangBuybackSplitterFactory factory;

    uint16 constant TAX = 300;

    function _newPairFactory() internal override returns (address) {
        return address(new TwapMockPairFactory());
    }

    function setUp() public {
        _deployGang(keeper);
        admin = new GangHandlerAdmin(owner, address(handler));
        vm.startPrank(owner);
        handler.transferOwnership(address(admin));
        admin.exec(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        vm.stopPrank();
        factory = new GangBuybackSplitterFactory(address(pad), address(admin));
        vm.prank(owner);
        admin.setFactory(address(factory), true);
    }

    // ---------------------------------------------------------------- helpers
    /// @dev The dev's splitter, from the factory (listed by the admin).
    function _splitter(address dev, uint16 bps) internal returns (GangBuybackSplitter s) {
        vm.prank(dev);
        s = GangBuybackSplitter(factory.create(bps));
    }

    /// @dev The dev gets a splitter, creates a taxed V3 token paying it, buys on the curve, and anyone binds it.
    function _setup(address quote, uint16 bps, bool grad)
        internal
        returns (GangBuybackSplitter s, address t, address dev)
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
    function newFactory(address pad_, address admin_) external returns (GangBuybackSplitterFactory) {
        return new GangBuybackSplitterFactory(pad_, admin_);
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

    // ---------------------------------------------------------------- admin
    function test_admin_takeoverExecAndHandBack() public {
        assertEq(handler.owner(), address(admin));
        assertEq(admin.handler(), address(handler));

        // only the Safe (the admin's owner) calls the handler through it
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        admin.exec(abi.encodeWithSignature("list(address,string)", stranger, "x"));

        // the handler's own admin calls still work, its errors come back as they are
        address partner = makeAddr("partner");
        vm.startPrank(owner);
        admin.exec(abi.encodeWithSignature("list(address,string)", partner, "partner"));
        assertTrue(handler.isListed(partner));
        admin.exec(abi.encodeWithSignature("delist(address)", partner));
        assertFalse(handler.isListed(partner));
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        admin.exec(abi.encodeWithSignature("list(address,string)", address(0), "zero"));

        // and the Safe can take the handler back
        admin.exec(abi.encodeCall(Ownable.transferOwnership, (owner)));
        handler.acceptOwnership();
        vm.stopPrank();
        assertEq(handler.owner(), owner);
    }

    function test_admin_factories() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        admin.setFactory(address(factory), false);
        vm.prank(owner);
        vm.expectRevert(GangHandlerAdmin.ZeroAddress.selector);
        admin.setFactory(address(0), true);

        // only an allowed factory lists, a contract, once
        GangBuybackSplitter s = _splitter(_newAgent(), 5_000);
        vm.expectRevert(GangHandlerAdmin.NotFactory.selector);
        admin.listModule(address(s), "x");
        vm.startPrank(address(factory));
        vm.expectRevert(GangHandlerAdmin.NoCode.selector);
        admin.listModule(makeAddr("eoa"), "x");
        vm.expectRevert(GangHandlerAdmin.AlreadyListed.selector);
        admin.listModule(address(s), "x");
        vm.stopPrank();
        assertEq(admin.moduleOf(address(s)), address(factory));
        assertEq(admin.moduleCount(), 1);
        assertEq(admin.modules()[0], address(s));

        // a stopped factory can't list any more (its clones stay listed); allowed again, it is not listed twice
        vm.prank(owner);
        admin.setFactory(address(factory), false);
        address dev = _newAgent();
        vm.prank(dev);
        vm.expectRevert(GangHandlerAdmin.NotFactory.selector);
        factory.create(5_000);
        assertTrue(handler.isListed(address(s)));
        vm.prank(owner);
        admin.setFactory(address(factory), true);
        assertEq(admin.factories().length, 1);
        assertTrue(admin.isFactory(address(factory)));
    }

    // ---------------------------------------------------------------- factory
    function test_factory_create() public {
        GangHandlerAdmin elsewhere = new GangHandlerAdmin(owner, makeAddr("otherHandler"));
        vm.expectRevert(GangBuybackSplitterFactory.WrongHandler.selector);
        this.newFactory(address(pad), address(elsewhere));
        vm.expectRevert(GangBuybackSplitterFactory.ZeroAddress.selector);
        this.newFactory(address(pad), address(0));
        vm.expectRevert(GangHandlerAdmin.ZeroAddress.selector);
        this.newAdmin(owner, address(0));

        // only an Agent (only an Agent can create the token)
        vm.prank(makeAddr("notAgent"));
        vm.expectRevert(GangBuybackSplitterFactory.NotAgent.selector);
        factory.create(5_000);
        address dev = _newAgent();
        vm.prank(dev);
        vm.expectRevert(GangBuybackSplitter.BadBps.selector);
        factory.create(10_001);

        vm.prank(dev);
        address s = factory.create(10_000);
        GangBuybackSplitter sp = GangBuybackSplitter(s);
        assertEq(sp.dev(), dev);
        assertEq(sp.buybackBps(), 10_000);
        assertEq(sp.token(), address(0));
        assertEq(sp.pad(), address(pad));
        assertEq(sp.taxHandler(), address(handler));
        assertEq(sp.factory(), address(factory));
        assertEq(sp.moduleType(), bytes32("buyback-burn-v1"));
        assertTrue(handler.isListed(s));
        assertEq(admin.moduleOf(s), address(factory));
        assertEq(factory.lastOf(dev), s);
        assertEq(factory.count(), 1);
        assertEq(factory.splitters()[0], s);

        // the implementation is never initialized; a clone only once, only by the factory
        GangBuybackSplitter impl = GangBuybackSplitter(factory.implementation());
        vm.expectRevert(GangBuybackSplitter.NotClone.selector);
        impl.initialize(dev, 1);
        vm.expectRevert(GangBuybackSplitter.NotFactory.selector);
        sp.initialize(dev, 1);
        vm.prank(address(factory));
        vm.expectRevert(GangBuybackSplitter.AlreadyInitialized.selector);
        sp.initialize(dev, 1);
    }

    // ---------------------------------------------------------------- bind
    function test_bind_checks() public {
        address dev = _newAgent();
        GangBuybackSplitter s = _splitter(dev, 5_000);

        vm.expectRevert(GangBuybackSplitter.NotCurve.selector);
        s.bind(makeAddr("nope"));
        address fair = _createFair(dev, address(wbnb), 100);
        vm.expectRevert(GangBuybackSplitter.NotCurve.selector);
        s.bind(fair);

        // a listed recipient is open to every creator: another creator's token can't take the binding
        address other = _createV3(_newAgent(), address(wbnb), _tax(TAX, TAX, 5_000, address(s)));
        vm.expectRevert(GangBuybackSplitter.NotCreator.selector);
        s.bind(other);

        // the dev's token paying someone else
        address own = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, dev));
        vm.expectRevert(GangBuybackSplitter.NotRecipient.selector);
        s.bind(own);

        // anyone binds the right one, once
        address t = _createV3(dev, address(quoteTok), _tax(TAX, TAX, 5_000, address(s)));
        vm.expectEmit(address(s));
        emit GangBuybackSplitter.Bound(t, address(quoteTok));
        vm.prank(makeAddr("stranger"));
        s.bind(t);
        assertEq(s.token(), t);
        assertEq(s.quote(), address(quoteTok));
        vm.expectRevert(GangBuybackSplitter.AlreadyBound.selector);
        s.bind(t);
    }

    // ---------------------------------------------------------------- split
    function test_split_byRatio() public {
        (GangBuybackSplitter s,, address dev) = _setup(address(wbnb), 3_000, false);
        uint256 dev0 = _bal(address(wbnb), dev);
        wbnb.mintUnlimited(address(s), 10 ether);
        assertEq(s.unsplit(), 10 ether);

        vm.expectEmit(address(s));
        emit GangBuybackSplitter.Split(10 ether, 3 ether, 7 ether);
        vm.prank(makeAddr("anyone"));
        s.split();
        assertEq(_bal(address(wbnb), dev) - dev0, 7 ether);
        assertEq(s.buybackLeft(), 3 ether);
        assertEq(_bal(address(wbnb), address(s)), 3 ether);
        assertEq(s.unsplit(), 0);

        // nothing new: a no-op
        s.split();
        assertEq(s.buybackLeft(), 3 ether);
    }

    function test_split_edges() public {
        (GangBuybackSplitter all,, address devA) = _setup(address(wbnb), 10_000, false);
        wbnb.mintUnlimited(address(all), 1 ether);
        uint256 a0 = _bal(address(wbnb), devA);
        all.split();
        assertEq(all.buybackLeft(), 1 ether);
        assertEq(_bal(address(wbnb), devA), a0);

        (GangBuybackSplitter none,, address devB) = _setup(address(wbnb), 0, false);
        wbnb.mintUnlimited(address(none), 1 ether);
        uint256 b0 = _bal(address(wbnb), devB);
        none.split();
        assertEq(none.buybackLeft(), 0);
        assertEq(_bal(address(wbnb), devB) - b0, 1 ether);
    }

    // ---------------------------------------------------------------- ratio changes
    function test_raise_appliesNow_oldQuoteKeepsOldRatio() public {
        (GangBuybackSplitter s,, address dev) = _setup(address(wbnb), 2_000, false);
        uint256 dev0 = _bal(address(wbnb), dev);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(GangBuybackSplitter.NotDev.selector);
        s.setBuybackBps(5_000);
        vm.prank(dev);
        vm.expectRevert(GangBuybackSplitter.BadBps.selector);
        s.setBuybackBps(10_001);

        wbnb.mintUnlimited(address(s), 10 ether);
        vm.expectEmit(address(s));
        emit GangBuybackSplitter.BuybackBpsSet(2_000, 5_000);
        vm.prank(dev);
        s.setBuybackBps(5_000);
        assertEq(s.buybackBps(), 5_000);
        // the 10 that came before the raise went at 20%
        assertEq(s.buybackLeft(), 2 ether);
        assertEq(_bal(address(wbnb), dev) - dev0, 8 ether);

        wbnb.mintUnlimited(address(s), 10 ether);
        s.split();
        assertEq(s.buybackLeft(), 7 ether);
        assertEq(_bal(address(wbnb), dev) - dev0, 13 ether);
    }

    function test_lower_waitsForNotice() public {
        (GangBuybackSplitter s,, address dev) = _setup(address(wbnb), 5_000, false);
        uint256 dev0 = _bal(address(wbnb), dev);

        vm.expectRevert(GangBuybackSplitter.NoProposal.selector);
        s.applyBuybackBps();

        uint64 at = uint64(block.timestamp + 3 days);
        vm.expectEmit(address(s));
        emit GangBuybackSplitter.BuybackBpsProposed(1_000, at);
        vm.prank(dev);
        s.setBuybackBps(1_000);
        assertEq(s.buybackBps(), 5_000, "not yet");
        assertEq(s.pendingBps(), 1_000);
        assertEq(s.pendingAt(), at);

        // during the notice the old share holds
        wbnb.mintUnlimited(address(s), 10 ether);
        s.split();
        assertEq(s.buybackLeft(), 5 ether);

        vm.warp(at - 1);
        vm.expectRevert(GangBuybackSplitter.NotDue.selector);
        s.applyBuybackBps();

        // quote that arrived before the cut is split at the old share first
        vm.warp(at);
        wbnb.mintUnlimited(address(s), 10 ether);
        vm.prank(makeAddr("anyone"));
        s.applyBuybackBps();
        assertEq(s.buybackBps(), 1_000);
        assertEq(s.pendingAt(), 0);
        assertEq(s.buybackLeft(), 10 ether);
        assertEq(_bal(address(wbnb), dev) - dev0, 10 ether);

        wbnb.mintUnlimited(address(s), 10 ether);
        s.split();
        assertEq(s.buybackLeft(), 11 ether);
        assertEq(_bal(address(wbnb), dev) - dev0, 19 ether);

        vm.expectRevert(GangBuybackSplitter.NoProposal.selector);
        s.applyBuybackBps();
    }

    function test_lower_lapsesAfterTtl() public {
        (GangBuybackSplitter s,, address dev) = _setup(address(wbnb), 5_000, false);
        vm.prank(dev);
        s.setBuybackBps(0);
        uint64 at = s.pendingAt();

        // the last moment still applies; one second later the cut has lapsed
        uint256 snap = vm.snapshotState();
        vm.warp(at + s.CUT_TTL());
        s.applyBuybackBps();
        assertEq(s.buybackBps(), 0);
        vm.revertToState(snap);

        (bool live, uint16 bps, uint64 when) = s.pendingCut();
        assertTrue(live);
        assertEq(bps, 0);
        assertEq(when, at);

        vm.warp(at + s.CUT_TTL() + 1);
        vm.expectRevert(GangBuybackSplitter.CutLapsed.selector);
        s.applyBuybackBps();
        assertEq(s.buybackBps(), 5_000);
        (live, bps, when) = s.pendingCut();
        assertFalse(live);
        assertEq(when, 0);

        // a raise clears the lapsed request without a cancel event (it was already dead)
        uint256 snap2 = vm.snapshotState();
        vm.recordLogs();
        vm.prank(dev);
        s.setBuybackBps(5_000);
        assertEq(vm.getRecordedLogs().length, 1, "only BuybackBpsSet");
        assertEq(s.pendingAt(), 0);
        vm.revertToState(snap2);

        // a new request starts a new notice
        vm.prank(dev);
        s.setBuybackBps(0);
        vm.warp(block.timestamp + 3 days);
        s.applyBuybackBps();
        assertEq(s.buybackBps(), 0);
    }

    function test_lower_cancelledByCurrentOrHigher() public {
        (GangBuybackSplitter s,, address dev) = _setup(address(wbnb), 5_000, false);
        vm.startPrank(dev);
        s.setBuybackBps(0);
        // asking again replaces the cut and restarts the notice
        _next(2 days);
        s.setBuybackBps(2_000);
        assertEq(s.pendingBps(), 2_000);
        assertEq(s.pendingAt(), block.timestamp + 3 days);

        vm.expectEmit(address(s));
        emit GangBuybackSplitter.BuybackBpsProposalCancelled(2_000);
        s.setBuybackBps(5_000);
        vm.stopPrank();
        assertEq(s.pendingAt(), 0);
        assertEq(s.buybackBps(), 5_000);
        _next(3 days);
        vm.expectRevert(GangBuybackSplitter.NoProposal.selector);
        s.applyBuybackBps();
    }

    // ---------------------------------------------------------------- burnChunk
    function test_burn_refusedBeforeGraduationOrEmpty() public {
        (GangBuybackSplitter s,,) = _setup(address(wbnb), 5_000, false);
        vm.expectRevert(GangBuybackSplitter.NothingToBurn.selector);
        s.burnChunk(0);

        wbnb.mintUnlimited(address(s), 1 ether);
        (bool ready,,) = s.previewBurn();
        assertFalse(ready);
        (bool due,) = s.previewWork();
        assertFalse(due);
        vm.expectRevert(GangBuybackSplitter.NotTradable.selector);
        s.burnChunk(0);
    }

    function test_burn_chunksUntilDone() public {
        (GangBuybackSplitter s, address t, address dev) = _setup(address(wbnb), 5_000, true);
        wbnb.mintUnlimited(address(s), 1 ether);
        uint256 dev0 = _bal(address(wbnb), dev);

        // first call splits and records the observation only
        (uint256 q0, uint256 b0) = s.burnChunk(0);
        assertEq(q0 + b0, 0);
        assertEq(s.buybackLeft(), 0.5 ether);
        assertEq(_bal(address(wbnb), dev) - dev0, 0.5 ether);
        address pair = s.pair();
        assertEq(pair, _curvePair(t));
        _next(5 minutes);
        (q0, b0) = s.burnChunk(0);
        assertEq(q0 + b0, 0, "window not passed");

        uint256 deadBefore = _bal(t, s.DEAD());
        uint256 burnedTotal;
        uint256 spent;
        uint256 chunks;
        while (s.buybackLeft() > 0) {
            _next(10 minutes);
            (uint256 rT, uint256 rQ) = _reserves(t, pair);
            (bool ok, uint256 pq, uint256 pOut) = s.previewBurn();
            assertTrue(ok);
            assertLe(pq, (rQ * 50) / 10_000, "chunk cap");
            uint256 out = (pq * 9975 * rT) / (rQ * 10_000 + pq * 9975);
            assertEq(pOut, out - (out * TAX) / 10_000, "buy tax");
            (uint256 q, uint256 burned) = s.burnChunk(pOut);
            assertEq(q, pq);
            assertEq(burned, pOut);
            burnedTotal += burned;
            spent += q;
            chunks++;
            if (s.buybackLeft() > 0) {
                vm.expectRevert(GangBuybackSplitter.BurnedThisBlock.selector);
                s.burnChunk(0);
            }
        }
        assertGt(chunks, 1);
        assertEq(spent, 0.5 ether);
        assertEq(_bal(t, s.DEAD()) - deadBefore, burnedTotal);
        assertEq(_bal(t, address(s)), 0);
        assertEq(_bal(address(wbnb), address(s)), 0);
        vm.expectRevert(GangBuybackSplitter.NothingToBurn.selector);
        s.burnChunk(0);
    }

    function test_burn_skipsAfterPump() public {
        (GangBuybackSplitter s, address t,) = _setup(address(wbnb), 10_000, true);
        wbnb.mintUnlimited(address(s), 1 ether);
        s.burnChunk(0);
        address pair = s.pair();
        _next(10 minutes);

        // someone lifts the price ~5% in this block, hoping to sell into the buy-back
        (, uint256 rQ) = _reserves(t, pair);
        _poolBuy(t, address(wbnb), pair, _newAgent(), (rQ * 5) / 100);
        uint256 left = s.buybackLeft();
        (bool ready,,) = s.previewBurn();
        assertFalse(ready);
        (uint256 q, uint256 burned) = s.burnChunk(0);
        assertEq(q + burned, 0);
        assertEq(s.buybackLeft(), left);

        // held while the keeper keeps calling, the high price becomes the average, and buying resumes
        for (uint256 i; i < 6 && q == 0; i++) {
            _next(10 minutes);
            (q,) = s.burnChunk(0);
        }
        assertGt(q, 0);
    }

    function test_burn_slippage() public {
        (GangBuybackSplitter s,,) = _setup(address(wbnb), 10_000, true);
        wbnb.mintUnlimited(address(s), 1 ether);
        s.burnChunk(0);
        _next(10 minutes);
        (bool ok,, uint256 pOut) = s.previewBurn();
        assertTrue(ok);
        vm.expectRevert(GangBuybackSplitter.Slippage.selector);
        s.burnChunk(pOut + 1);
        (, uint256 burned) = s.burnChunk(pOut);
        assertEq(burned, pOut);
    }

    function test_burn_erc20Quote() public {
        (GangBuybackSplitter s, address t, address dev) = _setup(address(quoteTok), 4_000, true);
        quoteTok.mintUnlimited(address(s), 1 ether);
        uint256 dev0 = _bal(address(quoteTok), dev);
        s.burnChunk(0);
        assertEq(_bal(address(quoteTok), dev) - dev0, 0.6 ether);
        _next(10 minutes);
        uint256 dead0 = _bal(t, s.DEAD());
        (bool ok, uint256 pq, uint256 pOut) = s.previewBurn();
        assertTrue(ok);
        (uint256 q, uint256 burned) = s.burnChunk(pOut);
        assertEq(q, pq);
        assertEq(_bal(t, s.DEAD()) - dead0, burned);
        assertGt(burned, 0);
    }

    /// @dev Not excluded from the dividend vault (the factory flow needs no vault call), a chunk leaves the splitter no
    ///      share and nothing pending: it holds the tokens only between the buy and the transfer to 0xdead.
    function test_burn_noDividendWithoutExclusion() public {
        (GangBuybackSplitter s, address t,) = _setup(address(wbnb), 10_000, true);
        assertFalse(divVault.excluded(address(s)));
        wbnb.mintUnlimited(address(s), 1 ether);
        s.burnChunk(0);
        _next(10 minutes);
        (, uint256 burned) = s.burnChunk(0);
        assertGt(burned, 0);
        // more tax afterwards: still nothing for it
        address seller = _newAgent();
        (uint256 rT,) = _reserves(t, s.pair());
        deal(t, seller, rT / 50);
        _poolSell(t, s.pair(), seller, rT / 50);
        assertEq(divVault.shares(t, address(s)), 0);
        assertEq(divVault.pending(t, address(s)), 0);
    }

    // ---------------------------------------------------------------- keeper hook
    /// @dev previewWork is due exactly when work does something: an observation, then (a window on) a chunk.
    function test_work_dueWhenItActs() public {
        (GangBuybackSplitter s, address t,) = _setup(address(wbnb), 10_000, true);
        (bool due, uint256 minOut) = s.previewWork();
        assertFalse(due, "nothing to buy back");

        wbnb.mintUnlimited(address(s), 1 ether);
        (due, minOut) = s.previewWork();
        assertTrue(due, "first observation");
        assertEq(minOut, 0);
        s.work(minOut);
        assertEq(s.buybackLeft(), 1 ether);
        (due,) = s.previewWork();
        assertFalse(due, "same block");

        // inside the window a call changes nothing: not due
        _next(5 minutes);
        (due,) = s.previewWork();
        assertFalse(due, "window not passed");

        _next(5 minutes);
        (bool ready,, uint256 pOut) = s.previewBurn();
        assertTrue(ready);
        (due, minOut) = s.previewWork();
        assertTrue(due);
        assertEq(minOut, (pOut * 9_900) / 10_000);
        uint256 dead0 = _bal(t, s.DEAD());
        s.work(minOut);
        assertEq(_bal(t, s.DEAD()) - dead0, pOut);
        (due,) = s.previewWork();
        assertFalse(due, "burned this block");

        // after a pump: not ready, but due when the call rolls the observation (it is what gets it ready again)
        _next(10 minutes);
        (, uint256 rQ) = _reserves(t, s.pair());
        _poolBuy(t, address(wbnb), s.pair(), _newAgent(), (rQ * 5) / 100);
        (ready,,) = s.previewBurn();
        assertFalse(ready);
        (due, minOut) = s.previewWork();
        assertTrue(due, "rolls the observation");
        assertEq(minOut, 0);
        uint256 left = s.buybackLeft();
        s.work(0);
        assertEq(s.buybackLeft(), left);
        _next(1 minutes);
        (due,) = s.previewWork();
        assertFalse(due, "rolled a minute ago");
    }

    /// @dev Review: a quote that blacklists the dev must not freeze the buy-back (every path splits first).
    function test_devBlacklisted_owedNotBlocking() public {
        (GangBuybackSplitter s, address t, address dev) = _setup(address(blq), 5_000, true);
        blq.setBlocked(dev, true);
        blq.mint(address(s), 1 ether);

        vm.expectEmit(address(s));
        emit GangBuybackSplitter.DevOwed(0.5 ether);
        s.burnChunk(0); // splits (the dev's push fails, owed), records the observation
        assertEq(s.devOwed(), 0.5 ether);
        assertEq(s.buybackLeft(), 0.5 ether);
        assertEq(s.unsplit(), 0);

        // owed quote is never spent on the buy-back, and the buy-back runs
        _next(10 minutes);
        uint256 dead0 = _bal(t, s.DEAD());
        (uint256 q, uint256 burned) = s.burnChunk(0);
        assertGt(q, 0);
        assertEq(_bal(t, s.DEAD()) - dead0, burned);
        assertEq(s.devOwed(), 0.5 ether);
        assertEq(_bal(address(blq), address(s)), s.buybackLeft() + 0.5 ether);

        // ratio changes still work
        vm.prank(dev);
        s.setBuybackBps(6_000);

        vm.expectRevert("blacklisted");
        s.releaseDev();
        blq.setBlocked(dev, false);
        uint256 dev0 = _bal(address(blq), dev);
        vm.expectEmit(address(s));
        emit GangBuybackSplitter.DevReleased(0.5 ether);
        vm.prank(makeAddr("anyone"));
        assertEq(s.releaseDev(), 0.5 ether);
        assertEq(_bal(address(blq), dev) - dev0, 0.5 ether);
        assertEq(s.devOwed(), 0);
        vm.expectRevert(GangBuybackSplitter.NothingOwed.selector);
        s.releaseDev();
    }

    /// @dev Review: a quote balance that shrinks below what is held must not lock the splitter (unsplit underflow).
    function test_shortfall_sharedInProportion() public {
        (GangBuybackSplitter s,, address dev) = _setup(address(blq), 5_000, true);
        blq.setBlocked(dev, true);
        blq.mint(address(s), 4 ether);
        s.split(); // 2 to the buy-back, 2 owed
        assertEq(s.buybackLeft(), 2 ether);
        assertEq(s.devOwed(), 2 ether);

        // the quote takes half of the splitter's balance
        deal(address(blq), address(s), 2 ether);
        assertEq(s.unsplit(), 0);
        vm.expectEmit(address(s));
        emit GangBuybackSplitter.Shortfall(2 ether);
        s.split();
        assertEq(s.buybackLeft(), 1 ether);
        assertEq(s.devOwed(), 1 ether);

        // and keeps working: new quote splits, the buy-back runs, the owed part is released
        blq.mint(address(s), 2 ether);
        s.burnChunk(0);
        assertEq(s.buybackLeft(), 2 ether);
        assertEq(s.devOwed(), 2 ether);
        _next(10 minutes);
        (uint256 q,) = s.burnChunk(0);
        assertGt(q, 0);
        blq.setBlocked(dev, false);
        assertEq(s.releaseDev(), 2 ether);
    }

    /// @dev Review: with a shortfall nobody split yet, `releaseDev` shares it first — the dev can't take the whole owed
    ///      part and leave the loss to the buy-back; `previewBurn` sees the shared amount too.
    function test_shortfall_releaseDevSharesFirst() public {
        (GangBuybackSplitter s, address t, address dev) = _setup(address(blq), 5_000, true);
        blq.setBlocked(dev, true);
        blq.mint(address(s), 4 ether);
        s.burnChunk(0); // 2 to the buy-back, 2 owed; records the observation
        _next(10 minutes);

        deal(address(blq), address(s), 2.5 ether); // 1.5 taken
        (, uint256 pq,) = s.previewBurn();
        (, uint256 rQ) = _reserves(t, s.pair());
        uint256 shared = 2.5 ether - (2 ether * 2.5 ether) / 4 ether; // the buy-back's 1.25
        assertEq(pq, shared < (rQ * 50) / 10_000 ? shared : (rQ * 50) / 10_000, "preview after the shortfall");

        blq.setBlocked(dev, false);
        uint256 dev0 = _bal(address(blq), dev);
        assertEq(s.releaseDev(), 1.25 ether);
        assertEq(_bal(address(blq), dev) - dev0, 1.25 ether);
        assertEq(s.buybackLeft(), 1.25 ether);
        assertEq(_bal(address(blq), address(s)), 1.25 ether);

        // all of it taken: the owed part is gone too, nothing to release
        blq.setBlocked(dev, true);
        blq.mint(address(s), 2 ether); // 1 more each
        s.split();
        assertEq(s.devOwed(), 1 ether);
        deal(address(blq), address(s), 0);
        blq.setBlocked(dev, false);
        vm.expectRevert(GangBuybackSplitter.NothingOwed.selector);
        s.releaseDev();
    }

    // ---------------------------------------------------------------- deploy script
    /// @dev The script's check and Safe batch, from a handler the Safe still owns to a factory that lists.
    function test_script_checkAndBatch() public {
        DeployGangBuybackSplitterFactory script = new DeployGangBuybackSplitterFactory();
        // the fixture's admin owns the handler and allows its factory: nothing to do
        script.check(address(pad), address(admin), address(factory));
        assertEq(script.pendingBatch(address(admin), address(factory)).length, 0);

        // a second admin while the first owns the handler is refused
        GangHandlerAdmin other = new GangHandlerAdmin(owner, address(handler));
        GangBuybackSplitterFactory otherFactory = new GangBuybackSplitterFactory(address(pad), address(other));
        vm.expectRevert(abi.encodeWithSelector(DeployGangBuybackSplitterFactory.WiringCheck.selector, "admin.owner"));
        script.check(address(pad), address(other), address(otherFactory));
        vm.expectRevert(abi.encodeWithSelector(DeployGangBuybackSplitterFactory.WiringCheck.selector, "factory.admin"));
        script.check(address(pad), address(admin), address(otherFactory));
        vm.expectRevert(abi.encodeWithSelector(DeployGangBuybackSplitterFactory.WiringCheck.selector, "factory.code"));
        script.check(address(pad), address(admin), makeAddr("eoa"));

        // the Safe holds the handler again (as before the takeover): the batch is takeover + allow, and works as printed
        vm.startPrank(owner);
        admin.exec(abi.encodeCall(Ownable.transferOwnership, (owner)));
        handler.acceptOwnership();
        vm.stopPrank();
        script.check(address(pad), address(other), address(otherFactory));
        bytes[] memory batch = script.pendingBatch(address(other), address(otherFactory));
        assertEq(batch.length, 3);
        for (uint256 i; i < batch.length; i++) {
            (address to, bytes memory data) = _split(batch[i]);
            vm.prank(owner);
            (bool ok,) = to.call(data);
            assertTrue(ok);
        }
        assertEq(handler.owner(), address(other));
        assertEq(script.pendingBatch(address(other), address(otherFactory)).length, 0);
        script.check(address(pad), address(other), address(otherFactory));

        // and the new factory's clones are listed
        address dev = _newAgent();
        vm.prank(dev);
        assertTrue(handler.isListed(otherFactory.create(5_000)));
    }

    function _split(bytes memory c) internal pure returns (address to, bytes memory data) {
        assembly ("memory-safe") {
            to := shr(96, mload(add(c, 32)))
        }
        data = new bytes(c.length - 20);
        for (uint256 j; j < data.length; j++) {
            data[j] = c[j + 20];
        }
    }

    // ---------------------------------------------------------------- sweep
    function test_sweep() public {
        address dev = _newAgent();
        GangBuybackSplitter s = _splitter(dev, 5_000);
        wbnb.mintUnlimited(address(s), 1 ether);
        // unbound: nothing leaves (a dev can't skip the binding and take the tax)
        vm.expectRevert(GangBuybackSplitter.NotBound.selector);
        s.sweep(address(wbnb));

        address t = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(s)));
        s.bind(t);
        vm.expectRevert(GangBuybackSplitter.NotSweepable.selector);
        s.sweep(address(wbnb));

        // another token's tax in another quote goes to the dev whole
        quoteTok.mintUnlimited(address(s), 2 ether);
        uint256 dev0 = _bal(address(quoteTok), dev);
        vm.prank(makeAddr("anyone"));
        s.sweep(address(quoteTok));
        assertEq(_bal(address(quoteTok), dev) - dev0, 2 ether);

        // what arrived before the binding is split like the rest
        s.split();
        assertEq(s.buybackLeft(), 0.5 ether);
    }

    // ---------------------------------------------------------------- end to end
    /// @dev Pool sells pay the tax; the handler's chunks pay the splitter its recipient part; it buys back and burns.
    function test_e2e_poolTaxPaysSplitter() public {
        (GangBuybackSplitter s, address t, address dev) = _setup(address(wbnb), 6_000, true);
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

        s.burnChunk(0); // splits, records the observation
        assertEq(s.buybackLeft(), (got * 6_000) / 10_000);
        assertEq(_bal(address(wbnb), dev) - dev0, got - (got * 6_000) / 10_000);

        uint256 dead0 = _bal(t, s.DEAD());
        _next(10 minutes);
        (uint256 q, uint256 burned) = s.burnChunk(0);
        assertGt(q, 0);
        assertGt(burned, 0);
        assertEq(_bal(t, s.DEAD()) - dead0, burned);
    }
}
