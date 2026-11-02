// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {IGangGateway} from "../src/router/interfaces/IGangGateway.sol";
import {GangFlywheelPad} from "../src/flywheel/GangFlywheelPad.sol";
import {IFlywheelPad} from "../src/flywheel/interfaces/IFlywheelPad.sol";

interface ITestQuoteMint {
    function mintUnlimited(address to, uint256 amount) external;
}

/// @dev An aggregator's adapter as written for four.meme: names its caller as the trader, 1% router fee on sells;
///      ERC-20 buys pull the caller's quote into the adapter and approve the gateway.
contract FlyAcceptanceAdapter {
    IGangGateway public immutable gw;
    address public immutable feeTo;

    constructor(IGangGateway gw_, address feeTo_) {
        gw = gw_;
        feeTo = feeTo_;
    }

    function buyBnb(address token, uint256 minAmount) external payable returns (uint256 out, uint256 used) {
        return gw.buyTokenAMAP{value: msg.value}(token, msg.sender, msg.value, minAmount);
    }

    function buyErc20(address token, address quote, uint256 funds, uint256 minAmount)
        external
        returns (uint256 out, uint256 used)
    {
        IERC20(quote).transferFrom(msg.sender, address(this), funds);
        IERC20(quote).approve(address(gw), funds);
        return gw.buyTokenAMAP(token, msg.sender, funds, minAmount);
    }

    function sell(address token, uint256 amount, uint256 minFunds) external returns (uint256) {
        return gw.sellToken(0, token, msg.sender, amount, minFunds, 100, feeTo);
    }
}

