// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Testnet / forge mock for SPCXB (18 decimals). Faucet mint for tests.
contract MockSPCXB is ERC20 {
    uint256 public constant FAUCET_CAP = 1000 ether;

    mapping(address => uint256) public minted;

    error FaucetCap();

    constructor() ERC20("Mock SpaceX bStock", "MockSPCXB") {}

    function mint(address to, uint256 amount) external {
        if (minted[to] + amount > FAUCET_CAP) revert FaucetCap();
        minted[to] += amount;
        _mint(to, amount);
    }

    /// @dev Uncapped mint for test fixtures / burner setup only.
    function mintUnlimited(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
