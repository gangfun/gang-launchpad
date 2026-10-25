// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {DividendVault} from "../../src/launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {MigratorV2} from "../../src/launchpad-v2/MigratorV2.sol";
import {LaunchToken} from "../../src/launchpad-v2/LaunchToken.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {MockPairFactory, MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {LaunchpadV3} from "../../src/launchpad-v3/LaunchpadV3.sol";
import {TaxLaunchTokenV3, TaxTokenDeployerV3} from "../../src/launchpad-v3/TaxLaunchTokenV3.sol";
import {PostGradTaxHandlerV3} from "../../src/launchpad-v3/PostGradTaxHandlerV3.sol";
import {TaxRouterV3} from "../../src/launchpad-v3/TaxRouterV3.sol";
import {TemplateRegistry} from "../../src/launchpad-v3/TemplateRegistry.sol";
import {ILaunchpadV3} from "../../src/launchpad-v3/interfaces/ILaunchpadV3.sol";
import {TemplateTypes} from "../../src/launchpad-v3/interfaces/TemplateTypes.sol";
import {CreatorTreasuryFactory, CreatorTreasuryVault} from "../../src/launchpad-v3/templates/CreatorTreasury.sol";
import {BuybackBurnFactory, BuybackBurnVault} from "../../src/launchpad-v3/templates/BuybackBurn.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";

/// @dev Listed factory whose vault lies about its token — create must reject it.
contract LyingVault {
    address public token = address(0xBEEF);
    address public quote;

    constructor(address quote_) {
        quote = quote_;
    }
}

contract LyingFactory {
    function createVault(address, address quote, address, bytes calldata) external returns (address) {
        return address(new LyingVault(quote));
    }

    function validate(bytes calldata) external pure returns (bool, string memory) {
        return (true, "");
    }
}

