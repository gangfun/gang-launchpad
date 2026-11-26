// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GangSwapV2Fixture} from "./GangSwapV2.t.sol";
import {MockToken} from "../Mocks.sol";
import {GangSwapV2Fees} from "../../src/v2/GangSwapV2Fees.sol";
import {IGangSwapV2Pair} from "../../src/v2/interfaces/IGangSwapV2.sol";

contract GangSwapV2AdversarialTest is GangSwapV2Fixture {
    event WindowClosed(address indexed token);

    function test_fullFloatSalePreservesAccruedFees() public {
        _tradeRoundTrips(5, 3 ether);
        assertGt(pair.feeAccrued(), 0);

        uint256 float = token.balanceOf(holder);
        uint256 net = pair.getAmountOut(float, address(token));
        _donate(0, float);
        uint256 balance = wbnb.balanceOf(address(pair));
        uint256 real = pair.realQuoteReserve();
        for (uint256 out = balance - 1; out > real; out -= out / 50 + 1) {
            assertFalse(_trySwap(out, 0, trader));
        }
        assertFalse(_trySwap(net + 1, 0, trader));
        _swapRaw(net, 0, trader);
        assertEq(wbnb.balanceOf(trader), net);
        _checkInvariants();

        uint256 accrued = pair.feeAccrued();
        balance = wbnb.balanceOf(address(pair));
        assertEq(fees.collect(address(pair)), accrued);
        assertEq(wbnb.balanceOf(address(pair)), balance - accrued);
        assertEq(pair.feeAccrued(), 0);
        _checkInvariants();
    }

    function testFuzz_rawSwapsPreserveReservesAndFeeSolvency(
        uint256 quoteIn,
        uint256 tokenIn,
        uint256 quoteOut,
        uint256 tokenOut,
        uint8 rounds
    ) public {
        rounds = uint8(bound(rounds, 1, 6));
        for (uint256 i; i < rounds; i++) {
            (uint256 rq, uint256 rt) = _reserves();
            uint256 qi = bound(uint256(keccak256(abi.encode(quoteIn, i))), 0, 50 ether);
            uint256 ti = bound(uint256(keccak256(abi.encode(tokenIn, i))), 0, token.balanceOf(holder) / 4);
            uint256 qo = bound(uint256(keccak256(abi.encode(quoteOut, i))), 0, rq - 1);
            uint256 to = bound(uint256(keccak256(abi.encode(tokenOut, i))), 0, rt - 1);
            if (i % 3 == 0) qo %= pair.realQuoteReserve() + 1;
            if (i % 3 == 1) to = 0;
            if (i % 3 == 2) qo = 0;

            uint256 kBefore = rq * rt;
            uint256 feesBefore = pair.feeAccrued();
            _donate(qi, ti);
            if (!_trySwap(qo, to, trader)) pair.skim(holder);
            _checkInvariants();
            assertGe(_k(), kBefore);
            assertGe(pair.feeAccrued(), feesBefore);
        }
        fees.collect(address(pair));
        _checkInvariants();
    }

    function testFuzz_sameTransactionSaleReturnsLessQuoteThanBuyCost(uint256 spend, uint256 sellBps, bool exactOut)
        public
    {
        spend = bound(spend, 1e6, 500 ether);
        sellBps = bound(sellBps, 1, 10_000);
        uint256 bought = _buyWithWrappedQuote(spend);
        uint256 amount = exactOut ? bought : bought * sellBps / 10_000;
        uint256 net = pair.getAmountOut(amount, address(token));
        if (net > 0) {
            if (exactOut) {
                uint256 required = pair.getAmountIn(net, address(wbnb));
                assertLe(required, amount);
                amount = required;
            }
            _sellWithWrappedQuote(amount, net);
        }
        assertLt(wbnb.balanceOf(trader), spend);
        _checkInvariants();
    }

    function testFuzz_sellExactInQuoteIsExecutableAndTight(uint256 priorBuy, uint256 amount) public {
        priorBuy = bound(priorBuy, 0, 200 ether);
        if (priorBuy != 0) _buy(trader, priorBuy);
        amount = bound(amount, 1e9, token.balanceOf(holder));
        uint256 net = pair.getAmountOut(amount, address(token));
        _donate(0, amount);
        assertFalse(_trySwap(net + 1, 0, trader));
        _swapRaw(net, 0, trader);
        assertEq(wbnb.balanceOf(trader), net);
        _checkInvariants();
    }

    function test_sellTakingOneWeiTokenCannotReceiveThePlainSellQuote() public {
        uint256 amount = 10_000_000 ether;
        uint256 plain = pair.getAmountOut(amount, address(token));
        uint256 smaller = pair.getAmountOut(amount * 99 / 100, address(token));
        assertLt(smaller, plain);

        _donate(0, amount);
        (uint256 out0, uint256 out1) = pair.quoteIs0() ? (plain, uint256(1)) : (uint256(1), plain);
        vm.expectRevert(bytes("GangSwap: K"));
        pair.swap(out0, out1, trader, "");

        _swapRaw(smaller - 1, 1, trader);
        assertEq(token.balanceOf(trader), 1);
        _checkInvariants();
    }

    function testFuzz_buyStepSellReturnsLessQuoteThanBuyCost(uint256 spend, uint8 priorSteps) public {
        priorSteps = uint8(bound(priorSteps, 0, 30));
        for (uint256 i; i < priorSteps; i++) {
            vm.warp(vm.getBlockTimestamp() + boost.STEP_GAP());
            boost.step(address(token));
        }
        spend = bound(spend, 0.01 ether, 100 ether);
        vm.warp(vm.getBlockTimestamp() + boost.STEP_GAP());
        uint256 bought = _buyWithWrappedQuote(spend);
        boost.step(address(token));
        uint256 net = pair.getAmountOut(bought, address(token));
        _sellWithWrappedQuote(bought, net);
        assertLt(wbnb.balanceOf(trader), spend);
        _checkInvariants();
    }

    function test_firstCollectionAfterGraceSettlesAllOutstandingFeesToPlatform() public {
        _runBoost();
        _endWindow();
        _tradeRoundTrips(3, 5 ether);

        uint256 accrued = pair.feeAccrued();
        uint256 before = bucket.accruedQuote(address(wbnb));
        uint256 pending = fees.pendingPlatform();
        assertEq(fees.collect(address(pair)), accrued);
        assertTrue(fees.windowClosed(address(token)));
        assertEq(fees.creatorFeeOf(address(token)), 0);
        assertEq(bucket.accruedQuote(address(wbnb)) - before, accrued + pending);

        before = bucket.accruedQuote(address(wbnb));
        _tradeRoundTrips(1, 5 ether);
        accrued = pair.feeAccrued();
        assertEq(fees.collect(address(pair)), accrued);
        uint256 creatorShare = accrued * 7 / 10;
        assertEq(fees.creatorFeeOf(address(token)), creatorShare);
        assertEq(bucket.accruedQuote(address(wbnb)) - before, accrued - creatorShare);
    }

    function test_emptyClosingClaimReturnsZeroAndKeepsWindowClosed() public {
        _runBoost();
        _endWindow();
        assertEq(pair.feeAccrued(), 0);
        assertFalse(fees.windowClosed(address(token)));

        vm.expectEmit(true, false, false, false, address(fees));
        emit WindowClosed(address(token));
        vm.prank(creator);
        assertEq(fees.claim(address(token), creator), 0);
        assertTrue(fees.windowClosed(address(token)));

        vm.prank(creator);
        vm.expectRevert(GangSwapV2Fees.ZeroAmount.selector);
        fees.claim(address(token), creator);
    }

    function test_unspentBoostKeepsCollectionsPlatformOnly() public {
        _tradeRoundTrips(3, 5 ether);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        uint256 accrued = pair.feeAccrued();
        assertEq(fees.collect(address(pair)), accrued);
        assertFalse(fees.windowClosed(address(token)));
        assertEq(fees.creatorFeeOf(address(token)), 0);
        assertEq(bucket.accruedQuote(address(wbnb)), accrued);
    }

    function test_stepsContinueThroughDonationsSyncAndSkim() public {
        _donate(1 ether, 1_000_000 ether);
        boost.step(address(token));

        _donate(0, 5_000_000 ether);
        pair.sync();
        vm.warp(vm.getBlockTimestamp() + boost.STEP_GAP());
        boost.step(address(token));

        _donate(3, 100 ether);
        pair.skim(holder);
        vm.warp(vm.getBlockTimestamp() + boost.STEP_GAP());
        boost.step(address(token));
        _runBoost();
        (,,,, uint128 left) = boost.boosts(address(token));
        assertEq(left, 0);
        _checkInvariants();
    }

    function test_graduationIncludesPriorDonationAndStaysWithinGasBudget() public {
        token = new MockToken(address(this));
        token.transfer(address(pad), POOL_TOKENS);
        token.transfer(holder, SUPPLY - POOL_TOKENS);
        pad.setCreator(address(token), creator);

        (address t0, address t1) =
            address(token) < address(wbnb) ? (address(token), address(wbnb)) : (address(wbnb), address(token));
        bytes32 salt = keccak256(abi.encodePacked(t0, t1));
        address predicted = address(uint160(uint256(
            keccak256(abi.encodePacked(hex"ff", address(factory), salt, factory.INIT_CODE_PAIR_HASH()))
        )));
        _wrap(trader, 1 ether);
        vm.prank(trader);
        wbnb.transfer(predicted, 1 ether);
        _wrap(address(this), G);
        wbnb.transfer(address(pad), G);

        uint256 gasBefore = gasleft();
        pair = IGangSwapV2Pair(pad.graduate(address(migrator), address(token), address(wbnb), POOL_TOKENS, G));
        assertLt(gasBefore - gasleft(), 2_700_000);
        assertEq(address(pair), predicted);
        (uint256 rq,) = _reserves();
        assertEq(rq, G + 1 ether);
        _checkInvariants();
    }

    function test_quoteOutputCannotBeSentToThePair() public {
        uint256 amount = 10_000_000 ether;
        uint256 net = pair.getAmountOut(amount, address(token));
        _donate(0, amount);
        (uint256 out0, uint256 out1) = pair.quoteIs0() ? (net, uint256(0)) : (uint256(0), net);
        vm.expectRevert(bytes("GangSwap: INVALID_TO"));
        pair.swap(out0, out1, address(pair), "");
    }

    function test_remainderJustBelowDustThresholdStillRespectsStepCap() public {
        _sell(holder, token.balanceOf(holder));
        (,,, uint128 v, uint128 left) = boost.boosts(address(token));
        uint256 gap = v / boost.DUST_DIV() - 1;
        while (left > v / boost.STEPS()) {
            boost.step(address(token));
            vm.warp(vm.getBlockTimestamp() + boost.STEP_GAP());
            (,,,, left) = boost.boosts(address(token));
        }

        uint256 cap = left - gap;
        uint256 targetReserve = cap * 10_000 / boost.CAP_BPS();
        (uint256 q,) = _reserves();
        assertGt(targetReserve, q);
        _donate(targetReserve - q, 0);
        pair.sync();

        (uint256 spent,) = boost.step(address(token));
        assertEq(spent, cap);
        (,,,, left) = boost.boosts(address(token));
        assertEq(left, gap);
    }

    function test_boostCollectionDoesNotCloseExpiredWindow() public {
        _runBoost();
        _endWindow();
        _buy(trader, 1 ether);
        uint256 accrued = pair.feeAccrued();
        uint256 pending = fees.pendingPlatform();
        vm.prank(address(boost));
        assertEq(fees.collectBoost(address(pair)), accrued);
        assertFalse(fees.windowClosed(address(token)));
        assertEq(fees.pendingPlatform(), pending + accrued);
        assertEq(fees.creatorFeeOf(address(token)), 0);
        assertEq(fees.collect(address(pair)), 0);
        assertTrue(fees.windowClosed(address(token)));
    }

    function _wrap(address who, uint256 amount) private {
        vm.deal(who, amount);
        vm.prank(who);
        wbnb.deposit{value: amount}();
    }

    function _buyWithWrappedQuote(uint256 amount) private returns (uint256 bought) {
        _wrap(trader, amount);
        bought = pair.getAmountOut(amount, address(wbnb));
        vm.prank(trader);
        wbnb.transfer(address(pair), amount);
        _swapRaw(0, bought, trader);
    }

    function _sellWithWrappedQuote(uint256 amount, uint256 net) private {
        vm.prank(trader);
        token.transfer(address(pair), amount);
        _swapRaw(net, 0, trader);
    }

    function _tradeRoundTrips(uint256 rounds, uint256 amount) private {
        for (uint256 i; i < rounds; i++) {
            _sell(trader, _buy(trader, amount));
        }
    }

    function _trySwap(uint256 quoteOut, uint256 tokenOut, address receiver) private returns (bool ok) {
        (uint256 out0, uint256 out1) = pair.quoteIs0() ? (quoteOut, tokenOut) : (tokenOut, quoteOut);
        (ok,) = address(pair).call(abi.encodeCall(IGangSwapV2Pair.swap, (out0, out1, receiver, "")));
    }
}
