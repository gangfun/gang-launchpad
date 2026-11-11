// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FloorBase} from "./GangFloorModule.t.sol";
import {GangFloorModule} from "../../src/gang/GangFloorModule.sol";

/// @notice From the independent re-review (2026-11-11) of the fixes: what a redemption sets aside for the payees
///         (`payeesPending`) through `setPayee`, `release`, `distribute`, a shortfall, the cap and the keeper.
contract GangFloorModulePendingTest is FloorBase {
    function setUp() public {
        _deployFloor();
    }

    function _books(GangFloorModule m, address q) internal view {
        assertEq(_bal(q, address(m)), m.treasuryHeld() + m.owedTotal(q) + m.payeesPending() + m.unsplit(), "books");
    }

    /// setPayee with pending: pending goes to the OLD payee; nothing doubled.
    function test_setPayee_withPending_oldGetsIt() public {
        (GangFloorModule m,,, address kol, address alice) = _setup(address(blq), 100 ether, true);
        blq.mint(address(m), 10 ether);
        vm.prank(alice);
        m.redeem(1 ether, 0, alice);
        assertEq(m.payeesPending(), 5 ether);
        uint64 lp = m.lastPaidAt();
        assertEq(lp, 0, "redeem does not touch lastPaidAt");
        address kol2 = makeAddr("kol2");
        _next(100);
        vm.prank(kol);
        m.setPayee(1, kol2);
        assertEq(_bal(address(blq), kol), 1.5 ether);
        assertEq(_bal(address(blq), kol2), 0);
        assertEq(m.payeesPending(), 0);
        assertEq(m.paidTotal(), 5 ether);
        assertEq(m.lastPaidAt(), uint64(block.timestamp));
        _books(m, address(blq));
    }

    /// setPayee in a shortfall with pending: the split returns early, the pending goes to the NEW payee.
    function test_setPayee_shortfall_pendingGoesToNew() public {
        (GangFloorModule m,,, address kol, address alice) = _setup(address(blq), 100 ether, true);
        blq.mint(address(m), 10 ether);
        vm.prank(alice);
        m.redeem(1 ether, 0, alice);
        uint256 bal = _bal(address(blq), address(m));
        deal(address(blq), address(m), bal - 1 ether);
        address kol2 = makeAddr("kol2");
        vm.prank(kol);
        m.setPayee(1, kol2);
        assertGt(m.payeesPending(), 0, "not pushed in the shortfall call");
        m.split();
        assertEq(_bal(address(blq), kol), 0, "old payee got none of what arrived before the move");
        assertGt(_bal(address(blq), kol2), 0);
        _books(m, address(blq));
    }

    /// keeper: previewWork due under a shortfall with pending, but work() does not push in that call.
    function test_work_shortfall_wastedCall() public {
        (GangFloorModule m,,,, address alice) = _setup(address(blq), 100 ether, true);
        blq.mint(address(m), 10 ether);
        vm.prank(alice);
        m.redeem(1 ether, 0, alice);
        uint256 bal = _bal(address(blq), address(m));
        deal(address(blq), address(m), bal - 1 ether);
        (bool due,) = m.previewWork();
        assertTrue(due);
        m.work(0);
        assertGt(m.payeesPending(), 0, "first work only books the shortfall");
        (due,) = m.previewWork();
        assertTrue(due);
        m.work(0);
        assertEq(m.payeesPending(), 0);
        _books(m, address(blq));
    }

    /// release / distribute(quote) with pending push it once.
    function test_release_and_distribute_withPending() public {
        (GangFloorModule m,, address dev, address kol, address alice) = _setup(address(blq), 100 ether, true);
        blq.setBlocked(kol, true);
        blq.mint(address(m), 10 ether);
        m.split(); // kol owed 1.5
        blq.mint(address(m), 10 ether);
        vm.prank(alice);
        m.redeem(1 ether, 0, alice);
        assertEq(m.payeesPending(), 5 ether);
        assertEq(m.owedOf(address(blq), 1), 1.5 ether);
        uint256 dev0 = _bal(address(blq), dev);
        blq.setBlocked(kol, false);
        // release: the split pushes pending (3.5 dev, 1.5 kol + its owed 1.5) → nothing owed left → reverts as a whole
        vm.expectRevert(GangFloorModule.NothingOwed.selector);
        m.release(address(blq), 1, ALL);
        assertEq(m.payeesPending(), 5 ether);
        assertEq(m.distribute(address(blq)), 0);
        assertEq(m.payeesPending(), 0);
        assertEq(_bal(address(blq), kol), 3 ether);
        assertEq(_bal(address(blq), dev) - dev0, 3.5 ether);
        assertEq(m.paidTotal(), 10 ether);
        _books(m, address(blq));

        // release with pending while still blocked: pending → owed, then released by a later release
        blq.setBlocked(kol, true);
        blq.mint(address(m), 10 ether);
        vm.prank(alice);
        m.redeem(1 ether, 0, alice);
        blq.mint(address(m), 2 ether);
        m.split();
        assertEq(m.owedOf(address(blq), 1), 1.8 ether);
        blq.setBlocked(kol, false);
        assertEq(m.release(address(blq), 1, ALL), 1.8 ether);
        assertEq(m.paidTotal(), 16 ether);
        _books(m, address(blq));
    }

    /// cap crossed by a redemption's split: CapReached once; payees get exactly the cap; previewWork due AFTER the cap.
    function test_capCrossedByRedeem() public {
        (GangFloorModule m, address t, address dev, address kol, address alice) = _setup(address(wbnb), 1 ether, true);
        uint256 dev0 = _bal(address(wbnb), dev);
        wbnb.mintUnlimited(address(m), 10 ether);
        vm.recordLogs();
        vm.prank(alice);
        m.redeem(1 ether, 0, alice);
        wbnb.mintUnlimited(address(m), 10 ether);
        vm.prank(alice);
        m.redeem(1 ether, 0, alice);
        assertTrue(m.capReached());
        assertEq(m.payeesPending(), 1 ether);
        (bool due,) = m.previewWork();
        assertTrue(due, "due after the cap is reached: pending");
        m.work(0);
        m.split();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(m) && logs[i].topics[0] == GangFloorModule.CapReached.selector) n++;
        }
        assertEq(n, 1, "CapReached once");
        assertEq(_bal(address(wbnb), kol) + _bal(address(wbnb), dev) - dev0, 1 ether);
        assertEq(m.paidTotal(), 1 ether);
        (due,) = m.previewWork();
        assertFalse(due);
        _books(m, address(wbnb));
        t;
    }

    /// small pending after the cap: the keeper is never due (below 1/100 of the floor), anyone can still split.
    function test_smallPendingAfterCap_keeperNeverDue() public {
        (GangFloorModule m,,, address kol, address alice) = _setup(address(wbnb), 1000, true);
        wbnb.mintUnlimited(address(m), 10 ether);
        vm.prank(alice);
        m.redeem(1 ether, 0, alice);
        assertTrue(m.capReached());
        assertEq(m.payeesPending(), 1000);
        _next(30 days);
        (bool due,) = m.previewWork();
        assertFalse(due);
        m.split();
        assertEq(_bal(address(wbnb), kol), 300);
    }
}

