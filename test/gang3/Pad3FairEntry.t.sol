// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {GangPadRegistryDeployLib as RG} from "../../script/GangPadRegistryDeployLib.sol";
import {Pad3Entry} from "./Pad3AsGateway.t.sol";
import {MultiHopRouter} from "./Pad3SellTo.t.sol";

/// @notice 打新 sales through GangLaunchpad 3.0's aggregator entry (spec §2): a gated sale reads as tradable (status 1),
///         `tryBuy` / `buyTokenAMAP` mint the most whole shares the funds pay for (to the wei, the rest back to the
///         buyer), `trySell` / both `sellToken`s sell whole shares back at the share price less the exit fee, the
///         last share launches the pair, the cap / gate / Agent rules are the sale's. Run twice: on 3.0's own sales
///         (`Pad3FairEntryLocalTest`) and on a 2.0 sale forwarded through 3.0 as its listed router
///         (`Pad3FairEntryForwardTest`, LegacyRoute → `mintFor` / `withdrawFor`).
abstract contract FairEntryCases is GangFixture {
    uint256 internal constant TPS = 50_000 ether;
    uint256 internal constant PRICE = 0.001 ether; // 10 BNB raise / 10,000 shares

    GangLaunchpad3 internal entry;
    address internal creator;
    address internal alice;
    address internal bob;

    function _setUpEntry() internal virtual;

    function setUp() public {
        _deployGang(makeAddr("keeper"));
        _setUpEntry();
        creator = _newAgent();
        alice = _newAgent();
        bob = _newAgent();
    }

    // ---------------------------------------------------------------- helpers
    function _sale() internal returns (address) {
        return _createFair(creator, address(0), 1);
    }

    function _buy(address who, address t, uint256 funds, uint256 minAmount)
        internal
        returns (uint256 out, uint256 used)
    {
        vm.deal(who, who.balance + funds);
        vm.prank(who, who);
        (out, used) = entry.buyTokenAMAP{value: funds}(t, who, funds, minAmount);
    }

    function _approveEntry(address who, address t) internal {
        vm.prank(who);
        IERC20(t).approve(address(entry), type(uint256).max);
    }

    /// @dev The entry keeps nothing of a trade: no BNB, no WBNB / quote above what it held, no tokens, no approvals.
    function _assertEntryHolds(address t, uint256 wbnbBefore) internal view {
        assertEq(address(entry).balance, 0, "entry BNB");
        // (3.0's own sale: the entry is the pad, which holds the unsold supply and the escrow)
        if (address(entry) != address(pad)) {
            assertEq(IERC20(t).balanceOf(address(entry)), 0, "entry token");
            assertEq(wbnb.balanceOf(address(entry)), wbnbBefore, "entry WBNB");
            assertEq(wbnb.allowance(address(entry), address(pad)), 0, "entry WBNB approval");
        }
    }

    function _held(address t, address who) internal view returns (uint256) {
        return IERC20(t).balanceOf(who);
    }

    // ---------------------------------------------------------------- status
    function test_fair_gatedSale_tradableStatus() public {
        address t = _sale();
        (uint8 st, address q, address pair, uint256 feeBps, uint256 left) = entry.getTokenInfo(t);
        assertEq(st, 1, "tradable through the entry");
        assertEq(q, address(0), "WBNB as 0");
        assertEq(pair, address(0));
        assertEq(feeBps, 100, "the mint fee");
        assertEq(left, (10_000 - 1) * PRICE, "the rest of the raise");
    }

    function test_fair_ungatedSale_staysMinting() public {
        address reg_ = address(pad.agentIdRegistry());
        vm.prank(owner);
        pad.setAgentGate(false, reg_);
        address t = _createFair(creator, address(0), 1);
        vm.prank(owner);
        pad.setAgentGate(true, reg_);
        (uint8 st,,,,) = entry.getTokenInfo(t);
        assertEq(st, 3, "no router can mint an ungated sale (A-2)");
        (,, uint256 amount,,,,,) = entry.tryBuy(t, alice, 0, 0.01 ether);
        assertEq(amount, 0);
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.RouterNeedsGate.selector);
        entry.buyTokenAMAP{value: 0.01 ether}(t, alice, 0.01 ether, 0);
        // nor sold through the entry (audits 2A L-1 / 2B L-2): no quote, refused; its minters withdraw directly
        _approveEntry(creator, t);
        (,, uint256 funds,) = entry.trySell(t, TPS);
        assertEq(funds, 0);
        vm.prank(creator, creator);
        vm.expectRevert(IGangLaunchpad.RouterNeedsGate.selector);
        entry.sellToken(0, t, creator, TPS, 0, 0, address(0));
    }

    // ---------------------------------------------------------------- buy
    /// @dev The quote is the fill to the wei; the unspent funds go back to the buyer in WBNB; the entry keeps nothing.
    function test_fair_buy_quoteEqualsFill_restBack() public {
        address t = _sale();
        uint256 w0 = wbnb.balanceOf(address(entry));
        uint256 funds = 0.0123 ether;
        (, address q, uint256 amount, uint256 cost, uint256 fee, uint256 msgValue,, uint256 amountFunds) =
            entry.tryBuy(t, alice, 0, funds);
        assertEq(q, address(0));
        // 12 shares cost 0.012 + 1% = 0.01212; 13 would cost 0.01313 > funds
        assertEq(amount, 12 * TPS);
        assertEq(cost, 0.01212 ether);
        assertEq(fee, 0.00012 ether);
        assertEq(msgValue, cost, "send exactly the cost of the whole shares (audit 2C M1)");
        assertEq(amountFunds, cost);
        uint256 wb0 = wbnb.balanceOf(alice);
        (uint256 out, uint256 used) = _buy(alice, t, funds, amount);
        assertEq(out, amount, "= tryBuy amount");
        assertEq(used, cost, "= tryBuy cost");
        assertEq(_held(t, alice), amount);
        assertEq(wbnb.balanceOf(alice) - wb0, funds - cost, "the rest back in WBNB");
        _assertEntryHolds(t, w0);
    }

    function test_fair_buy_slippageAndTooLittle() public {
        address t = _sale();
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.FundsTooLow.selector);
        entry.buyTokenAMAP{value: 0.001 ether}(t, alice, 0.001 ether, 0); // 1 share costs 0.00101
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.Slippage.selector);
        entry.buyTokenAMAP{value: 0.0101 ether}(t, alice, 0.0101 ether, 11 * TPS);
    }

    /// @dev The sale's cap (100 shares here) trims the buy; at the cap, no quote and no buy.
    function test_fair_buy_capTrims_thenRefused() public {
        address t = _sale();
        (,, uint256 amount, uint256 cost,,,,) = entry.tryBuy(t, alice, 0, 1 ether);
        assertEq(amount, 100 * TPS, "trimmed to the cap");
        (uint256 out, uint256 used) = _buy(alice, t, 1 ether, 0);
        assertEq(out, 100 * TPS);
        assertEq(used, cost);
        (,, amount,,,,,) = entry.tryBuy(t, alice, 0, 0.01 ether);
        assertEq(amount, 0, "at the cap");
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        entry.buyTokenAMAP{value: 0.01 ether}(t, alice, 0.01 ether, 0);
    }

    function test_fair_buy_nonAgentRefused_noTraderNoQuote() public {
        address t = _sale();
        address human = makeAddr("human");
        (,, uint256 amount,,,,,) = entry.tryBuy(t, human, 0, 0.01 ether);
        assertEq(amount, 0, "not an Agent");
        // no trader: quoted as a fresh Agent wallet (audit 2C L1); the fill checks the Agent
        (,, amount,,,,,) = entry.tryBuy(t, address(0), 0, 0.01 ether);
        assertEq(amount, 9 * TPS, "9 shares for 0.01 BNB");
        vm.deal(human, 1 ether);
        vm.prank(human, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        entry.buyTokenAMAP{value: 0.01 ether}(t, human, 0.01 ether, 0);
    }

    function test_fair_buy_toMustBeOrigin() public {
        address t = _sale();
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        entry.buyTokenAMAP{value: 0.01 ether}(t, bob, 0.01 ether, 0);
    }

    // ---------------------------------------------------------------- sell
    /// @dev Whole shares back at the share price less the exit fee; `trySell` = the 7-argument sell (with a router fee).
    function test_fair_sell_quoteEqualsFill_routerFee() public {
        address t = _sale();
        _buy(alice, t, 0.0202 ether, 0); // 20 shares
        _approveEntry(alice, t);
        uint256 w0 = wbnb.balanceOf(address(entry));
        (,, uint256 funds, uint256 fee) = entry.trySell(t, 5 * TPS);
        assertEq(fee, (5 * PRICE * 100) / 10_000, "the exit fee");
        assertEq(funds, 5 * PRICE - fee);
        address feeTo = makeAddr("feeTo");
        uint256 a0 = alice.balance;
        vm.prank(alice, alice);
        uint256 toSeller = entry.sellToken(0, t, alice, 5 * TPS, 0, 100, feeTo);
        assertEq(feeTo.balance, funds / 100, "1% router fee");
        assertEq(toSeller, funds - funds / 100);
        assertEq(alice.balance - a0, toSeller, "native BNB to the seller");
        assertEq(_held(t, alice), 15 * TPS);
        _assertEntryHolds(t, w0);
    }

    function test_fair_sell_wholeSharesOnly_needsAllowanceToEntry() public {
        address t = _sale();
        _buy(alice, t, 0.0202 ether, 0);
        (,, uint256 funds,) = entry.trySell(t, TPS + 1);
        assertEq(funds, 0);
        vm.prank(alice, alice);
        vm.expectRevert(); // no allowance to the entry
        entry.sellToken(0, t, alice, TPS, 0, 0, address(0));
        _approveEntry(alice, t);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.NotWholeShares.selector);
        entry.sellToken(0, t, alice, TPS + 1, 0, 0, address(0));
    }

    /// @dev Multi-hop: the payout goes to the listed router `to`, the seller's tokens back to the sale.
    function test_fair_sellTo_proceedsToTheRouter() public {
        address t = _sale();
        MultiHopRouter hop = new MultiHopRouter(entry);
        vm.prank(owner);
        entry.setCaller(address(hop), true);
        _buy(alice, t, 0.0202 ether, 0);
        _approveEntry(alice, t);
        (,, uint256 funds,) = entry.trySell(t, 3 * TPS);
        uint256 a0 = alice.balance;
        vm.prank(alice, alice);
        assertEq(hop.gangHop(t, 3 * TPS, funds), funds, "= trySell");
        assertEq(address(hop).balance, funds, "native BNB on the router");
        assertEq(alice.balance, a0);
        assertEq(_held(t, alice), 17 * TPS);
    }

    /// @dev A stale sale (7 days without progress) charges no exit fee, through the entry as directly.
    function test_fair_sell_staleNoExitFee() public {
        address t = _sale();
        _buy(alice, t, 0.0202 ether, 0);
        _approveEntry(alice, t);
        vm.warp(block.timestamp + 7 days);
        (,, uint256 funds, uint256 fee) = entry.trySell(t, 4 * TPS);
        assertEq(fee, 0);
        assertEq(funds, 4 * PRICE);
        vm.prank(alice, alice);
        assertEq(entry.sellToken(0, t, alice, 4 * TPS, funds, 0, address(0)), funds);
    }

    // ---------------------------------------------------------------- launch
    /// @dev The share that fills the sale launches the pair inside the entry buy; then the entry routes nothing.
    function test_fair_lastShare_launches_thenNotTradable() public {
        IGangLaunchpad.MintConfig memory cfg = _mintCfg(10 ether, 100, 6_000, 100, 100); // 200-share cap
        address t = _createFair(creator, address(0), cfg, 1);
        uint256 w0 = wbnb.balanceOf(address(entry));
        address last;
        for (uint256 i; i < 50; i++) {
            last = _newAgent();
            (,, uint256 amount,,,,,) = entry.tryBuy(t, last, 0, 1 ether);
            (uint256 out,) = _buy(last, t, 1 ether, amount);
            assertEq(out, amount);
            (uint8 st,,,,) = entry.getTokenInfo(t);
            if (st == 2) break;
        }
        (uint8 status, address q, address pair,,) = entry.getTokenInfo(t);
        assertEq(status, 2, "launched");
        assertEq(q, address(0));
        assertTrue(pair != address(0));
        _assertEntryHolds(t, w0);
        (,, uint256 a,,,,,) = entry.tryBuy(t, alice, 0, 0.01 ether);
        assertEq(a, 0);
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.NotCurveToken.selector);
        entry.buyTokenAMAP{value: 0.01 ether}(t, alice, 0.01 ether, 0);
        _approveEntry(last, t);
        (,, uint256 f,) = entry.trySell(t, TPS);
        assertEq(f, 0);
        vm.prank(last, last);
        vm.expectRevert(IGangLaunchpad3.NotCurveToken.selector);
        entry.sellToken(0, t, last, TPS, 0, 0, address(0));
    }

    // ---------------------------------------------------------------- ERC-20 quote
    function test_fair_erc20Quote_buyAndSell() public {
        address t = _createFair(creator, address(quoteTok), 1);
        (, address q, uint256 amount, uint256 cost,,, uint256 approval,) = entry.tryBuy(t, alice, 0, 5 ether);
        assertEq(q, address(quoteTok));
        assertEq(approval, cost, "approve exactly the cost of the whole shares");
        assertGt(amount, 0);
        vm.prank(alice);
        quoteTok.approve(address(entry), type(uint256).max);
        uint256 q0 = quoteTok.balanceOf(alice);
        vm.prank(alice, alice);
        (uint256 out, uint256 used) = entry.buyTokenAMAP(t, alice, 5 ether, amount);
        assertEq(out, amount);
        assertEq(used, cost);
        assertEq(q0 - quoteTok.balanceOf(alice), cost, "only the cost leaves the buyer");
        _approveEntry(alice, t);
        (,, uint256 funds,) = entry.trySell(t, TPS);
        vm.prank(alice, alice);
        assertEq(entry.sellToken(0, t, alice, TPS, funds, 0, address(0)), funds);
        assertEq(quoteTok.balanceOf(address(entry)) == 0 || address(entry) == address(pad), true);
    }

    /// @dev Audit 2B: the exit fee comes back between quote and fill (a mint restarts the stale clock): the seller's
    ///      `minFunds` stops it (Slippage), never a silent loss.
    function test_fair_staleClockResetBetweenQuoteAndFill() public {
        address t = _sale();
        _buy(alice, t, 0.0202 ether, 0);
        _approveEntry(alice, t);
        vm.warp(block.timestamp + 7 days);
        (,, uint256 q,) = entry.trySell(t, 4 * TPS);
        _buy(bob, t, 0.0202 ether, 0); // 20 shares ≥ STALE_STEP: the clock restarts
        (,, uint256 q2,) = entry.trySell(t, 4 * TPS);
        assertLt(q2, q);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.Slippage.selector);
        entry.sellToken(0, t, alice, 4 * TPS, q, 0, address(0));
        vm.prank(alice, alice);
        assertEq(entry.sellToken(0, t, alice, 4 * TPS, q2, 0, address(0)), q2);
    }

    // ---------------------------------------------------------------- fuzz
    /// @dev Audit 2B: odd share prices (the fee rounds down), 1–3% mint fee, shares held already, funds exactly the
    ///      cost of n shares (the n + 1 boundary): the quote is the fill, the most whole shares the funds pay for.
    function testFuzz_fair_quoteEqualsFill_oddPrice(uint256 raise, uint16 fee, uint256 funds, uint256 pre, bool exact)
        public
    {
        raise = bound(raise, 5 ether, 50 ether);
        fee = uint16(bound(fee, 100, 300));
        address t = _createFair(creator, address(0), _mintCfg(raise, 100, 6_000, fee, 100), 1); // 200-share cap
        uint256 price = _price(t);
        address a = _newAgent();
        pre = bound(pre, 0, 199);
        if (pre > 0) _buy(a, t, (pre * price * (10_000 + fee)) / 10_000 + 2 * price, 0);
        funds = bound(funds, 1, 3 ether);
        if (exact) {
            uint256 c = bound(funds, 1, 50) * price;
            funds = c + (c * fee) / 10_000;
        }
        uint256 held = IERC20(t).balanceOf(a) / TPS;
        (,, uint256 amount, uint256 cost, uint256 f, uint256 msgValue,,) = entry.tryBuy(t, a, 0, funds);
        if (amount == 0) {
            vm.deal(a, a.balance + funds);
            vm.prank(a, a);
            vm.expectRevert();
            entry.buyTokenAMAP{value: funds}(t, a, funds, 0);
            return;
        }
        assertEq(msgValue, cost);
        // sending exactly the quoted cost buys the same
        (uint256 out, uint256 used) = _buy(a, t, msgValue, amount);
        assertEq(out, amount);
        assertEq(used, cost);
        assertLe(cost, funds);
        uint256 n = amount / TPS;
        uint256 next = (n + 1) * price;
        if (n + held < 200 && _sold(t) < 10_000) assertGt(next + (next * fee) / 10_000, funds, "maximal");
        assertEq(f, cost - n * price);
    }

    function _price(address t) internal view returns (uint256 price) {
        (,,,,,,,,,, price,,,) = pad.sales(t);
    }

    function _sold(address t) internal view returns (uint256 sold) {
        (,,,,, sold,,,,,,,,) = pad.sales(t);
    }

    function testFuzz_fair_tryBuyEqualsBuy(uint256 funds) public {
        funds = bound(funds, 0.00101 ether, 0.5 ether);
        address t = _sale();
        (,, uint256 amount, uint256 cost,,,,) = entry.tryBuy(t, alice, 0, funds);
        (uint256 out, uint256 used) = _buy(alice, t, funds, 0);
        assertEq(out, amount);
        assertEq(used, cost);
    }
}

