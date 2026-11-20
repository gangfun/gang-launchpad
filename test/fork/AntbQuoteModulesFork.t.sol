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
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {Pad3VanitySalt} from "../../script/Pad3VanitySalt.sol";

interface IAqPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function balanceOf(address) external view returns (uint256);
}

interface IAqHandler {
    function maxChunk(address token) external view returns (uint256);
    function process(address token, uint256 amount, uint256 minQuoteOut) external returns (uint256);
    function keeper() external view returns (address);
}

interface IAqPadOwner {
    function owner() external view returns (address);
    function setWalletCapEnabled(bool enabled) external;
}

interface IAqPadQuote {
    function graduationAmountOf(address quote, address refPool) external view returns (uint256);
}

/// @notice ANTB (0x38dd…fc53, 18 decimals, no transfer fee, no receiver callback; a compliance blocklist and a pause
///         switch held by its issuer) listed on the shared mainnet QuoteRegistry with graduationQuoteAmount 0, as the
///         stablecoins were on 2026-11-01. Checks on GangLaunchpad 3.0: the graduation amount is unchanged (still
///         priced on the creator's reference pool, the Pancake V3 ANTB/USDT 0.25% pool bridged through USDT), the
///         live 3.0 split / combo clones serve ANTB once listed, and a combo on an ANTB-quoted 3.0 token graduates,
///         is paid its tax in ANTB, buys back, adds liquidity and pays its payees through the keeper's loop.
///         Agent IDs are mocked. No broadcast.
/// @dev Needs BSC_RPC_URL (without it every test is skipped).
contract AntbQuoteModulesForkTest is Test {
    address constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address constant SPLIT3 = 0x904D4498a9257E4d7638afEbB95A1162cB2171f2;
    address constant COMBO3 = 0x20188054dE31De844df205712768852BdeD3eA39;
    address constant REGISTRY = 0x8b93919862830ea6A720B28C7D0C42fCbb849F17;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address constant ANTB = 0x38Dd26788Cf2d901E3aBf04efE3007d459d0Fc53;
    /// Pancake V3 ANTB/USDT 0.25%: the reference pool (and, in the fork, the ANTB source for the test buyers)
    address constant ANTB_REF = 0x5AFB6E189A268c6adFC9DA13CA13e3BA91171a31;

    address dev = makeAddr("fork-aq-dev");
    address kol = makeAddr("fork-aq-kol");
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

    function _setListed(bool on) internal {
        vm.prank(M.OWNER_SAFE);
        QuoteRegistry(REGISTRY).setQuote(ANTB, on, 0);
    }

    /// @dev ANTB's balances live in namespaced storage behind a beacon proxy: move real ANTB out of the reference
    ///      pool instead of `deal` (the transfer runs the token's own pause and compliance checks).
    function _fund(address to, uint256 amount) internal {
        vm.prank(ANTB_REF);
        IERC20(ANTB).transfer(to, amount);
    }

    function test_fork_antb_listingKeepsGraduationAmount() public forkOnly {
        _setListed(false);
        assertFalse(QuoteRegistry(REGISTRY).isQuoted(ANTB), "unlisted");
        uint256 before = IAqPadQuote(PAD3).graduationAmountOf(ANTB, ANTB_REF);
        assertGt(before, 0);
        _setListed(true);
        assertTrue(QuoteRegistry(REGISTRY).isQuoted(ANTB));
        assertEq(QuoteRegistry(REGISTRY).graduationAmount(ANTB), 0, "no fixed rate");
        assertEq(IAqPadQuote(PAD3).graduationAmountOf(ANTB, ANTB_REF), before, "same graduation amount");
        vm.expectRevert(IGangLaunchpad.RefPoolRequired.selector);
        IAqPadQuote(PAD3).graduationAmountOf(ANTB, address(0));
        console.log("3.0 grad amount (ANTB, default target)", before);
    }

    function test_fork_antb_liveModulesServeOnceListed() public forkOnly {
        address[] memory p = new address[](1);
        p[0] = dev;
        uint16[] memory sh = new uint16[](1);
        sh[0] = 10_000;
        vm.prank(dev, dev);
        GangSplitModule s = GangSplitModule(GangSplitModuleFactory(SPLIT3).create(p, sh, keccak256("fork-aq-split")));
        vm.prank(dev, dev);
        GangComboSplitter c =
            GangComboSplitter(GangComboSplitterFactory(COMBO3).create(3_000, 3_000, p, sh, keccak256("fork-aq-c")));
        _setListed(false);
        assertFalse(s.keeperServes(ANTB) || c.keeperServes(ANTB), "not served unlisted");
        _setListed(true);
        assertTrue(s.keeperServes(ANTB) && c.keeperServes(ANTB), "served once listed");
    }

    function test_fork_antb_comboOnPad3() public forkOnly {
        _setListed(true);
        address[] memory p = new address[](2);
        (p[0], p[1]) = (dev, kol);
        uint16[] memory sh = new uint16[](2);
        (sh[0], sh[1]) = (7_000, 3_000);
        vm.prank(dev, dev);
        GangComboSplitter m =
            GangComboSplitter(GangComboSplitterFactory(COMBO3).create(3_000, 3_000, p, sh, keccak256("fork-aq-combo")));
        // 3.0 creates through the abcd vanity deployer (createWithSalt)
        Pad3VanityDeployer vd = Pad3VanityDeployer(Pad3Module(payable(PAD3)).vanityDeployer());
        bytes32 initHash = vd.tokenInitCodeHash("ANTB fork", "ANTBF", "m", IGangPad(PAD3).taxHandler(), 300, 300, false);
        (bytes32 salt, address at) = Pad3VanitySalt.find(address(vd), dev, initHash);
        bytes memory data = abi.encodeWithSignature(
            "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))",
            "ANTB fork",
            "ANTBF",
            "l",
            "m",
            ANTB,
            ANTB_REF,
            IGangLaunchpad.TaxConfig(300, 300, 4_000, address(m))
        );
        vm.prank(dev, dev);
        address t = Pad3Module(payable(PAD3)).createWithSalt(salt, data);
        assertEq(t, at);
        m.bind(t);
        assertEq(m.quote(), ANTB);
        assertTrue(m.keeperServes(ANTB));

        // a fork's state at its block is pruned within about a minute: no wallet cap, so a few buyers fill the curve
        vm.prank(IAqPadOwner(PAD3).owner());
        IAqPadOwner(PAD3).setWalletCapEnabled(false);
        uint256 per = IAqPadQuote(PAD3).graduationAmountOf(ANTB, ANTB_REF) / 3;
        bool graduated;
        address pair;
        for (uint256 i; i < 10 && !graduated; i++) {
            address b = address(uint160(0xD0000 + i));
            _fund(b, per);
            vm.startPrank(b, b);
            IERC20(ANTB).approve(PAD3, type(uint256).max);
            try IGangPad(PAD3).buy(t, per, 0) {} catch {}
            vm.stopPrank();
            (,,,,,, graduated,,,, pair,) = IGangPad(PAD3).curves(t);
        }
        assertTrue(graduated, "graduated on 3.0");
        uint256 deadLp0 = IAqPair(pair).balanceOf(DEAD);

        for (uint256 i; i < 6; i++) {
            address seller = address(uint160(0xD0000 + i));
            _poolSell(t, pair, seller, IERC20(t).balanceOf(seller) / 2);
            vm.warp(vm.getBlockTimestamp() + 60);
            vm.roll(vm.getBlockNumber() + 2);
        }
        IAqHandler h = IAqHandler(IGangPad(PAD3).taxHandler());
        uint256 mc = h.maxChunk(t);
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.roll(vm.getBlockNumber() + 2);
        uint256 got0 = IERC20(ANTB).balanceOf(address(m));
        vm.prank(h.keeper());
        if (mc != 0) h.process(t, mc, 1);
        assertGt(IERC20(ANTB).balanceOf(address(m)), got0, "tax paid to the combo in ANTB");
        // a larger backlog so both parts are worth a keeper call
        _fund(address(m), per / 10);
        uint256 kol0 = IERC20(ANTB).balanceOf(kol);
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
                assertEq(IAqPair(pair).balanceOf(address(m)), 0, "holds no LP");
            }
            vm.warp(vm.getBlockTimestamp() + 4 minutes);
            vm.roll(vm.getBlockNumber() + 1);
        }
        console.log("ANTB combo on 3.0: buy-backs, LP adds", burns, adds);
        assertGt(burns, 0, "bought back");
        assertGt(adds, 0, "liquidity added");
        assertGt(IERC20(t).balanceOf(DEAD), dead0, "burned");
        assertGt(IAqPair(pair).balanceOf(DEAD), deadLp0, "LP at 0xdead");
        assertGt(IERC20(ANTB).balanceOf(kol), kol0, "the KOL paid in ANTB");
    }

    function _poolSell(address t, address pair, address who, uint256 amount) internal {
        if (amount == 0) return;
        bool tIs0 = IAqPair(pair).token0() == t;
        vm.prank(who, who);
        IERC20(t).transfer(pair, amount);
        (uint112 r0, uint112 r1,) = IAqPair(pair).getReserves();
        (uint256 rT, uint256 rQ) = tIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inT = IERC20(t).balanceOf(pair) - rT;
        uint256 out = (inT * 9975 * rQ) / (rT * 10_000 + inT * 9975);
        vm.prank(who, who);
        if (tIs0) IAqPair(pair).swap(0, out, who, "");
        else IAqPair(pair).swap(out, 0, who, "");
    }
}
