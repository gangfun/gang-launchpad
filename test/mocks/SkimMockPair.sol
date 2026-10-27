// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";

/// @dev launchpad-v2's MockPair (same storage layout, so it can be etched over a live one) plus Pancake's `skim`.
contract SkimMockPair is MockPair {
    constructor() MockPair(address(1), address(2)) {}

    function skim(address to) external {
        IERC20(token0).transfer(to, IERC20(token0).balanceOf(address(this)) - reserve0);
        IERC20(token1).transfer(to, IERC20(token1).balanceOf(address(this)) - reserve1);
    }
}
