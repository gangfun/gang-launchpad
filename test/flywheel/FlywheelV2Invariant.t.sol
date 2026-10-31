// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FlywheelFixture} from "./FlywheelFixture.sol";
import {GangFlywheelPad} from "../../src/flywheel/GangFlywheelPad.sol";
import {GangMintToken} from "../../src/flywheel/GangMintToken.sol";
import {FlywheelTaxHandler} from "../../src/flywheel/FlywheelTaxHandler.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";
import {MockWBNB} from "../mocks/MockWBNB.sol";
import {TwapMockPair} from "../mocks/TwapMockPair.sol";

/// @dev 18-decimal quote whose transfers to a blocked address revert (a creator / bucket that can't receive).
contract BlockQuote is ERC20("Block", "BLK") {
    mapping(address => bool) public blocked;

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blocked");
        super._update(from, to, value);
    }
}

/// @dev A listed router: pays from its own balance, acts for tx.origin.
contract MiniRouter {
    GangFlywheelPad public pad;

    constructor(GangFlywheelPad p) {
        pad = p;
    }

    function mintFor(address q, address trader, address t, uint256 n) external returns (uint256) {
        IERC20(q).approve(address(pad), type(uint256).max);
        return pad.mintFor(trader, t, n, 0, address(0));
    }

    function mintPostFor(address q, address trader, address t, uint256 n, address ref)
        external
        returns (uint256, uint256)
    {
        IERC20(q).approve(address(pad), type(uint256).max);
        return pad.mintPostFor(trader, t, n, 0, type(uint256).max, ref);
    }

    function withdrawFor(address trader, address t, uint256 n) external returns (uint256) {
        return pad.withdrawFor(trader, t, n, 0);
    }
}

