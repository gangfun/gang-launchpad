// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {QuoteRegistry} from "../src/launchpad-v2/QuoteRegistry.sol";
import {PlatformFeeBucket} from "../src/launchpad-v2/PlatformFeeBucket.sol";
import {SharedPlatformFeeBucket} from "../src/common/SharedPlatformFeeBucket.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {SharedMigrator} from "../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../src/common/TokenDeployer.sol";

/// @dev What both cores (LaunchpadV3, FairMintPad) expose about the platform contracts they were built on.
interface IPeerCore {
    function quoteRegistry() external view returns (address);
    function platformBucket() external view returns (address);
}

/// @title SharedPlatform — the five contracts LaunchpadV3 and 打新 share: QuoteRegistry, SharedPlatformFeeBucket,
///        SharedDividendVault, SharedMigrator, TokenDeployer
/// @notice Never the live V2 ones: their owner is an EOA that could freeze user exits (every curve trade, 打新
///         withdraw and launch calls the bucket) and decide which quotes the new pads take (2026-10-26 internal audit).
///         The first deploy creates all five; the second reuses them — all five env vars or none (internal audit 5
///         C-F1: two of five quietly deployed a second vault / migrator / deployer and split the cores) — plus
///         PEER_CORE (the first core), checked to be wired on the same registry, bucket, vault, migrator and deployer.
///         Reuse works while
///         the deployer still owns them (Ownable2Step: ownership stays with the deployer until the multisig accepts).
///         On mainnet the new bucket pays the same fee vault and buyback burner as the V2 bucket, read on-chain.
abstract contract SharedPlatform is Script {
    uint256 internal constant TESTNET_QUOTE_PER_15_BNB = 15 ether;

    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error OwnerRequired();
    error NotDeployerOwned(string what);
    error WiringCheck(string what);
    error PartialShared();
    error PendingOwnerMismatch(address target);

    /// @param v2Bucket mainnet: the live V2 bucket, source of feeVault / burner; ignored on testnet
    function _platform(bool mainnet, address deployer, address keeper, address v2Bucket)
        internal
        returns (address registry, address bucket)
    {
        _requireAllOrNoShared();
        registry = vm.envOr("QUOTE_REGISTRY", address(0));
        if (registry == address(0)) {
            registry = address(new QuoteRegistry(deployer));
        } else if (Ownable2Step(registry).owner() != deployer) {
            revert NotDeployerOwned("QUOTE_REGISTRY");
        }

        bucket = vm.envOr("PLATFORM_BUCKET", address(0));
        if (bucket == address(0)) {
            // no collectPlatformSmart (C-F2): the keeper can only buy back along the burner's fixed path
            SharedPlatformFeeBucket b = new SharedPlatformFeeBucket(deployer, _feeVault(mainnet, deployer, v2Bucket));
            // the same BURNER / FEE_VAULT overrides `_checkBucket` checks against (review: BURNER was check-only)
            address burner = _burner(mainnet, v2Bucket);
            if (burner != address(0)) b.setBurner(burner);
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

    /// @dev QUOTE_REGISTRY, PLATFORM_BUCKET, DIVIDEND_VAULT, MIGRATOR, TOKEN_DEPLOYER: all set (reuse) or none.
    function _requireAllOrNoShared() internal view {
        uint256 n;
        if (vm.envOr("QUOTE_REGISTRY", address(0)) != address(0)) n++;
        if (vm.envOr("PLATFORM_BUCKET", address(0)) != address(0)) n++;
        if (vm.envOr("DIVIDEND_VAULT", address(0)) != address(0)) n++;
        if (vm.envOr("MIGRATOR", address(0)) != address(0)) n++;
        if (vm.envOr("TOKEN_DEPLOYER", address(0)) != address(0)) n++;
        if (n != 0 && n != 5) revert PartialShared();
        if (n == 5 && vm.envOr("PEER_CORE", address(0)) == address(0)) revert WiringCheck("PEER_CORE");
    }

    /// @notice List `core` on the shared vault (its own share floor; `operators` bound to it), migrator and deployer.
    ///         The migrator and the bucket never claim: a bag held there would earn dividends that stay stuck.
    function _wireCore(
        address vault,
        address migrator,
        address tokenDeployer,
        address bucket,
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
        // audit 4 (A-F2 / C-F4): the bucket can hold a dividend token as some token's quote; it never claims
        if (!v.excluded(bucket)) v.setExcluded(bucket, true);
        SharedMigrator(migrator).addLaunchpad(core);
        TokenDeployer(tokenDeployer).setLaunchpad(core, true);
    }

    function _checkCore(
        address registry,
        address vault,
        address migrator,
        address tokenDeployer,
        address bucket,
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
        if (!v.excluded(bucket)) revert WiringCheck("vault excludes bucket");
        if (!v.excluded(vault)) revert WiringCheck("vault excludes itself");
        if (!SharedMigrator(migrator).launchpads(core)) revert WiringCheck("migrator launchpad");
        if (!TokenDeployer(tokenDeployer).launchpads(core)) revert WiringCheck("deployer launchpad");
        // reuse (C-F1): the first core must sit on the very same registry, bucket, vault, migrator and deployer
        address peer = vm.envOr("PEER_CORE", address(0));
        if (peer != address(0)) {
            if (IPeerCore(peer).quoteRegistry() != registry) revert WiringCheck("peer core registry");
            if (IPeerCore(peer).platformBucket() != bucket) revert WiringCheck("peer core bucket");
            if (!SharedPlatformFeeBucket(bucket).operators(peer)) revert WiringCheck("peer core on bucket");
            if (!v.launchpads(peer) || v.operatorFor(peer) == address(0)) revert WiringCheck("peer core on vault");
            if (!SharedMigrator(migrator).launchpads(peer)) revert WiringCheck("peer core on migrator");
            if (!TokenDeployer(tokenDeployer).launchpads(peer)) revert WiringCheck("peer core on deployer");
        }
    }

    /// @dev C-F8: every contract is either owned by `owner` or has it pending (nothing left for another address).
    function _checkOwner(address owner, address target) internal view {
        Ownable2Step o = Ownable2Step(target);
        if (o.owner() != owner && o.pendingOwner() != owner) revert WiringCheck("owner / pendingOwner");
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
        // C-F8: a second run naming another OWNER must not overwrite the first run's pending owner
        address pending = o.pendingOwner();
        if (pending != address(0) && pending != owner) revert PendingOwnerMismatch(target);
        if (o.owner() == deployer && pending != owner) o.transferOwnership(owner);
    }

    /// @dev The buyback burner a new bucket gets: BURNER if set (non-zero), else the V2 bucket's on mainnet, none on
    ///      testnet (collectPlatform then reverts until the owner sets one).
    function _burner(bool mainnet, address v2Bucket) internal view returns (address burner) {
        burner = vm.envOr("BURNER", address(0));
        if (burner == address(0) && mainnet) burner = address(PlatformFeeBucket(v2Bucket).burner());
    }

    /// @dev The fee vault a new bucket gets: FEE_VAULT if set (non-zero), else the V2 bucket's on mainnet, the
    ///      deployer on testnet.
    function _feeVault(bool mainnet, address deployer, address v2Bucket) internal view returns (address feeVault) {
        feeVault = vm.envOr("FEE_VAULT", address(0));
        if (feeVault == address(0)) feeVault = mainnet ? PlatformFeeBucket(v2Bucket).feeVault() : deployer;
    }

    /// @dev C-F8: operators, keeper, and the fee legs' destinations — the same `_burner` / `_feeVault` the deploy
    ///      used (mainnet: the V2 bucket's unless BURNER / FEE_VAULT say otherwise, and a burner is required).
    function _checkBucket(bool mainnet, address v2Bucket, address bucket, address keeper, address a, address b)
        internal
        view
    {
        SharedPlatformFeeBucket pb = SharedPlatformFeeBucket(bucket);
        if (!pb.operators(a) || !pb.operators(b)) revert WiringCheck("bucket operators");
        if (pb.keeper() != keeper) revert WiringCheck("bucket keeper");
        if (pb.feeVault() == address(0)) revert WiringCheck("bucket feeVault");
        address burner = _burner(mainnet, v2Bucket);
        // testnet: only an explicit BURNER is checked (a reused testnet bucket may have had one set by hand)
        if ((mainnet || burner != address(0)) && (address(pb.burner()) != burner || burner == address(0))) {
            revert WiringCheck("bucket burner");
        }
        if (mainnet && pb.feeVault() != _feeVault(mainnet, address(0), v2Bucket)) {
            revert WiringCheck("bucket feeVault");
        }
    }

    function _logPlatform(address registry, address bucket) internal pure {
        console.log("QUOTE_REGISTRY", registry);
        console.log("PLATFORM_BUCKET", bucket);
    }

    function _broadcasting() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }
}
