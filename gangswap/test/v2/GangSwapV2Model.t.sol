// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GangSwapV2Fixture} from "./GangSwapV2.t.sol";

contract GangSwapV2ModelTest is GangSwapV2Fixture {
    enum Op {
        Buy,
        Sell,
        BuyExactOut,
        SellExactOut,
        Swap,
        Donate,
        Sync,
        Skim,
        Step,
        Collect,
        Claim
    }

    function setUp() public override {
        _mocks();
        _deploy();
    }

    function test_modelReplay6BNB() public { _replay(6); }
    function test_modelReplay9BNB() public { _replay(9); }
    function test_modelReplay12BNB() public { _replay(12); }
    function test_modelReplay15BNB() public { _replay(15); }

    function test_modelLifecycleFourTiers() public {
        string memory json = _readVectors();
        for (uint256 i; i < 4; i++) {
            uint256[] memory row = vm.parseJsonUintArray(json, _index(".lifecycle", i));
            _newPool(row[0] * 1 ether);
            assertEq(_runBoost(), row[1]);
            _endWindow();
            assertEq(fees.collect(address(pair)), 0);
            assertEq(_sell(holder, token.balanceOf(holder)), row[2]);
            assertEq(pair.realQuoteReserve(), row[3]);
            assertEq(pair.feeAccrued(), row[4]);
            assertEq(fees.collect(address(pair)), row[4]);
            assertEq(fees.creatorFeeOf(address(token)), row[5]);
            assertEq(token.balanceOf(DEAD), row[6]);
            _checkInvariants();
        }
    }

    function _replay(uint256 tier) private {
        _newPool(tier * 1 ether);
        string memory json = _readVectors();
        string memory path = string.concat(".tier", vm.toString(tier));
        uint256 previousK = _k();
        uint256 i;
        while (vm.keyExistsJson(json, _index(path, i))) {
            uint256[] memory row = vm.parseJsonUintArray(json, _index(path, i));
            assertEq(row.length, 20);
            vm.warp(row[1]);
            _execute(Op(row[0]), row[2], row[3], row[4], row[5]);
            _assertState(row);
            _checkInvariants();
            uint256 k = _k();
            assertGe(k, previousK, "K");
            previousK = k;
            i++;
        }
        assertGt(i, 40, "complete replay");
        assertEq(token.balanceOf(holder), 0, "final sell");
    }

    function _execute(Op op, uint256 a, uint256 b, uint256 c, uint256 d) private {
        if (op == Op.Buy) {
            address[] memory path = _path(address(wbnb), address(token));
            assertEq(pair.getAmountOut(a, address(wbnb)), b);
            assertEq(router.getAmountsOut(a, path)[1], b);
            uint256 before = token.balanceOf(holder);
            assertEq(_buy(holder, a), b);
            assertEq(token.balanceOf(holder) - before, b);
        } else if (op == Op.Sell) {
            assertEq(pair.getAmountOut(a, address(token)), b);
            assertEq(router.getAmountsOut(a, _path(address(token), address(wbnb)))[1], b);
            assertEq(_sell(holder, a), b);
        } else if (op == Op.BuyExactOut) {
            address[] memory path = _path(address(wbnb), address(token));
            assertEq(pair.getAmountIn(a, address(token)), b);
            assertEq(router.getAmountsIn(a, path)[0], b);
            uint256 before = token.balanceOf(holder);
            vm.deal(holder, b + 1);
            vm.prank(holder);
            uint256[] memory amounts = router.swapETHForExactTokens{value: b + 1}(a, path, holder, block.timestamp);
            assertEq(amounts[0], b);
            assertEq(holder.balance, 1);
            assertEq(token.balanceOf(holder) - before, a);
        } else if (op == Op.SellExactOut) {
            address[] memory path = _path(address(token), address(wbnb));
            assertEq(pair.getAmountIn(a, address(wbnb)), b);
            assertEq(router.getAmountsIn(a, path)[0], b);
            uint256 before = holder.balance;
            vm.startPrank(holder);
            token.approve(address(router), b);
            uint256[] memory amounts = router.swapTokensForExactETH(a, b, path, holder, block.timestamp);
            vm.stopPrank();
            assertEq(amounts[0], b);
            assertEq(holder.balance - before, a);
        } else if (op == Op.Swap) {
            _donate(a, b);
            uint256 before = wbnb.balanceOf(holder);
            _swapRaw(c, d, holder);
            assertEq(wbnb.balanceOf(holder) - before, c);
        } else if (op == Op.Donate) {
            _donate(a, b);
        } else if (op == Op.Sync) {
            pair.sync();
        } else if (op == Op.Skim) {
            pair.skim(holder);
        } else if (op == Op.Step) {
            (uint256 spend, uint256 burn) = boost.step(address(token));
            assertEq(spend, a);
            assertEq(burn, b);
        } else if (op == Op.Collect) {
            assertEq(fees.collect(address(pair)), a);
        } else if (op == Op.Claim) {
            vm.prank(creator);
            assertEq(fees.claim(address(token), creator), a);
        }
    }

    function _assertState(uint256[] memory row) private view {
        (uint256 q, uint256 t) = _reserves();
        (, uint64 lastStepAt,,, uint128 left) = boost.boosts(address(token));
        assertEq(q, row[6], "quote reserve");
        assertEq(t, row[7], "token reserve");
        assertEq(wbnb.balanceOf(address(pair)), row[8], "pair WBNB");
        assertEq(token.balanceOf(address(pair)), row[9], "pair tokens");
        assertEq(token.balanceOf(holder), row[10], "holder tokens");
        assertEq(token.balanceOf(DEAD), row[11], "burnt tokens");
        assertEq(pair.feeAccrued(), row[12], "pair fees");
        assertEq(left, row[13], "boost remaining");
        assertEq(wbnb.balanceOf(address(boost)), left, "boost funding");
        assertEq(lastStepAt, row[14], "last step");
        assertEq(fees.pendingPlatform(), row[15], "pending platform");
        assertEq(bucket.accruedQuote(address(wbnb)), row[16], "platform settled");
        assertEq(fees.creatorFeeOf(address(token)), row[17], "creator booked");
        assertEq(wbnb.balanceOf(creator), row[18], "creator settled");
        assertEq(fees.windowClosed(address(token)), row[19] != 0, "window closed");
        assertEq(wbnb.balanceOf(address(fees)), row[15] + row[17], "settlement solvency");
    }

    function _readVectors() private view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/test/v2/vectors.json"));
    }

    function _index(string memory path, uint256 i) private pure returns (string memory) {
        return string.concat(path, "[", vm.toString(i), "]");
    }
}
