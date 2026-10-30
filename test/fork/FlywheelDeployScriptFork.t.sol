// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {DeployFlywheel} from "../../script/DeployFlywheel.s.sol";
import {DeployFlywheelV2} from "../../script/DeployFlywheelV2.s.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../../src/common/SharedPlatformFeeBucket.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {MintTokenDeployer} from "../../src/flywheel/MintTokenDeployer.sol";
import {FlywheelTaxHandler} from "../../src/flywheel/FlywheelTaxHandler.sol";
import {GangFlywheelPad} from "../../src/flywheel/GangFlywheelPad.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";

interface IGangPadSharedA {
    function quoteRegistry() external view returns (address);
    function dividendVault() external view returns (address);
    function platformBucket() external view returns (address);
    function migrator() external view returns (address);
}

/// @dev Exposes the script's internal JSON builders (same code the script prints).
contract DeployFlywheelHarness is DeployFlywheel {
    function wiringJson(address[5] memory sh, address[3] memory o, address safe) external pure returns (string memory) {
        return _wiringJson(Shared(sh[0], sh[1], sh[2], sh[3], sh[4]), Own(o[0], o[1], o[2]), true, safe);
    }

    function acceptJson(address[5] memory sh, address[3] memory o, address safe) external pure returns (string memory) {
        return _acceptJson(
            Shared(sh[0], sh[1], sh[2], sh[3], sh[4]), Own(o[0], o[1], o[2]), true, safe, [true, true, true], true
        );
    }
}

/// @dev The V2 script's JSON builders.
contract DeployFlywheelV2Harness is DeployFlywheelV2 {
    function wiringJson(address[5] memory sh, address[3] memory o, address safe) external pure returns (string memory) {
        return _wiringJsonV2(Shared(sh[0], sh[1], sh[2], sh[3], sh[4]), Own(o[0], o[1], o[2]), true, safe);
    }

    /// @dev The Safe already owns the deployer: accept the handler and the pad, then open the pad.
    function acceptJson(address[5] memory sh, address[3] memory o, address safe) external pure returns (string memory) {
        return _acceptJson(
            Shared(sh[0], sh[1], sh[2], sh[3], sh[4]), Own(o[0], o[1], o[2]), true, safe, [false, true, true], true
        );
    }

    function stopV1Json(address deployer, address v1Pad, address safe) external pure returns (string memory) {
        return _stopV1Json(deployer, v1Pad, true, safe);
    }
}

/// @dev Stands in for FlywheelLogic as linked before the audit V2 fixes (re-review I-1): its `checkConfig` takes the
///      older bounds. Etched over the pad's linked FlywheelLogic, so it is reached by the pad's library call (any
///      selector: a library's struct parameter changes the selector, so this decodes whatever arrives).
contract StaleFlywheelLogic {
    uint256 internal immutable maxPostQuota;
    uint256 internal immutable maxInvite;

    constructor(uint256 maxPostQuota_, uint256 maxInvite_) {
        maxPostQuota = maxPostQuota_;
        maxInvite = maxInvite_;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        (IFlywheelPad.FlyConfig memory c,) = abi.decode(data[4:], (IFlywheelPad.FlyConfig, uint256));
        string memory why;
        if (c.postMint && c.baseQuota > maxPostQuota) {
            why = maxPostQuota == 10 ? "baseQuota must be 5-10 with postMint" : "baseQuota must be 5-20 with postMint";
        } else if (c.inviteBonus > maxInvite) {
            why = "inviteBonus must be 0-3";
        }
        return abi.encode(why);
    }
}

/// @dev The live V1 pad's create (its FlyConfig has no guardBps / twapWindow).
interface IFlywheelPadV1 {
    struct FlyConfigV1 {
        uint256 raiseBnb;
        uint16 baseQuota;
        uint8 inviteBonus;
        uint8 maxPerTx;
        uint16 holdBps;
        uint16 mintFeeBps;
        uint16 exitFeeBps;
        uint16 devCutBps;
        uint16 buyBps;
        uint16 sellTaxBps;
        uint32 launchDelay;
        uint32 window;
        uint8 windowCapMul;
        bool postMint;
        uint8 tierMode;
        uint16 stepBps;
        uint32 stepShares;
        uint16 maxMulX100;
        uint16 supplyCapMul;
    }

