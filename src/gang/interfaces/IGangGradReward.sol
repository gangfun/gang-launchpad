// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGangLaunchpad} from "./IGangLaunchpad.sol";

/// @title IGangGradReward — GangLaunchpad 3.0's graduation reward (冲毕业奖励, docs/SPEC-GRAD-REWARD-2026-11-17.md)
/// @notice A curve token can be created with a reward pool the dev pays in (the seed, in the token's quote). The pad
///         keeps the last `entries` counted curve buys; when the token graduates, the pool goes to those buyers (the
///         buy that graduates it gets `lastBps` of it on top; all split the rest by what each spent). A curve sell
///         takes every earlier entry of that wallet out, by
///         order. With the countdown reward on the same token, `carryBps` of the pool goes to that module at
///         graduation, at an address the pad derives itself. A token that does not graduate: the dev asks for the
///         pool back, and gets it only after a 7-day notice the token did not graduate in.
interface IGangGradRewardBase {
    /// @notice The create's options. All fixed for good.
    struct GradConfig {
        /// @dev the reward pool, pulled from the creator as the quote ERC-20 (WBNB for a BNB token)
        uint128 seed;
        /// @dev least quote a buy must actually spend (after a cap / graduation cut) to be counted
        uint96 minBuy;
        /// @dev how many of the last counted buys share the pool (1–20)
        uint8 entries;
        /// @dev the latest counted buy's part of the payout (0–5000; at graduation that is the graduating buy)
        uint16 lastBps;
        /// @dev part of the pool sent to the token's countdown reward module at graduation (0–5000; > 0 needs one)
        uint16 carryBps;
        /// @dev after this long without graduating, the dev may ask for the pool back (30–180 days, in seconds)
        uint32 refundAfter;
        /// @dev an optional promoter share, as `createWithPromote` (0, 0 = none)
        uint16 promoteBps;
        uint32 promoteWindow;
    }

    /// @notice A token's reward: terms and state.
    struct GradView {
        uint8 state;
        uint128 pot;
        uint96 minBuy;
        uint8 entries;
        uint16 lastBps;
        uint16 carryBps;
        uint32 refundAfter;
        uint40 createdAt;
        uint40 refundAt;
        uint40 gradAt;
        uint64 seq;
        address countdown;
        uint128 claimed;
        uint128 carryOwed;
        bool settled;
        uint16 valid;
        /// @dev once settled: Σ spent of the valid entries
        uint128 validSpent;
        /// @dev a refund request made and not lapsed (the pool can go back to the dev from refundAt + 7 days)
        bool refundPending;
    }

    event GradRewardSet(
        address indexed token,
        uint256 seed,
        uint256 minBuy,
        uint8 entries,
        uint16 lastBps,
        uint16 carryBps,
        uint32 refundAfter,
        address countdown
    );
    event GradEntry(address indexed token, address indexed buyer, uint64 seq, uint256 spent, uint256 tokens);
    /// @notice `wallet` sold on the curve: its entries up to `seq` no longer count.
    event GradDisqualified(address indexed token, address indexed wallet, uint64 seq);
    event GradRewardBooked(address indexed token, uint256 pot, uint256 carry, uint64 seq);
    /// @notice The entries were counted: `valid` of them share the payout. The newest valid one (`lastSeq`) gets
    ///         `lastShare`; all of them, the newest too, split `restPay` by what each spent (out of `validSpent`).
    event GradSettled(
        address indexed token, uint256 valid, uint64 lastSeq, uint256 lastShare, uint256 restPay, uint256 validSpent
    );
    event GradClaimed(address indexed token, address indexed wallet, uint256 amount);
    event GradSwept(address indexed token, address indexed to, uint256 amount);
    /// @notice The dev may take the pool back from `executableAt` until just before `expiresAt` (then the request lapses).
    event RefundRequested(address indexed token, uint256 executableAt, uint256 expiresAt);
    event RefundCancelled(address indexed token);
    event Refunded(address indexed token, address indexed dev, uint256 amount);
    event CarrySent(address indexed token, address indexed module, uint256 amount);
    event CarryOwed(address indexed token, address indexed module, uint256 amount);
    event GradRewardDepsSet(bool open, address handlerAdmin, address countdownFactory);

    error GradNotOpen();
    error BadGradConfig();
    error BadCountdown();
    error NotGradState();
    error RefundNotDue();
    error AlreadyClaimed();
    error NothingToClaim();
    error SweepNotDue();
    error NoCarryOwed();
    /// @notice Too little gas left to give the countdown module's `receiveCarry` its share: send the tx with more.
    error CarryGasLow();
}

/// @notice The full surface, as the pad answers it (Pad3Module: the owner switch and the create; Pad3GradModule,
///         behind it: the rest).
interface IGangGradReward is IGangGradRewardBase {
    /// @notice Owner: open / close new graduation-reward creates, and the two addresses the carry is checked with.
    function setGradReward(bool open, address handlerAdmin, address countdownFactory) external;

    /// @notice `createWithGradTarget` (optionally with a promoter share) plus a graduation reward. The seed is pulled
    ///         from the creator in the token's quote (approve the pad first). A countdown reward module named as the
    ///         tax recipient is found and checked here; `carryBps` > 0 needs one.
    function createWithGradReward(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        IGangLaunchpad.TaxConfig calldata tax,
        uint256 gradBnb,
        GradConfig calldata cfg
    ) external returns (address token);

    function claimGradReward(address token) external returns (uint256 amount);
    function settleGradReward(address token) external;
    function sweepGradReward(address token) external;
    function retryCarry(address token) external;
    function requestGradRefund(address token) external;
    function cancelGradRefund(address token) external;
    function gradRefund(address token) external returns (uint256 amount);

    function gradReward(address token) external view returns (GradView memory);
    function gradEntries(address token)
        external
        view
        returns (address[] memory buyers, uint64[] memory seqs, uint96[] memory spent, bool[] memory valid);
    function gradClaimable(address token, address wallet) external view returns (uint256);
    function gradRewardDeps() external view returns (bool open, address handlerAdmin, address countdownFactory);
}
