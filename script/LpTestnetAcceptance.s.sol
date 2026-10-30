// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {MockSPCXB} from "../src/launchpad-v2/mocks/MockSPCXB.sol";
import {IPancakeRouter02} from "../src/launchpad-v2/interfaces/IPancake.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {GangLiquiditySplitter} from "../src/gang/GangLiquiditySplitter.sol";
import {GangLiquiditySplitterFactory} from "../src/gang/GangLiquiditySplitterFactory.sol";

interface ILpAgentIdLite {
    function balanceOf(address) external view returns (uint256);
    function register() external returns (uint256);
}

interface ILpPairLite {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title LpTestnetAcceptance — one on-chain round of GangLiquiditySplitter on BSC testnet
/// @notice `run`: the deployer clones a 70% LP splitter (its dev part to a throwaway payee B), creates a taxed V3 token in
///         the test quote paying it, binds it, buys on the curve; throwaway Agents fill the curve (graduation); a pool
///         buy and sell pay the tax, the sell's swap-back pays the splitter; `split` sets 70% aside and pays B the rest
///         (checked to the wei); a first `addChunk(0)` records the TWAP observation. The chunks themselves wait for the
///         10-minute window: send them as the keeper does (`cast send … "addChunk(uint256)"` with the node's gas
///         estimate) and read the result with `--sig "report()"`.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, LP_FACTORY; optional LP_MODULE, TOKEN (resume), SKIP_POOL,
///      GAS_PRICE_WEI (default 0.1 gwei; pass the same as --with-gas-price). Broadcast with --slow. Afterwards
///      `--sig "sweep()"` returns the minters' leftover gas money. Wallet keys derive from DEPLOYER_PRIVATE_KEY.
contract LpTestnetAcceptance is Script {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant MINTERS = 120;
    uint256 internal constant MINTER_GAS = 600_000;
    uint256 internal constant NEAR_END_FACTOR = 10;
    string internal constant MINTER_LABEL = "gang-lp-testnet";
    bytes32 internal constant SALT = keccak256("lp-acceptance-1");
    uint16 internal constant LP_BPS = 7_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    error WrongChain(uint256 chainId);
    error Check(string what);

    uint256 internal deployerPk;
    address internal deployer;
    IGangPad internal pad;
    address internal q;

    function run() external {
        _init();
        GangLiquiditySplitterFactory factory = GangLiquiditySplitterFactory(vm.envAddress("LP_FACTORY"));
        pad = IGangPad(factory.pad());
        address b = vm.addr(_key("b", 0));
        GangLiquiditySplitter s = _module(factory, b);
        console.log("module", address(s));
        address t = _token(s);
        console.log("token", t);
        _curveBuy(t);
        _graduate(t);
        _poolRound(t);
        _split(s, b);
        if (s.lastAddAt() == 0) {
            vm.startBroadcast(deployerPk);
            s.addChunk(0); // records the observation (no trade)
            vm.stopBroadcast();
        }
        console.log("observation recorded; add chunks from", block.timestamp + 10 minutes);
    }

    /// @notice The splitter's state after the chunks (read only): LP_MODULE.
    function report() external view {
        GangLiquiditySplitter s = GangLiquiditySplitter(vm.envAddress("LP_MODULE"));
        address p = s.pair();
        console.log("pair", p);
        console.log("lpLeft", s.lpLeft());
        console.log("unsplit", s.unsplit());
        console.log("devOwed", s.devOwed());
        console.log("lastAddAt", uint256(s.lastAddAt()));
        if (p != address(0)) {
            console.log("LP at 0xdead", ILpPairLite(p).balanceOf(DEAD));
            console.log("LP supply", ILpPairLite(p).totalSupply());
            console.log("LP held by the module", ILpPairLite(p).balanceOf(address(s)));
            console.log("tokens held by the module", IERC20(s.token()).balanceOf(address(s)));
        }
        (bool ready, uint256 chunk, uint256 tokensOut) = s.previewAdd();
        console.log("previewAdd ready", ready);
        console.log("  chunk / tokensOut", chunk, tokensOut);
        (bool due, uint256 minOut) = s.previewWork();
        console.log("previewWork due", due, minOut);
    }

    // ---------------------------------------------------------------- steps
    function _module(GangLiquiditySplitterFactory factory, address b) internal returns (GangLiquiditySplitter s) {
        address given = vm.envOr("LP_MODULE", address(0));
        if (given != address(0)) return GangLiquiditySplitter(given);
        address at = factory.predict(deployer, SALT);
        if (at.code.length != 0) return GangLiquiditySplitter(at);
        vm.startBroadcast(deployerPk);
        s = GangLiquiditySplitter(factory.create(LP_BPS, SALT, b));
        vm.stopBroadcast();
        if (address(s) != at) revert Check("predicted address");
        if (s.payee() != b || s.lpBps() != LP_BPS || s.dev() != deployer) revert Check("initialized");
    }

    function _token(GangLiquiditySplitter s) internal returns (address t) {
        t = vm.envOr("TOKEN", address(0));
        if (t == address(0)) {
            vm.startBroadcast(deployerPk);
            t = pad.create(
                "LP Test",
                "LPT",
                "",
                "",
                q,
                address(0),
                IGangLaunchpad.TaxConfig({buyTaxBps: 300, sellTaxBps: 300, dividendBps: 4000, recipient: address(s)})
            );
            vm.stopBroadcast();
        }
        if (s.token() == address(0)) {
            vm.startBroadcast(deployerPk);
            s.bind(t);
            vm.stopBroadcast();
        }
        if (s.token() != t || s.quote() != q) revert Check("bound");
    }

    function _curveBuy(address t) internal {
        if (_graduated(t) || IERC20(t).balanceOf(deployer) > 0) return;
        vm.startBroadcast(deployerPk);
        _faucet(deployer, 1 ether);
        IERC20(q).approve(address(pad), type(uint256).max);
        pad.buy(t, 1 ether, 0); // up to the 1% cap
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

    /// @dev Deployer: a pool buy (tax accrues) and a sell of half its tokens (the swap-back pays the splitter).
    function _poolRound(address t) internal {
        if (vm.envOr("SKIP_POOL", false)) return;
        console.log("pair", _pair(t));
        vm.startBroadcast(deployerPk);
        _faucet(deployer, 1 ether);
        _swap(q, t, 0.5 ether);
        _swap(t, q, IERC20(t).balanceOf(deployer) / 2);
        vm.stopBroadcast();
    }

    /// @dev `split`: 70% set aside, the rest pushed to B, to the wei.
    function _split(GangLiquiditySplitter s, address b) internal {
        uint256 incoming = s.unsplit();
        console.log("unsplit", incoming);
        if (incoming == 0 && s.lpLeft() == 0) revert Check("tax reached the splitter");
        if (incoming == 0) return;
        uint256 left0 = s.lpLeft();
        uint256 b0 = IERC20(q).balanceOf(b);
        vm.startBroadcast(deployerPk);
        s.split();
        vm.stopBroadcast();
        uint256 toLp = (incoming * LP_BPS) / 10_000;
        if (s.lpLeft() - left0 != toLp) revert Check("LP part");
        if (IERC20(q).balanceOf(b) - b0 != incoming - toLp) revert Check("payee part");
        console.log("set aside / paid to B", toLp, incoming - toLp);
    }

    /// @notice Return each wallet's leftover gas money to the deployer.
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
    }

    function _register(uint256 pk) internal {
        ILpAgentIdLite agentId = ILpAgentIdLite(pad.agentIdRegistry());
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

    function _pair(address t) internal view returns (address p) {
        (,,,,,,,,,, p,) = pad.curves(t);
    }

    function _gasPrice() internal view returns (uint256) {
        return vm.envOr("GAS_PRICE_WEI", uint256(0.1 gwei));
    }

    function _key(string memory label, uint256 i) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(label, deployerPk, i))) % (SECP256K1_N - 1) + 1;
    }
}
