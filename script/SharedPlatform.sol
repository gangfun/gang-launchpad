// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {QuoteRegistry} from "../src/launchpad-v2/QuoteRegistry.sol";
import {PlatformFeeBucket} from "../src/launchpad-v2/PlatformFeeBucket.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {SharedMigrator} from "../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../src/common/TokenDeployer.sol";

/// @title SharedPlatform — the five contracts LaunchpadV3 and 打新 share: QuoteRegistry, PlatformFeeBucket,
///        SharedDividendVault, SharedMigrator, TokenDeployer
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

    /// @notice Shared dividend vault, migrator and token deployer: deployed by the first script, reused by the second via
    ///         DIVIDEND_VAULT / MIGRATOR / TOKEN_DEPLOYER while the deployer still owns them.
    function _shared(address deployer, address factory)
        internal
        returns (address vault, address migrator, address tokenDeployer)
    {
        vault = vm.envOr("DIVIDEND_VAULT", address(0));
        if (vault == address(0)) vault = address(new SharedDividendVault(deployer));
        else if (Ownable2Step(vault).owner() != deployer) revert NotDeployerOwned("DIVIDEND_VAULT");

        migrator = vm.envOr("MIGRATOR", address(0));
        if (migrator == address(0)) {
            migrator = address(new SharedMigrator(deployer, factory));
        } else if (Ownable2Step(migrator).owner() != deployer) {
            revert NotDeployerOwned("MIGRATOR");
        } else if (address(SharedMigrator(migrator).factory()) != factory) {
            revert WiringCheck("MIGRATOR factory");
        }

        tokenDeployer = vm.envOr("TOKEN_DEPLOYER", address(0));
        if (tokenDeployer == address(0)) tokenDeployer = address(new TokenDeployer(deployer));
        else if (Ownable2Step(tokenDeployer).owner() != deployer) revert NotDeployerOwned("TOKEN_DEPLOYER");
    }

    /// @notice List `core` on the shared vault (its own share floor; `operators` bound to it), migrator and deployer.
    ///         The migrator is tax-exempt and can never claim: a bag sent there would earn dividends that stay stuck.
    function _wireCore(
        address vault,
        address migrator,
        address tokenDeployer,
        address core,
        uint256 minShare,
        address[] memory operators
    ) internal {
        SharedDividendVault v = SharedDividendVault(vault);
        v.setLaunchpad(core, true);
        v.setMinimumShareBalance(core, minShare);
        for (uint256 i = 0; i < operators.length; i++) {
            v.setOperator(operators[i], core);
        }
        if (!v.excluded(migrator)) v.setExcluded(migrator, true);
        SharedMigrator(migrator).addLaunchpad(core);
        TokenDeployer(tokenDeployer).setLaunchpad(core, true);
    }

    function _checkCore(
        address vault,
        address migrator,
        address tokenDeployer,
        address core,
        uint256 minShare,
        address[] memory operators
    ) internal view {
        SharedDividendVault v = SharedDividendVault(vault);
        if (!v.launchpads(core)) revert WiringCheck("vault launchpad");
        if (v.minimumShareBalanceOf(core) != minShare) revert WiringCheck("vault floor");
        for (uint256 i = 0; i < operators.length; i++) {
            if (v.operatorOf(operators[i]) != core) revert WiringCheck("vault operator");
        }
        if (!v.excluded(migrator)) revert WiringCheck("vault excludes migrator");
        if (!SharedMigrator(migrator).launchpads(core)) revert WiringCheck("migrator launchpad");
        if (!TokenDeployer(tokenDeployer).launchpads(core)) revert WiringCheck("deployer launchpad");
    }

    function _logShared(address vault, address migrator, address tokenDeployer) internal pure {
        console.log("DIVIDEND_VAULT", vault);
        console.log("MIGRATOR", migrator);
        console.log("TOKEN_DEPLOYER", tokenDeployer);
    }

    /// @dev A fixed rate for `quote` (quote units per 15 BNB). The pads take any 18-decimal quote and price an unlisted
    ///      one from the creator's reference pool, as LaunchpadV2 does; a listed rate replaces that pool price.
    ///      Mainnet lists nothing: USDT is priced from the USDT/WBNB pool given at create (USDT_REF_POOL).
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
