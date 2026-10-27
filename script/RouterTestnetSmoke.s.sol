// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchpadV3TestnetRefs as T} from "../config/LaunchpadV3DeployRefs.sol";
import {GangLaunchpad as LaunchpadV3} from "../src/gang/GangLaunchpad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad as ILaunchpadV3} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {GangLaunchpad as FairMintPad} from "../src/gang/GangLaunchpad.sol";
import {GangRouter} from "../src/router/GangRouter.sol";

interface IWBNBDeposit {
    function deposit() external payable;
}

/// @title RouterTestnetSmoke — native BNB through GangRouter into both cores, on BSC testnet
/// @notice V3: create a WBNB-quoted tax token (2% / 2%, recipient = the demo treasury), buy 0.002 BNB of it through
///         router.v3BuyBNB. 打新: create a WBNB sale (5 BNB raise, the creator's 1 share paid in WBNB), mint 2 shares
///         through router.fairMintBNB sending more than needed (the rest comes back as BNB). Checks the trader, not the
///         router, holds the tokens / shares and the router ends empty.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY (an Agent ID holder), V3_PAD, FAIR_PAD, GANG_ROUTER.
contract RouterTestnetSmoke is Script {
    error WrongChain(uint256 chainId);
    error Check(string what);

    function run() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        LaunchpadV3 v3 = LaunchpadV3(vm.envAddress("V3_PAD"));
        FairMintPad fair = FairMintPad(vm.envAddress("FAIR_PAD"));
        GangRouter router = GangRouter(payable(vm.envAddress("GANG_ROUTER")));
        address treasury = T.DEMO_TREASURY;

        vm.startBroadcast(pk);
        address v3Token = v3.create(
            "Router V3 Test",
            "RV3",
            "",
            "",
            address(0),
            address(0),
            ILaunchpadV3.TaxConfig({buyTaxBps: 200, sellTaxBps: 200, dividendBps: 0, recipient: treasury})
        );
        uint256 out = router.v3BuyBNB{value: 0.002 ether}(v3Token, 1, block.timestamp + 1 days);

        // creator's own share: 5 BNB / 10,000 = 0.0005 WBNB + 1% mint fee, paid to the core directly
        IWBNBDeposit(T.WBNB).deposit{value: 0.000505 ether}();
        IERC20(T.WBNB).approve(address(fair), 0.000505 ether);
        address sale = fair.create(
            "Router Fair Test",
            "RFT",
            "",
            "",
            address(0),
            address(0),
            IGangLaunchpad.MintConfig({raiseBnb: 5 ether, capBps: 50, holdBps: 5000, mintFeeBps: 100, exitFeeBps: 100}),
            1
        );
        uint256 accepted = router.fairMintBNB{value: 0.002 ether}(sale, 2, 2, block.timestamp + 1 days);
        vm.stopBroadcast();

        if (out == 0 || IERC20(v3Token).balanceOf(me) != out) revert Check("v3 tokens not with the trader");
        uint16 shares = fair.positions(sale, me);
        if (accepted != 2 || shares != 3) revert Check("fair shares not with the trader");
        if (IERC20(T.WBNB).balanceOf(address(router)) != 0 || address(router).balance != 0) {
            revert Check("router not empty");
        }
        console.log("v3 token", v3Token, "tokens", out);
        console.log("fair sale", sale, "shares", shares);
    }
}
