// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GangMainnetRefs as M, GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";

/// @title DeployGangRouterUpgradeable — only the upgradeable GangRouter, for a GangLaunchpad that already exists
/// @notice Deploys implementation → TimelockController (proposer / executor / canceller = OWNER, no admin) →
///         TransparentUpgradeableProxy (initialized with the pad, WBNB and the Pancake V2 router), the same shape as
///         DeployGang (GangRouterDeployLib, AUDIT-BRIEF §21). Then lists the proxy on the pad and excludes it in the
///         pad's dividend vault when the deploy wallet owns them (testnet stacks); otherwise prints the owner's
///         `setRouter(proxy, true)` / `setExcluded(proxy, true)` calls. Runs the router
///         self-check and refuses to finish if anything differs.
///         The pad's other routers are left as they are (an old router stays listed until the owner unlists it).
/// @dev Env: DEPLOYER_PRIVATE_KEY, GANG_PAD; OWNER (the timelock's only role holder; mainnet: required and must be
///      the platform Safe, else OwnerRequired / OwnerNotSafe; testnet default the deployer); ROUTER_TIMELOCK_DELAY (seconds, default
///      172800; mainnet refuses any other value); GANG_ROUTER (re-run: deploy nothing, only check that proxy);
///      mainnet broadcast needs GANG_MAINNET_OK=true.
///      Testnet set 8: GANG_PAD=0x4f7391D69cbf62891Ba8db929c323cd2609b94e7 (owner = the deploy wallet 0xCa8e…00b6,
///      so setRouter runs here).
interface IExcludable {
    function setExcluded(address account, bool isExc) external;
    function excluded(address account) external view returns (bool);
}

contract DeployGangRouterUpgradeable is Script {
    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error OwnerRequired();
    error OwnerNotSafe(address owner);
    error WiringCheck(string what);

    function run() external returns (R.Router memory r) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address padAddr = vm.envAddress("GANG_PAD");
        IGangPad pad = IGangPad(padAddr);
        address wbnb = mainnet ? M.WBNB : T.WBNB;
        address pancake = mainnet ? M.PANCAKE_V2_ROUTER : T.PANCAKE_V2_ROUTER;
        if (pad.wbnb() != wbnb) revert WiringCheck("pad.wbnb");
        address owner = vm.envOr("OWNER", address(0));
        if (owner == address(0)) {
            if (mainnet) revert OwnerRequired();
            owner = deployer;
        }
        // mainnet: the router timelock belongs to the platform Safe, nobody else
        if (mainnet && owner != M.OWNER_SAFE) revert OwnerNotSafe(owner);
        uint256 delay = R.minDelayFromEnv(mainnet);
        address padOwner = Ownable(padAddr).owner();
        address vault = pad.dividendVault();
        address vaultOwner = Ownable(vault).owner();

        address existing = vm.envOr("GANG_ROUTER", address(0));
        if (existing != address(0)) {
            r = R.load(existing);
        } else {
            vm.startBroadcast(pk);
            r = R.deploy(padAddr, wbnb, pancake, owner, delay);
            if (padOwner == deployer) pad.setRouter(r.proxy, true);
            if (vaultOwner == deployer) IExcludable(vault).setExcluded(r.proxy, true);
            vm.stopBroadcast();
        }

        R.check(
            r,
            R.Expect({
                pad: padAddr,
                wbnb: wbnb,
                pancakeRouter: pancake,
                pancakeFactory: mainnet ? M.PANCAKE_V2_FACTORY : T.PANCAKE_V2_FACTORY,
                safe: owner,
                deployer: deployer,
                minDelay: delay,
                mainnet: mainnet
            })
        );
        if (pad.routers(r.impl) || pad.routers(r.proxyAdmin) || pad.routers(r.timelock)) {
            revert WiringCheck("pad.routers impl");
        }
        bool listed = pad.routers(r.proxy);
        if (padOwner == deployer && !listed) revert WiringCheck("pad.routers");
        bool excluded = IExcludable(vault).excluded(r.proxy);
        if (vaultOwner == deployer && !excluded) revert WiringCheck("vault excludes router");

        console.log("=== DeployGangRouterUpgradeable chain", block.chainid, "===");
        console.log("GANG_PAD", padAddr);
        console.log("GANG_ROUTER (proxy: the pad lists it, users approve it)", r.proxy);
        console.log("GANG_ROUTER_IMPL", r.impl);
        console.log("GANG_ROUTER_PROXY_ADMIN (owner = the timelock)", r.proxyAdmin);
        console.log("GANG_ROUTER_TIMELOCK", r.timelock);
        console.log("timelock proposer / executor / canceller", owner);
        console.log("timelock minDelay (s)", delay);
        console.log("pancakeRouter", pancake);
        if (listed) {
            console.log("pad.routers(proxy) = true");
        } else {
            console.log("PENDING pad owner", padOwner, ": setRouter(proxy, true) on the pad:");
            console.logBytes(abi.encodeCall(IGangPad.setRouter, (r.proxy, true)));
        }
        if (excluded) {
            console.log("dividendVault.excluded(proxy) = true");
        } else {
            console.log("PENDING vault owner", vaultOwner, ": setExcluded(proxy, true) on the dividend vault", vault);
            console.logBytes(abi.encodeCall(IExcludable.setExcluded, (r.proxy, true)));
        }
    }
}
