// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {GangModulePadScript} from "./GangModulePadScript.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {GangHandlerAdmin} from "../src/gang/GangHandlerAdmin.sol";
import {GangFloorModule} from "../src/gang/GangFloorModule.sol";
import {GangFloorModuleFactory} from "../src/gang/GangFloorModuleFactory.sol";

interface IHandlerOwner {
    function owner() external view returns (address);
}

interface IVanityPad {
    function vanityDeployer() external view returns (address);
}

/// @title DeployGangFloorModuleFactory — GangFloorModuleFactory on the live GangHandlerAdmin of one pad
/// @notice As DeployGangSplitModuleFactory: the admin already owns the tax handler; this deploys the factory unless
///         FLOOR_FACTORY is given, checks the wiring and the runtime code, and prints the one Safe call still to do:
///         `admin.setFactory(factory, true)`. On testnet, when the deployer owns the admin, the script sends it. The
///         code comparison is exact (metadata hash included): to re-check a deployed factory, run at the commit it
///         was deployed from.
/// @dev Env: the pad (GangModulePadScript; mainnet: GANG_PAD3 = 3.0 only, owned by the Safe; testnet GANG_PAD3, GANG_PAD2 or
///      GANG_PAD); HANDLER_ADMIN; FLOOR_FACTORY (optional, an existing one);
///      GANG_QUOTE (the GANG quote the keeper serves; mainnet: GANG, the default there; testnet: default none);
///      DEPLOYER_PRIVATE_KEY (unless the factory exists); mainnet broadcast needs GANG_MAINNET_OK=true.
contract DeployGangFloorModuleFactory is GangModulePadScript {
    /// @notice The Safe owning the mainnet GangHandlerAdmin (docs/MAINNET-GANG-2026-10-27.md).
    address internal constant MAINNET_SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    /// @notice GangLaunchpad 3.0's GangHandlerAdmin (docs/MAINNET-GANG-LAUNCHPAD-3-MODULES-2026-11-03.md).
    address internal constant MAINNET_ADMIN_3 = 0xC833CEC2B283759003945C0Bf8C048aB1949Af76;
    /// @notice The platform token GANG on BSC 56, a quote the keeper serves.
    address internal constant MAINNET_GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;

    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error WiringCheck(string what);

    function run() external returns (GangFloorModuleFactory factory) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();

        address pad = _modulePad(mainnet);
        // floor-v1 is for GangLaunchpad 3.0 only (docs/SPEC-FLOOR-MODULE-2026-11-11.md K-12)
        if (mainnet && pad != MAINNET_PAD_3) revert WiringCheck("pad: GangLaunchpad 3.0 only");
        // K-13: a module is cloned for a token address known before the token exists, which only the pad's CREATE2
        // (abcd) deployer gives. Without it a dev can't name the token, so the factory must not go live before it.
        if (mainnet && !vanityEnabled(pad)) revert WiringCheck("pad: abcd deployer not enabled");
        address admin = vm.envAddress("HANDLER_ADMIN");

        address gangQuote = vm.envOr("GANG_QUOTE", mainnet ? MAINNET_GANG : address(0));

        factory = GangFloorModuleFactory(vm.envOr("FLOOR_FACTORY", address(0)));
        if (address(factory) == address(0)) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
            factory = new GangFloorModuleFactory(pad, admin, gangQuote);
            vm.stopBroadcast();
        }

        check(pad, admin, address(factory));
        if (GangFloorModule(factory.implementation()).gangQuote() != gangQuote) revert WiringCheck("gangQuote");
        checkCode(address(factory));
        bytes[] memory batch = pendingBatch(admin, address(factory));
        _print(pad, admin, address(factory), batch);

        // testnet: the deployer owns the admin — allow the factory here
        if (!mainnet && batch.length != 0) {
            uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
            if (pk != 0 && vm.addr(pk) == GangHandlerAdmin(admin).owner()) {
                vm.startBroadcast(pk);
                GangHandlerAdmin(admin).setFactory(address(factory), true);
                vm.stopBroadcast();
                if (pendingBatch(admin, address(factory)).length != 0) revert WiringCheck("batch");
                console.log("testnet: setFactory sent by the deployer");
            }
        }
    }

    /// @notice Whether `pad` creates its tokens through the CREATE2 (abcd) deployer (false for a pad without one).
    function vanityEnabled(address pad) public view returns (bool) {
        try IVanityPad(pad).vanityDeployer() returns (address d) {
            return d != address(0);
        } catch {
            return false;
        }
    }

    /// @notice Revert unless `admin` is the GangHandlerAdmin owning `pad`'s handler and `factory` this repo's factory
    ///         over `pad` and `admin`, with its implementation over the same pad and made by it.
    function check(address pad, address admin, address factory) public view {
        address handler = IGangPad(pad).taxHandler();
        if (admin.code.length == 0) revert WiringCheck("admin.code");
        if (GangHandlerAdmin(admin).handler() != handler) revert WiringCheck("admin.handler");
        if (factory.code.length == 0) revert WiringCheck("factory.code");
        GangFloorModuleFactory f = GangFloorModuleFactory(factory);
        if (f.pad() != pad) revert WiringCheck("factory.pad");
        if (f.admin() != admin) revert WiringCheck("factory.admin");
        GangFloorModule impl = GangFloorModule(f.implementation());
        if (impl.pad() != pad) revert WiringCheck("implementation.pad");
        if (impl.taxHandler() != handler) revert WiringCheck("implementation.taxHandler");
        if (impl.factory() != factory) revert WiringCheck("implementation.factory");
        if (impl.moduleType() != bytes32("floor-v1")) revert WiringCheck("implementation.moduleType");
        if (IHandlerOwner(handler).owner() != admin) revert WiringCheck("admin.handlerOwner");
        if (block.chainid == 56 && pad != MAINNET_PAD_3) revert WiringCheck("pad: GangLaunchpad 3.0 only");
        if (block.chainid == 56 && !vanityEnabled(pad)) revert WiringCheck("pad: abcd deployer not enabled");
        if (block.chainid == 56 && admin != MAINNET_ADMIN_3) revert WiringCheck("admin: 3.0's GangHandlerAdmin");
        if (block.chainid == 56 && GangHandlerAdmin(admin).owner() != MAINNET_SAFE) revert WiringCheck("admin.owner");
        if (block.chainid == 56 && impl.gangQuote() != MAINNET_GANG) revert WiringCheck("implementation.gangQuote");
    }

    /// @notice Revert unless `factory` and its implementation have exactly the runtime code of a factory this repo
    ///         deploys over the same pad and admin (a reference deployed here, in the simulation only; the immutables
    ///         that differ — the two addresses — are swapped in before comparing).
    function checkCode(address factory) public {
        GangFloorModuleFactory live = GangFloorModuleFactory(factory);
        address liveImpl = live.implementation();
        GangFloorModuleFactory ref =
            new GangFloorModuleFactory(live.pad(), live.admin(), GangFloorModule(liveImpl).gangQuote());
        address refImpl = ref.implementation();
        bytes memory code = _swap(address(ref).code, refImpl, liveImpl);
        if (keccak256(code) != keccak256(factory.code)) revert WiringCheck("factory.runtimeCode");
        code = _swap(_swap(refImpl.code, address(ref), factory), refImpl, liveImpl);
        if (keccak256(code) != keccak256(liveImpl.code)) revert WiringCheck("implementation.runtimeCode");
    }

    /// @dev `code` with every occurrence of the 20 bytes of `from` replaced by `to`.
    function _swap(bytes memory code, address from, address to) internal pure returns (bytes memory) {
        bytes20 f = bytes20(from);
        bytes20 t = bytes20(to);
        for (uint256 i; i + 20 <= code.length; i++) {
            bytes20 w;
            assembly ("memory-safe") {
                w := mload(add(add(code, 32), i))
            }
            if (w != f) continue;
            for (uint256 j; j < 20; j++) {
                code[i + j] = t[j];
            }
            i += 19;
        }
        return code;
    }

    /// @notice The Safe calls still to make, each as (to ‖ data): allowing the factory on the admin.
    function pendingBatch(address admin, address factory) public view returns (bytes[] memory calls) {
        if (GangHandlerAdmin(admin).isFactory(factory)) return new bytes[](0);
        calls = new bytes[](1);
        calls[0] = abi.encodePacked(admin, abi.encodeCall(GangHandlerAdmin.setFactory, (factory, true)));
    }

    function _print(address pad, address admin, address factory, bytes[] memory batch) internal view {
        console.log("pad                    ", pad);
        console.log("GangHandlerAdmin       ", admin);
        console.log("  owner                ", GangHandlerAdmin(admin).owner());
        console.log("GangFloorModuleFactory ", factory);
        console.log("  implementation       ", GangFloorModuleFactory(factory).implementation());
        console.log(
            "  gangQuote            ", GangFloorModule(GangFloorModuleFactory(factory).implementation()).gangQuote()
        );
        console.log("block                  ", block.number);
        if (batch.length == 0) {
            console.log("Safe batch: nothing to do (factory allowed)");
            return;
        }
        console.log("Safe batch (the admin's owner):");
        console.log("  to  ", admin);
        console.logBytes(abi.encodeCall(GangHandlerAdmin.setFactory, (factory, true)));
    }
}
