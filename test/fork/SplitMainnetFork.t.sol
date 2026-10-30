// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {GangTaxHandler} from "../../src/gang/GangTaxHandler.sol";
import {GangSplitModule} from "../../src/gang/GangSplitModule.sol";
import {GangSplitModuleFactory} from "../../src/gang/GangSplitModuleFactory.sol";
import {DeployGangSplitModuleFactory} from "../../script/DeployGangSplitModuleFactory.s.sol";

/// @notice GangSplitModuleFactory on a BSC mainnet fork, against the live GangLaunchpad and GangHandlerAdmin: deployed
///         as the deploy script does, allowed by the Safe (the one batch call), then an Agent clones a 60/30/10 split,
///         creates a WBNB-quoted tax token naming it, binds it, and WBNB and GANG sent to it split to the wei. The
///         deploy script's wiring and runtime-code checks pass on it. The Agent ID is mocked (balanceOf = 1).
/// @dev Needs BSC_RPC_URL (without it every test is skipped).
contract SplitMainnetForkTest is Test {
    address constant PAD = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant ADMIN = 0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985;
    address constant GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;

    GangSplitModuleFactory factory;
    DeployGangSplitModuleFactory script;
    address dev = makeAddr("fork-dev");
    address b = makeAddr("fork-b");
    address c = makeAddr("fork-c");

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        factory = new GangSplitModuleFactory(PAD, ADMIN, GANG);
        script = new DeployGangSplitModuleFactory();
        assertEq(script.pendingBatch(ADMIN, address(factory)).length, 1, "one Safe call");
        vm.prank(M.OWNER_SAFE);
        GangHandlerAdmin(ADMIN).setFactory(address(factory), true);
        vm.mockCall(
            M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector, dev), abi.encode(uint256(1))
        );
    }

    modifier forkOnly() {
        if (address(factory) == address(0)) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_scriptChecks() public forkOnly {
        script.check(PAD, ADMIN, address(factory));
        script.checkCode(address(factory));
        assertEq(script.pendingBatch(ADMIN, address(factory)).length, 0, "nothing left for the Safe");
        assertEq(GangSplitModule(factory.implementation()).gangQuote(), GANG);
        assertEq(GangHandlerAdmin(ADMIN).owner(), M.OWNER_SAFE);
        assertEq(GangTaxHandler(IGangPad(PAD).taxHandler()).owner(), ADMIN);
    }

    function test_fork_cloneCreateBindSplit() public forkOnly {
        address[] memory payees = new address[](3);
        (payees[0], payees[1], payees[2]) = (dev, b, c);
        uint16[] memory shares = new uint16[](3);
        (shares[0], shares[1], shares[2]) = (6000, 3000, 1000);
        bytes32 salt = keccak256("fork");
        address predicted = factory.predict(dev, salt);

        vm.prank(dev, dev);
        GangSplitModule m = GangSplitModule(factory.create(payees, shares, salt));
        assertEq(address(m), predicted, "predict");
        assertEq(m.moduleType(), bytes32("split-v1"));
        assertEq(m.dev(), dev);
        assertEq(GangHandlerAdmin(ADMIN).moduleOf(address(m)), address(factory));
        assertTrue(GangTaxHandler(IGangPad(PAD).taxHandler()).isListed(address(m)), "listed");

        vm.prank(dev, dev);
        address t = IGangPad(PAD)
            .create(
                "Split fork",
                "SPLF",
                "",
                "",
                M.WBNB,
                address(0),
                IGangLaunchpad.TaxConfig({buyTaxBps: 200, sellTaxBps: 200, dividendBps: 5000, recipient: address(m)})
            );
        m.bind(t);
        assertEq(m.token(), t);
        assertEq(m.quote(), M.WBNB);
        assertTrue(m.keeperServes(M.WBNB) && m.keeperServes(GANG), "keeper serves WBNB and GANG");
        (bool due,) = m.previewWork();
        assertFalse(due, "not due before graduation");

        _split(m, M.WBNB, 1 ether + 7);
        _split(m, GANG, 1000 ether + 3);
    }

    function _split(GangSplitModule m, address asset, uint256 amount) internal {
        uint256[3] memory before =
            [IERC20(asset).balanceOf(dev), IERC20(asset).balanceOf(b), IERC20(asset).balanceOf(c)];
        deal(asset, address(m), amount);
        assertEq(m.distribute(asset), amount, "incoming");
        uint256 toB = (amount * 3000) / 10_000;
        uint256 toC = (amount * 1000) / 10_000;
        assertEq(IERC20(asset).balanceOf(b) - before[1], toB, "b 30%");
        assertEq(IERC20(asset).balanceOf(c) - before[2], toC, "c 10%");
        assertEq(IERC20(asset).balanceOf(dev) - before[0], amount - toB - toC, "dev 60% + remainder");
        assertEq(IERC20(asset).balanceOf(address(m)), 0, "nothing left");
        assertEq(m.owedTotal(asset), 0, "nothing owed");
    }
}
