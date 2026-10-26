// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MigratorV2} from "../../src/launchpad-v2/MigratorV2.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {FairMintPad} from "../../src/fair-mint/FairMintPad.sol";
import {FairTokenDeployer} from "../../src/fair-mint/FairToken.sol";
import {FairMintTest} from "./FairMint.t.sol";

contract SixDecimalQuote is ERC20("Six", "SIX") {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @dev Sends tokens with a chosen gas limit (the receiver-side stale-share attempt).
contract Gifter {
    function gift(address token, address to, uint256 amount, uint256 g) external returns (bool ok) {
        (ok,) = token.call{gas: g}(abi.encodeCall(IERC20.transfer, (to, amount)));
    }
}

/// @notice Regressions for the 2026-10-26 internal audit (docs/AUDIT-BRIEF-2026-10-26.md §10).
contract FairMintAuditTest is FairMintTest {
    /// @dev A-2: ungated, a listed router could mint to the future pair before launch and take the launch LP.
    function test_audit_mintForNeedsGate() public {
        vm.startPrank(owner);
        pad.setAgentGate(false, address(0));
        pad.setRouter(address(this), true);
        vm.stopPrank();
        address t = _create(); // ungated sale (gate snapshot = 0)

        wbnb.mintUnlimited(address(this), 1 ether);
        wbnb.approve(address(pad), type(uint256).max);
        vm.expectRevert(FairMintPad.RouterNeedsGate.selector);
        pad.mintFor(makeAddr("pair"), t, 1, 1);

        // the direct path still works ungated: msg.sender is the minter
        vm.prank(stranger);
        wbnb.approve(address(pad), type(uint256).max);
        wbnb.mintUnlimited(stranger, 1 ether);
        vm.prank(stranger);
        assertEq(pad.mint(t, 1, 1), 1);
    }

    /// @dev A-4 (refund gone, withdraw is the only exit): a vault whose owner re-pointed its launchpad refuses the pad's
    ///      writes; selling back must still work. The stale vault share is then cleared by the handler after launch.
    function test_audit_withdrawIndependentOfVault() public {
        address t = _create();
        address m = _minter(150); // not one of _fill's minters, so its baseline stays 0 after launch
        vm.prank(m);
        pad.mint(t, 100, 1);
        uint256 before = wbnb.balanceOf(m);

        vm.prank(owner);
        vault.setLaunchpad(makeAddr("elsewhere"));
        vm.expectEmit(true, true, false, true, address(pad));
        emit FairMintPad.ShareWriteFailed(t, m, 0);
        vm.prank(m);
        uint256 got = pad.withdraw(t, 100);
        assertEq(got, 100 * SHARE_PRICE * 99 / 100, "principal minus the 1% exit fee");
        assertEq(wbnb.balanceOf(m), before + got);
        assertEq(vault.shares(t, m), 100 * TPS, "the vault refused: share left as is");

        // vault fixed; the sale fills and launches; m's first touch after launch zeroes the share (baseline 0)
        vm.prank(owner);
        vault.setLaunchpad(address(pad));
        _fill(t);
        handler.syncShares(t, m, address(0));
        assertEq(vault.shares(t, m), 0, "zero-baseline share cleared by the handler");
    }

    /// @dev R3-1: 1-share mints can't keep the 7-day exit-fee waiver off; only shares that stay sold restart it.
    function test_audit_staleClockNeedsProgress() public {
        address t = _create(); // dev 1 share: the creator's mint starts the clock
        address v = _minter(0);
        vm.prank(v);
        pad.mint(t, 100, 1); // 101 ≥ 1 + 10: restart, markSold 101
        address g = _minter(1);
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(vm.getBlockTimestamp() + 7 days - 1);
            vm.prank(g);
            pad.mint(t, 1, 1);
            vm.prank(g);
            pad.withdraw(t, 1); // churn: sold never passes 111
        }
        assertEq(pad.exitFeeBpsOf(t), 0, "griefer's 1-share churn did not restart the clock");
        vm.prank(v);
        assertEq(pad.withdraw(t, 100), 100 * SHARE_PRICE, "victim leaves free");
    }

    /// @dev R3-2: a bucket that refuses the pad can't freeze withdraws; the fee is owed and flushed once it accepts.
    function test_audit_withdrawIndependentOfFeeSink() public {
        address t = _create();
        address m = _minter(0);
        vm.prank(m);
        pad.mint(t, 100, 1);
        uint256 principal = 100 * SHARE_PRICE;
        uint256 fee = principal / 100;

        vm.prank(owner);
        bucket.setLaunchpad(address(1)); // the pad is neither launchpad nor operator now
        vm.prank(m);
        assertEq(pad.withdraw(t, 100), principal - fee, "same payout as with a working bucket");
        assertEq(pad.owedFee(address(wbnb)), fee);
        assertEq(wbnb.allowance(address(pad), address(bucket)), 0, "no allowance left behind");
        vm.expectRevert(PlatformFeeBucket.OnlyLaunchpad.selector);
        pad.flushFees(address(wbnb));

        vm.prank(owner);
        bucket.setLaunchpad(address(pad));
        uint256 accrued = bucket.accruedQuote(address(wbnb));
        vm.prank(stranger);
        assertEq(pad.flushFees(address(wbnb)), fee);
        assertEq(pad.owedFee(address(wbnb)), 0);
        assertEq(bucket.accruedQuote(address(wbnb)), accrued + fee);
        vm.expectRevert(FairMintPad.ZeroAmount.selector);
        pad.flushFees(address(wbnb));
    }

    /// @dev Quote rules (2026-10-27, V2 pricing kept): WBNB or any 18-decimal ERC-20; no fixed rate → a reference pool is
    ///      required (priced in test_create_refPoolAgainstWbnb / test_create_refPoolViaBridge). A-3: low decimals and
    ///      non-tokens are refused even with a fixed rate.
    function test_audit_quoteRules() public {
        MockSPCXB unlisted = new MockSPCXB();
        vm.prank(dev);
        vm.expectRevert(FairMintPad.RefPoolRequired.selector);
        pad.create("Q", "Q", "", "", address(unlisted), address(0), _cfg(), 1);

        SixDecimalQuote six = new SixDecimalQuote();
        vm.prank(owner);
        registry.setQuote(address(six), true, 9_000e6);
        vm.prank(dev);
        vm.expectRevert(FairMintPad.QuoteNotAllowed.selector);
        pad.create("S", "S", "", "", address(six), address(0), _cfg(), 1);

        vm.prank(dev);
        vm.expectRevert(FairMintPad.QuoteNotAllowed.selector);
        pad.create("E", "E", "", "", makeAddr("notAToken"), address(0), _cfg(), 1);
    }

    /// @dev Low: a migrator bound to another pad would make every launch revert, and setMigrator is one-shot.
    function test_audit_setMigratorChecksPad() public {
        FairMintPad fresh = new FairMintPad(
            owner,
            address(registry),
            address(vault),
            address(bucket),
            address(handler),
            address(new FairTokenDeployer()),
            address(wbnb),
            address(factory)
        );
        vm.prank(owner);
        vm.expectRevert(FairMintPad.WrongMigrator.selector);
        fresh.setMigrator(address(migrator)); // bound to `pad`
        MigratorV2 own = new MigratorV2(address(factory), address(fresh));
        vm.prank(owner);
        fresh.setMigrator(address(own));
    }

    /// @dev A-5: a sender picking the gas so the receiver's setShare runs out of gas inside the handler's try must not
    ///      get a successful transfer with a stale share — the handler now reverts on a starved call.
    function test_audit_receiverGasCannotLeaveStaleShare() public {
        address t = _create();
        _fill(t);
        address v = _minter(8);
        _sell(t, v, 40 * TPS); // v keeps 60% of its base, still eligible
        assertEq(vault.shares(t, v), 60 * TPS);
        _buy(t, buyer, 3 ether);
        vm.prank(owner);
        handler.process(t, 1); // v has unharvested rewards → setShare(v) does a real harvest

        Gifter gifter = new Gifter();
        vm.prank(buyer);
        IERC20(t).transfer(address(gifter), 30 * TPS);

        uint256 lo = 20_000;
        uint256 hi = 1_000_000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap0 = vm.snapshotState();
            bool okMid = gifter.gift(t, v, 30 * TPS, mid);
            vm.revertToState(snap0);
            if (okMid) hi = mid;
            else lo = mid;
        }
        // before the fix: ~3,000 gas values here succeeded with v's share stuck at 60
        uint256 stale;
        for (uint256 g = hi; g < hi + 3_000; g += 3) {
            uint256 snap = vm.snapshotState();
            bool ok = gifter.gift(t, v, 30 * TPS, g);
            if (ok && vault.shares(t, v) != 90 * TPS) stale++;
            vm.revertToState(snap);
        }
        assertEq(stale, 0, "no successful transfer leaves a stale share");
        assertTrue(gifter.gift(t, v, 30 * TPS, hi));
        assertEq(vault.shares(t, v), 90 * TPS);
    }

    /// @dev K-7 for 打新 still holds: a vault that refuses writes (operator revoked) does not freeze trading.
    function test_audit_vaultFailureStillSwallowed() public {
        address t = _create();
        _fill(t);
        address v = _minter(8);
        vm.prank(owner);
        vault.setOperator(address(handler), false);
        _sell(t, v, 10 * TPS); // the handler's setShare reverts (not out of gas) → swallowed, the sell goes through
        assertEq(IERC20(t).balanceOf(v), 90 * TPS);
        assertEq(vault.shares(t, v), 100 * TPS, "stale until the vault accepts writes again");
    }
}
