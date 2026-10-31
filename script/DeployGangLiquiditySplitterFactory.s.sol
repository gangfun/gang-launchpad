// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {GangModulePadScript} from "./GangModulePadScript.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {GangHandlerAdmin} from "../src/gang/GangHandlerAdmin.sol";
import {GangLiquiditySplitter} from "../src/gang/GangLiquiditySplitter.sol";
import {GangLiquiditySplitterFactory} from "../src/gang/GangLiquiditySplitterFactory.sol";

interface IHandlerOwner {
    function owner() external view returns (address);
}

/// @title DeployGangLiquiditySplitterFactory — GangLiquiditySplitterFactory on the live GangHandlerAdmin of one pad
/// @notice As DeployGangSplitModuleFactory: the admin already owns the tax handler; this deploys the factory unless
///         LP_FACTORY is given, checks the wiring and the runtime code, and prints the one Safe call still to do:
///         `admin.setFactory(factory, true)`. On testnet, when the deployer owns the admin, the script sends it. The
///         code comparison is exact (metadata hash included): to re-check a deployed factory, run at the commit it
///         was deployed from.
/// @dev Env: the pad (GangModulePadScript: mainnet GANG_PAD2, a 2.0 pad owned by the Safe; testnet GANG_PAD2 or
///      GANG_PAD); HANDLER_ADMIN; LP_FACTORY (optional, an existing one);
///      DEPLOYER_PRIVATE_KEY (unless the factory exists); mainnet broadcast needs GANG_MAINNET_OK=true.
contract DeployGangLiquiditySplitterFactory is GangModulePadScript {
    /// @notice The Safe owning the mainnet GangHandlerAdmin (docs/MAINNET-GANG-2026-10-27.md).
    address internal constant MAINNET_SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;

    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error WiringCheck(string what);

    function run() external returns (GangLiquiditySplitterFactory factory) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();

        address pad = _modulePad(mainnet);
        address admin = vm.envAddress("HANDLER_ADMIN");

        factory = GangLiquiditySplitterFactory(vm.envOr("LP_FACTORY", address(0)));
        if (address(factory) == address(0)) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
            factory = new GangLiquiditySplitterFactory(pad, admin);
            vm.stopBroadcast();
        }

        check(pad, admin, address(factory));
        checkCode(address(factory));
        bytes[] memory batch = pendingBatch(admin, address(factory));
        _print(pad, admin, address(factory), batch);

        // testnet: the deployer owns the admin — allow the factory here
        if (!mainnet && batch.length != 0) {
            uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
            if (vm.addr(pk) == GangHandlerAdmin(admin).owner()) {
                vm.startBroadcast(pk);
                GangHandlerAdmin(admin).setFactory(address(factory), true);
                vm.stopBroadcast();
                if (pendingBatch(admin, address(factory)).length != 0) revert WiringCheck("batch");
                console.log("testnet: setFactory sent by the deployer");
            }
        }
    }

    /// @notice Revert unless `admin` is the GangHandlerAdmin owning `pad`'s handler and `factory` this repo's factory
    ///         over `pad` and `admin`, with its implementation over the same pad and made by it.
    function check(address pad, address admin, address factory) public view {
        address handler = IGangPad(pad).taxHandler();
        if (admin.code.length == 0) revert WiringCheck("admin.code");
        if (GangHandlerAdmin(admin).handler() != handler) revert WiringCheck("admin.handler");
        if (factory.code.length == 0) revert WiringCheck("factory.code");
        GangLiquiditySplitterFactory f = GangLiquiditySplitterFactory(factory);
        if (f.pad() != pad) revert WiringCheck("factory.pad");
        if (f.admin() != admin) revert WiringCheck("factory.admin");
        GangLiquiditySplitter impl = GangLiquiditySplitter(f.implementation());
        if (impl.pad() != pad) revert WiringCheck("implementation.pad");
        if (impl.taxHandler() != handler) revert WiringCheck("implementation.taxHandler");
        if (impl.factory() != factory) revert WiringCheck("implementation.factory");
        if (impl.moduleType() != bytes32("lp-burn-v1")) revert WiringCheck("implementation.moduleType");
        if (IHandlerOwner(handler).owner() != admin) revert WiringCheck("admin.handlerOwner");
        if (block.chainid == 56 && GangHandlerAdmin(admin).owner() != MAINNET_SAFE) revert WiringCheck("admin.owner");
    }

    /// @notice Revert unless `factory` and its implementation have exactly the runtime code of a factory this repo
    ///         deploys over the same pad and admin (a reference deployed here, in the simulation only; the immutables
    ///         that differ — the two addresses — are swapped in before comparing).
    function checkCode(address factory) public {
        GangLiquiditySplitterFactory live = GangLiquiditySplitterFactory(factory);
        address liveImpl = live.implementation();
        GangLiquiditySplitterFactory ref = new GangLiquiditySplitterFactory(live.pad(), live.admin());
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
        console.log("GangLiquiditySplitterFactory", factory);
        console.log("  implementation       ", GangLiquiditySplitterFactory(factory).implementation());
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
