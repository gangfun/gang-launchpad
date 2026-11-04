// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {FlyUpgradeHarness, Pad3LiveUpgrade} from "./Pad3LiveUpgrade.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {GangVaultLaunchpad} from "../../src/gang/GangVaultLaunchpad.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangVaultPad} from "../../src/gang/interfaces/IGangVaultPad.sol";
import {MockLockVault} from "../gang/VaultLaunchpad.t.sol";

/// @notice The vault mode upgrade on the LIVE GangLaunchpad 3.0 proxy (BSC mainnet fork): UpgradeGangLaunchpad3 checks
///         this build's implementation + module against the live one (simulated upgrade, snapshot of settings and the
///         newest tokens' records and views, phase-2 read-back), then the Safe's upgrade is executed as printed and the
///         vault mode runs on the same address: a vault listed and granted, a token created with it, bought through
///         the entry, locked (counted against the 1% cap, the vault refused as a trader), released, sold. The live
///         tokens' records and views read the same after the upgrade (the script's snapshot), and a token
///         created and bought before the upgrade buys and sells after it; a dividend token's lock / release keeps
///         the live dividend vault's shares at the balances. Agent IDs are mocked (balanceOf = 1 for everyone). No broadcast. Run it alone
///         (the script reads process-wide env vars).
/// @dev Needs BSC_RPC_URL (without it the test is skipped) and the live PoolCheck linked as on mainnet:
///      forge test --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
interface IShares {
    function shares(address token, address holder) external view returns (uint256);
}

