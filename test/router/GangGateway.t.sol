// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {GangFixture} from "../utils/GangFixture.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {GangGateway} from "../../src/router/GangGateway.sol";
import {IGangGateway} from "../../src/router/interfaces/IGangGateway.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangPadRegistryDeployLib as RG} from "../../script/GangPadRegistryDeployLib.sol";
import {GangGatewayDeployLib as G} from "../../script/GangGatewayDeployLib.sol";

/// @dev An aggregator's adapter as they write it for four.meme: anyone calls it, it names its caller as the trader,
///      pays buys out of what the caller sent and charges a router fee on sells.
contract GatewayAdapter {
    IGangGateway public immutable gw;
    address public immutable feeTo;
    uint256 public constant FEE_RATE = 100; // 1%

    constructor(IGangGateway gw_, address feeTo_) {
        gw = gw_;
        feeTo = feeTo_;
    }

    function buyBnb(address token, uint256 minAmount) external payable returns (uint256 out, uint256 used) {
        return gw.buyTokenAMAP{value: msg.value}(token, msg.sender, msg.value, minAmount);
    }

    /// @dev ERC-20 quote: pulled from the caller into the adapter, then approved to the gateway.
    function buyErc20(address token, address quote, uint256 funds) external returns (uint256 out, uint256 used) {
        IERC20(quote).transferFrom(msg.sender, address(this), funds);
        IERC20(quote).approve(address(gw), funds);
        return gw.buyTokenAMAP(token, msg.sender, funds, 0);
    }

    /// @dev Buys for someone other than its caller (never works: the pad wants tx.origin).
    function buyBnbFor(address token, address to) external payable {
        gw.buyTokenAMAP{value: msg.value}(token, to, msg.value, 0);
    }

    function sell(address token, uint256 amount, uint256 minFunds) external returns (uint256) {
        return gw.sellToken(0, token, msg.sender, amount, minFunds, FEE_RATE, feeTo);
    }
}

/// @dev What a phishing contract can do with the open sell path: sell its caller's approved curve tokens and take
///      the maximum router fee (the accepted four.meme model, AUDIT-BRIEF §25).
contract GatewayPhisher {
    IGangGateway public immutable gw;

    constructor(IGangGateway gw_) {
        gw = gw_;
    }

    function claimAirdrop(address token) external {
        gw.sellToken(0, token, tx.origin, IERC20(token).balanceOf(tx.origin), 0, 500, address(this));
    }

    receive() external payable {}
}

/// @dev Takes the router fee in BNB and tries to re-enter the gateway with it.
contract ReenteringFeeTaker {
    IGangGateway public immutable gw;
    address public token;

    constructor(IGangGateway gw_) {
        gw = gw_;
    }

    function setToken(address t) external {
        token = t;
    }

    receive() external payable {
        gw.buyTokenAMAP{value: msg.value}(token, tx.origin, msg.value, 0);
    }
}

/// @dev A pad the registry was made to return (a compromised registry): claims a huge fill, moves nothing.
contract LyingPad {
    uint256 public constant VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667;
    uint256 public constant PROTOCOL_FEE_BPS = 100;
    address public immutable wbnb;
    mapping(address => uint8) public kindOf;

    constructor(address wbnb_) {
        wbnb = wbnb_;
    }

    function list(address token) external {
        kindOf[token] = 1;
    }

    function curves(address)
        external
        view
        returns (address, address, uint128, uint128, uint128, uint128, bool, uint16, uint16, uint16, address, address)
    {
        return (address(this), wbnb, 0, 0, 0, 0, false, 0, 0, 0, address(0), address(0));
    }

    function buyFor(address, address, uint256 quoteIn, uint256) external returns (uint256) {
        IERC20(wbnb).transferFrom(msg.sender, address(this), quoteIn);
        return 1e30;
    }
}

/// @dev A Gang-looking token whose launchpad() is whatever it is told.
contract PointingToken is ERC20("Fake", "FAKE") {
    address public launchpad;

    constructor(address pad_) {
        launchpad = pad_;
    }
}

contract LookAlikeToken {
    address public launchpad;

    constructor(address pad_) {
        launchpad = pad_;
    }
}

