// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangSwapV2Fixture, IRouter} from "./GangSwapV2.t.sol";
import {MockBucket, MockToken} from "../Mocks.sol";
import {IGangSwapV2Pair} from "../../src/v2/interfaces/IGangSwapV2.sol";
import {GangSwapV2Boost} from "../../src/v2/GangSwapV2Boost.sol";
import {GangSwapV2Fees} from "../../src/v2/GangSwapV2Fees.sol";
import {GangSwapBoost} from "../../src/GangSwapBoost.sol";
import {GangSwapFees} from "../../src/GangSwapFees.sol";
import {GangSwapMigrator} from "../../src/GangSwapMigrator.sol";
import {IGangSwapPair} from "../../src/interfaces/IGangSwap.sol";

bytes32 constant SWAP_EVENT = keccak256("Swap(address,uint256,uint256,uint256,uint256,address)");

contract GangSwapV2RouterCoverageTest is GangSwapV2Fixture {
    enum QuoteKind { ExactIn, ExactOut, FeeOnTransfer }

    MockToken private tokenA;
    IGangSwapV2Pair private pairA;

    function setUp() public override {
        super.setUp();
        tokenA = token;
        pairA = pair;
        _newPool(12 ether);
        vm.startPrank(holder);
        tokenA.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function testFuzz_tokenRoutesMatchQuotesInBothDirections(uint256 inputSeed) public {
        uint256 amount = bound(inputSeed, 1_000 ether, 25_000_000 ether);
        for (uint256 i; i < 3; i++) {
            _tokenInput(_throughQuote(address(tokenA), address(token)), amount, QuoteKind(i));
            _tokenInput(_throughQuote(address(token), address(tokenA)), amount, QuoteKind(i));
        }
    }

    function testFuzz_nativeRoutesMatchQuotesAndRefundsForBothPools(uint256 quoteSeed, uint256 tokenSeed, uint256 refundSeed)
        public
    {
        uint256 quoteIn = bound(quoteSeed, 0.001 ether, 3 ether);
        uint256 tokenIn = bound(tokenSeed, 1_000 ether, 25_000_000 ether);
        uint256 refund = bound(refundSeed, 1, 3 ether);
        for (uint256 i; i < 3; i++) {
            QuoteKind kind = QuoteKind(i);
            _nativeInput(address(tokenA), quoteIn, refund, kind);
            _nativeInput(address(token), quoteIn, refund, kind);
            _tokenInput(_path(address(tokenA), address(wbnb)), tokenIn, kind);
            _tokenInput(_path(address(token), address(wbnb)), tokenIn, kind);
        }
    }

    function _tokenInput(address[] memory path, uint256 amount, QuoteKind kind) private {
        address output = path[path.length - 1];
        bool nativeOut = output == address(wbnb);
        bool exactOut = kind == QuoteKind.ExactOut;
        bytes4 selector = _tokenSelector(nativeOut, kind);
        uint256[] memory quote = _quote(path, amount, exactOut);
        uint256 expectedOut = quote[quote.length - 1];

        {
            bytes memory rejected = exactOut
                ? abi.encodeWithSelector(selector, expectedOut, quote[0] - 1, path, holder, block.timestamp)
                : abi.encodeWithSelector(selector, quote[0], expectedOut + 1, path, holder, block.timestamp);
            _assertRouterReverts(rejected, 0, exactOut);
        }

        uint256 inputBefore = IERC20(path[0]).balanceOf(holder);
        uint256 outputBefore = nativeOut ? holder.balance : IERC20(output).balanceOf(holder);
        bytes memory payload = exactOut
            ? abi.encodeWithSelector(selector, expectedOut, quote[0], path, holder, block.timestamp)
            : abi.encodeWithSelector(selector, quote[0], expectedOut, path, holder, block.timestamp);
        _executeRoute(payload, 0, quote, path, kind);

        assertEq(inputBefore - IERC20(path[0]).balanceOf(holder), quote[0]);
        uint256 outputAfter = nativeOut ? holder.balance : IERC20(output).balanceOf(holder);
        assertEq(outputAfter - outputBefore, expectedOut);
    }

    function _nativeInput(address output, uint256 amount, uint256 refund, QuoteKind kind) private {
        address[] memory path = _path(address(wbnb), output);
        bool exactOut = kind == QuoteKind.ExactOut;
        bytes4[3] memory selectors = [
            IRouter.swapExactETHForTokens.selector,
            IRouter.swapETHForExactTokens.selector,
            IRouter.swapExactETHForTokensSupportingFeeOnTransferTokens.selector
        ];
        bytes4 selector = selectors[uint256(kind)];
        uint256[] memory quote = _quote(path, amount, exactOut);
        uint256 payment = quote[0] + (exactOut ? refund : 0);
        vm.deal(holder, payment);
        {
            bytes memory rejected = abi.encodeWithSelector(
                selector, exactOut ? quote[1] : quote[1] + 1, path, holder, block.timestamp
            );
            _assertRouterReverts(rejected, exactOut ? quote[0] - 1 : payment, exactOut);
        }
        assertEq(holder.balance, payment);

        uint256 before = IERC20(output).balanceOf(holder);
        bytes memory payload = abi.encodeWithSelector(selector, quote[1], path, holder, block.timestamp);
        _executeRoute(payload, payment, quote, path, kind);
        assertEq(IERC20(output).balanceOf(holder) - before, quote[1]);
        assertEq(holder.balance, payment - quote[0]);
    }

    function _tokenSelector(bool nativeOut, QuoteKind kind) private pure returns (bytes4) {
        bytes4[3] memory selectors = nativeOut
            ? [
                IRouter.swapExactTokensForETH.selector,
                IRouter.swapTokensForExactETH.selector,
                IRouter.swapExactTokensForETHSupportingFeeOnTransferTokens.selector
            ]
            : [
                IRouter.swapExactTokensForTokens.selector,
                IRouter.swapTokensForExactTokens.selector,
                IRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens.selector
            ];
        return selectors[uint256(kind)];
    }

    function _quote(address[] memory path, uint256 amount, bool exactOut)
        private view returns (uint256[] memory quote)
    {
        quote = router.getAmountsOut(amount, path);
        if (exactOut) quote = router.getAmountsIn(quote[quote.length - 1] / 2, path);
    }

    function _assertRouterReverts(bytes memory payload, uint256 value, bool exactOut) private {
        vm.prank(holder);
        (bool ok, bytes memory reason) = address(router).call{value: value}(payload);
        assertFalse(ok);
        assertEq(bytes4(reason), bytes4(keccak256("Error(string)")));
        bytes memory arguments = new bytes(reason.length - 4);
        for (uint256 i; i < arguments.length; i++) arguments[i] = reason[i + 4];
        assertEq(
            abi.decode(arguments, (string)),
            exactOut ? "GangSwapV2Router: EXCESSIVE_INPUT_AMOUNT" : "GangSwapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    function _executeRoute(
        bytes memory payload,
        uint256 payment,
        uint256[] memory quote,
        address[] memory path,
        QuoteKind kind
    ) private {
        uint256 kA = _poolK(pairA);
        uint256 kB = _poolK(pair);
        vm.recordLogs();
        vm.prank(holder);
        (bool ok, bytes memory result) = address(router).call{value: payment}(payload);
        if (!ok) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (kind != QuoteKind.FeeOnTransfer) assertEq(abi.decode(result, (uint256[])), quote);
        _assertHopAmounts(logs, path, quote);
        assertEq(address(router).balance, 0);
        assertEq(wbnb.balanceOf(address(router)), 0);
        assertEq(tokenA.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertGe(_poolK(pairA), kA);
        assertGe(_poolK(pair), kB);
    }

    function _assertHopAmounts(Vm.Log[] memory logs, address[] memory path, uint256[] memory quote) private view {
        uint256 hop;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != SWAP_EVENT) continue;
            assertLt(hop + 1, path.length);
            address input = path[hop];
            address output = path[hop + 1];
            assertEq(logs[i].emitter, factory.getPair(input, output));
            (uint256 in0, uint256 in1, uint256 out0, uint256 out1) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertEq(input < output ? in0 : in1, quote[hop]);
            assertEq(input < output ? out1 : out0, quote[hop + 1]);
            hop++;
        }
        assertEq(hop, path.length - 1);
    }

    function _poolK(IGangSwapV2Pair pool) private view returns (uint256) {
        (uint112 r0, uint112 r1,) = pool.getReserves();
        uint256 q = pool.quoteIs0() ? r0 : r1;
        uint256 v = pool.virtualReserve();
        assertGe(q, v);
        assertGe(wbnb.balanceOf(address(pool)), q - v + pool.feeAccrued());
        return uint256(r0) * r1;
    }

    function _throughQuote(address input, address output) private view returns (address[] memory path) {
        path = new address[](3);
        (path[0], path[1], path[2]) = (input, address(wbnb), output);
    }
}

contract GasLimitedBucket {
    uint256 public minimumGas;
    mapping(address => bool) public operators;
    mapping(address => uint256) public accruedQuote;

    function setOperator(address account, bool allowed) external {
        operators[account] = allowed;
    }

    function setMinimumGas(uint256 minimum) external {
        minimumGas = minimum;
    }

    function notifyAccrual(address quote, uint256 amount) external {
        if (gasleft() < minimumGas) {
            // Exhaust the forwarded gas while the caller retains its EIP-150 reserve.
            assembly ("memory-safe") { for {} 1 {} {} }
        }
        require(operators[msg.sender]);
        require(IERC20(quote).transferFrom(msg.sender, address(this), amount));
        accruedQuote[quote] += amount;
    }
}

contract GangSwapV2GasCoverageTest is GangSwapV2Fixture {
    uint256 private constant BUCKET_GAS = 5_000_000;
    bytes32 private constant PLATFORM_DEFERRED = keccak256("PlatformDeferred(uint256)");

    GasLimitedBucket private gasBucket;
    MockToken private secondToken;

    function setUp() public override {
        _mocks();
        gasBucket = new GasLimitedBucket();
        bucket = MockBucket(address(gasBucket));
        _deploy();
        _newPool(G);
    }

    function test_collectPreservesLiabilitiesWhenBucketRunsOutOfGas() public {
        _sweep(false);
    }

    function test_claimPreservesLiabilitiesWhenBucketRunsOutOfGas() public {
        _sweep(true);
    }

    function test_stepDoesNotCallBucketWithLimitedGas() public {
        gasBucket.setMinimumGas(BUCKET_GAS);
        vm.expectCall(address(gasBucket), abi.encodeWithSelector(GasLimitedBucket.notifyAccrual.selector), 0);
        uint256[3] memory limits = [uint256(450_000), 1_000_000, 4_000_000];
        for (uint256 i; i < limits.length; i++) {
            _buy(trader, 0.1 ether);
            vm.warp(vm.getBlockTimestamp() + boost.STEP_GAP());
            uint256 accrued = pair.feeAccrued();
            uint256 pending = fees.pendingPlatform();
            (uint256 spent, uint256 burned) = boost.step{gas: limits[i]}(address(token));
            assertGt(burned, 0);
            assertEq(pair.feeAccrued(), 0);
            assertEq(fees.pendingPlatform(), pending + accrued + spent / 100);
            assertEq(bucket.accruedQuote(address(wbnb)), 0);
            _assertLedger();
            _checkInvariants();
        }
    }

    function _sweep(bool claim) private {
        _openNormalSettlementOnBothPools();
        _buy(trader, 1 ether);
        gasBucket.setMinimumGas(BUCKET_GAS);
        bytes memory payload = claim
            ? abi.encodeCall(fees.claim, (address(token), creator))
            : abi.encodeCall(fees.collect, (address(pair)));

        uint256[7] memory limits = [uint256(20_000), 100_000, 250_000, 500_000, 1_000_000, 2_000_000, 4_000_000];
        uint256 deferred;
        for (uint256 i; i < limits.length; i++) {
            uint256 snapshot = vm.snapshotState();
            if (_tryCollection(payload, limits[i], claim)) deferred++;
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
        assertGt(deferred, 0, "no successful deferred collection");
        assertLt(deferred, limits.length, "no fully reverted collection");
    }

    function _tryCollection(bytes memory payload, uint256 gasLimit, bool claim) private returns (bool ok) {
        uint256 accrued = pair.feeAccrued();
        uint256 creatorShare = accrued * 7 / 10;
        uint256 creatorBefore = wbnb.balanceOf(creator);
        uint256 bucketBefore = bucket.accruedQuote(address(wbnb));
        uint256 pairBefore = wbnb.balanceOf(address(pair));
        uint256 secondLiability = fees.creatorFeeOf(address(secondToken));

        vm.recordLogs();
        vm.prank(creator);
        bytes memory result;
        (ok, result) = address(fees).call{gas: gasLimit}(payload);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(bucket.accruedQuote(address(wbnb)), bucketBefore);
        assertEq(wbnb.balanceOf(address(bucket)), bucketBefore);
        assertEq(wbnb.allowance(address(fees), address(bucket)), 0);
        assertEq(fees.creatorFeeOf(address(secondToken)), secondLiability);
        if (!ok) {
            assertEq(pair.feeAccrued(), accrued);
            assertEq(wbnb.balanceOf(address(pair)), pairBefore);
            assertEq(wbnb.balanceOf(creator), creatorBefore);
            assertEq(fees.creatorFeeOf(address(token)), 0);
            assertEq(fees.pendingPlatform(), 0);
            _assertLedger();
            return false;
        }

        assertEq(abi.decode(result, (uint256)), claim ? creatorShare : accrued);
        assertEq(pair.feeAccrued(), 0);
        assertEq(wbnb.balanceOf(address(pair)), pairBefore - accrued);
        assertEq(wbnb.balanceOf(creator) - creatorBefore, claim ? creatorShare : 0);
        assertEq(fees.creatorFeeOf(address(token)), claim ? 0 : creatorShare);
        uint256 pending = accrued - creatorShare;
        assertEq(fees.pendingPlatform(), pending);
        _assertDeferred(logs, pending);
        _assertLedger();

        fees.flushPlatform{gas: 8_000_000}();
        assertEq(fees.pendingPlatform(), 0);
        assertEq(bucket.accruedQuote(address(wbnb)) - bucketBefore, pending);
        assertEq(wbnb.balanceOf(address(bucket)) - bucketBefore, pending);
        _assertLedger();
        _checkInvariants();
    }

    function _openNormalSettlementOnBothPools() private {
        _runBoost();
        _endWindow();
        assertEq(fees.collect(address(pair)), 0);
        MockToken firstToken = token;
        IGangSwapV2Pair firstPair = pair;

        _newPool(12 ether);
        _runBoost();
        _endWindow();
        assertEq(fees.collect(address(pair)), 0);
        _buy(trader, 0.5 ether);
        fees.collect(address(pair));
        secondToken = token;
        assertGt(fees.creatorFeeOf(address(secondToken)), 0);

        token = firstToken;
        pair = firstPair;
        _assertLedger();
    }

    function _assertLedger() private view {
        uint256 liabilities = fees.creatorFeeOf(address(token)) + fees.creatorFeeOf(address(secondToken));
        assertEq(wbnb.balanceOf(address(fees)), liabilities + fees.pendingPlatform());
    }

    function _assertDeferred(Vm.Log[] memory logs, uint256 pending) private view {
        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(fees) && logs[i].topics[0] == PLATFORM_DEFERRED) {
                assertEq(abi.decode(logs[i].data, (uint256)), pending);
                count++;
            }
        }
        assertEq(count, 1);
    }
}

