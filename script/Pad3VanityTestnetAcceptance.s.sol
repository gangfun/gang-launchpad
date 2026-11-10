// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {Pad3FlyModule} from "../src/gang/Pad3FlyModule.sol";
import {Pad3VanityDeployer} from "../src/gang/Pad3VanityDeployer.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangTokenDeployer} from "../src/gang/interfaces/IGangPadDeps.sol";
import {IFlywheelPad} from "../src/flywheel/interfaces/IFlywheelPad.sol";
import {Pad3VanitySalt} from "./Pad3VanitySalt.sol";

interface IVanityWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

contract Pad3VanityAcceptanceVault {}

/// @notice Testnet acceptance after abcd activation: seven create entries, prediction, native buys and sells,
///         plus a pre-existing WBNB curve. The caller needs an Agent ID and funds for gas and the small trades.
/// @dev Env: DEPLOYER_PRIVATE_KEY, GANG_PAD3; optional ABCD_ACCEPTANCE_VAULT (already listed and granted to the caller),
///      ABCD_LEGACY_TOKEN (otherwise selects a live legacy WBNB curve from the newest 200 tokens).
///      A missing vault is created/listed temporarily by the pad owner. No owner change is made.
contract Pad3VanityTestnetAcceptance is Script {
    GangLaunchpad3 internal p;
    Pad3Module internal pm;
    Pad3VanityDeployer internal factory;
    uint256 internal pk;
    address internal me;

    error Check(string what);

    function run() external {
        if (block.chainid != 97) revert Check("testnet only");
        _accept(
            vm.envAddress("GANG_PAD3"),
            vm.envUint("DEPLOYER_PRIVATE_KEY"),
            vm.envOr("ABCD_ACCEPTANCE_VAULT", address(0)),
            vm.envOr("ABCD_LEGACY_TOKEN", address(0))
        );
    }

    function _accept(address pad, uint256 key, address vault, address legacy)
        internal
        returns (address[] memory tokens)
    {
        p = GangLaunchpad3(payable(pad));
        pm = Pad3Module(payable(pad));
        pk = key;
        me = vm.addr(key);
        factory = Pad3VanityDeployer(pm.vanityDeployer());
        if (address(factory) == address(0) || factory.pad() != pad) revert Check("abcd is not enabled");
        if (!p.isAgent(me)) revert Check("caller needs an Agent ID");
        if (legacy == address(0)) legacy = _legacyCurve();
        if (!_isLegacyCurve(legacy)) revert Check("need an active legacy WBNB curve");
        bool demoVault = vault == address(0);
        if (demoVault && p.owner() != me) revert Check("provide a listed vault granted to the caller");
        if (!demoVault && (!pm.isVault(vault) || pm.vaultCreator(vault) != me)) revert Check("vault grant");

        uint256 wrappedBefore = IERC20(p.wbnb()).balanceOf(me);
        vm.startBroadcast(pk);
        IVanityWrappedNative(p.wbnb()).deposit{value: 0.01 ether}();
        IERC20(p.wbnb()).approve(pad, 0.01 ether);
        if (demoVault) {
            vault = address(new Pad3VanityAcceptanceVault());
            pm.setVault(vault, true);
            pm.setVaultCreator(vault, me);
        }
        vm.stopBroadcast();

        tokens = new address[](7);
        tokens[0] = _curve("ABCD curve", "ABC", false, 0);
        tokens[1] = _curve("ABCD tax", "ABT", true, 0);
        tokens[2] = _curve("ABCD target", "ABG", false, 6 ether);
        tokens[3] = _fair();
        tokens[4] = _fly();
        IGangLaunchpad.TaxConfig memory untaxed;
        bytes32 hash = factory.tokenInitCodeHash("ABCD vault", "ABV", "", address(0), 0, 0, false);
        tokens[5] = _launch(
            hash,
            abi.encodeCall(
                Pad3Module.createWithVault,
                ("ABCD vault", "ABV", "", "", address(0), address(0), untaxed, 9 ether, vault)
            ),
            1
        );
        if (pm.vaultOf(tokens[5]) != vault) revert Check("vault binding");
        hash = factory.tokenInitCodeHash("ABCD promote", "ABP", "", address(0), 0, 0, false);
        tokens[6] = _launch(
            hash,
            abi.encodeCall(
                Pad3Module.createWithPromote,
                ("ABCD promote", "ABP", "", "", address(0), address(0), untaxed, 9 ether, 1000, uint32(7 days))
            ),
            1
        );
        (uint16 share, uint32 window) = pm.promoteOf(tokens[6]);
        if (share != 1000 || window != 7 days) revert Check("promoter terms");

        for (uint256 i; i < tokens.length; i++) {
            _roundTrip(tokens[i]);
        }
        _roundTrip(legacy);
        vm.startBroadcast(pk);
        IERC20(p.wbnb()).approve(pad, 0);
        if (demoVault) pm.setVault(vault, false);
        uint256 wrappedAfter = IERC20(p.wbnb()).balanceOf(me);
        if (wrappedAfter > wrappedBefore) IVanityWrappedNative(p.wbnb()).withdraw(wrappedAfter - wrappedBefore);
        vm.stopBroadcast();
        console.log("abcd acceptance ok; new tokens", tokens.length);
    }

    function _curve(string memory name, string memory symbol, bool taxed, uint256 target) private returns (address) {
        IGangLaunchpad.TaxConfig memory tax;
        if (taxed) tax = IGangLaunchpad.TaxConfig(100, 200, 0, me);
        bytes memory data = target == 0
            ? abi.encodeWithSignature(
                "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))",
                name,
                symbol,
                "",
                "",
                address(0),
                address(0),
                tax
            )
            : abi.encodeCall(
                GangLaunchpad3.createWithGradTarget, (name, symbol, "", "", address(0), address(0), tax, target)
            );
        return _launch(
            factory.tokenInitCodeHash(
                name, symbol, "", taxed ? p.taxHandler() : address(0), tax.buyTaxBps, tax.sellTaxBps, false
            ),
            data,
            1
        );
    }

    function _fair() private returns (address) {
        IGangLaunchpad.MintConfig memory cfg = IGangLaunchpad.MintConfig(5 ether, 50, 6000, 100, 100);
        bytes memory data = abi.encodeWithSignature(
            "create(string,string,string,string,address,address,(uint256,uint16,uint16,uint16,uint16),uint256)",
            "ABCD fair",
            "ABF",
            "",
            "",
            address(0),
            address(0),
            cfg,
            uint256(1)
        );
        return _launch(factory.tokenInitCodeHash("ABCD fair", "ABF", "", p.taxHandler(), 100, 100, true), data, 2);
    }

    function _fly() private returns (address) {
        IFlywheelPad.FlyConfig memory cfg;
        cfg.raiseBnb = 3 ether;
        cfg.baseQuota = 10;
        cfg.inviteBonus = 1;
        cfg.maxPerTx = 10;
        cfg.holdBps = 6000;
        cfg.mintFeeBps = 100;
        cfg.exitFeeBps = 100;
        cfg.devCutBps = 1000;
        cfg.buyBps = 3000;
        cfg.sellTaxBps = 200;
        cfg.launchDelay = 60;
        cfg.window = 600;
        cfg.windowCapMul = 1;
        cfg.postMint = true;
        cfg.tierMode = 1;
        cfg.supplyCapMul = 100;
        cfg.twapWindow = 1800;
        string[4] memory text = ["ABCD fly", "ABM", "", ""];
        address handler = Pad3FlyModule(address(p)).flyTaxHandler();
        return _launch(
            factory.mintInitCodeHash(text[0], text[1], text[3], handler, 100, 200, 0, 200_000_000_000 ether),
            abi.encodeCall(Pad3FlyModule.create, (text, address(0), address(0), cfg, uint256(1))),
            3
        );
    }

    function _launch(bytes32 hash, bytes memory data, uint8 kind) private returns (address token) {
        vm.pauseGasMetering();
        (bytes32 salt, address expected) = Pad3VanitySalt.find(address(factory), me, hash);
        vm.resumeGasMetering();
        vm.startBroadcast(pk);
        token = pm.createWithSalt(salt, data);
        vm.stopBroadcast();
        if (token != expected || uint16(uint160(token)) != 0xabcd || p.kindOf(token) != kind) {
            revert Check("address or kind");
        }
        if (!factory.isLaunchToken(token)) revert Check("token filter");
        console.log("abcd token", token);
    }

    function _roundTrip(address token) internal {
        (,, uint256 amount, uint256 cost,, uint256 value,,) = p.tryBuy(token, me, 0, 0.002 ether);
        if (amount == 0 || value != cost) revert Check("buy quote");
        uint256 beforeTokens = IERC20(token).balanceOf(me);
        vm.startBroadcast(pk);
        (uint256 bought, uint256 spent) = p.buyTokenAMAP{value: value}(token, me, value, amount);
        vm.stopBroadcast();
        if (bought != amount || spent != cost || IERC20(token).balanceOf(me) != beforeTokens + amount) {
            revert Check("buy fill");
        }
        uint256 unit = p.kindOf(token) == 1 ? 1 : pm.shareSizeOf(token);
        uint256 sell = (amount / unit / 2) * unit;
        (,, uint256 funds,) = p.trySell(token, sell);
        if (sell == 0 || funds == 0) revert Check("sell quote");
        vm.startBroadcast(pk);
        IERC20(token).approve(address(p), sell);
        uint256 paid = p.sellToken(0, token, me, sell, funds, 0, address(0));
        vm.stopBroadcast();
        if (paid != funds || IERC20(token).allowance(me, address(p)) != 0) revert Check("sell fill");
    }

    function _isLegacyCurve(address token) private view returns (bool) {
        if (token == address(0) || p.kindOf(token) != 1) return false;
        (, address quote,,,,, bool graduated,,,,,) = p.curves(token);
        return !graduated && quote == p.wbnb() && IGangTokenDeployer(factory.legacyTokenDeployer()).isLaunchToken(token);
    }

    function _legacyCurve() private view returns (address) {
        uint256 n = p.tokenCount();
        uint256 stop = n > 200 ? n - 200 : 0;
        while (n > stop) {
            address token = p.allTokens(--n);
            if (_isLegacyCurve(token)) return token;
        }
        return address(0);
    }
}
