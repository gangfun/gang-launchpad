// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {GangComboSplitter} from "../../src/gang/GangComboSplitter.sol";
import {GangComboSplitterFactory} from "../../src/gang/GangComboSplitterFactory.sol";
import {GangSplitModule} from "../../src/gang/GangSplitModule.sol";
import {GangSplitModuleFactory} from "../../src/gang/GangSplitModuleFactory.sol";

interface ISQPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function balanceOf(address) external view returns (uint256);
}

interface ISQHandler {
    function maxChunk(address token) external view returns (uint256);
    function process(address token, uint256 amount, uint256 minQuoteOut) external returns (uint256);
    function keeper() external view returns (address);
}

interface ISQPadOwner {
    function owner() external view returns (address);
    function setWalletCapEnabled(bool enabled) external;
}

interface ISQPadQuote {
    function graduationAmountOf(address quote, address refPool) external view returns (uint256);
}

/// @notice USDT / USDC / USD1 listed on the shared mainnet QuoteRegistry with graduationQuoteAmount 0 (the Safe did it
///         on 2026-11-01; the tests unlist and list again, so they hold before and after): graduation amounts on both
///         pads are the same either way (still priced on the reference pool), the live combo / split modules serve
///         these quotes once listed, and a combo on a stablecoin-quoted token buys back, adds liquidity and pays its
///         payees through the keeper's loop. Every Agent ID is mocked.
/// @dev Needs BSC_RPC_URL (without it every test is skipped).
contract StableQuoteModulesForkTest is Test {
    address constant PAD1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant PAD2 = 0x770331a9accdb53ACb4a45B6c5B7D151fADCe557;
    address constant COMBO1 = 0xd33C38BE3f8472b3013167830F0638C1704e1DBd;
    address constant COMBO2 = 0xcCeA388DbC0Edb206eC25C9715546d57029198Be;
    address constant SPLIT2 = 0xa73dC3d63AAf72E70b1cb012e5f3A541360Bec59;
    address constant REGISTRY = 0x8b93919862830ea6A720B28C7D0C42fCbb849F17;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
    address constant USDC_REF = 0xd99c7F6C65857AC913a8f880A4cb84032AB2FC5b; // Pancake V2 WBNB/USDC
    address constant USD1_REF = 0x46b9217342CdC50c89FfA84A12Be45b2639eAf4A; // Pancake V2 WBNB/USD1

    address dev = makeAddr("fork-sq-dev");
    address kol = makeAddr("fork-sq-kol");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
    }

    modifier forkOnly() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _quotes() internal pure returns (address[3] memory q, address[3] memory ref) {
        q = [M.USDT, USDC, USD1];
        ref = [M.USDT_REF_POOL, USDC_REF, USD1_REF];
    }

    function _list() internal {
        _setListed(true);
    }

    function _setListed(bool on) internal {
        (address[3] memory q,) = _quotes();
        for (uint256 i; i < 3; i++) {
            vm.prank(M.OWNER_SAFE);
            QuoteRegistry(REGISTRY).setQuote(q[i], on, 0);
        }
    }

    function test_fork_listingKeepsGraduationAmounts() public forkOnly {
        (address[3] memory q, address[3] memory ref) = _quotes();
        address[2] memory pads = [PAD1, PAD2];
        uint256[2][3] memory before;
        _setListed(false);
        for (uint256 i; i < 3; i++) {
            assertFalse(QuoteRegistry(REGISTRY).isQuoted(q[i]), "unlisted");
            for (uint256 j; j < 2; j++) {
                before[i][j] = ISQPadQuote(pads[j]).graduationAmountOf(q[i], ref[i]);
                assertGt(before[i][j], 0);
            }
        }
        _list();
        for (uint256 i; i < 3; i++) {
            assertTrue(QuoteRegistry(REGISTRY).isQuoted(q[i]));
            assertEq(QuoteRegistry(REGISTRY).graduationAmount(q[i]), 0, "no fixed rate");
            for (uint256 j; j < 2; j++) {
                assertEq(ISQPadQuote(pads[j]).graduationAmountOf(q[i], ref[i]), before[i][j], "same graduation amount");
                // still priced on the creator's reference pool
                vm.expectRevert(IGangLaunchpad.RefPoolRequired.selector);
                ISQPadQuote(pads[j]).graduationAmountOf(q[i], address(0));
            }
            console.log("grad amount (pad1, pad2)", before[i][0], before[i][1]);
        }
    }

    function test_fork_liveModulesServeListedQuotes() public forkOnly {
        address[] memory p = new address[](1);
        p[0] = dev;
        uint16[] memory sh = new uint16[](1);
        sh[0] = 10_000;
        vm.prank(dev, dev);
        GangSplitModule s = GangSplitModule(GangSplitModuleFactory(SPLIT2).create(p, sh, keccak256("fork-sq-split")));
        vm.prank(dev, dev);
        GangComboSplitter c1 =
            GangComboSplitter(GangComboSplitterFactory(COMBO1).create(3_000, 3_000, p, sh, keccak256("fork-sq-c1")));
        (address[3] memory q,) = _quotes();
        _setListed(false);
        for (uint256 i; i < 3; i++) {
            assertFalse(s.keeperServes(q[i]) || c1.keeperServes(q[i]), "not served unlisted");
        }
        _list();
        for (uint256 i; i < 3; i++) {
            assertTrue(s.keeperServes(q[i]) && c1.keeperServes(q[i]), "served once listed");
        }
    }

    function test_fork_comboOnUsdtPad1() public forkOnly {
        _list();
        _runCombo(PAD1, COMBO1, M.USDT, M.USDT_REF_POOL, "c1-usdt");
    }

    function test_fork_comboOnUsdtPad2() public forkOnly {
        _list();
        _runCombo(PAD2, COMBO2, M.USDT, M.USDT_REF_POOL, "c2-usdt");
    }

    function test_fork_comboOnUsdcPad2() public forkOnly {
        _list();
        _runCombo(PAD2, COMBO2, USDC, USDC_REF, "c2-usdc");
    }

    function test_fork_comboOnUsd1Pad2() public forkOnly {
        _list();
        _runCombo(PAD2, COMBO2, USD1, USD1_REF, "c2-usd1");
    }

    function _runCombo(address pad, address factory, address quote, address ref, string memory salt) internal {
        address[] memory p = new address[](2);
        (p[0], p[1]) = (dev, kol);
        uint16[] memory sh = new uint16[](2);
        (sh[0], sh[1]) = (7_000, 3_000);
        vm.prank(dev, dev);
        GangComboSplitter m =
            GangComboSplitter(GangComboSplitterFactory(factory).create(3_000, 3_000, p, sh, keccak256(bytes(salt))));
        vm.prank(dev, dev);
        address t = IGangPad(pad)
            .create(
                "Stable fork",
                "STBF",
                "",
                "",
                quote,
                ref,
                IGangLaunchpad.TaxConfig({buyTaxBps: 300, sellTaxBps: 300, dividendBps: 4000, recipient: address(m)})
            );
        m.bind(t);
        assertEq(m.quote(), quote);
        assertTrue(m.keeperServes(quote));

        // a fork's state at its block is pruned within about a minute: no wallet cap, so a few buyers fill the curve
        vm.prank(ISQPadOwner(pad).owner());
        ISQPadOwner(pad).setWalletCapEnabled(false);
        uint256 per = ISQPadQuote(pad).graduationAmountOf(quote, ref) / 3;
        bool graduated;
        address pair;
        for (uint256 i; i < 10 && !graduated; i++) {
            address b = address(uint160(0xD0000 + i));
            deal(quote, b, per);
            vm.startPrank(b, b);
            IERC20(quote).approve(pad, type(uint256).max);
            try IGangPad(pad).buy(t, per, 0) {} catch {}
            vm.stopPrank();
            (,,,,,, graduated,,,, pair,) = IGangPad(pad).curves(t);
        }
        assertTrue(graduated, "graduated");
        uint256 deadLp0 = ISQPair(pair).balanceOf(DEAD);

        for (uint256 i; i < 6; i++) {
            address seller = address(uint160(0xD0000 + i));
            _poolSell(t, pair, seller, IERC20(t).balanceOf(seller) / 2);
            vm.warp(block.timestamp + 60);
            vm.roll(block.number + 2);
        }
        ISQHandler h = ISQHandler(IGangPad(pad).taxHandler());
        uint256 mc = h.maxChunk(t);
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 2);
        uint256 got0 = IERC20(quote).balanceOf(address(m));
        vm.prank(h.keeper());
        if (mc != 0) h.process(t, mc, 1);
        assertGt(IERC20(quote).balanceOf(address(m)), got0, "tax paid to the combo in the stablecoin");
        // a larger backlog so both parts are worth a keeper call
        deal(quote, address(m), IERC20(quote).balanceOf(address(m)) + per / 10);
        uint256 kol0 = IERC20(quote).balanceOf(kol);
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
                assertEq(ISQPair(pair).balanceOf(address(m)), 0, "holds no LP");
            }
            vm.warp(block.timestamp + 4 minutes);
            vm.roll(block.number + 1);
        }
        console.log(salt, burns, adds);
        assertGt(burns, 0, "bought back");
        assertGt(adds, 0, "liquidity added");
        assertGt(IERC20(t).balanceOf(DEAD), dead0, "burned");
        assertGt(ISQPair(pair).balanceOf(DEAD), deadLp0, "LP at 0xdead");
        assertGt(IERC20(quote).balanceOf(kol), kol0, "the KOL paid in the stablecoin");
    }

    function _poolSell(address t, address pair, address who, uint256 amount) internal {
        if (amount == 0) return;
        bool tIs0 = ISQPair(pair).token0() == t;
        vm.prank(who, who);
        IERC20(t).transfer(pair, amount);
        (uint112 r0, uint112 r1,) = ISQPair(pair).getReserves();
        (uint256 rT, uint256 rQ) = tIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inT = IERC20(t).balanceOf(pair) - rT;
        uint256 out = (inT * 9975 * rQ) / (rT * 10_000 + inT * 9975);
        vm.prank(who, who);
        if (tIs0) ISQPair(pair).swap(0, out, who, "");
        else ISQPair(pair).swap(out, 0, who, "");
    }
}
