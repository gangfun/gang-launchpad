// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// The one place the deploy script and its tests get the concrete GangLaunchpad / GangTaxHandler from.
// INTEGRATION: replace the stub import below with
//   import {GangLaunchpad} from "../src/gang/GangLaunchpad.sol";
// and delete script/stubs/GangStubs.sol.
import {GangLaunchpad} from "./stubs/GangStubs.sol";
import {GangTaxHandler} from "../src/gang/GangTaxHandler.sol";