contract GangSwapV2EventCoverageTest is GangSwapV2Fixture {
    bytes32 private constant PAIR_CREATED = keccak256("PairCreated(address,address,address,uint256)");
    bytes32 private constant SYNC = keccak256("Sync(uint112,uint112)");
    bytes32 private constant FEE_TAKEN = keccak256("FeeTaken(uint256,uint256)");
    bytes32 private constant FEES_CLAIMED = keccak256("FeesClaimed(address,uint256)");
    bytes32 private constant FEES_COLLECTED = keccak256("FeesCollected(address,address,uint256,uint256)");

    struct IndexedPool {
        address pool;
        bool quoteIs0;
        uint256 reserve0;
        uint256 reserve1;
        uint256 feesTaken;
        uint256 feesCollected;
    }

    struct EventBatch {
        uint256 sync0;
        uint256 sync1;
        uint256 feeQuote;
        uint256 feeToken;
        uint256 claimed;
        uint256 booked;
        bool sawSync;
        bool sawSwap;
    }

    function testFuzz_pairEventsReconstructReservesAndFees(uint256 seed) public {
        IndexedPool memory indexedPool;
        vm.recordLogs();
        _newPool(G);
        _consume(indexedPool, vm.getRecordedLogs());
        _assertIndexedState(indexedPool);

        uint256 start = seed % 10;
        for (uint256 i; i < 24; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 operation = i < 10 ? (i + start) % 10 : seed % 10;
            vm.recordLogs();
            _apply(operation, seed);
            _consume(indexedPool, vm.getRecordedLogs());
            _assertIndexedState(indexedPool);
        }
    }

    function _apply(uint256 operation, uint256 seed) private {
        uint256 quoteIn = 0.01 ether + (seed >> 16) % 0.5 ether;
        uint256 tokenIn = 1_000 ether + (seed >> 64) % 1_000_000 ether;
        if (operation == 0) {
            _buy(trader, quoteIn);
        } else if (operation == 1) {
            _sell(holder, tokenIn);
        } else if (operation == 2) {
            address[] memory path = _path(address(wbnb), address(token));
            uint256 output = router.getAmountsOut(quoteIn, path)[1] / 2;
            uint256 payment = router.getAmountsIn(output, path)[0];
            vm.deal(trader, payment);
            vm.prank(trader);
            router.swapETHForExactTokens{value: payment}(output, path, trader, block.timestamp);
        } else if (operation == 3) {
            address[] memory path = _path(address(token), address(wbnb));
            uint256 output = router.getAmountsOut(tokenIn, path)[1] / 2;
            uint256 payment = router.getAmountsIn(output, path)[0];
            vm.startPrank(holder);
            token.approve(address(router), payment);
            router.swapTokensForExactETH(output, payment, path, holder, block.timestamp);
            vm.stopPrank();
        } else if (operation == 4) {
            _donate(quoteIn / 10, tokenIn / 10);
        } else if (operation == 5) {
            pair.sync();
        } else if (operation == 6) {
            pair.skim(holder);
        } else if (operation == 7) {
            vm.warp(vm.getBlockTimestamp() + boost.STEP_GAP());
            boost.step(address(token));
        } else if (operation == 8) {
            fees.collect(address(pair));
        } else {
            _donate(quoteIn / 10, tokenIn / 10);
            _buy(trader, quoteIn);
        }
    }

    function _consume(IndexedPool memory indexedPool, Vm.Log[] memory logs) private view {
        EventBatch memory batch;
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length == 0) continue;
            bytes32 eventId = entry.topics[0];
            if (entry.emitter == address(factory) && eventId == PAIR_CREATED) {
                (indexedPool.pool,) = abi.decode(entry.data, (address, uint256));
                indexedPool.quoteIs0 = address(uint160(uint256(entry.topics[1]))) == address(wbnb);
            } else if (entry.emitter == indexedPool.pool) {
                if (eventId == FEE_TAKEN) {
                    (batch.feeQuote, batch.feeToken) = abi.decode(entry.data, (uint256, uint256));
                    indexedPool.feesTaken += batch.feeQuote;
                } else if (eventId == SYNC) {
                    (batch.sync0, batch.sync1) = abi.decode(entry.data, (uint112, uint112));
                    batch.sawSync = true;
                } else if (eventId == SWAP_EVENT) {
                    _applySwap(indexedPool, batch, entry.data);
                } else if (eventId == FEES_CLAIMED) {
                    batch.claimed += abi.decode(entry.data, (uint256));
                }
            } else if (entry.emitter == address(fees) && eventId == FEES_COLLECTED) {
                assertEq(address(uint160(uint256(entry.topics[1]))), indexedPool.pool);
                (uint256 amount,) = abi.decode(entry.data, (uint256, uint256));
                batch.booked += amount;
            }
        }
        // A Sync without a Swap initializes reserves or includes a standalone sync's deposits.
        if (batch.sawSync && !batch.sawSwap) {
            indexedPool.reserve0 = batch.sync0;
            indexedPool.reserve1 = batch.sync1;
        }
        assertEq(batch.claimed, batch.booked);
        indexedPool.feesCollected += batch.claimed;
    }

    function _applySwap(IndexedPool memory indexedPool, EventBatch memory batch, bytes memory data) private pure {
        (uint256 in0, uint256 in1, uint256 out0, uint256 out1) =
            abi.decode(data, (uint256, uint256, uint256, uint256));
        (uint256 fee0, uint256 fee1) =
            indexedPool.quoteIs0 ? (batch.feeQuote, batch.feeToken) : (batch.feeToken, batch.feeQuote);
        indexedPool.reserve0 = indexedPool.reserve0 + in0 - out0 - fee0;
        indexedPool.reserve1 = indexedPool.reserve1 + in1 - out1 - fee1;
        assertTrue(batch.sawSync);
        assertEq(indexedPool.reserve0, batch.sync0);
        assertEq(indexedPool.reserve1, batch.sync1);
        batch.sawSwap = true;
    }

    function _assertIndexedState(IndexedPool memory indexedPool) private view {
        assertEq(indexedPool.pool, address(pair));
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(indexedPool.reserve0, r0);
        assertEq(indexedPool.reserve1, r1);
        assertEq(indexedPool.feesTaken, indexedPool.feesCollected + pair.feeAccrued());
    }
}

