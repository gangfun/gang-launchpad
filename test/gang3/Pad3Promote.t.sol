// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3PromoteStore} from "../../src/gang/Pad3PromoteStore.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {IGangPromote} from "../../src/gang/interfaces/IGangPromote.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";

/// @dev The upgrade script's per-token promoter state, exposed.
contract PromoteSnapHarness is UpgradeGangLaunchpad3 {
    function promoteState(GangLaunchpad3 p, address t) external view returns (bytes memory) {
        return _promoteState(p, t);
    }

    function promoteProbes(GangLaunchpad3 p, address[] memory probes) external view returns (bytes memory) {
        return _promoteProbes(p, probes);
    }

    address[] internal _list;

    function setList(address[] memory list) external {
        _list = list;
    }

    function _promoteProbeList() internal view override returns (address[] memory) {
        return _list;
    }

    function warn(GangLaunchpad3 p) external view {
        _warnNoPromoteProbes(p);
    }

    function settingsWithList(GangLaunchpad3 p, address router) external view returns (bytes32) {
        Stack memory st;
        st.pad = address(p);
        st.router = router;
        return _snapshot(p, st, false, new bool[](0)).settings;
    }
}

/// @notice The promoter share (docs/SPEC-PROMOTER-SHARE-2026-11-04.md): set at create, bound at a wallet's first trade,
///         paid out of the creator's fee only, on every entry, while the window runs.
contract Pad3PromoteTest is GangFixture {
    uint256 internal constant BPS = 10_000;
    uint16 internal constant SHARE = 2_000;
    uint32 internal constant WINDOW = 30 days;
    /// @dev small enough that several buys stay under the 1% wallet cap (a capped buy pays on what it spent)
    uint256 internal constant GROSS = 0.001 ether;

    event PromoteSet(address indexed token, uint16 shareBps, uint32 window);
    event PromoterBound(address indexed token, address indexed wallet, address indexed promoter);
    event PromoterFeeAccrued(address indexed token, address indexed promoter, address indexed wallet, uint256 amount);
    event PromoterFeeClaimed(address indexed token, address indexed promoter, address indexed to, uint256 amount);
    event CreatorFeeAccrued(address indexed token, address indexed creator, uint256 amount);

    GangLaunchpad3 internal pad3;
    Pad3Module internal pm;
    address internal creator;
    address internal promoter;
    address internal trader;
    address internal notAgent = address(0xBEEF);
    address internal feeTo = address(0xFEE);

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(address(this));
        pad3 = GangLaunchpad3(payable(address(pad)));
        pm = Pad3Module(payable(address(pad)));
        creator = _newAgent();
        promoter = _newAgent();
        trader = _newAgent();
    }

    // ---------------------------------------------------------------- helpers
    function _create(address quote) internal returns (address t) {
        return _create(quote, SHARE, WINDOW);
    }

    function _create(address quote, uint16 share, uint32 window) internal returns (address t) {
        vm.prank(creator);
        t = pm.createWithPromote(
            "P", "P", "l", "m", quote, address(0), _tax(0, 0, 0, address(0)), 9 ether, share, window
        );
    }

    function _buyBound(address t, address who, uint256 funds, address p) internal returns (uint256 out) {
        vm.prank(who, who);
        (out,) = pm.buyWithPromoter{value: funds}(t, funds, 0, p);
    }

    function _creatorPart(uint256 gross) internal pure returns (uint256) {
        return (((gross * 100) / BPS) * 7_000) / BPS;
    }

    function _cut(uint256 gross) internal pure returns (uint256) {
        return (_creatorPart(gross) * SHARE) / BPS;
    }

    // ---------------------------------------------------------------- create
    function test_create_recordsTermsAndEmits() public {
        vm.recordLogs();
        address t = _create(address(wbnb));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.topics[0], PromoteSet.selector);
        assertEq(last.topics[1], bytes32(uint256(uint160(t))));
        assertEq(last.data, abi.encode(SHARE, WINDOW));
        (uint16 s, uint32 w) = pm.promoteOf(t);
        assertEq(s, SHARE);
        assertEq(w, WINDOW);
        assertEq(pad.kindOf(t), 1);
        assertEq(pad3.tokenVersionOf(t), pad3.TOKEN_VERSION());
        assertEq(pad.gradTargetOf(t), 9 ether);
        assertEq(pad.allTokens(pad.tokenCount() - 1), t);
    }

    function test_create_termBounds() public {
        address t = _create(address(wbnb), 1, 7 days);
        assertTrue(t != address(0));
        t = _create(address(wbnb), 5_000, 90 days);
        assertTrue(t != address(0));
        uint16[3] memory badShare = [uint16(0), 5_001, type(uint16).max];
        for (uint256 i; i < 3; i++) {
            vm.prank(creator);
            vm.expectRevert(IGangPromote.BadPromoteTerms.selector);
            pm.createWithPromote(
                "P", "P", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, badShare[i], WINDOW
            );
        }
        uint32[4] memory badWindow = [uint32(0), 7 days - 1, 90 days + 1, type(uint32).max];
        for (uint256 i; i < 4; i++) {
            vm.prank(creator);
            vm.expectRevert(IGangPromote.BadPromoteTerms.selector);
            pm.createWithPromote(
                "P", "P", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, SHARE, badWindow[i]
            );
        }
    }

    /// @dev The usual create rules apply: only an Agent creates, a bad graduation tier is refused.
    function test_create_usualRules() public {
        vm.prank(notAgent);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pm.createWithPromote(
            "P", "P", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, SHARE, WINDOW
        );
        vm.prank(creator);
        vm.expectRevert(IGangLaunchpad.BadGradTarget.selector);
        pm.createWithPromote(
            "P", "P", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 7 ether, SHARE, WINDOW
        );
    }

    // ---------------------------------------------------------------- the split
    /// @dev The first trade already pays. Trader, curve and platform see exactly what a token without a share sees.
    function test_firstBuy_splitsCreatorFeeOnly() public {
        address t = _create(address(wbnb));
        address plain = _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        vm.prank(trader, trader);
        (uint256 plainOut,) = pad3.buyTokenAMAP{value: GROSS}(plain, trader, GROSS, 0);
        uint256 bucket0 = bucket.accruedQuote(address(wbnb));

        vm.expectEmit(true, true, true, true, address(pad));
        emit PromoterBound(t, trader, promoter);
        vm.expectEmit(true, true, true, true, address(pad));
        emit PromoterFeeAccrued(t, promoter, trader, _cut(GROSS));
        vm.expectEmit(true, true, false, true, address(pad));
        emit CreatorFeeAccrued(t, creator, _creatorPart(GROSS) - _cut(GROSS));
        uint256 out = _buyBound(t, trader, GROSS, promoter);

        assertEq(out, plainOut, "same tokens as without a share");
        assertEq(_curveRealQuote(t), _curveRealQuote(plain), "same curve");
        assertEq(pm.promoterFeeOf(t, promoter), _cut(GROSS));
        assertEq(pad.creatorFeeOf(t), _creatorPart(GROSS) - _cut(GROSS));
        assertEq(pad.creatorFeeOf(t) + pm.promoterFeeOf(t, promoter), pad.creatorFeeOf(plain), "creator's 70% in all");
        assertEq(
            bucket.accruedQuote(address(wbnb)) - bucket0, (GROSS * 100) / BPS - _creatorPart(GROSS), "platform 30%"
        );
        (address p, uint40 at, bool traded) = pm.bindingOf(t, trader);
        assertEq(p, promoter);
        assertEq(at, block.timestamp);
        assertTrue(traded);
    }

    /// @dev TradeV1's creatorFee stays the creator's whole part: protocolFee - creatorFee is the platform's on any token.
    function test_tradeV1_keepsCreatorsWholePart() public {
        address t = _create(address(wbnb));
        (uint256 tokensOut,,,) = _quote(t, trader, GROSS);
        uint256 fee = (GROSS * 100) / BPS;
        uint256 rq = GROSS - fee;
        (,,,,, uint128 vq,,,,,,) = _curveView(t);
        uint256 price = ((uint256(vq) + rq) * 1e18) / (pad.VIRTUAL_TOKEN() - tokensOut);
        vm.expectEmit(true, true, false, true, address(pad));
        emit IGangLaunchpad3.TradeV1(t, trader, true, GROSS, tokensOut, fee, _creatorPart(GROSS), price, rq, tokensOut);
        _buyBound(t, trader, GROSS, promoter);
    }

    /// @dev A bound wallet's trades pay on every way in: the direct buy and sell, the entry's (a listed router's: below).
    function test_everyEntry_pays() public {
        address t = _create(address(wbnb));
        _buyBound(t, trader, GROSS, promoter);
        uint256 cum = pm.promoterFeeOf(t, promoter);

        // the entry's plain buy
        vm.prank(trader, trader);
        pad3.buyTokenAMAP{value: GROSS}(t, trader, GROSS, 0);
        assertEq(pm.promoterFeeOf(t, promoter) - cum, _cut(GROSS), "buyTokenAMAP");
        cum = pm.promoterFeeOf(t, promoter);

        // the direct buy
        vm.prank(trader);
        pad.buy(t, GROSS, 0);
        assertEq(pm.promoterFeeOf(t, promoter) - cum, _cut(GROSS), "buy");
        cum = pm.promoterFeeOf(t, promoter);

        // the direct sell
        uint256 part = IERC20(t).balanceOf(trader) / 4;
        vm.startPrank(trader, trader);
        IERC20(t).approve(address(pad), type(uint256).max);
        uint256 got = pad.sell(t, part, 0);
        vm.stopPrank();
        uint256 sellCut = pm.promoterFeeOf(t, promoter) - cum;
        uint256 fee = got * 100 / 9_900; // the 1% of what the curve paid, within a wei
        assertApproxEqAbs(sellCut, (((fee * 7_000) / BPS) * SHARE) / BPS, 2, "sell");
        cum = pm.promoterFeeOf(t, promoter);

        // the entry's sell
        vm.prank(trader, trader);
        pad3.sellToken(0, t, trader, part, 0, 0, address(0));
        assertGt(pm.promoterFeeOf(t, promoter), cum, "sellToken");
    }

    function test_listedRouter_buyAndSellFor_pay() public {
        address t = _create(address(wbnb));
        RouterStub r = new RouterStub(pad, address(wbnb));
        vm.prank(owner);
        pad.setRouter(address(r), true);
        _buyBound(t, trader, GROSS, promoter);
        uint256 cum = pm.promoterFeeOf(t, promoter);

        vm.prank(trader, trader);
        r.buyFor{value: GROSS}(t, trader, GROSS);
        assertEq(pm.promoterFeeOf(t, promoter) - cum, _cut(GROSS), "buyFor");
        cum = pm.promoterFeeOf(t, promoter);

        vm.startPrank(trader, trader);
        IERC20(t).approve(address(r), type(uint256).max);
        r.sellFor(t, trader, IERC20(t).balanceOf(trader) / 2);
        vm.stopPrank();
        assertGt(pm.promoterFeeOf(t, promoter), cum, "sellFor");
    }

    // ---------------------------------------------------------------- the window
    function test_window_endsAtBoundPlusWindow() public {
        address t = _create(address(wbnb));
        _buyBound(t, trader, GROSS, promoter);
        (, uint40 at,) = pm.bindingOf(t, trader);

        vm.warp(uint256(at) + WINDOW - 1);
        uint256 cum = pm.promoterFeeOf(t, promoter);
        vm.prank(trader, trader);
        pad3.buyTokenAMAP{value: GROSS}(t, trader, GROSS, 0);
        assertEq(pm.promoterFeeOf(t, promoter) - cum, _cut(GROSS), "last second pays");
        cum = pm.promoterFeeOf(t, promoter);

        vm.warp(uint256(at) + WINDOW);
        uint256 creator0 = pad.creatorFeeOf(t);
        vm.prank(trader, trader);
        pad3.buyTokenAMAP{value: GROSS}(t, trader, GROSS, 0);
        assertEq(pm.promoterFeeOf(t, promoter), cum, "window over");
        assertEq(pad.creatorFeeOf(t) - creator0, _creatorPart(GROSS), "all the creator's again");
    }

    // ---------------------------------------------------------------- binding rules
    function test_bind_onceOnly_firstPromoterStays() public {
        address t = _create(address(wbnb));
        address other = _newAgent();
        _buyBound(t, trader, GROSS, promoter);
        assertFalse(pm.canBind(t, trader, other));

        _buyBound(t, trader, GROSS, other);
        (address p,,) = pm.bindingOf(t, trader);
        assertEq(p, promoter, "the first stays");
        assertEq(pm.promoterFeeOf(t, other), 0);
        assertEq(pm.promoterFeeOf(t, promoter), _cut(GROSS) * 2);
    }

    /// @dev A wallet that traded the token without a promoter is nobody's referral, on any first entry.
    function test_bind_notAfterPlainFirstTrade() public {
        address t = _create(address(wbnb));
        vm.prank(trader, trader);
        pad3.buyTokenAMAP{value: GROSS}(t, trader, GROSS, 0);
        assertFalse(pm.canBind(t, trader, promoter));
        _buyBound(t, trader, GROSS, promoter);
        (address p,, bool traded) = pm.bindingOf(t, trader);
        assertEq(p, address(0));
        assertTrue(traded);
        assertEq(pm.promoterFeeOf(t, promoter), 0);
        assertEq(pad.creatorFeeOf(t), _creatorPart(GROSS) * 2);
    }

    /// @dev Selling everything doesn't free the wallet.
    function test_bind_notAfterSellingOut() public {
        address t = _create(address(wbnb));
        vm.prank(trader, trader);
        pad3.buyTokenAMAP{value: GROSS}(t, trader, GROSS, 0);
        uint256 bal = IERC20(t).balanceOf(trader);
        vm.startPrank(trader, trader);
        IERC20(t).approve(address(pad), bal);
        pad.sell(t, bal, 0);
        vm.stopPrank();
        assertEq(IERC20(t).balanceOf(trader), 0);
        assertFalse(pm.canBind(t, trader, promoter));
    }

    /// @dev Each refusal leaves the wallet unbound; the buy goes on, and the wallet has now traded.
    function test_bind_refusals_ignored_buyGoesOn() public {
        address t = _create(address(wbnb));
        address[4] memory bad = [address(0), trader, creator, notAgent];
        for (uint256 i; i < 4; i++) {
            address w = i == 1 ? trader : _newAgent();
            address p = bad[i];
            assertFalse(pm.canBind(t, w, p));
            uint256 out = _buyBound(t, w, GROSS, p);
            assertGt(out, 0);
            (address bound,, bool traded) = pm.bindingOf(t, w);
            assertEq(bound, address(0));
            assertTrue(traded);
        }
        assertEq(pm.promoterFeeOf(t, address(0)), 0);
        assertEq(pm.promoterFeeOf(t, creator), 0);
        assertEq(pad.creatorFeeOf(t), _creatorPart(GROSS) * 4);
    }

    /// @dev A promoter's Agent ID counts at the binding; losing it later doesn't undo the binding or block the claim.
    function test_bind_promoterLosesAgentIdLater() public {
        address t = _create(address(wbnb));
        _buyBound(t, trader, GROSS, promoter);
        _dropAgent(promoter);
        assertFalse(pad.isAgent(promoter));
        vm.prank(trader, trader);
        pad3.buyTokenAMAP{value: GROSS}(t, trader, GROSS, 0);
        assertEq(pm.promoterFeeOf(t, promoter), _cut(GROSS) * 2);
        vm.prank(promoter);
        pm.claimPromoterFee(t, feeTo);
        assertEq(wbnb.balanceOf(feeTo), _cut(GROSS) * 2);
    }

    /// @dev Only the wallet itself: no contract, listed or not, names a promoter for it (audit L-1). A contract can't buy
    ///      this way at all; what it can do for a wallet, it does through `buyTokenAMAP`, which names nobody.
    function test_buyWithPromoter_contractsRefused() public {
        address t = _create(address(wbnb));
        RouterStub stranger = new RouterStub(pad, address(wbnb));
        RouterStub router = new RouterStub(pad, address(wbnb));
        RouterStub caller = new RouterStub(pad, address(wbnb));
        vm.startPrank(owner);
        pad.setRouter(address(router), true);
        pad3.setCaller(address(caller), true);
        vm.stopPrank();
        RouterStub[3] memory all = [stranger, router, caller];
        for (uint256 i; i < 3; i++) {
            vm.prank(trader, trader);
            vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
            all[i].buyWithPromoter{value: GROSS}(t, GROSS, promoter);
        }
        (address p,, bool traded) = pm.bindingOf(t, trader);
        assertEq(p, address(0));
        assertFalse(traded);
        assertEq(IERC20(t).balanceOf(trader), 0);
        assertTrue(pm.canBind(t, trader, promoter), "still free");
    }

    /// @dev What's left of phishing (spec §3, known limits): a contract a wallet calls can spend its first trade with
    ///      `buyTokenAMAP`, naming nobody. Then no promoter ever gets this wallet, and nobody but the creator gains.
    function test_buyTokenAMAP_byAContract_usesUpTheFirstTrade() public {
        address t = _create(address(wbnb));
        RouterStub stranger = new RouterStub(pad, address(wbnb));
        vm.prank(trader, trader);
        stranger.buyEntry{value: GROSS}(t, GROSS);
        assertFalse(pm.canBind(t, trader, promoter));
        (address p,, bool traded) = pm.bindingOf(t, trader);
        assertEq(p, address(0));
        assertTrue(traded);
        assertEq(pad.creatorFeeOf(t), _creatorPart(GROSS));
    }

    /// @dev `canBind` agrees with the buy: a wallet without an Agent ID can't buy, so it says no.
    function test_canBind_agreesWithTheBuy() public {
        address t = _create(address(wbnb));
        assertFalse(pm.canBind(t, notAgent, promoter), "wallet not an Agent");
        assertTrue(pm.canBind(t, trader, promoter));
        vm.deal(notAgent, GROSS);
        vm.prank(notAgent, notAgent);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);
        assertFalse(pm.canBind(t, address(0), promoter), "no wallet");
        _buyBound(t, trader, GROSS, promoter);
        (address bound,,) = pm.bindingOf(t, trader);
        assertEq(bound, promoter, "it said yes, and it bound");
        assertFalse(pm.canBind(t, trader, promoter), "bound");
    }

    /// @dev The multi-hop `sellToken` (pay-to a listed caller) pays too: it's the same split.
    function test_payToSellToken_pays() public {
        address t = _create(address(wbnb));
        _buyBound(t, trader, GROSS, promoter);
        uint256 cum = pm.promoterFeeOf(t, promoter);
        RouterStub c = new RouterStub(pad, address(wbnb));
        vm.prank(owner);
        pad3.setCaller(address(c), true);
        uint256 bal = IERC20(t).balanceOf(trader);
        vm.prank(trader);
        IERC20(t).approve(address(pad), bal);
        vm.prank(trader, trader);
        c.sellTo(t, trader, bal);
        assertGt(pm.promoterFeeOf(t, promoter), cum);
    }

    function test_buyWithPromoter_refusals() public {
        address t = _create(address(wbnb));
        // not this pad's curve token
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad3.NotCurveToken.selector);
        pm.buyWithPromoter{value: GROSS}(address(0x1234), GROSS, 0, promoter);
        address fair = _createFair(creator, address(wbnb), 1);
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad3.NotCurveToken.selector);
        pm.buyWithPromoter{value: GROSS}(fair, GROSS, 0, promoter);
        // msg.value must equal funds
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad3.BadMsgValue.selector);
        pm.buyWithPromoter{value: GROSS - 1}(t, GROSS, 0, promoter);
        // slippage undoes the binding with the buy
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.Slippage.selector);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, type(uint256).max, promoter);
        (address p,, bool traded) = pm.bindingOf(t, trader);
        assertEq(p, address(0));
        assertFalse(traded);
        // the buyer must be an Agent, as on every curve buy
        vm.deal(notAgent, GROSS);
        vm.prank(notAgent, notAgent);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);
        // the gate off: the entry's rule (A-2)
        address gate = address(pad.agentIdRegistry());
        vm.prank(owner);
        pad.setAgentGate(false, gate);
        assertFalse(pm.canBind(t, trader, promoter));
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.RouterNeedsGate.selector);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);
    }

    /// @dev On a curve token without a share it's a plain entry buy: nothing is written for the wallet.
    function test_buyWithPromoter_tokenWithoutShare() public {
        address plain = _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        assertFalse(pm.canBind(plain, trader, promoter));
        _buyBound(plain, trader, GROSS, promoter);
        (address p,, bool traded) = pm.bindingOf(plain, trader);
        assertEq(p, address(0));
        assertFalse(traded);
        assertEq(pad.creatorFeeOf(plain), _creatorPart(GROSS));
        assertEq(pm.promoterFeeOf(plain, promoter), 0);
    }

    /// @dev An ERC-20 quote: the caller pays with its allowance; the claim pays that quote.
    function test_erc20Quote() public {
        address t = _create(address(quoteTok));
        _mintQuote(address(quoteTok), trader, 1 ether);
        vm.startPrank(trader, trader);
        quoteTok.approve(address(pad), type(uint256).max);
        (uint256 out, uint256 used) = pm.buyWithPromoter(t, GROSS, 0, promoter);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(used, GROSS);
        assertEq(pm.promoterFeeOf(t, promoter), _cut(GROSS));
        assertEq(
            quoteTok.balanceOf(address(pad)),
            _curveRealQuote(t) + pad.creatorFeeOf(t) + pm.promoterFeeOf(t, promoter),
            "books"
        );
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad3.BadMsgValue.selector);
        pm.buyWithPromoter{value: 1}(t, GROSS, 0, promoter);
        vm.prank(promoter);
        uint256 got = pm.claimPromoterFee(t, feeTo);
        assertEq(got, _cut(GROSS));
        assertEq(quoteTok.balanceOf(feeTo), got);
    }

    // ---------------------------------------------------------------- claim
    function test_claim_paysOnceToTo() public {
        address t = _create(address(wbnb));
        _buyBound(t, trader, GROSS, promoter);
        vm.expectEmit(true, true, true, true, address(pad));
        emit PromoterFeeClaimed(t, promoter, feeTo, _cut(GROSS));
        vm.prank(promoter);
        uint256 got = pm.claimPromoterFee(t, feeTo);
        assertEq(got, _cut(GROSS));
        assertEq(wbnb.balanceOf(feeTo), got);
        assertEq(pm.promoterFeeOf(t, promoter), 0);
        vm.prank(promoter);
        vm.expectRevert(IGangLaunchpad.ZeroAmount.selector);
        pm.claimPromoterFee(t, feeTo);
    }

    function test_claim_refusals() public {
        address t = _create(address(wbnb));
        _buyBound(t, trader, GROSS, promoter);
        vm.startPrank(promoter);
        vm.expectRevert(IGangLaunchpad.ZeroAddress.selector);
        pm.claimPromoterFee(t, address(0));
        vm.expectRevert(IGangLaunchpad.ZeroAddress.selector);
        pm.claimPromoterFee(t, address(pad));
        vm.stopPrank();
        // only what the caller earned: the creator and the trader have none of it
        vm.prank(creator);
        vm.expectRevert(IGangLaunchpad.ZeroAmount.selector);
        pm.claimPromoterFee(t, creator);
        vm.prank(trader);
        vm.expectRevert(IGangLaunchpad.ZeroAmount.selector);
        pm.claimPromoterFee(t, trader);
        // a token that isn't one
        vm.prank(promoter);
        vm.expectRevert(IGangLaunchpad.ZeroAmount.selector);
        pm.claimPromoterFee(address(0x1234), promoter);
    }

    /// @dev Creator and promoter draw from their own books, in any order, and never from the curve's escrow.
    function test_claims_independent_escrowIntact() public {
        address t = _create(address(wbnb));
        _buyBound(t, trader, GROSS, promoter);
        uint256 rq = _curveRealQuote(t);
        vm.prank(creator);
        pad.claimCreatorFee(t, creator);
        assertEq(wbnb.balanceOf(address(pad)), rq + pm.promoterFeeOf(t, promoter));
        vm.prank(promoter);
        pm.claimPromoterFee(t, promoter);
        assertEq(wbnb.balanceOf(address(pad)), rq);
    }

    /// @dev Graduation doesn't touch what's owed, and migrates exactly the curve's raise.
    function test_graduation_claimsAfter_noMoreBinding() public {
        address t = _create(address(wbnb));
        _buyBound(t, trader, GROSS, promoter);
        _graduate(t);
        assertTrue(_graduated(t));
        uint256 owed = pm.promoterFeeOf(t, promoter);
        assertGe(owed, _cut(GROSS));
        // the graduation cut's known 1-wei dust (as on 2.0) stays on the pad
        uint256 dust = wbnb.balanceOf(address(pad)) - pad.creatorFeeOf(t) - owed;
        assertLe(dust, 1, "only the fees stay");
        vm.prank(promoter);
        assertEq(pm.claimPromoterFee(t, promoter), owed);
        vm.prank(creator);
        pad.claimCreatorFee(t, creator);
        assertEq(wbnb.balanceOf(address(pad)), dust);

        address late = _newAgent();
        assertFalse(pm.canBind(t, late, promoter));
        vm.prank(late, late);
        vm.expectRevert(IGangLaunchpad3.NotCurveToken.selector);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);
    }

    /// @dev A wash trade under one's own second wallet always loses: earned ≤ 0.35% of the volume, paid at least 1%.
    function testFuzz_washTradingLoses(uint96 buyIn, uint16 share) public {
        uint256 gross = bound(uint256(buyIn), 0.001 ether, 1 ether);
        share = uint16(bound(uint256(share), 1, 5_000));
        address t = _create(address(wbnb), share, WINDOW);
        address washer = _newAgent();
        address second = _newAgent();
        uint256 before = washer.balance;
        _buyBound(t, washer, gross, second);
        uint256 bal = IERC20(t).balanceOf(washer);
        vm.startPrank(washer, washer);
        IERC20(t).approve(address(pad), bal);
        pad3.sellToken(0, t, washer, bal, 0, 0, address(0));
        vm.stopPrank();
        vm.prank(second);
        uint256 earned = pm.claimPromoterFee(t, second);
        uint256 lost = before - washer.balance;
        assertLt(earned, lost, "earned less than the round trip cost");
        assertLe(earned * BPS, (gross * 2) * 35, "at most 0.35% of the volume");
    }

    /// @dev Random mixes: the pad's quote is exactly curve + creator + promoters at every step; a claim never touches
    ///      another book; the fee split always adds up to the creator's 70%.
    function testFuzz_books(uint256 seed) public {
        address t = _create(address(wbnb));
        address[3] memory us = [_newAgent(), _newAgent(), _newAgent()];
        address[2] memory ps = [promoter, _newAgent()];
        for (uint256 i; i < 3; i++) {
            vm.prank(us[i]);
            IERC20(t).approve(address(pad), type(uint256).max);
        }
        for (uint256 k; k < 30; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            address u = us[r % 3];
            uint256 amt = ((r >> 8) % 0.05 ether) + 1e6;
            uint256 op = (r >> 72) % 5;
            if (_graduated(t)) break;
            if (op == 0) {
                vm.prank(u, u);
                try pm.buyWithPromoter{value: amt}(t, amt, 0, ps[(r >> 80) % 2]) {} catch {}
            } else if (op == 1) {
                vm.prank(u, u);
                try pad3.buyTokenAMAP{value: amt}(t, u, amt, 0) {} catch {}
            } else if (op == 2) {
                uint256 bal = IERC20(t).balanceOf(u);
                if (bal == 0) continue;
                vm.prank(u, u);
                pad.sell(t, ((r >> 96) % bal) + 1, 0);
            } else if (op == 3) {
                address p = ps[(r >> 80) % 2];
                if (pm.promoterFeeOf(t, p) == 0) continue;
                vm.prank(p);
                pm.claimPromoterFee(t, p);
            } else {
                vm.warp(block.timestamp + ((r >> 96) % 20 days));
            }
            assertEq(
                wbnb.balanceOf(address(pad)),
                _curveRealQuote(t) + pad.creatorFeeOf(t) + pm.promoterFeeOf(t, ps[0]) + pm.promoterFeeOf(t, ps[1]),
                "books"
            );
        }
    }

    // ---------------------------------------------------------------- the upgrade script
    /// @dev The upgrade snapshot: a token's terms for every sampled token, an ordinary wallet's binding and its promoter's
    ///      earnings through the probes; nothing for other tokens, or before the views exist (the first upgrade).
    function test_upgradeSnapshot_seesPromoteState() public {
        PromoteSnapHarness h = new PromoteSnapHarness();
        address plain = _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        assertEq(h.promoteState(pad3, plain).length, 0, "none for a token without a share");
        address t = _create(address(wbnb));
        _buyBound(t, trader, GROSS, promoter);
        address[] memory probes = new address[](2);
        (probes[0], probes[1]) = (t, trader);
        bytes memory state = h.promoteState(pad3, t);
        bytes memory probed = h.promoteProbes(pad3, probes);
        assertGt(state.length, 0);
        assertGt(probed.length, 0);
        uint256 base = uint256(Pad3PromoteStore.SLOT);

        // a binding that moved
        bytes32 slot = keccak256(abi.encode(trader, keccak256(abi.encode(t, base + 1))));
        bytes32 saved = vm.load(address(pad), slot);
        vm.store(address(pad), slot, bytes32(0));
        assertTrue(keccak256(h.promoteProbes(pad3, probes)) != keccak256(probed), "a changed binding shows");
        vm.store(address(pad), slot, saved);
        assertEq(h.promoteProbes(pad3, probes), probed);

        // earnings that moved
        slot = keccak256(abi.encode(promoter, keccak256(abi.encode(t, base + 2))));
        saved = vm.load(address(pad), slot);
        vm.store(address(pad), slot, bytes32(0));
        assertTrue(keccak256(h.promoteProbes(pad3, probes)) != keccak256(probed), "changed earnings show");
        vm.store(address(pad), slot, saved);

        // terms that moved
        vm.store(address(pad), keccak256(abi.encode(t, base)), bytes32(0));
        assertEq(h.promoteState(pad3, t).length, 0, "changed terms show");

        // an odd list is refused
        address[] memory odd = new address[](1);
        vm.expectRevert();
        h.promoteProbes(pad3, odd);
    }

    /// @dev The probes really go into what the upgrade compares: a moved binding changes the settings hash.
    function test_upgradeSnapshot_probesReachTheSettingsHash() public {
        PromoteSnapHarness h = new PromoteSnapHarness();
        address t = _create(address(wbnb));
        _buyBound(t, trader, GROSS, promoter);
        address[] memory list = new address[](2);
        (list[0], list[1]) = (t, trader);
        h.setList(list);
        bytes32 before = h.settingsWithList(pad3, address(router));
        bytes32 slot = keccak256(abi.encode(trader, keccak256(abi.encode(t, uint256(Pad3PromoteStore.SLOT) + 1))));
        vm.store(address(pad), slot, bytes32(0));
        assertTrue(h.settingsWithList(pad3, address(router)) != before, "a moved binding shows");
    }

    /// @dev The warnings are only words: with or without probes, on a pad with tokens with a share, nothing reverts.
    function test_upgradeSnapshot_warningsNeverRevert() public {
        PromoteSnapHarness h = new PromoteSnapHarness();
        h.warn(pad3);
        address t = _create(address(wbnb));
        h.warn(pad3); // a token with a share, no probes
        address[] memory list = new address[](2);
        (list[0], list[1]) = (t, trader);
        h.setList(list);
        h.warn(pad3); // a probe of a wallet bound to nobody
        _buyBound(t, trader, GROSS, promoter);
        h.warn(pad3);
    }

    function test_upgradeSnapshot_beforeTheViewsExist() public {
        PromoteSnapHarness h = new PromoteSnapHarness();
        address t = _create(address(wbnb));
        vm.mockCallRevert(address(pad), abi.encodeWithSelector(Pad3Module.promoteOf.selector, t), "");
        assertEq(h.promoteState(pad3, t).length, 0);
        // probes set too early: refused, in words
        address[] memory list = new address[](2);
        (list[0], list[1]) = (t, trader);
        vm.expectRevert(
            abi.encodeWithSignature("WiringCheck(string)", "PAD3_PROMOTE_PROBES: this pad has no promoter share yet")
        );
        h.promoteProbes(pad3, list);
    }

    // ---------------------------------------------------------------- storage
    /// @dev The namespace, pinned: SLOT as ERC-7201 computes it, and each member at its place.
    function test_namespacePinned() public {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("gang.pad3.promote")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(Pad3PromoteStore.SLOT, slot);
        address t = _create(address(wbnb));
        _buyBound(t, trader, GROSS, promoter);
        uint256 base = uint256(slot);
        bytes32 terms = vm.load(address(pad), keccak256(abi.encode(t, base)));
        assertEq(uint256(terms), uint256(SHARE) | (uint256(WINDOW) << 16), "termsOf");
        bytes32 inner = keccak256(abi.encode(t, base + 1));
        bytes32 binding = vm.load(address(pad), keccak256(abi.encode(trader, inner)));
        assertEq(
            uint256(binding),
            uint256(uint160(promoter)) | (uint256(block.timestamp) << 160) | (uint256(1) << 200),
            "bindingOf"
        );
        inner = keccak256(abi.encode(t, base + 2));
        assertEq(uint256(vm.load(address(pad), keccak256(abi.encode(promoter, inner)))), _cut(GROSS), "feeOf");
    }

    // ---------------------------------------------------------------- helpers
    function _quote(address t, address who, uint256 funds)
        internal
        view
        returns (uint256 amount, uint256 cost, uint256 fee, uint256 pay)
    {
        (,, amount, cost, fee, pay,,) = pad3.tryBuy(t, who, 0, funds);
    }

    function _curveView(address t)
        internal
        view
        returns (address, address, uint128, uint128, uint128, uint128, bool, uint16, uint16, uint16, address, address)
    {
        return pad.curves(t);
    }

    /// @dev The mock Agent ID is soulbound; the registry answering 0 is the same to the pad.
    function _dropAgent(address who) internal {
        vm.mockCall(address(agents), abi.encodeWithSignature("balanceOf(address)", who), abi.encode(uint256(0)));
    }
}

