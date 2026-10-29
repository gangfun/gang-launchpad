// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {GangToken as TaxLaunchTokenV3} from "../../src/gang/GangToken.sol";
import {GangTaxHandler as TaxHandlerV3} from "../../src/gang/GangTaxHandler.sol";
import {PostGradHandlerBase} from "../../src/common/PostGradHandlerBase.sol";
import {LaunchpadV3Test} from "./LaunchpadV3.t.sol";
import {SkimMockPair} from "../mocks/SkimMockPair.sol";

/// @notice Pool tax after graduation: sold in chunks — before a taxed sell (≤ 25% of that sell), by the keeper
///         otherwise — all within one budget per token per block (0.5% of the token side at the block's first chunk
///         attempt), never below the block's reference price by more than 2%; the holders' part credited when paid.
contract SwapBackTest is LaunchpadV3Test {
    function _dividendToken() internal returns (address t, MockPair pair) {
        t = _create(_tax(300, 300, 5000, treasury));
        _graduate(t);
        pair = MockPair(TaxLaunchTokenV3(t).pair());
    }

    /// @dev Pool buys only (no sell, so no swap-back): tax piles up past one chunk.
    function _buyBacklog(address t, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            _poolBuy(t, address(uint160(0xC0000 + i)), 20 ether);
        }
    }

    function _cap(address t, MockPair pair) internal view returns (uint256) {
        (uint256 rT,) = _reserves(t, pair);
        return (rT * 50) / 10_000;
    }

    function _expectedChunk(address t, uint256 sold) internal view returns (uint256 c) {
        c = handler.maxChunk(t);
        if (c > sold / 4) c = sold / 4;
    }

    function test_swapBack_sellSellsOneChunkFirst() public {
        (address t,) = _dividendToken();
        _buyBacklog(t, 12);
        uint256 accrued = handler.accruedTax(t);
        address seller = address(uint160(0xC0000));
        uint256 sold = IERC20(t).balanceOf(seller) / 2;
        uint256 chunk = _expectedChunk(t, sold);
        assertGt(chunk, 0);
        uint256 bucket0 = bucket.accruedQuote(address(quoteTok));
        uint256 vault0 = quoteTok.balanceOf(address(divVault));
        _poolSell(t, seller, sold);
        assertEq(handler.accruedTax(t), accrued - chunk + (sold * 300) / BPS, "one chunk sold before the sell");
        assertGt(bucket.accruedQuote(address(quoteTok)) - bucket0, 0, "platform paid in quote");
        assertGt(quoteTok.balanceOf(address(divVault)) - vault0, 0, "holders' units of the chunk turned to quote");
    }

    /// @dev D1/D3: a chunk is at most a quarter of the sell that triggers it.
    function test_swapBack_atMostAQuarterOfTheSell() public {
        (address t, MockPair pair) = _dividendToken();
        _buyBacklog(t, 12);
        uint256 accrued = handler.accruedTax(t);
        uint256 sold = 1_000 ether;
        assertGt(_cap(t, pair), sold, "the cap alone would allow more");
        _poolSell(t, address(uint160(0xC0000)), sold);
        assertEq(handler.accruedTax(t), accrued - sold / 4 + (sold * 300) / BPS);
    }

    /// @dev Audit 5 (B-F1 / A): one budget per token per block, drawn by what is sold — sells in the same block share
    ///      it (a dust sell only uses dust of it), the next block opens a fresh one.
    function test_swapBack_blockBudgetSharedBySells() public {
        (address t, MockPair pair) = _dividendToken();
        _withSkim(pair); // the first sell's tokens stay unsynced (no swap after it): set aside around the second chunk
        _buyBacklog(t, 12);
        address seller = address(uint160(0xC0000));
        uint256 budget = _cap(t, pair);
        uint256 small = budget; // its chunk: a quarter of it
        uint256 accrued = handler.accruedTax(t);
        vm.prank(seller);
        IERC20(t).transfer(address(pair), small); // a plain transfer into the pair: the chunk runs, no swap after
        uint256 first = accrued + (small * 300) / BPS - handler.accruedTax(t);
        assertEq(first, small / 4, "a quarter of the sell");
        (, uint96 used) = handler.windowOf(t);
        assertEq(used, first, "budget drawn by what was sold");
        assertEq(handler.maxChunk(t), budget - first, "the rest of the budget is left this block");
        // a second, larger sell in the same block takes what is left — no more
        accrued = handler.accruedTax(t);
        uint256 big = IERC20(t).balanceOf(seller) / 2;
        vm.prank(seller);
        IERC20(t).transfer(address(pair), big);
        uint256 second = accrued + (big * 300) / BPS - handler.accruedTax(t);
        assertEq(first + second, budget, "the whole block budget, not more");
        assertEq(handler.maxChunk(t), 0, "spent this block");
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(handler.maxChunk(t), 0, "next block: a fresh budget");
    }

    /// @dev D1: a transfer into the pair that pays no tax (dust) triggers nothing — no transfer-1-and-skim loop.
    function test_swapBack_untaxedDustTriggersNothing() public {
        (address t, MockPair pair) = _dividendToken();
        _buyBacklog(t, 12);
        uint256 accrued = handler.accruedTax(t);
        address seller = address(uint160(0xC0000));
        vm.prank(seller);
        IERC20(t).transfer(address(pair), 33); // 3% of 33 wei = 0
        assertEq(handler.accruedTax(t), accrued, "no chunk, no tax");
        (uint64 windowBlock,) = handler.windowOf(t);
        assertEq(windowBlock, 0, "no chunk attempt");
    }

    /// @dev The repo's MockPair has no `skim`; give the live pair one (same storage layout).
    function _withSkim(MockPair pair) internal {
        vm.etch(address(pair), address(new SkimMockPair()).code);
    }

    function _excess(address t, MockPair pair) internal view returns (uint256 exT, uint256 exQ) {
        (uint256 rT, uint256 rQ) = _reserves(t, pair);
        exT = IERC20(t).balanceOf(address(pair)) - rT;
        exQ = quoteTok.balanceOf(address(pair)) - rQ;
    }

    /// @dev D2 / audit 5 B-F2 (review): unsynced quote in the pair (someone mid-way adding liquidity, quote first)
    ///      no longer skips the chunk: it is set aside, the chunk sells at the reserves, and it goes back untouched.
    function test_swapBack_unsyncedQuoteSetAsideAndReturned() public {
        (address t, MockPair pair) = _dividendToken();
        _withSkim(pair);
        _buyBacklog(t, 12);
        uint256 sold = 1_000_000 ether;
        (, uint256 rQ) = _reserves(t, pair);
        uint256 lpQuote = rQ / 1000; // one side sent, not minted
        quoteTok.mintUnlimited(address(pair), lpQuote);
        uint256 accrued = handler.accruedTax(t);
        uint256 chunk = _expectedChunk(t, sold);
        assertGt(chunk, 0);
        vm.prank(address(uint160(0xC0000)));
        IERC20(t).transfer(address(pair), sold);
        assertEq(handler.accruedTax(t), accrued - chunk + (sold * 300) / BPS, "the chunk ran");
        (uint256 exT, uint256 exQ) = _excess(t, pair);
        assertEq(exQ, lpQuote, "the LP's quote is still there, unsynced");
        assertEq(exT, sold - (sold * 300) / BPS, "and the sell's tokens");
        assertEq(IERC20(t).balanceOf(address(handler)), handler.accruedTax(t), "nothing set aside stayed here");
        assertEq(quoteTok.balanceOf(address(handler)), 0);
    }

    /// @dev Unsynced tokens (sent to the pair, not swapped yet) are set aside and returned the same way.
    function test_swapBack_unsyncedTokensSetAsideAndReturned() public {
        (address t, MockPair pair) = _dividendToken();
        _withSkim(pair);
        _buyBacklog(t, 12);
        address a = address(uint160(0xC0000));
        address b = address(uint160(0xC0001));
        vm.prank(a);
        IERC20(t).transfer(address(pair), 1000 ether); // a's chunk runs, its tokens stay unsynced
        (uint256 exT0, uint256 exQ0) = _excess(t, pair);
        assertEq(exT0, 1000 ether - (1000 ether * 300) / BPS);
        assertEq(exQ0, 0);
        uint256 accrued = handler.accruedTax(t);
        uint256 sold = 1_000_000 ether;
        uint256 chunk = _expectedChunk(t, sold);
        assertGt(chunk, 0);
        vm.prank(b);
        IERC20(t).transfer(address(pair), sold);
        assertEq(handler.accruedTax(t), accrued - chunk + (sold * 300) / BPS, "b's chunk ran too");
        (uint256 exT, uint256 exQ) = _excess(t, pair);
        assertEq(exT, exT0 + sold - (sold * 300) / BPS, "a's unsynced tokens went back");
        assertEq(exQ, 0);
        assertEq(IERC20(t).balanceOf(address(handler)), handler.accruedTax(t), "nothing set aside stayed here");
    }

    /// @dev A pair without `skim` (not Pancake) can't set balances aside: the chunk fails, the sell goes through.
    function test_swapBack_unsyncedWithoutSkimNeverFailsTheSell() public {
        (address t, MockPair pair) = _dividendToken();
        _buyBacklog(t, 12);
        quoteTok.mintUnlimited(address(pair), 1);
        uint256 accrued = handler.accruedTax(t);
        uint256 sold = 1_000_000 ether;
        vm.prank(address(uint160(0xC0000)));
        IERC20(t).transfer(address(pair), sold);
        assertEq(handler.accruedTax(t), accrued + (sold * 300) / BPS, "no chunk, the sell went through");
    }

    /// @dev B-F2 (review): a dust sell next to 1 wei of unsynced quote neither skips nor spends the block.
    function test_swapBack_dustSellPlusOneWeiSpendsNothing() public {
        (address t, MockPair pair) = _dividendToken();
        _withSkim(pair);
        _buyBacklog(t, 12);
        quoteTok.mintUnlimited(address(pair), 1);
        address seller = address(uint160(0xC0000));
        vm.prank(seller);
        IERC20(t).transfer(address(pair), 100);
        (, uint96 used) = handler.windowOf(t);
        assertLe(used, 25, "at most its own dust chunk");
        uint256 accrued = handler.accruedTax(t);
        uint256 sold = 1_000_000 ether;
        uint256 chunk = _expectedChunk(t, sold);
        assertGt(chunk, 0);
        vm.prank(seller);
        IERC20(t).transfer(address(pair), sold);
        assertEq(handler.accruedTax(t), accrued - chunk + (sold * 300) / BPS, "the real sell still gets its chunk");
        (, uint256 exQ) = _excess(t, pair);
        assertEq(exQ, 1, "the 1 wei is still there");
    }

    function test_swapBack_dustDonationDoesNotSkip() public {
        (address t, MockPair pair) = _dividendToken();
        _withSkim(pair);
        _buyBacklog(t, 12);
        quoteTok.mintUnlimited(address(pair), 1); // B-F2: 1 wei used to skip the chunk for free
        uint256 accrued = handler.accruedTax(t);
        uint256 sold = 1_000_000 ether;
        uint256 chunk = _expectedChunk(t, sold);
        vm.prank(address(uint160(0xC0000)));
        IERC20(t).transfer(address(pair), sold);
        assertEq(handler.accruedTax(t), accrued - chunk + (sold * 300) / BPS, "the chunk ran anyway");
    }

    /// @dev B: previewSell quotes the sell with its chunk included (Pancake math, the 0.25% fee).
    function test_previewSell_includesTheChunk() public {
        (address t, MockPair pair) = _dividendToken();
        _buyBacklog(t, 12);
        address seller = address(uint160(0xC0000));
        uint256 sold = IERC20(t).balanceOf(seller) / 2;
        (uint256 quoted, uint256 chunk) = handler.previewSell(t, sold);
        assertEq(chunk, _expectedChunk(t, sold));
        vm.prank(seller);
        IERC20(t).transfer(address(pair), sold); // chunk runs here
        (uint256 rT, uint256 rQ) = _reserves(t, pair);
        uint256 inAmt = IERC20(t).balanceOf(address(pair)) - rT;
        uint256 out = (inAmt * 9975 * rQ) / (rT * 10_000 + inAmt * 9975);
        assertEq(quoted, out, "what the seller can get after the chunk");
    }

    function test_swapBack_priceImpactBounded() public {
        (address t, MockPair pair) = _dividendToken();
        _buyBacklog(t, 12);
        (uint256 rT0, uint256 rQ0) = _reserves(t, pair);
        vm.prank(t);
        handler.swapBack(t, type(uint128).max);
        (uint256 rT1, uint256 rQ1) = _reserves(t, pair);
        assertEq(rT1 - rT0, (rT0 * 50) / 10_000, "0.5% of the token side");
        assertGe(rQ1 * rT0 * 1000, rQ0 * rT1 * 989, "price moves about 1%");
    }

    function test_swapBack_onlyTheToken() public {
        (address t,) = _dividendToken();
        vm.prank(stranger);
        vm.expectRevert(PostGradHandlerBase.OnlyToken.selector);
        handler.swapBack(t, 1 ether);
    }

    /// @dev A failing chunk never fails the seller's trade; the tax stays for the next sell or the keeper.
    function test_swapBack_failureNeverFailsTheSell() public {
        (address t,) = _dividendToken();
        _buyBacklog(t, 3);
        uint256 accrued = handler.accruedTax(t);
        vm.mockCallRevert(address(handler), abi.encodeWithSelector(TaxHandlerV3.swapBack.selector), "boom");
        address seller = address(uint160(0xC0000));
        uint256 sold = IERC20(t).balanceOf(seller) / 2;
        uint256 got0 = quoteTok.balanceOf(seller);
        vm.expectEmit(false, false, false, false, t);
        emit TaxLaunchTokenV3.SwapBackFailed();
        _poolSell(t, seller, sold);
        assertGt(quoteTok.balanceOf(seller), got0, "the sell went through");
        assertEq(handler.accruedTax(t), accrued + (sold * 300) / BPS, "nothing sold, tax kept");
    }

    /// @dev A: gas estimation must land where the chunk runs. Binary-search the least gas a sell transfer succeeds
    ///      with (what eth_estimateGas does): at that limit the chunk was sold, not skipped.
    function test_swapBack_runsAtTheEstimatedGas() public {
        (address t, MockPair pair) = _dividendToken();
        _buyBacklog(t, 12);
        address seller = address(uint160(0xC0000));
        uint256 sold = IERC20(t).balanceOf(seller) / 2;
        uint256 accrued = handler.accruedTax(t);
        uint256 chunk = _expectedChunk(t, sold);
        bytes memory data = abi.encodeCall(IERC20.transfer, (address(pair), sold));
        uint256 lo = 30_000;
        uint256 hi = 5_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(seller);
            (bool ok,) = t.call{gas: mid}(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
        vm.prank(seller);
        (bool done,) = t.call{gas: lo}(data);
        assertTrue(done);
        assertEq(handler.accruedTax(t), accrued - chunk + (sold * 300) / BPS, "the chunk ran at the estimated gas");
        emit log_named_uint("least gas for a sell transfer with its chunk", lo);
    }

    /// @dev Buys never swap back (the pair is locked during a buy): the keeper drains a buy-only backlog chunk by
    ///      chunk, one block budget at a time (audit 5 B-F4: a second call in the same block finds it spent).
    function test_keeper_drainsBuyOnlyBacklogInChunks() public {
        (address t, MockPair pair) = _dividendToken();
        _buyBacklog(t, 20);
        uint256 rounds;
        while (handler.accruedTax(t) > 0 && rounds < 300) {
            uint256 chunk = handler.maxChunk(t);
            assertLe(chunk, _cap(t, pair), "never more than one chunk");
            vm.prank(keeper);
            handler.process(t, chunk, 1);
            if (handler.accruedTax(t) > 0) {
                assertEq(handler.maxChunk(t), 0, "one budget per block");
                vm.prank(keeper);
                vm.expectRevert(PostGradHandlerBase.ZeroAmount.selector);
                handler.process(t, 1, 1);
            }
            vm.roll(vm.getBlockNumber() + 1);
            rounds++;
        }
        assertEq(handler.accruedTax(t), 0, "drained, a budget a block");
        assertGt(rounds, 1, "took several chunks");
        assertEq(divVault.unsoldUnits(t), 0, "every holder unit sold");
        assertEq(handler.accruedPlatformTax(t), 0);
    }

    function test_keeper_processCutsToOneChunk() public {
        (address t, MockPair pair) = _dividendToken();
        _buyBacklog(t, 12);
        uint256 accrued = handler.accruedTax(t);
        uint256 cap = _cap(t, pair);
        vm.prank(keeper);
        handler.process(t, type(uint256).max, 1);
        assertEq(handler.accruedTax(t), accrued - cap);
        vm.prank(stranger);
        vm.expectRevert(PostGradHandlerBase.OnlyKeeperOrOwner.selector);
        handler.process(t, 1, 1);
    }

    /// @dev Who held when a tax was paid gets it: a holder who sells out afterwards keeps it, a later buyer gets none.
    function test_dividends_creditedAtTaxTime() public {
        (address t,) = _dividendToken();
        address a = address(uint160(0xB0000)); // a curve buyer, holding at graduation
        assertGt(divVault.shares(t, a), 0);
        _buyBacklog(t, 4);
        assertGt(divVault.pendingUnits(t, a), 0, "a credited at tax time");

        uint256 beforeSell = divVault.pendingUnits(t, a);
        _poolSell(t, a, IERC20(t).balanceOf(a)); // audit 5 C-F7: synced to 0 first, nothing of its own sell's tax
        assertEq(divVault.shares(t, a), 0);
        assertEq(divVault.pendingUnits(t, a), beforeSell, "no part of its own sell's tax");
        address late = makeAddr("late");
        _poolBuy(t, late, 1 ether);
        assertEq(divVault.pendingUnits(t, late), 0, "late buyer: nothing from earlier taxes (nor its own buy's)");

        while (handler.accruedTax(t) > 0) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.prank(keeper);
            handler.process(t, type(uint256).max, 1);
        }
        assertGt(divVault.pending(t, a), 0, "a still paid after selling out");
        assertEq(divVault.pending(t, late), 0, "late buyer paid nothing");
        uint256 before = quoteTok.balanceOf(a);
        vm.prank(a);
        divVault.claim(t);
        assertGt(quoteTok.balanceOf(a), before);
    }

    /// @dev D4: the bucket refusing the platform's quote doesn't fail a chunk: it is owed, holders still convert, and
    ///      anyone pays it in once the bucket accepts again.
    function test_bucketRefusing_platformOwed_chunkStillSells() public {
        (address t,) = _dividendToken();
        _buyBacklog(t, 6);
        vm.mockCallRevert(address(bucket), abi.encodeWithSelector(PlatformFeeBucket.notifyAccrual.selector), "no");
        uint256 vault0 = quoteTok.balanceOf(address(divVault));
        uint256 accrued = handler.accruedTax(t);
        vm.prank(keeper);
        handler.process(t, type(uint256).max, 1);
        assertLt(handler.accruedTax(t), accrued, "sold");
        uint256 owed = handler.owedPlatformOf(address(quoteTok));
        assertGt(owed, 0, "platform part owed");
        assertGt(quoteTok.balanceOf(address(divVault)), vault0, "holders converted anyway");
        vm.expectRevert();
        handler.flushPlatform(address(quoteTok)); // still refusing
        vm.clearMockedCalls();
        uint256 b0 = bucket.accruedQuote(address(quoteTok));
        vm.prank(stranger);
        handler.flushPlatform(address(quoteTok));
        assertEq(bucket.accruedQuote(address(quoteTok)) - b0, owed);
        assertEq(handler.owedPlatformOf(address(quoteTok)), 0);
    }

    /// @dev C/D4: the vault refusing a conversion doesn't stop the keeper: the holders' units and quote wait here and
    ///      convert on the next chunk (or flushHolders), paid to the same holders.
    function test_vaultRefusingConversion_waitsThenConverts() public {
        (address t,) = _dividendToken();
        _buyBacklog(t, 6);
        address a = address(uint160(0xB0000));
        uint256 p0 = divVault.pending(t, a); // its curve-phase dividends (paid in quote at the trade)
        vm.mockCallRevert(address(divVault), abi.encodeWithSelector(SharedDividendVault.convertDividend.selector), "no");
        vm.prank(keeper);
        handler.process(t, type(uint256).max, 1);
        uint256 units = handler.pendingHolderUnits(t);
        assertGt(units, 0, "waiting");
        assertGt(handler.pendingHolderQuote(t), 0);
        assertEq(divVault.pending(t, a), p0, "nothing new until converted");
        vm.clearMockedCalls();
        vm.prank(stranger);
        handler.flushHolders(t);
        assertEq(handler.pendingHolderUnits(t), 0, "converted");
        // a batch pays out once all of it is sold
        while (handler.accruedTax(t) > 0) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.prank(keeper);
            handler.process(t, type(uint256).max, 1);
        }
        assertEq(divVault.unsoldUnits(t), 0);
        assertGt(divVault.pending(t, a), p0, "paid to the holders of the tax");
    }

    /// @dev C (K-7): the vault refusing share writes (operator unbound) no longer freezes V3 transfers.
    function test_shareWriteRefused_tradingContinues() public {
        (address t,) = _dividendToken();
        // the vault refusing every operator write (an operator can no longer be unbound: flow review F4a)
        vm.mockCallRevert(address(divVault), abi.encodeWithSelector(SharedDividendVault.setShare.selector), "refused");
        vm.mockCallRevert(
            address(divVault), abi.encodeWithSelector(SharedDividendVault.accrueDividendUnits.selector), "refused"
        );
        vm.mockCallRevert(
            address(divVault), abi.encodeWithSelector(SharedDividendVault.convertDividend.selector), "refused"
        );
        address a = address(uint160(0xB0000));
        vm.expectEmit(true, true, false, false, address(handler));
        emit PostGradHandlerBase.ShareWriteFailed(t, a, 0);
        vm.prank(a);
        IERC20(t).transfer(makeAddr("friend"), 1 ether);
        _poolBuy(t, makeAddr("b"), 1 ether);
        _poolSell(t, a, 1_000 ether);
    }

    /// @dev Audit 5 C-F7: the seller's pre-credit sync only runs for dividend tokens — a token without dividends isn't
    ///      in the vault, so syncing there would only emit ShareWriteFailed on every sell.
    function test_sellOfTokenWithoutDividends_noShareWrite() public {
        address t = _create(_tax(300, 300, 0, treasury));
        _graduate(t);
        _poolBuy(t, stranger, 1 ether);
        vm.recordLogs();
        _poolSell(t, stranger, IERC20(t).balanceOf(stranger) / 2);
        bytes32 sig = PostGradHandlerBase.ShareWriteFailed.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != sig, "no ShareWriteFailed");
        }
    }

    /// @dev The vault refusing the tax-time credit never freezes trading: that part goes to the recipient.
    function test_vaultRefusingCredit_tradingContinues() public {
        (address t,) = _dividendToken();
        vm.mockCallRevert(
            address(divVault), abi.encodeWithSelector(SharedDividendVault.accrueDividendUnits.selector), "refused"
        );
        uint256 unsold0 = divVault.unsoldUnits(t);
        _poolBuy(t, makeAddr("b"), 5 ether);
        assertEq(divVault.unsoldUnits(t), unsold0, "nothing credited");
        assertGt(handler.accruedTax(t), 0, "tax still taken");
    }
}
