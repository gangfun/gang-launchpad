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
import {GangFloorModule} from "../src/gang/GangFloorModule.sol";
import {GangFloorModuleFactory} from "../src/gang/GangFloorModuleFactory.sol";
import {Pad3VanitySalt} from "./Pad3VanitySalt.sol";

interface IFloorAgentIdLite {
    function balanceOf(address) external view returns (uint256);
    function register() external returns (uint256);
}

/// @title FloorTestnetAcceptance — one on-chain round of GangFloorModule on BSC testnet
/// @notice `run`: the deployer computes the address its token will have (the pad's abcd deployer), clones a floor
///         module for it (cap CAP_AMOUNT of the test quote, default 0.001; 50% to the payees until then — itself 70%,
///         a throwaway payee B 30% —; the rest the treasury; a 2% redemption fee), creates the taxed V3 token at that
///         address paying the module, binds it, buys on the curve; throwaway Agents fill the curve (graduation); a
///         pool buy and sell pay the tax, the sell's swap-back pays the module; the deployer redeems a quarter of its
///         tokens before any split: the payout, the fee left in the treasury, what was set aside for the payees
///         (`payeesPending`, nobody pushed) and the tokens at 0xdead are checked to the wei.
///         Then `split()` is sent as the keeper does (`cast send`, the node's gas estimate: a script's own estimate
///         is under what a push needs — PushStarved, as the capped module's acceptance found), and
///         `--sig "finish()"` checks the payees got exactly the cap and redeems again: the floor did not fall.
///         `--sig "report()"` only reads.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, FLOOR_FACTORY; optional CAP_AMOUNT (wei of the test quote),
///      SKIP_POOL, GAS_PRICE_WEI (default 0.1 gwei; pass the same as --with-gas-price). Broadcast with --slow.
///      Afterwards `--sig "sweep()"` returns the minters' leftover gas money. The throwaway wallets derive from
///      DEPLOYER_PRIVATE_KEY with the capped module's acceptance labels: the same wallets, already registered Agents.
contract FloorTestnetAcceptance is Script {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant MINTERS = 120;
    uint256 internal constant MINTER_GAS = 600_000;
    uint256 internal constant NEAR_END_FACTOR = 10;
    /// @dev The capped module's acceptance wallets, reused: no new wallets.
    string internal constant MINTER_LABEL = "gang-capped-testnet";
    bytes32 internal constant SALT = keccak256("floor-acceptance-1");
    string internal constant NAME = "Floor Test";
    string internal constant SYMBOL = "FLRT";
    uint16 internal constant TAX_BPS = 300;
    uint16 internal constant DIVIDEND_BPS = 4_000;
    uint16 internal constant PAY_BPS = 5_000;
    uint16 internal constant FEE_BPS = 200;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    error WrongChain(uint256 chainId);
    error Check(string what);

    uint256 internal deployerPk;
    address internal deployer;
    IGangPad internal pad;
    address internal q;

    function run() external {
        _init();
        GangFloorModuleFactory factory = GangFloorModuleFactory(vm.envAddress("FLOOR_FACTORY"));
        pad = IGangPad(factory.pad());
        address b = vm.addr(_key("b", 0));
        (GangFloorModule s, bytes32 tokenSalt) = _module(factory, b);
        console.log("module", address(s));
        address t = _token(s, tokenSalt);
        console.log("token", t);
        _curveBuy(t);
        _graduate(t);
        _poolRound(t);
        _redeemBeforeSplit(s, b);
        console.log("next: cast send <module> 'split()', then --sig 'finish()'");
    }

    /// @notice After `split()` was sent: the payees got exactly what the cap allows; a second redemption matches its
    ///         preview and the floor does not fall.
    function finish() external {
        _init();
        GangFloorModule s = _existing();
        if (s.unsplit() != 0 || s.payeesPending() != 0) revert Check("split() first");
        if (!s.capReached() || s.paidTotal() != s.capAmount()) revert Check("cap reached");
        if (s.owedTotal(q) != 0) revert Check("nobody owed");
        if (IERC20(q).balanceOf(address(s)) != s.treasuryHeld()) revert Check("books = balance");
        uint256 price0 = s.floorPrice();
        uint256 held0 = s.treasuryHeld();
        uint256 supply0 = s.floorSupply();
        uint256 amount = IERC20(s.token()).balanceOf(deployer) / 2;
        (uint256 out, uint256 fee) = s.previewRedeem(amount);
        if (out == 0 || fee == 0) revert Check("preview");
        uint256 q0 = IERC20(q).balanceOf(deployer);
        vm.startBroadcast(deployerPk);
        uint256 got = s.redeem(amount, out, deployer);
        vm.stopBroadcast();
        if (got != out || IERC20(q).balanceOf(deployer) - q0 != out) revert Check("redeemed = preview");
        if (s.treasuryHeld() != held0 - out) revert Check("treasury");
        if (s.floorSupply() != supply0 - amount) revert Check("supply");
        if (s.floorPrice() <= price0) revert Check("the fee raised the floor");
        console.log("redeemed tokens / quote out / fee", amount, out, fee);
        console.log("floor price before / after (x1e18)", price0, s.floorPrice());
        console.log("floor acceptance ok");
    }

    /// @notice The module's state (read only).
    function report() external {
        _init();
        GangFloorModule s = _existing();
        console.log("module", address(s));
        console.log("token / floorToken", s.token(), s.floorToken());
        console.log("capAmount / paidTotal", s.capAmount(), s.paidTotal());
        console.log("capReached", s.capReached());
        console.log("treasuryHeld / treasury()", s.treasuryHeld(), s.treasury());
        console.log("payeesPending / unsplit", s.payeesPending(), s.unsplit());
        console.log("owedTotal", s.owedTotal(q));
        console.log("quote balance", IERC20(q).balanceOf(address(s)));
        console.log("floorSupply", s.floorSupply());
        console.log("floorPrice (x1e18)", s.floorPrice());
        console.log("tokens at 0xdead", IERC20(s.floorToken()).balanceOf(DEAD));
        console.log("payee B quote balance", IERC20(q).balanceOf(vm.addr(_key("b", 0))));
        (bool due,) = s.previewWork();
        console.log("previewWork due", due);
    }

    // ---------------------------------------------------------------- steps
    function _existing() internal returns (GangFloorModule s) {
        GangFloorModuleFactory factory = GangFloorModuleFactory(vm.envAddress("FLOOR_FACTORY"));
        pad = IGangPad(factory.pad());
        s = GangFloorModule(factory.predict(deployer, SALT));
        if (address(s).code.length == 0) revert Check("no module: run() first");
    }

    /// @dev The token's address first (it depends on the creator, the name, the symbol, the metadata URI, the handler
    ///      and the tax rates — not on the recipient), then the module cloned for it.
    function _module(GangFloorModuleFactory factory, address b)
        internal
        returns (GangFloorModule s, bytes32 tokenSalt)
    {
        Pad3VanityDeployer vd = Pad3VanityDeployer(Pad3Module(payable(address(pad))).vanityDeployer());
        bytes32 initHash = vd.tokenInitCodeHash(NAME, SYMBOL, "", pad.taxHandler(), TAX_BPS, TAX_BPS, false);
        address at = factory.predict(deployer, SALT);
        if (at.code.length != 0) {
            s = GangFloorModule(at);
            if (s.floorToken().code.length == 0) {
                address again;
                vm.pauseGasMetering();
                (tokenSalt, again) = Pad3VanitySalt.find(address(vd), deployer, initHash);
                vm.resumeGasMetering();
                if (again != s.floorToken()) revert Check("the token salt no longer leads to floorToken");
            }
            return (s, tokenSalt);
        }
        address predicted;
        vm.pauseGasMetering();
        (tokenSalt, predicted) = Pad3VanitySalt.find(address(vd), deployer, initHash);
        vm.resumeGasMetering();
        console.log("token address, before it exists", predicted);
        address[] memory p = new address[](2);
        (p[0], p[1]) = (deployer, b);
        uint16[] memory sh = new uint16[](2);
        (sh[0], sh[1]) = (7_000, 3_000);
        uint256 cap = vm.envOr("CAP_AMOUNT", uint256(0.001 ether));
        vm.startBroadcast(deployerPk);
        s = GangFloorModule(factory.create(predicted, q, cap, PAY_BPS, FEE_BPS, p, sh, SALT));
        vm.stopBroadcast();
        if (address(s) != at) revert Check("predicted module address");
        if (s.floorToken() != predicted || s.token() != address(0)) revert Check("token fixed, not bound");
        if (s.floorQuote() != q || s.capAmount() != cap || s.payBps() != PAY_BPS || s.redeemFeeBps() != FEE_BPS) {
            revert Check("initialized");
        }
        if (s.dev() != deployer || s.paidTotal() != 0) revert Check("initialized");
        if (!s.keeperServes(q)) revert Check("keeper serves the test quote");
    }

    function _token(GangFloorModule s, bytes32 tokenSalt) internal returns (address t) {
        t = s.floorToken();
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
                    buyTaxBps: TAX_BPS, sellTaxBps: TAX_BPS, dividendBps: DIVIDEND_BPS, recipient: address(s)
                })
            );
            vm.startBroadcast(deployerPk);
            address created = Pad3Module(payable(address(pad))).createWithSalt(tokenSalt, data);
            vm.stopBroadcast();
            if (created != t) revert Check("the token is not at the address the module was cloned for");
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

    /// @dev Deployer: a pool buy (tax accrues) and a sell of a third of its tokens (the swap-back pays the module).
    function _poolRound(address t) internal {
        if (vm.envOr("SKIP_POOL", false)) return;
        console.log("pair", _pair(t));
        vm.startBroadcast(deployerPk);
        _faucet(deployer, 1 ether);
        _swap(q, t, 0.5 ether);
        _swap(t, q, IERC20(t).balanceOf(deployer) / 3);
        vm.stopBroadcast();
    }

    /// @dev A redemption before any split: the split it starts with counts the payees' part against the cap and sets
    ///      it aside without pushing; the holder gets its share of the rest less the fee, to the wei.
    function _redeemBeforeSplit(GangFloorModule s, address b) internal {
        uint256 incoming = s.unsplit();
        console.log("unsplit", incoming);
        if (incoming == 0) {
            if (s.treasuryHeld() == 0) revert Check("tax reached the module");
            return; // a re-run after the first redemption
        }
        address t = s.token();
        uint256 paid0 = s.paidTotal();
        uint256 held0 = s.treasuryHeld();
        uint256 pend0 = s.payeesPending();
        uint256 toP = (incoming * PAY_BPS) / 10_000;
        if (toP > s.capAmount() - paid0) toP = s.capAmount() - paid0;
        uint256 treasury = held0 + incoming - toP;
        if (s.treasury() != treasury) revert Check("treasury() counts what a split would add");
        uint256 supply = IERC20(t).totalSupply() - IERC20(t).balanceOf(DEAD);
        if (s.floorSupply() != supply) revert Check("floorSupply");
        uint256 amount = IERC20(t).balanceOf(deployer) / 4;
        uint256 gross = (amount * treasury) / supply;
        uint256 fee = (gross * FEE_BPS) / 10_000;
        (uint256 pOut, uint256 pFee) = s.previewRedeem(amount);
        if (pOut != gross - fee || pFee != fee) revert Check("previewRedeem");
        uint256 b0 = IERC20(q).balanceOf(b);
        uint256 d0 = IERC20(q).balanceOf(deployer);
        uint256 dead0 = IERC20(t).balanceOf(DEAD);
        uint256 price0 = s.floorPrice();
        vm.startBroadcast(deployerPk);
        IERC20(t).approve(address(s), type(uint256).max);
        uint256 got = s.redeem(amount, pOut, deployer);
        vm.stopBroadcast();
        if (got != pOut) revert Check("redeemed = preview");
        if (IERC20(q).balanceOf(deployer) - d0 != pOut) revert Check("holder paid");
        if (IERC20(t).balanceOf(DEAD) - dead0 != amount) revert Check("tokens to 0xdead, untaxed");
        if (s.treasuryHeld() != treasury - pOut) revert Check("treasury after");
        if (s.paidTotal() - paid0 != toP) revert Check("counted against the cap");
        if (s.payeesPending() - pend0 != toP) revert Check("set aside for the payees");
        if (IERC20(q).balanceOf(b) != b0) revert Check("the redemption pushed nobody");
        if (s.owedTotal(q) != 0) revert Check("nobody owed");
        if (IERC20(q).balanceOf(address(s)) != s.treasuryHeld() + s.payeesPending()) revert Check("books = balance");
        if (s.floorPrice() <= price0) revert Check("the fee raised the floor");
        console.log("redeemed tokens / quote out / fee", amount, pOut, fee);
        console.log("set aside for the payees / treasury after", s.payeesPending(), s.treasuryHeld());
        console.log("paidTotal / capAmount", s.paidTotal(), s.capAmount());
        console.log("floor price before / after (x1e18)", price0, s.floorPrice());
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
        IFloorAgentIdLite agentId = IFloorAgentIdLite(pad.agentIdRegistry());
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
