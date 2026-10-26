// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev launchpad-v2 PlatformFeeBucket as the GangBuybackBurner tests use it. The tests do not import the contract:
///      src/launchpad-v2 is compiled with via-IR (foundry.toml), which would also compile GangBuybackBurner with via-IR
///      inside the test, so the tests would exercise different bytecode from the one the deploy script ships.
interface IPlatformFeeBucket {
    function BPS() external view returns (uint256);
    function BUYBACK_BPS() external view returns (uint256);
    function owner() external view returns (address);
    function launchpad() external view returns (address);
    function keeper() external view returns (address);
    function feeVault() external view returns (address);
    function burner() external view returns (address);
    function accruedQuote(address quote) external view returns (uint256);
    function setLaunchpad(address launchpad_) external;
    function setKeeper(address keeper_) external;
    function setBurner(address burner_) external;
    function notifyAccrual(address quote, uint256 amount) external;
    function collectPlatform(address quote, uint256 minGangOut) external;
}
