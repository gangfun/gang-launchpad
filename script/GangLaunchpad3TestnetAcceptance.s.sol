// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangGateway} from "../src/router/interfaces/IGangGateway.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";

/// @dev An aggregator's adapter as written for four.meme: names its caller as the trader, 1% router fee on sells.
contract Pad3AcceptanceAdapter {
    IGangGateway public immutable entry;
    address public immutable feeTo;

    constructor(IGangGateway entry_, address feeTo_) {
        entry = entry_;
        feeTo = feeTo_;
    }

    function buyBnb(address token, uint256 minAmount) external payable returns (uint256 out, uint256 used) {
        return entry.buyTokenAMAP{value: msg.value}(token, msg.sender, msg.value, minAmount);
    }

    function sell(address token, uint256 amount, uint256 minFunds) external returns (uint256) {
        return entry.sellToken(0, token, msg.sender, amount, minFunds, 100, feeTo);
    }
}

/// @dev An aggregator router's multi-hop: the Gang hop with four.meme's pay-to sell (proceeds to this contract), then
///      the next hop — here, the proceeds handed to its caller.
contract Pad3AcceptanceHop {
    GangLaunchpad3 public immutable entry;

    constructor(GangLaunchpad3 entry_) {
        entry = entry_;
    }

    receive() external payable {}

    function sellThenForward(address token, uint256 amount, uint256 minFunds) external returns (uint256 got) {
        got = entry.sellToken(0, token, msg.sender, address(this), amount, minFunds);
        (bool ok,) = msg.sender.call{value: got}("");
        require(ok, "bnb");
    }
}

