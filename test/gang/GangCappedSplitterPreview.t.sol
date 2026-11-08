// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {LpMockPairFactory} from "../mocks/LpMockPair.sol";
import {GasBurnQuote} from "./GangSplitModule.t.sol";
import {GangCappedSplitter} from "../../src/gang/GangCappedSplitter.sol";
import {GangCappedSplitterFactory} from "../../src/gang/GangCappedSplitterFactory.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";

/// @dev Exposes `_afterSplit` (what previewWork / previewChunk build on).
contract CappedHarness is GangCappedSplitter {
    constructor(address pad_, address gq) GangCappedSplitter(pad_, gq) {}

    function afterSplit() external view returns (uint256, uint256, uint256) {
        return _afterSplit();
    }
}

contract CappedHarnessFactory {
    address public immutable implementation;
    GangHandlerAdmin public immutable admin;

    constructor(address pad_, address admin_) {
        implementation = address(new CappedHarness(pad_, address(0)));
        admin = GangHandlerAdmin(admin_);
    }

    function create(
        address dev,
        address q,
        uint256 cap,
        uint16 pay,
        uint16 bbRest,
        address[] calldata p,
        uint16[] calldata s
    ) external returns (CappedHarness m) {
        m = CappedHarness(Clones.clone(implementation));
        m.initialize(dev, q, cap, pay, bbRest, p, s);
        admin.listModule(address(m), "capped-v1");
    }
}

