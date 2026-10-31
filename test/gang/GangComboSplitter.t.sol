// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {LpMockPair, LpMockPairFactory} from "../mocks/LpMockPair.sol";
import {GasBurnQuote} from "./GangSplitModule.t.sol";
import {GangComboSplitter} from "../../src/gang/GangComboSplitter.sol";
import {GangComboSplitterFactory} from "../../src/gang/GangComboSplitterFactory.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {DeployGangComboSplitterFactory} from "../../script/DeployGangComboSplitterFactory.s.sol";

/// @dev Answers every view the deploy script's `check` reads like a real factory / implementation, with other code.
contract FakeComboImpl {
    address public pad;
    address public taxHandler;
    address public factory;
    bytes32 public constant moduleType = "combo-v1";
    address public constant gangQuote = address(0x6A46);

    constructor(address pad_, address handler_) {
        (pad, taxHandler) = (pad_, handler_);
    }

    function setFactory(address f) external {
        factory = f;
    }
}

contract FakeComboFactory {
    address public pad;
    address public admin;
    address public implementation;

    constructor(address pad_, address admin_, address impl_) {
        (pad, admin, implementation) = (pad_, admin_, impl_);
    }
}

/// @notice GangComboSplitter (组合：回购 + 加池 + 分账) on the whole merged deployment, over pairs that keep the V2
///         oracle and mint LP as UniswapV2Pair does: the factory's checks, binding, the three-way split to the wei,
///         payees (owed, release, moving a slot, other assets), shortfalls, both chunk kinds on one pace and
///         price guard, the keeper's plan (`previewWork` / `work`), the deploy script, and the pool tax end to end.
contract GangComboSplitterTest is GangFixture {
    address keeper = makeAddr("keeper");
    GangHandlerAdmin admin;
    GangComboSplitterFactory factory;
    uint256 _salt;

    uint16 constant TAX = 300;
    uint256 constant ALL = type(uint256).max;
    address constant GANG = address(0x6A46);

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
        factory = new GangComboSplitterFactory(address(pad), address(admin), GANG);
        vm.prank(owner);
        admin.setFactory(address(factory), true);
    }

    // ---------------------------------------------------------------- helpers
    function _list(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        (p[0], p[1]) = (a, b);
    }

    function _shares(uint16 a, uint16 b) internal pure returns (uint16[] memory s) {
        s = new uint16[](2);
        (s[0], s[1]) = (a, b);
    }

    function _none() internal pure returns (address[] memory p, uint16[] memory s) {
        p = new address[](0);
        s = new uint16[](0);
    }

    function _combo(address dev, uint16 bb, uint16 lp, address[] memory p, uint16[] memory s)
        internal
        returns (GangComboSplitter m)
    {
        vm.prank(dev);
        m = GangComboSplitter(factory.create(bb, lp, p, s, bytes32(++_salt)));
    }

    /// @dev 30% buy-back, 30% liquidity, the rest to the dev (70%) and a KOL (30%); a taxed V3 token pays it.
    function _setup(address quote, bool grad)
        internal
        returns (GangComboSplitter m, address t, address dev, address kol)
    {
        dev = _newAgent();
        kol = makeAddr(string.concat("kol", vm.toString(_salt)));
        m = _combo(dev, 3_000, 3_000, _list(dev, kol), _shares(7_000, 3_000));
        t = _createV3(dev, quote, _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t);
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        if (grad) _graduate(t);
    }

    function _setupKept(address quote, uint16 bb, uint16 lp) internal returns (GangComboSplitter m, address t) {
        address dev = _newAgent();
        (address[] memory p, uint16[] memory s) = _none();
        m = _combo(dev, bb, lp, p, s);
        t = _createV3(dev, quote, _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t);
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
    }

    function newFactory(address pad_, address admin_) external returns (GangComboSplitterFactory) {
        return new GangComboSplitterFactory(pad_, admin_, GANG);
    }

    function create(
        GangComboSplitterFactory f,
        uint16 bb,
        uint16 lp,
        address[] memory p,
        uint16[] memory s,
        bytes32 salt
    ) external returns (address) {
        return f.create(bb, lp, p, s, salt);
    }

    function _next(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
    }

    function _bal(address asset, address who) internal view returns (uint256) {
        return IERC20(asset).balanceOf(who);
    }

    uint256 constant VALUE = (uint256(1) << 248) - 1;

    function _lp(address t, address who) internal view returns (uint256) {
        return LpMockPair(_curvePair(t)).balanceOf(who);
    }

    // ---------------------------------------------------------------- factory
    function test_factory_checks() public {
        vm.expectRevert(GangComboSplitterFactory.ZeroAddress.selector);
        this.newFactory(address(pad), address(0));
        GangHandlerAdmin elsewhere = new GangHandlerAdmin(owner, makeAddr("otherHandler"));
        vm.expectRevert(GangComboSplitterFactory.WrongHandler.selector);
        this.newFactory(address(pad), address(elsewhere));

        address dev = _newAgent();
        address b = makeAddr("b");
        (address[] memory none, uint16[] memory noShares) = _none();
        vm.prank(makeAddr("notAgent"));
        vm.expectRevert(GangComboSplitterFactory.NotAgent.selector);
        factory.create(3_000, 3_000, _list(dev, b), _shares(5_000, 5_000), bytes32(0));

        vm.startPrank(dev);
        vm.expectRevert(GangComboSplitter.BadBps.selector);
        factory.create(6_000, 5_000, none, noShares, bytes32(0));
        vm.expectRevert(GangComboSplitter.BadPayees.selector); // all kept but payees given
        factory.create(5_000, 5_000, _list(dev, b), _shares(5_000, 5_000), bytes32(0));
        vm.expectRevert(GangComboSplitter.BadPayees.selector); // a part left but no payees
        factory.create(3_000, 3_000, none, noShares, bytes32(0));
        vm.expectRevert(GangComboSplitter.BadPayees.selector);
        factory.create(3_000, 3_000, _list(dev, b), new uint16[](1), bytes32(0));
        address[] memory eleven = new address[](11);
        uint16[] memory elevenS = new uint16[](11);
        for (uint256 i; i < 11; i++) {
            eleven[i] = address(uint160(0x1000 + i));
            elevenS[i] = i == 0 ? 1_000 : 900;
        }
        vm.expectRevert(GangComboSplitter.BadPayees.selector);
        factory.create(3_000, 3_000, eleven, elevenS, bytes32(0));
        vm.expectRevert(GangComboSplitter.ZeroAddress.selector);
        factory.create(3_000, 3_000, _list(dev, address(0)), _shares(5_000, 5_000), bytes32(0));
        vm.expectRevert(GangComboSplitter.DuplicatePayee.selector);
        factory.create(3_000, 3_000, _list(dev, dev), _shares(5_000, 5_000), bytes32(0));
        vm.expectRevert(GangComboSplitter.BadShares.selector);
        factory.create(3_000, 3_000, _list(dev, b), _shares(10_000, 0), bytes32(0));
        vm.expectRevert(GangComboSplitter.BadShares.selector);
        factory.create(3_000, 3_000, _list(dev, b), _shares(5_000, 4_999), bytes32(0));
        vm.stopPrank();

        bytes32 salt = keccak256("launch-1");
        address predicted = factory.predict(dev, salt);
        vm.prank(dev);
        GangComboSplitter m =
            GangComboSplitter(factory.create(2_000, 4_000, _list(dev, b), _shares(6_000, 4_000), salt));
        assertEq(address(m), predicted);
        assertEq(m.moduleType(), bytes32("combo-v1"));
        assertEq(m.dev(), dev);
        assertEq(m.buybackBps(), 2_000);
        assertEq(m.lpBps(), 4_000);
        (address[] memory p, uint16[] memory s) = m.payeesOf();
        assertEq(p.length, 2);
        assertEq(p[1], b);
        assertEq(s[0], 6_000);
        assertEq(admin.moduleOf(address(m)), address(factory));
        assertTrue(handler.isListed(address(m)));
        assertEq(factory.count(), 1);
        vm.prank(dev);
        vm.expectRevert();
        factory.create(2_000, 4_000, _list(dev, b), _shares(6_000, 4_000), salt); // the address is taken

        // all kept, no payees: allowed; only the factory initializes, once; the implementation never
        vm.prank(dev);
        GangComboSplitter kept = GangComboSplitter(factory.create(10_000, 0, none, noShares, bytes32(0)));
        assertEq(kept.buybackBps(), 10_000);
        vm.expectRevert(GangComboSplitter.NotFactory.selector);
        kept.initialize(dev, 0, 0, _list(dev, b), _shares(5_000, 5_000));
        vm.prank(address(factory));
        vm.expectRevert(GangComboSplitter.AlreadyInitialized.selector);
        kept.initialize(dev, 0, 0, _list(dev, b), _shares(5_000, 5_000));
        GangComboSplitter impl = GangComboSplitter(factory.implementation());
        vm.prank(address(factory));
        vm.expectRevert(GangComboSplitter.NotClone.selector);
        impl.initialize(dev, 0, 0, _list(dev, b), _shares(5_000, 5_000));
    }

    function test_bind_checks() public {
        address dev = _newAgent();
        GangComboSplitter m = _combo(dev, 3_000, 3_000, _list(dev, makeAddr("k")), _shares(5_000, 5_000));
        address other = _newAgent();
        address t1 = _createV3(other, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        vm.expectRevert(GangComboSplitter.NotCreator.selector);
        m.bind(t1);
        address t2 = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, dev));
        vm.expectRevert(GangComboSplitter.NotRecipient.selector);
        m.bind(t2);
        vm.expectRevert(GangComboSplitter.NotCurve.selector);
        m.bind(makeAddr("nothing"));
        address t3 = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t3);
        assertEq(m.token(), t3);
        assertEq(m.quote(), address(wbnb));
        vm.expectRevert(GangComboSplitter.AlreadyBound.selector);
        m.bind(t3);
    }

    // ---------------------------------------------------------------- the split
    function test_split_threeWaysToTheWei() public {
        (GangComboSplitter m,, address dev, address kol) = _setup(address(wbnb), false);
        uint256 x = 1 ether + 7;
        uint256 dev0 = _bal(address(wbnb), dev);
        wbnb.mintUnlimited(address(m), x);
        assertEq(m.unsplit(), x);
        vm.expectEmit(address(m));
        uint256 toB = (x * 3_000) / 10_000;
        uint256 toL = (x * 3_000) / 10_000;
        uint256 toP = x - toB - toL;
        emit GangComboSplitter.Split(x, toB, toL, toP);
        m.split();
        assertEq(m.buybackLeft(), toB);
        assertEq(m.lpLeft(), toL);
        uint256 toKol = (toP * 3_000) / 10_000;
        assertEq(_bal(address(wbnb), kol), toKol, "kol 30% of the payees' part");
        assertEq(_bal(address(wbnb), dev) - dev0, toP - toKol, "dev the rest");
        assertEq(m.unsplit(), 0);
        assertEq(m.lastPaidAt(), block.timestamp);
    }

    function test_split_noPayeesRoundingStaysSetAside() public {
        (GangComboSplitter m,) = _setupKept(address(wbnb), 3_333, 6_667);
        wbnb.mintUnlimited(address(m), 7);
        m.split();
        assertEq(m.buybackLeft() + m.lpLeft(), 7, "nothing lost to rounding");
        assertEq(m.lpLeft(), (uint256(7) * 6_667) / 10_000);
        (GangComboSplitter m2,) = _setupKept(address(wbnb), 0, 10_000);
        wbnb.mintUnlimited(address(m2), 7);
        m2.split();
        assertEq(m2.lpLeft(), 7);
        assertEq(m2.buybackLeft(), 0);
    }

    // ---------------------------------------------------------------- payees
    function test_payee_blacklistedOwedReleased() public {
        (GangComboSplitter m,,, address kol) = _setup(address(blq), false);
        blq.setBlocked(kol, true);
        blq.mint(address(m), 10 ether);
        m.split(); // 4 to the payees: kol's 1.2 owed
        assertEq(m.owedOf(address(blq), 1), 1.2 ether);
        assertEq(m.owedTotal(address(blq)), 1.2 ether);
        assertEq(m.unsplit(), 0, "owed is held, not split again");
        vm.expectRevert("blacklisted");
        m.release(address(blq), 1, ALL);
        blq.setBlocked(kol, false);
        assertEq(m.release(address(blq), 1, 0.5 ether), 0.5 ether, "in parts");
        assertEq(m.release(address(blq), 1, ALL), 0.7 ether);
        assertEq(_bal(address(blq), kol), 1.2 ether);
        vm.expectRevert(GangComboSplitter.NothingOwed.selector);
        m.release(address(blq), 1, ALL);
        vm.expectRevert(GangComboSplitter.BadIndex.selector);
        m.release(address(blq), 2, ALL);
    }

    function test_payee_owedPaidAtTheNextPush() public {
        (GangComboSplitter m,,, address kol) = _setup(address(blq), false);
        blq.setBlocked(kol, true);
        blq.mint(address(m), 10 ether);
        m.split();
        blq.setBlocked(kol, false);
        blq.mint(address(m), 10 ether);
        m.split();
        assertEq(m.owedTotal(address(blq)), 0);
        assertEq(_bal(address(blq), kol), 2.4 ether);
    }

    function test_payee_movesOnlyItsOwnSlot() public {
        (GangComboSplitter m,, address dev, address kol) = _setup(address(wbnb), false);
        address kol2 = makeAddr("kol2");
        vm.prank(dev);
        vm.expectRevert(GangComboSplitter.NotPayee.selector);
        m.setPayee(1, kol2);
        vm.prank(kol);
        vm.expectRevert(GangComboSplitter.DuplicatePayee.selector);
        m.setPayee(1, dev);
        vm.prank(kol);
        vm.expectRevert(GangComboSplitter.BadPayee.selector);
        m.setPayee(1, address(m));
        vm.prank(kol);
        vm.expectRevert(GangComboSplitter.BadIndex.selector);
        m.setPayee(2, kol2);

        // what arrived before the move is split first and paid to the old address
        wbnb.mintUnlimited(address(m), 1 ether);
        vm.expectEmit(address(m));
        emit GangComboSplitter.PayeeChanged(1, kol, kol2);
        vm.prank(kol);
        m.setPayee(1, kol2);
        assertEq(_bal(address(wbnb), kol), 0.12 ether);
        wbnb.mintUnlimited(address(m), 1 ether);
        m.split();
        assertEq(_bal(address(wbnb), kol2), 0.12 ether);
    }

    /// @dev Another asset (another token's tax in another quote, a stray transfer): the buy-back and liquidity share
    ///      to 0xdead, the rest to the payees at their shares; a refusal that burns its gas costs at most PUSH_GAS and is
    ///      owed (as GangSplitModule).
    function test_otherAsset_keptShareToDeadRestToPayees() public {
        (GangComboSplitter m,, address dev, address kol) = _setup(address(wbnb), false);
        quoteTok.mintUnlimited(address(m), 1 ether);
        assertEq(m.undistributed(address(quoteTok)), 1 ether);
        uint256 dead0 = _bal(address(quoteTok), m.DEAD());
        vm.expectEmit(address(m));
        emit GangComboSplitter.Distributed(address(quoteTok), 1 ether, 0.6 ether);
        assertEq(m.distribute(address(quoteTok)), 1 ether);
        assertEq(_bal(address(quoteTok), m.DEAD()) - dead0, 0.6 ether, "30% + 30% to 0xdead");
        assertEq(_bal(address(quoteTok), kol), 0.12 ether, "kol 30% of the payees' 40%");
        assertEq(m.buybackLeft() + m.lpLeft(), 0, "other assets are never set aside");

        GasBurnQuote gb = new GasBurnQuote();
        gb.mint(address(m), 1 ether);
        gb.setBlocked(kol, true);
        uint256 g = gasleft();
        m.distribute(address(gb));
        assertLt(g - gasleft(), 2 * m.PUSH_GAS() + 200_000, "the dead push and a refusal, each at most PUSH_GAS");
        assertEq(m.owedOf(address(gb), 1), 0.12 ether);
        assertEq(gb.balanceOf(dev), 0.28 ether);
        assertEq(gb.balanceOf(m.DEAD()), 0.6 ether);
    }

    /// @dev An asset that refuses 0xdead: the share it can't burn goes to the payees with the rest; nothing is lost
    ///      or counted twice.
    function test_otherAsset_deadRefusedGoesToPayees() public {
        (GangComboSplitter m,, address dev, address kol) = _setup(address(wbnb), false);
        GasBurnQuote gb = new GasBurnQuote();
        gb.setBlocked(m.DEAD(), true);
        gb.mint(address(m), 1 ether);
        vm.expectEmit(address(m));
        emit GangComboSplitter.Distributed(address(gb), 1 ether, 0);
        m.distribute(address(gb));
        assertEq(gb.balanceOf(kol), 0.3 ether);
        assertEq(gb.balanceOf(dev), 0.7 ether);
        assertEq(gb.balanceOf(address(m)), m.owedTotal(address(gb)));
    }

    /// @dev Combo re-review 2026-10-31: before `bind` the quote is unknown, so nothing can be split as another asset —
    ///      tax that arrived early waits for the bind and is split as the quote.
    function test_beforeBind_nothingSplitOrBurned() public {
        address dev = _newAgent();
        GangComboSplitter m = _combo(dev, 3_000, 3_000, _list(dev, makeAddr("k")), _shares(5_000, 5_000));
        address t = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        wbnb.mintUnlimited(address(m), 1 ether);
        vm.expectRevert(GangComboSplitter.NotBound.selector);
        m.distribute(address(wbnb));
        vm.expectRevert(GangComboSplitter.NotBound.selector);
        m.release(address(wbnb), 0, ALL);
        m.split(); // nothing to do before bind
        assertEq(_bal(address(wbnb), address(m)), 1 ether);
        m.bind(t);
        m.split();
        assertEq(m.buybackLeft(), 0.3 ether);
        assertEq(m.lpLeft(), 0.3 ether);
    }

    function test_otherAsset_noPayeesAllToDead() public {
        (GangComboSplitter m,) = _setupKept(address(wbnb), 5_000, 5_000);
        quoteTok.mintUnlimited(address(m), 1 ether);
        uint256 dev0 = _bal(address(quoteTok), m.dev());
        uint256 dead0 = _bal(address(quoteTok), m.DEAD());
        m.distribute(address(quoteTok));
        assertEq(_bal(address(quoteTok), m.DEAD()) - dead0, 1 ether);
        assertEq(_bal(address(quoteTok), m.dev()), dev0, "nothing to the dev");
    }

    /// @dev Combo audit 2026-10-31 L-2: a dev binds a decoy token D, then launches the real token R naming the same
    ///      combo in another quote; R's tax can't skip the buy-back and liquidity shares to reach the dev.
    function test_otherAsset_decoyBindGainsTheDevNothingExtra() public {
        address dev = _newAgent();
        address kol = makeAddr("kolDecoy");
        GangComboSplitter m = _combo(dev, 3_000, 3_000, _list(dev, kol), _shares(7_000, 3_000));
        address decoy = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        m.bind(decoy);
        address real = _createV3(dev, address(quoteTok), _tax(TAX, TAX, 5_000, address(m)));
        assertTrue(real != decoy);
        quoteTok.mintUnlimited(address(m), 10 ether); // R's tax, in its quote
        uint256 dev0 = _bal(address(quoteTok), dev);
        m.distribute(address(quoteTok));
        assertEq(_bal(address(quoteTok), dev) - dev0, 2.8 ether, "the dev's payee share of 40%, not more");
        assertEq(_bal(address(quoteTok), m.DEAD()), 6 ether);
    }

    // ---------------------------------------------------------------- shortfall
    function test_shortfall_everyPartShrinks() public {
        (GangComboSplitter m,,, address kol) = _setup(address(blq), false);
        blq.setBlocked(kol, true);
        blq.mint(address(m), 10 ether);
        m.split(); // 3 buy-back, 3 liquidity, 1.2 owed to kol (2.8 pushed to the dev)
        assertEq(_bal(address(blq), address(m)), 7.2 ether);
        deal(address(blq), address(m), 3.6 ether); // half of it taken
        assertEq(m.unsplit(), 0);
        vm.expectEmit(address(m));
        emit GangComboSplitter.Shortfall(address(blq), 3.6 ether);
        m.split();
        assertEq(m.owedOf(address(blq), 1), 0.6 ether);
        assertEq(m.lpLeft(), 1.5 ether);
        assertEq(m.buybackLeft(), 1.5 ether);
        assertEq(m.buybackLeft() + m.lpLeft() + m.owedTotal(address(blq)), 3.6 ether, "held = balance");
        deal(address(blq), address(m), 1.8 ether);
        m.split();
        assertEq(m.buybackLeft() + m.lpLeft() + m.owedTotal(address(blq)), 1.8 ether);
        // the owed quote is released after the shortfall: what is left of it
        blq.setBlocked(kol, false);
        assertEq(m.release(address(blq), 1, ALL), 0.3 ether);
    }

    /// @dev Equal parts: a buy-back first (a tie), then, the buy-back part smaller, a liquidity add — each to the wei,
    ///      one per gap for both kinds.
    function test_chunks_largerPartOnOnePace() public {
        (GangComboSplitter m, address t,,) = _setup(address(wbnb), true);
        address pair = _curvePair(t);
        wbnb.mintUnlimited(address(m), 10 ether);
        (bool k0, uint256 q0,,) = m.chunk(0); // splits, records the observation
        assertFalse(k0 && q0 != 0);
        assertEq(q0, 0);
        assertEq(m.buybackLeft(), 3 ether);
        assertEq(m.lpLeft(), 3 ether);
        _next(10 minutes);

        // a buy-back chunk, to the wei
        (uint256 rT, uint256 rQ) = _reserves(t, pair);
        (bool ok, bool burnKind, uint256 pq, uint256 pOut) = m.previewChunk();
        assertTrue(ok);
        assertTrue(burnKind, "a tie: the buy-back");
        assertEq(pq, (rQ * 50) / 10_000, "capped");
        uint256 out = (pq * 9975 * rT) / (rQ * 10_000 + pq * 9975);
        assertEq(pOut, out - (out * TAX) / 10_000);
        uint256 dead0 = _bal(t, m.DEAD());
        (bool burned, uint256 q, uint256 tokens,) = m.chunk(pOut);
        assertTrue(burned);
        assertEq(q, pq);
        assertEq(tokens, pOut);
        assertEq(_bal(t, m.DEAD()) - dead0, tokens);

        (bool ready,,,) = m.previewChunk();
        assertFalse(ready);
        vm.expectRevert(GangComboSplitter.ChunkTooSoon.selector);
        m.chunk(0);
        _next(4 minutes);

        // the buy-back part is now the smaller: a liquidity chunk; reserves before the deposit = after the mint less
        // the deposit; matched rounded up
        m.split();
        assertLt(m.buybackLeft(), m.lpLeft());
        uint256 lpLeft0 = m.lpLeft();
        (, bool burnKind2, uint256 chunkAmt, uint256 pOut2) = m.previewChunk();
        assertFalse(burnKind2);
        uint256 supply0 = LpMockPair(pair).totalSupply();
        uint256 lp0 = _lp(t, m.DEAD());
        (bool burned2, uint256 q2, uint256 tokensIn, uint256 liq) = m.chunk(pOut2);
        assertFalse(burned2);
        (uint256 rT1, uint256 rQ1) = _reserves(t, pair);
        uint256 match_ = q2 - chunkAmt / 2;
        assertEq(tokensIn, pOut2 - (pOut2 * TAX) / 10_000, "sell tax on the deposit");
        uint256 rTb = rT1 - tokensIn;
        uint256 rQb = rQ1 - match_;
        assertEq(match_, (tokensIn * rQb + rTb - 1) / rTb, "matched at the reserves after the deposit");
        uint256 lt = (tokensIn * supply0) / rTb;
        uint256 lq = (match_ * supply0) / rQb;
        assertEq(liq, lt < lq ? lt : lq);
        assertEq(_lp(t, m.DEAD()) - lp0, liq);
        assertEq(m.lpLeft(), lpLeft0 - q2);
        assertEq(_bal(t, address(m)), 0);
        assertEq(_lp(t, address(m)), 0);
        assertGt(m.unsplit(), 0, "the deposit let the handler swap back, paying this recipient mid-chunk");
    }

    /// @dev Combo audit 2026-10-31 M-1: dust in the smaller part can't hold the shared pace — whoever calls `chunk`,
    ///      it works the larger part.
    function test_chunks_dustCantStarveTheLargerPart() public {
        address dev = _newAgent();
        GangComboSplitter m = _combo(dev, 5_000, 2_000, _list(dev, makeAddr("k")), _shares(5_000, 5_000));
        address t = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t);
        _graduate(t);
        wbnb.mintUnlimited(address(m), 1.5 ether);
        m.chunk(0);
        address griefer = _newAgent();
        uint256 chunks;
        for (uint256 i; i < 6; i++) {
            _next(4 minutes + (i == 0 ? 6 minutes : 0));
            uint256 lp0 = m.lpLeft();
            vm.startPrank(griefer);
            wbnb.transfer(address(m), 10);
            (bool burned, uint256 q,,) = m.chunk(0);
            vm.stopPrank();
            assertTrue(burned, "the griefer's call is for the buy-back, the larger part");
            assertGe(m.lpLeft(), lp0, "the smaller part is never chunked");
            if (q != 0) chunks++; // (none while the price guard holds after a run of buys)
        }
        assertGt(chunks, 2, "the buy-back advanced");
    }

    function test_chunks_refusedBeforeGraduationOrEmpty() public {
        (GangComboSplitter m,,,) = _setup(address(wbnb), false);
        vm.expectRevert(GangComboSplitter.NothingToChunk.selector);
        m.chunk(0);
        wbnb.mintUnlimited(address(m), 1 ether);
        vm.expectRevert(GangComboSplitter.NotTradable.selector);
        m.chunk(0);
        (bool ready,,,) = m.previewChunk();
        assertFalse(ready);
        (bool due,) = m.previewWork();
        assertFalse(due);
    }

    function test_chunks_skipAfterPump() public {
        (GangComboSplitter m, address t,,) = _setup(address(wbnb), true);
        wbnb.mintUnlimited(address(m), 10 ether);
        m.chunk(0);
        _next(10 minutes);
        (, uint256 rQ) = _reserves(t, _curvePair(t));
        _poolBuy(t, address(wbnb), _curvePair(t), _newAgent(), (rQ * 5) / 100);
        (bool ready,,,) = m.previewChunk();
        assertFalse(ready);
        (, uint256 q,,) = m.chunk(0);
        assertEq(q, 0);
        assertEq(m.lastChunkAt(), 0, "no chunk counted");
    }

    function test_chunks_slippage() public {
        (GangComboSplitter m,,,) = _setup(address(wbnb), true);
        wbnb.mintUnlimited(address(m), 10 ether);
        m.chunk(0);
        _next(10 minutes);
        (,,, uint256 pOut) = m.previewChunk();
        vm.expectRevert(GangComboSplitter.Slippage.selector);
        m.chunk(pOut + 1);
        m.chunk(pOut); // a buy-back
        _next(4 minutes);
        m.split();
        (, bool burn,, uint256 pOut2) = m.previewChunk();
        assertFalse(burn);
        vm.expectRevert(GangComboSplitter.Slippage.selector);
        m.chunk(pOut2 + 1);
    }

    /// @dev LP audit 2026-10-30 L-1, kept: quote left unsynced in the pair before the keeper's call can't fail it.
    function test_chunks_quoteLeftInPairDoesNotFailTheKeeper() public {
        (GangComboSplitter m, address t,,) = _setup(address(wbnb), true);
        address pair = _curvePair(t);
        (, uint256 rQ) = _reserves(t, pair);
        wbnb.mintUnlimited(address(m), rQ * 2);
        m.chunk(0);
        _next(10 minutes);
        (bool due, uint256 minOut) = m.previewWork();
        assertTrue(due);
        assertGt(minOut, 0);
        address griefer = _newAgent();
        vm.prank(griefer);
        wbnb.transfer(pair, (rQ * 3) / 100);
        m.work(minOut);
        assertEq(m.lastChunkAt(), block.timestamp, "the chunk went through");
    }

    /// @dev The keeper's loop: work(previewWork's minOut) whenever due. The observation comes first; each chunk goes to
    ///      the larger part (checked step by step); nothing is due inside the gap.
    function test_keeper_planFollowsTheLargerPart() public {
        address dev = _newAgent();
        address kol = makeAddr("kol");
        GangComboSplitter m = _combo(dev, 5_000, 2_000, _list(dev, kol), _shares(5_000, 5_000));
        address t = _createV3(dev, address(wbnb), _tax(TAX, TAX, 5_000, address(m)));
        m.bind(t);
        _graduate(t);
        (bool due, uint256 minOut) = m.previewWork();
        assertFalse(due, "nothing to do");

        wbnb.mintUnlimited(address(m), 10 ether);
        (due, minOut) = m.previewWork();
        assertTrue(due, "the observation the chunks need");
        assertEq(minOut >> 248, 3, "observe");
        m.work(minOut);
        assertEq(m.buybackLeft(), 5 ether);
        assertEq(m.lpLeft(), 2 ether);
        assertEq(m.lastChunkAt(), 0);
        (due,) = m.previewWork();
        assertFalse(due, "observed this block");

        _next(10 minutes);
        (due, minOut) = m.previewWork();
        assertTrue(due);
        (,,, uint256 out) = m.previewChunk();
        assertEq(minOut >> 248, 1, "a buy-back: the larger part");
        assertEq(minOut & VALUE, (out * 9_900) / 10_000);
        uint256 bb0 = m.buybackLeft();
        m.work(minOut);
        assertLt(m.buybackLeft(), bb0);
        (due,) = m.previewWork();
        assertFalse(due, "inside the gap");

        uint256 burns;
        uint256 adds;
        for (uint256 i; i < 200; i++) {
            _next(4 minutes);
            (due, minOut) = m.previewWork();
            if (!due) continue;
            m.split();
            uint256 b = m.buybackLeft();
            uint256 l = m.lpLeft();
            m.work(minOut);
            uint8 action = uint8(minOut >> 248);
            if (action == 1) {
                assertGe(b, l, "a buy-back only when it is the larger part");
                assertLt(m.buybackLeft(), b);
                burns++;
            } else if (action == 2) {
                assertGt(l, b, "a liquidity add only when it is the larger part");
                assertLt(m.lpLeft(), l);
                adds++;
            }
        }
        assertGt(burns, 1);
        assertGt(adds, 1);
        (, uint256 rQ) = _reserves(t, _curvePair(t));
        m.split();
        assertLt(m.buybackLeft() * 10_000, rQ * m.WORK_MIN_BPS(), "run down under the floor");
        assertLt(m.lpLeft() * 10_000, rQ * m.WORK_MIN_BPS());
    }

    /// @dev Combo audit 2026-10-31 L-1: a `minOut` planned for another action (the state moved between preview and
    ///      inclusion) makes `work` only split — no chunk with the wrong slippage bound, no revert.
    function test_keeper_workIgnoresAStalePlan() public {
        (GangComboSplitter m,,,) = _setup(address(wbnb), true);
        wbnb.mintUnlimited(address(m), 10 ether);
        (, uint256 obs) = m.previewWork();
        m.work(obs);
        _next(10 minutes);
        (bool due, uint256 burnPlan) = m.previewWork();
        assertTrue(due);
        assertEq(burnPlan >> 248, 1);
        m.chunk(0); // someone does that buy-back first
        _next(4 minutes);
        (, uint256 addPlan) = m.previewWork();
        assertEq(addPlan >> 248, 2, "now the liquidity part is larger");
        uint64 last = m.lastChunkAt();
        m.work(burnPlan); // the stale buy-back plan
        assertEq(m.lastChunkAt(), last, "no chunk");
        m.work(0); // a split-only / nothing plan
        assertEq(m.lastChunkAt(), last, "no chunk without a plan for it");
        m.work(addPlan);
        assertEq(m.lastChunkAt(), block.timestamp, "the current plan runs");
    }

    /// @dev Chunks small, the payees' part pending: due for a split once it is worth a call, or daily for a small one.
    function test_keeper_splitDueForThePayees() public {
        (GangComboSplitter m, address t,, address kol) = _setup(address(wbnb), true);
        (, uint256 rQ) = _reserves(t, _curvePair(t));
        uint256 floor = (rQ * m.WORK_MIN_BPS()) / 10_000;
        m.split();
        // a little: the payees' 40% under the floor, but over 1/100 of it
        wbnb.mintUnlimited(address(m), floor);
        (bool due,) = m.previewWork();
        assertFalse(due, "under the floor, paid out less than a day ago");
        _next(1 days);
        (due,) = m.previewWork();
        assertTrue(due, "idle a day");
        uint256 k0 = _bal(address(wbnb), kol);
        (, uint256 plan) = m.previewWork();
        assertEq(plan >> 248, 4, "a split");
        m.work(plan);
        assertGt(_bal(address(wbnb), kol), k0);
        // enough at once: due at once
        wbnb.mintUnlimited(address(m), (floor * 10_000) / 4_000 + 10);
        (due,) = m.previewWork();
        assertTrue(due);
    }

    function test_keeper_notForAQuoteItDoesNotServe() public {
        (GangComboSplitter m,,,) = _setup(address(quoteTok), true);
        quoteTok.mintUnlimited(address(m), 10 ether);
        (bool due,) = m.previewWork();
        assertTrue(due, "a QuoteRegistry quote is served");
        vm.prank(owner);
        quoteRegistry.setQuote(address(quoteTok), false, 0);
        assertFalse(m.keeperServes(address(quoteTok)));
        (due,) = m.previewWork();
        assertFalse(due);
        m.chunk(0); // by hand it still works
        assertGt(m.buybackLeft(), 0);
    }

    // ---------------------------------------------------------------- end to end
    /// @dev Pool sells pay the tax; the handler's chunks pay the combo; the keeper's loop burns, adds liquidity and
    ///      pays the payees; every wei is accounted for.
    function test_e2e_poolTaxPaysAllThree() public {
        (GangComboSplitter m, address t, address dev, address kol) = _setup(address(wbnb), true);
        address pair = _curvePair(t);
        for (uint256 i; i < 8; i++) {
            address seller = _newAgent();
            (uint256 rT,) = _reserves(t, pair);
            deal(t, seller, rT / 40);
            _poolSell(t, pair, seller, rT / 40);
            _next(1 minutes);
        }
        uint256 mc = handler.maxChunk(t);
        vm.prank(keeper);
        handler.process(t, mc, 1);
        assertGt(m.unsplit(), 0, "the recipient part arrived");

        uint256 dev0 = _bal(address(wbnb), dev);
        uint256 dead0 = _bal(t, m.DEAD());
        uint256 lp0 = _lp(t, m.DEAD());
        for (uint256 i; i < 100; i++) {
            (bool due, uint256 minOut) = m.previewWork();
            if (due) m.work(minOut);
            _next(4 minutes);
        }
        assertGt(_bal(t, m.DEAD()), dead0, "bought back and burned");
        assertGt(_lp(t, m.DEAD()), lp0, "liquidity locked");
        assertGt(_bal(address(wbnb), kol), 0, "kol paid");
        assertGt(_bal(address(wbnb), dev), dev0, "dev paid");
        assertEq(_bal(t, address(m)), 0);
        assertEq(_lp(t, address(m)), 0);
        assertEq(_bal(address(wbnb), address(m)), m.buybackLeft() + m.lpLeft() + m.unsplit(), "books = balance");
    }

    // ---------------------------------------------------------------- deploy script
    function test_script_check() public {
        DeployGangComboSplitterFactory script = new DeployGangComboSplitterFactory();
        script.check(address(pad), address(admin), address(factory));
        assertEq(script.pendingBatch(address(admin), address(factory)).length, 0);

        GangHandlerAdmin rogue = new GangHandlerAdmin(makeAddr("notTheSafe"), address(handler));
        GangComboSplitterFactory rogueFactory = new GangComboSplitterFactory(address(pad), address(rogue), GANG);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGangComboSplitterFactory.WiringCheck.selector, "admin.handlerOwner")
        );
        script.check(address(pad), address(rogue), address(rogueFactory));
        vm.expectRevert(abi.encodeWithSelector(DeployGangComboSplitterFactory.WiringCheck.selector, "factory.admin"));
        script.check(address(pad), address(admin), address(rogueFactory));

        script.checkCode(address(factory));
        FakeComboImpl fakeImpl = new FakeComboImpl(address(pad), address(handler));
        FakeComboFactory fake = new FakeComboFactory(address(pad), address(admin), address(fakeImpl));
        fakeImpl.setFactory(address(fake));
        script.check(address(pad), address(admin), address(fake));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGangComboSplitterFactory.WiringCheck.selector, "factory.runtimeCode")
        );
        script.checkCode(address(fake));

        GangComboSplitterFactory f2 = new GangComboSplitterFactory(address(pad), address(admin), GANG);
        bytes[] memory batch = script.pendingBatch(address(admin), address(f2));
        assertEq(batch.length, 1);
        bytes memory c = batch[0];
        address to;
        assembly ("memory-safe") {
            to := shr(96, mload(add(c, 32)))
        }
        bytes memory data = new bytes(c.length - 20);
        for (uint256 j; j < data.length; j++) {
            data[j] = c[j + 20];
        }
        assertEq(to, address(admin));
        vm.prank(owner);
        (bool ok,) = to.call(data);
        assertTrue(ok);
        assertTrue(admin.isFactory(address(f2)));
        assertEq(script.pendingBatch(address(admin), address(f2)).length, 0);
    }
}
