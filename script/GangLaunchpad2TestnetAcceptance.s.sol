// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {SharedPlatformFeeBucket} from "../src/common/SharedPlatformFeeBucket.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";

interface IGangRouterBnb {
    function v3BuyBNB(address token, uint256 minTokensOut, uint256 deadline) external payable returns (uint256);
}

interface IMintableQuote {
    function mintUnlimited(address to, uint256 amount) external;
}

/// @title GangLaunchpad2TestnetAcceptance — the creator fee of GangLaunchpad 2.0 end to end on BSC testnet
/// @notice With the deploy wallet (an Agent ID holder and the 2.0 owner), each step checked in the simulation forge runs
///         before it broadcasts (re-run the script, or read the chain, to confirm what landed):
///         A. a WBNB curve token: buy 0.002 BNB through the 2.0 GangRouter (creator 70% / bucket 30% of the 1%), sell
///            half straight on the pad (70% of that fee kept too), claim to the wallet (paid in WBNB, counter 0).
///         B. a taxed test-quote token (the creator its own recipient): with the wallet cap off for the run (one
///            wallet can then graduate it; the cap is turned back on at the end), buy to graduation through the live
///            migrator, claim after graduation; the pad then holds no test quote beyond dust.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, GANG_PAD2, GANG_ROUTER2, TEST_QUOTE (default the testnet one).
///      The wallet cap is turned off and on in separate transactions: if the graduating buy fails on chain (forge
///      stops), the cap stays off. A re-run turns it back on first, but only if the rest of the re-run simulates
///      cleanly (forge sends nothing otherwise); else `cast send <pad> "setWalletCapEnabled(bool)" true`.
contract GangLaunchpad2TestnetAcceptance is Script {
    uint256 internal constant BPS = 10_000;

    error WrongChain(uint256 chainId);
    error Check(string what);

    function run() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        IGangPad pad = IGangPad(vm.envAddress("GANG_PAD2"));
        address router = vm.envAddress("GANG_ROUTER2");
        address testQuote = vm.envOr("TEST_QUOTE", T.TEST_QUOTE);
        if (pad.CREATOR_FEE_SHARE_BPS() != 7_000) revert Check("not a 2.0 pad");
        if (!pad.routers(router)) revert Check("router not listed");
        if (Ownable(address(pad)).owner() != me) revert Check("deploy wallet is not the 2.0 owner");
        if (!pad.isAgent(me)) revert Check("deploy wallet holds no Agent ID");
        if (!pad.walletCapEnabled()) {
            // an earlier run stopped between turning the cap off and on again
            vm.startBroadcast(pk);
            pad.setWalletCapEnabled(true);
            vm.stopBroadcast();
        }
        _wbnbCurve(pad, router, pk, me);
        _graduateAndClaim(pad, testQuote, pk, me);
        console.log("acceptance ok");
    }

    function _untaxed() internal pure returns (IGangLaunchpad.TaxConfig memory) {
        return IGangLaunchpad.TaxConfig({buyTaxBps: 0, sellTaxBps: 0, dividendBps: 0, recipient: address(0)});
    }

    function _part(uint256 fee) internal pure returns (uint256) {
        return (fee * 7_000) / BPS;
    }

    function _wbnbCurve(IGangPad pad, address router, uint256 pk, address me) internal {
        IERC20 wbnb = IERC20(pad.wbnb());
        SharedPlatformFeeBucket bucket = SharedPlatformFeeBucket(pad.platformBucket());

        vm.startBroadcast(pk);
        address t = pad.create("Creator Fee A", "CFA", "", "", address(0), address(0), _untaxed());
        vm.stopBroadcast();
        console.log("A token", t);

        uint256 acc0 = bucket.accruedQuote(address(wbnb));
        vm.startBroadcast(pk);
        IGangRouterBnb(router).v3BuyBNB{value: 0.002 ether}(t, 0, block.timestamp + 600);
        vm.stopBroadcast();
        uint256 fee = (0.002 ether * 100) / BPS;
        if (pad.creatorFeeOf(t) != _part(fee)) revert Check("A buy: creator 70%");
        if (bucket.accruedQuote(address(wbnb)) - acc0 != fee - _part(fee)) revert Check("A buy: bucket 30%");
        console.log("A buy via router: creator fee", pad.creatorFeeOf(t));

        uint256 owed0 = pad.creatorFeeOf(t);
        uint256 acc1 = bucket.accruedQuote(address(wbnb));
        uint256 half = IERC20(t).balanceOf(me) / 2;
        uint256 wb0 = wbnb.balanceOf(me);
        vm.startBroadcast(pk);
        IERC20(t).approve(address(pad), half);
        uint256 toMe = pad.sell(t, half, 0);
        vm.stopBroadcast();
        uint256 toCreator = pad.creatorFeeOf(t) - owed0;
        uint256 toPlatform = bucket.accruedQuote(address(wbnb)) - acc1;
        uint256 sellFee = toCreator + toPlatform;
        if (sellFee != ((toMe + sellFee) * 100) / BPS) revert Check("A sell: 1% fee");
        if (toCreator != _part(sellFee)) revert Check("A sell: creator 70%");
        if (wbnb.balanceOf(me) - wb0 != toMe) revert Check("A sell: paid in WBNB");
        console.log("A sell on the pad: creator fee now", pad.creatorFeeOf(t));

        uint256 owed = pad.creatorFeeOf(t);
        uint256 wb1 = wbnb.balanceOf(me);
        vm.startBroadcast(pk);
        uint256 paid = pad.claimCreatorFee(t, me);
        vm.stopBroadcast();
        if (paid != owed || wbnb.balanceOf(me) - wb1 != owed || pad.creatorFeeOf(t) != 0) revert Check("A claim");
        console.log("A claimed (WBNB wei)", paid);
    }

    function _graduateAndClaim(IGangPad pad, address testQuote, uint256 pk, address me) internal {
        IGangLaunchpad.TaxConfig memory tax =
            IGangLaunchpad.TaxConfig({buyTaxBps: 300, sellTaxBps: 300, dividendBps: 4_000, recipient: me});
        uint256 padQ0 = IERC20(testQuote).balanceOf(address(pad)); // other test-quote curves of the shared set
        vm.startBroadcast(pk);
        address t = pad.create("Creator Fee B", "CFB", "", "", testQuote, address(0), tax);
        IMintableQuote(testQuote).mintUnlimited(me, 20 ether);
        IERC20(testQuote).approve(address(pad), type(uint256).max);
        pad.setWalletCapEnabled(false);
        pad.buy(t, 16 ether, 0); // past the 15-unit graduation amount: the cut comes back
        pad.setWalletCapEnabled(true);
        vm.stopBroadcast();
        console.log("B token", t);
        (,,,,,, bool graduated,,,, address pair,) = pad.curves(t);
        if (!graduated || pair == address(0)) revert Check("B graduated");
        if (!pad.walletCapEnabled()) revert Check("wallet cap back on");
        uint256 owed = pad.creatorFeeOf(t);
        if (owed == 0) revert Check("B creator fee");
        console.log("B graduated, pair", pair);
        console.log("B creator fee (test quote wei)", owed);

        uint256 q0 = IERC20(testQuote).balanceOf(me);
        vm.startBroadcast(pk);
        pad.claimCreatorFee(t, me);
        vm.stopBroadcast();
        if (IERC20(testQuote).balanceOf(me) - q0 != owed) revert Check("B claim after graduation");
        uint256 padQ = IERC20(testQuote).balanceOf(address(pad));
        if (padQ < padQ0 || padQ > padQ0 + 1) revert Check("B pad: back to its balance before the run (+ dust)");
        console.log("B claimed after graduation");
    }
}
