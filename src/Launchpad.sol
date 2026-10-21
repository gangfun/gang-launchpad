// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {IMigrator} from "./interfaces/IMigrator.sol";
import {IPancakeRouter02} from "./interfaces/IPancake.sol";

/// @title Gang Launchpad
/// @notice Agent-only bonding curve on BNB Chain. Buys require holding a SPACE ID Agent ID (.ai), the soulbound
///         NFT only a Binance Agentic Wallet can claim; sells are open. Each wallet may hold at most 1% of supply
///         from the curve. 1% fee on both sides accrues on-contract: 80% auto buyback-and-burns the official
///         platform token (GANG), 20% goes to the ops treasury (`feeVault`). At 20 BNB raised the remaining supply
///         and all BNB migrate to PancakeSwap V2 with LP burned, and the platform exits.
///
///         Trust model: the owner cannot touch curve BNB. The migrator is set once and never changed. The agent
///         registry can only be changed through a 24h timelock that is announced on-chain. Protocol buybacks are
///         fee-free, Agent-free, and wallet-cap-free so the treasury path cannot deadlock.
contract Launchpad is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ---------------------------------------------------------------- constants
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant GRADUATION_BNB = 20 ether;
    /// @dev 20/3 BNB, rounded up to the wei.
    uint256 public constant VIRTUAL_BNB = 6_666_666_666_666_666_667;
    /// @dev 16e9/15 tokens, rounded up to the smallest unit.
    uint256 public constant VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667;
    uint256 public constant K = VIRTUAL_BNB * VIRTUAL_TOKEN;
    /// @dev Per-wallet cap on curve holdings: 1% of total supply. Excess BNB is refunded.
    uint256 public constant MAX_PER_WALLET = 10_000_000 ether;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant BPS = 10_000;
    /// @dev Share of accruedFees used for platform-token buyback+burn; remainder goes to feeVault (opsTreasury).
    uint256 public constant BUYBACK_BPS = 8000;
    uint256 public constant REGISTRY_TIMELOCK = 24 hours;

    // ---------------------------------------------------------------- storage
    struct Curve {
        address creator;
        uint128 realBnb; // BNB held for this token (excludes fees)
        uint128 sold; // tokens sold out of CURVE_SUPPLY (includes protocol buybacks)
        bool graduated;
        address pair;
    }

    mapping(address token => Curve) public curves;
    address[] public allTokens;

    /// @notice Ops treasury: receives 20% of collected curve fees and 100% of swept excess. (v4: ex-100% fee sink.)
    address public feeVault;
    IMigrator public migrator;
    /// @notice SPACE ID "Agent ID" soulbound ERC-721 (.ai names), mintable only from a Binance Agentic Wallet.
    IERC721 public agentIdRegistry;
    address public pendingRegistry;
    uint256 public pendingRegistryAt;

    uint256 public accruedFees;
    /// @notice Sum of realBnb over all live curves. Lets `sweepExcess` recover force-fed BNB without touching user funds.
    uint256 public totalRealBnb;
    /// @notice BNB owed to accounts whose refund/payout transfer failed (contract wallets without receive()).
    mapping(address => uint256) public pendingWithdrawals;
    uint256 public totalPending;

    /// @notice Official platform token (GANG). Set once via `seedPlatformToken`.
    address public platformToken;
    /// @notice BNB reserved for buyback while platformToken/router is not ready, or swap could not run.
    uint256 public pendingBuyback;
    /// @notice Pancake V2 router for post-graduation buybacks. Set once.
    IPancakeRouter02 public pancakeRouter;
    /// @notice Max slippage for post-graduation DEX buybacks, in BPS (default 300 = 3%).
    /// @dev Only affects `_swapBurnOrPend` minOut. Requires a new Launchpad deploy to take effect on mainnet.
    uint256 public maxSlippageBps = 300;

    // ---------------------------------------------------------------- events
    event Created(address indexed token, address indexed creator, string name, string symbol);
    event Buy(
        address indexed token, address indexed buyer, uint256 bnbIn, uint256 fee, uint256 tokensOut, uint256 realBnb
    );
    event Sell(
        address indexed token, address indexed seller, uint256 tokensIn, uint256 fee, uint256 bnbOut, uint256 realBnb
    );
    event Graduated(address indexed token, address indexed pair, uint256 tokenAmount, uint256 bnbAmount);
    event PaymentDeferred(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event FeesCollected(address indexed vault, uint256 amount);
    event ExcessSwept(address indexed vault, uint256 amount);
    event FeeVaultUpdated(address indexed vault);
    event MigratorSet(address indexed migrator);
    event RegistryChangeProposed(address indexed registry, uint256 effectiveAt);
    event RegistryChangeCancelled(address indexed registry);
    event AgentIdRegistryUpdated(address indexed registry);
    event PlatformTokenSeeded(address indexed token, string name, string symbol);
    event BuybackBurned(address indexed token, uint256 bnbIn, uint256 tokensBurned);
    event BuybackPending(uint256 amount);
    event BuybackFlushed(uint256 amount);
    event PancakeRouterSet(address indexed router);
    event MaxSlippageBpsUpdated(uint256 bps);

    // ---------------------------------------------------------------- errors
    error UnknownToken();
    error AlreadyGraduated();
    error ZeroAmount();
    error Slippage();
    error PayoutFailed();
    error MigratorNotSet();
    error MigratorAlreadySet();
    error ZeroAddress();
    error NotAgent();
    error WalletCapReached();
    error NothingPending();
    error TimelockActive();
    error PlatformTokenAlreadySet();
    error PlatformTokenNotSet();
    error RouterAlreadySet();
    error SlippageBpsTooHigh();

    constructor(address owner_, address feeVault_, address agentIdRegistry_) Ownable(owner_) {
        if (feeVault_ == address(0) || agentIdRegistry_ == address(0)) revert ZeroAddress();
        feeVault = feeVault_;
        agentIdRegistry = IERC721(agentIdRegistry_);
        emit FeeVaultUpdated(feeVault_);
        emit AgentIdRegistryUpdated(agentIdRegistry_);
    }

    // ---------------------------------------------------------------- create
    /// @notice Deploys a new LaunchToken and opens its bonding curve. No creation fee.
    function create(string calldata name, string calldata symbol) external returns (address token) {
        if (address(migrator) == address(0)) revert MigratorNotSet();
        token = address(new LaunchToken(name, symbol));
        curves[token] = Curve({creator: msg.sender, realBnb: 0, sold: 0, graduated: false, pair: address(0)});
        allTokens.push(token);
        emit Created(token, msg.sender, name, symbol);
    }

    /// @notice One-shot official platform token (GANG). Creates the curve and binds `platformToken` atomically.
    function seedPlatformToken(string calldata name, string calldata symbol)
        external
        onlyOwner
        returns (address token)
    {
        if (platformToken != address(0)) revert PlatformTokenAlreadySet();
        if (address(migrator) == address(0)) revert MigratorNotSet();
        token = address(new LaunchToken(name, symbol));
        curves[token] = Curve({creator: msg.sender, realBnb: 0, sold: 0, graduated: false, pair: address(0)});
        allTokens.push(token);
        platformToken = token;
        emit Created(token, msg.sender, name, symbol);
        emit PlatformTokenSeeded(token, name, symbol);
    }

    // ---------------------------------------------------------------- buy
    /// @notice Buy on the curve. Caller must hold an Agent ID. Each wallet may hold at most MAX_PER_WALLET (1% of
    ///         supply) from the curve. BNB beyond the wallet cap or past graduation is refunded; the buy that reaches
    ///         20 BNB triggers migration in the same tx (that buyer pays the migration gas).
    function buy(address token, uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensOut) {
        Curve storage c = _live(token);
        if (msg.value == 0) revert ZeroAmount();
        if (!isAgent(msg.sender)) revert NotAgent();

        uint256 room = walletRoom(token, msg.sender);
        if (room == 0) revert WalletCapReached();

        uint256 fee;
        uint256 bnbIn;
        uint256 refund;
        (tokensOut, bnbIn, fee, refund) = _quote(c, msg.value, room);
        if (tokensOut < minTokensOut) revert Slippage();

        c.realBnb += bnbIn.toUint128();
        c.sold += tokensOut.toUint128();
        totalRealBnb += bnbIn;
        accruedFees += fee;

        IERC20(token).safeTransfer(msg.sender, tokensOut);
        emit Buy(token, msg.sender, bnbIn, fee, tokensOut, c.realBnb);

        if (c.realBnb == GRADUATION_BNB) _graduate(token, c);
        if (refund > 0) _pay(msg.sender, refund);
    }

    // ---------------------------------------------------------------- sell
    /// @notice Sell on the curve. No gate.
    function sell(address token, uint256 tokensIn, uint256 minBnbOut)
        external
        nonReentrant
        returns (uint256 bnbToUser)
    {
        Curve storage c = _live(token);
        if (tokensIn == 0) revert ZeroAmount();

        uint256 bnbOut = _bnbOut(c, tokensIn);
        uint256 fee = (bnbOut * FEE_BPS) / BPS;
        bnbToUser = bnbOut - fee;
        if (bnbToUser < minBnbOut) revert Slippage();

        c.realBnb -= bnbOut.toUint128();
        c.sold -= tokensIn.toUint128();
        totalRealBnb -= bnbOut;
        accruedFees += fee;

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        emit Sell(token, msg.sender, tokensIn, fee, bnbToUser, c.realBnb);
        _pay(msg.sender, bnbToUser);
    }

    /// @notice Withdraw BNB that could not be pushed to you (refund or sale proceeds).
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingPending();
        pendingWithdrawals[msg.sender] = 0;
        totalPending -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert PayoutFailed();
        emit Withdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------- graduation
    function _graduate(address token, Curve storage c) internal {
        c.graduated = true;
        uint256 tokenAmount = TOTAL_SUPPLY - c.sold; // exactly what the Launchpad holds: nothing else can enter
        uint256 bnbAmount = c.realBnb;
        c.realBnb = 0;
        totalRealBnb -= bnbAmount;

        LaunchToken(token).unlock();
        IERC20(token).safeTransfer(address(migrator), tokenAmount);
        address pair = migrator.migrate{value: bnbAmount}(token, tokenAmount);
        c.pair = pair;
        emit Graduated(token, pair, tokenAmount, bnbAmount);
    }

    // ---------------------------------------------------------------- quotes
    /// @notice Quote a buy for `buyer` sending `bnbGross` wei. Accounts for fee, graduation cap and wallet cap.
    function quoteBuy(address token, address buyer, uint256 bnbGross)
        external
        view
        returns (uint256 tokensOut, uint256 bnbIn, uint256 fee, uint256 refund)
    {
        Curve storage c = _live(token);
        uint256 room = walletRoom(token, buyer);
        if (room == 0) return (0, 0, 0, bnbGross);
        return _quote(c, bnbGross, room);
    }

    function quoteSell(address token, uint256 tokensIn) external view returns (uint256 bnbToUser, uint256 fee) {
        Curve storage c = _live(token);
        uint256 bnbOut = _bnbOut(c, tokensIn);
        fee = (bnbOut * FEE_BPS) / BPS;
        bnbToUser = bnbOut - fee;
    }

    /// @notice Spot price in wei per whole token (1e18 units). Reverts for unknown or graduated tokens.
    function spotPrice(address token) external view returns (uint256) {
        Curve storage c = _live(token);
        return ((VIRTUAL_BNB + c.realBnb) * 1 ether) / (VIRTUAL_TOKEN - c.sold);
    }

    /// @notice How many more tokens `buyer` may still buy from the curve (wallet cap minus current balance).
    function walletRoom(address token, address buyer) public view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(buyer);
        return bal >= MAX_PER_WALLET ? 0 : MAX_PER_WALLET - bal;
    }

    /// @notice True if `account` holds an Agent ID NFT (on-chain proof of a Binance Agentic Wallet).
    function isAgent(address account) public view returns (bool) {
        return agentIdRegistry.balanceOf(account) > 0;
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    /// @dev Applies, in order: 1% fee, graduation cap on BNB, wallet cap on tokens. When a cap binds, the
    ///      BNB actually spent shrinks, the fee is recomputed on it, and the rest is refunded.
    function _quote(Curve storage c, uint256 bnbGross, uint256 room)
        internal
        view
        returns (uint256 tokensOut, uint256 bnbIn, uint256 fee, uint256 refund)
    {
        fee = (bnbGross * FEE_BPS) / BPS;
        bnbIn = bnbGross - fee;
        bool capped = false;

        uint256 remaining = GRADUATION_BNB - c.realBnb;
        if (bnbIn > remaining) {
            bnbIn = remaining;
            capped = true;
        }

        tokensOut = _tokensOut(c, bnbIn);
        if (tokensOut > room) {
            tokensOut = room;
            bnbIn = _bnbInFor(c, room);
            capped = true;
        }

        if (capped) {
            fee = Math.min(Math.ceilDiv(bnbIn * FEE_BPS, BPS - FEE_BPS), bnbGross - bnbIn);
            refund = bnbGross - bnbIn - fee;
        }
    }

    /// @dev BNB needed to take exactly `tokensOut` from the curve (rounded up in the protocol's favour).
    function _bnbInFor(Curve storage c, uint256 tokensOut) internal view returns (uint256) {
        uint256 bnbReserve = VIRTUAL_BNB + c.realBnb;
        uint256 tokenReserve = VIRTUAL_TOKEN - c.sold;
        return Math.ceilDiv(K, tokenReserve - tokensOut) - bnbReserve;
    }

    function _tokensOut(Curve storage c, uint256 bnbIn) internal view returns (uint256) {
        uint256 bnbReserve = VIRTUAL_BNB + c.realBnb;
        uint256 tokenReserve = VIRTUAL_TOKEN - c.sold;
        uint256 newTokenReserve = Math.ceilDiv(K, bnbReserve + bnbIn);
        return tokenReserve - newTokenReserve;
    }

    function _bnbOut(Curve storage c, uint256 tokensIn) internal view returns (uint256) {
        uint256 bnbReserve = VIRTUAL_BNB + c.realBnb;
        uint256 tokenReserve = VIRTUAL_TOKEN - c.sold;
        uint256 newBnbReserve = Math.ceilDiv(K, tokenReserve + tokensIn);
        return bnbReserve - newBnbReserve;
    }

    function _live(address token) internal view returns (Curve storage c) {
        c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        if (c.graduated) revert AlreadyGraduated();
    }

    /// @dev Push BNB; if the recipient cannot receive it, park it for `withdraw()` instead of reverting.
    function _pay(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount, gas: 30_000}("");
        if (!ok) {
            pendingWithdrawals[to] += amount;
            totalPending += amount;
            emit PaymentDeferred(to, amount);
        }
    }

    // ---------------------------------------------------------------- fees / buyback
    /// @notice Anyone can settle accrued fees: 20% → feeVault (ops), 80% → buyback+burn platform token.
    function collectFees() external nonReentrant {
        uint256 amount = accruedFees;
        accruedFees = 0;
        uint256 buyback = (amount * BUYBACK_BPS) / BPS;
        uint256 ops = amount - buyback;

        if (ops > 0) {
            (bool ok,) = feeVault.call{value: ops}("");
            if (!ok) revert PayoutFailed();
        }
        emit FeesCollected(feeVault, ops);

        if (buyback > 0) _buybackAndBurn(buyback);
    }

    /// @notice Permissionless: spend `pendingBuyback` once `platformToken` is set (and router if graduated).
    function flushBuyback() external nonReentrant {
        uint256 amount = pendingBuyback;
        if (amount == 0) revert NothingPending();
        if (platformToken == address(0)) revert PlatformTokenNotSet();
        pendingBuyback = 0;
        emit BuybackFlushed(amount);
        _buybackAndBurn(amount);
    }

    /// @dev Protocol buyback: no Agent gate, no wallet cap, no fee accrual. Burns tokens to address(0).
    function _buybackAndBurn(uint256 bnb) internal {
        address token = platformToken;
        if (token == address(0)) {
            pendingBuyback += bnb;
            emit BuybackPending(bnb);
            return;
        }

        Curve storage c = curves[token];
        if (!c.graduated) {
            uint256 remaining = GRADUATION_BNB - c.realBnb;
            uint256 spend = bnb < remaining ? bnb : remaining;
            if (spend > 0) {
                uint256 tokensOut = _tokensOut(c, spend);
                c.realBnb += spend.toUint128();
                c.sold += tokensOut.toUint128();
                totalRealBnb += spend;
                if (tokensOut > 0) {
                    LaunchToken(token).burn(tokensOut);
                }
                emit BuybackBurned(token, spend, tokensOut);
                if (c.realBnb == GRADUATION_BNB) _graduate(token, c);
            }
            uint256 leftover = bnb - spend;
            if (leftover > 0) _swapBurnOrPend(token, leftover);
        } else {
            _swapBurnOrPend(token, bnb);
        }
    }

    function _swapBurnOrPend(address token, uint256 bnb) internal {
        if (address(pancakeRouter) == address(0)) {
            pendingBuyback += bnb;
            emit BuybackPending(bnb);
            return;
        }

        address wbnb = pancakeRouter.WETH();
        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = token;

        uint256 quoted = _quoteAmountsOut(bnb, path);
        if (quoted == 0) {
            // No route / empty reserves — park rather than swap with minOut=0.
            pendingBuyback += bnb;
            emit BuybackPending(bnb);
            return;
        }
        uint256 amountOutMin = quoted - (quoted * maxSlippageBps) / BPS;

        uint256 before = IERC20(token).balanceOf(address(this));
        try pancakeRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnb}(
            amountOutMin, path, address(this), block.timestamp
        ) {
            uint256 got = IERC20(token).balanceOf(address(this)) - before;
            if (got > 0) {
                LaunchToken(token).burn(got);
            }
            emit BuybackBurned(token, bnb, got);
        } catch {
            // Slippage / sandwich / transient router failure → keep BNB for later flush.
            pendingBuyback += bnb;
            emit BuybackPending(bnb);
        }
    }

    /// @dev Spot quote via router.getAmountsOut; returns 0 if router/path unavailable.
    function _quoteAmountsOut(uint256 amountIn, address[] memory path) internal view returns (uint256) {
        try pancakeRouter.getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            if (amounts.length == 0) return 0;
            return amounts[amounts.length - 1];
        } catch {
            return 0;
        }
    }

    /// @notice Owner sets max DEX buyback slippage (BPS). Cap 5000 (50%) to avoid accidental disable.
    function setMaxSlippageBps(uint256 bps) external onlyOwner {
        if (bps > 5000) revert SlippageBpsTooHigh();
        maxSlippageBps = bps;
        emit MaxSlippageBpsUpdated(bps);
    }

    /// @notice Recover BNB that was force-fed into the contract (e.g. via selfdestruct). Never touches curve BNB,
    ///         fees, deferred payouts, or pending buybacks. Excess goes 100% to ops (feeVault).
    function sweepExcess() external nonReentrant {
        uint256 excess = address(this).balance - totalRealBnb - accruedFees - totalPending - pendingBuyback;
        if (excess == 0) revert ZeroAmount();
        (bool ok,) = feeVault.call{value: excess}("");
        if (!ok) revert PayoutFailed();
        emit ExcessSwept(feeVault, excess);
    }

    function setFeeVault(address vault) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        feeVault = vault;
        emit FeeVaultUpdated(vault);
    }

    /// @notice One-shot Pancake V2 router for post-graduation buybacks.
    function setPancakeRouter(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        if (address(pancakeRouter) != address(0)) revert RouterAlreadySet();
        pancakeRouter = IPancakeRouter02(router);
        emit PancakeRouterSet(router);
    }

    /// @notice One-shot. Once set, the migrator can never be changed, so the owner cannot redirect graduations.
    function setMigrator(address migrator_) external onlyOwner {
        if (migrator_ == address(0)) revert ZeroAddress();
        if (address(migrator) != address(0)) revert MigratorAlreadySet();
        migrator = IMigrator(migrator_);
        emit MigratorSet(migrator_);
    }

    /// @notice Announce a registry change; it can be applied after REGISTRY_TIMELOCK. Users see it coming on-chain.
    function proposeAgentIdRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        pendingRegistry = registry;
        pendingRegistryAt = block.timestamp + REGISTRY_TIMELOCK;
        emit RegistryChangeProposed(registry, pendingRegistryAt);
    }

    function cancelAgentIdRegistry() external onlyOwner {
        emit RegistryChangeCancelled(pendingRegistry);
        pendingRegistry = address(0);
        pendingRegistryAt = 0;
    }

    function applyAgentIdRegistry() external onlyOwner {
        if (pendingRegistry == address(0)) revert NothingPending();
        if (block.timestamp < pendingRegistryAt) revert TimelockActive();
        agentIdRegistry = IERC721(pendingRegistry);
        emit AgentIdRegistryUpdated(pendingRegistry);
        pendingRegistry = address(0);
        pendingRegistryAt = 0;
    }
}
