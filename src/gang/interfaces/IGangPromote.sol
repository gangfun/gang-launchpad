// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGangLaunchpad} from "./IGangLaunchpad.sol";

/// @notice GangLaunchpad 3.0's promoter share (docs/SPEC-PROMOTER-SHARE-2026-11-04.md): a creator can give up part of
///         its fee to whoever brings a wallet to its token. Pad3Module's functions, reached through the pad.
interface IGangPromote {
    /// @notice `token` was created with a promoter share: `shareBps` of the creator's fee, for `window` seconds from
    ///         each binding. Fixed for good.
    event PromoteSet(address indexed token, uint16 shareBps, uint32 window);
    /// @notice `wallet`'s first trade of `token` named `promoter`, for good.
    event PromoterBound(address indexed token, address indexed wallet, address indexed promoter);
    /// @notice A curve trade by `wallet` earned `promoter` this much, out of the creator's fee, in the token's quote.
    event PromoterFeeAccrued(address indexed token, address indexed promoter, address indexed wallet, uint256 amount);
    event PromoterFeeClaimed(address indexed token, address indexed promoter, address indexed to, uint256 amount);

    /// @notice `createWithPromote`: `shareBps` not 1–5000, or `window` not 7–90 days.
    error BadPromoteTerms();

    /// @notice `createWithGradTarget` with a promoter share. `shareBps`: 1–5000 (at most half of the creator's fee).
    ///         `window`: 7–90 days, in seconds. Neither can change afterwards.
    function createWithPromote(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        IGangLaunchpad.TaxConfig calldata tax,
        uint256 gradBnb,
        uint16 shareBps,
        uint32 window
    ) external returns (address token);

    /// @notice The entry's `buyTokenAMAP` for a curve token of this pad, for the caller, naming who brought it. Only the
    ///         wallet that sent the tx can call it directly (TraderNotOrigin): no contract names a promoter for a wallet.
    ///         A promoter that can't be bound (see `canBind`) is ignored: the buy goes on.
    function buyWithPromoter(address token, uint256 funds, uint256 minAmount, address promoter)
        external
        payable
        returns (uint256 amountOut, uint256 fundsUsed);

    /// @notice The caller takes what it earned on `token`, in the token's quote, to `to`. Before or after graduation.
    function claimPromoterFee(address token, address to) external returns (uint256 amount);

    /// @notice `token`'s terms: 0, 0 = no promoter share.
    function promoteOf(address token) external view returns (uint16 shareBps, uint32 window);

    /// @notice `wallet` on `token`: who it is bound to (0 = nobody), since when (seconds), whether it has traded.
    function bindingOf(address token, address wallet)
        external
        view
        returns (address promoter, uint40 boundAt, bool traded);

    /// @notice What `promoter` earned on `token` and has not claimed.
    function promoterFeeOf(address token, address promoter) external view returns (uint256);

    /// @notice Whether a `buyWithPromoter` sent by `wallet` naming `promoter` would bind it now: the token has a promoter
    ///         share and is on its curve, the pad's Agent gate is on; `wallet` holds an Agent ID and has not traded the
    ///         token; `promoter` is not 0, `wallet` or the creator, and holds an Agent ID. A wallet at the 1% cap can't
    ///         buy at all; `tryBuy` tells that.
    function canBind(address token, address wallet, address promoter) external view returns (bool);
}
