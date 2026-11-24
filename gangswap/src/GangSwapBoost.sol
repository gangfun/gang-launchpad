// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IGangSwapPair} from "./interfaces/IGangSwap.sol";

/// @title GangSwapBoost (scheduled buy-back-and-burn after graduation)
/// @notice Holds each GangSwap token's V (the quote taken out of the pool at graduation) and spends it on a fixed
///         schedule, pump-style: ~40 steps, at least STEP_GAP apart, each buying the token from its pair and sending
///         it to 0xdead. Anyone can call `step`; no price condition (spec D8, decided by the user 2026-11-22).
/// @dev Each step is capped at CAP_BPS of the pool's effective quote reserve, so a sandwich around it loses money:
///      it moves the price ~2 x 0.5% = 1% against a ~2% round-trip fee (spec §7.3). The gap runs from the last step,
///      so a late keeper never catches up several steps at once. No owner, nothing to change.
contract GangSwapBoost is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant STEPS = 40;
    uint256 public constant STEP_GAP = 8; // seconds; block.timestamp is whole seconds
    uint256 public constant CAP_BPS = 50; // 0.5% of the effective quote reserve
    /// @dev A step that would leave less than V / DUST_DIV spends the rest (no extra step for a few wei).
    uint256 public constant DUST_DIV = 400;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant FEE_NUM = 9_900; // the pair's 1% fee, as GangSwapRouter

    address public immutable migrator;
    address public immutable quote;

    struct Boost {
        address pair;
        uint64 lastStepAt;
        bool quoteIs0;
        uint128 v;
        uint128 left;
    }

    mapping(address token => Boost) public boosts;

    error OnlyMigrator();
    error AlreadyRegistered();
    error ZeroAddress();
    error NothingLeft();
    error TooEarly();
    error NothingToBuy();

    event BoostRegistered(address indexed token, address indexed pair, uint256 v);
    event BoostStep(address indexed token, uint256 quoteIn, uint256 tokensBurned, uint256 left);

    constructor(address migrator_, address quote_) {
        if (migrator_ == address(0) || quote_ == address(0)) revert ZeroAddress();
        migrator = migrator_;
        quote = quote_;
    }

    /// @notice The migrator, at graduation, after sending `v` of the quote here.
    function register(address token, address pair, uint256 v) external {
        if (msg.sender != migrator) revert OnlyMigrator();
        Boost storage b = boosts[token];
        if (b.pair != address(0)) revert AlreadyRegistered();
        b.pair = pair;
        b.quoteIs0 = IGangSwapPair(pair).quoteIs0();
        b.v = v.toUint128();
        b.left = v.toUint128();
        emit BoostRegistered(token, pair, v);
    }

    /// @notice The quote the next step would spend, and whether it can run now.
    function nextStep(address token) public view returns (uint256 quoteIn, bool ready) {
        Boost memory b = boosts[token];
        if (b.left == 0) return (0, false);
        (uint256 rq,) = _reserves(b);
        quoteIn = _stepSize(b, rq);
        ready = b.lastStepAt == 0 || block.timestamp >= uint256(b.lastStepAt) + STEP_GAP;
    }

    /// @notice One buy-back step for `token`: buys from its pair and sends what arrives to 0xdead.
    function step(address token) external nonReentrant returns (uint256 quoteIn, uint256 tokensOut) {
        Boost storage b = boosts[token];
        if (b.left == 0) revert NothingLeft();
        if (b.lastStepAt != 0 && block.timestamp < uint256(b.lastStepAt) + STEP_GAP) revert TooEarly();

        Boost memory m = b;
        (uint256 rq, uint256 rt) = _reserves(m);
        quoteIn = _stepSize(m, rq);
        // V2 maths with the pair's 1% fee (GangSwapRouter's getAmountOut)
        uint256 inWithFee = quoteIn * FEE_NUM;
        tokensOut = (inWithFee * rt) / (rq * BPS + inWithFee);
        if (tokensOut == 0) revert NothingToBuy();

        b.left = m.left - quoteIn.toUint128();
        b.lastStepAt = block.timestamp.toUint64();

        IERC20(quote).safeTransfer(m.pair, quoteIn);
        if (m.quoteIs0) IGangSwapPair(m.pair).swap(0, tokensOut, DEAD, "");
        else IGangSwapPair(m.pair).swap(tokensOut, 0, DEAD, "");

        emit BoostStep(token, quoteIn, tokensOut, b.left);
    }

    function _reserves(Boost memory b) private view returns (uint256 rq, uint256 rt) {
        (uint112 r0, uint112 r1,) = IGangSwapPair(b.pair).getReserves();
        (rq, rt) = b.quoteIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// @dev min(left, V / STEPS, CAP_BPS of the effective quote reserve), at least 1 wei; the last bit of dust is
    ///      folded in. rq >= V always (spec I1), so a step is at least min(left, V x 0.5%): ~200 steps at most.
    function _stepSize(Boost memory b, uint256 rq) private pure returns (uint256 s) {
        uint256 left = b.left;
        s = b.v / STEPS;
        uint256 cap = (rq * CAP_BPS) / BPS;
        if (cap < s) s = cap;
        if (s == 0) s = 1;
        if (s > left || left - s < b.v / DUST_DIV) s = left;
    }
}
