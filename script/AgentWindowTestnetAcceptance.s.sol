// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../src/gang/Pad3VanityDeployer.sol";
import {GangPadRegistry} from "../src/gang/GangPadRegistry.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangAgentWindow} from "../src/gang/interfaces/IGangAgentWindow.sol";
import {Pad3VanitySalt} from "./Pad3VanitySalt.sol";

/// @dev A trader with no Agent ID: a contract the deployer owns, holding the quote it is sent.
contract WindowTestTrader {
    address public immutable owner;

    constructor() {
        owner = msg.sender;
    }

    function buy(GangLaunchpad3 pad, IERC20 quote, address token, uint256 amount) external returns (uint256) {
        require(msg.sender == owner, "owner");
        quote.approve(address(pad), amount);
        return pad.buy(token, amount, 0);
    }

    function sell(GangLaunchpad3 pad, address token, uint256 amount) external returns (uint256) {
        require(msg.sender == owner, "owner");
        IERC20(token).approve(address(pad), amount);
        return pad.sell(token, amount, 0);
    }

    function sweep(IERC20 t, address to) external {
        require(msg.sender == owner, "owner");
        t.transfer(to, t.balanceOf(address(this)));
    }
}

/// @notice BSC testnet acceptance of the agent window (docs/SPEC-AGENT-WINDOW-2026-11-20.md), in two runs:
///         PHASE=1: the deployer (an Agent) creates a token in WINDOW_QUOTE with a 1-minute window through
///         createWithAgentWindow(createWithSalt(createWithGradTarget …)) (abcd is on there) and deploys a trader
///         contract (no Agent ID). Inside the window: the Agent's buy is capped at 1%; the trader's buy is refused
///         (simulated), the pad and the registry quote it 0 and `canTradeCurve` is false. The newest token created
///         before the upgrade (OLD_TOKEN) has no window.
///         PHASE=2 (TOKEN, TRADER; run once `agentOpenAt(TOKEN)` has passed): the trader buys past 1% at exactly the
///         registry's quote, sells part back, then one buy graduates the token (the Pancake pair is created);
///         OLD_TOKEN still refuses the trader (simulated).
/// @dev Env: DEPLOYER_PRIVATE_KEY, GANG_PAD3, GANG_PAD_REGISTRY, WINDOW_QUOTE (an 18-decimal listed quote the deployer
///      holds; phase 2 sends the trader up to 8 of it), OLD_TOKEN (a curve token created before the upgrade), PHASE;
///      phase 2 also TOKEN and TRADER (from phase 1's log). Not idempotent: phase 1 creates a new token each run.
contract AgentWindowTestnetAcceptance is Script {
    string internal constant NAME = "Agent Window Test";
    string internal constant SYMBOL = "AWT";
    uint256 internal constant GRAD = 6 ether;
    uint16 internal constant WINDOW = 1;

    error Check(string what);

    function run() external {
        require(block.chainid == 97, "testnet only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        GangLaunchpad3 p = GangLaunchpad3(payable(vm.envAddress("GANG_PAD3")));
        GangPadRegistry reg = GangPadRegistry(vm.envAddress("GANG_PAD_REGISTRY"));
        IERC20 q = IERC20(vm.envAddress("WINDOW_QUOTE"));
        address old = vm.envAddress("OLD_TOKEN");
        IGangAgentWindow w = IGangAgentWindow(address(p));
        if (w.MAX_AGENT_WINDOW_MINUTES() != 1440) revert Check("pad does not serve the agent window");
        if (!p.agentGateEnabled() || !p.walletCapEnabled()) revert Check("gate and cap must be on");
        if (w.agentOpenAt(old) != 0 || p.kindOf(old) != 1) revert Check("OLD_TOKEN: a curve token with no window");
        if (vm.envUint("PHASE") == 1) _phase1(pk, p, reg, q, w, old);
        else _phase2(pk, p, reg, q, w, old);
    }

    function _phase1(uint256 pk, GangLaunchpad3 p, GangPadRegistry reg, IERC20 q, IGangAgentWindow w, address old)
        internal
    {
        address dev = vm.addr(pk);
        if (!p.isAgent(dev)) revert Check("the deployer must be an Agent");
        address factory = Pad3Module(payable(address(p))).vanityDeployer();
        if (factory == address(0)) revert Check("abcd not on");
        bytes32 hash = Pad3VanityDeployer(factory).tokenInitCodeHash(NAME, SYMBOL, "", address(0), 0, 0, false);
        (bytes32 salt, address expected) = Pad3VanitySalt.find(factory, dev, hash);
        IGangLaunchpad.TaxConfig memory none;
        bytes memory inner = abi.encodeCall(
            GangLaunchpad3.createWithGradTarget, (NAME, SYMBOL, "", "", address(q), address(0), none, GRAD)
        );
        bytes memory data = abi.encodeCall(Pad3Module.createWithSalt, (salt, inner));

        vm.startBroadcast(pk);
        address t = w.createWithAgentWindow(WINDOW, data);
        WindowTestTrader trader = new WindowTestTrader();
        q.approve(address(p), 0.05 ether);
        uint256 out = p.buy(t, 0.05 ether, 0);
        q.transfer(address(trader), 0.05 ether);
        vm.stopBroadcast();

        if (t != expected) revert Check("token address");
        uint40 openAt = w.agentOpenAt(t);
        if (openAt < block.timestamp + 60 || openAt > block.timestamp + 60 + 3600) revert Check("openAt");
        if (out != p.MAX_PER_WALLET()) revert Check("the Agent's buy is capped at 1% in the window");
        if (!w.walletCapOn(t) || w.agentWindowOpen(t)) revert Check("in the window: capped, not open");
        _refused(p, reg, w, q, trader, t, "window");
        _refused(p, reg, w, q, trader, old, "old token");
        console.log("token", t);
        console.log("trader", address(trader));
        console.log("openAt", openAt);
        console.log("ok: phase 1 (window token created, Agent capped, trader refused; old token agent only)");
    }

    function _phase2(uint256 pk, GangLaunchpad3 p, GangPadRegistry reg, IERC20 q, IGangAgentWindow w, address old)
        internal
    {
        address t = vm.envAddress("TOKEN");
        WindowTestTrader trader = WindowTestTrader(vm.envAddress("TRADER"));
        if (!w.agentWindowOpen(t)) revert Check("not open yet: wait for agentOpenAt");
        if (w.walletCapOn(t) || !w.canTradeCurve(t, address(trader))) revert Check("open: no cap, trader allowed");
        (uint256 quoted,,,) = reg.previewBuy(t, address(trader), 0.04 ether);
        (,,,, uint256 left) = p.getTokenInfo(t);

        vm.startBroadcast(pk);
        uint256 out = trader.buy(p, q, t, 0.04 ether);
        uint256 back = trader.sell(p, t, out / 4);
        q.transfer(address(trader), left + 1 ether);
        trader.buy(p, q, t, left + 1 ether);
        trader.sweep(q, vm.addr(pk));
        vm.stopBroadcast();

        if (out != quoted || out == 0) revert Check("the trader's buy = the registry's quote");
        if (IERC20(t).balanceOf(address(trader)) <= p.MAX_PER_WALLET()) revert Check("past 1% once open");
        if (back == 0) revert Check("the trader sold");
        (,, address pair,,) = p.getTokenInfo(t);
        if (pair == address(0)) revert Check("graduated: the pair");
        if (IERC20(t).balanceOf(pair) == 0 || q.balanceOf(pair) == 0) revert Check("the pair holds both sides");
        _refused(p, reg, w, q, trader, old, "old token");
        console.log("pair", pair);
        console.log("ok: phase 2 (trader bought past 1% at the registry quote, sold, graduated; old token agent only)");
    }

    /// @dev `trader` (no Agent ID) can't trade `t`: no quote from the pad or the registry, and its buy reverts NotAgent
    ///      (simulated only, never broadcast).
    function _refused(
        GangLaunchpad3 p,
        GangPadRegistry reg,
        IGangAgentWindow w,
        IERC20 q,
        WindowTestTrader trader,
        address t,
        string memory what
    ) internal {
        if (w.canTradeCurve(t, address(trader))) {
            revert Check(string.concat(what, ": canTradeCurve"));
        }
        (uint256 r,,,) = reg.previewBuy(t, address(trader), 0.01 ether);
        (,, uint256 est,,,,,) = p.tryBuy(t, address(trader), 0, 0.01 ether);
        if (r != 0 || est != 0) revert Check(string.concat(what, ": quoted"));
        vm.prank(trader.owner());
        try trader.buy(p, q, t, 0.01 ether) {
            revert Check(string.concat(what, ": the trader's buy went through"));
        } catch (bytes memory e) {
            if (bytes4(e) != IGangLaunchpad.NotAgent.selector) revert Check(string.concat(what, ": wrong revert"));
        }
    }
}
