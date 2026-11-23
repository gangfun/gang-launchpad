// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GangSwapMigrator} from "../src/GangSwapMigrator.sol";
import {GangSwapBoost} from "../src/GangSwapBoost.sol";
import {GangSwapFees} from "../src/GangSwapFees.sol";
import {IGangSwapFactory} from "../src/interfaces/IGangSwap.sol";

interface IRouterView {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

/// @notice Deploys the GangSwap set (spec docs/SPEC-GANGSWAP-2026-11-22.md §13 step 1): migrator, boost, fees and
///         factory point at each other, so their addresses are predicted from the deployer's nonce; then the router.
///         Refuses to finish unless (review M1 / M2):
///         - every predicted address is where the contract landed,
///         - `migrator.wired()` (factory, boost and fees all point back),
///         - the router's hard-coded pair init code hash equals `factory.INIT_CODE_PAIR_HASH()` (else every router call
///           would hit an empty address; run `sync-init-hash.sh` after any pair edit).
///         Pads are NOT listed here: `addLaunchpad` and the pad's `setGangSwapMigrator` go through the Safe (§13 step 2).
/// @dev    forge script script/DeployGangSwap.s.sol --root gangswap --rpc-url <rpc> --account <keystore> --broadcast
///         Env: GANGSWAP_OWNER (migrator owner: the Safe), WBNB, FEE_BUCKET (SharedPlatformFeeBucket). No keys in env.
contract DeployGangSwap is Script {
    function run() external returns (address migrator, address boost, address fees, address factory, address router) {
        address owner = vm.envAddress("GANGSWAP_OWNER");
        address wbnb = vm.envAddress("WBNB");
        address bucket = vm.envAddress("FEE_BUCKET");
        require(owner != address(0) && wbnb.code.length > 0 && bucket.code.length > 0, "bad env");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        uint64 n = vm.getNonce(deployer);
        address mAddr = vm.computeCreateAddress(deployer, n);
        address bAddr = vm.computeCreateAddress(deployer, n + 1);
        address fAddr = vm.computeCreateAddress(deployer, n + 2);
        address facAddr = vm.computeCreateAddress(deployer, n + 3);

        migrator = address(new GangSwapMigrator(owner, facAddr, bAddr, wbnb));
        boost = address(new GangSwapBoost(mAddr, wbnb));
        fees = address(new GangSwapFees(facAddr, mAddr, bucket, wbnb));
        factory = deployCode("GangSwapPair.sol:GangSwapFactory", abi.encode(mAddr, fAddr));
        router = deployCode("GangSwapRouter.sol:GangSwapRouter", abi.encode(factory, wbnb));
        vm.stopBroadcast();

        require(migrator == mAddr && boost == bAddr && fees == fAddr && factory == facAddr, "address prediction");
        require(GangSwapMigrator(migrator).wired(), "not wired");
        require(IRouterView(router).factory() == factory && IRouterView(router).WETH() == wbnb, "router wiring");
        require(routerInitHash() == IGangSwapFactory(factory).INIT_CODE_PAIR_HASH(), "router init code hash");

        console.log("GangSwapMigrator", migrator);
        console.log("GangSwapBoost   ", boost);
        console.log("GangSwapFees    ", fees);
        console.log("GangSwapFactory ", factory);
        console.log("GangSwapRouter  ", router);
    }

    /// @notice The `hex'...' // init code hash` constant compiled into GangSwapRouter (read from its source).
    function routerInitHash() public view returns (bytes32 h) {
        bytes memory src = bytes(vm.readFile(string.concat(vm.projectRoot(), "/src/GangSwapRouter.sol")));
        bytes memory marker = bytes("' // init code hash");
        uint256 at = _find(src, marker);
        require(at >= 64 && src[at - 65] == "'", "init hash constant not found");
        h = vm.parseBytes32(string.concat("0x", string(_slice(src, at - 64, 64))));
    }

    function _find(bytes memory hay, bytes memory needle) private pure returns (uint256) {
        for (uint256 i; i + needle.length <= hay.length; i++) {
            bool ok = true;
            for (uint256 j; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return i;
        }
        revert("marker not found");
    }

    function _slice(bytes memory b, uint256 from, uint256 len) private pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; i++) {
            out[i] = b[from + i];
        }
    }
}
