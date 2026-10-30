// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../../src/common/SharedPlatformFeeBucket.sol";
import {GangMintToken} from "../../src/flywheel/GangMintToken.sol";
import {MintTokenDeployer} from "../../src/flywheel/MintTokenDeployer.sol";
import {FlywheelTaxHandler} from "../../src/flywheel/FlywheelTaxHandler.sol";
import {IFlywheelPadView} from "../../src/flywheel/interfaces/IFlywheelPadView.sol";
import {TwapMockPair, TwapMockPairFactory} from "../mocks/TwapMockPair.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";
import {MockWBNB} from "../mocks/MockWBNB.sol";
import {OracleView} from "./OracleView.sol";

/// @dev The pad's side of the handler, without the sale: deploys a token, hands out "minted" tokens with baselines
///      before launch (writing vault shares itself, as the pad does while the token is locked), seeds the pair and
///      calls `onLaunch`.
contract PadStub is IFlywheelPadView {
    SharedDividendVault public vault;
    FlywheelTaxHandler public handler;
    MintTokenDeployer public deployer;
    TwapMockPairFactory public factory;
    MockWBNB public quote;
    address public creator;
    GangMintToken public token;
    address public pair;
    mapping(address => uint256) public baseline;
    uint16 public hold = 6_000;

    constructor(
        SharedDividendVault vault_,
        FlywheelTaxHandler handler_,
        MintTokenDeployer deployer_,
        TwapMockPairFactory factory_,
        MockWBNB quote_
    ) {
        vault = vault_;
        handler = handler_;
        deployer = deployer_;
        factory = factory_;
        quote = quote_;
    }

    function create(address creator_, uint16 sellBps) external {
        creator = creator_;
        token = GangMintToken(
            deployer.deploy("Fly", "FLY", "u", address(handler), 100, sellBps, 2_000_000 ether, 200_000_000 ether)
        );
        vault.registerToken(address(token), address(quote));
        handler.register(address(token), address(quote), creator_);
    }

    /// @dev Pre-launch "mint": tokens + baseline + vault share (the token is locked, so the pad writes the share).
    function preMint(address to, uint256 amount) external {
        token.transfer(to, amount);
        baseline[to] += amount;
        vault.setShare(address(token), to, baseline[to]);
    }

    function launch(uint256 tokens, uint256 quoteAmount, uint64 protectFor, address gate, uint256 cap) external {
        token.unlock(address(this));
        pair = factory.createPair(address(token), address(quote));
        token.transfer(pair, tokens);
        quote.mintUnlimited(pair, quoteAmount);
        TwapMockPair(pair).mint(address(0xdead));
        token.setPair(pair);
        handler.onLaunch(address(token), uint64(block.timestamp) + protectFor, gate, cap);
    }

    /// @dev Post-launch mint, as the pad does it: re-qualify a wallet that was out (fresh baseline), then send.
    function postMint(address to, uint256 amount) external {
        if (handler.isOut(address(token), to)) {
            baseline[to] = 0;
            handler.requalify(address(token), to);
        }
        baseline[to] += amount;
        token.padMint(to, amount);
    }

    function baselineOf(address, address user) external view returns (uint256) {
        return baseline[user];
    }

    function holdBpsOf(address) external view returns (uint16) {
        return hold;
    }
}

/// @dev Quote that refuses transfers to one address (a creator whose payouts must become owed).
contract RefusingWBNB is MockWBNB {
    address public refused;

    function setRefused(address a) external {
        refused = a;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != refused, "refused");
        return super.transfer(to, amount);
    }
}

