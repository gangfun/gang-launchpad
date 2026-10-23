// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPairFactoryV2, IPairV2} from "../interfaces/IMigratorV2.sol";

contract MockPair is IPairV2 {
    address public token0;
    address public token1;
    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public totalLp;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (uint112(reserve0), uint112(reserve1), uint32(block.timestamp));
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = bal0 - reserve0;
        uint256 amount1 = bal1 - reserve1;
        liquidity = amount0 + amount1; // naive LP units for PoC
        if (liquidity == 0) liquidity = 1;
        reserve0 = bal0;
        reserve1 = bal1;
        totalLp += liquidity;
        // LP "burn" tracked by leaving tokens in pair; to is DEAD — no ERC20 LP minted
        to; // silence
    }

    /// @notice Minimal Pancake-like swap for Tip B outer-tax liquidation tests (legacy 3-arg).
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external {
        _swap(amount0Out, amount1Out, to);
    }

    /// @notice Uniswap V2 / Pancake 4-arg swap (Finding 2 process path).
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        _swap(amount0Out, amount1Out, to);
    }

    function _swap(uint256 amount0Out, uint256 amount1Out, address to) internal {
        require(amount0Out > 0 || amount1Out > 0, "out");
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        require(bal0 > 0 && bal1 > 0, "reserves");
        reserve0 = bal0;
        reserve1 = bal1;
    }
}

contract MockPairFactory is IPairFactoryV2 {
    mapping(address => mapping(address => address)) public pairs;

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return pairs[tokenA][tokenB];
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(pairs[tokenA][tokenB] == address(0), "exists");
        pair = address(new MockPair(tokenA, tokenB));
        pairs[tokenA][tokenB] = pair;
        pairs[tokenB][tokenA] = pair;
    }
}
