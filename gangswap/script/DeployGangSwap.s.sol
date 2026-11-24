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

interface IBucketView {
    function operators(address account) external view returns (bool);
    function accruedQuote(address quote) external view returns (uint256);
}

/// @notice Deploys the GangSwap set (spec docs/SPEC-GANGSWAP-2026-11-22.md §13 step 1): migrator, boost, fees and
///         factory point at each other, so their addresses are predicted from the deployer's nonce; then the router.
///         `run` checks the set with `check` in the simulation, BEFORE anything is sent: it cannot see a partial or
///         reordered broadcast. After the broadcast run `check(migrator, router)` against the chain; only that proves
///         what was deployed. Pads are NOT listed here: that and `setGangSwapMigrator` go through the Safe (§13).
/// @dev    From gangswap/, after `forge clean`:
///           forge script script/DeployGangSwap.s.sol --rpc-url <rpc> --account <keystore> --broadcast
///           forge script script/DeployGangSwap.s.sol --rpc-url <rpc> --sig "check(address,address)" <migrator> <router>
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
        check(migrator, router);

        console.log("GangSwapMigrator", migrator);
        console.log("GangSwapBoost   ", boost);
        console.log("GangSwapFees    ", fees);
        console.log("GangSwapFactory ", factory);
        console.log("GangSwapRouter  ", router);
    }

    /// @notice Read-only checks of a deployed set against the env, from the contracts themselves (no source or artifact).
    function check(address migrator, address router) public view {
        GangSwapMigrator m = GangSwapMigrator(migrator);
        IGangSwapFactory factory = m.factory();
        address wbnb = vm.envAddress("WBNB");
        require(m.owner() == vm.envAddress("GANGSWAP_OWNER") && m.quote() == wbnb, "migrator owner / quote");
        require(m.wired(), "not wired");

        GangSwapFees fees = GangSwapFees(factory.fees());
        address bucket = address(fees.bucket());
        require(bucket == vm.envAddress("FEE_BUCKET"), "fee bucket");
        // a fee bucket answers these; WBNB, a Safe or an EOA does not (its own getters revert here)
        IBucketView(bucket).operators(address(fees));
        IBucketView(bucket).accruedQuote(wbnb);

        require(
            IRouterView(router).factory() == address(factory) && IRouterView(router).WETH() == wbnb, "router wiring"
        );
        // pairFor's constant in the router's own code: PUSH32 <hash>, exactly once
        bytes memory needle = abi.encodePacked(hex"7f", factory.INIT_CODE_PAIR_HASH());
        require(_count(router.code, needle) == 1, "router init code hash");
    }

    function _count(bytes memory hay, bytes memory needle) private pure returns (uint256 n) {
        for (uint256 i; i + needle.length <= hay.length; i++) {
            uint256 j;
            while (j < needle.length && hay[i + j] == needle[j]) j++;
            if (j == needle.length) n++;
        }
    }
}
