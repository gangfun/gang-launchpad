// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {FairToken} from "../../src/fair-mint/FairToken.sol";
import {HolderRewardHandler} from "../../src/fair-mint/HolderRewardHandler.sol";
import {PostGradHandlerBase} from "../../src/common/PostGradHandlerBase.sol";
import {FairMintTest} from "./FairMint.t.sol";

/// @notice 打新 pool tax after launch: sold in chunks (before taxed sells, once per block, ≤ 25% of the sell; keeper
///         otherwise); the holders' half credited to the eligible minters of the moment each tax is paid.
contract FairSwapBackTest is FairMintTest {
    function _launched() internal returns (address t, MockPair pair) {
        t = _create();
        _fill(t);
        pair = MockPair(FairToken(t).pair());
    }

    function _buyBacklog(address t, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            _buy(t, buyer, 2 ether);
        }
    }

    function _expectedChunk(address t, uint256 sold) internal view returns (uint256 c) {
        c = handler.maxChunk(t);
        if (c > sold / 4) c = sold / 4;
    }

    function test_swapBack_sellSellsOneChunkFirst() public {
        (address t,) = _launched();
        _buyBacklog(t, 10);
        uint256 accrued = handler.accruedTax(t);
        uint256 amount = 50 * TPS;
        uint256 chunk = _expectedChunk(t, amount);
        assertGt(chunk, 0);
        uint256 vault0 = wbnb.balanceOf(address(vault));
        _sell(t, _minter(3), amount);
        assertEq(handler.accruedTax(t), accrued - chunk + amount / 100, "one chunk sold before the sell");
        assertGt(wbnb.balanceOf(address(vault)) - vault0, 0, "holders' half of the chunk in quote");
    }

    function test_swapBack_oncePerBlock_andUntaxedDustIgnored() public {
        (address t, MockPair pair) = _launched();
        _buyBacklog(t, 10);
        _sell(t, _minter(3), 10 * TPS);
        uint256 accrued = handler.accruedTax(t);
        _sell(t, _minter(4), 10 * TPS); // same block
        assertEq(handler.accruedTax(t), accrued + (10 * TPS) / 100, "no second chunk this block");
        vm.roll(block.number + 1);
        accrued = handler.accruedTax(t);
        vm.prank(_minter(4));
        IERC20(t).transfer(address(pair), 99); // 1% of 99 wei = 0: untaxed
        assertEq(handler.accruedTax(t), accrued, "dust triggers nothing");
    }

    function test_swapBack_failureNeverFailsTheSell() public {
        (address t,) = _launched();
        _buyBacklog(t, 2);
        uint256 accrued = handler.accruedTax(t);
        vm.mockCallRevert(address(handler), abi.encodeWithSelector(HolderRewardHandler.swapBack.selector), "x");
        vm.expectEmit(false, false, false, false, t);
        emit FairToken.SwapBackFailed();
        _sell(t, _minter(3), 10 * TPS);
        assertEq(handler.accruedTax(t), accrued + (10 * TPS) / 100, "nothing sold, tax kept");
    }

    function test_swapBack_onlyTheTokenAndOnlyThisPad() public {
        (address t,) = _launched();
        vm.prank(stranger);
        vm.expectRevert(PostGradHandlerBase.OnlyToken.selector);
        handler.swapBack(t, 1 ether);
        address fake = makeAddr("fake");
        vm.prank(fake);
        vm.expectRevert(HolderRewardHandler.UnknownToken.selector);
        handler.swapBack(fake, 1 ether);
    }

    function test_previewSell_includesTheChunk() public {
        (address t, MockPair pair) = _launched();
        _buyBacklog(t, 10);
        address m = _minter(3);
        uint256 amount = 50 * TPS;
        (uint256 quoted, uint256 chunk) = handler.previewSell(t, amount);
        assertEq(chunk, _expectedChunk(t, amount));
        vm.prank(m);
        IERC20(t).transfer(address(pair), amount);
        (uint256 rT, uint256 rQ) = _reserves(t, pair);
        uint256 inAmt = IERC20(t).balanceOf(address(pair)) - rT;
        assertEq(quoted, (inAmt * 9975 * rQ) / (rT * 10_000 + inAmt * 9975));
    }

    /// @dev A minter who sells out after a tax keeps its half of it; a post-launch buyer never earns.
    function test_holderHalfCreditedAtTaxTime() public {
        (address t,) = _launched();
        _buyBacklog(t, 3);
        address m = _minter(7);
        assertGt(vault.pendingUnits(t, m), 0, "credited when the tax was paid");
        _sell(t, m, IERC20(t).balanceOf(m)); // out for good; its share drops to 0
        assertEq(vault.shares(t, m), 0);
        while (handler.accruedTax(t) > 0) {
            vm.prank(owner);
            handler.process(t, type(uint256).max, 1);
        }
        assertEq(vault.unsoldUnits(t), 0);
        assertGt(vault.pending(t, m), 0, "still paid after selling out");
        assertEq(vault.pending(t, buyer), 0, "post-launch buyer earns nothing");
    }

    /// @dev F2/D4: the bucket refusing doesn't fail process: the platform half is owed, the holders' half converts.
    function test_bucketRefusing_holdersStillPaid() public {
        (address t,) = _launched();
        _buyBacklog(t, 4);
        vm.mockCallRevert(address(bucket), abi.encodeWithSelector(PlatformFeeBucket.notifyAccrual.selector), "no");
        uint256 vault0 = wbnb.balanceOf(address(vault));
        vm.prank(owner);
        handler.process(t, type(uint256).max, 1);
        assertGt(handler.owedPlatformOf(address(wbnb)), 0, "platform half owed");
        assertGt(wbnb.balanceOf(address(vault)), vault0, "holders' half converted");
        vm.clearMockedCalls();
        handler.flushPlatform(address(wbnb));
        assertEq(handler.owedPlatformOf(address(wbnb)), 0);
    }

    function test_vaultRefusingConversion_waitsThenConverts() public {
        (address t,) = _launched();
        _buyBacklog(t, 4);
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(SharedDividendVault.convertDividend.selector), "no");
        vm.prank(owner);
        handler.process(t, type(uint256).max, 1);
        assertGt(handler.pendingHolderUnits(t), 0);
        vm.clearMockedCalls();
        // the next chunk converts the waiting units with its own
        vm.prank(owner);
        handler.process(t, type(uint256).max, 1);
        assertEq(handler.pendingHolderUnits(t), 0);
        assertGt(vault.pending(t, _minter(5)), 0);
    }

    /// @dev The vault refusing the credit (e.g. operator revoked) never freezes trading; that half is the platform's.
    function test_vaultRefusingCredit_tradingContinues() public {
        (address t,) = _launched();
        // the vault refusing every operator write (an operator can no longer be unbound: flow review F4a)
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(SharedDividendVault.setShare.selector), "refused");
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(SharedDividendVault.accrueDividendUnits.selector), "refused");
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(SharedDividendVault.convertDividend.selector), "refused");
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(SharedDividendVault.depositReward.selector), "refused");
        uint256 unsold0 = vault.unsoldUnits(t);
        _buy(t, buyer, 2 ether);
        _sell(t, buyer, IERC20(t).balanceOf(buyer) / 2);
        assertEq(vault.unsoldUnits(t), unsold0, "nothing credited");
        assertGt(handler.accruedTax(t), 0);
    }

    /// @dev A: at the least gas a sell transfer succeeds with (what eth_estimateGas finds), the chunk ran.
    function test_swapBack_runsAtTheEstimatedGas() public {
        (address t, MockPair pair) = _launched();
        _buyBacklog(t, 10);
        address m = _minter(3);
        uint256 amount = 50 * TPS;
        uint256 accrued = handler.accruedTax(t);
        uint256 chunk = _expectedChunk(t, amount);
        bytes memory data = abi.encodeCall(IERC20.transfer, (address(pair), amount));
        uint256 lo = 30_000;
        uint256 hi = 5_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(m);
            (bool ok,) = t.call{gas: mid}(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
        vm.prank(m);
        (bool done,) = t.call{gas: lo}(data);
        assertTrue(done);
        assertEq(handler.accruedTax(t), accrued - chunk + amount / 100, "the chunk ran at the estimated gas");
    }
}
