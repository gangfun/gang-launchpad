// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3GradStore} from "../../src/gang/Pad3GradStore.sol";
import {Pad3GradModule} from "../../src/gang/Pad3GradModule.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangPromote} from "../../src/gang/interfaces/IGangPromote.sol";
import {IGangGradReward, IGangGradRewardBase} from "../../src/gang/interfaces/IGangGradReward.sol";
import {GangFixture} from "../utils/GangFixture.sol";

/// @dev GangHandlerAdmin's `moduleOf`, set by hand.
contract MockModuleAdmin {
    mapping(address => address) public moduleOf;

    function set(address module, address factory) external {
        moduleOf[module] = factory;
    }
}

/// @dev The countdown module's carry entry: pulls exactly `amount` (or refuses, or burns all gas, on demand). Its
///      `rewardToken` is the pad's newest token unless set (the test can't know the token's address before create).
contract MockCountdown {
    GangLaunchpad internal immutable _pad;
    address public rewardQuote;
    address internal _token;
    uint8 public mode; // 0 pull, 1 revert, 2 burn gas, 3 pull half
    uint256 public received;

    constructor(GangLaunchpad pad_, address quote_) {
        _pad = pad_;
        rewardQuote = quote_;
    }

    function setToken(address t) external {
        _token = t;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function setQuote(address q) external {
        rewardQuote = q;
    }

    function rewardToken() external view returns (address) {
        if (_token != address(0)) return _token;
        return _pad.allTokens(_pad.tokenCount() - 1);
    }

    function receiveCarry(uint256 amount) external {
        if (mode == 1) revert("no");
        if (mode == 2) {
            while (true) {}
        }
        if (mode == 3) amount /= 2;
        IERC20(rewardQuote).transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}

/// @notice 冲毕业奖励 (docs/SPEC-GRAD-REWARD-2026-11-17.md) on GangLaunchpad 3.0: the seed pulled at create, the last
///         `entries` counted buys, a curve sell disqualifying by order, the pool booked at graduation and claimed,
///         the carry to the countdown module the pad derives itself, the refund behind a 7-day notice.
contract Pad3GradRewardTest is GangFixture {
    uint256 internal constant BPS = 10_000;
    uint128 internal constant SEED = 1 ether;
    uint96 internal constant MIN_BUY = 0.1 ether;
    uint16 internal constant LAST = 3_000;
    uint32 internal constant REFUND_AFTER = 90 days;
    uint16 internal constant TAX = 300;

    GangLaunchpad3 internal pad3;
    Pad3Module internal pm;
    MockModuleAdmin internal admin;
    IGangGradReward internal gr;
    address internal countdownFactory = makeAddr("countdownFactory");
    address internal creator;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(address(this));
        pad3 = GangLaunchpad3(payable(address(pad)));
        pm = Pad3Module(payable(address(pad)));
        admin = new MockModuleAdmin();
        gr = IGangGradReward(address(pad));
        vm.startPrank(owner);
        pm.setGradReward(true, address(admin), countdownFactory);
        // exact amounts per buy (the 1% cap would cut them)
        pad.setWalletCapEnabled(false);
        vm.stopPrank();
        creator = _newAgent();
    }

    // ---------------------------------------------------------------- helpers
    function _cfg(uint8 entries, uint16 carryBps) internal pure returns (IGangGradRewardBase.GradConfig memory) {
        return IGangGradRewardBase.GradConfig({
            seed: SEED,
            minBuy: MIN_BUY,
            entries: entries,
            lastBps: LAST,
            carryBps: carryBps,
            refundAfter: REFUND_AFTER,
            promoteBps: 0,
            promoteWindow: 0
        });
    }

    function _create(IGangGradRewardBase.GradConfig memory c, IGangLaunchpad.TaxConfig memory tax)
        internal
        returns (address t)
    {
        vm.prank(creator);
        t = pm.createWithGradReward("G", "G", "l", "m", address(wbnb), address(0), tax, 9 ether, c);
    }

    function _create(uint8 entries) internal returns (address t) {
        t = _create(_cfg(entries, 0), _tax(0, 0, 0, address(0)));
    }

    function _countdown() internal returns (MockCountdown m) {
        m = new MockCountdown(pad, address(wbnb));
        admin.set(address(m), countdownFactory);
        vm.prank(owner);
        handler.list(address(m), "countdown");
    }

    function _buy(address t, address who, uint256 amount) internal {
        vm.prank(who, who);
        pad.buy(t, amount, 0);
    }

    function _sell(address t, address who, uint256 amount) internal {
        vm.startPrank(who, who);
        IERC20(t).approve(address(pad), amount);
        pad.sell(t, amount, 0);
        vm.stopPrank();
    }

    function _claim(address t, address who) internal returns (uint256 got) {
        uint256 before = wbnb.balanceOf(who);
        vm.prank(who);
        gr.claimGradReward(t);
        got = wbnb.balanceOf(who) - before;
    }

    function _state(address t) internal view returns (uint8) {
        return gr.gradReward(t).state;
    }

    // ---------------------------------------------------------------- create
    function test_create_pullsSeedAndRecords() public {
        uint256 before = wbnb.balanceOf(creator);
        uint256 padBefore = wbnb.balanceOf(address(pad));
        address t = _create(10);
        assertEq(before - wbnb.balanceOf(creator), SEED);
        assertEq(wbnb.balanceOf(address(pad)) - padBefore, SEED);
        IGangGradRewardBase.GradView memory v = gr.gradReward(t);
        assertEq(v.state, 1);
        assertEq(v.pot, SEED);
        assertEq(v.minBuy, MIN_BUY);
        assertEq(v.entries, 10);
        assertEq(v.lastBps, LAST);
        assertEq(v.refundAfter, REFUND_AFTER);
        assertEq(v.createdAt, block.timestamp);
        assertEq(v.countdown, address(0));
        assertEq(pad.kindOf(t), 1);
        assertEq(pad.gradTargetOf(t), 9 ether);
    }

    function test_create_bounds() public {
        IGangGradRewardBase.GradConfig[9] memory bad;
        for (uint256 i; i < 9; i++) {
            bad[i] = _cfg(10, 0);
        }
        bad[0].seed = 0;
        bad[1].minBuy = 0;
        bad[2].entries = 0;
        bad[3].entries = 21;
        bad[4].lastBps = 5_001;
        bad[5].carryBps = 5_001;
        bad[6].refundAfter = 30 days - 1;
        bad[7].refundAfter = 180 days + 1;
        bad[8].refundAfter = 0;
        for (uint256 i; i < 9; i++) {
            vm.prank(creator);
            vm.expectRevert(IGangGradRewardBase.BadGradConfig.selector);
            pm.createWithGradReward(
                "G", "G", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, bad[i]
            );
        }
        // edges accepted
        IGangGradRewardBase.GradConfig memory ok = _cfg(20, 0);
        ok.lastBps = 5_000;
        ok.refundAfter = 30 days;
        _create(ok, _tax(0, 0, 0, address(0)));
        ok = _cfg(1, 0);
        ok.refundAfter = 180 days;
        _create(ok, _tax(0, 0, 0, address(0)));
    }

    function test_create_closedAndCarryNeedsCountdown() public {
        // carry > 0 without a countdown module recipient
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.BadCountdown.selector);
        pm.createWithGradReward(
            "G", "G", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, _cfg(10, 2_000)
        );
        // a listed recipient that is not the factory's module: not a countdown either
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.BadCountdown.selector);
        pm.createWithGradReward(
            "G", "G", "l", "m", address(wbnb), address(0), _tax(TAX, TAX, 0, treasury), 9 ether, _cfg(10, 2_000)
        );
        // the creator itself as recipient (its own wallet): refused too
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.BadCountdown.selector);
        pm.createWithGradReward(
            "G", "G", "l", "m", address(wbnb), address(0), _tax(TAX, TAX, 0, creator), 9 ether, _cfg(10, 2_000)
        );

        vm.prank(owner);
        pm.setGradReward(false, address(admin), countdownFactory);
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.GradNotOpen.selector);
        pm.createWithGradReward(
            "G", "G", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, _cfg(10, 0)
        );

        vm.prank(creator);
        vm.expectRevert(); // Ownable
        pm.setGradReward(true, address(admin), countdownFactory);
    }

    function test_create_countdownMustBeForThisToken() public {
        MockCountdown m = _countdown();
        m.setToken(makeAddr("otherToken"));
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.BadCountdown.selector);
        pm.createWithGradReward(
            "G", "G", "l", "m", address(wbnb), address(0), _tax(TAX, TAX, 0, address(m)), 9 ether, _cfg(10, 2_000)
        );
        m.setToken(address(0));
        m.setQuote(address(quoteTok));
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.BadCountdown.selector);
        pm.createWithGradReward(
            "G", "G", "l", "m", address(wbnb), address(0), _tax(TAX, TAX, 0, address(m)), 9 ether, _cfg(10, 2_000)
        );
        m.setQuote(address(wbnb));
        address t = _create(_cfg(10, 2_000), _tax(TAX, TAX, 0, address(m)));
        assertEq(gr.gradReward(t).countdown, address(m));
    }

    function test_create_withPromote() public {
        IGangGradRewardBase.GradConfig memory c = _cfg(10, 0);
        c.promoteBps = 2_000;
        c.promoteWindow = 30 days;
        address t = _create(c, _tax(0, 0, 0, address(0)));
        (uint16 s, uint32 w) = pm.promoteOf(t);
        assertEq(s, 2_000);
        assertEq(w, 30 days);
        c.promoteWindow = 0;
        vm.prank(creator);
        vm.expectRevert(IGangPromote.BadPromoteTerms.selector);
        pm.createWithGradReward("G", "G", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, c);
    }

    function test_create_seedInOtherQuote() public {
        uint256 before = quoteTok.balanceOf(creator);
        vm.prank(creator);
        address t = pm.createWithGradReward(
            "G", "G", "l", "m", address(quoteTok), address(0), _tax(0, 0, 0, address(0)), 9 ether, _cfg(10, 0)
        );
        assertEq(before - quoteTok.balanceOf(creator), SEED);
        assertEq(gr.gradReward(t).pot, SEED);
    }

    // ---------------------------------------------------------------- entries
    function test_entries_minBuyAndOrder() public {
        address t = _create(5);
        address a = _newAgent();
        address b = _newAgent();
        _buy(t, a, 0.05 ether); // below minBuy: not counted
        assertEq(gr.gradReward(t).seq, 0);
        _buy(t, b, 0.1 ether); // exactly minBuy
        _buy(t, a, 0.2 ether);
        (address[] memory buyers, uint64[] memory seqs,, bool[] memory valid) = gr.gradEntries(t);
        assertEq(buyers.length, 2);
        assertEq(buyers[0], a);
        assertEq(seqs[0], 2);
        assertEq(buyers[1], b);
        assertTrue(valid[0] && valid[1]);
    }

    function test_entries_ringKeepsLastN() public {
        address t = _create(3);
        address[5] memory w;
        for (uint256 i; i < 5; i++) {
            w[i] = _newAgent();
            _buy(t, w[i], 0.2 ether);
        }
        (address[] memory buyers, uint64[] memory seqs,,) = gr.gradEntries(t);
        assertEq(buyers.length, 3);
        assertEq(buyers[0], w[4]);
        assertEq(buyers[1], w[3]);
        assertEq(buyers[2], w[2]);
        assertEq(seqs[2], 3);
    }

    function test_entries_sellDisqualifiesEarlierOnly() public {
        address t = _create(10);
        address a = _newAgent();
        address b = _newAgent();
        _buy(t, a, 0.5 ether); // seq 1
        _buy(t, b, 0.5 ether); // seq 2
        _sell(t, a, IERC20(t).balanceOf(a) / 10);
        (,,, bool[] memory valid) = gr.gradEntries(t);
        assertTrue(valid[0]); // b
        assertFalse(valid[1]); // a
        _buy(t, a, 0.5 ether); // seq 3: a's new entry counts again
        (address[] memory buyers,,, bool[] memory v2) = gr.gradEntries(t);
        assertEq(buyers[0], a);
        assertTrue(v2[0]);
        assertFalse(v2[2]);
        // a sell before any entry writes nothing
        address c = _newAgent();
        address t2 = _create(10);
        _buy(t2, c, 0.05 ether);
        _sell(t2, c, IERC20(t2).balanceOf(c));
        assertEq(gr.gradReward(t2).seq, 0);
    }

    function test_entries_gateOffNotCounted() public {
        address t = _create(10);
        address a = _newAgent();
        vm.prank(owner);
        pad.setAgentGate(false, address(agents));
        _buy(t, a, 0.5 ether);
        assertEq(gr.gradReward(t).seq, 0);
        vm.prank(owner);
        pad.setAgentGate(true, address(agents));
        _buy(t, a, 0.5 ether);
        assertEq(gr.gradReward(t).seq, 1);
    }

    function test_entries_plainTokenUntouched() public {
        address t = _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        _buy(t, _newAgent(), 0.5 ether);
        assertEq(gr.gradReward(t).seq, 0);
        assertEq(gr.gradReward(t).state, 0);
        _graduate(t);
        assertEq(gr.gradReward(t).state, 0);
    }

    // ---------------------------------------------------------------- graduation and claims
    /// @dev a, b, c, d buy; b sells; e graduates with a buy below minBuy (counted: it graduates the token).
    function _scenario(address t) internal returns (address a, address b, address c, address d, address e) {
        a = _newAgent();
        b = _newAgent();
        c = _newAgent();
        d = _newAgent();
        e = _newAgent();
        _buy(t, a, 3 ether); // seq 1
        _buy(t, b, 3 ether); // seq 2
        _buy(t, c, 2.5 ether); // seq 3
        _sell(t, b, IERC20(t).balanceOf(b) / 2);
        // leave a little to graduate on
        (,,,, uint256 remaining) = pad3.getTokenInfo(t);
        uint256 dBuy = ((remaining - 0.05 ether) * BPS) / (BPS - 100);
        _buy(t, d, dBuy); // seq 4
        assertFalse(_graduated(t));
        _buy(t, e, 1 ether); // seq 5: graduates, spends ~0.05
        assertTrue(_graduated(t));
    }

    function test_graduation_bookAndClaim() public {
        address t = _create(10);
        (address a, address b, address c, address d, address e) = _scenario(t);
        IGangGradRewardBase.GradView memory v = gr.gradReward(t);
        assertEq(v.state, 2);
        assertEq(v.seq, 5);
        assertEq(v.gradAt, block.timestamp);
        // valid: a, c, d, e (b sold after its buy); e, the last, gets 30% on top; all four split 70% by what each spent
        assertEq(gr.gradClaimable(t, b), 0);
        (,, uint96[] memory spent,) = gr.gradEntries(t); // newest first: e, d, c, b, a
        assertEq(spent[4], 3 ether);
        assertEq(spent[2], 2.5 ether);
        uint256 rs = 3 ether + 2.5 ether + uint256(spent[1]) + uint256(spent[0]);
        uint256 lastShare = (uint256(SEED) * LAST) / BPS;
        uint256 restPay = SEED - lastShare;
        uint256 sa = (restPay * 3 ether) / rs;
        uint256 sc = (restPay * 2.5 ether) / rs;
        uint256 sd = (restPay * spent[1]) / rs;
        uint256 se = lastShare + (restPay * spent[0]) / rs;
        assertEq(gr.gradClaimable(t, e), se);
        assertEq(gr.gradClaimable(t, a), sa);
        assertEq(_claim(t, e), se);
        assertEq(_claim(t, a), sa);
        assertEq(_claim(t, c), sc);
        assertEq(_claim(t, d), sd);
        assertGt(sa, sc); // 3 BNB spent earns more than 2.5
        vm.prank(b);
        vm.expectRevert(IGangGradRewardBase.NothingToClaim.selector);
        gr.claimGradReward(t);
        vm.prank(a);
        vm.expectRevert(IGangGradRewardBase.AlreadyClaimed.selector);
        gr.claimGradReward(t);
        assertEq(gr.gradClaimable(t, a), 0);
        v = gr.gradReward(t);
        assertTrue(v.settled);
        assertEq(v.valid, 4);
        assertEq(v.claimed, se + sa + sc + sd);
        assertEq(v.validSpent, rs);

        // sweep: not before 180 days; then the dust to the dev, and closed
        vm.expectRevert(IGangGradRewardBase.SweepNotDue.selector);
        gr.sweepGradReward(t);
        vm.warp(block.timestamp + 180 days);
        uint256 devBefore = wbnb.balanceOf(creator);
        gr.sweepGradReward(t);
        assertEq(wbnb.balanceOf(creator) - devBefore, SEED - se - sa - sc - sd);
        assertEq(_state(t), 4);
        vm.expectRevert(IGangGradRewardBase.NotGradState.selector);
        gr.sweepGradReward(t);
    }

    function test_graduation_walletWithSeveralEntriesAddsUp() public {
        address t = _create(10);
        address a = _newAgent();
        address e = _newAgent();
        _buy(t, a, 3 ether);
        _buy(t, a, 3 ether);
        _buy(t, e, 1 ether);
        _buy(t, a, 10 ether); // graduates: a is last too
        assertTrue(_graduated(t));
        (,, uint96[] memory spent,) = gr.gradEntries(t);
        uint256 vs = 7 ether + uint256(spent[0]);
        uint256 lastShare = (uint256(SEED) * LAST) / BPS;
        uint256 restPay = SEED - lastShare;
        // the rest by spend, the graduating buy included
        assertEq(
            _claim(t, a), lastShare + (restPay * spent[0]) / vs + (restPay * 3 ether) / vs + (restPay * 3 ether) / vs
        );
        assertEq(_claim(t, e), (restPay * 1 ether) / vs);
    }

    /// @dev Many minimum entries don't out-earn one large one: the rest of the payout follows what each spent.
    function test_graduation_weightedBySpend() public {
        address t = _create(7); // 8 entries: the first falls out
        address whale = _newAgent();
        address farmer = _newAgent();
        _buy(t, _newAgent(), 4 ether); // falls out of the list
        _buy(t, whale, 2 ether);
        for (uint256 i; i < 5; i++) {
            _buy(t, farmer, MIN_BUY); // 5 entries of 0.1
        }
        address last = _newAgent();
        _buy(t, last, 20 ether); // graduates
        assertTrue(_graduated(t));
        (,, uint96[] memory spent,) = gr.gradEntries(t);
        uint256 vs = 2.5 ether + uint256(spent[0]);
        uint256 lastShare = (uint256(SEED) * LAST) / BPS;
        uint256 restPay = SEED - lastShare;
        // whale 2.0 vs farmer 5 × 0.1 = 0.5: 4 to 1 (by an equal split the farmer would get 5 of 6)
        uint256 w = _claim(t, whale);
        uint256 f = _claim(t, farmer);
        assertEq(w, (restPay * 2 ether) / vs);
        assertEq(f, 5 * ((restPay * MIN_BUY) / vs));
        assertGt(w, 3 * f);
        uint256 l = _claim(t, last);
        assertEq(l, lastShare + (restPay * spent[0]) / vs);
        assertLe(w + f + l, SEED);
    }

    function test_graduation_onlyNewestNShare() public {
        address t = _create(2);
        (address a,, address c, address d, address e) = _scenario(t);
        // list: d (4), e (5)
        assertEq(gr.gradClaimable(t, a), 0);
        assertEq(gr.gradClaimable(t, c), 0);
        (,, uint96[] memory spent,) = gr.gradEntries(t); // e, d
        uint256 vs = uint256(spent[0]) + spent[1];
        uint256 lastShare = (uint256(SEED) * LAST) / BPS;
        uint256 restPay = SEED - lastShare;
        assertEq(_claim(t, e), lastShare + (restPay * spent[0]) / vs);
        assertEq(_claim(t, d), (restPay * spent[1]) / vs);
    }

    function test_graduation_singleEntryTakesAll() public {
        address t = _create(1);
        (,,,, address e) = _scenario(t);
        assertEq(_claim(t, e), SEED);
    }

    function test_graduation_noValidEntryBackToDev() public {
        address t = _create(10);
        address a = _newAgent();
        vm.prank(owner);
        pad.setAgentGate(false, address(agents));
        _buy(t, a, 20 ether);
        assertTrue(_graduated(t));
        assertEq(gr.gradReward(t).seq, 0);
        uint256 devBefore = wbnb.balanceOf(creator);
        // the claim reverts (and so leaves it as it was); settling closes it and pays the dev
        vm.prank(a);
        vm.expectRevert(IGangGradRewardBase.NotGradState.selector);
        gr.claimGradReward(t);
        gr.settleGradReward(t);
        assertEq(wbnb.balanceOf(creator) - devBefore, SEED);
        assertEq(_state(t), 4);
    }

    function test_graduation_gasOfGraduatingBuy() public {
        address t = _create(20);
        for (uint256 i; i < 19; i++) {
            _buy(t, _newAgent(), 0.4 ether);
        }
        address e = _newAgent();
        vm.prank(e, e);
        uint256 g = gasleft();
        pad.buy(t, 10 ether, 0);
        g -= gasleft();
        assertTrue(_graduated(t));
        emit log_named_uint("graduating buy gas (20 entries)", g);
        // claim of the newest (counts 20 entries once)
        vm.prank(e);
        g = gasleft();
        gr.claimGradReward(t);
        emit log_named_uint("first claim gas (settles)", g - gasleft());
    }

    // ---------------------------------------------------------------- carry
    function test_carry_sentAtGraduation() public {
        MockCountdown m = _countdown();
        address t = _create(_cfg(10, 2_000), _tax(TAX, TAX, 0, address(m)));
        (,,,, address e) = _scenario(t);
        uint256 carry = (uint256(SEED) * 2_000) / BPS;
        assertEq(m.received(), carry);
        assertEq(wbnb.balanceOf(address(m)), carry);
        assertEq(wbnb.allowance(address(pad), address(m)), 0);
        uint256 pay = SEED - carry;
        uint256 got = _claim(t, e);
        assertGt(got, (pay * LAST) / BPS);
        // the sweep goes to the module too
        vm.warp(block.timestamp + 180 days);
        gr.sweepGradReward(t);
        assertEq(wbnb.balanceOf(address(m)), carry + pay - got);
    }

    function test_carry_refusedIsOwedAndRetried() public {
        MockCountdown m = _countdown();
        address t = _create(_cfg(10, 2_000), _tax(TAX, TAX, 0, address(m)));
        m.setMode(1);
        _scenario(t); // graduation does not revert
        uint256 carry = (uint256(SEED) * 2_000) / BPS;
        assertEq(gr.gradReward(t).carryOwed, carry);
        assertEq(wbnb.allowance(address(pad), address(m)), 0);
        gr.retryCarry(t); // still refused: owed again
        assertEq(gr.gradReward(t).carryOwed, carry);
        m.setMode(0);
        gr.retryCarry(t);
        assertEq(gr.gradReward(t).carryOwed, 0);
        assertEq(m.received(), carry);
        vm.expectRevert(IGangGradRewardBase.NoCarryOwed.selector);
        gr.retryCarry(t);
    }

    function test_carry_gasBurnerAndPartialPull() public {
        MockCountdown m = _countdown();
        address t = _create(_cfg(10, 2_000), _tax(TAX, TAX, 0, address(m)));
        m.setMode(2);
        _scenario(t);
        uint256 carry = (uint256(SEED) * 2_000) / BPS;
        assertEq(gr.gradReward(t).carryOwed, carry);
        m.setMode(3);
        gr.retryCarry(t);
        assertEq(gr.gradReward(t).carryOwed, carry - carry / 2);
        assertEq(wbnb.allowance(address(pad), address(m)), 0);
    }

    // ---------------------------------------------------------------- refund
    function test_refund_noticeThenRefund() public {
        address t = _create(10);
        address a = _newAgent();
        _buy(t, a, 1 ether);
        vm.expectRevert(IGangLaunchpad.NotCreator.selector);
        vm.prank(a);
        gr.requestGradRefund(t);
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.RefundNotDue.selector);
        gr.requestGradRefund(t);
        vm.warp(block.timestamp + REFUND_AFTER);
        vm.prank(creator);
        gr.requestGradRefund(t);
        assertEq(gr.gradReward(t).refundAt, block.timestamp);
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.RefundNotDue.selector);
        gr.requestGradRefund(t); // already asked
        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.RefundNotDue.selector);
        gr.gradRefund(t);
        vm.warp(block.timestamp + 1);
        uint256 before = wbnb.balanceOf(creator);
        vm.prank(creator);
        gr.gradRefund(t);
        assertEq(wbnb.balanceOf(creator) - before, SEED);
        assertEq(_state(t), 3);
        // the token graduates later: nothing booked, nothing to claim
        _buy(t, _newAgent(), 20 ether);
        assertTrue(_graduated(t));
        assertEq(_state(t), 3);
        vm.prank(a);
        vm.expectRevert(IGangGradRewardBase.NotGradState.selector);
        gr.claimGradReward(t);
    }

    function test_refund_graduationDuringNoticePays() public {
        address t = _create(10);
        vm.warp(block.timestamp + REFUND_AFTER);
        vm.prank(creator);
        gr.requestGradRefund(t);
        (,,,, address e) = _scenario(t);
        IGangGradRewardBase.GradView memory v = gr.gradReward(t);
        assertEq(v.state, 2);
        assertEq(v.refundAt, 0);
        vm.warp(block.timestamp + 7 days);
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.NotGradState.selector);
        gr.gradRefund(t);
        assertGt(_claim(t, e), 0);
    }

    function test_refund_cancel() public {
        address t = _create(10);
        vm.warp(block.timestamp + REFUND_AFTER);
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.RefundNotDue.selector);
        gr.cancelGradRefund(t);
        vm.prank(creator);
        gr.requestGradRefund(t);
        vm.prank(creator);
        gr.cancelGradRefund(t);
        vm.warp(block.timestamp + 7 days);
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.RefundNotDue.selector);
        gr.gradRefund(t);
    }

    // ---------------------------------------------------------------- accounting and layout
    function test_padHoldsEverything() public {
        address t = _create(10);
        address t2 = _create(3);
        _scenario(t);
        _buy(t2, _newAgent(), 1 ether);
        // t2's seed and curve funds stay; t's pool stays until claimed
        uint256 owedT = SEED; // nothing claimed yet
        uint256 rq2 = _curveRealQuote(t2);
        assertGe(wbnb.balanceOf(address(pad)), owedT + SEED + rq2 + pad.creatorFeeOf(t) + pad.creatorFeeOf(t2));
    }

    function test_slotPinned() public pure {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("gang.pad3.gradreward")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(Pad3GradStore.SLOT, slot);
    }

    // ---------------------------------------------------------------- review follow-ups
    function test_refund_requestLapses() public {
        address t = _create(10);
        vm.warp(block.timestamp + REFUND_AFTER);
        vm.prank(creator);
        gr.requestGradRefund(t);
        // past notice + window: lapsed, can't refund; must ask again (a fresh 7-day notice)
        vm.warp(block.timestamp + 10 days);
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.RefundNotDue.selector);
        gr.gradRefund(t);
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.RefundNotDue.selector);
        gr.cancelGradRefund(t);
        vm.prank(creator);
        gr.requestGradRefund(t);
        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.RefundNotDue.selector);
        gr.gradRefund(t);
        vm.warp(block.timestamp + 3 days); // last second of the window
        vm.prank(creator);
        gr.gradRefund(t);
        assertEq(_state(t), 3);
        assertEq(gr.gradReward(t).pot, 0);
    }

    function test_entries_otherBuyAndSellPaths() public {
        address t = _create(10);
        address a = _newAgent();
        address b = _newAgent();
        // the aggregator entry (native BNB), the promoter buy
        vm.prank(a, a);
        pad3.buyTokenAMAP{value: 0.5 ether}(t, a, 0.5 ether, 0);
        vm.prank(b, b);
        IGangPromote(address(pad)).buyWithPromoter{value: 0.5 ether}(t, 0.5 ether, 0, address(0));
        (address[] memory buyers,,, bool[] memory valid) = gr.gradEntries(t);
        assertEq(buyers.length, 2);
        assertEq(buyers[0], b);
        assertEq(buyers[1], a);
        assertTrue(valid[0] && valid[1]);
        // the aggregator sell disqualifies
        uint256 amt = IERC20(t).balanceOf(a) / 4;
        vm.startPrank(a, a);
        IERC20(t).approve(address(pad), amt);
        pad3.sellToken(0, t, a, amt, 0, 0, address(0));
        vm.stopPrank();
        (,,, valid) = gr.gradEntries(t);
        assertTrue(valid[0]);
        assertFalse(valid[1]);
    }

    function test_graduation_gateOffLastGoesToNewestValid() public {
        address t = _create(10);
        address a = _newAgent();
        address b = _newAgent();
        _buy(t, a, 3 ether); // seq 1
        _buy(t, b, 3 ether); // seq 2
        _sell(t, b, IERC20(t).balanceOf(b) / 2);
        vm.prank(owner);
        pad.setAgentGate(false, address(agents));
        _buy(t, _newAgent(), 20 ether); // graduates, not counted
        assertTrue(_graduated(t));
        // only a is valid: it takes the whole payout
        assertEq(gr.gradClaimable(t, a), SEED);
        assertEq(gr.gradClaimable(t, b), 0);
        assertEq(_claim(t, a), SEED);
    }

    function test_claimable_matchesClaimBeforeAndAfterSettle() public {
        address t = _create(10);
        (address a,, address c,, address e) = _scenario(t);
        uint256 ca = gr.gradClaimable(t, a);
        uint256 ce = gr.gradClaimable(t, e);
        assertEq(_claim(t, a), ca);
        assertEq(gr.gradClaimable(t, e), ce);
        assertEq(_claim(t, e), ce);
        uint256 cc = gr.gradClaimable(t, c);
        assertEq(_claim(t, c), cc);
        // closed after the sweep: no more claims
        vm.warp(block.timestamp + 180 days);
        gr.sweepGradReward(t);
        assertEq(gr.gradClaimable(t, a), 0);
    }

    function test_sweep_carryRefusedIsOwed() public {
        MockCountdown m = _countdown();
        address t = _create(_cfg(10, 2_000), _tax(TAX, TAX, 0, address(m)));
        _scenario(t);
        m.setMode(1);
        vm.warp(block.timestamp + 180 days);
        gr.sweepGradReward(t);
        uint256 carry = (uint256(SEED) * 2_000) / BPS;
        assertEq(gr.gradReward(t).carryOwed, SEED - carry);
        m.setMode(0);
        gr.retryCarry(t);
        assertEq(m.received(), SEED);
    }

    function test_gradModuleWiring() public {
        address gm = Pad3Module(payable(pad3.module())).gradModule();
        assertTrue(gm != address(0));
        assertEq(Pad3GradModule(gm).GRAD_REFUND_NOTICE(), 7 days);
        // the module's own storage is never used: a direct call sees no token
        vm.expectRevert(IGangGradRewardBase.NotGradState.selector);
        Pad3GradModule(gm).settleGradReward(address(1));
        // every view answers through the pad
        (bool open, address a, address f) = gr.gradRewardDeps();
        assertTrue(open);
        assertEq(a, address(admin));
        assertEq(f, countdownFactory);
    }

    function test_storageWordsPinned() public {
        address t = _create(_cfg(7, 0), _tax(0, 0, 0, address(0)));
        _buy(t, _newAgent(), 0.5 ether);
        bytes32 base = keccak256(abi.encode(t, uint256(Pad3GradStore.SLOT) + 2)); // rewardOf, after open|admin, factory
        uint256 w0 = uint256(vm.load(address(pad), base));
        assertEq(uint8(w0), 1, "state");
        assertEq(uint8(w0 >> 8), 7, "entries");
        assertEq(uint16(w0 >> 16), LAST, "lastBps");
        assertEq(uint32(w0 >> 48), REFUND_AFTER, "refundAfter");
        assertEq(uint64(w0 >> 160), 1, "seq");
        uint256 w1 = uint256(vm.load(address(pad), bytes32(uint256(base) + 1)));
        assertEq(uint128(w1), SEED, "pot");
        assertEq(uint96(w1 >> 128), MIN_BUY, "minBuy");
        // the layout's first words: open | handlerAdmin, then countdownFactory
        uint256 l0 = uint256(vm.load(address(pad), Pad3GradStore.SLOT));
        assertEq(uint8(l0), 1, "open");
        assertEq(address(uint160(l0 >> 8)), address(admin), "handlerAdmin");
        assertEq(
            address(uint160(uint256(vm.load(address(pad), bytes32(uint256(Pad3GradStore.SLOT) + 1))))),
            countdownFactory,
            "countdownFactory"
        );
    }

    function test_storageWordsPinned_afterGraduation() public {
        MockCountdown m = _countdown();
        address t = _create(_cfg(10, 2_000), _tax(TAX, TAX, 0, address(m)));
        m.setMode(1);
        (address a, address b,,, address e) = _scenario(t);
        _claim(t, e);
        uint256 s = uint256(Pad3GradStore.SLOT);
        uint256 base = uint256(keccak256(abi.encode(t, s + 2)));
        uint256 w2 = uint256(vm.load(address(pad), bytes32(base + 2)));
        assertEq(address(uint160(w2)), address(m), "countdown");
        assertEq(uint40(w2 >> 160), block.timestamp, "gradAt");
        assertEq(uint16(w2 >> 200), 5, "validPlus1"); // 4 valid
        uint256 w3 = uint256(vm.load(address(pad), bytes32(base + 3)));
        IGangGradRewardBase.GradView memory v = gr.gradReward(t);
        assertEq(uint128(w3), v.claimed, "claimed");
        assertEq(uint128(w3 >> 128), v.carryOwed, "carryOwed");
        assertEq(uint64(uint256(vm.load(address(pad), bytes32(base + 4)))), 5, "lastSeq");
        // ringOf (seq 1 = a in slot 0), sellSeqOf (b sold after seq 3), claimedBy (e)
        uint256 ring = uint256(keccak256(abi.encode(t, s + 3)));
        assertEq(address(uint160(uint256(vm.load(address(pad), bytes32(ring))))), a, "ring[0]");
        bytes32 sold = keccak256(abi.encode(b, keccak256(abi.encode(t, s + 4))));
        assertEq(uint256(vm.load(address(pad), sold)), 3, "sellSeqOf");
        bytes32 claimed = keccak256(abi.encode(e, keccak256(abi.encode(t, s + 5))));
        assertEq(uint256(vm.load(address(pad), claimed)), 1, "claimedBy");
    }

    function test_carry_lowGasRevertsWhole() public {
        MockCountdown m = _countdown();
        address t = _create(_cfg(10, 2_000), _tax(TAX, TAX, 0, address(m)));
        m.setMode(1);
        _scenario(t); // owed
        uint256 owed = gr.gradReward(t).carryOwed;
        assertGt(owed, 0);
        m.setMode(0);
        // too little gas for the module's 300k: the whole call reverts with CarryGasLow, the debt stays
        (bool ok, bytes memory ret) = address(pad).call{gas: 380_000}(abi.encodeCall(gr.retryCarry, (t)));
        assertFalse(ok);
        assertEq(bytes4(ret), IGangGradRewardBase.CarryGasLow.selector);
        assertEq(gr.gradReward(t).carryOwed, owed);
        (ok,) = address(pad).call{gas: 600_000}(abi.encodeCall(gr.retryCarry, (t)));
        assertTrue(ok);
        assertEq(gr.gradReward(t).carryOwed, 0);
        assertEq(m.received(), owed);
    }

    function test_refund_pendingFlag() public {
        address t = _create(10);
        vm.warp(block.timestamp + REFUND_AFTER);
        assertFalse(gr.gradReward(t).refundPending);
        vm.prank(creator);
        gr.requestGradRefund(t);
        assertTrue(gr.gradReward(t).refundPending);
        vm.warp(block.timestamp + 10 days);
        assertFalse(gr.gradReward(t).refundPending);
    }

    /// @dev lastBps 0: the graduating buy still gets its spend's part (it is weighted like the others).
    function test_graduation_lastBpsZeroStillPaysGraduatingBuy() public {
        IGangGradRewardBase.GradConfig memory c = _cfg(10, 0);
        c.lastBps = 0;
        address t = _create(c, _tax(0, 0, 0, address(0)));
        address a = _newAgent();
        address e = _newAgent();
        _buy(t, a, 3 ether);
        _buy(t, e, 20 ether); // graduates
        (,, uint96[] memory spent,) = gr.gradEntries(t);
        uint256 vs = 3 ether + uint256(spent[0]);
        assertEq(_claim(t, e), (uint256(SEED) * spent[0]) / vs);
        assertEq(_claim(t, a), (uint256(SEED) * 3 ether) / vs);
    }

    /// @dev Splitting the graduating push into a large buy and a tiny graduating one earns the same as one buy
    ///      (up to rounding): every entry is weighted by spend, the newest too.
    function test_graduation_splittingThePushGainsNothing() public {
        address t1 = _create(10);
        address t2 = _create(10);
        address a1 = _newAgent();
        address a2 = _newAgent();
        address x1 = _newAgent();
        address x2 = _newAgent();
        _buy(t1, a1, 3 ether);
        _buy(t2, a2, 3 ether);
        // one push on t1
        _buy(t1, x1, 20 ether);
        // two buys on t2: all but 0.01 of what is left, then the graduating rest
        (,,,, uint256 remaining) = pad3.getTokenInfo(t2);
        _buy(t2, x2, ((remaining - 0.01 ether) * BPS) / (BPS - 100));
        _buy(t2, x2, 1 ether);
        assertTrue(_graduated(t1) && _graduated(t2));
        uint256 one = _claim(t1, x1);
        uint256 two = _claim(t2, x2);
        assertApproxEqAbs(one, two, 1e9);
    }

    function test_storageWordFourPinned() public {
        address t = _create(10);
        (address a,,,,) = _scenario(t);
        _claim(t, a);
        bytes32 base = keccak256(abi.encode(t, uint256(Pad3GradStore.SLOT) + 2));
        uint256 w4 = uint256(vm.load(address(pad), bytes32(uint256(base) + 4)));
        assertEq(uint64(w4), 5, "lastSeq");
        assertEq(uint128(w4 >> 64), gr.gradReward(t).validSpent, "validSpent");
        // ring entry: spent in the upper 96 bits
        uint256 ring = uint256(keccak256(abi.encode(t, uint256(Pad3GradStore.SLOT) + 3)));
        uint256 e0 = uint256(vm.load(address(pad), bytes32(ring)));
        assertEq(e0 >> 160, 3 ether, "a spent");
    }
}