/// @title GangLaunchpad3TestnetAcceptance — GangLaunchpad 3.0's entry end to end on BSC testnet, as an aggregator
/// @notice With the deploy wallet (an Agent ID holder, owner of 3.0 and its ProxyAdmin on testnet):
///         1. a WBNB-quoted curve token created on 3.0 (rule version 1, found by the registry);
///         2. an aggregator-style adapter listed as a sell caller;
///         3. for 3.0's token and for a token created on each older pad in OLD_PADS (each must list 3.0 as a router):
///            a buy through the adapter with native BNB (= tryBuy), a quarter sold with the pay-to sell to a listed
///            multi-hop router (proceeds on the router, then handed on), half of the rest sold back through the adapter
///            with a 1% router fee
///            (= trySell, BNB out), the rest sold straight on the entry with no fee. After each step: no BNB left in
///            3.0, no allowance left to the older pad, and, for an older pad's token, 3.0's WBNB (its reserves)
///            unchanged and none of the token held;
///         4. GANG_GATEWAY (optional): the live gateway buys 3.0's token through the registry;
///         5. UPGRADE_REHEARSAL=true: the ProxyAdmin owner upgrades the proxy to a fresh build of the same
///            implementation (same dependencies), and 3.0's token keeps its state and trades on.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, GANG_PAD3, OLD_PADS (comma-separated curve pads: 1.0, 2.0),
///      GANG_GATEWAY (optional), UPGRADE_REHEARSAL (optional). Link as the deploy (forge deploys fresh libraries).
contract GangLaunchpad3TestnetAcceptance is Script {
    error WrongChain(uint256 chainId);
    error Check(string what);

    GangLaunchpad3 p;
    Pad3AcceptanceAdapter adapter;
    Pad3AcceptanceHop hop;
    uint256 pk;
    address me;

    function run() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        me = vm.addr(pk);
        p = GangLaunchpad3(payable(vm.envAddress("GANG_PAD3")));
        if (Ownable(address(p)).owner() != me) revert Check("deploy wallet is not 3.0's owner");
        address[] memory olds = vm.envOr("OLD_PADS", ",", new address[](0));
        for (uint256 i; i < olds.length; i++) {
            if (!IGangPad(olds[i]).routers(address(p))) revert Check("an OLD_PADS pad does not list 3.0");
        }

        vm.startBroadcast(pk);
        address t = _create(address(p), "Pad3 Test", "P3T");
        adapter = new Pad3AcceptanceAdapter(IGangGateway(address(p)), T.DEMO_TREASURY);
        p.setCaller(address(adapter), true);
        hop = new Pad3AcceptanceHop(p);
        p.setCaller(address(hop), true);
        vm.stopBroadcast();
        if (p.tokenVersionOf(t) != 1) revert Check("tokenVersionOf");
        if (p.padRegistry().padOf(t) != address(p)) revert Check("registry padOf");
        if (!p.isCaller(address(adapter))) revert Check("setCaller");
        console.log("3.0 token", t);
        console.log("adapter", address(adapter));
        _trade(t, address(p), true);

        for (uint256 i; i < olds.length; i++) {
            vm.startBroadcast(pk);
            address ot = _create(olds[i], "Pad3 Fwd", "P3F");
            vm.stopBroadcast();
            console.log("older pad", olds[i], "token", ot);
            _trade(ot, olds[i], false);
        }

        address gwAddr = vm.envOr("GANG_GATEWAY", address(0));
        if (gwAddr != address(0)) _gatewayBuy(IGangGateway(gwAddr), t);
        if (vm.envOr("UPGRADE_REHEARSAL", false)) _upgrade(t);
    }

    function _create(address pad, string memory name, string memory symbol) internal returns (address) {
        IGangLaunchpad.TaxConfig memory untaxed;
        return IGangPad(pad).create(name, symbol, "", "", T.WBNB, address(0), untaxed);
    }

    function _trade(address t, address pad, bool local) internal {
        uint256 w0 = IERC20(T.WBNB).balanceOf(address(p));
        uint256 t0 = IERC20(t).balanceOf(address(p));
        uint256 m0 = IERC20(t).balanceOf(me); // tokens `me` held before (e.g. bought through the gateway)
        (uint8 st, address q,, uint256 feeBps, uint256 left) = p.getTokenInfo(t);
        if (st != 1 || q != address(0) || feeBps != 100 || left == 0) revert Check("getTokenInfo");
        (address tm,, uint256 est, uint256 cost,, uint256 msgValue,,) = p.tryBuy(t, me, 0, 0.002 ether);
        if (tm != address(p) || est == 0 || cost != 0.002 ether || msgValue != 0.002 ether) revert Check("tryBuy");

        vm.startBroadcast(pk);
        (uint256 out, uint256 used) = adapter.buyBnb{value: 0.002 ether}(t, est);
        vm.stopBroadcast();
        if (out != est || used != cost || IERC20(t).balanceOf(me) != m0 + out) revert Check("buy");
        _after(t, pad, local, w0, t0, out);

        // a quarter through the pay-to sell (multi-hop): proceeds to the router, which hands them on
        uint256 quarter = out / 4;
        (,, uint256 qf,) = p.trySell(t, quarter);
        vm.startBroadcast(pk);
        IERC20(t).approve(address(p), quarter);
        uint256 viaHop = hop.sellThenForward(t, quarter, qf);
        vm.stopBroadcast();
        if (viaHop != qf || address(hop).balance != 0) revert Check("pay-to sell");
        out -= quarter;
        _after(t, pad, local, w0, t0, out);

        uint256 half = out / 2;
        (,, uint256 funds,) = p.trySell(t, half);
        uint256 fee = (funds * 100) / 10_000;
        uint256 fee0 = T.DEMO_TREASURY.balance;
        vm.startBroadcast(pk);
        IERC20(t).approve(address(p), half);
        uint256 toSeller = adapter.sell(t, half, funds - fee);
        vm.stopBroadcast();
        if (toSeller != funds - fee || T.DEMO_TREASURY.balance - fee0 != fee) revert Check("adapter sell split");
        if (IERC20(t).allowance(me, address(p)) != 0 || IERC20(t).balanceOf(me) != m0 + out - half) {
            revert Check("adapter sell allowance / balance");
        }
        _after(t, pad, local, w0, t0, out - half);

        uint256 rest = out - half;
        (,, uint256 funds2,) = p.trySell(t, rest);
        vm.startBroadcast(pk);
        IERC20(t).approve(address(p), rest);
        uint256 toSeller2 = p.sellToken(0, t, me, rest, funds2, 0, address(0));
        vm.stopBroadcast();
        if (toSeller2 != funds2 || IERC20(t).balanceOf(me) != m0) revert Check("direct sell");
        if (IERC20(t).allowance(me, address(p)) != 0) revert Check("direct sell allowance");
        _after(t, pad, local, w0, t0, 0);
        console.log("  bought / for wei (after the pay-to quarter)", out, used);
        console.log("  pay-to sell (multi-hop) via the router", viaHop);
        console.log("  adapter sell: to seller / router fee", toSeller, fee);
        console.log("  direct sell: to seller", toSeller2);
    }

    /// @param held the tokens `me` holds now (the part of the curve's tokens outside 3.0, for its own token)
    function _after(address t, address pad, bool local, uint256 w0, uint256 t0, uint256 held) internal view {
        if (address(p).balance != 0 || address(adapter).balance != 0) revert Check("BNB left behind");
        if (IERC20(t).balanceOf(address(adapter)) != 0) revert Check("adapter holds tokens");
        if (local) {
            uint256 out = t0 - IERC20(t).balanceOf(address(p));
            if (out != held) revert Check("3.0 token books");
            return;
        }
        if (IERC20(T.WBNB).balanceOf(address(p)) != w0) revert Check("3.0's reserves moved");
        if (IERC20(t).balanceOf(address(p)) != 0) revert Check("3.0 holds an older pad's token");
        if (IERC20(T.WBNB).allowance(address(p), pad) != 0) revert Check("allowance left to the older pad");
    }

    function _gatewayBuy(IGangGateway gw, address t) internal {
        (,, uint256 est,,,,,) = gw.tryBuy(t, me, 0, 0.001 ether);
        if (est == 0) revert Check("gateway tryBuy on a 3.0 token");
        vm.startBroadcast(pk);
        (uint256 out,) = gw.buyTokenAMAP{value: 0.001 ether}(t, me, 0.001 ether, est);
        vm.stopBroadcast();
        if (out != est) revert Check("gateway buy");
        console.log("gateway bought 3.0's token", out);
    }

    function _upgrade(address t) internal {
        address admin = R.adminOf(address(p));
        if (ProxyAdmin(admin).owner() != me) revert Check("deploy wallet is not the ProxyAdmin owner");
        (,, uint128 rq,,,,,,,,,) = p.curves(t);
        address old = R.implementationOf(address(p));
        vm.startBroadcast(pk);
        address next = address(
            new GangLaunchpad3(
                address(p.quoteRegistry()),
                address(p.dividendVault()),
                address(p.platformBucket()),
                p.taxHandler(),
                p.tokenDeployer(),
                p.wbnb(),
                address(p.padRegistry())
            )
        );
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(address(p)), next, "");
        vm.stopBroadcast();
        if (R.implementationOf(address(p)) != next || next == old) revert Check("upgrade");
        (,, uint128 rq2,,,,,,,,,) = p.curves(t);
        if (rq2 != rq || p.tokenVersionOf(t) != 1 || !p.isCaller(address(adapter))) revert Check("state kept");
        console.log("upgraded: implementation", old, "->", next);
        _trade(t, address(p), true);
    }
}
