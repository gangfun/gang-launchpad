// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2PairLite} from "./interfaces/IUniswapV2PairLite.sol";
import {IPairFactoryV2} from "./interfaces/IMigratorV2.sol";
import {TickMath} from "./libraries/TickMath.sol";

interface IV3PoolLite {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    /// @dev Pancake V3 packs feeProtocol as uint32 (Uniswap: uint8). Declared uint32 so both decode.
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint32, bool);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface IV3FactoryLite {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @title PoolCheck — dev-supplied reference pool (Pancake V2 pair or V3 pool)
/// @notice The dev passes the pool CA they want the graduation target priced against. We verify it is the
///         canonical factory pool, read the quote's price from it (V3: TWAP via observe(), spot fallback;
///         V2: reserves), and convert a target amount of the counter asset into quote units.
/// @dev Counter asset conversion to WBNB (for "≈15 BNB") is done by the caller via a bridge pool.
library PoolCheck {
    enum PoolKind { None, V2, V3 }

    struct Cfg {
        address wbnb;
        address v2Factory;
        address v3Factory;
        uint32 twapWindow; // seconds; 0 = spot only
    }

    struct PoolInfo {
        PoolKind kind;
        address token0;
        address token1;
        uint24 fee;
    }

    uint256 private constant Q96 = 2 ** 96;

    error ZeroAddress();
    error NotContract();
    error UnknownPoolType();
    error PoolNotFactory();
    error V3FactoryNotSet();
    error QuoteNotInPool();
    error PoolNoLiquidity();
    error ThinReferencePool();
    error GradAmtZero();

    // ------------------------------------------------------------------ inspect
    /// @notice Detect V2/V3 and verify the pool is registered in the respective factory.
    function inspect(Cfg memory cfg, address pool) public view returns (PoolInfo memory info) {
        if (pool == address(0)) revert ZeroAddress();
        if (pool.code.length == 0) revert NotContract();

        if (_isV2(pool)) {
            info.kind = PoolKind.V2;
            info.token0 = IUniswapV2PairLite(pool).token0();
            info.token1 = IUniswapV2PairLite(pool).token1();
            if (cfg.v2Factory == address(0)) revert ZeroAddress();
            if (IPairFactoryV2(cfg.v2Factory).getPair(info.token0, info.token1) != pool) revert PoolNotFactory();
            return info;
        }
        if (_isV3(pool)) {
            info.kind = PoolKind.V3;
            info.token0 = IV3PoolLite(pool).token0();
            info.token1 = IV3PoolLite(pool).token1();
            info.fee = IV3PoolLite(pool).fee();
            if (cfg.v3Factory == address(0)) revert V3FactoryNotSet();
            if (IV3FactoryLite(cfg.v3Factory).getPool(info.token0, info.token1, info.fee) != pool) revert PoolNotFactory();
            if (IV3PoolLite(pool).liquidity() == 0) revert PoolNoLiquidity();
            return info;
        }
        revert UnknownPoolType();
    }

    /// @notice The other token of the pool. Reverts if `quote` is not in the pool.
    function counterOf(PoolInfo memory info, address quote) public pure returns (address) {
        if (quote == info.token0) return info.token1;
        if (quote == info.token1) return info.token0;
        revert QuoteNotInPool();
    }

    /// @notice Pool depth of `token` (V2 reserve / V3 balance).
    function depthOf(PoolInfo memory info, address pool, address token) public view returns (uint256) {
        if (info.kind == PoolKind.V2) {
            (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pool).getReserves();
            return token == info.token0 ? uint256(r0) : uint256(r1);
        }
        return IERC20(token).balanceOf(pool);
    }

    // ------------------------------------------------------------------ convert
    /// @notice How many `tokenOut` are worth `amountOther` of the pool's other token, at pool price.
    function convert(Cfg memory cfg, PoolInfo memory info, address pool, address tokenOut, uint256 amountOther)
        public
        view
        returns (uint256 amountOut)
    {
        bool outIs0 = tokenOut == info.token0;
        if (!outIs0 && tokenOut != info.token1) revert QuoteNotInPool();

        if (info.kind == PoolKind.V2) {
            (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pool).getReserves();
            if (r0 == 0 || r1 == 0) revert PoolNoLiquidity();
            return outIs0 ? Math.mulDiv(amountOther, r0, r1) : Math.mulDiv(amountOther, r1, r0);
        }

        uint160 sqrtP = _v3SqrtPrice(cfg, pool);
        uint256 priceX96 = Math.mulDiv(sqrtP, sqrtP, Q96); // token1 per token0, Q96
        if (priceX96 == 0) revert PoolNoLiquidity();
        // tokenOut == token0: amountOther is token1 → out = other / price
        // tokenOut == token1: amountOther is token0 → out = other * price
        return outIs0 ? Math.mulDiv(amountOther, Q96, priceX96) : Math.mulDiv(amountOther, priceX96, Q96);
    }

    /// @dev TWAP over cfg.twapWindow when the pool's observation buffer allows; otherwise spot (slot0).
    function _v3SqrtPrice(Cfg memory cfg, address pool) private view returns (uint160) {
        if (cfg.twapWindow > 0) {
            uint32[] memory ago = new uint32[](2);
            ago[0] = cfg.twapWindow;
            ago[1] = 0;
            try IV3PoolLite(pool).observe(ago) returns (int56[] memory cum, uint160[] memory) {
                int56 delta = cum[1] - cum[0];
                int56 window = int56(uint56(cfg.twapWindow));
                int24 meanTick = int24(delta / window);
                if (delta < 0 && (delta % window != 0)) meanTick--;
                return TickMath.getSqrtRatioAtTick(meanTick);
            } catch {}
        }
        (uint160 sqrtP,,,,,,) = IV3PoolLite(pool).slot0();
        return sqrtP;
    }

    // ------------------------------------------------------------------ detection
    function _isV2(address pool) private view returns (bool) {
        try IUniswapV2PairLite(pool).getReserves() returns (uint112, uint112, uint32) {
            return true;
        } catch {
            return false;
        }
    }

    function _isV3(address pool) private view returns (bool) {
        try IV3PoolLite(pool).fee() returns (uint24) {
            try IV3PoolLite(pool).slot0() returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
                return true;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
