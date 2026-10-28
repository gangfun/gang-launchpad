// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What an aggregator reads from GangPadRegistry: which Gang pad (if any) a token trades on, and curve quotes
///         that match the pad's `buyFor` / `sellFor` to the wei. The registry address never changes (it is a proxy);
///         a new pad generation is registered here and the aggregator's code stays as it is.
interface IGangPadRegistry {
    event PadAdded(address indexed pad, uint256 index);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OnlyOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error NotAContract();
    error AlreadyPad();
    /// @notice The pad's curve constants differ from the ones this registry quotes with: upgrade the registry first.
    error CurveMathMismatch();

    /// @notice True for every pad the owner registered. Append-only: a pad is never removed or replaced.
    function isPad(address pad) external view returns (bool);

    /// @notice The trusted pad that created `token` (before and after graduation / launch: the curve / sale state stays
    ///         there, `pair` included), or address(0) for any other token (not a Gang token, a pad that is not
    ///         registered, a look-alike pointing at a real pad). A token cannot make it revert.
    function padOf(address token) external view returns (address pad);

    /// @notice `padOf(token)` and that pad's `kindOf(token)` (1 = curve, 2 = 打新; 0 with pad = address(0)).
    function lookup(address token) external view returns (address pad, uint8 kind);

    function padCount() external view returns (uint256);
    function padAt(uint256 i) external view returns (address);
    function pads() external view returns (address[] memory);

    /// @notice What `pad.buyFor(trader, token, quoteIn, 0)` would do now: tokens to `trader`, quote kept by the pad
    ///         (gross, fee included), the 1% fee, and the refund the pad sends to `trader` when the wallet cap or the
    ///         graduation cut the buy (spent + refund = quoteIn). All zero when the buy would revert (not a curve
    ///         token, graduated, gate, wallet cap reached, quoteIn 0 or past type(uint256).max / 100). `trader` =
    ///         address(0): quote for a fresh wallet (no gate check, full wallet room).
    function previewBuy(address token, address trader, uint256 quoteIn)
        external
        view
        returns (uint256 tokensOut, uint256 spent, uint256 fee, uint256 refund);

    /// @notice What `pad.sellFor(trader, token, tokensIn, 0)` would pay the caller now (after the 1% fee) and the fee.
    ///         Both zero when the sell would revert (not a curve token, graduated, gate, more than the curve sold,
    ///         tokensIn 0). `trader` = address(0): no gate check. The trader's balance and allowance are not checked.
    function previewSell(address token, address trader, uint256 tokensIn)
        external
        view
        returns (uint256 quoteOut, uint256 fee);

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function addPad(address pad) external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
