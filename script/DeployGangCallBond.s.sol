// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {GangModulePadScript} from "./GangModulePadScript.sol";
import {GangMainnetRefs as M, GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {GangCallBond} from "../src/gang/GangCallBond.sol";

interface ICallBondPadVersion {
    function TOKEN_VERSION() external view returns (uint8);
}

/// @title DeployGangCallBond — 喊单保证金 (docs/SPEC-AGENT-CALLS-2026-11-09.md §5) for GangLaunchpad 3.0
/// @notice One contract, nothing to wire: it only reads the pad, balances and pairs. Binds to the 3.0 proxy for good,
///         with WBNB plus the three stablecoins on mainnet (USDT, USDC, USD1) or the test quote on testnet.
/// @dev Env: DEPLOYER_PRIVATE_KEY, GANG_PAD3, CALLBOND_SETTLER, CALLBOND_OWNER (mainnet: must be the Safe; testnet
///      default: the deployer); GANG_CALL_BOND (re-run: deploy nothing, only check that one). Mainnet broadcast needs
///      GANG_MAINNET_OK=true.
contract DeployGangCallBond is GangModulePadScript {
    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error WiringCheck(string what);

    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address internal constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;

    function run() external returns (GangCallBond cb) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();
        if (vm.envOr("GANG_PAD2", address(0)) != address(0)) revert WiringCheck("3.0 only: unset GANG_PAD2");

        address pad = _modulePad(mainnet);
        if (vm.envAddress("GANG_PAD3") != pad) revert WiringCheck("GANG_PAD3");
        if (ICallBondPadVersion(pad).TOKEN_VERSION() != 1) revert WiringCheck("pad TOKEN_VERSION");
        address wbnb = mainnet ? M.WBNB : T.WBNB;
        if (IGangPad(pad).wbnb() != wbnb) revert WiringCheck("pad.wbnb");
        address[3] memory quotes = mainnet ? [M.USDT, USDC, USD1] : [T.TEST_QUOTE, address(0), address(0)];

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = mainnet ? vm.envAddress("CALLBOND_OWNER") : vm.envOr("CALLBOND_OWNER", vm.addr(pk));
        if (mainnet && owner != M.OWNER_SAFE) revert WiringCheck("mainnet owner must be the Safe");
        address settler = vm.envAddress("CALLBOND_SETTLER");
        if (settler == address(0) || settler == owner || (mainnet && settler == vm.addr(pk))) {
            revert WiringCheck("settler");
        }

        address existing = vm.envOr("GANG_CALL_BOND", address(0));
        if (existing != address(0)) {
            cb = GangCallBond(existing);
        } else {
            vm.startBroadcast(pk);
            cb = new GangCallBond(pad, wbnb, quotes, owner, settler);
            vm.stopBroadcast();
        }

        if (cb.pad() != pad) revert WiringCheck("cb.pad");
        if (cb.wbnb() != wbnb) revert WiringCheck("cb.wbnb");
        if (cb.quote1() != quotes[0] || cb.quote2() != quotes[1] || cb.quote3() != quotes[2]) {
            revert WiringCheck("cb.quotes");
        }
        if (cb.owner() != owner) revert WiringCheck("cb.owner");
        if (cb.settler() != settler) revert WiringCheck("cb.settler");
        if (cb.bondCount() != 0 && existing == address(0)) revert WiringCheck("fresh");
        console.log("GangCallBond", address(cb));
        console.log("  pad    ", pad);
        console.log("  owner  ", owner);
        console.log("  settler", settler);
        console.log("  block  ", block.number);
    }
}
