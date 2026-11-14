// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../src/gang/Pad3VanityDeployer.sol";
import {GangBaseVault} from "../src/gang/GangBaseVault.sol";
import {GangToken} from "../src/gang/GangToken.sol";
import {IGangBasePad} from "../src/gang/interfaces/IGangBasePad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {Pad3VanitySalt} from "./Pad3VanitySalt.sol";

interface IWBNBLite {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
}

/// @notice BSC testnet acceptance of the opening base (docs/SPEC-BASE-VAULT-V2-2026-11-12.md), up to graduation: the
///         deployer (an Agent) creates a 5% / 30-day base token through createWithSalt (abcd is on there), the records,
///         the vault and the money are read back, the vault cannot start before graduation, and the deployer's own
///         wallet still buys and sells on the curve. Graduation and release need 6 tBNB of buys and are covered by
///         test/fork/Pad3BaseUpgradeFork.t.sol on mainnet state.
/// @dev Env: DEPLOYER_PRIVATE_KEY, GANG_PAD3. Not idempotent: each run mines a fresh salt and creates (and pays for)
///      another base token.
contract BaseTestnetAcceptance is Script {
    string internal constant NAME = "Base Test";
    string internal constant SYMBOL = "BASET";
    uint256 internal constant GRAD = 6 ether;
    uint16 internal constant BPS = 500;
    uint32 internal constant DAYS = 30;

    error Check(string what);

    function run() external {
        require(block.chainid == 97, "testnet only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address dev = vm.addr(pk);
        GangLaunchpad3 p = GangLaunchpad3(payable(vm.envAddress("GANG_PAD3")));
        Pad3Module m = Pad3Module(payable(address(p)));
        address factory = m.vanityDeployer();
        if (factory == address(0)) revert Check("abcd not on");
        if (m.baseVaultImpl() == address(0)) revert Check("base vault implementation not set");

        bytes32 hash = Pad3VanityDeployer(factory).tokenInitCodeHash(NAME, SYMBOL, "", address(0), 0, 0, false);
        (bytes32 salt, address expected) = Pad3VanitySalt.find(factory, dev, hash);
        uint256 cost = m.previewBaseCost(GRAD, BPS);
        console.log("cost (wei)", cost);
        console.log("expected token", expected);

        uint256 padWbnb = IERC20(p.wbnb()).balanceOf(address(p));
        uint256 padBnb = address(p).balance;
        IGangLaunchpad.TaxConfig memory none;
        bytes memory data = abi.encodeCall(
            Pad3Module.createWithBase, (NAME, SYMBOL, "", "", none, GRAD, IGangBasePad.BaseConfig(BPS, DAYS))
        );
        vm.startBroadcast(pk);
        address t = m.createWithSalt{value: cost}(salt, data);
        vm.stopBroadcast();
        if (t != expected) revert Check("token address");
        console.log("token", t);
        _readBack(p, m, t, dev, cost, padWbnb);
        if (address(p).balance != padBnb) revert Check("BNB left on the pad");
        // the vault can't start before graduation (simulated, never broadcast)
        GangBaseVault v = GangBaseVault(m.baseVaultOf(t));
        try v.release() {
            revert Check("release before graduation");
        } catch (bytes memory r) {
            if (bytes4(r) != GangBaseVault.NotGraduated.selector) revert Check("release: wrong revert");
        }

        // the creator's own wallet trades the curve as anyone's (a small buy, then sell it back)
        IWBNBLite w = IWBNBLite(p.wbnb());
        vm.startBroadcast(pk);
        w.deposit{value: 0.002 ether}();
        w.approve(address(p), 0.002 ether);
        p.buy(t, 0.002 ether, 0);
        uint256 got = IERC20(t).balanceOf(dev);
        IERC20(t).approve(address(p), got);
        p.sell(t, got, 0);
        uint256 left = w.balanceOf(dev);
        if (left != 0) w.withdraw(left);
        vm.stopBroadcast();
        if (IERC20(t).balanceOf(dev) != 0) revert Check("round trip");
        if (IERC20(t).balanceOf(m.baseVaultOf(t)) != m.baseOf(t)) revert Check("V5 after trades");
        console.log("ok: created, read back, vault locked, creator round trip");
    }

    function _readBack(GangLaunchpad3 p, Pad3Module m, address t, address dev, uint256 cost, uint256 padWbnb)
        internal
        view
    {
        uint256 base = (1_000_000_000 ether * uint256(BPS)) / 10_000;
        GangBaseVault v = GangBaseVault(m.baseVaultOf(t));
        if (address(v) == address(0) || m.baseOf(t) != base) revert Check("records");
        if (IERC20(t).balanceOf(address(v)) != base) revert Check("vault balance");
        if (v.token() != t || v.creator() != dev || v.duration() != uint64(DAYS) * 1 days || v.startAt() != 0) {
            revert Check("vault init");
        }
        if (v.pad() != address(p) || v.moduleType() != "base-v1") revert Check("vault identity");
        (,, uint256 rq, uint256 sold,,,,,,,,) = p.curves(t);
        uint256 fee = cost / 100;
        if (sold != base || rq != cost - fee) revert Check("curve");
        if (p.creatorFeeOf(t) != (fee * 7_000) / 10_000) revert Check("creator fee");
        if (IERC20(p.wbnb()).balanceOf(address(p)) - padWbnb != rq + p.creatorFeeOf(t)) revert Check("pad WBNB");
        if (!GangToken(t).locked()) revert Check("locked");
    }
}
