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
import {GangPadRegistry} from "../src/gang/GangPadRegistry.sol";

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
///            printed as a Safe Transaction Builder batch (vault launchpad + floor + operator, migrator, bucket
///            operators, and GangPadRegistry.addPad so aggregators find the pad's tokens).
///         2. finish (FLYWHEEL_PAD, FLYWHEEL_HANDLER, FLYWHEEL_DEPLOYER set; after the Safe batch ran): check every
///            shared listing, start the ownership handover to OWNER and print the accept batch, which ends with
///            `setMigrator` (A-1: create needs it, so the pad opens only once everything accepts it; audit C-1: and
///            only once OWNER owns it, never while the deploy wallet still could change its settings). When OWNER is
///            the deployer (testnet), `setMigrator` is called right away.
/// @dev Mainnet broadcast is refused unless FLYWHEEL_MAINNET_OK=true. Env: DEPLOYER_PRIVATE_KEY, GANG_PAD; OWNER
///      (mainnet default the platform Safe); KEEPER (mainnet default the platform keeper, testnet the deployer). On
///      mainnet GANG_PAD, GANG_PAD_REGISTRY, OWNER and KEEPER must be the known ones (audit C-2) unless
///      FLYWHEEL_ALLOW_OVERRIDE=true. This is the V1 path (all three contracts new, from the current sources);
///      DeployFlywheelV2 reuses the live MintTokenDeployer through the hooks below.
contract DeployFlywheel is Script {
    uint256 internal constant MIN_SHARE = 1_000 ether;
    /// @dev The GangPadRegistry proxies aggregators read (docs/MAINNET-PAD-REGISTRY / TESTNET-PAD-REGISTRY).
    address internal constant MAINNET_PAD_REGISTRY = 0x4fF77D4d9ac080939a24E1B805206bA094C44e5C;
    address internal constant TESTNET_PAD_REGISTRY = 0xB11B83C83DEd269B040faecC1D61B4885BA8e56e;
    /// @dev The live GangLaunchpad whose shared contracts the pad joins.
    address internal constant MAINNET_GANG_PAD = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    /// @dev The entry contracts a pad may list with `setRouter` (docs/MAINNET-GANG-2026-10-27.md: GangRouter proxy;
    ///      docs/MAINNET-GANG-GATEWAY-2026-10-30.md: GangGateway proxy). A new pad lists neither until the Safe does
    ///      (audit V2 C-L3). Testnet: GANG_ROUTER / GANG_GATEWAY, if set.
    address internal constant MAINNET_GANG_ROUTER = 0xE040445690Aa56C8b68B7f7038C7b2562B5079C4;
    address internal constant MAINNET_GANG_GATEWAY = 0x9dD16b73f624bdd8a210CBB2602FdF70f1B450B8;
    /// @dev The reference-pool pricing window the pad's constructor sets (GangFlywheelPad `_config.twapWindow`).
    uint32 internal constant REF_TWAP_WINDOW = 1800;

    struct Shared {
        address quoteRegistry;
        address vault;
        address bucket;
        address migrator;
        address padRegistry;
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
        address gangPad = vm.envAddress("GANG_PAD");
        Shared memory sh = _shared(gangPad);
        sh.padRegistry = vm.envOr("GANG_PAD_REGISTRY", mainnet ? MAINNET_PAD_REGISTRY : TESTNET_PAD_REGISTRY);
        if (mainnet && !vm.envOr("FLYWHEEL_ALLOW_OVERRIDE", false)) _requireMainnetInputs(sh, gangPad, owner, keeper);
        _requireFactory(sh, mainnet ? M.PANCAKE_V2_FACTORY : T.PANCAKE_V2_FACTORY);
        console.log("=== DeployFlywheel chain", block.chainid, "===");
        console.log("deployer", me);
        console.log("owner", owner);

        address existing = vm.envOr("FLYWHEEL_PAD", address(0));
        vm.startBroadcast(pk);
        if (existing == address(0)) {
            Own memory o = _deploy(sh, mainnet, me, keeper);
            bool canWire = _canWire(sh, o, me);
            if (canWire) {
                _wireShared(sh, o);
                if (owner == me) GangFlywheelPad(payable(o.pad)).setMigrator(sh.migrator);
                _handOver(o, owner, me);
            }
            vm.stopBroadcast();
            _log(o);
            if (!canWire) {
                // audit V2 C-L1: everything that does not need the Safe's listings, before signers see the batch
                _checkOwn(sh, o, keeper, mainnet);
                console.log("self-check ok (phase 1: the pad and the handler as deployed; listings come in phase 2)");
                _printFingerprint(o);
                console.log("\n=== Safe batch: list the pad on the shared contracts, then run phase 2 ===");
                _printWiring(sh, o, mainnet);
            } else {
                _check(sh, o, owner, me, keeper, mainnet);
                if (owner != me) _printAccept(sh, o, mainnet, owner);
            }
            _afterRun(o, mainnet, owner);
        } else {
            Own memory o =
                Own({deployer: _existingDeployer(mainnet), handler: vm.envAddress("FLYWHEEL_HANDLER"), pad: existing});
            _requireShared(sh, o);
            if (owner == me && GangFlywheelPad(payable(o.pad)).migrator() == address(0)) {
                GangFlywheelPad(payable(o.pad)).setMigrator(sh.migrator);
            }
            _handOver(o, owner, me);
            vm.stopBroadcast();
            _check(sh, o, owner, me, keeper, mainnet);
            _log(o);
            if (owner != me) _printAccept(sh, o, mainnet, owner);
            _afterRun(o, mainnet, owner);
        }
    }

    // ------------------------------------------------------------ hooks (DeployFlywheelV2 overrides them)
    /// @dev Phase 2: the MintTokenDeployer phase 1 used.
    function _existingDeployer(bool) internal view virtual returns (address) {
        return vm.envAddress("FLYWHEEL_DEPLOYER");
    }

    /// @dev Whether the deploy wallet can list the pad on the shared contracts itself (testnet).
    function _canWire(Shared memory sh, Own memory, address me) internal view virtual returns (bool) {
        return Ownable(sh.vault).owner() == me && Ownable(sh.migrator).owner() == me && Ownable(sh.bucket).owner() == me
            && GangPadRegistry(sh.padRegistry).owner() == me;
    }

    /// @dev Phase 1 without `_canWire`: the Safe batch that lists the pad.
    function _printWiring(Shared memory sh, Own memory o, bool mainnet) internal view virtual {
        console.log(_wiringJson(sh, o, mainnet, Ownable(sh.vault).owner()));
    }

    /// @dev After either phase (nothing in V1). `owner`: who the contracts are handed to.
    function _afterRun(Own memory, bool, address) internal view virtual {}

    /// @dev The MintTokenDeployer side of the self-check: V1 deploys and lists its own deployer in phase 1.
    function _checkDeployer(Own memory o, bool) internal view virtual {
        if (!MintTokenDeployer(o.deployer).launchpads(o.pad)) revert NotWired("deployer.setLaunchpad");
    }

    /// @dev The routers the self-check knows: none may be listed on a new pad (the Safe lists them after review).
    function _knownRouters(bool mainnet) internal view returns (address[2] memory r) {
        if (mainnet) return [MAINNET_GANG_ROUTER, MAINNET_GANG_GATEWAY];
        r = [vm.envOr("GANG_ROUTER", address(0)), vm.envOr("GANG_GATEWAY", address(0))];
    }

    function _shared(address gangPad) internal view returns (Shared memory sh) {
        IGangPadShared p = IGangPadShared(gangPad);
        sh = Shared({
            quoteRegistry: p.quoteRegistry(),
            vault: p.dividendVault(),
            bucket: p.platformBucket(),
            migrator: p.migrator(),
            padRegistry: address(0)
        });
    }

    function _deploy(Shared memory sh, bool mainnet, address me, address keeper)
        internal
        virtual
        returns (Own memory o)
    {
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
    function _wireShared(Shared memory sh, Own memory o) internal virtual {
        SharedDividendVault v = SharedDividendVault(sh.vault);
        v.setLaunchpad(o.pad, true);
        v.setMinimumShareBalance(o.pad, MIN_SHARE);
        v.setOperator(o.handler, o.pad);
        SharedMigrator(sh.migrator).addLaunchpad(o.pad);
        SharedPlatformFeeBucket(sh.bucket).setOperator(o.pad, true);
        SharedPlatformFeeBucket(sh.bucket).setOperator(o.handler, true);
        GangPadRegistry(sh.padRegistry).addPad(o.pad);
    }

    function _requireShared(Shared memory sh, Own memory o) internal view virtual {
        SharedDividendVault v = SharedDividendVault(sh.vault);
        if (!v.launchpads(o.pad)) revert NotWired("vault.setLaunchpad(pad)");
        if (v.operatorOf(o.handler) != o.pad) revert NotWired("vault.setOperator(handler, pad)");
        if (v.minimumShareBalanceOf(o.pad) > MIN_SHARE) revert NotWired("vault floor of the pad above 1,000 tokens");
        if (!SharedMigrator(sh.migrator).launchpads(o.pad)) revert NotWired("migrator.addLaunchpad(pad)");
        if (!SharedPlatformFeeBucket(sh.bucket).operators(o.pad)) revert NotWired("bucket.setOperator(pad)");
        if (!SharedPlatformFeeBucket(sh.bucket).operators(o.handler)) revert NotWired("bucket.setOperator(handler)");
        if (!GangPadRegistry(sh.padRegistry).isPad(o.pad)) revert NotWired("padRegistry.addPad(pad)");
    }

    /// @dev The pad buys from the pairs the migrator seeds with Pancake V2's 0.25% fee hard-coded (review R2-2 I-3):
    ///      the migrator must use the same factory as the pad (the official Pancake V2 one of the chain).
    function _requireFactory(Shared memory sh, address factory) internal view {
        if (address(SharedMigrator(sh.migrator).factory()) != factory) {
            revert NotWired("migrator factory != Pancake V2");
        }
    }

    /// @dev Audit C-2: on mainnet the inputs are pinned (a testnet OWNER / KEEPER left in the env would hand the
    ///      contracts or the keeper role to the wrong wallet), and the Safe must own every shared contract.
    function _requireMainnetInputs(Shared memory sh, address gangPad, address owner, address keeper)
        internal
        view
        virtual
    {
        if (gangPad != MAINNET_GANG_PAD) revert NotWired("GANG_PAD is not the live GangLaunchpad");
        if (sh.padRegistry != MAINNET_PAD_REGISTRY) revert NotWired("GANG_PAD_REGISTRY is not the live registry");
        if (owner != M.OWNER_SAFE) revert NotWired("OWNER is not the platform Safe");
        if (keeper != M.KEEPER) revert NotWired("KEEPER is not the platform keeper");
        if (Ownable(sh.vault).owner() != M.OWNER_SAFE) revert NotWired("vault owner is not the Safe");
        if (Ownable(sh.bucket).owner() != M.OWNER_SAFE) revert NotWired("bucket owner is not the Safe");
        if (Ownable(sh.migrator).owner() != M.OWNER_SAFE) revert NotWired("migrator owner is not the Safe");
        if (Ownable(sh.padRegistry).owner() != M.OWNER_SAFE) revert NotWired("pad registry owner is not the Safe");
    }

    /// @dev Started once; skipped for a contract OWNER already owns (a re-run after the Safe accepted; audit C-4).
    function _handOver(Own memory o, address owner, address me) internal {
        if (owner == me) return;
        address[3] memory cs = [o.deployer, o.handler, o.pad];
        for (uint256 i; i < 3; i++) {
            Ownable2Step c = Ownable2Step(cs[i]);
            if (c.owner() != owner && c.pendingOwner() != owner) c.transferOwnership(owner);
        }
    }

    /// @dev Audit C-3: every setting phase 1 made, so a dropped phase 1 transaction is caught.
    function _check(Shared memory sh, Own memory o, address owner, address me, address keeper, bool mainnet)
        internal
        view
        virtual
    {
        _requireShared(sh, o);
        GangFlywheelPad p = GangFlywheelPad(payable(o.pad));
        if (p.migrator() == address(0)) {
            if (owner == me) revert NotWired("pad.setMigrator");
            console.log("pad.setMigrator: in the Safe batch below");
        } else if (p.migrator() != sh.migrator) {
            revert NotWired("pad.setMigrator");
        }
        _checkOwn(sh, o, keeper, mainnet);
        address[3] memory cs = [o.deployer, o.handler, o.pad];
        for (uint256 i; i < 3; i++) {
            Ownable2Step c = Ownable2Step(cs[i]);
            if (c.owner() != owner && c.pendingOwner() != owner) revert NotWired("ownership handover");
        }
        console.log("self-check ok");
    }

    /// @dev What phase 1 deployed and set, independent of the Safe's listings (audit V2 C-L1): pad and handler
    ///      immutables, the handler's pad / keeper / router, the Agent ID gate, the factories, the deployer, and (C-L3)
    ///      the pad's reference-pool window, no router listed, no bridge pool set.
    function _checkOwn(Shared memory sh, Own memory o, address keeper, bool mainnet) internal view virtual {
        GangFlywheelPad p = GangFlywheelPad(payable(o.pad));
        FlywheelTaxHandler h = FlywheelTaxHandler(o.handler);
        if (h.launchpad() != o.pad) revert NotWired("handler.setLaunchpad");
        if (h.keeper() != keeper) revert NotWired("handler keeper");
        if (address(h.dexRouter()) != (mainnet ? M.PANCAKE_V2_ROUTER : T.PANCAKE_V2_ROUTER)) {
            revert NotWired("handler router");
        }
        if (address(h.dividendVault()) != sh.vault || address(h.platformBucket()) != sh.bucket) {
            revert NotWired("handler shared contracts");
        }
        _checkDeployer(o, mainnet);
        if (address(p.agentIdRegistry()) == address(0) || !p.agentGateEnabled()) revert NotWired("agent gate");
        if (mainnet && address(p.agentIdRegistry()) != M.AGENT_ID_REGISTRY) revert NotWired("agent registry");
        if (p.taxHandler() != o.handler || p.tokenDeployer() != o.deployer) revert NotWired("pad immutables");
        if (
            address(p.quoteRegistry()) != sh.quoteRegistry || address(p.dividendVault()) != sh.vault
                || address(p.platformBucket()) != sh.bucket || p.wbnb() != (mainnet ? M.WBNB : T.WBNB)
        ) revert NotWired("pad shared contracts");
        if (p.pairFactory() != (mainnet ? M.PANCAKE_V2_FACTORY : T.PANCAKE_V2_FACTORY)) revert NotWired("pad factory");
        if (p.v3Factory() != (mainnet ? M.PANCAKE_V3_FACTORY : T.PANCAKE_V3_FACTORY)) {
            revert NotWired("pad v3 factory");
        }
        // `twapWindow()` exists from V2 on (re-review L-1: the live V1 pad has neither it nor `postRulesOf`)
        if (_isV2(p)) {
            if (p.twapWindow() != REF_TWAP_WINDOW) revert NotWired("pad reference-pool twapWindow");
        } else {
            console.log("V1 pad (no postRulesOf): reference-pool twapWindow not readable, not checked");
        }
        address[2] memory rs = _knownRouters(mainnet);
        for (uint256 i; i < 2; i++) {
            if (rs[i] != address(0) && p.routers(rs[i])) revert NotWired("a router is listed on the new pad");
        }
        if (p.bridgePoolOf(mainnet ? M.USDT : T.TEST_QUOTE) != address(0)) revert NotWired("a bridge pool is set");
    }

    /// @dev A V2 pad answers `postRulesOf`; a V1 pad reverts on it.
    function _isV2(GangFlywheelPad p) internal view returns (bool) {
        try p.postRulesOf(address(0)) returns (uint16, uint32) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev For the signers, next to the listing batch: what they are about to list (compare with the broadcast
    ///      record, broadcast/<script>/<chain>/run-latest.json, which holds the deploy transaction hashes).
    function _printFingerprint(Own memory o) internal view {
        console.log("\n=== fingerprint for the signers: the batch below lists exactly these ===");
        console.log("pad", o.pad);
        console.log("pad codehash", vm.toString(o.pad.codehash));
        console.log("handler", o.handler);
        console.log("handler codehash", vm.toString(o.handler.codehash));
        console.log("token deployer", o.deployer);
        console.log("deploy tx hashes: broadcast/<script>/<chain>/run-latest.json of this run");
    }

    /// @dev Only what is left for the Safe: the acceptOwnership calls it has not made, then `setMigrator` if the pad is
    ///      not open yet; nothing on a re-run once both are done (re-review of the audit fixes).
    function _printAccept(Shared memory sh, Own memory o, bool mainnet, address owner) internal view {
        bool open = GangFlywheelPad(payable(o.pad)).migrator() != address(0);
        address[3] memory cs = [o.deployer, o.handler, o.pad];
        bool[3] memory accept;
        bool any;
        for (uint256 i; i < 3; i++) {
            accept[i] = Ownable(cs[i]).owner() != owner;
            any = any || accept[i];
        }
        if (!any && open) {
            console.log("\nnothing left for the Safe: it owns the 3 flywheel contracts and the pad is open");
            return;
        }
        console.log("\n=== Safe batch: accept ownership and / or open the pad (setMigrator) ===");
        console.log(_acceptJson(sh, o, mainnet, owner, accept, !open));
        // audit V2 C-L3: the batch is checked against the chain as of this run
        console.log("REMINDER: re-run this phase-2 simulation (no --broadcast) right before signing the accept batch");
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
        j = string.concat(j, _wiringTxs(sh, o), "]}");
    }

    /// @dev The seven listings (vault ×3, migrator, bucket ×2, registry), comma-separated, no brackets.
    function _wiringTxs(Shared memory sh, Own memory o) internal pure returns (string memory) {
        return string.concat(
            _tx(sh.vault, abi.encodeCall(SharedDividendVault.setLaunchpad, (o.pad, true)), false),
            _tx(sh.vault, abi.encodeCall(SharedDividendVault.setMinimumShareBalance, (o.pad, MIN_SHARE)), true),
            _tx(sh.vault, abi.encodeCall(SharedDividendVault.setOperator, (o.handler, o.pad)), true),
            _tx(sh.migrator, abi.encodeCall(SharedMigrator.addLaunchpad, (o.pad)), true),
            _tx(sh.bucket, abi.encodeCall(SharedPlatformFeeBucket.setOperator, (o.pad, true)), true),
            _tx(sh.bucket, abi.encodeCall(SharedPlatformFeeBucket.setOperator, (o.handler, true)), true),
            _tx(sh.padRegistry, abi.encodeCall(GangPadRegistry.addPad, (o.pad)), true)
        );
    }

    /// @dev The acceptOwnership calls (deployer, handler, pad), then (audit C-1) `setMigrator`: the pad opens as the
    ///      Safe takes it.
    function _acceptJson(
        Shared memory sh,
        Own memory o,
        bool mainnet,
        address safe,
        bool[3] memory accept,
        bool openPad
    ) internal pure returns (string memory j) {
        j = _head(mainnet, safe, "gang: accept ownership of the continuous-mint contracts, open the pad");
        address[3] memory cs = [o.deployer, o.handler, o.pad];
        bool comma;
        for (uint256 i; i < 3; i++) {
            if (!accept[i]) continue;
            j = string.concat(j, _tx(cs[i], abi.encodeWithSignature("acceptOwnership()"), comma));
            comma = true;
        }
        if (openPad) {
            j = string.concat(j, _tx(o.pad, abi.encodeCall(GangFlywheelPad.setMigrator, (sh.migrator)), comma));
        }
        j = string.concat(j, "]}");
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