contract FlyInvHandler is Test {
    uint256 constant TPS = 100_000 ether;
    GangFlywheelPad pad;
    FlywheelTaxHandler th;
    SharedDividendVault vault;
    MockAgentId agents;
    MockWBNB wbnb;
    BlockQuote public bq;
    MiniRouter router;
    address bucket;

    address[] public tokens;
    mapping(address => address[]) internal walletsOf;
    mapping(address => mapping(address => bool)) internal known;
    address[] public actors;
    address[] public creators;
    uint256 nonce;

    // ghosts
    uint256 public postOk;
    uint256 public postRefused;
    uint256 public launches;
    uint256 public owedDevSeen;
    uint256 public owedFeeSeen;
    uint256 public graceRefunds;
    mapping(bytes4 => uint256) public refusals;

    constructor(
        GangFlywheelPad p,
        FlywheelTaxHandler h,
        SharedDividendVault v,
        MockAgentId a,
        MockWBNB w,
        BlockQuote q,
        MiniRouter r,
        address b
    ) {
        (pad, th, vault, agents, wbnb, bq, router, bucket) = (p, h, v, a, w, q, r, b);
        for (uint256 i; i < 8; i++) {
            actors.push(_agent());
        }
        for (uint256 i; i < 3; i++) {
            creators.push(_agent());
        }
    }

    function _agent() internal returns (address who) {
        who = address(uint160(uint256(keccak256(abi.encode("inv-agent", nonce++)))));
        agents.mint(who, 10_000_000 + nonce);
        wbnb.mintUnlimited(who, 1_000_000 ether);
        bq.mint(who, 1_000_000 ether);
        vm.deal(who, 1_000_000 ether);
        vm.startPrank(who);
        wbnb.approve(address(pad), type(uint256).max);
        bq.approve(address(pad), type(uint256).max);
        vm.stopPrank();
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function walletCount(address t) external view returns (uint256) {
        return walletsOf[t].length;
    }

    function walletAt(address t, uint256 i) external view returns (address) {
        return walletsOf[t][i];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _track(address t, address w) internal {
        if (!known[t][w]) {
            known[t][w] = true;
            walletsOf[t].push(w);
        }
    }

    function _tok(uint256 i) internal view returns (address) {
        return tokens[i % tokens.length];
    }

    function _q(address t) internal view returns (address) {
        return pad.sales(t).quote;
    }

    function _fund(address who, address q, uint256 amt) internal {
        if (q == address(wbnb)) wbnb.mintUnlimited(who, amt);
        else bq.mint(who, amt);
    }

    // ------------------------------------------------------------ actions
    function create(uint256 seed, uint256 fillSeed) external {
        if (tokens.length >= 3) return;
        IFlywheelPad.FlyConfig memory c;
        uint256 r = seed;
        c.postMint = (r % 5) != 0;
        r /= 5;
        c.raiseBnb = bound(r % 1000, 3, 50) * 1 ether;
        r /= 1000;
        c.maxPerTx = uint8(5 + r % 6);
        r /= 6;
        c.baseQuota = uint16(c.postMint ? 5 + r % 6 : 5 + r % 96);
        r /= 96;
        c.inviteBonus = uint8(c.postMint ? r % 2 : r % 4); // audit V2 A-M1: 0–1 with postMint
        r /= 4;
        c.holdBps = uint16(6000 + (r % 3001));
        r /= 3001;
        c.mintFeeBps = uint16(100 + r % 201);
        r /= 201;
        c.exitFeeBps = uint16(100 + r % 101);
        r /= 101;
        c.devCutBps = uint16(r % 1001);
        r /= 1001;
        c.buyBps = uint16(r % 5001);
        r /= 5001;
        c.sellTaxBps = uint16(100 + r % 101);
        r /= 101;
        c.launchDelay = uint32(r % 4 == 0 ? 0 : r % 301);
        r /= 301;
        c.window = uint32(300 + r % 1501);
        r /= 1501;
        c.windowCapMul = uint8(1 + r % 2);
        r /= 2;
        c.tierMode = uint8(r % 3);
        r /= 3;
        if (c.tierMode == 2) {
            c.stepBps = uint16(r % 1001);
            c.stepShares = uint32(100 + (r / 7) % 2000);
            c.maxMulX100 = uint16(100 + (r / 13) % 901);
        }
        r = uint256(keccak256(abi.encode(seed)));
        c.supplyCapMul = uint16(10 + r % 491);
        uint16[4] memory g = [uint16(0), 1500, 2000, 3000];
        c.guardBps = g[(r >> 16) % 4];
        c.twapWindow = ((r >> 24) % 2) == 0 ? 900 : 1800;
        uint256 devShares = 1 + (r >> 32) % (c.maxPerTx < c.baseQuota ? c.maxPerTx : c.baseQuota);
        bool useBq = ((r >> 40) % 3) == 0;
        address creator = creators[(r >> 48) % creators.length];

        bool bb = bq.blocked(bucket);
        bq.setBlocked(bucket, false);
        string[4] memory text = ["Inv", "INV", "l", "m"];
        vm.prank(creator);
        address t = pad.create(text, useBq ? address(bq) : address(0), address(0), c, devShares);
        tokens.push(t);
        _track(t, creator);
        (uint16 gb, uint32 tw) = pad.postRulesOf(t);
        assertEq(gb, c.guardBps, "postRules guard");
        assertEq(tw, c.twapWindow, "postRules window");

        // bulk fill target: 0 → stays well below early open, 1 → around the early-open line, 2 → full
        uint256 mode = fillSeed % 3;
        targetOf[t] = mode == 0 ? 500 + fillSeed % 2000 : mode == 1 ? 3000 + fillSeed % 300 : 10_000;
        _bulk(t, 120);
        if (pad.sales(t).launched) launches++;
        bq.setBlocked(bucket, bb);
    }

    mapping(address => uint256) public targetOf;
    mapping(address => uint256) internal bulkN;

    function fill(uint256 ti) external {
        if (tokens.length == 0) return;
        address t = _tok(ti);
        bool bb = bq.blocked(bucket);
        bq.setBlocked(bucket, false);
        _bulk(t, 600);
        if (pad.sales(t).launched) launches++;
        bq.setBlocked(bucket, bb);
    }

    function _bulk(address t, uint256 maxWallets) internal {
        uint256 target = targetOf[t];
        address q = _q(t);
        for (uint256 i; i < maxWallets; i++) {
            IFlywheelPad.Sale memory s = pad.sales(t);
            if (s.sold >= target || s.filledAt != 0) return;
            uint256 k = bulkN[t]++;
            address w = address(uint160(uint256(keccak256(abi.encode("bulk", t, k)))));
            agents.mint(w, uint256(keccak256(abi.encode("bulkid", t, k))));
            _fund(w, q, 10_000 ether);
            vm.startPrank(w);
            IERC20(q).approve(address(pad), type(uint256).max);
            for (uint256 j; j < 30; j++) {
                s = pad.sales(t);
                if (pad.quotaLeft(t, w) == 0 || s.filledAt != 0 || s.sold >= target) break;
                pad.mint(t, target - s.sold, 1, address(0));
            }
            vm.stopPrank();
            _track(t, w);
        }
    }

    function mint(uint256 ai, uint256 ti, uint256 shares, uint256 refSeed, uint256 path) external {
        if (tokens.length == 0) return;
        address t = _tok(ti);
        address a = actors[ai % actors.length];
        shares = bound(shares, 0, 25);
        address ref = refSeed % 3 == 0 ? address(0) : actors[refSeed % actors.length];
        address q = _q(t);
        (uint256 acc, uint256 cost, uint256 fee) = pad.previewMint(t, a, shares);
        IFlywheelPad.Sale memory s0 = pad.sales(t);
        uint256 ql = pad.quotaLeft(t, a);
        if (acc != 0) {
            uint256 exp = shares < ql ? shares : ql;
            if (exp > s0.maxPerTx) exp = s0.maxPerTx;
            if (exp > 10_000 - s0.sold) exp = 10_000 - s0.sold;
            assertEq(acc, exp, "previewMint accepted vs quotaLeft");
        }
        bool bucketBlocked = q == address(bq) && bq.blocked(bucket);
        uint256 balBefore = IERC20(q).balanceOf(a);
        uint256 p = path % 3;
        if (p == 2 && (s0.gate == address(0) || q != address(wbnb))) p = 0;
        if (p == 1 && q != address(wbnb)) p = 0;
        bool ok;
        uint256 spent;
        bytes memory err;
        if (p == 0) {
            vm.prank(a);
            try pad.mint(t, shares, 0, ref) returns (uint256 sp) {
                (ok, spent) = (true, sp);
            } catch (bytes memory e) {
                err = e;
            }
        } else if (p == 1) {
            vm.prank(a);
            try pad.mintWithBnb{value: cost + fee + 1 ether}(t, shares, 0, ref) returns (uint256 sp) {
                (ok, spent) = (true, sp);
            } catch (bytes memory e) {
                err = e;
            }
            balBefore = 0;
        } else {
            _fund(address(router), q, cost + fee);
            vm.prank(address(this), a);
            try router.mintFor(q, a, t, shares) returns (uint256 sp) {
                (ok, spent) = (true, sp);
            } catch (bytes memory e) {
                err = e;
            }
            balBefore = 0;
        }
        if (bucketBlocked) {
            if (acc != 0) assertFalse(ok, "mint fee into a refusing bucket must fail the mint");
            return;
        }
        assertEq(ok, acc != 0, "previewMint accepted==0 iff mint reverts");
        if (ok) {
            assertEq(spent, cost + fee, "mint spent == preview");
            assertEq(pad.sales(t).sold, s0.sold + acc, "sold delta");
            if (p == 0) assertEq(balBefore - IERC20(q).balanceOf(a), cost + fee, "pulled");
            _track(t, a);
            if (pad.sales(t).launched) launches++;
        }
    }

    function withdraw(uint256 ai, uint256 ti, uint256 shares, uint256 path) external {
        if (tokens.length == 0) return;
        address t = _tok(ti);
        address a = actors[ai % actors.length];
        address q = _q(t);
        if (q == address(bq) && bq.blocked(a)) return;
        shares = bound(shares, 0, 25);
        (uint256 payout, uint256 fee) = pad.previewWithdraw(t, a, shares);
        IFlywheelPad.Sale memory s0 = pad.sales(t);
        bool grace = s0.filledAt != 0;
        bool viaRouter = path % 2 == 1 && s0.gate != address(0);
        uint256 got;
        bool ok;
        uint256 owedBefore = pad.owedFee(q);
        if (viaRouter) {
            vm.prank(a);
            IERC20(t).approve(address(router), type(uint256).max);
            uint256 rb = IERC20(q).balanceOf(address(router));
            vm.prank(address(this), a);
            try router.withdrawFor(a, t, shares) returns (uint256 po) {
                (ok, got) = (true, po);
                assertEq(IERC20(q).balanceOf(address(router)) - rb, po, "router got payout");
            } catch {}
        } else {
            uint256 b = IERC20(q).balanceOf(a);
            vm.prank(a);
            try pad.withdraw(t, shares, 0) returns (uint256 po) {
                (ok, got) = (true, po);
                assertEq(IERC20(q).balanceOf(a) - b, po, "trader got payout");
            } catch {}
        }
        assertEq(ok, payout != 0, "previewWithdraw zero iff withdraw reverts");
        if (ok) {
            assertEq(got, payout, "payout == preview");
            assertEq(pad.sales(t).sold, s0.sold - shares, "sold down");
            if (pad.owedFee(q) > owedBefore) {
                owedFeeSeen++;
                assertEq(pad.owedFee(q) - owedBefore, fee, "owed fee == preview fee");
            }
            if (grace) graceRefunds++;
        }
    }

    function openEarly(uint256 ti) external {
        if (tokens.length == 0) return;
        address t = _tok(ti);
        address c = pad.sales(t).creator;
        vm.prank(c);
        try pad.openEarly(t) {
            if (pad.sales(t).launched) launches++;
        } catch {}
    }

    function launch(uint256 ti, uint256 wait) external {
        if (tokens.length == 0) return;
        address t = _tok(ti);
        IFlywheelPad.Sale memory s0 = pad.sales(t);
        if (s0.filledAt == 0 && s0.sold >= 3000 && wait % 2 == 0) {
            vm.prank(s0.creator);
            pad.openEarly(t);
        }
        vm.warp(vm.getBlockTimestamp() + bound(wait, 0, 400));
        vm.roll(vm.getBlockNumber() + 1);
        try pad.launch(t) {
            launches++;
            if (pad.owedDev(t) > 0) owedDevSeen++;
        } catch {}
    }

    function mintPost(uint256 ai, uint256 ti, uint256 shares, uint256 refSeed, uint256 path) external {
        if (tokens.length == 0) return;
        address t = _tok(ti);
        address a = actors[ai % actors.length];
        shares = bound(shares, 0, 12);
        address ref = refSeed % 3 == 0 ? address(0) : actors[refSeed % actors.length];
        address q = _q(t);
        (uint256 acc, uint256 paid, uint256 fee, uint256 out, bool pok) = pad.previewMintPost(t, a, shares);
        IFlywheelPad.Sale memory s0 = pad.sales(t);
        bool bucketBlocked = q == address(bq) && bq.blocked(bucket);

        uint256 p = path % 3;
        if (p == 2 && s0.gate == address(0)) p = 0;
        if (p == 1 && q != address(wbnb)) p = 0;
        uint256 tb = IERC20(t).balanceOf(a);
        bool ok;
        uint256 tokensOut;
        uint256 spent;
        bytes memory err;
        if (p == 0) {
            vm.prank(a);
            try pad.mintPost(t, shares, 0, type(uint256).max, ref) returns (uint256 o, uint256 sp) {
                (ok, tokensOut, spent) = (true, o, sp);
            } catch (bytes memory e) {
                err = e;
            }
        } else if (p == 1) {
            vm.prank(a);
            try pad.mintPostWithBnb{value: paid + fee + 0.5 ether}(t, shares, 0, ref) returns (uint256 o, uint256 sp) {
                (ok, tokensOut, spent) = (true, o, sp);
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            _fund(address(router), q, paid + fee);
            vm.prank(address(this), a);
            try router.mintPostFor(q, a, t, shares, ref) returns (uint256 o, uint256 sp) {
                (ok, tokensOut, spent) = (true, o, sp);
            } catch (bytes memory e) {
                err = e;
            }
        }
        if (!ok && err.length >= 4) refusals[bytes4(err)]++;
        if (bucketBlocked) {
            assertFalse(ok && pok && fee > 0, "fee into a refusing bucket");
            return;
        }
        if (ok) {
            postOk++;
            assertTrue(pok, "preview said no but mintPost succeeded");
            assertEq(tokensOut, out, "tokensOut == preview");
            assertEq(spent, paid + fee, "spent == preview");
            assertEq(IERC20(t).balanceOf(a) - tb, out, "trader received exactly tokensOut");
            assertEq(pad.sales(t).totalShares, s0.totalShares + acc, "totalShares delta");
            _track(t, a);
        } else {
            postRefused++;
            assertFalse(pok, "preview ok but mintPost reverted");
        }
    }

    function poolBuy(uint256 ai, uint256 ti, uint256 bps) external {
        if (tokens.length == 0) return;
        address t = _tok(ti);
        if (!pad.sales(t).launched) return;
        address a = actors[ai % actors.length];
        TwapMockPair p = TwapMockPair(pad.sales(t).pair);
        (uint112 r0, uint112 r1,) = p.getReserves();
        bool t0 = p.token0() == t;
        (uint256 rT, uint256 rQ) = t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 qIn = (rQ * bound(bps, 1, 3000)) / 10_000;
        uint256 out = (qIn * 9975 * rT) / (rQ * 10_000 + qIn * 9975);
        if (out == 0) return;
        address q = _q(t);
        _fund(address(p), q, qIn);
        try p.swap(t0 ? out : 0, t0 ? 0 : out, a, "") {}
        catch {
            p.skim(address(0xbeef)); // protection refused: take the quote back out
        }
    }

    function poolSell(uint256 ai, uint256 ti, uint256 bps) external {
        if (tokens.length == 0) return;
        address t = _tok(ti);
        if (!pad.sales(t).launched) return;
        address a = actors[ai % actors.length];
        uint256 amt = (IERC20(t).balanceOf(a) * bound(bps, 1, 10_000)) / 10_000;
        if (amt == 0) return;
        TwapMockPair p = TwapMockPair(pad.sales(t).pair);
        vm.prank(a);
        IERC20(t).transfer(address(p), amt);
        (uint112 r0, uint112 r1,) = p.getReserves();
        bool t0 = p.token0() == t;
        (uint256 rT, uint256 rQ) = t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inAmt = IERC20(t).balanceOf(address(p)) - rT;
        uint256 out = (inAmt * 9975 * rQ) / (rT * 10_000 + inAmt * 9975);
        if (out == 0) return;
        p.swap(t0 ? 0 : out, t0 ? out : 0, a, "");
    }

    function warp(uint256 secs, uint256 big) external {
        uint256 d = big % 20 == 0 ? bound(secs, 1 days, 8 days) : bound(secs, 1, 900);
        vm.warp(vm.getBlockTimestamp() + d);
        vm.roll(vm.getBlockNumber() + 1 + d / 3);
    }

    function toggleBlock(uint256 who, bool on) external {
        address x = who % 2 == 0 ? creators[who % creators.length] : bucket;
        bq.setBlocked(x, on);
    }

    function claimDev(uint256 ti) external {
        if (tokens.length == 0) return;
        address t = _tok(ti);
        uint256 owed = pad.owedDev(t);
        address c = pad.sales(t).creator;
        address q = _q(t);
        uint256 b = IERC20(q).balanceOf(c);
        try pad.claimDev(t) returns (uint256 amt) {
            assertEq(amt, owed);
            assertEq(IERC20(q).balanceOf(c) - b, owed, "claimDev paid creator");
            assertEq(pad.owedDev(t), 0);
        } catch {
            assertTrue(owed == 0 || (q == address(bq) && bq.blocked(c)), "claimDev reverted with a payable cut");
        }
    }

    function flush() external {
        try pad.flushFees(address(bq)) {} catch {}
    }
}

/// @notice From audit V2 / B: random creates (every config checkConfig allows, WBNB or an 18-decimal quote that can
///         refuse transfers), pre-launch mints and sell-backs (direct, BNB, listed router), early opens, launches,
///         post-launch mints, pool trades, time, blocked creators / bucket. Invariants: the pad holds exactly the escrow
///         plus what it owes; supply within the cap; accounts sum to the sale; previews equal trades (in the handler).
///         Kept short here (each run fills sales with hundreds of wallets); the audit ran 96 runs × 150 calls.
/// forge-config: default.invariant.runs = 4
/// forge-config: default.invariant.depth = 60
contract FlywheelV2InvariantTest is StdInvariant, FlywheelFixture {
    FlyInvHandler h;
    BlockQuote bq;
    MiniRouter router;

    function setUp() public {
        _deploy();
        bq = new BlockQuote();
        router = new MiniRouter(pad);
        vm.startPrank(owner);
        quoteRegistry.setQuote(address(bq), true, 15 ether);
        pad.setRouter(address(router), true);
        vm.stopPrank();
        h = new FlyInvHandler(pad, handler, vault, agents, wbnb, bq, router, address(bucket));
        // the handler mints Agent IDs and faucet tokens
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](14);
        sel[12] = FlyInvHandler.fill.selector;
        sel[13] = FlyInvHandler.fill.selector;
        sel[0] = FlyInvHandler.create.selector;
        sel[1] = FlyInvHandler.mint.selector;
        sel[2] = FlyInvHandler.withdraw.selector;
        sel[3] = FlyInvHandler.openEarly.selector;
        sel[4] = FlyInvHandler.launch.selector;
        sel[5] = FlyInvHandler.mintPost.selector;
        sel[6] = FlyInvHandler.poolBuy.selector;
        sel[7] = FlyInvHandler.poolSell.selector;
        sel[8] = FlyInvHandler.warp.selector;
        sel[9] = FlyInvHandler.toggleBlock.selector;
        sel[10] = FlyInvHandler.claimDev.selector;
        sel[11] = FlyInvHandler.mintPost.selector; // weight post-launch mints
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    /// pad quote balance == pre-launch escrow + owed exit fees + owed dev cuts, per quote (nothing stuck or lost)
    function invariant_funds() public view {
        address[2] memory qs = [address(wbnb), address(bq)];
        for (uint256 k; k < 2; k++) {
            uint256 expect = pad.owedFee(qs[k]);
            for (uint256 i; i < h.tokenCount(); i++) {
                address t = h.tokens(i);
                IFlywheelPad.Sale memory s = pad.sales(t);
                if (s.quote != qs[k]) continue;
                if (!s.launched) expect += uint256(s.sold) * s.basePrice;
                expect += pad.owedDev(t);
            }
            assertEq(IERC20(qs[k]).balanceOf(address(pad)), expect, "pad quote balance");
        }
    }

    function invariant_tokens() public view {
        for (uint256 i; i < h.tokenCount(); i++) {
            address t = h.tokens(i);
            IFlywheelPad.Sale memory s = pad.sales(t);
            GangMintToken tk = GangMintToken(t);
            assertLe(tk.totalSupply(), tk.maxSupply(), "supply <= max");
            uint256 padBal = tk.balanceOf(address(pad));
            if (!s.launched) {
                assertEq(tk.totalSupply() - padBal, uint256(s.sold) * TPS, "pre-launch supply outside the pad");
            } else {
                assertEq(padBal, 0, "post-launch: no token left in the pad");
            }
            // accounts
            uint256 sumPre;
            uint256 sumUsed;
            uint256 n = h.walletCount(t);
            for (uint256 j; j < n; j++) {
                address w = h.walletAt(t, j);
                (uint32 pre, uint32 used, uint32 bonus,,,, uint256 baseline) = pad.accounts(t, w);
                sumPre += pre;
                sumUsed += used;
                assertLe(used, uint256(s.baseQuota) + bonus, "used <= quota");
                assertEq(pad.quotaLeft(t, w), uint256(s.baseQuota) + bonus - used, "quotaLeft");
                if (!s.launched) {
                    assertEq(vault.shares(t, w), baseline, "pre-launch vault share == baseline");
                    assertEq(baseline, uint256(pre) * TPS, "pre-launch baseline");
                } else {
                    assertEq(vault.shares(t, w), handler.eligibleShare(t, w), "post-launch share == eligible");
                }
                if (w == s.creator) assertEq(pre, s.creatorShares, "creatorShares");
            }
            assertEq(sumPre, s.sold, "sum preShares == sold");
            assertEq(sumUsed, s.totalShares, "sum used == totalShares");
        }
    }

    function afterInvariant() public view {
        console2.log("tokens", h.tokenCount(), "launches", h.launches());
        console2.log("postOk", h.postOk(), "postRefused", h.postRefused());
        console2.log("graceRefunds", h.graceRefunds());
        console2.log("owedDevSeen", h.owedDevSeen(), "owedFeeSeen", h.owedFeeSeen());
        console2.log(
            "belowAvg",
            h.refusals(IFlywheelPad.PriceBelowAverage.selector),
            "abovePool",
            h.refusals(IFlywheelPad.PriceAbovePool.selector)
        );
        console2.log(
            "pace", h.refusals(IFlywheelPad.PaceExceeded.selector), "zero", h.refusals(IFlywheelPad.ZeroAmount.selector)
        );
    }
}
