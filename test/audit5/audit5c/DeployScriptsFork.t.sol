// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {DeployGang} from "../../../script/DeployGang.s.sol";
import {GangMainnetRefs as M, GangTestnetRefs as T} from "../../../config/GangDeployRefs.sol";
import {QuoteRegistry} from "../../../src/launchpad-v2/QuoteRegistry.sol";
import {SharedPlatformFeeBucket} from "../../../src/common/SharedPlatformFeeBucket.sol";
import {SharedDividendVault} from "../../../src/common/SharedDividendVault.sol";
import {SharedMigrator} from "../../../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../../../src/common/TokenDeployer.sol";
import {GangRouter} from "../../../src/router/GangRouter.sol";
import {IGangPad} from "../../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangTaxHandlerOps} from "../../../src/gang/interfaces/IGangTaxHandlerOps.sol";
import {StubGangLaunchpad} from "./mocks/StubGangLaunchpad.sol";

/// @dev Exposes DeployGang's config, self-check and mainnet gate to the tests.
contract DeployGangHarness is DeployGang {
    function cfgFor(address deployer) external view returns (Cfg memory) {
        return _cfg(deployer);
    }

    function check(Stack memory s, Cfg memory c) external view {
        _check(s, c);
    }

    function checkPadOnly(Stack memory s, Cfg memory c) external view {
        _checkPad(s, c);
    }

    function gate(bool mainnet, bool broadcasting) external view {
        _mainnetGate(mainnet, broadcasting);
    }

    function padsLine(Stack memory s) external pure returns (string memory) {
        return _padsLine(s);
    }
}

