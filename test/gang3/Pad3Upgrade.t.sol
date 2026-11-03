// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {DeployGang} from "../../script/DeployGang.s.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {GangLaunchpad3V2Mock} from "../mocks/GangLaunchpad3V2Mock.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {Pad3CurveSwapMock, MockWBNBFallback} from "../mocks/GangLaunchpad3Review3Mocks.sol";

/// @dev Exposes the upgrade script's own checks (the same code the script runs).
contract UpgradeHarness is UpgradeGangLaunchpad3 {
    function snap(GangLaunchpad3 p, DeployGang.Stack memory s) external view returns (Snapshot memory) {
        return _snapshot(p, s);
    }

    function checkImpl(address current, address impl) external view {
        _checkImpl(current, impl);
    }

    function wantVersion(address impl, uint64 current, bytes memory init) external view returns (uint64) {
        return _wantVersion(impl, current, init);
    }
}

/// @notice The independent re-review's three PoCs (review 3), as regressions: the upgrade script's record check sees a
///         same-type struct member swap; a new reinitializer can't be left open; a router fee to WBNB is refused.
contract Pad3UpgradeTest is GangFixture {
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    GangLaunchpad3 internal pad3;
    UpgradeHarness internal h;
    address internal alice;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(address(this));
        pad3 = GangLaunchpad3(payable(address(pad)));
        h = new UpgradeHarness();
        alice = _newAgent();
        vm.setEnv("CALLERS", "");
    }

    function _admin() internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(address(pad), ADMIN_SLOT)))));
    }

    function _stack() internal view returns (DeployGang.Stack memory s) {
        s.router = address(router);
    }

    function _v2() internal returns (address) {
        return address(
            new GangLaunchpad3V2Mock(
                address(quoteRegistry),
                address(divVault),
                address(bucket),
                address(handler),
                address(tokenDeployer),
                address(wbnb),
                address(padRegistry3)
            )
        );
    }

    /// @dev Two uint128 members of Curve swapped (realQuote <-> gradAmt): the raw record reads the same, the derived
    ///      views (graduation remaining, quotes) do not — the snapshot differs and the script refuses.
    function test_snapshot_seesSameTypeMemberSwap() public {
        address t = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        vm.prank(alice, alice);
        pad.buy(t, 1 ether, 0);
        UpgradeGangLaunchpad3.Snapshot memory before = h.snap(pad3, _stack());
        Pad3CurveSwapMock next = new Pad3CurveSwapMock();
        vm.prank(upgrader);
        _admin().upgradeAndCall(ITransparentUpgradeableProxy(address(pad)), address(next), "");
        UpgradeGangLaunchpad3.Snapshot memory afterUp = h.snap(pad3, _stack());
        assertTrue(afterUp.tokens[0] != before.tokens[0], "the token's record reads differently");
    }

    /// @dev A new reinitializer needs its set-up call inside the upgrade; a set-up call needs a new reinitializer.
    function test_wantVersion_reinitializerMustRunInTheUpgrade() public {
        address v2 = _v2();
        h.checkImpl(pad3Impl, v2);
        bytes memory init = abi.encodeCall(GangLaunchpad3V2Mock.initializeV2, (7));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGang.WiringCheck.selector, "PAD3_INIT_CALL missing: reinitializer left open")
        );
        h.wantVersion(v2, 1, "");
        assertEq(h.wantVersion(v2, 1, init), 2);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGang.WiringCheck.selector, "PAD3_INIT_CALL without a new reinitializer")
        );
        h.wantVersion(pad3Impl, 1, init);
        assertEq(h.wantVersion(pad3Impl, 1, ""), 1);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGang.WiringCheck.selector, "PAD3_IMPL initVersion below the proxy's")
        );
        h.wantVersion(pad3Impl, 2, "");
    }

    /// @dev WBNB's payable fallback would book a BNB router fee as the pad's WBNB, outside every book: refused.
    function test_sellToken_feeToWbnb_refused() public {
        vm.etch(address(wbnb), address(new MockWBNBFallback()).code);
        address t = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        vm.prank(alice, alice);
        uint256 out = pad.buy(t, 1 ether, 0);
        vm.startPrank(alice, alice);
        IERC20(t).approve(address(pad), out);
        vm.expectRevert(IGangLaunchpad3.ZeroFeeRecipient.selector);
        pad3.sellToken(0, t, alice, out, 0, 500, address(wbnb));
        vm.stopPrank();
    }
}
