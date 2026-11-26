// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The GangSwap core (=0.5.16 / =0.6.6) as the 0.8 periphery and tests see it.
interface IGangSwapV2Factory {
    function migrator() external view returns (address);
    function fees() external view returns (address);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairsLength() external view returns (uint256);
    function INIT_CODE_PAIR_HASH() external view returns (bytes32);
    function createPair(address tokenA, address tokenB, address quote, uint256 virtualReserve)
        external
        returns (address pair);
}

interface IGangSwapV2Pair {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function quoteIs0() external view returns (bool);
    function virtualReserve() external view returns (uint256);
    function feeAccrued() external view returns (uint256);
    function realQuoteReserve() external view returns (uint256);
    function quoteBalanceBase() external view returns (uint256);
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256 amountOut);
    function getAmountIn(uint256 amountOut, address tokenOut) external view returns (uint256 amountIn);
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
    function claimFees() external returns (uint256 amount);
}

interface IGangSwapV2Boost {
    function register(address token, address pair, uint256 v) external;
    function boosts(address token) external view returns (address pair, uint64 lastStepAt, bool quoteIs0, uint128 v, uint128 left);
}

interface IGangSwapV2BoostFees {
    function collectBoost(address pair) external returns (uint256 amount);
}

/// @notice The pad's `curves` getter (GangLaunchpad3; tuple layout as GangBond / GangRouter decode it).
interface IGangSwapV2PadView {
    function curves(address token)
        external
        view
        returns (
            address creator,
            address quote,
            uint128 realQuote,
            uint128 sold,
            uint128 gradAmt,
            uint128 virtualQuote,
            bool graduated,
            uint16 buyTaxBps,
            uint16 sellTaxBps,
            uint16 dividendBps,
            address pair,
            address refPair
        );
}

/// @notice SharedPlatformFeeBucket: an operator approves, then `notifyAccrual` pulls with transferFrom.
interface IGangSwapV2FeeBucket {
    function notifyAccrual(address quote, uint256 amount) external;
}
