// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IGangSwapFactory, IGangSwapPair, IGangSwapBoost} from "./interfaces/IGangSwap.sol";

interface IGangSwapBoostWiring {
    function migrator() external view returns (address);
    function quote() external view returns (address);
}

interface IGangSwapFeesWiring {
    function factory() external view returns (address);
    function migrator() external view returns (address);
    function quote() external view returns (address);
}

/// @title GangSwapMigrator (graduation of a GangSwap curve token into its GangSwap pair)
/// @notice The pad sends the token and the quote here, then calls `migrate` in the same tx (SharedMigrator's
///         IMigratorV2 shape). The raise G is split: V = G x tokens / supply stays in the pool as a VIRTUAL reserve
///         (the part no trade could ever reach) and goes to GangSwapBoost as real quote; G - V is the pool's real quote.
///         Spec: docs/SPEC-GANGSWAP-2026-11-22.md §5.
/// @dev The pad list is add-only, as SharedMigrator's: removing a pad would make its graduations revert forever.
///      Factory, boost and this contract point at each other: the deploy predicts the addresses (§13).
contract GangSwapMigrator is Ownable2Step {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IGangSwapFactory public immutable factory;
    IGangSwapBoost public immutable boost;
    /// @notice Phase 1: WBNB only (spec D3).
    address public immutable quote;

    mapping(address => bool) public launchpads;
    /// @notice The pad that graduated a pair (GangSwapFees reads the creator from it, spec §6.4).
    mapping(address pair => address pad) public padOf;

    error OnlyLaunchpad();
    error NothingToMigrate();
    error ZeroAddress();
    error BadQuote();
    error NotWired();

    event LaunchpadAdded(address indexed launchpad);
    event GangSwapMigrated(
        address indexed token,
        address indexed pair,
        address indexed pad,
        uint256 tokenAmount,
        uint256 seed,
        uint256 virtualReserve,
        uint256 lp
    );

    constructor(address owner_, address factory_, address boost_, address quote_) Ownable(owner_) {
        if (factory_ == address(0) || boost_ == address(0) || quote_ == address(0)) revert ZeroAddress();
        factory = IGangSwapFactory(factory_);
        boost = IGangSwapBoost(boost_);
        quote = quote_;
    }

    /// @notice Factory, boost and fees point back at this migrator and at each other (their addresses are predicted
    ///         at deploy, review M2). `addLaunchpad` requires it, so no pad can be wired to a broken set: a pad's
    ///         GangSwap migrator is set once and a wrong set would make every GangSwap graduation revert.
    function wired() public view returns (bool) {
        address fees = factory.fees();
        return factory.migrator() == address(this) && IGangSwapBoostWiring(address(boost)).migrator() == address(this)
            && IGangSwapBoostWiring(address(boost)).quote() == quote
            && IGangSwapFeesWiring(fees).factory() == address(factory)
            && IGangSwapFeesWiring(fees).migrator() == address(this) && IGangSwapFeesWiring(fees).quote() == quote;
    }

    function addLaunchpad(address launchpad) external onlyOwner {
        if (launchpad == address(0)) revert ZeroAddress();
        if (!wired()) revert NotWired();
        launchpads[launchpad] = true;
        emit LaunchpadAdded(launchpad);
    }

    /// @param tokenAmount the tokens the curve did not sell (TOTAL_SUPPLY - sold), already sent here
    /// @param quoteAmount the raise G, already sent here
    function migrate(address token, address quote_, uint256 tokenAmount, uint256 quoteAmount)
        external
        returns (address pair)
    {
        if (!launchpads[msg.sender]) revert OnlyLaunchpad();
        if (token == address(0)) revert ZeroAddress();
        if (quote_ != quote) revert BadQuote();
        if (tokenAmount == 0 || quoteAmount == 0) revert NothingToMigrate();

        // V rounded down: k0 = G x tokens >= V x supply, so the real quote never goes negative (spec I1)
        uint256 v = (quoteAmount * tokenAmount) / IERC20(token).totalSupply();
        uint256 seed = quoteAmount - v;
        if (v == 0 || seed == 0) revert NothingToMigrate();

        // reverts if the pair exists; only this contract can create one (factory), only at graduation (I3)
        pair = factory.createPair(token, quote, quote, v);
        IERC20(token).safeTransfer(pair, tokenAmount);
        IERC20(quote).safeTransfer(pair, seed);
        uint256 lp = IGangSwapPair(pair).mint(DEAD);

        IERC20(quote).safeTransfer(address(boost), v);
        boost.register(token, pair, v);
        padOf[pair] = msg.sender;

        emit GangSwapMigrated(token, pair, msg.sender, tokenAmount, seed, v, lp);
    }
}
