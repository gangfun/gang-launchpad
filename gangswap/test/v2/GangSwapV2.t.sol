// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangSwapV2Migrator} from "../../src/v2/GangSwapV2Migrator.sol";
import {GangSwapV2Boost} from "../../src/v2/GangSwapV2Boost.sol";
import {GangSwapV2Fees} from "../../src/v2/GangSwapV2Fees.sol";
import {IGangSwapV2Factory, IGangSwapV2Pair} from "../../src/v2/interfaces/IGangSwapV2.sol";
import {MockWBNB, MockToken, MockPad, MockBucket} from "../Mocks.sol";

interface IRouter {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);
    function swapTokensForExactTokens(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);
    function swapExactETHForTokens(uint256, address[] calldata, address, uint256)
        external
        payable
        returns (uint256[] memory);
    function swapETHForExactTokens(uint256, address[] calldata, address, uint256)
        external
        payable
        returns (uint256[] memory);
    function swapExactTokensForETH(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);
    function swapTokensForExactETH(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256, address[] calldata, address, uint256)
        external
        payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256, uint256, address[] calldata, address, uint256)
        external;
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
    function getAmountsIn(uint256, address[] calldata) external view returns (uint256[] memory);
}

abstract contract GangSwapV2Fixture is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant POOL_TOKENS = 200_000_000 ether;

    MockWBNB wbnb;
    MockToken token;
    MockPad pad;
    MockBucket bucket;
    GangSwapV2Migrator migrator;
    GangSwapV2Boost boost;
    GangSwapV2Fees fees;
    IGangSwapV2Factory factory;
    IRouter router;
    IGangSwapV2Pair pair;

    address holder = makeAddr("holder"); // stands for everyone who bought the 800M on the curve
    address creator = makeAddr("creator");
    address trader = makeAddr("trader");

    uint256 G = 9 ether;

    function setUp() public virtual {
        _mocks();
        token = new MockToken(address(this));
        _deploy();
        _seedPool(G);
    }

    function _mocks() internal {
        wbnb = new MockWBNB();
        pad = new MockPad();
        bucket = new MockBucket();
    }

    function _newPool(uint256 g) internal {
        token = new MockToken(address(this));
        _seedPool(g);
    }

    function _seedPool(uint256 g) internal {
        token.transfer(address(pad), POOL_TOKENS);
        token.transfer(holder, SUPPLY - POOL_TOKENS);
        pad.setCreator(address(token), creator);
        _graduate(g);
    }

    function _deploy() internal {
        _deploySet();
        migrator.addLaunchpad(address(pad));
        bucket.setOperator(address(fees), true);
    }

    function _deploySet() internal {
        uint256 n = vm.getNonce(address(this));
        address mAddr = vm.computeCreateAddress(address(this), n);
        address bAddr = vm.computeCreateAddress(address(this), n + 1);
        address fAddr = vm.computeCreateAddress(address(this), n + 2);
        address facAddr = vm.computeCreateAddress(address(this), n + 3);
        migrator = new GangSwapV2Migrator(address(this), facAddr, bAddr, address(wbnb));
        boost = new GangSwapV2Boost(mAddr, address(wbnb), facAddr);
        fees = new GangSwapV2Fees(facAddr, mAddr, address(bucket), address(wbnb), bAddr);
        factory = IGangSwapV2Factory(deployCode("GangSwapV2Pair.sol:GangSwapV2Factory", abi.encode(mAddr, fAddr)));
        assertEq(address(factory), facAddr);
        assertEq(address(migrator), mAddr);
        router = IRouter(deployCode("GangSwapV2Router.sol:GangSwapV2Router", abi.encode(address(factory), address(wbnb))));
    }

    function _graduate(uint256 g) internal {
        vm.deal(address(this), g);
        wbnb.deposit{value: g}();
        wbnb.transfer(address(pad), g);
        pair = IGangSwapV2Pair(pad.graduate(address(migrator), address(token), address(wbnb), POOL_TOKENS, g));
    }

    // ---------------------------------------------------------------- helpers
    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _reserves() internal view returns (uint256 rq, uint256 rt) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (rq, rt) = pair.quoteIs0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _k() internal view returns (uint256) {
        (uint256 rq, uint256 rt) = _reserves();
        return rq * rt;
    }

    function _buy(address who, uint256 bnb) internal returns (uint256 out) {
        vm.deal(who, bnb);
        vm.prank(who);
        uint256[] memory a =
            router.swapExactETHForTokens{value: bnb}(0, _path(address(wbnb), address(token)), who, block.timestamp);
        out = a[1];
    }

    function _sell(address who, uint256 amount) internal returns (uint256 out) {
        vm.startPrank(who);
        token.approve(address(router), amount);
        uint256 before = who.balance;
        router.swapExactTokensForETH(amount, 0, _path(address(token), address(wbnb)), who, block.timestamp);
        vm.stopPrank();
        out = who.balance - before;
    }

    function _checkInvariants() internal view {
        (uint256 rq,) = _reserves();
        uint256 v = pair.virtualReserve();
        assertGe(rq, v, "I1: effective quote >= V");
        assertGe(wbnb.balanceOf(address(pair)), (rq - v) + pair.feeAccrued(), "I6: balance >= real + feeAccrued");
    }

    function _runBoost() internal returns (uint256 steps) {
        while (true) {
            (,,,, uint128 left) = boost.boosts(address(token));
            if (left == 0) break;
            vm.warp(block.timestamp + 8);
            (uint256 rq,) = _reserves();
            (uint256 spent,) = boost.step(address(token));
            assertLe(spent, rq * boost.CAP_BPS() / 10_000);
            steps++;
            require(steps < 300, "runaway");
        }
    }

    function _endWindow() internal {
        (, uint64 lastStepAt,,, uint128 left) = boost.boosts(address(token));
        assertEq(left, 0);
        vm.warp(uint256(lastStepAt) + fees.GRACE());
    }

    function _swapRaw(uint256 quoteOut, uint256 tokenOut, address recipient) internal {
        (uint256 out0, uint256 out1) = pair.quoteIs0() ? (quoteOut, tokenOut) : (tokenOut, quoteOut);
        pair.swap(out0, out1, recipient, "");
    }

    function _donate(uint256 quoteIn, uint256 tokenIn) internal {
        if (quoteIn != 0) {
            vm.deal(address(this), quoteIn);
            wbnb.deposit{value: quoteIn}();
            wbnb.transfer(address(pair), quoteIn);
        }
        if (tokenIn != 0) {
            vm.prank(holder);
            token.transfer(address(pair), tokenIn);
        }
    }

    receive() external payable {}
}

