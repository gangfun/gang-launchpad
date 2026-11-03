// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {MockWBNB} from "./MockWBNB.sol";

/// @dev review3 PoC: a "next version" whose every top-level variable keeps its slot and whose public getters keep their
///      names, but whose Curve struct swaps two same-type members (realQuote <-> gradAmt, both uint128). The storage
///      is untouched by an upgrade; only the new code's reading of it changes.
contract Pad3CurveSwapMock is Initializable, Ownable2Step, ReentrancyGuard {
    struct Curve {
        address creator;
        address quote;
        uint128 gradAmt; // was realQuote (slot +2, offset 0)
        uint128 sold;
        uint128 realQuote; // was gradAmt (slot +3, offset 0)
        uint128 virtualQuote;
        bool graduated;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 dividendBps;
        address pair;
        address refPair;
    }

    IGangLaunchpad.Config internal _config;
    mapping(address => address) public bridgePoolOf;
    mapping(address router => bool) public routers;
    mapping(address token => uint8) public kindOf;
    mapping(address token => Curve) public curves;
    mapping(address token => IGangLaunchpad.Sale) public sales;
    mapping(address token => mapping(address user => IGangLaunchpad.Position)) public positions;
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

    function pairFactory() external view returns (address) {
        return _config.pairFactory;
    }

    function v3Factory() external view returns (address) {
        return _config.v3Factory;
    }

    function twapWindow() external view returns (uint32) {
        return _config.twapWindow;
    }

    function migrator() external view returns (address) {
        return _config.migrator;
    }

    function agentIdRegistry() external view returns (address) {
        return _config.agentIdRegistry;
    }

    function agentGateEnabled() external view returns (bool) {
        return _config.agentGateEnabled;
    }

    function walletCapEnabled() external view returns (bool) {
        return _config.walletCapEnabled;
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    function status(address token) public view returns (IGangLaunchpad.Status) {
        IGangLaunchpad.Sale storage s = sales[token];
        if (s.creator == address(0)) return IGangLaunchpad.Status.None;
        if (s.launched) return IGangLaunchpad.Status.Launched;
        return IGangLaunchpad.Status.Minting;
    }

    /// @dev same source as GangLaunchpad3.graduationRemaining: now reads the swapped members
    function graduationRemaining(address token) external view returns (uint256) {
        Curve storage c = curves[token];
        if (c.creator == address(0) || c.graduated) return 0;
        if (c.realQuote >= c.gradAmt) return 0;
        return uint256(c.gradAmt) - uint256(c.realQuote);
    }
}

/// @dev MockWBNB plus WETH9's payable fallback (real WBNB: `function() public payable { deposit(); }`).
contract MockWBNBFallback is MockWBNB {
    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
