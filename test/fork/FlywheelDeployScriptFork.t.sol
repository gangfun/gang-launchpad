// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {DeployFlywheel} from "../../script/DeployFlywheel.s.sol";
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
        return _acceptJson(Shared(sh[0], sh[1], sh[2], sh[3], sh[4]), Own(o[0], o[1], o[2]), true, safe, [true, true, true], true);
    }
}

interface IPancakeRouterA {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256, address[] calldata, address, uint256)
        external
        payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256, uint256, address[] calldata, address, uint256)
        external;
}

/// @notice Pre-mainnet audit C (2026-10-30): runs the real DeployFlywheel script (both phases) on a BSC mainnet fork
///         with a throwaway key, executes the Safe batches exactly as encoded, then a full life on the live shared
///         contracts. No broadcast. One test: the script reads process-wide env vars, and tests run in parallel.
contract FlywheelDeployScriptForkTest is Test {
    address constant GANG_PAD = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant PAD_REGISTRY = 0x4fF77D4d9ac080939a24E1B805206bA094C44e5C;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;

    DeployFlywheelHarness s;
    address me;
    address[5] sh;
    address[3] o;

    function _execAsSafe(string memory json, uint256 count) internal {
        assertEq(vm.parseJsonString(json, ".chainId"), "56");
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), SAFE);
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

    function _expectNotWired(string memory what) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployFlywheel.NotWired.selector, what));
        s.run();
    }

    function test_fork_deployScriptMainnetPathThenLife() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        uint256 pk = uint256(keccak256("flywheel deploy-script fork test: throwaway, never funded"));
        me = vm.addr(pk);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("GANG_PAD", vm.toString(GANG_PAD));
        vm.setEnv("GANG_PAD_REGISTRY", vm.toString(PAD_REGISTRY));
        vm.setEnv("FLYWHEEL_PAD", vm.toString(address(0)));
        vm.setEnv("FLYWHEEL_ALLOW_OVERRIDE", "false");
        s = new DeployFlywheelHarness();
        IGangPadSharedA live = IGangPadSharedA(GANG_PAD);
        sh = [live.quoteRegistry(), live.dividendVault(), live.platformBucket(), live.migrator(), PAD_REGISTRY];
        uint64 n = vm.getNonce(me);
        o = [vm.computeCreateAddress(me, n), vm.computeCreateAddress(me, n + 1), vm.computeCreateAddress(me, n + 2)];

        // audit C-2: mainnet inputs are pinned
        vm.setEnv("OWNER", vm.toString(me));
        _expectNotWired("OWNER is not the platform Safe");
        vm.setEnv("OWNER", vm.toString(SAFE));
        vm.setEnv("KEEPER", vm.toString(me));
        _expectNotWired("KEEPER is not the platform keeper");
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
        FlywheelTaxHandler h = FlywheelTaxHandler(o[1]);
        assertEq(h.keeper(), M.KEEPER);
        assertEq(address(h.dexRouter()), M.PANCAKE_V2_ROUTER);
        assertEq(address(p.agentIdRegistry()), M.AGENT_ID_REGISTRY);
        assertEq(p.v3Factory(), M.PANCAKE_V3_FACTORY);
        assertTrue(GangPadRegistry(PAD_REGISTRY).isPad(o[2]));
        assertEq(SharedDividendVault(sh[1]).minimumShareBalanceOf(GANG_PAD), 10_000 ether, "live pad untouched");
        assertEq(SharedDividendVault(sh[1]).minimumShareBalanceOf(o[2]), 1_000 ether);

        // audit C-4: phase 2 re-runs after the Safe accepted (self-check only)
        s.run();

        // a full life on the live shared contracts
        MockAgentId agents = new MockAgentId();
        vm.prank(SAFE);
        p.setAgentGate(true, address(agents)); // the soulbound live registry can't be minted on a fork

        uint256 vaultWbnb0 = IERC20(M.WBNB).balanceOf(sh[1]);
        uint256 bucketAcc0 = SharedPlatformFeeBucket(sh[2]).accruedQuote(M.WBNB);

        address dev = makeAddr("dev");
        agents.mint(dev, 1);
        vm.deal(dev, 10 ether);
        vm.startPrank(dev);
        (bool ok,) = M.WBNB.call{value: 1 ether}(abi.encodeWithSignature("deposit()"));
        require(ok);
        IERC20(M.WBNB).approve(o[2], type(uint256).max);
        IFlywheelPad.FlyConfig memory c = _cfg(1_000);
        c.baseQuota = 100;
        c.sellTaxBps = 200;
        c.buyBps = 3_000;
        address t = p.create(["Life", "LIFE", "", ""], address(0), address(0), c, 10);
        vm.stopPrank();
        for (uint256 i = 1; p.sales(t).sold < 3_000; i++) {
            address w = address(uint160(0xA0000 + i));
            agents.mint(w, 100 + i);
            vm.deal(w, 1 ether);
            vm.startPrank(w);
            while (p.quotaLeft(t, w) > 0 && p.sales(t).sold < 3_000) p.mintWithBnb{value: 0.01 ether}(t, 10, 1, dev);
            vm.stopPrank();
        }
        uint256 g = gasleft();
        vm.prank(dev);
        p.openEarly(t); // launchDelay 0: launches in the same tx through the LIVE migrator
        emit log_named_uint("gas: openEarly + launch (live migrator)", g - gasleft());
        assertTrue(p.sales(t).launched);

        vm.warp(block.timestamp + 400);
        vm.roll(block.number + 1);
        address trader = makeAddr("trader");
        vm.deal(trader, 5 ether);
        vm.prank(trader);
        IPancakeRouterA(M.PANCAKE_V2_ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 1 ether}(
            0, _path(M.WBNB, t), trader, block.timestamp
        );
        vm.roll(block.number + 1);
        uint256 bal = IERC20(t).balanceOf(trader);
        vm.startPrank(trader);
        IERC20(t).approve(M.PANCAKE_V2_ROUTER, bal);
        IPancakeRouterA(M.PANCAKE_V2_ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(
            bal / 2, 0, _path(t, M.WBNB), trader, block.timestamp
        );
        vm.stopPrank();
        vm.roll(block.number + 1);
        uint256 chunk = h.maxChunk(t);
        if (chunk > 0) {
            vm.prank(M.KEEPER);
            h.process(t, chunk, 1);
        }
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
            supplyCapMul: 10
        });
    }
}
