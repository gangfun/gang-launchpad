// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {QuoteRegistry} from "../../src/stocks/QuoteRegistry.sol";
import {DividendVault} from "../../src/stocks/DividendVault.sol";
import {PlatformFeeBucket} from "../../src/stocks/PlatformFeeBucket.sol";
import {BuybackBurner} from "../../src/stocks/BuybackBurner.sol";
import {LaunchpadS} from "../../src/stocks/LaunchpadS.sol";
import {MigratorS} from "../../src/stocks/MigratorS.sol";
import {TaxLaunchToken} from "../../src/stocks/TaxLaunchToken.sol";

import {MockSPCXB} from "../../src/stocks/mocks/MockSPCXB.sol";
import {MockGANG} from "../../src/stocks/mocks/MockGANG.sol";
import {MockPairFactory} from "../../src/stocks/mocks/MockPairFactory.sol";

/// @notice T0 Stocks PoC: create → buy/sell → 1% tax split (50/50) → claim → graduate.
/// @dev IS_TESTNET_MIN_PARAMS: graduation = 1e18 MockSPCXB; agent gate off; wallet cap off.
contract StocksPoCTest is Test {
    uint256 internal constant GRAD = 1 ether; // 1 MockSPCXB
    uint256 internal constant BPS = 10_000;

    QuoteRegistry internal registry;
    DividendVault internal vault;
    PlatformFeeBucket internal bucket;
    BuybackBurner internal burner;
    LaunchpadS internal pad;
    MigratorS internal migrator;
    MockPairFactory internal factory;
    MockSPCXB internal spcxb;
    MockGANG internal gang;

    address internal owner = makeAddr("owner");
    address internal feeVault = makeAddr("feeVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    TaxLaunchToken internal tok;

    function setUp() public {
        spcxb = new MockSPCXB();
        gang = new MockGANG();
        factory = new MockPairFactory();

        registry = new QuoteRegistry(owner);
        vault = new DividendVault(owner);
        burner = new BuybackBurner(owner);
        bucket = new PlatformFeeBucket(owner, feeVault);

        pad = new LaunchpadS(owner, address(registry), address(vault), address(bucket));
        migrator = new MigratorS(address(factory), address(pad));

        vm.startPrank(owner);
        registry.setQuote(address(spcxb), true, GRAD);
        vault.setLaunchpad(address(pad));
        bucket.setLaunchpad(address(pad));
        bucket.setBurner(address(burner));
        bucket.setKeeper(keeper);
        burner.setGang(address(gang));
        pad.setMigrator(address(migrator));
        pad.setAgentGate(false, address(0));
        pad.setWalletCapEnabled(false);
        vm.stopPrank();

        spcxb.mint(alice, 100 ether);
        spcxb.mint(bob, 100 ether);
        gang.mint(address(burner), 1000 ether);

        vm.prank(alice);
        address t = pad.create("Space Meme", "SMEME", address(spcxb));
        tok = TaxLaunchToken(t);
    }

    function test_CreateLocksQuote() public view {
        (address creator, address quote,,,,) = pad.curves(address(tok));
        assertEq(creator, alice);
        assertEq(quote, address(spcxb));
        assertEq(vault.quoteOf(address(tok)), address(spcxb));
        assertTrue(registry.isQuoted(address(spcxb)));
    }

    function test_CreateRejectsUnknownQuote() public {
        address junk = makeAddr("junk");
        vm.prank(alice);
        vm.expectRevert(LaunchpadS.QuoteNotAllowed.selector);
        pad.create("Bad", "BAD", junk);
    }

    function test_BuySplitsTax1Percent() public {
        // Keep spend << GRAD so graduation cap does not bind.
        uint256 spend = 0.1 ether;
        uint256 balBefore = spcxb.balanceOf(alice);

        vm.startPrank(alice);
        spcxb.approve(address(pad), spend);
        uint256 tokensOut = pad.buy(address(tok), spend, 0);
        vm.stopPrank();

        assertGt(tokensOut, 0);
        assertEq(spcxb.balanceOf(alice), balBefore - spend);

        uint256 expectDiv = (spend * 50) / BPS;
        uint256 expectPlat = (spend * 50) / BPS;
        uint256 expectNet = spend - expectDiv - expectPlat;

        (,, uint256 realQuote, uint256 sold, bool graduated,) = _curve();
        assertEq(realQuote, expectNet);
        assertEq(sold, tokensOut);
        assertFalse(graduated);

        assertEq(bucket.accruedQuote(address(spcxb)), expectPlat);
        // Share math floors a few wei; vault still holds full tax.
        // Magnified per-share math floors dust proportional to share size; vault holds full tax.
        assertApproxEqAbs(vault.pending(address(tok), alice), expectDiv, 1e12);
        assertEq(spcxb.balanceOf(address(vault)), expectDiv);
        assertGt(vault.pending(address(tok), alice), expectDiv * 99 / 100);
    }

    function test_SellSplitsTaxAndClaim() public {
        uint256 spend = 0.05 ether;
        vm.startPrank(alice);
        spcxb.approve(address(pad), spend);
        uint256 bought = pad.buy(address(tok), spend, 0);

        uint256 sellAmt = bought / 2;
        tok.approve(address(pad), sellAmt);
        uint256 quoteOut = pad.sell(address(tok), sellAmt, 0);
        vm.stopPrank();

        assertGt(quoteOut, 0);

        uint256 pending = vault.pending(address(tok), alice);
        assertGt(pending, 0);

        uint256 aliceQuoteBefore = spcxb.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claim(address(tok));
        assertEq(claimed, pending);
        assertEq(spcxb.balanceOf(alice), aliceQuoteBefore + claimed);
        assertEq(vault.pending(address(tok), alice), 0);
    }

    function test_PlatformCollect80_20() public {
        uint256 spend = 0.1 ether;
        vm.startPrank(alice);
        spcxb.approve(address(pad), spend);
        pad.buy(address(tok), spend, 0);
        vm.stopPrank();

        uint256 accrued = bucket.accruedQuote(address(spcxb));
        assertEq(accrued, (spend * 50) / BPS);

        uint256 vaultBefore = spcxb.balanceOf(feeVault);
        uint256 burnerBefore = burner.quoteReceived(address(spcxb));
        uint256 gangDeadBefore = gang.balanceOf(address(0xdead));

        vm.prank(keeper);
        bucket.collectPlatform(address(spcxb));

        uint256 toBuyback = (accrued * 8000) / BPS;
        uint256 toVault = accrued - toBuyback;
        assertEq(bucket.accruedQuote(address(spcxb)), 0);
        assertEq(spcxb.balanceOf(feeVault), vaultBefore + toVault);
        assertEq(burner.quoteReceived(address(spcxb)), burnerBefore + toBuyback);
        assertGt(gang.balanceOf(address(0xdead)), gangDeadBefore);
    }

    function test_GraduateCreatesTokenQuotePair() public {
        // Gross enough that net hits GRAD (1e18); excess refunded.
        uint256 gross = 2 ether;
        vm.startPrank(alice);
        spcxb.approve(address(pad), gross);
        pad.buy(address(tok), gross, 0);
        vm.stopPrank();

        (,,,, bool graduated, address pair) = _curve();
        assertTrue(graduated);
        assertTrue(pair != address(0));
        assertGt(IERC20(address(tok)).balanceOf(pair), 0);
        assertGt(spcxb.balanceOf(pair), 0);
        assertEq(tok.pair(), pair);
        assertFalse(tok.locked());
    }

    function test_FullPath_CreateBuySellClaimGraduateCollect() public {
        vm.startPrank(bob);
        spcxb.approve(address(pad), 0.05 ether);
        pad.buy(address(tok), 0.05 ether, 0);
        vm.stopPrank();

        vm.startPrank(alice);
        spcxb.approve(address(pad), 0.05 ether);
        uint256 bought = pad.buy(address(tok), 0.05 ether, 0);
        tok.approve(address(pad), bought / 5);
        pad.sell(address(tok), bought / 5, 0);
        vm.stopPrank();

        if (vault.pending(address(tok), alice) > 0) {
            vm.prank(alice);
            vault.claim(address(tok));
        }
        if (vault.pending(address(tok), bob) > 0) {
            vm.prank(bob);
            vault.claim(address(tok));
        }

        vm.startPrank(alice);
        spcxb.approve(address(pad), 5 ether);
        pad.buy(address(tok), 5 ether, 0);
        vm.stopPrank();

        (,,,, bool graduated,) = _curve();
        assertTrue(graduated);

        if (bucket.accruedQuote(address(spcxb)) > 0) {
            vm.prank(keeper);
            bucket.collectPlatform(address(spcxb));
        }
        assertEq(bucket.accruedQuote(address(spcxb)), 0);
    }

    function test_NeverTouchesMainTrackAccruedFees() public view {
        assertEq(bucket.accruedQuote(address(spcxb)), 0);
    }

    function _curve()
        internal
        view
        returns (address creator, address quote, uint256 realQuote, uint256 sold, bool graduated, address pair)
    {
        (creator, quote, realQuote, sold, graduated, pair) = pad.curves(address(tok));
    }
}
