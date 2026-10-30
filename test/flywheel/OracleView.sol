// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FlywheelOracle, IHasPairView} from "../../src/flywheel/FlywheelOracle.sol";

/// @dev FlywheelOracle over one handler, for suites without a pad (the pad itself exposes `prices`).
contract OracleView {
    address public immutable handler;

    constructor(address handler_) {
        handler = handler_;
    }

    function spotPrice(address token) external view returns (uint256) {
        return FlywheelOracle.spotOf(IHasPairView(token).pair(), token);
    }

    function blockStartPrice(address token) external view returns (uint256 b) {
        (, b,,) = FlywheelOracle.prices(handler, token);
    }

    function recentHigh(address token) external view returns (uint256) {
        return FlywheelOracle.recentHigh(handler, token);
    }

    function twap(address token) external view returns (uint256) {
        return FlywheelOracle.twap(handler, token, IHasPairView(token).pair());
    }
}
