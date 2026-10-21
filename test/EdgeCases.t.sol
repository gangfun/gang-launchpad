// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Launchpad} from "../src/Launchpad.sol";

contract EdgeCasesTest is BaseTest {
    function test_oneWeiBuy() public {
        uint256 out = _buyAsAgent(agent, 1);
        assertGt(out, 0);
        assertEq(_realBnb(), 1);
        assertEq(pad.accruedFees(), 0);
    }

    function test_hundredWeiBuy_feeIsOne() public {
        _buyAsAgent(agent, 100);
        assertEq(pad.accruedFees(), 1);
        assertEq(_realBnb(), 99);
    }

    /// @dev Selling everything ever bought never pays out more than the curve holds, at any fill level.
    function testFuzz_sellAllNeverExceedsReserve(uint96 a, uint96 b, uint96 c) public {
        uint256[3] memory amts =
            [bound(uint256(a), 1, 2 ether), bound(uint256(b), 1, 2 ether), bound(uint256(c), 1, 2 ether)];
        address[3] memory who = [alice, bob, agent];
        for (uint256 i; i < 3; i++) {
            _buy(who[i], amts[i]);
        }
        uint256 reserve = _realBnb();
        uint256 paid;
        for (uint256 i; i < 3; i++) {
            uint256 bal = tok.balanceOf(who[i]);
            if (bal == 0) continue;
            uint256 before = who[i].balance;
            _sell(who[i], bal);
            paid += who[i].balance - before;
        }
        assertLe(paid, reserve);
        assertEq(_sold(), 0);
        assertEq(address(pad).balance, _realBnb() + pad.accruedFees());
    }

    /// @dev The buy that lands exactly on 20 BNB with a tiny remainder still works and graduates.
    function test_graduation_tinyRemainder() public {
        for (uint256 i; i < 79; i++) {
            address w = address(uint160(0xD0000 + i));
            _mintAgent(w);
            vm.deal(w, 10 ether);
            vm.prank(w);
            pad.buy{value: 2 ether}(address(tok), 0);
        }
        uint256 remaining = 20 ether - _realBnb();
        // exact gross that nets remaining-3 wei: gross = ceil((remaining-3)*10000/9900)
        uint256 gross = ((remaining - 3) * 10000 + 9899) / 9900;
        _buy(alice, gross);
        assertFalse(_graduated());
        assertLe(20 ether - _realBnb(), 10); // a few wei left
        uint256 before = bob.balance;
        _buy(bob, 1 ether);
        assertTrue(_graduated());
        assertLt(before - bob.balance, 1000); // paid only the few wei + rounding fee
        assertEq(mockMigrator.lastBnb(), 20 ether);
    }

    function test_cannotBuyGraduated_evenWithRoom() public {
        _fillCurve();
        vm.prank(agent);
        vm.expectRevert(Launchpad.AlreadyGraduated.selector);
        pad.buy{value: 0.01 ether}(address(tok), 0);
    }

    function test_feesCollectableAfterGraduation() public {
        _fillCurve();
        uint256 fees = pad.accruedFees();
        assertGt(fees, 0);
        pad.collectFees();
        uint256 ops = fees - (fees * pad.BUYBACK_BPS()) / 10_000;
        assertEq(vault.balance, ops);
        assertEq(pad.pendingBuyback(), fees - ops);
        assertEq(address(pad).balance, pad.pendingBuyback());
    }

    function test_transferFromLockedBlocked() public {
        uint256 out = _buyAsAgent(agent, 0.01 ether);
        vm.prank(agent);
        tok.approve(alice, out);
        vm.prank(alice);
        vm.expectRevert();
        tok.transferFrom(agent, alice, out);
    }
}
