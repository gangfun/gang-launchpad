// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {NoReceive, SelfDestructor} from "./mocks/NoReceive.sol";

contract LaunchpadTest is BaseTest {
    // ------------------------------------------------------------ create
    function test_create_mintsSupplyToLaunchpad() public view {
        assertEq(tok.totalSupply(), 1_000_000_000 ether);
        assertEq(tok.balanceOf(address(pad)), 1_000_000_000 ether);
        assertTrue(tok.locked());
        assertEq(pad.tokenCount(), 1);
    }

    function test_create_noFee_devOnly() public {
        uint256 before = human.balance;
        vm.prank(human);
        vm.expectRevert(Launchpad.NotDev.selector);
        pad.create("Nope", "NO");

        vm.prank(owner);
        pad.setDev(human, true);
        vm.prank(human);
        pad.create("B", "B");
        assertEq(human.balance, before);
    }

    function test_create_requiresMigrator() public {
        Launchpad p2 = new Launchpad(owner, vault, address(agentId));
        vm.expectRevert(Launchpad.MigratorNotSet.selector);
        p2.create("X", "X");
    }

    // ------------------------------------------------------------ curve math
    function test_firstBuy_pointZeroOneBnb() public {
        uint256 out = _buy(alice, 0.01 ether);
        assertApproxEqRel(out, 1_581_651.25 ether, 1e12);
        assertEq(_realBnb(), 0.0099 ether);
        assertEq(pad.accruedFees(), 0.0001 ether);
        assertEq(pad.totalRealBnb(), 0.0099 ether);
    }

    function test_openingPrice() public view {
        assertApproxEqAbs(pad.spotPrice(address(tok)), 6.25e9, 1);
    }

    function test_priceMonotonic() public {
        uint256 p0 = pad.spotPrice(address(tok));
        _buy(alice, 0.01 ether);
        uint256 p1 = pad.spotPrice(address(tok));
        _buy(alice, 0.01 ether);
        uint256 p2 = pad.spotPrice(address(tok));
        assertGt(p1, p0);
        assertGt(p2, p1);
    }

    function test_buyThenSell_notProfitable() public {
        uint256 out = _buy(alice, 0.05 ether);
        uint256 before = alice.balance;
        _sell(alice, out);
        assertLt(alice.balance - before, 0.05 ether);
        assertApproxEqRel(alice.balance - before, 0.05 ether * 99 * 99 / 10_000, 1e14);
        assertEq(_sold(), 0);
    }

    function test_quoteMatchesExecution() public {
        (uint256 qOut, uint256 qIn, uint256 qFee, uint256 qRefund) = pad.quoteBuy(address(tok), alice, 0.03 ether);
        uint256 out = _buy(alice, 0.03 ether);
        assertEq(out, qOut);
        assertEq(qIn, 0.0297 ether);
        assertEq(qFee, 0.0003 ether);
        assertEq(qRefund, 0);
        (uint256 qBnb,) = pad.quoteSell(address(tok), out);
        uint256 before = alice.balance;
        _sell(alice, out);
        assertEq(alice.balance - before, qBnb);
    }

    // ------------------------------------------------------------ wallet cap (1% of supply)
    function test_walletCap_singleHugeBuyCappedAndRefunded() public {
        uint256 before = alice.balance;
        uint256 out = _buy(alice, 100 ether);
        assertEq(out, pad.MAX_PER_WALLET());
        assertFalse(_graduated());
        uint256 paid = before - alice.balance;
        uint256 bnbIn = _realBnb();
        uint256 fee = (bnbIn * 100 + 9899) / 9900;
        assertEq(paid, bnbIn + fee);
        assertEq(pad.accruedFees(), fee);
        assertLt(paid, 0.07 ether);
        assertEq(pad.walletRoom(address(tok), alice), 0);
    }

    function test_walletCap_partialFillsToExactCap() public {
        _buy(alice, 0.03 ether);
        _buy(alice, 5 ether);
        assertEq(tok.balanceOf(alice), 10_000_000 ether);
    }

    function test_walletCap_fullWalletReverts() public {
        _buy(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(Launchpad.WalletCapReached.selector);
        pad.buy{value: 0.01 ether}(address(tok), 0);
    }

    function test_walletCap_sellFreesRoom() public {
        _buy(alice, 100 ether);
        _sell(alice, 4_000_000 ether);
        assertEq(pad.walletRoom(address(tok), alice), 4_000_000 ether);
        _buy(alice, 100 ether);
        assertEq(tok.balanceOf(alice), 10_000_000 ether);
    }

    function test_walletCap_cannotDonateToLaunchpadToReopenRoom() public {
        _buy(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(LaunchToken.TransfersLocked.selector);
        tok.transfer(address(pad), 5_000_000 ether);
        assertEq(pad.walletRoom(address(tok), alice), 0);
    }

    function test_walletCap_quoteForFullWallet() public {
        _buy(alice, 100 ether);
        (uint256 qOut,,, uint256 qRefund) = pad.quoteBuy(address(tok), alice, 1 ether);
        assertEq(qOut, 0);
        assertEq(qRefund, 1 ether);
    }

    // ------------------------------------------------------------ graduation
    function test_graduation_needs80Wallets() public {
        uint256 n = _fillCurve();
        assertEq(n, 80);
        assertTrue(_graduated());
        assertEq(mockMigrator.calls(), 1);
        assertEq(mockMigrator.lastBnb(), 20 ether);
        assertEq(mockMigrator.lastTokenAmount(), 1_000_000_000 ether - _sold());
        assertApproxEqAbs(mockMigrator.lastTokenAmount(), 200_000_000 ether, 1e9);
        assertEq(tok.balanceOf(address(pad)), 0);
        assertFalse(tok.locked());
        assertEq(_realBnb(), 0);
        assertEq(pad.totalRealBnb(), 0);
        assertEq(address(pad).balance, pad.accruedFees());
    }

    function test_graduation_lastBuyRefundsExcess() public {
        for (uint256 i; i < 79; i++) {
            address w = address(uint160(0xB0000 + i));
            _mintAgent(w);
            vm.deal(w, 10 ether);
            vm.prank(w);
            pad.buy{value: 2 ether}(address(tok), 0);
        }
        uint256 remaining = 20 ether - _realBnb();
        uint256 before = agent.balance;
        _buy(agent, 50 ether);
        assertTrue(_graduated());
        uint256 fee = (remaining * 100 + 9899) / 9900;
        assertEq(before - agent.balance, remaining + fee);
    }

    function test_graduated_curveClosed_viewsRevert() public {
        _fillCurve();
        vm.prank(alice);
        vm.expectRevert(Launchpad.AlreadyGraduated.selector);
        pad.buy{value: 1 ether}(address(tok), 0);
        vm.startPrank(alice);
        tok.approve(address(pad), 1 ether);
        vm.expectRevert(Launchpad.AlreadyGraduated.selector);
        pad.sell(address(tok), 1 ether, 0);
        vm.stopPrank();
        vm.expectRevert(Launchpad.AlreadyGraduated.selector);
        pad.spotPrice(address(tok));
        vm.expectRevert(Launchpad.AlreadyGraduated.selector);
        pad.quoteBuy(address(tok), alice, 1 ether);
        vm.expectRevert(Launchpad.AlreadyGraduated.selector);
        pad.quoteSell(address(tok), 1 ether);
    }

    // ------------------------------------------------------------ transfer lock
    function test_lock_blocksTransfersBeforeGraduation() public {
        uint256 out = _buy(alice, 0.01 ether);
        vm.prank(alice);
        vm.expectRevert(LaunchToken.TransfersLocked.selector);
        tok.transfer(bob, out);
        vm.prank(alice);
        tok.approve(bob, out);
        vm.prank(bob);
        vm.expectRevert(LaunchToken.TransfersLocked.selector);
        tok.transferFrom(alice, bob, out);
        vm.prank(bob);
        vm.expectRevert(LaunchToken.TransfersLocked.selector);
        tok.transferFrom(alice, address(pad), out);
    }

    function test_lock_liftedAfterGraduation() public {
        uint256 out = _buy(alice, 0.01 ether);
        _fillCurve();
        vm.prank(alice);
        tok.transfer(bob, out);
        assertEq(tok.balanceOf(bob), out);
    }

    function test_unlock_onlyLaunchpad() public {
        vm.expectRevert(LaunchToken.OnlyLaunchpad.selector);
        tok.unlock();
    }

    // ------------------------------------------------------------ agent gate
    function test_gate_holderBuys_nonHolderRejected() public {
        assertGt(_buy(agent, 0.01 ether), 0);
        vm.prank(human);
        vm.expectRevert(Launchpad.NotAgent.selector);
        pad.buy{value: 0.01 ether}(address(tok), 0);
    }

    function test_gate_sellRequiresAgent() public {
        uint256 out = _buy(alice, 0.01 ether);
        assertGt(out, 0);
        vm.prank(human);
        vm.expectRevert(Launchpad.NotAgent.selector);
        pad.sell(address(tok), 1 ether, 0);
        _sell(alice, out);
    }

    function test_gate_soulbound() public {
        vm.prank(agent);
        vm.expectRevert();
        agentId.transferFrom(agent, human, 3);
    }

    // ------------------------------------------------------------ deferred payouts (contract wallets)
    function test_deferredRefund_contractWithoutReceive() public {
        NoReceive w = new NoReceive();
        _mintAgent(address(w));
        vm.deal(address(this), 10 ether);
        uint256 out = w.buy{value: 1 ether}(pad, address(tok)); // capped at 1% -> refund cannot be pushed
        assertEq(out, 10_000_000 ether);
        uint256 pending = pad.pendingWithdrawals(address(w));
        assertGt(pending, 0.9 ether);
        assertEq(pad.totalPending(), pending);
        // sell also defers
        w.sell(pad, address(tok), 1_000_000 ether);
        assertGt(pad.pendingWithdrawals(address(w)), pending);
        // withdraw fails for a contract that still can't receive; the funds stay claimable
        vm.expectRevert(Launchpad.PayoutFailed.selector);
        w.withdraw(pad);
        assertEq(
            address(pad).balance, pad.totalRealBnb() + pad.accruedFees() + pad.totalPending() + pad.pendingBuyback()
        );
    }

    function test_withdraw_nothingPending() public {
        vm.prank(alice);
        vm.expectRevert(Launchpad.NothingPending.selector);
        pad.withdraw();
    }

    // ------------------------------------------------------------ fees & admin
    function test_collectFees() public {
        _buy(alice, 0.5 ether);
        uint256 fees = pad.accruedFees();
        pad.collectFees();
        uint256 ops = fees - (fees * pad.BUYBACK_BPS()) / 10_000;
        assertEq(vault.balance, ops);
        assertEq(pad.accruedFees(), 0);
        // no platformToken yet → 80% parked as pendingBuyback
        assertEq(pad.pendingBuyback(), fees - ops);
        assertEq(address(pad).balance, _realBnb() + pad.pendingBuyback());
    }

    function test_sweepExcess_onlyForceFedBnb() public {
        _buy(alice, 0.5 ether);
        vm.expectRevert(Launchpad.ZeroAmount.selector);
        pad.sweepExcess();
        new SelfDestructor{value: 1 ether}(payable(address(pad)));
        pad.sweepExcess();
        assertEq(vault.balance, 1 ether);
        assertEq(address(pad).balance, pad.totalRealBnb() + pad.accruedFees());
    }

    function test_migrator_setOnce() public {
        vm.prank(owner);
        vm.expectRevert(Launchpad.MigratorAlreadySet.selector);
        pad.setMigrator(address(0xBAD));
    }

    function test_registry_timelock() public {
        address newReg = address(0x1234);
        vm.prank(owner);
        pad.proposeAgentIdRegistry(newReg);
        vm.prank(owner);
        vm.expectRevert(Launchpad.TimelockActive.selector);
        pad.applyAgentIdRegistry();
        vm.warp(block.timestamp + 24 hours);
        vm.prank(owner);
        pad.applyAgentIdRegistry();
        assertEq(address(pad.agentIdRegistry()), newReg);
    }

    function test_registry_cancel() public {
        vm.startPrank(owner);
        pad.proposeAgentIdRegistry(address(0x1234));
        pad.cancelAgentIdRegistry();
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(Launchpad.NothingPending.selector);
        pad.applyAgentIdRegistry();
        vm.stopPrank();
    }

    function test_slippage() public {
        vm.prank(alice);
        vm.expectRevert(Launchpad.Slippage.selector);
        pad.buy{value: 1 ether}(address(tok), type(uint256).max);
    }

    function test_unknownToken() public {
        vm.expectRevert(Launchpad.UnknownToken.selector);
        pad.sell(address(0x1234), 1, 0);
        vm.expectRevert(Launchpad.UnknownToken.selector);
        pad.spotPrice(address(0x1234));
    }

    function test_onlyOwnerAdmin() public {
        vm.expectRevert();
        pad.setFeeVault(alice);
        vm.expectRevert();
        pad.setMigrator(alice);
        vm.expectRevert();
        pad.proposeAgentIdRegistry(alice);
    }

    receive() external payable {}
}
