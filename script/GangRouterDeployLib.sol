// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GangRouter} from "../src/router/GangRouter.sol";
import {GangMainnetRefs as M} from "../config/GangDeployRefs.sol";

/// @dev What the self-check asks the Pancake V2 router (Router02 getters).
interface IPancakeV2RouterRefs {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

/// @title GangRouterDeployLib — the upgradeable GangRouter (AUDIT-BRIEF §21): deploy and read-back self-check
/// @notice One shape everywhere (DeployGang, DeployGangRouterUpgradeable, the tests):
///           impl      = GangRouter (its constructor locks it: never initializable)
///           timelock  = TimelockController(minDelay, proposers = [safe], executors = [safe], admin = address(0));
///                       OZ 5.1 also makes every proposer a canceller, and the timelock is its own only admin
///           proxy     = TransparentUpgradeableProxy(impl, timelock, initialize(pad, wbnb, pancakeRouter)) — initialized in its own
///                       constructor (no front-run window); it deploys its ProxyAdmin (owner = timelock)
///         The pad lists the PROXY (setRouter); an upgrade is timelock.schedule → wait minDelay → timelock.execute of
///         ProxyAdmin.upgradeAndCall(proxy, newImpl, data), both from the Safe.
/// @dev Internal functions only (inlined into the calling script: `new` broadcasts from its deployer).
library GangRouterDeployLib {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Mainnet timelock delay, fixed: an upgrade is public this long before it can run.
    uint256 internal constant MAINNET_MIN_DELAY = 48 hours;
    /// @dev ERC-1967 slots (ERC1967Utils.IMPLEMENTATION_SLOT / ADMIN_SLOT).
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    /// @dev Initializable's ERC-7201 slot: uint64 _initialized (low 8 bytes), bool _initializing (next byte).
    bytes32 internal constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    struct Router {
        /// @dev the address the pad lists and users approve (GANG_ROUTER)
        address proxy;
        address impl;
        address proxyAdmin;
        address timelock;
    }

    /// @dev What the read-back must find.
    struct Expect {
        address pad;
        address wbnb;
        /// @dev PancakeSwap V2 router of the pool entries, and the factory / WETH it must answer
        address pancakeRouter;
        address pancakeFactory;
        /// @dev the timelock's only proposer / executor / canceller (mainnet: must be the platform Safe M.OWNER_SAFE)
        address safe;
        /// @dev must hold no timelock role (mainnet: always; testnet: unless it is also `safe`, a stack the deployer
        ///      keeps for upgrade rehearsals)
        address deployer;
        uint256 minDelay;
        /// @dev mainnet rules: safe == M.OWNER_SAFE, the deployer holds nothing even if it is the OWNER
        bool mainnet;
    }

    error WiringCheck(string what);
    error MainnetTimelockDelay(uint256 delay);
    error MainnetTimelockNotSafe(address safe);

    /// @notice Who runs the router timelock: on mainnet always the platform Safe (whoever OWNER is, even with
    ///         MAINNET_OWNER_IS_DEPLOYER=true); on testnet `owner`.
    function timelockSafe(bool mainnet, address owner) internal pure returns (address) {
        return mainnet ? M.OWNER_SAFE : owner;
    }

    /// @notice ROUTER_TIMELOCK_DELAY (seconds), default 48 h. Mainnet: fixed at 48 h, anything else is refused.
    ///         Testnet: any value (a short one to rehearse an upgrade).
    function minDelayFromEnv(bool mainnet) internal view returns (uint256 d) {
        d = vm.envOr("ROUTER_TIMELOCK_DELAY", MAINNET_MIN_DELAY);
        if (mainnet && d != MAINNET_MIN_DELAY) revert MainnetTimelockDelay(d);
    }

    /// @notice impl → timelock → proxy (initialized in its constructor). Does NOT list it on the pad.
    function deploy(address pad, address wbnb, address pancakeRouter, address safe, uint256 minDelay)
        internal
        returns (Router memory r)
    {
        // a mainnet router timelock belongs to the platform Safe and nobody else
        if (block.chainid == 56 && safe != M.OWNER_SAFE) revert MainnetTimelockNotSafe(safe);
        r.impl = address(new GangRouter());
        address[] memory only = new address[](1);
        only[0] = safe;
        r.timelock = address(new TimelockController(minDelay, only, only, address(0)));
        r.proxy = address(
            new TransparentUpgradeableProxy(
                r.impl, r.timelock, abi.encodeCall(GangRouter.initialize, (pad, wbnb, pancakeRouter))
            )
        );
        r.proxyAdmin = adminOf(r.proxy);
    }

    /// @notice Read impl / ProxyAdmin / timelock back from a deployed proxy (re-run: only GANG_ROUTER is given).
    function load(address proxy) internal view returns (Router memory r) {
        r.proxy = proxy;
        r.impl = implementationOf(proxy);
        r.proxyAdmin = adminOf(proxy);
        if (r.proxyAdmin.code.length == 0) revert WiringCheck("router admin slot");
        r.timelock = ProxyAdmin(r.proxyAdmin).owner();
    }

    function implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function adminOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
    }

