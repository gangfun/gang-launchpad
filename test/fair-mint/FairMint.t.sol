// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {PoolCheck} from "../../src/launchpad-v2/PoolCheck.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {MockPairFactory, MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {FairMintPad} from "../../src/fair-mint/FairMintPad.sol";
import {FairToken} from "../../src/fair-mint/FairToken.sol";
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
    SharedDividendVault internal vault;
    PlatformFeeBucket internal bucket;
    HolderRewardHandler internal handler;
    FairMintPad internal pad;
    SharedMigrator internal migrator;
    TokenDeployer internal tokenDeployer;
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
        vault = new SharedDividendVault(owner);
        bucket = new PlatformFeeBucket(owner, feeVault);
        handler = new HolderRewardHandler(owner, address(vault), address(bucket), address(0));
        tokenDeployer = new TokenDeployer(owner);
        pad = new FairMintPad(
            owner,
            address(registry),
            address(vault),
            address(bucket),
            address(handler),
            address(tokenDeployer),
            address(wbnb),
            address(factory)
        );
        migrator = new SharedMigrator(owner, address(factory));

        vm.startPrank(owner);
        vault.setLaunchpad(address(pad), true);
        vault.setOperator(address(handler), address(pad));
        migrator.addLaunchpad(address(pad));
        tokenDeployer.setLaunchpad(address(pad), true);
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
        return FairMintPad.MintConfig({raiseBnb: 15 ether, capBps: 50, holdBps: 5000, mintFeeBps: 100, exitFeeBps: 100});
    }

    function _create() internal returns (address token) {
        vm.prank(dev);
        token = pad.create("Fair", "FAIR", "ipfs://logo", "ipfs://meta.json", address(0), address(0), _cfg(), 1);
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
        returns (uint256 capShares, uint256 sold, bool launched, uint256 sharePrice, uint256 lastMintAt, address pair)
    {
        (, uint64 last, uint16 cap,,, uint16 sold_, bool launched_,,,, uint128 price, address pair_,,) =
            pad.sales(token);
        return (cap, sold_, launched_, price, last, pair_);
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
        assertEq(wbnb.balanceOf(address(pad)), SHARE_PRICE, "pad keeps only principal");
        assertEq(bucket.accruedQuote(address(wbnb)), SHARE_PRICE / 100, "mint fee to the platform at once");
        (,,,, uint256 last,) = _sale(t);
        assertEq(last, block.timestamp, "the creator's mint counts as activity");
        assertEq(vault.minimumShareBalanceOf(address(pad)), 10_000 ether);
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
        _expectBadConfig(c, 1, "capBps must be 25-50 (0.25%-0.5%)");
        c = _cfg();
        c.capBps = 24;
        _expectBadConfig(c, 1, "capBps must be 25-50 (0.25%-0.5%)");
        c = _cfg();
        c.holdBps = 8001;
        _expectBadConfig(c, 1, "holdBps must be 3000-8000");
        c = _cfg();
        c.holdBps = 2999;
        _expectBadConfig(c, 1, "holdBps must be 3000-8000");
        c = _cfg();
        c.mintFeeBps = 99;
        _expectBadConfig(c, 1, "mintFeeBps must be 100-300 (1%-3%)");
        c = _cfg();
        c.mintFeeBps = 301;
        _expectBadConfig(c, 1, "mintFeeBps must be 100-300 (1%-3%)");
        c = _cfg();
        c.exitFeeBps = 99;
        _expectBadConfig(c, 1, "exitFeeBps must be 100-200 (1%-2%)");
        c = _cfg();
        c.exitFeeBps = 201;
        _expectBadConfig(c, 1, "exitFeeBps must be 100-200 (1%-2%)");
        _expectBadConfig(_cfg(), 0, "devShares must be 1..cap");
        _expectBadConfig(_cfg(), 101, "devShares must be 1..cap");
    }

    function _expectBadConfig(FairMintPad.MintConfig memory c, uint256 devShares, string memory reason) internal {
        vm.prank(dev);
        vm.expectRevert(abi.encodeWithSelector(FairMintPad.BadConfig.selector, reason));
        pad.create("X", "X", "", "", address(0), address(0), c, devShares);
    }

    function test_create_rejectsNonAgent() public {
        vm.prank(stranger);
        vm.expectRevert(FairMintPad.NotAgent.selector);
        pad.create("X", "X", "", "", address(0), address(0), _cfg(), 1);
    }

    function test_create_rejectsHighVaultFloor() public {
        vm.prank(owner);
        vault.setMinimumShareBalance(address(pad), 1_000_000 ether);
        vm.prank(dev);
        vm.expectRevert(FairMintPad.VaultFloorTooHigh.selector);
        pad.create("X", "X", "", "", address(0), address(0), _cfg(), 1);
    }

    function test_create_registryQuoteScalesWithRaise() public {
        MockSPCXB usd = new MockSPCXB();
        vm.prank(owner);
        registry.setQuote(address(usd), true, 9_000 ether); // 15 BNB ≈ 9,000 USD
        (uint256 raiseQuote, uint256 price) = pad.previewCreate(address(usd), address(0), 30 ether);
        assertEq(raiseQuote, 18_000 ether);
        assertEq(price, 1.8 ether);
    }

    /// @dev A listed quote without a fixed rate would be priced by its creator-picked reference pool at spot — one flash
    ///      swap in the create tx moves that by orders of magnitude (internal audit round 2) — so create refuses it.
    ///      previewCreate still shows what the pool says (300 Q : 150 WBNB → 1 BNB = 2 Q) for ops picking a rate.
    /// @dev Any 18-decimal quote, priced like LaunchpadV2: the creator's reference pool (300 Q : 150 WBNB → 15 BNB =
    ///      30 Q), unless QuoteRegistry holds a fixed rate, which wins over the pool.
    function test_create_refPoolAgainstWbnb() public {
        MockSPCXB q = new MockSPCXB(); // not in QuoteRegistry
        address ref = _seedPair(address(q), address(wbnb), 300 ether, 150 ether);
        (uint256 raiseQuote, uint256 price) = pad.previewCreate(address(q), ref, 15 ether);
        assertEq(raiseQuote, 30 ether);
        assertEq(price, 30 ether / 10_000);

        q.mintUnlimited(dev, 1 ether);
        vm.startPrank(dev);
        q.approve(address(pad), type(uint256).max);
        address t = pad.create("Q", "Q", "", "", address(q), ref, _cfg(), 1);
        vm.stopPrank();
        (,,, uint256 sharePrice,,) = _sale(t);
        assertEq(sharePrice, price, "unlisted quote priced from its pool");

        // a fixed rate (60 Q per 15 BNB) wins, whatever the pool says, and needs no pool
        vm.prank(owner);
        registry.setQuote(address(q), true, 60 ether);
        (raiseQuote,) = pad.previewCreate(address(q), ref, 15 ether);
        assertEq(raiseQuote, 60 ether);
        vm.prank(dev);
        t = pad.create("Q2", "Q2", "", "", address(q), address(0), _cfg(), 1);
        (,,, sharePrice,,) = _sale(t);
        assertEq(sharePrice, 60 ether / 10_000);
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

    /// @dev No deadline: a sale a year old still takes mints.
    function test_mint_rejectsNonAgent_noDeadline() public {
        address t = _create();
        vm.prank(stranger);
        vm.expectRevert(FairMintPad.NotAgent.selector);
        pad.mint(t, 1, 1);

        vm.warp(block.timestamp + 365 days);
        vm.prank(_minter(0));
        assertEq(pad.mint(t, 1, 1), 1);
        assertEq(uint8(pad.status(t)), uint8(FairMintPad.Status.Minting));
    }

    function test_mint_rejectsFeeOnTransferQuote() public {
        FeeOnTransferQuote fot = new FeeOnTransferQuote();
        vm.prank(owner);
        registry.setQuote(address(fot), true, 15 ether);
        fot.mint(dev, 10 ether);
        vm.startPrank(dev);
        fot.approve(address(pad), type(uint256).max);
        vm.expectRevert(FairMintPad.FeeOnTransferQuote.selector);
        pad.create("X", "X", "", "", address(fot), address(0), _cfg(), 1);
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
        (uint256 previewOut, uint256 previewFee) = pad.previewWithdraw(t, m, 40);
        vm.prank(m);
        uint256 out = pad.withdraw(t, 40, 0);
        uint256 principal = 40 * SHARE_PRICE;
        assertEq(out, principal - principal / 100);
        assertEq(previewOut, out);
        assertEq(previewFee, principal / 100);
        assertEq(wbnb.balanceOf(m) - before, out);

        // the mint fee went to the platform at mint; the withdraw adds only the exit fee
        assertEq(bucket.accruedQuote(address(wbnb)) - bucketBefore, principal / 100, "exit fee only");
        assertEq(IERC20(t).balanceOf(m), 60 * TPS, "tokens reclaimed");
        assertEq(vault.shares(t, m), 60 * TPS);
        (, uint256 sold,,,,) = _sale(t);
        assertEq(sold, 61);

        vm.prank(m);
        assertEq(pad.mint(t, 100, 1), 40, "cap room freed");
    }

    /// @dev mint 1% / withdraw 2%: each leg uses its own rate; both go to the platform.
    function test_fees_separateMintAndExitRates() public {
        FairMintPad.MintConfig memory c = _cfg();
        c.exitFeeBps = 200;
        vm.prank(dev);
        address t = pad.create("Fees", "FEE", "", "", address(0), address(0), c, 1);
        address m = _minter(0);
        uint256 start = wbnb.balanceOf(m);
        vm.prank(m);
        pad.mint(t, 50, 1);
        uint256 cost = 50 * SHARE_PRICE;
        assertEq(start - wbnb.balanceOf(m), cost + cost / 100, "mint: +1%");
        (,,,,,,, uint16 mintFee, uint16 exitFee,,,,,) = pad.sales(t);
        assertEq(mintFee, 100);
        assertEq(exitFee, 200);

        uint256 bucketBefore = bucket.accruedQuote(address(wbnb));
        uint256 before = wbnb.balanceOf(m);
        vm.prank(m);
        uint256 out = pad.withdraw(t, 20, 0);
        uint256 principal = 20 * SHARE_PRICE;
        assertEq(out, principal - (principal * 200) / 10_000, "withdraw: -2%");
        assertEq(wbnb.balanceOf(m) - before, out);
        assertEq(bucket.accruedQuote(address(wbnb)) - bucketBefore, (principal * 200) / 10_000, "exit fee only");
    }

    /// @dev The mint fee (up to 3%) goes to the platform at mint; there is no refund to escrow it for.
    function test_fees_mintFeeToPlatformAtOnce() public {
        FairMintPad.MintConfig memory c = _cfg();
        c.mintFeeBps = 300;
        vm.prank(dev);
        address t = pad.create("Fees", "FEE", "", "", address(0), address(0), c, 1);
        address m = _minter(0);
        uint256 start = wbnb.balanceOf(m);
        uint256 bucketBefore = bucket.accruedQuote(address(wbnb));
        vm.prank(m);
        pad.mint(t, 40, 1);
        assertEq(start - wbnb.balanceOf(m), 40 * SHARE_PRICE * 103 / 100);
        assertEq(
            bucket.accruedQuote(address(wbnb)) - bucketBefore, 40 * SHARE_PRICE * 3 / 100, "3% to the platform now"
        );
        (uint256 accepted,, uint256 fee) = pad.previewMint(t, _minter(1), 10);
        assertEq(accepted, 10);
        assertEq(fee, 10 * SHARE_PRICE * 3 / 100, "preview uses the sale's rate");
    }

    /// @dev No mint for 7 days: withdraw pays the full principal (only the mint fee is lost); a new mint ends that.
    function test_withdraw_exitFeeWaivedWhenStale() public {
        FairMintPad.MintConfig memory c = _cfg();
        c.exitFeeBps = 200;
        vm.prank(dev);
        address t = pad.create("Stale", "STL", "", "", address(0), address(0), c, 1);
        address m = _minter(0);
        vm.prank(m);
        pad.mint(t, 50, 1);
        assertEq(pad.exitFeeBpsOf(t), 200);

        vm.warp(block.timestamp + 7 days - 1);
        assertEq(pad.exitFeeBpsOf(t), 200, "not yet stale");
        vm.warp(block.timestamp + 1);
        assertEq(pad.exitFeeBpsOf(t), 0, "stale after 7 days without a mint");
        (uint256 previewOut, uint256 previewFee) = pad.previewWithdraw(t, m, 20);
        assertEq(previewFee, 0);
        uint256 bucketBefore = bucket.accruedQuote(address(wbnb));
        vm.prank(m);
        uint256 out = pad.withdraw(t, 20, 0);
        assertEq(out, 20 * SHARE_PRICE, "full principal back");
        assertEq(previewOut, out);
        assertEq(bucket.accruedQuote(address(wbnb)), bucketBefore, "no exit fee");

        // a withdraw is not progress, nor is a re-mint that only wins back withdrawn shares; reaching 10 above the
        // last restart (51 sold) is, and the exit fee is back
        vm.prank(_minter(1));
        pad.mint(t, 29, 1); // sold 31 → 60
        assertEq(pad.exitFeeBpsOf(t), 0, "below markSold + STALE_STEP: still stale");
        vm.prank(_minter(2));
        pad.mint(t, 1, 1); // 61
        assertEq(pad.exitFeeBpsOf(t), 200);
        vm.prank(m);
        assertEq(pad.withdraw(t, 10, 0), 10 * SHARE_PRICE * 98 / 100);
    }

    function test_withdraw_previewZeroWhenItWouldRevert() public {
        address t = _create();
        (uint256 out, uint256 fee) = pad.previewWithdraw(t, _minter(0), 1);
        assertEq(out + fee, 0, "holds nothing");
        (out, fee) = pad.previewWithdraw(t, dev, 2);
        assertEq(out + fee, 0, "more than held");
    }

    function test_accounting_padHoldsPrincipal() public {
        address t = _create();
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(_minter(i));
            pad.mint(t, 37 + i, 1);
        }
        vm.prank(_minter(2));
        pad.withdraw(t, 13, 0);
        vm.prank(_minter(4));
        pad.withdraw(t, 41, 0);
        (, uint256 sold,, uint256 price,,) = _sale(t);
        assertEq(wbnb.balanceOf(address(pad)), sold * price, "pad holds exactly the principal of the shares out");
    }

    // ---------------------------------------------------------------- no deadline
    /// @dev A sale that sits for a year with sell-backs along the way still fills and launches.
    function test_noDeadline_saleFillsWhenever() public {
        address t = _create();
        vm.prank(_minter(0));
        pad.mint(t, 100, 1);
        vm.warp(block.timestamp + 200 days);
        vm.prank(_minter(0));
        pad.withdraw(t, 100, 0); // stale: full principal back
        vm.warp(block.timestamp + 165 days);
        _fill(t);
        (,, bool launched,,,) = _sale(t);
        assertTrue(launched);
        assertEq(uint8(pad.status(t)), uint8(FairMintPad.Status.Launched));
    }

    // ---------------------------------------------------------------- launch
    function test_launch_openingPriceEqualsMintPrice() public {
        address t = _create();
        _fill(t);
        (,, bool launched,,, address pair) = _sale(t);
        assertTrue(launched);
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
        pad.withdraw(t, 1, 0);
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
        uint256 sharesAtTax = vault.totalShares(t); // every baseline share is held at both taxes below
        _buy(t, buyer, 3 ether);
        // minter 0's sell first sells the buy tax (swap-back); audit 5 C-F7: its share is synced down before its own
        // sell's tax is credited, so that tax goes over sharesAtTax - 20 shares
        _sell(t, _minter(0), 20 * TPS);
        uint256 taxTokens = handler.accruedTax(t);
        assertGt(taxTokens, 0);
        assertGt(wbnb.balanceOf(address(vault)), 0, "the buy tax's holder half is already in quote");

        uint256 vaultBefore = wbnb.balanceOf(address(vault));
        uint256 bucketBefore = bucket.accruedQuote(address(wbnb));
        vm.roll(vm.getBlockNumber() + 1); // the sell moved the price below this block's reference
        vm.prank(owner);
        uint256 quoteOut = handler.process(t, type(uint256).max, 1);
        uint256 toHolders = wbnb.balanceOf(address(vault)) - vaultBefore;
        assertApproxEqAbs(toHolders, quoteOut / 2, 1, "half the chunk to holders");
        assertEq(bucket.accruedQuote(address(wbnb)) - bucketBefore, quoteOut - toHolders);
        assertEq(vault.unsoldUnits(t), 0);

        // minter 5 held 100 shares when both taxes were paid: over 10,000 shares for the buy tax, 9,980 for the sell's
        uint256 inVault = wbnb.balanceOf(address(vault));
        uint256 p5 = vault.pending(t, _minter(5));
        assertGe(p5 + 1e6, (inVault * (100 * TPS)) / sharesAtTax);
        assertLe(p5, (inVault * (100 * TPS)) / (sharesAtTax - 20 * TPS));
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
        uint256 quoteOut = handler.process(t, type(uint256).max, 1);
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
        address t2 = pad.create("Open", "OPEN", "", "", address(0), address(0), _cfg(), 1);
        vm.stopPrank();
        assertEq(IERC20(t2).balanceOf(stranger), TPS);
    }

    function test_vaultFailureDoesNotFreezeTrading() public {
        address t = _create();
        _fill(t);
        // the vault refusing every operator write (an operator can no longer be unbound: flow review F4a)
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(SharedDividendVault.setShare.selector), "refused");
        vm.mockCallRevert(
            address(vault), abi.encodeWithSelector(SharedDividendVault.accrueDividendUnits.selector), "refused"
        );
        vm.mockCallRevert(
            address(vault), abi.encodeWithSelector(SharedDividendVault.convertDividend.selector), "refused"
        );
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(SharedDividendVault.depositReward.selector), "refused");
        address m = _minter(0);
        _sell(t, m, 60 * TPS);
        assertEq(IERC20(t).balanceOf(m), 40 * TPS);
        assertTrue(handler.isOut(t, m));
        assertEq(vault.shares(t, m), 100 * TPS, "zeroing failed while the vault refused");

        vm.clearMockedCalls();
        handler.syncShares(t, m, address(0));
        assertEq(vault.shares(t, m), 0, "retried once the vault accepts again");
    }

    /// @dev Audit G-01 (V2 PostGradTaxHandler skips excluded users, so their old share keeps earning): here the sync
    ///      writes the share anyway and the vault zeroes excluded users, so one sync (a transfer or a permissionless
    ///      `syncShares` call) stops further accrual. Rewards earned before the exclusion stay claimable.
    function test_auditG01_excludedHolderStopsEarningAfterSync() public {
        address t = _create();
        _fill(t);
        address m = _minter(3);
        _buy(t, buyer, 2 ether);
        vm.prank(owner);
        handler.process(t, type(uint256).max, 1);
        uint256 earned = vault.pending(t, m);
        assertGt(earned, 0);

        vm.etch(m, hex"00"); // audit 5 C-F5: only a contract can be excluded (say m is a locker)
        vm.prank(owner);
        vault.setExcluded(m, true);
        handler.syncShares(t, m, address(0));
        assertEq(vault.shares(t, m), 0, "zeroed although never out");

        _buy(t, buyer, 2 ether);
        vm.prank(owner);
        handler.process(t, type(uint256).max, 1);
        assertEq(vault.pending(t, m), earned, "no accrual after exclusion");

        _sell(t, m, 1 * TPS); // ordinary transfers keep it at 0
        assertEq(vault.shares(t, m), 0);
    }

    /// @dev Audit G-02 (deposit with totalShares == 0 is stuck forever): the handler never deposits then — the
    ///      holder half goes to the platform. Covered end to end in test_rewards_noEligibleHolderSendsAllToPlatform;
    ///      this pins the early-launch case where a holder half exists before anyone sells.
    function test_auditG02_neverDepositsIntoEmptyVault() public {
        address t = _create();
        _fill(t);
        for (uint256 i = 0; i < 100; i++) {
            address m = _minter(i);
            vm.etch(m, hex"00"); // only contracts can be excluded (audit 5 C-F5)
            vm.prank(owner);
            vault.setExcluded(m, true);
            handler.syncShares(t, m, address(0));
        }
        vm.etch(dev, hex"00");
        vm.prank(owner);
        vault.setExcluded(dev, true);
        handler.syncShares(t, dev, address(0));
        assertEq(vault.totalShares(t), 0);

        _buy(t, buyer, 2 ether);
        uint256 bucketBefore = bucket.accruedQuote(address(wbnb));
        vm.prank(owner);
        uint256 out = handler.process(t, type(uint256).max, 1);
        assertEq(bucket.accruedQuote(address(wbnb)) - bucketBefore, out, "100% to platform");
        assertEq(wbnb.balanceOf(address(vault)), 0, "nothing stranded in the vault");
    }

    function test_handlerPadIsOneShot() public {
        vm.prank(owner);
        vm.expectRevert(HolderRewardHandler.PadAlreadySet.selector);
        handler.setPad(stranger);
    }
}
