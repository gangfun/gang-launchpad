// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {GangGateway} from "../../src/router/GangGateway.sol";
import {IGangGateway} from "../../src/router/interfaces/IGangGateway.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangPadRegistryDeployLib as RG} from "../../script/GangPadRegistryDeployLib.sol";
import {GangGatewayDeployLib as G} from "../../script/GangGatewayDeployLib.sol";
import {FlywheelFixture} from "../flywheel/FlywheelFixture.sol";

/// @dev An aggregator's four.meme adapter: names its caller as the trader, 1% router fee on sells.
contract FlyAdapter {
    IGangGateway public immutable gw;
    address public immutable feeTo;

    constructor(IGangGateway gw_, address feeTo_) {
        gw = gw_;
        feeTo = feeTo_;
    }

    function buyBnb(address token, uint256 minAmount) external payable returns (uint256 out, uint256 used) {
        return gw.buyTokenAMAP{value: msg.value}(token, msg.sender, msg.value, minAmount);
    }

    function sell(address token, uint256 amount, uint256 minFunds) external returns (uint256) {
        return gw.sellToken(0, token, msg.sender, amount, minFunds, 100, feeTo);
    }
}

/// @dev A contract the user is tricked into calling (not whitelisted).
contract FlyPhisher {
    IGangGateway public immutable gw;

    constructor(IGangGateway gw_) {
        gw = gw_;
    }

    function claim(address token, uint256 amount) external {
        gw.sellToken(0, token, tx.origin, amount, 0, 500, address(this));
    }

    receive() external payable {}
}