    /// @dev Start of Solidity's CBOR metadata: {"ipfs": bytes(34) = 0x1220 ‖ 32-byte hash, …}.
    bytes10 internal constant METADATA_IPFS = 0xa2646970667358221220;

    /// @notice `a`'s runtime code equals `want` apart from the IPFS hash of every Solidity metadata block in it (the
    ///         trailing one, and one per creation code embedded as data, e.g. TokenDeployer's GangToken): the hash
    ///         moves with the build's source set and settings while the code stays the same. Metadata is never
    ///         executed; every other byte, jump targets included, must match.
    function sameCode(address a, bytes memory want) internal view returns (bool) {
        return sameCode(a.code, want);
    }

    /// @dev Does not modify `got` or `want`: the hashes are masked in copies.
    function sameCode(bytes memory got, bytes memory want) internal pure returns (bool) {
        if (got.length != want.length) return false;
        bytes memory g = bytes.concat(got);
        bytes memory w = bytes.concat(want);
        for (uint256 i; i + 42 <= w.length; i++) {
            bytes10 mw;
            bytes10 mg;
            assembly {
                mw := mload(add(add(w, 32), i))
                mg := mload(add(add(g, 32), i))
            }
            if (mw != METADATA_IPFS) continue;
            if (mg != METADATA_IPFS) return false;
            assembly {
                mstore(add(add(w, 42), i), 0)
                mstore(add(add(g, 42), i), 0)
            }
            i += 41;
        }
        return keccak256(g) == keccak256(w);
    }

    /// @return version Initializable._initialized of `a` (type(uint64).max = locked)
    /// @return initializing Initializable._initializing
    function initState(address a) internal view returns (uint64 version, bool initializing) {
        uint256 w = uint256(vm.load(a, INITIALIZABLE_SLOT));
        version = uint64(w);
        initializing = (w >> 64) & 0xff != 0;
    }

    /// @notice Everything about the upgradeable router, read back from chain. Any mismatch reverts with its name.
    ///         The pad's router list (proxy listed, impl / ProxyAdmin / timelock not) is checked by the caller.
    function check(Router memory r, Expect memory e) internal view {
        checkProxy(r, e);
        checkTimelock(r, e);
    }

    /// @dev The proxy's own runtime code is OZ 5.1's TransparentUpgradeableProxy (this build's artifact) with its one
    ///      immutable, `_admin`, equal to r.proxyAdmin: the artifact has zeros where the immutable goes, so every
    ///      32-byte word that is zero there and r.proxyAdmin in the deployed code is filled in, then the code must
    ///      match (`sameCode`: metadata aside). A look-alike with the same ERC-1967 slots but other code (a backdoor)
    ///      fails here.
    function checkProxyCode(Router memory r) internal view {
        bytes memory want = vm.getDeployedCode("TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy");
        bytes memory got = r.proxy.code;
        if (got.length != want.length || want.length < 32) revert WiringCheck("router proxy code");
        bytes32 adminWord = bytes32(uint256(uint160(r.proxyAdmin)));
        uint256 filled;
        for (uint256 p; p + 32 <= want.length; p++) {
            bytes32 w;
            bytes32 g;
            assembly {
                w := mload(add(add(want, 32), p))
                g := mload(add(add(got, 32), p))
            }
            if (w == bytes32(0) && g == adminWord) {
                assembly {
                    mstore(add(add(want, 32), p), adminWord)
                }
                filled++;
                p += 31;
            }
        }
        if (filled == 0 || !sameCode(got, want)) revert WiringCheck("router proxy code");
    }

