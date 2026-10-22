// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title QuoteRegistry (Stocks track)
/// @notice Whitelist of quote tokens (bStock) allowed for LaunchpadS creates.
/// @dev PoC: setQuote(MockSPCXB, true, 1e18). Does NOT store curve state.
contract QuoteRegistry is Ownable {
    struct QuoteInfo {
        bool enabled;
        uint256 graduationQuoteAmount;
        bool nativeSwapEnabled;
    }

    mapping(address => QuoteInfo) public quotes;

    event QuoteUpdated(address indexed quote, bool enabled, uint256 graduationQuoteAmount, bool nativeSwapEnabled);

    error ZeroAddress();

    constructor(address owner_) Ownable(owner_) {}

    function setQuote(address quote, bool enabled, uint256 graduationQuoteAmount) external onlyOwner {
        if (quote == address(0)) revert ZeroAddress();
        quotes[quote] = QuoteInfo({
            enabled: enabled,
            graduationQuoteAmount: graduationQuoteAmount,
            nativeSwapEnabled: false
        });
        emit QuoteUpdated(quote, enabled, graduationQuoteAmount, false);
    }

    function setNativeSwapEnabled(address quote, bool enabled) external onlyOwner {
        if (quote == address(0)) revert ZeroAddress();
        quotes[quote].nativeSwapEnabled = enabled;
        QuoteInfo memory q = quotes[quote];
        emit QuoteUpdated(quote, q.enabled, q.graduationQuoteAmount, enabled);
    }

    function isQuoted(address quote) external view returns (bool) {
        return quotes[quote].enabled;
    }

    function graduationAmount(address quote) external view returns (uint256) {
        return quotes[quote].graduationQuoteAmount;
    }

    function nativeSwapEnabled(address quote) external view returns (bool) {
        return quotes[quote].nativeSwapEnabled;
    }
}
