// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {GangBaseVault} from "../../src/gang/GangBaseVault.sol";
import {IGangBasePad} from "../../src/gang/interfaces/IGangBasePad.sol";
import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {DeployGang} from "../../script/DeployGang.s.sol";
import {SetGangBaseVaultImpl} from "../../script/SetGangBaseVaultImpl.s.sol";

contract BaseUpgradeHarness is UpgradeGangLaunchpad3 {
    function check(address proxy, address impl, address upgrader) external {
        _baseImpl = impl;
        _checkBaseImpl(proxy, upgrader);
    }

    function batch(address proxy, address impl, address admin) external returns (string memory) {
        _baseImpl = impl;
        return _batchJson(false, address(1), new address[](0), new bytes[](0), admin, hex"12345678", proxy);
    }

    function settingsPart(address proxy) external view returns (address) {
        return _baseState(GangLaunchpad3(payable(proxy)));
    }

    function tokenPart(address proxy, address t) external view returns (bytes memory) {
        return _baseState(GangLaunchpad3(payable(proxy)), t);
    }

    function probes(address proxy, address[] memory list) external view returns (bytes memory) {
        return _baseProbes(GangLaunchpad3(payable(proxy)), list);
    }
}

/// @notice The opening base across an upgrade, and UpgradeGangLaunchpad3's PAD3_BASE_VAULT_IMPL / PAD3_BASE_PROBES.
contract Pad3BaseUpgradeTest is GangFixture {
    Pad3Module internal m;
    GangLaunchpad3 internal p;
    GangBaseVault internal impl;
    address internal creator;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(makeAddr("keeper"));
        m = Pad3Module(payable(address(pad)));
        p = GangLaunchpad3(payable(address(pad)));
        impl = new GangBaseVault(address(pad));
        creator = _newAgent();
        // the pad owner is the ProxyAdmin owner, as on mainnet (the Safe)
        vm.prank(owner);
        p.transferOwnership(upgrader);
        vm.prank(upgrader);
        p.acceptOwnership();
    }

    function _createBase() internal returns (address t) {
        uint256 cost = m.previewBaseCost(9 ether, 500);
        IGangBasePad.BaseConfig memory cfg = IGangBasePad.BaseConfig({baseBps: 500, vestDays: 30});
        vm.prank(creator);
        t = m.createWithBase{value: cost}("Base", "BASE", "logo", "meta", _tax(0, 0, 0, address(0)), 9 ether, cfg);
    }

    function test_upgradeKeepsBaseState() public {
        vm.prank(upgrader);
        m.setBaseVaultImpl(address(impl));
        address t = _createBase();
        address v = m.baseVaultOf(t);
        uint256 base = m.baseOf(t);
        address next = Pad3Impl.deploy(
            Pad3Impl.depsOf(p), Pad3Impl.FlyDeps(address(flyHandler), address(flyDeployer), address(flyCore))
        );
        vm.prank(upgrader);
        ProxyAdmin(R.adminOf(address(pad))).upgradeAndCall(ITransparentUpgradeableProxy(address(pad)), next, "");
        assertEq(m.baseVaultImpl(), address(impl));
        assertEq(m.baseVaultOf(t), v);
        assertEq(m.baseOf(t), base);
        _graduate(t);
        GangBaseVault(v).release();
        vm.warp(GangBaseVault(v).startAt() + 30 days);
        GangBaseVault(v).release();
        assertEq(IERC20(t).balanceOf(creator), base);
    }

    function test_scriptChecksImpl_andAppendsTheCall() public {
        BaseUpgradeHarness h = new BaseUpgradeHarness();
        h.check(address(pad), address(impl), upgrader);
        // another pad's vault, a contract that is no vault, the wrong owner
        GangBaseVault other = new GangBaseVault(makeAddr("other pad"));
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "base vault implementation code"));
        h.check(address(pad), address(other), upgrader);
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "base vault implementation code"));
        h.check(address(pad), address(wbnb), upgrader);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGang.WiringCheck.selector, "base vault: pad owner must own the upgrade batch")
        );
        h.check(address(pad), address(impl), owner);
        // already set: refused
        vm.prank(upgrader);
        m.setBaseVaultImpl(address(impl));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGang.WiringCheck.selector, "base vault implementation already set: omit PAD3_BASE_VAULT_IMPL"
            )
        );
        h.check(address(pad), address(impl), upgrader);

        address admin = R.adminOf(address(pad));
        string memory batch = h.batch(address(pad), address(impl), admin);
        assertEq(vm.parseJsonAddress(batch, ".transactions[0].to"), admin);
        assertEq(vm.parseJsonAddress(batch, ".transactions[1].to"), address(pad));
        assertEq(
            vm.parseJsonBytes(batch, ".transactions[1].data"),
            abi.encodeCall(Pad3Module.setBaseVaultImpl, (address(impl)))
        );
        string memory plain = h.batch(address(pad), address(0), admin);
        assertFalse(vm.keyExistsJson(plain, ".transactions[1]"));
    }

    function test_scriptSnapshotParts() public {
        BaseUpgradeHarness h = new BaseUpgradeHarness();
        assertEq(h.settingsPart(address(pad)), address(0));
        address plain = _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        assertEq(h.tokenPart(address(pad), plain).length, 0, "no base: empty, as before the upgrade");
        vm.prank(upgrader);
        m.setBaseVaultImpl(address(impl));
        assertEq(h.settingsPart(address(pad)), address(impl));
        address t = _createBase();
        assertGt(h.tokenPart(address(pad), t).length, 0);
        address[] memory list = new address[](1);
        list[0] = t;
        assertGt(h.probes(address(pad), list).length, 0);
        list[0] = plain;
        vm.expectRevert(
            abi.encodeWithSelector(DeployGang.WiringCheck.selector, "PAD3_BASE_PROBES: a token without an opening base")
        );
        h.probes(address(pad), list);
    }

    /// @dev The second owner batch (spec §8): checks, simulates, sends nothing unless the deploy wallet owns the pad.
    function test_setScript_checksAndOnlyPrints() public {
        vm.chainId(97);
        SetGangBaseVaultImpl s = new SetGangBaseVaultImpl();
        s.run(address(pad), address(impl), 0, false);
        assertEq(m.baseVaultImpl(), address(0), "printed, not sent");

        address other = address(new GangBaseVault(makeAddr("other pad")));
        vm.expectRevert(abi.encodeWithSelector(SetGangBaseVaultImpl.Check.selector, "vault implementation code"));
        s.run(address(pad), other, 0, false);

        vm.expectRevert(
            abi.encodeWithSelector(SetGangBaseVaultImpl.Check.selector, "pad not upgraded to the base build")
        );
        s.run(address(wbnb), address(impl), 0, false);

        vm.prank(upgrader);
        m.setBaseVaultImpl(address(impl));
        vm.expectRevert(
            abi.encodeWithSelector(SetGangBaseVaultImpl.Check.selector, "already set to PAD3_BASE_VAULT_IMPL")
        );
        s.run(address(pad), address(impl), 0, false);

        // replacing one already set needs PAD3_BASE_REPLACE
        GangBaseVault second = new GangBaseVault(address(pad));
        vm.expectRevert(
            abi.encodeWithSelector(
                SetGangBaseVaultImpl.Check.selector,
                "an implementation is already set: PAD3_BASE_REPLACE=true to replace it"
            )
        );
        s.run(address(pad), address(second), 0, false);
        s.run(address(pad), address(second), 0, true);
        assertEq(m.baseVaultImpl(), address(impl), "printed, not sent");

        vm.chainId(56);
        vm.expectRevert(
            abi.encodeWithSelector(SetGangBaseVaultImpl.Check.selector, "GANG_PAD3 is not the mainnet 3.0 proxy")
        );
        s.run(address(pad), address(impl), 0, false);

        vm.chainId(31337);
        vm.expectRevert(
            abi.encodeWithSelector(SetGangBaseVaultImpl.Check.selector, "chain: BSC mainnet or testnet only")
        );
        s.run(address(pad), address(impl), 0, false);
    }

    function test_setScript_testnetSendsWhenTheDeployWalletOwnsThePad() public {
        (address dep, uint256 key) = makeAddrAndKey("testnet deployer");
        vm.prank(upgrader);
        p.transferOwnership(dep);
        vm.prank(dep);
        p.acceptOwnership();
        vm.chainId(97);
        SetGangBaseVaultImpl s = new SetGangBaseVaultImpl();
        // another key: printed only
        (, uint256 otherKey) = makeAddrAndKey("someone else");
        s.run(address(pad), address(impl), otherKey, false);
        assertEq(m.baseVaultImpl(), address(0));
        s.run(address(pad), address(impl), key, false);
        assertEq(m.baseVaultImpl(), address(impl));
    }
}
