// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {GangFloorModule} from "./GangFloorModule.sol";
import {IGangPad} from "./interfaces/IGangPad.sol";

interface IFloorVanityPad {
    function vanityDeployer() external view returns (address);
}

interface IFloorModuleLister {
    function handler() external view returns (address);
    function listModule(address module, string calldata label) external;
}

/// @title GangFloorModuleFactory — a dev's floor recipient (the tax kept as a treasury its holders can redeem)
/// @notice `create(token, floorQuote, capAmount, payBps, redeemFeeBps, payees, shares, salt)` clones GangFloorModule
///         for the caller (the dev: an Agent, as only an Agent can create the token), initializes it with the one
///         token it will ever serve, its fixed cap, ratios, fee and payee list, and has GangHandlerAdmin list it on
///         the tax handler, so the dev can name it as that token's `recipient` right away. `token` is the address the
///         token will have (the pad's CREATE2 deployer gives it before the token exists: `create` reverts on a pad
///         without one, and for an address that does not end in abcd or already has code); the module's own address is
///         `predict(dev, salt)`, known before the clone. Every clone runs the one implementation this factory
///         deployed, over its pad: that is what the Safe checked before allowing the factory on GangHandlerAdmin.
/// @dev No owner, not upgradeable. A new version of the module is a new factory. As GangCappedSplitterFactory.
contract GangFloorModuleFactory {
    string public constant LABEL = "floor-v1";

    address public immutable pad;
    address public immutable admin;
    /// @notice The GangFloorModule every clone runs.
    address public immutable implementation;

    address[] internal _all;

    event Created(
        address indexed dev,
        address indexed module,
        address indexed token,
        address floorQuote,
        uint256 capAmount,
        uint16 payBps,
        uint16 redeemFeeBps,
        address[] payees,
        uint16[] shares
    );

    error ZeroAddress();
    error WrongHandler();
    error NotAgent();
    error NoVanityDeployer();
    error BadToken();

    /// @param gangQuote_ The platform's GANG, a quote the keeper serves (GangFloorModule.gangQuote; 0: none).
    constructor(address pad_, address admin_, address gangQuote_) {
        if (pad_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (IFloorModuleLister(admin_).handler() != IGangPad(pad_).taxHandler()) revert WrongHandler();
        pad = pad_;
        admin = admin_;
        implementation = address(new GangFloorModule(pad_, gangQuote_));
    }

    /// @notice Clone a floor module for the caller (token, cap, ratios, fee and payees fixed for good), listed as a tax
    ///         recipient, at `predict(caller, salt)` (a salt the caller used before reverts: that address is taken).
    function create(
        address token,
        address floorQuote,
        uint256 capAmount,
        uint16 payBps,
        uint16 redeemFeeBps,
        address[] calldata payees,
        uint16[] calldata shares,
        bytes32 salt
    ) external returns (address module) {
        if (!IGangPad(pad).isAgent(msg.sender)) revert NotAgent();
        // The token's address must be one the dev alone can create a token at: the pad's CREATE2 (abcd) deployer's.
        // On a pad that deploys by nonce anyone could take the address first, and the dev's token, created with this
        // module as its recipient, would pay its tax into a module that can never bind (audit 2026-11-11 M-1).
        if (!vanityEnabled()) revert NoVanityDeployer();
        // such an address ends in abcd; a token already there was created before this module was listed, so this
        // module can't be its recipient
        if (uint16(uint160(token)) != 0xabcd || token.code.length != 0) revert BadToken();
        module = Clones.cloneDeterministic(implementation, _saltOf(msg.sender, salt));
        GangFloorModule(module)
            .initialize(msg.sender, token, floorQuote, capAmount, payBps, redeemFeeBps, payees, shares);
        IFloorModuleLister(admin).listModule(module, LABEL);
        _all.push(module);
        emit Created(msg.sender, module, token, floorQuote, capAmount, payBps, redeemFeeBps, payees, shares);
    }

    /// @notice Whether the pad creates its tokens through its CREATE2 (abcd) deployer (false on a pad without one).
    function vanityEnabled() public view returns (bool) {
        try IFloorVanityPad(pad).vanityDeployer() returns (address d) {
            return d != address(0);
        } catch {
            return false;
        }
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
