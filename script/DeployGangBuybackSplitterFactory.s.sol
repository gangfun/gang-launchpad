// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {GangModulePadScript} from "./GangModulePadScript.sol";
import {VmSafe} from "forge-std/Vm.sol";
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
///            `admin.exec`). When an older GangHandlerAdmin owns the handler (a new admin version), the first call is
///            `oldAdmin.exec(transferOwnership(admin))` instead;
///         2. `admin.setFactory(factory, true)` — the factory may list the splitters it clones.
///         On testnet, when the deployer is the handler's owner (set 10: the deployer wallet), the batch is sent by
///         the script itself. A later module kind / version: deploy its factory with HANDLER_ADMIN set (step 2 only);
///         the factories the admin still allows besides it are printed with the optional `setFactory(old, false)` that
///         stops each (its clones keep working) — the Safe's call, never in the batch.
/// @dev Env: the pad (GangModulePadScript: mainnet GANG_PAD2, a 2.0 pad owned by the Safe; testnet GANG_PAD2 or
///      GANG_PAD); HANDLER_ADMIN, SPLITTER_FACTORY (optional, existing ones); ADMIN_OWNER (default: whoever holds the
///      handler now — the Safe, or the owner of the older admin holding it; mainnet: must be the Safe, with no handover
///      pending, audit 2026-10-31 L-2);
///      DEPLOYER_PRIVATE_KEY (unless both exist); mainnet broadcast needs GANG_MAINNET_OK=true.
contract DeployGangBuybackSplitterFactory is GangModulePadScript {
    /// @notice The platform Safe (docs/MAINNET-GANG-2026-10-27.md): on mainnet it holds the handler and owns the admin.
    address internal constant MAINNET_SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;

    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error WiringCheck(string what);

    function run() external returns (GangHandlerAdmin admin, GangBuybackSplitterFactory factory) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();

        address pad = _modulePad(mainnet);
        address handler = IGangPad(pad).taxHandler();
        if (mainnet) {
            // L-2: the Safe holds the handler (no handover half-done) and will own the new admin
            if (ownerBehind(handler) != MAINNET_SAFE || IOwnable2Step(handler).pendingOwner() != address(0)) {
                revert WiringCheck("handler not settled with the Safe");
            }
            address ao = vm.envOr("ADMIN_OWNER", address(0));
            if (ao != address(0) && ao != MAINNET_SAFE) revert WiringCheck("ADMIN_OWNER must be the Safe on mainnet");
        }

        admin = GangHandlerAdmin(vm.envOr("HANDLER_ADMIN", address(0)));
        factory = GangBuybackSplitterFactory(vm.envOr("SPLITTER_FACTORY", address(0)));
        if (address(admin) == address(0) || address(factory) == address(0)) {
            uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
            vm.startBroadcast(pk);
            if (address(admin) == address(0)) {
                address ao = vm.envOr("ADMIN_OWNER", address(0)); // 0 = unset
                admin = new GangHandlerAdmin(ao == address(0) ? ownerBehind(handler) : ao, handler);
            }
            if (address(factory) == address(0)) factory = new GangBuybackSplitterFactory(pad, address(admin));
            vm.stopBroadcast();
        }

        check(pad, address(admin), address(factory));
        if (mainnet && admin.owner() != MAINNET_SAFE) revert WiringCheck("admin.owner");
        bytes[] memory batch = pendingBatch(address(admin), address(factory));
        _print(pad, address(admin), address(factory), batch);

        // testnet: the deployer owns the handler and the admin — do the batch here
        if (!mainnet && batch.length != 0) {
            uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
            if (vm.addr(pk) == admin.owner() && vm.addr(pk) == ownerBehind(handler)) {
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
        // before the takeover the admin's owner must be whoever holds the handler now: the Safe, or the Safe behind
        // an older admin
        if (IOwnable2Step(handler).owner() != admin && GangHandlerAdmin(admin).owner() != ownerBehind(handler)) {
            revert WiringCheck("admin.owner");
        }
    }

    /// @notice The handler's owner, or the owner of the GangHandlerAdmin that owns it.
    function ownerBehind(address handler) public view returns (address) {
        address o = IOwnable2Step(handler).owner();
        return _isAdminOf(o, handler) ? GangHandlerAdmin(o).owner() : o;
    }

    function _isAdminOf(address who, address handler) internal view returns (bool) {
        if (who.code.length == 0) return false;
        try GangHandlerAdmin(who).handler() returns (address h) {
            return h == handler;
        } catch {
            return false;
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
            address current = IOwnable2Step(handler).owner();
            calls[i++] = _isAdminOf(current, handler)
                ? abi.encodePacked(
                    current,
                    abi.encodeCall(GangHandlerAdmin.exec, (abi.encodeCall(IOwnable2Step.transferOwnership, (admin))))
                )
                : abi.encodePacked(handler, abi.encodeCall(IOwnable2Step.transferOwnership, (admin)));
            calls[i++] = abi.encodePacked(
                admin, abi.encodeCall(GangHandlerAdmin.exec, (abi.encodeCall(IOwnable2Step.acceptOwnership, ())))
            );
        }
        if (!allowed) {
            calls[i++] = abi.encodePacked(admin, abi.encodeCall(GangHandlerAdmin.setFactory, (factory, true)));
        }
    }

    function _apply(address handler, address admin, address factory) internal {
        address current = IOwnable2Step(handler).owner();
        if (current != admin) {
            if (_isAdminOf(current, handler)) {
                GangHandlerAdmin(current).exec(abi.encodeCall(IOwnable2Step.transferOwnership, (admin)));
            } else {
                IOwnable2Step(handler).transferOwnership(admin);
            }
            GangHandlerAdmin(admin).exec(abi.encodeCall(IOwnable2Step.acceptOwnership, ()));
        }
        if (!GangHandlerAdmin(admin).isFactory(factory)) GangHandlerAdmin(admin).setFactory(factory, true);
    }

    /// @notice The factories `admin` allows besides `factory` (an older version, another kind).
    function otherFactories(address admin, address factory) public view returns (address[] memory others) {
        address[] memory all = GangHandlerAdmin(admin).factories();
        others = new address[](all.length);
        uint256 n;
        for (uint256 i; i < all.length; i++) {
            if (all[i] != factory && GangHandlerAdmin(admin).isFactory(all[i])) others[n++] = all[i];
        }
        assembly ("memory-safe") {
            mstore(others, n)
        }
    }

    function _printOtherFactories(address admin, address factory) internal view {
        address[] memory others = otherFactories(admin, factory);
        for (uint256 i; i < others.length; i++) {
            console.log(
                "Also allowed on the admin (optional, the Safe's call: stop it, its clones keep working):", others[i]
            );
            console.log("  to  ", admin);
            console.logBytes(abi.encodeCall(GangHandlerAdmin.setFactory, (others[i], false)));
        }
    }

    function _print(address pad, address admin, address factory, bytes[] memory batch) internal view {
        console.log("pad                      ", pad);
        console.log("GangHandlerAdmin         ", admin);
        console.log("  owner                  ", GangHandlerAdmin(admin).owner());
        console.log("GangBuybackSplitterFactory", factory);
        console.log("  implementation         ", GangBuybackSplitterFactory(factory).implementation());
        console.log("block                    ", block.number);
        _printOtherFactories(admin, factory);
        if (batch.length == 0) {
            console.log("Safe batch: nothing to do (admin owns the handler, factory allowed)");
            return;
        }
        console.log(
            "Safe batch (the Safe: owner of the handler or of the admin holding it, and of the new admin), in order:"
        );
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
