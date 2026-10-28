// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice GangBond (Agent 押金承诺, 2026-10-28): a token's creator posts a bond in the token's quote, promising its
///         creating address holds at least `holdAmount` tokens from the post until the bond is settled; the deadline is
///         `duration` after the token reaches its pair (V3 graduation / 打新 launch). Below that, anyone can `report`:
///         the reporter gets 1% and the rest buys the token back from its pair in small chunks and burns it.
interface IGangBond {
    /// @dev Active covers both phases: pending (`deadline == 0`, the token not on its pair yet / not started) and
    ///      started. Refunded: posted before the pair, the pair never came within MAX_WAIT, and the promise held.
    enum State {
        None,
        Active,
        Slashed,
        Settled,
        Refunded
    }

    struct Bond {
        address creator; // curves(token).creator or sales(token).creator
        uint64 postedAt;
        uint32 round;
        address quote; // the token's quote; the bond is paid in it
        State state;
        uint64 deadline; // T; 0 while pending (the token not on its pair yet)
        uint64 duration; // T − start; the commitment after the token reaches its pair
        // when a requested step may run (0: none): pending, no pair MAX_WAIT after the post — the creator's refund;
        // started, past the deadline — the settle
        uint64 requestAt;
        uint128 amount; // the bond, in quote
        uint128 holdAmount; // X: tokens the creator promises to hold
        uint128 burnLeft; // quote slashed but not yet spent on buy-back
    }

    // creator
    function post(address token, uint256 amount, uint256 holdAmount, uint64 duration) external payable;
    function topUp(address token, uint256 amount) external payable;
    function raiseHold(address token, uint256 newHoldAmount) external;
    function extend(address token, uint64 by) external;

    // anyone (requestRefund / refund: creator only)
    function start(address token) external;
    function report(address token) external;
    function requestSettle(address token) external;
    function settle(address token) external;
    function requestRefund(address token) external;
    function refund(address token) external;
    function burnChunk(address token, uint256 minTokensOut) external returns (uint256 quoteIn, uint256 burned);

    // views
    function bondOf(address token) external view returns (Bond memory);
    function isViolated(address token) external view returns (bool);
    /// @notice The token is on its Pancake pair (V3 graduated / 打新 launched).
    function isLive(address token) external view returns (bool);
    function dumpValue(address token) external view returns (uint256 quoteOut);
    function coverageBps(address token) external view returns (uint256);
    function historyOf(address creator) external view returns (uint32 posted, uint32 honored, uint32 slashed);
    /// @notice What selling `holdAmount` of `token` into its pair would fetch now (after sell tax and the DEX fee), the
    ///         denominator of the coverage. For the CLI's `--cover` before a bond exists. Reverts before the pair.
    function quoteDump(address token, uint256 holdAmount) external view returns (uint256 quoteOut);
    /// @notice What `burnChunk` would do in this block: the quote it would spend and the tokens it would get after the
    ///         buy tax (`ready` false: it would only record a price observation or wait). For the keeper's minTokensOut.
    ///         Before the pair, past MAX_WAIT: ready with `tokensOut` 0 (the rest goes to 0xdead as quote).
    function previewBurn(address token) external view returns (bool ready, uint256 quoteIn, uint256 tokensOut);

    event BondPosted(
        address indexed token,
        address indexed creator,
        uint32 round,
        address quote,
        uint256 amount,
        uint256 holdAmount,
        uint64 duration,
        uint64 deadline
    );
    event BondStarted(address indexed token, uint32 round, uint64 deadline);
    event BondToppedUp(address indexed token, uint32 round, uint256 added, uint256 amount);
    event HoldRaised(address indexed token, uint32 round, uint256 holdAmount);
    event BondExtended(address indexed token, uint32 round, uint64 duration, uint64 deadline);
    event BondReported(
        address indexed token, uint32 round, address indexed reporter, uint256 balance, uint256 reward, uint256 burnLeft
    );
    event SettleRequested(address indexed token, uint32 round, uint64 settleAt);
    event BondSettled(address indexed token, uint32 round, address indexed creator, uint256 amount);
    event RefundRequested(address indexed token, uint32 round, uint64 refundAt);
    event BondRefunded(address indexed token, uint32 round, address indexed creator, uint256 amount);
    event BondBurned(address indexed token, uint32 round, uint256 quoteIn, uint256 tokensBurned, uint256 burnLeft);

    error ZeroAddress();
    error UnknownToken();
    /// @notice Needs the token's pair (V3 graduated / 打新 launched), and it is not there yet.
    error NotTradable();
    error NotCreator();
    /// @notice The token already has a live bond (Active, or Slashed with buy-back left).
    error BondLive();
    error NotActive();
    error ZeroAmount();
    error BadDuration();
    error BadHold();
    error BadValue();
    error FeeOnTransferQuote();
    error NotViolated();
    /// @notice `requestSettle` / `settle` / `refund` while the creator holds less than `holdAmount`: the bond is violated,
    ///         `report` it.
    error Violated();
    error NotDue();
    /// @notice `requestRefund` / `refund`: the token reached its pair, so the bond runs (`start`) instead.
    error AlreadyLive();
    error AlreadyRequested();
    error NoRefundRequest();
    error NoSettleRequest();
    /// @notice `requestSettle` / `settle` while the token's pair is mid flash swap (holds fewer tokens than its reserve).
    error FlashSwapActive();
    error NothingToBurn();
    /// @notice `burnChunk` less than CHUNK_GAP after the last chunk bought.
    error BurnTooSoon();
    error Slippage();
}