/// @notice GangGateway as it will be deployed (proxy behind a 48 h timelock run by `owner`, reading GangPadRegistry,
///         listed on the pad): four.meme-shaped quotes and trades for any caller, every trade bound to tx.origin by the
///         pad, the pad's rules (gate, wallet cap, graduation) unchanged, proceeds and refunds to the user only.
contract GangGatewayTest is GangFixture {
    GangPadRegistry internal reg;
    GangGateway internal gw;
    G.Gateway internal stack;
    GatewayAdapter internal adapter;
    address internal creator;
    address internal alice;
    address internal bob;
    address internal human = makeAddr("human"); // no Agent ID
    address internal feeTo = makeAddr("feeTo");

    function setUp() public {
        _deployGang(makeAddr("keeper"));
        address[] memory pads = new address[](1);
        pads[0] = address(pad);
        reg = GangPadRegistry(RG.deploy(owner, pads).proxy);
        stack = G.deploy(address(reg), address(wbnb), owner, R.MAINNET_MIN_DELAY);
        gw = GangGateway(payable(stack.proxy));
        vm.prank(owner);
        pad.setRouter(address(gw), true);
        adapter = new GatewayAdapter(IGangGateway(address(gw)), feeTo);

        creator = _newAgent();
        alice = _newAgent();
        bob = _newAgent();
        vm.deal(human, 10 ether);
    }

    // ---------------------------------------------------------------- helpers
    function _v3() internal returns (address) {
        return _createV3(creator, address(0), _tax(0, 0, 0, address(0)));
    }

    function _v3Erc20() internal returns (address) {
        return _createV3(creator, address(quoteTok), _tax(0, 0, 0, address(0)));
    }

    /// @dev `who` buys `bnb` worth on the curve through the gateway (as the EOA itself).
    function _buy(address who, address t, uint256 bnb) internal returns (uint256 out) {
        vm.prank(who, who);
        (out,) = gw.buyTokenAMAP{value: bnb}(t, who, bnb, 0);
    }

    function _approveGw(address who, address t) internal {
        vm.prank(who);
        IERC20(t).approve(address(gw), type(uint256).max);
    }

    function _assertGatewayEmpty(address t) internal view {
        assertEq(address(gw).balance, 0, "gateway BNB");
        assertEq(wbnb.balanceOf(address(gw)), 0, "gateway WBNB");
        assertEq(quoteTok.balanceOf(address(gw)), 0, "gateway quoteTok");
        assertEq(IERC20(t).balanceOf(address(gw)), 0, "gateway token");
        assertEq(wbnb.allowance(address(gw), address(pad)), 0, "gateway WBNB approval");
        assertEq(quoteTok.allowance(address(gw), address(pad)), 0, "gateway quoteTok approval");
    }

    // ---------------------------------------------------------------- deployment
    function test_deploy_selfCheckPasses() public view {
        G.check(
            stack,
            G.Expect({
                registry: address(reg),
                wbnb: address(wbnb),
                safe: owner,
                deployer: address(this),
                minDelay: R.MAINNET_MIN_DELAY,
                mainnet: false
            })
        );
        assertEq(address(gw.registry()), address(reg));
        assertEq(gw.wbnb(), address(wbnb));
        assertEq(gw.MAX_FEE_RATE(), 500);
        assertEq(gw.PROTOCOL_FEE_BPS(), 100);
    }

    function test_deploy_implAndProxyCannotBeInitializedAgain() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        GangGateway(payable(stack.impl)).initialize(address(reg), address(wbnb));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        gw.initialize(address(reg), address(wbnb));
    }

    function test_deploy_zeroAddressesRefused() public {
        address impl = address(new GangGateway());
        vm.expectRevert(IGangGateway.NotDeployed.selector);
        new TransparentUpgradeableProxy(
            impl, owner, abi.encodeCall(GangGateway.initialize, (address(0), address(wbnb)))
        );
        vm.expectRevert(IGangGateway.NotDeployed.selector);
        new TransparentUpgradeableProxy(impl, owner, abi.encodeCall(GangGateway.initialize, (address(reg), address(0))));
    }

    /// @dev Upgrades only through the timelock: the Safe itself cannot call the ProxyAdmin, the timelock waits 48 h.
    function test_upgrade_onlyThroughTimelock() public {
        GangGateway next = new GangGateway();
        bytes memory call = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(address(gw)), address(next), bytes(""))
        );
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        ProxyAdmin(stack.proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(address(gw)), address(next), "");

        (bool ok,) = stack.timelock
            .call(
                abi.encodeWithSignature(
                    "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                    stack.proxyAdmin,
                    0,
                    call,
                    bytes32(0),
                    bytes32(0),
                    R.MAINNET_MIN_DELAY
                )
            );
        assertFalse(ok, "only the Safe proposes");
        vm.prank(owner);
        (ok,) = stack.timelock
            .call(
                abi.encodeWithSignature(
                    "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                    stack.proxyAdmin,
                    0,
                    call,
                    bytes32(0),
                    bytes32(0),
                    R.MAINNET_MIN_DELAY
                )
            );
        assertTrue(ok, "scheduled");
        bytes memory exec = abi.encodeWithSignature(
            "execute(address,uint256,bytes,bytes32,bytes32)", stack.proxyAdmin, 0, call, bytes32(0), bytes32(0)
        );
        vm.prank(owner);
        (ok,) = stack.timelock.call(exec);
        assertFalse(ok, "not before 48 h");
        vm.warp(block.timestamp + R.MAINNET_MIN_DELAY);
        vm.prank(owner);
        (ok,) = stack.timelock.call(exec);
        assertTrue(ok, "executed after 48 h");
        assertEq(R.implementationOf(address(gw)), address(next));
        assertEq(address(gw.registry()), address(reg), "state kept");
    }

    // ---------------------------------------------------------------- getTokenInfo
    function test_info_curveBnb() public {
        address t = _v3();
        (uint8 status, address quote, address pair, uint256 feeBps, uint256 left) = gw.getTokenInfo(t);
        assertEq(status, 1);
        assertEq(quote, address(0), "WBNB reads as BNB");
        assertEq(pair, address(0));
        assertEq(feeBps, 100);
        assertEq(left, pad.graduationRemaining(t));
        assertGt(left, 0);
        _buy(alice, t, 0.01 ether);
        (,,,, uint256 left2) = gw.getTokenInfo(t);
        assertEq(left2, pad.graduationRemaining(t));
        assertLt(left2, left);
    }

    function test_info_curveErc20AndGraduated() public {
        address t = _v3Erc20();
        (uint8 status, address quote,,,) = gw.getTokenInfo(t);
        assertEq(status, 1);
        assertEq(quote, address(quoteTok));

        address u = _v3();
        _graduate(u);
        address pair;
        uint256 left;
        (status, quote, pair,, left) = gw.getTokenInfo(u);
        assertEq(status, 2);
        assertEq(quote, address(0));
        assertEq(pair, _curvePair(u));
        assertTrue(pair != address(0));
        assertEq(left, 0);
        (,,, uint256 feeBps,) = gw.getTokenInfo(u);
        assertEq(feeBps, 0, "no pad fee on the pool");
    }

    function test_info_fairMintingThenLaunched() public {
        address t = _createFair(creator, address(0), 1);
        (uint8 status, address quote, address pair,, uint256 left) = gw.getTokenInfo(t);
        assertEq(status, 3);
        assertEq(quote, address(0));
        assertEq(pair, address(0));
        assertEq(left, 0);
        _fill(t);
        (status,, pair,,) = gw.getTokenInfo(t);
        assertEq(status, 2);
        assertEq(pair, _salePair(t));
    }

    function test_info_notGang() public {
        address t = _v3();
        address[3] memory others = [address(quoteTok), address(new LookAlikeToken(address(pad))), makeAddr("eoa")];
        for (uint256 i; i < others.length; i++) {
            (uint8 status, address quote, address pair, uint256 feeBps, uint256 left) = gw.getTokenInfo(others[i]);
            assertEq(status, 0);
            assertEq(quote, address(0));
            assertEq(pair, address(0));
            assertEq(feeBps, 0, "no fee for a non-curve token");
            assertEq(left, 0);
        }
        // the real one next to them
        (uint8 s,,,,) = gw.getTokenInfo(t);
        assertEq(s, 1);
    }

    // ---------------------------------------------------------------- buy
    function test_buy_bnbDirect_matchesTryBuy() public {
        address t = _v3();
        (
            address tm,
            address quote,
            uint256 estAmount,
            uint256 estCost,
            uint256 estFee,
            uint256 msgValue,
            uint256 approval,
            uint256 amountFunds
        ) = gw.tryBuy(t, alice, 0, 0.01 ether);
        assertEq(tm, address(gw));
        assertEq(quote, address(0));
        assertEq(estCost, 0.01 ether);
        assertEq(estFee, 0.0001 ether);
        assertEq(msgValue, 0.01 ether);
        assertEq(approval, 0);
        assertEq(amountFunds, 0.01 ether);

        uint256 bnbBefore = alice.balance;
        vm.expectEmit(address(gw));
        emit IGangGateway.GatewayBuy(t, alice, alice, 0.01 ether, estAmount);
        vm.prank(alice, alice);
        (uint256 out, uint256 used) = gw.buyTokenAMAP{value: 0.01 ether}(t, alice, 0.01 ether, estAmount);
        assertEq(out, estAmount);
        assertEq(used, 0.01 ether);
        assertEq(IERC20(t).balanceOf(alice), out);
        assertEq(bnbBefore - alice.balance, 0.01 ether);
        _assertGatewayEmpty(t);
    }

    /// @dev An aggregator contract in between: the trader is still the EOA that sent the tx.
    function test_buy_viaAdapter() public {
        address t = _v3();
        vm.prank(alice, alice);
        (uint256 out,) = adapter.buyBnb{value: 0.01 ether}(t, 0);
        assertGt(out, 0);
        assertEq(IERC20(t).balanceOf(alice), out);
        assertEq(IERC20(t).balanceOf(address(adapter)), 0);
        _assertGatewayEmpty(t);
    }

    function test_buy_erc20ViaAdapter() public {
        address t = _v3Erc20();
        (,, uint256 est,,,, uint256 approval,) = gw.tryBuy(t, alice, 0, 0.01 ether);
        assertEq(approval, 0.01 ether);
        vm.prank(alice);
        quoteTok.approve(address(adapter), 0.01 ether);
        uint256 before = quoteTok.balanceOf(alice);
        vm.prank(alice, alice);
        (uint256 out, uint256 used) = adapter.buyErc20(t, address(quoteTok), 0.01 ether);
        assertEq(out, est);
        assertEq(used, 0.01 ether);
        assertEq(before - quoteTok.balanceOf(alice), 0.01 ether);
        assertEq(quoteTok.balanceOf(address(adapter)), 0);
        _assertGatewayEmpty(t);
    }

    function test_buy_toMustBeOrigin() public {
        address t = _v3();
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        adapter.buyBnbFor{value: 0.01 ether}(t, bob);
        // the adapter itself is never tx.origin either
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        adapter.buyBnbFor{value: 0.01 ether}(t, address(adapter));
    }

    function test_buy_badMsgValue() public {
        address t = _v3();
        vm.prank(alice, alice);
        vm.expectRevert(IGangGateway.BadMsgValue.selector);
        gw.buyTokenAMAP{value: 0.01 ether}(t, alice, 0.02 ether, 0);
        address u = _v3Erc20();
        vm.prank(alice);
        quoteTok.approve(address(gw), 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangGateway.BadMsgValue.selector);
        gw.buyTokenAMAP{value: 1}(u, alice, 0.01 ether, 0);
    }

    function test_buy_gateAndSlippageAreThePads() public {
        address t = _v3();
        vm.prank(human, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        gw.buyTokenAMAP{value: 0.01 ether}(t, human, 0.01 ether, 0);
        // tryBuy says so too
        (,, uint256 est,,, uint256 mv,,) = gw.tryBuy(t, human, 0, 0.01 ether);
        assertEq(est, 0);
        assertEq(mv, 0);

        (,, uint256 est2,,,,,) = gw.tryBuy(t, alice, 0, 0.01 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.Slippage.selector);
        gw.buyTokenAMAP{value: 0.01 ether}(t, alice, 0.01 ether, est2 + 1);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.ZeroAmount.selector);
        gw.buyTokenAMAP(t, alice, 0, 0);
    }

    /// @dev The 1% wallet cap cuts the buy: the pad refunds the rest to the TRADER in WBNB (§23), the aggregator that
    ///      paid sees it in `fundsUsed`, nothing stays in the gateway; tryBuy predicted all of it.
    function test_buy_walletCapRefundsTraderInWbnb() public {
        address t = _v3();
        (,, uint256 est, uint256 cost, uint256 fee,,, uint256 amountFunds) = gw.tryBuy(t, alice, 0, 1 ether);
        assertEq(est, 10_000_000 ether, "capped at 1%");
        assertLt(cost, 1 ether);
        assertEq(amountFunds, cost);
        assertGt(fee, 0);

        uint256 wBefore = wbnb.balanceOf(alice);
        uint256 bnbBefore = alice.balance;
        vm.prank(alice, alice);
        (uint256 out, uint256 used) = adapter.buyBnb{value: 1 ether}(t, 0);
        assertEq(out, est);
        assertEq(used, cost);
        assertEq(wbnb.balanceOf(alice) - wBefore, 1 ether - cost, "refund in WBNB to the trader");
        assertEq(bnbBefore - alice.balance, 1 ether);
        assertEq(wbnb.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
        _assertGatewayEmpty(t);

        // full now: the next buy reverts in the pad, tryBuy returns zeros
        (,, uint256 none,,,,,) = gw.tryBuy(t, alice, 0, 0.01 ether);
        assertEq(none, 0);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        gw.buyTokenAMAP{value: 0.01 ether}(t, alice, 0.01 ether, 0);
    }

    /// @dev Passing tryBuy's amountFunds buys the same amount with nothing refunded.
    function test_buy_amountFundsAvoidsRefund() public {
        address t = _v3();
        (,, uint256 est,,,,, uint256 amountFunds) = gw.tryBuy(t, alice, 0, 1 ether);
        uint256 wBefore = wbnb.balanceOf(alice);
        vm.prank(alice, alice);
        (uint256 out, uint256 used) = gw.buyTokenAMAP{value: amountFunds}(t, alice, amountFunds, 0);
        assertEq(out, est);
        assertEq(used, amountFunds);
        assertEq(wbnb.balanceOf(alice), wBefore, "no refund");
    }

    /// @dev The buy that crosses the graduation line graduates in the same tx; the cut is refunded to the trader.
    function test_buy_graduatesAndRefunds() public {
        address t = _v3();
        vm.prank(owner);
        pad.setWalletCapEnabled(false);
        uint256 left = pad.graduationRemaining(t);
        (,, uint256 est, uint256 cost,,,,) = gw.tryBuy(t, alice, 0, left * 2);
        uint256 wBefore = wbnb.balanceOf(alice);
        vm.deal(alice, left * 2 + 1 ether);
        vm.prank(alice, alice);
        (uint256 out, uint256 used) = gw.buyTokenAMAP{value: left * 2}(t, alice, left * 2, 0);
        assertEq(out, est);
        assertEq(used, cost);
        assertTrue(_graduated(t));
        assertEq(wbnb.balanceOf(alice) - wBefore, left * 2 - cost);
        _assertGatewayEmpty(t);
        (uint8 status,,,,) = gw.getTokenInfo(t);
        assertEq(status, 2);
        vm.prank(alice, alice);
        vm.expectRevert(IGangGateway.NotCurveToken.selector);
        gw.buyTokenAMAP{value: 0.01 ether}(t, alice, 0.01 ether, 0);
    }

    function test_buy_notCurveToken() public {
        address fair = _createFair(creator, address(0), 1);
        address fake = address(new LookAlikeToken(address(pad)));
        address[3] memory bad = [fair, fake, address(quoteTok)];
        for (uint256 i; i < bad.length; i++) {
            vm.prank(alice, alice);
            vm.expectRevert(IGangGateway.NotCurveToken.selector);
            gw.buyTokenAMAP{value: 0.01 ether}(bad[i], alice, 0.01 ether, 0);
            vm.prank(alice, alice);
            vm.expectRevert(IGangGateway.NotCurveToken.selector);
            gw.sellToken(0, bad[i], alice, 1, 0, 0, address(0));
            (,, uint256 est,,,,,) = gw.tryBuy(bad[i], alice, 0, 0.01 ether);
            assertEq(est, 0);
            (,, uint256 funds,) = gw.trySell(bad[i], 1 ether);
            assertEq(funds, 0);
        }
    }

    function test_tryBuy_byAmountNotSupported() public {
        address t = _v3();
        vm.expectRevert(IGangGateway.AmountNotSupported.selector);
        gw.tryBuy(t, alice, 1 ether, 0);
    }

    function test_delisted_onlyRouter() public {
        address t = _v3();
        uint256 got = _buy(alice, t, 0.01 ether);
        _approveGw(alice, t);
        vm.prank(owner);
        pad.setRouter(address(gw), false);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        gw.buyTokenAMAP{value: 0.01 ether}(t, alice, 0.01 ether, 0);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        gw.sellToken(0, t, alice, got, 0, 0, address(0));
        // the quotes say so (audit L-1); getTokenInfo still reports where the token trades
        (,, uint256 est,,, uint256 mv,,) = gw.tryBuy(t, alice, 0, 0.01 ether);
        assertEq(est, 0);
        assertEq(mv, 0);
        (,, uint256 funds,) = gw.trySell(t, got);
        assertEq(funds, 0);
        (uint8 status,,,,) = gw.getTokenInfo(t);
        assertEq(status, 1);
    }

    /// @dev Gate off: the pad's buyFor reverts RouterNeedsGate, so tryBuy quotes nothing; sells still work.
    function test_gateOff_noBuyQuote_sellStillWorks() public {
        address t = _v3();
        uint256 got = _buy(alice, t, 0.01 ether);
        _approveGw(alice, t);
        vm.prank(owner);
        pad.setAgentGate(false, address(agents));
        (,, uint256 est,,,,,) = gw.tryBuy(t, alice, 0, 0.01 ether);
        assertEq(est, 0);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.RouterNeedsGate.selector);
        gw.buyTokenAMAP{value: 0.01 ether}(t, alice, 0.01 ether, 0);
        (,, uint256 funds,) = gw.trySell(t, got);
        assertGt(funds, 0);
        vm.prank(alice, alice);
        assertEq(gw.sellToken(0, t, alice, got, funds, 0, address(0)), funds);
    }

    /// @dev Audit L-2: a pad the registry returns cannot fake a fill — amountOut is `to`'s balance change.
    function test_buy_lyingPadCannotFakeAFill() public {
        LyingPad liar = new LyingPad(address(wbnb));
        vm.prank(owner);
        reg.addPad(address(liar));
        PointingToken fake = new PointingToken(address(liar));
        liar.list(address(fake));
        (uint8 status,,,,) = gw.getTokenInfo(address(fake));
        assertEq(status, 1, "the registry vouches for it");
        vm.prank(alice, alice);
        vm.expectRevert(IGangGateway.Slippage.selector);
        gw.buyTokenAMAP{value: 0.01 ether}(address(fake), alice, 0.01 ether, 1);
        vm.prank(alice, alice);
        (uint256 out,) = gw.buyTokenAMAP{value: 0.01 ether}(address(fake), alice, 0.01 ether, 0);
        assertEq(out, 0, "not the 1e30 the pad claimed");
    }

    // ---------------------------------------------------------------- sell
    /// @dev Through an aggregator adapter with a 1% router fee: tokens from the seller straight into the pad (allowance
    ///      to the gateway spent), BNB to the seller and to the fee recipient, nothing kept anywhere in between.
    function test_sell_bnbViaAdapter_feeSplit() public {
        address t = _v3();
        uint256 got = _buy(alice, t, 0.02 ether);
        _approveGw(alice, t);
        uint256 amount = got / 2;
        (address tm, address quote, uint256 funds, uint256 padFee) = gw.trySell(t, amount);
        assertEq(tm, address(gw));
        assertEq(quote, address(0));
        uint256 routerFee = (funds * 100) / 10_000;

        uint256 bnbBefore = alice.balance;
        uint256 padTokens = IERC20(t).balanceOf(address(pad));
        vm.expectEmit(address(gw));
        emit IGangGateway.GatewaySell(t, alice, address(adapter), amount, funds, funds - routerFee, routerFee, feeTo);
        vm.prank(alice, alice);
        uint256 toSeller = adapter.sell(t, amount, funds - routerFee);
        assertEq(toSeller, funds - routerFee);
        assertEq(alice.balance - bnbBefore, toSeller, "BNB to the seller");
        assertEq(feeTo.balance, routerFee, "BNB fee");
        assertEq(IERC20(t).balanceOf(alice), got - amount);
        assertEq(IERC20(t).balanceOf(address(pad)) - padTokens, amount, "tokens straight into the pad");
        assertEq(IERC20(t).allowance(alice, address(gw)), type(uint256).max, "infinite allowance stays");
        assertGt(padFee, 0);
        assertEq(address(adapter).balance, 0);
        _assertGatewayEmpty(t);
    }

    function test_sell_direct_noFee_exactAllowance() public {
        address t = _v3();
        uint256 got = _buy(alice, t, 0.01 ether);
        vm.prank(alice);
        IERC20(t).approve(address(gw), got);
        (,, uint256 funds,) = gw.trySell(t, got);
        uint256 bnbBefore = alice.balance;
        vm.prank(alice, alice);
        uint256 toSeller = gw.sellToken(0, t, alice, got, funds, 0, address(0));
        assertEq(toSeller, funds);
        assertEq(alice.balance - bnbBefore, funds);
        assertEq(IERC20(t).allowance(alice, address(gw)), 0, "allowance spent");
        assertEq(IERC20(t).balanceOf(alice), 0);
        _assertGatewayEmpty(t);
    }

    function test_sell_erc20Quote() public {
        address t = _v3Erc20();
        vm.prank(alice);
        quoteTok.approve(address(gw), type(uint256).max);
        vm.prank(alice, alice);
        (uint256 got,) = gw.buyTokenAMAP(t, alice, 0.02 ether, 0);
        _approveGw(alice, t);
        (, address quote, uint256 funds,) = gw.trySell(t, got);
        assertEq(quote, address(quoteTok));
        uint256 before = quoteTok.balanceOf(alice);
        uint256 routerFee = (funds * 100) / 10_000;
        vm.prank(alice, alice);
        uint256 toSeller = adapter.sell(t, got, 0);
        assertEq(toSeller, funds - routerFee);
        assertEq(quoteTok.balanceOf(alice) - before, toSeller);
        assertEq(quoteTok.balanceOf(feeTo), routerFee);
        _assertGatewayEmpty(t);
    }

    /// @dev minFunds is what the seller ends up with: after the pad's fee AND the router fee.
    function test_sell_minFundsIsNet() public {
        address t = _v3();
        uint256 got = _buy(alice, t, 0.01 ether);
        _approveGw(alice, t);
        (,, uint256 funds,) = gw.trySell(t, got);
        uint256 net = funds - (funds * 100) / 10_000;
        vm.prank(alice, alice);
        vm.expectRevert(IGangGateway.Slippage.selector);
        adapter.sell(t, got, net + 1);
        vm.prank(alice, alice);
        assertEq(adapter.sell(t, got, net), net);
    }

    function test_sell_padAllowanceDoesNotCount() public {
        address t = _v3();
        uint256 got = _buy(alice, t, 0.01 ether);
        vm.prank(alice);
        IERC20(t).approve(address(pad), type(uint256).max);
        vm.prank(alice, alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(gw), 0, got));
        gw.sellToken(0, t, alice, got, 0, 0, address(0));
    }

    /// @dev A standing allowance to the gateway is usable only in the seller's own tx.
    function test_sell_fromMustBeOrigin() public {
        address t = _v3();
        uint256 got = _buy(alice, t, 0.01 ether);
        _approveGw(alice, t);
        vm.prank(bob, bob);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        gw.sellToken(0, t, alice, got, 0, 500, bob);
        // through an adapter in bob's tx the adapter names bob, not alice: alice's tokens are out of reach
        vm.prank(bob, bob);
        vm.expectRevert();
        adapter.sell(t, got, 0);
        assertEq(IERC20(t).balanceOf(alice), got);
    }

    function test_sell_feeChecks() public {
        address t = _v3();
        uint256 got = _buy(alice, t, 0.01 ether);
        _approveGw(alice, t);
        vm.prank(alice, alice);
        vm.expectRevert(IGangGateway.FeeRateTooHigh.selector);
        gw.sellToken(0, t, alice, got, 0, 501, feeTo);
        vm.prank(alice, alice);
        vm.expectRevert(IGangGateway.ZeroFeeRecipient.selector);
        gw.sellToken(0, t, alice, got, 0, 100, address(0));
        // the 5% cap itself is fine
        vm.prank(alice, alice);
        gw.sellToken(0, t, alice, got, 0, 500, feeTo);
        assertGt(feeTo.balance, 0);
    }

    /// @dev The Agent gate is checked on the seller by the pad (here: the gate moved to a registry alice is not in).
    function test_sell_gateIsThePads() public {
        address t = _v3();
        uint256 got = _buy(alice, t, 0.01 ether);
        _approveGw(alice, t);
        MockAgentId other = new MockAgentId();
        vm.prank(owner);
        pad.setAgentGate(true, address(other));
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        gw.sellToken(0, t, alice, got, 0, 0, address(0));
    }

    function test_sell_graduatedIsNotCurve() public {
        address t = _v3();
        uint256 got = _buy(alice, t, 0.01 ether);
        _approveGw(alice, t);
        _graduate(t);
        vm.prank(alice, alice);
        vm.expectRevert(IGangGateway.NotCurveToken.selector);
        gw.sellToken(0, t, alice, got, 0, 0, address(0));
        (,, uint256 funds,) = gw.trySell(t, got);
        assertEq(funds, 0);
    }

    /// @dev The accepted residual risk (four.meme's model, AUDIT-BRIEF §25): a contract the user is tricked into
    ///      calling sells the user's approved curve tokens in the user's own tx. The proceeds still go to the user;
    ///      the phisher keeps at most the 5% router fee.
    function test_phishing_openSellKeepsProceedsWithUser() public {
        address t = _v3();
        uint256 got = _buy(alice, t, 0.01 ether);
        _approveGw(alice, t);
        GatewayPhisher m = new GatewayPhisher(IGangGateway(address(gw)));
        (,, uint256 funds,) = gw.trySell(t, got);
        uint256 bnbBefore = alice.balance;
        vm.prank(alice, alice);
        m.claimAirdrop(t);
        uint256 fee = (funds * 500) / 10_000;
        assertEq(address(m).balance, fee, "phisher: 5% at most");
        assertEq(alice.balance - bnbBefore, funds - fee, "the rest to the user");
        assertEq(IERC20(t).balanceOf(alice), 0);
    }

    /// @dev A BNB fee recipient that re-enters the gateway fails the whole sell.
    function test_sell_reentrantFeeRecipientReverts() public {
        address t = _v3();
        uint256 got = _buy(alice, t, 0.01 ether);
        _approveGw(alice, t);
        ReenteringFeeTaker r = new ReenteringFeeTaker(IGangGateway(address(gw)));
        r.setToken(t);
        vm.prank(alice, alice);
        vm.expectRevert(IGangGateway.BnbTransferFailed.selector);
        gw.sellToken(0, t, alice, got, 0, 100, address(r));
    }

    function test_receive_onlyWbnb() public {
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(gw).call{value: 1}("");
        assertFalse(ok);
        assertEq(bytes4(ret), IGangGateway.OnlyWbnb.selector);
    }

    // ---------------------------------------------------------------- quotes vs trades, to the wei
    function testFuzz_tryBuyMatchesBuy(uint256 funds, uint256 pre) public {
        address t = _v3();
        vm.prank(owner);
        pad.setWalletCapEnabled(pre % 2 == 0);
        pre = bound(pre, 0, 5 ether);
        if (pre > 0) {
            address w = _newAgent();
            vm.deal(w, pre);
            vm.prank(owner);
            pad.setWalletCapEnabled(false);
            _buy(w, t, pre);
            vm.prank(owner);
            pad.setWalletCapEnabled(true);
        }
        if (_graduated(t)) return;
        funds = bound(funds, 1, 30 ether);
        vm.deal(alice, funds);
        (,, uint256 est, uint256 cost,,,,) = gw.tryBuy(t, alice, 0, funds);
        uint256 wBefore = wbnb.balanceOf(alice);
        vm.prank(alice, alice);
        if (est == 0) {
            vm.expectRevert();
            gw.buyTokenAMAP{value: funds}(t, alice, funds, 0);
            return;
        }
        (uint256 out, uint256 used) = gw.buyTokenAMAP{value: funds}(t, alice, funds, 0);
        assertEq(out, est, "amount");
        assertEq(used, cost, "cost");
        assertEq(wbnb.balanceOf(alice) - wBefore, funds - cost, "refund");
        _assertGatewayEmpty(t);
    }

    function testFuzz_trySellMatchesSell(uint256 bnb, uint256 part, uint256 feeRate) public {
        address t = _v3();
        bnb = bound(bnb, 0.001 ether, 0.05 ether);
        uint256 got = _buy(alice, t, bnb);
        _approveGw(alice, t);
        uint256 amount = bound(part, 1, got);
        feeRate = bound(feeRate, 0, 500);
        (,, uint256 funds,) = gw.trySell(t, amount);
        uint256 bnbBefore = alice.balance;
        // dust can sell for 0 (the pad does not refuse it): the quote says 0 too
        vm.prank(alice, alice);
        uint256 toSeller = gw.sellToken(0, t, alice, amount, 0, feeRate, feeTo);
        assertEq(toSeller, funds - (funds * feeRate) / 10_000);
        assertEq(alice.balance - bnbBefore, toSeller);
        _assertGatewayEmpty(t);
    }
}