/// @title GatewayFlywheelTestnetAcceptance — GangGateway V2 on a 铸币飞轮 pad, end to end on BSC testnet
/// @notice With the deploy wallet (an Agent ID holder and the gateway owner) on FLYWHEEL_PAD (must list the gateway):
///         creates a BNB sale and a test-quote (ERC-20) sale, whitelists an aggregator-style adapter, then on each:
///         a pre-launch buy through the adapter with funds over the price (the change back in WBNB / the quote,
///         checked against tryBuy), an exact-approval sell-back of part through the adapter (1% router fee, checked
///         against trySell) and of the rest straight on the gateway. On FLY_LAUNCHED (a launched sale with post-launch
///         minting): a post-launch buy through the adapter checked against tryBuy, and trySell 0. After each step the
///         gateway and the adapter hold nothing and the allowances to the gateway are 0.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, GANG_GATEWAY, FLYWHEEL_PAD, FLY_LAUNCHED (optional).
///      Run with --broadcast --slow --legacy --with-gas-price 100000000.
contract GatewayFlywheelTestnetAcceptance is Script {
    error WrongChain(uint256 chainId);
    error Check(string what);

    IGangGateway gw;
    GangFlywheelPad pad;
    FlyAcceptanceAdapter adapter;
    uint256 pk;
    address me;
    uint256 tps;

    function run() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        me = vm.addr(pk);
        gw = IGangGateway(vm.envAddress("GANG_GATEWAY"));
        pad = GangFlywheelPad(payable(vm.envAddress("FLYWHEEL_PAD")));
        if (!pad.routers(address(gw))) revert Check("gateway not listed on FLYWHEEL_PAD");
        if (gw.owner() != me) revert Check("deploy wallet is not the gateway owner");
        tps = pad.TOKENS_PER_SHARE();

        vm.startBroadcast(pk);
        ITestQuoteMint(T.TEST_QUOTE).mintUnlimited(me, 10 ether);
        IERC20(T.TEST_QUOTE).approve(address(pad), type(uint256).max);
        (bool ok,) = T.WBNB.call{value: 0.0005 ether}(abi.encodeWithSignature("deposit()"));
        if (!ok) revert Check("wrap");
        IERC20(T.WBNB).approve(address(pad), type(uint256).max);
        address bnbSale =
            pad.create(["Gateway Fly BNB", "GWFB", "ipfs://logo", "ipfs://meta"], address(0), address(0), _cfg(), 1);
        address erc20Sale =
            pad.create(["Gateway Fly Q", "GWFQ", "ipfs://logo", "ipfs://meta"], T.TEST_QUOTE, address(0), _cfg(), 1);
        adapter = new FlyAcceptanceAdapter(gw, T.DEMO_TREASURY);
        IERC20(T.WBNB).approve(address(pad), 0);
        IERC20(T.TEST_QUOTE).approve(address(pad), 0);
        vm.stopBroadcast();

        if (gw.isCaller(address(adapter))) revert Check("adapter listed before setCaller");
        vm.startBroadcast(pk);
        gw.setCaller(address(adapter), true);
        vm.stopBroadcast();

        _preLaunch(bnbSale, true);
        _preLaunch(erc20Sale, false);
        address launched = vm.envOr("FLY_LAUNCHED", address(0));
        if (launched != address(0)) _postLaunch(launched);

        console.log("BNB sale", bnbSale);
        console.log("test-quote sale", erc20Sale);
        console.log("adapter", address(adapter));
    }

    function _cfg() internal pure returns (IFlywheelPad.FlyConfig memory) {
        return IFlywheelPad.FlyConfig({
            raiseBnb: 3 ether,
            baseQuota: 10,
            inviteBonus: 1,
            maxPerTx: 10,
            holdBps: 6_000,
            mintFeeBps: 100,
            exitFeeBps: 100,
            devCutBps: 1_000,
            buyBps: 3_000,
            sellTaxBps: 200,
            launchDelay: 0,
            window: 300,
            windowCapMul: 1,
            postMint: true,
            tierMode: 1,
            stepBps: 0,
            stepShares: 0,
            maxMulX100: 0,
            supplyCapMul: 100,
            guardBps: 0,
            twapWindow: 1_800
        });
    }

    function _preLaunch(address t, bool bnb) internal {
        IFlywheelPad.Sale memory s = pad.sales(t);
        address quote = s.quote;
        (uint8 status, address q,, uint256 feeBps, uint256 left) = gw.getTokenInfo(t);
        if (status != 1 || q != (bnb ? address(0) : quote) || feeBps != s.mintFeeBps) revert Check("getTokenInfo");
        if (left != (10_000 - s.sold) * s.basePrice) revert Check("getTokenInfo left");

        // 3 shares' cost plus some change
        uint256 cost3 = 3 * s.basePrice + (3 * s.basePrice * s.mintFeeBps) / 10_000;
        uint256 funds = cost3 + s.basePrice / 2;
        (address tm,, uint256 est, uint256 cost,, uint256 msgValue, uint256 approval, uint256 amountFunds) =
            gw.tryBuy(t, me, 0, funds);
        if (tm != address(gw) || est != 3 * tps || cost != cost3 || amountFunds != cost3) revert Check("tryBuy");
        if (bnb ? (msgValue != funds || approval != 0) : (msgValue != 0 || approval != funds)) {
            revert Check("tryBuy value / approval");
        }

        uint256 q0 = IERC20(quote).balanceOf(me);
        vm.startBroadcast(pk);
        uint256 out;
        uint256 used;
        if (bnb) {
            (out, used) = adapter.buyBnb{value: funds}(t, est);
        } else {
            IERC20(quote).approve(address(adapter), funds);
            (out, used) = adapter.buyErc20(t, quote, funds, est);
        }
        vm.stopBroadcast();
        if (out != est || used != cost || IERC20(t).balanceOf(me) != 1 * tps + out) revert Check("buy");
        // BNB: the change comes back as WBNB; ERC-20: funds went out, the change came back
        uint256 q1 = IERC20(quote).balanceOf(me);
        if (bnb ? q1 - q0 != funds - cost : q0 - q1 != cost) revert Check("change");
        _empty(t, quote);

        // sell back 2 shares through the adapter (1% router fee), exact approval
        (,, uint256 sellFunds, uint256 exitFee) = gw.trySell(t, 2 * tps);
        (uint256 payout, uint256 padFee) = pad.previewWithdraw(t, me, 2);
        if (sellFunds != payout || exitFee != padFee || sellFunds == 0) revert Check("trySell");
        uint256 routerFee = sellFunds / 100;
        uint256 b0 = bnb ? me.balance : IERC20(quote).balanceOf(me);
        uint256 f0 = bnb ? T.DEMO_TREASURY.balance : IERC20(quote).balanceOf(T.DEMO_TREASURY);
        vm.startBroadcast(pk);
        IERC20(t).approve(address(gw), 2 * tps);
        uint256 toSeller = adapter.sell(t, 2 * tps, sellFunds - routerFee);
        vm.stopBroadcast();
        uint256 b1 = bnb ? me.balance : IERC20(quote).balanceOf(me);
        uint256 f1 = bnb ? T.DEMO_TREASURY.balance : IERC20(quote).balanceOf(T.DEMO_TREASURY);
        if (toSeller != sellFunds - routerFee || f1 - f0 != routerFee) revert Check("adapter sell split");
        // BNB: the seller also paid gas from the same balance
        if (!bnb && b1 - b0 != toSeller) revert Check("adapter sell paid");
        if (IERC20(t).allowance(me, address(gw)) != 0) revert Check("adapter sell allowance");
        _empty(t, quote);

        // sell the third share straight on the gateway, no fee
        (,, uint256 funds2,) = gw.trySell(t, tps);
        vm.startBroadcast(pk);
        IERC20(t).approve(address(gw), tps);
        uint256 toSeller2 = gw.sellToken(0, t, me, tps, funds2, 0, address(0));
        vm.stopBroadcast();
        if (toSeller2 != funds2 || IERC20(t).balanceOf(me) != 1 * tps) revert Check("direct sell");
        if (IERC20(t).allowance(me, address(gw)) != 0) revert Check("direct sell allowance");
        _empty(t, quote);
        console.log(bnb ? "BNB sale: bought / spent" : "test-quote sale: bought / spent", out, used);
        console.log("  sold back via adapter: to seller / router fee", toSeller, routerFee);
        console.log("  sold back direct: to seller", toSeller2);
    }

    function _postLaunch(address t) internal {
        IFlywheelPad.Sale memory s = pad.sales(t);
        if (!s.launched || !s.postMint) revert Check("FLY_LAUNCHED not launched with post-launch minting");
        address quote = s.quote;
        (uint8 status,, address pair,,) = gw.getTokenInfo(t);
        if (status != 2 || pair != s.pair) revert Check("post getTokenInfo");
        uint256 funds = 0.05 ether;
        bool bnb = quote == T.WBNB;
        (,, uint256 est, uint256 cost,,,,) = gw.tryBuy(t, me, 0, funds);
        if (est == 0) {
            console.log("post-launch: no quote now (quota / guards); skipped", t);
            return;
        }
        uint256 t0 = IERC20(t).balanceOf(me);
        vm.startBroadcast(pk);
        uint256 out;
        uint256 used;
        if (bnb) {
            (out, used) = adapter.buyBnb{value: funds}(t, est);
        } else {
            ITestQuoteMint(quote).mintUnlimited(me, funds);
            IERC20(quote).approve(address(adapter), funds);
            (out, used) = adapter.buyErc20(t, quote, funds, est);
        }
        vm.stopBroadcast();
        if (out != est || used != cost || IERC20(t).balanceOf(me) - t0 != out) revert Check("post-launch buy");
        (,, uint256 sellFunds,) = gw.trySell(t, tps);
        if (sellFunds != 0) revert Check("post-launch trySell");
        _empty(t, quote);
        console.log("post-launch buy: token / bought / spent", t);
        console.log("  ", out, used);
    }

    function _empty(address t, address quote) internal view {
        if (address(gw).balance != 0 || IERC20(T.WBNB).balanceOf(address(gw)) != 0) revert Check("gateway BNB/WBNB");
        if (IERC20(quote).balanceOf(address(gw)) != 0 || IERC20(t).balanceOf(address(gw)) != 0) {
            revert Check("gateway holds quote / tokens");
        }
        if (IERC20(quote).allowance(address(gw), address(pad)) != 0) revert Check("gateway approval left");
        if (address(adapter).balance != 0 || IERC20(quote).balanceOf(address(adapter)) != 0) {
            revert Check("adapter not empty");
        }
    }
}
