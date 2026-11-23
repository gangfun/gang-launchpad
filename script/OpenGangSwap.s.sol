// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangMainnetRefs as M} from "../config/GangDeployRefs.sol";
import {SharedPlatformFeeBucket} from "../src/common/SharedPlatformFeeBucket.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {GangPadRegistry} from "../src/gang/GangPadRegistry.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {Pad3GangSwapStore} from "../src/gang/Pad3GangSwapStore.sol";
import {Pad3VanityDeployer} from "../src/gang/Pad3VanityDeployer.sol";
import {IGangSwapPad} from "../src/gang/interfaces/IGangSwapPad.sol";
import {Pad3VanitySalt} from "./Pad3VanitySalt.sol";

interface IOpenMigrator {
    function factory() external view returns (address);
    function boost() external view returns (address);
    function quote() external view returns (address);
    function wired() external view returns (bool);
    function launchpads(address pad) external view returns (bool);
    function addLaunchpad(address pad) external;
}

interface IOpenFactory {
    function fees() external view returns (address);
    function getPair(address a, address b) external view returns (address);
    function allPairsLength() external view returns (uint256);
}

interface IOpenFees {
    function bucket() external view returns (address);
    function collect(address pair) external returns (uint256);
    function pendingPlatform() external view returns (uint256);
}

interface IOpenBoost {
    function boosts(address token) external view returns (address, uint64, bool, uint128, uint128);
    function step(address token) external returns (uint256, uint256);
}

interface IOpenRouter {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);
}

interface IOpenWbnb {
    function deposit() external payable;
}

