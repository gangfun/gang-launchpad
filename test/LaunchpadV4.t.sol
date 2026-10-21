// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockPancakeRouter} from "./mocks/MockPancakeRouter.sol";
import {SelfDestructor} from "./mocks/NoReceive.sol";

contract LaunchpadV4Test is BaseTest {
    LaunchToken internal gang;
    MockPancakeRouter internal router;
    address internal wbnb = makeAddr("wbnb");

    function _seedGang() internal returns (LaunchToken) {
        vm.prank(owner);
        address t = pad.seedPlatformToken("Gang", "GANG");
        gang = LaunchToken(t);
        return gang;
    }

    /// @dev Accrue at least `minFees` via buy/sell round-trips without graduating the GTT curve.
    function _accrueFees(uint256 minFees) internal {
        while (pad.accruedFees() < minFees) {
            vm.prank(alice);
            pad.buy{value: 0.05 ether}(address(tok), 0);
            uint256 bal = tok.balanceOf(alice);
            if (bal == 0) break;
            _sell(alice, bal);
        }
    }

    // ------------------------------------------------------------ seedPlatformToken
    function test_seedPlatformToken_onceOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        pad.seedPlatformToken("Gang", "GANG");

        _seedGang();
        assertEq(pad.platformToken(), address(gang));
        assertEq(gang.name(), "Gang");
        assertEq(gang.symbol(), "GANG");
        assertEq(pad.tokenCount(), 2); // GTT + GANG

        vm.prank(owner);
        vm.expectRevert(Launchpad.PlatformTokenAlreadySet.selector);
        pad.seedPlatformToken("Gang2", "GANG2");
    }

    function test_seedPlatformToken_requiresMigrator() public {
        Launchpad p2 = new Launchpad(owner, vault, address(agentId));
        vm.prank(owner);
        vm.expectRevert(Launchpad.MigratorNotSet.selector);
        p2.seedPlatformToken("Gang", "GANG");
    }

    // ------------------------------------------------------------ 80/20 accounting
    function test_collectFees_8020_withoutPlatform_pendsBuyback() public {
        _buy(alice, 1 ether);
        uint256 fees = pad.accruedFees();
        uint256 buyback = (fees * pad.BUYBACK_BPS()) / 10_000;
        uint256 ops = fees - buyback;

        pad.collectFees();
        assertEq(vault.balance, ops);
        assertEq(pad.pendingBuyback(), buyback);
        assertEq(pad.accruedFees(), 0);
    }

    function test_collectFees_8020_withPlatform_buysAndBurns() public {
        _seedGang();
        _buy(alice, 1 ether);
        uint256 fees = pad.accruedFees();
        uint256 buyback = (fees * pad.BUYBACK_BPS()) / 10_000;
        uint256 ops = fees - buyback;

        uint256 supplyBefore = gang.totalSupply();
        (, uint256 realBefore,,,) = pad.curves(address(gang));

        pad.collectFees();

        assertEq(vault.balance, ops);
        assertEq(pad.pendingBuyback(), 0);
        (, uint256 realAfter, uint256 soldAfter,,) = pad.curves(address(gang));
        assertEq(realAfter, realBefore + buyback);
        assertGt(soldAfter, 0);
        assertEq(gang.totalSupply(), supplyBefore - soldAfter); // protocol buys all burned
    }

    // ------------------------------------------------------------ protocol buyback properties
    function test_buyback_noAgentRequired_noFeeAccrual() public {
        _seedGang();
        _buy(alice, 0.5 ether);
        uint256 fees = pad.accruedFees();
        pad.collectFees();
        assertEq(pad.accruedFees(), 0);

        vm.prank(human);
        vm.expectRevert(Launchpad.NotAgent.selector);
        pad.buy{value: 0.01 ether}(address(gang), 0);

        (, uint256 realBnb,,,) = pad.curves(address(gang));
        assertEq(realBnb, (fees * pad.BUYBACK_BPS()) / 10_000);
    }

    function test_buyback_canTriggerGraduation() public {
        _seedGang();
        for (uint256 i; i < 79; i++) {
            address w = address(uint160(0xC0000 + i));
            _mintAgent(w);
            vm.deal(w, 10 ether);
            vm.prank(w);
            pad.buy{value: 2 ether}(address(gang), 0);
        }
        (, uint256 realBnb,, bool graduated,) = pad.curves(address(gang));
        assertFalse(graduated);
        uint256 remaining = 20 ether - realBnb;
        assertGt(remaining, 0);

        // Clear GANG-buy fees first into pending/buyback would move the curve — instead
        // accrue extra on GTT so 80% covers remaining, then collect once.
        uint256 needBuyback = remaining;
        uint256 needFees = (needBuyback * 10_000 + 7999) / 8000;
        // Current accruedFees already from GANG fills; may be close. Top up via GTT round-trips.
        if (pad.accruedFees() < needFees) {
            _accrueFees(needFees);
        }
        assertGe(pad.accruedFees(), needFees);

        pad.collectFees();
        (,,, bool gangGraduated,) = pad.curves(address(gang));
        assertTrue(gangGraduated);
        assertEq(mockMigrator.lastToken(), address(gang));
        assertEq(mockMigrator.lastBnb(), 20 ether);
    }

    function test_userBuy_stillNeedsAgent_andPaysFee() public {
        _seedGang();
        vm.prank(human);
        vm.expectRevert(Launchpad.NotAgent.selector);
        pad.buy{value: 0.01 ether}(address(gang), 0);

        uint256 feesBefore = pad.accruedFees();
        vm.prank(alice);
        uint256 out = pad.buy{value: 0.01 ether}(address(gang), 0);
        assertGt(out, 0);
        assertEq(pad.accruedFees() - feesBefore, 0.0001 ether);
    }

    // ------------------------------------------------------------ pending + flush
    function test_pendingBuyback_thenFlush() public {
        _buy(alice, 1 ether);
        uint256 fees = pad.accruedFees();
        uint256 buyback = (fees * pad.BUYBACK_BPS()) / 10_000;
        pad.collectFees();
        assertEq(pad.pendingBuyback(), buyback);

        _seedGang();
        uint256 supplyBefore = gang.totalSupply();
        pad.flushBuyback();
        assertEq(pad.pendingBuyback(), 0);
        (, uint256 realBnb, uint256 sold,,) = pad.curves(address(gang));
        assertEq(realBnb, buyback);
        assertEq(gang.totalSupply(), supplyBefore - sold);
    }

    function test_flushBuyback_revertsIfNoPlatformOrEmpty() public {
        vm.expectRevert(Launchpad.NothingPending.selector);
        pad.flushBuyback();

        _buy(alice, 1 ether);
        pad.collectFees();
        vm.expectRevert(Launchpad.PlatformTokenNotSet.selector);
        pad.flushBuyback();
    }

    // ------------------------------------------------------------ sweep excess 100% ops
    function test_sweepExcess_100pctToOps_ignoresPendingBuyback() public {
        _buy(alice, 0.5 ether);
        pad.collectFees();
        uint256 pending = pad.pendingBuyback();
        assertGt(pending, 0);

        new SelfDestructor{value: 1 ether}(payable(address(pad)));
        uint256 vaultBefore = vault.balance;
        pad.sweepExcess();
        assertEq(vault.balance - vaultBefore, 1 ether);
        assertEq(pad.pendingBuyback(), pending);
    }

    // ------------------------------------------------------------ post-grad router path
    function test_buyback_afterGraduation_usesRouter() public {
        _seedGang();
        router = new MockPancakeRouter(wbnb);
        // 1:1 wei for simpler accounting; fund router after unlock
        router.setRate(1);
        vm.prank(owner);
        pad.setPancakeRouter(address(router));

        for (uint256 i; i < 80; i++) {
            address w = address(uint160(0xF0000 + i));
            _mintAgent(w);
            vm.deal(w, 10 ether);
            vm.prank(w);
            pad.buy{value: 2 ether}(address(gang), 0);
        }
        (,,, bool graduated,) = pad.curves(address(gang));
        assertTrue(graduated);

        address holder = address(uint160(0xF0000));
        uint256 fund = gang.balanceOf(holder) / 2;
        vm.prank(holder);
        gang.transfer(address(router), fund);

        // Accrue fresh fees on GTT (round-trip) then collect → swap+burn
        uint256 feesBefore = pad.accruedFees();
        // Collect existing graduation fees first so we isolate the router path cleanly
        if (feesBefore > 0) {
            // Without enough router inventory relative to huge buyback, rate=1 needs fund >= buyback wei
            // Top up router from another holder if needed after first collect's buyback size known.
            pad.collectFees();
        }
        _accrueFees(0.01 ether);
        uint256 fees = pad.accruedFees();
        uint256 buyback = (fees * pad.BUYBACK_BPS()) / 10_000;
        // Ensure router has inventory for this buyback (rate=1 → need `buyback` tokens)
        if (gang.balanceOf(address(router)) < buyback) {
            address h2 = address(uint160(0xF0001));
            vm.prank(h2);
            gang.transfer(address(router), buyback);
        }

        uint256 supplyBefore = gang.totalSupply();
        uint256 routerBefore = gang.balanceOf(address(router));
        pad.collectFees();

        assertEq(pad.pendingBuyback(), 0);
        assertEq(gang.balanceOf(address(router)), routerBefore - buyback);
        assertEq(gang.totalSupply(), supplyBefore - buyback);
    }

    function test_setPancakeRouter_onceOnlyOwner() public {
        router = new MockPancakeRouter(wbnb);
        vm.expectRevert();
        pad.setPancakeRouter(address(router));

        vm.prank(owner);
        pad.setPancakeRouter(address(router));

        vm.prank(owner);
        vm.expectRevert(Launchpad.RouterAlreadySet.selector);
        pad.setPancakeRouter(address(router));
    }

    function test_graduatedBuyback_withoutRouter_pends() public {
        _seedGang();
        for (uint256 i; i < 80; i++) {
            address w = address(uint160(0xD1000 + i));
            _mintAgent(w);
            vm.deal(w, 10 ether);
            vm.prank(w);
            pad.buy{value: 2 ether}(address(gang), 0);
        }

        uint256 fees = pad.accruedFees();
        pad.collectFees();
        uint256 pending = pad.pendingBuyback();
        assertEq(pending, (fees * pad.BUYBACK_BPS()) / 10_000);
    }
}
