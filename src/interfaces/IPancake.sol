// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPancakePair {
    function mint(address to) external returns (uint256 liquidity);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IWBNB {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}

interface IPancakeRouter02 {
    function WETH() external view returns (address);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}
