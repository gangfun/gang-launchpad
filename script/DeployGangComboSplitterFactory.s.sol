// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {GangHandlerAdmin} from "../src/gang/GangHandlerAdmin.sol";
import {GangComboSplitter} from "../src/gang/GangComboSplitter.sol";
import {GangComboSplitterFactory} from "../src/gang/GangComboSplitterFactory.sol";

interface IHandlerOwner {
    function owner() external view returns (address);
}

/// @title DeployGangComboSplitterFactory — GangComboSplitterFactory on the live GangHandlerAdmin of one pad
/// @notice As DeployGangSplitModuleFactory: the admin already owns the tax handler; this deploys the factory unless
///         COMBO_FACTORY is given, checks the wiring and the runtime code, and prints the one Safe call still to do:
///         `admin.setFactory(factory, true)`. On testnet, when the deployer owns the admin, the script sends it. The
///         code comparison is exact (metadata hash included): to re-check a deployed factory, run at the commit it
///         was deployed from.
/// @dev Env: GANG_PAD (mainnet: must be the live pad); HANDLER_ADMIN; COMBO_FACTORY (optional, an existing one);
///      GANG_QUOTE (the GANG quote the keeper serves; mainnet: GANG, the default there; testnet: default none);
///      DEPLOYER_PRIVATE_KEY (unless the factory exists); mainnet broadcast needs GANG_MAINNET_OK=true.
contract DeployGangComboSplitterFactory is Script {
    /// @notice The live GangLaunchpad on BSC 56 (docs/MAINNET-GANG-2026-10-27.md).
    address internal constant MAINNET_PAD = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    /// @notice The Safe owning the mainnet GangHandlerAdmin (docs/MAINNET-GANG-2026-10-27.md).
    address internal constant MAINNET_SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    /// @notice The platform token GANG on BSC 56, a quote the keeper serves.
    address internal constant MAINNET_GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;

    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error WiringCheck(string what);

    function run() external returns (GangComboSplitterFactory factory) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();

        address pad = vm.envAddress("GANG_PAD");
        if (mainnet ? pad != MAINNET_PAD : IGangPad(pad).wbnb() != T.WBNB) revert WiringCheck("pad");
        address admin = vm.envAddress("HANDLER_ADMIN");

        address gangQuote = vm.envOr("GANG_QUOTE", mainnet ? MAINNET_GANG : address(0));

        factory = GangComboSplitterFactory(vm.envOr("COMBO_FACTORY", address(0)));
        if (address(factory) == address(0)) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
            factory = new GangComboSplitterFactory(pad, admin, gangQuote);
            vm.stopBroadcast();
        }

        check(pad, admin, address(factory));
        if (GangComboSplitter(factory.implementation()).gangQuote() != gangQuote) revert WiringCheck("gangQuote");
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
        GangComboSplitterFactory f = GangComboSplitterFactory(factory);
        if (f.pad() != pad) revert WiringCheck("factory.pad");
        if (f.admin() != admin) revert WiringCheck("factory.admin");
        GangComboSplitter impl = GangComboSplitter(f.implementation());
        if (impl.pad() != pad) revert WiringCheck("implementation.pad");
        if (impl.taxHandler() != handler) revert WiringCheck("implementation.taxHandler");
        if (impl.factory() != factory) revert WiringCheck("implementation.factory");
        if (impl.moduleType() != bytes32("combo-v1")) revert WiringCheck("implementation.moduleType");
        if (IHandlerOwner(handler).owner() != admin) revert WiringCheck("admin.handlerOwner");
        if (block.chainid == 56 && GangHandlerAdmin(admin).owner() != MAINNET_SAFE) revert WiringCheck("admin.owner");
        if (block.chainid == 56 && impl.gangQuote() != MAINNET_GANG) revert WiringCheck("implementation.gangQuote");
    }

    /// @notice Revert unless `factory` and its implementation have exactly the runtime code of a factory this repo
    ///         deploys over the same pad and admin (a reference deployed here, in the simulation only; the immutables
    ///         that differ — the two addresses — are swapped in before comparing).
    function checkCode(address factory) public {
        GangComboSplitterFactory live = GangComboSplitterFactory(factory);
        address liveImpl = live.implementation();
        GangComboSplitterFactory ref =
            new GangComboSplitterFactory(live.pad(), live.admin(), GangComboSplitter(liveImpl).gangQuote());
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
        console.log("GangComboSplitterFactory", factory);
        console.log("  implementation       ", GangComboSplitterFactory(factory).implementation());
        console.log(
            "  gangQuote            ", GangComboSplitter(GangComboSplitterFactory(factory).implementation()).gangQuote()
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
