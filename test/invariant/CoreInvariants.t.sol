// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../../src/common/SharedPlatformFeeBucket.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangTaxHandler} from "../../src/gang/GangTaxHandler.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangFixture} from "../utils/GangFixture.sol";

/// @notice Random actions against the whole merged system (one GangLaunchpad holding both kinds, one GangTaxHandler)
///         on mocks. Calls the rules refuse (cap, slippage, wrong kind…) just revert and are skipped; the invariants
///         are checked after every call either way. Three quotes: WBNB (V3 curves and 打新 sales side by side in the
///         one pad), an 18-decimal test quote, and a quote that can blacklist the tax recipient.
contract CoreHandler is GangFixture {
    address[] public actors;
    address[] public holders; // every address that ever held a token (for share / dividend sums)
    mapping(address => bool) internal isHolder;

    address[] public v3Tokens;
    mapping(address => bytes32) public v3ConfigHash;
    address[] public sales;
    mapping(address => mapping(address => bool)) public everOut;
    /// @notice kindOf as read right after create (must never change).
    mapping(address => uint8) public kindAtCreate;

    // §5.4: per quote, the pad's balance minus what it accounts for (dust) — may only grow
    mapping(address => uint256) public lastDust;
    mapping(address => bool) internal dustSeen;
    uint256 public dustShrank;
    uint256 public dustNegative;

    uint256 public calls;
    uint256 public v3Graduations;
    uint256 public fairLaunches;
    uint256 public staleExits; // withdraws with the exit fee waived (no mint for 7 days)
    uint256 public owedEvents;
    uint256 public blqTokens;
    uint256 public blockedSet;
    /// @dev §22: V3 tokens whose recipient is their own creator (no listing); the last one is blocked with treasury.
    uint256 public selfRecipientTokens;
    address public lastSelfRecipient;
    uint256 public mixedRounds; // same-WBNB rounds that touched both a live curve and a live sale
    /// @dev Spec §19 (no curve tax): curve trades that moved quote to the recipient / the vault / the tax handler, and
    ///      curve trades whose bucket accrual + creator part was not exactly 1% of the trade. Both must stay 0.
    uint256 public curveTaxLeaks;
    uint256 public curveFeeOff;
    /// @dev Creator fee: curve trades whose creator part was not 70% of the fee, and claims that paid the creator
    ///      anything but exactly what was kept. Must stay 0.
    uint256 public creatorFeeOff;
    uint256 public creatorClaims;
    uint256 public curveTrades;
    /// @dev Router buys / mints that went through (they need trader == tx.origin, §23).
    uint256 public routerTrades;

    constructor() {
        _deployGang(address(this));
        vm.deal(address(this), 1_000_000 ether); // pays the router's BNB paths (prank sets only msg.sender)
        for (uint256 i = 0; i < 6; i++) {
            actors.push(_newAgent());
        }
        _checkpoint();
    }

    // ---------------------------------------------------------------- views for the invariants
    function v3TokenCount() external view returns (uint256) {
        return v3Tokens.length;
    }

    function saleCount() external view returns (uint256) {
        return sales.length;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function quotes() public view returns (address[3] memory) {
        return [address(wbnb), address(quoteTok), address(blq)];
    }

    /// @notice What the pad must hold of `q` (merge plan §5.4): Σ not-launched sales' live principal + owedFee[q] +
    ///         Σ not-graduated curves' realQuote.
    function accountedOf(address q) public view returns (uint256 sum) {
        sum = pad.owedFee(q);
        for (uint256 i = 0; i < sales.length; i++) {
            address t = sales[i];
            if (_saleQuote(t) != q || _launched(t)) continue;
            uint256 shares;
            for (uint256 j = 0; j < holders.length; j++) {
                shares += pad.positions(t, holders[j]);
            }
            sum += shares * _sharePrice(t);
        }
        for (uint256 i = 0; i < v3Tokens.length; i++) {
            address t = v3Tokens[i];
            if (_curveQuote(t) != q) continue;
            sum += pad.creatorFeeOf(t); // kept for the creator, live or graduated
            if (!_graduated(t)) sum += _curveRealQuote(t);
        }
    }

    // ---------------------------------------------------------------- helpers
    function _onNewAgent(address who) internal override {
        _track(who);
    }

    function _track(address who) internal {
        if (!isHolder[who]) {
            isHolder[who] = true;
            holders.push(who);
        }
    }

    /// @dev After every action: the §5.4 dust per quote must be ≥ 0 and never shrink.
    function _checkpoint() internal {
        address[3] memory qs = quotes();
        for (uint256 k = 0; k < 3; k++) {
            uint256 bal = IERC20(qs[k]).balanceOf(address(pad));
            uint256 acc = accountedOf(qs[k]);
            if (bal < acc) {
                dustNegative++;
                continue;
            }
            uint256 dust = bal - acc;
            if (dustSeen[qs[k]] && dust < lastDust[qs[k]]) dustShrank++;
            lastDust[qs[k]] = dust;
            dustSeen[qs[k]] = true;
        }
    }

    modifier action() {
        calls++;
        _;
        _checkpoint();
    }

    /// @dev Picks hash the seed first: the fuzzer favours small integers, which would always pick the first entry.
    function _pick(uint256 seed, uint256 salt, uint256 n) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt))) % n;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[_pick(seed, 1, actors.length)];
    }

    function _quote(uint256 seed) internal view returns (address) {
        uint256 k = _pick(seed, 2, 3);
        return k == 0 ? address(wbnb) : k == 1 ? address(quoteTok) : address(blq);
    }

    function _v3(uint256 seed) internal view returns (address) {
        return v3Tokens[_pick(seed, 3, v3Tokens.length)];
    }

    function _sale(uint256 seed) internal view returns (address) {
        return sales[_pick(seed, 4, sales.length)];
    }

    function _tryPoolBuy(address token, address quote, address pair, address who, uint256 quoteIn) internal {
        _mintQuote(quote, pair, quoteIn);
        (uint256 rT, uint256 rQ) = _reserves(token, pair);
        if (rT == 0 || rQ == 0) return;
        uint256 out = (quoteIn * rT) / (rQ + quoteIn) / 2;
        if (out == 0) return;
        try this.swapOut(pair, token, true, out, who) {} catch {}
    }

    function _tryPoolSell(address token, address pair, address who, uint256 amount) internal {
        if (amount == 0) return;
        vm.prank(who);
        try IERC20(token).transfer(pair, amount) returns (bool) {}
        catch {
            return;
        }
        (uint256 rT, uint256 rQ) = _reserves(token, pair);
        uint256 bal = IERC20(token).balanceOf(pair);
        if (bal <= rT) return;
        uint256 out = ((bal - rT) * rQ) / bal / 2;
        if (out == 0) return;
        try this.swapOut(pair, token, false, out, who) {} catch {}
    }

    function swapOut(address pair, address token, bool tokenOut, uint256 out, address to) external {
        require(msg.sender == address(this));
        _pairSwapOut(pair, token, tokenOut, out, to);
    }

    // ================================================================ V3 (curve) actions
    function v3Create(uint256 seed, uint16 buyBps, uint16 sellBps, uint16 dividendBps, bool noRecipient)
        external
        action
    {
        if (v3Tokens.length >= 4) return;
        address creator = _actor(seed);
        address q = _quote(seed);
        buyBps = uint16(bound(buyBps, 100, 500));
        sellBps = uint16(bound(sellBps, 100, 500));
        dividendBps = noRecipient ? 10_000 : uint16(bound(dividendBps, 0, 10_000));
        // §22: a third of the recipient tokens name their own (unlisted) creator instead of the listed treasury
        bool self = !noRecipient && _pick(seed, 7, 3) == 0;
        address recipient = noRecipient ? address(0) : self ? creator : treasury;
        IGangLaunchpad.TaxConfig memory tax = _tax(buyBps, sellBps, dividendBps, recipient);
        if (_pick(seed, 5, 5) == 0) tax = _tax(0, 0, 0, address(0)); // untaxed GangToken
        vm.prank(creator);
        address t = pad.create("T", "T", "", "", q, address(0), tax);
        v3Tokens.push(t);
        kindAtCreate[t] = pad.kindOf(t);
        if (q == address(blq)) blqTokens++;
        (,,, address r0) = pad.taxConfigOf(t);
        if (r0 != address(0) && r0 == creator) {
            selfRecipientTokens++;
            lastSelfRecipient = creator;
        }
        (uint16 b, uint16 s, uint16 d, address r) = pad.taxConfigOf(t);
        v3ConfigHash[t] = keccak256(abi.encode(b, s, d, r));
    }

    function v3Buy(uint256 seed, uint256 amount, uint8 path) external action {
        if (v3Tokens.length == 0) return;
        _v3BuyOne(_v3(seed), _actor(seed + 1), amount, path);
    }

    function _v3BuyOne(address t, address who, uint256 amount, uint8 path) internal {
        if (_graduated(t)) return;
        address q = _curveQuote(t);
        amount = bound(amount, 1e12, 3 ether);
        bool native = q == address(wbnb) && path % 3 == 1;
        uint256 sinks0 = _sinks(q);
        uint256 fee0 = bucket.accruedQuote(q);
        uint256 cf0 = pad.creatorFeeOf(t);
        uint256 bal0 = native ? _bnbPaidFrom(who, q) : IERC20(q).balanceOf(who);
        vm.prank(who, who); // the router paths need trader == tx.origin (§23)
        uint256 paid;
        if (path % 3 == 0) {
            try pad.buy(t, amount, 0) {} catch {}
        } else if (native) {
            try router.v3BuyBNB{value: amount}(t, 0, block.timestamp) {
                paid = bal0 - _bnbPaidFrom(who, q);
                routerTrades++;
            } catch {}
        } else {
            try router.v3Buy(t, amount, 0, block.timestamp) {
                routerTrades++;
            } catch {}
        }
        if (!native) paid = bal0 - IERC20(q).balanceOf(who);
        _checkCurveTrade(q, sinks0, bucket.accruedQuote(q) - fee0, pad.creatorFeeOf(t) - cf0, paid);
        _afterV3(t);
    }

    /// @dev The BNB path: the value may come from this handler or from the pranked `who` (depends on the forge
    ///      version), and a cap / graduation cut comes back to `who` as WBNB, not BNB (§23), so count all three.
    function _bnbPaidFrom(address who, address q) internal view returns (uint256) {
        return who.balance + address(this).balance + IERC20(q).balanceOf(who);
    }

    function _sinks(address q) internal view returns (uint256) {
        return
            IERC20(q).balanceOf(treasury) + IERC20(q).balanceOf(address(handler))
                + IERC20(q).balanceOf(address(divVault));
    }

    /// @dev `gross` = what the buyer paid, or the curve's payout on a sell (to the seller + fee); 0 = no trade.
    ///      `toPlatform` / `toCreator`: the bucket's and the creator's parts of the 1% fee.
    function _checkCurveTrade(address q, uint256 sinks0, uint256 toPlatform, uint256 toCreator, uint256 gross)
        internal
    {
        if (gross == 0) return;
        curveTrades++;
        if (_sinks(q) != sinks0) curveTaxLeaks++;
        uint256 fee = (gross * 100) / 10_000;
        if (toPlatform + toCreator != fee) curveFeeOff++;
        if (toCreator != (fee * 7_000) / 10_000) creatorFeeOff++;
    }

    function v3Sell(uint256 seed, uint256 fracBps) external action {
        if (v3Tokens.length == 0) return;
        _v3SellOne(_v3(seed), _actor(seed + 1), fracBps);
    }

    function _v3SellOne(address t, address who, uint256 fracBps) internal {
        if (_graduated(t)) return;
        uint256 amount = (IERC20(t).balanceOf(who) * bound(fracBps, 1, 10_000)) / 10_000;
        if (amount == 0) return;
        address q = _curveQuote(t);
        uint256 sinks0 = _sinks(q);
        uint256 fee0 = bucket.accruedQuote(q);
        uint256 cf0 = pad.creatorFeeOf(t);
        uint256 got0 = IERC20(q).balanceOf(who);
        vm.startPrank(who);
        IERC20(t).approve(address(pad), amount);
        try pad.sell(t, amount, 0) {} catch {}
        vm.stopPrank();
        uint256 toPlatform = bucket.accruedQuote(q) - fee0;
        uint256 toCreator = pad.creatorFeeOf(t) - cf0;
        uint256 got = IERC20(q).balanceOf(who) - got0;
        _checkCurveTrade(q, sinks0, toPlatform, toCreator, got == 0 ? 0 : got + toPlatform + toCreator);
        _afterV3(t);
    }

    /// @dev Fresh agents buy 1 quote each (the 1% cap truncates) until the curve graduates.
    function v3Graduate(uint256 seed) external action {
        if (v3Tokens.length == 0) return;
        address t = _v3(seed);
        for (uint256 i = 0; i < 300 && !_graduated(t); i++) {
            address w = _newAgent();
            vm.prank(w);
            try pad.buy(t, 1 ether, 0) {} catch {}
        }
        _afterV3(t);
    }

    function v3PoolTrade(uint256 seed, uint256 amount, bool isBuy) external action {
        if (v3Tokens.length == 0) return;
        address t = _v3(seed);
        if (!_graduated(t)) return;
        address pair = _curvePair(t);
        address who = _actor(seed + 1);
        if (isBuy) _tryPoolBuy(t, _curveQuote(t), pair, who, bound(amount, 1e15, 2 ether));
        else _tryPoolSell(t, pair, who, (IERC20(t).balanceOf(who) * bound(amount, 1, 10_000)) / 10_000);
    }

    function v3Transfer(uint256 seed, uint256 fracBps) external action {
        if (v3Tokens.length == 0) return;
        address t = _v3(seed);
        if (!_graduated(t)) return; // locked before graduation
        address from = _actor(seed + 1);
        address to = _actor(seed + 2);
        uint256 amount = (IERC20(t).balanceOf(from) * bound(fracBps, 1, 10_000)) / 10_000;
        vm.prank(from);
        try IERC20(t).transfer(to, amount) returns (bool) {} catch {}
    }

    function v3Process(uint256 seed) external action {
        if (v3Tokens.length == 0) return;
        address t = _v3(seed);
        try handler.process(t, type(uint256).max, 1) {} catch {}
        _afterV3(t);
    }

    function v3Claim(uint256 seed) external action {
        if (v3Tokens.length == 0) return;
        vm.prank(_actor(seed + 1));
        try divVault.claim(_v3(seed)) {} catch {}
    }

    function blockRecipient(bool blocked) external action {
        blq.setBlocked(treasury, blocked);
        if (lastSelfRecipient != address(0)) blq.setBlocked(lastSelfRecipient, blocked);
        if (blocked) blockedSet++;
    }

    /// @dev The creator takes what was kept for it (live or graduated), to an address no quote blocks. The suite runs
    ///      with fail-on-revert off, so a reverting claim is counted in `creatorFeeOff` instead.
    function v3ClaimCreatorFee(uint256 seed) external action {
        if (v3Tokens.length == 0) return;
        address t = _v3(seed);
        uint256 owed = pad.creatorFeeOf(t);
        if (owed == 0) return;
        (address creator, address q,,,,,,,,,,) = pad.curves(t);
        address to = address(uint160(0xC1A1));
        uint256 before = IERC20(q).balanceOf(to);
        vm.prank(creator);
        try pad.claimCreatorFee(t, to) returns (uint256 paid) {
            creatorClaims++;
            if (paid != owed || IERC20(q).balanceOf(to) - before != owed || pad.creatorFeeOf(t) != 0) creatorFeeOff++;
        } catch {
            creatorFeeOff++;
        }
    }

    function v3Release(uint256 seed) external action {
        if (v3Tokens.length == 0) return;
        try handler.release(_v3(seed)) {} catch {}
    }

    function _afterV3(address t) internal {
        address pair = _curvePair(t);
        if (_graduated(t) && pair != address(0) && !isHolder[pair]) {
            v3Graduations++;
            _track(pair);
        }
        if (handler.owedOf(t) > 0) owedEvents++;
    }

    // ================================================================ 打新 actions
    function fairCreate(uint256 seed, uint256 raise, uint16 capBps, uint16 holdBps, uint16 fees) external action {
        if (sales.length >= 4) return;
        address creator = _actor(seed);
        // WBNB 2 in 3: the same-quote mix with the curves is the merge's new risk (§5.4)
        address q = _pick(seed, 6, 3) == 0 ? address(quoteTok) : address(wbnb);
        IGangLaunchpad.MintConfig memory cfg = _mintCfg(
            bound(raise, 5 ether, 50 ether),
            uint16(bound(capBps, 25, 100)),
            uint16(bound(holdBps, 6_000, 9_000)),
            uint16(bound(fees, 100, 300)),
            uint16(bound(fees >> 4, 100, 200))
        );
        vm.prank(creator);
        address t = pad.create("F", "F", "", "", q, address(0), cfg, 1);
        sales.push(t);
        kindAtCreate[t] = pad.kindOf(t);
    }

    function fairMint(uint256 seed, uint256 shares, bool viaRouter) external action {
        if (sales.length == 0) return;
        _fairMintOne(_sale(seed), _actor(seed + 1), shares, viaRouter);
    }

    function _fairMintOne(address t, address who, uint256 shares, bool viaRouter) internal {
        shares = bound(shares, 1, 240);
        address q = _saleQuote(t);
        vm.prank(who, who);
        if (!viaRouter) {
            try pad.mint(t, shares, 1) {} catch {}
        } else if (q == address(wbnb)) {
            try router.fairMintBNB{value: 5 ether}(t, shares, 1, block.timestamp) {
                routerTrades++;
            } catch {}
        } else {
            try router.fairMint(t, shares, 1, block.timestamp) {
                routerTrades++;
            } catch {}
        }
        _afterSale(t);
    }

    function fairWithdraw(uint256 seed, uint256 shares) external action {
        if (sales.length == 0) return;
        _fairWithdrawOne(_sale(seed), _actor(seed + 1), shares);
    }

    function _fairWithdrawOne(address t, address who, uint256 shares) internal {
        uint16 held = pad.positions(t, who);
        if (held == 0) return;
        bool stale = pad.exitFeeBpsOf(t) == 0;
        vm.prank(who);
        try pad.withdraw(t, bound(shares, 1, held), 0) {
            if (stale) staleExits++;
        } catch {}
    }

    /// @dev Fresh agents mint up to the cap until the sale fills (and launches in that same tx).
    function fairFill(uint256 seed) external action {
        if (sales.length == 0) return;
        address t = _sale(seed);
        if (_launched(t) || pad.status(t) != IGangLaunchpad.Status.Minting) return;
        for (uint256 i = 0; i < 600 && !_launched(t); i++) {
            address w = _newAgent();
            vm.prank(w);
            try pad.mint(t, 500, 1) {} catch {}
        }
        _afterSale(t);
    }

    function fairPoolTrade(uint256 seed, uint256 amount, bool isBuy) external action {
        if (sales.length == 0) return;
        address t = _sale(seed);
        if (!_launched(t)) return;
        address pair = _salePair(t);
        address who = _actor(seed + 1);
        if (isBuy) _tryPoolBuy(t, _saleQuote(t), pair, who, bound(amount, 1e15, 2 ether));
        else _tryPoolSell(t, pair, who, (IERC20(t).balanceOf(who) * bound(amount, 1, 10_000)) / 10_000);
        _recordOut(t);
    }

    function fairTransfer(uint256 seed, uint256 fracBps) external action {
        if (sales.length == 0) return;
        address t = _sale(seed);
        if (!_launched(t)) return;
        address from = _actor(seed + 1);
        address to = _actor(seed + 2);
        uint256 amount = (IERC20(t).balanceOf(from) * bound(fracBps, 1, 10_000)) / 10_000;
        vm.prank(from);
        try IERC20(t).transfer(to, amount) returns (bool) {} catch {}
        _recordOut(t);
    }

    function fairProcess(uint256 seed) external action {
        if (sales.length == 0) return;
        try handler.process(_sale(seed), type(uint256).max, 1) {} catch {}
    }

    function fairClaim(uint256 seed) external action {
        if (sales.length == 0) return;
        vm.prank(_actor(seed + 1));
        try divVault.claim(_sale(seed)) {} catch {}
    }

    function fairFlushFees(uint256 seed) external action {
        try pad.flushFees(_quote(seed)) {} catch {}
    }

    // ================================================================ same WBNB, both kinds in one call (§5.4)
    /// @dev A WBNB curve and a WBNB sale traded in alternation by the same actor: curve buy → mint → sell-back →
    ///      curve sell (the order flips with the seed). The pad's one WBNB balance has to keep both apart.
    function mixedWbnb(uint256 seed, uint256 amount, uint256 shares) external action {
        address t3;
        address tf;
        for (uint256 i = 0; i < v3Tokens.length; i++) {
            address t = v3Tokens[(i + seed) % v3Tokens.length];
            if (_curveQuote(t) == address(wbnb) && !_graduated(t)) {
                t3 = t;
                break;
            }
        }
        for (uint256 i = 0; i < sales.length; i++) {
            address t = sales[(i + seed) % sales.length];
            if (_saleQuote(t) == address(wbnb) && !_launched(t)) {
                tf = t;
                break;
            }
        }
        if (t3 == address(0) || tf == address(0)) return;
        mixedRounds++;
        address who = _actor(seed);
        if (seed % 2 == 0) {
            _v3BuyOne(t3, who, amount, 0);
            _fairMintOne(tf, who, shares, false);
            _checkpoint();
            _fairWithdrawOne(tf, who, shares >> 1);
            _v3SellOne(t3, who, amount);
        } else {
            _fairMintOne(tf, who, shares, seed % 3 == 0);
            _v3BuyOne(t3, who, amount, uint8(seed));
            _checkpoint();
            _v3SellOne(t3, who, amount);
            _fairWithdrawOne(tf, who, shares >> 1);
        }
    }

    function warp(uint256 dt) external action {
        // up to 8 days: long enough for a sale to go stale (no mint for 7 days → no exit fee)
        vm.warp(block.timestamp + bound(dt, 1 minutes, 8 days));
        vm.roll(block.number + 1);
    }

    function _afterSale(address t) internal {
        address pair = _salePair(t);
        if (_launched(t) && !isHolder[pair]) {
            fairLaunches++;
            _track(pair);
        }
    }

    function _recordOut(address t) internal {
        for (uint256 i = 0; i < actors.length; i++) {
            if (handler.isOut(t, actors[i])) everOut[t][actors[i]] = true;
        }
    }
}

