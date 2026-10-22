// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMigratorS, IPairFactoryS, IPairS} from "./interfaces/IMigratorS.sol";

/// @title MigratorS (Stocks track)
/// @notice Graduates liquidity into TOKEN/quote Pancake-like pair and burns LP.
/// @dev Parallel to main Migrator (WBNB); does not touch main-track contracts.
contract MigratorS is IMigratorS {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPairFactoryS public immutable factory;
    address public immutable launchpad;

    error OnlyLaunchpad();
    error NothingToMigrate();
    error ZeroAddress();

    event Migrated(
        address indexed token,
        address indexed pair,
        address indexed quote,
        uint256 tokenAmount,
        uint256 quoteAmount,
        uint256 lp
    );

    constructor(address factory_, address launchpad_) {
        if (factory_ == address(0) || launchpad_ == address(0)) revert ZeroAddress();
        factory = IPairFactoryS(factory_);
        launchpad = launchpad_;
    }

    function migrate(address token, address quote, uint256 tokenAmount, uint256 quoteAmount)
        external
        returns (address pair)
    {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (tokenAmount == 0 || quoteAmount == 0) revert NothingToMigrate();
        if (quote == address(0) || token == address(0)) revert ZeroAddress();

        pair = factory.getPair(token, quote);
        if (pair == address(0)) pair = factory.createPair(token, quote);

        IERC20(token).safeTransfer(pair, tokenAmount);
        IERC20(quote).safeTransfer(pair, quoteAmount);

        uint256 lp = IPairS(pair).mint(DEAD);
        emit Migrated(token, pair, quote, tokenAmount, quoteAmount, lp);
    }
}
