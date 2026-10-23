// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title QuoteRegistry (Stocks track)
/// @notice Whitelist of quote tokens (bStock) for LaunchpadS; optional graduationQuoteAmount override for U/S.
/// @dev Ops: setQuote(quote, true, gradAmt). gradAmt>0 → create locks that amount (skips PoolCheck spot).
///      gradAmt==0 → LaunchpadU/S fall back to PoolCheck V2 spot (or tip S requires >0).
///      OPT5B: graduationAmount returns 0 when enabled==false (U/S override gated by whitelist flag).
///      Mainnet bStock examples (appendix C): NVDAB/TSLAB/CRCLB/MUB/SNDKB/SPCXB — set ≈15 BNB-equiv quote units.

contract QuoteRegistry is Ownable2Step {
    struct QuoteInfo {
        bool enabled;
        uint256 graduationQuoteAmount;
    }

    mapping(address => QuoteInfo) public quotes;

    event QuoteUpdated(address indexed quote, bool enabled, uint256 graduationQuoteAmount);

    error ZeroAddress();

    constructor(address owner_) Ownable(owner_) {}

    function setQuote(address quote, bool enabled, uint256 graduationQuoteAmount) external onlyOwner {
        if (quote == address(0)) revert ZeroAddress();
        quotes[quote] = QuoteInfo({enabled: enabled, graduationQuoteAmount: graduationQuoteAmount});
        emit QuoteUpdated(quote, enabled, graduationQuoteAmount);
    }

    function isQuoted(address quote) external view returns (bool) {
        return quotes[quote].enabled;
    }

    /// @notice Ops override for create-time gradAmt. Returns 0 when quote is disabled (OPT5B).
    function graduationAmount(address quote) external view returns (uint256) {
        QuoteInfo memory q = quotes[quote];
        if (!q.enabled) return 0;
        return q.graduationQuoteAmount;
    }
}
