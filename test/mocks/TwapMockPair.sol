// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Pancake V2-like pair for tests that need the oracle: K-checked swap with the 0.25% fee, skim / sync, and
///         price0/1CumulativeLast updated as UniswapV2Pair._update does. Same getters as MockPair (token0/1,
///         getReserves, 4-arg swap), so the fixture's pool helpers work on it. LP is not minted (the first one is
///         burned to 0xdead by the migrator anyway).
contract TwapMockPair {
    address public token0;
    address public token1;
    uint112 internal reserve0;
    uint112 internal reserve1;
    uint32 internal blockTimestampLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public totalSupply;
    bool internal unlocked = true;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    modifier lock() {
        require(unlocked, "LOCKED");
        unlocked = false;
        _;
        unlocked = true;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function mint(address) external lock returns (uint256 liquidity) {
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        liquidity = (bal0 - reserve0) + (bal1 - reserve1);
        totalSupply += liquidity;
        _update(bal0, bal1);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external lock {
        require(amount0Out > 0 || amount1Out > 0, "out");
        require(amount0Out < reserve0 && amount1Out < reserve1, "liquidity");
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        uint256 in0 = bal0 > reserve0 - amount0Out ? bal0 - (reserve0 - amount0Out) : 0;
        uint256 in1 = bal1 > reserve1 - amount1Out ? bal1 - (reserve1 - amount1Out) : 0;
        require(in0 > 0 || in1 > 0, "in");
        uint256 adj0 = bal0 * 10_000 - in0 * 25;
        uint256 adj1 = bal1 * 10_000 - in1 * 25;
        require(adj0 * adj1 >= uint256(reserve0) * reserve1 * 10_000 ** 2, "K");
        _update(bal0, bal1);
    }

    function skim(address to) external lock {
        IERC20(token0).transfer(to, IERC20(token0).balanceOf(address(this)) - reserve0);
        IERC20(token1).transfer(to, IERC20(token1).balanceOf(address(this)) - reserve1);
    }

    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }

    function _update(uint256 bal0, uint256 bal1) internal {
        uint32 now32 = uint32(block.timestamp);
        unchecked {
            uint32 elapsed = now32 - blockTimestampLast;
            if (elapsed > 0 && reserve0 != 0 && reserve1 != 0) {
                price0CumulativeLast += ((uint256(reserve1) << 112) / reserve0) * elapsed;
                price1CumulativeLast += ((uint256(reserve0) << 112) / reserve1) * elapsed;
            }
        }
        reserve0 = uint112(bal0);
        reserve1 = uint112(bal1);
        blockTimestampLast = now32;
    }
}

contract TwapMockPairFactory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address a, address b) external returns (address pair) {
        require(getPair[a][b] == address(0), "exists");
        pair = address(new TwapMockPair(a, b));
        getPair[a][b] = pair;
        getPair[b][a] = pair;
    }
}
