// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GangSwapV2Migrator} from "../src/v2/GangSwapV2Migrator.sol";
import {GangSwapV2Boost} from "../src/v2/GangSwapV2Boost.sol";
import {GangSwapV2Fees} from "../src/v2/GangSwapV2Fees.sol";
import {IGangSwapV2Factory} from "../src/v2/interfaces/IGangSwapV2.sol";

interface IRouterView {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IBucketView {
    function operators(address account) external view returns (bool);
    function accruedQuote(address quote) external view returns (uint256);
}

interface IPadBucketView {
    function platformBucket() external view returns (address);
}

/// @notice Deploys the GangSwap set (spec docs/SPEC-GANGSWAP-2026-11-22.md §13 step 1): migrator, boost, fees and
///         factory point at each other, so their addresses are predicted from the deployer's nonce; then the router.
///         `run` checks the set with `check` in the simulation, BEFORE anything is sent: it cannot see a partial or
///         reordered broadcast. After the broadcast run `check(migrator, router)` against the chain; only that proves
///         what was deployed. Pads are NOT listed here: that and `setGangSwapMigrator` go through the Safe (§13).
/// @dev    From gangswap/, after `forge clean`:
///           forge script script/DeployGangSwapV2.s.sol --rpc-url <rpc> --account <keystore> --broadcast
///           forge script script/DeployGangSwapV2.s.sol --rpc-url <rpc> --sig "check(address,address)" <migrator> <router>
///         Env: GANGSWAP_V2_OWNER (migrator owner), GANGSWAP_V2_WBNB, GANGSWAP_V2_FEE_BUCKET (SharedPlatformFeeBucket).
///         Optional GANGSWAP_V2_PAD checks that the pad uses the same fee bucket.
contract DeployGangSwapV2 is Script {
    function run() external returns (address migrator, address boost, address fees, address factory, address router) {
        address owner = vm.envAddress("GANGSWAP_V2_OWNER");
        address wbnb = vm.envAddress("GANGSWAP_V2_WBNB");
        address bucket = vm.envAddress("GANGSWAP_V2_FEE_BUCKET");
        require(owner != address(0) && wbnb.code.length > 0 && bucket.code.length > 0, "bad env");

        _startBroadcast();
        (, address deployer,) = vm.readCallers();
        uint64 n = vm.getNonce(deployer);
        address mAddr = vm.computeCreateAddress(deployer, n);
        address bAddr = vm.computeCreateAddress(deployer, n + 1);
        address fAddr = vm.computeCreateAddress(deployer, n + 2);
        address facAddr = vm.computeCreateAddress(deployer, n + 3);

        migrator = address(new GangSwapV2Migrator(owner, facAddr, bAddr, wbnb));
        boost = address(new GangSwapV2Boost(mAddr, wbnb, facAddr));
        fees = address(new GangSwapV2Fees(facAddr, mAddr, bucket, wbnb, bAddr));
        factory = deployCode("GangSwapV2Pair.sol:GangSwapV2Factory", abi.encode(mAddr, fAddr));
        router = deployCode("GangSwapV2Router.sol:GangSwapV2Router", abi.encode(factory, wbnb));
        vm.stopBroadcast();

        require(migrator == mAddr && boost == bAddr && fees == fAddr && factory == facAddr, "address prediction");
        check(migrator, router);

        console.log("GangSwapV2Migrator", migrator);
        console.log("GangSwapV2Boost   ", boost);
        console.log("GangSwapV2Fees    ", fees);
        console.log("GangSwapV2Factory ", factory);
        console.log("GangSwapV2Router  ", router);
    }

    /// @notice Read-only checks of a deployed set against the env, from the contracts themselves (no source or artifact).
    function check(address migrator, address router) public view {
        GangSwapV2Migrator m = GangSwapV2Migrator(migrator);
        IGangSwapV2Factory factory = m.factory();
        address wbnb = vm.envAddress("GANGSWAP_V2_WBNB");
        address owner = m.owner();
        require(owner == vm.envAddress("GANGSWAP_V2_OWNER") && m.quote() == wbnb, "migrator owner / quote");
        // mainnet: the Safe; the BSC testnet's set is owned by its deployer
        require(block.chainid == 97 || owner.code.length > 0, "migrator owner has no code");
        require(m.wired(), "not wired");

        GangSwapV2Fees fees = GangSwapV2Fees(factory.fees());
        address bucket = address(fees.bucket());
        require(bucket == vm.envAddress("GANGSWAP_V2_FEE_BUCKET"), "fee bucket");
        string memory pad = vm.envOr("GANGSWAP_V2_PAD", string(""));
        if (bytes(pad).length > 0) {
            require(IPadBucketView(vm.parseAddress(pad)).platformBucket() == bucket, "pad fee bucket");
        }
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

    /// @dev The key from env when given (DEPLOYER_PRIVATE_KEY, never printed), else --account / --private-key.
    function _startBroadcast() private {
        uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
    }

    function _count(bytes memory hay, bytes memory needle) private pure returns (uint256 n) {
        for (uint256 i; i + needle.length <= hay.length; i++) {
            uint256 j;
            while (j < needle.length && hay[i + j] == needle[j]) j++;
            if (j == needle.length) n++;
        }
    }
}
