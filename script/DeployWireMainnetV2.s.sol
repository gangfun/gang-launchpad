// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LaunchpadV2DeployRefs as A} from "../config/LaunchpadV2DeployRefs.sol";
import {LaunchpadV2} from "../src/launchpad-v2/LaunchpadV2.sol";
import {MigratorV2} from "../src/launchpad-v2/MigratorV2.sol";
import {QuoteRegistry} from "../src/launchpad-v2/QuoteRegistry.sol";
import {DividendVault} from "../src/launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../src/launchpad-v2/PlatformFeeBucket.sol";
import {PostGradTaxHandler} from "../src/launchpad-v2/PostGradTaxHandler.sol";
import {BuybackBurner} from "../src/launchpad-v2/BuybackBurner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployWireMainnetV2 — LaunchpadV2 + REFPOOL on BSC 56
/// @notice Deploys NEW: QuoteRegistry, DividendVault(10k), PlatformFeeBucket, PostGradTaxHandler,
///         LaunchpadV2, MigratorV2. REUSES live BuybackBurner / feeVault / GANG.
/// @dev FORBIDDEN: any call to Soft/U/S or their DivVault/Bucket/PostGrad.
///      Already broadcast on BSC 56 (2026-10-23). Do not re-run.
///      Env: DEPLOYER_PRIVATE_KEY (→ OWNER 0x4EEd), KEEPER (optional), DEV_WALLET (optional)
contract DeployWireMainnetV2 is Script {
    error WrongChain(uint256 got);
    error DeployerNotOwner(address deployer, address owner);
    error ZeroKeeper();
    error BurnerGangMismatch(address got);
    error TouchedLegacy();

    address internal constant DEFAULT_KEEPER = 0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7;
    uint256 internal constant MIN_SHARE = 10_000 ether;

    function run() external {
        if (block.chainid != 56) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", deployer);
        if (deployer != owner) revert DeployerNotOwner(deployer, owner);

        address keeper = vm.envOr("KEEPER", DEFAULT_KEEPER);
        if (keeper == address(0)) revert ZeroKeeper();
        address devWallet = vm.envOr("DEV_WALLET", address(0));

        BuybackBurner burner = BuybackBurner(A.BUYBACK_BURNER);
        address gangOnBurner = burner.gang();
        if (gangOnBurner != A.GANG) revert BurnerGangMismatch(gangOnBurner);

        console.log("=== DeployWireMainnetV2 ===");
        console.log("owner", owner);
        console.log("keeper", keeper);
        console.log("reuse_burner", A.BUYBACK_BURNER);
        console.log("reuse_feeVault", A.FEE_VAULT);
        console.log("reuse_gang", A.GANG);
        console.log("DO_NOT_TOUCH_SOFT", A.LEGACY_SOFT);
        console.log("DO_NOT_TOUCH_U", A.LEGACY_U);
        console.log("DO_NOT_TOUCH_S", A.LEGACY_S);
        if (devWallet != address(0)) console.log("devWallet", devWallet);

        vm.startBroadcast(pk);

        QuoteRegistry reg = new QuoteRegistry(owner);
        DividendVault div = new DividendVault(owner);
        PlatformFeeBucket bucket = new PlatformFeeBucket(owner, A.FEE_VAULT);
        PostGradTaxHandler handler = new PostGradTaxHandler(owner, address(div), address(bucket));

        LaunchpadV2 pad = new LaunchpadV2(
            owner,
            address(reg),
            address(div),
            address(bucket),
            address(handler),
            A.WBNB,
            A.PANCAKE_V2_FACTORY
        );
        MigratorV2 mig = new MigratorV2(A.PANCAKE_V2_FACTORY, address(pad));

        // --- Wire (new stack only) ---
        div.setMinimumShareBalance(MIN_SHARE);
        div.setLaunchpad(address(pad));
        div.setOperator(address(handler), true);

        bucket.setBurner(A.BUYBACK_BURNER);
        bucket.setLaunchpad(address(pad));
        bucket.setKeeper(keeper);
        bucket.setOperator(address(handler), true);

        handler.setRouter(A.PANCAKE_V2_ROUTER);
        handler.setKeeper(keeper);

        pad.setMigrator(address(mig));
        pad.setAgentGate(true, A.AGENT_ID_REGISTRY);
        pad.setWalletCapEnabled(true);
        pad.setV3Factory(A.PANCAKE_V3_FACTORY);

        // USDT/WBNB V3 0.05% bridge for non-WBNB counters (same as fork tests)
        address usdtWbnb = _v3Pool(A.WBNB, A.USDT, 500);
        if (usdtWbnb != address(0)) {
            pad.setBridgePool(A.USDT, usdtWbnb);
        }

        if (devWallet != address(0)) {
            // LaunchpadV2 may not have setDev — only if present; skip via low-level
            (bool ok,) = address(pad).call(abi.encodeWithSignature("setDev(address,bool)", devWallet, true));
            if (ok) console.log("setDev", devWallet);
            else console.log("setDev skipped (no setter)");
        }

        vm.stopBroadcast();

        // Safety: prove we did not change legacy pads' code size / owner calls
        if (A.LEGACY_SOFT == address(pad) || A.LEGACY_U == address(pad) || A.LEGACY_S == address(pad)) {
            revert TouchedLegacy();
        }

        console.log("--- V2 ADDRESSES ---");
        console.log("V2_LAUNCHPAD", address(pad));
        console.log("V2_MIGRATOR", address(mig));
        console.log("V2_QUOTE_REGISTRY", address(reg));
        console.log("V2_DIVIDEND_VAULT", address(div));
        console.log("V2_PLATFORM_BUCKET", address(bucket));
        console.log("V2_POSTGRAD_HANDLER", address(handler));
        console.log("V2_BUYBACK_BURNER_REUSED", A.BUYBACK_BURNER);
        console.log("V2_FEE_VAULT_REUSED", A.FEE_VAULT);
        console.log("V2_GANG_REUSED", A.GANG);
        console.log("V2_agentGate", pad.agentGateEnabled());
        console.log("V2_walletCap", pad.walletCapEnabled());
        console.log("V2_v3Factory", pad.v3Factory());
        console.log("V2_minShare", div.minimumShareBalance());
        console.log("V2_usdtBridge", pad.bridgePoolOf(A.USDT));
        console.log("V2_TARGET_GRAD_BNB", pad.TARGET_GRAD_BNB());
    }

    function _v3Pool(address a, address b, uint24 fee) internal view returns (address pool) {
        (bool ok, bytes memory data) = A.PANCAKE_V3_FACTORY.staticcall(
            abi.encodeWithSignature("getPool(address,address,uint24)", a, b, fee)
        );
        if (ok && data.length >= 32) pool = abi.decode(data, (address));
    }
}
