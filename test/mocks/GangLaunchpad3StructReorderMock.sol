// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev AUDIT 3-C PoC (test only). A "next version" of GangLaunchpad 3.0 that keeps every top-level variable with the
///      same name, slot and type label prefix, but REORDERS the members of the structs it stores (as an edit of
///      IGangLaunchpad.Curve / Config would): `quote` before `creator` in Curve, `migrator` swapped with `pairFactory`
///      in Config. Every existing token's curve record and the pad's settings would be read garbled after an upgrade.
contract Pad3StructReorderMock is Initializable, Ownable2Step, ReentrancyGuard {
    struct Config {
        address migrator; // was pairFactory (slot +0)
        address v3Factory;
        uint32 twapWindow;
        address pairFactory; // was migrator (slot +2)
        address agentIdRegistry;
        bool agentGateEnabled;
        bool walletCapEnabled;
    }

    struct Curve {
        address quote; // was creator (slot +0)
        address creator; // was quote (slot +1)
        uint128 realQuote;
        uint128 sold;
        uint128 gradAmt;
        uint128 virtualQuote;
        bool graduated;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 dividendBps;
        address pair;
        address refPair;
    }

    struct Sale {
        address creator;
        uint64 progressAt;
        uint16 capShares;
        uint16 holdBps;
        address quote;
        uint16 sold;
        bool launched;
        uint16 mintFeeBps;
        uint16 exitFeeBps;
        address gate;
        uint128 sharePrice;
        address pair;
        address refPool;
        uint16 markSold;
    }

    struct Position {
        uint16 shares;
    }

    Config internal _config;
    mapping(address => address) public bridgePoolOf;
    mapping(address router => bool) public routers;
    mapping(address token => uint8) public kindOf;
    mapping(address token => Curve) internal curves;
    mapping(address token => Sale) internal _sales;
    mapping(address token => mapping(address user => Position)) internal positions;
    mapping(address token => string) public logoURIOf;
    mapping(address quote => uint256) public owedFee;
    address[] public allTokens;
    mapping(address token => uint256) public creatorFeeOf;
    mapping(address token => uint256) public gradTargetOf;
    mapping(address token => uint8) public tokenVersionOf;
    mapping(address caller => bool) public isCaller;

    constructor() Ownable(address(0xdEaD)) {
        _disableInitializers();
    }

    /// @dev What the new code reads as `creator` of a curve record written by 3.0.
    function creatorOf(address token) external view returns (address) {
        return curves[token].creator;
    }

    function migratorSetting() external view returns (address) {
        return _config.migrator;
    }
}
