// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GangToken} from "./GangToken.sol";
import {GangMintToken} from "../flywheel/GangMintToken.sol";
import {IGangTokenDeployer} from "./interfaces/IGangPadDeps.sol";

interface IPad3VanityContext {
    function vanitySalt() external view returns (bytes32);
}

/// @notice A fixed pad's CREATE2 deployer for every launch kind. Only addresses ending in abcd can be deployed.
///         Both previous deployers remain part of the platform-token filter, including tokens on older pads.
contract Pad3VanityDeployer {
    address public immutable pad;
    address public immutable legacyTokenDeployer;
    address public immutable legacyMintTokenDeployer;
    mapping(address => bool) private _tokens;

    error OnlyLaunchpad();
    error InvalidSuffix();
    error ZeroAddress();

    constructor(address pad_, address legacyTokenDeployer_, address legacyMintTokenDeployer_) {
        if (pad_ == address(0) || legacyTokenDeployer_ == address(0) || legacyMintTokenDeployer_ == address(0)) {
            revert ZeroAddress();
        }
        pad = pad_;
        legacyTokenDeployer = legacyTokenDeployer_;
        legacyMintTokenDeployer = legacyMintTokenDeployer_;
    }

    function isLaunchToken(address token) external view returns (bool) {
        return _tokens[token] || IGangTokenDeployer(legacyTokenDeployer).isLaunchToken(token)
            || IGangTokenDeployer(legacyMintTokenDeployer).isLaunchToken(token);
    }

    function tokenInitCodeHash(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        address handler,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        bool reclaimable
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(GangToken).creationCode,
                abi.encode(name, symbol, uri, pad, handler, buyTaxBps, sellTaxBps, reclaimable)
            )
        );
    }

    function mintInitCodeHash(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        address handler,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint256 startSupply,
        uint256 maxSupply
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(GangMintToken).creationCode,
                abi.encode(name, symbol, uri, pad, handler, buyTaxBps, sellTaxBps, true, startSupply, maxSupply)
            )
        );
    }

    /// @param salt The effective salt: keccak256(abi.encode(creator, userSalt)).
    function predict(bytes32 initCodeHash, bytes32 salt) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function _salt(bytes32 initCodeHash) private view returns (bytes32 salt) {
        if (msg.sender != pad) revert OnlyLaunchpad();
        salt = IPad3VanityContext(pad).vanitySalt();
        if (uint16(uint160(predict(initCodeHash, salt))) != 0xabcd) revert InvalidSuffix();
    }

    function deploy(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        address handler,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        bool reclaimable
    ) external returns (address token) {
        bytes32 salt = _salt(tokenInitCodeHash(name, symbol, uri, handler, buyTaxBps, sellTaxBps, reclaimable));
        token = address(new GangToken{salt: salt}(name, symbol, uri, pad, handler, buyTaxBps, sellTaxBps, reclaimable));
        _tokens[token] = true;
    }

    function deploy(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        address handler,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint256 startSupply,
        uint256 maxSupply
    ) external returns (address token) {
        bytes32 salt = _salt(
            mintInitCodeHash(name, symbol, uri, handler, buyTaxBps, sellTaxBps, startSupply, maxSupply)
        );
        token = address(
            new GangMintToken{salt: salt}(
                name, symbol, uri, pad, handler, buyTaxBps, sellTaxBps, true, startSupply, maxSupply
            )
        );
        _tokens[token] = true;
    }
}
