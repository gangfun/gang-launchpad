// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {TwapMockPairFactory} from "../mocks/TwapMockPair.sol";
import {GangBuybackSplitter} from "../../src/gang/GangBuybackSplitter.sol";
import {DeployGangBuybackSplitter} from "../../script/DeployGangBuybackSplitter.s.sol";

/// @dev A pad look-alike: answers `taxHandler()` like the real one, but its `curves()` would be whatever its author wants.
contract FakePad {
    address public taxHandler;

    constructor(address handler_) {
        taxHandler = handler_;
    }
}

/// @dev Not a GangBuybackSplitter, but answers its getters like one over the real pad.
contract ImposterSplitter {
    address public pad;
    address public taxHandler;
    address public dev;

    constructor(address pad_, address handler_, address dev_) {
        pad = pad_;
        taxHandler = handler_;
        dev = dev_;
    }
}

/// @notice GangBuybackSplitter (dev 税按比例回购销毁) on the whole merged deployment, over pairs that keep the V2 oracle:
///         binding, the split, ratio changes (raise now / cut after notice), the chunked buy-back with its TWAP check,
///         sweep, and the pool tax paying it end to end.
contract GangBuybackSplitterTest is GangFixture {
    address keeper = makeAddr("keeper");

    uint16 constant TAX = 300;

    function _newPairFactory() internal override returns (address) {
        return address(new TwapMockPairFactory());
    }

    function setUp() public {
        _deployGang(keeper);
    }

    // ---------------------------------------------------------------- helpers
    /// @dev A splitter for `dev`, listed on the tax handler.
    function _splitter(address dev, uint16 bps) internal returns (GangBuybackSplitter s) {
        s = new GangBuybackSplitter(address(pad), dev, bps);
        vm.prank(owner);
        handler.list(address(s), "dev buyback");
    }

    /// @dev The dev creates a taxed V3 token paying a fresh splitter, buys on the curve, and anyone binds it.
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

    function _next(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
    }

    function _bal(address asset, address who) internal view returns (uint256) {
        return IERC20(asset).balanceOf(who);
    }

    // ---------------------------------------------------------------- deploy / bind
    function test_constructor() public {
        address dev = makeAddr("dev");
        vm.expectRevert(GangBuybackSplitter.ZeroAddress.selector);
        new GangBuybackSplitter(address(0), dev, 1);
        vm.expectRevert(GangBuybackSplitter.ZeroAddress.selector);
        new GangBuybackSplitter(address(pad), address(0), 1);
        vm.expectRevert(GangBuybackSplitter.BadBps.selector);
        new GangBuybackSplitter(address(pad), dev, 10_001);

        GangBuybackSplitter s = new GangBuybackSplitter(address(pad), dev, 10_000);
        assertEq(s.taxHandler(), address(handler));
        assertEq(s.dev(), dev);
        assertEq(s.buybackBps(), 10_000);
        assertEq(s.token(), address(0));
    }

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
        assertEq(divVault.shares(t, address(s)), 0);
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

    /// @dev A splitter one block and a window past its first observation: the next `burnChunk` buys.
    function _readyToBuy() internal returns (GangBuybackSplitter s, address t) {
        (s, t,) = _setup(address(wbnb), 10_000, true);
        wbnb.mintUnlimited(address(s), 1 ether);
        s.burnChunk(0);
        _next(10 minutes);
    }

    /// @dev The control for the test below: not excluded, a chunk does write the splitter's share (so the zero-call
    ///      check there tests something).
    function test_burn_notExcludedSplitterGetsShareWrite() public {
        (GangBuybackSplitter s, address t) = _readyToBuy();
        vm.expectCall(address(divVault), abi.encodeWithSelector(divVault.setShare.selector, t, address(s)));
        s.burnChunk(0);
    }

    /// @dev Excluded from the vault (the Safe batch the deploy script prints), a chunk writes no share for it.
    function test_burn_excludedSplitterHasNoShare() public {
        (GangBuybackSplitter s, address t) = _readyToBuy();
        vm.prank(owner);
        divVault.setExcluded(address(s), true);
        // no share write for the splitter at all (a prefix match: any new share)
        vm.expectCall(address(divVault), abi.encodeWithSelector(divVault.setShare.selector, t, address(s)), 0);
        (, uint256 burned) = s.burnChunk(0);
        assertGt(burned, 0);
        assertEq(divVault.shares(t, address(s)), 0);
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

    // ---------------------------------------------------------------- deploy-script check
    function test_verify_acceptsGenuine_refusesFakes() public {
        DeployGangBuybackSplitter script = new DeployGangBuybackSplitter();
        address dev = _newAgent();
        GangBuybackSplitter s = new GangBuybackSplitter(address(pad), dev, 2_500);
        script.verify(address(pad), address(s));

        // over a fake pad: the getters say so
        GangBuybackSplitter overFake = new GangBuybackSplitter(address(new FakePad(address(handler))), dev, 2_500);
        vm.expectRevert(abi.encodeWithSelector(DeployGangBuybackSplitter.WiringCheck.selector, "splitter.pad"));
        script.verify(address(pad), address(overFake));

        // right getters, other code
        ImposterSplitter imp = new ImposterSplitter(address(pad), address(handler), dev);
        vm.expectRevert(abi.encodeWithSelector(DeployGangBuybackSplitter.WiringCheck.selector, "splitter.code"));
        script.verify(address(pad), address(imp));

        vm.expectRevert(abi.encodeWithSelector(DeployGangBuybackSplitter.WiringCheck.selector, "splitter.code"));
        script.verify(address(pad), makeAddr("eoa"));
    }

    function test_script_expectAndBps() public {
        DeployGangBuybackSplitter script = new DeployGangBuybackSplitter();
        address dev = _newAgent();
        GangBuybackSplitter s = new GangBuybackSplitter(address(pad), dev, 2_500);

        // a genuine splitter of another dev, or at another ratio, is not the one asked for
        script.expect(address(s), dev, 2_500);
        vm.expectRevert(abi.encodeWithSelector(DeployGangBuybackSplitter.WiringCheck.selector, "splitter.dev"));
        script.expect(address(s), makeAddr("other"), 2_500);
        vm.expectRevert(abi.encodeWithSelector(DeployGangBuybackSplitter.WiringCheck.selector, "splitter.buybackBps"));
        script.expect(address(s), dev, 2_000);

        // a cut already asked for: refused while it can apply, fine once it lapsed or was cancelled
        vm.prank(dev);
        s.setBuybackBps(0);
        vm.expectRevert(abi.encodeWithSelector(DeployGangBuybackSplitter.WiringCheck.selector, "splitter.pendingCut"));
        script.expect(address(s), dev, 2_500);
        uint256 snap = vm.snapshotState();
        vm.warp(s.pendingAt() + s.CUT_TTL() + 1);
        script.expect(address(s), dev, 2_500);
        vm.revertToState(snap);
        vm.prank(dev);
        s.setBuybackBps(2_500);
        script.expect(address(s), dev, 2_500);

        // SPLITTER_BPS above 10000 is refused, not wrapped (uint16(70000) = 4464)
        vm.setEnv("SPLITTER_BPS", "10000");
        assertEq(script.envBps(), 10_000);
        vm.setEnv("SPLITTER_BPS", "70000");
        vm.expectRevert(abi.encodeWithSelector(DeployGangBuybackSplitter.WiringCheck.selector, "SPLITTER_BPS"));
        script.envBps();
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
