// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GangTestnetRefs as T} from "../../config/GangDeployRefs.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {GangPadRegistryDeployLib as G} from "../../script/GangPadRegistryDeployLib.sol";

interface ITestnetAgentId {
    function register() external returns (uint256 id);
    function balanceOf(address owner) external view returns (uint256);
}

/// @dev A listed aggregator reduced to the pad calls: pays buys out of its own balance, keeps what a sell pays it.
contract ForkAggregator {
    IGangPad public immutable pad;

    constructor(IGangPad pad_, address quote) {
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

/// @notice GangPadRegistry against the live BSC testnet pad (set 10): its deployed bytecode and linked libraries, its
///         real tokens and curve state, the real Agent ID registry, WBNB and Pancake (graduation). A registry is
///         deployed on the fork, a test aggregator is listed by the pad owner, and every quote is checked against the
///         real `buyFor` / `sellFor` to the wei. Needs BSC_TESTNET_RPC_URL (skipped without it).
/// @dev The fork is the live head (the public testnet RPC keeps no old state), so each case picks the curves the
///      live state allows and skips when there are none, instead of assuming how far from graduation they are; the
///      pad's gate and wallet cap are switched on in setUp, as the cases need them.
contract PadRegistryTestnetForkTest is Test {
    IGangPad internal constant PAD = IGangPad(0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1);
    bytes32 internal constant BUY_TOPIC = keccak256("Buy(address,address,uint256,uint256,uint256,uint256,uint256)");
    bytes32 internal constant SELL_TOPIC = keccak256("Sell(address,address,uint256,uint256,uint256,uint256,uint256)");

    GangPadRegistry internal reg;
    ForkAggregator internal agg;
    uint256 internal _nonce;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_TESTNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        address[] memory pads = new address[](1);
        pads[0] = address(PAD);
        G.Registry memory r = G.deploy(address(this), pads);
        G.check(r, address(this), pads);
        reg = GangPadRegistry(r.proxy);

        agg = new ForkAggregator(PAD, T.WBNB);
        deal(T.WBNB, address(agg), 10_000 ether);
        // the pad owner lists the aggregator and pins the two switches the cases rely on (buyFor needs the gate on;
        // the cap case needs the cap on), whatever the live testnet has them at
        address padOwner = Ownable(address(PAD)).owner();
        vm.startPrank(padOwner);
        PAD.setRouter(address(agg), true);
        // turning the gate off with setAgentGate(false, 0) also clears the registry: fall back to the testnet one
        address ids = PAD.agentIdRegistry();
        PAD.setAgentGate(true, ids == address(0) ? T.AGENT_ID_REGISTRY : ids);
        PAD.setWalletCapEnabled(true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers
    /// @dev An EOA holding an Agent ID on the pad's own registry. makeAddr keys follow from public labels, so the
    ///      address may already have registered on the live testnet: register only when it has none.
    function _agent() internal returns (address who) {
        who = makeAddr(string.concat("fork-agent-", vm.toString(_nonce++)));
        ITestnetAgentId ids = ITestnetAgentId(PAD.agentIdRegistry());
        if (ids.balanceOf(who) == 0) {
            vm.prank(who);
            ids.register();
        }
        assertTrue(PAD.isAgent(who));
    }

    /// @dev An EOA with no Agent ID (skipping labels someone registered on the live testnet).
    function _stranger() internal returns (address who) {
        for (uint256 i;; i++) {
            who = makeAddr(string.concat("fork-no-agent-", vm.toString(i)));
            if (!PAD.isAgent(who)) return who;
        }
    }

    function _curve(address t) internal view returns (address quote, bool graduated, uint256 sold) {
        (, quote,, sold,,, graduated,,,,,) = PAD.curves(t);
    }

    /// @dev Live WBNB-quoted curve tokens with more than `minRemaining` left to graduation, in pad order. None: the
    ///      case is skipped (the live testnet has nothing left to check it on).
    function _liveWbnbCurves(uint256 minRemaining) internal returns (address[] memory out) {
        uint256 n = PAD.tokenCount();
        out = new address[](n);
        uint256 m;
        for (uint256 i; i < n; i++) {
            address t = PAD.allTokens(i);
            if (PAD.kindOf(t) != 1) continue;
            (address quote, bool graduated,) = _curve(t);
            if (quote == T.WBNB && !graduated && PAD.graduationRemaining(t) > minRemaining) out[m++] = t;
        }
        assembly {
            mstore(out, m)
        }
        if (m == 0) vm.skip(true);
    }

    function _fee(bytes32 topic) internal view returns (uint256 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(PAD) && logs[i].topics[0] == topic) {
                (, fee,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                return fee;
            }
        }
        revert("no pad event");
    }

    function _checkBuy(address t, address who, uint256 quoteIn) internal returns (uint256 out) {
        (uint256 eOut, uint256 eSpent, uint256 eFee, uint256 eRefund) = reg.previewBuy(t, who, quoteIn);
        assertGt(eOut, 0, "live");
        assertEq(eSpent + eRefund, quoteIn);
        uint256 tokBefore = IERC20(t).balanceOf(who);
        uint256 quoteBefore = IERC20(T.WBNB).balanceOf(who);
        uint256 aggBefore = IERC20(T.WBNB).balanceOf(address(agg));

        vm.recordLogs();
        vm.prank(who, who);
        out = agg.buy(t, quoteIn);

        assertEq(out, eOut, "tokensOut");
        assertEq(IERC20(t).balanceOf(who) - tokBefore, eOut, "tokens to the trader");
        assertEq(IERC20(T.WBNB).balanceOf(who) - quoteBefore, eRefund, "refund to the trader");
        assertEq(aggBefore - IERC20(T.WBNB).balanceOf(address(agg)), quoteIn, "aggregator paid quoteIn");
        assertEq(_fee(BUY_TOPIC), eFee, "fee");
    }

    function _checkSell(address t, address who, uint256 tokensIn) internal {
        (uint256 eOut, uint256 eFee) = reg.previewSell(t, who, tokensIn);
        assertGt(eOut, 0, "live");
        uint256 aggBefore = IERC20(T.WBNB).balanceOf(address(agg));
        vm.prank(who);
        IERC20(t).approve(address(agg), tokensIn);

        vm.recordLogs();
        vm.prank(who, who);
        uint256 out = agg.sell(t, tokensIn);

        assertEq(out, eOut, "quoteOut");
        assertEq(IERC20(T.WBNB).balanceOf(address(agg)) - aggBefore, eOut, "paid to the aggregator");
        assertEq(_fee(SELL_TOPIC), eFee, "fee");
    }

    // ---------------------------------------------------------------- tests
    function test_testnetFork_padOfEveryToken() public view {
        uint256 n = PAD.tokenCount();
        assertGt(n, 0);
        for (uint256 i; i < n; i++) {
            address t = PAD.allTokens(i);
            (address p, uint8 k) = reg.lookup(t);
            assertEq(p, address(PAD), "padOf");
            assertEq(k, PAD.kindOf(t), "kind");
        }
        assertEq(reg.padOf(address(PAD)), address(0));
        assertEq(reg.padOf(T.WBNB), address(0));
    }

    /// @dev Every live WBNB curve: a small buy and sells; where 5 BNB cannot reach graduation, a buy the 1% wallet
    ///      cap cuts (refund to the trader) too.
    function test_testnetFork_quotesMatchEveryLiveCurve() public {
        // 0.0123 BNB can neither graduate these nor leave them graduated before the sells
        address[] memory ts = _liveWbnbCurves(0.1 ether);
        for (uint256 i; i < ts.length; i++) {
            address t = ts[i];
            address a = _agent();
            uint256 small = _checkBuy(t, a, 0.0123 ether);
            _checkSell(t, a, small / 3);

            // 5 BNB (4.95 net) leaves the graduation line out of reach: the cap is what cuts it
            if (PAD.graduationRemaining(t) <= 5 ether) {
                _checkSell(t, a, IERC20(t).balanceOf(a));
                continue;
            }
            address b = _agent();
            (,,, uint256 refund) = reg.previewBuy(t, b, 5 ether);
            assertGt(refund, 0, "cap cut");
            uint256 capped = _checkBuy(t, b, 5 ether);
            assertEq(IERC20(t).balanceOf(b), PAD.MAX_PER_WALLET());
            _checkSell(t, b, capped - 1);
            _checkSell(t, a, IERC20(t).balanceOf(a));
        }
    }

    /// @dev The graduation cut on the real migrator and Pancake testnet: the cap is turned off by the pad owner so one
    ///      buy can cross the line; the quote must still match, and the token then quotes zero.
    function test_testnetFork_graduationCut() public {
        address[] memory ts = _liveWbnbCurves(0);
        address t = ts[ts.length - 1];
        vm.prank(Ownable(address(PAD)).owner());
        PAD.setWalletCapEnabled(false);

        address a = _agent();
        (,,, uint256 refund) = reg.previewBuy(t, a, 100 ether);
        assertGt(refund, 0, "graduation cut");
        _checkBuy(t, a, 100 ether);
        (, bool graduated,) = _curve(t);
        assertTrue(graduated, "graduated");
        (uint256 out, uint256 spent,,) = reg.previewBuy(t, a, 1 ether);
        assertEq(out + spent, 0, "graduated: zeros");
        assertEq(reg.padOf(t), address(PAD), "still the pad's");
    }

    function test_testnetFork_gateAndOtherKinds() public {
        address[] memory ts = _liveWbnbCurves(0);
        (uint256 out,,,) = reg.previewBuy(ts[0], _stranger(), 0.01 ether);
        assertEq(out, 0, "gate");
        uint256 n = PAD.tokenCount();
        for (uint256 i; i < n; i++) {
            address t = PAD.allTokens(i);
            if (PAD.kindOf(t) == 2) {
                (out,,,) = reg.previewBuy(t, address(0), 0.01 ether);
                assertEq(out, 0, "fair token");
            }
        }
    }
}