    function create(
        string[4] calldata text,
        address quote,
        address refPool,
        FlyConfigV1 calldata cfg,
        uint256 devShares
    ) external returns (address token);
    function setAgentGate(bool enabled, address registry) external;
}

interface IPancakeRouterA {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256, address[] calldata, address, uint256)
        external
        payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256, uint256, address[] calldata, address, uint256)
        external;
}

/// @notice Pre-mainnet audit C (2026-10-30), extended for V2: runs the real deploy scripts (both phases) on a BSC
///         mainnet fork with a throwaway key and executes the Safe batches exactly as encoded:
///         - DeployFlywheel (the V1 path: three new contracts) through its accept batch and a re-run;
///         - from the same fork state, DeployFlywheelV2 (a new handler and the V2 pad on the live MintTokenDeployer):
///           pins, the eight-transaction listing batch, the accept batch, a re-run, the optional batch that stops new
///           creates on the live V1 pad, then a full life on the live shared contracts.
///         No broadcast. One test: the scripts read process-wide env vars, and tests run in parallel.
contract FlywheelDeployScriptForkTest is Test {
    address constant GANG_PAD = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant PAD_REGISTRY = 0x4fF77D4d9ac080939a24E1B805206bA094C44e5C;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    address constant TOKEN_DEPLOYER = 0x2C95228AfA6eF211371A87f480aBa0f5c0Da072E;
    address constant V1_PAD = 0x631e66560F4FAE4e486B65349edE48189E48B029;
    address constant GANG_ROUTER = 0xE040445690Aa56C8b68B7f7038C7b2562B5079C4;
    address constant V1_HANDLER = 0xa8329cD0512f1a9b7ee4Afb051c57a50899F84CF;

    address me;
    address[5] sh;

    function _execAsSafe(string memory json, uint256 count) internal {
        assertEq(vm.parseJsonString(json, ".chainId"), "56");
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), SAFE);
        assertFalse(vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(count), "]")), "batch size");
        for (uint256 i; i < count; i++) {
            string memory k = string.concat(".transactions[", vm.toString(i), "]");
            address to = vm.parseJsonAddress(json, string.concat(k, ".to"));
            bytes memory data = vm.parseJsonBytes(json, string.concat(k, ".data"));
            vm.prank(SAFE);
            (bool ok, bytes memory ret) = to.call(data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _expectNotWired(DeployFlywheel script, string memory what) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployFlywheel.NotWired.selector, what));
        script.run();
    }

    function test_fork_deployScriptsMainnetPathsThenLife() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        uint256 pk = uint256(keccak256("flywheel deploy-script fork test: throwaway, never funded"));
        me = vm.addr(pk);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("GANG_PAD", vm.toString(GANG_PAD));
        vm.setEnv("GANG_PAD_REGISTRY", vm.toString(PAD_REGISTRY));
        vm.setEnv("FLYWHEEL_ALLOW_OVERRIDE", "false");
        IGangPadSharedA live = IGangPadSharedA(GANG_PAD);
        sh = [live.quoteRegistry(), live.dividendVault(), live.platformBucket(), live.migrator(), PAD_REGISTRY];
        uint256 snap = vm.snapshotState();
        _v1LiveRecheck();
        vm.revertToState(snap);
        _v1Path();
        vm.revertToState(snap);
        _v2PathThenLife();
    }

    /// @dev Re-review L-1: the base script's phase 2 re-checks the live V1 pad (no `twapWindow()`, no `postRulesOf`)
    ///      without reverting; nothing to broadcast (the Safe owns all three).
    function _v1LiveRecheck() internal {
        vm.setEnv("OWNER", vm.toString(SAFE));
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        vm.setEnv("FLYWHEEL_PAD", vm.toString(V1_PAD));
        vm.setEnv("FLYWHEEL_HANDLER", vm.toString(V1_HANDLER));
        vm.setEnv("FLYWHEEL_DEPLOYER", vm.toString(TOKEN_DEPLOYER));
        uint64 n = vm.getNonce(me);
        new DeployFlywheelHarness().run();
        assertEq(vm.getNonce(me), n, "a re-check of V1 sent something");
    }

    /// @dev The pad's linked FlywheelLogic: the one account its `checkConfig` calls into.
    function _linkedLogic(GangFlywheelPad p) internal returns (address lib) {
        vm.startStateDiffRecording();
        p.checkConfig(_cfg(0), 1);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        for (uint256 i; i < acc.length; i++) {
            if (
                acc[i].account != address(p)
                    && (acc[i].kind == VmSafe.AccountAccessKind.DelegateCall
                        || acc[i].kind == VmSafe.AccountAccessKind.StaticCall)
            ) lib = acc[i].account;
        }
        assertTrue(lib != address(0) && lib.code.length > 0, "linked FlywheelLogic not found");
    }

    /// @dev DeployFlywheel as run for V1 (three new contracts; today's sources).
    function _v1Path() internal {
        vm.setEnv("FLYWHEEL_PAD", vm.toString(address(0)));
        DeployFlywheelHarness s = new DeployFlywheelHarness();
        uint64 n = vm.getNonce(me);
        address[3] memory o =
            [vm.computeCreateAddress(me, n), vm.computeCreateAddress(me, n + 1), vm.computeCreateAddress(me, n + 2)];

        // audit C-2: mainnet inputs are pinned
        vm.setEnv("OWNER", vm.toString(me));
        _expectNotWired(s, "OWNER is not the platform Safe");
        vm.setEnv("OWNER", vm.toString(SAFE));
        vm.setEnv("KEEPER", vm.toString(me));
        _expectNotWired(s, "KEEPER is not the platform keeper");
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        vm.setEnv("GANG_PAD", vm.toString(address(0xBEEF)));
        vm.expectRevert(); // the getters of a non-pad
        s.run();
        vm.setEnv("GANG_PAD", vm.toString(GANG_PAD));

        // phase 1, then the listing batch as printed
        s.run();
        GangFlywheelPad p = GangFlywheelPad(payable(o[2]));
        assertEq(p.taxHandler(), o[1]);
        assertEq(p.migrator(), address(0));
        _execAsSafe(s.wiringJson(sh, o, SAFE), 7);

        // phase 2: hand-over started, the pad still closed (audit C-1)
        vm.setEnv("FLYWHEEL_PAD", vm.toString(o[2]));
        vm.setEnv("FLYWHEEL_HANDLER", vm.toString(o[1]));
        vm.setEnv("FLYWHEEL_DEPLOYER", vm.toString(o[0]));
        s.run();
        assertEq(p.migrator(), address(0), "not open while the deploy wallet owns it");
        assertEq(p.owner(), me);
        assertEq(Ownable2Step(o[2]).pendingOwner(), SAFE);
        vm.expectRevert(IFlywheelPad.MigratorNotSet.selector);
        p.create(["X", "X", "", ""], address(0), address(0), _cfg(0), 1);

        // the accept batch: three acceptOwnership, then setMigrator opens the pad
        _execAsSafe(s.acceptJson(sh, o, SAFE), 4);
        assertEq(Ownable(o[0]).owner(), SAFE);
        assertEq(Ownable(o[1]).owner(), SAFE);
        assertEq(p.owner(), SAFE);
        assertEq(p.migrator(), sh[3]);
        assertTrue(GangPadRegistry(PAD_REGISTRY).isPad(o[2]));

        // audit C-4: phase 2 re-runs after the Safe accepted (self-check only)
        s.run();
    }

    /// @dev DeployFlywheelV2: a new handler and the V2 pad, the live MintTokenDeployer.
    function _v2PathThenLife() internal {
        vm.setEnv("FLYWHEEL_PAD", vm.toString(address(0)));
        vm.setEnv("OWNER", vm.toString(SAFE));
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        DeployFlywheelV2Harness s = new DeployFlywheelV2Harness();
        MintTokenDeployer d = MintTokenDeployer(TOKEN_DEPLOYER);
        assertEq(d.owner(), SAFE);
        assertTrue(d.launchpads(V1_PAD));

        // pins: the live MintTokenDeployer and the live V1 pad
        vm.setEnv("FLYWHEEL_DEPLOYER", vm.toString(address(0xBEEF)));
        _expectNotWired(s, "FLYWHEEL_DEPLOYER is not the live MintTokenDeployer");
        vm.setEnv("FLYWHEEL_DEPLOYER", vm.toString(TOKEN_DEPLOYER));
        vm.setEnv("FLYWHEEL_V1_PAD", vm.toString(address(0xBEEF)));
        _expectNotWired(s, "FLYWHEEL_V1_PAD is not the live V1 pad");
        vm.setEnv("FLYWHEEL_V1_PAD", vm.toString(V1_PAD));

        // phase 1: two contracts (the libraries are linked, not deployed from this wallet), nothing listed yet
        uint64 n = vm.getNonce(me);
        address[3] memory o = [TOKEN_DEPLOYER, vm.computeCreateAddress(me, n), vm.computeCreateAddress(me, n + 1)];
        s.run();
        assertEq(vm.getNonce(me), n + 6, "2 deploys + handler launchpad / keeper + pad gate / v3 factory");
        GangFlywheelPad p = GangFlywheelPad(payable(o[2]));
        FlywheelTaxHandler h = FlywheelTaxHandler(o[1]);
        assertEq(p.taxHandler(), o[1]);
        assertEq(p.tokenDeployer(), TOKEN_DEPLOYER);
        assertEq(p.migrator(), address(0));
        assertFalse(d.launchpads(o[2]));

        // the listing batch: V1's seven, then MintTokenDeployer.setLaunchpad(pad, true)
        _execAsSafe(s.wiringJson(sh, o, SAFE), 8);
        assertTrue(d.launchpads(o[2]));
        assertTrue(d.launchpads(V1_PAD), "the listing leaves the V1 pad alone");
        assertEq(SharedDividendVault(sh[1]).operatorOf(o[1]), o[2]);

        // phase 2: hand-over of the handler and the pad; the pad still closed
        vm.setEnv("FLYWHEEL_PAD", vm.toString(o[2]));
        vm.setEnv("FLYWHEEL_HANDLER", vm.toString(o[1]));
        // audit V2 C-L3: a router or a bridge pool the deploy wallet set out of band fails the self-check
        vm.prank(me);
        p.setRouter(GANG_ROUTER, true);
        _expectNotWired(s, "a router is listed on the new pad");
        vm.prank(me);
        p.setRouter(GANG_ROUTER, false);
        vm.prank(me);
        p.setTwapWindow(900);
        _expectNotWired(s, "pad reference-pool twapWindow");
        vm.prank(me);
        p.setTwapWindow(1800);
        // re-review I-1: a bridge pool set out of band fails it too
        vm.prank(me);
        p.setBridgePool(M.USDT, M.USDT_WBNB_V3);
        _expectNotWired(s, "a bridge pool is set");
        vm.prank(me);
        p.setBridgePool(M.USDT, address(0));
        // re-review I-1: the checkConfig probe refuses a pad linked with stale (pre-fix) FlywheelLogic bounds
        address lib = _linkedLogic(p);
        bytes memory linked = lib.code;
        vm.etch(lib, address(new StaleFlywheelLogic(20, 3)).code); // the V2 libraries before the audit fixes
        _expectNotWired(s, "V2 checkConfig: baseQuota 11 with postMint");
        vm.etch(lib, address(new StaleFlywheelLogic(10, 3)).code); // the quota cap alone
        _expectNotWired(s, "V2 checkConfig: inviteBonus 2 with postMint (not the fixed V2 libraries)");
        vm.etch(lib, linked);
        s.run();
        assertEq(p.migrator(), address(0), "not open while the deploy wallet owns it");
        assertEq(Ownable2Step(o[1]).pendingOwner(), SAFE);
        assertEq(Ownable2Step(o[2]).pendingOwner(), SAFE);
        assertEq(d.owner(), SAFE);
        assertEq(Ownable2Step(TOKEN_DEPLOYER).pendingOwner(), address(0));

        // the accept batch: handler and pad, then setMigrator
        _execAsSafe(s.acceptJson(sh, o, SAFE), 3);
        assertEq(h.owner(), SAFE);
        assertEq(p.owner(), SAFE);
        assertEq(p.migrator(), sh[3]);
        assertEq(h.keeper(), M.KEEPER);
        assertEq(h.launchpad(), o[2]);
        assertEq(address(h.dexRouter()), M.PANCAKE_V2_ROUTER);
        assertEq(address(p.agentIdRegistry()), M.AGENT_ID_REGISTRY);
        assertEq(p.v3Factory(), M.PANCAKE_V3_FACTORY);
        assertEq(p.KIND(), 3);
        assertTrue(GangPadRegistry(PAD_REGISTRY).isPad(o[2]));
        assertTrue(GangPadRegistry(PAD_REGISTRY).isPad(V1_PAD));
        assertEq(SharedDividendVault(sh[1]).minimumShareBalanceOf(o[2]), 1_000 ether);
        assertEq(SharedDividendVault(sh[1]).minimumShareBalanceOf(GANG_PAD), 10_000 ether, "live pad untouched");

        // re-run after the Safe accepted (self-check only)
        s.run();

        // the V1 pad creates until the optional batch, then refuses (its gate pointed at a mock for the test)
        MockAgentId agents = new MockAgentId();
        vm.startPrank(SAFE);
        IFlywheelPadV1(V1_PAD).setAgentGate(true, address(agents));
        p.setAgentGate(true, address(agents)); // the soulbound live registry can't be minted on a fork
        vm.stopPrank();
        address dev = makeAddr("dev");
        agents.mint(dev, 1);
        vm.deal(dev, 10 ether);
        vm.startPrank(dev);
        (bool ok,) = M.WBNB.call{value: 1 ether}(abi.encodeWithSignature("deposit()"));
        require(ok);
        IERC20(M.WBNB).approve(V1_PAD, type(uint256).max);
        IERC20(M.WBNB).approve(o[2], type(uint256).max);
        IFlywheelPadV1(V1_PAD).create(["Old", "OLD", "", ""], address(0), address(0), _cfgV1(), 1);
        vm.stopPrank();
        _execAsSafe(s.stopV1Json(TOKEN_DEPLOYER, V1_PAD, SAFE), 1);
        assertFalse(d.launchpads(V1_PAD));
        vm.prank(dev);
        vm.expectRevert(MintTokenDeployer.OnlyLaunchpad.selector);
        IFlywheelPadV1(V1_PAD).create(["Old", "OLD", "", ""], address(0), address(0), _cfgV1(), 1);

        _life(p, h, agents, dev);
    }

    /// @dev A full V2 life on the live shared contracts: fill to 30%, open early (launch through the LIVE migrator),
    ///      router trades, the keeper's chunk, a post-launch mint matching its preview, holder rewards, fees.
    function _life(GangFlywheelPad p, FlywheelTaxHandler h, MockAgentId agents, address dev) internal {
        uint256 vaultWbnb0 = IERC20(M.WBNB).balanceOf(sh[1]);
        uint256 bucketAcc0 = SharedPlatformFeeBucket(sh[2]).accruedQuote(M.WBNB);
        IFlywheelPad.FlyConfig memory c = _cfg(1_000);
        c.baseQuota = 10;
        c.sellTaxBps = 200;
        c.buyBps = 3_000;
        c.guardBps = 2_000;
        c.twapWindow = 900;
        vm.prank(dev);
        address t = p.create(["Life", "LIFE", "", ""], address(0), address(0), c, 10);
        (uint16 g, uint32 w) = p.postRulesOf(t);
        assertEq(g, 2_000);
        assertEq(w, 900);
        (address found, uint8 kind) = GangPadRegistry(PAD_REGISTRY).lookup(t);
        assertEq(found, address(p));
        assertEq(kind, 3);
        for (uint256 i = 1; p.sales(t).sold < 3_000; i++) {
            address wl = address(uint160(0xA0000 + i));
            agents.mint(wl, 100 + i);
            vm.deal(wl, 1 ether);
            vm.startPrank(wl);
            while (p.quotaLeft(t, wl) > 0 && p.sales(t).sold < 3_000) p.mintWithBnb{value: 0.01 ether}(t, 10, 1, dev);
            vm.stopPrank();
        }
        uint256 gas0 = gasleft();
        vm.prank(dev);
        p.openEarly(t); // launchDelay 0: launches in the same tx through the LIVE migrator
        emit log_named_uint("gas: openEarly + launch (live migrator)", gas0 - gasleft());
        assertTrue(p.sales(t).launched);

        vm.warp(vm.getBlockTimestamp() + 400);
        vm.roll(vm.getBlockNumber() + 1);
        address trader = makeAddr("trader");
        vm.deal(trader, 5 ether);
        vm.prank(trader);
        IPancakeRouterA(M.PANCAKE_V2_ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 1 ether}(
            0, _path(M.WBNB, t), trader, vm.getBlockTimestamp()
        );
        vm.roll(vm.getBlockNumber() + 1);
        uint256 bal = IERC20(t).balanceOf(trader);
        vm.startPrank(trader);
        IERC20(t).approve(M.PANCAKE_V2_ROUTER, bal);
        IPancakeRouterA(M.PANCAKE_V2_ROUTER)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(
                bal / 2, 0, _path(t, M.WBNB), trader, vm.getBlockTimestamp()
            );
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        uint256 chunk = h.maxChunk(t);
        if (chunk > 0) {
            vm.prank(M.KEEPER);
            h.process(t, chunk, 1);
        }
        // a post-launch mint through the live pair, as previewed
        vm.roll(vm.getBlockNumber() + 1);
        address m = address(uint160(0xB0001));
        agents.mint(m, 99_999);
        vm.deal(m, 1 ether);
        (, uint256 paid, uint256 fee, uint256 out, bool okPreview) = p.previewMintPost(t, m, 10);
        assertTrue(okPreview);
        vm.prank(m);
        (uint256 got, uint256 spent) = p.mintPostWithBnb{value: 1 ether}(t, 10, out, address(0));
        assertEq(got, out);
        assertEq(spent, paid + fee);

        address holder = address(uint160(0xA0001));
        uint256 owed = SharedDividendVault(sh[1]).pending(t, holder);
        emit log_named_uint("holder pending (WBNB wei)", owed);
        if (owed > 0) {
            vm.prank(holder);
            SharedDividendVault(sh[1]).claim(t);
        }
        // platform fees landed in the live bucket and the live keeper can push them through the live burner
        uint256 acc = SharedPlatformFeeBucket(sh[2]).accruedQuote(M.WBNB);
        assertGt(acc, bucketAcc0);
        vm.prank(M.KEEPER);
        SharedPlatformFeeBucket(sh[2]).collectPlatform(M.WBNB, 1);
        // vault WBNB only grew by this token's holders' quote, minus what the holder claimed
        assertGe(IERC20(M.WBNB).balanceOf(sh[1]) + owed, vaultWbnb0);
    }

    function _cfg(uint16 devCut) internal pure returns (IFlywheelPad.FlyConfig memory) {
        return IFlywheelPad.FlyConfig({
            raiseBnb: 3 ether,
            baseQuota: 10,
            inviteBonus: 0,
            maxPerTx: 10,
            holdBps: 6_000,
            mintFeeBps: 100,
            exitFeeBps: 100,
            devCutBps: devCut,
            buyBps: 0,
            sellTaxBps: 100,
            launchDelay: 0,
            window: 300,
            windowCapMul: 1,
            postMint: true,
            tierMode: 1,
            stepBps: 0,
            stepShares: 0,
            maxMulX100: 0,
            supplyCapMul: 10,
            guardBps: 0,
            twapWindow: 1800
        });
    }

    function _cfgV1() internal pure returns (IFlywheelPadV1.FlyConfigV1 memory) {
        return IFlywheelPadV1.FlyConfigV1({
            raiseBnb: 3 ether,
            baseQuota: 10,
            inviteBonus: 0,
            maxPerTx: 10,
            holdBps: 6_000,
            mintFeeBps: 100,
            exitFeeBps: 100,
            devCutBps: 0,
            buyBps: 0,
            sellTaxBps: 100,
            launchDelay: 0,
            window: 300,
            windowCapMul: 1,
            postMint: true,
            tierMode: 1,
            stepBps: 0,
            stepShares: 0,
            maxMulX100: 0,
            supplyCapMul: 10
        });
    }
}
