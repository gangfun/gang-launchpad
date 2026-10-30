// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FlywheelOracle} from "../../src/flywheel/FlywheelOracle.sol";

interface IHasPairView {
    function pair() external view returns (address);
}

/// @dev FlywheelOracle over one handler, for suites without a pad (the pad itself exposes `prices`).
contract OracleView {
    address public immutable handler;

    constructor(address handler_) {
        handler = handler_;
    }

    function spotPrice(address token) external view returns (uint256) {
        return FlywheelOracle.spotOf(IHasPairView(token).pair(), token);
    }

    function blockStartPrice(address token) external view returns (uint256) {
        return FlywheelOracle.blockStart(handler, token, FlywheelOracle.spotOf(IHasPairView(token).pair(), token));
    }

    function recentHigh(address token) external view returns (uint256) {
        return FlywheelOracle.recentHigh(handler, token);
    }

    /// @dev Over 30 minutes (the V1 window; V2 sales pick 900 or 1,800 s).
    function twap(address token) external view returns (uint256) {
        return twapOver(token, 30 minutes);
    }

    function twapOver(address token, uint32 window) public view returns (uint256) {
        return FlywheelOracle.twap(handler, token, IHasPairView(token).pair(), window);
    }
}