/// @dev A listed router, or an aggregator's contract: pays and passes the trade on for the wallet that sent the tx.
contract RouterStub {
    GangLaunchpad internal immutable pad;
    address internal immutable wbnb;

    constructor(GangLaunchpad pad_, address wbnb_) {
        pad = pad_;
        wbnb = wbnb_;
    }

    function buyFor(address token, address trader, uint256 funds) external payable {
        IW(wbnb).deposit{value: funds}();
        IW(wbnb).approve(address(pad), funds);
        pad.buyFor(trader, token, funds, 0);
    }

    function sellFor(address token, address trader, uint256 amount) external {
        pad.sellFor(trader, token, amount, 0);
    }

    function sellTo(address token, address seller, uint256 amount) external {
        GangLaunchpad3(payable(address(pad))).sellToken(0, token, seller, address(this), amount, 0);
    }

    receive() external payable {}

    function buyWithPromoter(address token, uint256 funds, address promoter) external payable {
        Pad3Module(payable(address(pad))).buyWithPromoter{value: funds}(token, funds, 0, promoter);
    }

    function buyEntry(address token, uint256 funds) external payable {
        GangLaunchpad3(payable(address(pad))).buyTokenAMAP{value: funds}(token, tx.origin, funds, 0);
    }
}

interface IW {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}
