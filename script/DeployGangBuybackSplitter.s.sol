// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {GangBuybackSplitter} from "../src/gang/GangBuybackSplitter.sol";

/// @dev What the check reads from the tax handler and the dividend vault.
interface ISplitterListing {
    function isListed(address recipient) external view returns (bool);
}

interface ISplitterExclusion {
    function excluded(address account) external view returns (bool);
}

/// @title DeployGangBuybackSplitter — a dev's 税按比例回购 recipient, and the platform's check before listing it
/// @notice Deploy (SPLITTER unset): a GangBuybackSplitter for SPLITTER_DEV at SPLITTER_BPS over GANG_PAD.
///         Check (SPLITTER set): deploy nothing, check that one (a splitter someone else deployed).
///         Either way the splitter must pass `verify` before the Safe lists it: its pad is the platform's (mainnet: the
///         live pad, docs/MAINNET-GANG-2026-10-27.md) and its runtime code is exactly this repo's GangBuybackSplitter
///         for that pad and dev — a local reference deploy (never broadcast) carries the same immutables, so equal
///         code means the same source, pad, tax handler and dev. A splitter over a fake pad would buy from a fake pair.
///         Then prints the Safe batch: `handler.list(splitter, label)` (so the dev can name it as the recipient) and
///         `divVault.setExcluded(splitter, true)` (it holds the token only inside a buy-back chunk: no share writes).
///         Both modes also assert the splitter is SPLITTER_DEV's at SPLITTER_BPS (what the dev asked the platform to
///         list), not merely a genuine splitter: the two are required in check mode too, so a review can't skip them.
/// @dev Env: GANG_PAD (mainnet: must be the live pad); SPLITTER_DEV and SPLITTER_BPS (0–10000, refused above, never
///      truncated); SPLITTER (check only) or DEPLOYER_PRIVATE_KEY; SPLITTER_LABEL (default "buyback splitter");
///      mainnet broadcast needs GANG_MAINNET_OK=true.
contract DeployGangBuybackSplitter is Script {
    /// @notice The live GangLaunchpad on BSC 56 (docs/MAINNET-GANG-2026-10-27.md).
    address internal constant MAINNET_PAD = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;

    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error WiringCheck(string what);

    function run() external returns (GangBuybackSplitter splitter) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();

        address pad = vm.envAddress("GANG_PAD");
        if (mainnet ? pad != MAINNET_PAD : IGangPad(pad).wbnb() != T.WBNB) revert WiringCheck("pad");

        address dev = vm.envAddress("SPLITTER_DEV");
        uint16 bps = envBps();
        address existing = vm.envOr("SPLITTER", address(0));
        if (existing != address(0)) {
            splitter = GangBuybackSplitter(existing);
        } else {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
            splitter = new GangBuybackSplitter(pad, dev, bps);
            vm.stopBroadcast();
        }

        verify(pad, address(splitter));
        expect(address(splitter), dev, bps);
        _printBatch(pad, address(splitter), vm.envOr("SPLITTER_LABEL", string("buyback splitter")));
    }

    /// @notice SPLITTER_BPS as a ratio: above 10000 is refused (a plain uint16 cast would wrap 70000 to 4464).
    function envBps() public view returns (uint16) {
        uint256 raw = vm.envUint("SPLITTER_BPS");
        if (raw > 10_000) revert WiringCheck("SPLITTER_BPS");
        return uint16(raw);
    }

    /// @notice Revert unless `splitter` belongs to `dev` at `bps`, with no cut pending (a splitter listed at 50% with a
    ///         cut to 0 already asked for would drop to 0 three days later).
    function expect(address splitter, address dev, uint16 bps) public view {
        GangBuybackSplitter s = GangBuybackSplitter(splitter);
        if (s.dev() != dev) revert WiringCheck("splitter.dev");
        if (s.buybackBps() != bps) revert WiringCheck("splitter.buybackBps");
        (bool cutPending,,) = s.pendingCut();
        if (cutPending) revert WiringCheck("splitter.pendingCut");
    }

    /// @notice Revert unless `splitter` is this repo's GangBuybackSplitter over `pad` (see the contract notice).
    function verify(address pad, address splitter) public {
        if (splitter.code.length == 0) revert WiringCheck("splitter.code");
        if (GangBuybackSplitter(splitter).pad() != pad) revert WiringCheck("splitter.pad");
        if (GangBuybackSplitter(splitter).taxHandler() != IGangPad(pad).taxHandler()) {
            revert WiringCheck("splitter.taxHandler");
        }
        // local only: the reference shares every immutable with a genuine splitter for this pad and dev
        GangBuybackSplitter ref = new GangBuybackSplitter(pad, GangBuybackSplitter(splitter).dev(), 0);
        if (keccak256(address(ref).code) != keccak256(splitter.code)) revert WiringCheck("splitter.code");
    }

    function _printBatch(address pad, address splitter, string memory label) internal view {
        GangBuybackSplitter s = GangBuybackSplitter(splitter);
        address handler = IGangPad(pad).taxHandler();
        address vault = IGangPad(pad).dividendVault();
        console.log("GangBuybackSplitter", splitter);
        console.log("  dev        ", s.dev());
        console.log("  buybackBps ", uint256(s.buybackBps()));
        console.log("  token      ", s.token());
        console.log("  pad        ", pad);
        console.log("  block      ", block.number);
        console.log("Safe batch (owner of both):");
        if (ISplitterListing(handler).isListed(splitter)) {
            console.log("  handler.list: already listed");
        } else {
            console.log("  to  ", handler);
            console.logBytes(abi.encodeWithSignature("list(address,string)", splitter, label));
        }
        if (ISplitterExclusion(vault).excluded(splitter)) {
            console.log("  divVault.setExcluded: already excluded");
        } else {
            console.log("  to  ", vault);
            console.logBytes(abi.encodeWithSignature("setExcluded(address,bool)", splitter, true));
        }
    }
}
