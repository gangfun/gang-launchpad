// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {GangPromotePoolModule} from "./GangPromotePoolModule.sol";
import {IGangPad} from "./interfaces/IGangPad.sol";
import {IGangPromote} from "./interfaces/IGangPromote.sol";

interface IPromotePoolLister {
    function handler() external view returns (address);
    function listModule(address module, string calldata label) external;
}

/// @title GangPromotePoolModuleFactory — a dev's pool-side promoter share in one call
/// @notice `create(salt)` clones GangPromotePoolModule for the caller (an Agent, as only an Agent can create the token)
///         and has GangHandlerAdmin list it on the tax handler, so the dev can name it as the token's `recipient`.
///         Every clone reads the settler and the vetoer (this contract's owner) from here, so replacing a settler
///         touches no clone.
/// @dev Not upgradeable. A new version of the module is a new factory.
contract GangPromotePoolModuleFactory is Ownable2Step {
    string public constant LABEL = "promote-pool-v1";

    address public immutable pad;
    address public immutable admin;
    /// @notice The GangPromotePoolModule every clone runs.
    address public immutable implementation;

    /// @notice Who posts the roots of every clone.
    address public settler;

    address[] internal _all;

    event Created(address indexed dev, address indexed module);
    event SettlerSet(address indexed settler);

    error ZeroAddress();
    error WrongHandler();
    error NotAgent();

    /// @param gangQuote_ The platform's GANG, a quote the keeper serves (0: none).
    /// @dev `promoteOf` reverts on a pad without the promoter share, so this can't be deployed over one.
    constructor(address pad_, address admin_, address gangQuote_, address owner_, address settler_) Ownable(owner_) {
        if (pad_ == address(0) || admin_ == address(0) || settler_ == address(0)) revert ZeroAddress();
        if (IPromotePoolLister(admin_).handler() != IGangPad(pad_).taxHandler()) revert WrongHandler();
        IGangPromote(pad_).promoteOf(address(0));
        pad = pad_;
        admin = admin_;
        settler = settler_;
        implementation = address(new GangPromotePoolModule(pad_, gangQuote_));
        emit SettlerSet(settler_);
    }

    function setSettler(address settler_) external onlyOwner {
        if (settler_ == address(0)) revert ZeroAddress();
        settler = settler_;
        emit SettlerSet(settler_);
    }

    /// @notice Clone a module for the caller, listed as a tax recipient, at `predict(caller, salt)`.
    function create(bytes32 salt) external returns (address module) {
        if (!IGangPad(pad).isAgent(msg.sender)) revert NotAgent();
        module = Clones.cloneDeterministic(implementation, _saltOf(msg.sender, salt));
        GangPromotePoolModule(module).initialize(msg.sender);
        IPromotePoolLister(admin).listModule(module, LABEL);
        _all.push(module);
        emit Created(msg.sender, module);
    }

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
