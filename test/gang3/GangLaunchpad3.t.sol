// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {GangToken} from "../../src/gang/GangToken.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {GangLaunchpad3V2Mock} from "../mocks/GangLaunchpad3V2Mock.sol";
import {GangFixture} from "../utils/GangFixture.sol";

/// @notice What GangLaunchpad 3.0 adds to 2.0: the proxy set-up (implementation locked, one initialize), the
///         per-token rule version, and upgrades in place (only the ProxyAdmin's owner, state kept, tokens keep
///         trading on the same address). 2.0's behaviour on 3.0 is test/gang3/Pad3Parity.t.sol.
contract GangLaunchpad3Test is GangFixture {
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    GangLaunchpad3 internal pad3;
    address internal alice;
    address internal bob;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(address(this));
        pad3 = GangLaunchpad3(payable(address(pad)));
        alice = _newAgent();
        bob = _newAgent();
    }

    function _admin() internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(address(pad), ADMIN_SLOT)))));
    }

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(pad), IMPL_SLOT))));
    }

    function _deps() internal view returns (address, address, address, address, address, address, address) {
        return (
            address(quoteRegistry),
            address(divVault),
            address(bucket),
            address(handler),
            address(tokenDeployer),
            address(wbnb),
            address(padRegistry3)
        );
    }

    // ---------------------------------------------------------------- set-up
    function test_proxy_initializedOnce() public {
        assertEq(pad3.owner(), owner);
        assertEq(pad3.pairFactory(), address(pairFactory));
        assertEq(pad3.twapWindow(), 1800);
        assertTrue(pad3.agentGateEnabled());
        assertTrue(pad3.walletCapEnabled());
        assertEq(address(pad3.migrator()), address(migrator));
        assertEq(pad3.taxHandler(), address(handler));
        assertEq(pad3.wbnb(), address(wbnb));
        assertEq(_impl(), pad3Impl);
        assertEq(_admin().owner(), upgrader);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pad3.initialize(alice, address(pairFactory));
    }

    function test_impl_cannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        GangLaunchpad3(payable(pad3Impl)).initialize(alice, address(pairFactory));
        // the implementation's own owner is a dead address: its admin functions are unusable on it
        assertEq(GangLaunchpad3(payable(pad3Impl)).owner(), address(0xdEaD));
    }

    function test_constructor_and_initialize_refuseZero() public {
        (address q, address d, address b, address h, address t, address w, address r) = _deps();
        vm.expectRevert(IGangLaunchpad.ZeroAddress.selector);
        new GangLaunchpad3(q, d, b, h, t, w, address(0), address(1));
        vm.expectRevert(IGangLaunchpad.ZeroAddress.selector);
        new GangLaunchpad3(q, d, b, h, t, w, r, address(0));
        GangLaunchpad3 impl = GangLaunchpad3(payable(Pad3Impl.deploy(q, d, b, h, t, w, r)));
        vm.expectRevert(IGangLaunchpad.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl), upgrader, abi.encodeCall(GangLaunchpad3.initialize, (address(0), address(pairFactory)))
        );
        vm.expectRevert(IGangLaunchpad.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl), upgrader, abi.encodeCall(GangLaunchpad3.initialize, (owner, address(0)))
        );
    }

    function test_owner_twoStepTransfer() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pad3.setRouter(alice, true);
        vm.prank(owner);
        pad3.transferOwnership(bob);
        assertEq(pad3.owner(), owner);
        vm.prank(bob);
        pad3.acceptOwnership();
        assertEq(pad3.owner(), bob);
    }

    // ---------------------------------------------------------------- token version
    function test_tokenVersion_bothKinds() public {
        assertEq(pad3.TOKEN_VERSION(), 1);
        vm.expectEmit(false, false, false, true, address(pad));
        emit IGangLaunchpad3.TokenVersionSet(address(0), 1);
        address v3 = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        assertEq(pad3.tokenVersionOf(v3), 1);

        IGangLaunchpad.MintConfig memory cfg = IGangLaunchpad.MintConfig({
            raiseBnb: 15 ether, capBps: 100, holdBps: 8000, mintFeeBps: 100, exitFeeBps: 100
        });
        vm.prank(bob);
        address fair = pad.create("Fair", "FAIR", "logo", "meta", address(wbnb), address(0), cfg, 1);
        assertEq(pad3.tokenVersionOf(fair), 1);
        assertEq(pad3.tokenVersionOf(alice), 0);
    }

    function test_tokens_pointAtTheProxy() public {
        address t = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        assertEq(GangToken(t).launchpad(), address(pad));
    }

    // ---------------------------------------------------------------- upgrades
    function _v2Impl() internal returns (GangLaunchpad3V2Mock) {
        (address q, address d, address b, address h, address t, address w, address r) = _deps();
        return new GangLaunchpad3V2Mock(q, d, b, h, t, w, r, Pad3Impl.module(Pad3Impl.Deps(q, d, b, h, t, w, r)));
    }

    function test_upgrade_onlyProxyAdminOwner() public {
        GangLaunchpad3V2Mock v2 = _v2Impl();
        ProxyAdmin admin = _admin();
        // the pad's owner is not the upgrader
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(pad)), address(v2), "");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(pad)), address(v2), "");
        // calling the proxy's upgrade entry directly as anyone else reaches the implementation, which has none
        vm.prank(upgrader);
        (bool ok,) =
            address(pad).call(abi.encodeCall(ITransparentUpgradeableProxy.upgradeToAndCall, (address(v2), bytes(""))));
        assertFalse(ok);
        assertEq(_impl(), pad3Impl);
    }

    function test_upgrade_keepsEveryTokenAndTrade() public {
        // state before: a curve token with trades and creator fee kept, a router listed, a 打新 sale
        address t = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        vm.prank(bob);
        uint256 got = pad.buy(t, 1 ether, 0);
        uint256 feeBefore = pad.creatorFeeOf(t);
        assertGt(feeBefore, 0);
        (,, uint128 realQuote, uint128 sold,,,,,,,,) = pad.curves(t);
        uint256 tokensBefore = pad.tokenCount();
        uint256 escrow = IERC20(address(wbnb)).balanceOf(address(pad));

        GangLaunchpad3V2Mock v2 = _v2Impl();
        vm.prank(upgrader);
        _admin()
            .upgradeAndCall(
                ITransparentUpgradeableProxy(address(pad)),
                address(v2),
                abi.encodeCall(GangLaunchpad3V2Mock.initializeV2, (42))
            );
        assertEq(_impl(), address(v2));
        assertEq(GangLaunchpad3V2Mock(payable(address(pad))).v2Value(), 42);

        // nothing of 3.0's state moved
        assertEq(pad.owner(), owner);
        assertTrue(pad.routers(address(router)));
        assertEq(pad.creatorFeeOf(t), feeBefore);
        (,, uint128 rq2, uint128 sold2,,,,,,,,) = pad.curves(t);
        assertEq(rq2, realQuote);
        assertEq(sold2, sold);
        assertEq(pad.tokenCount(), tokensBefore);
        assertEq(pad.kindOf(t), 1);
        assertEq(GangLaunchpad3(payable(address(pad))).tokenVersionOf(t), 1);
        assertEq(IERC20(address(wbnb)).balanceOf(address(pad)), escrow);
        assertEq(IERC20(t).balanceOf(bob), got);

        // and the token keeps trading on the same address
        vm.startPrank(bob);
        IERC20(t).approve(address(pad), type(uint256).max);
        pad.sell(t, got / 2, 0);
        vm.stopPrank();
        vm.prank(alice);
        assertGt(pad.claimCreatorFee(t, alice), feeBefore);

        // reinitializer(2) is one-shot too
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        GangLaunchpad3V2Mock(payable(address(pad))).initializeV2(7);
    }
}
