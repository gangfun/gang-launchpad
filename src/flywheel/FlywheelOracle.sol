// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV2PairLite} from "../launchpad-v2/interfaces/IUniswapV2PairLite.sol";

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

interface IHasPairView {
    function pair() external view returns (address);
}

/// @title FlywheelOracle — the prices a continuous-mint pad checks and prices mints with (UQ112x112, quote per token)
/// @notice Internal library over the raw data FlywheelTaxHandler records on every pool trade:
///         - spot: the pair's reserves now;
///         - blockStart: the price at this block's first touch (spot if nothing touched the pair yet this block);
///         - high: the recent high of block-start prices, decaying 0.5% a minute: a dump followed by mints finds the
///           pre-dump price here, less only 0.5% for every minute the dump was held;
///         - average: the TWAP over at least the last 30 minutes (the newest observation at least that old, to now);
///           within the first 30 minutes after launch the time before launch counts at the launch price.
library FlywheelOracle {
    uint32 internal constant TWAP_WINDOW = 30 minutes;
    uint256 internal constant OBS_SLOTS = 8;

    error NotLaunched();

    function prices(address handler, address token)
        internal
        view
        returns (uint256 spot, uint256 blockStart, uint256 high, uint256 average)
    {
        address pair = IHasPairView(token).pair();
        spot = spotOf(pair, token);
        (uint32 b, uint224 bp) = IFlywheelOracleData(handler).blockRefOf(token);
        blockStart = b == uint32(block.number) ? bp : spot;
        high = recentHigh(handler, token);
        average = twap(handler, token, pair);
    }

    function spotOf(address pair, address token) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pair).getReserves();
        (uint256 rT, uint256 rQ) =
            IUniswapV2PairLite(pair).token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (rT == 0) return 0;
        return (rQ << 112) / rT;
    }

    /// @dev The recent high of block-start prices, decayed to now.
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

    function twap(address handler, address token, address pair) internal view returns (uint256) {
        IFlywheelOracleData h = IFlywheelOracleData(handler);
        (uint32 launchedAt,, uint224 launchPrice, uint256 launchCum) = h.oracleOf(token);
        if (launchedAt == 0) revert NotLaunched();
        uint256 nowCum = cumulative(pair, token);
        uint32 now32 = uint32(block.timestamp);
        uint32 age = now32 - launchedAt;
        unchecked {
            if (age < TWAP_WINDOW) {
                return (uint256(launchPrice) * (TWAP_WINDOW - age) + (nowCum - launchCum)) / TWAP_WINDOW;
            }
            // the newest observation at least a window old (the launch one if none newer qualifies): the ring holds
            // OBS_SLOTS at least 5 minutes apart, so there always is one
            uint32 target = now32 - TWAP_WINDOW;
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
