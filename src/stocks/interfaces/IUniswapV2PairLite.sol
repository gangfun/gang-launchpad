// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal Pancake/Uniswap V2 pair surface for Tip A pool checks.
interface IUniswapV2PairLite {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}
