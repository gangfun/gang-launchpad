// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPair} from "../../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {TaxLaunchTokenV3} from "../../../src/launchpad-v3/TaxLaunchTokenV3.sol";
import {LaunchpadV3Test} from "../../launchpad-v3/LaunchpadV3.t.sol";

/// @notice audit5a: who decides when (and at what price) the holders' tax tokens are sold.
contract SwapBackTimingTest is LaunchpadV3Test {
    address t;
    MockPair pair;
    address whale = address(uint160(0xB0000));

    function _setup() internal {
        t = _create(_tax(100, 100, 10_000, address(0))); // 1% / 1%, all of the rest to holders
        _graduate(t);
        pair = MockPair(TaxLaunchTokenV3(t).pair());
        for (uint256 i = 0; i < 12; i++) _poolBuy(t, address(uint160(0xC0000 + i)), 20 ether); // backlog
        // whale gathers tokens (untaxed wallet transfers)
        for (uint256 i = 1; i < 60; i++) {
            address w = address(uint160(0xB0000 + i));
            uint256 bal = IERC20(t).balanceOf(w);
            if (bal == 0) break;
            vm.prank(w);
            IERC20(t).transfer(whale, bal);
        }
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev Audit 5 A L-1a (regression): a dust taxed sell at the top of the block only uses a dust slice of the
    ///      block's budget; a real sell after it in the same block still sells a chunk.
    function test_dustSellNoLongerTakesTheBlocksSwapBack() public {
        _setup();
        address griefer = address(uint160(0xC0000));
        uint256 accrued0 = handler.accruedTax(t);
        _poolSell(t, griefer, 1e9); // 1% of it is taxed
        uint256 dustChunk = accrued0 + (1e9 * 100) / BPS - handler.accruedTax(t);
        assertLe(dustChunk, 1e9 / 4, "dust chunk");
        (, uint96 used) = handler.windowOf(t);
        assertEq(used, dustChunk, "only the dust is drawn from the budget");
        uint256 a1 = handler.accruedTax(t);
        uint256 sold = IERC20(t).balanceOf(whale) / 10;
        _poolSell(t, whale, sold);
        assertLt(handler.accruedTax(t), a1 + (sold * 100) / BPS, "the big sell still sold a chunk");
    }

    /// @dev Audit 5 A L-1b (regression): 1 wei of quote donated to the pair no longer skips the chunk, and a chunk
    ///      never sells more than 2% below the block's reference price — the "donate → dump → chunk" order now has the
    ///      dump sell its chunk first at the honest price, and the small sell after it sells none.
    function test_donationNoLongerLetsTheChunkRunAfterADump() public {
        _setup();
        uint256 dump = IERC20(t).balanceOf(whale) / 2;
        uint256 small = 4 * handler.maxChunk(t) * 3;

        uint256 snap = vm.snapshotState();
        uint256 v0 = quoteTok.balanceOf(address(divVault));
        _poolSell(t, whale, dump);
        uint256 honest = quoteTok.balanceOf(address(divVault)) - v0;
        vm.revertToState(snap);

        quoteTok.mintUnlimited(address(pair), 1);
        uint256 a0 = handler.accruedTax(t);
        v0 = quoteTok.balanceOf(address(divVault));
        _poolSell(t, whale, dump);
        assertLt(handler.accruedTax(t), a0 + (dump * 100) / BPS, "the dump sold its chunk (1 wei is absorbed)");
        assertEq(quoteTok.balanceOf(address(divVault)) - v0, honest, "at the honest price");
        uint256 a1 = handler.accruedTax(t);
        _poolSell(t, whale, small);
        assertEq(handler.accruedTax(t), a1 + (small * 100) / BPS, "no chunk below the block's reference price");
    }
}
