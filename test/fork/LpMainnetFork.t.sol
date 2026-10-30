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
import {GangLiquiditySplitter} from "../../src/gang/GangLiquiditySplitter.sol";
import {GangLiquiditySplitterFactory} from "../../src/gang/GangLiquiditySplitterFactory.sol";
import {DeployGangLiquiditySplitterFactory} from "../../script/DeployGangLiquiditySplitterFactory.s.sol";

interface IForkPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IForkHandler {
    function maxChunk(address token) external view returns (uint256);
    function process(address token, uint256 amount, uint256 minQuoteOut) external returns (uint256);
    function keeper() external view returns (address);
}

/// @notice GangLiquiditySplitterFactory on a BSC mainnet fork, against the live GangLaunchpad, GangTaxHandler and
///         PancakeSwap: deployed as the deploy script does and allowed by the Safe; an Agent clones a 70% LP splitter,
///         creates a WBNB tax token naming it, binds it; the curve graduates into a real Pancake pair; pool sells pay
///         the tax, the handler's chunks pay the splitter; chunks buy half, deposit back (real sell tax and swap-back),
///         match the quote and mint real Pancake LP to 0xdead. Every Agent ID is mocked (balanceOf = 1).
/// @dev Needs BSC_RPC_URL (without it every test is skipped).
contract LpMainnetForkTest is Test {
    address constant PAD = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant ADMIN = 0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    GangLiquiditySplitterFactory factory;
    DeployGangLiquiditySplitterFactory script;
    address dev = makeAddr("fork-lp-dev");

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        factory = new GangLiquiditySplitterFactory(PAD, ADMIN);
        script = new DeployGangLiquiditySplitterFactory();
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

    function test_fork_graduateTaxAndAddLiquidity() public forkOnly {
        vm.prank(dev, dev);
        GangLiquiditySplitter s = GangLiquiditySplitter(factory.create(7000, keccak256("fork-lp"), address(0)));
        assertEq(s.moduleType(), bytes32("lp-burn-v1"));
        vm.prank(dev, dev);
        address t = IGangPad(PAD)
            .create(
                "LP fork",
                "LPF",
                "",
                "",
                M.WBNB,
                address(0),
                IGangLaunchpad.TaxConfig({buyTaxBps: 300, sellTaxBps: 300, dividendBps: 4000, recipient: address(s)})
            );
        s.bind(t);

        // graduate: fresh buyers, 1% each
        bool graduated;
        address pair;
        for (uint256 i; i < 400 && !graduated; i++) {
            address b = address(uint160(0xB0000 + i));
            deal(M.WBNB, b, 2 ether);
            vm.startPrank(b, b);
            IERC20(M.WBNB).approve(PAD, type(uint256).max);
            try IGangPad(PAD).buy(t, 2 ether, 0) {} catch {}
            vm.stopPrank();
            (,,,,,, graduated,,,, pair,) = IGangPad(PAD).curves(t);
        }
        assertTrue(graduated, "graduated");
        console.log("pair", pair);
        uint256 deadLp0 = IForkPair(pair).balanceOf(DEAD);
        assertGt(deadLp0, 0, "graduation LP at 0xdead");

        // pool sells pay the tax; the handler's chunks pay the splitter
        for (uint256 i; i < 6; i++) {
            address seller = address(uint160(0xB0000 + i));
            uint256 bal = IERC20(t).balanceOf(seller);
            _poolSell(t, pair, seller, bal / 2);
            vm.warp(block.timestamp + 60);
            vm.roll(block.number + 2);
        }
        IForkHandler h = IForkHandler(IGangPad(PAD).taxHandler());
        uint256 mc = h.maxChunk(t);
        // the keeper's run, a block later (the handler refuses a price under its block reference: it waits)
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 2);
        vm.prank(h.keeper());
        if (mc != 0) {
            try h.process(t, mc, 1) {} catch {}
        }
        s.split();
        uint256 left = s.lpLeft();
        console.log("lpLeft after the tax", left);
        assertGt(left, 0, "the LP part arrived");

        // chunks: the first call records the observation, then one per gap
        s.addChunk(0);
        uint256 minted;
        uint256 spent;
        uint256 paidMidChunk;
        for (uint256 i; i < 4; i++) {
            vm.warp(block.timestamp + 10 minutes);
            vm.roll(block.number + 1);
            (bool ok, uint256 chunk, uint256 pOut) = s.previewAdd();
            if (!ok) break;
            uint256 supply0 = IForkPair(pair).totalSupply();
            (uint256 q, uint256 tokensIn, uint256 liq) = s.addChunk((pOut * 99) / 100);
            console.log("chunk / spent / LP", chunk, q, liq);
            assertGt(q, chunk / 2, "bought and deposited");
            assertLe(q, chunk);
            assertGt(tokensIn, 0);
            assertGt(liq, 0, "real Pancake LP minted");
            assertGt(IForkPair(pair).totalSupply(), supply0);
            assertEq(IERC20(t).balanceOf(address(s)), 0, "holds no token");
            assertEq(IForkPair(pair).balanceOf(address(s)), 0, "holds no LP");
            minted += liq;
            spent += q;
            // the deposit let the handler sell its tax into the pair and pay this recipient mid-chunk
            if (s.unsplit() > 0) paidMidChunk++;
            s.split();
        }
        assertGt(paidMidChunk, 0, "the handler's swap-back paid in during a chunk");
        assertGt(minted, 0);
        // Pancake may mint its protocol fee LP to feeTo in the same mint: 0xdead got at least ours
        assertGe(IForkPair(pair).balanceOf(DEAD) - deadLp0, minted, "LP at 0xdead");
        console.log("spent / left", spent, s.lpLeft());
    }

    function _poolSell(address t, address pair, address who, uint256 amount) internal {
        if (amount == 0) return;
        (uint112 r0, uint112 r1,) = IForkPair(pair).getReserves();
        bool tIs0 = IForkPair(pair).token0() == t;
        vm.prank(who, who);
        IERC20(t).transfer(pair, amount);
        (r0, r1,) = IForkPair(pair).getReserves();
        (uint256 rT, uint256 rQ) = tIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inT = IERC20(t).balanceOf(pair) - rT;
        uint256 out = (inT * 9975 * rQ) / (rT * 10_000 + inT * 9975);
        vm.prank(who, who);
        if (tIs0) IForkPair(pair).swap(0, out, who, "");
        else IForkPair(pair).swap(out, 0, who, "");
    }
}
