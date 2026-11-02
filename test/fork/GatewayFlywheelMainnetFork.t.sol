// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {GangGateway} from "../../src/router/GangGateway.sol";
import {IGangGateway} from "../../src/router/interfaces/IGangGateway.sol";
import {GangFlywheelPad} from "../../src/flywheel/GangFlywheelPad.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangGatewayDeployLib as G} from "../../script/GangGatewayDeployLib.sol";
import {GatewayAdapter} from "../router/GangGateway.t.sol";

/// @notice GangGateway V2 (铸币飞轮 support, AUDIT-BRIEF §26) on a BSC mainnet fork: the live proxy upgraded the way
///         the Safe will do it (timelock.schedule → 48 h → execute of ProxyAdmin.upgradeAndCall), the read-back
///         self-check against this build, then listed by the Safe on both flywheel pads. On live V1 and V2 sales:
///         a pre-launch buy and sell-back and a post-launch buy through an aggregator-style adapter, each matching
///         tryBuy / trySell to the wei; and a live curve token on GangLaunchpad 1.0 still trades as before. The
///         trader's Agent ID is mocked (balanceOf = 1).
/// @dev Needs BSC_RPC_URL (without it every test is skipped).
contract GatewayFlywheelMainnetForkTest is Test {
    GangGateway gw;
    G.Gateway stack;
    GatewayAdapter adapter;
    address user = makeAddr("fork-fly-user");
    address feeTo = makeAddr("fork-fly-feeTo");

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        stack = G.load(M.GANG_GATEWAY);
        address impl = address(new GangGateway());
        bytes memory call =
            abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(stack.proxy), impl, bytes("")));
        TimelockController tl = TimelockController(payable(stack.timelock));
        vm.prank(M.OWNER_SAFE);
        tl.schedule(stack.proxyAdmin, 0, call, bytes32(0), bytes32(0), R.MAINNET_MIN_DELAY);
        vm.warp(block.timestamp + R.MAINNET_MIN_DELAY);
        vm.prank(M.OWNER_SAFE);
        tl.execute(stack.proxyAdmin, 0, call, bytes32(0), bytes32(0));
        stack = G.load(M.GANG_GATEWAY);
        gw = GangGateway(payable(stack.proxy));

        vm.startPrank(M.OWNER_SAFE);
        IGangPad(M.FLYWHEEL_PAD_V1).setRouter(address(gw), true);
        IGangPad(M.FLYWHEEL_PAD_V2).setRouter(address(gw), true);
        vm.stopPrank();
        adapter = new GatewayAdapter(IGangGateway(address(gw)), feeTo);
        vm.prank(M.OWNER_SAFE);
        gw.setCaller(address(adapter), true);
        vm.mockCall(
            M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector, user), abi.encode(uint256(1))
        );
        vm.deal(user, 100 ether);
    }

    modifier forkOnly() {
        if (address(gw) == address(0)) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev The newest sale on `pad` that is minting (not filled, gated, with shares left), or launched with
    ///      post-launch minting.
    function _find(address pad, bool launched) internal view returns (address) {
        GangFlywheelPad p = GangFlywheelPad(payable(pad));
        for (uint256 i = p.tokenCount(); i > 0; i--) {
            address t = p.allTokens(i - 1);
            IFlywheelPad.Sale memory s = p.sales(t);
            if (s.gate == address(0)) continue;
            if (launched && s.launched && s.postMint) return t;
            if (!launched && !s.launched && s.filledAt == 0 && s.sold < 9_000) return t;
        }
        return address(0);
    }

    function test_fork_upgradeKeepsTheGateway() public forkOnly {
        G.check(
            stack,
            G.Expect({
                registry: M.PAD_REGISTRY,
                wbnb: M.WBNB,
                safe: M.OWNER_SAFE,
                deployer: address(this),
                minDelay: R.MAINNET_MIN_DELAY,
                mainnet: true
            })
        );
        assertTrue(IGangPad(0x15CFD2dc8278Fb87a1783ef42111618E20874365).routers(address(gw)), "pad 1.0 listing kept");
    }

    function test_fork_curveStillTrades() public forkOnly {
        address pad = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
        address live;
        for (uint256 i = IGangPad(pad).tokenCount(); i > 0 && live == address(0); i--) {
            address t = IGangPad(pad).allTokens(i - 1);
            (uint8 status, address quote,,, uint256 left) = gw.getTokenInfo(t);
            if (status == 1 && quote == address(0) && left > 0.5 ether) live = t;
        }
        if (live == address(0)) return vm.skip(true, "no live BNB curve token on pad 1.0");
        (,, uint256 est,,,,, uint256 amountFunds) = gw.tryBuy(live, user, 0, 0.01 ether);
        assertGt(est, 0);
        vm.prank(user, user);
        (uint256 out, uint256 used) = adapter.buyBnb{value: 0.01 ether}(live, est);
        assertEq(out, est);
        assertEq(used, amountFunds);
    }

    function _preLaunch(address pad) internal {
        address t = _find(pad, false);
        if (t == address(0)) return vm.skip(true, "no minting sale on this pad");
        (uint8 status, address quote,,,) = gw.getTokenInfo(t);
        assertEq(status, 1);
        assertEq(quote, address(0));
        (,, uint256 est, uint256 cost,,,, uint256 amountFunds) = gw.tryBuy(t, user, 0, 1 ether);
        assertGt(est, 0, "pre-launch quote");
        uint256 w0 = IERC20(M.WBNB).balanceOf(user);
        vm.prank(user, user);
        (uint256 out, uint256 used) = adapter.buyBnb{value: 1 ether}(t, est);
        assertEq(out, est, "tokens = quote");
        assertEq(used, cost);
        assertEq(amountFunds, cost);
        assertEq(IERC20(M.WBNB).balanceOf(user) - w0, 1 ether - cost, "refund in WBNB");

        uint256 tps = GangFlywheelPad(payable(pad)).TOKENS_PER_SHARE();
        uint256 amount = (out / tps) * tps;
        (,, uint256 funds,) = gw.trySell(t, amount);
        (uint256 payout,) = GangFlywheelPad(payable(pad)).previewWithdraw(t, user, amount / tps);
        assertEq(funds, payout);
        vm.prank(user);
        IERC20(t).approve(address(gw), amount);
        uint256 b0 = user.balance;
        vm.prank(user, user);
        uint256 got = adapter.sell(t, amount, 0);
        assertEq(got, funds - funds / 100, "after the adapter's 1% fee");
        assertEq(user.balance - b0, got, "BNB through WBNB's 2300-gas transfer");
        assertEq(IERC20(t).balanceOf(user), 0);
        assertEq(IERC20(M.WBNB).balanceOf(address(gw)), 0);
        assertEq(address(gw).balance, 0);
    }

    function test_fork_v1_preLaunch() public forkOnly {
        _preLaunch(M.FLYWHEEL_PAD_V1);
    }

    function test_fork_v2_preLaunch() public forkOnly {
        _preLaunch(M.FLYWHEEL_PAD_V2);
    }

    /// @param mustQuote the sale was driven to launch here: no quote is a failure, not a skip
    function _postLaunch(address pad, address t, bool mustQuote) internal {
        (uint8 status,, address pair,,) = gw.getTokenInfo(t);
        assertEq(status, 2);
        assertEq(pair, GangFlywheelPad(payable(pad)).sales(t).pair);
        (,, uint256 est, uint256 cost,,,,) = gw.tryBuy(t, user, 0, 0.05 ether);
        // the pad's guards may refuse mints right now (price, supply cap): then the buy must revert
        if (est == 0) {
            assertFalse(mustQuote, "no post-launch quote on a sale launched here");
            vm.prank(user, user);
            vm.expectRevert();
            adapter.buyBnb{value: 0.05 ether}(t, 0);
            return vm.skip(true, "post-launch mints refused right now");
        }
        uint256 tokens0 = IERC20(t).balanceOf(user);
        uint256 w0 = IERC20(M.WBNB).balanceOf(user);
        vm.prank(user, user);
        (uint256 out, uint256 used) = adapter.buyBnb{value: 0.05 ether}(t, est);
        assertEq(out, est, "tokens = quote");
        assertEq(used, cost);
        assertEq(IERC20(t).balanceOf(user) - tokens0, out);
        assertEq(IERC20(M.WBNB).balanceOf(user) - w0, 0.05 ether - cost, "change back in WBNB");
        assertEq(IERC20(M.WBNB).allowance(address(gw), pad), 0, "no approval left");
        assertEq(IERC20(M.WBNB).balanceOf(address(gw)), 0);
        // sells are the pair's
        (,, uint256 funds,) = gw.trySell(t, out);
        assertEq(funds, 0);
    }

    function test_fork_v1_postLaunch() public forkOnly {
        address t = _find(M.FLYWHEEL_PAD_V1, true);
        if (t == address(0)) return vm.skip(true, "no launched V1 sale with post-launch minting");
        _postLaunch(M.FLYWHEEL_PAD_V1, t, false);
    }

    /// @dev V2 has no launched sale yet: drive the minting V2 sale with the most shares sold to the early-open line
    ///      (30%), open it early and launch it, then buy post-launch at three sizes (audit L-1). Mints come from mocked
    ///      Agent IDs; the vault's per-holder writes are mocked out (each is one more RPC read of the fork).
    function test_fork_v2_postLaunch() public forkOnly {
        GangFlywheelPad p = GangFlywheelPad(payable(M.FLYWHEEL_PAD_V2));
        address t = _find(M.FLYWHEEL_PAD_V2, true);
        bool driven = t == address(0);
        if (driven) {
            uint256 best;
            for (uint256 i = p.tokenCount(); i > 0; i--) {
                address c = p.allTokens(i - 1);
                IFlywheelPad.Sale memory cs = p.sales(c);
                if (!cs.launched && cs.filledAt == 0 && cs.postMint && cs.gate != address(0) && cs.sold >= best) {
                    (t, best) = (c, cs.sold);
                }
            }
            if (t == address(0)) return vm.skip(true, "no V2 sale with post-launch minting");
            IFlywheelPad.Sale memory s = p.sales(t);
            vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
            address vault = 0x1BDBDD73f51079c64BCA3917629c84c257921aCc;
            vm.mockCall(vault, abi.encodeWithSignature("setShare(address,address,uint256)"), "");
            for (uint256 i; p.sales(t).sold < 3_000; i++) {
                address w = address(uint160(uint256(keccak256(abi.encode("fork-fly-minter", i)))));
                vm.deal(w, 1 ether);
                vm.prank(w);
                p.mintWithBnb{value: 1 ether}(t, s.maxPerTx, 1, address(0));
            }
            vm.clearMockedCalls();
            vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
            vm.prank(s.creator);
            p.openEarly(t);
            vm.warp(block.timestamp + s.launchDelay);
            if (!p.sales(t).launched) p.launch(t);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 3);
        }
        _postLaunch(M.FLYWHEEL_PAD_V2, t, driven);
        // smaller sizes on the sale launched here (its first post-launch shares cost about the pre-launch price)
        if (!driven) return;
        uint256[2] memory sizes = [uint256(0.003 ether), 0.01 ether];
        for (uint256 k; k < sizes.length; k++) {
            address u = address(uint160(uint256(keccak256(abi.encode("fork-fly-buyer", k)))));
            vm.deal(u, 1 ether);
            (,, uint256 est, uint256 cost,,,,) = gw.tryBuy(t, u, 0, sizes[k]);
            assertGt(est, 0);
            vm.prank(u, u);
            (uint256 out, uint256 used) = adapter.buyBnb{value: sizes[k]}(t, est);
            assertEq(out, est);
            assertEq(used, cost);
        }
        assertEq(IERC20(M.WBNB).balanceOf(address(gw)), 0);
    }
}
