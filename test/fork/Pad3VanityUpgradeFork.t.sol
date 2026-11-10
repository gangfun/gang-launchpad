// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {Pad3VanityStore} from "../../src/gang/Pad3VanityStore.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {Pad3VanityAcceptanceVault} from "../../script/Pad3VanityTestnetAcceptance.s.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {FlyUpgradeHarness} from "./Pad3LiveUpgrade.sol";
import {Pad3VanityAcceptanceHarness} from "../utils/Pad3VanityAcceptanceHarness.sol";

/// @notice The live proxy upgraded and activated on a mainnet fork, followed by the same seven-entry acceptance
///         flow used on testnet and a legacy curve round trip. Agent IDs are mocked only on this fork. No broadcast.
/// @dev BSC_RPC_URL required (skipped if absent); link the live PoolCheck as other Pad3 upgrade fork tests do.
contract Pad3VanityUpgradeForkTest is Test {
    address internal constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address internal constant PAD1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address internal constant ROUTER3 = 0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7;

    function test_fork_upgradeActivateAndAcceptAllModes() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        GangLaunchpad3 p = GangLaunchpad3(payable(PAD3));
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        (address actor, uint256 key) = makeAddrAndKey("abcd mainnet fork actor");
        vm.deal(actor, 10 ether);
        IGangLaunchpad.TaxConfig memory untaxed;
        vm.prank(actor, actor);
        address old = p.create("ABCD legacy fork", "ABO", "", "", address(0), address(0), untaxed);
        (, Pad3Impl.FlyDeps memory f) = Pad3Impl.flyDepsOf(p);
        Pad3VanityDeployer d = new Pad3VanityDeployer(PAD3, p.tokenDeployer(), f.flyTokenDeployer);
        _env(key, address(d));
        FlyUpgradeHarness upgrade = new FlyUpgradeHarness();
        vm.pauseGasMetering();
        upgrade.run();
        vm.resumeGasMetering();
        address next = upgrade.deployedImpl();
        assertTrue(next != address(0));
        vm.record();
        vm.startPrank(M.OWNER_SAFE);
        ProxyAdmin(R.adminOf(PAD3)).upgradeAndCall(ITransparentUpgradeableProxy(PAD3), next, "");
        Pad3Module(payable(PAD3)).enableVanity(address(d));
        vm.stopPrank();
        (, bytes32[] memory writes) = vm.accesses(PAD3);
        assertEq(writes.length, 2, "only the implementation and new factory slots may be written");
        for (uint256 i; i < writes.length; i++) {
            assertTrue(
                writes[i] == R.IMPLEMENTATION_SLOT || writes[i] == Pad3VanityStore.SLOT, "historical storage changed"
            );
        }
        vm.startPrank(M.OWNER_SAFE);
        address vault = address(new Pad3VanityAcceptanceVault());
        Pad3Module(payable(PAD3)).setVault(vault, true);
        Pad3Module(payable(PAD3)).setVaultCreator(vault, actor);
        vm.stopPrank();
        assertEq(R.implementationOf(PAD3), next);
        assertEq(p.owner(), M.OWNER_SAFE);
        assertEq(Pad3Module(payable(PAD3)).vanityDeployer(), address(d));
        assertTrue(d.isLaunchToken(old));
        Pad3VanityAcceptanceHarness runner = new Pad3VanityAcceptanceHarness();
        address[] memory tokens = runner.accept(PAD3, key, vault, old);
        assertEq(tokens.length, 7);
        assertEq(p.kindOf(old), 1);
        assertEq(p.owner(), M.OWNER_SAFE);
        vm.prank(actor, actor);
        vm.expectRevert(Pad3Module.VanityContextRequired.selector);
        p.create("Unsalted", "NO", "", "", address(0), address(0), untaxed);
    }

    function _env(uint256 key, address factory) private {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(key));
        vm.setEnv("GANG_PAD", vm.toString(PAD1));
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        vm.setEnv("GANG_ROUTER3", vm.toString(ROUTER3));
        vm.setEnv("OWNER", vm.toString(M.OWNER_SAFE));
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        vm.setEnv("GANG_GATEWAY", vm.toString(M.GANG_GATEWAY));
        vm.setEnv("GANG_PAD_REGISTRY", vm.toString(M.PAD_REGISTRY));
        vm.setEnv("PAD3_ABCD_DEPLOYER", vm.toString(factory));
        vm.setEnv("PAD3_IMPL", vm.toString(address(0)));
        vm.setEnv("PAD3_INIT_CALL", "0x");
        vm.setEnv("PAD3_FLY_HANDLER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_TOKEN_DEPLOYER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_VAULT_CORE", vm.toString(address(0)));
        vm.setEnv("CALLERS", "");
        vm.setEnv("PAD3_NEW", "false");
        vm.setEnv("GANG_MAINNET_OK", "true");
        vm.setEnv("CUTOVER", "false");
        vm.setEnv("RECIPIENT", vm.toString(address(0)));
        vm.setEnv("TWAP_WINDOW", vm.toString(padTwap()));
    }

    function padTwap() private view returns (uint256) {
        return GangLaunchpad3(payable(PAD1)).twapWindow();
    }
}