/// @notice GangGateway V2 on a 铸币飞轮 pad (GangFlywheelPad, kind 3) found through GangPadRegistry: before launch a
///         buy mints whole shares (mintFor) and a sell sells them back (withdrawFor); after launch a buy mints at the
///         post-launch price (mintPostFor) and sells are the pair's. Quotes match the trades wei for wei; the pad
///         spends exactly what it pulls and the rest goes back to the buyer; nothing stays in the gateway.
contract GangGatewayFlywheelTest is FlywheelFixture {
    GangPadRegistry internal reg;
    GangGateway internal gw;
    FlyAdapter internal adapter;
    address internal feeTo = makeAddr("feeTo");

    function setUp() public {
        _deploy();
        address[] memory pads = new address[](1);
        pads[0] = address(pad);
        reg = GangPadRegistry(RG.deploy(owner, pads).proxy);
        gw = GangGateway(payable(G.deploy(address(reg), address(wbnb), owner, R.MAINNET_MIN_DELAY).proxy));
        adapter = new FlyAdapter(IGangGateway(address(gw)), feeTo);
        vm.startPrank(owner);
        pad.setRouter(address(gw), true);
        gw.setCaller(address(adapter), true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers
    function _tryBuy(address t, address who, uint256 funds)
        internal
        view
        returns (uint256 amount, uint256 cost, uint256 fee, uint256 amountFunds)
    {
        address tm;
        address q;
        uint256 msgValue;
        uint256 approval;
        (tm, q, amount, cost, fee, msgValue, approval, amountFunds) = gw.tryBuy(t, who, 0, funds);
        assertEq(tm, address(gw));
        assertEq(q, address(0), "BNB quote");
        assertEq(approval, 0);
        assertEq(msgValue, amount == 0 ? 0 : funds);
    }

    function _trySell(address t, uint256 amount) internal view returns (uint256 funds, uint256 fee) {
        (,, funds, fee) = gw.trySell(t, amount);
    }

    /// @dev `who` buys through the adapter (tx.origin = who); returns the trade and `who`'s WBNB refund.
    function _buy(address t, address who, uint256 funds, uint256 minAmount)
        internal
        returns (uint256 out, uint256 used, uint256 refund)
    {
        uint256 w0 = wbnb.balanceOf(who);
        vm.prank(who, who);
        (out, used) = adapter.buyBnb{value: funds}(t, minAmount);
        refund = wbnb.balanceOf(who) - w0;
    }

    function _approveGw(address who, address t) internal {
        vm.prank(who);
        IERC20(t).approve(address(gw), type(uint256).max);
    }

    function _assertGatewayEmpty(address t) internal view {
        assertEq(address(gw).balance, 0, "gateway BNB");
        assertEq(wbnb.balanceOf(address(gw)), 0, "gateway WBNB");
        assertEq(IERC20(t).balanceOf(address(gw)), 0, "gateway token");
        assertEq(wbnb.allowance(address(gw), address(pad)), 0, "gateway WBNB approval");
    }

    function _shareCost(address t, uint256 n) internal view returns (uint256) {
        IFlywheelPad.Sale memory s = _sale(t);
        uint256 cost = n * s.basePrice;
        return cost + (cost * s.mintFeeBps) / 10_000;
    }

    // ---------------------------------------------------------------- getTokenInfo
    function test_info_beforeAndAfterLaunch() public {
        address t = _create(_wide(), 1);
        IFlywheelPad.Sale memory s = _sale(t);
        (uint8 status, address q, address pair, uint256 feeBps, uint256 left) = gw.getTokenInfo(t);
        assertEq(status, 1);
        assertEq(q, address(0));
        assertEq(pair, address(0));
        assertEq(feeBps, s.mintFeeBps);
        assertEq(left, (SHARES - s.sold) * s.basePrice);

        _fillAndLaunch(t);
        (status, q, pair, feeBps, left) = gw.getTokenInfo(t);
        assertEq(status, 2);
        assertEq(q, address(0));
        assertEq(pair, _sale(t).pair);
        assertTrue(pair != address(0));
        assertEq(feeBps, 0);
        assertEq(left, 0);
    }

    // ---------------------------------------------------------------- before launch: buy
    function testFuzz_beforeLaunch_buyMatchesQuote(uint256 funds) public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        funds = bound(funds, _shareCost(t, 1), 1 ether);
        (uint256 amount, uint256 cost, uint256 fee, uint256 amountFunds) = _tryBuy(t, w, funds);
        (uint256 accepted, uint256 price, uint256 padFee) = pad.previewMint(t, w, amount / TPS);
        assertEq(amount, accepted * TPS, "whole shares");
        assertEq(cost, price + padFee);
        assertEq(fee, padFee);
        assertEq(amountFunds, cost);
        assertLe(cost, funds);

        (uint256 out, uint256 used, uint256 refund) = _buy(t, w, funds, amount);
        assertEq(out, amount, "tokens = quote");
        assertEq(used, cost, "spent = quote");
        assertEq(refund, funds - cost, "rest back to the buyer in WBNB");
        assertEq(IERC20(t).balanceOf(w), out);
        _assertGatewayEmpty(t);
    }

    function test_beforeLaunch_buyTakesTheMostWholeShares() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        // exactly 3 shares, then a wei short of 3
        (uint256 out,,) = _buy(t, w, _shareCost(t, 3), 0);
        assertEq(out, 3 * TPS);
        address w2 = _newAgent();
        (out,,) = _buy(t, w2, _shareCost(t, 3) - 1, 0);
        assertEq(out, 2 * TPS);
    }

    function test_beforeLaunch_quotaCapsTheBuyAndTheRestIsRefunded() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        uint256 funds = _shareCost(t, 50);
        (uint256 out, uint256 used, uint256 refund) = _buy(t, w, funds, 0);
        assertEq(out, 10 * TPS, "quota / per-mint cap 10");
        assertEq(used, _shareCost(t, 10));
        assertEq(refund, funds - used);
        // no quota left: no quote, and the pad refuses
        (uint256 amount,,,) = _tryBuy(t, w, funds);
        assertEq(amount, 0);
        vm.prank(w, w);
        vm.expectRevert(IFlywheelPad.ZeroAmount.selector);
        adapter.buyBnb{value: funds}(t, 0);
    }

    /// @dev Huge funds: no overflow (audit I-2), the quota caps the quote.
    function test_quotes_hugeFunds() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        (,, uint256 amount,,,,,) = gw.tryBuy(t, w, 0, type(uint256).max);
        assertEq(amount, 10 * TPS);
        _fillAndLaunch(t);
        address w2 = _newAgent();
        (,, amount,,,,,) = gw.tryBuy(t, w2, 0, type(uint256).max);
        (,,, uint256 out10,) = pad.previewMintPost(t, w2, 10);
        assertEq(amount, out10);
    }

    function test_beforeLaunch_fundsBelowOneShare() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        uint256 funds = _shareCost(t, 1) - 1;
        (uint256 amount,,,) = _tryBuy(t, w, funds);
        assertEq(amount, 0);
        vm.prank(w, w);
        vm.expectRevert(IGangGateway.FundsTooLow.selector);
        adapter.buyBnb{value: funds}(t, 0);
    }

    function test_beforeLaunch_minAmountAboveTheFill() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        uint256 funds = _shareCost(t, 2);
        vm.prank(w, w);
        vm.expectRevert(IFlywheelPad.Slippage.selector);
        adapter.buyBnb{value: funds}(t, 2 * TPS + 1);
    }

    function test_beforeLaunch_noAgentId() public {
        address t = _create(_wide(), 1);
        address p = _plain();
        uint256 funds = _shareCost(t, 1);
        (uint256 amount,,,) = _tryBuy(t, p, funds);
        assertEq(amount, 0);
        vm.prank(p, p);
        vm.expectRevert(IFlywheelPad.NotAgent.selector);
        adapter.buyBnb{value: funds}(t, 0);
    }

    function test_beforeLaunch_buyForSomeoneElseRefused() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        address other = _newAgent();
        uint256 funds = _shareCost(t, 1);
        vm.prank(w, w);
        vm.expectRevert(IFlywheelPad.TraderNotOrigin.selector);
        gw.buyTokenAMAP{value: funds}(t, other, funds, 0);
    }

    function test_quotes_zeroForAddressZeroAndWhenUnlisted() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        uint256 funds = _shareCost(t, 2);
        _buy(t, w, funds, 0);
        (uint256 amount,,,) = _tryBuy(t, address(0), funds);
        assertEq(amount, 0, "a flywheel quote needs the wallet");

        vm.prank(owner);
        pad.setRouter(address(gw), false);
        (amount,,,) = _tryBuy(t, _newAgent(), funds);
        assertEq(amount, 0, "unlisted: no buy quote");
        (uint256 sellFunds,) = _trySell(t, TPS);
        assertEq(sellFunds, 0, "unlisted: no sell quote");
        vm.prank(w, w);
        vm.expectRevert(IFlywheelPad.OnlyRouter.selector);
        adapter.buyBnb{value: funds}(t, 0);
    }

    function test_badMsgValue() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        uint256 funds = _shareCost(t, 1);
        vm.prank(w, w);
        vm.expectRevert(IGangGateway.BadMsgValue.selector);
        gw.buyTokenAMAP{value: funds - 1}(t, w, funds, 0);
    }

    // ---------------------------------------------------------------- before launch: sell back
    function test_beforeLaunch_sellBackMatchesQuote_self() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        _buy(t, w, _shareCost(t, 5), 0);
        _approveGw(w, t);
        (uint256 funds, uint256 fee) = _trySell(t, 3 * TPS);
        (uint256 payout, uint256 padFee) = pad.previewWithdraw(t, w, 3);
        assertEq(funds, payout);
        assertEq(fee, padFee);
        assertGt(funds, 0);

        uint256 b0 = w.balance;
        vm.prank(w, w);
        uint256 got = gw.sellToken(0, t, w, 3 * TPS, funds, 0, address(0));
        assertEq(got, funds);
        assertEq(w.balance - b0, funds, "paid in BNB");
        assertEq(IERC20(t).balanceOf(w), 2 * TPS);
        assertEq(pad.quotaLeft(t, w), 8, "sold-back shares free their quota");
        _assertGatewayEmpty(t);
    }

    function test_beforeLaunch_sellBackViaWhitelistedAdapter() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        _buy(t, w, _shareCost(t, 4), 0);
        _approveGw(w, t);
        (uint256 funds,) = _trySell(t, 4 * TPS);
        uint256 routerFee = funds / 100;
        uint256 b0 = w.balance;
        vm.prank(w, w);
        uint256 got = adapter.sell(t, 4 * TPS, funds - routerFee);
        assertEq(got, funds - routerFee);
        assertEq(w.balance - b0, funds - routerFee);
        assertEq(feeTo.balance, routerFee);
        assertEq(IERC20(t).balanceOf(w), 0);
        _assertGatewayEmpty(t);
    }

    function test_beforeLaunch_sellBackWholeSharesOnly() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        _buy(t, w, _shareCost(t, 2), 0);
        _approveGw(w, t);
        (uint256 funds,) = _trySell(t, TPS + 1);
        assertEq(funds, 0);
        (funds,) = _trySell(t, 0);
        assertEq(funds, 0);
        vm.startPrank(w, w);
        vm.expectRevert(IGangGateway.NotWholeShares.selector);
        gw.sellToken(0, t, w, TPS + 1, 0, 0, address(0));
        vm.expectRevert(IGangGateway.NotWholeShares.selector);
        gw.sellToken(0, t, w, 0, 0, 0, address(0));
        // more than it minted: the pad refuses
        vm.expectRevert(IFlywheelPad.BadAmount.selector);
        gw.sellToken(0, t, w, 3 * TPS, 0, 0, address(0));
        vm.stopPrank();
    }

    function test_beforeLaunch_phisherCannotSell() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        _buy(t, w, _shareCost(t, 3), 0);
        _approveGw(w, t);
        FlyPhisher ph = new FlyPhisher(IGangGateway(address(gw)));
        vm.prank(w, w);
        vm.expectRevert(IGangGateway.NotWhitelisted.selector);
        ph.claim(t, 3 * TPS);
        assertEq(IERC20(t).balanceOf(w), 3 * TPS);
    }

    function test_beforeLaunch_sellMinFundsAfterRouterFee() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        _buy(t, w, _shareCost(t, 2), 0);
        _approveGw(w, t);
        (uint256 funds,) = _trySell(t, 2 * TPS);
        vm.prank(w, w);
        vm.expectRevert(IGangGateway.Slippage.selector);
        adapter.sell(t, 2 * TPS, funds); // the 1% router fee leaves less
    }

    // ---------------------------------------------------------------- filled, waiting for launch
    function test_filled_noBuyNoSellUntilTheGrace() public {
        address t = _create(_wide(), 1);
        address early = _newAgent();
        _buy(t, early, _shareCost(t, 5), 0);
        _fill(t);
        (uint8 status,,,, uint256 left) = gw.getTokenInfo(t);
        assertEq(status, 1);
        assertEq(left, 0);
        (uint256 amount,,,) = _tryBuy(t, _newAgent(), 1 ether);
        assertEq(amount, 0, "filled: mints closed");
        (uint256 funds,) = _trySell(t, TPS);
        assertEq(funds, 0, "filled: sell-backs closed");
        // not launched a week past its launch time: sell-backs reopen
        IFlywheelPad.Sale memory s = _sale(t);
        vm.warp(uint256(s.filledAt) + s.launchDelay + 7 days);
        (funds,) = _trySell(t, TPS);
        assertGt(funds, 0);
        _approveGw(early, t);
        uint256 b0 = early.balance;
        vm.prank(early, early);
        gw.sellToken(0, t, early, TPS, funds, 0, address(0));
        assertEq(early.balance - b0, funds);
    }

    // ---------------------------------------------------------------- after launch
    function testFuzz_afterLaunch_buyMatchesQuote(uint256 funds) public {
        address t = _create(_wide(), 1);
        _fillAndLaunch(t);
        address w = _newAgent();
        funds = bound(funds, 0.001 ether, 2 ether);
        (uint256 amount, uint256 cost, uint256 fee, uint256 amountFunds) = _tryBuy(t, w, funds);
        if (amount == 0) {
            vm.prank(w, w);
            vm.expectRevert();
            adapter.buyBnb{value: funds}(t, 0);
            return;
        }
        assertEq(amountFunds, cost);
        assertLe(cost, funds);
        assertGt(fee, 0);
        (uint256 out, uint256 used, uint256 refund) = _buy(t, w, funds, amount);
        assertEq(out, amount, "tokens = quote");
        assertEq(used, cost, "spent = quote");
        assertEq(refund, funds - cost);
        _assertGatewayEmpty(t);
    }

    function test_afterLaunch_fundsPickTheShares() public {
        address t = _create(_wide(), 1);
        _fillAndLaunch(t);
        address w = _newAgent();
        // what 3 shares cost now: exactly that buys 3
        (uint256 accepted, uint256 paid, uint256 fee,, bool ok) = pad.previewMintPost(t, w, 3);
        assertEq(accepted, 3);
        assertTrue(ok);
        (uint256 amount,,,) = _tryBuy(t, w, paid + fee);
        (,,, uint256 out3,) = pad.previewMintPost(t, w, 3);
        assertEq(amount, out3);
        (uint256 out, uint256 used,) = _buy(t, w, paid + fee, 0);
        assertEq(out, out3);
        assertEq(used, paid + fee);
    }

    function test_afterLaunch_fundsBelowOneShare() public {
        address t = _create(_wide(), 1);
        _fillAndLaunch(t);
        address w = _newAgent();
        (, uint256 paid, uint256 fee,,) = pad.previewMintPost(t, w, 1);
        vm.prank(w, w);
        vm.expectRevert(IGangGateway.FundsTooLow.selector);
        adapter.buyBnb{value: paid + fee - 1}(t, 0);
    }

    function test_afterLaunch_minAmount() public {
        address t = _create(_wide(), 1);
        _fillAndLaunch(t);
        address w = _newAgent();
        (uint256 amount,,,) = _tryBuy(t, w, 1 ether);
        assertGt(amount, 0);
        vm.prank(w, w);
        vm.expectRevert(IFlywheelPad.Slippage.selector);
        adapter.buyBnb{value: 1 ether}(t, amount + 1);
    }

    function test_afterLaunch_sellsAreThePairs() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        _buy(t, w, _shareCost(t, 2), 0);
        _fillAndLaunch(t);
        _approveGw(w, t);
        (uint256 funds,) = _trySell(t, TPS);
        assertEq(funds, 0);
        vm.prank(w, w);
        vm.expectRevert(IGangGateway.NotCurveToken.selector);
        gw.sellToken(0, t, w, TPS, 0, 0, address(0));
    }

    function test_afterLaunch_noPostMint() public {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.postMint = false;
        address t = _create(c, 1);
        _fillAndLaunch(t);
        address w = _newAgent();
        (uint256 amount,,,) = _tryBuy(t, w, 1 ether);
        assertEq(amount, 0);
        vm.prank(w, w);
        vm.expectRevert(IGangGateway.NotCurveToken.selector);
        adapter.buyBnb{value: 1 ether}(t, 0);
    }

    // ---------------------------------------------------------------- an ungated sale (gate off at create)
    function test_ungatedSale_notTradableHere() public {
        vm.prank(owner);
        pad.setAgentGate(false, address(agents));
        IFlywheelPad.FlyConfig memory c = _wide();
        c.postMint = false;
        c.devCutBps = 0;
        address t = _create(c, 1);
        address w = _plain();
        uint256 funds = _shareCost(t, 1);
        (uint256 amount,,,) = _tryBuy(t, w, funds);
        assertEq(amount, 0);
        vm.prank(w, w);
        vm.expectRevert(IFlywheelPad.RouterNeedsGate.selector);
        adapter.buyBnb{value: funds}(t, 0);
        (uint256 sellFunds,) = _trySell(t, TPS);
        assertEq(sellFunds, 0);
    }

    // ---------------------------------------------------------------- events
    function test_events() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        uint256 funds = _shareCost(t, 2);
        vm.expectEmit(address(gw));
        emit IGangGateway.GatewayBuy(t, w, address(adapter), funds, 2 * TPS);
        _buy(t, w, funds, 0);
        _approveGw(w, t);
        (uint256 sellFunds,) = _trySell(t, 2 * TPS);
        vm.expectEmit(address(gw));
        emit IGangGateway.GatewaySell(t, w, w, 2 * TPS, sellFunds, sellFunds, 0, address(0));
        vm.prank(w, w);
        gw.sellToken(0, t, w, 2 * TPS, 0, 0, address(0));
    }
}
