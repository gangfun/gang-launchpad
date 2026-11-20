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
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangAgentWindow} from "../../src/gang/interfaces/IGangAgentWindow.sol";
import {Pad3VanitySalt} from "../../script/Pad3VanitySalt.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {FlyUpgradeHarness} from "./Pad3LiveUpgrade.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";

interface IWBNBWin {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

/// @notice The agent window on a mainnet fork (docs/SPEC-AGENT-WINDOW-2026-11-20.md): UpgradeGangLaunchpad3 run
///         against the live proxy (its checks and simulation, `_checkAgentWindow` included), the upgrade sent as the
///         Safe, the registry upgraded to this build as the Safe; the newest live tokens are still agent only with
///         their cap. Then a token with a 60-minute window is created through createWithSalt: inside the window a
///         wallet without an Agent ID is refused (pad and registry), an Agent buys under the 1% cap; at `openAt` the
///         same wallet buys (the registry quotes it to the wei) and one buy takes it to graduation on the real
///         Pancake V2 pair. Agent IDs are mocked per address on this fork only. No broadcast.
/// @dev BSC_RPC_URL required (skipped if absent); BSC_FORK_BLOCK optional. Link the live PoolCheck:
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract Pad3AgentWindowForkTest is Test {
    address internal constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address internal constant PAD1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address internal constant ROUTER3 = 0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7;
    uint16 internal constant MINUTES = 60;

    GangLaunchpad3 internal p = GangLaunchpad3(payable(PAD3));
    Pad3Module internal m = Pad3Module(payable(PAD3));
    IGangAgentWindow internal w = IGangAgentWindow(PAD3);
    GangPadRegistry internal reg = GangPadRegistry(M.PAD_REGISTRY);
    uint256 internal _n;

    function test_fork_upgradeCreateOpenGraduate() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        address factory = m.vanityDeployer();
        assertTrue(factory != address(0), "abcd is live on mainnet");
        uint256 before = p.tokenCount();
        address oldToken = p.allTokens(before - 1);

        // the script: deploys this build, checks it, simulates the upgrade (with `_checkAgentWindow`)
        (, uint256 key) = makeAddrAndKey("agent window fork deployer");
        vm.deal(vm.addr(key), 10 ether);
        _env(key);
        FlyUpgradeHarness upgrade = new FlyUpgradeHarness();
        vm.pauseGasMetering();
        upgrade.run();
        vm.resumeGasMetering();
        address next = upgrade.deployedImpl();
        assertTrue(next != address(0));

        // the Safe's upgrade: only the implementation slot moves
        vm.record();
        vm.prank(M.OWNER_SAFE);
        ProxyAdmin(R.adminOf(PAD3)).upgradeAndCall(ITransparentUpgradeableProxy(PAD3), next, "");
        (, bytes32[] memory writes) = vm.accesses(PAD3);
        assertEq(writes.length, 1, "only the implementation slot");
        assertEq(writes[0], R.IMPLEMENTATION_SLOT);
        assertEq(p.owner(), M.OWNER_SAFE);
        assertEq(p.tokenCount(), before);

        // and the registry, to this build (its storage is untouched: one function changed)
        address regImpl = address(new GangPadRegistry());
        vm.prank(M.OWNER_SAFE);
        ProxyAdmin(R.adminOf(M.PAD_REGISTRY)).upgradeAndCall(ITransparentUpgradeableProxy(M.PAD_REGISTRY), regImpl, "");

        // live tokens: agent only, cap as before
        assertEq(w.MAX_AGENT_WINDOW_MINUTES(), 1440);
        assertEq(w.agentOpenAt(oldToken), 0);
        if (p.kindOf(oldToken) == 1) assertEq(w.walletCapOn(oldToken), p.walletCapEnabled());

        // a token with a 60-minute window, through createWithSalt (direct create is refused with abcd on)
        address creator = _actor(true);
        vm.prank(creator, creator);
        w.setNextAgentWindow(MINUTES);
        address t = _saltCreate(creator, factory);
        uint40 openAt = w.agentOpenAt(t);
        assertEq(openAt, block.timestamp + uint256(MINUTES) * 60);
        assertEq(w.nextAgentWindowOf(creator), 0);

        // inside the window: a wallet without an Agent ID is refused, an Agent buys under the cap
        address human = _actor(false);
        assertFalse(p.isAgent(human));
        (uint256 q,,,) = reg.previewBuy(t, human, 0.1 ether);
        assertEq(q, 0, "registry: no quote for a human");
        _wrap(human, 0.1 ether);
        vm.prank(human, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        p.buy(t, 0.1 ether, 0);
        address agent = _actor(true);
        _wrap(agent, 1 ether);
        vm.prank(agent, agent);
        assertEq(p.buy(t, 1 ether, 0), p.MAX_PER_WALLET(), "the 1% cap in the window");

        // at openAt: the human buys, as the registry quotes it, past 1%
        vm.warp(openAt);
        assertTrue(w.agentWindowOpen(t));
        assertFalse(w.walletCapOn(t));
        (q,,,) = reg.previewBuy(t, human, 0.1 ether);
        vm.prank(human, human);
        uint256 out = p.buy(t, 0.1 ether, 0);
        assertEq(out, q, "registry quote = the buy");
        assertGt(out, p.MAX_PER_WALLET(), "no cap once open");

        // one buy takes it to graduation on the real Pancake V2 pair
        _wrap(human, 10 ether);
        vm.prank(human, human);
        p.buy(t, 10 ether, 0);
        (,, address pair,,) = p.getTokenInfo(t);
        assertTrue(pair != address(0), "graduated");
        assertGt(IERC20(t).balanceOf(pair), 0);
        assertGt(IERC20(M.WBNB).balanceOf(pair), 0);
    }

    function _saltCreate(address creator, address factory) internal returns (address t) {
        bytes32 hash = Pad3VanityDeployer(factory).tokenInitCodeHash("Win", "WIN", "meta", address(0), 0, 0, false);
        (bytes32 salt, address expected) = Pad3VanitySalt.find(factory, creator, hash);
        IGangLaunchpad.TaxConfig memory none;
        bytes memory data = abi.encodeCall(
            GangLaunchpad3.createWithGradTarget, ("Win", "WIN", "", "meta", address(0), address(0), none, 6 ether)
        );
        vm.prank(creator, creator);
        t = m.createWithSalt(salt, data);
        assertEq(t, expected);
    }

    /// @dev A fresh wallet; `agent`: its Agent ID mocked on this fork (the registry's other answers are the real ones).
    function _actor(bool agent) internal returns (address a) {
        a = makeAddr(string.concat("agent window fork actor ", vm.toString(_n++)));
        vm.deal(a, 20 ether);
        if (agent) {
            vm.mockCall(address(p.agentIdRegistry()), abi.encodeCall(IERC721.balanceOf, (a)), abi.encode(uint256(1)));
        }
    }

    function _wrap(address who, uint256 amt) internal {
        vm.startPrank(who, who);
        IWBNBWin(M.WBNB).deposit{value: amt}();
        IWBNBWin(M.WBNB).approve(PAD3, type(uint256).max);
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
        vm.setEnv("PAD3_GRAD_REWARD", "false");
        vm.setEnv("PAD3_GRAD_HANDLER_ADMIN", vm.toString(address(0)));
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