/// @notice GangCappedSplitter, the parts the main suite can't reach through its public views: `_afterSplit` (what
///         previewWork / previewChunk build on) against the split that follows under random arrivals, shortfalls and
///         refusing payees (I-5); spec §1's worked example to the wei; ten gas-burning payees (I-8); two tokens of the
///         same quote sharing one cap (§6); `setPayee` leaving every number as it was (I-7). From the 2026-11-08 review.
contract GangCappedSplitterPreviewTest is GangFixture {
    address keeper = makeAddr("keeper");
    GangHandlerAdmin admin;
    GangCappedSplitterFactory factory;
    CappedHarnessFactory hf;
    uint256 _salt;

    function _newPairFactory() internal override returns (address) {
        return address(new LpMockPairFactory());
    }

    function setUp() public {
        _deployGang(keeper);
        admin = new GangHandlerAdmin(owner, address(handler));
        vm.startPrank(owner);
        handler.transferOwnership(address(admin));
        admin.exec(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        vm.stopPrank();
        factory = new GangCappedSplitterFactory(address(pad), address(admin), address(0));
        hf = new CappedHarnessFactory(address(pad), address(admin));
        vm.startPrank(owner);
        admin.setFactory(address(factory), true);
        admin.setFactory(address(hf), true);
        vm.stopPrank();
    }

    function _two(address a, address b) internal pure returns (address[] memory p, uint16[] memory s) {
        p = new address[](2);
        (p[0], p[1]) = (a, b);
        s = new uint16[](2);
        (s[0], s[1]) = (6_000, 4_000);
    }

    function _one(address a) internal pure returns (address[] memory p, uint16[] memory s) {
        p = new address[](1);
        p[0] = a;
        s = new uint16[](1);
        s[0] = 10_000;
    }

    function _capped(
        address dev,
        address q,
        uint256 cap,
        uint16 pay,
        uint16 bbRest,
        address[] memory p,
        uint16[] memory s
    ) internal returns (GangCappedSplitter m) {
        vm.prank(dev);
        m = GangCappedSplitter(factory.create(q, cap, pay, bbRest, p, s, bytes32(++_salt)));
    }

    // ------------------------------------------------------------ spec §1 worked example, to the wei
    /// @dev 3% tax, 40% dividend, 100 BNB volume: the module gets 1.5; payBps 50%, cap 20, rest 70/30.
    function test_specWorkedExample() public {
        address dev = _newAgent();
        (address[] memory p, uint16[] memory s) = _one(dev);
        GangCappedSplitter m = _capped(dev, address(wbnb), 20 ether, 5_000, 7_000, p, s);
        address t = _createV3(dev, address(wbnb), _tax(300, 300, 4_000, address(m)));
        m.bind(t);
        uint256 dev0 = wbnb.balanceOf(dev);
        // the module's part of 100 BNB volume: (3% - 0.5%) * 60% = 1.5
        uint256 v = 100 ether;
        assertEq(((v * (300 - 50)) / 10_000) * 6_000 / 10_000, uint256(1.5 ether));
        wbnb.mintUnlimited(address(m), 1.5 ether);
        m.split();
        assertEq(wbnb.balanceOf(dev) - dev0, 0.75 ether, "payees 0.75");
        assertEq(m.buybackLeft(), 0.525 ether, "buy-back 0.525");
        assertEq(m.lpLeft(), 0.225 ether, "lp 0.225");
        // fill the cap
        wbnb.mintUnlimited(address(m), 40 ether);
        m.split();
        assertTrue(m.capReached());
        uint256 bb0 = m.buybackLeft();
        uint256 lp0 = m.lpLeft();
        uint256 dev1 = wbnb.balanceOf(dev);
        wbnb.mintUnlimited(address(m), 1.5 ether);
        m.split();
        assertEq(wbnb.balanceOf(dev), dev1, "payees 0 after the cap");
        assertEq(m.buybackLeft() - bb0, 1.05 ether, "buy-back 1.05");
        assertEq(m.lpLeft() - lp0, 0.45 ether, "lp 0.45");
        // §1 volume-to-cap table: cap / ((tax - 0.5%) * (1 - div) * payBps), in bps^3
        uint256 c20 = 20 ether * 1e12;
        uint256 c10 = 10 ether * 1e12;
        assertEq(c20 / (250 * 6_000 * 5_000) / 1 ether, 2_666); // ≈ 2,667
        assertEq(c10 / (250 * 6_000 * 5_000) / 1 ether, 1_333); // ≈ 1,333
        assertEq(c20 / (250 * 10_000 * 10_000) / 1 ether, 800); // 800
        assertEq(c20 / (450 * 10_000 * 10_000) / 1 ether, 444); // ≈ 444
    }

    // ------------------------------------------------------------ I-5: the real preview == split, under random state
    function testFuzz_I5_afterSplitIsTheSplit(uint256 seed, uint96 cap, uint16 pay, uint16 bbRest) public {
        cap = uint96(bound(cap, 1, 50 ether));
        pay = uint16(bound(pay, 1, 10_000));
        bbRest = uint16(bound(bbRest, 0, 10_000));
        address dev = _newAgent();
        address kol = makeAddr("rvKol");
        (address[] memory p, uint16[] memory s) = _two(dev, kol);
        CappedHarness m = hf.create(dev, address(blq), cap, pay, bbRest, p, s);
        address t = _createV3(dev, address(blq), _tax(300, 300, 5_000, address(m)));
        m.bind(t);
        for (uint256 i; i < 24; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 5;
            if (op == 0) {
                blq.setBlocked(kol, (r >> 8) % 2 == 0);
                continue;
            }
            if (op == 1) {
                uint256 held = m.buybackLeft() + m.lpLeft() + m.owedTotal(address(blq));
                if (held == 0) continue;
                deal(address(blq), address(m), held - ((held * ((r >> 8) % 50)) / 100));
            } else {
                blq.mint(address(m), (r >> 8) % 20 ether);
            }
            (uint256 bb, uint256 lp, uint256 toP) = m.afterSplit();
            uint256 paid0 = m.paidTotal();
            m.split();
            assertEq(m.buybackLeft(), bb, "I-5 buy-back");
            assertEq(m.lpLeft(), lp, "I-5 liquidity");
            assertEq(m.paidTotal() - paid0, toP, "I-5 payees");
            if (paid0 == cap) assertEq(toP, 0, "I-4");
        }
    }

    // ------------------------------------------------------------ I-8 with gas-burning payees (all ten)
    function test_I8_tenGasBurningPayees() public {
        GasBurnQuote gb = new GasBurnQuote();
        vm.prank(owner);
        quoteRegistry.setQuote(address(gb), true, 15 ether);
        address dev = _newAgent();
        address[] memory p = new address[](10);
        uint16[] memory s = new uint16[](10);
        for (uint256 i; i < 10; i++) {
            p[i] = i == 0 ? dev : address(uint160(0xB000 + i));
            s[i] = 1_000;
            gb.setBlocked(p[i], true);
        }
        GangCappedSplitter m = _capped(dev, address(gb), 1 ether, 5_000, 5_000, p, s);
        address t = _createV3(dev, address(gb), _tax(300, 300, 5_000, address(m)));
        m.bind(t);
        gb.mint(address(m), 10 ether);
        uint256 g = gasleft();
        m.split();
        uint256 used = g - gasleft();
        assertLt(used, 10 * m.PUSH_GAS() + 1_000_000);
        assertEq(m.paidTotal(), 1 ether, "owed counts against the cap");
        assertEq(m.owedTotal(address(gb)), 1 ether);
        assertEq(m.buybackLeft() + m.lpLeft(), 9 ether, "set aside regardless");
        // a later split after the cap pushes nothing (no new owed) and costs no push gas
        gb.mint(address(m), 1 ether);
        g = gasleft();
        m.split();
        assertLt(g - gasleft(), 200_000, "after the cap no pushes");
        assertEq(m.owedTotal(address(gb)), 1 ether);
    }

    // ------------------------------------------------------------ §6: same-quote second token shares the cap
    function test_sameQuoteSecondTokenSharesTheCap() public {
        address dev = _newAgent();
        (address[] memory p, uint16[] memory s) = _one(dev);
        GangCappedSplitter m = _capped(dev, address(wbnb), 1 ether, 10_000, 5_000, p, s);
        address d = _createV3(dev, address(wbnb), _tax(300, 300, 5_000, address(m)));
        m.bind(d);
        _createV3(dev, address(wbnb), _tax(300, 300, 5_000, address(m))); // R, same quote, same recipient
        uint256 dev0 = wbnb.balanceOf(dev);
        wbnb.mintUnlimited(address(m), 5 ether); // R's tax arrives as the bound quote
        m.split();
        assertEq(wbnb.balanceOf(dev) - dev0, 1 ether, "the one cap holds across both tokens");
    }

    // ------------------------------------------------------------ I-7: setPayee leaves every number as it was
    function test_I7_setPayeeOnlyMovesTheAddress() public {
        address dev = _newAgent();
        address kol = makeAddr("k7");
        (address[] memory p, uint16[] memory s) = _two(dev, kol);
        GangCappedSplitter m = _capped(dev, address(wbnb), 3 ether, 4_000, 2_500, p, s);
        vm.prank(kol);
        m.setPayee(1, makeAddr("k7b"));
        (address[] memory p2, uint16[] memory s2) = m.payeesOf();
        assertEq(p2[0], dev);
        assertEq(p2[1], makeAddr("k7b"));
        assertEq(s2[0], 6_000);
        assertEq(s2[1], 4_000);
        assertEq(m.capAmount(), 3 ether);
        assertEq(m.capQuote(), address(wbnb));
        assertEq(m.payBps(), 4_000);
        assertEq(m.buybackOfRestBps(), 2_500);
    }
}
