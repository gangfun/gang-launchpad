// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
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
    uint256 _salt;

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
        s = GangBuybackSplitter(factory.create(bps, bytes32(++_salt), address(0)));
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

        // modules() a page at a time
        GangBuybackSplitter s2 = _splitter(_newAgent(), 5_000);
        GangBuybackSplitter s3 = _splitter(_newAgent(), 5_000);
        address[] memory page = admin.modulesFrom(1, 5);
        assertEq(page.length, 2);
        assertEq(page[0], address(s2));
        assertEq(page[1], address(s3));
        assertEq(admin.modulesFrom(0, 1).length, 1);
        assertEq(admin.modulesFrom(3, 1).length, 0);
        assertEq(admin.modulesFrom(9, 1).length, 0);

        // a stopped factory can't list any more (its clones stay listed); allowed again, it is not listed twice
        vm.prank(owner);
        admin.setFactory(address(factory), false);
        address dev = _newAgent();
        vm.prank(dev);
        vm.expectRevert(GangHandlerAdmin.NotFactory.selector);
        factory.create(5_000, bytes32(0), address(0));
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
        factory.create(5_000, bytes32(0), address(0));
        address dev = _newAgent();
        vm.prank(dev);
        vm.expectRevert(GangBuybackSplitter.BadBps.selector);
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
        GangBuybackSplitter sp = GangBuybackSplitter(s);
        assertEq(sp.dev(), dev);
        assertEq(sp.buybackBps(), 10_000);
        assertEq(sp.token(), address(0));
        assertEq(sp.pad(), address(pad));
        assertEq(sp.taxHandler(), address(handler));
        assertEq(sp.factory(), address(factory));
        assertEq(sp.moduleType(), bytes32("buyback-burn-v3"));
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
        vm.expectRevert(GangBuybackSplitter.BadPayee.selector);
        factory.create(5_000, selfSalt, selfAt);

        GangBuybackSplitter impl = GangBuybackSplitter(factory.implementation());
        vm.expectRevert(GangBuybackSplitter.NotClone.selector);
        impl.initialize(dev, 1, address(0));
        vm.expectRevert(GangBuybackSplitter.NotFactory.selector);
        sp.initialize(dev, 1, address(0));
        vm.prank(address(factory));
        vm.expectRevert(GangBuybackSplitter.AlreadyInitialized.selector);
        sp.initialize(dev, 1, address(0));
    }

    // ---------------------------------------------------------------- payee
    /// @dev The dev's part goes to the payee: named at create, changed by the dev at once; quote that arrived before a
    ///      change goes to the old payee, what is owed and swept to the payee of that moment.
    function test_payee_atCreateAndChanged() public {
        address dev = _newAgent();
        address treasury = makeAddr("treasury");
        vm.prank(dev);
        GangBuybackSplitter s = GangBuybackSplitter(factory.create(3_000, bytes32(++_salt), treasury));
        assertEq(s.payee(), treasury);
        address t = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(s)));
        s.bind(t);

        uint256 dev0 = _bal(address(wbnb), dev);
        wbnb.mintUnlimited(address(s), 10 ether);
        s.split();
        assertEq(_bal(address(wbnb), treasury), 7 ether, "the dev part to the payee");
        assertEq(_bal(address(wbnb), dev), dev0, "nothing to the dev");
        assertEq(s.buybackLeft(), 3 ether);

        // only the dev changes it, never to 0
        vm.prank(treasury);
        vm.expectRevert(GangBuybackSplitter.NotDev.selector);
        s.setPayee(treasury);
        vm.prank(dev);
        vm.expectRevert(GangBuybackSplitter.ZeroAddress.selector);
        s.setPayee(address(0));
        vm.prank(dev);
        vm.expectRevert(GangBuybackSplitter.BadPayee.selector);
        s.setPayee(address(s));

        // what arrived before the change is split to the old payee first
        address next = makeAddr("next");
        wbnb.mintUnlimited(address(s), 10 ether);
        vm.expectEmit(address(s));
        emit GangBuybackSplitter.PayeeSet(treasury, next);
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

    /// @dev A payee the quote blacklists is owed, the buy-back is not held up; the owed part goes to the payee the dev
    ///      names next.
    function test_payee_owedGoesToTheCurrentPayee() public {
        address dev = _newAgent();
        address blocked = makeAddr("blocked");
        vm.prank(dev);
        GangBuybackSplitter s = GangBuybackSplitter(factory.create(5_000, bytes32(++_salt), blocked));
        address t = _createV3(dev, address(blq), _tax(TAX, TAX, 5_000, address(s)));
        s.bind(t);
        blq.setBlocked(blocked, true);
        blq.mint(address(s), 4 ether);
        vm.expectEmit(address(s));
        emit GangBuybackSplitter.DevOwed(2 ether);
        s.split();
        assertEq(s.devOwed(), 2 ether);
        assertEq(s.buybackLeft(), 2 ether);
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
                vm.expectRevert(GangBuybackSplitter.BurnTooSoon.selector);
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

    /// @dev GangBond audit 2026-10-29 H-1: once a pumped price is the average, a chunk per block let a seller empty the
    ///      buy-back in seconds; one chunk per CHUNK_GAP makes the pump last as long as the whole buy-back.
    function test_burn_oneChunkPerGap() public {
        (GangBuybackSplitter s,,) = _setup(address(wbnb), 10_000, true);
        wbnb.mintUnlimited(address(s), 1 ether);
        s.burnChunk(0);
        _next(10 minutes);
        (uint256 q,) = s.burnChunk(0);
        assertGt(q, 0);
        assertEq(s.lastBurnAt(), block.timestamp);
        uint256 last = s.lastBurnAt();
        uint64 gap = s.CHUNK_GAP();
        // explicit times: block.timestamp read back in a loop of warps can be stale here
        for (uint256 i = 1; i < gap; i += 12) {
            vm.warp(last + i); // later blocks inside the gap, up to its last second
            vm.roll(block.number + 1);
            (bool ready,,) = s.previewBurn();
            assertFalse(ready);
            (bool due,) = s.previewWork();
            assertFalse(due);
            vm.expectRevert(GangBuybackSplitter.BurnTooSoon.selector);
            s.burnChunk(0);
            vm.expectRevert(GangBuybackSplitter.BurnTooSoon.selector);
            s.work(0);
        }
        vm.warp(last + gap);
        vm.roll(block.number + 1);
        (bool ok,,) = s.previewBurn();
        assertTrue(ok);
        (bool due2,) = s.previewWork();
        assertTrue(due2);
        (q,) = s.burnChunk(0);
        assertGt(q, 0);
    }

    /// @dev H-1 replayed: pump, hold until the average catches up, then sell into the buy-back every block. With the
    ///      gap the buy-back spends one chunk in the next minute, not one per block (with no gap: 11).
    function test_burn_pumpAndHoldGetsOneChunkPerGap() public {
        (GangBuybackSplitter s, address t,) = _setup(address(wbnb), 10_000, true);
        address pair = _curvePair(t);
        (, uint256 rQ) = _reserves(t, pair);
        wbnb.mintUnlimited(address(s), rQ / 5); // a backlog of 20% of the pool's quote
        address attacker = _newAgent();
        _poolBuy(t, address(wbnb), pair, attacker, (rQ * 414) / 1000); // ~1.7x the price (the mock buy takes half out)
        s.burnChunk(0); // a fresh observation at the pumped price
        _next(10 minutes);
        uint256 start = vm.getBlockTimestamp(); // block.timestamp can read stale after warps here
        uint256 left0 = s.buybackLeft();
        uint256 chunks;
        for (uint256 i; i < 133; i++) {
            // a minute of 0.45 s blocks, everyone trying
            vm.warp(start + (i * 45) / 100);
            vm.roll(block.number + 1);
            try s.burnChunk(0) returns (uint256 q, uint256 burned) {
                if (q != 0) {
                    chunks++;
                    _poolSell(t, pair, attacker, burned); // sells the same back: the price stays up
                }
            } catch (bytes memory err) {
                assertEq(bytes4(err), GangBuybackSplitter.BurnTooSoon.selector);
            }
        }
        assertEq(chunks, 1);
        assertLe(left0 - s.buybackLeft(), (rQ * 2 * 50) / 10_000, "one chunk of the pumped reserve");
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

    /// @dev Review: a trickle under WORK_MIN_BPS of the pair's quote reserve is not worth a keeper tx — not due, neither
    ///      to buy nor to observe — until more tax arrives; burnChunk still takes it by hand.
    function test_work_notDueBelowMinimum() public {
        (GangBuybackSplitter s, address t,) = _setup(address(wbnb), 10_000, true);
        (, uint256 rQ) = _reserves(t, _curvePair(t));
        uint256 floor = (rQ * s.WORK_MIN_BPS()) / 10_000;
        wbnb.mintUnlimited(address(s), floor - 1);
        (bool due,) = s.previewWork();
        assertFalse(due, "under the floor: no observation call either");
        s.burnChunk(0); // by hand: records the observation
        _next(10 minutes);
        (bool ready,,) = s.previewBurn();
        assertTrue(ready);
        (due,) = s.previewWork();
        assertFalse(due, "under the floor: no chunk either");

        // enough tax arrives: due again
        wbnb.mintUnlimited(address(s), 2);
        (due,) = s.previewWork();
        assertTrue(due);
        (uint256 q,) = s.burnChunk(0);
        assertEq(q, floor + 1);
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
    /// @dev The script's check and Safe batch: refusals, moving the handler from an older admin, and the first takeover
    ///      from the Safe; each printed batch works as printed.
    function test_script_checkAndBatch() public {
        DeployGangBuybackSplitterFactory script = new DeployGangBuybackSplitterFactory();
        // the fixture's admin owns the handler and allows its factory: nothing to do
        script.check(address(pad), address(admin), address(factory));
        assertEq(script.pendingBatch(address(admin), address(factory)).length, 0);

        // an admin someone else owns is refused; a factory over another admin, or no factory, too
        GangHandlerAdmin rogue = new GangHandlerAdmin(makeAddr("notTheSafe"), address(handler));
        GangBuybackSplitterFactory rogueFactory = new GangBuybackSplitterFactory(address(pad), address(rogue));
        vm.expectRevert(abi.encodeWithSelector(DeployGangBuybackSplitterFactory.WiringCheck.selector, "admin.owner"));
        script.check(address(pad), address(rogue), address(rogueFactory));
        vm.expectRevert(abi.encodeWithSelector(DeployGangBuybackSplitterFactory.WiringCheck.selector, "factory.admin"));
        script.check(address(pad), address(admin), address(rogueFactory));
        vm.expectRevert(abi.encodeWithSelector(DeployGangBuybackSplitterFactory.WiringCheck.selector, "factory.code"));
        script.check(address(pad), address(admin), makeAddr("eoa"));

        // a new admin version while the old one holds the handler: the old admin hands it over, as printed
        assertEq(script.ownerBehind(address(handler)), owner);
        GangHandlerAdmin admin2 = new GangHandlerAdmin(owner, address(handler));
        GangBuybackSplitterFactory factory2 = new GangBuybackSplitterFactory(address(pad), address(admin2));
        script.check(address(pad), address(admin2), address(factory2));
        bytes[] memory batch = script.pendingBatch(address(admin2), address(factory2));
        assertEq(batch.length, 3);
        (address first,) = _split(batch[0]);
        assertEq(first, address(admin), "the old admin hands over");
        _runAsSafe(batch);
        assertEq(handler.owner(), address(admin2));
        assertEq(script.pendingBatch(address(admin2), address(factory2)).length, 0);
        // a later factory on the same admin: only setFactory, and the earlier one is listed as still allowed
        GangBuybackSplitterFactory factory2b = new GangBuybackSplitterFactory(address(pad), address(admin2));
        assertEq(script.pendingBatch(address(admin2), address(factory2b)).length, 1);
        address[] memory others = script.otherFactories(address(admin2), address(factory2b));
        assertEq(others.length, 1);
        assertEq(others[0], address(factory2));
        // allowed too, then the earlier one stopped: none left besides it
        vm.startPrank(owner);
        admin2.setFactory(address(factory2b), true);
        admin2.setFactory(address(factory2), false);
        vm.stopPrank();
        assertEq(script.otherFactories(address(admin2), address(factory2b)).length, 0);
        vm.prank(owner);
        admin2.setFactory(address(factory2), true);
        script.check(address(pad), address(admin2), address(factory2));
        // the old admin's factory can't list any more; the new one's can
        address dev = _newAgent();
        vm.prank(dev);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(admin)));
        factory.create(5_000, bytes32(0), address(0));
        vm.prank(dev);
        assertTrue(handler.isListed(factory2.create(5_000, bytes32(0), address(0))));

        // from a handler the Safe holds itself (the first takeover): handler.transferOwnership first
        vm.startPrank(owner);
        admin2.exec(abi.encodeCall(Ownable.transferOwnership, (owner)));
        handler.acceptOwnership();
        vm.stopPrank();
        GangHandlerAdmin admin3 = new GangHandlerAdmin(owner, address(handler));
        GangBuybackSplitterFactory factory3 = new GangBuybackSplitterFactory(address(pad), address(admin3));
        script.check(address(pad), address(admin3), address(factory3));
        batch = script.pendingBatch(address(admin3), address(factory3));
        assertEq(batch.length, 3);
        (first,) = _split(batch[0]);
        assertEq(first, address(handler));
        _runAsSafe(batch);
        assertEq(handler.owner(), address(admin3));
        assertEq(script.pendingBatch(address(admin3), address(factory3)).length, 0);
    }

    function _runAsSafe(bytes[] memory batch) internal {
        for (uint256 i; i < batch.length; i++) {
            (address to, bytes memory data) = _split(batch[i]);
            vm.prank(owner);
            (bool ok,) = to.call(data);
            assertTrue(ok);
        }
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