/// @dev Model fuzz with shortfalls, setPayee, release, work, redeem.
contract GangFloorModulePendingFuzzTest is FloorBase {
    GangFloorModule m;
    address t;
    address dev;
    address[] kols;
    address[3] hs;
    uint256 dev0;

    function setUp() public {
        _deployFloor();
        dev = _newAgent();
        kols.push(makeAddr("k0"));
        m = _floor(dev, _nextToken(dev), address(blq), 40 ether, 3_333, 137, _list(dev, kols[0]), _shares(6_000, 4_000));
        t = _createT(dev, address(blq), _tax(TAX, TAX, 0, address(m)));
        m.bind(t);
        for (uint256 h; h < 3; h++) {
            hs[h] = _holder(t, m);
        }
        _graduate(t);
        dev0 = _bal(address(blq), dev);
    }

    function _recv() internal view returns (uint256 r) {
        r = _bal(address(blq), dev) - dev0;
        for (uint256 i; i < kols.length; i++) {
            r += _bal(address(blq), kols[i]);
        }
    }

    function testFuzz_model(uint256 seed) public {
        address q = address(blq);
        bool shortfallSeen;
        for (uint256 i; i < 40; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 10;
            address kol = kols[kols.length - 1];
            uint256 view0 = m.treasury();
            uint256 supply0 = m.floorSupply();
            bool short_ = _bal(q, address(m)) < m.treasuryHeld() + m.owedTotal(q) + m.payeesPending();
            if (op == 0) {
                blq.setBlocked(kol, (r >> 8) % 2 == 0);
            } else if (op == 1) {
                try m.release(q, 1, ALL) {} catch {}
            } else if (op <= 3) {
                address who = hs[(r >> 8) % 3];
                uint256 bal = _bal(t, who);
                if (bal == 0) continue;
                uint256 a = 1 + ((r >> 16) % bal);
                (uint256 pOut,) = m.previewRedeem(a);
                if (pOut == 0) continue;
                uint256 owed0 = m.owedTotal(q);
                uint256 recv0 = _recv();
                vm.prank(who);
                uint256 out = m.redeem(a, pOut, makeAddr("to"));
                assertEq(out, pOut, "preview");
                assertEq(m.treasuryHeld(), view0 - out, "view==exec (redeem)");
                assertEq(_recv(), recv0, "redeem pushed nobody");
                if (!short_) assertEq(m.owedTotal(q), owed0, "redeem owes nobody");
            } else if (op == 4) {
                m.split();
                assertEq(m.treasuryHeld(), view0, "view==exec (split)");
                if (!short_) assertEq(m.payeesPending(), 0, "push clears pending");
            } else if (op == 5) {
                m.work(0);
                assertEq(m.treasuryHeld(), view0, "view==exec (work)");
            } else if (op == 6) {
                address nk = makeAddr(string.concat("k", vm.toString(kols.length)));
                vm.prank(kol);
                m.setPayee(1, nk);
                kols.push(nk);
                assertEq(m.treasuryHeld(), view0, "view==exec (setPayee)");
            } else if (op == 7) {
                // shortfall: take a random part of the balance away
                uint256 bal = _bal(q, address(m));
                if (bal == 0) continue;
                deal(q, address(m), bal - ((r >> 8) % bal) / 3);
                shortfallSeen = true;
                assertLe(m.treasury(), view0);
                continue; // identity only after the next split
            } else {
                blq.mint(address(m), (r >> 8) % 30 ether);
            }
            assertLe(m.paidTotal(), m.capAmount(), "I-1");
            assertLe(_recv() + m.owedTotal(q) + m.payeesPending(), m.paidTotal(), "I-1b");
            if (!shortfallSeen) {
                assertGe(m.treasury() * supply0, view0 * m.floorSupply(), "I-2");
            }
            uint256 b = _bal(q, address(m));
            uint256 heldAll = m.treasuryHeld() + m.owedTotal(q) + m.payeesPending();
            if (b >= heldAll) assertEq(b, heldAll + m.unsplit(), "books");
        }
    }
}
