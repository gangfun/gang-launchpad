// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {GangHandlerAdmin} from "../src/gang/GangHandlerAdmin.sol";
import {IGangGradReward} from "../src/gang/interfaces/IGangGradReward.sol";
import {DeployGangCountdownRewardFactory} from "./DeployGangCountdownRewardFactory.s.sol";

/// @title SetGradRewardCountdown — open the graduation reward's carry into the countdown reward (spec
///        docs/SPEC-GRAD-REWARD-2026-11-17.md §5): `setGradReward(true, admin, countdownFactory)` on GangLaunchpad 3.0
/// @notice With the countdown factory set, a reward token whose tax recipient is a module of that factory, made for
///         this very token and quote, can carry `carryBps` of its pool into that module's reward pool at graduation.
///         Before the call is sent or printed:
///         - the reward is open, the admin is the one already set, and no other countdown factory is set;
///         - the factory and its implementation pass DeployGangCountdownRewardFactory's `check` and `checkCode` over the
///           pad and the admin. The code comparison is exact (metadata included), so run this at the commit the factory
///           was deployed from (or a later one that leaves its sources unchanged) and WITHOUT --libraries (linked
///           libraries are part of the compiler settings in the metadata: a build with them never matches);
///         - the admin allows the factory (`isFactory`);
///         - the call runs in the simulation as the pad's owner, and `gradRewardDeps` reads back (true, admin, factory);
///           then it is rolled back.
///         Testnet, with the deploy wallet owning the pad: sent. Otherwise: printed as a one-call Safe batch.
/// @dev Env: GANG_PAD3, COUNTDOWN_FACTORY; DEPLOYER_PRIVATE_KEY (testnet send only).
contract SetGradRewardCountdown is Script {
    address internal constant MAINNET_PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address internal constant MAINNET_SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;

    error WiringCheck(string what);

    function run() external returns (bytes memory call) {
        return run(vm.envAddress("GANG_PAD3"), vm.envAddress("COUNTDOWN_FACTORY"));
    }

    function run(address pad, address factory) public returns (bytes memory call) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WiringCheck("BSC mainnet (56) or the BSC testnet (97) only");
        if (mainnet && pad != MAINNET_PAD3) revert WiringCheck("GANG_PAD3 is not GangLaunchpad 3.0");
        (bool open, address admin, address current) = IGangGradReward(pad).gradRewardDeps();
        if (!open) revert WiringCheck("the graduation reward is not open");
        if (current == factory) revert WiringCheck("this countdown factory is already set");
        if (current != address(0)) revert WiringCheck("another countdown factory is set");
        if (admin == address(0)) revert WiringCheck("no handler admin set");

        DeployGangCountdownRewardFactory d = new DeployGangCountdownRewardFactory();
        d.check(pad, admin, factory);
        d.checkCode(factory);
        if (!GangHandlerAdmin(admin).isFactory(factory)) revert WiringCheck("the admin does not allow the factory");

        address owner = Ownable(pad).owner();
        if (mainnet && owner != MAINNET_SAFE) revert WiringCheck("the pad's owner is not the Safe");
        call = abi.encodeCall(Pad3Module.setGradReward, (true, admin, factory));

        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        (bool ok,) = pad.call(call);
        if (!ok) revert WiringCheck("setGradReward reverted in the simulation");
        (bool o2, address a2, address f2) = IGangGradReward(pad).gradRewardDeps();
        if (!o2 || a2 != admin || f2 != factory) revert WiringCheck("gradRewardDeps after the call");
        vm.revertToState(snap);

        console.log("pad                 ", pad);
        console.log("GangHandlerAdmin    ", admin);
        console.log("countdown factory   ", factory);
        console.log("pad owner           ", owner);
        console.log("simulated: setGradReward(true, admin, factory) ok");

        uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (!mainnet && pk != 0 && vm.addr(pk) == owner) {
            vm.startBroadcast(pk);
            Pad3Module(payable(pad)).setGradReward(true, admin, factory);
            vm.stopBroadcast();
            console.log("testnet: sent by the deploy wallet (the pad's owner)");
            return call;
        }
        console.log("\n=== Safe batch: open the graduation reward's countdown carry (one call, effective at once) ===");
        console.log(batchJson(mainnet, owner, pad, call));
    }

    function batchJson(bool mainnet, address safe, address pad, bytes memory call) public pure returns (string memory) {
        return string.concat(
            '{"version":"1.0","chainId":"',
            mainnet ? "56" : "97",
            '","createdAt":0,"meta":{"name":"gang: open the graduation reward countdown carry","txBuilderVersion":"1.16.5","createdFromSafeAddress":"',
            vm.toString(safe),
            '"},"transactions":[{"to":"',
            vm.toString(pad),
            '","value":"0","data":"',
            vm.toString(call),
            '","contractMethod":null,"contractInputsValues":null}]}'
        );
    }
}
