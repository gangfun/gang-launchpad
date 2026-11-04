// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {Pad3FlyModule} from "../src/gang/Pad3FlyModule.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {IFlywheelPad} from "../src/flywheel/interfaces/IFlywheelPad.sol";

/// @title Pad3FlyTestnetAcceptance — GangLaunchpad 3.0's 铸币飞轮 mode on BSC testnet, after its upgrade
/// @notice With the deploy wallet (an Agent ID holder): a gated WBNB 铸币飞轮 sale created on 3.0 (kind 3, registered in
///         the shared vault under 3.0's 铸币飞轮 vault core at V2's floor), then through 3.0's entry: status 1, a buy with native BNB of exactly
///         `tryBuy`'s `amountMsgValue` (whole shares), one share sold back with `sellToken` (= `trySell`); then V2's
///         own calls on the same address: `mint`, `withdraw` (dispatched by kind), `sales` / `accounts` /
///         `shareSizeOf`. Checked in the simulation before broadcasting and again on chain. Launching needs 3,000
///         shares from other Agent wallets: the mainnet fork test covers it (test/fork/Pad3FlyUpgradeFork.t.sol).
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, GANG_PAD3. Broadcast with --slow and --legacy --with-gas-price
///      100000000.
contract Pad3FlyTestnetAcceptance is Script {
    uint256 internal constant TPS = 100_000 ether;

    error Check(string what);

    function run() external {
        if (block.chainid != 97) revert Check("testnet only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        GangLaunchpad3 p3 = GangLaunchpad3(payable(vm.envAddress("GANG_PAD3")));
        Pad3FlyModule fly = Pad3FlyModule(address(p3));
        if (!p3.isAgent(me)) revert Check("deploy wallet holds no Agent ID");
        address wbnb = p3.wbnb();

        IFlywheelPad.FlyConfig memory cfg = IFlywheelPad.FlyConfig({
            raiseBnb: 3 ether,
            baseQuota: 10,
            inviteBonus: 1,
            maxPerTx: 10,
            holdBps: 6_000,
            mintFeeBps: 100,
            exitFeeBps: 100,
            devCutBps: 1_000,
            buyBps: 3_000,
            sellTaxBps: 200,
            launchDelay: 60,
            window: 600,
            windowCapMul: 1,
            postMint: true,
            tierMode: 1,
            stepBps: 0,
            stepShares: 0,
            maxMulX100: 0,
            supplyCapMul: 100,
            guardBps: 0,
            twapWindow: 1800
        });
        (bool ok, string memory why) = fly.checkConfig(cfg, 1);
        if (!ok) revert Check(why);

        string[4] memory text = ["Fly entry", "FLYE", "", ""];
        vm.startBroadcast(pk);
        IERC20(wbnb).approve(address(p3), type(uint256).max);
        (bool okDep,) = wbnb.call{value: 0.01 ether}(abi.encodeWithSignature("deposit()"));
        if (!okDep) revert Check("wrap");
        address t = fly.create(text, address(0), address(0), cfg, 1);
        vm.stopBroadcast();
        if (p3.kindOf(t) != 3) revert Check("kind 3");
        if (Pad3Module(payable(address(p3))).shareSizeOf(t) != TPS) revert Check("shareSizeOf");
        SharedDividendVault vault = SharedDividendVault(address(p3.dividendVault()));
        if (vault.shares(t, me) != TPS) revert Check("dev share in the vault");
        if (vault.launchpadOf(t) != fly.flyVaultCore() || vault.minimumShareBalanceFor(t) != 1_000 ether) {
            revert Check("under the vault core at V2's floor");
        }
        (uint8 st,,,,) = p3.getTokenInfo(t);
        if (st != 1) revert Check("status 1");

        // the entry: whole shares in, one back
        (,, uint256 amount, uint256 cost,, uint256 msgValue,,) = p3.tryBuy(t, me, 0, 0.0021 ether);
        if (amount == 0 || amount % TPS != 0 || msgValue != cost) revert Check("quote");
        uint256 held0 = IERC20(t).balanceOf(me);
        vm.startBroadcast(pk);
        (uint256 out, uint256 used) = p3.buyTokenAMAP{value: msgValue}(t, me, msgValue, amount);
        vm.stopBroadcast();
        if (out != amount || used != cost) revert Check("buy = tryBuy");
        if (IERC20(t).balanceOf(me) != held0 + amount) revert Check("tokens");
        (,, uint256 funds,) = p3.trySell(t, TPS);
        vm.startBroadcast(pk);
        IERC20(t).approve(address(p3), TPS);
        uint256 paid = p3.sellToken(0, t, me, TPS, funds, 0, address(0));
        vm.stopBroadcast();
        if (paid != funds || funds == 0) revert Check("sell = trySell");

        // V2's own calls on the same address
        uint256 base0 = fly.accounts(t, me).baseline;
        vm.startBroadcast(pk);
        fly.mint(t, 1, 1, address(0));
        p3.withdraw(t, 1, 0);
        IERC20(wbnb).approve(address(p3), 0);
        vm.stopBroadcast();
        if (fly.accounts(t, me).baseline != base0) revert Check("mint + withdraw");
        if (vault.shares(t, me) != base0) revert Check("vault share = baseline");
        console.log("fly token", t);
        console.log("acceptance ok");
    }
}
