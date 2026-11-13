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
/// @dev Env: DEPLOYER_PRIVATE_KEY; OWNER (default MainnetAddresses.OWNER); BURNER (an already deployed
///      RoutedBuybackBurner to print the batch for instead of deploying).
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

        vm.startBroadcast(pk);
        if (burner == address(0)) {
            burner =
                address(new RoutedBuybackBurner(owner, M.PANCAKE_V2_ROUTER, M.PANCAKE_SMART_ROUTER, M.WBNB, M.GANG));
            console.log("RoutedBuybackBurner deployed", burner);
        } else {
            _checkBurner(burner, owner);
            console.log("RoutedBuybackBurner reused", burner);
        }
        RoutedBuybackBurner b = RoutedBuybackBurner(burner);
        if (deployer == owner) {
            for (uint256 i; i < quotes.length; i++) {
                b.setV3Route(quotes[i], paths[i]);
            }
            if (bucket.owner() == deployer) bucket.setBurner(burner);
        }
        vm.stopBroadcast();

        if (deployer != owner || bucket.owner() != deployer) _printSafeBatch(burner, quotes, paths, bucket.owner());
    }

    /// @dev Safe Transaction Builder JSON: setV3Route per quote, then the shared bucket's setBurner (last, so the
    ///      bucket only moves once every route is in place).
    function _printSafeBatch(address burner, address[] memory quotes, bytes[] memory paths, address safe)
        internal
        pure
    {
        string memory txs;
        for (uint256 i; i < quotes.length; i++) {
            txs = string.concat(
                txs, _tx(burner, abi.encodeCall(RoutedBuybackBurner.setV3Route, (quotes[i], paths[i]))), ",\n"
            );
        }
        txs = string.concat(txs, _tx(SHARED_BUCKET, abi.encodeCall(ISharedPlatformFeeBucket.setBurner, (burner))));
        console.log("=== Safe batch (Transaction Builder JSON) ===");
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

    /// @dev A reused burner must be wired like a fresh deploy and owned by OWNER.
    function _checkBurner(address a, address owner) internal view {
        RoutedBuybackBurner b = RoutedBuybackBurner(a);
        if (
            a.code.length == 0 || b.owner() != owner || b.gang() != M.GANG || b.wbnb() != M.WBNB
                || address(b.router()) != M.PANCAKE_V2_ROUTER || b.smartRouter() != M.PANCAKE_SMART_ROUTER
        ) revert BadBurner(a);
    }
}
