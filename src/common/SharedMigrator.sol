// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IMigratorV2, IPairFactoryV2, IPairV2} from "../launchpad-v2/interfaces/IMigratorV2.sol";

/// @title SharedMigrator (LaunchpadV3 + 打新 · graduation into a Pancake V2 pair, LP burned)
/// @notice launchpad-v2/MigratorV2 for several cores. The core sends the token and quote here, then calls `migrate` in
///         the same tx; nothing is held between calls.
/// @dev The core list is add-only: removing a core would make every graduation / launch of its tokens revert forever
///      (the old one-core migrator had no such power, and this one shouldn't either).
contract SharedMigrator is IMigratorV2, Ownable2Step {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPairFactoryV2 public immutable factory;
    mapping(address => bool) public launchpads;

    error OnlyLaunchpad();
    error NothingToMigrate();
    error ZeroAddress();
    error PairHasLiquidity();

    event LaunchpadAdded(address indexed launchpad);
    event Migrated(
        address indexed token,
        address indexed pair,
        address indexed quote,
        uint256 tokenAmount,
        uint256 quoteAmount,
        uint256 lp
    );

    constructor(address owner_, address factory_) Ownable(owner_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = IPairFactoryV2(factory_);
    }

    function addLaunchpad(address launchpad) external onlyOwner {
        if (launchpad == address(0)) revert ZeroAddress();
        launchpads[launchpad] = true;
        emit LaunchpadAdded(launchpad);
    }

    function migrate(address token, address quote, uint256 tokenAmount, uint256 quoteAmount)
        external
        returns (address pair)
    {
        if (!launchpads[msg.sender]) revert OnlyLaunchpad();
        if (tokenAmount == 0 || quoteAmount == 0) revert NothingToMigrate();
        if (quote == address(0) || token == address(0)) revert ZeroAddress();

        pair = factory.getPair(token, quote);
        if (pair == address(0)) pair = factory.createPair(token, quote);

        IERC20(token).safeTransfer(pair, tokenAmount);
        IERC20(quote).safeTransfer(pair, quoteAmount);

        // audit 4 A-F4: the whole first LP position goes to 0xdead. A quote whose transfer hook calls `pair.mint` in
        // between would take it and leave 0xdead dust, so the pair must still have no LP here. (A pre-created pair
        // has none: the token is locked until this tx.) Read low-level: test mocks have no totalSupply.
        (bool ok, bytes memory ret) = pair.staticcall(abi.encodeWithSignature("totalSupply()"));
        if (ok && ret.length >= 32 && abi.decode(ret, (uint256)) != 0) revert PairHasLiquidity();

        uint256 lp = IPairV2(pair).mint(DEAD);
        emit Migrated(token, pair, quote, tokenAmount, quoteAmount, lp);
    }
}
