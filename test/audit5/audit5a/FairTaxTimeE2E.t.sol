// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPair} from "../../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {FairToken} from "../../../src/fair-mint/FairToken.sol";
import {FairMintTest} from "../../fair-mint/FairMint.t.sol";

/// @notice audit5a: end-to-end tax-time dividends on 打新 (FairToken + GangTaxHandler + shared vault).
contract FairTaxTimeE2E is FairMintTest {
    address[] holders;
    address t;

    function _check() internal view {
        uint256 unsold = vault.unsoldUnits(t);
        uint256 pend = handler.pendingHolderUnits(t);
        assertLe(unsold - pend, handler.accruedTax(t), "holder units > accrued");
        assertLe(handler.accruedTax(t), IERC20(t).balanceOf(address(handler)), "accrued > held");
        uint256 owed;
        uint256 units;
        for (uint256 i = 0; i < holders.length; i++) {
            owed += vault.pending(t, holders[i]);
            units += vault.pendingUnits(t, holders[i]);
            uint256 e = handler.eligibleShare(t, holders[i]);
            uint256 expect = e > vault.minimumShareBalanceFor(t) ? e : 0;
            assertEq(vault.shares(t, holders[i]), expect, "stale share");
        }
        assertGe(wbnb.balanceOf(address(vault)), owed, "vault insolvent");
        assertLe(units, unsold + _sellingSold(), "units > unsettled");
    }

    function _sellingSold() internal view returns (uint256) {
        (, uint64 selling,) = vault.pipeOf(t);
        if (selling == 0) return 0;
        (, uint128 sold,,,) = vault.batchOf(t, selling);
        return sold;
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_fairE2E(uint256 seed) public {
        t = _create();
        _fill(t);
        holders.push(dev);
        for (uint256 i = 0; i < 100; i++) {
            holders.push(_minter(i));
        }
        holders.push(buyer);
        for (uint256 i = 0; i < 60; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 k = r % 6;
            address a = holders[(r >> 8) % holders.length];
            address b = holders[(r >> 24) % holders.length];
            if (k == 0) {
                if (wbnb.balanceOf(a) < 1 ether) wbnb.mintUnlimited(a, 10 ether);
                _buy(t, a, ((r >> 40) % 20 + 1) * 0.05 ether);
            } else if (k == 1) {
                uint256 bal = IERC20(t).balanceOf(a);
                if (bal < 1e6) continue;
                _sell(t, a, (r >> 40) % 3 == 0 ? bal : 1 + (r >> 48) % bal);
            } else if (k == 2) {
                uint256 bal = IERC20(t).balanceOf(a);
                if (bal == 0) continue;
                vm.prank(a);
                IERC20(t).transfer(b, (r >> 48) % (bal + 1));
            } else if (k == 3) {
                uint256 mc = handler.maxChunk(t);
                if (mc == 0) continue;
                vm.prank(owner);
                try handler.process(t, 1 + (r >> 48) % mc, 1) {} catch {}
            } else if (k == 4) {
                if (vault.pending(t, a) == 0) continue;
                vm.prank(a);
                vault.claim(t);
            } else {
                vm.roll(vm.getBlockNumber() + 1);
            }
            _check();
        }
        for (uint256 i = 0; i < 3000 && handler.accruedTax(t) > 0; i++) {
            vm.roll(vm.getBlockNumber() + 1); // audit 5: one chunk budget per block
            vm.prank(owner);
            handler.process(t, type(uint256).max, 1);
        }
        assertEq(vault.unsoldUnits(t), 0, "all sold");
        _check();
        for (uint256 i = 0; i < holders.length; i++) {
            assertEq(vault.pendingUnits(t, holders[i]), 0);
        }
    }
}
