// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SharedDividendVault} from "../../../src/common/SharedDividendVault.sol";
import {A5Quote} from "./VaultUnitsInvariant.t.sol";

/// @notice audit5a: extreme magnitudes, long gaps, 1-wei chunks, gas.
contract VaultEdgesTest is Test {
    SharedDividendVault vault;
    A5Quote quote;
    address constant T = address(0x7a7);
    address a = address(0xA1);
    address b = address(0xA2);

    function setUp() public {
        quote = new A5Quote();
        vault = new SharedDividendVault(address(this));
        vault.setLaunchpad(address(this), true);
        vault.registerToken(T, address(quote));
        quote.approve(address(vault), type(uint256).max);
    }

    function _convert(uint256 units, uint256 amount) internal {
        quote.mint(address(this), amount);
        vault.convertDividend(T, units, amount);
    }

    function test_hugeSharesTinyBatch() public {
        vault.setShare(T, a, 1e27);
        vault.setShare(T, b, 3e27);
        for (uint256 i = 0; i < 1000; i++) {
            vault.accrueDividendUnits(T, 4); // 4 wei of tax at a time
            _convert(4, 4);
        }
        assertEq(vault.pending(T, a), 1000, "a: exactly a quarter");
        assertEq(vault.pending(T, b), 3000, "b: exactly three quarters");
    }

    function test_tinyShareHugeBatch() public {
        vault.setShare(T, a, 1);
        vault.setShare(T, b, 1e27 - 1);
        vault.accrueDividendUnits(T, 1e27);
        _convert(1e27, 1e27);
        assertEq(vault.pending(T, a), 1);
        assertEq(vault.pending(T, b), 1e27 - 1);
    }

    function test_uint128Edge() public {
        vault.setShare(T, a, 1);
        vault.accrueDividendUnits(T, type(uint128).max);
        vm.expectRevert(); // a batch can't exceed uint128 (the handler then pays that part elsewhere)
        vault.accrueDividendUnits(T, 1);
        _convert(type(uint128).max, type(uint128).max);
        assertEq(vault.pending(T, a), type(uint128).max);
    }

    function test_oneWeiChunksSettle() public {
        vault.setShare(T, a, 7e18);
        vault.setShare(T, b, 3e18);
        vault.accrueDividendUnits(T, 500);
        for (uint256 i = 0; i < 499; i++) {
            _convert(1, 2);
            vault.accrueDividendUnits(T, 1); // keeps the open batch filling during the sale
        }
        assertEq(vault.pending(T, a), 0, "not settled until the last unit");
        _convert(1, 2);
        (,, uint64 settled) = vault.pipeOf(T);
        assertEq(settled, 1);
        assertEq(vault.pending(T, a), 700);
        assertEq(vault.pending(T, b), 300);
    }

    /// @dev A holder untouched for 2,000 batches costs the same to touch as after one.
    function test_gasFlatAcrossManyBatches() public {
        vault.setShare(T, a, 1e24);
        vault.setShare(T, b, 1e24);
        vault.accrueDividendUnits(T, 1e18);
        _convert(1e18 / 2, 1e18);
        uint256 g = gasleft();
        vault.setShare(T, b, 2e24);
        uint256 g1 = g - gasleft();
        for (uint256 i = 0; i < 2000; i++) {
            vault.accrueDividendUnits(T, 1e18);
            _convert(vault.unsoldUnits(T) / 2 + 1, 1e18);
        }
        g = gasleft();
        vault.setShare(T, a, 0);
        uint256 g2 = g - gasleft();
        emit log_named_uint("touch after 1 batch", g1);
        emit log_named_uint("touch after 2000 batches", g2);
        assertLt(g2, 150_000); // O(1): only slot temperature differs
        vm.prank(a);
        vault.claim(T);
    }
}
