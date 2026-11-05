// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {GangModulePadScript} from "./GangModulePadScript.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {GangHandlerAdmin} from "../src/gang/GangHandlerAdmin.sol";
import {GangPromotePoolModule} from "../src/gang/GangPromotePoolModule.sol";
import {GangPromotePoolModuleFactory} from "../src/gang/GangPromotePoolModuleFactory.sol";

interface IPromotePoolHandlerOwner {
    function owner() external view returns (address);
}

/// @title DeployGangPromotePoolModuleFactory — the pool side of the promoter share, on the live GangHandlerAdmin of 3.0
/// @notice Deploys the factory unless PROMOTE_POOL_FACTORY is given, checks the wiring and prints the one Safe call still
///         to do: `admin.setFactory(factory, true)`. On testnet, when the deployer owns the admin, the script sends it.
///         The pad must already have the promoter share (the factory's constructor checks).
/// @dev Env: GANG_PAD3 (GangModulePadScript); HANDLER_ADMIN; PROMOTE_SETTLER; PROMOTE_POOL_OWNER (testnet: default the
///      deployer; mainnet: the Safe, the default and the only value allowed); PROMOTE_POOL_FACTORY (optional, an existing
///      one); GANG_QUOTE (mainnet: GANG, the default there; testnet: default none); DEPLOYER_PRIVATE_KEY (unless the
///      factory exists); a mainnet broadcast needs GANG_MAINNET_OK=true.
contract DeployGangPromotePoolModuleFactory is GangModulePadScript {
    address internal constant MAINNET_SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    address internal constant MAINNET_GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;

    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error WiringCheck(string what);

    function run() external returns (GangPromotePoolModuleFactory factory) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();

        address pad = _modulePad(mainnet);
        address admin = vm.envAddress("HANDLER_ADMIN");
        address gangQuote = vm.envOr("GANG_QUOTE", mainnet ? MAINNET_GANG : address(0));

        factory = GangPromotePoolModuleFactory(vm.envOr("PROMOTE_POOL_FACTORY", address(0)));
        if (address(factory) == address(0)) {
            uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
            address settler = vm.envAddress("PROMOTE_SETTLER");
            address owner_ = vm.envOr("PROMOTE_POOL_OWNER", mainnet ? MAINNET_SAFE : vm.addr(pk));
            vm.startBroadcast(pk);
            factory = new GangPromotePoolModuleFactory(pad, admin, gangQuote, owner_, settler);
            vm.stopBroadcast();
        }

        check(pad, admin, address(factory));
        if (GangPromotePoolModule(factory.implementation()).gangQuote() != gangQuote) revert WiringCheck("gangQuote");
        checkCode(address(factory));
        bytes[] memory batch = pendingBatch(admin, address(factory));
        _print(pad, admin, address(factory), batch);

        if (!mainnet && batch.length != 0) {
            uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
            if (pk != 0 && vm.addr(pk) == GangHandlerAdmin(admin).owner()) {
                vm.startBroadcast(pk);
                GangHandlerAdmin(admin).setFactory(address(factory), true);
                vm.stopBroadcast();
                console.log("testnet: setFactory sent by the deployer");
            }
        }
    }

    /// @notice Revert unless `admin` is the GangHandlerAdmin owning `pad`'s handler and `factory` this repo's factory over
    ///         `pad` and `admin`, with its implementation over the same pad and made by it.
    function check(address pad, address admin, address factory) public view {
        address handler = IGangPad(pad).taxHandler();
        if (admin.code.length == 0) revert WiringCheck("admin.code");
        if (GangHandlerAdmin(admin).handler() != handler) revert WiringCheck("admin.handler");
        if (factory.code.length == 0) revert WiringCheck("factory.code");
        GangPromotePoolModuleFactory f = GangPromotePoolModuleFactory(factory);
        if (f.pad() != pad) revert WiringCheck("factory.pad");
        if (f.admin() != admin) revert WiringCheck("factory.admin");
        if (f.settler() == address(0)) revert WiringCheck("factory.settler");
        GangPromotePoolModule impl = GangPromotePoolModule(f.implementation());
        if (impl.pad() != pad) revert WiringCheck("implementation.pad");
        if (impl.taxHandler() != handler) revert WiringCheck("implementation.taxHandler");
        if (impl.factory() != factory) revert WiringCheck("implementation.factory");
        if (impl.moduleType() != bytes32("promote-pool-v1")) revert WiringCheck("implementation.moduleType");
        if (IPromotePoolHandlerOwner(handler).owner() != admin) revert WiringCheck("admin.handlerOwner");
        if (block.chainid == 56) {
            if (GangHandlerAdmin(admin).owner() != MAINNET_SAFE) revert WiringCheck("admin.owner");
            if (f.owner() != MAINNET_SAFE) revert WiringCheck("factory.owner");
            if (f.pendingOwner() != address(0)) revert WiringCheck("factory.pendingOwner");
            // the settler posts and the owner vetoes: one key doing both makes the veto worthless
            if (f.settler() == f.owner()) revert WiringCheck("factory.settlerIsOwner");
            if (impl.gangQuote() != MAINNET_GANG) revert WiringCheck("implementation.gangQuote");
        }
    }

    /// @notice Revert unless `factory` and its implementation have exactly the runtime code of a factory this repo deploys
    ///         over the same pad and admin (a reference deployed here, in the simulation only; the immutables that
    ///         differ, the two addresses, are swapped in before comparing). The owner and settler are storage, so they
    ///         don't enter this; `check` covers them.
    function checkCode(address factory) public {
        GangPromotePoolModuleFactory live = GangPromotePoolModuleFactory(factory);
        address liveImpl = live.implementation();
        GangPromotePoolModuleFactory ref = new GangPromotePoolModuleFactory(
            live.pad(), live.admin(), GangPromotePoolModule(liveImpl).gangQuote(), live.owner(), live.settler()
        );
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

    /// @notice The Safe calls still to make, each as (to ‖ data).
    function pendingBatch(address admin, address factory) public view returns (bytes[] memory calls) {
        if (GangHandlerAdmin(admin).isFactory(factory)) return new bytes[](0);
        calls = new bytes[](1);
        calls[0] = abi.encodePacked(admin, abi.encodeCall(GangHandlerAdmin.setFactory, (factory, true)));
    }

    function _print(address pad, address admin, address factory, bytes[] memory batch) internal view {
        GangPromotePoolModuleFactory f = GangPromotePoolModuleFactory(factory);
        console.log("pad                 ", pad);
        console.log("GangHandlerAdmin    ", admin);
        console.log("factory             ", factory);
        console.log("  implementation    ", f.implementation());
        console.log("  owner             ", f.owner());
        console.log("  settler           ", f.settler());
        console.log("block               ", block.number);
        if (batch.length == 0) {
            console.log("Safe batch: nothing to do (factory allowed)");
            return;
        }
        console.log("Safe batch (the admin's owner):");
        console.log("  to  ", admin);
        console.logBytes(abi.encodeCall(GangHandlerAdmin.setFactory, (factory, true)));
    }
}
