// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {QuoteRegistry} from "../../src/stocks/QuoteRegistry.sol";
import {DividendVault} from "../../src/stocks/DividendVault.sol";
import {PlatformFeeBucket} from "../../src/stocks/PlatformFeeBucket.sol";
import {BuybackBurner} from "../../src/stocks/BuybackBurner.sol";
import {LaunchpadU} from "../../src/stocks/LaunchpadU.sol";
import {MigratorS} from "../../src/stocks/MigratorS.sol";
import {TaxLaunchToken} from "../../src/stocks/TaxLaunchToken.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {PoolCheck} from "../../src/stocks/PoolCheck.sol";

import {MockSPCXB} from "../../src/stocks/mocks/MockSPCXB.sol";
import {MockGANG} from "../../src/stocks/mocks/MockGANG.sol";
import {MockPairFactory, MockPair} from "../../src/stocks/mocks/MockPairFactory.sol";

/// @notice Tip A: any-pool + normal/taxed create. Forge only — no Chapel broadcast.
contract AnyPoolTaxTipATest is Test {
    uint256 internal constant GRAD = 1 ether;
    uint256 internal constant BPS = 10_000;

    QuoteRegistry internal registry;
    DividendVault internal vault;
    PlatformFeeBucket internal bucket;
    BuybackBurner internal burner;
    LaunchpadU internal pad;
    MigratorS internal migrator;
    MockPairFactory internal factory;
    MockSPCXB internal spcxb;
    MockSPCXB internal wbnb;
    MockGANG internal gang;

    address internal owner = makeAddr("owner");
    address internal feeVault = makeAddr("feeVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    address internal liquidPair;

    function setUp() public {
        spcxb = new MockSPCXB();
        wbnb = new MockSPCXB(); // stand-in WBNB (18 dec)
        gang = new MockGANG();
        factory = new MockPairFactory();

        registry = new QuoteRegistry(owner);
        vault = new DividendVault(owner);
        burner = new BuybackBurner(owner);
        bucket = new PlatformFeeBucket(owner, feeVault);

        pad = new LaunchpadU(
            owner, address(registry), address(vault), address(bucket), address(wbnb), address(factory)
        );
        migrator = new MigratorS(address(factory), address(pad));

        vm.startPrank(owner);
        // Registry optional — leave empty to prove taxed path does not hard-require whitelist.
        vault.setLaunchpad(address(pad));
        bucket.setLaunchpad(address(pad));
        bucket.setBurner(address(burner));
        bucket.setKeeper(keeper);
        burner.setGang(address(gang));
        pad.setMigrator(address(migrator));
        pad.setAgentGate(false, address(0));
        pad.setWalletCapEnabled(false);
        pad.setDefaultGraduationQuoteAmount(GRAD);
        vm.stopPrank();

        spcxb.mint(alice, 200 ether);
        spcxb.mint(bob, 100 ether);
        wbnb.mint(alice, 200 ether);
        gang.mint(address(burner), 1000 ether);

        // Seed quote/WBNB pair with reserves (any-pool precondition).
        liquidPair = factory.createPair(address(spcxb), address(wbnb));
        spcxb.mintUnlimited(address(this), 50 ether);
        wbnb.mintUnlimited(address(this), 50 ether);
        spcxb.transfer(liquidPair, 50 ether);
        wbnb.transfer(liquidPair, 50 ether);
        MockPair(liquidPair).mint(address(0xdead));
    }

    function test_CreateNormal_V41Style() public {
        vm.prank(alice);
        address t = pad.create("Plain Meme", "PLAIN", "ipfs://logo", false, address(spcxb));

        (address creator, address quote,,,, bool taxed, address pair, address refPair) = _curve(t);
        assertEq(creator, alice);
        assertEq(quote, address(spcxb));
        assertFalse(taxed);
        assertEq(pair, address(0));
        assertEq(refPair, address(0));
        assertEq(pad.logoURIOf(t), "ipfs://logo");
        // Untaxed uses LaunchToken (no tax hooks).
        assertTrue(LaunchToken(t).locked());
        // Not registered in dividend vault.
        assertEq(vault.quoteOf(t), address(0));
        assertEq(vault.minimumShareBalance(), 0);
    }

    function test_CreateTaxed_WithPairReserves() public {
        vm.prank(alice);
        address t = pad.create("Taxed Stock", "TSTOCK", "https://x/l.png", true, liquidPair);

        (address creator, address quote,,,, bool taxed,, address refPair) = _curve(t);
        assertEq(creator, alice);
        assertEq(quote, address(spcxb));
        assertTrue(taxed);
        assertEq(refPair, liquidPair);
        assertEq(vault.quoteOf(t), address(spcxb));
        assertEq(vault.minimumShareBalance(), pad.TAXED_MIN_SHARE());
        assertTrue(TaxLaunchToken(t).locked());
    }

    function test_CreateTaxed_WithQuoteERC20_ResolvesPair() public {
        vm.prank(alice);
        address t = pad.create("Via Quote", "VQ", "", true, address(spcxb));
        (, address quote,,,, bool taxed,, address rp) = _curve(t);
        assertEq(quote, address(spcxb));
        assertTrue(taxed);
        assertEq(rp, liquidPair);
    }

    function test_CreateTaxed_RejectsEmptyPair() public {
        // WBNB pair exists but has zero reserves.
        MockSPCXB orphanQuote = new MockSPCXB();
        address emptyPair = factory.createPair(address(orphanQuote), address(wbnb));
        vm.prank(alice);
        vm.expectRevert(PoolCheck.PairNoReserves.selector);
        pad.create("Empty", "EMP", "", true, emptyPair);
    }

    function test_CreateTaxed_RejectsUnknownQuoteNoPair() public {
        MockSPCXB orphan = new MockSPCXB(); // no factory pair
        vm.prank(alice);
        vm.expectRevert(PoolCheck.PairEmpty.selector);
        pad.create("Junk", "JNK", "", true, address(orphan));
    }

    function test_CreateTaxed_RejectsZero() public {
        vm.prank(alice);
        vm.expectRevert(LaunchpadU.TaxedRequiresPairOrQuote.selector);
        pad.create("Z", "Z", "", true, address(0));
    }

    function test_UntaxedBuy_ProtocolFeeToPlatformOnly() public {
        vm.prank(alice);
        address t = pad.create("Plain", "P", "", false, address(spcxb));

        uint256 spend = 0.1 ether;
        vm.startPrank(alice);
        spcxb.approve(address(pad), spend);
        uint256 out = pad.buy(t, spend, 0);
        vm.stopPrank();

        assertGt(out, 0);
        uint256 expectPlat = (spend * 100) / BPS; // full 1% → platform
        assertEq(bucket.accruedQuote(address(spcxb)), expectPlat);
        assertEq(spcxb.balanceOf(address(vault)), 0);
        assertEq(vault.pending(t, alice), 0); // unknown token / no shares
    }

    function test_TaxedBuy_Splits50_50_AndMinShareGate() public {
        vm.prank(owner);
        pad.setDefaultGraduationQuoteAmount(1000 ether); // keep curve open

        vm.prank(alice);
        address t = pad.create("Taxed", "TX", "", true, liquidPair);
        assertEq(vault.minimumShareBalance(), pad.TAXED_MIN_SHARE());

        spcxb.mintUnlimited(alice, 50 ether);

        // Large buy → balance ≥ 10000e18 → earns shares + pending.
        uint256 spend = 1 ether;
        vm.startPrank(alice);
        spcxb.approve(address(pad), type(uint256).max);
        uint256 out = pad.buy(t, spend, 0);
        vm.stopPrank();

        assertGe(out, pad.TAXED_MIN_SHARE());
        assertEq(vault.shares(t, alice), IERC20(t).balanceOf(alice));
        uint256 expectDiv = (spend * 50) / BPS;
        uint256 expectPlat = (spend * 50) / BPS;
        assertEq(bucket.accruedQuote(address(spcxb)), expectPlat);
        assertEq(spcxb.balanceOf(address(vault)), expectDiv);
        assertGt(vault.pending(t, alice), 0);

        // Sell down below TAXED_MIN_SHARE → share gate zeroes Alice.
        uint256 bal = IERC20(t).balanceOf(alice);
        uint256 sellAmt = bal - (pad.TAXED_MIN_SHARE() - 1);
        vm.startPrank(alice);
        TaxLaunchToken(t).approve(address(pad), sellAmt);
        pad.sell(t, sellAmt, 0);
        vm.stopPrank();

        assertLt(IERC20(t).balanceOf(alice), pad.TAXED_MIN_SHARE());
        assertEq(vault.shares(t, alice), 0);
    }

    function test_PlatformCollect_FeeVaultGets20Percent() public {
        vm.prank(alice);
        address t = pad.create("Plain", "P2", "", false, address(spcxb));
        uint256 spend = 0.1 ether;
        vm.startPrank(alice);
        spcxb.approve(address(pad), spend);
        pad.buy(t, spend, 0);
        vm.stopPrank();

        uint256 accrued = bucket.accruedQuote(address(spcxb));
        uint256 vaultBefore = spcxb.balanceOf(feeVault);
        vm.prank(keeper);
        bucket.collectPlatform(address(spcxb));
        uint256 toVault = accrued - (accrued * 8000) / BPS;
        assertEq(spcxb.balanceOf(feeVault), vaultBefore + toVault);
    }

    function _curve(address token)
        internal
        view
        returns (
            address creator,
            address quote,
            uint128 realQuote,
            uint128 sold,
            bool graduated,
            bool taxed,
            address pair,
            address refPair
        )
    {
        return pad.curves(token);
    }
}
