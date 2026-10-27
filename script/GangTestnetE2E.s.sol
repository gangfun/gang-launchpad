// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {MockSPCXB} from "../src/launchpad-v2/mocks/MockSPCXB.sol";
import {IPancakeRouter02} from "../src/launchpad-v2/interfaces/IPancake.sol";
import {TestnetBlacklistQuote} from "../src/launchpad-v3/mocks/TestnetBlacklistQuote.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../src/common/SharedPlatformFeeBucket.sol";
import {GangRouter, IPancakeV2Router} from "../src/router/GangRouter.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangTaxHandlerOps} from "../src/gang/interfaces/IGangTaxHandlerOps.sol";

interface ITestnetAgentId {
    function balanceOf(address) external view returns (uint256);
    function register() external returns (uint256);
}

interface IPairFactoryLite {
    function getPair(address, address) external view returns (address);
}

interface IGangTokenPair {
    function pair() external view returns (address);
}

/// @title GangTestnetE2E — one full round of both kinds of token on the one pad from DeployGang, BSC testnet
/// @notice V3 (curve; no curve tax, pool tax 2% / 2%, half to holders, half to the listed demo treasury):
///         A (test quote): curve buy + sell, 80 throwaway Agents fill the curve (graduation), then a pool buy + sell —
///           the sell sells one chunk of the accrued tax on its way in (swap-back) — and the keeper `process`es one more.
///         W (WBNB, optional): a router buy with native BNB (v3BuyBNB) and a direct curve sell.
///         B (blacklist quote): graduated the same way; with the treasury blocked, the pool sell's swap-back books the
///           treasury's part as owed (TaxOwed); the treasury is unblocked and `release` pushes it.
///         打新: a sale in the test quote, 100 throwaway Agents fill it (launch: pair + LP), then a pool buy, minter 0
///           sells below the reward line (out for good), the keeper `process`es a chunk, minter 5 claims.
/// @dev TESTNET ONLY. The deployer must be the handler's keeper (DeployGang's testnet default) and the blacklist quote's
///      admin (DeployGang deploys it from the deployer). Minter keys derive from DEPLOYER_PRIVATE_KEY (recoverable,
///      worthless off testnet); the labels are the old per-core scripts' ones, so their Agent IDs are reused.
///      Resumable: TOKEN_A / TOKEN_B / TOKEN_W / TOKEN_F skip their create; minters that already hold a token (V3) or a
///      position (打新) are skipped; fills stop once graduated / launched; each trading step is skipped when its result is
///      already on chain. SKIP_V3=true / SKIP_FAIR=true / SKIP_B=true / SKIP_W=true run only the rest.
///      Env: DEPLOYER_PRIVATE_KEY, GANG_PAD, BLACKLIST_QUOTE (unless SKIP_B); optional GANG_ROUTER (for W, and the
///      router's Pancake V2 pool entries on A after its keeper step), TEST_QUOTE,
///      RECIPIENT, GAS_PRICE_WEI (default 0.1 gwei — pass the same value as --with-gas-price; minter prefunds are sized
///      from it), GAS_PER_MINTER (wei, overrides the sized prefund). Broadcast with --slow: the keeper steps assume the
///      trades before them are already mined (the simulation rolls one block before each `process`). Deadlines are a day out (fixed at simulation time;
///      the ~1,000 broadcasts take a while). Afterwards run `--sig "sweep()"` as its own script to return what the
///      minters did not burn: it must be a separate run, since a simulation does not charge gas.
///      Needs ≈ 0.15 tBNB at 0.1 gwei (most of it prefunds the 180 minters; `sweep` brings the rest back).
contract GangTestnetE2E is Script {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant V3_MINTERS = 120;
    uint256 internal constant FAIR_MINTERS = 100;
    /// @dev register + faucet + approve + capped buy ~370k gas; the buy that graduates (pair + LP) ~2.45M
    uint256 internal constant MINTER_GAS = 600_000;
    uint256 internal constant NEAR_END_FACTOR = 10;
    uint256 internal constant TPS = 50_000 ether;

    error WrongChain(uint256 chainId);
    error Check(string what);

    IGangPad internal pad;
    IGangTaxHandlerOps internal handler;
    MockSPCXB internal quote;
    address internal treasury;
    uint256 internal deployerPk;
    address internal deployer;
    uint256 internal gasPerMinter;

    function run() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPk);
        pad = IGangPad(vm.envAddress("GANG_PAD"));
        handler = IGangTaxHandlerOps(pad.taxHandler());
        quote = MockSPCXB(vm.envOr("TEST_QUOTE", T.TEST_QUOTE));
        treasury = vm.envOr("RECIPIENT", T.DEMO_TREASURY);
        gasPerMinter = vm.envOr("GAS_PER_MINTER", MINTER_GAS * _gasPrice());
        if (handler.keeper() != deployer) revert Check("deployer is not the handler keeper");

        // create / curve trades / mints are Agent-only: a fresh deployer registers a testnet Agent ID first
        _register(deployerPk);

        if (!vm.envOr("SKIP_V3", false)) _v3();
        if (!vm.envOr("SKIP_FAIR", false)) _fair();
    }

    // ================================================================ V3
    function _v3() internal {
        // ---- A: create + curve buy / sell, fill, pool trades, keeper
        address a = vm.envOr("TOKEN_A", address(0));
        if (a == address(0)) a = _createV3(address(quote), "Gang V3 Tax Test", "GV3T");
        console.log("V3 token A", a);
        _curveTrade(a, address(quote));
        _graduate(a, address(quote));
        _poolRound(a, address(quote));
        _keeperChunk(a, address(quote));
        _routerPoolRound(a, address(quote));
        console.log("A accruedTax", handler.accruedTax(a), "platform part", handler.accruedPlatformTax(a));
        console.log("treasury quote", quote.balanceOf(treasury));

        // ---- W: WBNB quote, native BNB through the router
        if (!vm.envOr("SKIP_W", false)) _wbnbRouter();

        // ---- B: blacklist quote, failed push → owed → release
        if (!vm.envOr("SKIP_B", false)) _owedFlow();
    }

    function _createV3(address q, string memory name, string memory symbol) internal returns (address t) {
        vm.startBroadcast(deployerPk);
        IERC20(q).approve(address(pad), type(uint256).max);
        t = pad.create(
            name,
            symbol,
            "",
            "",
            q,
            address(0),
            IGangLaunchpad.TaxConfig({buyTaxBps: 200, sellTaxBps: 200, dividendBps: 5000, recipient: treasury})
        );
        vm.stopBroadcast();
        if (pad.kindOf(t) != 1) revert Check("V3 token kind");
    }

    /// @dev Deployer buys a little on the curve and sells half back (skipped once it holds the token or graduated).
    function _curveTrade(address t, address q) internal {
        if (_graduated(t) || IERC20(t).balanceOf(deployer) > 0) return;
        vm.startBroadcast(deployerPk);
        _faucet(q, deployer, 1 ether);
        IERC20(q).approve(address(pad), type(uint256).max);
        pad.buy(t, 0.05 ether, 0);
        uint256 bal = IERC20(t).balanceOf(deployer);
        IERC20(t).approve(address(pad), bal);
        pad.sell(t, bal / 2, 0);
        vm.stopBroadcast();
        if (IERC20(t).balanceOf(deployer) == 0) revert Check("curve trade");
    }

    /// @dev Throwaway Agents buy at the 1% cap until the curve graduates (~80).
    function _graduate(address t, address q) internal {
        for (uint256 i = 0; i < V3_MINTERS; i++) {
            if (_graduated(t)) break;
            uint256 pk = _minterKey("gang-v3-testnet", i);
            address m = vm.addr(pk);
            if (IERC20(t).balanceOf(m) > 0) continue; // bought on an earlier run
            // the buy that graduates also builds the pair: the last few get more gas
            _prefund(m, pad.graduationRemaining(t) < 3 ether ? gasPerMinter * NEAR_END_FACTOR : gasPerMinter);
            _register(pk);
            vm.startBroadcast(pk);
            _faucet(q, m, 1 ether);
            IERC20(q).approve(address(pad), type(uint256).max);
            pad.buy(t, 1 ether, 0); // truncated to the 1% cap, the rest refunded
            vm.stopBroadcast();
        }
        if (!_graduated(t)) revert Check("not graduated");
        console.log("graduated, pair", IGangTokenPair(t).pair());
    }

    /// @dev Deployer: pool buy (tax accrues), pool sell (sells one chunk of it first: swap-back).
    function _poolRound(address t, address q) internal {
        uint256 accrued0 = handler.accruedTax(t);
        vm.startBroadcast(deployerPk);
        _faucet(q, deployer, 1 ether);
        _swap(q, t, 0.5 ether, deployer);
        uint256 afterBuy = handler.accruedTax(t);
        _swap(t, q, IERC20(t).balanceOf(deployer) / 2, deployer);
        vm.stopBroadcast();
        uint256 afterSell = handler.accruedTax(t);
        console.log("accruedTax before / after buy / after sell", accrued0, afterBuy, afterSell);
        if (afterBuy <= accrued0) revert Check("pool buy accrued no tax");
    }

    /// @dev The router's Pancake V2 entries on A (GANG_ROUTER, an upgradeable router with `pancakeRouter`; skipped
    ///      otherwise): poolBuy in the quote, poolSell back to it, and the BNB pair (poolBuyBNB / poolSellForBNB through
    ///      [WBNB, quote, A]) when a WBNB/quote pair exists. The router must end with nothing and no allowance.
    function _routerPoolRound(address t, address q) internal {
        address r = vm.envOr("GANG_ROUTER", address(0));
        if (r == address(0)) return;
        GangRouter router = GangRouter(payable(r));
        try router.pancakeRouter() returns (IPancakeV2Router pr) {
            if (address(pr) != T.PANCAKE_V2_ROUTER) revert Check("router pancakeRouter");
        } catch {
            console.log("router pool round skipped: router has no pool entries");
            return;
        }
        uint256 dl = block.timestamp + 1 days;
        bool bnbPath = IPairFactoryLite(T.PANCAKE_V2_FACTORY).getPair(T.WBNB, q) != address(0);
        _nextBlock();
        vm.startBroadcast(deployerPk);
        _faucet(q, deployer, 1 ether);
        IERC20(q).approve(r, 0.2 ether);
        uint256 bought = router.poolBuy(t, q, 0.2 ether, 1, dl);
        IERC20(t).approve(r, bought);
        uint256 got = router.poolSell(t, q, bought / 2, 1, dl);
        uint256 bnbBought;
        uint256 bnbGot;
        if (bnbPath) {
            bnbBought = router.poolBuyBNB{value: 0.0005 ether}(t, q, 1, dl);
            IERC20(t).approve(r, bnbBought);
            bnbGot = router.poolSellForBNB(t, q, bnbBought, 1, dl);
        }
        vm.stopBroadcast();
        console.log("router pool: bought / sold-for quote", bought, got);
        if (bnbPath) console.log("router pool: BNB bought / sold-for BNB", bnbBought, bnbGot);
        else console.log("router pool: no WBNB/quote pair, BNB entries skipped");
        if (
            IERC20(t).balanceOf(r) != 0 || IERC20(q).balanceOf(r) != 0 || IERC20(T.WBNB).balanceOf(r) != 0
                || r.balance != 0
        ) revert Check("router not empty after pool round");
        if (IERC20(t).allowance(r, T.PANCAKE_V2_ROUTER) != 0 || IERC20(q).allowance(r, T.PANCAKE_V2_ROUTER) != 0) {
            revert Check("router left a Pancake allowance");
        }
    }

    /// @dev Keeper sells one chunk with a 1% slippage bound (skipped when nothing is sellable this block).
    function _keeperChunk(address t, address q) internal returns (uint256 out) {
        // with --slow the keeper's tx lands in a later block than the trades above: a fresh per-block budget and
        // reference price (in one simulated block it would hit ZeroAmount / PriceBelowReference)
        _nextBlock();
        uint256 chunk = handler.maxChunk(t);
        if (chunk == 0) {
            console.log("keeper: nothing to process this block", t);
            return 0;
        }
        address[] memory path = new address[](2);
        (path[0], path[1]) = (t, q);
        uint256 quoted = IPancakeRouter02(T.PANCAKE_V2_ROUTER).getAmountsOut(chunk, path)[1];
        vm.startBroadcast(deployerPk);
        out = handler.process(t, chunk, (quoted * 99) / 100);
        vm.stopBroadcast();
        console.log("keeper processed (quote wei)", out);
    }

    function _wbnbRouter() internal {
        address r = vm.envOr("GANG_ROUTER", address(0));
        if (r == address(0)) {
            console.log("W skipped: no GANG_ROUTER");
            return;
        }
        GangRouter router = GangRouter(payable(r));
        if (address(router.pad()) != address(pad)) revert Check("GANG_ROUTER is on another pad");
        address w = vm.envOr("TOKEN_W", address(0));
        vm.startBroadcast(deployerPk);
        if (w == address(0)) {
            w = pad.create(
                "Gang V3 WBNB Test",
                "GV3W",
                "",
                "",
                address(0),
                address(0),
                IGangLaunchpad.TaxConfig({buyTaxBps: 200, sellTaxBps: 200, dividendBps: 5000, recipient: treasury})
            );
        }
        uint256 out = router.v3BuyBNB{value: 0.002 ether}(w, 1, block.timestamp + 1 days);
        IERC20(w).approve(address(pad), out);
        pad.sell(w, out / 2, 0);
        vm.stopBroadcast();
        console.log("V3 token W (WBNB)", w, "bought via router", out);
        if (IERC20(T.WBNB).balanceOf(r) != 0 || r.balance != 0) revert Check("router not empty");
    }

    function _owedFlow() internal {
        TestnetBlacklistQuote blq = TestnetBlacklistQuote(vm.envAddress("BLACKLIST_QUOTE"));
        if (blq.admin() != deployer) revert Check("deployer is not the blacklist quote admin");
        address b = vm.envOr("TOKEN_B", address(0));
        if (b == address(0)) b = _createV3(address(blq), "Gang V3 Owed Test", "GV3O");
        console.log("V3 token B", b);
        _graduate(b, address(blq));

        if (handler.owedOf(b) == 0) {
            // the treasury refuses the quote: the swap-back's push to it fails and is booked as owed
            vm.startBroadcast(deployerPk);
            blq.setBlocked(treasury, true);
            vm.stopBroadcast();
            _poolRound(b, address(blq));
            if (handler.owedOf(b) == 0) _keeperChunk(b, address(blq));
            if (handler.owedOf(b) == 0) revert Check("nothing owed on B");
        }
        uint256 owed = handler.owedOf(b);
        console.log("B owed to the treasury (tBUSD wei)", owed);
        uint256 before = blq.balanceOf(treasury);
        vm.startBroadcast(deployerPk);
        blq.setBlocked(treasury, false);
        handler.release(b); // anyone may; the keeper does it in keeper-tax-process.sh
        vm.stopBroadcast();
        if (handler.owedOf(b) != 0 || blq.balanceOf(treasury) != before + owed) revert Check("release");
        console.log("released to the treasury", owed);
    }

    // ================================================================ 打新
    function _fair() internal {
        address f = vm.envOr("TOKEN_F", address(0));
        (, uint256 price) = pad.previewCreate(address(quote), address(0), 15 ether);
        if (f == address(0)) {
            vm.startBroadcast(deployerPk);
            _faucet(address(quote), deployer, 10 ether);
            quote.approve(address(pad), type(uint256).max);
            f = pad.create(
                "Gang Fair Test",
                "GFAIR",
                "",
                "",
                address(quote),
                address(0),
                IGangLaunchpad.MintConfig({
                    raiseBnb: 15 ether, capBps: 50, holdBps: 5000, mintFeeBps: 100, exitFeeBps: 100
                }),
                1
            );
            vm.stopBroadcast();
            if (pad.kindOf(f) != 2) revert Check("fair token kind");
        }
        console.log("fair token", f);

        // 100 minters × 100 shares (the last one is truncated to 99) → launch
        for (uint256 i = 0; i < FAIR_MINTERS && pad.status(f) != IGangLaunchpad.Status.Launched; i++) {
            uint256 pk = _minterKey("gang-fair-mint-testnet", i);
            address m = vm.addr(pk);
            if (pad.positions(f, m) > 0) continue; // minted on an earlier run
            // the filling mint also builds the pair: give the last minter 10x gas
            _prefund(m, i == FAIR_MINTERS - 1 ? gasPerMinter * NEAR_END_FACTOR : gasPerMinter);
            _register(pk);
            vm.startBroadcast(pk);
            _faucet(address(quote), m, (price * 100 * 101) / 100);
            quote.approve(address(pad), type(uint256).max);
            pad.mint(f, 100, 1);
            vm.stopBroadcast();
        }
        if (pad.status(f) != IGangLaunchpad.Status.Launched) revert Check("not launched");
        console.log("launched, pair", IGangTokenPair(f).pair());

        // pool buy; minter 0 sells 55% of its 100 shares (below the 50% line: out for good); keeper; minter 5 claims
        address m0 = _minterAddr("gang-fair-mint-testnet", 0);
        if (!handler.isOut(f, m0)) {
            vm.startBroadcast(deployerPk);
            _faucet(address(quote), deployer, 3 ether);
            _swap(address(quote), f, 3 ether, deployer);
            vm.stopBroadcast();
            // its mint used most of the prefund: the approve + a sell carrying a swap-back chunk need ~3 more
            _prefund(m0, gasPerMinter * 3);
            vm.startBroadcast(_minterKey("gang-fair-mint-testnet", 0));
            _swap(f, address(quote), 55 * TPS, m0);
            vm.stopBroadcast();
            if (!handler.isOut(f, m0)) revert Check("minter 0 not out");
        }
        uint256 out = _keeperChunk(f, address(quote));

        SharedDividendVault vault = SharedDividendVault(pad.dividendVault());
        address m5 = _minterAddr("gang-fair-mint-testnet", 5);
        uint256 pend = vault.pending(f, m5);
        if (pend == 0) revert Check("no reward for minter 5");
        _prefund(m5, gasPerMinter);
        vm.startBroadcast(_minterKey("gang-fair-mint-testnet", 5));
        vault.claim(f);
        vm.stopBroadcast();

        console.log("fair tax processed (quote wei)", out);
        console.log("minter 5 claimed (quote wei)", pend);
        console.log(
            "bucket accrued (quote wei)", SharedPlatformFeeBucket(pad.platformBucket()).accruedQuote(address(quote))
        );
    }

    // ================================================================ sweep
    /// @notice Return each minter's leftover gas money to the deployer (one plain transfer per minter, read from chain).
    function sweep() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPk);
        uint256 total = _sweep("gang-v3-testnet", V3_MINTERS) + _sweep("gang-fair-mint-testnet", FAIR_MINTERS);
        console.log("swept", total);
    }

    function _sweep(string memory label, uint256 n) internal returns (uint256 total) {
        uint256 fee = 21_000 * _gasPrice();
        for (uint256 i = 0; i < n; i++) {
            uint256 pk = _minterKey(label, i);
            address m = vm.addr(pk);
            // 2x fee: whatever the transfer does not burn stays behind as dust
            if (m.balance <= 2 * fee) continue;
            uint256 amount = m.balance - 2 * fee;
            vm.startBroadcast(pk);
            _send(deployer, amount);
            vm.stopBroadcast();
            total += amount;
        }
    }

    // ================================================================ helpers
    function _register(uint256 pk) internal {
        ITestnetAgentId agentId = ITestnetAgentId(pad.agentIdRegistry());
        if (agentId.balanceOf(vm.addr(pk)) > 0) return;
        vm.startBroadcast(pk);
        agentId.register();
        vm.stopBroadcast();
    }

    /// @dev Top a minter up to `amount` of tBNB for gas (a resumed run does not pay twice).
    function _prefund(address m, uint256 amount) internal {
        if (m.balance >= amount) return;
        vm.startBroadcast(deployerPk);
        _send(m, amount - m.balance);
        vm.stopBroadcast();
    }

    /// @dev A plain value call (not `transfer`: a 7702-delegated deployer wallet needs more than 2,300 gas).
    function _send(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert Check("BNB transfer");
    }

    /// @dev Testnet faucet mint (MockSPCXB caps each address at 1,000; the blacklist quote has no cap). Call inside
    ///      a broadcast of `to` or the deployer.
    function _faucet(address q, address to, uint256 amount) internal {
        if (IERC20(q).balanceOf(to) >= amount) return;
        MockSPCXB(q).mint(to, amount - IERC20(q).balanceOf(to));
    }

    function _graduated(address t) internal view returns (bool g) {
        (,,,,,, g,,,,,) = pad.curves(t);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, address to) internal {
        address[] memory path = new address[](2);
        (path[0], path[1]) = (tokenIn, tokenOut);
        IERC20(tokenIn).approve(T.PANCAKE_V2_ROUTER, amountIn);
        IPancakeRouter02(T.PANCAKE_V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, to, block.timestamp + 1 days);
    }

    /// @dev Simulation only: model the next block (the broadcast runs with --slow, one receipt at a time).
    function _nextBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 3);
    }

    function _gasPrice() internal view returns (uint256) {
        return vm.envOr("GAS_PRICE_WEI", uint256(0.1 gwei));
    }

    function _minterKey(string memory label, uint256 i) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(label, deployerPk, i))) % (SECP256K1_N - 1) + 1;
    }

    function _minterAddr(string memory label, uint256 i) internal view returns (address) {
        return vm.addr(_minterKey(label, i));
    }
}
