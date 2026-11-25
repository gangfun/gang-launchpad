// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangSwapPad} from "../../src/gang/interfaces/IGangSwapPad.sol";
import {IGangAgentWindow} from "../../src/gang/interfaces/IGangAgentWindow.sol";
import {IGangGradReward, IGangGradRewardBase} from "../../src/gang/interfaces/IGangGradReward.sol";
import {Pad3VanitySalt} from "../../script/Pad3VanitySalt.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {WindowBatchHarness} from "./Pad3AgentWindowFork.t.sol";

interface IWBNBGg {
    function deposit() external payable;
}

interface IGgMigrator {
    function boost() external view returns (address);
}

interface IGgBoost {
    function step(address) external returns (uint256, uint256);
    function boosts(address) external view returns (address, uint64, bool, uint128, uint128);
}

interface IGgPair {
    function virtualReserve() external view returns (uint256);
    function realQuoteReserve() external view returns (uint256);
}

/// @notice createGangSwapWithGradReward on a mainnet fork (docs/SPEC-GANGSWAP-GRAD-REWARD-2026-11-25.md), over the LIVE
///         pad, GangSwap version, abcd deployer and registry, none of which the upgrade touches. UpgradeGangLaunchpad3 is run
///         against the live proxy (deploying this build, checking, simulating), then read-only over what it deployed; its
///         batch is the one upgrade; sent as the Safe it writes only the implementation slot. The creates that exist
///         today (kind 1, kind 1 with a reward, GangSwap), each traded, give the same logs, records and balances, to the byte,
///         on the live implementation and on the new one. A kind-1 token, a kind-1 reward token and a GangSwap token created
///         and traded BEFORE the upgrade read the same after it (registry quotes too) and graduate as before. Then a
///         GangSwap token with a reward and an agent window, through createWithAgentWindow(createWithSalt(...)), to its
///         graduation, buy-back, claims and sweep. Agent IDs are mocked per address on this fork only. No broadcast.
/// @dev BSC_RPC_URL required (skipped if absent): a node that keeps the state of the block it forks (the newest, or
///      BSC_FORK_BLOCK) for the run. Link the live PoolCheck:
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract Pad3GangSwapGradForkTest is Test {
    address internal constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address internal constant PAD1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address internal constant ROUTER3 = 0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant G = 6 ether;
    uint128 internal constant SEED = 0.5 ether;
    uint16 internal constant MINUTES = 60;

    GangLaunchpad3 internal p = GangLaunchpad3(payable(PAD3));
    Pad3Module internal m = Pad3Module(payable(PAD3));
    IGangGradReward internal g = IGangGradReward(PAD3);
    GangPadRegistry internal reg = GangPadRegistry(M.PAD_REGISTRY);
    IERC20 internal wbnb = IERC20(M.WBNB);
    address internal mig;
    uint256 internal _n;

    function test_fork_upgradeThenRewardToken() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        emit log_named_uint("fork block", block.number);

        mig = m.gangSwapMigrator();
        assertTrue(mig != address(0), "GangSwap is open on mainnet");
        (bool open,, address factory) = g.gradRewardDeps();
        assertTrue(open, "the graduation reward is open on mainnet");
        assertTrue(m.vanityDeployer() != address(0), "abcd is on");

        // tokens of today, partly bought
        address dev = _actor(true);
        address old1 = _saltCreate(dev, "Old1", _plain("Old1"));
        address oldR = _rewardKind1(dev, "OldR");
        address oldGs = _saltCreate(dev, "OldGs", _gs("OldGs"));
        address holder = _actor(true);
        _buy(holder, old1, 0.1 ether);
        _buy(holder, oldR, 0.1 ether);
        _buy(holder, oldGs, 0.1 ether);
        // and two graduated ones: GangSwap, and a kind-1 reward one with one claim made
        address doneGs = _saltCreate(dev, "DoneGs", _gs("DoneGs"));
        _graduate(doneGs);
        address doneR = _rewardKind1(dev, "DoneR");
        _buy(holder, doneR, 0.1 ether);
        address doneLast = _graduate(doneR);
        _claim(doneR, doneLast);
        bytes memory doneRecords = abi.encode(_record(doneGs), _record(doneR), _grad(doneR));
        bytes memory records = abi.encode(_record(old1), _record(oldR), _record(oldGs));
        bytes memory gradRecord = _grad(oldR);

        bytes32 live1 = _run(0);
        bytes32 liveR = _run(1);
        bytes32 liveGs = _run(2);
        assertFalse(_served(), "not on the live implementation");

        address current = R.implementationOf(PAD3);
        address next = _upgrade();
        assertTrue(next != current);
        assertTrue(_served());

        assertEq(_run(0), live1, "kind 1: logs, record, balances");
        assertEq(_run(1), liveR, "kind 1 with a reward");
        assertEq(_run(2), liveGs, "GangSwap");
        assertEq(abi.encode(_record(old1), _record(oldR), _record(oldGs)), records);
        assertEq(_grad(oldR), gradRecord);
        assertEq(abi.encode(_record(doneGs), _record(doneR), _grad(doneR)), doneRecords);
        assertTrue(g.gradReward(doneR).settled);
        _claim(doneR, _lastBut(doneR, doneLast));
        // what the upgrade leaves alone
        assertEq(m.gangSwapMigrator(), mig);
        (bool open2,, address factory2) = g.gradRewardDeps();
        assertTrue(open2 && factory2 == factory);
        assertEq(p.owner(), M.OWNER_SAFE);

        _rewardToken();

        // the old ones graduate as before: Pancake V2, Pancake V2 paying its reward, GangSwap without one
        _graduate(old1);
        (uint8 s,,,,) = p.getTokenInfo(old1);
        assertEq(s, 2);
        address last = _graduate(oldR);
        (s,,,,) = p.getTokenInfo(oldR);
        assertEq(s, 2);
        _claim(oldR, last);
        _graduate(oldGs);
        (s,,,,) = p.getTokenInfo(oldGs);
        assertEq(s, 4);
        assertEq(g.gradReward(oldGs).state, 0);
    }

    // ---------------------------------------------------------------- the upgrade
    function _upgrade() internal returns (address next) {
        (, uint256 key) = makeAddrAndKey("gangswap grad fork deployer");
        vm.deal(vm.addr(key), 10 ether);
        _env(key);
        WindowBatchHarness up = new WindowBatchHarness();
        vm.pauseGasMetering();
        up.run();
        next = up.deployedImpl();
        // read-only over the deployed implementation: the run that prints the batch
        vm.setEnv("PAD3_IMPL", vm.toString(next));
        WindowBatchHarness again = new WindowBatchHarness();
        again.run();
        vm.resumeGasMetering();
        emit log_named_uint("size GangLaunchpad3", next.code.length);
        address module = p.module();
        address newModule = GangLaunchpad3(payable(next)).module();
        assertTrue(newModule != module);
        emit log_named_uint("size Pad3Module", newModule.code.length);
        emit log_named_uint("size Pad3GradModule", Pad3Module(payable(newModule)).gradModule().code.length);

        address admin = R.adminOf(PAD3);
        bytes memory call =
            abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(PAD3), next, bytes("")));
        string memory json = again.batchJson(admin, call, PAD3);
        assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), admin);
        assertEq(vm.parseJsonBytes(json, ".transactions[0].data"), call);
        assertFalse(vm.keyExistsJson(json, ".transactions[1]"), "the upgrade alone");
        vm.record();
        vm.prank(M.OWNER_SAFE);
        (bool ok,) = admin.call(call);
        assertTrue(ok);
        (, bytes32[] memory writes) = vm.accesses(PAD3);
        assertEq(writes.length, 1, "only the implementation slot");
        assertEq(writes[0], R.IMPLEMENTATION_SLOT);
    }

    function _served() internal returns (bool) {
        IGangGradRewardBase.GradConfig memory none;
        (bool ok, bytes memory ret) =
            PAD3.call(abi.encodeCall(IGangSwapPad.createGangSwapWithGradReward, ("", "", "", "", 0, address(0), none)));
        return !ok && ret.length == 4 && bytes4(ret) == IGangGradRewardBase.BadGradConfig.selector;
    }

    // ---------------------------------------------------------------- the same on both implementations
    /// @dev Create (0 kind 1, 1 kind 1 with a reward, 2 GangSwap), buy, sell, graduate; every log, the records and the
    ///      balances hashed; rolled back.
    function _run(uint256 what) internal returns (bytes32 h) {
        uint256 snap = vm.snapshotState();
        address dev = _actor(true);
        vm.recordLogs();
        address t;
        if (what == 0) t = _saltCreate(dev, "Run", _plain("Run"));
        else if (what == 1) t = _rewardKind1(dev, "Run");
        else t = _saltCreate(dev, "Run", _gs("Run"));
        address a = _actor(true);
        _buy(a, t, 0.03 ether);
        vm.startPrank(a, a);
        uint256 half = IERC20(t).balanceOf(a) / 2;
        IERC20(t).approve(PAD3, half);
        p.sell(t, half, 0);
        vm.stopPrank();
        bytes memory mid = _record(t);
        address last = _graduate(t);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        h = keccak256(
            abi.encode(
                mid,
                _record(t),
                _grad(t),
                g.gradClaimable(t, last),
                wbnb.balanceOf(PAD3),
                wbnb.balanceOf(dev),
                wbnb.balanceOf(a)
            )
        );
        for (uint256 i; i < logs.length; i++) {
            h = keccak256(abi.encode(h, logs[i].emitter, logs[i].topics, logs[i].data));
        }
        vm.revertToState(snap);
    }

    function _record(address t) internal view returns (bytes memory) {
        (bool ok, bytes memory cv) = PAD3.staticcall(abi.encodeWithSignature("curves(address)", t));
        assertTrue(ok);
        (bool ok2, bytes memory info) = PAD3.staticcall(abi.encodeCall(GangLaunchpad3.getTokenInfo, (t)));
        assertTrue(ok2);
        (, bytes memory quote) =
            M.PAD_REGISTRY.staticcall(abi.encodeCall(GangPadRegistry.previewBuy, (t, address(0), 0.01 ether)));
        (, bytes memory back) =
            M.PAD_REGISTRY.staticcall(abi.encodeCall(GangPadRegistry.previewSell, (t, address(0), 1 ether)));
        (, bytes memory tb) = PAD3.staticcall(abi.encodeCall(GangLaunchpad3.tryBuy, (t, address(0), 0, 0.01 ether)));
        return abi.encode(
            cv,
            info,
            quote,
            back,
            tb,
            p.kindOf(t),
            p.creatorFeeOf(t),
            m.gangSwapMigratorOf(t),
            IGangAgentWindow(PAD3).agentOpenAt(t)
        );
    }

    function _grad(address t) internal view returns (bytes memory) {
        (, bytes memory e) = PAD3.staticcall(abi.encodeCall(IGangGradReward.gradEntries, (t)));
        return abi.encode(g.gradReward(t), e);
    }

    // ---------------------------------------------------------------- the reward GangSwap token
    function _rewardToken() internal {
        address dev = _actor(true);
        uint256 padBefore = wbnb.balanceOf(PAD3);
        uint256 devBefore = _fund(dev, SEED);
        bytes memory data =
            abi.encodeCall(IGangSwapPad.createGangSwapWithGradReward, ("Gs", "GSG", "", "meta", G, mig, _cfg()));
        (bytes32 salt, address expected) = _saltFor(dev, "Gs");
        vm.prank(dev, dev);
        uint256 gas0 = gasleft();
        address t = IGangAgentWindow(PAD3)
            .createWithAgentWindow(MINUTES, abi.encodeCall(Pad3Module.createWithSalt, (salt, data)));
        emit log_named_uint("create gas (window + salt + reward)", gas0 - gasleft());
        assertEq(t, expected);
        assertEq(p.kindOf(t), 4);
        assertEq(m.gangSwapMigratorOf(t), mig);
        assertEq(devBefore - wbnb.balanceOf(dev), SEED);
        assertEq(wbnb.balanceOf(PAD3) - padBefore, SEED);
        assertEq(g.gradReward(t).pot, SEED);

        // inside the window Agents only; after it anyone trades and only Agents count
        address human = _actor(false);
        _fund(human, 10 ether);
        vm.prank(human, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        p.buy(t, 0.1 ether, 0);
        address[] memory w = new address[](22);
        for (uint256 i; i < 20; i++) {
            w[i] = _actor(true);
            _buy(w[i], t, 0.02 ether);
        }
        assertEq(g.gradReward(t).seq, 20);
        vm.warp(vm.getBlockTimestamp() + uint256(MINUTES) * 60);
        vm.prank(human, human);
        p.buy(t, 2 ether, 0);
        assertEq(g.gradReward(t).seq, 20, "a wallet without an Agent ID is not counted");
        // one of the list sells: out
        vm.startPrank(w[19], w[19]);
        IERC20(t).approve(PAD3, 1 ether);
        p.sell(t, 1 ether, 0);
        vm.stopPrank();

        w[20] = _actor(true);
        _fund(w[20], 10 ether);
        (,,,, uint256 left) = p.getTokenInfo(t);
        assertGt(left, 0);
        uint256 padHeld = wbnb.balanceOf(PAD3) - SEED;
        vm.prank(w[20], w[20]);
        gas0 = gasleft();
        p.buy(t, 10 ether, 0);
        emit log_named_uint("graduating buy gas (live version, full list)", gas0 - gasleft());
        (uint8 s,, address pair,,) = p.getTokenInfo(t);
        assertEq(s, 4);
        IGgPair x = IGgPair(pair);
        uint256 v = x.virtualReserve();
        assertEq(x.realQuoteReserve(), G - v, "the raise less V, no reward money");
        assertEq(wbnb.balanceOf(pair), G - v);
        IGgBoost boost = IGgBoost(IGgMigrator(mig).boost());
        (address bp,,,, uint128 boostLeft) = boost.boosts(t);
        assertEq(bp, pair);
        assertEq(boostLeft, v);
        // the pad paid out the curve's raise so far and nothing of the pot
        (,, uint128 rq,,,,,,,,,) = p.curves(t);
        assertEq(rq, 0);
        assertGe(wbnb.balanceOf(PAD3), SEED);
        assertLe(wbnb.balanceOf(PAD3) - SEED, padHeld);
        assertEq(g.gradReward(t).state, 2);
        assertEq(g.gradReward(t).seq, 21);

        // the buy-back, to its end: the pot is not in it
        uint256 held = wbnb.balanceOf(PAD3);
        uint256 burned = IERC20(t).balanceOf(DEAD);
        for (uint256 i; boostLeft != 0; i++) {
            require(i < 100, "boost");
            vm.warp(vm.getBlockTimestamp() + 8);
            boost.step(t);
            (,,,, boostLeft) = boost.boosts(t);
        }
        assertGt(IERC20(t).balanceOf(DEAD), burned);
        assertEq(wbnb.balanceOf(PAD3), held);

        // claims: the list is the graduating buy and 19 before it; w0 fell off, w19 sold
        assertEq(g.gradClaimable(t, w[0]), 0);
        assertEq(g.gradClaimable(t, w[19]), 0);
        assertEq(g.gradClaimable(t, human), 0);
        uint256 paid;
        for (uint256 i = 20; i > 0; i--) {
            if (i != 19) paid += _claim(t, w[i]);
        }
        assertEq(g.gradReward(t).claimed, paid);
        assertLe(SEED - paid, 20, "dust");
        assertEq(held - wbnb.balanceOf(PAD3), paid);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        uint256 before = wbnb.balanceOf(dev);
        g.sweepGradReward(t);
        assertEq(wbnb.balanceOf(dev) - before, SEED - paid);
        assertEq(g.gradReward(t).state, 4);
    }

    // ---------------------------------------------------------------- helpers
    function _cfg() internal pure returns (IGangGradRewardBase.GradConfig memory) {
        return IGangGradRewardBase.GradConfig({
            seed: SEED,
            minBuy: 0.01 ether,
            entries: 20,
            lastBps: 3_000,
            carryBps: 0,
            refundAfter: 90 days,
            promoteBps: 0,
            promoteWindow: 0
        });
    }

    function _noTax() internal pure returns (IGangLaunchpad.TaxConfig memory) {}

    function _plain(string memory name) internal pure returns (bytes memory) {
        return abi.encodeCall(
            GangLaunchpad3.createWithGradTarget, (name, "GSG", "", "meta", address(0), address(0), _noTax(), G)
        );
    }

    function _gs(string memory name) internal view returns (bytes memory) {
        return abi.encodeCall(IGangSwapPad.createGangSwap, (name, "GSG", "", "meta", G, mig));
    }

    function _rewardKind1(address dev, string memory name) internal returns (address) {
        _fund(dev, SEED);
        return _saltCreate(
            dev,
            name,
            abi.encodeCall(
                IGangGradReward.createWithGradReward,
                (name, "GSG", "", "meta", address(0), address(0), _noTax(), G, _cfg())
            )
        );
    }

    function _saltFor(address creator, string memory name) internal view returns (bytes32 salt, address expected) {
        address f = m.vanityDeployer();
        return Pad3VanitySalt.find(
            f, creator, Pad3VanityDeployer(f).tokenInitCodeHash(name, "GSG", "meta", address(0), 0, 0, false)
        );
    }

    function _saltCreate(address creator, string memory name, bytes memory data) internal returns (address t) {
        (bytes32 salt, address expected) = _saltFor(creator, name);
        vm.prank(creator, creator);
        t = m.createWithSalt(salt, data);
        assertEq(t, expected);
    }

    function _actor(bool agent) internal returns (address a) {
        a = makeAddr(string.concat("gangswap grad fork actor ", vm.toString(_n++)));
        vm.deal(a, 50 ether);
        vm.mockCall(
            address(p.agentIdRegistry()), abi.encodeCall(IERC721.balanceOf, (a)), abi.encode(uint256(agent ? 1 : 0))
        );
    }

    function _fund(address a, uint256 amt) internal returns (uint256) {
        vm.startPrank(a, a);
        IWBNBGg(M.WBNB).deposit{value: amt}();
        wbnb.approve(PAD3, type(uint256).max);
        vm.stopPrank();
        return wbnb.balanceOf(a);
    }

    function _buy(address who, address t, uint256 amt) internal {
        _fund(who, amt);
        vm.prank(who, who);
        p.buy(t, amt, 0);
    }

    function _graduate(address t) internal returns (address last) {
        for (uint256 i; i < 200; i++) {
            (uint8 s,,,,) = p.getTokenInfo(t);
            if (s != 1) return last;
            last = _actor(true);
            _buy(last, t, 0.4 ether);
        }
        revert("not graduated");
    }

    /// @dev The newest buyer on `t`'s list other than `not`.
    function _lastBut(address t, address not) internal view returns (address) {
        (address[] memory buyers,,,) = g.gradEntries(t);
        for (uint256 i; i < buyers.length; i++) {
            if (buyers[i] != not) return buyers[i];
        }
        revert("no other buyer");
    }

    function _claim(address t, address who) internal returns (uint256 got) {
        got = g.gradClaimable(t, who);
        assertGt(got, 0);
        uint256 before = wbnb.balanceOf(who);
        vm.prank(who);
        g.claimGradReward(t);
        assertEq(wbnb.balanceOf(who) - before, got);
    }

    function _env(uint256 key) private {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(key));
        vm.setEnv("GANG_PAD", vm.toString(PAD1));
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        vm.setEnv("GANG_ROUTER3", vm.toString(ROUTER3));
        vm.setEnv("OWNER", vm.toString(M.OWNER_SAFE));
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        vm.setEnv("GANG_GATEWAY", vm.toString(M.GANG_GATEWAY));
        vm.setEnv("GANG_PAD_REGISTRY", vm.toString(M.PAD_REGISTRY));
        vm.setEnv("PAD3_ABCD_DEPLOYER", vm.toString(address(0)));
        vm.setEnv("PAD3_BASE_VAULT_IMPL", vm.toString(address(0)));
        vm.setEnv("PAD3_GRAD_REWARD", "false");
        vm.setEnv("PAD3_GRAD_HANDLER_ADMIN", vm.toString(address(0)));
        vm.setEnv("PAD3_GRAD_COUNTDOWN_FACTORY", vm.toString(address(0)));
        vm.setEnv("PAD3_IMPL", vm.toString(address(0)));
        vm.setEnv("PAD3_REGISTRY_UPGRADE", "false");
        vm.setEnv("PAD_REGISTRY_IMPL", vm.toString(address(0)));
        vm.setEnv("PAD3_INIT_CALL", "0x");
        vm.setEnv("PAD3_FLY_HANDLER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_TOKEN_DEPLOYER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_VAULT_CORE", vm.toString(address(0)));
        vm.setEnv("CALLERS", "");
        vm.setEnv("PAD3_NEW", "false");
        vm.setEnv("GANG_MAINNET_OK", "true");
        vm.setEnv("CUTOVER", "false");
        vm.setEnv("RECIPIENT", vm.toString(address(0)));
        vm.setEnv("TWAP_WINDOW", vm.toString(GangLaunchpad3(payable(PAD1)).twapWindow()));
    }
}
