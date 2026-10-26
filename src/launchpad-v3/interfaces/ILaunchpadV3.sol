// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice LaunchpadV3 surface. Curve / Agent gate / 1% wallet cap / ≈15 BNB graduation are unchanged from V2; the
///         `bool taxed` switch becomes a TaxConfig with its own buy / sell tax and a platform-listed tax recipient.
interface ILaunchpadV3 {
    /// @param buyTaxBps   Tax on buys, curve and pool. 0 together with sellTaxBps = untaxed (all fields zero);
    ///                    otherwise 100–500. Fixed for the token's life.
    /// @param sellTaxBps  Tax on sells, curve and pool, same bounds.
    /// @param dividendBps Share of each tax after the platform's 0.5% of volume that goes to holder dividends
    ///                    (0–10_000). The rest goes to `recipient`.
    /// @param recipient   RecipientRegistry-listed address paid in quote (e.g. a project vault). Fixed for the token's
    ///                    life. May be 0 only when dividendBps is 10_000.
    struct TaxConfig {
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 dividendBps;
        address recipient;
    }

    /// @dev Same as V2 minus `taxed`; the tax side is in `TaxConfigured` (always emitted, also for untaxed).
    event Created(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string logoURI,
        address indexed quote,
        address refPair,
        uint256 gradAmt
    );
    event TaxConfigured(
        address indexed token, uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address indexed recipient
    );

    function create(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        address quote,
        address refPool,
        TaxConfig calldata tax
    ) external returns (address token);

    /// @notice CLI preflight: every TaxConfig check `create` would revert on, without reverting.
    function checkTaxConfig(TaxConfig calldata tax) external view returns (bool ok, string memory reason);

    function taxConfigOf(address token)
        external
        view
        returns (uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address recipient);
}
