// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGangPadEntry, IPancakeV2Router, IWBNB} from "../../src/router/GangRouter.sol";

/// @title GangRouterV2Mock — a well-formed next version of GangRouter, written by the upgrade rule
/// @notice The v1 source unchanged except: one appended variable `v2Value` taken from the gap (slot 4; `__gap` 47 → 46),
///         `initializeV2` (reinitializer(2), run through ProxyAdmin.upgradeAndCall) and `version()`. Layout v2:
///         slot 0 _status, 1 pad, 2 wbnb, 3 pancakeRouter, 4 v2Value, 5–50 __gap.
contract GangRouterV2Mock is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice GangLaunchpad (both kinds of token). Set once by `initialize`.
    IGangPadEntry public pad;
    /// @notice WBNB. Set once by `initialize`.
    address public wbnb;
    /// @notice PancakeSwap V2 router the pool entries swap through. Set once by `initialize`.
    IPancakeV2Router public pancakeRouter;
    /// @notice V2's appended variable: takes slot 4, the first slot of v1's gap.
    uint256 public v2Value;
    /// @dev v1's gap less the one slot v2Value took (47 → 46): slots 5–50, so slot 51 onward is untouched as in v1.
    uint256[46] private __gap;

    error Expired();
    error NotDeployed();
    error UnknownToken();
    error NotWbnbQuote();
    error NotEnoughValue();
    error OnlyWbnb();
    error BnbTransferFailed();
    /// @notice A pool entry got 0 in (msg.value / amount, or nothing arrived from the caller).
    error ZeroAmount();
    /// @notice A pool entry's output (as received) is below the caller's minimum.
    error TooLittleReceived(uint256 received, uint256 minimum);

    /// @dev The implementation itself can never be initialized: only a proxy's storage holds a pad.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Run once, by the proxy's constructor (TransparentUpgradeableProxy's `_data`), in the deploy transaction.
    /// @param pad_ GangLaunchpad (both kinds of token)
    /// @param pancakeRouter_ PancakeSwap V2 router (mainnet 0x10ED…024E, testnet 0xD99D…50D1)
    function initialize(address pad_, address wbnb_, address pancakeRouter_) external initializer {
        if (pad_ == address(0) || wbnb_ == address(0) || pancakeRouter_ == address(0)) revert NotDeployed();
        pad = IGangPadEntry(pad_);
        wbnb = wbnb_;
        pancakeRouter = IPancakeV2Router(pancakeRouter_);
    }

    /// @notice V2 set-up, run once through ProxyAdmin.upgradeAndCall's data.
    function initializeV2(uint256 value) external reinitializer(2) {
        v2Value = value;
    }

    function version() external pure returns (uint256) {
        return 2;
    }

    /// @notice The pad, under the old V3 core getter name (CLI / indexer compatibility).
    function v3() external view returns (IGangPadEntry) {
        return pad;
    }

    /// @notice The pad, under the old 打新 core getter name (CLI / indexer compatibility).
    function fair() external view returns (IGangPadEntry) {
        return pad;
    }

    /// @dev Only WBNB unwrapping sends BNB here. WBNB pays with `transfer` (2300 gas): through the proxy this costs one
    ///      warm implementation-slot read, the delegatecall and one warm `wbnb` read (the call that unwraps read it).
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
        nonReentrant
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
        nonReentrant
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
        nonReentrant
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
        nonReentrant
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

    // ---------------------------------------------------------------- PancakeSwap V2 pool
    /// @notice Buy `token` on its Pancake V2 pair with native BNB: wrapped, swapped along [WBNB, token] (quote = WBNB)
    ///         or [WBNB, quote, token], tokens sent by Pancake straight to the caller.
    /// @return tokensOut what the caller's token balance grew by (after any buy tax), at least `minTokensOut`
    function poolBuyBNB(address token, address quote, uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        before(deadline)
        returns (uint256 tokensOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        address w = wbnb;
        uint256 base = IERC20(w).balanceOf(address(this));
        IWBNB(w).deposit{value: msg.value}();
        tokensOut = _swapTo(_path(w, quote, token, quote == w), msg.value, msg.sender, deadline);
        if (tokensOut < minTokensOut) revert TooLittleReceived(tokensOut, minTokensOut);
        _settle(IERC20(w), base, true);
    }

    /// @notice Buy `token` on its Pancake V2 pair with `quoteIn` of `quote` (approved to this router) along
    ///         [quote, token]; tokens sent by Pancake straight to the caller.
    /// @return tokensOut what the caller's token balance grew by (after any buy tax), at least `minTokensOut`
    function poolBuy(address token, address quote, uint256 quoteIn, uint256 minTokensOut, uint256 deadline)
        external
        nonReentrant
        before(deadline)
        returns (uint256 tokensOut)
    {
        uint256 base = IERC20(quote).balanceOf(address(this));
        uint256 arrived = _pull(IERC20(quote), quoteIn, base);
        tokensOut = _swapTo(_path(quote, address(0), token, true), arrived, msg.sender, deadline);
        if (tokensOut < minTokensOut) revert TooLittleReceived(tokensOut, minTokensOut);
        _settle(IERC20(quote), base, false);
    }

    /// @notice Sell `amountIn` of `token` (approved to this router) on its Pancake V2 pair for `quote` along
    ///         [token, quote]; the quote is sent by Pancake straight to the caller.
    /// @return quoteOut what the caller's quote balance grew by, at least `minQuoteOut`
    function poolSell(address token, address quote, uint256 amountIn, uint256 minQuoteOut, uint256 deadline)
        external
        nonReentrant
        before(deadline)
        returns (uint256 quoteOut)
    {
        uint256 base = IERC20(token).balanceOf(address(this));
        uint256 arrived = _pull(IERC20(token), amountIn, base);
        quoteOut = _swapTo(_path(token, address(0), quote, true), arrived, msg.sender, deadline);
        if (quoteOut < minQuoteOut) revert TooLittleReceived(quoteOut, minQuoteOut);
        _settle(IERC20(token), base, false);
    }

    /// @notice Sell `amountIn` of `token` (approved to this router) on its Pancake V2 pair for native BNB along
    ///         [token, WBNB] (quote = WBNB) or [token, quote, WBNB]; the WBNB comes here, is unwrapped and sent on.
    /// @return bnbOut the BNB sent to the caller, at least `minBnbOut`
    function poolSellForBNB(address token, address quote, uint256 amountIn, uint256 minBnbOut, uint256 deadline)
        external
        nonReentrant
        before(deadline)
        returns (uint256 bnbOut)
    {
        address w = wbnb;
        uint256 baseToken = IERC20(token).balanceOf(address(this));
        uint256 baseW = IERC20(w).balanceOf(address(this));
        uint256 arrived = _pull(IERC20(token), amountIn, baseToken);
        bnbOut = _swapTo(_path(token, quote, w, quote == w), arrived, address(this), deadline);
        if (bnbOut < minBnbOut) revert TooLittleReceived(bnbOut, minBnbOut);
        _settle(IERC20(token), baseToken, false);
        _settle(IERC20(w), baseW, true); // exactly bnbOut: unwrapped and sent to the caller
    }

    // ---------------------------------------------------------------- internal
    /// @dev Pull `amount` of `t` from the caller; what arrived (a fee-on-transfer token arrives short), never 0.
    function _pull(IERC20 t, uint256 amount, uint256 base) internal returns (uint256 arrived) {
        if (amount == 0) revert ZeroAmount();
        t.safeTransferFrom(msg.sender, address(this), amount);
        arrived = t.balanceOf(address(this)) - base;
        if (arrived == 0) revert ZeroAmount();
    }

    /// @dev [a, b] when `direct`, else [a, mid, b].
    function _path(address a, address mid, address b, bool direct) internal pure returns (address[] memory p) {
        if (direct) {
            p = new address[](2);
            (p[0], p[1]) = (a, b);
        } else {
            p = new address[](3);
            (p[0], p[1], p[2]) = (a, mid, b);
        }
    }

    /// @dev Swap exactly `amountIn` of path[0] (held here) on Pancake V2, output to `to`; Pancake is approved exactly
    ///      `amountIn` and back to 0 afterwards. Returns what `to`'s balance of the last token grew by.
    function _swapTo(address[] memory path, uint256 amountIn, address to, uint256 deadline)
        internal
        returns (uint256 out)
    {
        IPancakeV2Router r = pancakeRouter;
        IERC20 tokenIn = IERC20(path[0]);
        IERC20 tokenOut = IERC20(path[path.length - 1]);
        uint256 prior = tokenOut.balanceOf(to);
        tokenIn.forceApprove(address(r), amountIn);
        // the minimum is checked on what the caller actually gets (after any tax), so Pancake's is 0
        r.swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, to, deadline);
        tokenIn.forceApprove(address(r), 0);
        out = tokenOut.balanceOf(to) - prior;
    }

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
