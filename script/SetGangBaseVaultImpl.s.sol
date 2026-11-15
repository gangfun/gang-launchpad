// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GangMainnetRefs as M} from "../config/GangDeployRefs.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {GangBaseVault} from "../src/gang/GangBaseVault.sol";

/// @notice Open `createWithBase` on a GangLaunchpad 3.0 already upgraded to the base build: the second owner batch of
///         docs/SPEC-BASE-VAULT-V2-2026-11-12.md §8, sent only once the server, the website and the CLI are live
///         (UpgradeGangLaunchpad3 would deploy and upgrade again, so this is its own script). Checks the vault
///         implementation's code against this build with its `pad` fixed to GANG_PAD3, simulates `setBaseVaultImpl` as
///         the pad's owner and reads it back, then prints a one-call Safe batch (mainnet) or sends it (testnet, when
///         the deploy wallet owns the pad and the run broadcasts). Read-only otherwise.
/// @dev Env: GANG_PAD3, PAD3_BASE_VAULT_IMPL (from DeployGangBaseVault); DEPLOYER_PRIVATE_KEY on testnet only;
///      PAD3_BASE_REPLACE=true to replace an implementation already set (refused otherwise).
contract SetGangBaseVaultImpl is Script {
    /// @dev The mainnet GangLaunchpad 3.0 proxy.
    address internal constant MAINNET_PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;

    error Check(string what);

    function run() external {
        run(
            vm.envAddress("GANG_PAD3"),
            vm.envAddress("PAD3_BASE_VAULT_IMPL"),
            vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0)),
            vm.envOr("PAD3_BASE_REPLACE", false)
        );
    }

    /// @dev `run` with its inputs passed in (tests: no process-wide env between parallel tests).
    function run(address pad, address impl, uint256 pk, bool replace) public {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert Check("chain: BSC mainnet or testnet only");
        if (mainnet && pad != MAINNET_PAD3) revert Check("GANG_PAD3 is not the mainnet 3.0 proxy");
        address current = _baseVaultImpl(pad);
        address owner = Ownable(pad).owner();
        if (mainnet && owner != M.OWNER_SAFE) revert Check("pad owner is not the Safe");
        if (current == impl) revert Check("already set to PAD3_BASE_VAULT_IMPL");
        if (current != address(0)) {
            if (!replace) revert Check("an implementation is already set: PAD3_BASE_REPLACE=true to replace it");
            console.log("replaces the current implementation", current);
        }
        if (!R.sameCode(impl, address(new GangBaseVault(pad)).code)) revert Check("vault implementation code");

        Pad3Module p = Pad3Module(payable(pad));
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        p.setBaseVaultImpl(impl);
        if (p.baseVaultImpl() != impl) revert Check("read back");
        vm.revertToState(snap);

        if (!mainnet && pk != 0 && vm.addr(pk) == owner) {
            vm.startBroadcast(pk);
            p.setBaseVaultImpl(impl);
            vm.stopBroadcast();
            if (p.baseVaultImpl() != impl) revert Check("read back");
            console.log(
                _broadcasting()
                    ? "set (testnet, the deploy wallet owns the pad)"
                    : "simulated only: add --broadcast to send",
                impl
            );
            return;
        }
        console.log("\n=== Safe batch: open createWithBase (setBaseVaultImpl, effective at once) ===");
        console.log(
            string.concat(
                '{"version":"1.0","chainId":"',
                mainnet ? "56" : "97",
                '","createdAt":0,"meta":{"name":"gang: open the opening base (setBaseVaultImpl)","txBuilderVersion":"1.16.5","createdFromSafeAddress":"',
                vm.toString(owner),
                '"},"transactions":[{"to":"',
                vm.toString(pad),
                '","value":"0","data":"',
                vm.toString(abi.encodeCall(Pad3Module.setBaseVaultImpl, (impl))),
                '","contractMethod":null,"contractInputsValues":null}]}'
            )
        );
    }

    /// @dev The pad's current base vault implementation; a pad without the base build is refused.
    function _baseVaultImpl(address pad) internal view returns (address impl) {
        (bool ok, bytes memory ret) = pad.staticcall(abi.encodeCall(Pad3Module.baseVaultImpl, ()));
        if (!ok || ret.length != 32) revert Check("pad not upgraded to the base build");
        impl = abi.decode(ret, (address));
    }

    function _broadcasting() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }
}
