// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGangPadRegistry} from "./interfaces/IGangPadRegistry.sol";
import {IGangLaunchpad} from "./interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "./interfaces/IGangLaunchpad3.sol";
import {IFlywheelPad} from "../flywheel/interfaces/IFlywheelPad.sol";
import {IGangGatewayPad, IGangGatewayFlywheel} from "../router/GangGateway.sol";

/// @title LegacyRoute — GangLaunchpad 3.0's aggregator entry for tokens of the pads before it
/// @notice External library, delegatecalled by GangLaunchpad3: GangGateway's logic (V2, AUDIT-BRIEF §25–§26) for the
///         tokens of the other pads GangPadRegistry trusts (1.0, 2.0, the vault pad: kind 1 curves; 铸币飞轮 V1 / V2:
///         kind 3), with 3.0 as the listed router on those pads (each pad's `setRouter(3.0, true)`). Running on the
///         pad, it spends only what the caller paid in for the trade: the pad wraps / pulls the funds first and
///         checks afterwards that its own balance of the quote is back where it was (EscrowMoved), so a forwarded
///         trade never reaches the escrow of 3.0's own tokens. Every rule of the old pads stays theirs (price, fee,
///         Agent gate, wallet cap, trader == tx.origin, graduation, the sale rules).
/// @dev Views return what the Gateway returns for the same token. `tokenManager` / the quote as address(0) for WBNB
///      are filled in by the pad.
library LegacyRoute {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PROTOCOL_FEE_BPS = 100;
    uint8 internal constant KIND_CURVE = 1;
    uint8 internal constant KIND_FAIR = 2;
    uint8 internal constant KIND_FLY = 3;
    /// @dev FlywheelLogic.LAUNCH_GRACE (V1 = V2).
    uint256 internal constant FLY_LAUNCH_GRACE = 7 days;
    uint8 internal constant STATUS_NONE = 0;
    uint8 internal constant STATUS_CURVE = 1;
    uint8 internal constant STATUS_POOL = 2;
    uint8 internal constant STATUS_MINTING = 3;

    // ---------------------------------------------------------------- views (GangGateway's)
    /// @notice getTokenInfo for a token of another registered pad; the quote as the token's own (WBNB stays WBNB).
    function info(IGangPadRegistry registry, address token)
        public
        view
        returns (uint8 status, address quote, address pair, uint256 protocolFeeBps, uint256 graduationLeft)
    {
        (address pad, uint8 kind) = registry.lookup(token);
        if (pad == address(0) || pad == address(this)) return (STATUS_NONE, address(0), address(0), 0, 0);
        if (kind == KIND_CURVE) {
            (, address q, uint128 realQuote,, uint128 gradAmt,, bool graduated,,,, address p,) =
                IGangGatewayPad(pad).curves(token);
            if (graduated) return (STATUS_POOL, q, p, 0, 0);
            return (STATUS_CURVE, q, address(0), PROTOCOL_FEE_BPS, gradAmt - realQuote);
        }
        if (kind == KIND_FAIR) {
            (,,,, address q,, bool launched,,,,, address p,,) = IGangGatewayPad(pad).sales(token);
            if (launched) return (STATUS_POOL, q, p, 0, 0);
            return (STATUS_MINTING, q, address(0), 0, 0);
        }
        if (kind == KIND_FLY) {
            IGangGatewayFlywheel f = IGangGatewayFlywheel(pad);
            IFlywheelPad.Sale memory s = f.sales(token);
            if (s.launched) return (STATUS_POOL, s.quote, s.pair, 0, 0);
            return (STATUS_CURVE, s.quote, address(0), s.mintFeeBps, (f.TOTAL_SHARES() - s.sold) * s.basePrice);
        }
    }

    /// @notice tryBuy's estimates for a token of another registered pad (all 0 when the buy would revert).
    function tryBuy(IGangPadRegistry registry, address token, address trader, uint256 funds)
        external
        view
        returns (address quote, uint256 estimatedAmount, uint256 estimatedCost, uint256 estimatedFee)
    {
        uint8 status;
        (status, quote,,,) = info(registry, token);
        (address pad, uint8 kind) = registry.lookup(token);
        if (status == STATUS_NONE) return (quote, 0, 0, 0);
        if (kind == KIND_FLY) {
            (, estimatedAmount, estimatedCost, estimatedFee) =
                _flyQuote(IGangGatewayFlywheel(pad), token, trader, funds);
        } else if (status == STATUS_CURVE) {
            IGangGatewayPad p = IGangGatewayPad(pad);
            if (p.routers(address(this)) && p.agentGateEnabled()) {
                (estimatedAmount, estimatedCost, estimatedFee,) = registry.previewBuy(token, trader, funds);
            }
        }
    }

    /// @notice trySell's result for a token of another registered pad (0, 0 when the sell would revert).
    function trySell(IGangPadRegistry registry, address token, uint256 amount)
        external
        view
        returns (address quote, uint256 funds, uint256 fee)
    {
        uint8 status;
        (status, quote,,,) = info(registry, token);
        if (status != STATUS_CURVE) return (quote, 0, 0);
        (address pad, uint8 kind) = registry.lookup(token);
        if (!IGangGatewayPad(pad).routers(address(this))) return (quote, 0, 0);
        if (kind == KIND_FLY) {
            IGangGatewayFlywheel f = IGangGatewayFlywheel(pad);
            IFlywheelPad.Sale memory s = f.sales(token);
            uint256 shares = _wholeShares(f, amount);
            if (shares == 0 || shares > s.sold || s.gate == address(0) || !_withdrawable(s)) return (quote, 0, 0);
            uint256 principal = shares * s.basePrice;
            fee = (principal * f.exitFeeBpsOf(token)) / BPS;
            funds = principal - fee;
        } else {
            (funds, fee) = registry.previewSell(token, address(0), amount);
        }
    }

    // ---------------------------------------------------------------- trades
    /// @notice The quote and pad of a token another registered pad trades on its curve / in its sale now (reverts
    ///         NotCurveToken otherwise): what the pad pays in before `buy`.
    function quoteOf(IGangPadRegistry registry, address token) external view returns (address quote) {
        (address pad, uint8 kind) = registry.lookup(token);
        if (pad == address(0) || pad == address(this)) revert IGangLaunchpad3.NotCurveToken();
        if (kind == KIND_CURVE) {
            bool graduated;
            (, quote,,,,, graduated,,,,,) = IGangGatewayPad(pad).curves(token);
            if (graduated) revert IGangLaunchpad3.NotCurveToken();
        } else if (kind == KIND_FLY) {
            IFlywheelPad.Sale memory s = IGangGatewayFlywheel(pad).sales(token);
            if (s.launched && !s.postMint) revert IGangLaunchpad3.NotCurveToken();
            quote = s.quote;
        } else {
            revert IGangLaunchpad3.NotCurveToken();
        }
    }

    /// @notice Buy on another registered pad with `funds` of `quote` the pad already holds for this trade; tokens to
    ///         `to` (the old pad requires to == tx.origin), any cut / unspent funds back to `to` in the quote ERC-20.
    function buy(IGangPadRegistry registry, address token, address to, uint256 funds, uint256 minAmount)
        external
        returns (uint256 amountOut, uint256 fundsUsed)
    {
        (address p, uint8 kind) = registry.lookup(token);
        uint256 tokensBefore = IERC20(token).balanceOf(to);
        if (kind == KIND_FLY) {
            fundsUsed = _flyBuy(IGangGatewayFlywheel(p), token, to, funds, minAmount);
        } else {
            IGangGatewayPad pad = IGangGatewayPad(p);
            (, address q,,,,,,,,,,) = pad.curves(token);
            IERC20 quote = IERC20(q);
            uint256 toBefore = quote.balanceOf(to);
            quote.forceApprove(address(pad), funds);
            pad.buyFor(to, token, funds, minAmount);
            quote.forceApprove(address(pad), 0);
            fundsUsed = funds - (quote.balanceOf(to) - toBefore);
        }
        // what `to` received, not what the pad says: a locked token moves only from its own pad (Gateway audit L-2)
        amountOut = IERC20(token).balanceOf(to) - tokensBefore;
        if (amountOut < minAmount) revert IGangLaunchpad.Slippage();
        emit IGangLaunchpad3.Routed(token, p, to, true, fundsUsed, amountOut);
    }

    /// @notice Sell `from`'s tokens on another registered pad (its `sellFor` / `withdrawFor`, `from`'s allowance to 3.0);
    ///         the proceeds land on the pad for the caller to split. Returns the quote, what arrived, and the pad's
    ///         balance of the quote before it (the caller pays `funds` out and checks it is back at `base`).
    function sell(IGangPadRegistry registry, address token, address from, uint256 amount)
        external
        returns (IERC20 quote, uint256 funds, uint256 base)
    {
        (address p, uint8 kind) = registry.lookup(token);
        if (p == address(0) || p == address(this)) revert IGangLaunchpad3.NotCurveToken();
        if (kind == KIND_FLY) {
            IGangGatewayFlywheel f = IGangGatewayFlywheel(p);
            IFlywheelPad.Sale memory s = f.sales(token);
            if (s.launched) revert IGangLaunchpad3.NotCurveToken();
            uint256 shares = _wholeShares(f, amount);
            if (shares == 0) revert IGangLaunchpad3.NotWholeShares();
            quote = IERC20(s.quote);
            base = quote.balanceOf(address(this));
            f.withdrawFor(from, token, shares, 0);
        } else if (kind == KIND_CURVE) {
            IGangGatewayPad pad = IGangGatewayPad(p);
            (, address q,,,,, bool graduated,,,,,) = pad.curves(token);
            if (graduated) revert IGangLaunchpad3.NotCurveToken();
            quote = IERC20(q);
            base = quote.balanceOf(address(this));
            pad.sellFor(from, token, amount, 0);
        } else {
            revert IGangLaunchpad3.NotCurveToken();
        }
        funds = quote.balanceOf(address(this)) - base;
        emit IGangLaunchpad3.Routed(token, p, from, false, funds, amount);
    }

    // ---------------------------------------------------------------- internal: 铸币飞轮 (kind 3), as GangGateway V2
    function _flyBuy(IGangGatewayFlywheel f, address token, address to, uint256 funds, uint256 minAmount)
        private
        returns (uint256 fundsUsed)
    {
        IFlywheelPad.Sale memory s = f.sales(token);
        IERC20 quote = IERC20(s.quote);
        quote.forceApprove(address(f), funds);
        if (!s.launched) {
            uint256 shares = _sharesFor(s, funds);
            if (shares == 0) revert IGangLaunchpad3.FundsTooLow();
            fundsUsed = f.mintFor(to, token, shares, Math.ceilDiv(minAmount, f.TOKENS_PER_SHARE()), address(0));
        } else {
            (uint256 shares,,,, bool affordable) = _postMint(f, s, token, to, funds);
            if (!affordable) revert IGangLaunchpad3.FundsTooLow();
            (, fundsUsed) = f.mintPostFor(to, token, shares == 0 ? 1 : shares, minAmount, funds, address(0));
        }
        quote.forceApprove(address(f), 0);
        if (funds > fundsUsed) quote.safeTransfer(to, funds - fundsUsed);
    }

    function _flyQuote(IGangGatewayFlywheel f, address token, address trader, uint256 funds)
        private
        view
        returns (uint256 shares, uint256 amountOut, uint256 cost, uint256 fee)
    {
        if (trader == address(0) || !f.routers(address(this))) return (0, 0, 0, 0);
        IFlywheelPad.Sale memory s = f.sales(token);
        if (s.gate == address(0)) return (0, 0, 0, 0);
        if (!s.launched) {
            uint256 want = _sharesFor(s, funds);
            if (want == 0) return (0, 0, 0, 0);
            uint256 price;
            (shares, price, fee) = f.previewMint(token, trader, want);
            if (shares == 0) return (0, 0, 0, 0);
            return (shares, shares * f.TOKENS_PER_SHARE(), price + fee, fee);
        }
        if (!s.postMint) return (0, 0, 0, 0);
        (shares, amountOut, cost, fee,) = _postMint(f, s, token, trader, funds);
    }

    function _postMint(IGangGatewayFlywheel f, IFlywheelPad.Sale memory s, address token, address trader, uint256 funds)
        private
        view
        returns (uint256 shares, uint256 amountOut, uint256 cost, uint256 fee, bool affordable)
    {
        uint256 want = _sharesFor(s, funds);
        if (want > s.maxPerTx) want = s.maxPerTx;
        while (want != 0) {
            (uint256 accepted, uint256 paid, uint256 mintFee, uint256 out, bool ok) =
                f.previewMintPost(token, trader, want);
            if (accepted == 0) return (0, 0, 0, 0, true);
            if (paid + mintFee <= funds) {
                if (ok) return (accepted, out, paid + mintFee, mintFee, true);
                affordable = true;
            }
            want = accepted - 1;
        }
    }

    function _sharesFor(IFlywheelPad.Sale memory s, uint256 funds) private pure returns (uint256 n) {
        if (funds > type(uint128).max) funds = type(uint128).max;
        uint256 unit = s.basePrice;
        n = (funds * BPS) / (unit * (BPS + s.mintFeeBps));
        uint256 cost = (n + 1) * unit;
        if (cost + (cost * s.mintFeeBps) / BPS <= funds) n++;
    }

    function _wholeShares(IGangGatewayFlywheel f, uint256 amount) private view returns (uint256) {
        uint256 tps = f.TOKENS_PER_SHARE();
        if (amount == 0 || amount % tps != 0) return 0;
        return amount / tps;
    }

    function _withdrawable(IFlywheelPad.Sale memory s) private view returns (bool) {
        if (s.creator == address(0) || s.launched) return false;
        if (s.filledAt == 0) return true;
        return block.timestamp >= uint256(s.filledAt) + s.launchDelay + FLY_LAUNCH_GRACE;
    }
}
