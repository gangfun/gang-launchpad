// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MainnetAddresses as M} from "../config/MainnetAddresses.sol";
import {GangBuybackBurner} from "../src/buyback/GangBuybackBurner.sol";

/// @dev The bucket calls used here. Not imported from src/launchpad-v2: that path is compiled with via-IR (foundry.toml),
///      which would drag this script and the GangBuybackBurner it deploys onto a second, different build.
interface IPlatformFeeBucket {
    function burner() external view returns (address);
    function owner() external view returns (address);
    function setBurner(address burner_) external;
}

/// @title DeployGangBuybackBurner — replace the platform burner behind the live PlatformFeeBucket V2 / U / S (BSC 56)
/// @notice Deploys GangBuybackBurner (burns GANG-quoted fees directly) and, when the deploy key owns the buckets,
///         points each bucket at it with setBurner. Otherwise prints the setBurner calls for the bucket owner.
///         Nothing else changes: buckets, keeper, fee vault and accrued balances stay as they are.
///         Safe to re-run: a GangBuybackBurner that a bucket already uses (or BURNER) is reused, not redeployed,
///         and buckets already on it are left alone.
/// @dev Env: DEPLOYER_PRIVATE_KEY; OWNER (default MainnetAddresses.OWNER); REWIRE (default true);
///      BURNER (a GangBuybackBurner already deployed from this build, to wire instead of deploying one).
///      Dry run: forge script script/DeployGangBuybackBurner.s.sol --rpc-url bsc
///      Broadcast: add --broadcast --verify
contract DeployGangBuybackBurner is Script {
    /// @dev LaunchpadU / LaunchpadS buckets (README appendix); V2 bucket is in MainnetAddresses.
    address internal constant BUCKET_U = 0xe314efeB69229386baAd32034f4C06c196F6260c;
    address internal constant BUCKET_S = 0xad34653E20a33bE38340a837b0C67d85C899dEeC;

    error WrongChain(uint256 got);
    error BucketGangMismatch(address bucket);
    error BadBurner(address burner);

    function run() external {
        if (block.chainid != 56) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", M.OWNER);
        bool rewire = vm.envOr("REWIRE", true);
        address burner = vm.envOr("BURNER", address(0));

        address[3] memory buckets = [M.PLATFORM_FEE_BUCKET_V2, BUCKET_U, BUCKET_S];
        for (uint256 i; i < buckets.length; i++) {
            address current = IPlatformFeeBucket(buckets[i]).burner();
            // The old burner must already target real GANG, so the swap cannot silently change what gets burned.
            if (GangBuybackBurner(current).gang() != M.GANG) revert BucketGangMismatch(buckets[i]);
            if (burner == address(0) && _isGangBuybackBurner(current)) burner = current;
        }
        if (burner != address(0)) _checkBurner(burner, owner);

        console.log("=== DeployGangBuybackBurner ===");
        console.log("deployer", deployer);
        console.log("owner", owner);

        vm.startBroadcast(pk);
        if (burner == address(0)) {
            burner = address(new GangBuybackBurner(owner, M.PANCAKE_V2_ROUTER, M.PANCAKE_SMART_ROUTER, M.WBNB, M.GANG));
            console.log("GangBuybackBurner deployed", burner);
        } else {
            console.log("GangBuybackBurner reused", burner);
        }

        for (uint256 i; i < buckets.length; i++) {
            IPlatformFeeBucket b = IPlatformFeeBucket(buckets[i]);
            address current = b.burner();
            console.log("bucket", buckets[i], "burner", current);
            if (current == burner) {
                console.log("  -> already on GangBuybackBurner");
            } else if (rewire && b.owner() == deployer) {
                b.setBurner(burner);
                console.log("  -> setBurner done");
            } else {
                console.log(
                    string.concat(
                        "  -> owner runs: cast send ",
                        vm.toString(buckets[i]),
                        " 'setBurner(address)' ",
                        vm.toString(burner),
                        " --rpc-url $BSC_RPC_URL"
                    )
                );
            }
        }
        vm.stopBroadcast();
    }

    /// @dev Same runtime code as this build's GangBuybackBurner (it has no immutables, so the code is fixed), ignoring
    ///      the trailing metadata: that hashes the source, so an edit to a comment alone would otherwise not match.
    function _isGangBuybackBurner(address a) internal view returns (bool) {
        return a.code.length > 0 && _hashSansMetadata(a.code) == _hashSansMetadata(type(GangBuybackBurner).runtimeCode);
    }

    /// @dev keccak256 of `code` without the CBOR metadata, whose length sits in the last two bytes.
    function _hashSansMetadata(bytes memory code) internal pure returns (bytes32 h) {
        uint256 n = code.length;
        if (n >= 2) {
            uint256 meta = ((uint256(uint8(code[n - 2])) << 8) | uint8(code[n - 1])) + 2;
            if (meta <= n) n -= meta;
        }
        assembly {
            h := keccak256(add(code, 0x20), n)
        }
    }

    /// @dev A reused burner must be this build's GangBuybackBurner (an old burner has the same getters but cannot burn
    ///      GANG), wired like a fresh deploy and owned by OWNER.
    function _checkBurner(address a, address owner) internal view {
        GangBuybackBurner b = GangBuybackBurner(a);
        if (
            !_isGangBuybackBurner(a) || b.owner() != owner || b.gang() != M.GANG || b.wbnb() != M.WBNB
                || address(b.router()) != M.PANCAKE_V2_ROUTER || b.smartRouter() != M.PANCAKE_SMART_ROUTER
        ) revert BadBurner(a);
    }
}
