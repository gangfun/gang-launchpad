// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";

interface IGangRouterTier {
    function v3BuyBNB(address token, uint256 minTokensOut, uint256 deadline) external payable returns (uint256);
}

interface IMintableQuoteTier {
    function mintUnlimited(address to, uint256 amount) external;
}

/// @title GangLaunchpad2TierMatrixTestnet — every graduation tier of GangLaunchpad 2.0 on BSC testnet
/// @notice For each tier (6 / 9 / 12 / 15 BNB), with the deploy wallet (the 2.0 owner and an Agent ID holder):
///         - a WBNB token with one small buy through the 2.0 router (the badge reads "<tier> BNB");
///         - a test-quote token bought to half its graduation amount (not graduated; progress about 50%);
///         - a taxed test-quote token bought past it: graduated through the live migrator, the pool opened at about
///           5x the target, the creator fee claimed.
///         These tokens are the fixtures the backend and the site are checked against. The wallet cap is off only
///         for the run.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, GANG_PAD2, GANG_ROUTER2, TEST_QUOTE (default the testnet one).
contract GangLaunchpad2TierMatrixTestnet is Script {
    error WrongChain(uint256 chainId);
    error Check(string what);

    function run() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        IGangPad pad = IGangPad(vm.envAddress("GANG_PAD2"));
        address router = vm.envAddress("GANG_ROUTER2");
        address q = vm.envOr("TEST_QUOTE", T.TEST_QUOTE);
        if (pad.CREATOR_FEE_SHARE_BPS() != 7_000) revert Check("not a 2.0 pad");
        if (Ownable(address(pad)).owner() != me) revert Check("deploy wallet is not the 2.0 owner");
        if (!pad.isAgent(me)) revert Check("deploy wallet holds no Agent ID");

        uint256[4] memory tiers = pad.GRAD_BNB_TIERS();
        vm.startBroadcast(pk);
        IERC20(q).approve(address(pad), type(uint256).max);
        if (pad.walletCapEnabled()) pad.setWalletCapEnabled(false);
        vm.stopBroadcast();
        for (uint256 i; i < 4; i++) {
            _tier(pad, router, q, pk, me, tiers[i]);
        }
        vm.startBroadcast(pk);
        pad.setWalletCapEnabled(true);
        vm.stopBroadcast();
        if (!pad.walletCapEnabled()) revert Check("wallet cap back on");
        console.log("tier matrix ok");
    }

    function _tier(IGangPad pad, address router, address q, uint256 pk, address me, uint256 gradBnb) internal {
        string memory n = vm.toString(gradBnb / 1 ether);
        IGangLaunchpad.TaxConfig memory untaxed =
            IGangLaunchpad.TaxConfig({buyTaxBps: 0, sellTaxBps: 0, dividendBps: 0, recipient: address(0)});
        IGangLaunchpad.TaxConfig memory taxed =
            IGangLaunchpad.TaxConfig({buyTaxBps: 300, sellTaxBps: 300, dividendBps: 4_000, recipient: me});
        uint256 grad = pad.graduationAmountFor(q, address(0), gradBnb);

        vm.startBroadcast(pk);
        address w = pad.createWithGradTarget(
            string.concat("Tier ", n, " WBNB"),
            string.concat("T", n, "W"),
            "",
            "",
            address(0),
            address(0),
            untaxed,
            gradBnb
        );
        IGangRouterTier(router).v3BuyBNB{value: 0.001 ether}(w, 0, block.timestamp + 600);
        address h = pad.createWithGradTarget(
            string.concat("Tier ", n, " Half"), string.concat("T", n, "H"), "", "", q, address(0), untaxed, gradBnb
        );
        address g = pad.createWithGradTarget(
            string.concat("Tier ", n, " Grad"), string.concat("T", n, "G"), "", "", q, address(0), taxed, gradBnb
        );
        IMintableQuoteTier(q).mintUnlimited(me, grad * 2);
        pad.buy(h, grad / 2, 0);
        pad.buy(g, (grad * 3) / 2, 0);
        vm.stopBroadcast();

        if (pad.gradTargetOf(w) != gradBnb || pad.gradAmtOf(w) != gradBnb) revert Check("WBNB token: target");
        if (pad.gradTargetOf(h) != gradBnb || pad.gradAmtOf(h) != grad) revert Check("half token: target");
        if (pad.gradTargetOf(g) != gradBnb || pad.gradAmtOf(g) != grad) revert Check("graduated token: target");
        (,, uint128 realQuote,,,, bool hGrad,,,,,) = pad.curves(h);
        if (hGrad || realQuote >= grad) revert Check("half token graduated");
        (,,,,,, bool gGrad,,,, address pair,) = pad.curves(g);
        if (!gGrad || pair == address(0)) revert Check("graduated token: not graduated");
        uint256 mcap = (IERC20(q).balanceOf(pair) * pad.TOTAL_SUPPLY()) / IERC20(g).balanceOf(pair);
        if (mcap < (5 * grad * 97) / 100 || mcap > (5 * grad * 103) / 100) revert Check("pool at ~5x the target");

        uint256 owed = pad.creatorFeeOf(g);
        uint256 q0 = IERC20(q).balanceOf(me);
        vm.startBroadcast(pk);
        pad.claimCreatorFee(g, me);
        vm.stopBroadcast();
        if (IERC20(q).balanceOf(me) - q0 != owed || owed == 0) revert Check("claim after graduation");

        console.log(string.concat("tier ", n, " BNB, graduation amount (test quote wei)"), grad);
        console.log("  WBNB  ", w);
        console.log("  half  ", h, realQuote);
        console.log("  grad  ", g, pair);
    }
}
