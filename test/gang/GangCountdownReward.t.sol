// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FloorBase} from "./GangFloorModule.t.sol";
import {GangCountdownReward} from "../../src/gang/GangCountdownReward.sol";
import {GangCountdownRewardFactory} from "../../src/gang/GangCountdownRewardFactory.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {TwapMockPairFactory} from "../mocks/TwapMockPair.sol";

/// @notice GangCountdownReward (倒计时奖励): the factory's checks, binding, buying through the module on the token's
///         own pair, rounds (counted buys, the deadline, the lazy freeze / settle, the ring of the last entries, a
///         frozen round never overwritten), the split (the last entry's extra, dust back to the pool), the pool's money
///         in (the pool tax with the dev's part, `fund` / `receiveCarry` without), `finalize` after idle, the books.
contract GangCountdownRewardTest is FloorBase {
    GangCountdownRewardFactory cf;

    uint256 constant MIN_BUY = 0.05 ether;
    uint256 constant MIN_POT = 0.1 ether;
    uint256 constant MAX_PAYOUT = 1 ether;

    /// @dev Pancake V2-like pairs: K-checked with the 0.25% fee and locked during a swap (audit 2026-11-17 L-6).
    function _newPairFactory() internal override returns (address) {
        return address(new TwapMockPairFactory());
    }

    function setUp() public {
        _deployFloor();
        cf = new GangCountdownRewardFactory(address(pad), address(admin), GANG);
        vm.prank(owner);
        admin.setFactory(address(cf), true);
    }

    function newFactory(address pad_, address admin_) external returns (GangCountdownRewardFactory) {
        return new GangCountdownRewardFactory(pad_, admin_, GANG);
    }

    function _cfg() internal pure returns (GangCountdownReward.Config memory c) {
        c = GangCountdownReward.Config({
            window: 1 hours,
            maxRound: 6 hours,
            idle: 30 days,
            payoutBps: 3_000,
            lastBps: 2_000,
            devBps: 0,
            entries: 3,
            minBuy: MIN_BUY,
            minPot: MIN_POT,
            maxPayout: MAX_PAYOUT
        });
    }

    function _module(address dev, address tok, address q, GangCountdownReward.Config memory c)
        internal
        returns (GangCountdownReward m)
    {
        vm.prank(dev);
        m = GangCountdownReward(cf.create(tok, q, c, bytes32(++_salt)));
    }

    /// @dev A taxed V3 token over `q` whose recipient is a countdown module with `c`, bound, seeded with `seed`
    ///      (from the dev), graduated when `grad`.
    function _setupCD(address q, GangCountdownReward.Config memory c, uint256 seed, bool grad)
        internal
        returns (GangCountdownReward m, address t, address dev)
    {
        dev = _newAgent();
        m = _module(dev, _nextToken(dev), q, c);
        t = _createT(dev, q, _tax(TAX, TAX, 0, address(m)));
        m.bind(t);
        if (seed != 0) {
            vm.startPrank(dev);
            IERC20(q).approve(address(m), seed);
            m.fund(seed);
            vm.stopPrank();
        }
        if (grad) _graduate(t);
    }

    function _buyer() internal returns (address who) {
        who = _newAgent();
    }

    function _buyBnb(GangCountdownReward m, address who, uint256 amount) internal returns (uint256 out) {
        vm.prank(who);
        out = m.buy{value: amount}(0, block.timestamp, false);
    }

    /// @dev Books: the quote held covers everything accounted for.
    function _assertBooks(GangCountdownReward m, address q) internal view {
        assertGe(
            _bal(q, address(m)),
            m.pot() + m.reservedTotal() + m.claimTotal() + m.devOwed(),
            "balance covers pot + reserved + claims + dev"
        );
    }

    // ---------------------------------------------------------------- factory / init / bind
    function test_factory_checks() public {
        vm.expectRevert(GangCountdownRewardFactory.ZeroAddress.selector);
        this.newFactory(address(pad), address(0));
        GangHandlerAdmin elsewhere = new GangHandlerAdmin(owner, makeAddr("otherHandler"));
        vm.expectRevert(GangCountdownRewardFactory.WrongHandler.selector);
        this.newFactory(address(pad), address(elsewhere));

        address dev = _newAgent();
        address tok = address(uint160(0x7777abcd));
        address w = address(wbnb);
        GangCountdownReward.Config memory c = _cfg();
        vm.prank(makeAddr("notAgent"));
        vm.expectRevert(GangCountdownRewardFactory.NotAgent.selector);
        cf.create(tok, w, c, bytes32(0));

        vm.startPrank(dev);
        vm.expectRevert(GangCountdownRewardFactory.BadToken.selector);
        cf.create(makeAddr("tok"), w, c, bytes32(0));
        vm.expectRevert(GangCountdownReward.BadQuote.selector);
        cf.create(tok, makeAddr("devsQuote"), c, bytes32(0));
        GangCountdownReward.Config memory bad = _cfg();
        bad.window = 29 minutes;
        vm.expectRevert(GangCountdownReward.BadConfig.selector);
        cf.create(tok, w, bad, bytes32(0));
        bad = _cfg();
        bad.lastBps = 2_001;
        vm.expectRevert(GangCountdownReward.BadConfig.selector);
        cf.create(tok, w, bad, bytes32(0));
        bad = _cfg();
        bad.maxPayout = 0;
        vm.expectRevert(GangCountdownReward.BadConfig.selector);
        cf.create(tok, w, bad, bytes32(0));
        bad = _cfg();
        bad.entries = 21;
        vm.expectRevert(GangCountdownReward.BadConfig.selector);
        cf.create(tok, w, bad, bytes32(0));
        bad = _cfg();
        bad.maxRound = 59 minutes;
        vm.expectRevert(GangCountdownReward.BadConfig.selector);
        cf.create(tok, w, bad, bytes32(0));
        bad = _cfg();
        bad.maxRound = 24 hours + 1;
        vm.expectRevert(GangCountdownReward.BadConfig.selector);
        cf.create(tok, w, bad, bytes32(0));
        bad = _cfg();
        bad.window = 2 hours;
        bad.maxRound = 1 hours; // under the window
        vm.expectRevert(GangCountdownReward.BadConfig.selector);
        cf.create(tok, w, bad, bytes32(0));
        bad = _cfg();
        bad.payoutBps = 5_001;
        vm.expectRevert(GangCountdownReward.BadConfig.selector);
        cf.create(tok, w, bad, bytes32(0));

        address m = cf.create(tok, w, c, bytes32(uint256(1)));
        vm.stopPrank();
        assertEq(m, cf.predict(dev, bytes32(uint256(1))));
        assertEq(admin.moduleOf(m), address(cf));
        assertEq(GangCountdownReward(m).moduleType(), bytes32("countdown-v1"));
        vm.expectRevert(GangCountdownReward.NotFactory.selector);
        GangCountdownReward(m).initialize(dev, tok, w, c);
    }

    function test_bind_checks() public {
        address dev = _newAgent();
        // any token other than the one fixed at clone can't be bound (made first: `_createT` plans one token at a time)
        address o = _newAgent();
        address other = _createT(o, address(wbnb), _tax(TAX, TAX, 0, o));
        GangCountdownReward m = _module(dev, _nextToken(dev), address(wbnb), _cfg());
        vm.expectRevert(GangCountdownReward.WrongToken.selector);
        m.bind(other);
        address t = _createT(dev, address(wbnb), _tax(TAX, TAX, 0, address(m)));
        m.bind(t);
        assertEq(m.token(), t);
        vm.expectRevert(GangCountdownReward.AlreadyBound.selector);
        m.bind(t);

        // a module that is not the token's recipient can't bind
        address dev2 = _newAgent();
        GangCountdownReward m2 = _module(dev2, _nextToken(dev2), address(wbnb), _cfg());
        address t2 = _createT(dev2, address(wbnb), _tax(TAX, TAX, 0, address(m)));
        vm.expectRevert(GangCountdownReward.NotRecipient.selector);
        m2.bind(t2);
    }

    // ---------------------------------------------------------------- buying
    function test_buy_beforeGraduationReverts() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 1 ether, false);
        address b = _buyer();
        vm.prank(b);
        vm.expectRevert(GangCountdownReward.NotTradable.selector);
        m.buy{value: 0.1 ether}(0, block.timestamp, false);
    }

    function test_buy_guards() public {
        (GangCountdownReward m, address t,) = _setupCD(address(wbnb), _cfg(), 1 ether, true);
        address b = _buyer();
        vm.startPrank(b);
        vm.expectRevert(GangCountdownReward.Expired.selector);
        m.buy{value: 0.1 ether}(0, block.timestamp - 1, false);
        vm.expectRevert(GangCountdownReward.Slippage.selector);
        m.buy{value: 0.1 ether}(type(uint256).max, block.timestamp, false);
        vm.expectRevert(GangCountdownReward.ZeroAmount.selector);
        m.buy{value: 0}(0, block.timestamp, false);
        vm.stopPrank();
        // the buyer gets the tokens (after the buy tax), the pair the BNB as WBNB, the module holds none of it
        uint256 pool0 = _bal(address(wbnb), address(m));
        uint256 out = _buyBnb(m, b, 0.1 ether);
        assertGt(out, 0);
        assertEq(_bal(t, b), out);
        assertEq(_bal(address(wbnb), address(m)), pool0, "the buyer's BNB never stays here");
        assertEq(address(m).balance, 0);
    }

    function test_buyWithQuote_nonWbnb() public {
        (GangCountdownReward m, address t,) = _setupCD(address(quoteTok), _cfg(), 1 ether, true);
        address b = _buyer();
        vm.prank(b);
        vm.expectRevert(GangCountdownReward.NotWbnb.selector);
        m.buy{value: 0.1 ether}(0, block.timestamp, false);
        vm.startPrank(b);
        quoteTok.approve(address(m), type(uint256).max);
        uint256 out = m.buyWithQuote(0.1 ether, 0, block.timestamp, false);
        vm.stopPrank();
        assertEq(_bal(t, b), out);
        assertTrue(m.currentRound() != 0, "counted");
    }

    // ---------------------------------------------------------------- rounds
    function test_round_fullFlow() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 1 ether, true);
        assertEq(m.pot(), 1 ether);
        address a = _buyer();
        address b = _buyer();
        address c = _buyer();
        _buyBnb(m, a, 0.1 ether);
        assertEq(m.currentRound(), 1);
        assertEq(m.deadline(), block.timestamp + 1 hours);
        _next(10 minutes);
        _buyBnb(m, b, 0.1 ether);
        _next(10 minutes);
        _buyBnb(m, c, 0.1 ether);
        uint256 d = m.deadline();
        // not over yet
        vm.warp(d);
        (bool due,) = m.previewWork();
        assertFalse(due);
        vm.warp(d + 1);
        (due,) = m.previewWork();
        assertTrue(due);
        m.work(0);
        // payout = 30% of 1 BNB = 0.3; the last (c) gets 20% extra = 0.06; 0.24 shared by 3 = 0.08 each
        assertEq(m.claimableOf(a), 0.08 ether);
        assertEq(m.claimableOf(b), 0.08 ether);
        assertEq(m.claimableOf(c), 0.14 ether);
        assertEq(m.pot(), 0.7 ether);
        assertEq(m.reservedTotal(), 0);
        assertEq(m.currentRound(), 0);
        _assertBooks(m, address(wbnb));
        uint256 c0 = _bal(address(wbnb), c);
        vm.prank(c);
        m.claim(c);
        assertEq(_bal(address(wbnb), c) - c0, 0.14 ether);
        vm.prank(c);
        vm.expectRevert(GangCountdownReward.NothingToClaim.selector);
        m.claim(c);
        _assertBooks(m, address(wbnb));
    }

    function test_round_minBuyAndMinPot() public {
        // a pool under minPot: nothing counts
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 0.05 ether, true);
        address a = _buyer();
        _buyBnb(m, a, 0.1 ether);
        assertEq(m.currentRound(), 0, "pool under minPot: no round");
        assertFalse(m.wouldCount(0.1 ether));
        // seeded above it: a buy under minBuy still does not count, one at minBuy does
        vm.startPrank(a);
        wbnb.approve(address(m), 1 ether);
        m.fund(1 ether);
        vm.stopPrank();
        assertFalse(m.wouldCount(MIN_BUY - 1));
        assertTrue(m.wouldCount(MIN_BUY));
        _buyBnb(m, a, MIN_BUY - 1);
        assertEq(m.currentRound(), 0);
        _buyBnb(m, a, MIN_BUY);
        assertEq(m.currentRound(), 1);
    }

    function test_round_ringKeepsTheLastEntries() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 1 ether, true);
        address[5] memory w;
        for (uint256 i; i < 5; i++) {
            w[i] = _buyer();
            _buyBnb(m, w[i], 0.1 ether);
            _next(1 minutes);
        }
        (, uint32 count,,,, GangCountdownReward.Entry[] memory list) = m.round(0);
        assertEq(count, 5);
        assertEq(list.length, 3);
        assertEq(list[0].buyer, w[2]);
        assertEq(list[2].buyer, w[4]);
        vm.warp(m.deadline() + 1);
        m.settle();
        assertEq(m.claimableOf(w[0]), 0);
        assertEq(m.claimableOf(w[1]), 0);
        assertEq(m.claimableOf(w[2]), 0.08 ether);
        assertEq(m.claimableOf(w[4]), 0.14 ether);
    }

    function test_round_sameWalletTakesSeveralEntries() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 1 ether, true);
        address a = _buyer();
        address b = _buyer();
        _buyBnb(m, a, 0.1 ether);
        _buyBnb(m, b, 0.1 ether);
        _buyBnb(m, a, 0.1 ether);
        vm.warp(m.deadline() + 1);
        m.settle();
        assertEq(m.claimableOf(a), 0.08 ether + 0.14 ether);
        assertEq(m.claimableOf(b), 0.08 ether);
    }

    function test_round_lazyRollAndReserve() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 1 ether, true);
        address a = _buyer();
        address b = _buyer();
        _buyBnb(m, a, 0.1 ether);
        vm.warp(m.deadline() + 1);
        // the next counted buy freezes round 1 (0.3 reserved) and starts round 2
        _buyBnb(m, b, 0.1 ether);
        assertEq(m.currentRound(), 2);
        assertEq(m.reservedTotal(), 0.3 ether);
        assertEq(m.pot(), 0.7 ether);
        (uint64 id1,, bool frozen1, bool settled1, uint256 res1,) = m.round(0);
        assertEq(id1, 1);
        assertTrue(frozen1);
        assertFalse(settled1);
        assertEq(res1, 0.3 ether);
        _assertBooks(m, address(wbnb));
        // settle pays round 1 only (round 2 still runs)
        m.settle();
        assertEq(m.claimableOf(a), 0.3 ether, "a single entry takes all");
        assertEq(m.claimableOf(b), 0);
        assertEq(m.currentRound(), 2);
        // round 2 ends: its payout is 30% of what is left (0.7) = 0.21
        vm.warp(m.deadline() + 1);
        m.settle();
        assertEq(m.claimableOf(b), 0.21 ether);
        assertEq(m.pot(), 0.49 ether);
        _assertBooks(m, address(wbnb));
    }

    function test_round_frozenRoundNeverOverwritten() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 1 ether, true);
        address a = _buyer();
        address b = _buyer();
        address c = _buyer();
        _buyBnb(m, a, 0.1 ether); // round 1, buffer 0
        vm.warp(m.deadline() + 1);
        _buyBnb(m, b, 0.1 ether); // freezes 1, round 2 in buffer 1
        vm.warp(m.deadline() + 1);
        // nobody settled: this buy freezes 2 and must settle 1 before reusing buffer 0 for round 3
        _buyBnb(m, c, 0.1 ether);
        assertEq(m.currentRound(), 3);
        assertEq(m.claimableOf(a), 0.3 ether, "round 1 paid before its buffer was reused");
        assertEq(m.claimableOf(b), 0, "round 2 frozen, not settled yet");
        assertEq(m.reservedTotal(), 0.21 ether);
        m.settle();
        assertEq(m.claimableOf(b), 0.21 ether);
        _assertBooks(m, address(wbnb));
    }

    /// @dev Buys every 50 minutes would keep a 1-hour countdown alive for good: the round still ends 6 hours after its
    ///      first counted buy, and the next buy starts round 2.
    function test_round_maxRoundEndsIt() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 1 ether, true);
        uint256 start = vm.getBlockTimestamp();
        address a = _buyer();
        _buyBnb(m, a, 0.1 ether);
        assertEq(m.roundEndsBy(), start + 6 hours);
        address last;
        for (uint256 i; i < 7; i++) {
            _next(50 minutes);
            last = _buyer();
            _buyBnb(m, last, 0.1 ether);
            assertLe(m.deadline(), start + 6 hours, "never past the cap");
        }
        // 5h50: the deadline is the cap, not 6h50
        assertEq(m.deadline(), start + 6 hours);
        assertEq(m.currentRound(), 1);
        vm.warp(start + 6 hours);
        (bool due,) = m.previewWork();
        assertFalse(due, "at the cap itself the round still runs");
        vm.warp(start + 6 hours + 1);
        (due,) = m.previewWork();
        assertTrue(due);
        address next = _buyer();
        _buyBnb(m, next, 0.1 ether);
        assertEq(m.currentRound(), 2, "the next buy starts round 2");
        assertEq(m.roundEndsBy(), start + 6 hours + 1 + 6 hours);
        m.settle();
        // capped: 0.3 shared equally by the last 3 entries, no extra for the last one
        assertEq(m.claimableOf(last), 0.1 ether, "an equal share at the cap");
        assertEq(m.claimableOf(next), 0);
        (,,,,, GangCountdownReward.Entry[] memory list) = m.round(0);
        assertEq(m.claimableOf(list[0].buyer), 0.1 ether);
        assertEq(m.claimableOf(list[1].buyer), 0.1 ether);
    }

    function test_round_maxPayoutCaps() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 10 ether, true);
        address a = _buyer();
        _buyBnb(m, a, 0.1 ether);
        vm.warp(m.deadline() + 1);
        m.settle();
        assertEq(m.claimableOf(a), MAX_PAYOUT, "30% of 10 = 3, capped at 1");
        assertEq(m.pot(), 9 ether);
    }

    function test_round_dustStaysInThePool() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 1 ether + 1, true);
        address a = _buyer();
        address b = _buyer();
        address c = _buyer();
        _buyBnb(m, a, 0.1 ether);
        _buyBnb(m, b, 0.1 ether);
        _buyBnb(m, c, 0.1 ether);
        vm.warp(m.deadline() + 1);
        m.settle();
        uint256 credited = m.claimableOf(a) + m.claimableOf(b) + m.claimableOf(c);
        assertEq(m.claimTotal(), credited);
        assertEq(m.pot() + credited, 1 ether + 1, "nothing lost to rounding");
        _assertBooks(m, address(wbnb));
    }

    // ---------------------------------------------------------------- money in
    function test_fund_andReceiveCarry_haveNoDevPart() public {
        GangCountdownReward.Config memory c = _cfg();
        c.devBps = 5_000;
        (GangCountdownReward m,,) = _setupCD(address(wbnb), c, 1 ether, false);
        assertEq(m.pot(), 1 ether);
        assertEq(m.devOwed(), 0);
        address carrier = _buyer();
        vm.startPrank(carrier);
        wbnb.approve(address(m), 0.5 ether);
        m.receiveCarry(0.5 ether);
        vm.stopPrank();
        assertEq(m.pot(), 1.5 ether);
        assertEq(m.devOwed(), 0);
        vm.expectRevert(GangCountdownReward.ZeroAmount.selector);
        m.fund(0);
    }

    function test_fund_onlyOnceBound() public {
        address dev = _newAgent();
        GangCountdownReward m = _module(dev, _nextToken(dev), address(wbnb), _cfg());
        vm.startPrank(dev);
        wbnb.approve(address(m), 0.3 ether);
        vm.expectRevert(GangCountdownReward.NotBound.selector);
        m.fund(0.3 ether);
        vm.expectRevert(GangCountdownReward.NotBound.selector);
        m.receiveCarry(0.3 ether);
        vm.stopPrank();
        address t = _createT(dev, address(wbnb), _tax(TAX, TAX, 0, address(m)));
        m.bind(t);
        vm.prank(dev);
        m.fund(0.3 ether);
        assertEq(m.pot(), 0.3 ether);
    }

    function test_mustCount() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 0.05 ether, true);
        address a = _buyer();
        vm.prank(a);
        vm.expectRevert(GangCountdownReward.NotCounted.selector);
        m.buy{value: 0.1 ether}(0, block.timestamp, true); // the pool is under minPot
        vm.prank(a);
        m.buy{value: 0.1 ether}(0, block.timestamp, false); // without it the buy goes through, not counted
        assertEq(m.currentRound(), 0);
        vm.startPrank(a);
        wbnb.approve(address(m), 1 ether);
        m.fund(1 ether);
        m.buy{value: 0.1 ether}(0, block.timestamp, true);
        vm.stopPrank();
        assertEq(m.currentRound(), 1);
    }

    function test_distribute_otherAssets() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 1 ether, false);
        quoteTok.mintUnlimited(address(m), 5 ether);
        m.distribute(address(quoteTok));
        assertEq(_bal(address(quoteTok), DEAD), 5 ether);
        vm.expectRevert(GangCountdownReward.WrongQuote.selector);
        m.distribute(address(wbnb));
    }

    function test_tax_bookedWithTheDevPart() public {
        GangCountdownReward.Config memory c = _cfg();
        c.devBps = 2_500;
        (GangCountdownReward m, address t, address dev) = _setupCD(address(wbnb), c, 0, true);
        address pair = _curvePair(t);
        for (uint256 i; i < 16; i++) {
            address seller = _newAgent();
            (uint256 rT,) = _reserves(t, pair);
            deal(t, seller, rT / 40, true);
            _poolSell(t, pair, seller, rT / 40);
            _next(1 minutes);
            if (i % 8 == 7) {
                uint256 mc = handler.maxChunk(t);
                vm.prank(keeper);
                handler.process(t, mc, 1);
            }
        }
        uint256 arrived = _bal(address(wbnb), address(m));
        assertGt(arrived, 0, "the pool tax arrived");
        assertEq(m.potAvailable(), arrived - (arrived * 2_500) / 10_000);
        m.settle(); // books it
        assertEq(m.devOwed(), (arrived * 2_500) / 10_000);
        assertEq(m.pot() + m.devOwed(), arrived);
        uint256 d0 = _bal(address(wbnb), dev);
        m.claimDev();
        assertEq(_bal(address(wbnb), dev) - d0, (arrived * 2_500) / 10_000);
        _assertBooks(m, address(wbnb));
    }

    // ---------------------------------------------------------------- finalize
    function test_finalize_afterIdle() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 10 ether, true);
        address a = _buyer();
        _buyBnb(m, a, 0.1 ether);
        vm.expectRevert(GangCountdownReward.NotDue.selector);
        m.finalize();
        vm.warp(m.deadline() + 1);
        m.settle();
        assertEq(m.claimableOf(a), 1 ether);
        vm.expectRevert(GangCountdownReward.NotDue.selector);
        m.finalize();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        (bool due,) = m.previewWork();
        assertTrue(due);
        m.work(0);
        assertEq(m.claimableOf(a), 2 ether, "finalize pays the last round's entries again, at most maxPayout");
        vm.expectRevert(GangCountdownReward.NotDue.selector);
        m.finalize();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        m.finalize();
        assertEq(m.claimableOf(a), 3 ether);
        // a new counted buy starts the game again
        address b = _buyer();
        _buyBnb(m, b, 0.1 ether);
        assertGt(m.currentRound(), 0);
        _assertBooks(m, address(wbnb));
    }

    function test_finalize_notUnderMinPot() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 0.2 ether, true);
        address a = _buyer();
        _buyBnb(m, a, 0.1 ether);
        vm.warp(m.deadline() + 1);
        m.settle(); // 30% of 0.2 paid: 0.14 left, above minPot (0.1)
        vm.warp(vm.getBlockTimestamp() + 30 days);
        m.finalize(); // 0.042 more: 0.098 left, under minPot
        assertLt(m.pot(), MIN_POT);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        (bool due,) = m.previewWork();
        assertFalse(due, "under minPot: not paid again to the old entries");
        vm.expectRevert(GangCountdownReward.NotDue.selector);
        m.finalize();
    }

    function test_settle_withNothingDueIsHarmless() public {
        (GangCountdownReward m,,) = _setupCD(address(wbnb), _cfg(), 1 ether, true);
        m.settle();
        assertEq(m.pot(), 1 ether);
        vm.expectRevert(GangCountdownReward.NotDue.selector);
        m.work(0);
    }

    // ---------------------------------------------------------------- gas
    function test_gas_receiveCarry() public {
        (GangCountdownReward m,, address dev) = _setupCD(address(wbnb), _cfg(), 0, false);
        vm.startPrank(dev);
        wbnb.approve(address(m), 1 ether);
        uint256 g = gasleft();
        m.receiveCarry(1 ether);
        g -= gasleft();
        vm.stopPrank();
        emit log_named_uint("receiveCarry gas", g);
        assertLt(g, 300_000);
    }
}
