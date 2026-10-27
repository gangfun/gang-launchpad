// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SharedDividendVault} from "../../../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../../../src/common/SharedPlatformFeeBucket.sol";
import {PostGradHandlerBase} from "../../../src/common/PostGradHandlerBase.sol";
import {GangTaxHandler} from "../../../src/gang/GangTaxHandler.sol";

/// @notice Review of the audit 5 fixes (§18): the keeper's set-once flag and the EIP-7702 wallet check, without a fork.
contract ReviewUnitTest is Test {
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address evil = makeAddr("evil");

    SharedDividendVault vault;
    SharedPlatformFeeBucket bucket;
    GangTaxHandler v3Handler;
    GangTaxHandler fairHandler;

    function setUp() public {
        vault = new SharedDividendVault(owner);
        bucket = new SharedPlatformFeeBucket(owner, makeAddr("feeVault"));
        v3Handler = new GangTaxHandler(owner, address(vault), address(bucket), address(0));
        fairHandler = new GangTaxHandler(owner, address(vault), address(bucket), address(0));
    }

    // ------------------------------------------------------------------ keeper: set once, then only the delay
    function _handlers() internal view returns (PostGradHandlerBase[2] memory hs) {
        hs[0] = PostGradHandlerBase(address(v3Handler));
        hs[1] = PostGradHandlerBase(address(fairHandler));
    }

    /// The review PoC: propose 0 → 48h → accept, then `setKeeper` used to be instant again (keeper == 0).
    function test_review_handlerKeeperZeroNoLongerReopensSetKeeper() public {
        PostGradHandlerBase[2] memory hs = _handlers();
        for (uint256 i; i < 2; i++) {
            PostGradHandlerBase h = hs[i];
            vm.startPrank(owner);
            h.setKeeper(keeper);
            assertTrue(h.keeperSet());
            vm.expectRevert(PostGradHandlerBase.KeeperAlreadySet.selector);
            h.setKeeper(evil);
            h.proposeKeeper(address(0));
            vm.warp(block.timestamp + h.KEEPER_DELAY());
            h.acceptKeeper();
            assertEq(h.keeper(), address(0));
            vm.expectRevert(PostGradHandlerBase.KeeperAlreadySet.selector);
            h.setKeeper(evil);
            // the only way to a new keeper is the delay again
            h.proposeKeeper(evil);
            vm.expectRevert(PostGradHandlerBase.TooEarly.selector);
            h.acceptKeeper();
            vm.warp(block.timestamp + h.KEEPER_DELAY());
            h.acceptKeeper();
            vm.stopPrank();
            assertEq(h.keeper(), evil);
        }
    }

    /// A handler whose first keeper came through the delay (no `setKeeper` ever) can't use `setKeeper` afterwards.
    function test_review_handlerAcceptedKeeperClosesSetKeeper() public {
        PostGradHandlerBase[2] memory hs = _handlers();
        for (uint256 i; i < 2; i++) {
            PostGradHandlerBase h = hs[i];
            vm.startPrank(owner);
            h.proposeKeeper(keeper);
            vm.warp(block.timestamp + h.KEEPER_DELAY());
            h.acceptKeeper();
            vm.expectRevert(PostGradHandlerBase.KeeperAlreadySet.selector);
            h.setKeeper(evil);
            vm.stopPrank();
            assertEq(h.keeper(), keeper);
        }
    }

    /// Setting the first keeper to 0 also uses up `setKeeper`.
    function test_review_handlerSetKeeperZeroUsesItUp() public {
        vm.startPrank(owner);
        v3Handler.setKeeper(address(0));
        vm.expectRevert(PostGradHandlerBase.KeeperAlreadySet.selector);
        v3Handler.setKeeper(evil);
        vm.stopPrank();
    }

    function test_review_bucketKeeperZeroNoLongerReopensSetKeeper() public {
        vm.startPrank(owner);
        bucket.setKeeper(keeper);
        assertTrue(bucket.keeperSet());
        vm.expectRevert(SharedPlatformFeeBucket.KeeperAlreadySet.selector);
        bucket.setKeeper(evil);
        bucket.proposeKeeper(address(0));
        vm.warp(block.timestamp + bucket.KEEPER_DELAY());
        bucket.acceptKeeper();
        assertEq(bucket.keeper(), address(0));
        vm.expectRevert(SharedPlatformFeeBucket.KeeperAlreadySet.selector);
        bucket.setKeeper(evil);
        vm.stopPrank();
    }

    function test_review_bucketAcceptedKeeperClosesSetKeeper() public {
        vm.startPrank(owner);
        bucket.proposeKeeper(keeper);
        vm.warp(block.timestamp + bucket.KEEPER_DELAY());
        bucket.acceptKeeper();
        vm.expectRevert(SharedPlatformFeeBucket.KeeperAlreadySet.selector);
        bucket.setKeeper(evil);
        vm.stopPrank();
        assertEq(bucket.keeper(), keeper);
    }

    function test_review_keeperSettersOwnerOnly() public {
        vm.startPrank(evil);
        vm.expectRevert();
        v3Handler.setKeeper(evil);
        vm.expectRevert();
        bucket.setKeeper(evil);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ EIP-7702: a delegated wallet is a wallet
    function test_review_eip7702DelegatedWalletCantBeExcluded() public {
        address wallet = makeAddr("wallet");
        address impl = makeAddr("impl");
        vm.etch(impl, hex"6000");
        vm.etch(wallet, abi.encodePacked(hex"ef0100", impl)); // the 23-byte delegation designator
        assertEq(wallet.code.length, 23);
        vm.prank(owner);
        vm.expectRevert(SharedDividendVault.NotAContract.selector);
        vault.setExcluded(wallet, true);
        assertFalse(vault.excluded(wallet));
        // un-excluding stays free
        vm.prank(owner);
        vault.setExcluded(wallet, false);
    }

    function test_review_plainWalletStillRefused_contractsStillAllowed() public {
        vm.prank(owner);
        vm.expectRevert(SharedDividendVault.NotAContract.selector);
        vault.setExcluded(makeAddr("eoa"), true);

        // 23 bytes of ordinary code (not 0xef0100…) is a contract
        address c23 = makeAddr("c23");
        vm.etch(c23, abi.encodePacked(hex"600000", bytes20(uint160(1))));
        // (0xef-prefixed code of any other shape can't exist: EIP-3541 forbids deploying it, and an etch refuses it)
        address[1] memory cs = [c23];
        vm.startPrank(owner);
        for (uint256 i; i < cs.length; i++) {
            vault.setExcluded(cs[i], true);
            assertTrue(vault.excluded(cs[i]));
        }
        vault.setExcluded(address(bucket), true);
        vm.stopPrank();
    }
}
