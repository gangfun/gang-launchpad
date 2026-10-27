// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev The slice of GangLaunchpad (the one pad for V3 curves and 打新 sales) this router calls. `curves` / `sales` keep
///      the old cores' 12- / 14-field layouts, so decoding is unchanged.
interface IGangPadEntry {
    function curves(address token)
        external
        view
        returns (
            address creator,
            address quote,
            uint128 realQuote,
            uint128 sold,
            uint128 gradAmt,
            uint128 virtualQuote,
            bool graduated,
            uint16 buyTaxBps,
            uint16 sellTaxBps,
            uint16 dividendBps,
            address pair,
            address refPair
        );
    function buyFor(address trader, address token, uint256 quoteIn, uint256 minTokensOut)
        external
        returns (uint256 tokensOut);
    function sales(address token)
        external
        view
        returns (
            address creator,
            uint64 progressAt,
            uint16 capShares,
            uint16 holdBps,
            address quote,
            uint16 sold,
            bool launched,
            uint16 mintFeeBps,
            uint16 exitFeeBps,
            address gate,
            uint128 sharePrice,
            address pair,
            address refPool,
            uint16 markSold
        );
    function previewMint(address token, address user, uint256 shares)
        external
        view
        returns (uint256 accepted, uint256 cost, uint256 fee);
    function mintFor(address trader, address token, uint256 shares, uint256 minShares)
        external
        returns (uint256 accepted);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title GangRouter — stateless entry for V3 curve buys and 打新 mints on GangLaunchpad
/// @notice The pad (GangLaunchpad: V3 curves and 打新 sales in one contract) holds every reserve and enforces every rule: price, fee, tax and its
///         split, wallet cap, Agent gate (on the trader this router names), graduation / launch. This contract only
///         moves the caller's own money into one pad call: native BNB in (wrapped to WBNB) and back out, a deadline,
///         and whatever the pad refunds (cap / fill truncation) returned to the caller in what they paid with.
///         No owner, no storage: a new version is a new deployment that the pad owner lists with setRouter, and that
///         users opt into by approving it. A listed router can only spend what it was sent — it cannot sell, withdraw,
///         refund or claim for anyone (those stay msg.sender-only on the pad). A token of the other kind reads as an
///         empty curve / sale here, so `v3*` on a 打新 token and `fair*` on a V3 token revert UnknownToken.
/// @dev Anything sent here outside a call (tokens, BNB) stays here: every call settles against its own balance delta.
contract GangRouter {
    using SafeERC20 for IERC20;

    IGangPadEntry public immutable pad;
    address public immutable wbnb;

    error Expired();
    error NotDeployed();
    error UnknownToken();
    error NotWbnbQuote();
    error NotEnoughValue();
    error OnlyWbnb();
    error BnbTransferFailed();

    /// @param pad_ GangLaunchpad (both kinds of token)
    constructor(address pad_, address wbnb_) {
        if (pad_ == address(0) || wbnb_ == address(0)) revert NotDeployed();
        pad = IGangPadEntry(pad_);
        wbnb = wbnb_;
    }

    /// @notice The pad, under the old V3 core getter name (CLI / indexer compatibility).
    function v3() external view returns (IGangPadEntry) {
        return pad;
    }

    /// @notice The pad, under the old 打新 core getter name (CLI / indexer compatibility).
    function fair() external view returns (IGangPadEntry) {
        return pad;
    }

    /// @dev Only WBNB unwrapping sends BNB here.
    receive() external payable {
        if (msg.sender != wbnb) revert OnlyWbnb();
    }

    modifier before(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    // ---------------------------------------------------------------- V3 (curve)
    /// @notice Buy on the curve with `quoteIn` of the token's quote (approved to this router); any refund comes back.
    function v3Buy(address token, uint256 quoteIn, uint256 minTokensOut, uint256 deadline)
        external
        before(deadline)
        returns (uint256 tokensOut)
    {
        IERC20 quote = IERC20(_v3Quote(token));
        uint256 base = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), quoteIn);
        // a fee-on-transfer quote arrives short: pass on what arrived (the pad prices on what it receives)
        uint256 arrived = quote.balanceOf(address(this)) - base;
        quote.forceApprove(address(pad), arrived);
        tokensOut = pad.buyFor(msg.sender, token, arrived, minTokensOut);
        _settle(quote, base, false);
    }

