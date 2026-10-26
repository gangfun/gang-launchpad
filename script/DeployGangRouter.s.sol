// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LaunchpadV3MainnetRefs as M, LaunchpadV3TestnetRefs as T} from "../config/LaunchpadV3DeployRefs.sol";
import {GangRouter} from "../src/router/GangRouter.sol";

interface IRouterListing {
    function setRouter(address router_, bool enabled) external;
    function routers(address router_) external view returns (bool);
    function wbnb() external view returns (address);
}

/// @title DeployGangRouter — the stateless entry in front of the LaunchpadV3 and 打新 cores (BSC 97 or 56)
/// @notice Deploys GangRouter(V3_PAD, FAIR_PAD, WBNB) and lists it on each core the deployer owns (setRouter); a core
///         owned by someone else (a multisig) is printed as PENDING. Either pad may be left unset (address(0)).
/// @dev Mainnet broadcast is refused unless GANG_ROUTER_MAINNET_OK=true (spec: no mainnet broadcast before audit).
///      Env: DEPLOYER_PRIVATE_KEY; V3_PAD and / or FAIR_PAD.
contract DeployGangRouter is Script {
    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error NoCore();
    error WrongCore(string what);

    function run() external returns (GangRouter router) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        if (mainnet && _broadcasting() && !vm.envOr("GANG_ROUTER_MAINNET_OK", false)) revert MainnetNotAllowed();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address v3 = vm.envOr("V3_PAD", address(0));
        address fair = vm.envOr("FAIR_PAD", address(0));
        if (v3 == address(0) && fair == address(0)) revert NoCore();
        address wbnb = mainnet ? M.WBNB : T.WBNB;
        // a wrong env value would deploy a router that cannot unwrap / settle against that core
        if (v3 != address(0) && IRouterListing(v3).wbnb() != wbnb) revert WrongCore("V3_PAD wbnb");
        if (fair != address(0) && IRouterListing(fair).wbnb() != wbnb) revert WrongCore("FAIR_PAD wbnb");
        // internal audit 5 C-F8: swapped V3_PAD / FAIR_PAD would deploy and list a router that can't trade either
        if (v3 != address(0) && !_has(v3, "TAXED_MIN_SHARE()")) revert WrongCore("V3_PAD is not LaunchpadV3");
        if (fair != address(0) && !_has(fair, "TOTAL_SHARES()")) revert WrongCore("FAIR_PAD is not FairMintPad");

        vm.startBroadcast(pk);
        router = new GangRouter(v3, fair, wbnb);
        bool v3Listed = _list(v3, address(router), deployer);
        bool fairListed = _list(fair, address(router), deployer);
        vm.stopBroadcast();

        console.log("GANG_ROUTER", address(router));
        if (v3 != address(0)) {
            if (v3Listed) require(IRouterListing(v3).routers(address(router)), "v3 listing");
            else console.log("PENDING V3 owner: setRouter(GANG_ROUTER, true) on", v3);
        }
        if (fair != address(0)) {
            if (fairListed) require(IRouterListing(fair).routers(address(router)), "fair listing");
            else console.log("PENDING fair owner: setRouter(GANG_ROUTER, true) on", fair);
        }
    }

    /// @dev Whether `target` answers the view `sig` (a getter only that core type has).
    function _has(address target, string memory sig) internal view returns (bool) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        return ok && ret.length == 32;
    }

    function _list(address core, address router, address deployer) internal returns (bool) {
        if (core == address(0) || Ownable(core).owner() != deployer) return false;
        IRouterListing(core).setRouter(router, true);
        return true;
    }

    function _broadcasting() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }
}
