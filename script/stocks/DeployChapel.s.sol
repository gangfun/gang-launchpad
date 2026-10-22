// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {QuoteRegistry} from "../../src/stocks/QuoteRegistry.sol";
import {DividendVault} from "../../src/stocks/DividendVault.sol";
import {PlatformFeeBucket} from "../../src/stocks/PlatformFeeBucket.sol";
import {BuybackBurner} from "../../src/stocks/BuybackBurner.sol";
import {LaunchpadS} from "../../src/stocks/LaunchpadS.sol";
import {MigratorS} from "../../src/stocks/MigratorS.sol";
import {MockSPCXB} from "../../src/stocks/mocks/MockSPCXB.sol";
import {MockGANG} from "../../src/stocks/mocks/MockGANG.sol";
import {MockPairFactory} from "../../src/stocks/mocks/MockPairFactory.sol";

/// @title DeployChapel — Stocks track wire-up on BSC Chapel only
/// @notice IS_TESTNET_MIN_PARAMS: graduation = 1e18 MockSPCXB; agent gate off; wallet cap off.
/// @dev HARD BAN: refuses any chain other than 97. Never broadcast to 56.
///
/// Env (testnet only — never mainnet DEPLOYER_PRIVATE_KEY):
///   CHAPEL_PRIVATE_KEY or TESTNET_PRIVATE_KEY  (required for --broadcast)
///   FEE_VAULT (optional; defaults to deployer)
///   KEEPER    (optional; defaults to deployer)
///   OWNER     (optional; defaults to deployer)
///
/// Dry-run:
///   forge script script/stocks/DeployChapel.s.sol --rpc-url $CHAPEL_RPC_URL
/// Broadcast (97 only):
///   forge script script/stocks/DeployChapel.s.sol --rpc-url $CHAPEL_RPC_URL --broadcast
contract DeployChapel is Script {
    uint256 internal constant CHAPEL_CHAIN_ID = 97;
    uint256 internal constant GRADUATION_QUOTE = 1 ether; // 1 MockSPCXB — test only

    error WrongChain(uint256 got);
    error MainnetBanned();

    function run() external {
        uint256 cid = block.chainid;
        if (cid == 56) revert MainnetBanned();
        if (cid != CHAPEL_CHAIN_ID) revert WrongChain(cid);

        uint256 pk = _loadTestnetKey();
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", deployer);
        address feeVault = vm.envOr("FEE_VAULT", deployer);
        address keeper = vm.envOr("KEEPER", deployer);

        console.log("=== Stocks Chapel deploy (chainId 97) ===");
        console.log("deployer:", deployer);
        console.log("owner:   ", owner);
        console.log("feeVault:", feeVault);
        console.log("keeper:  ", keeper);
        console.log("IS_TESTNET_MIN_PARAMS = true");
        console.log("tax = 1% (50 bps div + 50 bps platform; platform 80/20)");

        vm.startBroadcast(pk);

        MockSPCXB spcxb = new MockSPCXB();
        MockGANG gang = new MockGANG();
        MockPairFactory factory = new MockPairFactory();

        QuoteRegistry registry = new QuoteRegistry(owner);
        DividendVault vault = new DividendVault(owner);
        BuybackBurner burner = new BuybackBurner(owner);
        PlatformFeeBucket bucket = new PlatformFeeBucket(owner, feeVault);
        LaunchpadS pad = new LaunchpadS(owner, address(registry), address(vault), address(bucket));
        MigratorS migrator = new MigratorS(address(factory), address(pad));

        // Wire — owner must be msg.sender when owner==deployer; otherwise we need owner key.
        // For Chapel PoC we require OWNER == deployer (or unset).
        require(owner == deployer, "OWNER must equal deployer for single-key Chapel PoC");

        registry.setQuote(address(spcxb), true, GRADUATION_QUOTE);
        vault.setLaunchpad(address(pad));
        bucket.setLaunchpad(address(pad));
        bucket.setBurner(address(burner));
        bucket.setKeeper(keeper);
        burner.setGang(address(gang));
        pad.setMigrator(address(migrator));
        pad.setAgentGate(false, address(0));
        pad.setWalletCapEnabled(false);

        // Seed burner with MockGANG so collectPlatform stub-burn works on testnet.
        gang.mint(address(burner), 1_000_000 ether);

        vm.stopBroadcast();

        console.log("--- addresses ---");
        console.log("MockSPCXB:         ", address(spcxb));
        console.log("MockGANG:          ", address(gang));
        console.log("MockPairFactory:   ", address(factory));
        console.log("QuoteRegistry:     ", address(registry));
        console.log("DividendVault:     ", address(vault));
        console.log("BuybackBurner:     ", address(burner));
        console.log("PlatformFeeBucket: ", address(bucket));
        console.log("LaunchpadS:        ", address(pad));
        console.log("MigratorS:         ", address(migrator));
        console.log("graduationQuote:   ", GRADUATION_QUOTE);
    }

    function _loadTestnetKey() internal view returns (uint256 pk) {
        // Prefer explicit Chapel / testnet names. Refuse to silently use DEPLOYER_PRIVATE_KEY
        // (that name is reserved for mainnet ops and must not broadcast here).
        try vm.envUint("CHAPEL_PRIVATE_KEY") returns (uint256 k) {
            return k;
        } catch {}
        try vm.envUint("TESTNET_PRIVATE_KEY") returns (uint256 k) {
            return k;
        } catch {}
        // Simulation without broadcast may still need a key for addr derivation.
        try vm.envUint("CHAPEL_TEST_PRIVATE_KEY") returns (uint256 k) {
            return k;
        } catch {}
        // Anvil default #0 for local dry simulation only — NEVER for real funds.
        return uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);
    }
}
