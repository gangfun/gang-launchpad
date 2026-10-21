// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPancakeRouter02} from "../../src/interfaces/IPancake.sol";

/// @dev Minimal router mock: 1 wei BNB → `rate` token units (capped by balance).
contract MockPancakeRouter is IPancakeRouter02 {
    address public immutable override WETH;
    uint256 public rate = 1000 ether; // tokens per 1 wei BNB (tests fund small amounts)
    bool public revertSwap;
    bool public revertQuote;

    constructor(address weth_) {
        WETH = weth_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setRevertSwap(bool v) external {
        revertSwap = v;
    }

    function setRevertQuote(bool v) external {
        revertQuote = v;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        override
        returns (uint256[] memory amounts)
    {
        require(path.length == 2, "path");
        if (revertQuote) revert("quote");
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * rate;
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external payable override {
        require(!revertSwap, "swap");
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
