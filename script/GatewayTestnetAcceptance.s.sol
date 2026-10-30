// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangGateway} from "../src/router/interfaces/IGangGateway.sol";

/// @dev An aggregator's adapter as written for four.meme: names its caller as the trader, 1% router fee on sells.
contract GatewayAcceptanceAdapter {
    IGangGateway public immutable gw;
    address public immutable feeTo;

    constructor(IGangGateway gw_, address feeTo_) {
        gw = gw_;
        feeTo = feeTo_;
    }

    function buyBnb(address token, uint256 minAmount) external payable returns (uint256 out, uint256 used) {
        return gw.buyTokenAMAP{value: msg.value}(token, msg.sender, msg.value, minAmount);
    }

    function sell(address token, uint256 amount, uint256 minFunds) external returns (uint256) {
        return gw.sellToken(0, token, msg.sender, amount, minFunds, 100, feeTo);
    }
}

/// @title GatewayTestnetAcceptance — GangGateway end to end on BSC testnet, as an aggregator would use it
/// @notice With the deploy wallet (an Agent ID holder): create a WBNB-quoted curve token on GANG_PAD; buy 0.002 BNB of
///         it through an aggregator-style adapter (quote checked against tryBuy); approve the gateway exactly half and
///         sell that through the adapter with a 1% router fee to the demo treasury (BNB out, checked against
///         trySell); approve exactly the rest and sell it straight on the gateway with no fee. After each step: the
///         trader holds the tokens / gets the BNB, the allowance is back to 0, the gateway and adapter hold nothing.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, GANG_GATEWAY, GANG_PAD (must list the gateway).
contract GatewayTestnetAcceptance is Script {
    error WrongChain(uint256 chainId);
    error Check(string what);

    function run() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        IGangGateway gw = IGangGateway(vm.envAddress("GANG_GATEWAY"));
        IGangPad pad = IGangPad(vm.envAddress("GANG_PAD"));
        if (!pad.routers(address(gw))) revert Check("gateway not listed on GANG_PAD");
        address feeTo = T.DEMO_TREASURY;

        vm.startBroadcast(pk);
        address token = pad.create(
            "Gateway Test",
            "GWT",
            "",
            "",
            address(0),
            address(0),
            IGangLaunchpad.TaxConfig({buyTaxBps: 0, sellTaxBps: 0, dividendBps: 0, recipient: address(0)})
        );
        GatewayAcceptanceAdapter adapter = new GatewayAcceptanceAdapter(gw, feeTo);
        vm.stopBroadcast();

        (uint8 status, address quote,, uint256 feeBps, uint256 left) = gw.getTokenInfo(token);
        if (status != 1 || quote != address(0) || feeBps != 100 || left == 0) revert Check("getTokenInfo");
        (address tm,, uint256 est, uint256 cost,, uint256 msgValue,,) = gw.tryBuy(token, me, 0, 0.002 ether);
        if (tm != address(gw) || est == 0 || cost != 0.002 ether || msgValue != 0.002 ether) revert Check("tryBuy");

        // 1. buy through the adapter
        vm.startBroadcast(pk);
        (uint256 out, uint256 used) = adapter.buyBnb{value: 0.002 ether}(token, est);
        vm.stopBroadcast();
        if (out != est || used != cost || IERC20(token).balanceOf(me) != out) revert Check("buy");
        _empty(gw, adapter, token);

        // 2. sell half through the adapter, 1% router fee, exact approval
        uint256 half = out / 2;
        (,, uint256 funds,) = gw.trySell(token, half);
        uint256 fee = (funds * 100) / 10_000;
        uint256 fee0 = feeTo.balance;
        vm.startBroadcast(pk);
        IERC20(token).approve(address(gw), half);
        uint256 toSeller = adapter.sell(token, half, funds - fee);
        vm.stopBroadcast();
        // the gateway and adapter end empty and the fee arrived: the rest of `funds` went to the seller
        if (toSeller != funds - fee || feeTo.balance - fee0 != fee) revert Check("adapter sell split");
        if (IERC20(token).allowance(me, address(gw)) != 0 || IERC20(token).balanceOf(me) != out - half) {
            revert Check("adapter sell allowance / balance");
        }
        _empty(gw, adapter, token);

        // 3. sell the rest straight on the gateway, no fee
        uint256 rest = out - half;
        (,, uint256 funds2,) = gw.trySell(token, rest);
        vm.startBroadcast(pk);
        IERC20(token).approve(address(gw), rest);
        uint256 toSeller2 = gw.sellToken(0, token, me, rest, funds2, 0, address(0));
        vm.stopBroadcast();
        if (toSeller2 != funds2 || IERC20(token).balanceOf(me) != 0) revert Check("direct sell");
        if (IERC20(token).allowance(me, address(gw)) != 0) revert Check("direct sell allowance");
        _empty(gw, adapter, token);

        console.log("token", token);
        console.log("adapter", address(adapter));
        console.log("bought", out, "for wei", used);
        console.log("adapter sell: to seller / router fee", toSeller, fee);
        console.log("direct sell: to seller", toSeller2);
    }

    function _empty(IGangGateway gw, GatewayAcceptanceAdapter adapter, address token) internal view {
        if (address(gw).balance != 0 || IERC20(T.WBNB).balanceOf(address(gw)) != 0) revert Check("gateway not empty");
        if (IERC20(token).balanceOf(address(gw)) != 0) revert Check("gateway holds tokens");
        if (address(adapter).balance != 0 || IERC20(T.WBNB).balanceOf(address(adapter)) != 0) {
            revert Check("adapter not empty");
        }
    }
}
