// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {GangComboSplitter} from "./GangComboSplitter.sol";
import {IGangPad} from "./interfaces/IGangPad.sol";

interface IComboModuleLister {
    function handler() external view returns (address);
    function listModule(address module, string calldata label) external;
}

/// @title GangComboSplitterFactory — a dev's combined recipient (buy-back + liquidity + payees) in one call
/// @notice `create(buybackBps, lpBps, payees, shares, salt)` clones GangComboSplitter for the caller (the dev: an Agent,
///         as only an Agent can create the token), initializes it with its fixed ratios and payee list and has
///         GangHandlerAdmin list it on the tax handler, so the dev can name it as the token's `recipient` right away
///         (the CLI's `gang create … --buyback <pct> --lp <pct> --split …` together). The address is
///         `predict(dev, salt)`, known before the clone. Every clone runs the one implementation this factory
///         deployed, over its pad: that is what the Safe checked before allowing the factory on GangHandlerAdmin.
/// @dev No owner, not upgradeable. A new version of the module is a new factory.
contract GangComboSplitterFactory {
    string public constant LABEL = "combo-v1";

    address public immutable pad;
    address public immutable admin;
    /// @notice The GangComboSplitter every clone runs.
    address public immutable implementation;

    address[] internal _all;

    event Created(
        address indexed dev, address indexed module, uint16 buybackBps, uint16 lpBps, address[] payees, uint16[] shares
    );

    error ZeroAddress();
    error WrongHandler();
    error NotAgent();

    /// @param gangQuote_ The platform's GANG, a quote the keeper serves (GangComboSplitter.gangQuote; 0: none).
    constructor(address pad_, address admin_, address gangQuote_) {
        if (pad_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (IComboModuleLister(admin_).handler() != IGangPad(pad_).taxHandler()) revert WrongHandler();
        pad = pad_;
        admin = admin_;
        implementation = address(new GangComboSplitter(pad_, gangQuote_));
    }

    /// @notice Clone a combined splitter for the caller (ratios and payees fixed for good), listed as a tax recipient,
    ///         at `predict(caller, salt)` (a salt the caller used before reverts: that address is taken).
    function create(uint16 buybackBps, uint16 lpBps, address[] calldata payees, uint16[] calldata shares, bytes32 salt)
        external
        returns (address module)
    {
        if (!IGangPad(pad).isAgent(msg.sender)) revert NotAgent();
        module = Clones.cloneDeterministic(implementation, _saltOf(msg.sender, salt));
        GangComboSplitter(module).initialize(msg.sender, buybackBps, lpBps, payees, shares);
        IComboModuleLister(admin).listModule(module, LABEL);
        _all.push(module);
        emit Created(msg.sender, module, buybackBps, lpBps, payees, shares);
    }

    /// @notice Where `create(…, salt)` from `dev` puts the module.
    function predict(address dev, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _saltOf(dev, salt));
    }

    function modules() external view returns (address[] memory) {
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
