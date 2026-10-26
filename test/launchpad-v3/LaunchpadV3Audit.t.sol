// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MigratorV2} from "../../src/launchpad-v2/MigratorV2.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {LaunchpadV3} from "../../src/launchpad-v3/LaunchpadV3.sol";
import {TaxTokenDeployerV3} from "../../src/launchpad-v3/TaxLaunchTokenV3.sol";
import {LaunchpadV3Test} from "./LaunchpadV3.t.sol";

contract SixDecimalQuoteV3 is ERC20("Six", "SIX") {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice Regressions for the 2026-10-26 internal audit (docs/AUDIT-BRIEF-2026-10-26.md §10).
contract LaunchpadV3AuditTest is LaunchpadV3Test {
    /// @dev A-2: ungated, a listed router could buy for the future pair before graduation.
    function test_audit_buyForNeedsGate() public {
        address t = _create(_tax(200, 200, 0, treasury));
        vm.startPrank(owner);
        pad.setRouter(address(this), true);
        pad.setAgentGate(false, address(0));
        vm.stopPrank();
        quoteTok.mintUnlimited(address(this), 1 ether);
        quoteTok.approve(address(pad), type(uint256).max);
        vm.expectRevert(LaunchpadV3.RouterNeedsGate.selector);
        pad.buyFor(makeAddr("pair"), t, 0.01 ether, 0);
    }

    /// @dev A-3 / A-6: only WBNB or a listed 18-decimal quote.
    function test_audit_quoteWhitelist() public {
        MockSPCXB unlisted = new MockSPCXB();
        vm.prank(agent);
        vm.expectRevert(LaunchpadV3.QuoteNotAllowed.selector);
        pad.create("Q", "Q", "", address(unlisted), address(0), _tax(200, 200, 0, treasury));

        SixDecimalQuoteV3 six = new SixDecimalQuoteV3();
        vm.prank(owner);
        quoteRegistry.setQuote(address(six), true, 9_000e6);
        vm.prank(agent);
        vm.expectRevert(LaunchpadV3.QuoteNotAllowed.selector);
        pad.create("S", "S", "", address(six), address(0), _tax(200, 200, 0, treasury));
    }

    /// @dev Low: a migrator bound to another pad would make every graduation revert, and setMigrator is one-shot.
    function test_audit_setMigratorChecksPad() public {
        LaunchpadV3 fresh = new LaunchpadV3(
            owner,
            address(quoteRegistry),
            address(divVault),
            address(bucket),
            address(handler),
            address(router),
            address(recipients),
            address(new TaxTokenDeployerV3()),
            address(wbnb),
            address(pairFactory)
        );
        vm.prank(owner);
        vm.expectRevert(LaunchpadV3.WrongMigrator.selector);
        fresh.setMigrator(address(migrator)); // bound to `pad`
        MigratorV2 own = new MigratorV2(address(pairFactory), address(fresh));
        vm.prank(owner);
        fresh.setMigrator(address(own));
    }

    /// @dev Low: a seller used to earn its pro-rata part of its own sell tax (tax split before its share shrank).
    ///      A sole holder selling everything with a 5% sell tax, 100% dividends, got 4.5% of volume back.
    function test_audit_sellerEarnsNothingOfOwnSellTax() public {
        address t = _create(_tax(500, 500, 10_000, address(0)));
        vm.prank(agent);
        pad.buy(t, 1 ether, 0); // first buy: no holders yet → dividend leg to the platform
        uint256 bal = IERC20(t).balanceOf(agent);
        vm.startPrank(agent);
        IERC20(t).approve(address(pad), bal);
        pad.sell(t, bal, 0);
        vm.stopPrank();
        assertEq(divVault.shares(t, agent), 0);
        assertEq(divVault.pending(t, agent), 0, "no rebate of its own sell tax");
    }

    /// @dev The other holders still earn the seller's sell tax.
    function test_audit_sellTaxStillPaysOtherHolders() public {
        address t = _create(_tax(500, 500, 10_000, address(0)));
        vm.prank(agent);
        pad.buy(t, 0.1 ether, 0);
        vm.prank(agent2);
        pad.buy(t, 0.1 ether, 0);
        uint256 before = divVault.pending(t, agent);
        uint256 bal = IERC20(t).balanceOf(agent2);
        vm.startPrank(agent2);
        IERC20(t).approve(address(pad), bal);
        pad.sell(t, bal, 0);
        vm.stopPrank();
        assertGt(divVault.pending(t, agent), before, "agent earns agent2's sell tax");
        assertEq(divVault.shares(t, agent2), 0);
    }
}
