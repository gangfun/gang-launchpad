// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV2PairLite} from "../launchpad-v2/interfaces/IUniswapV2PairLite.sol";
import {IGangLaunchpad} from "../gang/interfaces/IGangLaunchpad.sol";
import {PadCommon} from "../gang/PadCommon.sol";
import {IFlywheelPad} from "./interfaces/IFlywheelPad.sol";
import {FlywheelLogic, IFlyToken, IFlyHandler} from "./FlywheelLogic.sol";
import {FlywheelOracle} from "./FlywheelOracle.sol";

interface IFlyPair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function mint(address to) external returns (uint256 liquidity);
    function sync() external;
}

/// @title FlywheelPostLogic — GangFlywheelPad's post-launch mint
/// @notice External library (delegatecalled by the pad). A wallet mints within its quota (shared with pre-launch) at the
///         tier price per share; it gets the share's money worth of tokens at the higher of the pair's price now and
///         at the block's start (V2: a dump earlier in the same block can't make a mint cheaper; from the next block on
///         a mint pays the pool's price). The mint fee goes to the platform, the dev's cut to the creator, and
///         everything else into the pool: `buyBps` of it buys from the pair (never pushing the price more than 0.8%
///         above the lower of the price now and the block's start, so neither one mint nor several in a block can be
///         sold back at a profit), the rest is added as liquidity with newly minted tokens (LP to 0xdead). Refused when
///         that price is more than 10% above the pool (only in the block of a dump: an honest minter is never charged
///         far above the pool), when the sale's guard is on and the pair's price is more than `guardBps` below its TWAP
///         over the sale's `twapWindow`, and when the wallet's mints in the last 30 minutes would pass 2% of the pool's
///         quote. A wallet that fell below its hold line qualifies again from this mint's tokens.
library FlywheelPostLogic {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal constant BPS = 10_000;
    /// @dev The pre-launch shares (FlywheelLogic.TOTAL_SHARES): the tiers start above them.
    uint256 internal constant PRE_SHARES = 10_000;
    /// @notice A mint's pool buy never lifts the price above this far over min(price now, block-start price).
    uint256 internal constant PUSH_BPS = 80;
    /// @notice A mint is refused rather than priced more than this above the pool (re-review R6 L-1): with the price
    ///         max(spot, blockStart) that is only in the block of a dump.
    uint256 internal constant ABOVE_POOL_BPS = 1_000;
    /// @notice One wallet's mints per PACE_WINDOW stay within this share of the pool's quote reserve.
    uint256 internal constant PACE_POOL_BPS = 200;
    uint256 internal constant PACE_WINDOW = 30 minutes;
    uint256 internal constant DEX_FEE_NUM = 9975;
    uint256 internal constant DEX_FEE_DEN = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Quote {
        uint256 accepted;
        uint256 paid; // P: the shares' price
        uint256 fee;
        uint256 devCut;
        uint256 tokensOut;
    }

    /// @notice What a post-launch mint is priced and checked with now (also the pad's `previewMintPost`).
    struct Pricing {
        uint256 rT; // pair reserves (token, quote)
        uint256 rQ;
        uint256 spot; // UQ112x112 quote per token
        uint256 blockStart;
        uint256 price; // max(spot, blockStart): the buyer's price
        bool belowAverage; // the guard refuses (PriceBelowAverage)
        bool abovePool; // price more than ABOVE_POOL_BPS above spot (PriceAbovePool)
    }

    function mintPost(
        mapping(address => IFlywheelPad.Sale) storage sales,
        mapping(address => mapping(address => IFlywheelPad.Account)) storage accounts,
        mapping(address => uint256) storage owedDev,
        mapping(address => IFlywheelPad.PostRules) storage postRules,
        IGangLaunchpad.Deps memory d,
        address trader,
        address token,
        uint256 shares,
        uint256 minTokensOut,
        uint256 maxSpent,
        address referrer,
        uint256 bnbIn
    ) external returns (uint256 tokensOut, uint256 spent) {
        if (shares == 0) revert IFlywheelPad.ZeroAmount();
        IFlywheelPad.Sale storage s = sales[token];
        if (s.creator == address(0)) revert IFlywheelPad.UnknownToken();
        if (!s.launched) revert IFlywheelPad.NotLaunched();
        if (!s.postMint) revert IFlywheelPad.PostMintOff();
        FlywheelLogic._requireAgent(s.gate, trader);
        IFlywheelPad.Account storage a = accounts[token][trader];

        Quote memory q;
        q.accepted = FlywheelLogic._acceptable(s, a, shares, type(uint256).max);
        if (q.accepted == 0) revert IFlywheelPad.ZeroAmount();
        q.paid = (q.accepted * s.basePrice * tierX100(s, uint256(s.totalShares) + q.accepted)) / 100;
        q.fee = (q.paid * s.mintFeeBps) / BPS;
        // no cut on the creator's own mints: it would come straight back to it (internal audit B-M1)
        q.devCut = trader == s.creator ? 0 : (q.paid * s.devCutBps) / BPS;
        // a tier step crossed by an earlier mint raises both the price and the tokens, so minTokensOut alone does not
        // bound the spend (audit B-I1)
        spent = q.paid + q.fee;
        if (spent > maxSpent) revert IFlywheelPad.Slippage();
        // paid in before any price is read: a quote calling the payer back (ERC777-style) moves the pool before the
        // checks, not between them and the buy; the fee and the cut go out last (audit B-L1)
        FlywheelLogic.collect(s.quote, spent, bnbIn);

        IFlyHandler(d.taxHandler).observe(token);
        address pair = s.pair;
        Pricing memory p = pricing(d.taxHandler, token, pair, postRules[token]);
        if (p.belowAverage) revert IFlywheelPad.PriceBelowAverage();
        _pace(a, q.paid, p.rQ);
        if (p.abovePool) revert IFlywheelPad.PriceAbovePool();
        q.tokensOut = Math.mulDiv(q.paid, 1 << 112, p.price);
        if (q.tokensOut < minTokensOut) revert IFlywheelPad.Slippage();
        uint256 net = q.paid - q.devCut;
        uint256 b = _buyPart(s.buyBps, net, p.spot, p.blockStart, p.rQ);
        uint256 bought = b == 0 ? 0 : _buy(pair, token, s.quote, b, p.rT, p.rQ);
        if (bought == 0) b = 0; // a buy too small to get a token (nothing was sent): it joins the liquidity (B-I1)
        _addLiquidity(pair, token, s.quote, net - b);

        uint32 n = q.accepted.toUint32();
        a.used += n;
        s.totalShares += n;
        FlywheelLogic.refer(s, accounts, token, trader, a, referrer);

        // tokens first, against the old baseline (a delivery in two parts must not look like a sale below the hold
        // line); then the new baseline — from zero for a wallet that was out — and one share sync
        _deliver(token, trader, q.tokensOut, bought);
        if (IFlyHandler(d.taxHandler).isOut(token, trader)) {
            a.baseline = 0;
            IFlyHandler(d.taxHandler).requalify(token, trader);
        }
        a.baseline += q.tokensOut;
        IFlyHandler(d.taxHandler).syncShares(token, trader, trader);
        PadCommon.toPlatform(d, s.quote, q.fee);
        FlywheelLogic.payDev(owedDev, s, token, q.devCut);
        tokensOut = q.tokensOut;
        emit IFlywheelPad.PostMinted(token, trader, q.accepted, q.paid, q.fee, q.devCut, q.tokensOut, b);
    }

    /// @notice The price a mint gives tokens at, and the price refusals. Price: the higher of the pair's price now and
    ///         at the block's start (no same-block dump-then-mint). Refused when that is more than ABOVE_POOL_BPS above
    ///         the pool (`abovePool`), and, with the sale's guard on, when the pair's price is more than `guardBps`
    ///         below its TWAP over the sale's window (`belowAverage`; the TWAP is not read with the guard off).
    function pricing(address handler, address token, address pair, IFlywheelPad.PostRules memory r)
        internal
        view
        returns (Pricing memory p)
    {
        (p.rT, p.rQ) = _reserves(pair, token);
        p.spot = FlywheelOracle.spotFrom(p.rT, p.rQ);
        p.blockStart = FlywheelOracle.blockStart(handler, token, p.spot);
        p.price = p.spot > p.blockStart ? p.spot : p.blockStart;
        p.abovePool = p.price * BPS > p.spot * (BPS + ABOVE_POOL_BPS);
        if (r.guardBps != 0) {
            uint256 average = FlywheelOracle.twap(handler, token, pair, r.twapWindow);
            p.belowAverage = p.spot * BPS < average * (BPS - r.guardBps);
        }
    }

    /// @notice Price multiple (×100) of the share numbered `n` (pre-launch shares count, so share 10,001 is the first
    ///         post-launch share of a filled sale): flat, the standard table (as the Agent ID mint projects use: ×1 up to
    ///         share 10,000, then steps to ×8.07 at 4,440,000) or linear: ×1 up to share 10,000, then `stepBps` more
    ///         every `stepShares` shares counted from share 10,001 (audit V2 A-M1: counting the pre-launch shares put
    ///         the first post-launch share of a steep sale at the cap already), at most `maxMulX100`.
    function tierX100(IFlywheelPad.Sale storage s, uint256 n) internal view returns (uint256) {
        uint8 mode = s.tierMode;
        if (mode == 0) return 100;
        if (mode == 2) {
            if (n <= PRE_SHARES) return 100;
            uint256 m = 100 + (uint256(s.stepBps) * ((n - PRE_SHARES - 1) / s.stepShares)) / 100;
            return m > s.maxMulX100 ? s.maxMulX100 : m;
        }
        return standardX100(n);
    }

    function standardX100(uint256 n) internal pure returns (uint256) {
        if (n <= 10_000) return 100;
        if (n <= 20_000) return 110 + 10 * ((n - 10_001) / 1_000);
        if (n <= 100_000) return 210 + 2 * ((n - 20_001) / 1_000);
        if (n <= 1_000_000) return 370 + 2 * ((n - 100_001) / 10_000);
        if (n <= 4_440_000) return 550 + (15 * ((n - 1_000_001) / 20_000) + 5) / 10; // +0.015, to the cent
        return 807;
    }

    // ---------------------------------------------------------------- internal
    /// @dev A sliding window (audit B-L1: a fixed window let a wallet spend its allowance at a window's end and again
    ///      at the next one's start): what the wallet minted decays linearly to zero over PACE_WINDOW, and the decayed
    ///      amount plus this mint must stay within PACE_POOL_BPS of the pool's quote. `windowStart` = last update.
    function _pace(IFlywheelPad.Account storage a, uint256 paid, uint256 rQ) private {
        uint256 total = recentSpent(a) + paid;
        if (total * BPS > rQ * PACE_POOL_BPS) revert IFlywheelPad.PaceExceeded();
        a.windowStart = uint64(block.timestamp);
        a.windowSpent = total.toUint128();
    }

    /// @notice What the wallet minted recently, decayed linearly over PACE_WINDOW since its last mint.
    function recentSpent(IFlywheelPad.Account storage a) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - a.windowStart;
        if (elapsed >= PACE_WINDOW) return 0;
        return (uint256(a.windowSpent) * (PACE_WINDOW - elapsed)) / PACE_WINDOW;
    }

    /// @dev The quote to buy: `buyBps` of the pool money, cut to what lifts the price to PUSH_BPS over the lower of the
    ///      price now and the block's start (0 once others in the block already lifted it that far).
    function _buyPart(uint256 buyBps, uint256 net, uint256 spot, uint256 blockStart, uint256 rQ)
        private
        pure
        returns (uint256)
    {
        uint256 want = (net * buyBps) / BPS;
        if (want == 0) return 0;
        uint256 ref = spot < blockStart ? spot : blockStart;
        uint256 limit = (ref * (BPS + PUSH_BPS)) / BPS;
        if (limit <= spot) return 0;
        uint256 max = quoteToRaise(rQ, spot, limit);
        return want < max ? want : max;
    }

    /// @notice Quote a buy needs so the price ends at `target` (from `spot`, quote reserve `y`): the positive root of
    ///         (y + B)(y + γB) = (target / spot)·y², γ the Pancake V2 fee factor.
    function quoteToRaise(uint256 y, uint256 spot, uint256 target) internal pure returns (uint256) {
        if (target <= spot) return 0;
        uint256 g = (1e18 * DEX_FEE_NUM) / DEX_FEE_DEN;
        uint256 f1 = Math.mulDiv(target - spot, 1e18, spot); // target / spot − 1, 1e18 scale
        uint256 onePlusG = 1e18 + g;
        uint256 root = Math.sqrt(onePlusG * onePlusG + 4 * g * f1);
        return Math.mulDiv(y, root - onePlusG, 2 * g);
    }

    /// @notice Tokens a mint priced with `p` newly mints, exactly as `mintPost` does (the pad's `previewMintPost`
    ///         checks them against the supply cap; audit V2 B-1): the liquidity's tokens at the reserves after the pool
    ///         buy, plus the buyer's tokens beyond what the buy got.
    /// @param net the pool money: paid less the dev's cut
    function newlyMinted(
        Pricing memory p,
        address pair,
        address token,
        address quote,
        uint256 buyBps,
        uint256 net,
        uint256 tokensOut
    ) internal view returns (uint256) {
        uint256 b = _buyPart(buyBps, net, p.spot, p.blockStart, p.rQ);
        uint256 bought = b == 0 ? 0 : _amountOut(b, p.rT, p.rQ);
        uint256 rT = p.rT;
        uint256 rQ = p.rQ;
        if (bought == 0) {
            b = 0;
        } else {
            // the swap leaves the pair's reserves at its balances
            rT = IERC20(token).balanceOf(pair) - bought;
            rQ = IERC20(quote).balanceOf(pair) + b;
        }
        uint256 liquidity = ((net - b) * rT) / rQ;
        return liquidity + (tokensOut > bought ? tokensOut - bought : 0);
    }

    /// @dev Pancake V2 tokens out for `quoteIn` against reserves `rT` (token) and `rQ` (quote).
    function _amountOut(uint256 quoteIn, uint256 rT, uint256 rQ) private pure returns (uint256) {
        uint256 inFee = quoteIn * DEX_FEE_NUM;
        return (inFee * rT) / (rQ * DEX_FEE_DEN + inFee);
    }

    /// @dev Buy with `quoteIn` straight from the pair (the pad is tax-excluded); the tokens come here.
    function _buy(address pair, address token, address quote, uint256 quoteIn, uint256 rT, uint256 rQ)
        private
        returns (uint256 out)
    {
        out = _amountOut(quoteIn, rT, rQ);
        if (out == 0) return 0;
        IERC20(quote).safeTransfer(pair, quoteIn);
        if (IUniswapV2PairLite(pair).token0() == token) IFlyPair(pair).swap(out, 0, address(this), "");
        else IFlyPair(pair).swap(0, out, address(this), "");
    }

    /// @dev `quoteIn` and newly minted tokens at the pair's price, LP to 0xdead. If the pair can't mint LP for it (a
    ///      dust amount), what was sent joins the reserves (`sync`) rather than sitting there for anyone to skim.
    function _addLiquidity(address pair, address token, address quote, uint256 quoteIn) private {
        if (quoteIn == 0) return;
        (uint256 rT, uint256 rQ) = _reserves(pair, token);
        uint256 tokens = (quoteIn * rT) / rQ;
        IERC20(quote).safeTransfer(pair, quoteIn);
        if (tokens != 0) IFlyToken(token).padMint(pair, tokens);
        try IFlyPair(pair).mint(DEAD) {}
        catch {
            IFlyPair(pair).sync();
        }
    }

    /// @dev The buyer's tokens: the ones bought first, the rest minted (bought beyond them — possible when the buyer's
    ///      price is above spot after a drop — goes to 0xdead).
    function _deliver(address token, address to, uint256 amount, uint256 bought) private {
        if (bought >= amount) {
            IERC20(token).safeTransfer(to, amount);
            if (bought > amount) IERC20(token).safeTransfer(DEAD, bought - amount);
        } else {
            if (bought != 0) IERC20(token).safeTransfer(to, bought);
            IFlyToken(token).padMint(to, amount - bought);
        }
    }

    function _reserves(address pair, address token) internal view returns (uint256 rT, uint256 rQ) {
        (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pair).getReserves();
        (rT, rQ) = IUniswapV2PairLite(pair).token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }
}
