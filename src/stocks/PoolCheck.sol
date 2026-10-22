// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV2PairLite} from "./interfaces/IUniswapV2PairLite.sol";
import {IPairFactoryS} from "./interfaces/IMigratorS.sol";

/// @title PoolCheck (Tip A · any-pool)
/// @notice Resolve quote from a Pancake V2-style pair (or quote+WBNB getPair) and require reserves.
library PoolCheck {
    error ZeroAddress();
    error PairEmpty();
    error PairNoReserves();
    error NotWbnbPair();
    error InvalidPairOrQuote();

    /// @dev `pairOrQuote` may be a pair CA, or an ERC20 quote (then factory.getPair(quote, wbnb)).
    /// @return quote Non-WBNB side of the liquid pair.
    /// @return pair  The pair that holds reserves.
    function resolveQuoteAndPair(address pairOrQuote, address wbnb, address factory)
        internal
        view
        returns (address quote, address pair)
    {
        if (pairOrQuote == address(0) || wbnb == address(0) || factory == address(0)) revert ZeroAddress();

        if (_tryAsPair(pairOrQuote)) {
            pair = pairOrQuote;
            quote = _quoteFromPair(pair, wbnb);
        } else {
            quote = pairOrQuote;
            pair = IPairFactoryS(factory).getPair(quote, wbnb);
            if (pair == address(0)) revert PairEmpty();
            // Sanity: pair must contain quote + wbnb
            _quoteFromPair(pair, wbnb);
            if (!_pairContains(pair, quote)) revert InvalidPairOrQuote();
        }

        _requireReserves(pair);
    }

    function hasReserves(address pair) internal view returns (bool) {
        if (pair == address(0)) return false;
        try IUniswapV2PairLite(pair).getReserves() returns (uint112 r0, uint112 r1, uint32) {
            return r0 > 0 && r1 > 0;
        } catch {
            return false;
        }
    }

    function _requireReserves(address pair) private view {
        if (!hasReserves(pair)) revert PairNoReserves();
    }

    function _tryAsPair(address maybe) private view returns (bool) {
        try IUniswapV2PairLite(maybe).token0() returns (address) {
            try IUniswapV2PairLite(maybe).token1() returns (address) {
                try IUniswapV2PairLite(maybe).getReserves() returns (uint112, uint112, uint32) {
                    return true;
                } catch {
                    return false;
                }
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    function _quoteFromPair(address pair, address wbnb) private view returns (address quote) {
        address t0 = IUniswapV2PairLite(pair).token0();
        address t1 = IUniswapV2PairLite(pair).token1();
        if (t0 == wbnb) quote = t1;
        else if (t1 == wbnb) quote = t0;
        else revert NotWbnbPair();
        if (quote == address(0)) revert ZeroAddress();
    }

    function _pairContains(address pair, address token) private view returns (bool) {
        address t0 = IUniswapV2PairLite(pair).token0();
        address t1 = IUniswapV2PairLite(pair).token1();
        return t0 == token || t1 == token;
    }
}
