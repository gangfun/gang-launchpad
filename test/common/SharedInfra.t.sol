// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {FairMintPad} from "../../src/fair-mint/FairMintPad.sol";
import {HolderRewardHandler} from "../../src/fair-mint/HolderRewardHandler.sol";
import {LaunchpadV3} from "../../src/launchpad-v3/LaunchpadV3.sol";
import {TaxLaunchTokenV3} from "../../src/launchpad-v3/TaxLaunchTokenV3.sol";
import {TaxHandlerV3} from "../../src/launchpad-v3/TaxHandlerV3.sol";
import {MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {GangRouterTest} from "../router/GangRouter.t.sol";

/// @notice LaunchpadV3 and 打新 on one SharedDividendVault, one SharedMigrator, one TokenDeployer (GangRouterTest's
///         setup is that deployment). Each core's tokens stay its own: no cross-core writes, separate share floors.
contract SharedInfraTest is GangRouterTest {
    function _graduateV3(address token) internal {
        for (uint256 i = 0; i < 200 && !_v3Graduated(token); i++) {
            address w = address(uint160(0xE0000 + i));
            _agent(w);
            vm.prank(w);
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
            vm.prank(m);
            router.fairMintBNB{value: 1 ether}(token, 100, 1, block.timestamp);
            if (fair.status(token) == FairMintPad.Status.Launched) return;
        }
        revert("not launched");
    }

    function test_shared_oneVaultMigratorDeployerForBothCores() public {
        assertEq(address(v3.dividendVault()), address(fair.dividendVault()), "one vault");
        assertEq(address(v3.migrator()), address(fair.migrator()), "one migrator");
        assertEq(address(v3.tokenDeployer()), address(fair.tokenDeployer()), "one deployer");
        address a = _v3Token(5000);
        address b = _fairSale();
        assertEq(v3Vault.launchpadOf(a), address(v3));
        assertEq(v3Vault.launchpadOf(b), address(fair));
    }

    function test_shared_bothGraduate_dividendsStaySeparate() public {
        address a = _v3Token(5000);
        address b = _fairSale();
        vm.prank(agent2);
        router.v3BuyBNB{value: 0.5 ether}(a, 0, block.timestamp);
        vm.prank(agent);
        router.v3BuyBNB{value: 0.5 ether}(a, 0, block.timestamp); // §19: no curve tax, so no curve dividend
        assertGt(v3Vault.shares(a, agent2), 0, "V3 holder's share written on the curve");
        assertEq(v3Vault.pending(a, agent2), 0, "V3 holders earn only from the pool tax");
        assertEq(v3Vault.unsoldUnits(b), 0, "nothing reached the fair token");

        _launchFair(b);
        _graduateV3(a);
        (,,,,,,,,,,, address pairB,,) = fair.sales(b);
        assertTrue(pairB != address(0), "fair launched through the shared migrator");
        assertEq(v3Vault.unsoldUnits(a), 0, "no V3 pool tax yet: nothing credited to V3 holders");
        assertEq(v3Vault.pending(a, agent2), 0, "V3 holders earn only from the pool tax");
        assertEq(v3Vault.minimumShareBalanceFor(a), 10_000 ether);
        assertEq(v3Vault.minimumShareBalanceFor(b), fair.MIN_SHARE_BALANCE());
    }

    /// @dev syncShares is permissionless: the 打新 handler must not be able to zero a V3 holder's share (or the reverse).
    function test_shared_handlerCannotTouchOtherCoresToken() public {
        address a = _v3Token(5000);
        address b = _fairSale();
        vm.prank(agent2);
        router.v3BuyBNB{value: 0.5 ether}(a, 0, block.timestamp);
        uint256 shareA = v3Vault.shares(a, agent2);
        assertGt(shareA, 0);
        address fairHandler = fair.taxHandler();
        address v3Handler = address(v3.taxHandler());

        (bool ok,) = fairHandler.call(abi.encodeCall(HolderRewardHandler.syncShares, (a, agent2, address(0))));
        ok; // reverts or no-ops; either way the V3 share stands
        assertEq(v3Vault.shares(a, agent2), shareA, "fair handler left the V3 share alone");

        vm.prank(fairHandler);
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        v3Vault.setShare(a, agent2, 0);
        vm.prank(address(fair));
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        v3Vault.setShare(a, agent2, 0);
        vm.prank(fairHandler);
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        v3Vault.accrueDividendUnits(a, 1);
        vm.prank(fairHandler);
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        v3Vault.convertDividend(a, 1, 0);
        vm.prank(v3Handler);
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        v3Vault.setShare(b, agent, 0);
        vm.prank(address(v3));
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        v3Vault.setShare(b, agent, 0);
    }

    function test_shared_onlyListedCallers() public {
        address b = _fairSale();
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        v3Vault.registerToken(makeAddr("t"), address(wbnb));
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        v3Vault.ensureMinimumShareBalance(1);
        vm.expectRevert(TokenDeployer.OnlyLaunchpad.selector);
        tokenDeployer.deployFair("X", "X", stranger, "");
        vm.expectRevert(TokenDeployer.OnlyLaunchpad.selector);
        tokenDeployer.deployTax("X", "X", 100, 100, stranger, "");
        vm.expectRevert(TokenDeployer.OnlyLaunchpad.selector);
        tokenDeployer.deployPlain("X", "X", "");
        vm.expectRevert(SharedMigrator.OnlyLaunchpad.selector);
        sharedMig.migrate(b, address(wbnb), 1, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sharedMig.addLaunchpad(stranger);
        vm.stopPrank();

        // a listed core can't take over another core's token
        vm.prank(address(v3));
        vm.expectRevert(SharedDividendVault.AlreadyRegistered.selector);
        v3Vault.registerToken(b, address(wbnb));
        // operators bind to a listed core only
        vm.prank(owner);
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        v3Vault.setOperator(stranger, stranger);
    }

    /// @dev Removing a core stops new tokens; its existing tokens keep trading and earning, and the other core is untouched.
    function test_shared_ownerRemovesCore_existingTokensKeepWorking() public {
        address a = _v3Token(5000);
        vm.prank(agent2);
        router.v3BuyBNB{value: 0.5 ether}(a, 0, block.timestamp);

        vm.startPrank(owner);
        v3Vault.setLaunchpad(address(v3), false);
        tokenDeployer.setLaunchpad(address(v3), false);
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(TokenDeployer.OnlyLaunchpad.selector);
        v3.create("New", "NEW", "", "", address(0), address(0), _tax(5000));

        vm.prank(agent);
        router.v3BuyBNB{value: 0.5 ether}(a, 0, block.timestamp);
        assertGt(v3Vault.shares(a, agent), 0, "existing token: shares still written");
        // dividends come from the pool tax (§19: none on the curve): graduate, sell into the pool, sell the tax
        _graduateV3(a);
        _poolSellV3(a, address(uint160(0xE0000)), IERC20(a).balanceOf(address(uint160(0xE0000))));
        assertGt(v3Vault.pendingUnits(a, agent2), 0, "existing token: pool tax credited");
        vm.roll(vm.getBlockNumber() + 1);
        TaxHandlerV3 handler = v3.taxHandler();
        vm.prank(owner);
        handler.process(a, type(uint256).max, 1);
        assertGt(v3Vault.pending(a, agent2), 0, "existing token: dividends still paid");
        vm.prank(agent2);
        uint256 got = v3Vault.claim(a);
        assertGt(got, 0, "claims never depend on the core");

        address b = _fairSale(); // the other core is unaffected
        assertEq(v3Vault.launchpadOf(b), address(fair));
    }

    function test_shared_floorsArePerCore() public {
        vm.prank(owner);
        v3Vault.setMinimumShareBalance(address(v3), 100_000_000 ether);
        assertEq(v3Vault.minimumShareBalanceOf(address(fair)), 0, "fair floor untouched");
        address b = _fairSale(); // FairMintPad.VaultFloorTooHigh reads only its own floor
        assertEq(v3Vault.minimumShareBalanceFor(b), fair.MIN_SHARE_BALANCE());

        // audit 5 C-F4: a V3 floor raised above TAXED_MIN_SHARE refuses new dividend tokens (as 打新 does) instead of
        // creating one whose holders all sit below the floor
        vm.prank(agent);
        vm.expectRevert(LaunchpadV3.VaultFloorTooHigh.selector);
        v3.create("Tax", "TAX", "", "", address(0), address(0), _tax(5000));
        address plain = _v3Token(0); // no dividend: the floor plays no part
        assertTrue(plain != address(0));
    }
}
