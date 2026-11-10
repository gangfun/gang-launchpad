// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GangFixture} from "../utils/GangFixture.sol";
import {Pad3VanityAcceptanceHarness} from "../utils/Pad3VanityAcceptanceHarness.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {Pad3VanityAcceptanceVault} from "../../script/Pad3VanityTestnetAcceptance.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Pad3VanityAcceptanceTest is GangFixture {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function test_acceptance_createsAllModesAndTradesLegacy() public {
        _deployGang(makeAddr("keeper"));
        (address actor, uint256 key) = makeAddrAndKey("abcd acceptance actor");
        agents.mint(actor, _nextAgentId++);
        vm.deal(actor, 1 ether);
        address old = _createV3(actor, address(wbnb), _tax(0, 0, 0, address(0)));
        Pad3VanityDeployer d = new Pad3VanityDeployer(address(pad), address(tokenDeployer), address(flyDeployer));
        Pad3Module pm = Pad3Module(payable(address(pad)));
        address vault = address(new Pad3VanityAcceptanceVault());
        vm.startPrank(owner);
        pm.enableVanity(address(d));
        pm.setVault(vault, true);
        pm.setVaultCreator(vault, actor);
        vm.stopPrank();
        Pad3VanityAcceptanceHarness runner = new Pad3VanityAcceptanceHarness();
        address[] memory tokens = runner.accept(address(pad), key, vault, old);
        assertEq(tokens.length, 7);
        for (uint256 i; i < tokens.length; i++) {
            assertEq(uint16(uint160(tokens[i])), 0xabcd);
            assertTrue(d.isLaunchToken(tokens[i]));
            assertGt(IERC20(tokens[i]).balanceOf(actor), 0);
            assertEq(IERC20(tokens[i]).allowance(actor, address(pad)), 0);
        }
        assertEq(IERC20(address(wbnb)).allowance(actor, address(pad)), 0);
        assertGt(IERC20(old).balanceOf(actor), 0);
        assertEq(GangLaunchpad3(payable(address(pad))).owner(), owner);
        assertEq(pm.vaultOf(tokens[5]), vault);
    }
}
