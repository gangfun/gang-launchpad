// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangMainnetRefs as M, GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../src/common/SharedPlatformFeeBucket.sol";
import {SharedMigrator} from "../src/common/SharedMigrator.sol";
import {MintTokenDeployer} from "../src/flywheel/MintTokenDeployer.sol";
import {FlywheelTaxHandler} from "../src/flywheel/FlywheelTaxHandler.sol";
import {GangFlywheelPad} from "../src/flywheel/GangFlywheelPad.sol";

/// @dev The live GangLaunchpad's getters for the shared contracts this pad joins.
interface IGangPadShared {
    function quoteRegistry() external view returns (address);
    function dividendVault() external view returns (address);
    function platformBucket() external view returns (address);
    function migrator() external view returns (address);
}

/// @title DeployFlywheel — the continuous-mint pad next to the live GangLaunchpad, on BSC testnet (97) or mainnet (56)
/// @notice It joins the shared contracts the live pad uses (read from GANG_PAD: QuoteRegistry, SharedDividendVault,
///         SharedPlatformFeeBucket, SharedMigrator) and deploys its own three: MintTokenDeployer, FlywheelTaxHandler,
///         GangFlywheelPad (+ the external libraries FlywheelLogic / FlywheelPostLogic, deployed and linked by forge).
///         Two phases, because on mainnet only the Safe can list the new pad on the shared contracts:
///         1. deploy (no FLYWHEEL_PAD): deploy, wire what the deployer owns (deployer list, handler pad / keeper, the
///            pad's Agent ID gate). Shared wiring: done here when the deployer owns those contracts (testnet), else
///            printed as a Safe Transaction Builder batch (vault launchpad + floor + operator + exclusions, migrator,
///            bucket operators).
///         2. finish (FLYWHEEL_PAD, FLYWHEEL_HANDLER, FLYWHEEL_DEPLOYER set; after the Safe batch ran): check every
///            shared listing, call `setMigrator` LAST (A-1: create needs it, so the pad opens only once everything
///            accepts it), start the ownership handover to OWNER and print the acceptOwnership batch.
/// @dev Mainnet broadcast is refused unless FLYWHEEL_MAINNET_OK=true. Env: DEPLOYER_PRIVATE_KEY, GANG_PAD; OWNER
///      (mainnet default the platform Safe); KEEPER (mainnet default the platform keeper, testnet the deployer).
contract DeployFlywheel is Script {
    uint256 internal constant MIN_SHARE = 1_000 ether;

    struct Shared {
        address quoteRegistry;
        address vault;
        address bucket;
        address migrator;
    }

    struct Own {
        address deployer;
        address handler;
        address pad;
    }

    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error NotWired(string what);

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        if (mainnet && _broadcasting() && !vm.envOr("FLYWHEEL_MAINNET_OK", false)) revert MainnetNotAllowed();
        address owner = vm.envOr("OWNER", mainnet ? M.OWNER_SAFE : me);
        address keeper = vm.envOr("KEEPER", mainnet ? M.KEEPER : me);
        Shared memory sh = _shared(vm.envAddress("GANG_PAD"));
        console.log("=== DeployFlywheel chain", block.chainid, "===");
        console.log("deployer", me);
        console.log("owner", owner);

        address existing = vm.envOr("FLYWHEEL_PAD", address(0));
        vm.startBroadcast(pk);
        if (existing == address(0)) {
            Own memory o = _deploy(sh, mainnet, me, keeper);
            bool canWire = Ownable(sh.vault).owner() == me && Ownable(sh.migrator).owner() == me
                && Ownable(sh.bucket).owner() == me;
            if (canWire) {
                _wireShared(sh, o);
                GangFlywheelPad(payable(o.pad)).setMigrator(sh.migrator);
                _handOver(o, owner, me);
            }
            vm.stopBroadcast();
            _log(o);
            if (!canWire) {
                console.log("\n=== Safe batch: list the pad on the shared contracts, then run phase 2 ===");
                console.log(_wiringJson(sh, o, mainnet, Ownable(sh.vault).owner()));
            } else {
                _check(sh, o);
            }
        } else {
            Own memory o = Own({
                deployer: vm.envAddress("FLYWHEEL_DEPLOYER"),
                handler: vm.envAddress("FLYWHEEL_HANDLER"),
                pad: existing
            });
            _requireShared(sh, o);
            if (GangFlywheelPad(payable(o.pad)).migrator() == address(0)) {
                GangFlywheelPad(payable(o.pad)).setMigrator(sh.migrator);
            }
            _handOver(o, owner, me);
            vm.stopBroadcast();
            _check(sh, o);
            _log(o);
            if (owner != me) {
                console.log("\n=== Safe batch: accept ownership of the 3 flywheel contracts ===");
                console.log(_acceptJson(o, mainnet, owner));
            }
        }
    }

    function _shared(address gangPad) internal view returns (Shared memory sh) {
        IGangPadShared p = IGangPadShared(gangPad);
        sh = Shared({
            quoteRegistry: p.quoteRegistry(),
            vault: p.dividendVault(),
            bucket: p.platformBucket(),
            migrator: p.migrator()
        });
    }

    function _deploy(Shared memory sh, bool mainnet, address me, address keeper) internal returns (Own memory o) {
        address wbnb = mainnet ? M.WBNB : T.WBNB;
        address factory = mainnet ? M.PANCAKE_V2_FACTORY : T.PANCAKE_V2_FACTORY;
        address router = mainnet ? M.PANCAKE_V2_ROUTER : T.PANCAKE_V2_ROUTER;
        address agentId = mainnet ? M.AGENT_ID_REGISTRY : vm.envOr("AGENT_ID", T.AGENT_ID_REGISTRY);
        MintTokenDeployer d = new MintTokenDeployer(me);
        FlywheelTaxHandler h = new FlywheelTaxHandler(me, sh.vault, sh.bucket, router);
        GangFlywheelPad p =
            new GangFlywheelPad(me, sh.quoteRegistry, sh.vault, sh.bucket, address(h), address(d), wbnb, factory);
        d.setLaunchpad(address(p), true);
        h.setLaunchpad(address(p));
        h.setKeeper(keeper);
        p.setAgentGate(true, agentId);
        if (!mainnet) p.setV3Factory(T.PANCAKE_V3_FACTORY);
        else p.setV3Factory(M.PANCAKE_V3_FACTORY);
        o = Own({deployer: address(d), handler: address(h), pad: address(p)});
    }

    /// @dev The shared listings (only when the deployer owns the shared contracts, i.e. testnet).
    function _wireShared(Shared memory sh, Own memory o) internal {
        SharedDividendVault v = SharedDividendVault(sh.vault);
        v.setLaunchpad(o.pad, true);
        v.setMinimumShareBalance(o.pad, MIN_SHARE);
        v.setOperator(o.handler, o.pad);
        SharedMigrator(sh.migrator).addLaunchpad(o.pad);
        SharedPlatformFeeBucket(sh.bucket).setOperator(o.pad, true);
        SharedPlatformFeeBucket(sh.bucket).setOperator(o.handler, true);
    }

    function _requireShared(Shared memory sh, Own memory o) internal view {
        SharedDividendVault v = SharedDividendVault(sh.vault);
        if (!v.launchpads(o.pad)) revert NotWired("vault.setLaunchpad(pad)");
        if (v.operatorOf(o.handler) != o.pad) revert NotWired("vault.setOperator(handler, pad)");
        if (v.minimumShareBalanceOf(o.pad) > MIN_SHARE) revert NotWired("vault floor of the pad above 1,000 tokens");
        if (!SharedMigrator(sh.migrator).launchpads(o.pad)) revert NotWired("migrator.addLaunchpad(pad)");
        if (!SharedPlatformFeeBucket(sh.bucket).operators(o.pad)) revert NotWired("bucket.setOperator(pad)");
        if (!SharedPlatformFeeBucket(sh.bucket).operators(o.handler)) revert NotWired("bucket.setOperator(handler)");
    }

    function _handOver(Own memory o, address owner, address me) internal {
        if (owner == me) return;
        if (Ownable2Step(o.deployer).pendingOwner() != owner) Ownable2Step(o.deployer).transferOwnership(owner);
        if (Ownable2Step(o.handler).pendingOwner() != owner) Ownable2Step(o.handler).transferOwnership(owner);
        if (Ownable2Step(o.pad).pendingOwner() != owner) Ownable2Step(o.pad).transferOwnership(owner);
    }

    function _check(Shared memory sh, Own memory o) internal view {
        _requireShared(sh, o);
        GangFlywheelPad p = GangFlywheelPad(payable(o.pad));
        if (p.migrator() != sh.migrator) revert NotWired("pad.setMigrator");
        if (FlywheelTaxHandler(o.handler).launchpad() != o.pad) revert NotWired("handler.setLaunchpad");
        if (!MintTokenDeployer(o.deployer).launchpads(o.pad)) revert NotWired("deployer.setLaunchpad");
        if (address(p.agentIdRegistry()) == address(0) || !p.agentGateEnabled()) revert NotWired("agent gate");
        if (p.taxHandler() != o.handler || p.tokenDeployer() != o.deployer) revert NotWired("pad immutables");
        console.log("self-check ok");
    }

    function _log(Own memory o) internal pure {
        console.log("FLYWHEEL_DEPLOYER", o.deployer);
        console.log("FLYWHEEL_HANDLER", o.handler);
        console.log("FLYWHEEL_PAD", o.pad);
    }

    function _wiringJson(Shared memory sh, Own memory o, bool mainnet, address safe)
        internal
        pure
        returns (string memory j)
    {
        j = _head(mainnet, safe, "gang: list the continuous-mint pad on the shared contracts");
        j = string.concat(
            j,
            _tx(sh.vault, abi.encodeCall(SharedDividendVault.setLaunchpad, (o.pad, true)), false),
            _tx(sh.vault, abi.encodeCall(SharedDividendVault.setMinimumShareBalance, (o.pad, MIN_SHARE)), true),
            _tx(sh.vault, abi.encodeCall(SharedDividendVault.setOperator, (o.handler, o.pad)), true),
            _tx(sh.migrator, abi.encodeCall(SharedMigrator.addLaunchpad, (o.pad)), true),
            _tx(sh.bucket, abi.encodeCall(SharedPlatformFeeBucket.setOperator, (o.pad, true)), true),
            _tx(sh.bucket, abi.encodeCall(SharedPlatformFeeBucket.setOperator, (o.handler, true)), true),
            "]}"
        );
    }

    function _acceptJson(Own memory o, bool mainnet, address safe) internal pure returns (string memory j) {
        j = _head(mainnet, safe, "gang: accept ownership of the 3 continuous-mint contracts");
        bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
        j = string.concat(j, _tx(o.deployer, accept, false), _tx(o.handler, accept, true), _tx(o.pad, accept, true), "]}");
    }

    function _head(bool mainnet, address safe, string memory name) internal pure returns (string memory) {
        return string.concat(
            '{"version":"1.0","chainId":"',
            mainnet ? "56" : "97",
            '","createdAt":0,"meta":{"name":"',
            name,
            '","txBuilderVersion":"1.16.5","createdFromSafeAddress":"',
            vm.toString(safe),
            '"},"transactions":['
        );
    }

    function _tx(address to, bytes memory data, bool comma) internal pure returns (string memory) {
        return string.concat(
            comma ? "," : "",
            '{"to":"',
            vm.toString(to),
            '","value":"0","data":"',
            vm.toString(data),
            '","contractMethod":null,"contractInputsValues":null}'
        );
    }

    function _broadcasting() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }
}
