// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pad3VanityTestnetAcceptance} from "../../script/Pad3VanityTestnetAcceptance.s.sol";

/// @dev Reuse the actual acceptance flow on local fixtures and mainnet forks without its testnet-only entry guard.
contract Pad3VanityAcceptanceHarness is Pad3VanityTestnetAcceptance {
    function accept(address pad, uint256 key, address vault, address legacy) external returns (address[] memory) {
        return _accept(pad, key, vault, legacy);
    }
}
