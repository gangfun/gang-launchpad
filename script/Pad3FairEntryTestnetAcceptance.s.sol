// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";

interface IFairCreateT {
    function create(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        IGangLaunchpad.MintConfig calldata cfg,
        uint256 devShares
    ) external returns (address token);
}

/// @title Pad3FairEntryTestnetAcceptance — 打新 through GangLaunchpad 3.0's aggregator entry on BSC testnet
/// @notice With the deploy wallet (an Agent ID holder): a gated WBNB 打新 sale created on 3.0 and on each older pad in
///         OLD_PADS (each lists 3.0 as a router), then on each, through 3.0's entry: status 1, a buy with native BNB of
///         exactly `tryBuy`'s `amountMsgValue` (= its amount and cost to the wei), half of it sold back with
///         `sellToken` (= `trySell`, native BNB). Checked in the simulation before broadcasting and again on chain.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, GANG_PAD3, OLD_PADS (comma-separated). Broadcast with --slow and
///      --legacy --with-gas-price 100000000.
contract Pad3FairEntryTestnetAcceptance is Script {
    uint256 internal constant TPS = 50_000 ether;

    error Check(string what);

    function run() external {
        if (block.chainid != 97) revert Check("testnet only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        GangLaunchpad3 p3 = GangLaunchpad3(payable(vm.envAddress("GANG_PAD3")));
        address[] memory olds = vm.envAddress("OLD_PADS", ",");
        if (!p3.isAgent(me)) revert Check("deploy wallet holds no Agent ID");

        address[] memory pads = new address[](olds.length + 1);
        pads[0] = address(p3);
        for (uint256 i; i < olds.length; i++) {
            if (!IGangPad(olds[i]).routers(address(p3))) revert Check("older pad does not list 3.0");
            pads[i + 1] = olds[i];
        }
        for (uint256 i; i < pads.length; i++) {
            _roundTrip(pk, me, p3, pads[i]);
        }
        console.log("acceptance ok");
    }

    function _roundTrip(uint256 pk, address me, GangLaunchpad3 p3, address pad) internal {
        address wbnb = p3.wbnb();
        IGangLaunchpad.MintConfig memory cfg = IGangLaunchpad.MintConfig({
            raiseBnb: 5 ether, capBps: 50, holdBps: 6_000, mintFeeBps: 100, exitFeeBps: 100
        });
        vm.startBroadcast(pk);
        IERC20(wbnb).approve(pad, type(uint256).max);
        (bool okDep,) = wbnb.call{value: 0.001 ether}(abi.encodeWithSignature("deposit()"));
        if (!okDep) revert Check("wrap");
        address t = IFairCreateT(pad).create("Fair entry", "FEN", "", "", address(0), address(0), cfg, 1);
        IERC20(wbnb).approve(pad, 0);
        vm.stopBroadcast();
        (uint8 st,,,,) = p3.getTokenInfo(t);
        if (st != 1) revert Check("status 1");

        (,, uint256 amount, uint256 cost,, uint256 msgValue,,) = p3.tryBuy(t, me, 0, 0.0123 ether);
        if (amount == 0 || msgValue != cost) revert Check("quote");
        uint256 held0 = IERC20(t).balanceOf(me);
        vm.startBroadcast(pk);
        (uint256 out, uint256 used) = p3.buyTokenAMAP{value: msgValue}(t, me, msgValue, amount);
        vm.stopBroadcast();
        if (out != amount || used != cost) revert Check("buy = tryBuy");
        if (IERC20(t).balanceOf(me) != held0 + amount) revert Check("tokens");

        uint256 half = ((amount / TPS) / 2) * TPS;
        (,, uint256 funds,) = p3.trySell(t, half);
        vm.startBroadcast(pk);
        IERC20(t).approve(address(p3), half);
        uint256 paid = p3.sellToken(0, t, me, half, funds, 0, address(0));
        vm.stopBroadcast();
        if (paid != funds || funds == 0) revert Check("sell = trySell");
        if (IERC20(t).allowance(me, address(p3)) != 0) revert Check("allowance used up");
        console.log("pad", pad);
        console.log("  token / bought / sold", t, amount, half);
    }
}
