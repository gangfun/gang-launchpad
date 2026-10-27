// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairMintForkTest} from "../../fair-mint/FairMintFork.t.sol";
import {GangToken as FairToken} from "../../../src/gang/GangToken.sol";
import {FlashSellerR} from "./ReviewFork.t.sol";

/// @notice Review of the audit 5 fixes (AUDIT-BRIEF §18): a flash-swap sell of an 打新 token is refused too
///         (FairToken passes the handler's `SellDuringFlashSwap` on), on a BSC fork with the real Pancake pair.
contract ReviewFairForkTest is FairMintForkTest {
    function test_review_fair_flashSwapSellRefused() public forkOnly {
        address t = _create(WBNB, address(0));
        _fill(t, WBNB);
        address pair = FairToken(t).pair();
        for (uint256 i; i < 5; i++) {
            address b = address(uint160(0xB0B1000 + i));
            deal(WBNB, b, 2 ether);
            _swap(b, WBNB, t, 2 ether);
        }
        vm.roll(vm.getBlockNumber() + 1);
        address m = _minter(1);
        uint256 amount = IERC20(t).balanceOf(m) / 2;
        (, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0);
        uint256 taxBps = FairToken(t).sellTaxBps();
        FlashSellerR f = new FlashSellerR();
        vm.prank(m);
        IERC20(t).transfer(address(f), amount);
        vm.expectRevert(FairToken.SellDuringFlashSwap.selector);
        f.sell(t, WBNB, pair, amount, taxBps);
        // the same tokens through the router: the chunk runs
        uint256 acc0 = handler.accruedTax(t);
        assertGt(_swap(address(f), t, WBNB, amount), 0);
        assertEq(handler.accruedTax(t), acc0 - chunk + (amount * taxBps) / 10_000);
    }

    /// Unsynced quote and tokens in an 打新 pair are set aside around the chunk and returned (§18).
    function test_review_fair_unsyncedSetAsideAndReturned() public forkOnly {
        address t = _create(WBNB, address(0));
        _fill(t, WBNB);
        address pair = FairToken(t).pair();
        for (uint256 i; i < 5; i++) {
            address b = address(uint160(0xB0B2000 + i));
            deal(WBNB, b, 2 ether);
            _swap(b, WBNB, t, 2 ether);
        }
        vm.roll(vm.getBlockNumber() + 1);
        (uint256 rT, uint256 rQ) = _reserves(t, pair);
        uint256 d = rQ / 2000;
        deal(WBNB, address(this), d);
        IERC20(WBNB).transfer(pair, d);
        address m = _minter(2);
        uint256 amount = IERC20(t).balanceOf(m) / 2;
        (, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0);
        uint256 acc0 = handler.accruedTax(t);
        uint256 taxBps = FairToken(t).sellTaxBps();
        vm.prank(m);
        IERC20(t).transfer(pair, amount);
        assertEq(handler.accruedTax(t), acc0 - chunk + (amount * taxBps) / 10_000, "the chunk ran");
        (rT, rQ) = _reserves(t, pair);
        assertEq(IERC20(WBNB).balanceOf(pair) - rQ, d, "the unsynced quote went back");
        assertEq(IERC20(t).balanceOf(pair) - rT, amount - (amount * taxBps) / 10_000);
        assertEq(IERC20(t).balanceOf(address(handler)), handler.accruedTax(t), "nothing set aside stayed here");
    }
}
