// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {GangPadRegistry} from "../src/gang/GangPadRegistry.sol";
import {FlywheelTaxHandler} from "../src/flywheel/FlywheelTaxHandler.sol";
import {GangFlywheelPad} from "../src/flywheel/GangFlywheelPad.sol";
import {IFlywheelPad} from "../src/flywheel/interfaces/IFlywheelPad.sol";

interface IAgentRegister {
    function balanceOf(address) external view returns (uint256);
    function register() external returns (uint256);
}

interface ITestQuote {
    function mintUnlimited(address to, uint256 amount) external;
}

interface IRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @dev Tries a pool buy to itself (a contract: no Agent ID) through the router during the launch protection and
///      records whether it was refused — the protection proven on chain without failing the script.
contract ProtectionProbe {
    bool public refused;

    function probe(address router, address quote, address token, uint256 amountIn) external {
        IERC20(quote).approve(router, amountIn);
        address[] memory path = new address[](2);
        path[0] = quote;
        path[1] = token;
        try IRouterV2(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, address(this), block.timestamp) {
            refused = false;
        } catch {
            refused = true;
        }
    }
}

/// @title FlywheelTestnetAccept — acceptance run of the continuous-mint pad on BSC testnet (97)
/// @notice Phase 1 (ACCEPT_PHASE=1): a test-quote sale (raise 3, quota 10 — the V2 ceiling with post-launch minting —,
///         guard 20% over a 15-minute TWAP, launchDelay 0, protection 300 s) filled to 30% by 300 throwaway wallets
///         minting along a referral chain (one sells back and re-mints), the creator opens
///         early (launch in the same tx), a probe checks the launch protection refuses a buyer without an Agent ID;
///         a WBNB sale takes a BNB mint with change refunded and a sell-back. Phase 2 (ACCEPT_PHASE=2, after the
///         protection): post-launch mints (preview checked against the mint), router buy and sell, the keeper sells
///         the tax, holder rewards accrue, GangPadRegistry finds the token.
/// @dev Throwaway wallets: keys derived from the deployer key and an index, used only inside the script. Env:
///      DEPLOYER_PRIVATE_KEY (the testnet deployer = keeper), FLYWHEEL_PAD, FLYWHEEL_HANDLER; phase 2: ACCEPT_TOKEN.
///      Run with --broadcast --slow --legacy --with-gas-price 100000000.
contract FlywheelTestnetAccept is Script {
    uint256 internal constant WALLETS = 300;
    uint256 internal constant GAS_FUND = 0.004 ether;
    address internal constant TEST_QUOTE = 0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c;
    address internal constant PAD_REGISTRY = 0xB11B83C83DEd269B040faecC1D61B4885BA8e56e;

    GangFlywheelPad pad;
    FlywheelTaxHandler handler;
    uint256 pk;
    address me;

    error Check(string what);

    function run() external {
        require(block.chainid == 97, "testnet only");
        pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        me = vm.addr(pk);
        pad = GangFlywheelPad(payable(vm.envAddress("FLYWHEEL_PAD")));
        handler = FlywheelTaxHandler(vm.envAddress("FLYWHEEL_HANDLER"));
        uint256 phase = vm.envUint("ACCEPT_PHASE");
        if (phase == 1) _phase1();
        else _phase2(vm.envAddress("ACCEPT_TOKEN"));
    }

    function _wallet(uint256 i) internal view returns (uint256 key, address who) {
        key = uint256(keccak256(abi.encode(pk, "flywheel-accept", i))) % (type(uint256).max / 2) + 1;
        who = vm.addr(key);
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
            guardBps: 2_000,
            twapWindow: 900
        });
    }

    function _phase1() internal {
        // the creator: Agent ID, test quote, WBNB for the WBNB sale's first share
        vm.startBroadcast(pk);
        if (IAgentRegister(T.AGENT_ID_REGISTRY).balanceOf(me) == 0) IAgentRegister(T.AGENT_ID_REGISTRY).register();
        ITestQuote(TEST_QUOTE).mintUnlimited(me, 100 ether);
        IERC20(TEST_QUOTE).approve(address(pad), type(uint256).max);
        (bool ok,) = T.WBNB.call{value: 0.001 ether}(abi.encodeWithSignature("deposit()"));
        require(ok);
        IERC20(T.WBNB).approve(address(pad), type(uint256).max);
        address s =
            pad.create(["Flywheel Accept", "FWA", "ipfs://logo", "ipfs://meta"], TEST_QUOTE, address(0), _cfg(), 10);
        address w = pad.create(["Flywheel BNB", "FWB", "ipfs://logo", "ipfs://meta"], address(0), address(0), _cfg(), 1);
        for (uint256 i; i < WALLETS; i++) {
            (, address who) = _wallet(i);
            if (who.balance < GAS_FUND) payable(who).transfer(GAS_FUND - who.balance);
        }
        vm.stopBroadcast();
        console.log("ACCEPT_TOKEN", s);
        console.log("ACCEPT_BNB_TOKEN", w);

        // 300 wallets: Agent ID, quote, then 10 shares each along a referral chain (each invited by the previous one)
        for (uint256 i; i < WALLETS; i++) {
            (uint256 key, address who) = _wallet(i);
            (, address prev) = i == 0 ? (0, me) : _wallet(i - 1);
            vm.startBroadcast(key);
            if (IAgentRegister(T.AGENT_ID_REGISTRY).balanceOf(who) == 0) {
                IAgentRegister(T.AGENT_ID_REGISTRY).register();
            }
            ITestQuote(TEST_QUOTE).mintUnlimited(who, 10 ether);
            IERC20(TEST_QUOTE).approve(address(pad), type(uint256).max);
            pad.mint(s, 10, 1, prev);
            if (i == 0) {
                // a sell-back, then the shares minted again
                uint256 payout = pad.withdraw(s, 5, 0);
                if (payout == 0) revert Check("sell-back paid nothing");
                pad.mint(s, 5, 5, address(0));
            }
            if (i == 1) {
                // the WBNB sale: pay in BNB, the change comes back; then a sell-back
                uint256 before = who.balance;
                uint256 spent = pad.mintWithBnb{value: 0.002 ether}(w, 5, 5, address(0));
                if (before - who.balance != spent) revert Check("BNB change not refunded");
                pad.withdraw(w, 2, 0);
            }
            vm.stopBroadcast();
        }
        if (pad.quotaLeft(s, me) != 1) revert Check("creator's referral bonus missing");

        // the creator opens early (launchDelay 0: launch in the same tx); a probe checks the launch protection
        vm.startBroadcast(pk);
        pad.openEarly(s);
        ProtectionProbe probe = new ProtectionProbe();
        ITestQuote(TEST_QUOTE).mintUnlimited(address(probe), 1 ether);
        probe.probe(T.PANCAKE_V2_ROUTER, TEST_QUOTE, s, 0.01 ether);
        vm.stopBroadcast();

        IFlywheelPad.Sale memory sale = pad.sales(s);
        if (!sale.launched) revert Check("not launched");
        if (!probe.refused()) revert Check("protection let a wallet without an Agent ID buy");
        console.log("pair", sale.pair);
        console.log("sold", sale.sold);
        // simulated time: with --slow the launch lands later; phase 2 reads the real end from the handler
        console.log("protection until (simulated)", block.timestamp + 300);
    }

    function _phase2(address s) internal {
        IFlywheelPad.Sale memory sale = pad.sales(s);
        if (!sale.launched) revert Check("not launched");
        (uint16 guardBps, uint32 twapWindow) = pad.postRulesOf(s);
        if (guardBps != 2_000 || twapWindow != 900) revert Check("post rules not stored");
        (uint64 until,,) = handler.protectionOf(s);
        if (block.timestamp < until) {
            revert Check("protection window still open: wait for handler.protectionOf(token)");
        }
        // post-launch mints by up to five wallets with quota left (a re-run skips the ones that used theirs); the
        // preview must match
        uint256 minted;
        for (uint256 i = 10; i < WALLETS && minted < 5; i++) {
            (uint256 key, address who) = _wallet(i);
            uint256 want = pad.quotaLeft(s, who);
            if (want == 0) continue;
            if (want > 10) want = 10;
            (uint256 acc, uint256 paid, uint256 fee, uint256 out, bool ok) = pad.previewMintPost(s, who, want);
            if (!ok || acc == 0) revert Check("preview says no");
            vm.startBroadcast(key);
            (uint256 got, uint256 spent) = pad.mintPost(s, want, (out * 98) / 100, paid + fee, address(0));
            vm.stopBroadcast();
            if (got != out || spent != paid + fee) revert Check("preview != mint");
            minted++;
        }
        if (minted == 0) revert Check("no wallet with quota left");
        // pool trading through the router, then the keeper sells the tax
        vm.startBroadcast(pk);
        address[] memory path = new address[](2);
        path[0] = TEST_QUOTE;
        path[1] = s;
        IERC20(TEST_QUOTE).approve(T.PANCAKE_V2_ROUTER, type(uint256).max);
        IRouterV2(T.PANCAKE_V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(0.05 ether, 0, path, me, block.timestamp + 1 hours);
        // the keeper sells a chunk before the sell: after a sell, in the same block, the price is below the block's
        // reference and `process` refuses by design (forge re-simulates every tx in one block)
        uint256 chunk = handler.maxChunk(s);
        if (chunk > 0) handler.process(s, chunk, 1);
        uint256 bal = IERC20(s).balanceOf(me);
        IERC20(s).approve(T.PANCAKE_V2_ROUTER, type(uint256).max);
        path[0] = s;
        path[1] = TEST_QUOTE;
        IRouterV2(T.PANCAKE_V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(bal / 3, 0, path, me, block.timestamp + 1 hours);
        vm.stopBroadcast();

        (, address holder) = _wallet(3);
        SharedDividendVault vault = SharedDividendVault(address(pad.dividendVault()));
        if (vault.pending(s, holder) == 0 && vault.pendingUnits(s, holder) == 0) revert Check("no holder reward");
        (address found, uint8 kind) = GangPadRegistry(PAD_REGISTRY).lookup(s);
        if (found != address(pad) || kind != 3) revert Check("registry does not find the token");
        console.log("accepted: post-launch mints, router trades, keeper chunk, holder rewards, registry lookup");
    }
}
