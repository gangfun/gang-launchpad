// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {GangHandlerAdmin} from "../src/gang/GangHandlerAdmin.sol";
import {GangBuybackSplitter} from "../src/gang/GangBuybackSplitter.sol";
import {GangBuybackSplitterFactory} from "../src/gang/GangBuybackSplitterFactory.sol";

interface IOwnable2Step {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

/// @title DeployGangBuybackSplitterFactory — GangHandlerAdmin + GangBuybackSplitterFactory over one pad
/// @notice Deploys what is missing (HANDLER_ADMIN / SPLITTER_FACTORY given: kept and checked), checks the wiring, and
///         prints the Safe batch that is still to do, in order:
///         1. `handler.transferOwnership(admin)` and `admin.exec(acceptOwnership())` — the admin becomes the tax
///            handler's owner (once per handler; the Safe stays the admin's owner and does everything else through
///            `admin.exec`);
///         2. `admin.setFactory(factory, true)` — the factory may list the splitters it clones.
///         On testnet, when the deployer is the handler's owner (set 10: the deployer wallet), the batch is sent by
///         the script itself. A later module kind / version: deploy its factory with HANDLER_ADMIN set (step 2 only).
/// @dev Env: GANG_PAD (mainnet: must be the live pad); HANDLER_ADMIN, SPLITTER_FACTORY (optional, existing ones);
///      ADMIN_OWNER (default: the handler's owner now — the Safe; the admin's owner if it took over already);
///      DEPLOYER_PRIVATE_KEY (unless both exist); mainnet broadcast needs GANG_MAINNET_OK=true.
contract DeployGangBuybackSplitterFactory is Script {
    /// @notice The live GangLaunchpad on BSC 56 (docs/MAINNET-GANG-2026-10-27.md).
    address internal constant MAINNET_PAD = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;

    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error WiringCheck(string what);

    function run() external returns (GangHandlerAdmin admin, GangBuybackSplitterFactory factory) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();

        address pad = vm.envAddress("GANG_PAD");
        if (mainnet ? pad != MAINNET_PAD : IGangPad(pad).wbnb() != T.WBNB) revert WiringCheck("pad");
        address handler = IGangPad(pad).taxHandler();

        admin = GangHandlerAdmin(vm.envOr("HANDLER_ADMIN", address(0)));
        factory = GangBuybackSplitterFactory(vm.envOr("SPLITTER_FACTORY", address(0)));
        if (address(admin) == address(0) || address(factory) == address(0)) {
            uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
            vm.startBroadcast(pk);
            if (address(admin) == address(0)) {
                address handlerOwner = IOwnable2Step(handler).owner();
                admin = new GangHandlerAdmin(vm.envOr("ADMIN_OWNER", handlerOwner), handler);
            }
            if (address(factory) == address(0)) factory = new GangBuybackSplitterFactory(pad, address(admin));
            vm.stopBroadcast();
        }

        check(pad, address(admin), address(factory));
        bytes[] memory batch = pendingBatch(address(admin), address(factory));
        _print(pad, address(admin), address(factory), batch);

        // testnet: the deployer owns the handler and the admin — do the batch here
        if (!mainnet && batch.length != 0) {
            uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
            if (vm.addr(pk) == admin.owner() && vm.addr(pk) == IOwnable2Step(handler).owner()) {
                vm.startBroadcast(pk);
                _apply(handler, address(admin), address(factory));
                vm.stopBroadcast();
                check(pad, address(admin), address(factory));
                if (pendingBatch(address(admin), address(factory)).length != 0) revert WiringCheck("batch");
                console.log("testnet: batch sent by the deployer");
            }
        }
    }

    /// @notice Revert unless `admin` is a GangHandlerAdmin of `pad`'s handler and `factory` this repo's factory over
    ///         `pad` and `admin`, with its implementation over the same pad and made by it.
    function check(address pad, address admin, address factory) public view {
        address handler = IGangPad(pad).taxHandler();
        if (admin.code.length == 0) revert WiringCheck("admin.code");
        if (GangHandlerAdmin(admin).handler() != handler) revert WiringCheck("admin.handler");
        if (factory.code.length == 0) revert WiringCheck("factory.code");
        GangBuybackSplitterFactory f = GangBuybackSplitterFactory(factory);
        if (f.pad() != pad) revert WiringCheck("factory.pad");
        if (f.admin() != admin) revert WiringCheck("factory.admin");
        GangBuybackSplitter impl = GangBuybackSplitter(f.implementation());
        if (impl.pad() != pad) revert WiringCheck("implementation.pad");
        if (impl.taxHandler() != handler) revert WiringCheck("implementation.taxHandler");
        if (impl.factory() != factory) revert WiringCheck("implementation.factory");
        // the admin's owner must be whoever owns the handler now (before the takeover) or will after it
        address handlerOwner = IOwnable2Step(handler).owner();
        if (handlerOwner != admin && GangHandlerAdmin(admin).owner() != handlerOwner) {
            revert WiringCheck("admin.owner");
        }
    }

    /// @notice The Safe calls still to make, each as (to ‖ data): the handler takeover, then allowing the factory.
    function pendingBatch(address admin, address factory) public view returns (bytes[] memory calls) {
        address handler = GangHandlerAdmin(admin).handler();
        bool owned = IOwnable2Step(handler).owner() == admin;
        bool allowed = GangHandlerAdmin(admin).isFactory(factory);
        calls = new bytes[]((owned ? 0 : 2) + (allowed ? 0 : 1));
        uint256 i;
        if (!owned) {
            calls[i++] = abi.encodePacked(handler, abi.encodeCall(IOwnable2Step.transferOwnership, (admin)));
            calls[i++] = abi.encodePacked(
                admin, abi.encodeCall(GangHandlerAdmin.exec, (abi.encodeCall(IOwnable2Step.acceptOwnership, ())))
            );
        }
        if (!allowed) {
            calls[i++] = abi.encodePacked(admin, abi.encodeCall(GangHandlerAdmin.setFactory, (factory, true)));
        }
    }

    function _apply(address handler, address admin, address factory) internal {
        if (IOwnable2Step(handler).owner() != admin) {
            IOwnable2Step(handler).transferOwnership(admin);
            GangHandlerAdmin(admin).exec(abi.encodeCall(IOwnable2Step.acceptOwnership, ()));
        }
        if (!GangHandlerAdmin(admin).isFactory(factory)) GangHandlerAdmin(admin).setFactory(factory, true);
    }

    function _print(address pad, address admin, address factory, bytes[] memory batch) internal view {
        console.log("pad                      ", pad);
        console.log("GangHandlerAdmin         ", admin);
        console.log("  owner                  ", GangHandlerAdmin(admin).owner());
        console.log("GangBuybackSplitterFactory", factory);
        console.log("  implementation         ", GangBuybackSplitterFactory(factory).implementation());
        console.log("block                    ", block.number);
        if (batch.length == 0) {
            console.log("Safe batch: nothing to do (admin owns the handler, factory allowed)");
            return;
        }
        console.log("Safe batch (owner of the handler, then of the admin), in order:");
        for (uint256 i; i < batch.length; i++) {
            bytes memory c = batch[i];
            address to;
            assembly ("memory-safe") {
                to := shr(96, mload(add(c, 32)))
            }
            bytes memory data = new bytes(c.length - 20);
            for (uint256 j; j < data.length; j++) {
                data[j] = c[j + 20];
            }
            console.log("  to  ", to);
            console.logBytes(data);
        }
    }
}