contract GangSwapV2VersionCoverageTest is GangSwapV2Fixture {
    struct LegacyPool {
        GangSwapBoost boost;
        GangSwapFees fees;
        IGangSwapPair pair;
        IRouter router;
        MockToken token;
    }

    function test_versionMismatchesAndUnauthorizedRegisterPreserveBalances() public {
        LegacyPool memory legacy = _graduateLegacyPool();
        _buy(trader, 1 ether);
        address quote = address(wbnb);
        address[] memory legacyPath = _path(address(legacy.token), quote);
        address[] memory currentPath = _path(address(token), quote);
        vm.startPrank(holder);
        legacy.token.approve(address(router), 1 ether);
        token.approve(address(legacy.router), 1 ether);
        vm.stopPrank();
        bytes32 before = _balances(legacy);

        vm.prank(holder);
        vm.expectRevert();
        legacy.router.swapExactTokensForETH(1 ether, 0, currentPath, holder, block.timestamp);
        assertEq(_balances(legacy), before);

        vm.prank(holder);
        vm.expectRevert();
        router.swapExactTokensForETH(1 ether, 0, legacyPath, holder, block.timestamp);
        assertEq(_balances(legacy), before);

        vm.expectRevert(GangSwapFees.UnknownPair.selector);
        legacy.fees.collect(address(pair));
        assertEq(_balances(legacy), before);

        vm.expectRevert(GangSwapV2Fees.UnknownPair.selector);
        fees.collect(address(legacy.pair));
        assertEq(_balances(legacy), before);

        vm.prank(holder);
        vm.expectRevert(GangSwapV2Boost.OnlyMigrator.selector);
        boost.register(address(legacy.token), address(legacy.pair), 1 ether);
        assertEq(_balances(legacy), before);
        (address registered,,,,) = boost.boosts(address(legacy.token));
        assertEq(registered, address(0));
    }

    function _graduateLegacyPool() private returns (LegacyPool memory legacy) {
        uint256 n = vm.getNonce(address(this));
        address m = vm.computeCreateAddress(address(this), n);
        address b = vm.computeCreateAddress(address(this), n + 1);
        address f = vm.computeCreateAddress(address(this), n + 2);
        address fac = vm.computeCreateAddress(address(this), n + 3);
        GangSwapMigrator legacyMigrator = new GangSwapMigrator(address(this), fac, b, address(wbnb));
        legacy.boost = new GangSwapBoost(m, address(wbnb));
        legacy.fees = new GangSwapFees(fac, m, address(bucket), address(wbnb));
        assertEq(deployCode("GangSwapPair.sol:GangSwapFactory", abi.encode(m, f)), fac);
        legacy.router = IRouter(deployCode("GangSwapRouter.sol:GangSwapRouter", abi.encode(fac, address(wbnb))));
        legacyMigrator.addLaunchpad(address(pad));
        bucket.setOperator(address(legacy.fees), true);

        legacy.token = new MockToken(address(this));
        legacy.token.transfer(address(pad), POOL_TOKENS);
        legacy.token.transfer(holder, SUPPLY - POOL_TOKENS);
        pad.setCreator(address(legacy.token), creator);
        vm.deal(address(this), G);
        wbnb.deposit{value: G}();
        wbnb.transfer(address(pad), G);
        legacy.pair = IGangSwapPair(pad.graduate(address(legacyMigrator), address(legacy.token), address(wbnb), POOL_TOKENS, G));
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        legacy.router.swapExactETHForTokens{value: 1 ether}(
            0, _path(address(wbnb), address(legacy.token)), trader, block.timestamp
        );
    }

    function _balances(LegacyPool memory legacy) private view returns (bytes32 digest) {
        address[12] memory accounts = [
            holder, creator, trader, address(bucket), address(pair), address(legacy.pair),
            address(router), address(legacy.router), address(fees), address(legacy.fees),
            address(boost), address(legacy.boost)
        ];
        digest = keccak256(abi.encode(pair.feeAccrued(), legacy.pair.feeAccrued()));
        for (uint256 i; i < accounts.length; i++) {
            address account = accounts[i];
            digest = keccak256(abi.encode(
                digest, account.balance, wbnb.balanceOf(account), token.balanceOf(account),
                legacy.token.balanceOf(account)
            ));
        }
    }
}
