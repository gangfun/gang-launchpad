// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {DividendVault} from "../../src/launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {MigratorV2} from "../../src/launchpad-v2/MigratorV2.sol";
import {PoolCheck} from "../../src/launchpad-v2/PoolCheck.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {MockPairFactory, MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {FairMintPad} from "../../src/fair-mint/FairMintPad.sol";
import {FairToken, FairTokenDeployer} from "../../src/fair-mint/FairToken.sol";
import {HolderRewardHandler} from "../../src/fair-mint/HolderRewardHandler.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";

/// @dev Quote that burns 1% on every transfer.
contract FeeOnTransferQuote is ERC20("FoT", "FOT") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 burn = value / 100;
            super._update(from, address(0), burn);
            value -= burn;
        }
        super._update(from, to, value);
    }
}

/// @notice FairMintPad + FairToken + HolderRewardHandler on mocks. No broadcast.
contract FairMintTest is Test {
    QuoteRegistry internal registry;
    DividendVault internal vault;
    PlatformFeeBucket internal bucket;
    HolderRewardHandler internal handler;
    FairMintPad internal pad;
    MigratorV2 internal migrator;
    MockPairFactory internal factory;
    MockSPCXB internal wbnb;
    MockAgentId internal agents;

    address internal owner = makeAddr("owner");
    address internal feeVault = makeAddr("feeVault");
    address internal dev = makeAddr("dev");
    address internal stranger = makeAddr("stranger");
    address internal buyer = makeAddr("buyer");
    uint256 internal nextAgentId = 1;

    uint256 internal constant SHARE_PRICE = 15 ether / 10_000; // default raise 15 BNB
    uint256 internal constant TPS = 50_000 ether;

    function setUp() public {
        wbnb = new MockSPCXB();
        factory = new MockPairFactory();
        agents = new MockAgentId();
        registry = new QuoteRegistry(owner);
        vault = new DividendVault(owner);
        bucket = new PlatformFeeBucket(owner, feeVault);
        handler = new HolderRewardHandler(owner, address(vault), address(bucket));
        FairTokenDeployer deployer = new FairTokenDeployer();
        pad = new FairMintPad(
            owner,
            address(registry),
            address(vault),
            address(bucket),
            address(handler),
            address(deployer),
            address(wbnb),
            address(factory)
        );
        migrator = new MigratorV2(address(factory), address(pad));

        vm.startPrank(owner);
        vault.setLaunchpad(address(pad));
        vault.setOperator(address(handler), true);
        bucket.setLaunchpad(address(pad));
        bucket.setOperator(address(handler), true);
        pad.setMigrator(address(migrator));
        pad.setAgentGate(true, address(agents));
        handler.setPad(address(pad));
        handler.setKeeper(owner);
        vm.stopPrank();

        _fund(dev);
        _fund(buyer);
    }

    // ---------------------------------------------------------------- helpers
    function _fund(address who) internal {
        agents.mint(who, nextAgentId++);
        wbnb.mintUnlimited(who, 100 ether);
        vm.prank(who);
        wbnb.approve(address(pad), type(uint256).max);
    }

    function _minter(uint256 i) internal returns (address who) {
        who = address(uint160(0x100000 + i));
        if (agents.balanceOf(who) == 0) _fund(who);
    }

    function _cfg() internal pure returns (FairMintPad.MintConfig memory) {
        return FairMintPad.MintConfig({raiseBnb: 15 ether, capBps: 50, duration: 24 hours, holdBps: 5000});
    }

    function _create() internal returns (address token) {
        vm.prank(dev);
        token = pad.create("Fair", "FAIR", "ipfs://logo", address(0), address(0), _cfg(), 1);
    }

    /// @dev dev holds 1 share; minters 0..98 take 100 each (9,900); minter 99 takes the last 99.
    function _fill(address token) internal {
        for (uint256 i = 0; i < 100; i++) {
            address m = _minter(i);
            vm.prank(m);
            pad.mint(token, 100, 1);
        }
    }

    function _sale(address token)
        internal
        view
        returns (uint256 capShares, uint256 sold, bool launched, uint256 sharePrice, uint256 escrowedFee, address pair)
    {
        (,, uint16 cap,,, uint16 sold_, bool launched_,,, uint128 price, uint128 fee, address pair_,) = pad.sales(token);
        return (cap, sold_, launched_, price, fee, pair_);
    }

    function _sell(address token, address who, uint256 amount) internal {
        MockPair pair = MockPair(FairToken(token).pair());
        vm.prank(who);
        IERC20(token).transfer(address(pair), amount);
        (uint256 rT, uint256 rQ) = _reserves(token, pair);
        uint256 inAmt = IERC20(token).balanceOf(address(pair)) - rT;
        uint256 out = (inAmt * rQ) / (rT + inAmt);
        if (pair.token0() == token) pair.swap(0, out, who, "");
        else pair.swap(out, 0, who, "");
    }

    function _buy(address token, address who, uint256 quoteIn) internal {
        MockPair pair = MockPair(FairToken(token).pair());
        vm.prank(who);
        wbnb.transfer(address(pair), quoteIn);
        (uint256 rT, uint256 rQ) = _reserves(token, pair);
        uint256 out = (quoteIn * rT) / (rQ + quoteIn);
        if (pair.token0() == token) pair.swap(out, 0, who, "");
        else pair.swap(0, out, who, "");
    }

    function _reserves(address token, MockPair pair) internal view returns (uint256 rT, uint256 rQ) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (rT, rQ) = pair.token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    // ---------------------------------------------------------------- create
    function test_create_locksRulesAndDevMints() public {
        address t = _create();
        (uint256 cap, uint256 sold,, uint256 price,,) = _sale(t);
        assertEq(cap, 100, "0.5% = 100 shares");
        assertEq(sold, 1);
        assertEq(price, SHARE_PRICE);
        assertEq(IERC20(t).balanceOf(dev), TPS);
        assertEq(pad.baselineOf(t, dev), TPS);
        assertEq(vault.shares(t, dev), TPS);
        assertEq(uint8(pad.status(t)), uint8(FairMintPad.Status.Minting));
        assertEq(wbnb.balanceOf(address(pad)), SHARE_PRICE + SHARE_PRICE / 100);
        assertEq(vault.minimumShareBalance(), 10_000 ether);
    }

    function test_create_rejectsOutOfBounds() public {
        FairMintPad.MintConfig memory c = _cfg();
        c.raiseBnb = 4 ether;
        _expectBadConfig(c, 1, "raiseBnb must be 5-50 BNB");
        c = _cfg();
        c.raiseBnb = 51 ether;
        _expectBadConfig(c, 1, "raiseBnb must be 5-50 BNB");
        c = _cfg();
        c.capBps = 51;
        _expectBadConfig(c, 1, "capBps must be 10-50 (0.1%-0.5%)");
        c = _cfg();
        c.capBps = 9;
        _expectBadConfig(c, 1, "capBps must be 10-50 (0.1%-0.5%)");
        c = _cfg();
        c.duration = 73 hours;
        _expectBadConfig(c, 1, "duration must be 1-72 hours");
        c = _cfg();
        c.duration = 1 hours - 1;
        _expectBadConfig(c, 1, "duration must be 1-72 hours");
        c = _cfg();
        c.holdBps = 8001;
        _expectBadConfig(c, 1, "holdBps must be 3000-8000");
        c = _cfg();
        c.holdBps = 2999;
        _expectBadConfig(c, 1, "holdBps must be 3000-8000");
        _expectBadConfig(_cfg(), 0, "devShares must be 1..cap");
        _expectBadConfig(_cfg(), 101, "devShares must be 1..cap");
    }

    function _expectBadConfig(FairMintPad.MintConfig memory c, uint256 devShares, string memory reason) internal {
        vm.prank(dev);
        vm.expectRevert(abi.encodeWithSelector(FairMintPad.BadConfig.selector, reason));
        pad.create("X", "X", "", address(0), address(0), c, devShares);
    }

    function test_create_rejectsNonAgent() public {
        vm.prank(stranger);
        vm.expectRevert(FairMintPad.NotAgent.selector);
        pad.create("X", "X", "", address(0), address(0), _cfg(), 1);
    }

    function test_create_rejectsHighVaultFloor() public {
        vm.prank(owner);
        vault.setMinimumShareBalance(1_000_000 ether);
        vm.prank(dev);
        vm.expectRevert(FairMintPad.VaultFloorTooHigh.selector);
        pad.create("X", "X", "", address(0), address(0), _cfg(), 1);
    }

    function test_create_registryQuoteScalesWithRaise() public {
        MockSPCXB usd = new MockSPCXB();
        vm.prank(owner);
        registry.setQuote(address(usd), true, 9_000 ether); // 15 BNB ≈ 9,000 USD
        (uint256 raiseQuote, uint256 price) = pad.previewCreate(address(usd), address(0), 30 ether);
        assertEq(raiseQuote, 18_000 ether);
        assertEq(price, 1.8 ether);
    }

    /// @dev Non-registry quote priced by a V2 pair against WBNB: 300 Q : 150 WBNB → 1 BNB = 2 Q.
    function test_create_refPoolAgainstWbnb() public {
        MockSPCXB q = new MockSPCXB();
        address ref = _seedPair(address(q), address(wbnb), 300 ether, 150 ether);
        (uint256 raiseQuote, uint256 price) = pad.previewCreate(address(q), ref, 15 ether);
        assertEq(raiseQuote, 30 ether);
        assertEq(price, 30 ether / 10_000);

        q.mintUnlimited(dev, 1 ether);
        vm.startPrank(dev);
        q.approve(address(pad), type(uint256).max);
        address t = pad.create("Q", "Q", "", address(q), ref, _cfg(), 1);
        vm.stopPrank();
        (,,, uint256 sharePrice,,) = _sale(t);
        assertEq(sharePrice, price);
    }

    /// @dev Quote priced against USDT, bridged to BNB: 20,000 Q : 10,000 USDT, 600 USDT : 1 WBNB → 1 BNB = 1,200 Q.
    function test_create_refPoolViaBridge() public {
        MockSPCXB q = new MockSPCXB();
        MockSPCXB usdt = new MockSPCXB();
        address ref = _seedPair(address(q), address(usdt), 20_000 ether, 10_000 ether);
        address bridge = _seedPair(address(usdt), address(wbnb), 6_000 ether, 10 ether);

        vm.expectRevert(FairMintPad.NoBridgePool.selector);
        pad.previewCreate(address(q), ref, 15 ether);

        vm.prank(owner);
        pad.setBridgePool(address(usdt), bridge);
        (uint256 raiseQuote,) = pad.previewCreate(address(q), ref, 15 ether);
        assertEq(raiseQuote, 18_000 ether);
    }

    function test_create_refPoolRequiredAndDepthFloor() public {
        MockSPCXB q = new MockSPCXB();
        vm.expectRevert(FairMintPad.RefPoolRequired.selector);
        pad.previewCreate(address(q), address(0), 15 ether);

        address thin = _seedPair(address(q), address(wbnb), 2 ether, 0.5 ether); // < 1 BNB of WBNB
        vm.expectRevert(PoolCheck.ThinReferencePool.selector);
        pad.previewCreate(address(q), thin, 15 ether);
    }

    function _seedPair(address a, address b, uint256 amtA, uint256 amtB) internal returns (address pair) {
        pair = factory.createPair(a, b);
        MockSPCXB(a).mintUnlimited(pair, amtA);
        MockSPCXB(b).mintUnlimited(pair, amtB);
        MockPair(pair).mint(address(0xdead));
    }

    // ---------------------------------------------------------------- mint
    function test_mint_capsPerAddress() public {
        address t = _create();
        address m = _minter(0);
        vm.prank(m);
        assertEq(pad.mint(t, 500, 1), 100, "truncated to cap");
        vm.prank(m);
        vm.expectRevert(FairMintPad.WalletCapReached.selector);
        pad.mint(t, 1, 1);
    }

    function test_mint_lastFillTruncatesAndChargesOnlyAccepted() public {
        address t = _create();
        for (uint256 i = 0; i < 99; i++) {
            vm.prank(_minter(i));
            pad.mint(t, 100, 1);
        }
        address last = _minter(99);
        vm.prank(last);
        vm.expectRevert(FairMintPad.Slippage.selector);
        pad.mint(t, 100, 100); // only 99 left

        uint256 before = wbnb.balanceOf(last);
        vm.prank(last);
        uint256 gasStart = gasleft();
        uint256 accepted = pad.mint(t, 100, 1);
        emit log_named_uint("gas: filling mint incl. launch", gasStart - gasleft());
        assertEq(accepted, 99);
        uint256 cost = 99 * SHARE_PRICE;
        assertEq(before - wbnb.balanceOf(last), cost + cost / 100);
        assertEq(uint8(pad.status(t)), uint8(FairMintPad.Status.Launched));
    }

    function test_mint_rejectsNonAgentAndAfterDeadline() public {
        address t = _create();
        vm.prank(stranger);
        vm.expectRevert(FairMintPad.NotAgent.selector);
        pad.mint(t, 1, 1);

        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(_minter(0));
        vm.expectRevert(FairMintPad.NotMinting.selector);
        pad.mint(t, 1, 1);
    }

    function test_mint_rejectsFeeOnTransferQuote() public {
        FeeOnTransferQuote fot = new FeeOnTransferQuote();
        vm.prank(owner);
        registry.setQuote(address(fot), true, 15 ether);
        fot.mint(dev, 10 ether);
        vm.startPrank(dev);
        fot.approve(address(pad), type(uint256).max);
        vm.expectRevert(FairMintPad.FeeOnTransferQuote.selector);
        pad.create("X", "X", "", address(fot), address(0), _cfg(), 1);
        vm.stopPrank();
    }

    function test_tokensLockedBeforeLaunch() public {
        address t = _create();
        vm.prank(dev);
        vm.expectRevert(FairToken.TransfersLocked.selector);
        IERC20(t).transfer(stranger, 1);
    }

    // ---------------------------------------------------------------- withdraw
    function test_withdraw_paysPrincipalMinusFeeAndKeepsMintFee() public {
        address t = _create();
        address m = _minter(0);
        vm.prank(m);
        pad.mint(t, 100, 1);
        uint256 bucketBefore = bucket.accruedQuote(address(wbnb));

        uint256 before = wbnb.balanceOf(m);
        vm.prank(m);
        uint256 out = pad.withdraw(t, 40);
        uint256 principal = 40 * SHARE_PRICE;
        assertEq(out, principal - principal / 100);
        assertEq(wbnb.balanceOf(m) - before, out);

        uint256 mintFee = (100 * SHARE_PRICE / 100) * 40 / 100;
        assertEq(bucket.accruedQuote(address(wbnb)) - bucketBefore, mintFee + principal / 100, "both 1% legs");
        assertEq(IERC20(t).balanceOf(m), 60 * TPS, "tokens reclaimed");
        assertEq(vault.shares(t, m), 60 * TPS);
        (, uint256 sold,,,,) = _sale(t);
        assertEq(sold, 61);

        vm.prank(m);
        assertEq(pad.mint(t, 100, 1), 40, "cap room freed");
    }

    function test_withdraw_blockedAfterDeadline() public {
        address t = _create();
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(dev);
        vm.expectRevert(FairMintPad.NotMinting.selector);
        pad.withdraw(t, 1);
    }

    function test_accounting_padHoldsPrincipalPlusEscrow() public {
        address t = _create();
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(_minter(i));
            pad.mint(t, 37 + i, 1);
        }
        vm.prank(_minter(2));
        pad.withdraw(t, 13);
        vm.prank(_minter(4));
        pad.withdraw(t, 41);
        (, uint256 sold,, uint256 price, uint256 escrow,) = _sale(t);
        assertEq(wbnb.balanceOf(address(pad)), sold * price + escrow);
    }

    // ---------------------------------------------------------------- failure
    function test_refund_fullAfterDeadline() public {
        address t = _create();
        address m = _minter(0);
        uint256 start = wbnb.balanceOf(m);
        vm.prank(m);
        pad.mint(t, 70, 1);

        vm.prank(m);
        vm.expectRevert(FairMintPad.NotFailed.selector);
        pad.refund(t);

        vm.warp(block.timestamp + 24 hours + 1);
        assertEq(uint8(pad.status(t)), uint8(FairMintPad.Status.Failed));
        vm.prank(m);
        pad.refund(t);
        assertEq(wbnb.balanceOf(m), start, "principal + mint fee back");
        assertEq(IERC20(t).balanceOf(m), 0);
        assertEq(vault.shares(t, m), 0);

        vm.prank(m);
        vm.expectRevert(FairMintPad.NothingToRefund.selector);
        pad.refund(t);

        vm.prank(dev);
        pad.refund(t);
        assertEq(wbnb.balanceOf(address(pad)), 0, "pad empty after all refunds");
    }

    // ---------------------------------------------------------------- launch
    function test_launch_openingPriceEqualsMintPrice() public {
        address t = _create();
        _fill(t);
        (,, bool launched,, uint256 escrow, address pair) = _sale(t);
        assertTrue(launched);
        assertEq(escrow, 0);
        assertFalse(FairToken(t).locked());
        assertEq(FairToken(t).pair(), pair);
        assertEq(FairToken(t).taxHandler(), address(handler));

        (uint256 rT, uint256 rQ) = _reserves(t, MockPair(pair));
        assertEq(rT, 500_000_000 ether);
        assertEq(rQ, 15 ether);
        assertEq(rQ * TPS / rT, SHARE_PRICE, "pool price = mint price");

        assertEq(IERC20(t).balanceOf(address(pad)), 0);
        assertEq(wbnb.balanceOf(address(pad)), 0);
        assertEq(bucket.accruedQuote(address(wbnb)), 15 ether / 100, "1% of the raise");
    }

    /// @dev Someone creates the pair early and donates quote: launch still works, the donation just raises the price.
    function test_launch_withPreCreatedPair() public {
        address t = _create();
        address early = factory.createPair(t, address(wbnb));
        wbnb.mintUnlimited(early, 1 ether);

        vm.prank(dev);
        vm.expectRevert(FairToken.TransfersLocked.selector);
        IERC20(t).transfer(early, TPS); // no way to seed the token side

        _fill(t);
        (,,,,, address pair) = _sale(t);
        assertEq(pair, early);
        (uint256 rT, uint256 rQ) = _reserves(t, MockPair(pair));
        assertEq(rT, 500_000_000 ether);
        assertEq(rQ, 16 ether, "15 BNB raise + 1 BNB donation");
    }

    function test_reclaimDeadAfterLaunch() public {
        address t = _create();
        _fill(t);
        vm.prank(address(pad));
        vm.expectRevert(FairToken.NotLocked.selector);
        FairToken(t).reclaim(dev, 1);
        vm.prank(dev);
        vm.expectRevert(FairMintPad.NotMinting.selector);
        pad.withdraw(t, 1);
        vm.prank(dev);
        vm.expectRevert(FairMintPad.NotFailed.selector);
        pad.refund(t);
    }

    // ---------------------------------------------------------------- rewards
    function test_rewards_weightFollowsBalanceAndLineIsFinal() public {
        address t = _create();
        _fill(t);
        address m = _minter(0);
        uint256 base = 100 * TPS;

        _sell(t, m, base * 30 / 100);
        assertEq(vault.shares(t, m), base * 70 / 100, "share = current balance");

        _sell(t, m, base * 21 / 100); // 49% left < 50%
        assertTrue(handler.isOut(t, m));
        assertEq(vault.shares(t, m), 0);

        _buy(t, m, 5 ether);
        assertGt(IERC20(t).balanceOf(m), base);
        assertEq(vault.shares(t, m), 0, "buying back does not restore");
    }

    function test_rewards_onlyPreLaunchHoldersAndCappedAtBaseline() public {
        address t = _create();
        _fill(t);
        _buy(t, buyer, 1 ether);
        assertGt(IERC20(t).balanceOf(buyer), 0);
        assertEq(vault.shares(t, buyer), 0, "post-launch buyer");
        assertEq(vault.shares(t, FairToken(t).pair()), 0);

        address a = _minter(1);
        address b = _minter(2);
        vm.prank(b);
        IERC20(t).transfer(a, 100 * TPS);
        assertEq(vault.shares(t, a), 100 * TPS, "capped at baseline");
        assertTrue(handler.isOut(t, b));
    }

    function test_rewards_processSplitsHalfToEligibleHolders() public {
        address t = _create();
        _fill(t);
        _buy(t, buyer, 3 ether);
        _sell(t, _minter(0), 20 * TPS);
        uint256 taxTokens = handler.accruedTax(t);
        assertGt(taxTokens, 0);

        uint256 bucketBefore = bucket.accruedQuote(address(wbnb));
        vm.prank(owner);
        uint256 quoteOut = handler.process(t, 1);
        uint256 toHolders = quoteOut / 2;
        assertEq(wbnb.balanceOf(address(vault)), toHolders);
        assertEq(bucket.accruedQuote(address(wbnb)) - bucketBefore, quoteOut - toHolders);

        // minter 5 still holds its full baseline: 100 of the 10,000 baseline shares minus minter 0's 20.
        uint256 expected = toHolders * (100 * TPS) / vault.totalShares(t);
        assertApproxEqAbs(vault.pending(t, _minter(5)), expected, vault.totalShares(t) / 1e18 + 1);
        vm.prank(_minter(5));
        vault.claim(t);
    }

    function test_rewards_noEligibleHolderSendsAllToPlatform() public {
        address t = _create();
        // every pre-launch holder moves its tokens away → all out
        _fill(t);
        for (uint256 i = 0; i < 100; i++) {
            address m = _minter(i);
            uint256 bal = IERC20(t).balanceOf(m);
            vm.prank(m);
            IERC20(t).transfer(buyer, bal);
        }
        vm.prank(dev);
        IERC20(t).transfer(buyer, TPS);
        assertEq(vault.totalShares(t), 0);

        _sell(t, buyer, 1_000_000 ether);
        uint256 bucketBefore = bucket.accruedQuote(address(wbnb));
        vm.prank(owner);
        uint256 quoteOut = handler.process(t, 1);
        assertEq(bucket.accruedQuote(address(wbnb)) - bucketBefore, quoteOut);
        assertEq(wbnb.balanceOf(address(vault)), 0);
    }

    function test_tax_onlyOnPairTrades() public {
        address t = _create();
        _fill(t);
        address m = _minter(0);
        address other = _minter(1);
        vm.prank(m);
        IERC20(t).transfer(other, 10 * TPS);
        assertEq(handler.accruedTax(t), 0, "wallet to wallet untaxed");
        _sell(t, m, 10 * TPS);
        assertEq(handler.accruedTax(t), 10 * TPS / 100);
    }

    // ---------------------------------------------------------------- admin can't change a live sale
    function test_ownerGateChangeOnlyAffectsNewSales() public {
        address t = _create();
        vm.prank(owner);
        pad.setAgentGate(false, address(0));
        wbnb.mintUnlimited(stranger, 1 ether);
        vm.startPrank(stranger);
        wbnb.approve(address(pad), type(uint256).max);
        vm.expectRevert(FairMintPad.NotAgent.selector);
        pad.mint(t, 1, 1);
        address t2 = pad.create("Open", "OPEN", "", address(0), address(0), _cfg(), 1);
        vm.stopPrank();
        assertEq(IERC20(t2).balanceOf(stranger), TPS);
    }

    function test_vaultFailureDoesNotFreezeTrading() public {
        address t = _create();
        _fill(t);
        vm.prank(owner);
        vault.setOperator(address(handler), false);
        address m = _minter(0);
        _sell(t, m, 60 * TPS);
        assertEq(IERC20(t).balanceOf(m), 40 * TPS);
        assertTrue(handler.isOut(t, m));
        assertEq(vault.shares(t, m), 100 * TPS, "zeroing failed while the vault refused");

        vm.prank(owner);
        vault.setOperator(address(handler), true);
        handler.syncShares(t, m, address(0));
        assertEq(vault.shares(t, m), 0, "retried once the vault accepts again");
    }

    function test_handlerPadIsOneShot() public {
        vm.prank(owner);
        vm.expectRevert(HolderRewardHandler.PadAlreadySet.selector);
        handler.setPad(stranger);
    }
}
