// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";

/// @notice The creator's 70% of the curve's 1% fee (pons model, docs/SPEC-CURVE-CREATOR-FEE-2026-10-31.md): kept on the
///         pad per token, claimed by the creator only; the platform keeps 30%; the trader still pays 1% in all.
contract CreatorFeeTest is GangFixture {
    uint256 internal constant BPS = 10_000;

    event CreatorFeeAccrued(address indexed token, address indexed creator, uint256 amount);
    event CreatorFeeClaimed(address indexed token, address indexed creator, address indexed to, uint256 amount);

    address internal creator;
    address internal trader;

    function setUp() public {
        _deployGang(address(this));
        creator = _newAgent();
        trader = _newAgent();
    }

    function _creatorPart(uint256 fee) internal pure returns (uint256) {
        return (fee * 7_000) / BPS;
    }

    function test_constants() public view {
        assertEq(pad.CREATOR_FEE_SHARE_BPS(), 7_000);
        assertEq(pad.PROTOCOL_FEE_BPS(), 100, "the trader still pays 1% in all");
    }

    function test_buy_splits70_30_eventsAndEscrow() public {
        address t = _createV3(creator, address(quoteTok), _tax(0, 0, 0, address(0)));
        uint256 gross = 0.01 ether;
        uint256 fee = (gross * 100) / BPS;
        uint256 toCreator = _creatorPart(fee);

        vm.expectEmit(true, true, false, true, address(pad));
        emit CreatorFeeAccrued(t, creator, toCreator);
        vm.prank(trader);
        pad.buy(t, gross, 0);

        assertEq(pad.creatorFeeOf(t), toCreator, "70% kept for the creator");
        assertEq(bucket.accruedQuote(address(quoteTok)), fee - toCreator, "30% to the platform");
        assertEq(_curveRealQuote(t), gross - fee, "99% enters the curve");
        assertEq(quoteTok.balanceOf(address(pad)), _curveRealQuote(t) + toCreator, "pad holds escrow + creator part");
    }

    function test_sell_splits70_30() public {
        address t = _createV3(creator, address(quoteTok), _tax(0, 0, 0, address(0)));
        vm.prank(trader);
        pad.buy(t, 0.01 ether, 0);
        uint256 owedBefore = pad.creatorFeeOf(t);
        uint256 bucketBefore = bucket.accruedQuote(address(quoteTok));

        uint256 bal = IERC20(t).balanceOf(trader);
        vm.startPrank(trader);
        IERC20(t).approve(address(pad), bal);
        uint256 toUser = pad.sell(t, bal, 0);
        vm.stopPrank();

        uint256 toCreator = pad.creatorFeeOf(t) - owedBefore;
        uint256 toPlatform = bucket.accruedQuote(address(quoteTok)) - bucketBefore;
        uint256 fee = toCreator + toPlatform;
        assertEq(fee, ((toUser + fee) * 100) / BPS, "1% of what the curve paid out");
        assertEq(toCreator, _creatorPart(fee), "70% kept for the creator");
    }

    /// @notice Router entries (`buyFor` / `sellFor`) split the same way; the creator part never goes to the router.
    function test_routerEntries_splitTheSame() public {
        address t = _createV3(creator, address(quoteTok), _tax(0, 0, 0, address(0)));
        address r = makeAddr("listedRouter");
        vm.prank(owner);
        pad.setRouter(r, true);
        quoteTok.mintUnlimited(r, 1 ether);
        vm.prank(r);
        quoteTok.approve(address(pad), type(uint256).max);

        uint256 owedBefore = pad.creatorFeeOf(t);
        vm.prank(r, trader);
        pad.buyFor(trader, t, 0.02 ether, 0);
        assertEq(pad.creatorFeeOf(t) - owedBefore, _creatorPart((0.02 ether * 100) / BPS), "buyFor: 70%");

        uint256 bal = IERC20(t).balanceOf(trader);
        vm.prank(trader);
        IERC20(t).approve(r, bal);
        owedBefore = pad.creatorFeeOf(t);
        uint256 bucketBefore = bucket.accruedQuote(address(quoteTok));
        vm.prank(r, trader);
        pad.sellFor(trader, t, bal, 0);
        uint256 toCreator = pad.creatorFeeOf(t) - owedBefore;
        uint256 toPlatform = bucket.accruedQuote(address(quoteTok)) - bucketBefore;
        assertEq(toCreator, _creatorPart(toCreator + toPlatform), "sellFor: 70%");
    }

    function test_onlyCreatorClaims_toAnyAddress_once() public {
        address t = _createV3(creator, address(quoteTok), _tax(0, 0, 0, address(0)));
        vm.prank(trader);
        pad.buy(t, 0.01 ether, 0);
        vm.prank(creator);
        pad.buy(t, 0.01 ether, 0); // the creator's own trades accrue too
        uint256 owed = pad.creatorFeeOf(t);
        assertEq(owed, 2 * _creatorPart((0.01 ether * 100) / BPS));

        vm.prank(trader);
        vm.expectRevert(IGangLaunchpad.NotCreator.selector);
        pad.claimCreatorFee(t, trader);

        address to = makeAddr("creatorPayee");
        vm.expectEmit(true, true, true, true, address(pad));
        emit CreatorFeeClaimed(t, creator, to, owed);
        vm.prank(creator);
        assertEq(pad.claimCreatorFee(t, to), owed);
        assertEq(quoteTok.balanceOf(to), owed, "paid in the quote");
        assertEq(pad.creatorFeeOf(t), 0);
        assertEq(quoteTok.balanceOf(address(pad)), _curveRealQuote(t), "only the curve escrow is left");

        vm.prank(creator);
        vm.expectRevert(IGangLaunchpad.ZeroAmount.selector);
        pad.claimCreatorFee(t, to);
    }

    function test_claimGuards() public {
        address t = _createV3(creator, address(quoteTok), _tax(0, 0, 0, address(0)));
        vm.prank(trader);
        pad.buy(t, 0.01 ether, 0);

        vm.startPrank(creator);
        vm.expectRevert(IGangLaunchpad.ZeroAddress.selector);
        pad.claimCreatorFee(t, address(0));
        vm.expectRevert(IGangLaunchpad.ZeroAddress.selector);
        pad.claimCreatorFee(t, address(pad));
        vm.expectRevert(IGangLaunchpad.UnknownToken.selector);
        pad.claimCreatorFee(address(quoteTok), creator);
        vm.stopPrank();

        // a 打新 token is not a curve: nothing to claim, and its creator is not a curve creator
        address f = _createFair(creator, address(quoteTok), 1);
        vm.prank(creator);
        vm.expectRevert(IGangLaunchpad.UnknownToken.selector);
        pad.claimCreatorFee(f, creator);
    }

    /// @notice What is kept survives graduation (the pair gets exactly realQuote) and is claimable after it; it goes
    ///         to the creator whoever the tax recipient is; two tokens on one quote stay apart.
    function test_survivesGraduation_perToken_notRecipient() public {
        address other = _newAgent();
        address t = _createV3(creator, address(quoteTok), _tax(200, 400, 5_000, treasury));
        address u = _createV3(other, address(quoteTok), _tax(0, 0, 0, address(0)));
        vm.prank(trader);
        pad.buy(u, 0.02 ether, 0);
        uint256 owedU = pad.creatorFeeOf(u);

        _graduate(t);
        uint256 owedT = pad.creatorFeeOf(t);
        assertGt(owedT, 0);
        assertEq(pad.creatorFeeOf(u), owedU, "other token untouched");
        assertEq(quoteTok.balanceOf(treasury), 0, "the tax recipient gets nothing on the curve");
        assertLe(quoteTok.balanceOf(address(pad)) - _curveRealQuote(u) - owedT - owedU, 1, "graduation dust only");

        uint256 before = quoteTok.balanceOf(creator);
        vm.prank(creator);
        pad.claimCreatorFee(t, creator);
        assertEq(quoteTok.balanceOf(creator) - before, owedT);

        vm.prank(other);
        pad.claimCreatorFee(u, other);
        assertLe(quoteTok.balanceOf(address(pad)) - _curveRealQuote(u), 1);
    }

    /// @notice A creator the quote refuses to pay never blocks trading: the fee is kept, never pushed.
    function test_blockedCreator_tradesStillWork_claimElsewhere() public {
        address t = _createV3(creator, address(blq), _tax(0, 0, 0, address(0)));
        blq.setBlocked(creator, true);
        vm.prank(trader);
        pad.buy(t, 0.01 ether, 0);
        uint256 bal = IERC20(t).balanceOf(trader);
        vm.startPrank(trader);
        IERC20(t).approve(address(pad), bal);
        pad.sell(t, bal, 0);
        vm.stopPrank();
        uint256 owed = pad.creatorFeeOf(t);
        assertGt(owed, 0, "kept for the blocked creator");

        address to = makeAddr("elsewhere");
        vm.prank(creator);
        pad.claimCreatorFee(t, to);
        assertEq(blq.balanceOf(to), owed);
    }

    /// @notice One WBNB balance backs two curves, a 打新 sale and its owed exit fee: a refused bucket reverts the whole
    ///         curve trade (no accrual), and owedFee / flushFees / launch / graduation never spend a creator's part;
    ///         after both claims only the live curve's escrow and dust are left (audit 2026-10-31).
    function test_sameQuote_allPathsLeaveCreatorFee() public {
        address q = address(wbnb);
        address c1 = _createV3(creator, q, _tax(0, 0, 0, address(0)));
        address c2 = _createV3(trader, q, _tax(200, 200, 5_000, treasury));
        address s = _createFair(creator, q, 1);
        for (uint256 i; i < 5; i++) {
            address w = _newAgent();
            vm.prank(w);
            pad.buy(c1, 0.5 ether, 0);
            vm.prank(w);
            pad.buy(c2, 0.3 ether, 0);
            uint256 b = IERC20(c1).balanceOf(w);
            vm.startPrank(w);
            IERC20(c1).approve(address(pad), b / 2);
            pad.sell(c1, b / 2, 0);
            vm.stopPrank();
        }
        address m = _newAgent();
        vm.prank(m);
        pad.mint(s, 50, 1);

        // the bucket refuses the pad: a curve trade reverts as a whole, the 打新 exit fee becomes owed
        vm.prank(owner);
        bucket.setOperator(address(pad), false);
        uint256 cfBefore = pad.creatorFeeOf(c1);
        vm.prank(m);
        vm.expectRevert();
        pad.buy(c1, 0.1 ether, 0);
        assertEq(pad.creatorFeeOf(c1), cfBefore, "no accrual on a refused trade");
        vm.prank(m);
        pad.withdraw(s, 20, 0);
        assertGt(pad.owedFee(q), 0, "exit fee owed");
        vm.prank(owner);
        bucket.setOperator(address(pad), true);
        pad.flushFees(q);

        _fill(s);
        _graduate(c1);
        uint256 f1 = pad.creatorFeeOf(c1);
        uint256 f2 = pad.creatorFeeOf(c2);
        uint256 bal = wbnb.balanceOf(address(pad));
        assertGe(bal, f1 + f2 + _curveRealQuote(c2), "backed");

        vm.prank(creator);
        pad.claimCreatorFee(c1, creator);
        vm.prank(trader);
        pad.claimCreatorFee(c2, trader);
        assertEq(wbnb.balanceOf(address(pad)), bal - f1 - f2);
        assertLe(wbnb.balanceOf(address(pad)) - _curveRealQuote(c2), 10, "only c2's escrow + dust");
        _graduate(c2);
        assertLe(wbnb.balanceOf(address(pad)) - pad.creatorFeeOf(c2), 10);
    }

    /// @notice WBNB curve through GangRouter (BNB in): same split, in WBNB.
    function test_wbnbCurve_viaRouter() public {
        address t = _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        vm.prank(trader, trader);
        router.v3BuyBNB{value: 0.01 ether}(t, 0, block.timestamp);
        uint256 fee = (0.01 ether * 100) / BPS;
        assertEq(pad.creatorFeeOf(t), _creatorPart(fee));
        assertEq(bucket.accruedQuote(address(wbnb)), fee - _creatorPart(fee));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_buyThenSell_conservation(uint256 gross, uint256 sellPart) public {
        gross = bound(gross, 1, 2 ether);
        address t = _createV3(creator, address(quoteTok), _tax(0, 0, 0, address(0)));
        vm.prank(trader);
        pad.buy(t, gross, 0);
        uint256 bal = IERC20(t).balanceOf(trader);
        sellPart = bound(sellPart, 0, bal);
        if (sellPart > 0) {
            vm.startPrank(trader);
            IERC20(t).approve(address(pad), sellPart);
            pad.sell(t, sellPart, 0);
            vm.stopPrank();
        }
        uint256 owed = pad.creatorFeeOf(t);
        uint256 platform = bucket.accruedQuote(address(quoteTok));
        // per trade: creator = 0.7f - e, platform = 0.3f + e (0 <= e < 1 wei), so 7 * platform - 3 * owed = 10e < 10
        assertLe(owed * 3, platform * 7, "creator part at most 70%");
        assertLt(platform * 7 - owed * 3, 20, "creator part is 70% up to rounding (2 trades)");
        assertEq(quoteTok.balanceOf(address(pad)), _curveRealQuote(t) + owed, "pad = escrow + creator part");
    }
}
