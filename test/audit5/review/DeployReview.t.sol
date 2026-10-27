// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployScriptsForkTest} from "../audit5c/DeployScriptsFork.t.sol";
import {DeployGang} from "../../../script/DeployGang.s.sol";
import {GangMainnetRefs as M} from "../../../config/GangDeployRefs.sol";
import {SharedPlatformFeeBucket} from "../../../src/common/SharedPlatformFeeBucket.sol";
import {PlatformFeeBucket} from "../../../src/launchpad-v2/PlatformFeeBucket.sol";
import {IGangTaxHandlerOps} from "../../../src/gang/interfaces/IGangTaxHandlerOps.sol";

/// @notice Review of the audit 5 deploy fixes (AUDIT-BRIEF §18) on the merged single-script deploy, BSC mainnet fork
///         (no broadcast): BURNER / FEE_VAULT are used by the deploy, not only checked (R5-5); the defaults copy the
///         V2 bucket; the keepers are set through the one-time setKeeper (R5-4). Process-wide env: `--threads 1`.
contract DeployReviewForkTest is DeployScriptsForkTest {
    /// BURNER / FEE_VAULT overrides go into the new bucket (the review PoC: BURNER used to be check-only, so the deploy
    /// wired the V2 burner and then failed its own check); a re-run with the defaults instead is caught by its check.
    function test_review_deploy_burnerAndFeeVaultOverridesUsed() public {
        if (!forked) return;
        address burner = address(0x1111);
        address feeVault = address(0x2222);
        vm.setEnv("BURNER", vm.toString(burner));
        vm.setEnv("FEE_VAULT", vm.toString(feeVault));
        DeployGang.Stack memory s = _deploy();
        assertEq(address(SharedPlatformFeeBucket(s.bucket).burner()), burner);
        assertEq(SharedPlatformFeeBucket(s.bucket).feeVault(), feeVault);
        // a re-run with the same overrides passes its check
        _rerunEnv(s);
        new DeployGang().run();
        // the re-run with the defaults: its check sees the bucket's burner isn't the V2 one
        vm.setEnv("BURNER", vm.toString(address(0)));
        DeployGang d = new DeployGang();
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "bucket burner"));
        d.run(); // the check runs after the broadcast ends
        vm.setEnv("BURNER", vm.toString(burner));
        vm.setEnv("FEE_VAULT", vm.toString(address(0)));
        d = new DeployGang();
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "bucket feeVault"));
        d.run();
        _clear();
    }

    /// Defaults (no override): the V2 bucket's burner and fee vault; keepers set through the one-time setKeeper.
    function test_review_deploy_defaultsAndKeeperFlags() public {
        if (!forked) return;
        DeployGang.Stack memory s = _deploy();
        SharedPlatformFeeBucket pb = SharedPlatformFeeBucket(s.bucket);
        assertEq(address(pb.burner()), address(PlatformFeeBucket(M.V2_PLATFORM_BUCKET).burner()));
        assertEq(pb.feeVault(), PlatformFeeBucket(M.V2_PLATFORM_BUCKET).feeVault());
        assertTrue(address(pb.burner()) != address(0), "mainnet bucket has a burner");
        assertEq(pb.keeper(), M.KEEPER);
        assertTrue(pb.keeperSet());
        IGangTaxHandlerOps hd = IGangTaxHandlerOps(s.handler);
        assertEq(hd.keeper(), M.KEEPER);
        assertTrue(hd.keeperSet());
        // R5-4: the instant path is used up on both
        vm.startPrank(deployer);
        vm.expectRevert();
        pb.setKeeper(address(0x1));
        vm.expectRevert();
        hd.setKeeper(address(0x1));
        vm.stopPrank();
    }

    /// KEEPER (with the explicit KEEPER_OVERRIDE_OK=true on mainnet) overrides the default on both the handler and
    /// the bucket.
    function test_review_deploy_keeperOverride() public {
        if (!forked) return;
        address k = address(0x3333);
        vm.setEnv("KEEPER", vm.toString(k));
        vm.setEnv("KEEPER_OVERRIDE_OK", "true");
        DeployGang.Stack memory s = _deploy();
        _clear();
        assertEq(SharedPlatformFeeBucket(s.bucket).keeper(), k);
        assertEq(IGangTaxHandlerOps(s.handler).keeper(), k);
    }

    /// RECIPIENT on mainnet is listed at deploy (else the owner lists the partner later).
    function test_review_deploy_recipientListed() public {
        if (!forked) return;
        address r = address(0x4444);
        vm.setEnv("RECIPIENT", vm.toString(r));
        vm.setEnv("RECIPIENT_LABEL", "partner");
        DeployGang.Stack memory s = _deploy();
        _clear();
        assertEq(s.recipient, r);
        assertTrue(IGangTaxHandlerOps(s.handler).isListed(r));
    }
}
