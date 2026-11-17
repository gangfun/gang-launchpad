// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3GradStore} from "../../src/gang/Pad3GradStore.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangGradReward, IGangGradRewardBase} from "../../src/gang/interfaces/IGangGradReward.sol";
import {Pad3VanitySalt} from "../../script/Pad3VanitySalt.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {FlyUpgradeHarness} from "./Pad3LiveUpgrade.sol";
import {DeployGang} from "../../script/DeployGang.s.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";

/// @dev The Safe batch JSON the script prints (its `_batchJson`), for the run that deploys nothing.
contract GradBatchHarness is FlyUpgradeHarness {
    function batchJson(address admin, bytes memory call, address proxy) external view returns (string memory) {
        return _batchJson(true, M.OWNER_SAFE, new address[](0), new bytes[](0), admin, call, proxy);
    }
}

interface IWBNBFork {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

/// @notice The graduation reward on a mainnet fork (docs/SPEC-GRAD-REWARD-2026-11-17.md): UpgradeGangLaunchpad3 run
///         against the live proxy with PAD3_GRAD_REWARD (its checks and simulation), its batch sent as the Safe (the
///         upgrade, then `setGradReward`), then a reward token created through createWithSalt and bought to
///         graduation by fresh Agents under the 1% cap (one of the last buyers sells part back), migrated to the real
///         Pancake V2 pair; every buyer on the list claims, the sum stays within the payout, and the sweep sends the
///         dust to the dev. Agent IDs are mocked only on this fork. No broadcast.
/// @dev BSC_RPC_URL required (skipped if absent); BSC_FORK_BLOCK optional. Link the live PoolCheck:
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract Pad3GradRewardForkTest is Test {
    address internal constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address internal constant PAD1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address internal constant ROUTER3 = 0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7;
    /// @dev 3.0's GangHandlerAdmin (docs/MAINNET-GANG-LAUNCHPAD-3-MODULES-2026-11-03.md)
    address internal constant ADMIN3 = 0xC833CEC2B283759003945C0Bf8C048aB1949Af76;
    uint128 internal constant SEED = 0.5 ether;
    uint8 internal constant ENTRIES = 10;

    GangLaunchpad3 internal p = GangLaunchpad3(payable(PAD3));
    Pad3Module internal m = Pad3Module(payable(PAD3));
    IGangGradReward internal g = IGangGradReward(PAD3);
    uint256 internal _n;

    function test_fork_upgradeOpenCreateGraduateClaim() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        address factory = m.vanityDeployer();
        assertTrue(factory != address(0), "abcd is live on mainnet");

        // the script: deploys this build, checks it, simulates upgrade + setGradReward (mainnet: prints no batch)
        (, uint256 key) = makeAddrAndKey("grad fork deployer");
        vm.deal(vm.addr(key), 10 ether);
        _env(key);
        GradBatchHarness upgrade = new GradBatchHarness();
        vm.pauseGasMetering();
        UpgradeGangLaunchpad3.Stack memory st = upgrade.run();
        vm.resumeGasMetering();
        address next = upgrade.deployedImpl();
        assertTrue(next != address(0));
        // the batch below is built with no 铸币飞轮 listings: there are none left to send on mainnet
        (address[] memory prepTo,) = upgrade.prep(st, M.KEEPER, M.OWNER_SAFE);
        assertEq(prepTo.length, 0, "no fly listings in the batch");

        // the read-only re-run over the deployed implementation (the one that prints the batch the Safe signs)
        vm.setEnv("PAD3_IMPL", vm.toString(next));
        vm.pauseGasMetering();
        upgrade.run();
        vm.resumeGasMetering();
        address admin = R.adminOf(PAD3);
        string memory json = upgrade.batchJson(
            admin, abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(PAD3), next, "")), PAD3
        );
        assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), admin);
        assertEq(vm.parseJsonAddress(json, ".transactions[1].to"), PAD3);
        assertEq(
            vm.parseJsonBytes(json, ".transactions[1].data"),
            abi.encodeCall(Pad3Module.setGradReward, (true, ADMIN3, address(0))),
            "the opening, last"
        );
        assertFalse(vm.keyExistsJson(json, ".transactions[2]"));

        // the Safe sends it: the upgrade (only the implementation slot), then the opening (only the namespace)
        vm.record();
        _send(json, 0);
        (, bytes32[] memory writes) = vm.accesses(PAD3);
        assertEq(writes.length, 1, "only the implementation slot");
        assertEq(writes[0], R.IMPLEMENTATION_SLOT);
        assertEq(R.implementationOf(PAD3), next);
        (bool open,,) = g.gradRewardDeps();
        assertFalse(open, "closed after the upgrade alone");
        vm.record();
        _send(json, 1);
        (, writes) = vm.accesses(PAD3);
        for (uint256 i; i < writes.length; i++) {
            assertTrue(
                writes[i] == Pad3GradStore.SLOT || writes[i] == bytes32(uint256(Pad3GradStore.SLOT) + 1),
                "only the layout's first two words"
            );
        }
        (bool open2, address a2, address f2) = g.gradRewardDeps();
        assertTrue(open2 && a2 == ADMIN3 && f2 == address(0));
        // a later run with PAD3_GRAD_REWARD again is refused: never over what the Safe set since
        vm.setEnv("PAD3_IMPL", vm.toString(address(0)));
        GradBatchHarness again = new GradBatchHarness();
        vm.expectRevert(
            abi.encodeWithSelector(DeployGang.WiringCheck.selector, "grad reward already set: omit PAD3_GRAD_REWARD")
        );
        again.run();
        assertEq(p.owner(), M.OWNER_SAFE);
        assertEq(m.vanityDeployer(), factory);

        _createGraduateClaim(factory);
    }

    /// @notice The Safe batch written for signing (PAD3_FORK_BATCH = docs/MAINNET-GANG-LAUNCHPAD-3-UPGRADE-GRAD-SAFE-BATCH-
    ///         2026-11-17.json), as written, over the deployed mainnet contracts: exactly the upgrade, then the opening;
    ///         then a reward token bought to graduation and claimed.
    function test_fork_signedBatchThenGrad() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        string memory path = vm.envOr("PAD3_FORK_BATCH", string(""));
        if (bytes(rpc).length == 0 || bytes(path).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        address factory = m.vanityDeployer();
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonString(json, ".chainId"), "56");
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), M.OWNER_SAFE);
        assertFalse(vm.keyExistsJson(json, ".transactions[2]"), "two calls");
        address admin = R.adminOf(PAD3);
        assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), admin);
        assertEq(vm.parseJsonString(json, ".transactions[0].value"), "0");
        assertEq(vm.parseJsonAddress(json, ".transactions[1].to"), PAD3);
        assertEq(vm.parseJsonString(json, ".transactions[1].value"), "0");
        bytes memory up = vm.parseJsonBytes(json, ".transactions[0].data");
        (address proxy, address next, bytes memory init) = abi.decode(_tail(up), (address, address, bytes));
        assertEq(proxy, PAD3);
        assertEq(init.length, 0, "no set-up call");
        assertTrue(next.code.length > 0, "the new implementation is deployed");
        assertEq(
            vm.parseJsonBytes(json, ".transactions[1].data"),
            abi.encodeCall(Pad3Module.setGradReward, (true, ADMIN3, address(0)))
        );
        vm.record();
        _send(json, 0);
        (, bytes32[] memory writes) = vm.accesses(PAD3);
        assertEq(writes.length, 1, "only the implementation slot");
        assertEq(writes[0], R.IMPLEMENTATION_SLOT);
        address impl = R.implementationOf(PAD3);
        assertEq(up, abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(PAD3), impl, bytes(""))));
        _send(json, 1);
        (bool open, address a, address f) = g.gradRewardDeps();
        assertTrue(open && a == ADMIN3 && f == address(0));
        assertEq(p.owner(), M.OWNER_SAFE);
        assertEq(m.vanityDeployer(), factory);
        _createGraduateClaim(factory);
    }

    function _tail(bytes memory data) private pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }

    function _createGraduateClaim(address factory) internal {
        // a reward token, through createWithSalt (direct create is refused with abcd on)
        address creator = _actor();
        IGangGradRewardBase.GradConfig memory cfg = IGangGradRewardBase.GradConfig({
            seed: SEED,
            minBuy: 0.01 ether,
            entries: ENTRIES,
            lastBps: 3_000,
            carryBps: 0,
            refundAfter: 90 days,
            promoteBps: 0,
            promoteWindow: 0
        });
        IGangLaunchpad.TaxConfig memory none;
        vm.startPrank(creator, creator);
        IWBNBFork(M.WBNB).deposit{value: SEED}();
        IWBNBFork(M.WBNB).approve(PAD3, SEED);
        vm.stopPrank();
        address t = _saltCreate(
            creator,
            factory,
            abi.encodeCall(
                IGangGradReward.createWithGradReward,
                ("Grad", "GRAD", "", "meta", address(0), address(0), none, 6 ether, cfg)
            )
        );
        assertEq(g.gradReward(t).pot, SEED);

        // fresh Agents buy under the 1% cap until close; one of the last sells part back; one more graduates it
        address[] memory buyers = new address[](200);
        uint256 nb;
        uint256 left;
        while (true) {
            (,,,, left) = p.getTokenInfo(t);
            if (left < 0.3 ether) break;
            address a = _actor();
            _buy(a, t, 0.25 ether);
            buyers[nb++] = a;
        }
        address seller = buyers[nb - 2];
        vm.startPrank(seller, seller);
        uint256 part = IERC20(t).balanceOf(seller) / 3;
        IERC20(t).approve(PAD3, part);
        p.sell(t, part, 0);
        vm.stopPrank();
        address last;
        address pair;
        while (pair == address(0)) {
            last = _actor();
            _buy(last, t, 1 ether);
            buyers[nb++] = last;
            (,, pair,,) = p.getTokenInfo(t);
        }
        assertTrue(nb >= 80, "the 1% cap: at least 80 buyers");

        IGangGradRewardBase.GradView memory v = g.gradReward(t);
        assertEq(v.state, 2);
        uint256 pay = SEED; // no carry
        uint256 lastShare = (pay * 3_000) / 10_000;
        assertEq(g.gradClaimable(t, seller), 0, "the seller's entry is out");
        uint256 sum;
        for (uint256 i = nb > 12 ? nb - 12 : 0; i < nb; i++) {
            address b = buyers[i];
            uint256 c = g.gradClaimable(t, b);
            if (c == 0) continue;
            uint256 before = IERC20(M.WBNB).balanceOf(b);
            vm.prank(b);
            g.claimGradReward(t);
            assertEq(IERC20(M.WBNB).balanceOf(b) - before, c);
            sum += c;
        }
        v = g.gradReward(t);
        assertEq(v.valid, ENTRIES - 1, "ten on the list, one sold");
        assertEq(v.claimed, sum);
        assertLe(sum, pay);
        assertGe(sum + ENTRIES, pay, "only rounding dust left");
        assertGe(sum, lastShare, "the graduating buy's bonus was paid");

        vm.warp(block.timestamp + 180 days);
        uint256 devBefore = IERC20(M.WBNB).balanceOf(creator);
        g.sweepGradReward(t);
        assertEq(IERC20(M.WBNB).balanceOf(creator) - devBefore, pay - sum);
        assertEq(g.gradReward(t).state, 4);
    }

    function _send(string memory json, uint256 i) internal {
        string memory k = string.concat(".transactions[", vm.toString(i), "]");
        vm.prank(M.OWNER_SAFE);
        (bool ok,) =
            vm.parseJsonAddress(json, string.concat(k, ".to")).call(vm.parseJsonBytes(json, string.concat(k, ".data")));
        assertTrue(ok, "a transaction of the Safe batch");
    }

    function _saltCreate(address creator, address factory, bytes memory data) internal returns (address t) {
        bytes32 hash = Pad3VanityDeployer(factory).tokenInitCodeHash("Grad", "GRAD", "meta", address(0), 0, 0, false);
        (bytes32 salt, address expected) = Pad3VanitySalt.find(factory, creator, hash);
        vm.prank(creator, creator);
        t = m.createWithSalt(salt, data);
        assertEq(t, expected);
    }

    function _actor() internal returns (address a) {
        a = makeAddr(string.concat("grad fork actor ", vm.toString(_n++)));
        vm.deal(a, 10 ether);
    }

    function _buy(address who, address t, uint256 amt) internal {
        vm.startPrank(who, who);
        IWBNBFork(M.WBNB).deposit{value: amt}();
        IWBNBFork(M.WBNB).approve(PAD3, amt);
        p.buy(t, amt, 0);
        vm.stopPrank();
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
        vm.setEnv("PAD3_GRAD_REWARD", "true");
        vm.setEnv("PAD3_GRAD_HANDLER_ADMIN", vm.toString(ADMIN3));
        vm.setEnv("PAD3_GRAD_COUNTDOWN_FACTORY", vm.toString(address(0)));
        vm.setEnv("PAD3_IMPL", vm.toString(address(0)));
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