contract FlywheelTaxHandlerTest is Test {
    SharedDividendVault vault;
    SharedPlatformFeeBucket bucket;
    FlywheelTaxHandler handler;
    MintTokenDeployer deployer;
    TwapMockPairFactory factory;
    RefusingWBNB quote;
    MockAgentId agents;
    PadStub pad;
    GangMintToken token;
    TwapMockPair pair;
    OracleView oracle;

    address owner = makeAddr("owner");
    address feeVault = makeAddr("feeVault");
    address creator = makeAddr("creator");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice"); // minter
    address bob = makeAddr("bob"); // minter
    address carol = makeAddr("carol"); // pool buyer with an Agent ID
    address dave = makeAddr("dave"); // pool buyer without one

    uint256 constant LAUNCH_TOKENS = 1_000_000 ether;
    uint256 constant LAUNCH_QUOTE = 10 ether;
    uint256 constant CAP = 20_000 ether;

    function setUp() public {
        quote = new RefusingWBNB();
        agents = new MockAgentId();
        factory = new TwapMockPairFactory();
        vault = new SharedDividendVault(owner);
        bucket = new SharedPlatformFeeBucket(owner, feeVault);
        handler = new FlywheelTaxHandler(owner, address(vault), address(bucket), address(0));
        deployer = new MintTokenDeployer(owner);
        pad = new PadStub(vault, handler, deployer, factory, quote);
        oracle = new OracleView(address(handler));
        vm.startPrank(owner);
        handler.setLaunchpad(address(pad));
        handler.setKeeper(keeper);
        bucket.setOperator(address(handler), true);
        vault.setLaunchpad(address(pad), true);
        vault.setMinimumShareBalance(address(pad), 1_000 ether);
        vault.setOperator(address(handler), address(pad));
        deployer.setLaunchpad(address(pad), true);
        vm.stopPrank();
        agents.mint(alice, 1);
        agents.mint(bob, 2);
        agents.mint(carol, 3);
    }

    function _create(uint16 sellBps) internal {
        pad.create(creator, sellBps);
        token = pad.token();
        pad.preMint(alice, 100_000 ether);
        pad.preMint(bob, 100_000 ether);
    }

    function _launch(uint64 protectFor) internal {
        pad.launch(LAUNCH_TOKENS, LAUNCH_QUOTE, protectFor, address(agents), CAP);
        pair = TwapMockPair(pad.pair());
    }

    // ------------------------------------------------------------ pool helpers (Pancake V2 amounts, K-checked)
    function _amountOut(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 inFee = amountIn * 9975;
        return (inFee * rOut) / (rIn * 10_000 + inFee);
    }

    function _res() internal view returns (uint256 rT, uint256 rQ) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (rT, rQ) = pair.token0() == address(token) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _buy(address who, uint256 quoteIn) internal returns (uint256 out) {
        (uint256 rT, uint256 rQ) = _res();
        out = _amountOut(quoteIn, rQ, rT);
        quote.mintUnlimited(address(pair), quoteIn);
        if (pair.token0() == address(token)) pair.swap(out, 0, who, "");
        else pair.swap(0, out, who, "");
    }

    function _sell(address who, uint256 amount) internal returns (uint256 out) {
        vm.prank(who);
        token.transfer(address(pair), amount);
        (uint256 rT, uint256 rQ) = _res();
        uint256 inAmt = token.balanceOf(address(pair)) - rT;
        out = _amountOut(inAmt, rT, rQ);
        if (pair.token0() == address(token)) pair.swap(0, out, who, "");
        else pair.swap(out, 0, who, "");
    }

    // ------------------------------------------------------------ tax split
    function test_buyTaxSplitHoldersHalfPlatformQuarterDevRest() public {
        _create(100);
        _launch(0);
        uint256 gross = _buy(carol, 1 ether);
        uint256 tax = gross / 100;
        assertApproxEqAbs(handler.accruedTax(address(token)), tax, 1);
        assertApproxEqAbs(vault.unsoldUnits(address(token)), tax / 2, 2); // holders: half of the first 1%
        assertApproxEqAbs(handler.accruedPlatformTax(address(token)), tax / 4, 2); // platform: a quarter
        // sell it all: quote split 50 / 25 / 25
        uint256 all = handler.maxChunk(address(token));
        assertEq(all, tax); // within the block budget
        vm.prank(keeper);
        uint256 q = handler.process(address(token), all, 1);
        assertApproxEqRel(quote.balanceOf(creator), q / 4, 1e15);
        assertApproxEqRel(quote.balanceOf(address(bucket)), q / 4, 1e15);
        assertApproxEqRel(vault.pending(address(token), alice) + vault.pending(address(token), bob), q / 2, 1e15);
    }

    function test_sellTaxAboveOnePercentGoesToHolders() public {
        _create(200);
        _launch(0);
        _buy(carol, 1 ether);
        uint256 chunk = handler.maxChunk(address(token));
        vm.prank(keeper);
        handler.process(address(token), chunk, 1); // nothing accrued afterwards: no swap-back chunk
        assertEq(handler.accruedTax(address(token)), 0);
        uint256 units0 = vault.unsoldUnits(address(token));
        uint256 plat0 = handler.accruedPlatformTax(address(token));
        uint256 amount = 10_000 ether;
        _sell(carol, amount);
        uint256 tax = (amount * 200) / 10_000;
        // 2% sell: holders 0.5% + 1% = 3/4 of the tax, platform 0.25% = 1/8, creator 1/8
        assertApproxEqAbs(vault.unsoldUnits(address(token)) - units0, (tax * 3) / 4, 2);
        assertApproxEqAbs(handler.accruedPlatformTax(address(token)) - plat0, tax / 8, 2);
        assertEq(handler.accruedTax(address(token)), tax);
    }

    function test_noHoldersMeansTheHoldersPartIsThePlatforms() public {
        pad.create(creator, 100);
        token = pad.token();
        _launch(0);
        uint256 tax = _buy(carol, 1 ether) / 100;
        assertEq(vault.unsoldUnits(address(token)), 0);
        assertApproxEqAbs(handler.accruedPlatformTax(address(token)), (tax * 3) / 4, 2);
    }

    function test_creatorPushFailsBecomesOwedThenReleased() public {
        _create(100);
        _launch(0);
        _buy(carol, 2 ether);
        quote.setRefused(creator);
        uint256 all = handler.maxChunk(address(token));
        vm.prank(keeper);
        handler.process(address(token), all, 1);
        uint256 owed = handler.owedOf(address(token));
        assertGt(owed, 0);
        assertEq(quote.balanceOf(creator), 0);
        vm.expectRevert();
        handler.release(address(token));
        quote.setRefused(address(0));
        handler.release(address(token));
        assertEq(quote.balanceOf(creator), owed);
        assertEq(handler.owedOf(address(token)), 0);
    }

    // ------------------------------------------------------------ launch protection
    function test_protectionRefusesBuyerWithoutAgentId() public {
        _create(100);
        _launch(600);
        (uint256 rT, uint256 rQ) = _res();
        uint256 out = _amountOut(0.01 ether, rQ, rT);
        quote.mintUnlimited(address(pair), 0.01 ether);
        bool t0 = pair.token0() == address(token);
        vm.expectRevert(FlywheelTaxHandler.ProtectionNotAgent.selector);
        pair.swap(t0 ? out : 0, t0 ? 0 : out, dave, "");
    }

    function test_protectionCapsEachWalletsTotalEvenAfterMovingTokensOut() public {
        _create(100);
        _launch(600);
        _buy(carol, 0.15 ether); // ≈ 14.8k tokens gross
        uint256 held = token.balanceOf(carol);
        vm.prank(carol);
        token.transfer(dave, held); // balance back to 0
        (uint256 rT, uint256 rQ) = _res();
        uint256 out = _amountOut(0.1 ether, rQ, rT); // another ≈ 9.8k: over the 20k cap in total
        quote.mintUnlimited(address(pair), 0.1 ether);
        bool t0 = pair.token0() == address(token);
        vm.expectRevert(FlywheelTaxHandler.ProtectionCapExceeded.selector);
        pair.swap(t0 ? out : 0, t0 ? 0 : out, carol, "");
    }

    function test_protectionEndsOnTime() public {
        _create(100);
        _launch(600);
        vm.warp(vm.getBlockTimestamp() + 600);
        uint256 got = _buy(dave, 1 ether);
        assertGt(got, CAP); // no Agent ID, above the cap: fine after the window
    }

    // ------------------------------------------------------------ holder rule
    function test_sellBelowHoldLineIsOutBuyBackDoesNotRestoreMintingAgainDoes() public {
        _create(100);
        _launch(0);
        assertEq(vault.shares(address(token), alice), 100_000 ether);
        _sell(alice, 50_000 ether); // 50% < 60% hold line
        assertTrue(handler.isOut(address(token), alice));
        assertEq(vault.shares(address(token), alice), 0);
        _buy(alice, 1 ether);
        assertEq(vault.shares(address(token), alice), 0);
        pad.postMint(alice, 10_000 ether); // fresh baseline 10k, balance well above it
        assertFalse(handler.isOut(address(token), alice));
        assertEq(pad.baseline(alice), 10_000 ether);
        assertEq(vault.shares(address(token), alice), 10_000 ether);
    }

    function test_sellerGetsNoPartOfItsOwnSellTax() public {
        _create(100);
        _launch(0);
        _sell(alice, 10_000 ether); // stays above the hold line
        // alice's units from her own sell: credited after her share was synced down, bob's share unchanged
        uint256 a = vault.pendingUnits(address(token), alice);
        uint256 b = vault.pendingUnits(address(token), bob);
        assertLt(a, b);
    }

    function test_poolBuyersHaveNoShare() public {
        _create(100);
        _launch(0);
        _buy(carol, 1 ether);
        assertEq(vault.shares(address(token), carol), 0);
        assertEq(handler.eligibleShare(address(token), carol), 0);
    }

    // ------------------------------------------------------------ oracle
    function test_twapStartsAtTheLaunchPriceAndMovesSlowly() public {
        _create(100);
        _launch(0);
        uint256 p0 = oracle.spotPrice(address(token));
        assertEq(oracle.twap(address(token)), p0);
        vm.warp(vm.getBlockTimestamp() + 60);
        _sell(alice, 30_000 ether); // spot drops several %
        uint256 spot = oracle.spotPrice(address(token));
        assertLt(spot, (p0 * 95) / 100);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 t = oracle.twap(address(token));
        assertGt(t, (p0 * 99) / 100); // 1 second of a low price in a 30-minute window
    }

    function test_twapAfterTheFirstWindowUsesObservations() public {
        _create(100);
        _launch(0);
        uint256 p0 = oracle.spotPrice(address(token));
        for (uint256 i; i < 12; i++) {
            vm.warp(vm.getBlockTimestamp() + 5 minutes);
            vm.roll(vm.getBlockNumber() + 1);
            handler.observe(address(token));
        }
        assertApproxEqRel(oracle.twap(address(token)), p0, 1e12);
        _buy(carol, 2 ether); // price up ~40%
        uint256 p1 = oracle.spotPrice(address(token));
        vm.warp(vm.getBlockTimestamp() + 15 minutes);
        uint256 t = oracle.twap(address(token));
        assertGt(t, p0);
        assertLt(t, p1);
    }

    /// @dev V2: the pad reads a 15- or 30-minute TWAP from the same observations (the handler is unchanged), and seeds
    ///      the first window after launch at the launch price over the window chosen.
    function test_twapOverEitherWindowFromTheSameObservations() public {
        _create(100);
        _launch(0);
        uint256 p0 = oracle.spotPrice(address(token));
        vm.warp(vm.getBlockTimestamp() + 60);
        _sell(alice, 30_000 ether);
        uint256 low = oracle.spotPrice(address(token));
        vm.warp(vm.getBlockTimestamp() + 60);
        // 120 s after launch: 60 s at the launch price, 60 s low, the rest of the window at the launch price
        assertApproxEqRel(oracle.twapOver(address(token), 900), (p0 * 840 + low * 60) / 900, 1e12);
        assertApproxEqRel(oracle.twapOver(address(token), 1800), (p0 * 1740 + low * 60) / 1800, 1e12);
        for (uint256 i; i < 12; i++) {
            vm.warp(vm.getBlockTimestamp() + 5 minutes);
            vm.roll(vm.getBlockNumber() + 1);
            handler.observe(address(token));
        }
        _buy(carol, 2 ether);
        uint256 p1 = oracle.spotPrice(address(token));
        vm.warp(vm.getBlockTimestamp() + 15 minutes);
        // the newest observation 15 minutes old is the one just before the buy: the 15-minute TWAP is all p1
        assertApproxEqRel(oracle.twapOver(address(token), 900), p1, 1e12);
        uint256 t30 = oracle.twapOver(address(token), 1800);
        assertApproxEqRel(t30, (low * 15 + p1 * 15) / 30, 1e12);
    }

    function test_blockStartPriceIsTheFirstTouchOfTheBlock() public {
        _create(100);
        _launch(0);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 3);
        uint256 before = oracle.spotPrice(address(token));
        _sell(alice, 20_000 ether);
        assertEq(oracle.blockStartPrice(address(token)), before);
        assertLt(oracle.spotPrice(address(token)), before);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(oracle.blockStartPrice(address(token)), oracle.spotPrice(address(token)));
    }

    // ------------------------------------------------------------ access
    function test_onlyPadRegistersLaunchesRequalifies() public {
        vm.expectRevert(FlywheelTaxHandler.OnlyLaunchpad.selector);
        handler.register(address(1), address(2), address(3));
        vm.expectRevert(FlywheelTaxHandler.OnlyLaunchpad.selector);
        handler.onLaunch(address(1), 0, address(0), 0);
        vm.expectRevert(FlywheelTaxHandler.OnlyLaunchpad.selector);
        handler.requalify(address(1), address(2));
        vm.prank(owner);
        vm.expectRevert(FlywheelTaxHandler.LaunchpadAlreadySet.selector);
        handler.setLaunchpad(address(9));
    }

    function test_unknownTokensAreIgnoredBySyncAndRefusedByNotify() public {
        handler.syncShares(address(0xBEEF), alice, bob);
        vm.prank(address(0xBEEF));
        vm.expectRevert(FlywheelTaxHandler.UnknownToken.selector);
        handler.notifyTax(address(0xBEEF), alice, bob, 1, 100);
    }

    function test_recentHighDecaysSlowly() public {
        _create(100);
        _launch(0);
        vm.warp(vm.getBlockTimestamp() + 120);
        vm.roll(vm.getBlockNumber() + 1);
        handler.observe(address(token));
        uint256 before = oracle.spotPrice(address(token));
        _sell(alice, 30_000 ether); // a dump in this block
        vm.roll(vm.getBlockNumber() + 1); // next block: its start is the dumped price
        handler.observe(address(token));
        assertLt(oracle.blockStartPrice(address(token)), before);
        assertEq(oracle.recentHigh(address(token)), before); // the pre-dump block start is still the recent high
        vm.warp(vm.getBlockTimestamp() + 120);
        vm.roll(vm.getBlockNumber() + 1);
        handler.observe(address(token));
        // two minutes on it has only decayed by 1% (0.5% a minute): a held dump does not shake it off quickly
        assertEq(oracle.recentHigh(address(token)), handler.decayedHigh(before, 120));
        assertApproxEqRel(oracle.recentHigh(address(token)), (before * 99) / 100, 1e12);
    }

    function test_aPumpInsideOneBlockDoesNotRaiseTheRecentHigh() public {
        _create(100);
        _launch(0);
        vm.warp(vm.getBlockTimestamp() + 120);
        vm.roll(vm.getBlockNumber() + 1);
        handler.observe(address(token));
        uint256 start = oracle.spotPrice(address(token));
        _buy(carol, 2 ether); // pump ...
        uint256 peak = oracle.spotPrice(address(token));
        _sell(carol, token.balanceOf(carol)); // ... and back, same block
        vm.roll(vm.getBlockNumber() + 1);
        handler.observe(address(token));
        // block-start prices only, and only once the next block starts there too: still the pre-pump start
        assertEq(oracle.recentHigh(address(token)), start);
        assertLt(oracle.recentHigh(address(token)), (peak * 9) / 10); // the in-block peak was never recorded
    }
}