contract Pad3FairEntryLocalTest is FairEntryCases {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function _setUpEntry() internal override {
        entry = GangLaunchpad3(payable(address(pad)));
    }

    /// @dev Audit 2A: the other books on the same WBNB balance (a curve, another sale, owed fees) stay whole through
    ///      entry buys (with refunds) and sells (with a router fee) of sale A, up to its launch inside an entry buy.
    function test_fair_escrowOfOthersIntact_throughLaunch() public {
        GangLaunchpad3 p = GangLaunchpad3(payable(address(pad)));
        address curveT = _createV3(creator, address(0), _tax(100, 100, 0, creator));
        vm.prank(bob);
        pad.buy(curveT, 1 ether, 0);
        address saleB = _createFair(creator, address(0), 3);
        vm.prank(bob);
        pad.mint(saleB, 40, 40);
        address a = _createFair(creator, address(0), _mintCfg(10 ether, 100, 6_000, 300, 200), 1);
        uint256 others = _curveRealQuote(curveT) + p.creatorFeeOf(curveT) + _sold(saleB) * _price(saleB);
        others += p.owedFee(address(wbnb));
        for (uint256 i; i < 60 && !_launched(a); i++) {
            address w = _newAgent();
            _buy(w, a, 0.33 ether + i * 7, 0); // odd amounts: a refund every time
            if (i % 3 == 0 && !_launched(a)) {
                _approveEntry(w, a);
                vm.prank(w, w);
                entry.sellToken(0, a, w, 7 * TPS, 0, 250, makeAddr("aggFee"));
            }
            uint256 aEscrow = _launched(a) ? 0 : _sold(a) * _price(a);
            assertEq(wbnb.balanceOf(address(pad)), others + aEscrow, "pad WBNB = every book on it");
        }
        assertTrue(_launched(a));
    }
}

