// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IMigratorS {
    /// @notice LaunchpadS must transfer `tokenAmount` of token and `quoteAmount` of quote to the migrator first.
    function migrate(address token, address quote, uint256 tokenAmount, uint256 quoteAmount)
        external
        returns (address pair);
}

interface IPairFactoryS {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPairS {
    function mint(address to) external returns (uint256 liquidity);
}