    /// @notice Buy a WBNB-quoted token with native BNB (msg.value); any refund comes back as BNB.
    function v3BuyBNB(address token, uint256 minTokensOut, uint256 deadline)
        external
        payable
        before(deadline)
        returns (uint256 tokensOut)
    {
        IERC20 quote = IERC20(_v3Quote(token));
        if (address(quote) != wbnb) revert NotWbnbQuote();
        uint256 base = quote.balanceOf(address(this));
        IWBNB(wbnb).deposit{value: msg.value}();
        quote.forceApprove(address(pad), msg.value);
        tokensOut = pad.buyFor(msg.sender, token, msg.value, minTokensOut);
        _settle(quote, base, true);
    }

    // ---------------------------------------------------------------- 打新
    /// @notice Mint `shares` (cut to what is left / the cap, never below `minShares`) paying cost + mint fee in the
    ///         sale's quote (approved to this router). The position, tokens and fee escrow are the caller's.
    function fairMint(address token, uint256 shares, uint256 minShares, uint256 deadline)
        external
        before(deadline)
        returns (uint256 accepted)
    {
        (IERC20 quote, uint256 need) = _fairCost(token, shares);
        uint256 base = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), need);
        quote.forceApprove(address(pad), need);
        accepted = pad.mintFor(msg.sender, token, shares, minShares);
        _settle(quote, base, false);
    }

    /// @notice fairMint for a WBNB-quoted sale with native BNB: msg.value must cover cost + mint fee; the rest comes back.
    function fairMintBNB(address token, uint256 shares, uint256 minShares, uint256 deadline)
        external
        payable
        before(deadline)
        returns (uint256 accepted)
    {
        (IERC20 quote, uint256 need) = _fairCost(token, shares);
        if (address(quote) != wbnb) revert NotWbnbQuote();
        if (msg.value < need) revert NotEnoughValue();
        uint256 base = quote.balanceOf(address(this));
        IWBNB(wbnb).deposit{value: msg.value}();
        quote.forceApprove(address(pad), need);
        accepted = pad.mintFor(msg.sender, token, shares, minShares);
        _settle(quote, base, true);
    }

    // ---------------------------------------------------------------- internal
    function _v3Quote(address token) internal view returns (address quote) {
        (, quote,,,,,,,,,,) = pad.curves(token);
        if (quote == address(0)) revert UnknownToken();
    }

    /// @dev What the pad will pull for `shares` minted by msg.sender right now (same block, same state as the mint).
    function _fairCost(address token, uint256 shares) internal view returns (IERC20 quote, uint256 need) {
        address q;
        (,,,, q,,,,,,,,,) = pad.sales(token);
        if (q == address(0)) revert UnknownToken();
        (, uint256 cost, uint256 fee) = pad.previewMint(token, msg.sender, shares);
        return (IERC20(q), cost + fee);
    }

    /// @dev Return to msg.sender whatever this call left above `base` (a pad refund, unspent msg.value), as BNB if asked.
    function _settle(IERC20 quote, uint256 base, bool asBnb) internal {
        uint256 left = quote.balanceOf(address(this)) - base;
        if (left == 0) return;
        if (!asBnb) {
            quote.safeTransfer(msg.sender, left);
            return;
        }
        IWBNB(wbnb).withdraw(left);
        (bool ok,) = msg.sender.call{value: left}("");
        if (!ok) revert BnbTransferFailed();
    }
}