/// @notice script/DeployGang.s.sol simulated in-process on BSC forks (no broadcast): the whole merged stack in one run,
///         every wiring step read back by `_check`, OWNER / re-run / mainnet-gate rules (merge plan §7.4; internal audit
///         5 C-F8, review R5-5). The reuse / PEER_CORE cases of the old two-script deploy are gone with that mode.
///         Mainnet fork: BSC_RPC_URL (48.club keeps history). Testnet fork: BSC_TESTNET_RPC_URL. Without them the fork
///         tests return early. To link the live PoolCheck as the mainnet deploy does, add
///         --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
///         (CurveLogic / FairLogic are deployed and linked by forge either way).
///         The script reads its config through `vm.setEnv`, which is process-wide: run with `--threads 1`.
contract DeployScriptsForkTest is Test {
    uint256 constant PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address multisig = address(0xBEEF);
    address deployer;
    bool forked;

    DeployGangHarness internal h;
    DeployGang.Stack internal st;
    DeployGang.Cfg internal cf;

    function setUp() public virtual {
        deployer = vm.addr(PK);
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        _clear();
    }

    /// @dev Every env var DeployGang reads, back to its default.
    function _clear() internal {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(PK));
        string[10] memory addrs = [
            "OWNER",
            "KEEPER",
            "BURNER",
            "FEE_VAULT",
            "RECIPIENT",
            "AGENT_ID",
            "TEST_QUOTE",
            "BLACKLIST_QUOTE",
            "GANG_PAD",
            "GANG_ROUTER"
        ];
        for (uint256 i; i < addrs.length; i++) {
            vm.setEnv(addrs[i], vm.toString(address(0)));
        }
        string[4] memory flags = ["MAINNET_OWNER_IS_DEPLOYER", "GANG_MAINNET_OK", "NEW_MOCKS", "KEEPER_OVERRIDE_OK"];
        for (uint256 i; i < flags.length; i++) {
            vm.setEnv(flags[i], "false");
        }
        vm.setEnv("TWAP_WINDOW", "1800");
        vm.setEnv("GANG_PAD_BLOCK", "0");
        vm.setEnv("RECIPIENT_LABEL", "");
        vm.setEnv("OWNER", vm.toString(multisig));
    }

    /// @dev Fresh deploy through the harness; keeps the stack and the config it was checked against.
    function _deploy() internal returns (DeployGang.Stack memory s) {
        h = new DeployGangHarness();
        s = h.run();
        st = s;
        cf = h.cfgFor(deployer);
    }

    function _rerunEnv(DeployGang.Stack memory s) internal {
        vm.setEnv("GANG_PAD", vm.toString(s.pad));
        vm.setEnv("GANG_ROUTER", vm.toString(s.router));
    }

    function _owned(DeployGang.Stack memory s) internal pure returns (address[7] memory) {
        return [s.quoteRegistry, s.bucket, s.vault, s.migrator, s.tokenDeployer, s.handler, s.pad];
    }

    // ---------------------------------------------------------------- mainnet: the whole stack in one run
    function test_fork_deploy_mainnet_wholeStack() public {
        if (!forked) return;
        DeployGang.Stack memory s = _deploy();
        IGangPad pad = IGangPad(s.pad);
        // pad on the stack the same run made, router on the pad, both libraries live (the self-check also ran)
        assertEq(pad.quoteRegistry(), s.quoteRegistry);
        assertEq(pad.platformBucket(), s.bucket);
        assertEq(pad.dividendVault(), s.vault);
        assertEq(pad.taxHandler(), s.handler);
        assertEq(pad.tokenDeployer(), s.tokenDeployer);
        assertEq(pad.migrator(), s.migrator, "setMigrator done");
        assertEq(pad.wbnb(), M.WBNB);
        assertEq(pad.pairFactory(), M.PANCAKE_V2_FACTORY);
        assertEq(pad.v3Factory(), M.PANCAKE_V3_FACTORY);
        assertEq(pad.bridgePoolOf(M.USDT), M.USDT_WBNB_V3);
        assertEq(pad.agentIdRegistry(), M.AGENT_ID_REGISTRY);
        assertTrue(pad.routers(s.router));
        assertEq(address(GangRouter(payable(s.router)).v3()), s.pad);
        assertEq(address(GangRouter(payable(s.router)).fair()), s.pad);
        assertEq(IGangTaxHandlerOps(s.handler).launchpad(), s.pad);
        assertEq(IGangTaxHandlerOps(s.handler).dexRouter(), M.PANCAKE_V2_ROUTER);
        assertEq(address(SharedMigrator(s.migrator).factory()), M.PANCAKE_V2_FACTORY);
        assertEq(s.padBlock, block.number, "start block = the run's block");
        // nothing listed on mainnet: no quote, no recipient unless RECIPIENT
        assertFalse(QuoteRegistry(s.quoteRegistry).isQuoted(M.USDT));
        assertEq(s.recipient, address(0));
        // the deploy key owns everything until the multisig accepts (Ownable2Step), with the multisig pending
        address[7] memory owned = _owned(s);
        for (uint256 i; i < owned.length; i++) {
            assertEq(Ownable2Step(owned[i]).owner(), deployer);
            assertEq(Ownable2Step(owned[i]).pendingOwner(), multisig);
        }
    }

    /// A-1: setMigrator is the last wiring call; after it only the ownership hand-over follows.
    function test_fork_deploy_setMigratorIsLast() public {
        if (!forked) return;
        vm.recordLogs();
        DeployGang.Stack memory s = _deploy();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 handOver = keccak256("OwnershipTransferStarted(address,address)");
        uint256 at = type(uint256).max;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == s.pad && logs[i].topics[0] == IGangLaunchpad.MigratorSet.selector) at = i;
        }
        assertTrue(at != type(uint256).max, "MigratorSet emitted");
        address[7] memory owned = _owned(s);
        for (uint256 i = at + 1; i < logs.length; i++) {
            bool ours;
            for (uint256 j; j < owned.length; j++) {
                if (logs[i].emitter == owned[j]) ours = true;
            }
            if (ours) assertEq(logs[i].topics[0], handOver, "only the hand-over after setMigrator");
        }
        // and every setter of the pad ran before it
        bytes32[4] memory before = [
            IGangLaunchpad.RouterSet.selector,
            IGangLaunchpad.AgentGateUpdated.selector,
            IGangLaunchpad.V3FactorySet.selector,
            IGangLaunchpad.BridgePoolSet.selector
        ];
        for (uint256 k; k < before.length; k++) {
            bool seen;
            for (uint256 i; i < at; i++) {
                if (logs[i].emitter == s.pad && logs[i].topics[0] == before[k]) seen = true;
            }
            assertTrue(seen, "pad setter before setMigrator");
        }
    }

    // ---------------------------------------------------------------- the self-check catches wiring errors
    /// @dev Break one thing as the deploy key (still the owner) and the self-check names it.
    function _breaks(address target, bytes memory call, string memory what) internal {
        uint256 snap = vm.snapshotState();
        vm.prank(deployer);
        (bool ok,) = target.call(call);
        assertTrue(ok, string.concat("break: ", what));
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, what));
        h.check(st, cf);
        vm.revertToState(snap);
    }

    function test_fork_deploy_checksCatch() public {
        if (!forked) return;
        DeployGang.Stack memory s = _deploy();
        h.check(st, cf); // a clean stack passes
        address x = address(0x1234);
        // pad
        _breaks(s.pad, abi.encodeCall(IGangPad.setRouter, (s.router, false)), "pad.routers");
        _breaks(s.pad, abi.encodeCall(IGangPad.setAgentGate, (false, M.AGENT_ID_REGISTRY)), "agent gate");
        _breaks(s.pad, abi.encodeCall(IGangPad.setWalletCapEnabled, (false)), "wallet cap");
        _breaks(s.pad, abi.encodeCall(IGangPad.setV3Factory, (x)), "pad.v3Factory");
        _breaks(s.pad, abi.encodeCall(IGangPad.setTwapWindow, (60)), "pad.twapWindow");
        _breaks(s.pad, abi.encodeCall(IGangPad.setBridgePool, (M.USDT, address(0))), "pad.bridgePool USDT");
        _breaks(s.pad, abi.encodeCall(IGangPad.setPairFactory, (x)), "pad.pairFactory");
        // handler
        _breaks(s.handler, abi.encodeCall(IGangTaxHandlerOps.proposeDexRouter, (x)), "handler.dexRouter");
        // vault
        _breaks(s.vault, abi.encodeCall(SharedDividendVault.setLaunchpad, (s.pad, false)), "vault launchpad");
        _breaks(s.vault, abi.encodeCall(SharedDividendVault.setMinimumShareBalance, (s.pad, 1)), "vault floor");
        _breaks(s.vault, abi.encodeCall(SharedDividendVault.setExcluded, (s.bucket, false)), "vault excludes bucket");
        _breaks(
            s.vault, abi.encodeCall(SharedDividendVault.setExcluded, (s.migrator, false)), "vault excludes migrator"
        );
        // bucket
        _breaks(s.bucket, abi.encodeCall(SharedPlatformFeeBucket.setOperator, (s.handler, false)), "bucket operators");
        _breaks(s.bucket, abi.encodeCall(SharedPlatformFeeBucket.setOperator, (s.pad, false)), "bucket operators");
        _breaks(s.bucket, abi.encodeCall(SharedPlatformFeeBucket.setBurner, (x)), "bucket burner");
        _breaks(s.bucket, abi.encodeCall(SharedPlatformFeeBucket.setFeeVault, (x)), "bucket feeVault");
        // platform
        _breaks(s.tokenDeployer, abi.encodeCall(TokenDeployer.setLaunchpad, (s.pad, false)), "deployer launchpad");
        _breaks(s.quoteRegistry, abi.encodeCall(QuoteRegistry.setQuote, (M.USDT, true, 1)), "mainnet USDT listed");
        // ownership (C-F8): something left pending for another address
        _breaks(s.vault, abi.encodeWithSignature("transferOwnership(address)", x), "owner / pendingOwner");
    }

    /// The deploy-time stub (same setters and wiring views as the pad, no logic), wired exactly like the real pad,
    /// must not pass the self-check: it has no CURVE_SUPPLY / MINT_SUPPLY / checkTaxConfig, nor the USDT library path.
    function test_fork_deploy_checkRefusesTheStub() public {
        if (!forked) return;
        DeployGang.Stack memory s = _deploy();
        vm.startPrank(deployer);
        StubGangLaunchpad stub = new StubGangLaunchpad(
            deployer, s.quoteRegistry, s.vault, s.bucket, s.handler, s.tokenDeployer, M.WBNB, M.PANCAKE_V2_FACTORY
        );
        stub.setRouter(s.router, true);
        stub.setAgentGate(true, M.AGENT_ID_REGISTRY);
        stub.setV3Factory(M.PANCAKE_V3_FACTORY);
        stub.setBridgePool(M.USDT, M.USDT_WBNB_V3);
        SharedMigrator(s.migrator).addLaunchpad(address(stub));
        stub.setMigrator(s.migrator);
        vm.stopPrank();
        DeployGang.Stack memory fake = st;
        fake.pad = address(stub);
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "pad.CURVE_SUPPLY"));
        h.checkPadOnly(fake, cf);
        // and the full self-check refuses it too
        vm.expectRevert();
        h.check(fake, cf);
        h.check(st, cf); // the real one still passes
    }

    /// Mainnet: MAINNET_OWNER_IS_DEPLOYER=true with an OWNER that is not the deployer is refused, not ignored.
    function test_fork_deploy_ownerIsDeployerFlagNeedsTheDeployer() public {
        if (!forked) return;
        vm.setEnv("MAINNET_OWNER_IS_DEPLOYER", "true"); // OWNER stays the multisig
        DeployGangHarness g = new DeployGangHarness();
        vm.expectRevert(DeployGang.OwnerNotDeployer.selector);
        g.cfgFor(deployer);
        _clear();
    }

    /// Mainnet: the keeper is 0xB6f1…cFc7 unless KEEPER_OVERRIDE_OK=true; TWAP_WINDOW has a 600 s floor.
    function test_fork_deploy_keeperPinnedAndTwapFloor() public {
        if (!forked) return;
        DeployGangHarness g = new DeployGangHarness();
        assertEq(g.cfgFor(deployer).keeper, M.KEEPER, "default keeper");
        address other = address(0x1234);
        vm.setEnv("KEEPER", vm.toString(other));
        vm.expectRevert(abi.encodeWithSelector(DeployGang.KeeperNotDefault.selector, other));
        g.cfgFor(deployer);
        vm.setEnv("KEEPER_OVERRIDE_OK", "true");
        assertEq(g.cfgFor(deployer).keeper, other, "explicit override");
        _clear();
        vm.setEnv("TWAP_WINDOW", "599");
        vm.expectRevert(abi.encodeWithSelector(DeployGang.TwapWindowTooShort.selector, uint32(599)));
        g.cfgFor(deployer);
        vm.setEnv("TWAP_WINDOW", "600");
        assertEq(g.cfgFor(deployer).twapWindow, 600);
        _clear();
    }

    /// The keeper line is exactly `PADS=gang:PAD(at)BLOCK`; a re-run without GANG_PAD_BLOCK prints no start block.
    function test_fork_deploy_padsLineAndRerunWithoutBlock() public {
        if (!forked) return;
        DeployGang.Stack memory s = _deploy();
        assertGt(s.padBlock, 0);
        assertEq(
            h.padsLine(s), string.concat("PADS=gang:", vm.toString(s.pad), "@", vm.toString(s.padBlock)), "PADS line"
        );
        _rerunEnv(s); // GANG_PAD_BLOCK stays unset (0)
        DeployGang.Stack memory again = new DeployGang().run();
        _clear();
        assertEq(again.padBlock, 0);
        assertEq(h.padsLine(again), "", "no @0 line");
    }

    // ---------------------------------------------------------------- OWNER, re-run, mainnet gate
    function test_fork_deploy_ownerRequiredOnMainnet() public {
        if (!forked) return;
        vm.setEnv("OWNER", vm.toString(address(0)));
        DeployGang d = new DeployGang();
        vm.expectRevert(DeployGang.OwnerRequired.selector);
        d.run();
        vm.setEnv("OWNER", vm.toString(deployer));
        d = new DeployGang();
        vm.expectRevert(DeployGang.OwnerRequired.selector);
        d.run();
        _clear();
    }

    /// The 2026-10-27 launch: the deploy wallet is also the owner. Everything stays on it, nothing pending.
    function test_fork_deploy_ownerIsDeployer() public {
        if (!forked) return;
        vm.setEnv("OWNER", vm.toString(deployer));
        vm.setEnv("MAINNET_OWNER_IS_DEPLOYER", "true");
        DeployGang.Stack memory s = _deploy();
        _clear();
        address[7] memory owned = _owned(s);
        for (uint256 i; i < owned.length; i++) {
            assertEq(Ownable2Step(owned[i]).owner(), deployer);
            assertEq(Ownable2Step(owned[i]).pendingOwner(), address(0), "no pending owner");
        }
    }

    /// C-F8: a re-run naming another OWNER does not overwrite the pending owner; the same OWNER is idempotent.
    function test_fork_deploy_rerunPendingOwnerMismatch() public {
        if (!forked) return;
        DeployGang.Stack memory s = _deploy();
        _rerunEnv(s);
        DeployGang.Stack memory again = new DeployGang().run();
        assertEq(again.pad, s.pad);
        assertEq(again.bucket, s.bucket);
        assertEq(again.handler, s.handler);
        assertEq(Ownable2Step(s.pad).pendingOwner(), multisig);

        vm.setEnv("OWNER", vm.toString(address(0xBAD)));
        DeployGang d = new DeployGang();
        vm.expectRevert(abi.encodeWithSelector(DeployGang.PendingOwnerMismatch.selector, s.quoteRegistry));
        d.run();
        vm.stopBroadcast();
        _clear();
        address[7] memory owned = _owned(s);
        for (uint256 i; i < owned.length; i++) {
            assertEq(Ownable2Step(owned[i]).pendingOwner(), multisig, "pending owner kept");
        }
    }

    /// A re-run needs the router too (it is not readable from the pad).
    function test_fork_deploy_rerunNeedsRouter() public {
        if (!forked) return;
        DeployGang.Stack memory s = _deploy();
        vm.setEnv("GANG_PAD", vm.toString(s.pad));
        DeployGang d = new DeployGang();
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "GANG_ROUTER"));
        d.run();
        vm.stopBroadcast();
        _clear();
    }

    /// No mainnet broadcast without GANG_MAINNET_OK=true; simulations and testnet need nothing.
    function test_deploy_mainnetBroadcastGate() public {
        DeployGangHarness g = new DeployGangHarness();
        vm.setEnv("GANG_MAINNET_OK", "false");
        vm.expectRevert(DeployGang.MainnetNotAllowed.selector);
        g.gate(true, true);
        g.gate(true, false);
        g.gate(false, true);
        vm.setEnv("GANG_MAINNET_OK", "true");
        g.gate(true, true);
        vm.setEnv("GANG_MAINNET_OK", "false");
    }

    function test_deploy_wrongChainRefused() public {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(PK));
        vm.chainId(1);
        DeployGang d = new DeployGang();
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WrongChain.selector, uint256(1)));
        d.run();
    }

    // ---------------------------------------------------------------- testnet
    function test_fork_deploy_testnet() public {
        string memory rpc = vm.envOr("BSC_TESTNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        _clear();
        vm.setEnv("OWNER", vm.toString(address(0))); // testnet default: the deployer
        DeployGang.Stack memory s = _deploy();
        _clear();
        // quotes at the fixed rate, demo treasury listed, keeper = deployer, everything on the deployer
        (bool on, uint256 amount) = QuoteRegistry(s.quoteRegistry).quotes(T.TEST_QUOTE);
        assertTrue(on);
        assertEq(amount, 15 ether);
        (on, amount) = QuoteRegistry(s.quoteRegistry).quotes(s.blacklistQuote);
        assertTrue(on && s.blacklistQuote != address(0));
        assertEq(amount, 15 ether);
        assertEq(s.testQuote, T.TEST_QUOTE);
        assertEq(s.agentId, T.AGENT_ID_REGISTRY);
        assertEq(s.recipient, T.DEMO_TREASURY);
        assertTrue(IGangTaxHandlerOps(s.handler).isListed(T.DEMO_TREASURY));
        assertEq(IGangTaxHandlerOps(s.handler).keeper(), deployer);
        assertEq(SharedPlatformFeeBucket(s.bucket).keeper(), deployer);
        assertEq(SharedPlatformFeeBucket(s.bucket).feeVault(), deployer);
        assertEq(address(SharedPlatformFeeBucket(s.bucket).burner()), address(0), "testnet: no burner by default");
        assertEq(IGangPad(s.pad).bridgePoolOf(M.USDT), address(0), "no bridge on testnet");
        address[7] memory owned = _owned(s);
        for (uint256 i; i < owned.length; i++) {
            assertEq(Ownable2Step(owned[i]).owner(), deployer);
            assertEq(Ownable2Step(owned[i]).pendingOwner(), address(0));
        }
    }
}
