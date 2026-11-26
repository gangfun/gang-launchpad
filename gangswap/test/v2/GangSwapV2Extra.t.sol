// SPDX-License-Identifier: MIT
// Extra cases from the 2026-11-22 implementation review: K refusal inside (real, real + fee), multi-hop across two
// GangSwap pairs, FoT buys with feeAccrued > V, tiny V, pre-graduation donation, and the whole suite with the other
// token ordering.
pragma solidity 0.8.28;

import {GangSwapV2Test, IRouter} from "./GangSwapV2.t.sol";
import {MockToken, MockWBNB, MockPad, MockBucket} from "../Mocks.sol";
import {IGangSwapV2Pair} from "../../src/v2/interfaces/IGangSwapV2.sol";
import {GangSwapV2Boost} from "../../src/v2/GangSwapV2Boost.sol";

contract GangSwapV2ExtraTest is GangSwapV2Test {
    // §10 item 3: output in (real - feeAccrued, real] -> the transfer itself succeeds (paid from feeAccrued), K must refuse
    function test_outputBetweenRealMinusFeeAndReal_revertsK() public {
        for (uint256 i; i < 20; i++) {
            _buy(trader, 3 ether);
        }
        uint256 fee = pair.feeAccrued();
        assertGt(fee, 0.5 ether);
        uint256 bal = wbnb.balanceOf(address(pair));
        uint256 real = pair.realQuoteReserve();
        assertEq(bal, real + fee);
        // dump every token the holder has (more than enough input) and ask for real + fee/2 (inside (real, real+fee))
        uint256 inTok = token.balanceOf(holder);
        vm.prank(holder);
        token.transfer(address(pair), inTok);
        uint256 want = real + fee / 2;
        (uint256 o0, uint256 o1) = pair.quoteIs0() ? (want, uint256(0)) : (uint256(0), want);
        vm.expectRevert(bytes("GangSwap: K"));
        pair.swap(o0, o1, holder, "");
    }

    // multi-hop A -> WBNB -> B across two GangSwap pairs: standard, exact-out and FoT
    function _second() internal returns (MockToken t2, IGangSwapV2Pair p2) {
        t2 = new MockToken(address(this));
        t2.transfer(address(pad), POOL_TOKENS);
        t2.transfer(holder, SUPPLY - POOL_TOKENS);
        vm.deal(address(this), 6 ether);
        wbnb.deposit{value: 6 ether}();
        wbnb.transfer(address(pad), 6 ether);
        p2 = IGangSwapV2Pair(pad.graduate(address(migrator), address(t2), address(wbnb), POOL_TOKENS, 6 ether));
    }

    function test_multiHopTokenWbnbToken() public {
        (MockToken t2, IGangSwapV2Pair p2) = _second();
        _buy(trader, 1 ether); // accrue some fee on pair 1
        address[] memory path = new address[](3);
        path[0] = address(token);
        path[1] = address(wbnb);
        path[2] = address(t2);
        uint256 amt = 10_000_000 ether;
        uint256[] memory q = router.getAmountsOut(amt, path);
        uint256 snap = vm.snapshotState();
        vm.startPrank(holder);
        token.approve(address(router), type(uint256).max);
        uint256 b0 = t2.balanceOf(holder);
        router.swapExactTokensForTokens(amt, q[2], path, holder, block.timestamp);
        assertEq(t2.balanceOf(holder) - b0, q[2]);
        vm.stopPrank();
        vm.revertToState(snap);
        vm.startPrank(holder);
        token.approve(address(router), type(uint256).max);
        b0 = t2.balanceOf(holder);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amt, q[2], path, holder, block.timestamp);
        assertEq(t2.balanceOf(holder) - b0, q[2], "FoT multi-hop exact");
        vm.stopPrank();
        vm.revertToState(snap);
        uint256[] memory qi = router.getAmountsIn(q[2], path);
        vm.startPrank(holder);
        token.approve(address(router), type(uint256).max);
        b0 = t2.balanceOf(holder);
        router.swapTokensForExactTokens(q[2], qi[0], path, holder, block.timestamp);
        assertEq(t2.balanceOf(holder) - b0, q[2]);
        vm.stopPrank();
        p2;
    }

    // FoT buy when feeAccrued > V (review N2 third case)
    function test_fotBuyWhenFeeAccruedExceedsV() public {
        // churn: buy and sell back many times without collect
        for (uint256 i; i < 120; i++) {
            uint256 got = _buy(trader, 5 ether);
            _sell(trader, got);
        }
        assertGt(pair.feeAccrued(), pair.virtualReserve(), "fee > V");
        uint256 expected = router.getAmountsOut(0.05 ether, _path(address(wbnb), address(token)))[1];
        address b = makeAddr("b");
        vm.deal(b, 0.05 ether);
        vm.prank(b);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.05 ether}(
            expected, _path(address(wbnb), address(token)), b, block.timestamp
        );
        assertEq(token.balanceOf(b), expected);
        _checkInvariants();
        fees.collect(address(pair));
        _checkInvariants();
    }

    // tiny V: boost must still finish (no permanent NothingToBuy / TooEarly)
    function test_tinyV_boostFinishes() public {
        MockToken t2 = new MockToken(address(this));
        t2.transfer(address(pad), POOL_TOKENS);
        vm.deal(address(this), 150);
        wbnb.deposit{value: 150}();
        wbnb.transfer(address(pad), 150);
        IGangSwapV2Pair p2 = IGangSwapV2Pair(pad.graduate(address(migrator), address(t2), address(wbnb), POOL_TOKENS, 150));
        assertEq(p2.virtualReserve(), 30);
        uint256 steps;
        while (true) {
            (,,,, uint128 left) = boost.boosts(address(t2));
            if (left == 0) break;
            vm.warp(block.timestamp + 8);
            boost.step(address(t2));
            steps++;
        }
        assertLe(steps, 30, "tiny V: one wei a step at most, then done");
    }

    // pre-graduation WBNB donation to the predicted pair address: graduation still works, I1 holds
    function test_preGradDonation() public {
        MockToken t2 = new MockToken(address(this));
        t2.transfer(address(pad), POOL_TOKENS);
        t2.transfer(holder, SUPPLY - POOL_TOKENS);
        (address a, address b) =
            address(t2) < address(wbnb) ? (address(t2), address(wbnb)) : (address(wbnb), address(t2));
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff", address(factory), keccak256(abi.encodePacked(a, b)), factory.INIT_CODE_PAIR_HASH()
                        )
                    )
                )
            )
        );
        vm.deal(address(this), 20 ether);
        wbnb.deposit{value: 20 ether}();
        wbnb.transfer(predicted, 11 ether);
        wbnb.transfer(address(pad), 9 ether);
        IGangSwapV2Pair p2 =
            IGangSwapV2Pair(pad.graduate(address(migrator), address(t2), address(wbnb), POOL_TOKENS, 9 ether));
        assertEq(address(p2), predicted);
        assertEq(p2.realQuoteReserve(), 9 ether - 1.8 ether + 11 ether);
    }
}

