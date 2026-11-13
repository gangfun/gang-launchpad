// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MainnetAddresses as M} from "../config/MainnetAddresses.sol";
import {RoutedBuybackBurner} from "../src/buyback/RoutedBuybackBurner.sol";

/// @dev The shared bucket calls used here (not imported: src/common is compiled with via-IR, see foundry.toml).
interface ISharedPlatformFeeBucket {
    function burner() external view returns (address);
    function owner() external view returns (address);
    function setBurner(address burner_) external;
}

interface IV3Quoter {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256);
}

/// @title DeployRoutedBuybackBurner — Pancake V3 routes for the SharedPlatformFeeBucket's stuck stock quotes (BSC 56)
/// @notice Deploys RoutedBuybackBurner owned by OWNER (the Safe), then prints the Safe Transaction Builder batch that
///         sets the V3 routes and points the shared bucket (LaunchpadV3 / 打新 / Flywheel cores) at it. When the
///         deploy key is OWNER (testing), it sends those calls itself. V2 / U / S buckets are not touched: they keep
///         GangBuybackBurner and its collectPlatformSmart.
///         Every route is quoted on Pancake V3 first; one that does not quote stops the run.
/// @dev Env: DEPLOYER_PRIVATE_KEY; OWNER (default MainnetAddresses.OWNER); BURNER (a RoutedBuybackBurner already
///      deployed from this build, checked against a simulated fresh deploy, to wire instead of deploying one).
///      Dry run: forge script script/DeployRoutedBuybackBurner.s.sol --rpc-url bsc
///      Broadcast: add --broadcast --verify
contract DeployRoutedBuybackBurner is Script {
    address internal constant SHARED_BUCKET = 0xB8C4B68a62513240A5e44EFd78fFc35ac25bA21b;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    error WrongChain(uint256 got);
    error BadBurner(address burner);
    error RouteDoesNotQuote(address quote);

    /// @dev Stock quotes stuck in the shared bucket on 2026-11-13 (no fair Pancake V2 route; deep on V3 against USDT).
    ///      USDT → WBNB on the 0.01% pool, the deepest of the four tiers.
    function _routes() internal pure returns (address[] memory q, bytes[] memory p) {
        q = new address[](4);
        q[0] = 0x24B518b332543a4E1C3649d063daB199d103760a; // oANTHROPIC
        q[1] = 0xBE82F76637DBA2C114C41Df856c2C51e522E2Cb8; // EWYB
        q[2] = 0x41333Df9E7639188BBfca5522dC4844398Af9f9E; // wTCENTx
        q[3] = 0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec; // BABAB (has a V2 pair, too thin: ~5.6% impact)
        p = new bytes[](4);
        for (uint256 i; i < 4; i++) {
            p[i] = abi.encodePacked(q[i], uint24(2500), USDT, uint24(100), M.WBNB);
        }
    }

    function run() external {
        if (block.chainid != 56) revert WrongChain(block.chainid);
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", M.OWNER);
        address burner = vm.envOr("BURNER", address(0));
        ISharedPlatformFeeBucket bucket = ISharedPlatformFeeBucket(SHARED_BUCKET);

        (address[] memory quotes, bytes[] memory paths) = _routes();
        for (uint256 i; i < quotes.length; i++) {
            (bool ok, bytes memory ret) = V3_QUOTER.call(abi.encodeCall(IV3Quoter.quoteExactInput, (paths[i], 1e15)));
            if (!ok || abi.decode(ret, (uint256)) == 0) revert RouteDoesNotQuote(quotes[i]);
        }

        console.log("=== DeployRoutedBuybackBurner ===");
        console.log("deployer", deployer);
        console.log("owner", owner);
        console.log("shared bucket", SHARED_BUCKET, "burner now", bucket.burner());

        if (burner != address(0)) _checkBurner(burner, owner);
        vm.startBroadcast(pk);
        if (burner == address(0)) {
            burner =
                address(new RoutedBuybackBurner(owner, M.PANCAKE_V2_ROUTER, M.PANCAKE_SMART_ROUTER, M.WBNB, M.GANG));
            console.log("RoutedBuybackBurner deployed", burner);
        } else {
            console.log("RoutedBuybackBurner reused", burner);
        }
        // What the deploy key may do itself; the rest goes into a Safe batch per signer (routes: the burner's owner,
        // setBurner: the bucket's owner — the same Safe on mainnet, so one batch, routes first).
        address bucketOwner = bucket.owner();
        bool routesHere = deployer == owner;
        bool switchHere = routesHere && bucketOwner == deployer;
        if (routesHere) {
            for (uint256 i; i < quotes.length; i++) {
                RoutedBuybackBurner(burner).setV3Route(quotes[i], paths[i]);
            }
        }
        if (switchHere) bucket.setBurner(burner);
        vm.stopBroadcast();

        if (!routesHere && owner == bucketOwner) {
            _printSafeBatch(owner, burner, quotes, paths, true);
        } else {
            if (!routesHere) _printSafeBatch(owner, burner, quotes, paths, false);
            if (!switchHere) _printSafeBatch(bucketOwner, burner, new address[](0), new bytes[](0), true);
        }
    }

    /// @dev Safe Transaction Builder JSON for `safe`: setV3Route per quote, then (withSwitch) the shared bucket's
    ///      setBurner — last, so the bucket only moves once every route is in place.
    function _printSafeBatch(
        address safe,
        address burner,
        address[] memory quotes,
        bytes[] memory paths,
        bool withSwitch
    ) internal pure {
        string memory txs;
        for (uint256 i; i < quotes.length; i++) {
            txs = string.concat(
                txs,
                i == 0 ? "" : ",\n",
                _tx(burner, abi.encodeCall(RoutedBuybackBurner.setV3Route, (quotes[i], paths[i])))
            );
        }
        if (withSwitch) {
            txs = string.concat(
                txs,
                quotes.length == 0 ? "" : ",\n",
                _tx(SHARED_BUCKET, abi.encodeCall(ISharedPlatformFeeBucket.setBurner, (burner)))
            );
        }
        console.log("=== Safe batch (Transaction Builder JSON) for", safe, "===");
        console.log(
            string.concat(
                '{\n  "version": "1.0",\n  "chainId": "56",\n  "createdAt": 0,\n  "meta": {\n',
                '    "name": "gang: Pancake V3 routes for the shared bucket stock quotes (RoutedBuybackBurner)",\n',
                '    "txBuilderVersion": "1.16.5",\n    "createdFromSafeAddress": "',
                vm.toString(safe),
                '"\n  },\n  "transactions": [\n',
                txs,
                "\n  ]\n}"
            )
        );
    }

    function _tx(address to, bytes memory data) internal pure returns (string memory) {
        return string.concat(
            '    {\n      "to": "',
            vm.toString(to),
            '",\n      "value": "0",\n      "data": "',
            vm.toString(data),
            '",\n      "contractMethod": null,\n      "contractInputsValues": null\n    }'
        );
    }

    /// @dev A reused burner must be this build's RoutedBuybackBurner wired like a fresh deploy (same runtime code as a
    ///      reference deployed in the simulation only: the immutables are part of it), owned by OWNER, with no owner
    ///      transfer pending.
    function _checkBurner(address a, address owner) internal {
        address ref =
            address(new RoutedBuybackBurner(owner, M.PANCAKE_V2_ROUTER, M.PANCAKE_SMART_ROUTER, M.WBNB, M.GANG));
        if (
            a.code.length == 0 || _hashSansMetadata(a.code) != _hashSansMetadata(ref.code)
                || RoutedBuybackBurner(a).owner() != owner || RoutedBuybackBurner(a).pendingOwner() != address(0)
        ) revert BadBurner(a);
    }

    /// @dev keccak256 of `code` without the CBOR metadata, whose length sits in the last two bytes (it hashes the
    ///      source, so an edit to a comment alone would otherwise not match).
    function _hashSansMetadata(bytes memory code) internal pure returns (bytes32 h) {
        uint256 n = code.length;
        if (n >= 2) {
            uint256 meta = ((uint256(uint8(code[n - 2])) << 8) | uint8(code[n - 1])) + 2;
            if (meta <= n) n -= meta;
        }
        assembly {
            h := keccak256(add(code, 0x20), n)
        }
    }
}
