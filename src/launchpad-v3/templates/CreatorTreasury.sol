// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IVaultFactory} from "../interfaces/IVaultFactory.sol";
import {TemplateTypes} from "../interfaces/TemplateTypes.sol";

/// @title CreatorTreasuryVault (official template · Agent 自养)
/// @notice Holds the token side of the tax for the creator Agent (compute, API bills…). Only the beneficiary
///         withdraws, capped per 24h window when `dailyCap` > 0 — holders can see the Agent cannot drain it at once.
contract CreatorTreasuryVault is IVault {
    using SafeERC20 for IERC20;

    uint256 public constant WINDOW = 1 days;

    address public immutable token;
    address public immutable quote;
    address public immutable factory;
    address public immutable router;
    /// @dev 0 = no cap. In quote units.
    uint256 public immutable dailyCap;

    address public beneficiary;
    uint256 public windowStart;
    uint256 public withdrawnInWindow;

    event TaxReceived(uint256 amount, TemplateTypes.Phase phase);
    event Withdrawn(address indexed to, uint256 amount);
    event BeneficiaryUpdated(address indexed beneficiary);

    error OnlyBeneficiary();
    error OnlyRouter();
    error ZeroAddress();
    error OverDailyCap();

    constructor(address token_, address quote_, address router_, address beneficiary_, uint256 dailyCap_) {
        token = token_;
        quote = quote_;
        factory = msg.sender;
        router = router_;
        beneficiary = beneficiary_;
        dailyCap = dailyCap_;
    }

    function onTaxReceived(uint256 amount, TemplateTypes.Phase phase) external {
        if (msg.sender != router) revert OnlyRouter();
        emit TaxReceived(amount, phase);
    }

    function available() public view returns (uint256) {
        uint256 bal = IERC20(quote).balanceOf(address(this));
        if (dailyCap == 0) return bal;
        uint256 used = block.timestamp >= windowStart + WINDOW ? 0 : withdrawnInWindow;
        uint256 room = dailyCap - used;
        return room < bal ? room : bal;
    }

    function withdraw(uint256 amount, address to) external {
        if (msg.sender != beneficiary) revert OnlyBeneficiary();
        if (to == address(0)) revert ZeroAddress();
        if (amount > available()) revert OverDailyCap();
        if (dailyCap > 0) {
            if (block.timestamp >= windowStart + WINDOW) {
                windowStart = block.timestamp;
                withdrawnInWindow = 0;
            }
            withdrawnInWindow += amount;
        }
        IERC20(quote).safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    /// @notice The Agent may rotate wallets; it cannot hand the vault to the platform or anyone it does not choose.
    function setBeneficiary(address beneficiary_) external {
        if (msg.sender != beneficiary) revert OnlyBeneficiary();
        if (beneficiary_ == address(0)) revert ZeroAddress();
        beneficiary = beneficiary_;
        emit BeneficiaryUpdated(beneficiary_);
    }

    function uiSchema() external pure returns (TemplateTypes.Method[] memory methods) {
        methods = new TemplateTypes.Method[](4);

        TemplateTypes.Field[] memory none = new TemplateTypes.Field[](0);
        TemplateTypes.Field[] memory amountOut = new TemplateTypes.Field[](1);
        amountOut[0] = TemplateTypes.Field("amount", TemplateTypes.FieldKind.Uint, 18, false, "Quote amount");
        TemplateTypes.Field[] memory addrOut = new TemplateTypes.Field[](1);
        addrOut[0] =
            TemplateTypes.Field("beneficiary", TemplateTypes.FieldKind.Address, 0, false, "Creator Agent wallet");

        TemplateTypes.Field[] memory withdrawIn = new TemplateTypes.Field[](2);
        withdrawIn[0] = TemplateTypes.Field("amount", TemplateTypes.FieldKind.Uint, 18, false, "Quote amount");
        withdrawIn[1] = TemplateTypes.Field("to", TemplateTypes.FieldKind.Address, 0, false, "Recipient");
        TemplateTypes.Field[] memory setIn = new TemplateTypes.Field[](1);
        setIn[0] = TemplateTypes.Field("beneficiary", TemplateTypes.FieldKind.Address, 0, false, "New wallet");

        methods[0] =
            TemplateTypes.Method("available", "Withdrawable now (balance, capped by dailyCap)", false, none, amountOut);
        methods[1] = TemplateTypes.Method("beneficiary", "Who can withdraw", false, none, addrOut);
        methods[2] = TemplateTypes.Method("withdraw", "Beneficiary withdraws quote", true, withdrawIn, none);
        methods[3] = TemplateTypes.Method("setBeneficiary", "Beneficiary rotates wallet", true, setIn, none);
    }
}

/// @title CreatorTreasuryFactory
/// @notice data = abi.encode(address beneficiary, uint256 dailyCap). beneficiary 0 → creator.
contract CreatorTreasuryFactory is IVaultFactory {
    address public immutable launchpad;
    address public immutable router;

    event VaultCreated(address indexed token, address indexed vault, address beneficiary, uint256 dailyCap);

    error OnlyLaunchpad();
    error BadData();

    constructor(address launchpad_, address router_) {
        launchpad = launchpad_;
        router = router_;
    }

    function createVault(address token, address quote, address creator, bytes calldata data)
        external
        returns (address vault)
    {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (data.length != 64) revert BadData();
        (address beneficiary, uint256 dailyCap) = abi.decode(data, (address, uint256));
        if (beneficiary == address(0)) beneficiary = creator;
        vault = address(new CreatorTreasuryVault(token, quote, router, beneficiary, dailyCap));
        emit VaultCreated(token, vault, beneficiary, dailyCap);
    }

    function validate(bytes calldata data) external pure returns (bool ok, string memory reason) {
        if (data.length != 64) return (false, "data must be abi.encode(address beneficiary, uint256 dailyCap)");
        return (true, "");
    }

    function metadata() external pure returns (TemplateTypes.Metadata memory) {
        return TemplateTypes.Metadata({
            name: "Creator Treasury",
            version: "1",
            description: "Token-side tax goes to a treasury the creator Agent withdraws from, optionally capped per day.",
            docsURI: ""
        });
    }

    function dataSchema() external pure returns (TemplateTypes.Field[] memory fields) {
        fields = new TemplateTypes.Field[](2);
        fields[0] = TemplateTypes.Field(
            "beneficiary", TemplateTypes.FieldKind.Address, 0, false, "Who can withdraw; zero address = creator"
        );
        fields[1] = TemplateTypes.Field(
            "dailyCap", TemplateTypes.FieldKind.Uint, 18, false, "Max quote withdrawn per 24h; 0 = no cap"
        );
    }
}
