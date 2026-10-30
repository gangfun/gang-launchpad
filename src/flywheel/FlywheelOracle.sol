// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV2PairLite} from "../launchpad-v2/interfaces/IUniswapV2PairLite.sol";
import {IFlywheelPad} from "./interfaces/IFlywheelPad.sol";

/// @notice The raw oracle data FlywheelTaxHandler keeps (its public getters).
interface IFlywheelOracleData {
    function oracleOf(address token)
        external
        view
        returns (uint32 launchedAt, uint8 last, uint224 launchPrice, uint256 launchCumulative);
    function observation(address token, uint256 i) external view returns (uint32 timestamp, uint256 cumulative);
    function blockRefOf(address token) external view returns (uint32 blockNumber, uint224 price);
    function peakOf(address token) external view returns (uint32 time, uint224 high);
    function decayedHigh(uint256 high, uint256 elapsed) external pure returns (uint256);
}

interface IPairCumulativeView {
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

/// @title FlywheelOracle — the prices a continuous-mint pad checks and prices mints with (UQ112x112, quote per token)
/// @notice Internal library over the raw data FlywheelTaxHandler records on every pool trade:
///         - spot: the pair's reserves now;
///         - blockStart: the price at this block's first touch (spot if nothing touched the pair yet this block);
///         - average: the TWAP over at least the sale's window (900 or 1,800 s: the newest observation at least that
///           old, to now); within the first window after launch the time before launch counts at the launch price;
///         - high: the handler's recent high of block-start prices (decaying 0.5% a minute). V2 neither prices nor
///           refuses mints with it; the pad's `prices` view still reports it for information.
///         The handler (unchanged from V1) observes at most every 5 minutes into 8 slots, so both windows come from the
///         same observations; its previous-block start (`prevBlockStartOf`) is no longer read (nor declared here).
library FlywheelOracle {
    uint256 internal constant OBS_SLOTS = 8;

    function spotOf(address pair, address token) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pair).getReserves();
        (uint256 rT, uint256 rQ) =
            IUniswapV2PairLite(pair).token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        return spotFrom(rT, rQ);
    }

    /// @dev The price of reserves `rT` (token) and `rQ` (quote).
    function spotFrom(uint256 rT, uint256 rQ) internal pure returns (uint256) {
        if (rT == 0) return 0;
        return (rQ << 112) / rT;
    }

    /// @dev This block's first-touch price, or `spot` while nothing touched the pair yet this block.
    function blockStart(address handler, address token, uint256 spot) internal view returns (uint256) {
        (uint32 b, uint224 bp) = IFlywheelOracleData(handler).blockRefOf(token);
        return b == uint32(block.number) ? bp : spot;
    }

    /// @dev The recent high of block-start prices, decayed to now (information only).
    function recentHigh(address handler, address token) internal view returns (uint256) {
        (uint32 t, uint224 h) = IFlywheelOracleData(handler).peakOf(token);
        return IFlywheelOracleData(handler).decayedHigh(h, block.timestamp - t);
    }

    /// @dev The pair's cumulative quote-per-token price now (stored value plus the current price since its update).
    function cumulative(address pair, address token) internal view returns (uint256 cum) {
        bool tokenIs0 = IUniswapV2PairLite(pair).token0() == token;
        cum = tokenIs0
            ? IPairCumulativeView(pair).price0CumulativeLast()
            : IPairCumulativeView(pair).price1CumulativeLast();
        (,, uint32 last) = IUniswapV2PairLite(pair).getReserves();
        unchecked {
            uint32 elapsed = uint32(block.timestamp) - last;
            if (elapsed > 0) cum += spotOf(pair, token) * elapsed;
        }
    }

    /// @param window the sale's TWAP window in seconds (900 or 1,800; never 0)
    /// @dev Known limitation (audit V2 A-I1): times are uint32 seconds, as the handler and the pair store them. The
    ///      differences below are unchecked, so they stay right across the uint32 wrap (7 February 2106), but the
    ///      observation search compares absolute values (`ts <= target && ts > bestTs`, the launch time as the floor)
    ///      and the handler's ring is not wrap-aware either. A sale launched before the wrap would, after it, find no
    ///      observation newer than its launch and fall back to the TWAP since launch (a span longer than its window).
    ///      The handler must stay byte-identical to V1, so this is accepted, not fixed.
    function twap(address handler, address token, address pair, uint32 window) internal view returns (uint256) {
        IFlywheelOracleData h = IFlywheelOracleData(handler);
        (uint32 launchedAt,, uint224 launchPrice, uint256 launchCum) = h.oracleOf(token);
        if (launchedAt == 0) revert IFlywheelPad.NotLaunched();
        uint256 nowCum = cumulative(pair, token);
        uint32 now32 = uint32(block.timestamp);
        uint32 age = now32 - launchedAt;
        unchecked {
            if (age < window) {
                return (uint256(launchPrice) * (window - age) + (nowCum - launchCum)) / window;
            }
            // the newest observation at least a window old (the launch one if none newer qualifies): the ring holds
            // OBS_SLOTS at least 5 minutes apart, so there always is one
            uint32 target = now32 - window;
            uint32 bestTs = launchedAt;
            uint256 bestCum = launchCum;
            for (uint256 i; i < OBS_SLOTS; i++) {
                (uint32 ts, uint256 cum) = h.observation(token, i);
                if (ts != 0 && ts <= target && ts > bestTs) (bestTs, bestCum) = (ts, cum);
            }
            return (nowCum - bestCum) / (now32 - bestTs);
        }
    }
}
