// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV2PairLite} from "./interfaces/IUniswapV2PairLite.sol";
import {IPairFactoryS} from "./interfaces/IMigratorS.sol";

/// @title PoolCheck (Tip A · any-pool)
/// @notice Resolve quote from a Pancake V2-style pair (or quote+WBNB getPair) and require reserves.
///         Also compute create-time spot graduation amount ≈ targetBnb * reserveQuote / reserveWbnb.
/// @dev Finding M1 (2026-10-23): NEVER trust an arbitrary pair CA. Always require
///      `factory.getPair(quote, wbnb) == pair` so fake/manipulable pairs cannot set gradAmt.
library PoolCheck {
    error ZeroAddress();
    error PairEmpty();
    error PairNoReserves();
    error NotWbnbPair();
    error InvalidPairOrQuote();
    error ThinWbnbReserve();
    error GradAmtZero();
    error PairNotFactory();

    /// @dev `pairOrQuote` may be a pair CA, or an ERC20 quote (then factory.getPair(quote, wbnb)).
    ///      Pair CA path: still resolved only if factory.getPair(quote,wbnb) returns that exact pair.
    /// @return quote Non-WBNB side of the liquid pair.
    /// @return pair  The factory-registered pair that holds reserves.
    function resolveQuoteAndPair(address pairOrQuote, address wbnb, address factory)
        internal
        view
        returns (address quote, address pair)
    {
        if (pairOrQuote == address(0) || wbnb == address(0) || factory == address(0)) revert ZeroAddress();

        if (_looksLikePair(pairOrQuote)) {
            // Candidate pair — extract quote, then REQUIRE factory canonical match (M1).
            quote = _quoteFromPair(pairOrQuote, wbnb);
            address canonical = IPairFactoryS(factory).getPair(quote, wbnb);
            if (canonical == address(0)) revert PairEmpty();
            if (canonical != pairOrQuote) revert PairNotFactory();
            pair = canonical;
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

    /// @dev Resolve quote (+ optional pair) WITHOUT requiring reserves.
    ///      Used when QuoteRegistry.graduationQuoteAmount override is set (ops GradAmt).
    ///      Pair-CA input still requires factory canonical match (M1). Quote-only may return pair=0.
    function resolveQuoteIdentity(address pairOrQuote, address wbnb, address factory)
        internal
        view
        returns (address quote, address pair)
    {
        if (pairOrQuote == address(0) || wbnb == address(0) || factory == address(0)) revert ZeroAddress();

        if (_looksLikePair(pairOrQuote)) {
            quote = _quoteFromPair(pairOrQuote, wbnb);
            address canonical = IPairFactoryS(factory).getPair(quote, wbnb);
            if (canonical == address(0)) revert PairEmpty();
            if (canonical != pairOrQuote) revert PairNotFactory();
            pair = canonical;
        } else {
            quote = pairOrQuote;
            pair = IPairFactoryS(factory).getPair(quote, wbnb);
            if (pair != address(0)) {
                _quoteFromPair(pair, wbnb);
                if (!_pairContains(pair, quote)) revert InvalidPairOrQuote();
            }
        }
    }

    /// @notice Spot graduation quote amount locked at create: `targetBnb * rQuote / rWbnb`.
    /// @dev Reverts if WBNB reserve below `minReserveWbnb` (thin / dust pool) or result is 0.
    function spotGradAmt(address pair, address wbnb, uint256 targetBnb, uint256 minReserveWbnb)
        internal
        view
        returns (uint256 gradAmt)
    {
        if (pair == address(0) || wbnb == address(0)) revert ZeroAddress();
        if (targetBnb == 0) revert GradAmtZero();

        address t0 = IUniswapV2PairLite(pair).token0();
        address t1 = IUniswapV2PairLite(pair).token1();
        (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pair).getReserves();

        uint256 rWbnb;
        uint256 rQuote;
        if (t0 == wbnb) {
            rWbnb = uint256(r0);
            rQuote = uint256(r1);
        } else if (t1 == wbnb) {
            rWbnb = uint256(r1);
            rQuote = uint256(r0);
        } else {
            revert NotWbnbPair();
        }

        if (rWbnb == 0 || rQuote == 0) revert PairNoReserves();
        if (rWbnb < minReserveWbnb) revert ThinWbnbReserve();

        gradAmt = (targetBnb * rQuote) / rWbnb;
        if (gradAmt == 0) revert GradAmtZero();
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

    function _looksLikePair(address maybe) private view returns (bool) {
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
