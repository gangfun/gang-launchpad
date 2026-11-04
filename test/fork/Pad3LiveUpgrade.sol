// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";

/// @dev The upgrade script, keeping what the test needs from its run: the implementation it deployed, the 铸币飞轮
///      dependencies it resolved and the listings it put before the upgrade in the Safe batch.
contract FlyUpgradeHarness is UpgradeGangLaunchpad3 {
    address public deployedImpl;

    function _newImplWith(GangLaunchpad3 cur, address m) internal override returns (address a) {
        a = super._newImplWith(cur, m);
        // the first is `_newImpl`'s; later ones are the check's references
        if (deployedImpl == address(0)) deployedImpl = a;
    }

    function fly() external view returns (Pad3Impl.FlyDeps memory) {
        return _fly;
    }

    function prep(Stack memory s, address keeper, address upgrader)
        external
        view
        returns (address[] memory, bytes[] memory)
    {
        return _flyPrep(s, keeper, M.PANCAKE_V2_ROUTER, upgrader);
    }
}

/// @notice The live 3.0 proxy upgraded to this build on a fork, as on mainnet: `check` runs UpgradeGangLaunchpad3 (it
///         deploys what it needs from the deploy wallet and checks the upgrade in its simulation; the env must leave
///         PAD3_IMPL / PAD3_FLY_* unset or 0), `execute` sends the printed Safe batch (the 铸币飞轮 listings, then
///         the upgrade) as the Safe. See `batchFile` for the file the Safe signs.
library Pad3LiveUpgrade {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;

    function check() internal returns (FlyUpgradeHarness h, UpgradeGangLaunchpad3.Stack memory s) {
        h = new FlyUpgradeHarness();
        if (bytes(batchFile()).length != 0) return (h, s);
        s = h.run();
    }

    /// @dev PAD3_FORK_BATCH: the Safe batch written for signing (a path in the repo). With it, `check` runs nothing and
    ///      `execute` sends that file as the Safe, over the contracts it names (the rehearsal of spec §6).
    function batchFile() internal view returns (string memory) {
        return VM.envOr("PAD3_FORK_BATCH", string(""));
    }

    /// @notice Sends every transaction of a Safe batch file as the Safe; returns the proxy's implementation after it.
    function executeBatchFile(string memory path, address safe) internal returns (address impl) {
        string memory json = VM.readFile(path);
        VM.startPrank(safe);
        for (uint256 i;; i++) {
            string memory tx_ = string.concat(".transactions[", VM.toString(i), "]");
            if (!VM.keyExistsJson(json, tx_)) break;
            address to = VM.parseJsonAddress(json, string.concat(tx_, ".to"));
            (bool ok,) = to.call(VM.parseJsonBytes(json, string.concat(tx_, ".data")));
            require(ok, "a transaction of the Safe batch");
        }
        VM.stopPrank();
        impl = R.implementationOf(PAD3);
    }

    function execute(FlyUpgradeHarness h, UpgradeGangLaunchpad3.Stack memory s, address safe)
        internal
        returns (address impl)
    {
        if (bytes(batchFile()).length != 0) return executeBatchFile(batchFile(), safe);
        (address[] memory to, bytes[] memory data) = h.prep(s, M.KEEPER, safe);
        impl = h.deployedImpl();
        VM.startPrank(safe);
        for (uint256 i; i < to.length; i++) {
            (bool ok,) = to[i].call(data[i]);
            require(ok, "a listing in the Safe batch");
        }
        ProxyAdmin(R.adminOf(s.pad)).upgradeAndCall(ITransparentUpgradeableProxy(s.pad), impl, "");
        VM.stopPrank();
    }
}
