// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {MockSPCXB} from "../src/launchpad-v2/mocks/MockSPCXB.sol";
import {IPancakeRouter02} from "../src/launchpad-v2/interfaces/IPancake.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../src/gang/Pad3VanityDeployer.sol";
import {GangCountdownReward} from "../src/gang/GangCountdownReward.sol";
import {GangCountdownRewardFactory} from "../src/gang/GangCountdownRewardFactory.sol";
import {Pad3VanitySalt} from "./Pad3VanitySalt.sol";

interface ICdAgentIdLite {
    function balanceOf(address) external view returns (uint256);
    function register() external returns (uint256);
}

/// @title CountdownTestnetAcceptance — one on-chain round of GangCountdownReward (倒计时奖励) on BSC testnet
/// @notice `run`: the deployer computes its token's address (the pad's abcd deployer), clones a countdown module for
///         it (the test quote; a 30-minute window, 3 entries, 30% a round, 20% extra to the last, 25% of the tax to
///         the dev), creates the taxed V3 token paying the module, binds it, seeds the pool, buys on the curve;
///         throwaway Agents fill the curve (graduation); pool sells pay the tax (the swap-back pays the module, booked
///         with the dev's part); then three counted buys through the module (`buyWithQuote`, the real Pancake pair):
///         the deployer, a throwaway buyer B, and the deployer again. Checked to the wei: the seed has no dev part,
///         each buy reaches the buyer, nothing of it stays in the module, the deadline, the ring.
///         After the window: `--sig "finish()"` settles (or `work`s) the round, checks each credit to the wei
///         (equal shares, the last entry's extra, dust back to the pool), claims for the deployer and B, claims the
///         dev's part, and that the books match the balance; then one more counted buy starts round 2.
///         `--sig "report()"` only reads.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, COUNTDOWN_FACTORY; optional GAS_PRICE_WEI (default 0.1 gwei; pass the
///      same as --with-gas-price). Broadcast with --slow. Afterwards `--sig "sweep()"` returns the throwaway wallets'
///      leftover gas money. The graduation wallets and buyer B (the first of them) are the capped / floor
///      acceptances' (same label): no new wallets.
contract CountdownTestnetAcceptance is Script {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant MINTERS = 120;
    uint256 internal constant MINTER_GAS = 600_000;
    uint256 internal constant NEAR_END_FACTOR = 10;
    string internal constant MINTER_LABEL = "gang-capped-testnet";
    /// @dev CD_RUN (default 1) picks the module salt and the token's name: a second run (a new factory) gets its own.
    bytes32 internal SALT;
    string internal NAME;
    string internal SYMBOL;
    uint16 internal constant TAX_BPS = 300;
    uint16 internal constant DIVIDEND_BPS = 2_000;
    uint256 internal constant SEED = 0.2 ether;
    uint256 internal constant BUY = 0.02 ether;
    uint256 internal constant BPS = 10_000;

    error WrongChain(uint256 chainId);
    error Check(string what);

    uint256 internal deployerPk;
    address internal deployer;
    IGangPad internal pad;
    address internal q;

    function _cfg() internal pure returns (GangCountdownReward.Config memory) {
        return GangCountdownReward.Config({
            window: 30 minutes,
            maxRound: 6 hours,
            idle: 7 days,
            payoutBps: 3_000,
            lastBps: 2_000,
            devBps: 2_500,
            entries: 3,
            minBuy: 0.01 ether,
            minPot: 0.05 ether,
            maxPayout: 1 ether
        });
    }

    function run() external {
        _init();
        GangCountdownRewardFactory factory = GangCountdownRewardFactory(vm.envAddress("COUNTDOWN_FACTORY"));
        pad = IGangPad(factory.pad());
        (GangCountdownReward m, bytes32 tokenSalt) = _module(factory);
        console.log("module", address(m));
        address t = _token(m, tokenSalt);
        console.log("token", t);
        _seed(m);
        _curveBuy(t);
        _graduate(t);
        _poolTax(m, t);
        _countedBuys(m, t);
        console.log("deadline", m.deadline());
        console.log("next: after the deadline, --sig 'finish()'");
    }

    /// @notice After the deadline: settle, check each credit, claim, the dev's part, the books; round 2 starts.
    function finish() external {
        _init();
        GangCountdownReward m = _existing();
        if (m.deadline() == 0 || block.timestamp <= m.deadline()) revert Check("wait for the deadline");
        address b = vm.addr(_key(MINTER_LABEL, 0));
        (uint64 id, uint32 count,,,, GangCountdownReward.Entry[] memory list) = m.round(m.cur());
        if (id != 1 || count != 3 || list.length != 3) revert Check("round 1: three entries");
        if (list[0].buyer != deployer || list[1].buyer != b || list[2].buyer != deployer) revert Check("entries");
        (bool due,) = m.previewWork();
        if (!due) revert Check("previewWork due");
        // what the freeze will take: 30% of the pool once the arrived tax is booked
        uint256 avail = m.potAvailable();
        uint256 payout = (avail * 3_000) / BPS;
        if (payout > 1 ether) payout = 1 ether;
        uint256 extra = (payout * 2_000) / BPS;
        uint256 each = (payout - extra) / 3;
        uint256 dust = payout - extra - each * 3;
        uint256 d0 = m.claimableOf(deployer);
        uint256 b0 = m.claimableOf(b);
        vm.startBroadcast(deployerPk);
        m.work(0);
        vm.stopBroadcast();
        if (m.claimableOf(deployer) - d0 != each * 2 + extra) revert Check("deployer: two shares + the extra");
        if (m.claimableOf(b) - b0 != each) revert Check("B: one share");
        if (m.pot() != avail - payout + dust) revert Check("pot: the rest and the dust");
        if (m.reservedTotal() != 0 || m.deadline() != 0) revert Check("round over, nothing reserved");
        _books(m);
        console.log("payout / each / extra", payout, each, extra);

        // claims: the deployer, B, the dev's booked part
        uint256 qd0 = IERC20(q).balanceOf(deployer);
        uint256 cd = m.claimableOf(deployer);
        uint256 dev = m.devOwed();
        vm.startBroadcast(deployerPk);
        m.claim(deployer);
        if (dev != 0) m.claimDev();
        vm.stopBroadcast();
        if (IERC20(q).balanceOf(deployer) - qd0 != cd + dev) revert Check("deployer claimed + dev part");
        uint256 bpk = _key(MINTER_LABEL, 0);
        _prefund(b, MINTER_GAS * _gasPrice());
        uint256 qb0 = IERC20(q).balanceOf(b);
        uint256 cb = m.claimableOf(b);
        vm.startBroadcast(bpk);
        m.claim(b);
        vm.stopBroadcast();
        if (IERC20(q).balanceOf(b) - qb0 != cb) revert Check("B claimed");
        if (m.claimTotal() != 0 || m.devOwed() != 0) revert Check("all claimed");
        _books(m);

        // round 2: the next counted buy starts it
        vm.startBroadcast(deployerPk);
        _faucet(deployer, 1 ether);
        IERC20(q).approve(address(m), BUY);
        m.buyWithQuote(BUY, 0, block.timestamp + 1 hours, true);
        vm.stopBroadcast();
        if (m.currentRound() != 2) revert Check("round 2 started");
        _books(m);
        console.log("countdown acceptance ok");
    }

    /// @notice The module's state (read only).
    function report() external {
        _init();
        GangCountdownReward m = _existing();
        console.log("module", address(m));
        console.log("token / rewardToken", m.token(), m.rewardToken());
        console.log("pot / potAvailable", m.pot(), m.potAvailable());
        console.log("reservedTotal / claimTotal / devOwed", m.reservedTotal(), m.claimTotal(), m.devOwed());
        console.log("quote balance", IERC20(q).balanceOf(address(m)));
        console.log("currentRound / deadline / now", m.currentRound(), m.deadline(), block.timestamp);
        (bool due,) = m.previewWork();
        console.log("previewWork due", due);
    }

    // ---------------------------------------------------------------- steps
    function _existing() internal returns (GangCountdownReward m) {
        GangCountdownRewardFactory factory = GangCountdownRewardFactory(vm.envAddress("COUNTDOWN_FACTORY"));
        pad = IGangPad(factory.pad());
        m = GangCountdownReward(factory.predict(deployer, SALT));
        if (address(m).code.length == 0) revert Check("no module: run() first");
    }

    function _module(GangCountdownRewardFactory factory) internal returns (GangCountdownReward m, bytes32 tokenSalt) {
        Pad3VanityDeployer vd = Pad3VanityDeployer(Pad3Module(payable(address(pad))).vanityDeployer());
        bytes32 initHash = vd.tokenInitCodeHash(NAME, SYMBOL, "", pad.taxHandler(), TAX_BPS, TAX_BPS, false);
        address at = factory.predict(deployer, SALT);
        address predicted;
        vm.pauseGasMetering();
        (tokenSalt, predicted) = Pad3VanitySalt.find(address(vd), deployer, initHash);
        vm.resumeGasMetering();
        if (at.code.length != 0) {
            m = GangCountdownReward(at);
            if (m.rewardToken() != predicted) revert Check("the token salt no longer leads to rewardToken");
            return (m, tokenSalt);
        }
        console.log("token address, before it exists", predicted);
        GangCountdownReward.Config memory c = _cfg();
        vm.startBroadcast(deployerPk);
        m = GangCountdownReward(factory.create(predicted, q, c, SALT));
        vm.stopBroadcast();
        if (address(m) != at) revert Check("predicted module address");
        if (m.rewardToken() != predicted || m.token() != address(0)) revert Check("token fixed, not bound");
        if (m.rewardQuote() != q || m.dev() != deployer) revert Check("initialized");
        GangCountdownReward.Config memory got = m.config();
        if (got.window != c.window || got.devBps != c.devBps || got.entries != c.entries) revert Check("config");
        if (!m.keeperServes(q)) revert Check("keeper serves the test quote");
    }

    function _token(GangCountdownReward m, bytes32 tokenSalt) internal returns (address t) {
        t = m.rewardToken();
        if (t.code.length == 0) {
            bytes memory data = abi.encodeWithSignature(
                "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))",
                NAME,
                SYMBOL,
                "",
                "",
                q,
                address(0),
                IGangLaunchpad.TaxConfig({
                    buyTaxBps: TAX_BPS, sellTaxBps: TAX_BPS, dividendBps: DIVIDEND_BPS, recipient: address(m)
                })
            );
            vm.startBroadcast(deployerPk);
            address created = Pad3Module(payable(address(pad))).createWithSalt(tokenSalt, data);
            vm.stopBroadcast();
            if (created != t) revert Check("the token is not at the address the module was cloned for");
        }
        if (m.token() == address(0)) {
            vm.startBroadcast(deployerPk);
            m.bind(t);
            vm.stopBroadcast();
        }
        if (m.token() != t || m.quote() != q) revert Check("bound");
    }

    /// @dev The seed is the pool's, all of it (no dev part).
    function _seed(GangCountdownReward m) internal {
        if (m.pot() >= SEED) return;
        uint256 dev0 = m.devOwed();
        uint256 pot0 = m.pot();
        vm.startBroadcast(deployerPk);
        _faucet(deployer, 1 ether);
        IERC20(q).approve(address(m), SEED);
        m.fund(SEED);
        vm.stopBroadcast();
        if (m.pot() - pot0 != SEED || m.devOwed() != dev0) revert Check("seed: all to the pool");
        _books(m);
    }

    function _curveBuy(address t) internal {
        if (_graduated(t) || IERC20(t).balanceOf(deployer) > 0) return;
        vm.startBroadcast(deployerPk);
        _faucet(deployer, 1 ether);
        IERC20(q).approve(address(pad), type(uint256).max);
        pad.buy(t, 1 ether, 0);
        vm.stopBroadcast();
    }

    function _graduate(address t) internal {
        uint256 gasPer = MINTER_GAS * _gasPrice();
        for (uint256 i = 0; i < MINTERS; i++) {
            if (_graduated(t)) break;
            uint256 pk = _key(MINTER_LABEL, i);
            address mt = vm.addr(pk);
            if (IERC20(t).balanceOf(mt) > 0) continue;
            _prefund(mt, pad.graduationRemaining(t) < 3 ether ? gasPer * NEAR_END_FACTOR : gasPer);
            _register(pk);
            vm.startBroadcast(pk);
            _faucet(mt, 1 ether);
            IERC20(q).approve(address(pad), type(uint256).max);
            pad.buy(t, 1 ether, 0);
            vm.stopBroadcast();
        }
        if (!_graduated(t)) revert Check("not graduated");
    }

    /// @dev Deployer: two pool sells (their swap-backs pay the module); the arrival is then booked with the dev part.
    function _poolTax(GangCountdownReward m, address t) internal {
        if (m.devOwed() != 0) return; // a re-run: already booked
        uint256 pot0 = m.pot();
        vm.startBroadcast(deployerPk);
        _faucet(deployer, 1 ether);
        _swap(q, t, 0.3 ether);
        _swap(t, q, IERC20(t).balanceOf(deployer) / 4);
        _swap(t, q, IERC20(t).balanceOf(deployer) / 4);
        vm.stopBroadcast();
        uint256 bal = IERC20(q).balanceOf(address(m));
        uint256 arrived = bal - (m.pot() + m.reservedTotal() + m.claimTotal() + m.devOwed());
        console.log("tax arrived", arrived);
        if (arrived == 0) revert Check("the pool tax reached the module");
        uint256 toDev = (arrived * 2_500) / BPS;
        if (m.potAvailable() != pot0 + arrived - toDev) revert Check("potAvailable");
        vm.startBroadcast(deployerPk);
        m.settle(); // books it
        vm.stopBroadcast();
        if (m.devOwed() != toDev || m.pot() != pot0 + arrived - toDev) revert Check("tax booked with the dev part");
        _books(m);
    }

    /// @dev Three counted buys through the module on the real pair: deployer, B, deployer.
    function _countedBuys(GangCountdownReward m, address t) internal {
        if (m.currentRound() != 0) return; // a re-run
        address b = vm.addr(_key(MINTER_LABEL, 0));
        uint256 bpk = _key(MINTER_LABEL, 0);
        _prefund(b, MINTER_GAS * _gasPrice() * 2);
        _buy(m, t, deployerPk);
        _buy(m, t, bpk);
        _buy(m, t, deployerPk);
        (uint64 id, uint32 count,,,,) = m.round(m.cur());
        if (id != 1 || count != 3) revert Check("round 1, three counted");
        _books(m);
    }

    function _buy(GangCountdownReward m, address t, uint256 pk) internal {
        address who = vm.addr(pk);
        uint256 mod0 = IERC20(q).balanceOf(address(m));
        uint256 t0 = IERC20(t).balanceOf(who);
        vm.startBroadcast(pk);
        _faucet(who, 1 ether);
        IERC20(q).approve(address(m), BUY);
        uint256 out = m.buyWithQuote(BUY, 0, block.timestamp + 1 hours, true);
        vm.stopBroadcast();
        if (out == 0 || IERC20(t).balanceOf(who) - t0 != out) revert Check("the buyer got the tokens");
        if (IERC20(q).balanceOf(address(m)) != mod0) revert Check("nothing of the buy stays in the module");
        if (m.deadline() != block.timestamp + 30 minutes) revert Check("deadline = now + window");
        console.log("counted buy: tokens out", out);
    }

    function _books(GangCountdownReward m) internal view {
        uint256 held = m.pot() + m.reservedTotal() + m.claimTotal() + m.devOwed();
        if (IERC20(q).balanceOf(address(m)) < held) revert Check("books covered by the balance");
    }

    /// @notice Return each throwaway wallet's leftover gas money to the deployer.
    function sweep() external {
        _init();
        uint256 fee = 21_000 * _gasPrice();
        uint256 total;
        for (uint256 i = 0; i < MINTERS; i++) {
            uint256 pk = _key(MINTER_LABEL, i);
            address mt = vm.addr(pk);
            if (mt.balance <= 2 * fee) continue;
            uint256 amount = mt.balance - 2 * fee;
            vm.startBroadcast(pk);
            (bool ok,) = payable(deployer).call{value: amount}("");
            vm.stopBroadcast();
            if (!ok) revert Check("sweep");
            total += amount;
        }
        console.log("swept", total);
    }

    // ---------------------------------------------------------------- helpers
    function _init() internal {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPk);
        q = T.TEST_QUOTE;
        uint256 runId = vm.envOr("CD_RUN", uint256(1));
        if (runId == 1) {
            (SALT, NAME, SYMBOL) = (keccak256("countdown-acceptance-1"), "Countdown Test", "CDRT");
        } else {
            string memory n = vm.toString(runId);
            SALT = keccak256(bytes(string.concat("countdown-acceptance-", n)));
            (NAME, SYMBOL) = (string.concat("Countdown Test ", n), string.concat("CDR", n));
        }
    }

    function _register(uint256 pk) internal {
        ICdAgentIdLite agentId = ICdAgentIdLite(pad.agentIdRegistry());
        if (agentId.balanceOf(vm.addr(pk)) > 0) return;
        vm.startBroadcast(pk);
        agentId.register();
        vm.stopBroadcast();
    }

    function _prefund(address to, uint256 amount) internal {
        if (to.balance >= amount) return;
        vm.startBroadcast(deployerPk);
        (bool ok,) = payable(to).call{value: amount - to.balance}("");
        vm.stopBroadcast();
        if (!ok) revert Check("prefund");
    }

    /// @dev MockSPCXB faucet (≤ 1,000 per address); call inside a broadcast of `to` or the deployer.
    function _faucet(address to, uint256 amount) internal {
        if (IERC20(q).balanceOf(to) >= amount) return;
        MockSPCXB(q).mint(to, amount - IERC20(q).balanceOf(to));
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        address[] memory path = new address[](2);
        (path[0], path[1]) = (tokenIn, tokenOut);
        IERC20(tokenIn).approve(T.PANCAKE_V2_ROUTER, amountIn);
        IPancakeRouter02(T.PANCAKE_V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn, 0, path, deployer, block.timestamp + 1 days
            );
    }

    function _graduated(address t) internal view returns (bool g) {
        (,,,,,, g,,,,,) = pad.curves(t);
    }

    function _gasPrice() internal view returns (uint256) {
        return vm.envOr("GAS_PRICE_WEI", uint256(0.1 gwei));
    }

    function _key(string memory label, uint256 i) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(label, deployerPk, i))) % (SECP256K1_N - 1) + 1;
    }
}