contract GangSwapV2Test is GangSwapV2Fixture {
    // ---------------------------------------------------------------- graduation
    function test_graduationSplitsTheRaise() public view {
        uint256 v = (G * POOL_TOKENS) / SUPPLY; // 0.2 G
        assertEq(v, 1.8 ether);
        assertEq(pair.virtualReserve(), v);
        (uint256 rq, uint256 rt) = _reserves();
        assertEq(rq, G, "effective quote = the raise: price continues the curve");
        assertEq(rt, POOL_TOKENS);
        assertEq(pair.realQuoteReserve(), G - v);
        assertEq(wbnb.balanceOf(address(pair)), G - v);
        assertEq(wbnb.balanceOf(address(boost)), v);
        (address bp,,, uint128 bv, uint128 left) = boost.boosts(address(token));
        assertEq(bp, address(pair));
        assertEq(bv, v);
        assertEq(left, v);
        assertEq(migrator.padOf(address(pair)), address(pad));
        // LP: all of it burned (MINIMUM_LIQUIDITY at 0x0, the rest at 0xdead)
        assertEq(pair.balanceOf(DEAD) + pair.balanceOf(address(0)), pair.totalSupply());
        assertEq(factory.getPair(address(token), address(wbnb)), address(pair));
    }

    function test_onlyMigratorCreatesPairs_andMintIsOneShot() public {
        vm.expectRevert(bytes("GangSwap: FORBIDDEN"));
        factory.createPair(address(token), address(wbnb), address(wbnb), 1);
        vm.prank(address(migrator));
        vm.expectRevert(bytes("GangSwap: FORBIDDEN"));
        pair.mint(trader);
        vm.expectRevert(bytes("GangSwap: FORBIDDEN"));
        pair.mint(trader);
        vm.expectRevert(bytes("GangSwap: BURN_DISABLED"));
        pair.burn(trader);
        vm.expectRevert(GangSwapV2Migrator.OnlyLaunchpad.selector);
        migrator.migrate(address(token), address(wbnb), 1, 1);
    }

    function test_addLaunchpadRequiresWiring() public {
        assertTrue(migrator.wired());
        // a migrator whose predicted factory / boost / fees don't point back at it cannot list a pad
        GangSwapV2Migrator stray = new GangSwapV2Migrator(address(this), address(factory), address(boost), address(wbnb));
        assertFalse(stray.wired());
        vm.expectRevert(GangSwapV2Migrator.NotWired.selector);
        stray.addLaunchpad(address(pad));
    }

    /// @dev Each `wired()` condition alone makes it false.
    function test_wiredChecksEveryPointer() public {
        address[9] memory at = [
            address(factory), address(boost), address(boost), address(boost), address(boost),
            address(fees), address(fees), address(fees), address(fees)
        ];
        string[9] memory sig = [
            "migrator()", "migrator()", "quote()", "factory()", "fees()",
            "factory()", "migrator()", "quote()", "boost()"
        ];
        for (uint256 i; i < at.length; i++) {
            vm.mockCall(at[i], abi.encodeWithSignature(sig[i]), abi.encode(address(1)));
            assertFalse(migrator.wired(), sig[i]);
            vm.expectRevert(GangSwapV2Migrator.NotWired.selector);
            migrator.addLaunchpad(address(2));
            vm.clearMockedCalls();
            assertTrue(migrator.wired());
        }
    }

    function test_migratorErrorPaths() public {
        vm.startPrank(address(pad));
        vm.expectRevert(GangSwapV2Migrator.BadQuote.selector);
        migrator.migrate(address(token), address(token), 1, 1);
        vm.expectRevert(GangSwapV2Migrator.NothingToMigrate.selector);
        migrator.migrate(address(token), address(wbnb), 0, 1);
        vm.expectRevert(GangSwapV2Migrator.ZeroAddress.selector);
        migrator.migrate(address(0), address(wbnb), 1, 1);
        vm.stopPrank();
    }

    function test_secondGraduationOfSameTokenReverts() public {
        vm.deal(address(this), 1 ether);
        wbnb.deposit{value: 1 ether}();
        wbnb.transfer(address(pad), 1 ether);
        vm.prank(holder);
        token.transfer(address(pad), 1 ether);
        vm.expectRevert(bytes("GangSwap: PAIR_EXISTS"));
        pad.graduate(address(migrator), address(token), address(wbnb), 1 ether, 1 ether);
    }

    function test_routerInitCodeHashMatchesFactory() public view {
        // the router's pairFor must land on the factory's pair, or every router call would hit an empty address
        uint256[] memory a = router.getAmountsOut(1 ether, _path(address(wbnb), address(token)));
        assertGt(a[1], 0);
        address t0 = address(wbnb) < address(token) ? address(wbnb) : address(token);
        address t1 = t0 == address(wbnb) ? address(token) : address(wbnb);
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            address(factory),
                            keccak256(abi.encodePacked(t0, t1)),
                            factory.INIT_CODE_PAIR_HASH()
                        )
                    )
                )
            )
        );
        assertEq(predicted, address(pair));
    }

    // ---------------------------------------------------------------- trading
    function test_buyMatchesQuote_andFeeLeavesThePool() public {
        uint256[] memory q = router.getAmountsOut(1 ether, _path(address(wbnb), address(token)));
        uint256 k0 = _k();
        uint256 out = _buy(trader, 1 ether);
        assertEq(out, q[1]);
        assertEq(token.balanceOf(trader), out);
        assertEq(pair.feeAccrued(), 0.01 ether, "1% of the input, kept for GangSwapV2Fees");
        (uint256 rq,) = _reserves();
        assertEq(rq, G + 0.99 ether, "the fee is not in the reserves");
        assertGe(_k(), k0);
        _checkInvariants();
    }

    event FeeTaken(uint256 feeQuote, uint256 feeTokenBurned);

    function test_sellAccruesRoundedUpQuoteFee() public {
        uint256 amount = 10_000_000 ether;
        uint256[] memory q = router.getAmountsOut(amount, _path(address(token), address(wbnb)));
        uint256 fee = (q[1] + 98) / 99;
        assertGt(q[1] % 99, 0);
        uint256 out = q[1];
        (uint256 out0, uint256 out1) = pair.quoteIs0() ? (out, uint256(0)) : (uint256(0), out);
        _donate(0, amount);
        vm.expectEmit(false, false, false, true, address(pair));
        emit FeeTaken(fee, 0);
        pair.swap(out0, out1, holder, "");
        assertEq(wbnb.balanceOf(holder), out);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(pair.feeAccrued(), fee);
        (uint256 rq, uint256 rt) = _reserves();
        assertEq(rq, G - out - fee);
        assertEq(rt, POOL_TOKENS + amount);
        _checkInvariants();
    }

    function test_exactOutBuyAndTokenToTokenPaths() public {
        uint256 want = 5_000_000 ether;
        uint256[] memory q = router.getAmountsIn(want, _path(address(wbnb), address(token)));
        assertEq(q[0], pair.getAmountIn(want, address(token)));
        vm.deal(trader, q[0]);
        vm.prank(trader);
        router.swapETHForExactTokens{value: q[0]}(want, _path(address(wbnb), address(token)), trader, block.timestamp);
        assertEq(token.balanceOf(trader), want);
        _checkInvariants();
    }

    function test_flashSwapRefused() public {
        vm.expectRevert(bytes("GangSwap: NO_FLASH_SWAP"));
        pair.swap(1, 0, trader, hex"01");
    }

    function test_cannotTakeMoreThanK() public {
        // send 1 BNB and ask for 1 wei more than the quote: K check refuses
        uint256[] memory q = router.getAmountsOut(1 ether, _path(address(wbnb), address(token)));
        vm.deal(trader, 1 ether);
        vm.startPrank(trader);
        wbnb.deposit{value: 1 ether}();
        wbnb.transfer(address(pair), 1 ether);
        (uint256 o0, uint256 o1) = pair.quoteIs0() ? (uint256(0), q[1] + 1) : (q[1] + 1, uint256(0));
        vm.expectRevert(bytes("GangSwap: K"));
        pair.swap(o0, o1, trader, "");
        vm.stopPrank();
    }

    function test_virtualQuoteIsNeverPaidOut() public {
        // The net amount fits the effective reserve, but the net amount plus its fee exceeds it.
        (uint256 rq,) = _reserves();
        assertEq(wbnb.balanceOf(address(pair)), rq - pair.virtualReserve());
        (uint256 o0, uint256 o1) = pair.quoteIs0() ? (rq - 1, uint256(0)) : (uint256(0), rq - 1);
        vm.prank(holder);
        token.transfer(address(pair), 800_000_000 ether - 1);
        vm.expectRevert(bytes("GangSwap: INSUFFICIENT_LIQUIDITY"));
        pair.swap(o0, o1, holder, "");
    }

    // ---------------------------------------------------------------- H1: fee-on-transfer path, quote input
    function test_fotPathQuoteInput_matchesStandardPath() public {
        // accrue fees first so quoteBalanceBase != reserve - V
        _buy(trader, 3 ether);
        _sell(holder, 50_000_000 ether);
        assertGt(pair.feeAccrued(), 0);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 0.1 ether;
        amounts[1] = 1 ether;
        amounts[2] = 2 ether;
        for (uint256 i; i < amounts.length; i++) {
            uint256 snap = vm.snapshotState();
            uint256 expected = router.getAmountsOut(amounts[i], _path(address(wbnb), address(token)))[1];
            address b = makeAddr(string(abi.encode("fot", i)));
            vm.deal(b, amounts[i]);
            vm.prank(b);
            router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amounts[i]}(
                expected, _path(address(wbnb), address(token)), b, block.timestamp
            );
            assertEq(token.balanceOf(b), expected, "FoT path gives exactly the standard quote");
            _checkInvariants();
            vm.revertToState(snap);
        }
    }

    function test_fotPathTokenInput_sell() public {
        uint256 amount = 20_000_000 ether;
        uint256 expected = router.getAmountsOut(amount, _path(address(token), address(wbnb)))[1];
        vm.startPrank(holder);
        token.approve(address(router), amount);
        uint256 before = holder.balance;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, expected, _path(address(token), address(wbnb)), holder, block.timestamp
        );
        vm.stopPrank();
        assertEq(holder.balance - before, expected);
    }

    // ---------------------------------------------------------------- full sell-back: no stranded real quote
    function test_sellEverything_noBoost_leavesNoRealQuote() public {
        _sell(holder, token.balanceOf(holder));
        assertLe(pair.realQuoteReserve(), 1);
        _checkInvariants();
    }

    function test_sellEverything_inSmallChunks() public {
        uint256 left = token.balanceOf(holder);
        uint256 chunk = left / 50;
        for (uint256 i; i < 50; i++) {
            _sell(holder, i == 49 ? token.balanceOf(holder) : chunk);
            _checkInvariants();
        }
        assertLt(pair.realQuoteReserve(), 0.1 ether);
    }

    function test_fullBoostThenSellEverything_matchesModel() public {
        _runBoost();
        _endWindow();
        assertEq(wbnb.balanceOf(address(boost)), 0);
        _sell(holder, token.balanceOf(holder));
        uint256 real = pair.realQuoteReserve();
        assertApproxEqAbs(real, 0.061533149 ether, 1e9);
        _checkInvariants();
    }

    // ---------------------------------------------------------------- boost
    function test_boostSchedule_40Steps_burnsToDead() public {
        uint256 deadBefore = token.balanceOf(DEAD);
        uint256 steps = _runBoost();
        assertEq(steps, 40);
        uint256 burned = token.balanceOf(DEAD) - deadBefore;
        assertApproxEqRel(burned, 33_060_000 ether, 0.01e18, "spec 7.4: ~33.06M burned");
        _checkInvariants();
    }

    function test_boostStep_gapFromLastStep_noCatchUp() public {
        boost.step(address(token)); // first step right after graduation
        vm.expectRevert(GangSwapV2Boost.TooEarly.selector);
        boost.step(address(token));
        vm.warp(block.timestamp + 7);
        vm.expectRevert(GangSwapV2Boost.TooEarly.selector);
        boost.step(address(token));
        // keeper away for an hour: still one step, then the gap again
        vm.warp(block.timestamp + 3600);
        boost.step(address(token));
        vm.expectRevert(GangSwapV2Boost.TooEarly.selector);
        boost.step(address(token));
    }

    function test_boostNotBlockedBySyncOrTrades() public {
        // review N1: a free sync() or a trade in the same block must not stop a step
        vm.warp(block.timestamp + 8);
        pair.sync();
        _buy(trader, 0.1 ether);
        boost.step(address(token));
    }

    function test_boostCapFollowsTheCurrentReserve() public {
        // the pool sold down: the step shrinks to 0.5% of the effective quote, so a sandwich cannot pay
        _sell(holder, 600_000_000 ether);
        (uint256 rq,) = _reserves();
        (uint256 s,) = boost.nextStep(address(token));
        assertEq(s, (rq * 50) / 10_000);
        assertLt(s, pair.virtualReserve() / 40);
    }

    function test_boostSandwichDoesNotPay() public {
        _sell(holder, 400_000_000 ether); // a lower reserve makes the step relatively bigger
        address mev = makeAddr("mev");
        uint256 spend = 3 ether;
        vm.warp(block.timestamp + 8);
        uint256 got = _buy(mev, spend);
        boost.step(address(token));
        uint256 back = _sell(mev, got);
        assertLt(back, spend, "front-run + back-run around a step loses money");
    }

    function test_boostOnlyMigratorRegisters() public {
        vm.expectRevert(GangSwapV2Boost.OnlyMigrator.selector);
        boost.register(address(token), address(pair), 1);
    }

    function test_boostDustFoldedIntoLastStep() public {
        _runBoost();
        (,,,, uint128 left) = boost.boosts(address(token));
        assertEq(left, 0);
        vm.expectRevert(GangSwapV2Boost.NothingLeft.selector);
        boost.step(address(token));
    }

    // ---------------------------------------------------------------- fees
    function test_feesSplit70_30() public {
        _runBoost();
        fees.flushPlatform();
        _endWindow();
        assertEq(fees.collect(address(pair)), 0);
        uint256 bucketBefore = bucket.accruedQuote(address(wbnb));
        _buy(trader, 2 ether); // 0.02 fee
        uint256 fee = pair.feeAccrued();
        fees.collect(address(pair));
        assertEq(pair.feeAccrued(), 0);
        assertEq(fees.creatorFeeOf(address(token)), (fee * 7000) / 10_000);
        assertEq(bucket.accruedQuote(address(wbnb)) - bucketBefore, fee - (fee * 7000) / 10_000);
        _checkInvariants();

        vm.prank(trader);
        vm.expectRevert(GangSwapV2Fees.NotCreator.selector);
        fees.claim(address(token), trader);

        vm.prank(creator);
        uint256 got = fees.claim(address(token), creator);
        assertEq(got, (fee * 7000) / 10_000);
        assertEq(wbnb.balanceOf(creator), got);
    }

    function test_claimCollectsFirst() public {
        _runBoost();
        _endWindow();
        assertEq(fees.collect(address(pair)), 0);
        _buy(trader, 1 ether);
        vm.prank(creator);
        uint256 got = fees.claim(address(token), creator);
        assertEq(got, (0.01 ether * 7000) / 10_000);
    }

    function test_bucketRefusal_doesNotBlockCreator() public {
        _runBoost();
        _endWindow();
        assertEq(fees.collect(address(pair)), 0);
        uint256 bucketBefore = bucket.accruedQuote(address(wbnb));
        bucket.setRefuse(true);
        _buy(trader, 2 ether);
        fees.collect(address(pair));
        uint256 pending = fees.pendingPlatform();
        assertGt(pending, 0);
        assertEq(wbnb.allowance(address(fees), address(bucket)), 0);
        vm.prank(creator);
        fees.claim(address(token), creator);
        assertGt(wbnb.balanceOf(creator), 0);
        bucket.setRefuse(false);
        fees.flushPlatform();
        assertEq(fees.pendingPlatform(), 0);
        assertEq(bucket.accruedQuote(address(wbnb)) - bucketBefore, pending);
    }

    function test_fakePairRefused() public {
        FakePair fake = new FakePair(address(token), address(wbnb));
        vm.expectRevert(GangSwapV2Fees.UnknownPair.selector);
        fees.collect(address(fake));
    }

    function test_onlyFeesClaimsFromPair() public {
        _buy(trader, 1 ether);
        vm.expectRevert(bytes("GangSwap: FORBIDDEN"));
        pair.claimFees();
    }

    // ---------------------------------------------------------------- donations, skim, sync
    function test_skimCannotTakeFees_andDonationIsJustAGift() public {
        _buy(trader, 1 ether);
        uint256 fee = pair.feeAccrued();
        pair.skim(trader); // nothing to skim
        assertEq(wbnb.balanceOf(trader), 0);
        assertEq(pair.feeAccrued(), fee);
        // donate 1 WBNB, skim it back: exactly the donation, never the fee
        vm.deal(address(this), 1 ether);
        wbnb.deposit{value: 1 ether}();
        wbnb.transfer(address(pair), 1 ether);
        pair.skim(trader);
        assertEq(wbnb.balanceOf(trader), 1 ether);
        // donate + sync: reserves rise, invariants hold
        vm.deal(address(this), 1 ether);
        wbnb.deposit{value: 1 ether}();
        wbnb.transfer(address(pair), 1 ether);
        uint256 k0 = _k();
        pair.sync();
        assertGt(_k(), k0);
        _checkInvariants();
    }

    // ---------------------------------------------------------------- fuzz: random sequences keep I1, I2, I6
    function testFuzz_randomSequence(uint256 seed) public {
        for (uint256 i; i < 25; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = seed % 10;
            uint256 k0 = _k();
            if (op == 0) {
                _buy(trader, 1e15 + (seed >> 8) % 3 ether);
            } else if (op == 1) {
                uint256 bal = token.balanceOf(holder);
                if (bal > 0) _sellIfQuoted(holder, 1 + (seed >> 8) % bal);
            } else if (op == 2) {
                uint256 bal = token.balanceOf(trader);
                if (bal > 0) _sellIfQuoted(trader, 1 + (seed >> 8) % bal);
            } else if (op == 3) {
                vm.warp(block.timestamp + 8);
                (, bool ready) = boost.nextStep(address(token));
                (,,,, uint128 left) = boost.boosts(address(token));
                if (ready && left > 0) boost.step(address(token));
            } else if (op == 4) {
                pair.sync();
            } else if (op == 5) {
                fees.collect(address(pair));
            } else if (op == 6) {
                _donate((seed >> 16) % 0.001 ether, token.balanceOf(holder) / 1_000);
            } else if (op == 7) {
                pair.skim(holder);
            } else if (op == 8) {
                uint256 tokenIn = token.balanceOf(holder) / 100;
                if (tokenIn > 0) {
                    uint256 quoteIn = 0.01 ether;
                    uint256 quoteOut = pair.getAmountOut(tokenIn, address(token)) / 2;
                    uint256 tokenOut = pair.getAmountOut(quoteIn, address(wbnb)) / 2;
                    _donate(quoteIn, tokenIn);
                    _swapRaw(quoteOut, tokenOut, holder);
                }
            } else {
                uint256 quoteIn = 0.01 ether;
                uint256 tokenOut = pair.getAmountOut(quoteIn, address(wbnb)) / 2;
                _donate(quoteIn, 0);
                _swapRaw(0, tokenOut, trader);
            }
            assertGe(_k(), k0, "I2: k never decreases");
            _checkInvariants();
        }
        // everyone sells out at the end: real quote stays >= 0 and small
        pair.skim(holder);
        uint256 finalK = _k();
        _sellIfQuoted(trader, token.balanceOf(trader));
        _sellIfQuoted(holder, token.balanceOf(holder));
        assertGe(_k(), finalK);
        _checkInvariants();
    }

    function _sellIfQuoted(address who, uint256 amount) internal {
        if (amount > 0 && pair.getAmountOut(amount, address(token)) > 0) _sell(who, amount);
    }

}

contract FakePair {
    address public token0;
    address public token1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function claimFees() external pure returns (uint256) {
        return 0;
    }
}
