// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {GangLiquiditySplitter} from "./GangLiquiditySplitter.sol";
import {IGangPad} from "./interfaces/IGangPad.sol";

interface ILpModuleLister {
    function handler() external view returns (address);
    function listModule(address module, string calldata label) external;
}

/// @title GangLiquiditySplitterFactory — a dev's auto-liquidity recipient in one call
/// @notice `create(bps, salt, payee)` clones GangLiquiditySplitter for the caller (the dev: an Agent, as only an Agent
///         can create the token), initializes it at `bps` with the dev's part going to `payee` (0 = the dev), and has
///         GangHandlerAdmin list it on the tax handler, so the dev can name it as the token's `recipient` right away
///         (the CLI's `gang create … --lp <pct> [--lp-to <addr>]`). The address is `predict(dev, salt)`, known before
///         the clone. Every clone runs the one implementation this factory deployed, over its pad: that is what the
///         Safe checked before allowing the factory on GangHandlerAdmin, so a clone needs no check of its own.
/// @dev No owner, not upgradeable. A new version of the module is a new factory.
contract GangLiquiditySplitterFactory {
    string public constant LABEL = "lp-burn-v1";

    address public immutable pad;
    address public immutable admin;
    /// @notice The GangLiquiditySplitter every clone runs.
    address public immutable implementation;

    address[] internal _all;

    event Created(address indexed dev, address indexed splitter, uint16 lpBps, address payee);

    error ZeroAddress();
    error WrongHandler();
    error NotAgent();

    constructor(address pad_, address admin_) {
        if (pad_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (ILpModuleLister(admin_).handler() != IGangPad(pad_).taxHandler()) revert WrongHandler();
        pad = pad_;
        admin = admin_;
        implementation = address(new GangLiquiditySplitter(pad_));
    }

    /// @notice Clone a splitter for the caller at `lpBps`, its dev part to `payee` (0 = the caller), listed as a tax
    ///         recipient, at `predict(caller, salt)` (a salt the caller used before reverts: that address is taken).
    function create(uint16 lpBps, bytes32 salt, address payee) external returns (address splitter) {
        if (!IGangPad(pad).isAgent(msg.sender)) revert NotAgent();
        splitter = Clones.cloneDeterministic(implementation, _saltOf(msg.sender, salt));
        GangLiquiditySplitter(splitter).initialize(msg.sender, lpBps, payee);
        ILpModuleLister(admin).listModule(splitter, LABEL);
        _all.push(splitter);
        emit Created(msg.sender, splitter, lpBps, GangLiquiditySplitter(splitter).payee());
    }

    /// @notice Where `create(…, salt)` from `dev` puts the splitter.
    function predict(address dev, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _saltOf(dev, salt));
    }

    function splitters() external view returns (address[] memory) {
        return _all;
    }

    function count() external view returns (uint256) {
        return _all.length;
    }

    /// @dev The dev is part of the salt: nobody can take a dev's predicted address first.
    function _saltOf(address dev, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(dev, salt));
    }
}
