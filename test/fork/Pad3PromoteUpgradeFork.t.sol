// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {FlyUpgradeHarness, Pad3LiveUpgrade} from "./Pad3LiveUpgrade.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";

interface IPromoteForkRouter {
    function v3BuyBNB(address token, uint256 minTokensOut, uint256 deadline) external payable returns (uint256);
}

/// @dev Any contract a wallet might call.
contract PromoteForkCaller {
    function buy(address pad, address token, address promoter) external payable {
        Pad3Module(payable(pad)).buyWithPromoter{value: msg.value}(token, msg.value, 0, promoter);
    }
}

/// @notice The promoter share on the LIVE GangLaunchpad 3.0 proxy (BSC mainnet fork): UpgradeGangLaunchpad3 checks this
///         build against the live implementation (simulated upgrade, snapshot of settings and the newest tokens, phase-2
///         read-back), the upgrade runs as the Safe sends it, and then the share runs on real contracts: the live router,
///         fee bucket, dividend vault, migrator and Pancake, in BNB and USDT, through graduation. Agent IDs are mocked
///         unless a test says otherwise. No broadcast. Run each test alone (the script reads process-wide env vars, and
///         a plain node's old state doesn't last long).
/// @dev Needs BSC_RPC_URL (skipped without it) and the live PoolCheck linked:
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract Pad3PromoteUpgradeForkTest is Test {
    address constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address constant ROUTER3 = 0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7;
    address constant PAD_1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    uint256 constant BPS = 10_000;
    uint16 constant SHARE = 2_000;
    uint32 constant WINDOW = 30 days;
    /// @dev small enough that several buys stay under the 1% wallet cap on the 6 BNB tier
    uint256 constant GROSS = 0.002 ether;

    GangLaunchpad3 p = GangLaunchpad3(payable(PAD3));
    Pad3Module pm = Pad3Module(payable(PAD3));
    IERC20 wbnb = IERC20(M.WBNB);
    address creator = makeAddr("promote-fork-creator");
    address wallet = makeAddr("promote-fork-wallet");
    address promoter = makeAddr("promote-fork-promoter");
    address other = makeAddr("promote-fork-other");
    uint256 internal _n;

    /// @dev The script's whole check on the live tokens, then the upgrade as the Safe. False: no RPC, skipped.
    function _upgrade() internal returns (bool) {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        // the view doesn't exist before the upgrade
        (bool ok, bytes memory ret) = PAD3.staticcall(abi.encodeCall(Pad3Module.promoteOf, (p.allTokens(0))));
        assertFalse(ok, "live pad has no promoter share yet");
        assertEq(ret.length, 0);

        uint256 pk = uint256(keccak256("GangLaunchpad 3.0 promoter share fork test: throwaway, never funded"));
        vm.deal(vm.addr(pk), 1 ether);
        _env(pk);
        (FlyUpgradeHarness h, UpgradeGangLaunchpad3.Stack memory st) = Pad3LiveUpgrade.check();
        address impl = Pad3LiveUpgrade.execute(h, st, SAFE);
        assertEq(R.implementationOf(PAD3), impl, "the proxy runs this build");

        (uint16 liveShare,) = pm.promoteOf(p.allTokens(0));
        assertEq(liveShare, 0, "a live token has no terms");
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        vm.deal(wallet, 100 ether);
        vm.deal(other, 100 ether);
        return true;
    }

    function _noTax() internal pure returns (IGangLaunchpad.TaxConfig memory t) {}

    function _create(address quote, address refPool, IGangLaunchpad.TaxConfig memory tax) internal returns (address t) {
        vm.prank(creator);
        t = pm.createWithPromote("Promote", "PROMO", "l", "m", quote, refPool, tax, 6 ether, SHARE, WINDOW);
    }

    function _plain(address quote, address refPool, IGangLaunchpad.TaxConfig memory tax) internal returns (address t) {
        vm.prank(creator);
        t = p.createWithGradTarget("Plain", "PLAIN", "l", "m", quote, refPool, tax, 6 ether);
    }

    function _creatorPart(uint256 gross) internal pure returns (uint256) {
        return (((gross * 100) / BPS) * 7_000) / BPS;
    }

    function _cut(uint256 gross) internal pure returns (uint256) {
        return (_creatorPart(gross) * SHARE) / BPS;
    }

    /// @dev BNB: a share token and a plain one side by side, on the entry; the live bucket's part; both sells; the window;
    ///      a contract refused; both claims.
    function test_fork_promote_bnb() public {
        if (!_upgrade()) return;
        address t = _create(address(0), address(0), _noTax());
        address plain = _plain(address(0), address(0), _noTax());
        assertEq(p.kindOf(t), 1);
        assertEq(p.owner(), SAFE, "the pad's owner stays the Safe");

        PromoteForkCaller c = new PromoteForkCaller();
        vm.prank(wallet, wallet);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        c.buy{value: GROSS}(PAD3, t, promoter);
        assertTrue(pm.canBind(t, wallet, promoter), "a refused contract uses up nothing");

        uint256 bucket0 = wbnb.balanceOf(address(p.platformBucket()));
        vm.prank(wallet, wallet);
        (uint256 o1, uint256 used) = pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);
        uint256 bucketPart = wbnb.balanceOf(address(p.platformBucket())) - bucket0;
        assertEq(used, GROSS);
        assertEq(bucketPart, (GROSS * 100) / BPS - _creatorPart(GROSS), "the platform's 30%");
        vm.prank(other, other);
        (uint256 o2,) = p.buyTokenAMAP{value: GROSS}(plain, other, GROSS, 0);
        assertEq(o1, o2, "same tokens as without a share");
        assertEq(pm.promoterFeeOf(t, promoter), _cut(GROSS));
        assertEq(p.creatorFeeOf(t), _creatorPart(GROSS) - _cut(GROSS));
        assertEq(p.creatorFeeOf(plain), _creatorPart(GROSS));
        (address bound,,) = pm.bindingOf(t, wallet);
        assertEq(bound, promoter);

        // both sells pay
        uint256 part = IERC20(t).balanceOf(wallet) / 4;
        vm.startPrank(wallet, wallet);
        IERC20(t).approve(PAD3, type(uint256).max);
        uint256 owed = pm.promoterFeeOf(t, promoter);
        p.sell(t, part, 0);
        assertGt(pm.promoterFeeOf(t, promoter), owed, "direct sell");
        owed = pm.promoterFeeOf(t, promoter);
        p.sellToken(0, t, wallet, part, 0, 0, address(0));
        assertGt(pm.promoterFeeOf(t, promoter), owed, "entry sell");
        vm.stopPrank();

        // the window's end
        (, uint40 at,) = pm.bindingOf(t, wallet);
        vm.warp(uint256(at) + WINDOW);
        owed = pm.promoterFeeOf(t, promoter);
        uint256 kept = p.creatorFeeOf(t);
        vm.prank(wallet, wallet);
        p.buyTokenAMAP{value: GROSS / 10}(t, wallet, GROSS / 10, 0);
        assertEq(pm.promoterFeeOf(t, promoter), owed, "window over");
        assertEq(p.creatorFeeOf(t) - kept, _creatorPart(GROSS / 10));

        // the claims, in the quote (WBNB)
        vm.prank(promoter);
        uint256 got = pm.claimPromoterFee(t, promoter);
        assertEq(got, owed);
        assertEq(wbnb.balanceOf(promoter), owed);
        uint256 keptNow = p.creatorFeeOf(t);
        vm.prank(creator);
        assertEq(p.claimCreatorFee(t, creator), keptNow);
        assertEq(wbnb.balanceOf(creator), keptNow);
        assertEq(address(p).balance, 0, "no BNB stays on the pad");
    }

    /// @dev The real Agent ID registry, not the mock: a wallet without one can't buy.
    function test_fork_promote_realAgentGate() public {
        if (!_upgrade()) return;
        address t = _create(address(0), address(0), _noTax());
        vm.clearMockedCalls();
        address noId = makeAddr("promote-fork-no-agent-id");
        vm.deal(noId, 1 ether);
        assertFalse(pm.canBind(t, noId, promoter), "wallet without an Agent ID");
        vm.prank(noId, noId);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);
        assertFalse(pm.canBind(t, address(0), promoter), "no wallet: the real registry would revert");
    }

    /// @dev The real registry with real holders (live tokens' creators): a promoter without an Agent ID is ignored and the
    ///      buy goes on; with both holding one, the wallet is bound and the promoter earns.
    function test_fork_promote_realAgentHolders() public {
        if (!_upgrade()) return;
        address t = _create(address(0), address(0), _noTax());
        vm.clearMockedCalls();
        address a;
        address b;
        uint256 n = p.tokenCount();
        for (uint256 i = 1; i < n && b == address(0); i++) {
            (address c,,,,,,,,,,,) = p.curves(p.allTokens(i));
            if (c == address(0) || c == creator || c == a) continue;
            if (IERC721(M.AGENT_ID_REGISTRY).balanceOf(c) == 0) continue;
            if (a == address(0)) a = c;
            else b = c;
        }
        assertTrue(a != address(0) && b != address(0), "two real holders");
        assertFalse(pm.canBind(t, a, promoter), "a promoter without an Agent ID");
        assertTrue(pm.canBind(t, a, b), "both hold one");
        vm.deal(a, 1 ether);
        vm.deal(b, 1 ether);
        vm.prank(b, b);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);
        (address none,, bool traded) = pm.bindingOf(t, b);
        assertEq(none, address(0), "ignored");
        assertTrue(traded, "the buy went on");
        assertGt(IERC20(t).balanceOf(b), 0);
        vm.prank(a, a);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, b);
        (address bound,,) = pm.bindingOf(t, a);
        assertEq(bound, b);
        assertEq(pm.promoterFeeOf(t, b), _cut(GROSS));
    }

    /// @dev A bound wallet's buy through the live GangRouter pays. The router has no sell entry, so `sellFor` is called
    ///      from its address. It can't name a promoter.
    function test_fork_promote_liveRouter() public {
        if (!_upgrade()) return;
        address t = _create(address(0), address(0), _noTax());
        vm.prank(wallet, wallet);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);
        uint256 owed = pm.promoterFeeOf(t, promoter);
        assertTrue(p.routers(ROUTER3), "the live router is listed");

        vm.prank(wallet, wallet);
        IPromoteForkRouter(ROUTER3).v3BuyBNB{value: GROSS}(t, 0, block.timestamp + 60);
        assertEq(pm.promoterFeeOf(t, promoter) - owed, _cut(GROSS), "the router's buy");
        owed = pm.promoterFeeOf(t, promoter);

        vm.prank(wallet);
        IERC20(t).approve(ROUTER3, type(uint256).max);
        uint256 bal = IERC20(t).balanceOf(wallet);
        vm.prank(ROUTER3, wallet);
        p.sellFor(wallet, t, bal / 2, 0);
        assertGt(pm.promoterFeeOf(t, promoter), owed, "sellFor");

        vm.deal(ROUTER3, GROSS);
        vm.prank(ROUTER3, wallet);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);
    }

    /// @dev Into a real Pancake pair: a buy naming a promoter crosses the line; what's owed stays claimable; the buy after
    ///      it is refused.
    function test_fork_promote_graduation() public {
        if (!_upgrade()) return;
        address t = _create(address(0), address(0), _noTax());
        uint256 padBefore = wbnb.balanceOf(PAD3);
        vm.prank(wallet, wallet);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);
        _fillTo(t, 0.05 ether);
        (,,,,,, bool grad0,,,,,) = p.curves(t);
        assertFalse(grad0, "still on the curve");

        // the last buy names a promoter, and graduates
        address last = _agent();
        vm.prank(last, last);
        pm.buyWithPromoter{value: 1 ether}(t, 1 ether, 0, promoter);
        (,,,,,, bool grad,,,, address pair,) = p.curves(t);
        assertTrue(grad, "graduated in the buy");
        assertTrue(pair != address(0), "a real pair");
        assertGt(wbnb.balanceOf(pair), 5 ether, "the raise went to the pair");
        (address bound,,) = pm.bindingOf(t, last);
        assertEq(bound, promoter);
        assertGt(wbnb.balanceOf(last), 0, "the cut came back in WBNB");

        uint256 owed = pm.promoterFeeOf(t, promoter);
        assertGt(owed, _cut(GROSS));
        // only the fees stay, and the graduation cut's known dust (a wei or two)
        uint256 d = wbnb.balanceOf(PAD3) - padBefore - p.creatorFeeOf(t) - owed;
        assertLe(d, 2, "only fees stay");
        address late = _agent();
        assertFalse(pm.canBind(t, late, promoter));
        vm.prank(late, late);
        vm.expectRevert(IGangLaunchpad3.NotCurveToken.selector);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);

        vm.prank(promoter);
        assertEq(pm.claimPromoterFee(t, promoter), owed);
        uint256 kept = p.creatorFeeOf(t);
        vm.prank(creator);
        assertEq(p.claimCreatorFee(t, creator), kept);
        assertEq(wbnb.balanceOf(PAD3), padBefore + d, "after the claims, only the dust");
    }

    /// @dev USDT quote: pulled with the wallet's allowance, the claim in USDT, the pad's USDT exactly its books.
    function test_fork_promote_usdt() public {
        if (!_upgrade()) return;
        address t = _create(M.USDT, M.USDT_REF_POOL, _noTax());
        IERC20 usdt = IERC20(M.USDT);
        uint256 padBefore = usdt.balanceOf(PAD3);
        deal(M.USDT, wallet, 100 ether);
        uint256 gross = 10 ether;
        vm.startPrank(wallet, wallet);
        usdt.approve(PAD3, type(uint256).max);
        (uint256 out, uint256 used) = pm.buyWithPromoter(t, gross, 0, promoter);
        vm.expectRevert(IGangLaunchpad3.BadMsgValue.selector);
        pm.buyWithPromoter{value: 1}(t, gross, 0, promoter);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(used, gross);
        assertEq(pm.promoterFeeOf(t, promoter), _cut(gross));
        (,, uint128 realQuote,,,,,,,,,) = p.curves(t);
        assertEq(usdt.balanceOf(PAD3) - padBefore, realQuote + p.creatorFeeOf(t) + _cut(gross), "books");
        vm.prank(promoter);
        assertEq(pm.claimPromoterFee(t, promoter), _cut(gross));
        assertEq(usdt.balanceOf(promoter), _cut(gross), "paid in USDT");
    }

    /// @dev A taxed dividend token: the same shares in the live vault as a token without a share; the split as ever.
    function test_fork_promote_taxedDividend() public {
        if (!_upgrade()) return;
        IGangLaunchpad.TaxConfig memory tax = IGangLaunchpad.TaxConfig(300, 300, 10_000, address(0));
        address t = _create(address(0), address(0), tax);
        address plain = _plain(address(0), address(0), tax);
        SharedDividendVault vault = SharedDividendVault(address(p.dividendVault()));
        vm.prank(wallet, wallet);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);
        vm.prank(wallet, wallet);
        p.buyTokenAMAP{value: GROSS}(plain, wallet, GROSS, 0);
        assertGt(vault.shares(t, wallet), 0);
        assertEq(vault.shares(t, wallet), vault.shares(plain, wallet), "same share after a buy");
        assertEq(pm.promoterFeeOf(t, promoter), _cut(GROSS));
        uint256 half = IERC20(t).balanceOf(wallet) / 2;
        vm.startPrank(wallet, wallet);
        IERC20(t).approve(PAD3, half);
        IERC20(plain).approve(PAD3, half);
        p.sell(t, half, 0);
        p.sell(plain, half, 0);
        vm.stopPrank();
        assertEq(vault.shares(t, wallet), vault.shares(plain, wallet), "same share after a sell");
    }

    /// @dev Fresh Agents buy (the 1% cap trims each) until the curve needs `left` more.
    function _fillTo(address t, uint256 left) internal {
        uint256 grad = pm.gradAmtOf(t);
        for (uint256 i; i < 400; i++) {
            (,, uint128 rq,,,,,,,,,) = p.curves(t);
            if (grad - rq <= left) return;
            uint256 gross = ((grad - rq - left) * BPS) / 9_900;
            if (gross > 1 ether) gross = 1 ether;
            address a = _agent();
            vm.prank(a, a);
            p.buyTokenAMAP{value: gross}(t, a, gross, 0);
        }
        revert("did not fill");
    }

    function _agent() internal returns (address a) {
        a = makeAddr(string.concat("promote-fork-agent-", vm.toString(_n++)));
        vm.deal(a, 10 ether);
    }

    function _env(uint256 pk) internal {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("GANG_PAD", vm.toString(PAD_1));
        vm.setEnv("OWNER", vm.toString(SAFE));
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        vm.setEnv("GANG_GATEWAY", vm.toString(M.GANG_GATEWAY));
        vm.setEnv("GANG_PAD_REGISTRY", vm.toString(M.PAD_REGISTRY));
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        vm.setEnv("GANG_ROUTER3", vm.toString(ROUTER3));
        vm.setEnv("PAD3_NEW", "false");
        vm.setEnv(
            "CALLERS",
            "0x1de460f363AF910f51726DEf188F9004276Bf4bc,0xDB97fC3329Ed1939012D56ECeaef00Be1C0CdFF5,0x3508DcA95a64C9378Cb07eF6F40553A50905372a"
        );
        vm.setEnv("CALLER_CODEHASHES", "");
        vm.setEnv("CALLERS_PROXY_OK", "true");
        vm.setEnv("PAD3_INIT_CALL", "0x");
        vm.setEnv("PAD3_IMPL", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_HANDLER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_TOKEN_DEPLOYER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_VAULT_CORE", vm.toString(address(0)));
        vm.setEnv("GANG_MAINNET_OK", "true");
        vm.setEnv("PAD3_LOG_SCAN", "false");
        vm.setEnv("CUTOVER", "false");
        vm.setEnv("ROUTER_TIMELOCK_DELAY", "172800");
        vm.setEnv("MAINNET_OWNER_IS_DEPLOYER", "false");
        vm.setEnv("KEEPER_OVERRIDE_OK", "false");
        vm.setEnv("FEE_VAULT", vm.toString(address(0)));
        vm.setEnv("BURNER", vm.toString(address(0)));
        vm.setEnv("RECIPIENT", vm.toString(address(0)));
        vm.setEnv("TWAP_WINDOW", vm.toString(uint256(IGangPad(PAD_1).twapWindow())));
    }
}
