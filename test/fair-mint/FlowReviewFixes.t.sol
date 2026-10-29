// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GangLaunchpad as FairMintPad} from "../../src/gang/GangLaunchpad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {PostGradHandlerBase} from "../../src/common/PostGradHandlerBase.sol";
import {FairMintTest} from "./FairMint.t.sol";

/// @notice Flow review fixes: withdraw floor (F3), one-shot vault operator (F4a), per-token share floor (F4c),
///         delayed DEX router change (F4b).
contract FlowReviewFixesTest is FairMintTest {
    /// @dev F3: a 10-share mint landing first restarts the stale clock; the seller's minPayout refuses the 1% fee.
    function test_F3_withdrawFloorRefusesARestartedFee() public {
        IGangLaunchpad.MintConfig memory c = _cfg(); // exit fee 1%
        vm.prank(dev);
        address t = pad.create("Stale", "STL", "", "", address(0), address(0), c, 1);
        address victim = _minter(0);
        vm.prank(victim);
        pad.mint(t, 50, 1); // sold 51: clock restarts, mark 51
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(pad.exitFeeBpsOf(t), 0, "stale");
        (uint256 expected,) = pad.previewWithdraw(t, victim, 50);
        assertEq(expected, 50 * SHARE_PRICE, "full principal while stale");

        vm.prank(_minter(1));
        pad.mint(t, 10, 1); // 61 = 51 + STALE_STEP: the fee is back
        vm.prank(victim);
        vm.expectRevert(IGangLaunchpad.Slippage.selector);
        pad.withdraw(t, 50, expected);

        vm.prank(victim);
        assertEq(pad.withdraw(t, 50, expected * 99 / 100), expected * 99 / 100, "accepted the fee knowingly");
    }

    /// @dev F4a: the pad's operator is bound once; the owner can't rebind, unbind or add a second one.
    function test_F4a_operatorBoundOnce() public {
        assertEq(vault.operatorFor(address(pad)), address(handler));
        address rogue = makeAddr("rogue");
        vm.startPrank(owner);
        vm.expectRevert(SharedDividendVault.OperatorAlreadyBound.selector);
        vault.setOperator(rogue, address(pad));
        vm.expectRevert(SharedDividendVault.ZeroAddress.selector);
        vault.setOperator(address(handler), address(0));
        address otherCore = makeAddr("otherCore");
        vault.setLaunchpad(otherCore, true);
        vm.expectRevert(SharedDividendVault.OperatorAlreadyBound.selector);
        vault.setOperator(address(handler), otherCore);
        vm.stopPrank();
        assertEq(vault.operatorOf(address(handler)), address(pad));

        // the rogue cannot write shares of the pad's tokens
        address t = _create();
        vm.prank(rogue);
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        vault.setShare(t, rogue, 1_000_000 ether);
    }

    /// @dev F4c: raising the core's floor after create no longer zeroes existing holders.
    function test_F4c_floorSnapshottedPerToken() public {
        address t = _create();
        _fill(t);
        address m = _minter(0);
        uint256 share = vault.shares(t, m);
        assertGt(share, 0);
        uint256 floor = vault.minimumShareBalanceFor(t);

        vm.prank(owner);
        vault.setMinimumShareBalance(address(pad), 100_000_000 ether);
        handler.syncShares(t, m, address(0));
        assertEq(vault.shares(t, m), share, "existing token keeps its floor");
        assertEq(vault.minimumShareBalanceFor(t), floor);
        assertEq(vault.tokenMinimumShareBalance(t), floor);
    }

    /// @dev F4b: a router change waits DEX_ROUTER_DELAY; it can also go back to the direct pair (0).
    function test_F4b_dexRouterChangeIsDelayed() public {
        assertEq(address(handler.dexRouter()), address(0), "deployed selling straight into the pair");
        address r = makeAddr("router");
        (bool ok,) = address(handler).call(abi.encodeWithSignature("setDexRouter(address)", r));
        assertFalse(ok, "no instant setter");

        vm.prank(stranger);
        vm.expectRevert();
        handler.proposeDexRouter(r);

        vm.startPrank(owner);
        vm.expectRevert(PostGradHandlerBase.NoProposal.selector);
        handler.acceptDexRouter();
        handler.proposeDexRouter(r);
        vm.expectRevert(PostGradHandlerBase.TooEarly.selector);
        handler.acceptDexRouter();
        vm.warp(vm.getBlockTimestamp() + handler.DEX_ROUTER_DELAY() - 1);
        vm.expectRevert(PostGradHandlerBase.TooEarly.selector);
        handler.acceptDexRouter();
        vm.warp(vm.getBlockTimestamp() + 1);
        handler.acceptDexRouter();
        assertEq(address(handler.dexRouter()), r);

        // back to the direct pair, and a cancelled proposal changes nothing
        handler.proposeDexRouter(address(0));
        vm.warp(vm.getBlockTimestamp() + handler.DEX_ROUTER_DELAY());
        handler.acceptDexRouter();
        assertEq(address(handler.dexRouter()), address(0));
        handler.proposeDexRouter(r);
        handler.cancelDexRouter();
        vm.warp(vm.getBlockTimestamp() + handler.DEX_ROUTER_DELAY());
        vm.expectRevert(PostGradHandlerBase.NoProposal.selector);
        handler.acceptDexRouter();
        vm.stopPrank();
        assertEq(address(handler.dexRouter()), address(0));
    }
}
