// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IGangSwapV2Pair, IGangSwapV2Factory, IGangSwapV2BoostFees} from "./interfaces/IGangSwapV2.sol";

/// @title GangSwapV2Boost (scheduled buy-back-and-burn after graduation)
/// @notice Holds each GangSwap token's V (the quote taken out of the pool at graduation) and spends it on a fixed
///         schedule, pump-style: ~40 steps, at least STEP_GAP apart, each buying the token from its pair and sending
///         it to 0xdead. Anyone can call `step`; no price condition (spec D8, decided by the user 2026-11-22).
/// @dev Each step uses the pool's effective quote reserve for the cap. The gap runs from the last step.
contract GangSwapV2Boost is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant STEPS = 40;
    uint256 public constant STEP_GAP = 8; // seconds; block.timestamp is whole seconds
    uint256 public constant CAP_BPS = 50; // 0.5% of the effective quote reserve
    /// @dev Fold remaining dust into the step when the whole remainder fits under the cap.
    uint256 public constant DUST_DIV = 400;
    uint256 internal constant BPS = 10_000;

    address public immutable migrator;
    address public immutable quote;
    IGangSwapV2Factory public immutable factory;

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

    constructor(address migrator_, address quote_, address factory_) {
        if (migrator_ == address(0) || quote_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        migrator = migrator_;
        quote = quote_;
        factory = IGangSwapV2Factory(factory_);
    }

    function fees() external view returns (address) {
        return factory.fees();
    }

    /// @notice The migrator, at graduation, after sending `v` of the quote here.
    function register(address token, address pair, uint256 v) external {
        if (msg.sender != migrator) revert OnlyMigrator();
        Boost storage b = boosts[token];
        if (b.pair != address(0)) revert AlreadyRegistered();
        b.pair = pair;
        b.quoteIs0 = IGangSwapV2Pair(pair).quoteIs0();
        b.v = v.toUint128();
        b.left = v.toUint128();
        emit BoostRegistered(token, pair, v);
    }

    /// @notice The quote the next step would spend, and whether it can run now.
    function nextStep(address token) public view returns (uint256 quoteIn, bool ready) {
        Boost memory b = boosts[token];
        if (b.left == 0) return (0, false);
        uint256 rq = _quoteReserve(b);
        quoteIn = _stepSize(b, rq);
        ready = b.lastStepAt == 0 || block.timestamp >= uint256(b.lastStepAt) + STEP_GAP;
    }

    /// @notice One buy-back step for `token`: buys from its pair and sends what arrives to 0xdead.
    function step(address token) external nonReentrant returns (uint256 quoteIn, uint256 tokensOut) {
        Boost storage b = boosts[token];
        if (b.left == 0) revert NothingLeft();
        if (b.lastStepAt != 0 && block.timestamp < uint256(b.lastStepAt) + STEP_GAP) revert TooEarly();

        Boost memory m = b;
        IGangSwapV2Pair pair = IGangSwapV2Pair(m.pair);
        quoteIn = _stepSize(m, _quoteReserve(m));
        tokensOut = pair.getAmountOut(quoteIn, quote);
        if (tokensOut == 0) revert NothingToBuy();

        b.left = m.left - quoteIn.toUint128();
        b.lastStepAt = block.timestamp.toUint64();

        IERC20(quote).safeTransfer(m.pair, quoteIn);
        if (m.quoteIs0) pair.swap(0, tokensOut, DEAD, "");
        else pair.swap(tokensOut, 0, DEAD, "");
        IGangSwapV2BoostFees(IGangSwapV2Factory(pair.factory()).fees()).collectBoost(m.pair);

        emit BoostStep(token, quoteIn, tokensOut, b.left);
    }

    function _quoteReserve(Boost memory b) private view returns (uint256) {
        (uint112 r0, uint112 r1,) = IGangSwapV2Pair(b.pair).getReserves();
        return b.quoteIs0 ? r0 : r1;
    }

    /// @dev Spend the minimum of left, V / STEPS and the cap, with a 1 wei minimum. Fold dust only within the cap.
    ///      At the 6, 9, 12 and 15 BNB tiers the step count runs from 40 quiet steps to at most 140.
    function _stepSize(Boost memory b, uint256 rq) private pure returns (uint256 s) {
        uint256 left = b.left;
        s = b.v / STEPS;
        uint256 cap = (rq * CAP_BPS) / BPS;
        if (cap < s) s = cap;
        if (s == 0) s = 1;
        if (s > left || (left <= cap && left - s < b.v / DUST_DIV)) s = left;
    }
}
