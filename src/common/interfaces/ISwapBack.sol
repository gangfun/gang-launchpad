// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What a taxed token calls on its handler when a taxed sell of `sellAmount` goes into its pair, before the sold
///         tokens move: the handler sells a small chunk of the tax it holds (sell-time swap-back).
interface ISwapBack {
    function swapBack(address token, uint256 sellAmount) external returns (uint256 quoteOut);
}
