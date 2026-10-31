// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {GangTaxHandler} from "../../src/gang/GangTaxHandler.sol";
import {GangComboSplitter} from "../../src/gang/GangComboSplitter.sol";
import {GangComboSplitterFactory} from "../../src/gang/GangComboSplitterFactory.sol";
import {DeployGangComboSplitterFactory} from "../../script/DeployGangComboSplitterFactory.s.sol";

interface IComboForkPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IComboForkHandler {
    function maxChunk(address token) external view returns (uint256);
    function process(address token, uint256 amount, uint256 minQuoteOut) external returns (uint256);
    function keeper() external view returns (address);
}

/// @notice GangComboSplitterFactory on a BSC mainnet fork, against the live GangLaunchpad, GangTaxHandler and
///         PancakeSwap: deployed as the deploy script does and allowed by the Safe; an Agent clones a combined splitter
///         (30% buy-back, 30% liquidity, the rest 70 / 30 to itself and a KOL), creates a WBNB tax token naming it,
///         binds it; the curve graduates into a real Pancake pair; pool sells pay the tax; the keeper's loop
///         (previewWork / work) burns, adds real LP to 0xdead and pays the payees. Every Agent ID is mocked.
/// @dev Needs BSC_RPC_URL (without it every test is skipped).
contract ComboMainnetForkTest is Test {
    address constant PAD = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant ADMIN = 0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address constant GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;

    GangComboSplitterFactory factory;
    DeployGangComboSplitterFactory script;
    address dev = makeAddr("fork-combo-dev");
    address kol = makeAddr("fork-combo-kol");

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        factory = new GangComboSplitterFactory(PAD, ADMIN, GANG);
        script = new DeployGangComboSplitterFactory();
        assertEq(script.pendingBatch(ADMIN, address(factory)).length, 1, "one Safe call");
        vm.prank(M.OWNER_SAFE);
        GangHandlerAdmin(ADMIN).setFactory(address(factory), true);
        // every address is an Agent here (the curve needs a hundred buyers to graduate)
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
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
        assertEq(GangTaxHandler(IGangPad(PAD).taxHandler()).owner(), ADMIN);
    }

    function test_fork_graduateTaxAndRunAllThree() public forkOnly {
        address[] memory p = new address[](2);
        (p[0], p[1]) = (dev, kol);
        uint16[] memory sh = new uint16[](2);
        (sh[0], sh[1]) = (7_000, 3_000);
        vm.prank(dev, dev);
        GangComboSplitter m = GangComboSplitter(factory.create(3_000, 3_000, p, sh, keccak256("fork-combo")));
        assertEq(m.moduleType(), bytes32("combo-v1"));
        vm.prank(dev, dev);
        address t = IGangPad(PAD)
            .create(
                "Combo fork",
                "CMBF",
                "",
                "",
                M.WBNB,
                address(0),
                IGangLaunchpad.TaxConfig({buyTaxBps: 300, sellTaxBps: 300, dividendBps: 4000, recipient: address(m)})
            );
        m.bind(t);
        assertTrue(m.keeperServes(M.WBNB) && m.keeperServes(GANG));

        bool graduated;
        address pair;
        for (uint256 i; i < 400 && !graduated; i++) {
            address b = address(uint160(0xC0000 + i));
            deal(M.WBNB, b, 2 ether);
            vm.startPrank(b, b);
            IERC20(M.WBNB).approve(PAD, type(uint256).max);
            try IGangPad(PAD).buy(t, 2 ether, 0) {} catch {}
            vm.stopPrank();
            (,,,,,, graduated,,,, pair,) = IGangPad(PAD).curves(t);
        }
        assertTrue(graduated, "graduated");
        uint256 deadLp0 = IComboForkPair(pair).balanceOf(DEAD);

        for (uint256 i; i < 6; i++) {
            address seller = address(uint160(0xC0000 + i));
            _poolSell(t, pair, seller, IERC20(t).balanceOf(seller) / 2);
            vm.warp(block.timestamp + 60);
            vm.roll(block.number + 2);
        }
        IComboForkHandler h = IComboForkHandler(IGangPad(PAD).taxHandler());
        uint256 mc = h.maxChunk(t);
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 2);
        vm.prank(h.keeper());
        if (mc != 0) {
            try h.process(t, mc, 1) {} catch {}
        }
        // a larger backlog so both parts are worth a keeper call
        deal(M.WBNB, address(m), IERC20(M.WBNB).balanceOf(address(m)) + 0.5 ether);
        uint256 kol0 = IERC20(M.WBNB).balanceOf(kol);
        uint256 dead0 = IERC20(t).balanceOf(DEAD);
        uint256 burns;
        uint256 adds;
        for (uint256 i; i < 30; i++) {
            (bool due, uint256 minOut) = m.previewWork();
            if (due) {
                uint256 b0 = m.buybackLeft();
                uint256 l0 = m.lpLeft();
                m.work(minOut);
                if (m.buybackLeft() < b0) burns++;
                if (m.lpLeft() < l0) adds++;
                assertEq(IERC20(t).balanceOf(address(m)), 0, "holds no token");
                assertEq(IComboForkPair(pair).balanceOf(address(m)), 0, "holds no LP");
            }
            vm.warp(block.timestamp + 4 minutes);
            vm.roll(block.number + 1);
        }
        console.log("burns / adds", burns, adds);
        assertGt(burns, 0, "bought back");
        assertGt(adds, 0, "liquidity added");
        assertGt(IERC20(t).balanceOf(DEAD), dead0, "burned");
        assertGt(IComboForkPair(pair).balanceOf(DEAD), deadLp0, "real Pancake LP at 0xdead");
        assertGt(IERC20(M.WBNB).balanceOf(kol), kol0, "the KOL paid");
    }

    function _poolSell(address t, address pair, address who, uint256 amount) internal {
        if (amount == 0) return;
        (uint112 r0, uint112 r1,) = IComboForkPair(pair).getReserves();
        bool tIs0 = IComboForkPair(pair).token0() == t;
        vm.prank(who, who);
        IERC20(t).transfer(pair, amount);
        (r0, r1,) = IComboForkPair(pair).getReserves();
        (uint256 rT, uint256 rQ) = tIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inT = IERC20(t).balanceOf(pair) - rT;
        uint256 out = (inT * 9975 * rQ) / (rT * 10_000 + inT * 9975);
        vm.prank(who, who);
        if (tIs0) IComboForkPair(pair).swap(0, out, who, "");
        else IComboForkPair(pair).swap(out, 0, who, "");
    }
}
