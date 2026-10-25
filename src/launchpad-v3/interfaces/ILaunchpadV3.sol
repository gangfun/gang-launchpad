// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice LaunchpadV3 surface (draft). Curve / gate / walletCap / graduation are unchanged from V2; only the
///         `bool taxed` switch becomes a TaxConfig. Implementation is not written yet.
interface ILaunchpadV3 {
    /// @param taxBps       0 = untaxed (all other fields must be zero/false). Otherwise one of 100/200/300/500.
    ///                     Fixed for the token's life.
    /// @param bondingTax   Also charge `taxBps` on curve buys/sells, on top of PROTOCOL_FEE_BPS.
    /// @param dividendBps  Share of the token side (70% of each tax) → DividendVault. Must be 10_000 when
    ///                     `vaultFactory` is 0.
    /// @param vaultFactory TemplateRegistry-listed factory, or 0 = holder dividends only.
    /// @param vaultData    abi-encoded per `IVaultFactory(vaultFactory).dataSchema()`.
    struct TaxConfig {
        uint16 taxBps;
        bool bondingTax;
        uint16 dividendBps;
        address vaultFactory;
        bytes vaultData;
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
        address indexed token,
        uint16 taxBps,
        bool bondingTax,
        uint16 dividendBps,
        address indexed vaultFactory,
        address indexed vault
    );

    function create(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        address quote,
        address refPool,
        TaxConfig calldata tax
    ) external returns (address token);

    /// @notice CLI preflight: every TaxConfig check `create` would revert on (tier, registry listing,
    ///         dividendBps, factory.validate), without reverting.
    function checkTaxConfig(TaxConfig calldata tax) external view returns (bool ok, string memory reason);

    function taxConfigOf(address token)
        external
        view
        returns (uint16 taxBps, bool bondingTax, uint16 dividendBps, address vaultFactory, address vault);

    function isAllowedTaxBps(uint256 taxBps) external pure returns (bool);
}