contract Pad3FairEntryForwardTest is FairEntryCases {
    GangPadRegistry internal reg;

    function _setUpEntry() internal override {
        address[] memory pads = new address[](1);
        pads[0] = address(pad);
        reg = GangPadRegistry(RG.deploy(owner, pads).proxy);
        entry = GangLaunchpad3(payable(Pad3Entry.deploy(address(wbnb), address(reg), owner)));
        vm.prank(owner);
        pad.setRouter(address(entry), true);
    }

    /// @dev The forwarded trade names the older pad it went to.
    function test_fair_forward_emitsRouted() public {
        address t = _sale();
        (,, uint256 amount, uint256 cost,,,,) = entry.tryBuy(t, alice, 0, 0.0101 ether);
        vm.expectEmit(address(entry));
        emit IGangLaunchpad3.Routed(t, address(pad), alice, true, cost, amount);
        _buy(alice, t, 0.0101 ether, amount);
    }

    /// @dev An older pad that dropped 3.0 as its router: no quote, the trade reverts there.
    function test_fair_forward_unlisted_noQuote() public {
        address t = _sale();
        vm.prank(owner);
        pad.setRouter(address(entry), false);
        (,, uint256 amount,,,,,) = entry.tryBuy(t, alice, 0, 0.01 ether);
        assertEq(amount, 0);
        (,, uint256 funds,) = entry.trySell(t, TPS);
        assertEq(funds, 0);
    }
}
