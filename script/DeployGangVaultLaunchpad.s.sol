// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangVaultPad} from "../src/gang/interfaces/IGangVaultPad.sol";
import {IGangTaxHandlerOps} from "../src/gang/interfaces/IGangTaxHandlerOps.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";
import {GangVaultLaunchpad, GangTaxHandler} from "./GangContracts.sol";
import {DeployGangLaunchpad2} from "./DeployGangLaunchpad2.s.sol";

/// @title DeployGangVaultLaunchpad — GangVaultLaunchpad (2.0 + a lock vault per curve token) next to 1.0 and 2.0
/// @notice The 2.0 deploy (DeployGangLaunchpad2: same phases, checks and Safe batches 1 / 2) with these differences:
///         - the pad is a GangVaultLaunchpad (only `createWithVault`), with its own handler, router and fresh
///           CurveLogic / FairLogic (CurveLogic's `buy` takes the locked amount: a 2.0 library can't serve it);
///         - its own env names: phase 2 reads GANG_VAULT_PAD / GANG_VAULT_ROUTER / GANG_VAULT_PAD_BLOCK (2.0's
///           GANG_PAD2 & co. are ignored, so a 2.0 address left in the env is never picked up);
///         - mainnet phase 1 also needs VAULT_PAD_NEW=true (a phase 2 run that forgot GANG_VAULT_PAD must not deploy a
///           second pad);
///         - VAULT (optional): a vault to list on the pad (`setVault`) and as a tax recipient on the handler (`list`,
///           label VAULT_LABEL). Testnet phase 1: the deployer lists it. Mainnet: refused in phase 1; phase 2 prints it
///           as its own Safe batch, once the Safe owns the pad and the handler, after a simulated run of it;
///         - VAULT_CREATOR (optional, with VAULT): the wallet named to create the vault's token (`setVaultCreator`,
///           single use). Testnet phase 1: set by the deployer. Mainnet: in VAULT's batch, or (VAULT already listed)
///           its own batch;
///         - no cut-over batch: 1.0 and 2.0 keep creating, this pad runs next to them;
///         - no modules: GangBond, buyback / split / LP / combo factories are not wired for this pad (a vault token's
///           tax goes to its vault; GangBond reads `balanceOf(creator)`, which a lock lowers).
/// @dev Link as DeployGangLaunchpad2 (mainnet: PoolCheck only; never CurveLogic / FairLogic, forge deploys them fresh).
contract DeployGangVaultLaunchpad is DeployGangLaunchpad2 {
    /// @dev VAULT, not listed on the pad yet: its Safe batch is printed at the end of phase 2.
    address internal pendingVault;
    /// @dev VAULT_CREATOR, not yet named for VAULT: in VAULT's batch (or a batch of its own once VAULT is listed).
    address internal pendingCreator;

    function _padName() internal pure override returns (string memory) {
        return "GangVaultLaunchpad";
    }

    function _padEnv() internal pure override returns (string memory) {
        return "GANG_VAULT_PAD";
    }

    function _routerEnv() internal pure override returns (string memory) {
        return "GANG_VAULT_ROUTER";
    }

    function _blockEnv() internal pure override returns (string memory) {
        return "GANG_VAULT_PAD_BLOCK";
    }

    /// @dev Review 2026-11-01 H-1 / M-1: on mainnet a fresh deploy needs VAULT_PAD_NEW=true, and never takes VAULT
    ///      (the Safe lists vaults, through the batch phase 2 prints).
    function _ctx(bool mainnet) internal view override returns (Ctx memory x) {
        x = super._ctx(mainnet);
        if (mainnet && _envAddr(_padEnv(), address(0)) == address(0)) {
            if (!vm.envOr("VAULT_PAD_NEW", false)) revert WiringCheck("phase 1 on mainnet needs VAULT_PAD_NEW=true");
            if (_vault() != address(0)) revert WiringCheck("VAULT must be empty in mainnet phase 1 (Safe batch)");
            if (_vaultCreator() != address(0)) revert WiringCheck("VAULT_CREATOR must be empty in mainnet phase 1");
        }
    }

    function _deploy2(Stack memory s, Cfg memory c) internal override {
        s.handler = address(new GangTaxHandler(c.deployer, s.vault, s.bucket, c.dexRouter));
        s.pad = address(
            new GangVaultLaunchpad(
                c.deployer, s.quoteRegistry, s.vault, s.bucket, s.handler, s.tokenDeployer, c.wbnb, c.factory
            )
        );
        s.padBlock = block.number;
        _setRouter(s, R.deploy(s.pad, c.wbnb, c.dexRouter, R.timelockSafe(c.mainnet, c.owner), c.routerDelay));
    }

    /// @dev Phase 2: the pad from the env must be a vault pad, before anything is sent.
    function _load2(address pad2, address pad1, Cfg memory c) internal view override returns (Stack memory s) {
        if (!_hasSelector(pad2.code, IGangVaultPad.createWithVault.selector)) {
            revert WiringCheck("GANG_VAULT_PAD is not a GangVaultLaunchpad");
        }
        s = super._load2(pad2, pad1, c);
    }

    /// @dev 2.0's wiring, then (testnet only) the vault: after the routers, since a router can't be listed as a vault.
    function _wireOwn(Stack memory s, Cfg memory c, Ctx memory x) internal override {
        super._wireOwn(s, c, x);
        address v = _vault();
        if (v == address(0)) return;
        if (c.mainnet) revert WiringCheck("VAULT on mainnet: Safe batch only");
        IGangVaultPad(s.pad).setVault(v, true);
        IGangTaxHandlerOps(s.handler).list(v, _vaultLabel());
        address vc = _vaultCreator();
        if (vc != address(0)) IGangVaultPad(s.pad).setVaultCreator(v, vc);
    }

    /// @dev 2.0's checks (which also prove the new CurveLogic is linked: `buy` reaches it), then the vault pad's own.
    function _checkPre(Stack memory s, Cfg memory c, Ctx memory x, bool closedOk) internal override {
        super._checkPre(s, c, x, closedOk);
        _checkVaultPad(s);
    }

    /// @dev A GangVaultLaunchpad: its dispatcher holds the vault entries, every other create is refused, a lock for an
    ///      unbound token is refused. VAULT (when given): listed on the pad and the handler and no router, or, not
    ///      listed yet, fit to be listed (a contract, no router): its batch is printed at the end.
    ///      Not view: `vaultLock` is nonReentrant (it writes); the probe reverts, outside the broadcast.
    function _checkVaultPad(Stack memory s) internal {
        bytes memory code = s.pad.code;
        bytes4[4] memory sels = [
            IGangVaultPad.createWithVault.selector,
            IGangVaultPad.vaultLock.selector,
            IGangVaultPad.vaultRelease.selector,
            IGangVaultPad.setVaultCreator.selector
        ];
        for (uint256 i; i < 4; i++) {
            if (!_hasSelector(code, sels[i])) revert WiringCheck("not a GangVaultLaunchpad");
        }
        IGangLaunchpad.TaxConfig memory tax;
        IGangLaunchpad.MintConfig memory mint;
        bytes[3] memory creates = [
            abi.encodeWithSignature(
                "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))",
                "",
                "",
                "",
                "",
                address(0),
                address(0),
                tax
            ),
            abi.encodeCall(IGangPad.createWithGradTarget, ("", "", "", "", address(0), address(0), tax, 0)),
            abi.encodeWithSignature(
                "create(string,string,string,string,address,address,(uint256,uint16,uint16,uint16,uint16),uint256)",
                "",
                "",
                "",
                "",
                address(0),
                address(0),
                mint,
                0
            )
        ];
        for (uint256 i; i < 3; i++) {
            _expectRevert(s.pad, creates[i], IGangVaultPad.UseVaultCreate.selector, "other creates not refused");
        }
        address probe = address(uint160(uint256(keccak256("gang.deploy-vault.unknown-token"))));
        _expectRevert(
            s.pad, abi.encodeCall(IGangVaultPad.vaultLock, (probe, probe, 1)), IGangVaultPad.NotVault.selector, "lock"
        );
        address v = _vault();
        address vc = _vaultCreator();
        if (v == address(0)) {
            if (vc != address(0)) revert WiringCheck("VAULT_CREATOR without VAULT");
            return;
        }
        if (vc != address(0) && IGangVaultPad(s.pad).vaultCreator(v) != vc) pendingCreator = vc;
        if (IGangPad(s.pad).routers(v)) revert WiringCheck("VAULT is a router");
        if (IGangVaultPad(s.pad).isVault(v)) {
            if (!GangTaxHandler(s.handler).isListed(v)) revert WiringCheck("VAULT not listed on the handler");
        } else {
            if (v.code.length == 0) revert WiringCheck("VAULT has no code");
            pendingVault = v;
        }
    }

    function _expectRevert(address target, bytes memory data, bytes4 err, string memory what) internal {
        (bool ok, bytes memory ret) = target.call(data);
        if (ok || ret.length < 4 || bytes4(ret) != err) revert WiringCheck(what);
    }

    function _vault() internal view returns (address) {
        return _envAddr("VAULT", address(0));
    }

    function _vaultCreator() internal view returns (address) {
        return _envAddr("VAULT_CREATOR", address(0));
    }

    function _vaultLabel() internal view returns (string memory) {
        return vm.envOr("VAULT_LABEL", string("vault"));
    }

    /// @dev No cut-over (this pad runs next to 1.0 and 2.0). Instead, once the pad is open: VAULT's listing batch
    ///      (with VAULT_CREATOR named), or, VAULT listed already, the batch naming VAULT_CREATOR.
    function _printCutover(Stack memory s, Ctx memory, Cfg memory c) internal override {
        address v = pendingVault;
        address vc = pendingCreator;
        if (v == address(0) && vc == address(0)) return;
        if (v == address(0)) v = _vault();
        bool listing = pendingVault != address(0);
        // a re-listed vault is usually still on the handler (delisting the vault leaves the handler alone)
        bool handlerList = listing && !GangTaxHandler(s.handler).isListed(v);
        address padOwner = Ownable(s.pad).owner();
        address handlerOwner = Ownable(s.handler).owner();
        if (
            Ownable2Step(s.pad).pendingOwner() != address(0)
                || (handlerList && (padOwner != handlerOwner || Ownable2Step(s.handler).pendingOwner() != address(0)))
        ) {
            console.log("\nVAULT pending: run batch 2 (the owner accepts the pad and the handler), then re-run phase 2");
            return;
        }
        address current = IGangVaultPad(s.pad).vaultCreator(v);
        // the batch runs in the simulation first (rolled back): it must go through as the owner sends it
        uint256 snap = vm.snapshotState();
        if (listing) {
            vm.prank(padOwner);
            IGangVaultPad(s.pad).setVault(v, true);
        }
        if (handlerList) {
            vm.prank(handlerOwner);
            IGangTaxHandlerOps(s.handler).list(v, _vaultLabel());
        }
        if (vc != address(0)) {
            vm.prank(padOwner);
            IGangVaultPad(s.pad).setVaultCreator(v, vc);
        }
        bool ok = IGangVaultPad(s.pad).isVault(v) && GangTaxHandler(s.handler).isListed(v)
            && (vc == address(0) || IGangVaultPad(s.pad).vaultCreator(v) == vc);
        vm.revertToState(snap);
        if (!ok) revert WiringCheck("VAULT batch");
        string memory j;
        if (listing) {
            console.log(
                handlerList
                    ? "\n=== Safe batch: list VAULT on GangVaultLaunchpad (pad.setVault + handler.list) ==="
                    : "\n=== Safe batch: re-list VAULT on GangVaultLaunchpad (pad.setVault; handler: listed already) ==="
            );
            j = string.concat(
                _head(c.mainnet, padOwner, "gang: list a vault on GangVaultLaunchpad"),
                _tx(s.pad, abi.encodeCall(IGangVaultPad.setVault, (v, true)), false)
            );
            if (handlerList) {
                j = string.concat(j, _tx(s.handler, abi.encodeCall(IGangTaxHandlerOps.list, (v, _vaultLabel())), true));
            }
        } else {
            console.log(
                "\n=== Safe batch: name VAULT_CREATOR for VAULT on GangVaultLaunchpad (pad.setVaultCreator) ==="
            );
            j = _head(c.mainnet, padOwner, "gang: name a vault's creator on GangVaultLaunchpad");
        }
        if (vc != address(0)) {
            j = string.concat(j, _tx(s.pad, abi.encodeCall(IGangVaultPad.setVaultCreator, (v, vc)), listing));
        }
        console.log("VAULT", v);
        if (vc != address(0)) {
            console.log("VAULT_CREATOR (single use: this grant binds ONE more token to VAULT)", vc);
            if (current != address(0)) console.log("  replaces the unused grant to", current);
            else console.log("  no grant open now: any earlier grant was used up (or never given)");
        }
        console.log(string.concat(j, "]}"));
    }

    function _log2(Stack memory s, Cfg memory c) internal view override {
        console.log("--- GANG VAULT LAUNCHPAD (2.0 + lock vaults) ---");
        console.log("GANG_VAULT_PAD", s.pad);
        console.log("GANG_VAULT_PAD_BLOCK", s.padBlock);
        console.log("GANG_VAULT_TAX_HANDLER", s.handler);
        console.log("GANG_VAULT_ROUTER (proxy: the pad lists it, users approve it)", s.router);
        console.log("GANG_VAULT_ROUTER_IMPL", s.routerImpl);
        console.log("GANG_VAULT_ROUTER_PROXY_ADMIN (owner = the timelock)", s.routerAdmin);
        console.log("GANG_VAULT_ROUTER_TIMELOCK", s.routerTimelock);
        console.log("router timelock proposer / executor / canceller", R.timelockSafe(c.mainnet, c.owner));
        console.log("shared (1.0's): QUOTE_REGISTRY", s.quoteRegistry);
        console.log("shared (1.0's): PLATFORM_BUCKET", s.bucket);
        console.log("shared (1.0's): DIVIDEND_VAULT", s.vault);
        console.log("shared (1.0's): MIGRATOR", s.migrator);
        console.log("shared (1.0's): TOKEN_DEPLOYER", s.tokenDeployer);
        if (s.padBlock != 0) {
            console.log("--- for the keeper / indexer: runs next to 1.0 and 2.0 (start block below) ---");
            console.log(string.concat("gang:", vm.toString(s.pad), "@", vm.toString(s.padBlock)));
            console.log("indexer: balances also move on VaultLocked / VaultReleased (Transfer), not only Buy / Sell");
        }
        console.log("NOT WIRED (by design): GangBond and the module factories; no cut-over batch");
    }
}
