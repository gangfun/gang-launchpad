// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGangGradRewardBase} from "./interfaces/IGangGradReward.sol";
import {IGangLaunchpad} from "./interfaces/IGangLaunchpad.sol";
import {PadCommon} from "./PadCommon.sol";
import {Pad3AgentWindowStore} from "./Pad3AgentWindowStore.sol";

/// @dev The countdown reward module's entry for the carry (GangCountdownReward): pulls exactly `amount` of its quote
///      from the caller (the allowance the pad gives it) into its pool, with no dev part.
interface ICountdownCarry {
    function receiveCarry(uint256 amount) external;
    function rewardToken() external view returns (address);
    function rewardQuote() external view returns (address);
}

/// @title Pad3GradStore — GangLaunchpad 3.0's graduation reward state, in its own ERC-7201 namespace, and the hooks
///        the curve runs (docs/SPEC-GRAD-REWARD-2026-11-17.md)
/// @notice Shared by CurveLogic3 (every curve buy and sell reads a token's state word; a token with a reward also
///         books entries / sells, and its graduation books the reward and sends the carry) and Pad3Module (the create,
///         claims, the refund, the views), all running in the proxy's storage. UPGRADES: members are only ever appended
///         at the end (never reordered, retyped or removed) and SLOT never changes; test/gang3/Pad3GradReward.t.sol
///         pins both.
library Pad3GradStore {
    using SafeERC20 for IERC20;

    uint8 internal constant NONE = 0;
    /// @dev on the curve: buys are counted, sells disqualify
    uint8 internal constant ACTIVE = 1;
    /// @dev graduated: the pool is booked; buyers claim
    uint8 internal constant BOOKED = 2;
    /// @dev the dev took the pool back (the token never graduated in time)
    uint8 internal constant REFUNDED = 3;
    /// @dev graduated, and the unclaimed rest was swept (or no entry was valid): nothing more to claim
    uint8 internal constant CLOSED = 4;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_ENTRIES = 20;
    /// @dev gas the countdown module's `receiveCarry` gets (it needs ~60–90k); a failure is owed, never a revert
    uint256 internal constant CARRY_GAS = 300_000;
    /// @dev what the carry needs around the module's call (approvals, balance reads, books) and the caller's tail
    uint256 internal constant CARRY_TAIL_GAS = 100_000;

    struct Reward {
        // word 0: everything a curve trade reads
        uint8 state;
        uint8 entries;
        uint16 lastBps;
        uint16 carryBps;
        uint32 refundAfter;
        uint40 createdAt;
        /// @dev when the dev asked for the pool back (0: not asked / cancelled)
        uint40 refundAt;
        /// @dev counted buys so far (1-based: the n-th counted buy has seq n)
        uint64 seq;
        // word 1
        uint128 pot;
        uint96 minBuy;
        // word 2
        /// @dev the token's countdown reward module, checked at create (0: none)
        address countdown;
        uint40 gradAt;
        /// @dev valid entries + 1, once counted (0: not counted yet)
        uint16 validPlus1;
        // word 3
        uint128 claimed;
        uint128 carryOwed;
        // word 4
        /// @dev seq of the latest valid entry (the `lastBps` share), once counted
        uint64 lastSeq;
        /// @dev Σ spent of the valid entries (the newest included): the weights the rest of the payout is split by
        uint128 validSpent;
    }

    /// @custom:storage-location erc7201:gang.pad3.gradreward
    struct Layout {
        /// @dev new creates allowed
        bool open;
        /// @dev GangHandlerAdmin: `moduleOf(recipient)` says which factory deployed a tax recipient
        address handlerAdmin;
        /// @dev the countdown reward factory whose modules may receive a carry
        address countdownFactory;
        mapping(address token => Reward) rewardOf;
        /// @dev the last `entries` counted buys: seq n in slot (n − 1) % entries; buyer | spent << 160 (quote actually spent, capped at uint96 max)
        mapping(address token => uint256[MAX_ENTRIES]) ringOf;
        /// @dev the counted-buy seq at the wallet's latest curve sell: its entries up to it don't count
        mapping(address token => mapping(address wallet => uint64)) sellSeqOf;
        mapping(address token => mapping(address wallet => bool)) claimedBy;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("gang.pad3.gradreward")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xebb16a90b21c13a653a08c79948f0845192fd2cea390b673a55e7dffc642ad00;

    function layout() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly ("memory-safe") {
            l.slot := s
        }
    }

    // ---------------------------------------------------------------- curve hooks (CurveLogic3)
    /// @dev A curve buy of `token` by `trader`. Counted when the Agent gate is on and `trader` holds an Agent ID (off,
    ///      or a wallet without one on a token past its agent window, a contract wallet could fill the list for free)
    ///      and it actually spent `minBuy`, or it is the buy that graduates the token. Inside the window the gate let
    ///      only Agents buy, so the Agent ID is read only on an open token (and only once the reward is active).
    function onBuy(
        IGangLaunchpad.Config storage c,
        address token,
        address trader,
        uint256 spent,
        uint256 tokens,
        bool graduates
    ) internal {
        Reward storage r = layout().rewardOf[token];
        if (r.state != ACTIVE || !c.agentGateEnabled) return;
        if (Pad3AgentWindowStore.isOpen(token) && !PadCommon.isAgent(c, trader)) return;
        if (spent < r.minBuy && !graduates) return;
        uint64 seq = r.seq + 1;
        r.seq = seq;
        // the share is weighted by what the buy spent (review: many small entries must not out-earn one large one)
        uint256 w = spent > type(uint96).max ? type(uint96).max : spent;
        layout().ringOf[token][(seq - 1) % r.entries] = uint256(uint160(trader)) | (w << 160);
        emit IGangGradRewardBase.GradEntry(token, trader, seq, w, tokens);
    }

    /// @dev A curve sell of `token` by `trader`: its entries counted so far stop counting (later buys count again).
    function onSell(address token, address trader) internal {
        Reward storage r = layout().rewardOf[token];
        if (r.state != ACTIVE) return;
        uint64 seq = r.seq;
        mapping(address => uint64) storage sold = layout().sellSeqOf[token];
        if (seq == 0 || sold[trader] == seq) return;
        sold[trader] = seq;
        emit IGangGradRewardBase.GradDisqualified(token, trader, seq);
    }

    /// @dev `token` graduates: book the pool (a pending refund request is void) and send the carry. Never reverts on
    ///      the module's account: a failed carry is owed (`retryCarry`).
    function onGraduate(address token, address quote) internal {
        Reward storage r = layout().rewardOf[token];
        if (r.state != ACTIVE) return; // none, or refunded
        r.state = BOOKED;
        r.gradAt = uint40(block.timestamp);
        if (r.refundAt != 0) {
            r.refundAt = 0;
            emit IGangGradRewardBase.RefundCancelled(token);
        }
        uint256 carry = carryOf(r);
        emit IGangGradRewardBase.GradRewardBooked(token, r.pot, carry, r.seq);
        if (carry > 0) sendCarry(r, token, quote, carry);
    }

    // ---------------------------------------------------------------- shared math / transfers
    function carryOf(Reward storage r) internal view returns (uint256) {
        return (uint256(r.pot) * r.carryBps) / BPS;
    }

    /// @dev What the entries share: the pool less the carry.
    function payOf(Reward storage r) internal view returns (uint256) {
        return uint256(r.pot) - carryOf(r);
    }

    /// @dev The newest valid entry's bonus, and the rest every valid entry (the newest too) splits by what each
    ///      spent, for `valid` valid entries. Weighting the newest too means splitting the graduating push into two
    ///      buys earns nothing, and `lastBps` 0 still pays the graduating buy its spend's part (spend review L-1/L-2).
    function splitOf(Reward storage r, uint256 valid) internal view returns (uint256 lastShare, uint256 restPay) {
        if (valid == 0) return (0, 0);
        uint256 pay = payOf(r);
        lastShare = (pay * r.lastBps) / BPS;
        restPay = pay - lastShare;
    }

    /// @dev What a valid entry that spent `spent` gets of `restPay` (rounded down; the dust is swept).
    function restShare(uint256 restPay, uint256 spent, uint256 validSpent) internal pure returns (uint256) {
        if (validSpent == 0) return 0;
        return (restPay * spent) / validSpent;
    }

    /// @dev The weight a ring entry holds.
    function spentOf(uint256 entry) internal pure returns (uint256) {
        return entry >> 160;
    }

    /// @dev `amount` to the token's countdown module through its `receiveCarry` (the pad approves, the module pulls).
    ///      Whatever the module did not take is owed, and the allowance is cleared either way.
    function sendCarry(Reward storage r, address token, address quote, uint256 amount) internal {
        address m = r.countdown;
        IERC20 q = IERC20(quote);
        // a call short of gas must fail as a whole, not leave the carry owed: gas estimation would otherwise settle on
        // the cheaper path where the module runs out of gas (re-review L-1)
        if (gasleft() < (CARRY_GAS * 64) / 63 + CARRY_TAIL_GAS) revert IGangGradRewardBase.CarryGasLow();
        uint256 before = q.balanceOf(address(this));
        q.forceApprove(m, amount);
        try ICountdownCarry(m).receiveCarry{gas: CARRY_GAS}(amount) {} catch {}
        q.forceApprove(m, 0);
        uint256 afterBal = q.balanceOf(address(this));
        uint256 sent = before > afterBal ? before - afterBal : 0;
        if (sent > amount) sent = amount; // never: the allowance was `amount`
        if (sent > 0) emit IGangGradRewardBase.CarrySent(token, m, sent);
        if (sent < amount) {
            r.carryOwed += uint128(amount - sent);
            emit IGangGradRewardBase.CarryOwed(token, m, amount - sent);
        }
    }
}