/// @notice LaunchpadV3 end to end on mocks: create rules, bonding tax split, graduation, post-grad tax via
///         TaxRouterV3, both official templates. No broadcast.
contract LaunchpadV3Test is Test {
    QuoteRegistry internal quoteRegistry;
    DividendVault internal divVault;
    PlatformFeeBucket internal bucket;
    TaxRouterV3 internal router;
    TemplateRegistry internal templates;
    PostGradTaxHandlerV3 internal handler;
    LaunchpadV3 internal pad;
    MigratorV2 internal migrator;
    MockPairFactory internal pairFactory;
    MockSPCXB internal quoteTok;
    MockSPCXB internal wbnb;
    MockAgentId internal agents;
    CreatorTreasuryFactory internal treasury;
    CreatorTreasuryFactory internal treasuryByAuthor;
    BuybackBurnFactory internal buyback;

    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal feeVault = makeAddr("feeVault");
    address internal author = makeAddr("author");
    address internal agent = makeAddr("agent");
    address internal agent2 = makeAddr("agent2");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant BPS = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        quoteTok = new MockSPCXB();
        wbnb = new MockSPCXB();
        pairFactory = new MockPairFactory();
        agents = new MockAgentId();

        quoteRegistry = new QuoteRegistry(owner);
        divVault = new DividendVault(owner);
        bucket = new PlatformFeeBucket(owner, feeVault);
        router = new TaxRouterV3(owner, address(divVault), address(bucket));
        templates = new TemplateRegistry(owner);
        handler = new PostGradTaxHandlerV3(owner, address(divVault), address(router));
        pad = new LaunchpadV3(
            owner,
            address(quoteRegistry),
            address(divVault),
            address(bucket),
            address(handler),
            address(router),
            address(templates),
            address(new TaxTokenDeployerV3()),
            address(wbnb),
            address(pairFactory)
        );
        migrator = new MigratorV2(address(pairFactory), address(pad));
        treasury = new CreatorTreasuryFactory(address(pad), address(router));
        treasuryByAuthor = new CreatorTreasuryFactory(address(pad), address(router));
        buyback = new BuybackBurnFactory(owner, address(pad), address(router), address(pairFactory));

        vm.startPrank(owner);
        quoteRegistry.setQuote(address(quoteTok), true, 15 ether);
        divVault.setLaunchpad(address(pad));
        divVault.setOperator(address(router), true);
        divVault.setOperator(address(handler), true);
        bucket.setLaunchpad(address(pad));
        bucket.setOperator(address(router), true);
        router.setLaunchpad(address(pad));
        router.setSource(address(handler), true);
        handler.setKeeper(keeper);
        buyback.setKeeper(keeper);
        templates.list(address(treasury), address(0));
        templates.list(address(treasuryByAuthor), author);
        templates.list(address(buyback), address(0));
        pad.setMigrator(address(migrator));
        pad.setAgentGate(true, address(agents));
        vm.stopPrank();

        agents.mint(agent, 1);
        agents.mint(agent2, 2);
        _fund(agent);
        _fund(agent2);
    }

    // ---------------------------------------------------------------- helpers

    function _fund(address who) internal {
        quoteTok.mintUnlimited(who, 1_000 ether);
        vm.prank(who);
        quoteTok.approve(address(pad), type(uint256).max);
    }

    function _cfg(uint16 taxBps, bool bondingTax, uint16 dividendBps, address factory, bytes memory data)
        internal
        pure
        returns (ILaunchpadV3.TaxConfig memory)
    {
        return ILaunchpadV3.TaxConfig({
            taxBps: taxBps, bondingTax: bondingTax, dividendBps: dividendBps, vaultFactory: factory, vaultData: data
        });
    }

    function _untaxed() internal pure returns (ILaunchpadV3.TaxConfig memory) {
        return _cfg(0, false, 0, address(0), "");
    }

    function _create(ILaunchpadV3.TaxConfig memory tax) internal returns (address t) {
        vm.prank(agent);
        t = pad.create("T", "T", "", address(quoteTok), address(0), tax);
    }

    function _graduated(address t) internal view returns (bool g) {
        (,,,,,, g,,,,,) = pad.curves(t);
    }

    function _pair(address t) internal view returns (address p) {
        (,,,,,,,,,, p,) = pad.curves(t);
    }

    /// @dev Wallet cap off, one oversized buy: the pad caps net at the remaining amount and refunds the rest.
    function _graduate(address t, address buyer) internal {
        vm.prank(owner);
        pad.setWalletCapEnabled(false);
        vm.prank(buyer);
        pad.buy(t, 100 ether, 0);
        assertTrue(_graduated(t), "expected graduation");
        vm.prank(owner);
        pad.setWalletCapEnabled(true);
    }

    function _reason(ILaunchpadV3.TaxConfig memory tax) internal view returns (string memory r) {
        (, r) = pad.checkTaxConfig(tax);
    }

    // ---------------------------------------------------------------- create rules

    function test_checkTaxConfig_rules() public {
        (bool ok,) = pad.checkTaxConfig(_untaxed());
        assertTrue(ok);
        (ok,) = pad.checkTaxConfig(_cfg(300, true, 10_000, address(0), ""));
        assertTrue(ok);
        (ok,) = pad.checkTaxConfig(_cfg(500, false, 5_000, address(treasury), abi.encode(address(0), uint256(0))));
        assertTrue(ok);

        assertEq(
            _reason(_cfg(0, true, 0, address(0), "")),
            "untaxed: bondingTax/dividendBps/vaultFactory/vaultData must be empty"
        );
        assertEq(_reason(_cfg(400, false, 10_000, address(0), "")), "taxBps must be 100, 200, 300 or 500");
        assertEq(_reason(_cfg(1000, false, 10_000, address(0), "")), "taxBps must be 100, 200, 300 or 500");
        assertEq(_reason(_cfg(100, false, 5_000, address(0), "")), "no template: dividendBps must be 10000");
        assertEq(_reason(_cfg(100, false, 10_001, address(treasury), "")), "dividendBps > 10000");
        assertEq(_reason(_cfg(100, false, 0, makeAddr("rando"), "")), "template not listed");
        assertEq(
            _reason(_cfg(100, false, 0, address(treasury), hex"01")),
            "data must be abi.encode(address beneficiary, uint256 dailyCap)"
        );

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadV3.BadTaxConfig.selector, "template not listed"));
        pad.create("T", "T", "", address(quoteTok), address(0), _cfg(100, false, 0, makeAddr("rando"), ""));
    }

    function test_create_rejectsNonAgent() public {
        vm.prank(stranger);
        vm.expectRevert(LaunchpadV3.NotAgent.selector);
        pad.create("T", "T", "", address(quoteTok), address(0), _untaxed());
    }

    function test_create_delistedTemplate_rejectedForNewTokens() public {
        vm.prank(owner);
        templates.delist(address(buyback));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadV3.BadTaxConfig.selector, "template not listed"));
        pad.create("T", "T", "", address(quoteTok), address(0), _cfg(300, false, 0, address(buyback), ""));
    }

    function test_create_rejectsVaultForAnotherToken() public {
        LyingFactory lying = new LyingFactory();
        vm.prank(owner);
        templates.list(address(lying), address(0));
        vm.prank(agent);
        vm.expectRevert(LaunchpadV3.BadVault.selector);
        pad.create("T", "T", "", address(quoteTok), address(0), _cfg(300, false, 0, address(lying), ""));
    }

    function test_create_untaxed() public {
        address t = _create(_untaxed());
        assertEq(LaunchToken(t).launchpad(), address(pad));
        (uint16 taxBps, bool bondingTax, uint16 dividendBps, address f, address v) = pad.taxConfigOf(t);
        assertEq(taxBps, 0);
        assertFalse(bondingTax);
        assertEq(dividendBps, 0);
        assertEq(f, address(0));
        assertEq(v, address(0));
        (address q,,,) = router.routeOf(t);
        assertEq(q, address(0), "untaxed tokens have no route");
    }

    function test_create_taxedWithTemplate_wiresEverything() public {
        address t = _create(_cfg(300, true, 4_000, address(treasury), abi.encode(address(0), uint256(0))));
        (uint16 taxBps,,, address f, address v) = pad.taxConfigOf(t);
        assertEq(taxBps, 300);
        assertEq(f, address(treasury));
        assertEq(TaxLaunchTokenV3(t).taxBps(), 300);
        assertEq(TaxLaunchTokenV3(t).launchpad(), address(pad));
        assertEq(IERC20(t).balanceOf(address(pad)), 1_000_000_000 ether);
        assertTrue(TaxLaunchTokenV3(t).isExcluded(v), "vault is tax-excluded");
        assertEq(CreatorTreasuryVault(v).beneficiary(), agent);
        assertEq(divVault.quoteOf(t), address(quoteTok));

        (address q, address rv, address a, uint16 d) = router.routeOf(t);
        assertEq(q, address(quoteTok));
        assertEq(rv, v);
        assertEq(a, address(0));
        assertEq(d, 4_000);
    }

    function test_create_externalTemplate_snapshotsAuthor() public {
        address t = _create(_cfg(100, false, 0, address(treasuryByAuthor), abi.encode(address(0), uint256(0))));
        (,, address a,) = router.routeOf(t);
        assertEq(a, author);
    }

    // ---------------------------------------------------------------- bonding

    function test_bonding_untaxed_protocolFeeOnly() public {
        address t = _create(_untaxed());
        vm.prank(agent);
        pad.buy(t, 0.01 ether, 0);
        assertEq(bucket.accruedQuote(address(quoteTok)), 0.0001 ether);
    }

    function test_bonding_taxOff_onlyProtocolFee() public {
        address t = _create(_cfg(500, false, 10_000, address(0), ""));
        vm.prank(agent);
        pad.buy(t, 0.01 ether, 0);
        assertEq(bucket.accruedQuote(address(quoteTok)), 0.0001 ether);
        assertEq(quoteTok.balanceOf(address(divVault)), 0);
    }

    /// @dev 3% bonding tax, dividends only. First buy has no eligible holders → the 70% rolls to platform.
    ///      Second buy pays the 70% to the first buyer. Buys stay under the 1% wallet cap (no truncation).
    function test_bonding_dividendOnly_firstBuyRollsToPlatform_thenHolders() public {
        address t = _create(_cfg(300, true, 10_000, address(0), ""));

        vm.prank(agent);
        pad.buy(t, 0.01 ether, 0);
        // 1% protocol + 3% tax, all to platform on the first buy.
        assertEq(bucket.accruedQuote(address(quoteTok)), 0.0004 ether);
        assertGt(divVault.shares(t, agent), 0);

        vm.prank(agent2);
        pad.buy(t, 0.01 ether, 0);
        // second buy: 1% + 30% of 3% to platform; 70% of 3% to holders (only agent eligible).
        assertEq(bucket.accruedQuote(address(quoteTok)), 0.0004 ether + 0.0001 ether + 0.00009 ether);
        // DividendVault accRewardPerShare rounding: up to totalShares / 1e18 wei of dust (V2 behaviour).
        assertApproxEqAbs(divVault.pending(t, agent), 0.00021 ether, divVault.totalShares(t) / 1e18 + 1);
        assertEq(divVault.pending(t, agent2), 0);
    }

    function test_bonding_templateVault_andAuthor() public {
        address t = _create(_cfg(500, true, 0, address(treasuryByAuthor), abi.encode(address(0), uint256(0))));
        (,,,, address v) = pad.taxConfigOf(t);

        vm.prank(agent);
        pad.buy(t, 0.02 ether, 0);
        uint256 tax = 0.001 ether; // 5% of 0.02
        assertEq(bucket.accruedQuote(address(quoteTok)), 0.0002 ether + (tax * 2_000) / BPS);
        assertEq(router.owed(author, address(quoteTok)), (tax * 1_000) / BPS);
        assertEq(quoteTok.balanceOf(v), (tax * 7_000) / BPS);

        vm.prank(agent);
        CreatorTreasuryVault(v).withdraw(0.0007 ether, agent);
        assertEq(quoteTok.balanceOf(v), 0);
    }

    function test_bonding_sell_chargesTax() public {
        address t = _create(_cfg(200, true, 10_000, address(0), ""));
        vm.prank(agent);
        pad.buy(t, 1 ether, 0);
        uint256 bal = IERC20(t).balanceOf(agent);

        uint256 before = quoteTok.balanceOf(agent);
        uint256 bucketBefore = bucket.accruedQuote(address(quoteTok));
        vm.startPrank(agent);
        IERC20(t).approve(address(pad), bal);
        uint256 got = pad.sell(t, bal / 2, 0);
        vm.stopPrank();

        assertEq(quoteTok.balanceOf(agent) - before, got);
        // gross = got / (1 - 1% - 2%); seller still held shares when the tax was split → 70% to holders.
        uint256 gross = (got * BPS) / (BPS - 300);
        assertApproxEqAbs(bucket.accruedQuote(address(quoteTok)) - bucketBefore, (gross * 160) / BPS, 1e9);
    }

    function test_bonding_walletCapStillApplies() public {
        address t = _create(_cfg(300, true, 10_000, address(0), ""));
        vm.prank(agent);
        pad.buy(t, 10 ether, 0);
        assertEq(IERC20(t).balanceOf(agent), pad.MAX_PER_WALLET());
    }

    // ---------------------------------------------------------------- graduation + post-grad

    function test_postGrad_buybackTemplate_endToEnd() public {
        address t = _create(_cfg(500, true, 5_000, address(buyback), ""));
        (,,,, address v) = pad.taxConfigOf(t);

        vm.prank(agent2);
        pad.buy(t, 1 ether, 0); // agent2 becomes a dividend holder
        _graduate(t, agent);

        address pair = _pair(t);
        assertEq(TaxLaunchTokenV3(t).pair(), pair);
        assertEq(TaxLaunchTokenV3(t).taxHandler(), address(handler));

        // Pair trade: agent sends tokens to the pair → 5% outer tax accrues in the handler.
        uint256 trade = 1_000_000 ether;
        vm.prank(agent);
        IERC20(t).transfer(pair, trade);
        uint256 taxTokens = (trade * 500) / BPS;
        assertEq(handler.accruedTax(t), taxTokens);

        // Wallet ↔ wallet: no tax.
        vm.prank(agent);
        IERC20(t).transfer(stranger, 1 ether);
        assertEq(handler.accruedTax(t), taxTokens);

        vm.expectRevert(PostGradTaxHandlerV3.OnlyKeeperOrOwner.selector);
        handler.process(t, 1);

        uint256 bucketBefore = bucket.accruedQuote(address(quoteTok));
        uint256 vaultBefore = quoteTok.balanceOf(v);
        uint256 pendingBefore = divVault.pending(t, agent2);
        vm.prank(keeper);
        uint256 quoteOut = handler.process(t, 1);
        assertGt(quoteOut, 0);

        assertEq(bucket.accruedQuote(address(quoteTok)) - bucketBefore, (quoteOut * 3_000) / BPS);
        uint256 tokenSide = quoteOut - (quoteOut * 3_000) / BPS;
        assertEq(quoteTok.balanceOf(v) - vaultBefore, tokenSide - (tokenSide * 5_000) / BPS);
        assertGt(divVault.pending(t, agent2), pendingBefore);

        // Buyback: keeper only, burns to 0xdead, vault quote → 0.
        vm.expectRevert(BuybackBurnVault.OnlyKeeper.selector);
        BuybackBurnVault(v).buyback(0, 1);

        uint256 deadBefore = IERC20(t).balanceOf(DEAD);
        vm.prank(keeper);
        uint256 burned = BuybackBurnVault(v).buyback(0, 1);
        assertGt(burned, 0);
        assertEq(IERC20(t).balanceOf(DEAD) - deadBefore, burned);
        assertEq(quoteTok.balanceOf(v), 0);
        assertEq(BuybackBurnVault(v).totalBurned(), burned);
        assertEq(handler.accruedTax(t), 0, "vault buyback pays no tax");
    }

    function test_postGrad_buyback_beforeGraduation_reverts() public {
        address t = _create(_cfg(500, true, 0, address(buyback), ""));
        (,,,, address v) = pad.taxConfigOf(t);
        vm.prank(agent);
        pad.buy(t, 1 ether, 0);
        assertGt(quoteTok.balanceOf(v), 0, "bonding tax waits in the vault");
        vm.prank(keeper);
        vm.expectRevert(BuybackBurnVault.NoPair.selector);
        BuybackBurnVault(v).buyback(0, 1);
    }

    function test_postGrad_untaxed_noTax() public {
        address t = _create(_untaxed());
        _graduate(t, agent);
        address pair = _pair(t);
        uint256 before = IERC20(t).balanceOf(pair);
        vm.prank(agent);
        IERC20(t).transfer(pair, 1_000 ether);
        assertEq(IERC20(t).balanceOf(pair) - before, 1_000 ether);
    }
}
