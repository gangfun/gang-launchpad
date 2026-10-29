// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";

contract TTQuote is ERC20("Q", "Q") {
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @notice Tax-time dividends in SharedDividendVault: the holders' part of a pool tax is credited to whoever held at
///         the moment it was taxed, in units, and paid in quote once those units are sold (FIFO batches, ≤ 2 open).
///         This contract plays the core (it registered the token), so it may write shares and units.
contract TaxTimeDividendsTest is Test {
    SharedDividendVault vault;
    TTQuote quote;
    address constant TOKEN = address(0x7a7);
    address[4] users = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];

    function _fresh() internal {
        quote = new TTQuote();
        vault = new SharedDividendVault(address(this));
        vault.setLaunchpad(address(this), true);
        vault.registerToken(TOKEN, address(quote));
        quote.approve(address(vault), type(uint256).max);
    }

    function _convert(uint256 units, uint256 amount) internal {
        quote.mint(address(this), amount);
        vault.convertDividend(TOKEN, units, amount);
    }

    // ---------------------------------------------------------------- examples
    /// @dev Tax paid while A holds; A sells everything after, B buys after: A gets it all, B nothing.
    function test_creditedToWhoHeldWhenTaxed() public {
        _fresh();
        vault.setShare(TOKEN, users[0], 100 ether);
        vault.accrueDividendUnits(TOKEN, 1_000 ether); // the tax of some trade, while A holds

        vault.setShare(TOKEN, users[0], 0); // A sells out
        vault.setShare(TOKEN, users[1], 100 ether); // B buys after the tax
        assertEq(vault.pendingUnits(TOKEN, users[0]), 1_000 ether, "units stay A's");
        assertEq(vault.pendingUnits(TOKEN, users[1]), 0);

        _convert(1_000 ether, 3 ether); // the tax is sold later
        assertEq(vault.pending(TOKEN, users[0]), 3 ether, "A: all of it");
        assertEq(vault.pending(TOKEN, users[1]), 0, "B bought after the tax");
        vm.prank(users[0]);
        vault.claim(TOKEN);
        assertEq(quote.balanceOf(users[0]), 3 ether);
    }

    /// @dev §19 (only tax-time dividends left): a share change settles the units the old share earned first, so a
    ///      holder who shrinks, claims mid-way and grows again gets exactly its share of each tax at that moment.
    function test_shareChangeSettlesOldUnitsFirst_claimBetween() public {
        _fresh();
        vault.setShare(TOKEN, users[0], 100 ether);
        vault.setShare(TOKEN, users[1], 100 ether);
        vault.accrueDividendUnits(TOKEN, 1_000 ether); // A 500, B 500
        vault.setShare(TOKEN, users[0], 25 ether); // A sells 75%
        vault.accrueDividendUnits(TOKEN, 1_000 ether); // A 200, B 800
        assertEq(vault.pendingUnits(TOKEN, users[0]), 700 ether, "A: 500 + 200");
        _convert(2_000 ether, 4 ether); // 2 quote per 1,000 units
        assertEq(vault.pending(TOKEN, users[0]), 1.4 ether);
        vm.prank(users[0]);
        vault.claim(TOKEN);
        assertEq(quote.balanceOf(users[0]), 1.4 ether);
        assertEq(vault.pending(TOKEN, users[0]), 0, "claimed");

        vault.setShare(TOKEN, users[0], 300 ether); // A buys back: only later tax counts at the new share
        vault.accrueDividendUnits(TOKEN, 1_000 ether); // A 750, B 250
        _convert(1_000 ether, 1 ether);
        assertEq(vault.pending(TOKEN, users[0]), 0.75 ether, "A: new share, new tax only");
        assertEq(vault.pending(TOKEN, users[1]), 2.6 ether + 0.25 ether, "B: 500 + 800 units, then 250");
        assertEq(vault.pendingUnits(TOKEN, users[0]) + vault.pendingUnits(TOKEN, users[1]), 0, "all settled");
    }

    /// @dev Units turn into quote only when their whole batch is sold, at what the batch fetched; oldest first.
    function test_fifoBatchesSettleInOrder() public {
        _fresh();
        vault.setShare(TOKEN, users[0], 100 ether);
        vault.accrueDividendUnits(TOKEN, 600 ether); // batch 1, A alone
        _convert(200 ether, 1 ether); // batch 1 starts selling; batch 2 opens
        assertEq(vault.pending(TOKEN, users[0]), 0, "not settled yet");

        vault.setShare(TOKEN, users[1], 100 ether);
        vault.accrueDividendUnits(TOKEN, 400 ether); // batch 2: A and B half each
        assertEq(vault.unsoldUnits(TOKEN), 800 ether);

        // one sale spans the rest of batch 1 (400) and half of batch 2 (200): 6 quote for 600 units
        _convert(600 ether, 6 ether);
        (uint64 open, uint64 selling, uint64 settled) = vault.pipeOf(TOKEN);
        assertEq(settled, 1);
        assertEq(selling, 2);
        assertEq(open, 3);
        // batch 1: 600 units fetched 1 + 4 = 5 → all A's
        assertEq(vault.pending(TOKEN, users[0]), 5 ether);
        assertEq(vault.pending(TOKEN, users[1]), 0);

        _convert(200 ether, 2 ether); // batch 2: 400 units fetched 2 + 2 = 4, half each
        assertEq(vault.pending(TOKEN, users[0]), 7 ether);
        assertEq(vault.pending(TOKEN, users[1]), 2 ether);
        assertEq(vault.unsoldUnits(TOKEN), 0);
    }

    /// @dev A holder untouched across many settled batches is paid through the cumulative index in one step.
    function test_untouchedHolderAcrossManyBatches() public {
        _fresh();
        vault.setShare(TOKEN, users[0], 300 ether);
        vault.setShare(TOKEN, users[1], 100 ether);
        for (uint256 i = 0; i < 30; i++) {
            vault.accrueDividendUnits(TOKEN, 40 ether);
            _convert(40 ether, 1 ether);
        }
        assertEq(vault.pending(TOKEN, users[0]), 22.5 ether);
        assertEq(vault.pending(TOKEN, users[1]), 7.5 ether);
    }

    function test_onlyTheCoreOrItsOperator() public {
        _fresh();
        vault.setShare(TOKEN, users[0], 1 ether);
        vm.prank(users[1]);
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        vault.accrueDividendUnits(TOKEN, 1);
        vm.prank(users[1]);
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        vault.convertDividend(TOKEN, 1, 0);
    }

    function test_noSharesNoUnits_moreThanUnsoldRefused() public {
        _fresh();
        vm.expectRevert(SharedDividendVault.NoShares.selector);
        vault.accrueDividendUnits(TOKEN, 1 ether);
        vault.setShare(TOKEN, users[0], 1 ether);
        vault.accrueDividendUnits(TOKEN, 1 ether);
        quote.mint(address(this), 1);
        vm.expectRevert(SharedDividendVault.TooManyUnits.selector);
        vault.convertDividend(TOKEN, 1 ether + 1, 1);
    }

    // ---------------------------------------------------------------- fuzz against a brute-force model
    // model: units each holder earned in each batch (credited share × units / total at that moment), and the quote
    // that is exactly theirs once a batch settles (their units × batch quote / batch units)
    mapping(uint256 => mapping(uint256 => uint256)) mUnits; // batch → user → units (1e18 extra precision)
    mapping(uint256 => uint256) mClaimed; // user → claimed
    uint256[4] mShares;

    /// @dev Exactly `u`'s still-unclaimed quote, with 1e18 extra precision (can dip below 0 by rounding only).
    function _exactClaimableX(uint256 u) internal view returns (int256) {
        (,, uint64 settled) = vault.pipeOf(TOKEN);
        uint256 sum;
        for (uint256 b = 1; b <= settled; b++) {
            (uint256 bu,, uint256 bq,,) = vault.batchOf(TOKEN, b);
            sum += Math.mulDiv(mUnits[b][u], bq, bu);
        }
        return int256(sum) - int256(mClaimed[u] * 1e18);
    }

    function testFuzz_matchesExactModel(uint256 seed) public {
        _fresh();
        uint256 ops;
        for (uint256 step = 0; step < 60; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 kind = r % 5;
            uint256 u = (r >> 8) % 4;
            if (kind == 0) {
                // share change (a trade / transfer); 0 sometimes
                uint256 s = (r >> 16) % 3 == 0 ? 0 : (((r >> 24) % 1_000) + 1) * 1 ether;
                vault.setShare(TOKEN, users[u], s);
                mShares[u] = vault.shares(TOKEN, users[u]);
            } else if (kind == 1 || kind == 2) {
                uint256 ts = vault.totalShares(TOKEN);
                if (ts == 0) continue;
                uint256 units = (((r >> 32) % 10_000) + 1) * 1e15;
                (uint64 open,,) = vault.pipeOf(TOKEN);
                uint256 b = open == 0 ? 1 : open;
                for (uint256 i = 0; i < 4; i++) {
                    mUnits[b][i] += Math.mulDiv(units * 1e18, mShares[i], ts);
                }
                vault.accrueDividendUnits(TOKEN, units);
                ops++;
            } else if (kind == 3) {
                uint256 unsold = vault.unsoldUnits(TOKEN);
                if (unsold == 0) continue;
                uint256 units = (r >> 40) % 2 == 0 ? unsold : ((r >> 48) % unsold) + 1;
                uint256 amount = (((r >> 56) % 1_000) + 1) * 1e14;
                _convert(units, amount);
                ops++;
            } else {
                uint256 p = vault.pending(TOKEN, users[u]);
                if (p == 0) continue;
                vm.prank(users[u]);
                vault.claim(TOKEN);
                mClaimed[u] += p;
            }
            // every holder: never more than exactly theirs, and only rounding below it
            uint256 owedAll;
            for (uint256 i = 0; i < 4; i++) {
                int256 exactX = _exactClaimableX(i);
                int256 gotX = int256(vault.pending(TOKEN, users[i]) * 1e18);
                // at most 1 wei over the exact amount per payout so far, and only rounding below it
                assertLe(gotX, exactX + int256((ops + 1) * 1e18), "never more than exact");
                assertGe(gotX + int256(4 * (ops + 1) * 1e18) + exactX / 1e15, exactX, "only rounding below exact");
                owedAll += vault.pending(TOKEN, users[i]);
            }
            assertGe(quote.balanceOf(address(vault)), owedAll, "vault pays everyone");
        }
    }
}
