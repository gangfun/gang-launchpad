// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {GangCountdownReward} from "./GangCountdownReward.sol";
import {IGangPad} from "./interfaces/IGangPad.sol";

interface ICountdownVanityPad {
    function vanityDeployer() external view returns (address);
}

interface ICountdownModuleLister {
    function handler() external view returns (address);
    function listModule(address module, string calldata label) external;
}

/// @title GangCountdownRewardFactory — a dev's countdown reward (倒计时奖励) recipient
/// @notice `create(token, quote, config, salt)` clones GangCountdownReward for the caller (the dev: an Agent, as only
///         an Agent can create the token), initializes it with the one token it will ever serve and its fixed settings,
///         and has GangHandlerAdmin list it on the tax handler, so the dev can name it as that token's `recipient`.
///         `token` is the address the token will have (the pad's CREATE2 deployer gives it before the token exists:
///         `create` reverts on a pad without one, and for an address that does not end in abcd or already has code);
///         the module's own address is `predict(dev, salt)`. As GangFloorModuleFactory.
/// @dev No owner, not upgradeable. A new version of the module is a new factory.
contract GangCountdownRewardFactory {
    string public constant LABEL = "countdown-v1";

    address public immutable pad;
    address public immutable admin;
    address public immutable implementation;

    address[] internal _all;

    event Created(
        address indexed dev,
        address indexed module,
        address indexed token,
        address quote,
        GangCountdownReward.Config config
    );

    error ZeroAddress();
    error WrongHandler();
    error NotAgent();
    error NoVanityDeployer();
    error BadToken();

    constructor(address pad_, address admin_, address gangQuote_) {
        if (pad_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (ICountdownModuleLister(admin_).handler() != IGangPad(pad_).taxHandler()) revert WrongHandler();
        pad = pad_;
        admin = admin_;
        implementation = address(new GangCountdownReward(pad_, gangQuote_));
    }

    /// @notice Clone a countdown reward module for the caller, listed as a tax recipient, at `predict(caller, salt)`.
    function create(address token, address quote, GangCountdownReward.Config calldata config, bytes32 salt)
        external
        returns (address module)
    {
        if (!IGangPad(pad).isAgent(msg.sender)) revert NotAgent();
        // only the pad's CREATE2 (abcd) deployer gives an address the dev alone can create a token at (floor M-1)
        if (!vanityEnabled()) revert NoVanityDeployer();
        if (uint16(uint160(token)) != 0xabcd || token.code.length != 0) revert BadToken();
        module = Clones.cloneDeterministic(implementation, _saltOf(msg.sender, salt));
        GangCountdownReward(module).initialize(msg.sender, token, quote, config);
        ICountdownModuleLister(admin).listModule(module, LABEL);
        _all.push(module);
        emit Created(msg.sender, module, token, quote, config);
    }

    function vanityEnabled() public view returns (bool) {
        try ICountdownVanityPad(pad).vanityDeployer() returns (address d) {
            return d != address(0);
        } catch {
            return false;
        }
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

    function _saltOf(address dev, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(dev, salt));
    }
}
