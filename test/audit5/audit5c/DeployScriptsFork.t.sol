// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {DeployLaunchpadV3} from "../../../script/DeployLaunchpadV3.s.sol";
import {DeployFairMint} from "../../../script/DeployFairMint.s.sol";
import {SharedPlatform} from "../../../script/SharedPlatform.sol";
import {DeployGangRouter} from "../../../script/DeployGangRouter.s.sol";
import {GangRouter} from "../../../src/router/GangRouter.sol";
import {LaunchpadV3} from "../../../src/launchpad-v3/LaunchpadV3.sol";
import {ILaunchpadV3} from "../../../src/launchpad-v3/interfaces/ILaunchpadV3.sol";
import {FairMintPad} from "../../../src/fair-mint/FairMintPad.sol";
import {SharedDividendVault} from "../../../src/common/SharedDividendVault.sol";
import {SharedMigrator} from "../../../src/common/SharedMigrator.sol";
import {PlatformFeeBucket} from "../../../src/launchpad-v2/PlatformFeeBucket.sol";

interface IWBNBd {
    function deposit() external payable;
}

/// @notice Internal audit 5 C-F1 / C-F8 (regressions): both deploy scripts simulated in-process on a BSC mainnet fork
///         (no broadcast).
contract DeployScriptsForkTest is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant AGENT = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    uint256 constant PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address multisig = address(0xBEEF);
    address deployer;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        deployer = vm.addr(PK);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(PK));
        vm.setEnv("OWNER", vm.toString(multisig));
        _clear();
    }

    function _clear() internal {
        string[6] memory k =
            ["QUOTE_REGISTRY", "PLATFORM_BUCKET", "DIVIDEND_VAULT", "MIGRATOR", "TOKEN_DEPLOYER", "PEER_CORE"];
        for (uint256 i; i < 6; i++) vm.setEnv(k[i], vm.toString(address(0)));
        vm.setEnv("OWNER", vm.toString(multisig));
    }

    function _deployV3() internal returns (DeployLaunchpadV3.Stack memory s) {
        s = new DeployLaunchpadV3().run();
    }

    function _reuse(DeployLaunchpadV3.Stack memory a) internal {
        vm.setEnv("QUOTE_REGISTRY", vm.toString(a.quoteRegistry));
        vm.setEnv("PLATFORM_BUCKET", vm.toString(a.bucket));
        vm.setEnv("DIVIDEND_VAULT", vm.toString(a.vault));
        vm.setEnv("MIGRATOR", vm.toString(a.migrator));
        vm.setEnv("TOKEN_DEPLOYER", vm.toString(a.tokenDeployer));
        vm.setEnv("PEER_CORE", vm.toString(a.pad));
    }

    /// Correct sequence (all five shared env vars): one vault / migrator / deployer for both cores.
    function test_fork_deploy_sharedSequence() public {
        if (!forked) return;
        DeployLaunchpadV3.Stack memory a = _deployV3();
        _reuse(a);
        DeployFairMint.Stack memory b = new DeployFairMint().run();
        assertEq(b.vault, a.vault);
        assertEq(b.tokenDeployer, a.tokenDeployer);
        // hot wallet still owns everything until the multisig accepts (Ownable2Step), with the multisig pending
        assertEq(Ownable2Step(a.vault).owner(), deployer);
        assertEq(Ownable2Step(a.vault).pendingOwner(), multisig);
        assertEq(Ownable2Step(b.pad).pendingOwner(), multisig);
        // C-F8: a re-run naming another OWNER no longer overwrites the pending owner of the shared contracts
        vm.setEnv("OWNER", vm.toString(address(0xBAD)));
        DeployFairMint f = new DeployFairMint();
        vm.expectRevert();
        f.run();
        vm.stopBroadcast();
        _clear();
        assertEq(Ownable2Step(a.bucket).pendingOwner(), multisig);
    }

    /// C-F1 (regression): two of the five shared env vars (the old runbook's invocation) no longer quietly deploy a
    /// second vault / migrator / token deployer: the script refuses anything but all five (plus PEER_CORE) or none.
    function test_fork_deploy_partialSharedEnvRefused() public {
        if (!forked) return;
        DeployLaunchpadV3.Stack memory a = _deployV3();
        vm.setEnv("QUOTE_REGISTRY", vm.toString(a.quoteRegistry));
        vm.setEnv("PLATFORM_BUCKET", vm.toString(a.bucket));
        DeployFairMint f = new DeployFairMint();
        vm.expectRevert(SharedPlatform.PartialShared.selector);
        f.run();
        vm.stopBroadcast();
        _reuse(a);
        vm.setEnv("PEER_CORE", vm.toString(address(0)));
        f = new DeployFairMint();
        vm.expectRevert(abi.encodeWithSelector(SharedPlatform.WiringCheck.selector, "PEER_CORE"));
        f.run();
        vm.stopBroadcast();
        _clear();
    }

    /// Control: on the shared deployment the same create is refused.
    function test_fork_deploy_shared_refusesCrossCoreQuote() public {
        if (!forked) return;
        DeployLaunchpadV3.Stack memory a = _deployV3();
        _reuse(a);
        DeployFairMint.Stack memory b = new DeployFairMint().run();
        _clear();
        vm.mockCall(AGENT, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        address dev = makeAddr("dev");
        vm.prank(dev);
        address t = LaunchpadV3(a.pad).create("T", "T", "", "", address(0), address(0),
            ILaunchpadV3.TaxConfig({buyTaxBps: 0, sellTaxBps: 0, dividendBps: 0, recipient: address(0)}));
        vm.prank(dev);
        vm.expectRevert(FairMintPad.QuoteNotAllowed.selector);
        FairMintPad(b.pad).create("F", "F", "", "", t, address(0),
            FairMintPad.MintConfig({raiseBnb: 5 ether, capBps: 50, holdBps: 5000, mintFeeBps: 100, exitFeeBps: 100}), 1);
    }

    /// Wiring checks that do fire.
    function test_fork_deploy_checksCatch() public {
        if (!forked) return;
        DeployLaunchpadV3.Stack memory a = _deployV3();
        // migrator on another factory (all five set, as the reuse rule requires)
        _reuse(a);
        SharedMigrator other = new SharedMigrator(deployer, address(0x1234));
        vm.setEnv("MIGRATOR", vm.toString(address(other)));
        DeployFairMint f = new DeployFairMint();
        vm.expectRevert(abi.encodeWithSelector(SharedPlatform.WiringCheck.selector, "MIGRATOR factory"));
        f.run();
        vm.stopBroadcast();
        _clear();
        // shared contract already accepted by the multisig
        vm.prank(multisig);
        Ownable2Step(a.vault).acceptOwnership();
        _reuse(a);
        f = new DeployFairMint();
        vm.expectRevert(abi.encodeWithSelector(SharedPlatform.NotDeployerOwned.selector, "DIVIDEND_VAULT"));
        f.run();
        vm.stopBroadcast();
        _clear();
    }

    /// C-F8 (regression): DeployGangRouter now checks each core's type — swapped V3_PAD / FAIR_PAD are refused.
    function test_fork_routerScript_swappedCoresRefused() public {
        if (!forked) return;
        DeployLaunchpadV3.Stack memory a = _deployV3();
        _reuse(a);
        DeployFairMint.Stack memory b = new DeployFairMint().run();
        _clear();
        vm.setEnv("V3_PAD", vm.toString(b.pad));
        vm.setEnv("FAIR_PAD", vm.toString(a.pad));
        DeployGangRouter r = new DeployGangRouter();
        vm.expectRevert(abi.encodeWithSelector(DeployGangRouter.WrongCore.selector, "V3_PAD is not LaunchpadV3"));
        r.run();
        vm.setEnv("V3_PAD", vm.toString(a.pad));
        vm.setEnv("FAIR_PAD", vm.toString(b.pad));
        GangRouter ok = new DeployGangRouter().run();
        vm.setEnv("V3_PAD", vm.toString(address(0)));
        vm.setEnv("FAIR_PAD", vm.toString(address(0)));
        assertEq(address(ok.v3()), a.pad);
    }
}
