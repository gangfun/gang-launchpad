// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {MockSPCXB} from "../src/launchpad-v2/mocks/MockSPCXB.sol";
import {IPancakeRouter02} from "../src/launchpad-v2/interfaces/IPancake.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {GangSplitModule} from "../src/gang/GangSplitModule.sol";
import {GangSplitModuleFactory} from "../src/gang/GangSplitModuleFactory.sol";

interface ITestnetAgentIdLite {
    function balanceOf(address) external view returns (uint256);
    function register() external returns (uint256);
}

interface IWBNBLite {
    function deposit() external payable;
}

/// @title SplitTestnetAcceptance — one on-chain round of GangSplitModule on BSC testnet
/// @notice The deployer clones a split module (itself 60%, B 30%, C 10%), creates a taxed V3 token in the test quote
///         paying it, binds it, and buys on the curve; throwaway Agents fill the curve (graduation); a pool buy and
///         sell pay the tax, the sell's swap-back pays the module; the keeper step (`previewWork` / `work`) splits it,
///         checked to the wei against the module's rule (the others rounded down, the first takes the rest). Then:
///         another asset (WBNB) sent to the module splits at the same shares, and C moves its slot to C2 (`setPayee`)
///         and is paid there.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, SPLIT_FACTORY; optional SPLIT_MODULE, TOKEN (resume), GAS_PRICE_WEI
///      (default 0.1 gwei; pass the same as --with-gas-price). Broadcast with --slow. Afterwards `--sig "sweep()"`
///      returns the minters' leftover gas money. Wallet keys derive from DEPLOYER_PRIVATE_KEY (worthless off testnet).
contract SplitTestnetAcceptance is Script {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant MINTERS = 120;
    uint256 internal constant MINTER_GAS = 600_000;
    uint256 internal constant NEAR_END_FACTOR = 10;
    string internal constant MINTER_LABEL = "gang-split-testnet";
    bytes32 internal constant SALT = keccak256("split-acceptance-1");

    error WrongChain(uint256 chainId);
    error Check(string what);

    uint256 internal deployerPk;
    address internal deployer;
    IGangPad internal pad;
    address internal q;

    function run() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPk);
        GangSplitModuleFactory factory = GangSplitModuleFactory(vm.envAddress("SPLIT_FACTORY"));
        pad = IGangPad(factory.pad());
        q = T.TEST_QUOTE;
        uint256 cPk = _key("c", 0);
        address b = vm.addr(_key("b", 0));
        address c = vm.addr(cPk);
        address c2 = vm.addr(_key("c2", 0));

        GangSplitModule m = _module(factory, b, c);
        console.log("module", address(m));
        address t = _token(m);
        console.log("token", t);
        _curveBuy(t);
        _graduate(t);
        _poolRound(t);
        _keeperSplit(m);
        _otherAsset(m, b);
        _move(m, cPk, c2);
    }

    // ---------------------------------------------------------------- steps
    function _module(GangSplitModuleFactory factory, address b, address c) internal returns (GangSplitModule m) {
        address given = vm.envOr("SPLIT_MODULE", address(0));
        if (given != address(0)) return GangSplitModule(given);
        address at = factory.predict(deployer, SALT);
        if (at.code.length != 0) return GangSplitModule(at);
        address[] memory p = new address[](3);
        (p[0], p[1], p[2]) = (deployer, b, c);
        uint16[] memory s = new uint16[](3);
        (s[0], s[1], s[2]) = (6_000, 3_000, 1_000);
        vm.startBroadcast(deployerPk);
        m = GangSplitModule(factory.create(p, s, SALT));
        vm.stopBroadcast();
        if (address(m) != at) revert Check("predicted address");
        if (!GangSplitModule(m).keeperServes(q)) revert Check("keeper serves the test quote");
    }

    function _token(GangSplitModule m) internal returns (address t) {
        t = vm.envOr("TOKEN", address(0));
        if (t == address(0)) {
            vm.startBroadcast(deployerPk);
            t = pad.create(
                "Split Test",
                "SPLT",
                "",
                "",
                q,
                address(0),
                IGangLaunchpad.TaxConfig({buyTaxBps: 200, sellTaxBps: 200, dividendBps: 5000, recipient: address(m)})
            );
            vm.stopBroadcast();
        }
        if (m.token() == address(0)) {
            vm.startBroadcast(deployerPk);
            m.bind(t);
            vm.stopBroadcast();
        }
        if (m.token() != t || m.quote() != q) revert Check("bound");
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

    /// @dev Deployer: a pool buy (tax accrues) and a sell of half its tokens (the swap-back pays the module).
    function _poolRound(address t) internal {
        if (vm.envOr("SKIP_POOL", false)) return;
        address pair = _pair(t);
        vm.startBroadcast(deployerPk);
        _faucet(deployer, 1 ether);
        _swap(q, t, 0.5 ether);
        _swap(t, q, IERC20(t).balanceOf(deployer) / 2);
        vm.stopBroadcast();
        console.log("pair", pair);
    }

    /// @dev The keeper step: `work(0)` splits what arrived, to the wei.
    function _keeperSplit(GangSplitModule m) internal {
        uint256 pending = m.undistributed(q);
        (bool due,) = m.previewWork();
        console.log("pending", pending, "due", due);
        if (pending == 0) revert Check("tax reached the module");
        (address[] memory p, uint16[] memory s) = m.payeesOf();
        uint256[] memory before = new uint256[](p.length);
        for (uint256 i; i < p.length; i++) {
            before[i] = IERC20(q).balanceOf(p[i]);
        }
        vm.startBroadcast(deployerPk);
        m.work(0);
        vm.stopBroadcast();
        _checkSplit(q, p, s, before, pending);
        if (m.undistributed(q) != 0 || m.owedTotal(q) != 0) revert Check("all paid");
    }

    /// @dev WBNB sent to the module splits at the same shares.
    function _otherAsset(GangSplitModule m, address b) internal {
        if (IERC20(T.WBNB).balanceOf(b) != 0) return;
        vm.startBroadcast(deployerPk);
        IWBNBLite(T.WBNB).deposit{value: 0.001 ether}();
        IERC20(T.WBNB).transfer(address(m), 0.001 ether);
        vm.stopBroadcast();
        (address[] memory p, uint16[] memory s) = m.payeesOf();
        uint256[] memory before = new uint256[](p.length);
        for (uint256 i; i < p.length; i++) {
            before[i] = IERC20(T.WBNB).balanceOf(p[i]);
        }
        vm.startBroadcast(deployerPk);
        m.distribute(T.WBNB);
        vm.stopBroadcast();
        _checkSplit(T.WBNB, p, s, before, 0.001 ether);
    }

    /// @dev C moves its slot to C2; the next split pays C2.
    function _move(GangSplitModule m, uint256 cPk, address c2) internal {
        (address[] memory p,) = m.payeesOf();
        if (p[2] != c2) {
            _prefund(vm.addr(cPk), 300_000 * _gasPrice());
            vm.startBroadcast(cPk);
            m.setPayee(2, c2);
            vm.stopBroadcast();
        }
        (p,) = m.payeesOf();
        if (p[2] != c2) revert Check("moved");
        uint256 c20 = IERC20(q).balanceOf(c2);
        vm.startBroadcast(deployerPk);
        _faucet(deployer, 1 ether);
        IERC20(q).transfer(address(m), 1 ether);
        m.distribute(q);
        vm.stopBroadcast();
        if (IERC20(q).balanceOf(c2) - c20 != 0.1 ether) revert Check("paid at the new address");
    }

    /// @notice Return each wallet's leftover gas money to the deployer.
    function sweep() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPk);
        uint256 fee = 21_000 * _gasPrice();
        uint256 total;
        for (uint256 i = 0; i <= MINTERS; i++) {
            uint256 pk = i == MINTERS ? _key("c", 0) : _key(MINTER_LABEL, i);
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
    /// @dev The module's rule: every payee but the first gets its share rounded down, the first the rest.
    function _checkSplit(
        address asset,
        address[] memory p,
        uint16[] memory s,
        uint256[] memory before,
        uint256 incoming
    ) internal view {
        uint256 left = incoming;
        for (uint256 i = 1; i < p.length; i++) {
            uint256 part = (incoming * s[i]) / 10_000;
            left -= part;
            if (IERC20(asset).balanceOf(p[i]) - before[i] != part) revert Check("payee part");
            console.log("payee", i, part);
        }
        if (IERC20(asset).balanceOf(p[0]) - before[0] != left) revert Check("first payee part");
        console.log("payee", uint256(0), left);
    }

    function _register(uint256 pk) internal {
        ITestnetAgentIdLite agentId = ITestnetAgentIdLite(pad.agentIdRegistry());
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
