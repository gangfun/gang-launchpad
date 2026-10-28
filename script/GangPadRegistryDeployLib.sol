// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {GangPadRegistry} from "../src/gang/GangPadRegistry.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";

/// @title GangPadRegistryDeployLib — the upgradeable GangPadRegistry: deploy and read-back self-check
/// @notice impl  = GangPadRegistry (its constructor locks it: never initializable)
///         proxy = TransparentUpgradeableProxy(impl, owner, initialize(owner, pads)) — initialized in its own
///                 constructor (no front-run window); it deploys its ProxyAdmin (owner = `owner`)
///         On mainnet `owner` is the platform Safe (2 of 3): it owns both the registry (addPad) and the registry's
///         ProxyAdmin (upgrades), with no timelock.
/// @dev Internal functions only (inlined into the calling script: `new` broadcasts from its deployer).
library GangPadRegistryDeployLib {
    struct Registry {
        /// @dev the address aggregators keep (GANG_PAD_REGISTRY)
        address proxy;
        address impl;
        address proxyAdmin;
    }

    error WiringCheck(string what);

    function deploy(address owner, address[] memory pads) internal returns (Registry memory r) {
        r.impl = address(new GangPadRegistry());
        r.proxy = address(
            new TransparentUpgradeableProxy(r.impl, owner, abi.encodeCall(GangPadRegistry.initialize, (owner, pads)))
        );
        r.proxyAdmin = R.adminOf(r.proxy);
    }

    function load(address proxy) internal view returns (Registry memory r) {
        r.proxy = proxy;
        r.impl = R.implementationOf(proxy);
        r.proxyAdmin = R.adminOf(proxy);
        if (r.proxyAdmin.code.length == 0) revert WiringCheck("registry admin slot");
    }

    /// @notice Proxy code, impl (this build's code, locked), ProxyAdmin (the proxy's own, plain OZ, owned by
    ///         `owner`), the registry's owner (no pending hand-over) and its pads, in order. Any mismatch reverts with
    ///         its name.
    function check(Registry memory r, address owner, address[] memory pads) internal view {
        R.checkProxyCode(R.Router({proxy: r.proxy, impl: r.impl, proxyAdmin: r.proxyAdmin, timelock: address(0)}));
        if (r.impl == address(0) || R.implementationOf(r.proxy) != r.impl) revert WiringCheck("registry impl slot");
        // code compared without the trailing metadata (R.sameCode): a re-run from another build still matches
        if (!R.sameCode(r.impl, type(GangPadRegistry).runtimeCode)) revert WiringCheck("registry impl code");
        (uint64 implVersion,) = R.initState(r.impl);
        if (implVersion != type(uint64).max || GangPadRegistry(r.impl).owner() != address(0)) {
            revert WiringCheck("registry impl locked");
        }
        if (R.adminOf(r.proxy) != r.proxyAdmin || r.proxyAdmin != _createAddress(r.proxy, 1)) {
            revert WiringCheck("registry admin slot");
        }
        if (!R.sameCode(r.proxyAdmin, type(ProxyAdmin).runtimeCode)) revert WiringCheck("registry admin code");
        if (ProxyAdmin(r.proxyAdmin).owner() != owner) revert WiringCheck("registry admin owner");

        (uint64 v, bool initializing) = R.initState(r.proxy);
        if (v == 0 || initializing) revert WiringCheck("registry initialized");
        GangPadRegistry g = GangPadRegistry(r.proxy);
        if (g.owner() != owner || owner == address(0)) revert WiringCheck("registry owner");
        if (g.pendingOwner() != address(0)) revert WiringCheck("registry pendingOwner");
        if (g.padCount() != pads.length) revert WiringCheck("registry pads");
        for (uint256 i; i < pads.length; i++) {
            if (g.padAt(i) != pads[i] || !g.isPad(pads[i])) revert WiringCheck("registry pads");
        }
    }

    /// @dev CREATE address for nonce < 128 (a fresh proxy's first deployment is nonce 1).
    function _createAddress(address deployer, uint8 nonce) private pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(nonce))))));
    }
}