contract Pad3VaultUpgradeForkTest is Test {
    address constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address constant ROUTER3 = 0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7;
    address constant PAD_1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    uint256 constant MAX_PER_WALLET = 10_000_000 ether;

    GangLaunchpad3 p = GangLaunchpad3(payable(PAD3));
    GangVaultLaunchpad vp = GangVaultLaunchpad(PAD3);
    address creator = makeAddr("pad3-vault-creator");
    address alice = makeAddr("pad3-vault-alice");

    function test_fork_upgradeLive3_vaultMode() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        uint256 pk = uint256(keccak256("GangLaunchpad 3.0 vault upgrade fork test: throwaway, never funded"));
        vm.deal(vm.addr(pk), 1 ether);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        _env(pk);

        // this build's implementation (and module) with the live one's dependencies, checked by the script
        address cur = R.implementationOf(PAD3);
        (FlyUpgradeHarness u, UpgradeGangLaunchpad3.Stack memory st) = Pad3LiveUpgrade.check();
        assertEq(R.implementationOf(PAD3), cur, "printed for the Safe, not sent");

        // a curve token made and bought on the live implementation, traded again after the upgrade
        IGangLaunchpad.TaxConfig memory untaxed;
        vm.prank(creator, creator);
        address live = p.create("Before", "BFR", "logo", "meta", M.WBNB, address(0), untaxed);
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        p.buyTokenAMAP{value: 0.01 ether}(live, alice, 0.01 ether, 0);
        uint256 held = IERC20(live).balanceOf(alice);

        // the Safe's batch: ProxyAdmin.upgradeAndCall(proxy, impl, "") — no set-up call (same initialized version)
        uint256 count = p.tokenCount();
        address impl = Pad3LiveUpgrade.execute(u, st, SAFE);
        assertEq(R.implementationOf(PAD3), impl);
        assertEq(Ownable(PAD3).owner(), SAFE, "owner kept");
        assertEq(p.tokenCount(), count, "tokens kept");
        assertTrue(p.module() != address(0));
        assertEq(Pad3Module(payable(p.module())).owner(), address(0xdEaD), "the module on its own: no owner");

        // the token made before the upgrade trades on, both ways, with no vault
        assertEq(vp.vaultOf(live), address(0));
        vm.prank(alice, alice);
        (uint256 got,) = p.buyTokenAMAP{value: 0.01 ether}(live, alice, 0.01 ether, 0);
        assertGt(got, 0, "a token from before buys after the upgrade");
        vm.prank(alice);
        IERC20(live).approve(PAD3, held + got);
        vm.prank(alice, alice);
        p.sellToken(0, live, alice, held + got, 0, 0, address(0));
        assertEq(IERC20(live).balanceOf(alice), 0, "and sells");

        // the vault mode: listed, granted, a token bound to it
        MockLockVault vault = new MockLockVault(vp);
        vm.startPrank(SAFE);
        vp.setVault(address(vault), true);
        vp.setVaultCreator(address(vault), creator);
        vm.stopPrank();
        vm.prank(creator);
        address t =
            vp.createWithVault("Vault3", "VLT3", "logo", "meta", M.WBNB, address(0), untaxed, 9 ether, address(vault));
        assertEq(vp.vaultOf(t), address(vault));
        assertEq(p.kindOf(t), 1, "a curve token of 3.0");
        vault.approvePad(t);

        // bought to the cap through the entry, part locked, the cap counting it, the vault never a trader
        vm.deal(alice, 10 ether);
        vm.prank(alice, alice);
        p.buyTokenAMAP{value: 5 ether}(t, alice, 5 ether, 0);
        assertEq(IERC20(t).balanceOf(alice), MAX_PER_WALLET, "at the cap");
        vm.prank(alice);
        IERC20(t).approve(address(vault), 4_000_000 ether);
        vm.prank(alice, alice);
        vault.lock(t, 4_000_000 ether);
        assertEq(vp.lockedOf(t, alice), 4_000_000 ether);
        assertEq(IERC20(t).balanceOf(address(vault)), 4_000_000 ether);
        (,, uint256 amount,,,,,) = p.tryBuy(t, alice, 0, 0.01 ether);
        assertEq(amount, 0, "the locked amount counts against the cap");
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        p.buyTokenAMAP{value: 0.01 ether}(t, alice, 0.01 ether, 0);
        vm.deal(address(vault), 1 ether);
        vm.prank(address(vault), address(vault));
        vm.expectRevert(IGangVaultPad.VaultCannotTrade.selector);
        p.buyTokenAMAP{value: 0.01 ether}(t, address(vault), 0.01 ether, 0);

        // released, then all of it sold through the entry
        vm.prank(alice, alice);
        vault.release(t, 4_000_000 ether);
        assertEq(vp.lockedOf(t, alice), 0);
        assertEq(IERC20(t).balanceOf(alice), MAX_PER_WALLET);
        vm.prank(alice);
        IERC20(t).approve(PAD3, MAX_PER_WALLET);
        uint256 bnb0 = alice.balance;
        vm.prank(alice, alice);
        uint256 paid = p.sellToken(0, t, alice, MAX_PER_WALLET, 0, 0, address(0));
        assertEq(alice.balance - bnb0, paid);
        assertEq(IERC20(t).balanceOf(alice), 0);

        _dividendLockRelease(vault);

        // a moved view answers through the fallback
        (,, uint128 rq,, uint128 gradAmt,,,,,,,) = p.curves(t);
        assertEq(Pad3Module(payable(PAD3)).gradAmtOf(t), gradAmt);
        assertEq(Pad3Module(payable(PAD3)).graduationRemaining(t), gradAmt - rq);
    }

    /// @dev A dividend vault token on the live dividend vault: lock and release keep both sides' shares at their
    ///      balances (the pad, through the module, writing the live SharedDividendVault).
    function _dividendLockRelease(MockLockVault vault) internal {
        vm.prank(SAFE);
        vp.setVaultCreator(address(vault), creator);
        IGangLaunchpad.TaxConfig memory tax =
            IGangLaunchpad.TaxConfig({buyTaxBps: 300, sellTaxBps: 300, dividendBps: 5_000, recipient: creator});
        vm.prank(creator);
        address t = vp.createWithVault("Div3", "DIV3", "logo", "meta", M.WBNB, address(0), tax, 9 ether, address(vault));
        vault.approvePad(t);
        address bob = makeAddr("pad3-vault-bob");
        vm.deal(bob, 10 ether);
        vm.prank(bob, bob);
        p.buyTokenAMAP{value: 1 ether}(t, bob, 1 ether, 0);
        uint256 bal = IERC20(t).balanceOf(bob);
        IShares dv = IShares(address(p.dividendVault()));
        assertEq(dv.shares(t, bob), bal, "share = balance");
        vm.prank(bob);
        IERC20(t).approve(address(vault), bal / 2);
        vm.prank(bob, bob);
        vault.lock(t, bal / 2);
        assertEq(dv.shares(t, bob), bal - bal / 2, "locked part leaves the share");
        assertEq(dv.shares(t, address(vault)), bal / 2, "and joins the vault's");
        vm.prank(bob, bob);
        vault.release(t, bal / 2);
        assertEq(dv.shares(t, bob), bal, "released back");
        assertEq(dv.shares(t, address(vault)), 0);
    }

    function _env(uint256 pk) internal {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("GANG_PAD", vm.toString(PAD_1));
        vm.setEnv("OWNER", vm.toString(SAFE));
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        vm.setEnv("GANG_GATEWAY", vm.toString(M.GANG_GATEWAY));
        vm.setEnv("GANG_PAD_REGISTRY", vm.toString(M.PAD_REGISTRY));
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        vm.setEnv("GANG_ROUTER3", vm.toString(ROUTER3));
        vm.setEnv("PAD3_NEW", "false");
        vm.setEnv(
            "CALLERS",
            "0x1de460f363AF910f51726DEf188F9004276Bf4bc,0xDB97fC3329Ed1939012D56ECeaef00Be1C0CdFF5,0x3508DcA95a64C9378Cb07eF6F40553A50905372a"
        );
        vm.setEnv("CALLER_CODEHASHES", "");
        vm.setEnv("CALLERS_PROXY_OK", "true");
        vm.setEnv("PAD3_INIT_CALL", "0x");
        // the script deploys the implementation and the 铸币飞轮 tax handler (Pad3LiveUpgrade)
        vm.setEnv("PAD3_IMPL", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_HANDLER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_TOKEN_DEPLOYER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_VAULT_CORE", vm.toString(address(0)));
        vm.setEnv("GANG_MAINNET_OK", "true");
        vm.setEnv("PAD3_LOG_SCAN", "false");
        vm.setEnv("CUTOVER", "false");
        vm.setEnv("ROUTER_TIMELOCK_DELAY", "172800");
        vm.setEnv("MAINNET_OWNER_IS_DEPLOYER", "false");
        vm.setEnv("KEEPER_OVERRIDE_OK", "false");
        vm.setEnv("FEE_VAULT", vm.toString(address(0)));
        vm.setEnv("BURNER", vm.toString(address(0)));
        vm.setEnv("RECIPIENT", vm.toString(address(0)));
        vm.setEnv("TWAP_WINDOW", vm.toString(uint256(IGangPad(PAD_1).twapWindow())));
    }
}
