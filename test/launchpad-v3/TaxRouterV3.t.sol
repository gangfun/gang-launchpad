// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DividendVault} from "../../src/launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {TaxRouterV3} from "../../src/launchpad-v3/TaxRouterV3.sol";
import {TemplateRegistry} from "../../src/launchpad-v3/TemplateRegistry.sol";
import {TemplateTypes} from "../../src/launchpad-v3/interfaces/TemplateTypes.sol";
import {CreatorTreasuryFactory, CreatorTreasuryVault} from "../../src/launchpad-v3/templates/CreatorTreasury.sol";

/// @dev Quote with a blacklist (USDT-style): transfers to a blocked address revert.
contract BlacklistQuote is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Blacklist Quote", "BLQ") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function block_(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blocked");
        super._update(from, to, value);
    }
}

contract RevertingHookVault {
    address public token;
    address public quote;

    constructor(address token_, address quote_) {
        token = token_;
        quote = quote_;
    }

    function onTaxReceived(uint256, TemplateTypes.Phase) external pure {
        revert("nope");
    }
}

/// @notice TaxRouterV3 split + TemplateRegistry + CreatorTreasury template. Pad and post-grad handler are
///         stand-in addresses (LaunchpadV3 not written yet). No broadcast.
contract TaxRouterV3Test is Test {
    DividendVault internal divVault;
    PlatformFeeBucket internal bucket;
    TaxRouterV3 internal router;
    TemplateRegistry internal registry;
    CreatorTreasuryFactory internal treasuryFactory;
    MockSPCXB internal quote;

    address internal owner = makeAddr("owner");
    address internal feeVault = makeAddr("feeVault");
    address internal pad = makeAddr("pad");
    address internal postGrad = makeAddr("postGrad");
    address internal creator = makeAddr("creator");
    address internal author = makeAddr("author");
    address internal holder = makeAddr("holder");
    address internal token = makeAddr("token");

    function setUp() public {
        quote = new MockSPCXB();
        divVault = new DividendVault(owner);
        bucket = new PlatformFeeBucket(owner, feeVault);
        router = new TaxRouterV3(owner, address(divVault), address(bucket));
        registry = new TemplateRegistry(owner);
        treasuryFactory = new CreatorTreasuryFactory(pad, address(router));

        vm.startPrank(owner);
        divVault.setLaunchpad(pad);
        divVault.setOperator(address(router), true);
        bucket.setLaunchpad(pad);
        bucket.setOperator(address(router), true);
        router.setLaunchpad(pad);
        router.setSource(postGrad, true);
        registry.list(address(treasuryFactory), address(0));
        vm.stopPrank();

        vm.prank(pad);
        divVault.registerToken(token, address(quote));
        vm.prank(pad);
        divVault.setShare(token, holder, 1_000_000 ether);

        quote.mintUnlimited(pad, 1_000_000 ether);
        quote.mintUnlimited(postGrad, 1_000_000 ether);
        vm.prank(pad);
        quote.approve(address(router), type(uint256).max);
        vm.prank(postGrad);
        quote.approve(address(router), type(uint256).max);
    }

    function _treasury(uint256 dailyCap) internal returns (CreatorTreasuryVault v) {
        vm.prank(pad);
        v = CreatorTreasuryVault(
            treasuryFactory.createVault(token, address(quote), creator, abi.encode(address(0), dailyCap))
        );
    }

    // ---------------------------------------------------------------- split

    function test_split_platformTemplate_70_30() public {
        CreatorTreasuryVault v = _treasury(0);
        vm.prank(pad);
        router.register(token, address(quote), address(v), address(0), 5_000);

        vm.prank(pad);
        router.distribute(token, 1000 ether, TemplateTypes.Phase.Bonding);

        assertEq(bucket.accruedQuote(address(quote)), 300 ether);
        assertEq(divVault.pending(token, holder), 350 ether);
        assertEq(quote.balanceOf(address(v)), 350 ether);
        assertEq(quote.balanceOf(address(router)), 0);
    }

    function test_split_externalAuthor_takesTenOutOfPlatform() public {
        CreatorTreasuryVault v = _treasury(0);
        vm.prank(pad);
        router.register(token, address(quote), address(v), author, 5_000);

        vm.prank(postGrad);
        router.distribute(token, 1000 ether, TemplateTypes.Phase.PostGrad);

        assertEq(bucket.accruedQuote(address(quote)), 200 ether);
        assertEq(router.owed(author, address(quote)), 100 ether);
        assertEq(divVault.pending(token, holder), 350 ether);
        assertEq(quote.balanceOf(address(v)), 350 ether);

        router.release(author, address(quote));
        assertEq(quote.balanceOf(author), 100 ether);
        assertEq(router.owed(author, address(quote)), 0);
    }

    function test_split_dividendOnly_noVault() public {
        vm.prank(pad);
        router.register(token, address(quote), address(0), address(0), 10_000);

        vm.prank(pad);
        router.distribute(token, 1000 ether, TemplateTypes.Phase.Bonding);

        assertEq(bucket.accruedQuote(address(quote)), 300 ether);
        assertEq(divVault.pending(token, holder), 700 ether);
    }

    function test_split_noShares_rollsToVault_elsePlatform() public {
        vm.prank(pad);
        divVault.setShare(token, holder, 0);

        CreatorTreasuryVault v = _treasury(0);
        vm.prank(pad);
        router.register(token, address(quote), address(v), address(0), 5_000);
        vm.prank(pad);
        router.distribute(token, 1000 ether, TemplateTypes.Phase.Bonding);
        assertEq(quote.balanceOf(address(v)), 700 ether);

        address token2 = makeAddr("token2");
        vm.prank(pad);
        router.register(token2, address(quote), address(0), address(0), 10_000);
        vm.prank(pad);
        router.distribute(token2, 1000 ether, TemplateTypes.Phase.Bonding);
        assertEq(bucket.accruedQuote(address(quote)), 300 ether + 1000 ether);
    }

    function test_previewSplit_matchesDistribute() public {
        CreatorTreasuryVault v = _treasury(0);
        vm.prank(pad);
        router.register(token, address(quote), address(v), author, 2_500);

        (uint256 p, uint256 a, uint256 d, uint256 vt) = router.previewSplit(token, 777 ether);
        assertEq(p + a + d + vt, 777 ether);

        vm.prank(pad);
        router.distribute(token, 777 ether, TemplateTypes.Phase.Bonding);
        assertEq(bucket.accruedQuote(address(quote)), p);
        assertEq(router.owed(author, address(quote)), a);
        assertEq(quote.balanceOf(address(v)), vt);
    }

    // ---------------------------------------------------------------- vault can never block trades

    function test_revertingHook_stillPays() public {
        RevertingHookVault v = new RevertingHookVault(token, address(quote));
        vm.prank(pad);
        router.register(token, address(quote), address(v), address(0), 0);

        vm.prank(pad);
        router.distribute(token, 1000 ether, TemplateTypes.Phase.Bonding);
        assertEq(quote.balanceOf(address(v)), 700 ether);
    }

    function test_blockedVaultAndAuthor_goToOwed_tradeDoesNotRevert() public {
        BlacklistQuote bq = new BlacklistQuote();
        address t = makeAddr("bqToken");
        RevertingHookVault v = new RevertingHookVault(t, address(bq));
        bq.block_(address(v), true);
        bq.block_(author, true);
        bq.mint(pad, 1000 ether);
        vm.prank(pad);
        bq.approve(address(router), type(uint256).max);

        vm.prank(pad);
        router.register(t, address(bq), address(v), author, 0);
        vm.prank(pad);
        router.distribute(t, 1000 ether, TemplateTypes.Phase.Bonding);

        assertEq(router.owed(address(v), address(bq)), 700 ether);
        assertEq(router.owed(author, address(bq)), 100 ether);

        bq.block_(address(v), false);
        router.release(address(v), address(bq));
        assertEq(bq.balanceOf(address(v)), 700 ether);
    }

    // ---------------------------------------------------------------- access

    function test_onlySource_distributes() public {
        vm.prank(pad);
        router.register(token, address(quote), address(0), address(0), 10_000);
        vm.expectRevert(TaxRouterV3.OnlySource.selector);
        router.distribute(token, 1 ether, TemplateTypes.Phase.Bonding);
    }

    function test_register_rules() public {
        vm.expectRevert(TaxRouterV3.OnlyLaunchpad.selector);
        router.register(token, address(quote), address(0), address(0), 10_000);

        vm.startPrank(pad);
        vm.expectRevert(TaxRouterV3.BadDividendBps.selector);
        router.register(token, address(quote), address(0), address(0), 5_000);

        vm.expectRevert(TaxRouterV3.NotContract.selector);
        router.register(token, address(quote), makeAddr("eoa"), address(0), 5_000);

        router.register(token, address(quote), address(0), address(0), 10_000);
        vm.expectRevert(TaxRouterV3.AlreadyRegistered.selector);
        router.register(token, address(quote), address(0), address(0), 10_000);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- registry

    function test_registry_listDelist_doesNotTouchLiveRoutes() public {
        CreatorTreasuryVault v = _treasury(0);
        vm.prank(pad);
        router.register(token, address(quote), address(v), address(0), 5_000);

        vm.prank(owner);
        registry.delist(address(treasuryFactory));
        assertFalse(registry.isListed(address(treasuryFactory)));
        assertEq(registry.listedFactories().length, 0);
        assertEq(registry.factories().length, 1);

        vm.prank(pad);
        router.distribute(token, 1000 ether, TemplateTypes.Phase.Bonding);
        assertEq(quote.balanceOf(address(v)), 350 ether);

        vm.prank(owner);
        registry.list(address(treasuryFactory), author);
        assertEq(registry.authorOf(address(treasuryFactory)), author);
        assertEq(registry.factories().length, 1);
    }

    function test_registry_onlyOwner_andContractsOnly() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.list(address(treasuryFactory), address(0));

        vm.startPrank(owner);
        vm.expectRevert(TemplateRegistry.NotContract.selector);
        registry.list(makeAddr("eoa"), address(0));
        vm.expectRevert(TemplateRegistry.AlreadyListed.selector);
        registry.list(address(treasuryFactory), address(0));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- CreatorTreasury

    function test_treasury_dailyCap() public {
        CreatorTreasuryVault v = _treasury(100 ether);
        assertEq(v.beneficiary(), creator);
        quote.mintUnlimited(address(v), 500 ether);

        assertEq(v.available(), 100 ether);
        vm.startPrank(creator);
        v.withdraw(60 ether, creator);
        assertEq(v.available(), 40 ether);
        vm.expectRevert(CreatorTreasuryVault.OverDailyCap.selector);
        v.withdraw(41 ether, creator);

        vm.warp(block.timestamp + 1 days);
        assertEq(v.available(), 100 ether);
        v.withdraw(100 ether, creator);
        vm.stopPrank();
        assertEq(quote.balanceOf(creator), 160 ether);

        vm.expectRevert(CreatorTreasuryVault.OnlyBeneficiary.selector);
        v.withdraw(1, address(this));
    }

    function test_treasury_hookOnlyFromRouter() public {
        CreatorTreasuryVault v = _treasury(0);
        vm.expectRevert(CreatorTreasuryVault.OnlyRouter.selector);
        v.onTaxReceived(1, TemplateTypes.Phase.Bonding);
    }

    function test_treasuryFactory_validateAndSchema() public view {
        (bool ok,) = treasuryFactory.validate(abi.encode(address(0), uint256(0)));
        assertTrue(ok);
        (ok,) = treasuryFactory.validate(hex"01");
        assertFalse(ok);
        assertEq(treasuryFactory.dataSchema().length, 2);
        assertEq(treasuryFactory.metadata().name, "Creator Treasury");
    }

    function test_treasuryFactory_onlyLaunchpad() public {
        vm.expectRevert(CreatorTreasuryFactory.OnlyLaunchpad.selector);
        treasuryFactory.createVault(token, address(quote), creator, abi.encode(address(0), uint256(0)));
    }
}
