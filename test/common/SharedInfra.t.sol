// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangToken as TaxLaunchTokenV3} from "../../src/gang/GangToken.sol";
import {GangTaxHandler as TaxHandlerV3} from "../../src/gang/GangTaxHandler.sol";
import {MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {GangRouterTest} from "../router/GangRouter.t.sol";

/// @notice One GangLaunchpad, two kinds (curve / 打新) on one SharedDividendVault, SharedMigrator, TokenDeployer and
///         handler (GangRouterTest's setup is that deployment): each kind graduates / launches on its own, the kind is
///         fixed at create, one vault floor for both, strangers are refused everywhere.
contract SharedInfraTest is GangRouterTest {
    function _graduateV3(address token) internal {
        for (uint256 i = 0; i < 200 && !_v3Graduated(token); i++) {
            address w = address(uint160(0xE0000 + i));
            _agent(w);
            vm.prank(w, w);
            router.v3BuyBNB{value: 1 ether}(token, 0, block.timestamp);
        }
        assertTrue(_v3Graduated(token), "V3 graduated");
    }

    /// @dev `who` sells `amount` of a graduated V3 token straight into its (mock) pair: the pool sell tax applies.
    function _poolSellV3(address token, address who, uint256 amount) internal {
        MockPair pair = MockPair(TaxLaunchTokenV3(token).pair());
        vm.prank(who);
        IERC20(token).transfer(address(pair), amount);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool t0 = pair.token0() == token;
        (uint256 rT, uint256 rQ) = t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inAmt = IERC20(token).balanceOf(address(pair)) - rT;
        uint256 out = (inAmt * rQ) / (rT + inAmt) / 2;
        if (t0) pair.swap(0, out, who, "");
        else pair.swap(out, 0, who, "");
    }

    function _launchFair(address token) internal {
        for (uint256 i = 0; i < 101; i++) {
            address m = address(uint160(0xF0000 + i));
            _agent(m);
            vm.prank(m, m);
            router.fairMintBNB{value: 1 ether}(token, 100, 1, block.timestamp);
            if (fair.status(token) == IGangLaunchpad.Status.Launched) return;
        }
        revert("not launched");
    }

    function test_shared_oneCoreTwoKinds() public {
        assertEq(address(v3), address(fair), "one pad");
        address a = _v3Token(5000);
        address b = _fairSale();
        assertEq(v3.kindOf(a), 1, "curve kind");
        assertEq(v3.kindOf(b), 2, "fair kind");
        assertEq(v3.kindOf(address(wbnb)), 0, "not a pad token");
        assertEq(v3.tokenCount(), 2);
        assertEq(v3.allTokens(0), a);
        assertEq(v3.allTokens(1), b);
        assertEq(v3Vault.launchpadOf(a), address(v3));
        assertEq(v3Vault.launchpadOf(b), address(v3));
        // a curve token has no sale, a sale no curve
        (address saleCreator,,,,,,,,,,,,,) = fair.sales(a);
        (address curveCreator,,,,,,,,,,,) = v3.curves(b);
        assertEq(saleCreator, address(0));
        assertEq(curveCreator, address(0));
        vm.prank(agent);
        vm.expectRevert(IGangLaunchpad.UnknownToken.selector);
        fair.mint(a, 1, 1);
        vm.prank(agent);
        vm.expectRevert(IGangLaunchpad.UnknownToken.selector);
        v3.buy(b, 1 ether, 0);

        vm.prank(agent2, agent2);
        router.v3BuyBNB{value: 0.5 ether}(a, 0, block.timestamp);
        assertGt(v3Vault.shares(a, agent2), 0, "V3 holder's share written on the curve");
        assertEq(v3Vault.pending(a, agent2), 0, "V3 holders earn only from the pool tax");
        assertEq(v3Vault.unsoldUnits(b), 0, "nothing reached the fair token");

        _launchFair(b);
        _graduateV3(a);
        (,,,,,,,,,,, address pairB,,) = fair.sales(b);
        (,,,,,,,,,, address pairA,) = v3.curves(a);
        assertTrue(pairA != address(0) && pairB != address(0) && pairA != pairB, "each through the one migrator");
        assertEq(v3.kindOf(a), 1, "kind never changes");
        assertEq(v3.kindOf(b), 2, "kind never changes");
        assertEq(v3Vault.minimumShareBalanceFor(a), 10_000 ether);
        assertEq(v3Vault.minimumShareBalanceFor(b), fair.MIN_SHARE_BALANCE());
    }

    function test_shared_onlyListedCallers() public {
        address b = _fairSale();
        address stranger = makeAddr("stranger");
        TaxHandlerV3 h = TaxHandlerV3(v3.taxHandler());
        vm.startPrank(stranger);
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        v3Vault.registerToken(makeAddr("t"), address(wbnb));
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        v3Vault.ensureMinimumShareBalance(1);
        vm.expectRevert(TokenDeployer.OnlyLaunchpad.selector);
        tokenDeployer.deploy("X", "X", "", stranger, 100, 100, true);
        vm.expectRevert(TokenDeployer.OnlyLaunchpad.selector);
        tokenDeployer.deploy("X", "X", "", stranger, 0, 0, false);
        vm.expectRevert(TokenDeployer.OnlyLaunchpad.selector);
        tokenDeployer.deploy("X", "X", "", stranger, 100, 100, false);
        vm.expectRevert(TokenDeployer.OnlyLaunchpad.selector);
        tokenDeployer.deploy("X", "X", "", address(0), 0, 0, false);
        vm.expectRevert(SharedMigrator.OnlyLaunchpad.selector);
        sharedMig.migrate(b, address(wbnb), 1, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sharedMig.addLaunchpad(stranger);
        vm.expectRevert(TaxHandlerV3.OnlyLaunchpad.selector);
        h.register(address(0xBEEF), address(wbnb), address(0), 5000, 2);
        vm.stopPrank();

        // the pad can't take over a registered token
        vm.prank(address(v3));
        vm.expectRevert(SharedDividendVault.AlreadyRegistered.selector);
        v3Vault.registerToken(b, address(wbnb));
        // operators bind to a listed core only
        vm.prank(owner);
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        v3Vault.setOperator(stranger, stranger);
    }

    /// @dev Kept from the two-core test_shared_handlerCannotTouchOtherCoresToken (feat/merge-handler added the
    ///      accrueDividendUnits / convertDividend legs): with one pad and one handler, nobody but the handler writes
    ///      the vault for either kind, and permissionless syncShares never zeroes a V3 holder's share.
    function test_shared_nobodyButTheHandlerWritesTheVault() public {
        address a = _v3Token(5000);
        address b = _fairSale();
        vm.prank(agent2, agent2);
        router.v3BuyBNB{value: 0.5 ether}(a, 0, block.timestamp);
        uint256 shareA = v3Vault.shares(a, agent2);
        assertGt(shareA, 0);
        address h = address(v3.taxHandler());
        (bool ok,) = h.call(abi.encodeCall(TaxHandlerV3.syncShares, (a, agent2, address(0))));
        ok; // reverts or re-writes the same balance; either way the V3 share stands
        assertEq(v3Vault.shares(a, agent2), shareA, "syncShares left the V3 share alone");

        address stranger = makeAddr("strangerHandler");
        address[2] memory toks = [a, b];
        for (uint256 i; i < 2; i++) {
            vm.startPrank(stranger);
            vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
            v3Vault.setShare(toks[i], agent2, 0);
            vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
            v3Vault.accrueDividendUnits(toks[i], 1);
            vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
            v3Vault.convertDividend(toks[i], 1, 0);
            vm.stopPrank();
        }
        assertEq(v3Vault.shares(a, agent2), shareA, "V3 share untouched");
    }

    /// @dev Delisting the pad stops new tokens of both kinds; its existing tokens keep trading and earning.
    function test_shared_ownerRemovesCore_existingTokensKeepWorking() public {
        address a = _v3Token(5000);
        vm.prank(agent2, agent2);
        router.v3BuyBNB{value: 0.5 ether}(a, 0, block.timestamp);

        vm.startPrank(owner);
        v3Vault.setLaunchpad(address(v3), false);
        tokenDeployer.setLaunchpad(address(v3), false);
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(TokenDeployer.OnlyLaunchpad.selector);
        v3.create("New", "NEW", "", "", address(0), address(0), _tax(5000));
        IGangLaunchpad.MintConfig memory cfg = IGangLaunchpad.MintConfig({
            raiseBnb: 15 ether, capBps: 50, holdBps: 6000, mintFeeBps: 100, exitFeeBps: 200
        });
        vm.prank(agent);
        vm.expectRevert(TokenDeployer.OnlyLaunchpad.selector);
        fair.create("Fair", "FAIR", "", "", address(0), address(0), cfg, 1);

        vm.prank(agent, agent);
        router.v3BuyBNB{value: 0.5 ether}(a, 0, block.timestamp);
        assertGt(v3Vault.shares(a, agent), 0, "existing token: shares still written");
        // dividends come from the pool tax (§19: none on the curve): graduate, sell into the pool, sell the tax
        _graduateV3(a);
        _poolSellV3(a, address(uint160(0xE0000)), IERC20(a).balanceOf(address(uint160(0xE0000))));
        assertGt(v3Vault.pendingUnits(a, agent2), 0, "existing token: pool tax credited");
        vm.roll(vm.getBlockNumber() + 1);
        TaxHandlerV3 handler = TaxHandlerV3(v3.taxHandler());
        vm.prank(owner);
        handler.process(a, type(uint256).max, 1);
        assertGt(v3Vault.pending(a, agent2), 0, "existing token: dividends still paid");
        vm.prank(agent2);
        uint256 got = v3Vault.claim(a);
        assertGt(got, 0, "claims never depend on the core");
    }

    /// @dev One floor for both kinds (TAXED_MIN_SHARE == MIN_SHARE_BALANCE). Raised above it: 打新 refuses every new
    ///      sale, V3 refuses new dividend tokens only (audit 5 C-F4) — the two checks keep their own timing.
    function test_shared_oneFloor() public {
        assertEq(v3.TAXED_MIN_SHARE(), fair.MIN_SHARE_BALANCE());
        address b0 = _fairSale();
        assertEq(v3Vault.minimumShareBalanceOf(address(v3)), 10_000 ether);
        assertEq(v3Vault.minimumShareBalanceFor(b0), 10_000 ether);

        vm.prank(owner);
        v3Vault.setMinimumShareBalance(address(v3), 100_000_000 ether);
        IGangLaunchpad.MintConfig memory cfg = IGangLaunchpad.MintConfig({
            raiseBnb: 15 ether, capBps: 50, holdBps: 6000, mintFeeBps: 100, exitFeeBps: 200
        });
        vm.prank(agent);
        vm.expectRevert(IGangLaunchpad.VaultFloorTooHigh.selector);
        fair.create("Fair", "FAIR", "", "", address(0), address(0), cfg, 1);
        vm.prank(agent);
        vm.expectRevert(IGangLaunchpad.VaultFloorTooHigh.selector);
        v3.create("Tax", "TAX", "", "", address(0), address(0), _tax(5000));
        address plain = _v3Token(0); // no dividend: the floor plays no part
        assertTrue(plain != address(0));
        assertEq(v3Vault.minimumShareBalanceFor(b0), 10_000 ether, "existing token keeps its floor");
    }
}
