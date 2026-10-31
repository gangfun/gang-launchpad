// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PostGradHandlerBase} from "../../src/common/PostGradHandlerBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {GangLaunchpad as LaunchpadV3} from "../../src/gang/GangLaunchpad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangToken as TaxLaunchTokenV3} from "../../src/gang/GangToken.sol";
import {GangTaxHandler as TaxHandlerV3} from "../../src/gang/GangTaxHandler.sol";
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
        address pair = makeAddr("pair");
        // §23: the future pair is never tx.origin
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        pad.buyFor(pair, t, 0.01 ether, 0);
        // and the A-2 check is still there behind it (even for the sender of the tx)
        vm.prank(address(this), pair);
        vm.expectRevert(IGangLaunchpad.RouterNeedsGate.selector);
        pad.buyFor(pair, t, 0.01 ether, 0);
    }

    /// @dev Quote rules (2026-10-27, V2 pricing kept): WBNB or any 18-decimal ERC-20; no fixed rate → a reference pool is
    ///      required. A-3: low decimals and non-tokens are refused even with a fixed rate.
    function test_audit_quoteRules() public {
        MockSPCXB unlisted = new MockSPCXB();
        vm.prank(agent);
        vm.expectRevert(IGangLaunchpad.RefPoolRequired.selector);
        pad.create("Q", "Q", "", "", address(unlisted), address(0), _tax(200, 200, 0, treasury));

        SixDecimalQuoteV3 six = new SixDecimalQuoteV3();
        vm.prank(owner);
        quoteRegistry.setQuote(address(six), true, 9_000e6);
        vm.prank(agent);
        vm.expectRevert(IGangLaunchpad.QuoteNotAllowed.selector);
        pad.create("S", "S", "", "", address(six), address(0), _tax(200, 200, 0, treasury));

        vm.prank(agent);
        vm.expectRevert(IGangLaunchpad.QuoteNotAllowed.selector);
        pad.create("E", "E", "", "", makeAddr("notAToken"), address(0), _tax(200, 200, 0, treasury));
    }

    /// @dev An unlisted 18-decimal quote is priced like LaunchpadV2 from the creator's pool (300 Q : 150 WBNB → the 9 BNB
    ///      default = 18 Q); a QuoteRegistry fixed rate ("15 BNB worth", scaled to 9) wins over the pool and needs none.
    function test_create_refPoolPricesUnlistedQuote() public {
        MockSPCXB q = new MockSPCXB();
        address ref = pairFactory.createPair(address(q), address(wbnb));
        q.mintUnlimited(ref, 300 ether);
        wbnb.mintUnlimited(ref, 150 ether);
        MockPair(ref).mint(address(0xdead));

        assertEq(pad.graduationAmountOf(address(q), ref), 18 ether);
        vm.prank(agent);
        address t = pad.create("Q", "Q", "", "", address(q), ref, _tax(200, 200, 0, treasury));
        assertEq(pad.gradAmtOf(t), 18 ether, "unlisted quote priced from its pool");

        vm.prank(owner);
        quoteRegistry.setQuote(address(q), true, 60 ether);
        assertEq(pad.graduationAmountOf(address(q), ref), 36 ether);
        vm.prank(agent);
        t = pad.create("Q2", "Q2", "", "", address(q), address(0), _tax(200, 200, 0, treasury));
        assertEq(pad.gradAmtOf(t), 36 ether, "fixed rate wins");
    }

    /// @dev Low: a migrator bound to another pad would make every graduation revert, and setMigrator is one-shot.
    function test_audit_setMigratorChecksPad() public {
        LaunchpadV3 fresh = new LaunchpadV3(
            owner,
            address(quoteRegistry),
            address(divVault),
            address(bucket),
            address(handler),
            address(tokenDeployer),
            address(wbnb),
            address(pairFactory)
        );
        vm.prank(owner);
        vm.expectRevert(IGangLaunchpad.WrongMigrator.selector);
        fresh.setMigrator(address(migrator)); // the shared migrator does not list `fresh` yet
        vm.startPrank(owner);
        migrator.addLaunchpad(address(fresh));
        fresh.setMigrator(address(migrator));
        vm.stopPrank();
        assertEq(address(fresh.migrator()), address(migrator), "listed: one migrator serves both pads");
    }

    /// @dev Low: a seller used to earn its pro-rata part of its own sell tax (tax split before its share shrank).
    ///      A sole holder selling everything with a 5% sell tax, 100% dividends, got 4.5% of volume back.
    function test_audit_sellerEarnsNothingOfOwnSellTax() public {
        address t = _create(_tax(500, 500, 10_000, address(0)));
        vm.prank(agent);
        pad.buy(t, 1 ether, 0);
        uint256 bal = IERC20(t).balanceOf(agent);
        vm.startPrank(agent);
        IERC20(t).approve(address(pad), bal);
        pad.sell(t, bal, 0);
        vm.stopPrank();
        assertEq(divVault.shares(t, agent), 0);
        assertEq(divVault.pending(t, agent), 0, "no rebate of its own sell tax");
    }

    /// @dev §19: a curve sell pays no tax, so no holder earns from it (the pool keeps C-F7: audit5 tests).
    function test_audit_curveSellPaysNoHolder() public {
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
        assertEq(divVault.pending(t, agent), before, "no curve sell tax to earn");
        assertEq(before, 0, "nor from the curve buys");
        assertEq(divVault.shares(t, agent2), 0);
    }

    /// @dev Anyone can deploy a TaxLaunchTokenV3 bound to themselves with our handler and a 1 bps rate (its "platform
    ///      part" would be 50× its tax). Only route-registered tokens may accrue: the fake one's taxed transfer reverts.
    function test_audit_unregisteredTokenCannotAccrue() public {
        // the token contract itself is permissionless to deploy (TokenDeployer only lists our cores)
        TaxLaunchTokenV3 fake = new TaxLaunchTokenV3("Fake", "FAKE", "", address(this), address(handler), 1, 1, false);
        address fakePair = makeAddr("fakePair");
        fake.unlock(makeAddr("fakeMigrator"));
        fake.setPair(fakePair);
        address user = makeAddr("fakeUser");
        fake.transfer(user, 1_000_000 ether); // from the "launchpad" (this test): untaxed
        vm.prank(user);
        vm.expectRevert(TaxHandlerV3.UnknownToken.selector);
        fake.transfer(fakePair, 100_000 ether); // a taxed sell into the fake pair → notifyTax refuses
        assertEq(handler.accruedTax(address(fake)), 0);
        assertEq(handler.accruedPlatformTax(address(fake)), 0);
    }

    /// @dev The split pays in the route's quote; the pair the tax is sold into must be token / that quote — on the
    ///      pair path and on the DEX-router path (which picks its pool from the path and used to skip the check).
    function test_audit_processChecksPairQuote_bothPaths() public {
        address t = _create(_tax(200, 200, 0, treasury));
        _graduate(t);
        _poolSell(t, address(uint160(0xB0000)), 1_000_000 ether);
        assertGt(handler.accruedTax(t), 0);

        // a pair of the token against another quote (e.g. a rogue pool) stands in for the token's pair
        address other = pairFactory.createPair(t, address(wbnb));
        vm.mockCall(t, abi.encodeWithSignature("pair()"), abi.encode(other));

        vm.prank(keeper);
        vm.expectRevert(PostGradHandlerBase.PairQuoteMismatch.selector);
        handler.process(t, type(uint256).max, 1); // pair path

        vm.startPrank(owner);
        handler.proposeDexRouter(makeAddr("dexRouter"));
        vm.warp(vm.getBlockTimestamp() + handler.DEX_ROUTER_DELAY());
        handler.acceptDexRouter();
        vm.stopPrank();
        vm.prank(keeper);
        vm.expectRevert(PostGradHandlerBase.PairQuoteMismatch.selector);
        handler.process(t, type(uint256).max, 1); // router path: refused before any approve / swap

        vm.clearMockedCalls();
        assertGt(handler.accruedTax(t), 0, "nothing consumed");
    }

    /// @dev With the token's real pair the check passes and the tax is processed as before.
    function test_audit_processWithRealPair() public {
        address t = _create(_tax(200, 200, 0, treasury));
        _graduate(t);
        _poolSell(t, address(uint160(0xB0000)), 1_000_000 ether);
        uint256 before = quoteTok.balanceOf(treasury);
        vm.prank(keeper);
        uint256 out = handler.process(t, type(uint256).max, 1);
        assertGt(out, 0);
        assertGt(quoteTok.balanceOf(treasury), before, "recipient paid in the quote");
        assertEq(handler.accruedTax(t), 0);
    }

    /// @dev Merge (TaxRouterV3 + PostGradTaxHandlerV3 → TaxHandlerV3): owed recipient quote now sits in the same
    ///      contract as the pool tax it sells. When that quote is itself a token the handler taxes (X), `process(X)`
    ///      must leave the owed X alone (owedTotalOf), so `release` still pays it in full.
    ///      Audit 4: a launch token can no longer be a quote at all; the create checks are mocked away here so the
    ///      owedTotalOf guard (defence in depth) stays covered.
    function test_merge_owedQuoteNeverSoldByProcess() public {
        address x = _create(_tax(100, 300, 0, treasury));
        _graduate(x);
        _poolBuy(x, agent, 5 ether); // agent holds X; the handler accrues X pool tax
        uint256 accruedX = handler.accruedTax(x);
        assertGt(accruedX, 0);

        vm.prank(owner);
        quoteRegistry.setQuote(x, true, 15 ether); // X becomes a listed 18-decimal quote
        vm.prank(agent);
        vm.expectRevert(IGangLaunchpad.QuoteNotAllowed.selector);
        pad.create("Y", "Y", "", "", x, address(0), _tax(200, 200, 0, treasury));

        vm.mockCall(
            address(pad.tokenDeployer()), abi.encodeWithSignature("isLaunchToken(address)", x), abi.encode(false)
        );
        vm.mockCall(address(divVault), abi.encodeWithSignature("launchpadOf(address)", x), abi.encode(address(0)));
        vm.prank(agent);
        address y = pad.create("Y", "Y", "", "", x, address(0), _tax(200, 200, 0, treasury));
        vm.clearMockedCalls();
        // §19: Y's curve charges no tax, so Y graduates first (one buyer, cap off) and its pool tax makes the debt
        vm.prank(owner);
        pad.setWalletCapEnabled(false);
        vm.startPrank(agent);
        IERC20(x).approve(address(pad), type(uint256).max);
        pad.buy(y, 20 ether, 0);
        vm.stopPrank();
        assertTrue(_graduated(y), "Y graduated");
        assertEq(handler.owedOf(y), 0, "no curve tax: nothing owed yet");
        _poolSell(y, agent, IERC20(y).balanceOf(agent) / 2);
        assertGt(handler.accruedTax(y), 0, "Y pool tax accrued");

        // the recipient cannot take X right now: Y's pool tax, sold for X, is booked as owed, held here in X
        vm.roll(vm.getBlockNumber() + 1);
        vm.mockCallRevert(x, abi.encodeWithSelector(IERC20.transfer.selector, treasury), "");
        vm.prank(keeper);
        handler.process(y, type(uint256).max, 1);
        vm.clearMockedCalls();
        uint256 owed = handler.owedOf(y);
        assertGt(owed, 0, "owed in X");
        assertEq(handler.owedTotalOf(x), owed);
        assertEq(IERC20(x).balanceOf(address(handler)), accruedX + owed, "pool tax and owed side by side");

        vm.prank(keeper);
        handler.process(x, type(uint256).max, 1);
        assertEq(handler.accruedTax(x), 0);
        assertEq(IERC20(x).balanceOf(address(handler)), owed, "only the pool tax was sold");

        uint256 before = IERC20(x).balanceOf(treasury);
        assertEq(handler.release(y), owed);
        assertEq(IERC20(x).balanceOf(treasury) - before, owed);
        assertEq(handler.owedTotalOf(x), 0);
    }
}
