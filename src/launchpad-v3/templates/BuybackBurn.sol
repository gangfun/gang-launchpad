// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPairFactoryV2} from "../../launchpad-v2/interfaces/IMigratorV2.sol";
import {IUniswapV2PairLite} from "../../launchpad-v2/interfaces/IUniswapV2PairLite.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IVaultFactory} from "../interfaces/IVaultFactory.sol";
import {TemplateTypes} from "../interfaces/TemplateTypes.sol";

interface IPairSwap4 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @title BuybackBurnVault (official template · 回购销毁)
/// @notice Accumulates the token side of the tax in quote; the platform keeper buys the token back on its graduated
///         pair and sends it to 0xdead. Quote can only ever leave this vault as a buyback.
/// @dev Keeper-only with a mandatory off-chain `minTokensOut` (V2 H1: a self-chosen floor could be sandwiched).
///      Buyback needs the graduated pair, so bonding-phase tax waits here until graduation.
///      The vault is tax-excluded on its token (LaunchpadV3 create), so pair → vault pays no tax.
contract BuybackBurnVault is IVault {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant DEX_FEE_NUM = 9975;
    uint256 public constant DEX_FEE_DEN = 10000;

    address public immutable token;
    address public immutable quote;
    address public immutable factory;
    address public immutable router;
    IPairFactoryV2 public immutable pairFactory;

    uint256 public totalQuoteSpent;
    uint256 public totalBurned;

    event TaxReceived(uint256 amount, TemplateTypes.Phase phase);
    event BuybackBurned(uint256 quoteIn, uint256 tokensBurned);

    error OnlyRouter();
    error OnlyKeeper();
    error ZeroAmount();
    error NoPair();
    error Slippage();

    constructor(address token_, address quote_, address router_, address pairFactory_) {
        token = token_;
        quote = quote_;
        factory = msg.sender;
        router = router_;
        pairFactory = IPairFactoryV2(pairFactory_);
    }

    function onTaxReceived(uint256 amount, TemplateTypes.Phase phase) external {
        if (msg.sender != router) revert OnlyRouter();
        emit TaxReceived(amount, phase);
    }

    function pendingQuote() external view returns (uint256) {
        return IERC20(quote).balanceOf(address(this));
    }

    /// @param amountIn 0 or more than the balance = spend the whole balance.
    function buyback(uint256 amountIn, uint256 minTokensOut) external returns (uint256 burned) {
        BuybackBurnFactory f = BuybackBurnFactory(factory);
        if (msg.sender != f.keeper() && msg.sender != f.owner()) revert OnlyKeeper();
        if (minTokensOut == 0) revert ZeroAmount();
        address pair = pairFactory.getPair(token, quote);
        if (pair == address(0)) revert NoPair();

        uint256 bal = IERC20(quote).balanceOf(address(this));
        if (amountIn == 0 || amountIn > bal) amountIn = bal;
        if (amountIn == 0) revert ZeroAmount();

        bool tokenIs0 = IUniswapV2PairLite(pair).token0() == token;
        (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = tokenIs0 ? (uint256(r1), uint256(r0)) : (uint256(r0), uint256(r1));
        if (reserveIn == 0 || reserveOut == 0) revert NoPair();

        IERC20(quote).safeTransfer(pair, amountIn);
        // Fee-on-transfer quotes: price what the pair actually received.
        uint256 actualIn = IERC20(quote).balanceOf(pair) - reserveIn;
        uint256 inWithFee = actualIn * DEX_FEE_NUM;
        uint256 out = (inWithFee * reserveOut) / (reserveIn * DEX_FEE_DEN + inWithFee);
        if (out < minTokensOut) revert Slippage();

        uint256 before = IERC20(token).balanceOf(address(this));
        if (tokenIs0) IPairSwap4(pair).swap(out, 0, address(this), "");
        else IPairSwap4(pair).swap(0, out, address(this), "");
        burned = IERC20(token).balanceOf(address(this)) - before;
        IERC20(token).safeTransfer(DEAD, burned);

        totalQuoteSpent += amountIn;
        totalBurned += burned;
        emit BuybackBurned(amountIn, burned);
    }

    function uiSchema() external pure returns (TemplateTypes.Method[] memory methods) {
        methods = new TemplateTypes.Method[](3);
        TemplateTypes.Field[] memory none = new TemplateTypes.Field[](0);

        TemplateTypes.Field[] memory quoteOut = new TemplateTypes.Field[](1);
        quoteOut[0] =
            TemplateTypes.Field("amount", TemplateTypes.FieldKind.Uint, 18, false, "Quote waiting for buyback");
        TemplateTypes.Field[] memory burnedOut = new TemplateTypes.Field[](1);
        burnedOut[0] = TemplateTypes.Field("amount", TemplateTypes.FieldKind.Uint, 18, false, "Tokens burned so far");
        TemplateTypes.Field[] memory buyIn = new TemplateTypes.Field[](2);
        buyIn[0] = TemplateTypes.Field("amountIn", TemplateTypes.FieldKind.Uint, 18, false, "Quote to spend; 0 = all");
        buyIn[1] = TemplateTypes.Field("minTokensOut", TemplateTypes.FieldKind.Uint, 18, false, "Slippage floor");

        methods[0] = TemplateTypes.Method("pendingQuote", "Quote waiting for the next buyback", false, none, quoteOut);
        methods[1] = TemplateTypes.Method("totalBurned", "Tokens bought back and burned", false, none, burnedOut);
        methods[2] = TemplateTypes.Method("buyback", "Platform keeper buys back and burns", true, buyIn, none);
    }
}

/// @title BuybackBurnFactory
/// @notice data = empty. Owner (platform multisig) sets the keeper; neither can move vault quote anywhere but a
///         buyback on the token's own pair.
contract BuybackBurnFactory is IVaultFactory, Ownable2Step {
    address public immutable launchpad;
    address public immutable router;
    address public immutable pairFactory;
    address public keeper;

    event VaultCreated(address indexed token, address indexed vault);
    event KeeperSet(address indexed keeper);

    error OnlyLaunchpad();
    error BadData();

    constructor(address owner_, address launchpad_, address router_, address pairFactory_) Ownable(owner_) {
        launchpad = launchpad_;
        router = router_;
        pairFactory = pairFactory_;
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function createVault(address token, address quote, address, bytes calldata data) external returns (address vault) {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (data.length != 0) revert BadData();
        vault = address(new BuybackBurnVault(token, quote, router, pairFactory));
        emit VaultCreated(token, vault);
    }

    function validate(bytes calldata data) external pure returns (bool ok, string memory reason) {
        if (data.length != 0) return (false, "buyback-burn takes no params; vaultData must be empty");
        return (true, "");
    }

    function metadata() external pure returns (TemplateTypes.Metadata memory) {
        return TemplateTypes.Metadata({
            name: "Buyback & Burn",
            version: "1",
            description: "Token-side tax buys the token back on its pair and burns it to 0xdead.",
            docsURI: ""
        });
    }

    function dataSchema() external pure returns (TemplateTypes.Field[] memory fields) {
        fields = new TemplateTypes.Field[](0);
    }
}
