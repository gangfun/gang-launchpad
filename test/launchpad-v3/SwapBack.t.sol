// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {TaxLaunchTokenV3} from "../../src/launchpad-v3/TaxLaunchTokenV3.sol";
import {TaxHandlerV3} from "../../src/launchpad-v3/TaxHandlerV3.sol";
import {PostGradHandlerBase} from "../../src/common/PostGradHandlerBase.sol";
import {LaunchpadV3Test} from "./LaunchpadV3.t.sol";

/// @notice Pool tax after graduation: sold in chunks — before a taxed sell (≤ 0.5% of the pair's token side and
///         ≤ 25% of that sell, once per block), by the keeper otherwise — with the holders' part credited when paid.
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

    /// @dev D1: once per token per block; again next block.
    function test_swapBack_oncePerBlock() public {
        (address t,) = _dividendToken();
        _buyBacklog(t, 12);
        address seller = address(uint160(0xC0000));
        uint256 sold = IERC20(t).balanceOf(seller) / 4;
        _poolSell(t, seller, sold);
        uint256 accrued = handler.accruedTax(t);
        _poolSell(t, seller, sold); // same block
        assertEq(handler.accruedTax(t), accrued + (sold * 300) / BPS, "no second chunk this block");
        vm.roll(block.number + 1);
        accrued = handler.accruedTax(t);
        uint256 chunk = _expectedChunk(t, sold);
        _poolSell(t, seller, sold);
        assertEq(handler.accruedTax(t), accrued - chunk + (sold * 300) / BPS, "next block: a chunk again");
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
        assertEq(handler.lastSwapBackBlock(t), 0);
    }

    /// @dev D2: the pair holds an unsynced balance (someone mid-way adding liquidity): no chunk swallows it.
    function test_swapBack_skippedWhilePairUnsynced() public {
        (address t, MockPair pair) = _dividendToken();
        _buyBacklog(t, 12);
        quoteTok.mintUnlimited(address(pair), 1 ether); // one side sent, not minted
        uint256 accrued = handler.accruedTax(t);
        uint256 sold = 1_000_000 ether;
        _poolSell(t, address(uint160(0xC0000)), sold);
        assertEq(handler.accruedTax(t), accrued + (sold * 300) / BPS, "skipped");
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
    ///      chunk, any number per block (D).
    function test_keeper_drainsBuyOnlyBacklogInChunks() public {
        (address t, MockPair pair) = _dividendToken();
        _buyBacklog(t, 20);
        uint256 rounds;
        while (handler.accruedTax(t) > 0 && rounds < 300) {
            uint256 chunk = handler.maxChunk(t);
            assertLe(chunk, _cap(t, pair), "never more than one chunk");
            vm.prank(keeper);
            handler.process(t, chunk, 1);
            rounds++;
        }
        assertEq(handler.accruedTax(t), 0, "drained, all in this block");
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

        _poolSell(t, a, IERC20(t).balanceOf(a)); // credited for its own sell's tax on its pre-sell share
        assertEq(divVault.shares(t, a), 0);
        address late = makeAddr("late");
        _poolBuy(t, late, 1 ether);
        assertEq(divVault.pendingUnits(t, late), 0, "late buyer: nothing from earlier taxes (nor its own buy's)");

        while (handler.accruedTax(t) > 0) {
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
        vm.mockCallRevert(
            address(divVault), abi.encodeWithSelector(SharedDividendVault.convertDividend.selector), "no"
        );
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
        vm.mockCallRevert(address(divVault), abi.encodeWithSelector(SharedDividendVault.accrueDividendUnits.selector), "refused");
        vm.mockCallRevert(address(divVault), abi.encodeWithSelector(SharedDividendVault.convertDividend.selector), "refused");
        vm.mockCallRevert(address(divVault), abi.encodeWithSelector(SharedDividendVault.depositReward.selector), "refused");
        address a = address(uint160(0xB0000));
        vm.expectEmit(true, true, false, false, address(handler));
        emit PostGradHandlerBase.ShareWriteFailed(t, a, 0);
        vm.prank(a);
        IERC20(t).transfer(makeAddr("friend"), 1 ether);
        _poolBuy(t, makeAddr("b"), 1 ether);
        _poolSell(t, a, 1_000 ether);
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
