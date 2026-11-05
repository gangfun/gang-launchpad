// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3FlyModule} from "../../src/gang/Pad3FlyModule.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";

interface IDeployerList {
    function setLaunchpad(address launchpad, bool enabled) external;
}

interface IFairCreate2 {
    function create(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        IGangLaunchpad.MintConfig calldata cfg,
        uint256 devShares
    ) external returns (address token);
}

interface IFlySales2 {
    function tokenCount() external view returns (uint256);
    function allTokens(uint256 i) external view returns (address);
    function sales(address token) external view returns (IFlywheelPad.Sale memory);
}

/// @notice The cut-over (Safe batch 5) rehearsed on the upgraded mainnet: 1.0, 2.0, the vault pad and 铸币飞轮 V2 stop
///         creating, and afterwards every kind still creates on 3.0, and the older pads' tokens still trade. Agent IDs
///         are mocked. No broadcast.
/// @dev Needs BSC_RPC_URL (skipped without it) with enough old state for a run of about two minutes (spec §6).
contract Pad3CutoverForkTest is Test {
    address constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address constant PAD_1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant PAD_2 = 0x770331a9accdb53ACb4a45B6c5B7D151fADCe557;
    address constant VAULT_PAD = 0xE90851A90C6278E3d6e4C24320101f8B13D90A11;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    GangLaunchpad3 p = GangLaunchpad3(payable(PAD3));
    uint256 _n;

    function _agent() internal returns (address w) {
        w = makeAddr(string.concat("cut-", vm.toString(_n++)));
        vm.deal(w, 10 ether);
        deal(M.WBNB, w, 10 ether);
    }

    function _flyCfg() internal pure returns (IFlywheelPad.FlyConfig memory) {
        return IFlywheelPad.FlyConfig({
            raiseBnb: 3 ether,
            baseQuota: 100,
            inviteBonus: 1,
            maxPerTx: 10,
            holdBps: 6_000,
            mintFeeBps: 100,
            exitFeeBps: 100,
            devCutBps: 1_000,
            buyBps: 3_000,
            sellTaxBps: 200,
            launchDelay: 60,
            window: 600,
            windowCapMul: 1,
            postMint: false,
            tierMode: 1,
            stepBps: 0,
            stepShares: 0,
            maxMulX100: 0,
            supplyCapMul: 100,
            guardBps: 0,
            twapWindow: 1800
        });
    }

    function _createCurve(address pad) internal returns (bool ok, address t) {
        address c = _agent();
        IGangLaunchpad.TaxConfig memory untaxed;
        vm.prank(c, c);
        try GangLaunchpad(payable(pad)).create("Cut", "CUT", "logo", "meta", M.WBNB, address(0), untaxed) returns (
            address a
        ) {
            return (true, a);
        } catch {
            return (false, address(0));
        }
    }

    function _createFair(address pad) internal returns (bool ok, address t) {
        address c = _agent();
        vm.prank(c);
        IERC20(M.WBNB).approve(pad, type(uint256).max);
        IGangLaunchpad.MintConfig memory cfg = IGangLaunchpad.MintConfig({
            raiseBnb: 10 ether, capBps: 50, holdBps: 6_000, mintFeeBps: 100, exitFeeBps: 100
        });
        vm.prank(c, c);
        try IFairCreate2(pad).create("Cut", "CUTF", "", "", address(0), address(0), cfg, 1) returns (address a) {
            return (true, a);
        } catch {
            return (false, address(0));
        }
    }

    function _createFly(address pad) internal returns (bool ok, address t) {
        address c = _agent();
        vm.prank(c);
        IERC20(M.WBNB).approve(pad, type(uint256).max);
        string[4] memory text = ["Cut fly", "CUTY", "", ""];
        vm.prank(c, c);
        try Pad3FlyModule(pad).create(text, address(0), address(0), _flyCfg(), 1) returns (address a) {
            return (true, a);
        } catch {
            return (false, address(0));
        }
    }

    function _trade(address t, uint256 funds, uint256 unit, string memory what) internal {
        address w = _agent();
        (,, uint256 amount,,,,,) = p.tryBuy(t, w, 0, funds);
        assertGt(amount, 0, string.concat(what, ": quoted"));
        vm.prank(w, w);
        (uint256 out,) = p.buyTokenAMAP{value: funds}(t, w, funds, amount);
        assertEq(out, amount, string.concat(what, ": bought"));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 back = unit == 0 ? out / 2 : unit;
        vm.prank(w);
        IERC20(t).approve(PAD3, back);
        (,, uint256 f,) = p.trySell(t, back);
        assertGt(f, 0, string.concat(what, ": sell quoted"));
        vm.prank(w, w);
        assertEq(p.sellToken(0, t, w, back, f, 0, address(0)), f, string.concat(what, ": sold"));
    }

    function _liveCurve(address pad) internal view returns (address) {
        GangLaunchpad g = GangLaunchpad(payable(pad));
        for (uint256 i = g.tokenCount(); i > 0; i--) {
            address c = g.allTokens(i - 1);
            if (g.kindOf(c) != 1) continue;
            (uint8 st, address q,,,) = p.getTokenInfo(c);
            if (st == 1 && q == address(0)) return c;
        }
        return address(0);
    }

    function _liveFly(address pad) internal view returns (address) {
        IFlySales2 f = IFlySales2(pad);
        for (uint256 i = f.tokenCount(); i > 0; i--) {
            address c = f.allTokens(i - 1);
            IFlywheelPad.Sale memory s = f.sales(c);
            if (s.gate != address(0) && s.quote == M.WBNB && !s.launched && s.filledAt == 0 && s.sold < 9_000) {
                return c;
            }
        }
        return address(0);
    }

    function test_fork_cutover() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        // PAD3_FORK_THIS_BUILD: this build's implementation, as the Safe would upgrade to it. Otherwise: the live one.
        if (vm.envOr("PAD3_FORK_THIS_BUILD", false)) {
            Pad3Impl.Deps memory d = Pad3Impl.depsOf(p);
            (, Pad3Impl.FlyDeps memory fd) = Pad3Impl.flyDepsOf(p);
            address impl = Pad3Impl.implWith(d, Pad3Impl.module(d, fd));
            vm.prank(SAFE);
            ProxyAdmin(R.adminOf(PAD3)).upgradeAndCall(ITransparentUpgradeableProxy(PAD3), impl, "");
            assertEq(R.implementationOf(PAD3), impl);
        }
        console.log("3.0 implementation under test", R.implementationOf(PAD3));

        address curve1 = _liveCurve(PAD_1);
        address curve2 = _liveCurve(PAD_2);
        address flyV1 = _liveFly(M.FLYWHEEL_PAD_V1);
        address flyV2 = _liveFly(M.FLYWHEEL_PAD_V2);
        (bool flyBefore,) = _createFly(M.FLYWHEEL_PAD_V2);
        assertTrue(flyBefore, "V2 creates before the cut-over");

        address td = p.tokenDeployer();
        vm.startPrank(SAFE);
        IDeployerList(td).setLaunchpad(PAD_1, false);
        IDeployerList(td).setLaunchpad(PAD_2, false);
        IDeployerList(td).setLaunchpad(VAULT_PAD, false);
        IDeployerList(M.FLYWHEEL_TOKEN_DEPLOYER).setLaunchpad(M.FLYWHEEL_PAD_V2, false);
        vm.stopPrank();

        // the older pads no longer create
        (bool ok,) = _createCurve(PAD_1);
        assertFalse(ok, "1.0 curve");
        (ok,) = _createCurve(PAD_2);
        assertFalse(ok, "2.0 curve");
        (ok,) = _createFair(PAD_1);
        assertFalse(ok, "1.0 fair");
        (ok,) = _createFair(PAD_2);
        assertFalse(ok, "2.0 fair");
        (ok,) = _createFly(M.FLYWHEEL_PAD_V2);
        assertFalse(ok, "fly V2");

        // 3.0 creates every kind, and each trades
        address t;
        (ok, t) = _createCurve(PAD3);
        assertTrue(ok, "3.0 curve");
        _trade(t, 0.001 ether, 0, "3.0 curve");
        (ok, t) = _createFair(PAD3);
        assertTrue(ok, "3.0 fair");
        _trade(t, 0.01 ether, 50_000 ether, "3.0 fair");
        (ok, t) = _createFly(PAD3);
        assertTrue(ok, "3.0 fly");
        _trade(t, 0.05 ether, 100_000 ether, "3.0 fly");

        // the older pads' tokens still trade through 3.0
        if (curve1 != address(0)) _trade(curve1, 0.001 ether, 0, "1.0 curve");
        if (curve2 != address(0)) _trade(curve2, 0.001 ether, 0, "2.0 curve");
        if (flyV1 != address(0)) _trade(flyV1, 0.05 ether, 100_000 ether, "fly V1");
        if (flyV2 != address(0)) _trade(flyV2, 0.05 ether, 100_000 ether, "fly V2");
    }
}
