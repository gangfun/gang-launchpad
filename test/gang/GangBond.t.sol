// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {TwapMockPairFactory} from "../mocks/TwapMockPair.sol";
import {GangBond} from "../../src/gang/GangBond.sol";
import {IGangBond} from "../../src/gang/interfaces/IGangBond.sol";

/// @notice GangBond (Agent 押金承诺) on the whole merged deployment, over pairs that keep the V2 oracle: posting rules,
///         the two endings (settle / report), the chunked buy-back with its TWAP check, and the coverage views — on a
///         taxed V3 token, an untaxed one (no `token.pair()`) and a 打新 token.
contract GangBondTest is GangFixture {
    GangBond bond;
    address keeper = makeAddr("keeper");
    address reporter = makeAddr("reporter");

    uint16 constant TAX = 300;

    function _newPairFactory() internal override returns (address) {
        return address(new TwapMockPairFactory());
    }

    function setUp() public {
        _deployGang(keeper);
        bond = new GangBond(address(pad), address(wbnb));
    }

    // ---------------------------------------------------------------- helpers
    /// @dev A V3 token whose creator bought on the curve before it graduated.
    function _v3(address quote, uint16 taxBps) internal returns (address t, address creator) {
        creator = _newAgent();
        t = _createV3(creator, quote, taxBps == 0 ? _tax(0, 0, 0, address(0)) : _tax(taxBps, taxBps, 5_000, creator));
        vm.prank(creator);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
    }

    function _fair() internal returns (address t, address creator) {
        creator = _newAgent();
        t = _createFair(creator, address(wbnb), 100);
        _fill(t);
    }

    function _bal(address t, address who) internal view returns (uint256) {
        return IERC20(t).balanceOf(who);
    }

    /// @dev Post with BNB (WBNB quote): half the creator's balance, 30 days.
    function _postBnb(address t, address creator, uint256 amount) internal returns (uint256 hold, uint64 deadline) {
        hold = _bal(t, creator) / 2;
        deadline = uint64(block.timestamp + 30 days);
        vm.deal(creator, amount);
        vm.prank(creator);
        bond.post{value: amount}(t, amount, hold, deadline);
    }

    /// @dev The creator sends `amount` away (below the promise once past its slack).
    function _dump(address t, address creator, uint256 amount) internal {
        vm.prank(creator);
        IERC20(t).transfer(makeAddr("elsewhere"), amount);
    }

    function _pairOf(address t) internal view returns (address p) {
        (p,) = bond.marketOf(t);
    }

    function _next(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
    }

    // ---------------------------------------------------------------- post
    function test_post_refusesUnknownAndPreGraduation() public {
        vm.expectRevert(IGangBond.UnknownToken.selector);
        bond.post(makeAddr("nope"), 1, 1, uint64(block.timestamp + 30 days));

        address creator = _newAgent();
        address t = _createV3(creator, address(wbnb), _tax(TAX, TAX, 5_000, creator));
        vm.prank(creator);
        pad.buy(t, 1 ether, 0);
        vm.prank(creator);
        vm.expectRevert(IGangBond.NotTradable.selector);
        bond.post(t, 1 ether, 1, uint64(block.timestamp + 30 days));

        address c2 = _newAgent();
        address s = _createFair(c2, address(wbnb), 100);
        vm.prank(c2);
        vm.expectRevert(IGangBond.NotTradable.selector);
        bond.post(s, 1 ether, 1, uint64(block.timestamp + 30 days));
    }

    function test_post_checks() public {
        (address t, address creator) = _v3(address(wbnb), TAX);
        uint256 bal = _bal(t, creator);
        uint64 dl = uint64(block.timestamp + 30 days);
        vm.deal(creator, 10 ether);
        vm.startPrank(creator);
        vm.expectRevert(IGangBond.ZeroAmount.selector);
        bond.post(t, 0, 1, dl);
        vm.expectRevert(IGangBond.BadDuration.selector);
        bond.post{value: 1 ether}(t, 1 ether, 1, uint64(block.timestamp + 7 days - 1));
        vm.expectRevert(IGangBond.BadDuration.selector);
        bond.post{value: 1 ether}(t, 1 ether, 1, uint64(block.timestamp + 90 days + 1));
        vm.expectRevert(IGangBond.BadHold.selector);
        bond.post{value: 1 ether}(t, 1 ether, 0, dl);
        vm.expectRevert(IGangBond.BadHold.selector);
        bond.post{value: 1 ether}(t, 1 ether, bal + 1, dl);
        vm.expectRevert(IGangBond.BadValue.selector);
        bond.post{value: 0.5 ether}(t, 1 ether, bal, dl);
        vm.stopPrank();

        address stranger = _newAgent();
        vm.prank(stranger);
        vm.expectRevert(IGangBond.NotCreator.selector);
        bond.post(t, 1 ether, 1, dl);

        // the edges themselves are fine
        vm.prank(creator);
        bond.post{value: 1 ether}(t, 1 ether, bal, uint64(block.timestamp + 7 days));
    }

    function test_post_bnb_recordsBond() public {
        (address t, address creator) = _v3(address(wbnb), TAX);
        uint256 hold = _bal(t, creator) / 2;
        uint64 dl = uint64(block.timestamp + 30 days);
        vm.deal(creator, 1 ether);
        vm.expectEmit(address(bond));
        emit IGangBond.BondPosted(t, creator, 1, address(wbnb), 1 ether, hold, dl);
        vm.prank(creator);
        bond.post{value: 1 ether}(t, 1 ether, hold, dl);

        IGangBond.Bond memory b = bond.bondOf(t);
        assertEq(b.creator, creator);
        assertEq(b.quote, address(wbnb));
        assertEq(b.round, 1);
        assertEq(uint8(b.state), uint8(IGangBond.State.Active));
        assertEq(b.postedAt, block.timestamp);
        assertEq(b.deadline, dl);
        assertEq(b.amount, 1 ether);
        assertEq(b.holdAmount, hold);
        assertEq(b.burnLeft, 0);
        assertEq(wbnb.balanceOf(address(bond)), 1 ether);
        (uint32 posted,,) = bond.historyOf(creator);
        assertEq(posted, 1);
        assertEq(_pairOf(t), _curvePair(t));

        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(IGangBond.BondLive.selector);
        bond.post{value: 1 ether}(t, 1 ether, hold, dl);
    }

    function test_post_erc20Quote() public {
        (address t, address creator) = _v3(address(quoteTok), TAX);
        uint256 hold = _bal(t, creator) / 2;
        vm.startPrank(creator);
        quoteTok.approve(address(bond), type(uint256).max);
        vm.expectRevert(IGangBond.BadValue.selector); // native BNB only for a WBNB quote
        bond.post{value: 1 ether}(t, 1 ether, hold, uint64(block.timestamp + 30 days));
        bond.post(t, 2 ether, hold, uint64(block.timestamp + 30 days));
        vm.stopPrank();
        assertEq(quoteTok.balanceOf(address(bond)), 2 ether);
        assertEq(bond.bondOf(t).quote, address(quoteTok));
    }

    // ---------------------------------------------------------------- topUp / raiseHold / extend
    function test_creatorAdjustments() public {
        (address t, address creator) = _v3(address(wbnb), TAX);
        (uint256 hold, uint64 dl) = _postBnb(t, creator, 1 ether);

        // topUp: BNB or WBNB, creator only, adds
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        bond.topUp{value: 0.5 ether}(t, 0.5 ether);
        vm.startPrank(creator);
        wbnb.approve(address(bond), type(uint256).max);
        bond.topUp(t, 0.25 ether);
        vm.expectRevert(IGangBond.ZeroAmount.selector);
        bond.topUp(t, 0);
        vm.stopPrank();
        assertEq(bond.bondOf(t).amount, 1.75 ether);
        vm.prank(reporter);
        vm.expectRevert(IGangBond.NotCreator.selector);
        bond.topUp(t, 1);

        // raiseHold: not lower, not above the balance
        uint256 bal = _bal(t, creator);
        vm.startPrank(creator);
        vm.expectRevert(IGangBond.BadHold.selector);
        bond.raiseHold(t, hold - 1);
        vm.expectRevert(IGangBond.BadHold.selector);
        bond.raiseHold(t, bal + 1);
        bond.raiseHold(t, bal);
        vm.stopPrank();
        assertEq(bond.bondOf(t).holdAmount, bal);

        // extend: later, at most 90 days from now
        vm.startPrank(creator);
        vm.expectRevert(IGangBond.BadDuration.selector);
        bond.extend(t, dl);
        vm.expectRevert(IGangBond.BadDuration.selector);
        bond.extend(t, uint64(block.timestamp + 90 days + 1));
        bond.extend(t, uint64(block.timestamp + 90 days));
        vm.stopPrank();
        assertEq(bond.bondOf(t).deadline, block.timestamp + 90 days);

        vm.prank(reporter);
        vm.expectRevert(IGangBond.NotCreator.selector);
        bond.extend(t, uint64(block.timestamp + 91 days));
    }

    // ---------------------------------------------------------------- report
    function test_report_slashesWithReward() public {
        (address t, address creator) = _v3(address(wbnb), TAX);
        (uint256 hold,) = _postBnb(t, creator, 1 ether);
        assertFalse(bond.isViolated(t));
        vm.prank(reporter);
        vm.expectRevert(IGangBond.NotViolated.selector);
        bond.report(t);

        // exactly at the promise is fine; one unit below is not
        _dump(t, creator, _bal(t, creator) - hold);
        assertFalse(bond.isViolated(t));
        _dump(t, creator, 1);
        assertTrue(bond.isViolated(t));

        vm.expectEmit(address(bond));
        emit IGangBond.BondReported(t, 1, reporter, hold - 1, 0.01 ether, 0.99 ether);
        vm.prank(reporter);
        bond.report(t);

        IGangBond.Bond memory b = bond.bondOf(t);
        assertEq(uint8(b.state), uint8(IGangBond.State.Slashed));
        assertEq(b.burnLeft, 0.99 ether);
        assertEq(wbnb.balanceOf(reporter), 0.01 ether);
        (, uint32 honored, uint32 slashed) = bond.historyOf(creator);
        assertEq(honored, 0);
        assertEq(slashed, 1);

        vm.expectRevert(IGangBond.NotActive.selector);
        bond.report(t);
        vm.expectRevert(IGangBond.NotActive.selector);
        bond.settle(t);
        vm.prank(creator);
        vm.expectRevert(IGangBond.NotActive.selector);
        bond.topUp(t, 1);
        // buy-back still owed: no new bond yet
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(IGangBond.BondLive.selector);
        bond.post{value: 1 ether}(t, 1 ether, 1, uint64(block.timestamp + 30 days));
    }

    function test_report_selfReportGetsNoReward() public {
        (address t, address creator) = _v3(address(wbnb), TAX);
        _postBnb(t, creator, 1 ether);
        _dump(t, creator, _bal(t, creator));
        vm.prank(creator);
        bond.report(t);
        assertEq(bond.bondOf(t).burnLeft, 1 ether);
        assertEq(wbnb.balanceOf(address(bond)), 1 ether);
    }

    function test_report_afterDeadlineBeforeSettle() public {
        (address t, address creator) = _v3(address(wbnb), TAX);
        (, uint64 dl) = _postBnb(t, creator, 1 ether);
        vm.warp(dl + 1 days);
        _dump(t, creator, _bal(t, creator));
        vm.expectRevert(IGangBond.Violated.selector);
        bond.settle(t);
        vm.prank(reporter);
        bond.report(t);
        assertEq(uint8(bond.bondOf(t).state), uint8(IGangBond.State.Slashed));
    }

    // ---------------------------------------------------------------- settle
    function test_settle_refundsCreatorAndAllowsNewRound() public {
        (address t, address creator) = _v3(address(wbnb), TAX);
        (uint256 hold, uint64 dl) = _postBnb(t, creator, 1 ether);
        vm.warp(dl - 1);
        vm.expectRevert(IGangBond.NotDue.selector);
        bond.settle(t);

        vm.warp(dl);
        uint256 before = wbnb.balanceOf(creator);
        vm.expectEmit(address(bond));
        emit IGangBond.BondSettled(t, 1, creator, 1 ether);
        vm.prank(reporter); // anyone can call; the bond still goes to the creator
        bond.settle(t);
        assertEq(wbnb.balanceOf(creator) - before, 1 ether);
        assertEq(wbnb.balanceOf(reporter), 0);
        assertEq(uint8(bond.bondOf(t).state), uint8(IGangBond.State.Settled));
        (uint32 posted, uint32 honored, uint32 slashed) = bond.historyOf(creator);
        assertEq(posted, 1);
        assertEq(honored, 1);
        assertEq(slashed, 0);

        // free to sell now; a new round starts clean
        _dump(t, creator, _bal(t, creator) - hold / 2);
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        bond.post{value: 1 ether}(t, 1 ether, hold / 2, uint64(block.timestamp + 30 days));
        assertEq(bond.bondOf(t).round, 2);
    }

    // ---------------------------------------------------------------- burnChunk
    function test_burn_chunksUntilDone() public {
        (address t, address creator) = _v3(address(wbnb), TAX);
        _postBnb(t, creator, 0.5 ether);
        _dump(t, creator, _bal(t, creator));
        vm.prank(reporter);
        bond.report(t);
        address pair = _pairOf(t);

        // first call records the observation only
        (uint256 q0, uint256 b0) = bond.burnChunk(t, 0);
        assertEq(q0 + b0, 0);
        (bool ready,,) = bond.previewBurn(t);
        assertFalse(ready);
        _next(5 minutes);
        (q0, b0) = bond.burnChunk(t, 0);
        assertEq(q0 + b0, 0, "window not passed");

        uint256 deadBefore = _bal(t, bond.DEAD());
        uint256 burnedTotal;
        uint256 chunks;
        while (bond.bondOf(t).burnLeft > 0) {
            _next(10 minutes);
            (uint256 rT, uint256 rQ) = _reserves(t, pair);
            (bool ok, uint256 pq, uint256 pOut) = bond.previewBurn(t);
            assertTrue(ok);
            assertLe(pq, (rQ * 50) / 10_000, "chunk cap");
            uint256 out = (pq * 9975 * rT) / (rQ * 10_000 + pq * 9975);
            assertEq(pOut, out - (out * TAX) / 10_000, "buy tax");
            (uint256 q, uint256 burned) = bond.burnChunk(t, pOut);
            assertEq(q, pq);
            assertEq(burned, pOut);
            burnedTotal += burned;
            chunks++;
            if (bond.bondOf(t).burnLeft > 0) {
                vm.expectRevert(IGangBond.BurnedThisBlock.selector);
                bond.burnChunk(t, 0);
            }
        }
        assertGt(chunks, 1);
        assertEq(_bal(t, bond.DEAD()) - deadBefore, burnedTotal);
        assertEq(_bal(t, address(bond)), 0);
        assertEq(wbnb.balanceOf(address(bond)), 0);
        vm.expectRevert(IGangBond.NothingToBurn.selector);
        bond.burnChunk(t, 0);

        // the round is over: a new post is no longer BondLive (this creator holds nothing, so it fails on the hold)
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(IGangBond.BadHold.selector);
        bond.post{value: 1 ether}(t, 1 ether, 1, uint64(block.timestamp + 30 days));
    }

    function test_burn_skipsAfterPump() public {
        (address t, address creator) = _v3(address(wbnb), TAX);
        _postBnb(t, creator, 0.5 ether);
        _dump(t, creator, _bal(t, creator));
        vm.prank(reporter);
        bond.report(t);
        address pair = _pairOf(t);
        bond.burnChunk(t, 0);
        _next(10 minutes);

        // someone lifts the price ~5% in this block, hoping to sell into the buy-back
        (, uint256 rQ) = _reserves(t, pair);
        _poolBuy(t, address(wbnb), pair, _newAgent(), (rQ * 5) / 100);
        uint256 left = bond.bondOf(t).burnLeft;
        (bool ready,,) = bond.previewBurn(t);
        assertFalse(ready);
        (uint256 q, uint256 burned) = bond.burnChunk(t, 0);
        assertEq(q + burned, 0);
        assertEq(bond.bondOf(t).burnLeft, left);

        // held while the keeper keeps calling, the high price becomes the average, and buying resumes
        for (uint256 i; i < 6 && q == 0; i++) {
            _next(10 minutes);
            (q,) = bond.burnChunk(t, 0);
        }
        assertGt(q, 0);
    }

    /// @dev Review M-1: after the keeper went quiet and the price fell, an average over the idle stretch would let a bot
    ///      push the price back up near the old level and sell into the buy-back. The observations start over instead.
    function test_burn_restartsAfterIdle() public {
        (address t, address creator) = _v3(address(wbnb), 0);
        _postBnb(t, creator, 5 ether);
        _dump(t, creator, _bal(t, creator));
        vm.prank(reporter);
        bond.report(t);
        address pair = _pairOf(t);
        bond.burnChunk(t, 0); // observation at the old price

        // a day without calls at the old price, then it falls ~40% just before the next call
        _next(1 days);
        (uint256 rT,) = _reserves(t, pair);
        address whale = _newAgent();
        deal(t, whale, rT / 3);
        _poolSell(t, pair, whale, rT / 3);
        _next(1 minutes);

        // the bot lifts the price back toward the old average: the stale average must not be used
        (, uint256 rQ) = _reserves(t, pair);
        _poolBuy(t, address(wbnb), pair, _newAgent(), (rQ * 20) / 100);
        (bool ready,,) = bond.previewBurn(t);
        assertFalse(ready);
        (uint256 q,) = bond.burnChunk(t, 0);
        assertEq(q, 0, "restart: records only");

        // a fresh window at the current price buys again
        _next(10 minutes);
        (q,) = bond.burnChunk(t, 0);
        assertGt(q, 0);
    }

    /// @dev Review L-2: tokens borrowed from the pair's own flash swap (the pair holds fewer than its reserve) can't
    ///      make a breached creator look compliant at settle.
    function test_settle_refusesMidFlashSwap() public {
        (address t, address creator) = _v3(address(wbnb), TAX);
        (, uint64 dl) = _postBnb(t, creator, 1 ether);
        _dump(t, creator, _bal(t, creator));
        vm.warp(dl);
        address pair = _pairOf(t);
        // the pair has sent tokens out ahead of being paid (optimistic transfer inside swap)
        uint256 need = bond.bondOf(t).holdAmount * 2;
        vm.prank(pair);
        IERC20(t).transfer(creator, need);
        vm.expectRevert(IGangBond.FlashSwapActive.selector);
        bond.settle(t);
    }

    function test_burn_slippage() public {
        (address t, address creator) = _v3(address(wbnb), TAX);
        _postBnb(t, creator, 0.5 ether);
        _dump(t, creator, _bal(t, creator));
        vm.prank(reporter);
        bond.report(t);
        bond.burnChunk(t, 0);
        _next(10 minutes);
        (,, uint256 out) = bond.previewBurn(t);
        vm.expectRevert(IGangBond.Slippage.selector);
        bond.burnChunk(t, out + 1);
    }

    function test_burn_newSlashRecordsAfresh() public {
        (address t, address creator) = _v3(address(wbnb), TAX);
        (uint256 hold,) = _postBnb(t, creator, 0.01 ether);
        uint256 keep = _bal(t, creator);
        _dump(t, creator, keep - hold + 1);
        vm.prank(reporter);
        bond.report(t);
        bond.burnChunk(t, 0);
        _next(10 minutes);
        bond.burnChunk(t, 0);
        assertEq(bond.bondOf(t).burnLeft, 0);

        // round 2, slashed a minute later (well inside the window, so only the report's reset can make this call
        // record-only): its first call records again instead of reusing round 1's observations
        _next(1 minutes);
        vm.deal(creator, 0.01 ether);
        vm.prank(creator);
        bond.post{value: 0.01 ether}(t, 0.01 ether, 1, uint64(block.timestamp + 30 days));
        _dump(t, creator, _bal(t, creator));
        vm.prank(reporter);
        bond.report(t);
        (bool ready,,) = bond.previewBurn(t);
        assertFalse(ready);
        (uint256 q,) = bond.burnChunk(t, 0);
        assertEq(q, 0);
    }

    /// @dev An 18-decimal ERC20 quote (not WBNB) through the whole buy-back.
    function test_burn_erc20Quote() public {
        (address t, address creator) = _v3(address(quoteTok), TAX);
        uint256 hold = _bal(t, creator) / 2;
        vm.startPrank(creator);
        quoteTok.approve(address(bond), type(uint256).max);
        bond.post(t, 1 ether, hold, uint64(block.timestamp + 30 days));
        vm.stopPrank();
        _dump(t, creator, _bal(t, creator));
        vm.prank(reporter);
        bond.report(t);
        assertEq(quoteTok.balanceOf(reporter), 0.01 ether);
        bond.burnChunk(t, 0);
        _next(10 minutes);
        (, uint256 pq, uint256 pOut) = bond.previewBurn(t);
        uint256 deadBefore = _bal(t, bond.DEAD());
        (uint256 q, uint256 burned) = bond.burnChunk(t, pOut);
        assertEq(q, pq);
        assertEq(burned, pOut);
        assertEq(_bal(t, bond.DEAD()) - deadBefore, burned);
        assertEq(quoteTok.balanceOf(address(bond)), 0.99 ether - q);
    }

    /// @dev Two tokens bonded in WBNB: one's slash and buy-back and the other's settle each move only their own bond.
    function test_twoBondsShareWbnb() public {
        (address a, address ca) = _v3(address(wbnb), TAX);
        (address c, address cc) = _v3(address(wbnb), 0);
        _postBnb(a, ca, 1 ether);
        (, uint64 dl) = _postBnb(c, cc, 2 ether);
        assertEq(wbnb.balanceOf(address(bond)), 3 ether);

        _dump(a, ca, _bal(a, ca));
        vm.prank(reporter);
        bond.report(a);
        bond.burnChunk(a, 0);
        _next(10 minutes);
        (uint256 q,) = bond.burnChunk(a, 0);
        assertGt(q, 0);
        assertEq(wbnb.balanceOf(address(bond)), 2 ether + bond.bondOf(a).burnLeft);

        vm.warp(dl);
        uint256 before = wbnb.balanceOf(cc);
        bond.settle(c);
        assertEq(wbnb.balanceOf(cc) - before, 2 ether);
        assertEq(wbnb.balanceOf(address(bond)), bond.bondOf(a).burnLeft);
    }

    // ---------------------------------------------------------------- other kinds
    function test_untaxedV3_fullCycle() public {
        (address t, address creator) = _v3(address(wbnb), 0);
        assertEq(_gangToken(t).pair(), address(0)); // untaxed: the token never learns its pair
        _postBnb(t, creator, 0.2 ether);
        assertEq(_pairOf(t), _curvePair(t));
        _dump(t, creator, _bal(t, creator));
        vm.prank(reporter);
        bond.report(t);
        bond.burnChunk(t, 0);
        _next(10 minutes);
        (bool ok, uint256 pq, uint256 pOut) = bond.previewBurn(t);
        assertTrue(ok);
        (uint256 q, uint256 burned) = bond.burnChunk(t, 0);
        assertEq(q, pq);
        assertEq(burned, pOut); // no buy tax
        assertGe(_bal(t, bond.DEAD()), burned);
    }

    function test_fair_fullCycle() public {
        (address t, address creator) = _fair();
        uint256 hold = _bal(t, creator);
        assertGt(hold, 0);
        vm.deal(creator, 0.2 ether);
        vm.prank(creator);
        bond.post{value: 0.2 ether}(t, 0.2 ether, hold, uint64(block.timestamp + 7 days));
        assertEq(_pairOf(t), _salePair(t));
        _dump(t, creator, 1);
        vm.prank(reporter);
        bond.report(t);
        bond.burnChunk(t, 0);
        _next(10 minutes);
        (uint256 rT, uint256 rQ) = _reserves(t, _salePair(t));
        (, uint256 pq, uint256 pOut) = bond.previewBurn(t);
        uint256 out = (pq * 9975 * rT) / (rQ * 10_000 + pq * 9975);
        assertEq(pOut, out - out / 100); // 打新: 1% buy tax
        (uint256 q, uint256 burned) = bond.burnChunk(t, pOut);
        assertEq(q, pq);
        assertEq(burned, pOut);
    }

    // ---------------------------------------------------------------- coverage views
    function test_coverage() public {
        (address t, address creator) = _v3(address(wbnb), TAX);
        assertEq(bond.dumpValue(t), 0);
        assertEq(bond.coverageBps(t), 0);
        uint256 hold = _bal(t, creator) / 2;
        (uint256 rT, uint256 rQ) = _reserves(t, _curvePair(t));
        uint256 xIn = hold - (hold * TAX) / 10_000;
        uint256 expect = (xIn * 9975 * rQ) / (rT * 10_000 + xIn * 9975);
        assertEq(bond.quoteDump(t, hold), expect); // before any bond: the CLI's --cover

        _postBnb(t, creator, 1 ether);
        assertEq(bond.dumpValue(t), expect);
        assertEq(bond.coverageBps(t), (1 ether * 10_000) / expect);

        // the price rises → coverage falls
        uint256 c0 = bond.coverageBps(t);
        _poolBuy(t, address(wbnb), _curvePair(t), _newAgent(), 2 ether);
        assertLt(bond.coverageBps(t), c0);
    }
}
