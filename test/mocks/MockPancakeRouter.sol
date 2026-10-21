// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPancakeRouter02} from "../../src/interfaces/IPancake.sol";

/// @dev Minimal router mock: 1 wei BNB → up to `rate` token units (capped by balance).
contract MockPancakeRouter is IPancakeRouter02 {
    address public immutable override WETH;
    uint256 public rate = 1000 ether; // tokens per 1 wei BNB (tests fund small amounts)

    constructor(address weth_) {
        WETH = weth_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external payable override {
        require(path.length == 2, "path");
        require(path[0] == WETH, "wbnb");
        uint256 out = msg.value * rate;
        uint256 bal = IERC20(path[1]).balanceOf(address(this));
        if (out > bal) out = bal;
        require(out >= amountOutMin, "slippage");
        require(IERC20(path[1]).transfer(to, out), "xfer");
    }

    receive() external payable {}
}
