// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {DividendVault} from "../../src/launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {BuybackBurner} from "../../src/launchpad-v2/BuybackBurner.sol";
import {LaunchpadV2} from "../../src/launchpad-v2/LaunchpadV2.sol";
import {PostGradTaxHandler} from "../../src/launchpad-v2/PostGradTaxHandler.sol";
import {MigratorV2} from "../../src/launchpad-v2/MigratorV2.sol";
import {TaxLaunchToken} from "../../src/launchpad-v2/TaxLaunchToken.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {MockGANG} from "../../src/launchpad-v2/mocks/MockGANG.sol";
import {MockPairFactory} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";

contract MockAgentIdR is IERC721 {
    mapping(address => uint256) public bal;
    function setBalance(address a, uint256 b) external { bal[a] = b; }
    function balanceOf(address a) external view returns (uint256) { return bal[a]; }
    function ownerOf(uint256) external pure returns (address) { revert(); }
    function safeTransferFrom(address, address, uint256, bytes calldata) external pure { revert(); }
    function safeTransferFrom(address, address, uint256) external pure { revert(); }
    function transferFrom(address, address, uint256) external pure { revert(); }
    function approve(address, uint256) external pure { revert(); }
    function setApprovalForAll(address, bool) external pure { revert(); }
    function getApproved(uint256) external pure returns (address) { return address(0); }
    function isApprovedForAll(address, address) external pure returns (bool) { return false; }
    function supportsInterface(bytes4) external pure returns (bool) { return false; }
}

/// @notice Regression tests for two audit findings (2026-10-25):
///         R1: create() must fail fast on GradAmtTooSmall BEFORE deploying the token
///             (previously burned ~660k gas — full ERC-20 deploy + dividend wiring — then reverted).
///         R2: DividendVault.depositReward must revert on totalShares == 0
///             (previously accepted the reward into accounting limbo: accRewardPerShare never
///              accrued, so the funds were unclaimable forever).
contract RegressTest is Test {
    QuoteRegistry internal registry;
    DividendVault internal vault;
    PlatformFeeBucket internal bucket;
    BuybackBurner internal burner;
    LaunchpadV2 internal pad;
    PostGradTaxHandler internal taxHandler;
    MigratorV2 internal migrator;
    MockPairFactory internal factory;
    MockSPCXB internal quoteTok;
    MockSPCXB internal wbnb;
    MockGANG internal gang;
    MockAgentIdR internal agents;

    address internal owner = makeAddr("owner");
    address internal feeVault = makeAddr("feeVault");
    address internal agent = makeAddr("agent");
    address internal holder = makeAddr("holder");

    function setUp() public {
        quoteTok = new MockSPCXB();
        wbnb = new MockSPCXB();
        gang = new MockGANG();
        factory = new MockPairFactory();
        agents = new MockAgentIdR();

        registry = new QuoteRegistry(owner);
        vault = new DividendVault(owner);
        burner = new BuybackBurner(owner);
        bucket = new PlatformFeeBucket(owner, feeVault);
        taxHandler = new PostGradTaxHandler(owner, address(vault), address(bucket));
        pad = new LaunchpadV2(
            owner, address(registry), address(vault), address(bucket), address(taxHandler), address(wbnb), address(factory)
        );
        migrator = new MigratorV2(address(factory), address(pad));

        vm.startPrank(owner);
        registry.setQuote(address(quoteTok), true, 15 ether);
        vault.setLaunchpad(address(pad));
        vault.setOperator(address(taxHandler), true);
        bucket.setBurner(address(burner));
        bucket.setLaunchpad(address(pad));
        bucket.setOperator(address(taxHandler), true);
        pad.setMigrator(address(migrator));
        pad.setAgentGate(true, address(agents));
        vm.stopPrank();

        agents.setBalance(agent, 1);
        quoteTok.mintUnlimited(agent, 500 ether);
        quoteTok.mintUnlimited(address(this), 1_000 ether);
    }

    // ------------------------------------------------------------------ R1
    /// @dev GradAmtTooSmall fires before the token contract exists: a create that reverts on a
    ///      too-small graduation amount must cost registration-level gas, not deployment-level.
    function test_R1_create_gradAmtTooSmall_failsBeforeDeployment() public {
        vm.prank(owner);
        registry.setQuote(address(quoteTok), true, 500_000); // > 0 but < MIN_GRAD_AMT (1e6)

        uint256 gasBefore = gasleft();
        vm.prank(agent);
        vm.expectRevert(LaunchpadV2.GradAmtTooSmall.selector);
        pad.create("T", "T", "", false, address(quoteTok), address(0));
        uint256 spent = gasBefore - gasleft();

        // Pre-fix this measured 658,880 (full LaunchToken deploy + mint inside the reverted call).
        // A fail-fast check costs registration-level gas only.
        assertLt(spent, 200_000, "create must revert before deploying the token");
        assertEq(pad.tokenCount(), 0);
    }

    // ------------------------------------------------------------------ R2
    function test_R2_depositReward_zeroShares_reverts() public {
        vm.prank(agent);
        address token = pad.create("D", "D", "", true, address(quoteTok), address(0));
        assertEq(vault.totalShares(token), 0);

        vm.prank(owner);
        vault.setOperator(address(this), true);
        quoteTok.approve(address(vault), 100 ether);

        vm.expectRevert(DividendVault.NoShares.selector);
        vault.depositReward(token, 100 ether);

        // nothing entered accounting limbo: vault holds nothing, accrual unchanged
        assertEq(quoteTok.balanceOf(address(vault)), 0);
        assertEq(vault.accRewardPerShare(token), 0);
    }

    function test_R2_depositReward_afterShare_accrues() public {
        vm.prank(agent);
        address token = pad.create("D2", "D2", "", true, address(quoteTok), address(0));

        vm.prank(address(pad));
        vault.setShare(token, holder, 50_000 ether);
        assertEq(vault.totalShares(token), 50_000 ether);

        vm.prank(owner);
        vault.setOperator(address(this), true);
        quoteTok.approve(address(vault), 50 ether);
        vault.depositReward(token, 50 ether);

        assertEq(vault.accRewardPerShare(token), (50 ether * 1e18) / 50_000 ether);
        vm.prank(holder);
        assertEq(vault.claim(token), 50 ether);
    }
}
