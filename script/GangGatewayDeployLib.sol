// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GangGateway} from "../src/router/GangGateway.sol";
import {GangMainnetRefs as M} from "../config/GangDeployRefs.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";

/// @title GangGatewayDeployLib — the upgradeable GangGateway (AUDIT-BRIEF §25): deploy and read-back self-check
/// @notice The GangRouter shape (GangRouterDeployLib), because users approve this contract too:
///           impl      = GangGateway (its constructor locks it: never initializable)
///           timelock  = TimelockController(minDelay, proposers = [safe], executors = [safe], admin = address(0))
///           proxy     = TransparentUpgradeableProxy(impl, timelock, initialize(registry, wbnb, safe)) — initialized in its
///                       own constructor (no front-run window); it deploys its ProxyAdmin (owner = timelock)
///         Each pad lists the PROXY (setRouter); an upgrade is timelock.schedule → wait minDelay → timelock.execute of
///         ProxyAdmin.upgradeAndCall(proxy, newImpl, data), both from the Safe.
/// @dev Internal functions only (inlined into the calling script: `new` broadcasts from its deployer).
library GangGatewayDeployLib {
    struct Gateway {
        /// @dev the address pads list and users approve (GANG_GATEWAY)
        address proxy;
        address impl;
        address proxyAdmin;
        address timelock;
    }

    struct Expect {
        address registry;
        address wbnb;
        /// @dev the timelock's only proposer / executor / canceller (mainnet: must be the platform Safe M.OWNER_SAFE)
        address safe;
        /// @dev must hold no timelock role (mainnet: always; testnet: unless it is also `safe`)
        address deployer;
        uint256 minDelay;
        bool mainnet;
    }

    error WiringCheck(string what);

    /// @notice impl → timelock → proxy (initialized in its constructor). Does NOT list it on any pad.
    function deploy(address registry, address wbnb, address safe, uint256 minDelay)
        internal
        returns (Gateway memory g)
    {
        // a mainnet gateway timelock belongs to the platform Safe and nobody else
        if (block.chainid == 56 && safe != M.OWNER_SAFE) revert R.MainnetTimelockNotSafe(safe);
        g.impl = address(new GangGateway());
        address[] memory only = new address[](1);
        only[0] = safe;
        g.timelock = address(new TimelockController(minDelay, only, only, address(0)));
        g.proxy = address(
            new TransparentUpgradeableProxy(
                g.impl, g.timelock, abi.encodeCall(GangGateway.initialize, (registry, wbnb, safe))
            )
        );
        g.proxyAdmin = R.adminOf(g.proxy);
    }

    /// @notice Read impl / ProxyAdmin / timelock back from a deployed proxy (re-run: only GANG_GATEWAY is given).
    function load(address proxy) internal view returns (Gateway memory g) {
        g.proxy = proxy;
        g.impl = R.implementationOf(proxy);
        g.proxyAdmin = R.adminOf(proxy);
        if (g.proxyAdmin.code.length == 0) revert WiringCheck("gateway admin slot");
        g.timelock = ProxyAdmin(g.proxyAdmin).owner();
    }

    /// @notice Proxy code, impl (this build's code, locked), ProxyAdmin (the proxy's own, plain OZ, owned by the
    ///         timelock), the proxy's registry / WBNB / owner (= the Safe, no pending hand-over), and the timelock
    ///         (GangRouterDeployLib.checkTimelock: plain OZ code, delay, the Safe's roles only, no admin but itself).
    ///         Any mismatch reverts with its name.
    function check(Gateway memory g, Expect memory e) internal view {
        R.Router memory asRouter =
            R.Router({proxy: g.proxy, impl: g.impl, proxyAdmin: g.proxyAdmin, timelock: g.timelock});
        R.checkProxyCode(asRouter);
        if (g.impl == address(0) || R.implementationOf(g.proxy) != g.impl) revert WiringCheck("gateway impl slot");
        if (!R.sameCode(g.impl, type(GangGateway).runtimeCode)) revert WiringCheck("gateway impl code");
        (uint64 implVersion,) = R.initState(g.impl);
        if (implVersion != type(uint64).max || address(GangGateway(payable(g.impl)).registry()) != address(0)) {
            revert WiringCheck("gateway impl locked");
        }
        if (R.adminOf(g.proxy) != g.proxyAdmin || g.proxyAdmin != _createAddress(g.proxy, 1)) {
            revert WiringCheck("gateway admin slot");
        }
        if (!R.sameCode(g.proxyAdmin, type(ProxyAdmin).runtimeCode)) revert WiringCheck("gateway admin code");
        if (ProxyAdmin(g.proxyAdmin).owner() != g.timelock) revert WiringCheck("gateway admin owner");

        (uint64 v, bool initializing) = R.initState(g.proxy);
        if (v == 0 || initializing) revert WiringCheck("gateway initialized");
        GangGateway gw = GangGateway(payable(g.proxy));
        if (address(gw.registry()) != e.registry || e.registry == address(0)) revert WiringCheck("gateway registry");
        if (gw.wbnb() != e.wbnb || e.wbnb == address(0)) revert WiringCheck("gateway wbnb");
        // the sell-caller whitelist belongs to the same Safe that runs the timelock, with no hand-over pending
        if (gw.owner() != e.safe || gw.pendingOwner() != address(0)) revert WiringCheck("gateway owner");

        R.checkTimelock(
            asRouter,
            R.Expect({
                pad: address(0),
                wbnb: e.wbnb,
                pancakeRouter: address(0),
                pancakeFactory: address(0),
                safe: e.safe,
                deployer: e.deployer,
                minDelay: e.minDelay,
                mainnet: e.mainnet
            })
        );
    }

    /// @dev CREATE address for nonce < 128 (a fresh proxy's first deployment is nonce 1).
    function _createAddress(address deployer, uint8 nonce) private pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(nonce))))));
    }
}
