// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {QuoteRegistry} from "../src/launchpad-v2/QuoteRegistry.sol";
import {PlatformFeeBucket} from "../src/launchpad-v2/PlatformFeeBucket.sol";

/// @title SharedPlatform — QuoteRegistry + PlatformFeeBucket shared by LaunchpadV3 and 打新
/// @notice Never the live V2 ones: their owner is an EOA that could freeze user exits (every curve trade, 打新
///         withdraw and launch calls the bucket) and decide which quotes the new pads take (2026-10-26 internal audit).
///         The first deploy creates both; the second reuses them via QUOTE_REGISTRY / PLATFORM_BUCKET while the
///         deployer still owns them (Ownable2Step: ownership stays with the deployer until the multisig accepts).
///         On mainnet the new bucket pays the same fee vault and buyback burner as the V2 bucket, read on-chain.
abstract contract SharedPlatform is Script {
    uint256 internal constant TESTNET_QUOTE_PER_15_BNB = 15 ether;

    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error OwnerRequired();
    error NotDeployerOwned(string what);
    error WiringCheck(string what);

    /// @param v2Bucket mainnet: the live V2 bucket, source of feeVault / burner; ignored on testnet
    function _platform(bool mainnet, address deployer, address keeper, address v2Bucket)
        internal
        returns (address registry, address bucket)
    {
        registry = vm.envOr("QUOTE_REGISTRY", address(0));
        if (registry == address(0)) {
            registry = address(new QuoteRegistry(deployer));
        } else if (Ownable2Step(registry).owner() != deployer) {
            revert NotDeployerOwned("QUOTE_REGISTRY");
        }

        bucket = vm.envOr("PLATFORM_BUCKET", address(0));
        if (bucket == address(0)) {
            address feeVault = vm.envOr("FEE_VAULT", mainnet ? PlatformFeeBucket(v2Bucket).feeVault() : deployer);
            PlatformFeeBucket b = new PlatformFeeBucket(deployer, feeVault);
            if (mainnet) b.setBurner(address(PlatformFeeBucket(v2Bucket).burner()));
            b.setKeeper(keeper);
            bucket = address(b);
        } else if (Ownable2Step(bucket).owner() != deployer) {
            revert NotDeployerOwned("PLATFORM_BUCKET");
        }
    }

    /// @dev Listed quotes: WBNB is implicit; anything else must be enabled here (and have 18 decimals, checked by the
    ///      pads). graduationQuoteAmount 0 = priced by its reference pool at create.
    function _listQuote(address registry, address quote, uint256 graduationQuoteAmount) internal {
        QuoteRegistry reg = QuoteRegistry(registry);
        (bool enabled, uint256 amount) = reg.quotes(quote);
        if (!enabled || amount != graduationQuoteAmount) reg.setQuote(quote, true, graduationQuoteAmount);
    }

    /// @dev Mainnet needs OWNER (the multisig): leaving every contract on the deploy key is refused.
    function _owner(bool mainnet, address deployer) internal view returns (address owner) {
        owner = vm.envOr("OWNER", deployer);
        if (mainnet && owner == deployer) revert OwnerRequired();
    }

    function _handOver(address owner, address deployer, address target) internal {
        if (owner == deployer) return;
        Ownable2Step o = Ownable2Step(target);
        if (o.owner() == deployer && o.pendingOwner() != owner) o.transferOwnership(owner);
    }

    function _checkBucket(address bucket, address keeper, address a, address b) internal view {
        PlatformFeeBucket pb = PlatformFeeBucket(bucket);
        if (!pb.operators(a) || !pb.operators(b)) revert WiringCheck("bucket operators");
        if (pb.keeper() != keeper) revert WiringCheck("bucket keeper");
    }

    function _logPlatform(address registry, address bucket) internal pure {
        console.log("QUOTE_REGISTRY", registry);
        console.log("PLATFORM_BUCKET", bucket);
    }

    function _broadcasting() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }
}
