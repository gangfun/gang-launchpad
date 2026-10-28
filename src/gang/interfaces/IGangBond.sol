// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice GangBond (Agent 押金承诺, 2026-10-28): a token's creator posts a bond in the token's quote, promising its
///         creating address holds at least `holdAmount` tokens until `deadline`. Below that, anyone can `report`: the
///         reporter gets 1% and the rest buys the token back from its pair in small chunks and burns it.
interface IGangBond {
    enum State {
        None,
        Active,
        Slashed,
        Settled
    }

    struct Bond {
        address creator; // curves(token).creator or sales(token).creator
        address quote; // the token's quote; the bond is paid in it
        uint32 round;
        State state;
        uint64 postedAt;
        uint64 deadline; // T
        uint128 amount; // the bond, in quote
        uint128 holdAmount; // X: tokens the creator promises to hold
        uint128 burnLeft; // quote slashed but not yet spent on buy-back
    }

    // creator
    function post(address token, uint256 amount, uint256 holdAmount, uint64 deadline) external payable;
    function topUp(address token, uint256 amount) external payable;
    function raiseHold(address token, uint256 newHoldAmount) external;
    function extend(address token, uint64 newDeadline) external;

    // anyone
    function report(address token) external;
    function settle(address token) external;
    function burnChunk(address token, uint256 minTokensOut) external returns (uint256 quoteIn, uint256 burned);

    // views
    function bondOf(address token) external view returns (Bond memory);
    function isViolated(address token) external view returns (bool);
    function dumpValue(address token) external view returns (uint256 quoteOut);
    function coverageBps(address token) external view returns (uint256);
    function historyOf(address creator) external view returns (uint32 posted, uint32 honored, uint32 slashed);
    /// @notice What selling `holdAmount` of `token` into its pair would fetch now (after sell tax and the DEX fee), the
    ///         denominator of the coverage. For the CLI's `--cover` before a bond exists.
    function quoteDump(address token, uint256 holdAmount) external view returns (uint256 quoteOut);
    /// @notice What `burnChunk` would do in this block: the quote it would spend and the tokens it would get after the
    ///         buy tax (`ready` false: it would only record a price observation or wait). For the keeper's minTokensOut.
    function previewBurn(address token) external view returns (bool ready, uint256 quoteIn, uint256 tokensOut);

    event BondPosted(
        address indexed token,
        address indexed creator,
        uint32 round,
        address quote,
        uint256 amount,
        uint256 holdAmount,
        uint64 deadline
    );
    event BondToppedUp(address indexed token, uint32 round, uint256 added, uint256 amount);
    event HoldRaised(address indexed token, uint32 round, uint256 holdAmount);
    event BondExtended(address indexed token, uint32 round, uint64 deadline);
    event BondReported(
        address indexed token, uint32 round, address indexed reporter, uint256 balance, uint256 reward, uint256 burnLeft
    );
    event BondSettled(address indexed token, uint32 round, address indexed creator, uint256 amount);
    event BondBurned(address indexed token, uint32 round, uint256 quoteIn, uint256 tokensBurned, uint256 burnLeft);

    error ZeroAddress();
    error UnknownToken();
    /// @notice A V3 token before graduation or a 打新 sale before launch: there is no pair to buy back from yet.
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
    /// @notice `settle` while the creator holds less than `holdAmount`: the bond is violated, `report` it instead.
    error Violated();
    error NotDue();
    /// @notice `settle` while the token's pair is mid flash swap (holds fewer tokens than its reserve).
    error FlashSwapActive();
    error NothingToBurn();
    error BurnedThisBlock();
    error Slippage();
}
