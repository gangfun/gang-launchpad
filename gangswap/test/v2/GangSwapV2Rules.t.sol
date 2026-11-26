// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GangSwapV2Fixture} from "./GangSwapV2.t.sol";
import {GangSwapV2Fees} from "../../src/v2/GangSwapV2Fees.sol";
import {IGangSwapV2Boost} from "../../src/v2/interfaces/IGangSwapV2.sol";

contract GangSwapV2RulesTest is GangSwapV2Fixture {
    event FeeTaken(uint256 feeQuote, uint256 feeTokenBurned);
    event FeesCollected(address indexed pair, address indexed token, uint256 amount, uint256 toCreator);
    event WindowClosed(address indexed token);

    function test_sellExactInAndExactOutAreTight() public {
        address[] memory path = _path(address(token), address(wbnb));
        uint256 amountIn = 12_300_000 ether + 108;
        uint256 out = pair.getAmountOut(amountIn, address(token));
        assertEq(router.getAmountsOut(amountIn, path)[1], out);
        uint256 minIn = pair.getAmountIn(out, address(wbnb));
        assertEq(router.getAmountsIn(out, path)[0], minIn);
        assertLe(minIn, amountIn);

        uint256 snap = vm.snapshotState();
        _donate(0, amountIn);
        _expectRawRevert("GangSwap: K", out + 1, 0, holder);
        assertTrue(vm.revertToState(snap));

        _donate(0, minIn - 1);
        _expectRawRevert("GangSwap: K", out, 0, holder);
        assertTrue(vm.revertToState(snap));

        uint256 before = wbnb.balanceOf(holder);
        vm.startPrank(holder);
        token.approve(address(router), minIn);
        uint256[] memory actual = router.swapTokensForExactTokens(out, minIn, path, holder, block.timestamp);
        vm.stopPrank();
        assertEq(actual[0], minIn);
        assertEq(wbnb.balanceOf(holder) - before, out);
        assertTrue(vm.revertToState(snap));
        assertEq(_sell(holder, amountIn), out);
    }

    function test_viewsChooseDirectionAndRejectInvalidRequests() public {
        address[] memory path = _path(address(wbnb), address(token));
        uint256 input = 1 ether;
        uint256 out = pair.getAmountOut(input, address(wbnb));
        assertEq(router.getAmountsOut(input, path)[1], out);
        uint256 exactIn = pair.getAmountIn(out, address(token));
        assertEq(router.getAmountsIn(out, path)[0], exactIn);
        assertLe(exactIn, input);
        assertEq(_buy(trader, input), out);

        (uint256 rq, uint256 rt) = _reserves();
        vm.expectRevert(bytes("GangSwap: INVALID_TOKEN"));
        pair.getAmountOut(1, address(1));
        vm.expectRevert(bytes("GangSwap: INVALID_TOKEN"));
        pair.getAmountIn(1, address(1));
        vm.expectRevert(bytes("GangSwap: INSUFFICIENT_INPUT_AMOUNT"));
        pair.getAmountOut(0, address(wbnb));
        vm.expectRevert(bytes("GangSwap: INSUFFICIENT_OUTPUT_AMOUNT"));
        pair.getAmountIn(0, address(token));
        vm.expectRevert(bytes("GangSwap: INSUFFICIENT_LIQUIDITY"));
        pair.getAmountIn(rt, address(token));
        vm.expectRevert(bytes("GangSwap: INSUFFICIENT_LIQUIDITY"));
        pair.getAmountIn(rq * 99 / 100 + 1, address(wbnb));
        assertEq(pair.getAmountOut(1, address(token)), 0, "dust quote");
    }

    function test_sellExactOutRequiresRealQuoteForOutputAndFee() public {
        // Align the reserve so consecutive net outputs produce consecutive gross outputs.
        _donate(2, 0);
        pair.sync();
        uint256 real = pair.realQuoteReserve();
        uint256 maxNet = real * 99 / 100;
        assertEq(maxNet + (maxNet + 98) / 99, real);
        assertGt(pair.getAmountIn(maxNet, address(wbnb)), 0);

        uint256 net = maxNet + 1;
        uint256 gross = net + (net + 98) / 99;
        (uint256 effective,) = _reserves();
        assertEq(gross, real + 1);
        assertLt(gross, effective);
        _donate(10 ether, 0);
        vm.expectRevert(bytes("GangSwap: INSUFFICIENT_LIQUIDITY"));
        pair.getAmountIn(net, address(wbnb));
        address[] memory path = _path(address(token), address(wbnb));
        vm.expectRevert(bytes("GangSwap: INSUFFICIENT_LIQUIDITY"));
        router.getAmountsIn(net, path);

        _swapRaw(net, 0, holder);
        assertEq(wbnb.balanceOf(holder), net);
        _checkInvariants();
    }

    function test_bothInputsAndOutputsBookBothFees() public {
        _buy(trader, 1 ether);
        (uint256 q, uint256 t) = _reserves();
        uint256 before = pair.feeAccrued();
        uint256 quoteIn = 0.11 ether;
        uint256 quoteOut = 0.05 ether + 1;
        uint256 tokenIn = 3_000_000 ether;
        uint256 tokenOut = 1_000_000 ether;
        uint256 fee = quoteIn / 100 + (quoteOut + 98) / 99;

        _donate(quoteIn, tokenIn);
        {
            (uint256 out0, uint256 out1) = pair.quoteIs0() ? (quoteOut, tokenOut) : (tokenOut, quoteOut);
            vm.expectEmit(false, false, false, true, address(pair));
            emit FeeTaken(fee, 0);
            pair.swap(out0, out1, holder, "");
        }

        (uint256 rq, uint256 rt) = _reserves();
        assertEq(rq, q + quoteIn - quoteOut - fee);
        assertEq(rt, t + tokenIn - tokenOut);
        assertEq(pair.feeAccrued(), before + fee);
        assertEq(wbnb.balanceOf(holder), quoteOut);
        _checkInvariants();
    }

    function test_tokenOnlySwapReverts() public {
        _donate(0, 2 ether);
        _expectRawRevert("GangSwap: NO_QUOTE_MOVEMENT", 0, 1 ether, holder);
    }

    function test_pairRecipientReverts() public {
        _donate(1 ether, 0);
        _expectRawRevert("GangSwap: INVALID_TO", 0, 1 ether, address(pair));
    }

    function test_tokenInputDiscountRejectsEqualTokenRoundTrip() public {
        _donate(1, 1 ether);
        _expectRawRevert("GangSwap: K", 0, 1 ether, holder);
    }

    function test_buyWithUnsyncedTokenDonation() public {
        uint256 amount = 1 ether;
        uint256 out = pair.getAmountOut(amount, address(wbnb));
        _donate(0, 1 ether);
        assertEq(_buy(trader, amount), out);
        _checkInvariants();
    }

    function test_collectAndClaimAcrossWindowBoundary() public {
        _buy(creator, 1 ether);
        _sell(holder, 20_000_000 ether);
        uint256 charge = pair.feeAccrued();
        _expectCollection(charge, 0);
        assertEq(fees.collect(address(pair)), charge);
        assertEq(bucket.accruedQuote(address(wbnb)), charge);

        _buy(trader, 1 ether);
        charge = pair.feeAccrued();
        _expectCollection(charge, 0);
        vm.prank(creator);
        assertEq(fees.claim(address(token), creator), 0);
        assertEq(pair.feeAccrued(), 0);
        assertEq(wbnb.balanceOf(creator), 0);

        _runBoost();
        (, uint64 lastStepAt,,, uint128 left) = boost.boosts(address(token));
        assertEq(left, 0);
        vm.warp(uint256(lastStepAt) + fees.GRACE() - 1);
        _sell(holder, 20_000_000 ether);
        charge = pair.feeAccrued();
        _expectCollection(charge, 0);
        assertEq(fees.collect(address(pair)), charge);
        assertEq(fees.creatorFeeOf(address(token)), 0);

        _endWindow();
        assertEq(fees.collect(address(pair)), 0);
        _buy(trader, 1 ether);
        charge = pair.feeAccrued();
        uint256 toCreator = charge * 7 / 10;
        _expectCollection(charge, toCreator);
        assertEq(fees.collect(address(pair)), charge);
        assertEq(fees.creatorFeeOf(address(token)), toCreator);
        vm.prank(creator);
        assertEq(fees.claim(address(token), creator), toCreator);
    }

    function test_graceFeesAfterKeeperCollectGoToPlatform() public {
        (uint256 last, uint256 tokens) = _openPositionAndFinishBoost();
        vm.warp(last + 50);
        assertEq(fees.collect(address(pair)), 0);
        vm.warp(last + 55);
        _sell(creator, tokens);
        vm.warp(last + 61);
        _closeAndCheckPlatform(false);
    }

    function test_graceFeesWithoutKeeperCollectGoToPlatform() public {
        (uint256 last, uint256 tokens) = _openPositionAndFinishBoost();
        vm.warp(last + 1);
        _sell(creator, tokens);
        vm.warp(last + 61);
        _closeAndCheckPlatform(true);
    }

    function test_collectAtGraceBoundaryClosesWindow() public {
        (uint256 last, uint256 tokens) = _openPositionAndFinishBoost();
        vm.warp(last + 59);
        _sell(creator, tokens);
        vm.warp(last + 60);
        _closeAndCheckPlatform(false);

        _buy(trader, 1 ether);
        uint256 charge = pair.feeAccrued();
        _expectCollection(charge, charge * 7 / 10);
        vm.prank(creator);
        assertEq(fees.claim(address(token), creator), charge * 7 / 10);
    }

    function test_emptyClaimOutsideWindowRevertsZeroAmount() public {
        _runBoost();
        _endWindow();
        assertEq(pair.feeAccrued(), 0);
        vm.prank(creator);
        vm.expectRevert(GangSwapV2Fees.ZeroAmount.selector);
        fees.claim(address(token), creator);

        _expectWindowClosed();
        assertEq(fees.collect(address(pair)), 0);
        vm.prank(creator);
        vm.expectRevert(GangSwapV2Fees.ZeroAmount.selector);
        fees.claim(address(token), creator);
    }

    function _openPositionAndFinishBoost() private returns (uint256 last, uint256 tokens) {
        for (uint256 i; i < 38; i++) {
            vm.warp(vm.getBlockTimestamp() + boost.STEP_GAP());
            boost.step(address(token));
        }
        tokens = _buy(creator, 0.6 ether);
        assertEq(_runBoost(), 2);
        (, uint64 timestamp,,, uint128 left) = boost.boosts(address(token));
        assertEq(left, 0);
        return (timestamp, tokens);
    }

    function _closeAndCheckPlatform(bool claimFirst) private {
        uint256 charge = pair.feeAccrued();
        assertGt(charge, 0);
        uint256 pending = fees.pendingPlatform();
        uint256 before = bucket.accruedQuote(address(wbnb));
        _expectWindowClosed();
        _expectCollection(charge, 0);
        if (claimFirst) {
            vm.prank(creator);
            assertEq(fees.claim(address(token), creator), 0);
        } else {
            assertEq(fees.collect(address(pair)), charge);
        }
        assertEq(pair.feeAccrued(), 0);
        assertEq(fees.creatorFeeOf(address(token)), 0);
        assertEq(wbnb.balanceOf(creator), 0);
        assertEq(bucket.accruedQuote(address(wbnb)) - before, charge + pending);
    }

    function test_collectBoostRequiresBoost() public {
        _buy(trader, 1 ether);
        vm.expectRevert(GangSwapV2Fees.OnlyBoost.selector);
        fees.collectBoost(address(pair));
        assertEq(pair.feeAccrued(), 0.01 ether);
    }

    function test_stepBooksAllFeesWithoutReadingWindowOrCallingBucket() public {
        _buy(trader, 1 ether);
        (uint256 spend,) = boost.nextStep(address(token));
        uint256 charge = pair.feeAccrued() + spend / 100;
        vm.mockCallRevert(
            address(boost), abi.encodeCall(IGangSwapV2Boost.boosts, (address(token))), bytes("unexpected window read")
        );
        _expectCollection(charge, 0);
        boost.step(address(token));
        vm.clearMockedCalls();
        assertEq(fees.pendingPlatform(), charge);
        assertEq(pair.feeAccrued(), 0);
        assertEq(bucket.accruedQuote(address(wbnb)), 0);

        bucket.setRefuse(true);
        vm.warp(block.timestamp + 1 days);
        _sell(holder, 20_000_000 ether);
        charge = pair.feeAccrued();
        _expectCollection(charge, 0);
        assertEq(fees.collect(address(pair)), charge);
        assertEq(fees.creatorFeeOf(address(token)), 0);

        _runBoost();
        assertEq(pair.feeAccrued(), 0, "final step books quote fee");
        assertEq(fees.creatorFeeOf(address(token)), 0);
        assertEq(bucket.accruedQuote(address(wbnb)), 0);
        uint256 pending = fees.pendingPlatform();
        assertEq(wbnb.balanceOf(address(fees)), pending);
        bucket.setRefuse(false);
        fees.flushPlatform();
        assertEq(bucket.accruedQuote(address(wbnb)), pending);
    }

    function test_stepCountsAndCapsAcrossTiers() public {
        for (uint256 tier = 6 ether; tier <= 15 ether; tier += 3 ether) {
            _newPool(tier);
            uint256 snap = vm.snapshotState();
            assertEq(_runBoost(), 40);
            assertTrue(vm.revertToState(snap));
            _sell(holder, token.balanceOf(holder));
            assertEq(_runBoost(), 140);
            _checkInvariants();
        }
    }

    function test_dustOneWeiAboveCapNeedsAnotherStep() public {
        _sell(holder, token.balanceOf(holder));
        (,,, uint128 v, uint128 left) = boost.boosts(address(token));
        while (left > v / 40) {
            _stepWithCap();
            vm.warp(vm.getBlockTimestamp() + boost.STEP_GAP());
            (,,,, left) = boost.boosts(address(token));
        }

        (uint256 q,) = _reserves();
        uint256 targetQuote = (uint256(left) - 1) * 10_000 / 50;
        assertGt(targetQuote, q);
        _donate(targetQuote - q, 0);
        pair.sync();

        (uint256 next, bool ready) = boost.nextStep(address(token));
        assertTrue(ready);
        assertEq(next, left - 1);
        _stepWithCap();
        (,,,, left) = boost.boosts(address(token));
        assertEq(left, 1);
        vm.warp(vm.getBlockTimestamp() + boost.STEP_GAP());
        _stepWithCap();
        (,,,, left) = boost.boosts(address(token));
        assertEq(left, 0);
    }

    function test_stepRoundTripsAreNotPositive() public {
        uint256 original = vm.snapshotState();
        for (uint256 tier = 6 ether; tier <= 15 ether; tier += 3 ether) {
            assertTrue(vm.revertToState(original));
            _newPool(tier);
            uint256 start = vm.snapshotState();
            for (uint256 stage; stage < 2; stage++) {
                assertTrue(vm.revertToState(start));
                if (stage == 1) {
                    for (uint256 i; i < 39; i++) {
                        boost.step(address(token));
                        vm.warp(block.timestamp + boost.STEP_GAP());
                    }
                }
                uint256 beforeTrade = vm.snapshotState();
                int256 stranger = _aroundStep(trader, tier, true, stage == 1);
                assertTrue(vm.revertToState(beforeTrade));
                assertEq(_aroundStep(creator, tier, true, stage == 1), stranger);
                assertTrue(vm.revertToState(beforeTrade));
                stranger = _aroundStep(trader, tier, false, stage == 1);
                assertTrue(vm.revertToState(beforeTrade));
                assertEq(_aroundStep(creator, tier, false, stage == 1), stranger);
            }
        }
    }

    function _aroundStep(address who, uint256 tier, bool buyFirst, bool finalStep) private returns (int256 pnl) {
        if (buyFirst) {
            uint256 spent = tier / 10;
            uint256 got = _buy(who, spent);
            _stepWithCap();
            pnl = int256(_sell(who, got)) - int256(spent);
        } else {
            uint256 position = 5_000_000 ether;
            vm.prank(holder);
            token.transfer(who, position);
            uint256 got = _sell(who, position);
            _stepWithCap();
            uint256 cost = pair.getAmountIn(position, address(token));
            vm.deal(who, cost);
            vm.prank(who);
            router.swapETHForExactTokens{value: cost}(
                position, _path(address(wbnb), address(token)), who, block.timestamp
            );
            assertEq(token.balanceOf(who), position);
            pnl = int256(got) - int256(cost);
        }

        (,,,, uint128 left) = boost.boosts(address(token));
        assertEq(left == 0, finalStep);
        fees.collect(address(pair));
        assertEq(fees.creatorFeeOf(address(token)), 0);
        assertLt(pnl, 0);
    }

    function _stepWithCap() private {
        (uint256 rq,) = _reserves();
        (uint256 spend,) = boost.step(address(token));
        assertLe(spend, rq * 50 / 10_000);
    }

    function _expectRawRevert(string memory reason, uint256 quoteOut, uint256 tokenOut, address to) private {
        (uint256 out0, uint256 out1) = pair.quoteIs0() ? (quoteOut, tokenOut) : (tokenOut, quoteOut);
        vm.expectRevert(bytes(reason));
        pair.swap(out0, out1, to, "");
    }

    function _expectCollection(uint256 amount, uint256 toCreator) private {
        vm.expectEmit(true, true, false, true, address(fees));
        emit FeesCollected(address(pair), address(token), amount, toCreator);
    }

    function _expectWindowClosed() private {
        vm.expectEmit(true, false, false, false, address(fees));
        emit WindowClosed(address(token));
    }
}
