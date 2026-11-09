// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GangCallBond} from "../../src/gang/GangCallBond.sol";
import {IGangCallBond} from "../../src/gang/interfaces/IGangCallBond.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";

/// @notice GangCallBond (docs/SPEC-AGENT-CALLS-2026-11-09.md §5) on a whole 3.0 deployment of mocks.
contract GangCallBondTest is GangFixture {
    GangCallBond internal cb;
    address internal safe = makeAddr("safe");
    address internal settlerKey = makeAddr("settler");
    address internal caller;
    address internal reporter;
    address internal f1 = makeAddr("follower1");
    address internal f2 = makeAddr("follower2");
    address internal t;
    bytes32 internal constant NOTE = keccak256("note tx");
    uint256 internal constant BOND = 1 ether;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(address(this));
        cb = new GangCallBond(
            address(pad), address(wbnb), [address(quoteTok), address(0), address(0)], safe, settlerKey
        );
        caller = _newAgent();
        reporter = _newAgent();
        t = _createV3(_newAgent(), address(wbnb), _tax(0, 0, 0, address(0)));
        _buy(caller, t, 0.05 ether);
        vm.prank(caller);
        wbnb.approve(address(cb), type(uint256).max);
    }

    // ---------------------------------------------------------------- helpers
    function _buy(address who, address token, uint256 funds) internal returns (uint256 out) {
        vm.prank(who, who);
        out = pad.buy(token, funds, 0);
    }

    function _sell(address who, address token, uint256 amount) internal {
        vm.startPrank(who, who);
        IERC20(token).approve(address(pad), amount);
        pad.sell(token, amount, 0);
        vm.stopPrank();
    }

    function _bal(address who) internal view returns (uint256) {
        return IERC20(t).balanceOf(who);
    }

    function _post() internal returns (uint256 id) {
        uint256 hold = _bal(caller);
        vm.prank(caller);
        id = cb.post(t, NOTE, BOND, hold, 48 hours);
    }

    function _reported() internal returns (uint256 id) {
        id = _post();
        _sell(caller, t, _bal(caller) / 2);
        vm.prank(reporter);
        cb.report(id);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev A two-leaf tree: (f1, a1), (f2, a2).
    function _tree(uint256 id, uint256 a1, uint256 a2)
        internal
        view
        returns (bytes32 root, bytes32[] memory p1, bytes32[] memory p2)
    {
        bytes32 l1 = cb.leaf(id, f1, a1);
        bytes32 l2 = cb.leaf(id, f2, a2);
        root = _hashPair(l1, l2);
        p1 = new bytes32[](1);
        p1[0] = l2;
        p2 = new bytes32[](1);
        p2[0] = l1;
    }

    function _postRoot(uint256 id, bytes32 root, uint256 total) internal {
        vm.prank(settlerKey);
        cb.postRoot(id, root, total);
    }

    // ---------------------------------------------------------------- constructor / owner
    function test_constructor_settlerMustDifferFromOwner() public {
        vm.expectRevert(IGangCallBond.SettlerIsOwner.selector);
        new GangCallBond(address(pad), address(wbnb), [address(0), address(0), address(0)], safe, safe);
        vm.expectRevert(IGangCallBond.ZeroAddress.selector);
        new GangCallBond(address(0), address(wbnb), [address(0), address(0), address(0)], safe, settlerKey);
    }

    function test_setSettler_onlyOwner_notOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        cb.setSettler(address(1));
        vm.startPrank(safe);
        vm.expectRevert(IGangCallBond.SettlerIsOwner.selector);
        cb.setSettler(safe);
        cb.setSettler(address(1));
        assertEq(cb.settler(), address(1));
        vm.expectRevert(IGangCallBond.SettlerIsOwner.selector);
        cb.transferOwnership(address(1));
        cb.transferOwnership(address(2));
        vm.expectRevert(IGangCallBond.SettlerIsOwner.selector);
        cb.setSettler(address(2)); // the pending owner
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- post
    function test_post_pullsQuoteAndRecords() public {
        uint256 hold = _bal(caller);
        uint256 before = wbnb.balanceOf(caller);
        vm.prank(caller);
        uint256 id = cb.post(t, NOTE, BOND, hold, 48 hours);
        assertEq(id, 1);
        assertEq(wbnb.balanceOf(caller), before - BOND);
        assertEq(wbnb.balanceOf(address(cb)), BOND);
        IGangCallBond.Bond memory b = cb.bondOf(id);
        assertEq(b.caller, caller);
        assertEq(b.token, t);
        assertEq(b.quote, address(wbnb));
        assertEq(b.amount, BOND);
        assertEq(b.hold, hold);
        assertEq(b.noteTx, NOTE);
        assertEq(b.deadline, vm.getBlockTimestamp() + 48 hours);
        assertEq(uint8(b.state), uint8(IGangCallBond.State.Active));
        assertEq(cb.activeBondOf(caller, t), id);
    }

    function test_post_nativeBnb() public {
        uint256 hold = _bal(caller);
        vm.prank(caller);
        vm.expectRevert(IGangCallBond.BadValue.selector);
        cb.post{value: BOND - 1}(t, NOTE, BOND, hold, 7 days);
        vm.prank(caller);
        uint256 id = cb.post{value: BOND}(t, NOTE, BOND, hold, 7 days);
        assertEq(wbnb.balanceOf(address(cb)), BOND);
        assertEq(cb.bondOf(id).amount, BOND);
    }

    function test_post_erc20Quote() public {
        address q = _createV3(_newAgent(), address(quoteTok), _tax(0, 0, 0, address(0)));
        _buy(caller, q, 1 ether);
        vm.startPrank(caller);
        quoteTok.approve(address(cb), type(uint256).max);
        // ERC-20 quote: BNB is refused
        vm.expectRevert(IGangCallBond.BadValue.selector);
        cb.post{value: 1 ether}(q, NOTE, 1 ether, 1, 48 hours);
        uint256 id = cb.post(q, NOTE, 2 ether, IERC20(q).balanceOf(caller), 48 hours);
        vm.stopPrank();
        assertEq(cb.bondOf(id).quote, address(quoteTok));
        assertEq(quoteTok.balanceOf(address(cb)), 2 ether);
    }

    function test_post_refusesQuoteNotListed() public {
        address q = _createV3(_newAgent(), address(blq), _tax(0, 0, 0, address(0)));
        _buy(caller, q, 1 ether);
        vm.prank(caller);
        vm.expectRevert(IGangCallBond.QuoteNotAllowed.selector);
        cb.post(q, NOTE, 1 ether, 1, 48 hours);
    }

    function test_post_refusesFairAndUnknownTokens() public {
        address fair = _createFair(_newAgent(), address(wbnb), 1);
        vm.prank(caller);
        vm.expectRevert(IGangCallBond.NotCurveToken.selector);
        cb.post(fair, NOTE, BOND, 1, 48 hours);
        vm.prank(caller);
        vm.expectRevert(IGangCallBond.NotCurveToken.selector);
        cb.post(address(wbnb), NOTE, BOND, 1, 48 hours);
    }

    function test_post_refusesGraduated() public {
        _graduate(t);
        vm.prank(caller);
        vm.expectRevert(IGangCallBond.AlreadyGraduated.selector);
        cb.post(t, NOTE, BOND, 1, 48 hours);
    }

    function test_post_argumentChecks() public {
        uint256 bal = _bal(caller);
        vm.startPrank(caller);
        vm.expectRevert(IGangCallBond.BadNote.selector);
        cb.post(t, bytes32(0), BOND, bal, 48 hours);
        vm.expectRevert(IGangCallBond.ZeroAmount.selector);
        cb.post(t, NOTE, 0, bal, 48 hours);
        vm.expectRevert(IGangCallBond.BadDuration.selector);
        cb.post(t, NOTE, BOND, bal, 48 hours - 1);
        vm.expectRevert(IGangCallBond.BadDuration.selector);
        cb.post(t, NOTE, BOND, bal, 7 days + 1);
        vm.expectRevert(IGangCallBond.BadHold.selector);
        cb.post(t, NOTE, BOND, 0, 48 hours);
        vm.expectRevert(IGangCallBond.BadHold.selector);
        cb.post(t, NOTE, BOND, bal + 1, 48 hours);
        cb.post(t, NOTE, BOND, bal, 48 hours);
        vm.expectRevert(IGangCallBond.BondLive.selector);
        cb.post(t, keccak256("other"), BOND, bal, 48 hours);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- report
    function test_report_needsViolation() public {
        uint256 id = _post();
        vm.prank(reporter);
        vm.expectRevert(IGangCallBond.NotViolated.selector);
        cb.report(id);
        // other wallets trading changes nothing
        _buy(_newAgent(), t, 0.001 ether);
        vm.prank(reporter);
        vm.expectRevert(IGangCallBond.NotViolated.selector);
        cb.report(id);
    }

    function test_report_splitsRewardBurnPool() public {
        uint256 id = _post();
        _sell(caller, t, 1);
        uint256 r0 = wbnb.balanceOf(reporter);
        vm.prank(reporter);
        cb.report(id);
        assertEq(wbnb.balanceOf(reporter) - r0, BOND / 100);
        assertEq(wbnb.balanceOf(DEAD), BOND / 2);
        IGangCallBond.Bond memory b = cb.bondOf(id);
        assertEq(b.pool, BOND - BOND / 100 - BOND / 2);
        assertEq(wbnb.balanceOf(address(cb)), b.pool);
        assertEq(uint8(b.state), uint8(IGangCallBond.State.Reported));
        assertEq(b.reportedBlock, block.number);
        assertEq(cb.activeBondOf(caller, t), 0);
        vm.expectRevert(IGangCallBond.NotActive.selector);
        cb.report(id);
    }

    function test_report_selfReportBurnsTheReward() public {
        uint256 id = _post();
        _sell(caller, t, 1);
        uint256 c0 = wbnb.balanceOf(caller);
        vm.prank(caller);
        cb.report(id);
        assertEq(wbnb.balanceOf(caller), c0);
        assertEq(wbnb.balanceOf(DEAD), BOND / 2 + BOND / 100);
        assertEq(cb.bondOf(id).pool, BOND - BOND / 2 - BOND / 100);
    }

    function test_report_afterDeadlineUntilSettle() public {
        uint256 id = _post();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        cb.requestSettle(id);
        _sell(caller, t, 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert(IGangCallBond.Violated.selector);
        cb.settle(id);
        vm.prank(reporter);
        cb.report(id);
        assertEq(uint8(cb.bondOf(id).state), uint8(IGangCallBond.State.Reported));
    }

    function test_report_newBondAfterReport() public {
        _reported();
        uint256 bal = _bal(caller);
        vm.prank(caller);
        uint256 id2 = cb.post(t, keccak256("next"), BOND, bal, 48 hours);
        assertEq(id2, 2);
    }

    function testFuzz_report_splitAddsUp(uint96 amount, bool self) public {
        amount = uint96(bound(amount, 1, 100 ether));
        uint256 hold = _bal(caller);
        vm.prank(caller);
        uint256 id = cb.post(t, NOTE, amount, hold, 48 hours);
        _sell(caller, t, 1);
        uint256 r0 = wbnb.balanceOf(reporter);
        vm.prank(self ? caller : reporter);
        cb.report(id);
        uint256 reward = wbnb.balanceOf(reporter) - r0;
        uint256 pool = cb.bondOf(id).pool;
        assertEq(reward + wbnb.balanceOf(DEAD) + pool, amount);
        assertEq(wbnb.balanceOf(address(cb)), pool);
        assertGe(wbnb.balanceOf(DEAD), uint256(amount) / 2);
        if (self) assertEq(reward, 0);
    }

    // ---------------------------------------------------------------- settle
    function test_settle_returnsBond() public {
        uint256 id = _post();
        vm.expectRevert(IGangCallBond.NotDue.selector);
        cb.requestSettle(id);
        vm.expectRevert(IGangCallBond.NoSettleRequest.selector);
        cb.settle(id);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        cb.requestSettle(id);
        vm.expectRevert(IGangCallBond.AlreadyRequested.selector);
        cb.requestSettle(id);
        vm.expectRevert(IGangCallBond.NotDue.selector);
        cb.settle(id);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 c0 = wbnb.balanceOf(caller);
        cb.settle(id);
        assertEq(wbnb.balanceOf(caller) - c0, BOND);
        assertEq(uint8(cb.bondOf(id).state), uint8(IGangCallBond.State.Settled));
        assertEq(cb.activeBondOf(caller, t), 0);
        vm.expectRevert(IGangCallBond.NotActive.selector);
        cb.report(id);
    }

    function test_settle_requestNeedsPromiseKept() public {
        uint256 id = _post();
        _sell(caller, t, 1);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(IGangCallBond.Violated.selector);
        cb.requestSettle(id);
    }

    function test_settle_afterGraduation() public {
        uint256 id = _post();
        _graduate(t);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        cb.requestSettle(id);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        cb.settle(id);
        assertEq(uint8(cb.bondOf(id).state), uint8(IGangCallBond.State.Settled));
    }

    function test_settle_afterGraduation_transferOutIsViolation() public {
        uint256 id = _post();
        _graduate(t);
        vm.prank(caller);
        IERC20(t).transfer(address(0xA17), 1);
        vm.prank(reporter);
        cb.report(id);
        assertEq(uint8(cb.bondOf(id).state), uint8(IGangCallBond.State.Reported));
    }

    // ---------------------------------------------------------------- roots
    function test_postRoot_rules() public {
        uint256 id = _post();
        (bytes32 root,,) = _tree(id, 0.1 ether, 0.2 ether);
        vm.prank(settlerKey);
        vm.expectRevert(IGangCallBond.NotReported.selector);
        cb.postRoot(id, root, 0.3 ether);

        _sell(caller, t, 1);
        cb.report(id);
        uint256 pool = cb.bondOf(id).pool;

        vm.expectRevert(IGangCallBond.NotSettler.selector);
        cb.postRoot(id, root, 0.3 ether);
        vm.prank(settlerKey);
        vm.expectRevert(IGangCallBond.TooEarly.selector);
        cb.postRoot(id, root, 0.3 ether);
        assertFalse(cb.canPostRoot(id));

        vm.warp(vm.getBlockTimestamp() + 1 hours + 10 minutes);
        assertTrue(cb.canPostRoot(id));
        vm.startPrank(settlerKey);
        vm.expectRevert(IGangCallBond.BadTotal.selector);
        cb.postRoot(id, root, pool + 1);
        vm.expectRevert(IGangCallBond.BadTotal.selector);
        cb.postRoot(id, bytes32(0), 0.3 ether);
        cb.postRoot(id, root, 0.3 ether);
        vm.expectRevert(IGangCallBond.RootExists.selector);
        cb.postRoot(id, root, 0.3 ether);
        vm.stopPrank();
        assertFalse(cb.canPostRoot(id));
    }

    function test_claim_afterDispute() public {
        uint256 id = _reported();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        (bytes32 root, bytes32[] memory p1, bytes32[] memory p2) = _tree(id, 0.1 ether, 0.2 ether);
        _postRoot(id, root, 0.3 ether);

        vm.expectRevert(IGangCallBond.NotClaimable.selector);
        cb.claim(id, f1, 0.1 ether, p1);

        vm.warp(vm.getBlockTimestamp() + 2 days);
        // anyone sends it; the money goes to the account
        vm.prank(reporter);
        cb.claim(id, f1, 0.1 ether, p1);
        assertEq(wbnb.balanceOf(f1), 0.1 ether);
        vm.expectRevert(IGangCallBond.AlreadyClaimed.selector);
        cb.claim(id, f1, 0.1 ether, p1);
        vm.expectRevert(IGangCallBond.BadProof.selector);
        cb.claim(id, f2, 0.3 ether, p2);
        cb.claim(id, f2, 0.2 ether, p2);
        assertEq(wbnb.balanceOf(f2), 0.2 ether);
        assertTrue(cb.claimed(id, f1));
    }

    function test_claim_capsAtTotal() public {
        uint256 id = _reported();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        // leaves sum to more than the posted total: the later claim reverts
        (bytes32 root, bytes32[] memory p1, bytes32[] memory p2) = _tree(id, 0.2 ether, 0.2 ether);
        _postRoot(id, root, 0.3 ether);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        cb.claim(id, f1, 0.2 ether, p1);
        vm.expectRevert(IGangCallBond.OverTotal.selector);
        cb.claim(id, f2, 0.2 ether, p2);
    }

    function test_claim_leafBindsContractAndId() public {
        uint256 id = _reported();
        bytes32 l = cb.leaf(id, f1, 1);
        assertTrue(l != cb.leaf(id + 1, f1, 1));
        GangCallBond other =
            new GangCallBond(address(pad), address(wbnb), [address(0), address(0), address(0)], safe, settlerKey);
        assertTrue(l != other.leaf(id, f1, 1));
    }

    function test_veto_thenRepost() public {
        uint256 id = _reported();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        (bytes32 root, bytes32[] memory p1,) = _tree(id, 0.1 ether, 0.2 ether);
        _postRoot(id, root, 0.3 ether);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        cb.veto(id);
        vm.prank(safe);
        cb.veto(id);
        assertEq(cb.bondOf(id).root, bytes32(0));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(IGangCallBond.NotClaimable.selector);
        cb.claim(id, f1, 0.1 ether, p1);

        _postRoot(id, root, 0.3 ether);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(safe);
        vm.expectRevert(IGangCallBond.DisputeOver.selector);
        cb.veto(id);
        cb.claim(id, f1, 0.1 ether, p1);
    }

    function test_postWindow_closesAt28Days_vetoReopensFor3() public {
        uint256 id = _reported();
        uint256 r = vm.getBlockTimestamp();
        (bytes32 root,,) = _tree(id, 0.1 ether, 0.2 ether);

        vm.warp(r + 27 days);
        _postRoot(id, root, 0.3 ether);
        vm.warp(r + 28 days + 1 hours);
        vm.prank(safe);
        cb.veto(id);
        // past 28 days, but within 3 days of the veto
        vm.warp(r + 31 days);
        _postRoot(id, root, 0.3 ether);
        vm.prank(safe);
        cb.veto(id);
        vm.warp(r + 34 days + 1);
        vm.prank(settlerKey);
        vm.expectRevert(IGangCallBond.PostWindowClosed.selector);
        cb.postRoot(id, root, 0.3 ether);
    }

    function test_postWindow_hardCapAt60Days() public {
        uint256 id = _reported();
        uint256 r = vm.getBlockTimestamp();
        (bytes32 root,,) = _tree(id, 0.1 ether, 0.2 ether);
        vm.warp(r + 27 days);
        _postRoot(id, root, 0.3 ether);
        // keep vetoing every ~3 days
        for (uint256 i; i < 30; i++) {
            vm.prank(safe);
            cb.veto(id);
            if (vm.getBlockTimestamp() + 2 days >= r + 60 days) break;
            vm.warp(vm.getBlockTimestamp() + 2 days);
            _postRoot(id, root, 0.3 ether);
        }
        vm.warp(r + 60 days);
        vm.prank(settlerKey);
        vm.expectRevert(IGangCallBond.PostWindowClosed.selector);
        cb.postRoot(id, root, 0.3 ether);
        cb.burnUnpaid(id);
    }

    function test_claim_neverPaysTheCaller() public {
        uint256 id = _reported();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        bytes32 lc = cb.leaf(id, caller, 0.1 ether);
        bytes32 l2 = cb.leaf(id, f2, 0.2 ether);
        bytes32[] memory pc = new bytes32[](1);
        pc[0] = l2;
        _postRoot(id, _hashPair(lc, l2), 0.3 ether);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(IGangCallBond.NotFollower.selector);
        cb.claim(id, caller, 0.1 ether, pc);
    }

    function test_renounceDisabled() public {
        vm.prank(safe);
        vm.expectRevert(IGangCallBond.RenounceDisabled.selector);
        cb.renounceOwnership();
        assertEq(cb.owner(), safe);
    }

    function test_zeroTotalRoot_burnsWholePoolAfterDispute() public {
        uint256 id = _reported();
        uint256 pool = cb.bondOf(id).pool;
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _postRoot(id, keccak256("no followers"), 0);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        uint256 d0 = wbnb.balanceOf(DEAD);
        cb.burnRemainder(id);
        assertEq(wbnb.balanceOf(DEAD) - d0, pool);
        assertEq(wbnb.balanceOf(address(cb)), 0);
    }

    function test_settle_flashSwapActiveBlocks() public {
        uint256 id = _post();
        _graduate(t);
        address pair = _curvePair(t);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        // the pair lent out tokens it still books as reserve (mid flash swap)
        vm.prank(pair);
        IERC20(t).transfer(address(0xF1A5), 1);
        vm.expectRevert(IGangCallBond.FlashSwapActive.selector);
        cb.requestSettle(id);
    }

    function test_thirdPartyCannotSellForTheCaller() public {
        uint256 id = _post();
        vm.prank(caller);
        IERC20(t).approve(address(router), type(uint256).max);
        // a router call sent by someone else's tx
        vm.prank(address(router), reporter);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        pad.sellFor(caller, t, 1, 0);
        vm.prank(reporter);
        vm.expectRevert(IGangCallBond.NotViolated.selector);
        cb.report(id);
    }

    // ---------------------------------------------------------------- burns
    function test_burnRemainder() public {
        uint256 id = _reported();
        uint256 pool = cb.bondOf(id).pool;
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        (bytes32 root, bytes32[] memory p1, bytes32[] memory p2) = _tree(id, 0.1 ether, 0.2 ether);
        _postRoot(id, root, 0.3 ether);
        vm.expectRevert(IGangCallBond.NotClaimable.selector);
        cb.burnRemainder(id);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        cb.claim(id, f1, 0.1 ether, p1);
        uint256 d0 = wbnb.balanceOf(DEAD);
        cb.burnRemainder(id);
        assertEq(wbnb.balanceOf(DEAD) - d0, pool - 0.3 ether);
        vm.expectRevert(IGangCallBond.AlreadyBurned.selector);
        cb.burnRemainder(id);
        // the other leaf is still payable after the remainder burn
        cb.claim(id, f2, 0.2 ether, p2);
        assertEq(wbnb.balanceOf(address(cb)), 0);
    }

    function test_burnUnpaid_noRoot() public {
        uint256 id = _reported();
        uint256 pool = cb.bondOf(id).pool;
        vm.expectRevert(IGangCallBond.StillPayable.selector);
        cb.burnUnpaid(id);
        vm.warp(vm.getBlockTimestamp() + 28 days);
        uint256 d0 = wbnb.balanceOf(DEAD);
        cb.burnUnpaid(id);
        assertEq(wbnb.balanceOf(DEAD) - d0, pool);
        assertEq(uint8(cb.bondOf(id).state), uint8(IGangCallBond.State.Closed));
        vm.expectRevert(IGangCallBond.NotReported.selector);
        cb.burnUnpaid(id);
    }

    function test_burnUnpaid_pendingRootBlocks() public {
        uint256 id = _reported();
        uint256 r = vm.getBlockTimestamp();
        (bytes32 root, bytes32[] memory p1, bytes32[] memory p2) = _tree(id, 0.1 ether, 0.2 ether);
        vm.warp(r + 27 days + 23 hours);
        _postRoot(id, root, 0.3 ether);
        vm.warp(r + 29 days);
        vm.expectRevert(IGangCallBond.StillPayable.selector);
        cb.burnUnpaid(id);
        // the root becomes claimable: still payable for the claim window
        vm.warp(r + 30 days);
        vm.expectRevert(IGangCallBond.StillPayable.selector);
        cb.burnUnpaid(id);
        cb.claim(id, f1, 0.1 ether, p1);
        vm.warp(r + 27 days + 23 hours + 2 days + 90 days);
        vm.expectRevert(IGangCallBond.NotClaimable.selector);
        cb.claim(id, f2, 0.2 ether, p2);
        uint256 left = wbnb.balanceOf(address(cb));
        uint256 d0 = wbnb.balanceOf(DEAD);
        cb.burnUnpaid(id);
        assertEq(wbnb.balanceOf(DEAD) - d0, left);
        assertEq(wbnb.balanceOf(address(cb)), 0);
    }

    function test_nothingEverReturnsToTheCallerAfterReport() public {
        uint256 id = _reported();
        uint256 afterSell = wbnb.balanceOf(caller);
        vm.warp(vm.getBlockTimestamp() + 28 days);
        cb.burnUnpaid(id);
        assertEq(wbnb.balanceOf(caller), afterSell);
        assertEq(wbnb.balanceOf(address(cb)), 0);
        assertEq(wbnb.balanceOf(DEAD), BOND - BOND / 100);
    }

    function test_zeroTotalRoot_refusesEveryLeaf() public {
        uint256 id = _reported();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        (bytes32 root, bytes32[] memory p1,) = _tree(id, 0.1 ether, 0.2 ether);
        _postRoot(id, root, 0);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(IGangCallBond.OverTotal.selector);
        cb.claim(id, f1, 0.1 ether, p1);
    }
}
