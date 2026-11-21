// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGangLaunchpad} from "./interfaces/IGangLaunchpad.sol";
import {IGangGradReward, IGangGradRewardBase} from "./interfaces/IGangGradReward.sol";
import {Pad3GradStore} from "./Pad3GradStore.sol";
import {Pad3AgentWindowStore} from "./Pad3AgentWindowStore.sol";
import {IGangAgentWindow} from "./interfaces/IGangAgentWindow.sol";
import {CurveLogic3} from "./CurveLogic3.sol";
import {Pad3VaultStore} from "./Pad3VaultStore.sol";
import {IGangVaultPad} from "./interfaces/IGangVaultPad.sol";
import {IGangPromote} from "./interfaces/IGangPromote.sol";
import {IGangBasePad} from "./interfaces/IGangBasePad.sol";

/// @title Pad3GradModule — 冲毕业奖励's claims, refund, sweep and views (docs/SPEC-GRAD-REWARD-2026-11-17.md), moved
///        out of Pad3Module for its 24 KB limit
/// @notice Never called directly: Pad3Module's fallback delegatecalls it for IGangGradReward's selectors that
///         Pad3Module does not define (Pad3Module itself is delegatecalled by the pad), so it runs in the proxy's
///         storage, with the proxy's balance and the caller as msg.sender. The create and the owner switch stay in
///         Pad3Module; the curve's hooks are Pad3GradStore's. Also serves the agent window's entry and views
///         (IGangAgentWindow, docs/SPEC-AGENT-WINDOW-2026-11-20.md), for the same 24 KB reason; the window is written
///         by the creates and read by CurveLogic3.
/// @dev STORAGE: as Pad3Module: OZ Ownable / Ownable2Step / ReentrancyGuard (slots 0–2; `nonReentrant` acts on the
///      proxy's guard), then a mirror of GangLaunchpad3's variables in its order (test/gang3/GangLaunchpad3Layout.t.sol
///      checks it); the reward's own state is Pad3GradStore's namespace. No immutables, no owner functions.
contract Pad3GradModule is IGangLaunchpad, IGangGradRewardBase, IGangAgentWindow, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice How long a refund request is public before the dev can take the pool back.
    uint32 public constant GRAD_REFUND_NOTICE = 7 days;
    /// @notice After the notice, how long the dev has to take it; then the request lapses.
    uint32 public constant GRAD_REFUND_WINDOW = 3 days;
    /// @notice After graduation, how long buyers have to claim; then the rest is swept.
    uint32 public constant GRAD_CLAIM_WINDOW = 180 days;
    /// @inheritdoc IGangAgentWindow
    uint16 public constant MIN_AGENT_WINDOW_MINUTES = Pad3AgentWindowStore.MIN_MINUTES;
    /// @inheritdoc IGangAgentWindow
    uint16 public constant MAX_AGENT_WINDOW_MINUTES = Pad3AgentWindowStore.MAX_MINUTES;

    // ---------------------------------------------------------------- mirror of GangLaunchpad3's layout (slot 3 on)
    Config internal _config;
    mapping(address => address) internal bridgePoolOf;
    mapping(address router => bool) internal routers;
    mapping(address token => uint8) internal kindOf;
    mapping(address token => Curve) internal curves;
    mapping(address token => Sale) internal _sales;
    mapping(address token => mapping(address user => Position)) internal positions;
    mapping(address token => string) internal logoURIOf;
    mapping(address quote => uint256) internal owedFee;
    address[] internal allTokens;
    mapping(address token => uint256) internal creatorFeeOf;
    mapping(address token => uint256) internal gradTargetOf;
    mapping(address token => uint8) internal tokenVersionOf;
    mapping(address caller => bool) internal isCaller;

    constructor() Ownable(address(0xdEaD)) {}

    // ---------------------------------------------------------------- agent window (SPEC-AGENT-WINDOW-2026-11-20; here for Pad3Module's 24 KB)
    /// @inheritdoc IGangAgentWindow
    /// @dev As `createWithSalt`: the chosen entry runs delegatecalled on the proxy (its own checks, reentrancy guard and
    ///      events), msg.sender and msg.value unchanged. The window is held in transient storage for this call only and
    ///      taken by the first curve create the caller makes in it (`Pad3AgentWindowStore.consume`); a call that makes
    ///      none reverts, so a window is never left for a later create.
    function createWithAgentWindow(uint16 windowMinutes, bytes calldata data) external payable returns (address token) {
        if (windowMinutes < MIN_AGENT_WINDOW_MINUTES || windowMinutes > MAX_AGENT_WINDOW_MINUTES) {
            revert BadAgentWindow();
        }
        if (data.length < 4 || !_isCurveCreate(bytes4(data[:4]))) revert BadAgentWindowCall();
        Pad3AgentWindowStore.setPending(msg.sender, windowMinutes);
        (bool ok, bytes memory result) = address(this).delegatecall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        (, uint16 left) = Pad3AgentWindowStore.pending();
        if (left != 0) revert AgentWindowNotUsed();
        token = abi.decode(result, (address));
        if (Pad3AgentWindowStore.layout().openAt[token] == 0) revert AgentWindowNotUsed();
    }

    /// @inheritdoc IGangAgentWindow
    function agentOpenAt(address token) external view returns (uint40) {
        return Pad3AgentWindowStore.layout().openAt[token];
    }

    /// @inheritdoc IGangAgentWindow
    function agentWindowOpen(address token) external view returns (bool) {
        return Pad3AgentWindowStore.isOpen(token);
    }

    /// @inheritdoc IGangAgentWindow
    /// @dev A token's own vault never trades it on the curve (the pad's `_checkCurveTrader`): false for it, so the
    ///      registry doesn't quote it (audit B L-1).
    function canTradeCurve(address token, address account) external view returns (bool) {
        if (account != address(0) && account == Pad3VaultStore.layout().vaultOf[token]) return false;
        if (account == address(0)) return !_config.agentGateEnabled || Pad3AgentWindowStore.isOpen(token);
        return CurveLogic3.canTrade(_config, token, account);
    }

    /// @inheritdoc IGangAgentWindow
    function walletCapOn(address token) external view returns (bool) {
        return CurveLogic3.walletCapOn(_config, token);
    }

    /// @dev The curve create entries (and `createWithSalt`, whose own list then picks one of its entries; a 打新 /
    ///      铸币飞轮 create there makes no curve token, so `createWithAgentWindow` reverts AgentWindowNotUsed).
    function _isCurveCreate(bytes4 s) private pure returns (bool) {
        return s
                == bytes4(
                keccak256("create(string,string,string,string,address,address,(uint16,uint16,uint16,address))")
            )
            || s
                == bytes4(
                keccak256(
                "createWithGradTarget(string,string,string,string,address,address,(uint16,uint16,uint16,address),uint256)"
            )
            ) || s == IGangVaultPad.createWithVault.selector || s == IGangPromote.createWithPromote.selector
            || s == IGangBasePad.createWithBase.selector || s == IGangGradReward.createWithGradReward.selector
            || s == bytes4(keccak256("createWithSalt(bytes32,bytes)"));
    }

    function settleGradReward(address token) external nonReentrant {
        _gradSettle(token);
    }

    /// @dev Every valid entry of the caller in the list, added up, once per wallet.
    function claimGradReward(address token) external nonReentrant returns (uint256 amount) {
        (Pad3GradStore.Reward storage r, uint256 valid) = _gradSettle(token);
        if (r.state != Pad3GradStore.BOOKED) revert NotGradState();
        Pad3GradStore.Layout storage g = Pad3GradStore.layout();
        if (g.claimedBy[token][msg.sender]) revert AlreadyClaimed();
        amount = _gradClaimableAt(token, r, msg.sender, valid, r.lastSeq, r.validSpent);
        if (amount == 0) revert NothingToClaim();
        g.claimedBy[token][msg.sender] = true;
        r.claimed += uint128(amount);
        IERC20(curves[token].quote).safeTransfer(msg.sender, amount);
        emit GradClaimed(token, msg.sender, amount);
    }

    /// @dev Anyone, GRAD_CLAIM_WINDOW after graduation: the unclaimed rest (dust included) goes to the countdown module
    ///      (or back to the dev without one) and claims close.
    function sweepGradReward(address token) external nonReentrant {
        Pad3GradStore.Reward storage r = Pad3GradStore.layout().rewardOf[token];
        if (r.state != Pad3GradStore.BOOKED) revert NotGradState();
        if (block.timestamp < uint256(r.gradAt) + GRAD_CLAIM_WINDOW) revert SweepNotDue();
        _gradSettle(token);
        if (r.state != Pad3GradStore.BOOKED) return; // no valid entry: settling closed it
        _gradClose(token, r, Pad3GradStore.payOf(r) - r.claimed);
    }

    function retryCarry(address token) external nonReentrant {
        Pad3GradStore.Reward storage r = Pad3GradStore.layout().rewardOf[token];
        uint256 owed = r.carryOwed;
        if (owed == 0) revert NoCarryOwed();
        r.carryOwed = 0;
        Pad3GradStore.sendCarry(r, token, curves[token].quote, owed);
    }

    /// @dev The creator, `refundAfter` after the create, before graduation. The pool stays until `gradRefund`.
    function requestGradRefund(address token) external {
        Pad3GradStore.Reward storage r = _gradDev(token);
        // a request not used in its window has lapsed: asking again restarts the notice
        if (_refundPending(r) || block.timestamp < uint256(r.createdAt) + r.refundAfter) revert RefundNotDue();
        r.refundAt = uint40(block.timestamp);
        emit RefundRequested(
            token, block.timestamp + GRAD_REFUND_NOTICE, block.timestamp + GRAD_REFUND_NOTICE + GRAD_REFUND_WINDOW
        );
    }

    function cancelGradRefund(address token) external {
        Pad3GradStore.Reward storage r = _gradDev(token);
        if (!_refundPending(r)) revert RefundNotDue();
        r.refundAt = 0;
        emit RefundCancelled(token);
    }

    /// @dev The creator, GRAD_REFUND_NOTICE after its request and within GRAD_REFUND_WINDOW after that, the token
    ///      still on its curve: the whole pool back; the reward ends (a later graduation pays nothing). A request not
    ///      used in its window lapses, so a dev can't keep one ready to front-run a graduation (review M-1).
    function gradRefund(address token) external nonReentrant returns (uint256 amount) {
        Pad3GradStore.Reward storage r = _gradDev(token);
        uint256 at = r.refundAt;
        if (at == 0 || block.timestamp < at + GRAD_REFUND_NOTICE || !_refundPending(r)) revert RefundNotDue();
        r.state = Pad3GradStore.REFUNDED;
        amount = r.pot;
        r.pot = 0;
        IERC20(curves[token].quote).safeTransfer(msg.sender, amount);
        emit Refunded(token, msg.sender, amount);
    }

    function gradReward(address token) external view returns (GradView memory v) {
        Pad3GradStore.Reward storage r = Pad3GradStore.layout().rewardOf[token];
        v = GradView({
            state: r.state,
            pot: r.pot,
            minBuy: r.minBuy,
            entries: r.entries,
            lastBps: r.lastBps,
            carryBps: r.carryBps,
            refundAfter: r.refundAfter,
            createdAt: r.createdAt,
            refundAt: r.refundAt,
            gradAt: r.gradAt,
            seq: r.seq,
            countdown: r.countdown,
            claimed: r.claimed,
            carryOwed: r.carryOwed,
            settled: r.validPlus1 != 0,
            valid: r.validPlus1 == 0 ? 0 : r.validPlus1 - 1,
            validSpent: r.validSpent,
            refundPending: r.state == Pad3GradStore.ACTIVE && _refundPending(r)
        });
    }

    /// @dev Newest first. `spent`: the quote the buy actually spent (its weight). `valid`: not taken out by a later sell
    ///      of the same wallet.
    function gradEntries(address token)
        external
        view
        returns (address[] memory buyers, uint64[] memory seqs, uint96[] memory spent, bool[] memory valid)
    {
        Pad3GradStore.Layout storage g = Pad3GradStore.layout();
        Pad3GradStore.Reward storage r = g.rewardOf[token];
        uint64 s = r.seq;
        uint256 k = r.entries < s ? r.entries : s;
        buyers = new address[](k);
        seqs = new uint64[](k);
        spent = new uint96[](k);
        valid = new bool[](k);
        for (uint256 i; i < k; i++) {
            uint64 sq = s - uint64(i);
            uint256 e = g.ringOf[token][(sq - 1) % r.entries];
            address w = address(uint160(e));
            (buyers[i], seqs[i], spent[i], valid[i]) =
            (w, sq, uint96(Pad3GradStore.spentOf(e)), sq > g.sellSeqOf[token][w]);
        }
    }

    /// @dev 0 before graduation, once claimed, or after the sweep.
    function gradClaimable(address token, address wallet) external view returns (uint256) {
        Pad3GradStore.Layout storage g = Pad3GradStore.layout();
        Pad3GradStore.Reward storage r = g.rewardOf[token];
        if (r.state != Pad3GradStore.BOOKED || g.claimedBy[token][wallet]) return 0;
        if (r.validPlus1 != 0) return _gradClaimableAt(token, r, wallet, r.validPlus1 - 1, r.lastSeq, r.validSpent);
        (uint256 valid, uint64 lastSeq, uint256 validSpent) = _gradCount(token, r);
        return _gradClaimableAt(token, r, wallet, valid, lastSeq, validSpent);
    }

    function gradRewardDeps() external view returns (bool open, address handlerAdmin, address countdownFactory) {
        Pad3GradStore.Layout storage g = Pad3GradStore.layout();
        return (g.open, g.handlerAdmin, g.countdownFactory);
    }

    /// @dev A request made and not lapsed (lapsed: GRAD_REFUND_NOTICE + GRAD_REFUND_WINDOW after it).
    function _refundPending(Pad3GradStore.Reward storage r) private view returns (bool) {
        uint256 at = r.refundAt;
        return at != 0 && block.timestamp < at + GRAD_REFUND_NOTICE + GRAD_REFUND_WINDOW;
    }

    /// @dev The token's reward, the caller its creator, still on the curve with the reward running.
    function _gradDev(address token) private view returns (Pad3GradStore.Reward storage r) {
        r = Pad3GradStore.layout().rewardOf[token];
        if (r.state != Pad3GradStore.ACTIVE) revert NotGradState();
        if (msg.sender != curves[token].creator) revert NotCreator();
    }

    /// @dev Counts the valid entries once (they can't change after graduation: the curve is closed). With none, the
    ///      whole payout goes to the countdown module, or back to the dev, and the reward closes.
    function _gradSettle(address token) private returns (Pad3GradStore.Reward storage r, uint256 valid) {
        r = Pad3GradStore.layout().rewardOf[token];
        if (r.state != Pad3GradStore.BOOKED && r.state != Pad3GradStore.CLOSED) revert NotGradState();
        if (r.validPlus1 != 0) return (r, r.validPlus1 - 1);
        uint64 lastSeq;
        uint256 validSpent;
        (valid, lastSeq, validSpent) = _gradCount(token, r);
        r.validPlus1 = uint16(valid + 1);
        r.lastSeq = lastSeq;
        r.validSpent = uint128(validSpent); // ≤ 20 × uint96 max
        (uint256 lastShare, uint256 restPay) = Pad3GradStore.splitOf(r, valid);
        emit GradSettled(token, valid, lastSeq, lastShare, restPay, validSpent);
        if (valid == 0) _gradClose(token, r, Pad3GradStore.payOf(r));
    }

    /// @dev Valid entries in the list, the seq of the newest one, and Σ spent of all of them.
    function _gradCount(address token, Pad3GradStore.Reward storage r)
        private
        view
        returns (uint256 valid, uint64 lastSeq, uint256 validSpent)
    {
        Pad3GradStore.Layout storage g = Pad3GradStore.layout();
        uint64 s = r.seq;
        uint64 n = r.entries;
        uint64 k = n < s ? n : s;
        for (uint64 sq = s; sq > s - k; sq--) {
            uint256 e = g.ringOf[token][(sq - 1) % n];
            if (sq > g.sellSeqOf[token][address(uint160(e))]) {
                valid++;
                if (lastSeq == 0) lastSeq = sq;
                validSpent += Pad3GradStore.spentOf(e);
            }
        }
    }

    /// @dev `wallet`'s valid entries' shares, added up.
    function _gradClaimableAt(
        address token,
        Pad3GradStore.Reward storage r,
        address wallet,
        uint256 valid,
        uint64 lastSeq,
        uint256 validSpent
    ) private view returns (uint256 amount) {
        if (valid == 0) return 0;
        Pad3GradStore.Layout storage g = Pad3GradStore.layout();
        (uint256 lastShare, uint256 restPay) = Pad3GradStore.splitOf(r, valid);
        uint64 sold = g.sellSeqOf[token][wallet];
        uint64 s = r.seq;
        uint64 n = r.entries;
        uint64 k = n < s ? n : s;
        for (uint64 sq = s; sq > s - k; sq--) {
            uint256 e = g.ringOf[token][(sq - 1) % n];
            if (sq <= sold || address(uint160(e)) != wallet) continue;
            amount += Pad3GradStore.restShare(restPay, Pad3GradStore.spentOf(e), validSpent);
            if (sq == lastSeq) amount += lastShare;
        }
    }

    /// @dev Close the reward and send `amount` (what no buyer can claim any more) on: to the countdown module when
    ///      the token has one (owed if it refuses), else to the creator.
    function _gradClose(address token, Pad3GradStore.Reward storage r, uint256 amount) private {
        r.state = Pad3GradStore.CLOSED;
        if (amount == 0) return;
        if (r.countdown != address(0)) {
            emit GradSwept(token, r.countdown, amount);
            Pad3GradStore.sendCarry(r, token, curves[token].quote, amount);
        } else {
            address dev = curves[token].creator;
            emit GradSwept(token, dev, amount);
            IERC20(curves[token].quote).safeTransfer(dev, amount);
        }
    }
}
