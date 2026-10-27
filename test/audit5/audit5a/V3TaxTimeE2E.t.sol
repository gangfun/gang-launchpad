// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPair} from "../../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {GangToken as TaxLaunchTokenV3} from "../../../src/gang/stub/GangToken.sol";
import {LaunchpadV3Test} from "../../launchpad-v3/LaunchpadV3.t.sol";

/// @notice audit5a: end-to-end tax-time dividends on V3 (real token + handler + shared vault, mock pair).
contract V3TaxTimeE2E is LaunchpadV3Test {
    address[] holders;
    address t;
    MockPair pair;

    function _setupToken(uint16 buy, uint16 sell, uint16 div, address rec) internal {
        t = _create(_tax(buy, sell, div, rec));
        _graduate(t);
        pair = MockPair(TaxLaunchTokenV3(t).pair());
        delete holders;
        for (uint256 i = 0; i < 400; i++) {
            address w = address(uint160(0xB0000 + i));
            if (IERC20(t).balanceOf(w) == 0) break;
            holders.push(w);
        }
        for (uint256 i = 0; i < 6; i++) {
            holders.push(address(uint160(0xD0000 + i)));
        }
    }

    function _owedAll() internal view returns (uint256 owed, uint256 units) {
        for (uint256 i = 0; i < holders.length; i++) {
            owed += divVault.pending(t, holders[i]);
            units += divVault.pendingUnits(t, holders[i]);
        }
    }

    function _check(string memory where) internal view {
        uint256 unsold = divVault.unsoldUnits(t);
        uint256 pend = handler.pendingHolderUnits(t);
        assertLe(unsold - pend, handler.accruedTax(t), string.concat(where, ": holder units > accrued"));
        assertLe(handler.accruedTax(t), IERC20(t).balanceOf(address(handler)), string.concat(where, ": accrued > held"));
        assertLe(handler.accruedPlatformTax(t) + unsold - pend, handler.accruedTax(t) + 1, "platform+holders > accrued");
        (uint256 owed, uint256 units) = _owedAll();
        assertGe(quoteTok.balanceOf(address(divVault)), owed, string.concat(where, ": vault insolvent"));
        (uint64 open, uint64 selling,) = divVault.pipeOf(t);
        uint256 cap;
        if (selling != 0) {
            (uint128 u,,,,) = divVault.batchOf(t, selling);
            cap += u;
        }
        if (open != 0) {
            (uint128 u,,,,) = divVault.batchOf(t, open);
            cap += u;
        }
        assertLe(units, cap, string.concat(where, ": units > unsettled"));
        // shares are never stale: each holder's share is the rule applied to its balance right now
        uint256 floor = divVault.minimumShareBalanceFor(t);
        for (uint256 i = 0; i < holders.length; i++) {
            uint256 bal = IERC20(t).balanceOf(holders[i]);
            assertEq(divVault.shares(t, holders[i]), bal > floor ? bal : 0, "stale share");
        }
        // the pair / handler never hold shares
        assertEq(divVault.shares(t, address(pair)), 0);
        assertEq(divVault.shares(t, address(handler)), 0);
    }

    function _act(uint256 r) internal {
        uint256 k = r % 7;
        address a = holders[(r >> 8) % holders.length];
        address b = holders[(r >> 24) % holders.length];
        if (k == 0 || k == 1) {
            _poolBuy(t, a, ((r >> 40) % 50 + 1) * 0.05 ether);
        } else if (k == 2 || k == 3) {
            uint256 bal = IERC20(t).balanceOf(a);
            if (bal < 1e6) return;
            uint256 amt = (r >> 40) % 3 == 0 ? bal : 1 + (r >> 48) % bal;
            _poolSell(t, a, amt);
        } else if (k == 4) {
            uint256 bal = IERC20(t).balanceOf(a);
            if (bal == 0) return;
            vm.prank(a);
            IERC20(t).transfer(b, (r >> 40) % 2 == 0 ? bal : (r >> 48) % (bal + 1));
        } else if (k == 5) {
            uint256 mc = handler.maxChunk(t);
            if (mc == 0) return;
            uint256 amt = (r >> 40) % 3 == 0 ? type(uint256).max : 1 + (r >> 48) % mc;
            vm.prank(keeper);
            try handler.process(t, amt, 1) {} catch {} // a dust chunk may fetch 0 quote
        } else {
            if (divVault.pending(t, a) == 0) {
                vm.roll(vm.getBlockNumber() + 1);
                return;
            }
            uint256 p = divVault.pending(t, a);
            uint256 b0 = quoteTok.balanceOf(a);
            vm.prank(a);
            divVault.claim(t);
            assertEq(quoteTok.balanceOf(a) - b0, p, "claim pays pending");
        }
    }

    function _drain() internal {
        for (uint256 i = 0; i < 2000 && handler.accruedTax(t) > 0; i++) {
            vm.roll(vm.getBlockNumber() + 1); // audit 5: one chunk budget per block
            vm.prank(keeper);
            handler.process(t, type(uint256).max, 1);
        }
        assertEq(handler.accruedTax(t), 0, "drained");
        assertEq(divVault.unsoldUnits(t), 0, "every holder unit sold once accrued is 0");
        (uint256 owed, uint256 units) = _owedAll();
        assertEq(units, 0, "nothing left unsettled");
        assertGe(quoteTok.balanceOf(address(divVault)), owed, "drained vault insolvent");
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_e2e_recipient(uint256 seed) public {
        _setupToken(300, 500, 5000, treasury);
        for (uint256 i = 0; i < 60; i++) {
            _act(uint256(keccak256(abi.encode(seed, i))));
            _check("step");
        }
        _drain();
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_e2e_allHolders(uint256 seed) public {
        _setupToken(100, 100, 10_000, address(0));
        for (uint256 i = 0; i < 60; i++) {
            _act(uint256(keccak256(abi.encode(seed, i))));
            _check("step");
        }
        _drain();
    }
}