/// Same suite, other token ordering (quoteIs0 flipped).
contract GangSwapV2ExtraFlippedTest is GangSwapV2ExtraTest {
    function setUp() public override {
        _mocks();
        // base suite: decide which side WBNB is on, then mint tokens until the token lands on the other side
        MockToken probe = new MockToken(address(this));
        bool baseTokenLower = address(probe) < address(wbnb);
        token = probe;
        while ((address(token) < address(wbnb)) == baseTokenLower) token = new MockToken(address(this));
        token.transfer(address(pad), POOL_TOKENS);
        token.transfer(holder, SUPPLY - POOL_TOKENS);
        _deploy();
        pad.setCreator(address(token), creator);
        _graduate(G);
    }
}

contract GangSwapV2GasTest is GangSwapV2Test {
    function test_graduationGas() public {
        MockToken t2 = new MockToken(address(this));
        t2.transfer(address(pad), POOL_TOKENS);
        vm.deal(address(this), 9 ether);
        wbnb.deposit{value: 9 ether}();
        wbnb.transfer(address(pad), 9 ether);
        // Local gas budgets for graduation and the first step, including fee booking.
        uint256 g0 = gasleft();
        pad.graduate(address(migrator), address(t2), address(wbnb), POOL_TOKENS, 9 ether);
        assertLt(g0 - gasleft(), 2_700_000, "graduation gas");
        vm.warp(block.timestamp + 8);
        g0 = gasleft();
        boost.step(address(t2));
        assertLt(g0 - gasleft(), 300_000, "boost step gas");
    }
}
