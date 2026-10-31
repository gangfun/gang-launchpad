// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GangMainnetRefs as M, GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {MintTokenDeployer} from "../src/flywheel/MintTokenDeployer.sol";
import {FlywheelTaxHandler} from "../src/flywheel/FlywheelTaxHandler.sol";
import {GangFlywheelPad} from "../src/flywheel/GangFlywheelPad.sol";
import {IFlywheelPad} from "../src/flywheel/interfaces/IFlywheelPad.sol";
import {DeployFlywheel} from "./DeployFlywheel.s.sol";

/// @title DeployFlywheelV2 — a second continuous-mint pad (V2 post-launch rules, kind 3) next to the live one
/// @notice Same two phases, pins and self-check as DeployFlywheel, with one difference: it deploys only a new
///         FlywheelTaxHandler (same code as V1's) and the V2 GangFlywheelPad (+ its libraries), and reuses the live
///         MintTokenDeployer (owned by the platform Safe on mainnet). Listing the new pad on that deployer is then a
///         Safe call too, so the phase 1 listing batch has eight transactions: V1's seven (vault launchpad + floor +
///         operator(newHandler, newPad), migrator, bucket operators for pad and handler, GangPadRegistry.addPad) and
///         `MintTokenDeployer.setLaunchpad(newPad, true)`. Phase 2 hands the handler and the pad over (the deployer is
///         already the Safe's) and prints the accept batch, which ends with `setMigrator`.
///         Phase 1 checks the new pad and handler (immutables, wiring, the V2 libraries through `checkConfig`) and
///         prints their fingerprint before the listing batch (audit V2 C-L1 / C-I1). Once the V2 pad is open and the
///         Safe owns it, a run also prints, separately, the optional Safe batch that stops new creates on the V1 pad
///         (`MintTokenDeployer.setLaunchpad(V1 pad, false)`; V1 sales already created are not affected), while the V1
///         pad is still listed on the deployer; before that it prints a one-line note instead (C-L2).
/// @dev Env as DeployFlywheel, plus FLYWHEEL_DEPLOYER: the live MintTokenDeployer (mainnet default and pin
///      0x2C95…072E, owner the Safe; testnet required) and FLYWHEEL_V1_PAD (mainnet default 0x631e…B029; testnet
///      optional). Phase 2: FLYWHEEL_PAD, FLYWHEEL_HANDLER.
///      Mainnet (audit V2 C-I2): pass the deployed PoolCheck library, which the pad links,
///        --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
///      (GangMainnetRefs.POOL_CHECK); without it forge deploys a new PoolCheck from the deploy wallet. FlywheelLogic
///      and FlywheelPostLogic are new (V2) and deployed by forge in phase 1.
contract DeployFlywheelV2 is DeployFlywheel {
    /// @dev The live MintTokenDeployer (docs/MAINNET-FLYWHEEL-2026-10-30.md), owned by M.OWNER_SAFE.
    address internal constant MAINNET_TOKEN_DEPLOYER = 0x2C95228AfA6eF211371A87f480aBa0f5c0Da072E;
    /// @dev The live V1 GangFlywheelPad.
    address internal constant MAINNET_V1_PAD = 0x631e66560F4FAE4e486B65349edE48189E48B029;

    function _tokenDeployer(bool mainnet) internal view returns (address) {
        return mainnet ? vm.envOr("FLYWHEEL_DEPLOYER", MAINNET_TOKEN_DEPLOYER) : vm.envAddress("FLYWHEEL_DEPLOYER");
    }

    function _v1Pad(bool mainnet) internal view returns (address) {
        return vm.envOr("FLYWHEEL_V1_PAD", mainnet ? MAINNET_V1_PAD : address(0));
    }

    function _existingDeployer(bool mainnet) internal view override returns (address) {
        return _tokenDeployer(mainnet);
    }

    /// @dev The handler and the pad; the deployer wallet lists the pad on the deployer only if it owns it (testnet).
    function _deploy(Shared memory sh, bool mainnet, address me, address keeper)
        internal
        override
        returns (Own memory o)
    {
        address wbnb = mainnet ? M.WBNB : T.WBNB;
        address factory = mainnet ? M.PANCAKE_V2_FACTORY : T.PANCAKE_V2_FACTORY;
        address router = mainnet ? M.PANCAKE_V2_ROUTER : T.PANCAKE_V2_ROUTER;
        address agentId = mainnet ? M.AGENT_ID_REGISTRY : vm.envOr("AGENT_ID", T.AGENT_ID_REGISTRY);
        MintTokenDeployer d = MintTokenDeployer(_tokenDeployer(mainnet));
        if (address(d).code.length == 0) revert NotWired("FLYWHEEL_DEPLOYER has no code");
        FlywheelTaxHandler h = new FlywheelTaxHandler(me, sh.vault, sh.bucket, router);
        GangFlywheelPad p =
            new GangFlywheelPad(me, sh.quoteRegistry, sh.vault, sh.bucket, address(h), address(d), wbnb, factory);
        if (d.owner() == me) d.setLaunchpad(address(p), true);
        h.setLaunchpad(address(p));
        h.setKeeper(keeper);
        p.setAgentGate(true, agentId);
        p.setV3Factory(mainnet ? M.PANCAKE_V3_FACTORY : T.PANCAKE_V3_FACTORY);
        o = Own({deployer: address(d), handler: address(h), pad: address(p)});
    }

    /// @dev Also the deployer listing: without it the Safe batch is needed even where the deploy wallet owns the rest.
    function _canWire(Shared memory sh, Own memory o, address me) internal view override returns (bool) {
        return super._canWire(sh, o, me) && MintTokenDeployer(o.deployer).launchpads(o.pad);
    }

    function _requireShared(Shared memory sh, Own memory o) internal view override {
        super._requireShared(sh, o);
        if (!MintTokenDeployer(o.deployer).launchpads(o.pad)) revert NotWired("deployer.setLaunchpad(pad)");
    }

    /// @dev V1's pins, plus the live MintTokenDeployer and its owner.
    function _requireMainnetInputs(Shared memory sh, address gangPad, address owner, address keeper)
        internal
        view
        override
    {
        super._requireMainnetInputs(sh, gangPad, owner, keeper);
        address d = _tokenDeployer(true);
        if (d != MAINNET_TOKEN_DEPLOYER) revert NotWired("FLYWHEEL_DEPLOYER is not the live MintTokenDeployer");
        if (Ownable(d).owner() != M.OWNER_SAFE) revert NotWired("deployer owner is not the Safe");
        if (_v1Pad(true) != MAINNET_V1_PAD) revert NotWired("FLYWHEEL_V1_PAD is not the live V1 pad");
    }

    /// @dev The deployer is the live one (pinned on mainnet); its listing of the pad is the Safe's (`_requireShared`).
    function _checkDeployer(Own memory o, bool mainnet) internal view override {
        if (mainnet && o.deployer != MAINNET_TOKEN_DEPLOYER) revert NotWired("deployer");
        if (o.deployer.code.length == 0) revert NotWired("deployer has no code");
    }

    /// @dev V1's checks, plus: the pad is V2 code with V2's libraries linked (audit V2 C-I1): `postRulesOf` exists and
    ///      `checkConfig` accepts the widest V2 config and refuses one share of quota or invite bonus past it.
    function _checkOwn(Shared memory sh, Own memory o, address keeper, bool mainnet) internal view override {
        super._checkOwn(sh, o, keeper, mainnet);
        GangFlywheelPad p = GangFlywheelPad(payable(o.pad));
        p.postRulesOf(address(0)); // reverts on a V1 pad
        IFlywheelPad.FlyConfig memory c = _v2Probe();
        (bool ok, string memory why) = p.checkConfig(c, 1);
        if (!ok) revert NotWired(string.concat("V2 checkConfig refused the widest V2 config: ", why));
        c.baseQuota = 11;
        (ok, why) = p.checkConfig(c, 1);
        if (ok || keccak256(bytes(why)) != keccak256("baseQuota must be 5-10 with postMint")) {
            revert NotWired("V2 checkConfig: baseQuota 11 with postMint");
        }
        c.baseQuota = 10;
        c.inviteBonus = 2;
        (ok, why) = p.checkConfig(c, 1);
        if (ok || keccak256(bytes(why)) != keccak256("inviteBonus must be 0-1 with postMint")) {
            revert NotWired("V2 checkConfig: inviteBonus 2 with postMint (not the fixed V2 libraries)");
        }
        console.log("V2 libraries ok (checkConfig)");
    }

    /// @dev The widest config V2 allows with post-launch minting (quota 10, invite bonus 1, 15-minute window).
    function _v2Probe() internal pure returns (IFlywheelPad.FlyConfig memory) {
        return IFlywheelPad.FlyConfig({
            raiseBnb: 20 ether,
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
            twapWindow: 900
        });
    }

    function _check(Shared memory sh, Own memory o, address owner, address me, address keeper, bool mainnet)
        internal
        view
        override
    {
        super._check(sh, o, owner, me, keeper, mainnet);
        console.log("self-check ok (V2)");
    }

    function _printWiring(Shared memory sh, Own memory o, bool mainnet) internal view override {
        console.log(_wiringJsonV2(sh, o, mainnet, Ownable(sh.vault).owner()));
    }

    /// @dev The V1-stop batch only once the V2 pad is open and the owner (the Safe) owns it (audit V2 C-L2): stopping
    ///      V1 earlier would leave no pad taking new sales.
    function _afterRun(Own memory o, bool mainnet, address owner) internal view override {
        address v1 = _v1Pad(mainnet);
        if (v1 == address(0) || !MintTokenDeployer(o.deployer).launchpads(v1)) return;
        GangFlywheelPad p = GangFlywheelPad(payable(o.pad));
        if (p.migrator() == address(0) || p.owner() != owner) {
            console.log("\nV1-stop batch: run phase 2 again after the accept batch");
            return;
        }
        console.log("\n=== OPTIONAL Safe batch (not part of the listing): stop new creates on the V1 pad ===");
        console.log(_stopV1Json(o.deployer, v1, mainnet, Ownable(o.deployer).owner()));
    }

    /// @dev V1's seven listings, then the deployer listing (the MintTokenDeployer is the Safe's).
    function _wiringJsonV2(Shared memory sh, Own memory o, bool mainnet, address safe)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            _head(
                mainnet, safe, "gang: list the continuous-mint pad V2 on the shared contracts and the token deployer"
            ),
            _wiringTxs(sh, o),
            _tx(o.deployer, abi.encodeCall(MintTokenDeployer.setLaunchpad, (o.pad, true)), true),
            "]}"
        );
    }

    /// @dev One transaction: the V1 pad can no longer deploy tokens, so its `create` reverts (OnlyLaunchpad).
    function _stopV1Json(address deployer, address v1Pad, bool mainnet, address safe)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            _head(mainnet, safe, "gang: stop new creates on the continuous-mint pad V1"),
            _tx(deployer, abi.encodeCall(MintTokenDeployer.setLaunchpad, (v1Pad, false)), false),
            "]}"
        );
    }
}