/// @notice Fund-conservation invariants of docs/AUDIT-BRIEF-2026-10-26.md §5, on the merged system (merge plan §5.4,
///         §7.2), checked after every random call. CI runs 24 × 50; before release run 200 × 80 (raise the numbers
///         below).
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = false
contract CoreInvariantsTest is Test {
    CoreHandler internal h;

    function setUp() public {
        h = new CoreHandler();
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](32);
        sel[0] = CoreHandler.v3Create.selector;
        sel[1] = CoreHandler.v3Buy.selector;
        sel[2] = CoreHandler.v3Sell.selector;
        sel[3] = CoreHandler.v3Graduate.selector;
        sel[4] = CoreHandler.v3PoolTrade.selector;
        sel[5] = CoreHandler.v3Transfer.selector;
        sel[6] = CoreHandler.v3Process.selector;
        sel[7] = CoreHandler.v3Claim.selector;
        sel[8] = CoreHandler.blockRecipient.selector;
        sel[9] = CoreHandler.v3Release.selector;
        sel[10] = CoreHandler.fairCreate.selector;
        sel[11] = CoreHandler.fairMint.selector;
        sel[12] = CoreHandler.fairWithdraw.selector;
        sel[13] = CoreHandler.fairWithdraw.selector;
        sel[14] = CoreHandler.fairFill.selector;
        sel[15] = CoreHandler.fairPoolTrade.selector;
        sel[16] = CoreHandler.fairTransfer.selector;
        sel[17] = CoreHandler.fairProcess.selector;
        sel[18] = CoreHandler.fairClaim.selector;
        sel[19] = CoreHandler.warp.selector;
        // weights: trades, the blacklist toggle, time and withdraws come up more often so owed tax and stale exits
        // are reached in most runs
        sel[20] = CoreHandler.v3Buy.selector;
        sel[21] = CoreHandler.blockRecipient.selector;
        sel[22] = CoreHandler.warp.selector;
        sel[23] = CoreHandler.fairWithdraw.selector;
        sel[24] = CoreHandler.fairMint.selector;
        sel[25] = CoreHandler.v3Release.selector;
        sel[26] = CoreHandler.v3Create.selector;
        // merge: same-WBNB alternation of both kinds, and the exit-fee flush
        sel[27] = CoreHandler.mixedWbnb.selector;
        sel[28] = CoreHandler.mixedWbnb.selector;
        sel[29] = CoreHandler.mixedWbnb.selector;
        sel[30] = CoreHandler.fairFlushFees.selector;
        sel[31] = CoreHandler.v3ClaimCreatorFee.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    // ---------------------------------------------------------------- the pad's money (§5 #1 + #7 → §5.4)
    /// @dev Per quote: balanceOf(pad) == Σ not-launched sales' live principal + owedFee + Σ not-graduated curves'
    ///      realQuote + Σ curves' unclaimed creator fee + dust, with dust ≥ 0 after every call and never shrinking. A sell-back or launch that took
    ///      curve quote, or a graduation that took escrowed principal, makes the dust negative or shrink.
    function invariant_padQuoteIdentity() public view {
        address[3] memory qs = h.quotes();
        GangLaunchpad pad = h.pad();
        for (uint256 k = 0; k < 3; k++) {
            uint256 bal = IERC20(qs[k]).balanceOf(address(pad));
            uint256 acc = h.accountedOf(qs[k]);
            assertGe(bal, acc, "pad quote >= escrow + owed fees + live realQuote");
            assertEq(bal - acc, h.lastDust(qs[k]), "dust as recorded after the last call");
        }
        assertEq(h.dustNegative(), 0, "dust went negative after some call");
        assertEq(h.dustShrank(), 0, "dust shrank after some call");
    }

    /// @dev #2 / #3: positions add up, caps hold, tokens are where the shares / the curve say — both kinds in one pad.
    function invariant_padTokens() public view {
        GangLaunchpad pad = h.pad();
        for (uint256 i = 0; i < h.saleCount(); i++) {
            address t = h.sales(i);
            (,, uint16 cap,,, uint16 sold, bool launched,,,,,,,) = pad.sales(t);
            assertLe(sold, 10_000, "sold <= 10,000");
            uint256 sumShares;
            for (uint256 j = 0; j < h.holderCount(); j++) {
                uint16 s = pad.positions(t, h.holders(j));
                assertLe(s, cap, "shares <= cap");
                sumShares += s;
            }
            assertEq(sumShares, sold, "sold == sum shares");
            uint256 padTokens = IERC20(t).balanceOf(address(pad));
            if (launched) assertEq(padTokens, 0, "pad holds no token after launch");
            else assertEq(padTokens, 1_000_000_000 ether - sumShares * 50_000 ether, "pad holds the unminted supply");
        }
        for (uint256 i = 0; i < h.v3TokenCount(); i++) {
            address t = h.v3Tokens(i);
            (,,, uint128 sold,,, bool graduated,,,,,) = pad.curves(t);
            uint256 padTokens = IERC20(t).balanceOf(address(pad));
            if (graduated) assertEq(padTokens, 0, "pad holds no token after graduation");
            else assertEq(padTokens, 1_000_000_000 ether - sold, "pad holds the unsold supply");
        }
    }

    // ---------------------------------------------------------------- kinds
    /// @dev New: kindOf is written once at create and never changes; the handler's route kind agrees (taxed tokens),
    ///      untaxed V3 tokens are never registered, and a sale has no curve / a curve no baseline.
    function invariant_kindFixed() public view {
        GangLaunchpad pad = h.pad();
        GangTaxHandler handler = h.handler();
        for (uint256 i = 0; i < h.v3TokenCount(); i++) {
            address t = h.v3Tokens(i);
            assertEq(h.kindAtCreate(t), 1, "curve kind at create");
            assertEq(pad.kindOf(t), 1, "curve kind fixed");
            (,,, uint8 rk) = handler.routeOf(t);
            (uint16 b,,,) = pad.taxConfigOf(t);
            assertEq(rk, b == 0 ? 0 : 1, "handler route kind (untaxed: none)");
            assertEq(pad.baselineOf(t, h.actors(0)), 0, "no baseline on a curve token");
        }
        for (uint256 i = 0; i < h.saleCount(); i++) {
            address t = h.sales(i);
            assertEq(h.kindAtCreate(t), 2, "fair kind at create");
            assertEq(pad.kindOf(t), 2, "fair kind fixed");
            (,,, uint8 rk) = handler.routeOf(t);
            assertEq(rk, 2, "handler route kind (fair)");
            (address cq,,,,,,,,,,,) = pad.curves(t);
            assertEq(cq, address(0), "a sale has no curve");
        }
    }

    /// @dev #6 on the merged handler + new: once out, always out; a 打新 reward weight never exceeds the launch
    ///      baseline and is 0 once out.
    function invariant_fairRewardWeights() public view {
        GangLaunchpad pad = h.pad();
        SharedDividendVault vault = h.divVault();
        GangTaxHandler handler = h.handler();
        for (uint256 i = 0; i < h.saleCount(); i++) {
            address t = h.sales(i);
            (,,,,,, bool launched,,,,,,,) = pad.sales(t);
            if (!launched) continue;
            for (uint256 j = 0; j < h.holderCount(); j++) {
                address u = h.holders(j);
                bool out = handler.isOut(t, u);
                if (h.everOut(t, u)) assertTrue(out, "out stays out");
                assertLe(vault.shares(t, u), pad.baselineOf(t, u), "weight <= baseline");
                if (out) assertEq(vault.shares(t, u), 0, "out: weight 0");
            }
        }
    }

    // ---------------------------------------------------------------- the handler's money (#9, extended)
    /// @dev Per quote: the one handler holds at least what it owes recipients (owedTotalOf), what the bucket refused
    ///      (owedPlatformOf) and the holders' quote still waiting for the vault (Σ pendingHolderQuote, both kinds);
    ///      owedTotalOf is exactly Σ owedOf.
    function invariant_handlerOwedBacked() public view {
        GangTaxHandler r = h.handler();
        address[3] memory qs = h.quotes();
        for (uint256 k = 0; k < 3; k++) {
            uint256 owed;
            uint256 pendingHolders;
            for (uint256 i = 0; i < h.v3TokenCount(); i++) {
                address t = h.v3Tokens(i);
                (address q,,,) = r.routeOf(t);
                if (q != qs[k]) continue;
                owed += r.owedOf(t);
                pendingHolders += r.pendingHolderQuote(t);
            }
            for (uint256 i = 0; i < h.saleCount(); i++) {
                address t = h.sales(i);
                (address q,,,) = r.routeOf(t);
                if (q != qs[k]) continue;
                assertEq(r.owedOf(t), 0, "fair: no recipient, nothing owed");
                pendingHolders += r.pendingHolderQuote(t);
            }
            assertEq(r.owedTotalOf(qs[k]), owed, "owedTotalOf == sum of owedOf");
            assertGe(
                IERC20(qs[k]).balanceOf(address(r)),
                owed + r.owedPlatformOf(qs[k]) + pendingHolders,
                "handler quote >= owed + platform owed + pending holder quote"
            );
        }
    }

    /// @dev #10: tax config never changes after create.
    function invariant_v3ConfigImmutable() public view {
        for (uint256 i = 0; i < h.v3TokenCount(); i++) {
            address t = h.v3Tokens(i);
            (uint16 b, uint16 s, uint16 d, address r) = h.pad().taxConfigOf(t);
            assertEq(keccak256(abi.encode(b, s, d, r)), h.v3ConfigHash(t), "tax config immutable");
        }
    }

    /// @dev Spec §19 (feat/v3-no-curve-tax, kept): a curve trade (buy direct / via the router / with BNB, or sell)
    ///      pays exactly the 1% protocol fee to the bucket and moves nothing to the recipient, the dividend vault or
    ///      the tax handler.
    function invariant_v3CurveNoTax() public view {
        assertEq(h.curveTaxLeaks(), 0, "curve trade paid a tax");
        assertEq(h.curveFeeOff(), 0, "curve fee != 1%");
        assertEq(h.creatorFeeOff(), 0, "creator part != 70% of the fee, or a claim paid the wrong amount");
        for (uint256 i = 0; i < h.v3TokenCount(); i++) {
            // holders earn only from the pool tax: before graduation nothing is credited to a V3 token's holders
            address t = h.v3Tokens(i);
            (,,,,,, bool graduated,,,,,) = h.pad().curves(t);
            if (!graduated) assertEq(h.divVault().unsoldUnits(t), 0, "no curve dividend");
        }
    }

    /// @dev The sequence that once failed invariant_v3CurveNoTax: a BNB buy over the 1% cap, whose cut came back as
    ///      WBNB and was counted as paid.
    function test_v3CurveNoTax_bnbBuyCutRefund() public {
        h.fairCreate(17527, 1084181109, 11680, 7510, 7965);
        h.v3Create(164, 2994, 8738, 42748, false);
        h.mixedWbnb(1907, 40 ether, 1691192412);
        assertEq(h.curveTrades(), 2, "buy and sell reached the curve");
        invariant_v3CurveNoTax();
    }

    // ---------------------------------------------------------------- shared sinks and the router (§5 #11, #12)
    /// @dev The bucket holds what it accounts for; the vault can pay every holder's pending rewards.
    function invariant_sinksSolvent() public view {
        address[3] memory qs = h.quotes();
        SharedPlatformFeeBucket b = h.bucket();
        for (uint256 k = 0; k < 3; k++) {
            assertGe(IERC20(qs[k]).balanceOf(address(b)), b.accruedQuote(qs[k]), "bucket >= accrued");
            assertGe(IERC20(qs[k]).balanceOf(address(h.divVault())), _pendingSum(qs[k]), "vault >= pending");
        }
    }

    /// @dev #12 (tax-time dividends): the vault holds every holder's claimable quote plus the quote of batches still
    ///      being sold; the one handler holds at least each token's accrued tax, the holders' unsold units are part of
    ///      it, and the units credited to holders never exceed those of the unsettled batches.
    function invariant_taxTimeDividendsBacked() public view {
        SharedDividendVault vault = h.divVault();
        address[3] memory qs = h.quotes();
        for (uint256 k = 0; k < 3; k++) {
            assertGe(
                IERC20(qs[k]).balanceOf(address(vault)),
                _pendingSum(qs[k]) + _sellingQuote(qs[k]),
                "vault >= claimable + selling batches"
            );
        }
        GangTaxHandler r = h.handler();
        for (uint256 i = 0; i < h.v3TokenCount() + h.saleCount(); i++) {
            _checkUnits(vault, r, _tokenAt(i));
        }
    }

    function _tokenAt(uint256 i) internal view returns (address) {
        uint256 n = h.v3TokenCount();
        return i < n ? h.v3Tokens(i) : h.sales(i - n);
    }

    function _sellingQuote(address quote) internal view returns (uint256 sum) {
        SharedDividendVault vault = h.divVault();
        for (uint256 i = 0; i < h.v3TokenCount() + h.saleCount(); i++) {
            address t = _tokenAt(i);
            if (vault.quoteOf(t) != quote) continue;
            (, uint64 selling,) = vault.pipeOf(t);
            if (selling == 0) continue;
            (,, uint256 q,,) = vault.batchOf(t, selling);
            sum += q;
        }
    }

    function _checkUnits(SharedDividendVault vault, GangTaxHandler r, address t) internal view {
        uint256 accrued = r.accruedTax(t);
        uint256 unsold = vault.unsoldUnits(t) - r.pendingHolderUnits(t);
        assertGe(accrued, unsold, "holders' unsold units are part of the accrued tax");
        assertGe(IERC20(t).balanceOf(address(r)), accrued, "handler holds its accrued tax");
        // holders' units wait for their batch to settle: at most the units of the unsettled batches
        (uint64 open, uint64 selling,) = vault.pipeOf(t);
        uint256 unsettled;
        if (selling != 0) {
            (uint128 su,,,,) = vault.batchOf(t, selling);
            unsettled += su;
        }
        if (open != 0) {
            (uint128 ou,,,,) = vault.batchOf(t, open);
            unsettled += ou;
        }
        uint256 credited;
        for (uint256 j = 0; j < h.holderCount(); j++) {
            credited += vault.pendingUnits(t, h.holders(j));
        }
        assertLe(credited, unsettled, "units credited <= units of the unsettled batches");
    }

    function _pendingSum(address quote) internal view returns (uint256 sum) {
        SharedDividendVault vault = h.divVault();
        for (uint256 i = 0; i < h.v3TokenCount() + h.saleCount(); i++) {
            address t = _tokenAt(i);
            if (vault.quoteOf(t) != quote) continue;
            for (uint256 j = 0; j < h.holderCount(); j++) {
                sum += vault.pending(t, h.holders(j));
            }
        }
    }

    /// @dev #11: the router never keeps anything between calls.
    function invariant_routerEmpty() public view {
        address[3] memory qs = h.quotes();
        for (uint256 k = 0; k < 3; k++) {
            assertEq(IERC20(qs[k]).balanceOf(address(h.router())), 0, "router quote");
        }
        assertEq(address(h.router()).balance, 0, "router BNB");
    }

    /// @dev Coverage report: how much of the state space each run reached (-vv).
    function afterInvariant() external view {
        console2.log("calls / v3 tokens / graduations", h.calls(), h.v3TokenCount(), h.v3Graduations());
        console2.log("  owed events / sales / launches", h.owedEvents(), h.saleCount(), h.fairLaunches());
        console2.log("  stale exits / blq tokens / blocked set", h.staleExits(), h.blqTokens(), h.blockedSet());
        console2.log("  self-recipient V3 tokens", h.selfRecipientTokens());
        console2.log("  curve trades checked for no tax / same-WBNB mixed rounds", h.curveTrades(), h.mixedRounds());
        console2.log("  router buys / mints", h.routerTrades());
        console2.log("  creator fee claims", h.creatorClaims());
    }
}
