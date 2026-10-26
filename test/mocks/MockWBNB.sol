// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev WETH9-style wrapper for router tests: deposit / withdraw native BNB, plus an unbacked faucet mint for fixtures
///      (tests vm.deal the contract so withdrawals of minted balance still pay out).
contract MockWBNB is ERC20("Wrapped BNB", "WBNB") {
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        // as real WBNB (WETH9): `transfer`, so the receiver gets a 2300-gas stipend — GangRouter.receive must fit in it
        payable(msg.sender).transfer(amount);
    }

    function mintUnlimited(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
