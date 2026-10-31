// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GangFixture} from "../utils/GangFixture.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {IGangPadRegistry} from "../../src/gang/interfaces/IGangPadRegistry.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangPadRegistryDeployLib as G} from "../../script/GangPadRegistryDeployLib.sol";

/// @dev A listed aggregator reduced to the pad calls: pays buys out of its own balance, keeps what a sell pays it.
contract RegistryAggregator {
    GangLaunchpad public immutable pad;

    constructor(GangLaunchpad pad_, address quote) {
        pad = pad_;
        IERC20(quote).approve(address(pad_), type(uint256).max);
    }

    function buy(address token, uint256 quoteIn) external returns (uint256) {
        return pad.buyFor(msg.sender, token, quoteIn, 0);
    }

    function sell(address token, uint256 tokensIn) external returns (uint256) {
        return pad.sellFor(msg.sender, token, tokensIn, 0);
    }
}

/// @dev Points at whatever pad it is told to; nobody lists it.
contract FakeGangToken {
    address public launchpad;

    constructor(address pad_) {
        launchpad = pad_;
    }
}

contract RevertingToken {
    function launchpad() external pure returns (address) {
        revert("no");
    }
}

contract GasBurningToken {
    function launchpad() external view returns (address) {
        uint256 i;
        while (gasleft() > 1_000) i++;
        return address(uint160(i));
    }
}

/// @dev Returns a word that is not an address, or (bomb) 4 KB whose first word is `pad`: cheap enough to finish under
///      the lookup's gas cap, so padOf copies the first word only and the pad itself turns the token down.
contract OddReturnToken {
    address internal immutable pad;
    bool internal immutable bomb;

    constructor(address pad_, bool bomb_) {
        pad = pad_;
        bomb = bomb_;
    }

    fallback() external {
        address p = pad;
        if (bomb) {
            assembly {
                mstore(0x00, p)
                return(0x00, 4096)
            }
        }
        assembly {
            mstore(0x00, or(shl(160, 1), p))
            return(0x00, 0x20)
        }
    }
}

/// @dev Stands in for a later pad generation: lists the tokens it is told to, with the curve constants of `math`.
contract NextPad {
    uint256 public immutable VIRTUAL_TOKEN;
    uint256 public immutable PROTOCOL_FEE_BPS;
    mapping(address => uint8) public kindOf;

    constructor(uint256 virtualToken, uint256 feeBps) {
        VIRTUAL_TOKEN = virtualToken;
        PROTOCOL_FEE_BPS = feeBps;
    }

    function list(address token, uint8 kind) external {
        kindOf[token] = kind;
    }
}

