// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployScriptsForkTest} from "../audit5c/DeployScriptsFork.t.sol";
import {DeployLaunchpadV3} from "../../../script/DeployLaunchpadV3.s.sol";
import {DeployFairMint} from "../../../script/DeployFairMint.s.sol";
import {SharedPlatform} from "../../../script/SharedPlatform.sol";
import {QuoteRegistry} from "../../../src/launchpad-v2/QuoteRegistry.sol";
import {SharedPlatformFeeBucket} from "../../../src/common/SharedPlatformFeeBucket.sol";
import {PlatformFeeBucket} from "../../../src/launchpad-v2/PlatformFeeBucket.sol";
import {GangTaxHandler} from "../../../src/gang/GangTaxHandler.sol";
import {LaunchpadV3MainnetRefs as M} from "../../../config/LaunchpadV3DeployRefs.sol";

/// @notice Review of the audit 5 fixes (AUDIT-BRIEF §18), deploy scripts on a BSC mainnet fork (no broadcast): the
///         peer core pins the registry and bucket, and BURNER / FEE_VAULT are used by the deploy, not only checked.
///         Process-wide env (vm.setEnv): run with `--threads 1`.
contract DeployReviewForkTest is DeployScriptsForkTest {
    function _foreignBucket() internal returns (SharedPlatformFeeBucket b2) {
        vm.startPrank(deployer);
        b2 = new SharedPlatformFeeBucket(deployer, PlatformFeeBucket(M.V2_PLATFORM_BUCKET).feeVault());
        b2.setBurner(address(PlatformFeeBucket(M.V2_PLATFORM_BUCKET).burner()));
        b2.setKeeper(M.KEEPER);
        vm.stopPrank();
    }

    /// The review PoC: reuse with a foreign QUOTE_REGISTRY + PLATFORM_BUCKET used to pass every check.
    function test_review_deploy_peerRegistryMismatchRefused() public {
        if (!forked) return;
        DeployLaunchpadV3.Stack memory a = _deployV3();
        _reuse(a);
        vm.prank(deployer);
        QuoteRegistry reg2 = new QuoteRegistry(deployer);
        SharedPlatformFeeBucket b2 = _foreignBucket();
        vm.setEnv("QUOTE_REGISTRY", vm.toString(address(reg2)));
        vm.setEnv("PLATFORM_BUCKET", vm.toString(address(b2)));
        DeployFairMint f = new DeployFairMint();
        vm.expectRevert(abi.encodeWithSelector(SharedPlatform.WiringCheck.selector, "peer core registry"));
        f.run(); // the peer checks run after the broadcast ends
        _clear();
    }

    function test_review_deploy_peerBucketMismatchRefused() public {
        if (!forked) return;
        DeployLaunchpadV3.Stack memory a = _deployV3();
        _reuse(a);
        SharedPlatformFeeBucket b2 = _foreignBucket();
        vm.setEnv("PLATFORM_BUCKET", vm.toString(address(b2)));
        DeployFairMint f = new DeployFairMint();
        vm.expectRevert(abi.encodeWithSelector(SharedPlatform.WiringCheck.selector, "peer core bucket"));
        f.run(); // the peer checks run after the broadcast ends
        _clear();
    }

    /// BURNER / FEE_VAULT overrides go into the new bucket (the review PoC: BURNER used to be check-only, so the
    /// deploy wired the V2 burner and then failed its own check); the reuse run checks the same values.
    function test_review_deploy_burnerAndFeeVaultOverridesUsed() public {
        if (!forked) return;
        address burner = address(0x1111);
        address vault_ = address(0x2222);
        vm.setEnv("BURNER", vm.toString(burner));
        vm.setEnv("FEE_VAULT", vm.toString(vault_));
        DeployLaunchpadV3.Stack memory a = _deployV3();
        assertEq(address(SharedPlatformFeeBucket(a.bucket).burner()), burner);
        assertEq(SharedPlatformFeeBucket(a.bucket).feeVault(), vault_);
        _reuse(a);
        DeployFairMint.Stack memory b = new DeployFairMint().run();
        assertEq(b.bucket, a.bucket);
        // the reuse run with the defaults instead: its check sees the bucket's burner isn't the V2 one
        vm.setEnv("BURNER", vm.toString(address(0)));
        DeployFairMint f = new DeployFairMint();
        vm.expectRevert(abi.encodeWithSelector(SharedPlatform.WiringCheck.selector, "bucket burner"));
        f.run();
        _clear();
    }

    /// Defaults (no override): the V2 bucket's burner and fee vault; keepers set through the one-time setKeeper.
    function test_review_deploy_defaultsAndKeeperFlags() public {
        if (!forked) return;
        DeployLaunchpadV3.Stack memory a = _deployV3();
        SharedPlatformFeeBucket pb = SharedPlatformFeeBucket(a.bucket);
        assertEq(address(pb.burner()), address(PlatformFeeBucket(M.V2_PLATFORM_BUCKET).burner()));
        assertEq(pb.feeVault(), PlatformFeeBucket(M.V2_PLATFORM_BUCKET).feeVault());
        assertTrue(pb.keeperSet());
        assertTrue(GangTaxHandler(a.handler).keeperSet());
        _reuse(a);
        DeployFairMint.Stack memory b = new DeployFairMint().run();
        _clear();
        assertTrue(GangTaxHandler(b.handler).keeperSet());
    }
}