/// @title OpenGangSwap: the two owner batches that open a deployed GangSwap version on GangLaunchpad 3.0
///        (docs/SPEC-GANGSWAP-2026-11-22.md §13 steps 4 and 6), for the first version and for a later one
/// @notice GANGSWAP_STEP=list: `addLaunchpad(pad)` on the migrator and the fee contract as an operator of the fee bucket
///         (whichever is missing). GANGSWAP_STEP=open: `setGangSwapMigrator`, effective at once for NEW tokens; refused
///         unless the list step is on chain. Send it only once the keeper, the indexer, the website and the CLI serve
///         this version: this script cannot see them.
///         Before anything is printed or sent:
///         - the deployed migrator, boost, fees, factory and router are this build's code, byte for byte (references
///           deployed here from gangswap/out with the same constructor arguments) and were created with this build's
///           creation code and those arguments, point at each other, and take the pad's WBNB and fee bucket; every owner
///           is the same account (mainnet: the Safe), nothing pending; the migrator lists no other registered pad;
///         - open: every older version with tokens keeps its fee contract as a bucket operator;
///         - the batch runs in the simulation and, in both steps, the whole life of a token under it: created on the
///           pad, found by the registry as kind 4, graduated by one buy into the version's own pair, one boost step, a
///           buy and a sell on the router, fees collected into the bucket. Gate and wallet cap are switched off for
///           that rehearsal only; all of it is rolled back.
///         Then a Safe batch (mainnet, or testnet when the deploy wallet is not the owner), or sent (testnet).
/// @dev Env: GANG_PAD3, GANGSWAP_MIGRATOR, GANGSWAP_ROUTER, GANGSWAP_STEP, GANGSWAP_DEPLOY_TXS (DeployGangSwap's five
///      transactions, in its order: migrator,boost,fees,factory,router); GANGSWAP_REPLACE=true to replace a version
///      already set (the old fee contract must still be a bucket operator: its tokens live on); DEPLOYER_PRIVATE_KEY on
///      testnet only. `forge build --root gangswap --force` first, from a clean checkout. Mainnet batches: re-run right before the Safe signs.
contract OpenGangSwap is Script {
    /// @dev The mainnet GangLaunchpad 3.0 proxy.
    address internal constant MAINNET_PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    uint256 internal constant G = 6 ether;

    /// @dev keccak256 of the five contracts' creation code in this build (`_buildHash`): stale gangswap/out artifacts
    ///      would agree with a set deployed from them. Changes with any edit in gangswap/src (the test prints the new one);
    ///      an older live version is then repaired from a checkout of its own commit.
    bytes32 internal constant BUILD = 0x9dbfe0dc74ba8b000fb349125dbcc6f82c35e273664ef6f468edc59e87428db3;

    /// @dev GANGSWAP_DEPLOY_TXS, in `_sameCode`'s order.
    bytes32[5] internal _txs;

    error Check(string what);

    struct Version {
        address migrator;
        address boost;
        address fees;
        address factory;
        address router;
        address bucket;
    }

    function run() external {
        string memory step = vm.envString("GANGSWAP_STEP");
        bool open = _eq(step, "open");
        if (!open && !_eq(step, "list")) revert Check("GANGSWAP_STEP: list or open");
        bytes32[] memory txs = vm.envBytes32("GANGSWAP_DEPLOY_TXS", ",");
        if (txs.length != 5) revert Check("GANGSWAP_DEPLOY_TXS: migrator,boost,fees,factory,router");
        for (uint256 i; i < 5; i++) {
            _txs[i] = txs[i];
        }
        runWith(
            vm.envAddress("GANG_PAD3"),
            vm.envAddress("GANGSWAP_MIGRATOR"),
            vm.envAddress("GANGSWAP_ROUTER"),
            open,
            vm.envOr("GANGSWAP_REPLACE", false),
            vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0))
        );
    }

    /// @dev `run` with its inputs passed in (tests: no process-wide env between parallel tests).
    function runWith(address pad, address migrator, address router, bool open, bool replace, uint256 pk) public {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert Check("chain: BSC mainnet or testnet only");
        if (mainnet && pad != MAINNET_PAD3) revert Check("GANG_PAD3 is not the mainnet 3.0 proxy");
        address owner = Ownable(pad).owner();
        if (mainnet && owner != M.OWNER_SAFE) revert Check("pad owner is not the Safe");
        if (_buildHash() != BUILD) revert Check("gangswap/out is not this commit's build");
        _checkCurrent(pad, migrator, open, replace);
        Version memory v = _version(pad, migrator, router, owner);
        (address[] memory to, bytes[] memory data) = _batch(pad, v, open);
        if (open) _checkOldVersions(pad, v);

        uint256 snap = vm.snapshotState();
        _send(to, data, owner);
        if (!open) {
            vm.prank(owner);
            IGangSwapPad(pad).setGangSwapMigrator(migrator);
        }
        _checkOpen(pad, v);
        _rehearse(pad, v, owner);
        if (!vm.revertToState(snap)) revert Check("rollback");
        console.log("checked: code, wiring, owners; rehearsed: create, graduate, boost, router, fees");

        if (!mainnet && pk != 0 && vm.addr(pk) == owner) {
            vm.startBroadcast(pk);
            _send(to, data, address(0));
            vm.stopBroadcast();
            if (open) _checkOpen(pad, v);
            console.log(_broadcasting() ? "sent (testnet)" : "simulated only: add --broadcast to send");
            return;
        }
        console.log(
            open
                ? "\n=== Safe batch: open createGangSwap (setGangSwapMigrator, effective at once) ==="
                : "\n=== Safe batch: list the pad and the fee contract (createGangSwap stays as it is) ==="
        );
        if (open) {
            console.log("Only once the keeper, indexer, website and CLI serve this version (not checked here).");
        }
        console.log(_json(mainnet, owner, open, to, data));
    }

    // ---------------------------------------------------------------- checks
    function _checkCurrent(address pad, address migrator, bool open, bool replace) internal view {
        (bool ok, bytes memory ret) = pad.staticcall(abi.encodeCall(IGangSwapPad.gangSwapMigrator, ()));
        if (!ok || ret.length != 32) revert Check("pad does not serve GangSwap: upgrade it first");
        address current = abi.decode(ret, (address));
        if (current == address(0)) return;
        if (current == migrator) {
            // `list` stays possible: it repairs a live version that lost its fee operator
            if (open) revert Check("already open with this version");
            return;
        }
        if (!replace) revert Check("a version is already set: GANGSWAP_REPLACE=true to replace it");
        console.log("replaces, for new tokens, the current version", current);
        _checkOldFees(current);
    }

    /// @dev Every version a token graduates through (a walk of the pad's tokens) keeps its fee operator: its tokens keep
    ///      paying fees whatever new tokens get.
    function _checkOldVersions(address pad, Version memory v) internal view {
        GangLaunchpad3 p = GangLaunchpad3(payable(pad));
        address last;
        uint256 n = p.tokenCount();
        for (uint256 i; i < n; i++) {
            address own = IGangSwapPad(pad).gangSwapMigratorOf(p.allTokens(i));
            if (own == address(0) || own == last || own == v.migrator) continue;
            last = own;
            _checkOldFees(own);
        }
    }

    function _checkOldFees(address migrator) internal view {
        address fees = IOpenFactory(IOpenMigrator(migrator).factory()).fees();
        if (!SharedPlatformFeeBucket(IOpenFees(fees).bucket()).operators(fees)) {
            revert Check("an older version's fee contract is no bucket operator");
        }
    }

    /// @dev The version's contracts, read from the migrator; each one this build's code, wired to the others.
    function _version(address pad, address migrator, address router, address owner)
        internal
        returns (Version memory v)
    {
        GangLaunchpad3 p = GangLaunchpad3(payable(pad));
        address wbnb = p.wbnb();
        if (migrator.code.length == 0 || router.code.length == 0) revert Check("GANGSWAP_MIGRATOR / GANGSWAP_ROUTER");
        IOpenMigrator m = IOpenMigrator(migrator);
        v.migrator = migrator;
        v.router = router;
        v.factory = m.factory();
        v.boost = m.boost();
        v.fees = IOpenFactory(v.factory).fees();
        v.bucket = IOpenFees(v.fees).bucket();
        if (v.bucket != address(p.platformBucket())) revert Check("fee bucket is not the pad's");
        if (Ownable(migrator).owner() != owner || Ownable(v.bucket).owner() != owner) {
            revert Check("the pad, the migrator and the fee bucket must have the same owner");
        }
        if (
            Ownable2Step(pad).pendingOwner() != address(0) || Ownable2Step(migrator).pendingOwner() != address(0)
                || _pending(v.bucket) != address(0)
        ) revert Check("an ownership transfer is pending");

        _sameCode(0, migrator, abi.encode(owner, v.factory, v.boost, wbnb));
        _sameCode(1, v.boost, abi.encode(migrator, wbnb));
        _sameCode(2, v.fees, abi.encode(v.factory, migrator, v.bucket, wbnb));
        _sameCode(3, v.factory, abi.encode(migrator, v.fees));
        _sameCode(4, router, abi.encode(v.factory, wbnb));
        if (m.quote() != wbnb || !m.wired()) revert Check("migrator quote / wired");
        // another pad could take a token's pair first, and that token would never graduate
        address[] memory pads = GangPadRegistry(address(p.padRegistry())).pads();
        for (uint256 i; i < pads.length; i++) {
            if (pads[i] != pad && m.launchpads(pads[i])) revert Check("the migrator lists another pad");
        }
        // never listed, so nothing graduated through it
        if (!m.launchpads(pad) && IOpenFactory(v.factory).allPairsLength() != 0) {
            revert Check("the factory has pairs already");
        }
    }

    /// @dev `a` runs exactly what this build deploys with `args` (its immutables; state is checked by `wired()`).
    function _sameCode(uint256 i, address a, bytes memory args) internal {
        string memory artifact = _artifact(i);
        address ref = deployCode(string.concat("gangswap/out/", artifact, ".json"), args);
        if (a.codehash != ref.codehash) revert Check(string.concat("code is not this build's: ", artifact));
        _checkCreation(i, a, bytes.concat(vm.getCode(string.concat("gangswap/out/", artifact, ".json")), args));
    }

    /// @dev The runtime code cannot show what a look-alike constructor wrote to storage (a listed pad, a pair): `a` was
    ///      created, by the transaction GANGSWAP_DEPLOY_TXS names, with exactly this build's creation code and
    ///      arguments. With the migrator's first owner among them, only that owner can have listed a pad since.
    function _checkCreation(uint256 i, address a, bytes memory initCode) internal virtual {
        string memory params = string.concat('["', vm.toString(_txs[i]), '"]');
        string memory receipt = vm.rpcJson("eth_getTransactionReceipt", params);
        if (vm.parseJsonAddress(receipt, ".contractAddress") != a) {
            revert Check(string.concat("GANGSWAP_DEPLOY_TXS: another contract: ", _artifact(i)));
        }
        string memory t = vm.rpcJson("eth_getTransactionByHash", params);
        if (keccak256(vm.parseJsonBytes(t, ".input")) != keccak256(initCode)) {
            revert Check(string.concat("creation code is not this build's: ", _artifact(i)));
        }
    }

    function _artifact(uint256 i) internal pure returns (string memory) {
        if (i == 0) return "GangSwapMigrator.sol/GangSwapMigrator";
        if (i == 1) return "GangSwapBoost.sol/GangSwapBoost";
        if (i == 2) return "GangSwapFees.sol/GangSwapFees";
        if (i == 3) return "GangSwapPair.sol/GangSwapFactory";
        return "GangSwapRouter.sol/GangSwapRouter";
    }

    function _buildHash() internal view virtual returns (bytes32 h) {
        for (uint256 i; i < 5; i++) {
            h = keccak256(abi.encode(h, vm.getCode(string.concat("gangswap/out/", _artifact(i), ".json"))));
        }
    }

    function _pending(address a) internal view returns (address) {
        (bool ok, bytes memory ret) = a.staticcall(abi.encodeCall(Ownable2Step.pendingOwner, ()));
        return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
    }

    function _batch(address pad, Version memory v, bool open)
        internal
        view
        returns (address[] memory to, bytes[] memory data)
    {
        bool listed = IOpenMigrator(v.migrator).launchpads(pad);
        bool operator = SharedPlatformFeeBucket(v.bucket).operators(v.fees);
        if (open) {
            if (!listed || !operator) revert Check("the list step is not on chain yet");
            to = new address[](1);
            data = new bytes[](1);
            (to[0], data[0]) = (pad, abi.encodeCall(IGangSwapPad.setGangSwapMigrator, (v.migrator)));
            return (to, data);
        }
        if (listed && operator) revert Check("already listed: go on with GANGSWAP_STEP=open");
        uint256 n;
        to = new address[](2);
        data = new bytes[](2);
        if (!listed) (to[n], data[n++]) = (v.migrator, abi.encodeCall(IOpenMigrator.addLaunchpad, (pad)));
        if (!operator) {
            (to[n], data[n++]) = (v.bucket, abi.encodeCall(SharedPlatformFeeBucket.setOperator, (v.fees, true)));
        }
        assembly ("memory-safe") {
            mstore(to, n)
            mstore(data, n)
        }
    }

    /// @dev Each call as `prank` (the simulation) or, with 0, as the broadcaster.
    function _send(address[] memory to, bytes[] memory data, address prank) internal {
        for (uint256 i; i < to.length; i++) {
            if (prank != address(0)) vm.prank(prank);
            (bool ok,) = to[i].call(data[i]);
            if (!ok) revert Check("a batch call reverts");
        }
    }

    function _checkOpen(address pad, Version memory v) internal view {
        if (IGangSwapPad(pad).gangSwapMigrator() != v.migrator) revert Check("read back: gangSwapMigrator");
        if (!IOpenMigrator(v.migrator).launchpads(pad)) revert Check("read back: launchpads");
        if (!SharedPlatformFeeBucket(v.bucket).operators(v.fees)) revert Check("read back: bucket operator");
    }

    // ---------------------------------------------------------------- the rehearsal (simulation only)
    function _rehearse(address pad, Version memory v, address owner) internal {
        GangLaunchpad3 p = GangLaunchpad3(payable(pad));
        address wbnb = p.wbnb();
        address who = makeAddr("gangswap rehearsal");
        address registry = address(p.agentIdRegistry());
        vm.startPrank(owner);
        if (p.agentGateEnabled()) p.setAgentGate(false, registry);
        if (p.walletCapEnabled()) p.setWalletCapEnabled(false);
        vm.stopPrank();

        address t = _create(pad, v.migrator, who);
        if (p.kindOf(t) != Pad3GangSwapStore.KIND || IGangSwapPad(pad).gangSwapMigratorOf(t) != v.migrator) {
            revert Check("rehearsal: create");
        }
        (address rp, uint8 kind) = GangPadRegistry(address(p.padRegistry())).lookup(t);
        if (rp != pad || kind != Pad3GangSwapStore.KIND) revert Check("rehearsal: the registry does not know kind 4");

        vm.deal(who, 20 ether);
        vm.startPrank(who, who);
        IOpenWbnb(wbnb).deposit{value: 14 ether}();
        IERC20(wbnb).approve(pad, 2 * G);
        p.buy(t, 2 * G, 0);
        vm.stopPrank();
        (uint8 st,, address pair,,) = p.getTokenInfo(t);
        if (st != 4 || pair == address(0) || IOpenFactory(v.factory).getPair(t, wbnb) != pair) {
            revert Check("rehearsal: graduation");
        }
        (address bp,,, uint128 total,) = IOpenBoost(v.boost).boosts(t);
        if (bp != pair || total == 0) revert Check("rehearsal: boost");
        IOpenBoost(v.boost).step(t);

        _swap(v.router, wbnb, t, 1 ether, who);
        _swap(v.router, t, wbnb, IERC20(t).balanceOf(who), who);
        uint256 accrued = SharedPlatformFeeBucket(v.bucket).accruedQuote(wbnb);
        uint256 parked = IOpenFees(v.fees).pendingPlatform();
        uint256 got = IOpenFees(v.fees).collect(pair);
        if (
            got == 0
                || SharedPlatformFeeBucket(v.bucket).accruedQuote(wbnb) - accrued != parked + got - got * 7000 / 10_000
                || IOpenFees(v.fees).pendingPlatform() != 0
        ) revert Check("rehearsal: fees");
    }

    function _create(address pad, address migrator, address who) internal returns (address t) {
        Pad3Module m = Pad3Module(payable(pad));
        bytes memory data = abi.encodeCall(IGangSwapPad.createGangSwap, ("Rehearsal", "GSR", "", "", G, migrator));
        address f = m.vanityDeployer();
        if (f == address(0)) {
            vm.prank(who, who);
            return IGangSwapPad(pad).createGangSwap("Rehearsal", "GSR", "", "", G, migrator);
        }
        bytes32 hash = Pad3VanityDeployer(f).tokenInitCodeHash("Rehearsal", "GSR", "", address(0), 0, 0, false);
        (bytes32 salt,) = Pad3VanitySalt.find(f, who, hash);
        vm.prank(who, who);
        t = m.createWithSalt(salt, data);
    }

    /// @dev A swap on the router at exactly its quote.
    function _swap(address router, address a, address b, uint256 amount, address who) internal {
        address[] memory path = new address[](2);
        (path[0], path[1]) = (a, b);
        uint256 out = IOpenRouter(router).getAmountsOut(amount, path)[1];
        uint256 had = IERC20(b).balanceOf(who);
        vm.startPrank(who, who);
        IERC20(a).approve(router, amount);
        IOpenRouter(router).swapExactTokensForTokens(amount, out, path, who, block.timestamp);
        vm.stopPrank();
        if (out == 0 || IERC20(b).balanceOf(who) - had != out) revert Check("rehearsal: router");
    }

    // ---------------------------------------------------------------- output
    function _json(bool mainnet, address safe, bool open, address[] memory to, bytes[] memory data)
        internal
        pure
        returns (string memory j)
    {
        j = string.concat(
            '{"version":"1.0","chainId":"',
            mainnet ? "56" : "97",
            '","createdAt":0,"meta":{"name":"gang: ',
            open ? "open GangSwap (setGangSwapMigrator)" : "list GangSwap (addLaunchpad, fee operator)",
            '","txBuilderVersion":"1.16.5","createdFromSafeAddress":"',
            vm.toString(safe),
            '"},"transactions":['
        );
        for (uint256 i; i < to.length; i++) {
            j = string.concat(
                j,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(to[i]),
                '","value":"0","data":"',
                vm.toString(data[i]),
                '","contractMethod":null,"contractInputsValues":null}'
            );
        }
        j = string.concat(j, "]}");
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _broadcasting() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }
}