/// @notice GangPadRegistry as deployed on mainnet (proxy, ProxyAdmin and registry owned by the Safe, `owner` here; the
///         pad registered in `initialize`): discovery that look-alikes cannot fool and tokens cannot break, append-only
///         registration by the owner only, quotes that match `buyFor` / `sellFor` to the wei, upgrades by the owner
///         only that keep the state, and the storage layout.
contract GangPadRegistryTest is GangFixture {
    bytes32 internal constant BUY_TOPIC = keccak256("Buy(address,address,uint256,uint256,uint256,uint256,uint256)");
    bytes32 internal constant SELL_TOPIC = keccak256("Sell(address,address,uint256,uint256,uint256,uint256,uint256)");

    GangPadRegistry internal reg;
    G.Registry internal stack;
    RegistryAggregator internal agg;
    address internal creator;
    address internal trader;
    address internal human = makeAddr("human"); // no Agent ID
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _deployGang(makeAddr("keeper"));
        address[] memory pads = new address[](1);
        pads[0] = address(pad);
        stack = G.deploy(owner, pads);
        reg = GangPadRegistry(stack.proxy);

        agg = new RegistryAggregator(pad, address(wbnb));
        wbnb.mintUnlimited(address(agg), 100_000 ether);
        vm.prank(owner);
        pad.setRouter(address(agg), true);
        creator = _newAgent();
        trader = _newAgent();
    }

    // ---------------------------------------------------------------- helpers
    function _v3() internal returns (address) {
        return _createV3(creator, address(0), _tax(0, 0, 0, address(0)));
    }

    /// @dev The fee and tokens of the one pad event of `topic` in the recorded logs.
    function _padEvent(bytes32 topic) internal view returns (uint256 amount, uint256 fee, uint256 out) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(pad) && logs[i].topics[0] == topic) {
                (amount, fee,, out,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                return (amount, fee, out);
            }
        }
        revert("no pad event");
    }

    /// @dev previewBuy, then the same buy through the listed aggregator: tokens, refund to the trader, fee and the
    ///      aggregator's spend must all be the preview's.
    function _checkBuy(address t, address who, uint256 quoteIn) internal {
        (uint256 eOut, uint256 eSpent, uint256 eFee, uint256 eRefund) = reg.previewBuy(t, who, quoteIn);
        assertEq(eSpent + eRefund, quoteIn, "spent + refund = quoteIn");
        uint256 tokBefore = IERC20(t).balanceOf(who);
        uint256 quoteBefore = wbnb.balanceOf(who);
        uint256 aggBefore = wbnb.balanceOf(address(agg));

        vm.recordLogs();
        vm.prank(who, who);
        uint256 out = agg.buy(t, quoteIn);
        (, uint256 fee,) = _padEvent(BUY_TOPIC);

        assertEq(out, eOut, "tokensOut");
        assertEq(IERC20(t).balanceOf(who) - tokBefore, eOut, "tokens to the trader");
        assertEq(wbnb.balanceOf(who) - quoteBefore, eRefund, "refund to the trader");
        assertEq(aggBefore - wbnb.balanceOf(address(agg)), quoteIn, "aggregator paid quoteIn");
        assertEq(fee, eFee, "fee");
    }

    function _checkSell(address t, address who, uint256 tokensIn) internal {
        (uint256 eOut, uint256 eFee) = reg.previewSell(t, who, tokensIn);
        uint256 aggBefore = wbnb.balanceOf(address(agg));
        vm.prank(who);
        IERC20(t).approve(address(agg), tokensIn);

        vm.recordLogs();
        vm.prank(who, who);
        uint256 out = agg.sell(t, tokensIn);
        (, uint256 fee,) = _padEvent(SELL_TOPIC);

        assertEq(out, eOut, "quoteOut");
        assertEq(wbnb.balanceOf(address(agg)) - aggBefore, eOut, "paid to the aggregator");
        assertEq(fee, eFee, "fee");
    }

    // ================================================================ deploy
    function test_deploy_checkPasses_andIsLocked() public {
        address[] memory pads = new address[](1);
        pads[0] = address(pad);
        G.check(stack, owner, pads);
        assertEq(reg.owner(), owner);
        assertEq(ProxyAdmin(stack.proxyAdmin).owner(), owner);
        assertEq(reg.pads(), pads);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        reg.initialize(address(this), pads);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        GangPadRegistry(stack.impl).initialize(address(this), pads);
    }

    function test_deploy_refusesBadInitialPads() public {
        address[] memory pads = new address[](2);
        pads[0] = address(pad);
        pads[1] = address(pad);
        address impl = address(new GangPadRegistry());
        vm.expectRevert(IGangPadRegistry.AlreadyPad.selector);
        new TransparentUpgradeableProxy(impl, owner, abi.encodeCall(GangPadRegistry.initialize, (owner, pads)));

        pads = new address[](0);
        vm.expectRevert(IGangPadRegistry.ZeroAddress.selector);
        new TransparentUpgradeableProxy(impl, owner, abi.encodeCall(GangPadRegistry.initialize, (address(0), pads)));
    }

    // ================================================================ discovery
    function test_padOf_bothKinds() public {
        address c = _v3();
        address f = _createFair(creator, address(0), 1);
        assertEq(reg.padOf(c), address(pad));
        assertEq(reg.padOf(f), address(pad));
        (address p, uint8 k) = reg.lookup(c);
        assertEq(p, address(pad));
        assertEq(k, KIND_CURVE);
        (p, k) = reg.lookup(f);
        assertEq(p, address(pad));
        assertEq(k, KIND_FAIR);
    }

    /// @dev Still the pad's after graduation: the aggregator then reads `curves(token).pair` and trades the pool.
    function test_padOf_graduatedStaysThePads() public {
        address c = _v3();
        _graduate(c);
        assertEq(reg.padOf(c), address(pad));
    }

    function test_padOf_lookAlikesReadZero() public {
        // a look-alike pointing at the real pad: the pad does not list it
        assertEq(reg.padOf(address(new FakeGangToken(address(pad)))), address(0));
        // pointing at an unregistered contract that does list it
        NextPad next = new NextPad(1_066_666_666_666_666_666_666_666_667, 100);
        FakeGangToken fake = new FakeGangToken(address(next));
        next.list(address(fake), 1);
        assertEq(reg.padOf(address(fake)), address(0));
        (address p, uint8 k) = reg.lookup(address(fake));
        assertEq(p, address(0));
        assertEq(k, 0);
        // the pad itself, an EOA, the zero address, WBNB
        assertEq(reg.padOf(address(pad)), address(0));
        assertEq(reg.padOf(human), address(0));
        assertEq(reg.padOf(address(0)), address(0));
        assertEq(reg.padOf(address(wbnb)), address(0));
    }

    function test_padOf_hostileTokensCannotBreakIt() public {
        assertEq(reg.padOf(address(new RevertingToken())), address(0));
        assertEq(reg.padOf(address(new OddReturnToken(address(pad), false))), address(0), "not an address");
        assertEq(reg.padOf(address(new OddReturnToken(address(pad), true))), address(0), "bomb: pad does not list it");

        // the bomb really completes under the cap: once a registered pad lists it, its first word resolves
        NextPad next = new NextPad(1_066_666_666_666_666_666_666_666_667, 100);
        vm.prank(owner);
        reg.addPad(address(next));
        OddReturnToken bomb = new OddReturnToken(address(next), true);
        next.list(address(bomb), 1);
        assertEq(reg.padOf(address(bomb)), address(next), "bomb: first word only");

        GasBurningToken burner = new GasBurningToken();
        uint256 g = gasleft();
        assertEq(reg.padOf(address(burner)), address(0));
        assertLt(g - gasleft(), 30_000, "gas capped");
    }

    // ================================================================ registration
    function test_addPad_onlyOwner_appendOnly() public {
        NextPad next = new NextPad(1_066_666_666_666_666_666_666_666_667, 100);
        FakeGangToken tok = new FakeGangToken(address(next));
        next.list(address(tok), 1);

        vm.prank(stranger);
        vm.expectRevert(IGangPadRegistry.OnlyOwner.selector);
        reg.addPad(address(next));
        vm.prank(address(pad)); // not even the pad itself
        vm.expectRevert(IGangPadRegistry.OnlyOwner.selector);
        reg.addPad(address(next));

        vm.expectEmit(true, false, false, true, address(reg));
        emit IGangPadRegistry.PadAdded(address(next), 1);
        vm.prank(owner);
        reg.addPad(address(next));

        assertTrue(reg.isPad(address(next)));
        assertEq(reg.padCount(), 2);
        assertEq(reg.padAt(1), address(next));
        assertEq(reg.padOf(address(tok)), address(next), "a new generation's token resolves");
        assertEq(reg.padOf(_v3()), address(pad), "the old pad's tokens still resolve to it");
    }

    function test_addPad_refusals() public {
        vm.startPrank(owner);
        vm.expectRevert(IGangPadRegistry.AlreadyPad.selector);
        reg.addPad(address(pad));
        vm.expectRevert(IGangPadRegistry.ZeroAddress.selector);
        reg.addPad(address(0));
        vm.expectRevert(IGangPadRegistry.NotAContract.selector);
        reg.addPad(human);
        address otherMath = address(new NextPad(2_000_000_000 ether, 100));
        vm.expectRevert(IGangPadRegistry.CurveMathMismatch.selector);
        reg.addPad(otherMath);
        address otherFee = address(new NextPad(1_066_666_666_666_666_666_666_666_667, 50));
        vm.expectRevert(IGangPadRegistry.CurveMathMismatch.selector);
        reg.addPad(otherFee);
        vm.stopPrank();
    }

    function test_ownership_twoStep() public {
        address next = makeAddr("nextOwner");
        vm.prank(stranger);
        vm.expectRevert(IGangPadRegistry.OnlyOwner.selector);
        reg.transferOwnership(stranger);
        vm.prank(owner);
        reg.transferOwnership(next);
        assertEq(reg.owner(), owner);
        assertEq(reg.pendingOwner(), next);

        vm.expectRevert(IGangPadRegistry.NotPendingOwner.selector);
        reg.acceptOwnership();
        vm.prank(next);
        reg.acceptOwnership();
        assertEq(reg.owner(), next);
        assertEq(reg.pendingOwner(), address(0));
    }

    // ================================================================ previewBuy
    function test_previewBuy_matchesBuyFor() public {
        address t = _v3();
        _checkBuy(t, trader, 0.01 ether);
        _checkBuy(t, _newAgent(), 1 wei);
        _checkBuy(t, _newAgent(), 0.0337 ether);
    }

    function test_previewBuy_walletCapCut() public {
        address t = _v3();
        (uint256 out,,, uint256 refund) = reg.previewBuy(t, trader, 1 ether);
        assertEq(out, pad.MAX_PER_WALLET());
        assertGt(refund, 0.9 ether);
        _checkBuy(t, trader, 1 ether);
        // at the cap: the buy would revert WalletCapReached
        (out,,,) = reg.previewBuy(t, trader, 0.01 ether);
        assertEq(out, 0);
    }

    function test_previewBuy_graduationCut_capOff() public {
        vm.prank(owner);
        pad.setWalletCapEnabled(false);
        address t = _v3();
        _checkBuy(t, _newAgent(), 3 ether);
        (,,, uint256 refund) = reg.previewBuy(t, trader, 40 ether);
        assertGt(refund, 0, "graduation cut");
        _checkBuy(t, trader, 40 ether);
        assertTrue(_graduated(t));
        (uint256 out, uint256 spent,,) = reg.previewBuy(t, trader, 1 ether);
        assertEq(out + spent, 0, "graduated: zeros");
    }

    function test_previewBuy_graduationCut_capOn() public {
        address t = _v3();
        for (uint256 i = 0; i < 1_000 && pad.graduationRemaining(t) > 0.3 ether; i++) {
            address w = _newAgent();
            vm.prank(w);
            pad.buy(t, 0.1 ether, 0);
        }
        _checkBuy(t, trader, 1 ether);
        assertTrue(_graduated(t));
    }

    function test_previewBuy_zerosWhereBuyReverts() public {
        address t = _v3();
        address f = _createFair(creator, address(0), 1);
        uint256 a;
        uint256 b;
        (a, b,,) = reg.previewBuy(t, human, 1 ether);
        assertEq(a + b, 0, "gate");
        (a, b,,) = reg.previewBuy(t, trader, 0);
        assertEq(a + b, 0, "zero in");
        (a, b,,) = reg.previewBuy(f, trader, 1 ether);
        assertEq(a + b, 0, "fair token");
        (a, b,,) = reg.previewBuy(address(new FakeGangToken(address(pad))), trader, 1 ether);
        assertEq(a + b, 0, "look-alike");
        (a, b,,) = reg.previewBuy(t, trader, type(uint256).max);
        assertEq(a + b, 0, "past the fee math's range");
        // address(0): a fresh wallet, no gate check
        (a,,,) = reg.previewBuy(t, address(0), 0.01 ether);
        (uint256 c,,,) = reg.previewBuy(t, _newAgent(), 0.01 ether);
        assertEq(a, c);
    }

    function testFuzz_previewBuy_matchesBuyFor(uint256 seed, uint256 quoteIn, bool capOn) public {
        if (!capOn) {
            vm.prank(owner);
            pad.setWalletCapEnabled(false);
        }
        address t = _v3();
        uint256 pre = bound(seed, 0, 6);
        for (uint256 i; i < pre; i++) {
            address w = _newAgent();
            vm.prank(w);
            // ≤ 6 × 1.4 BNB stays under the 9 BNB line (2.0 default): the curve is still live for the buy under test
            pad.buy(t, bound(uint256(keccak256(abi.encode(seed, i))), 1, capOn ? 0.2 ether : 1.4 ether), 0);
        }
        assertFalse(_graduated(t));
        quoteIn = bound(quoteIn, 1, capOn ? 2 ether : 30 ether);
        _checkBuy(t, trader, quoteIn);
    }

    // ================================================================ previewSell
    function test_previewSell_matchesSellFor() public {
        address t = _v3();
        vm.prank(trader);
        pad.buy(t, 0.05 ether, 0);
        uint256 bal = IERC20(t).balanceOf(trader);
        _checkSell(t, trader, bal / 3);
        _checkSell(t, trader, 1);
        _checkSell(t, trader, IERC20(t).balanceOf(trader));
    }

    function test_previewSell_zerosWhereSellReverts() public {
        address t = _v3();
        vm.prank(trader);
        pad.buy(t, 0.05 ether, 0);
        uint256 sold = _curveSold(t);
        uint256 a;
        (a,) = reg.previewSell(t, trader, sold + 1);
        assertEq(a, 0, "more than sold");
        (a,) = reg.previewSell(t, trader, 0);
        assertEq(a, 0, "zero in");
        (a,) = reg.previewSell(t, human, 1 ether);
        assertEq(a, 0, "gate");
        (a,) = reg.previewSell(_createFair(creator, address(0), 1), trader, 1 ether);
        assertEq(a, 0, "fair token");
        (a,) = reg.previewSell(t, address(0), 1 ether);
        assertGt(a, 0, "address(0): no gate check");
    }

    function testFuzz_previewSell_matchesSellFor(uint256 seed, uint256 buyIn, uint256 sellPart) public {
        address t = _v3();
        uint256 pre = bound(seed, 0, 5);
        for (uint256 i; i < pre; i++) {
            address w = _newAgent();
            vm.prank(w);
            pad.buy(t, bound(uint256(keccak256(abi.encode(seed, i))), 1, 0.2 ether), 0);
        }
        vm.prank(trader);
        pad.buy(t, bound(buyIn, 1e9, 0.2 ether), 0);
        uint256 bal = IERC20(t).balanceOf(trader);
        _checkSell(t, trader, bound(sellPart, 1, bal));
    }

    // ================================================================ upgrade
    function test_upgrade_onlyOwner_keepsState() public {
        NextPad next = new NextPad(1_066_666_666_666_666_666_666_666_667, 100);
        vm.prank(owner);
        reg.addPad(address(next));
        address c = _v3();

        address impl2 = address(new GangPadRegistry());
        ProxyAdmin admin = ProxyAdmin(stack.proxyAdmin);
        vm.prank(stranger);
        vm.expectRevert();
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(reg)), impl2, "");

        vm.prank(owner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(reg)), impl2, "");
        assertEq(R.implementationOf(address(reg)), impl2);
        assertEq(reg.owner(), owner);
        assertEq(reg.padCount(), 2);
        assertEq(reg.padAt(0), address(pad));
        assertEq(reg.padAt(1), address(next));
        assertEq(reg.padOf(c), address(pad));
    }

    // ================================================================ layout
    function test_layout_v1() public view {
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/out/GangPadRegistry.sol/GangPadRegistry.json"));
        string[5] memory labels = ["owner", "pendingOwner", "_pads", "isPad", "__gap"];
        string[5] memory types = [
            "t_address",
            "t_address",
            "t_array(t_address)dyn_storage",
            "t_mapping(t_address,t_bool)",
            "t_array(t_uint256)46_storage"
        ];
        assertFalse(vm.keyExistsJson(json, ".storageLayout.storage[5]"), "five entries");
        for (uint256 i; i < 5; i++) {
            string memory k = string.concat(".storageLayout.storage[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(json, string.concat(k, ".label")), labels[i]);
            assertEq(vm.parseUint(vm.parseJsonString(json, string.concat(k, ".slot"))), i, labels[i]);
            assertEq(vm.parseJsonUint(json, string.concat(k, ".offset")), 0, labels[i]);
            assertEq(vm.parseJsonString(json, string.concat(k, ".type")), types[i], labels[i]);
        }
    }
}