    /// @dev Proxy (its own code) → impl (this build's GangRouter, locked) and → ProxyAdmin (the one the proxy deployed,
    ///      plain OZ code, owned by the timelock); the proxy itself initialized on the right pad / WBNB / Pancake.
    function checkProxy(Router memory r, Expect memory e) internal view {
        checkProxyCode(r);
        // ERC-1967 implementation slot = the implementation, and that is this build's GangRouter code
        if (r.impl == address(0) || implementationOf(r.proxy) != r.impl) revert WiringCheck("router impl slot");
        if (!sameCode(r.impl, type(GangRouter).runtimeCode)) revert WiringCheck("router impl code");
        // the implementation is locked by its constructor and holds no pad
        (uint64 implVersion,) = initState(r.impl);
        if (implVersion != type(uint64).max) revert WiringCheck("router impl locked");
        if (address(GangRouter(payable(r.impl)).pad()) != address(0)) revert WiringCheck("router impl locked");
        // admin slot = the ProxyAdmin the proxy's constructor created (its first CREATE), plain OZ ProxyAdmin code
        if (adminOf(r.proxy) != r.proxyAdmin || r.proxyAdmin != vm.computeCreateAddress(r.proxy, 1)) {
            revert WiringCheck("router admin slot");
        }
        if (!sameCode(r.proxyAdmin, type(ProxyAdmin).runtimeCode)) revert WiringCheck("router admin code");
        if (ProxyAdmin(r.proxyAdmin).owner() != r.timelock) revert WiringCheck("router admin owner");
        // the proxy: initialized (once, not mid-initialization), on this pad and WBNB
        (uint64 v, bool initializing) = initState(r.proxy);
        if (v == 0 || initializing) revert WiringCheck("router initialized");
        GangRouter g = GangRouter(payable(r.proxy));
        if (address(g.pad()) != e.pad || address(g.v3()) != e.pad || address(g.fair()) != e.pad) {
            revert WiringCheck("router pad");
        }
        if (g.wbnb() != e.wbnb) revert WiringCheck("router wbnb");
        if (address(g.pancakeRouter()) != e.pancakeRouter || e.pancakeRouter == address(0)) {
            revert WiringCheck("router pancakeRouter");
        }
        // and that address really is the Pancake V2 router of this chain: its factory and WETH
        IPancakeV2RouterRefs pr = IPancakeV2RouterRefs(e.pancakeRouter);
        if (pr.factory() != e.pancakeFactory || pr.WETH() != e.wbnb) revert WiringCheck("router pancake refs");
    }

    /// @dev The timelock: plain OZ code, delay at least the expected one, the Safe holds proposer / executor /
    ///      canceller, nobody else checked here holds anything, and only the timelock administers its roles.
    function checkTimelock(Router memory r, Expect memory e) internal view {
        TimelockController t = TimelockController(payable(r.timelock));
        // mainnet: the platform Safe, whatever OWNER the run was given
        if (e.mainnet && e.safe != M.OWNER_SAFE) revert WiringCheck("router timelock not the Safe");
        // the code, not the metadata hash: the live timelock was built from another source set (same OZ 5.1 code)
        if (!sameCode(r.timelock, type(TimelockController).runtimeCode)) revert WiringCheck("router timelock code");
        if (t.getMinDelay() < e.minDelay) revert WiringCheck("router timelock delay");
        bytes32 admin = t.DEFAULT_ADMIN_ROLE();
        bytes32[3] memory ops = [t.PROPOSER_ROLE(), t.EXECUTOR_ROLE(), t.CANCELLER_ROLE()];
        for (uint256 i; i < ops.length; i++) {
            if (!t.hasRole(ops[i], e.safe)) revert WiringCheck("router timelock safe roles");
            // address(0) as executor would let anyone execute a ready operation; as proposer / canceller it is nonsense
            if (t.hasRole(ops[i], address(0))) revert WiringCheck("router timelock open role");
            if (t.getRoleAdmin(ops[i]) != admin) revert WiringCheck("router timelock role admin");
        }
        // DEFAULT_ADMIN_ROLE: the timelock itself only (constructor admin = address(0)): roles change only through a
        // timelocked proposal
        if (!t.hasRole(admin, r.timelock)) revert WiringCheck("router timelock admin");
        address[4] memory notAdmin = [e.safe, e.deployer, address(0), r.proxyAdmin];
        for (uint256 i; i < notAdmin.length; i++) {
            if (t.hasRole(admin, notAdmin[i])) revert WiringCheck("router timelock admin");
        }
        // the deploy wallet keeps nothing: on mainnet always; on testnet unless it IS the owner (a stack left on the
        // deployer for upgrade rehearsals)
        if (e.mainnet || e.deployer != e.safe) {
            for (uint256 i; i < ops.length; i++) {
                if (t.hasRole(ops[i], e.deployer)) revert WiringCheck("router timelock deployer role");
            }
        }
    }
}
