// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {MockSPCXB} from "../src/launchpad-v2/mocks/MockSPCXB.sol";
import {IPancakeRouter02} from "../src/launchpad-v2/interfaces/IPancake.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {GangComboSplitter} from "../src/gang/GangComboSplitter.sol";
import {GangComboSplitterFactory} from "../src/gang/GangComboSplitterFactory.sol";

interface IComboAgentIdLite {
    function balanceOf(address) external view returns (uint256);
    function register() external returns (uint256);
}

interface IComboPairLite {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title ComboTestnetAcceptance — one on-chain round of GangComboSplitter on BSC testnet
/// @notice `run`: the deployer clones a combined splitter (30% buy-back, 30% liquidity, the rest 70 / 30 to itself and a
///         throwaway payee B), creates a taxed V3 token in the test quote paying it, binds it, buys on the curve;
///         throwaway Agents fill the curve (graduation); a pool buy and sell pay the tax, the sell's swap-back pays the
///         splitter; `split` sets 30% + 30% aside and pays the payees (checked to the wei); the keeper's first `work`
///         records the TWAP observation. The chunks wait for the 10-minute window: send `work(previewWork().minOut)`
///         as the keeper does (`cast send`, the node's gas estimate) and read the result with `--sig "report()"`.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, COMBO_FACTORY; optional COMBO_MODULE, TOKEN (resume), SKIP_POOL,
///      GAS_PRICE_WEI (default 0.1 gwei; pass the same as --with-gas-price). Broadcast with --slow. Afterwards
///      `--sig "sweep()"` returns the minters' leftover gas money. Wallet keys derive from DEPLOYER_PRIVATE_KEY.
contract ComboTestnetAcceptance is Script {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant MINTERS = 120;
    uint256 internal constant MINTER_GAS = 600_000;
    uint256 internal constant NEAR_END_FACTOR = 10;
    string internal constant MINTER_LABEL = "gang-combo-testnet";
    bytes32 internal constant SALT = keccak256("combo-acceptance-1");
    uint16 internal constant BB_BPS = 3_000;
    uint16 internal constant LP_BPS = 3_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    error WrongChain(uint256 chainId);
    error Check(string what);

    uint256 internal deployerPk;
    address internal deployer;
    IGangPad internal pad;
    address internal q;

    function run() external {
        _init();
        GangComboSplitterFactory factory = GangComboSplitterFactory(vm.envAddress("COMBO_FACTORY"));
        pad = IGangPad(factory.pad());
        address b = vm.addr(_key("b", 0));
        GangComboSplitter s = _module(factory, b);
        console.log("module", address(s));
        address t = _token(s);
        console.log("token", t);
        _curveBuy(t);
        _graduate(t);
        _poolRound(t);
        _split(s, b);
        if (s.lastChunkAt() == 0) {
            (bool due, uint256 minOut) = s.previewWork();
            if (due && minOut >> 248 == 3) {
                vm.startBroadcast(deployerPk);
                s.work(minOut); // records the observation (the keeper's first call)
                vm.stopBroadcast();
            }
        }
        console.log("observation recorded; chunks from", block.timestamp + 10 minutes);
    }

    /// @notice The splitter's state after the chunks (read only): COMBO_MODULE.
    function report() external view {
        GangComboSplitter s = GangComboSplitter(vm.envAddress("COMBO_MODULE"));
        address p = s.pair();
        console.log("pair", p);
        console.log("buybackLeft", s.buybackLeft());
        console.log("lpLeft", s.lpLeft());
        console.log("unsplit", s.unsplit());
        console.log("lastChunkAt", uint256(s.lastChunkAt()));
        if (p != address(0)) {
            console.log("tokens at 0xdead", IERC20(s.token()).balanceOf(DEAD));
            console.log("LP at 0xdead", IComboPairLite(p).balanceOf(DEAD));
            console.log("LP held by the module", IComboPairLite(p).balanceOf(address(s)));
            console.log("tokens held by the module", IERC20(s.token()).balanceOf(address(s)));
        }
        (bool ready, bool burn, uint256 amount, uint256 tokensOut) = s.previewChunk();
        console.log("previewChunk ready / burn", ready, burn);
        console.log("  amount / tokensOut", amount, tokensOut);
        (bool due, uint256 minOut) = s.previewWork();
        console.log("previewWork due / action", due, minOut >> 248);
        console.log("  minOut (encoded)", minOut);
    }

    // ---------------------------------------------------------------- steps
    function _module(GangComboSplitterFactory factory, address b) internal returns (GangComboSplitter s) {
        address given = vm.envOr("COMBO_MODULE", address(0));
        if (given != address(0)) return GangComboSplitter(given);
        address at = factory.predict(deployer, SALT);
        if (at.code.length != 0) return GangComboSplitter(at);
        address[] memory p = new address[](2);
        (p[0], p[1]) = (deployer, b);
        uint16[] memory sh = new uint16[](2);
        (sh[0], sh[1]) = (7_000, 3_000);
        vm.startBroadcast(deployerPk);
        s = GangComboSplitter(factory.create(BB_BPS, LP_BPS, p, sh, SALT));
        vm.stopBroadcast();
        if (address(s) != at) revert Check("predicted address");
        if (s.buybackBps() != BB_BPS || s.lpBps() != LP_BPS || s.dev() != deployer) revert Check("initialized");
        if (!s.keeperServes(q)) revert Check("keeper serves the test quote");
    }

    function _token(GangComboSplitter s) internal returns (address t) {
        t = vm.envOr("TOKEN", address(0));
        if (t == address(0)) {
            vm.startBroadcast(deployerPk);
            t = pad.create(
                "Combo Test",
                "CMBT",
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

    /// @dev `split`: 30% + 30% set aside, the rest to the payees (B 30% of it, the deployer the rest), to the wei.
    function _split(GangComboSplitter s, address b) internal {
        uint256 incoming = s.unsplit();
        console.log("unsplit", incoming);
        if (incoming == 0 && s.buybackLeft() + s.lpLeft() == 0) revert Check("tax reached the splitter");
        if (incoming == 0) return;
        uint256 bb0 = s.buybackLeft();
        uint256 lp0 = s.lpLeft();
        uint256 b0 = IERC20(q).balanceOf(b);
        uint256 d0 = IERC20(q).balanceOf(deployer);
        vm.startBroadcast(deployerPk);
        s.split();
        vm.stopBroadcast();
        uint256 toB = (incoming * BB_BPS) / 10_000;
        uint256 toL = (incoming * LP_BPS) / 10_000;
        uint256 toP = incoming - toB - toL;
        uint256 toPayeeB = (toP * 3_000) / 10_000;
        if (s.buybackLeft() - bb0 != toB) revert Check("buy-back part");
        if (s.lpLeft() - lp0 != toL) revert Check("liquidity part");
        if (IERC20(q).balanceOf(b) - b0 != toPayeeB) revert Check("payee B part");
        if (IERC20(q).balanceOf(deployer) - d0 != toP - toPayeeB) revert Check("payee 0 part");
        console.log("buy-back / liquidity set aside", toB, toL);
        console.log("paid B / deployer", toPayeeB, toP - toPayeeB);
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
        IComboAgentIdLite agentId = IComboAgentIdLite(pad.agentIdRegistry());
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
