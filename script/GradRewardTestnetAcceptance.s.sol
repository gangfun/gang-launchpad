// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../src/gang/Pad3VanityDeployer.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangGradReward, IGangGradRewardBase} from "../src/gang/interfaces/IGangGradReward.sol";
import {Pad3VanitySalt} from "./Pad3VanitySalt.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @notice BSC testnet acceptance of the graduation reward (docs/SPEC-GRAD-REWARD-2026-11-17.md), up to graduation:
///         the deployer (an Agent) creates a reward token through createWithSalt (abcd is on there) in GRAD_QUOTE
///         (a listed ERC-20 it holds), the seed is pulled and the terms read back; then on the curve a buy below
///         minBuy is not counted, two buys are, a sell takes both out, a later buy counts again; a refund request
///         before `refundAfter` and a claim before graduation are refused (simulated). Graduation and claims need
///         ~80 Agent wallets under the 1% cap and are covered by test/fork/Pad3GradRewardFork.t.sol.
/// @dev Env: DEPLOYER_PRIVATE_KEY, GANG_PAD3, GRAD_QUOTE. Not idempotent: each run mines a fresh salt and creates
///      another token (and leaves its seed in it until the refund or graduation).
contract GradRewardTestnetAcceptance is Script {
    string internal constant NAME = "Grad Reward Test";
    string internal constant SYMBOL = "GRADT";
    uint256 internal constant GRAD = 6 ether;
    uint128 internal constant SEED = 0.05 ether;
    uint96 internal constant MIN_BUY = 0.003 ether;
    uint8 internal constant ENTRIES = 5;
    uint16 internal constant LAST = 3_000;
    uint32 internal constant REFUND_AFTER = 30 days;

    error Check(string what);

    function run() external {
        require(block.chainid == 97, "testnet only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address dev = vm.addr(pk);
        GangLaunchpad3 p = GangLaunchpad3(payable(vm.envAddress("GANG_PAD3")));
        Pad3Module m = Pad3Module(payable(address(p)));
        IGangGradReward g = IGangGradReward(address(p));
        IERC20 q = IERC20(vm.envAddress("GRAD_QUOTE"));
        (bool open,,) = g.gradRewardDeps();
        if (!open) revert Check("grad reward not open");
        // entries are counted only with the Agent gate on; the amounts below assume 18 decimals
        if (!p.agentGateEnabled()) revert Check("Agent gate off: no buy would be counted");
        if (IERC20Decimals(address(q)).decimals() != 18) revert Check("GRAD_QUOTE must have 18 decimals");
        address factory = m.vanityDeployer();
        if (factory == address(0)) revert Check("abcd not on");

        bytes32 hash = Pad3VanityDeployer(factory).tokenInitCodeHash(NAME, SYMBOL, "", address(0), 0, 0, false);
        (bytes32 salt, address expected) = Pad3VanitySalt.find(factory, dev, hash);
        console.log("expected token", expected);

        IGangGradRewardBase.GradConfig memory cfg = IGangGradRewardBase.GradConfig({
            seed: SEED,
            minBuy: MIN_BUY,
            entries: ENTRIES,
            lastBps: LAST,
            carryBps: 0,
            refundAfter: REFUND_AFTER,
            promoteBps: 0,
            promoteWindow: 0
        });
        IGangLaunchpad.TaxConfig memory none;
        bytes memory data = abi.encodeCall(
            IGangGradReward.createWithGradReward, (NAME, SYMBOL, "", "", address(q), address(0), none, GRAD, cfg)
        );
        uint256 devBefore = q.balanceOf(dev);
        uint256 padBefore = q.balanceOf(address(p));
        vm.startBroadcast(pk);
        q.approve(address(p), SEED);
        address t = m.createWithSalt(salt, data);
        vm.stopBroadcast();
        if (t != expected) revert Check("token address");
        console.log("token", t);
        if (devBefore - q.balanceOf(dev) != SEED) revert Check("seed pulled from the dev");
        if (q.balanceOf(address(p)) - padBefore != SEED) revert Check("seed on the pad");
        _terms(g.gradReward(t));

        // the curve: 0.001 (not counted), 0.004, 0.004, sell a quarter (both out), 0.004 (counted again)
        vm.startBroadcast(pk);
        q.approve(address(p), 0.013 ether);
        p.buy(t, 0.001 ether, 0);
        p.buy(t, 0.004 ether, 0);
        p.buy(t, 0.004 ether, 0);
        uint256 part = IERC20(t).balanceOf(dev) / 4;
        IERC20(t).approve(address(p), part);
        p.sell(t, part, 0);
        p.buy(t, 0.004 ether, 0);
        vm.stopBroadcast();

        (address[] memory buyers, uint64[] memory seqs, uint96[] memory spent, bool[] memory valid) = g.gradEntries(t);
        if (buyers.length != 3 || g.gradReward(t).seq != 3) revert Check("three counted buys");
        for (uint256 i; i < 3; i++) {
            if (buyers[i] != dev || seqs[i] != 3 - i || spent[i] != 0.004 ether) revert Check("entry");
        }
        if (!valid[0] || valid[1] || valid[2]) revert Check("sell takes earlier entries out, later buy counts");
        if (g.gradClaimable(t, dev) != 0) revert Check("claimable before graduation");

        // refused before their time (simulated, never broadcast)
        vm.prank(dev);
        try g.requestGradRefund(t) {
            revert Check("refund request before refundAfter");
        } catch (bytes memory r) {
            if (bytes4(r) != IGangGradRewardBase.RefundNotDue.selector) revert Check("refund request: wrong revert");
        }
        vm.prank(dev);
        try g.claimGradReward(t) {
            revert Check("claim before graduation");
        } catch (bytes memory r) {
            if (bytes4(r) != IGangGradRewardBase.NotGradState.selector) revert Check("claim: wrong revert");
        }
        console.log("ok: created with the seed, entries counted / not counted / taken out / counted again");
    }

    function _terms(IGangGradRewardBase.GradView memory v) internal view {
        if (
            v.state != 1 || v.pot != SEED || v.minBuy != MIN_BUY || v.entries != ENTRIES || v.lastBps != LAST
                || v.carryBps != 0 || v.refundAfter != REFUND_AFTER || v.createdAt == 0 || v.countdown != address(0)
                || v.seq != 0
        ) revert Check("terms");
    }
}
