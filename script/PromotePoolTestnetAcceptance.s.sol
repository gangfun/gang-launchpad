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
import {GangPromotePoolModule as M} from "../src/gang/GangPromotePoolModule.sol";
import {GangPromotePoolModuleFactory as F} from "../src/gang/GangPromotePoolModuleFactory.sol";

interface IPoolAcceptanceAgentId {
    function balanceOf(address) external view returns (uint256);
    function register() external returns (uint256);
}

/// @title PromotePoolTestnetAcceptance — the pool side of the promoter share on BSC testnet
/// @notice One round on the real handler, Pancake pair and Agent ID registry, in steps, because a script's checks only
///         run in its simulation and the root comes from scripts/promote-settle/settle.mjs, between them:
///         1. `run` (broadcast): the deploy wallet clones a module and creates a token in the test quote (buy tax 2%, sell
///            tax 4%, 20% dividends, 20% promoter share for 7 days) paying it, and binds it. Throwaway Agents: `bound`
///            buys naming `promoter`, `plain` names nobody, minters fill the curve. In the pool `bound` and `plain` buy and
///            sell (the sells' swap-backs pay the module), `work` splits. Prints the addresses for settle.mjs.
///         2. `verify(m, t)` (read only): the binding, the terms, and that the split reached the books from chain.
///         3. `post(m, root, allocated, through)` (broadcast): the settler posts. `postWrong` + `veto` first, to show a bad
///            root can be dropped and the same period posted again.
///         4. `claim(m, cumulative, proof)` as the promoter, after the two-day window (broadcast, or on a fork with
///            `vm.warp`); `sweep()` returns the wallets' gas money.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, PROMOTE_POOL_FACTORY. The deploy wallet owns the factory; the settler's key
///      derives from DEPLOYER_PRIVATE_KEY like the others (the factory must name it: `settlerAddress()`). Broadcast with
///      --slow --legacy --with-gas-price 100000000 --gas-estimate-multiplier 500: a split needs PUSH_GAS × 64/63 + PUSH_RESERVE
///      left to start the dev's push, whatever the push ends up using, and forge sizes a tx by what it used in simulation.
contract PromotePoolTestnetAcceptance is Script {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant MINTERS = 120;
    uint256 internal constant MINTER_GAS = 600_000;
    uint256 internal constant NEAR_END_FACTOR = 10;
    uint256 internal constant WALLET_GAS = 0.01 ether;
    string internal constant MINTER_LABEL = "gang-promote-pool-testnet";
    uint16 internal constant SHARE = 2_000;
    uint32 internal constant WINDOW = 7 days;

    error WrongChain(uint256 chainId);
    error Check(string what);

    uint256 internal deployerPk;
    address internal deployer;
    F internal factory;
    IGangPad internal pad;
    address internal q;

    function settlerAddress() external returns (address) {
        _env();
        return vm.addr(_key("settler", 0));
    }

    function run() external {
        _env();
        uint256 boundPk = _key("bound", 0);
        uint256 plainPk = _key("plain", 0);
        uint256 promoterPk = _key("promoter", 0);
        address promoter = vm.addr(promoterPk);
        if (factory.settler() != vm.addr(_key("settler", 0))) revert Check("the factory's settler");

        bytes32 salt = keccak256(abi.encode("promote-pool-acceptance", block.number));
        vm.startBroadcast(deployerPk);
        M m = M(factory.create(salt));
        address t = Pad3Module(payable(address(pad)))
            .createWithPromote(
                "Pool Share Test",
                "POOL",
                "",
                "",
                q,
                address(0),
                IGangLaunchpad.TaxConfig({buyTaxBps: 200, sellTaxBps: 400, dividendBps: 2000, recipient: address(m)}),
                6 ether,
                SHARE,
                WINDOW
            );
        m.bind(t);
        vm.stopBroadcast();
        if (m.token() != t || m.quote() != q || m.shareBps() != SHARE || m.window() != WINDOW) revert Check("bound");
        console.log("module");
        console.log(address(m));
        console.log("token");
        console.log(t);
        console.log("promoter");
        console.log(promoter);

        _prefund(vm.addr(boundPk), WALLET_GAS);
        _prefund(vm.addr(plainPk), WALLET_GAS);
        _prefund(promoter, WALLET_GAS);
        _register(promoterPk);
        _curveBuy(boundPk, t, promoter);
        _curveBuy(plainPk, t, address(0));
        (address bound_,,) = Pad3Module(payable(address(pad))).bindingOf(t, vm.addr(boundPk));
        if (bound_ != promoter) revert Check("bound on the curve");
        (bound_,,) = Pad3Module(payable(address(pad))).bindingOf(t, vm.addr(plainPk));
        if (bound_ != address(0)) revert Check("plain is not bound");
        uint256 curveFee = Pad3Module(payable(address(pad))).promoterFeeOf(t, promoter);
        if (curveFee == 0) revert Check("the curve share accrued");

        _graduate(t);

        // the pool, in order: a bound buy, a plain buy, then sells of each: the sells' swap-backs sell the oldest tax first
        _poolRound(boundPk, plainPk, t);
        vm.startBroadcast(deployerPk);
        m.work(0);
        vm.stopBroadcast();
        console.log("escrowIn", m.escrowIn());
        if (m.escrowIn() == 0) revert Check("the escrow got nothing");
        if (Pad3Module(payable(address(pad))).promoterFeeOf(t, promoter) != curveFee) {
            revert Check("the curve share moved");
        }
        console.log("promote pool run done");
    }

    /// @notice Split what arrived (resuming a run whose last step ran out of gas).
    function split(M m) external {
        _env();
        vm.startBroadcast(deployerPk);
        m.work(0);
        vm.stopBroadcast();
        console.log("escrowIn", m.escrowIn());
    }

    /// @notice Read back from chain, with no broadcast: what `run` only saw in its simulation.
    function verify(M m, address t) external {
        _env();
        (address p,,) = Pad3Module(payable(address(pad))).bindingOf(t, vm.addr(_key("bound", 0)));
        if (p != vm.addr(_key("promoter", 0))) revert Check("binding");
        if (m.token() != t || m.closed() || !m.escrowOpen()) revert Check("module state");
        (,,,,,, bool graduated,,,,,) = pad.curves(t);
        if (!graduated) revert Check("graduated");
        if (m.firstGradSeenAt() == 0) revert Check("graduation seen");
        uint256 esc = m.escrowIn();
        if (esc == 0) revert Check("escrow");
        if (IERC20(q).balanceOf(address(m)) < m.held()) revert Check("the module holds what it owes");
        console.log("escrowIn", esc);
        console.log("verified on chain");
    }

    /// @notice A bad root posted, then dropped by the owner: the same period can be posted again.
    function postWrongThenVeto(M m, uint64 through) external {
        _env();
        uint256 settlerPk = _key("settler", 0);
        _prefund(vm.addr(settlerPk), WALLET_GAS);
        vm.startBroadcast(settlerPk);
        m.post(keccak256("a wrong root"), 0, through, "acceptance: wrong on purpose");
        vm.stopBroadcast();
        vm.startBroadcast(deployerPk);
        m.veto();
        vm.stopBroadcast();
        if (m.pendingRoot() != bytes32(0)) revert Check("vetoed");
        console.log("veto done");
    }

    function post(M m, bytes32 root, uint256 allocated, uint64 through) external {
        _env();
        uint256 settlerPk = _key("settler", 0);
        _prefund(vm.addr(settlerPk), WALLET_GAS);
        vm.startBroadcast(settlerPk);
        m.post(root, allocated, through, "acceptance");
        vm.stopBroadcast();
        if (m.pendingRoot() != root || m.pendingAllocated() != allocated) revert Check("posted");
        console.log("activeAt", m.pendingActiveAt());
    }

    /// @notice As the promoter: only after the dispute window. A pending root must not pay.
    function claim(M m, uint256 cumulative, bytes32[] calldata proof) external {
        _env();
        uint256 pk = _key("promoter", 0);
        address who = vm.addr(pk);
        uint256 before = IERC20(q).balanceOf(who);
        vm.startBroadcast(pk);
        uint256 got = m.claim(cumulative, proof, who);
        vm.stopBroadcast();
        if (got == 0 || IERC20(q).balanceOf(who) - before != got) revert Check("claim paid");
        console.log("claimed", got);
    }

    /// @notice Return each wallet's leftover gas money to the deployer.
    function sweep() external {
        _env();
        uint256 fee = 21_000 * _gasPrice();
        uint256 total;
        string[4] memory labels = ["bound", "plain", "promoter", "settler"];
        for (uint256 i = 0; i < MINTERS + 4; i++) {
            uint256 pk = i < MINTERS ? _key(MINTER_LABEL, i) : _key(labels[i - MINTERS], 0);
            address w = vm.addr(pk);
            if (w.balance <= 2 * fee) continue;
            uint256 amount = w.balance - 2 * fee;
            vm.startBroadcast(pk);
            (bool ok,) = payable(deployer).call{value: amount}("");
            vm.stopBroadcast();
            if (!ok) revert Check("sweep");
            total += amount;
        }
        console.log("swept", total);
    }

    // ---------------------------------------------------------------- helpers
    function _env() internal {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPk);
        factory = F(vm.envAddress("PROMOTE_POOL_FACTORY"));
        pad = IGangPad(factory.pad());
        q = T.TEST_QUOTE;
    }

    function _curveBuy(uint256 pk, address t, address promoter) internal {
        _register(pk);
        vm.startBroadcast(pk);
        _faucet(vm.addr(pk), 1 ether);
        IERC20(q).approve(address(pad), type(uint256).max);
        Pad3Module(payable(address(pad))).buyWithPromoter(t, 0.05 ether, 0, promoter);
        vm.stopBroadcast();
    }

    function _graduate(address t) internal {
        uint256 gasPer = MINTER_GAS * _gasPrice();
        for (uint256 i = 0; i < MINTERS; i++) {
            if (_graduated(t)) break;
            uint256 pk = _key(MINTER_LABEL, i);
            address w = vm.addr(pk);
            if (IERC20(t).balanceOf(w) > 0) continue;
            _prefund(w, pad.graduationRemaining(t) < 3 ether ? gasPer * NEAR_END_FACTOR : gasPer);
            _register(pk);
            vm.startBroadcast(pk);
            _faucet(w, 1 ether);
            IERC20(q).approve(address(pad), type(uint256).max);
            pad.buy(t, 1 ether, 0);
            vm.stopBroadcast();
        }
        if (!_graduated(t)) revert Check("not graduated");
    }

    function _poolRound(uint256 boundPk, uint256 plainPk, address t) internal {
        _swapAs(boundPk, q, t, 0.02 ether);
        _swapAs(plainPk, q, t, 0.02 ether);
        for (uint256 i; i < 3; i++) {
            _swapAs(boundPk, t, q, IERC20(t).balanceOf(vm.addr(boundPk)) / 3);
            _swapAs(plainPk, t, q, IERC20(t).balanceOf(vm.addr(plainPk)) / 3);
        }
    }

    function _swapAs(uint256 pk, address tokenIn, address tokenOut, uint256 amountIn) internal {
        address who = vm.addr(pk);
        address[] memory path = new address[](2);
        (path[0], path[1]) = (tokenIn, tokenOut);
        vm.startBroadcast(pk);
        IERC20(tokenIn).approve(T.PANCAKE_V2_ROUTER, amountIn);
        IPancakeRouter02(T.PANCAKE_V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, who, block.timestamp + 1 days);
        vm.stopBroadcast();
    }

    function _register(uint256 pk) internal {
        IPoolAcceptanceAgentId agentId = IPoolAcceptanceAgentId(pad.agentIdRegistry());
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
