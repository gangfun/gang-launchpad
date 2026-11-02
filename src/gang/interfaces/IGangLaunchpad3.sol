// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What GangLaunchpad 3.0 adds to 2.0's ABI (IGangLaunchpad, unchanged): events only appended, never changed
///         (SPEC-GANG-PAD-3 §18.2). Declared here so the pad and CurveLogic3 emit the same events.
interface IGangLaunchpad3 {
    /// @notice `token` was created under rule set `version` (the pad's TOKEN_VERSION then); every create, both kinds.
    event TokenVersionSet(address indexed token, uint8 version);

    /// @notice Every curve trade of a 3.0 token, next to 2.0's `Buy` / `Sell`, with the whole fee split and the price
    ///         after the trade.
    /// @param quoteAmount buy: quote the curve took (fee included, refund excluded); sell: quote the curve paid out
    ///        before its fee
    /// @param tokenAmount tokens bought / sold
    /// @param protocolFee the 1% (creatorFee + the platform's part)
    /// @param creatorFee the creator's part of protocolFee, kept on the pad (`creatorFeeOf`)
    /// @param postPrice the curve's marginal price after the trade, quote wei per 1e18 token wei
    /// @param realQuote the curve's quote after the trade (before a graduation this trade triggers)
    /// @param sold tokens sold by the curve after the trade
    event TradeV1(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 quoteAmount,
        uint256 tokenAmount,
        uint256 protocolFee,
        uint256 creatorFee,
        uint256 postPrice,
        uint256 realQuote,
        uint256 sold
    );

    // ---------------------------------------------------------------- the aggregator entry (four.meme-shaped)
    /// @notice A `buyTokenAMAP` (local or forwarded), as GangGateway's: `caller` is msg.sender (the aggregator or the
    ///         user), `fundsUsed` what the pad kept, `amountOut` what `trader` received.
    event GatewayBuy(
        address indexed token, address indexed trader, address indexed caller, uint256 fundsUsed, uint256 amountOut
    );
    /// @notice A `sellToken`, as GangGateway's: `funds` is what the curve (or the old pad) paid after its 1% fee =
    ///         fundsToSeller + routerFee.
    event GatewaySell(
        address indexed token,
        address indexed trader,
        address indexed caller,
        uint256 amount,
        uint256 funds,
        uint256 fundsToSeller,
        uint256 routerFee,
        address feeRecipient
    );
    /// @notice A contract allowed (or no longer allowed) to call `sellToken` for a seller other than itself.
    event CallerSet(address indexed caller, bool allowed);

    /// @notice `sellToken` by a contract that is neither the seller nor listed (`isCaller`).
    error NotWhitelisted();
    /// @notice `setCaller(caller, true)` on an address without code, or an EIP-7702-delegated EOA.
    error NotAContract();
    /// @notice Not a token the aggregator entry trades now (not a Gang token, a 打新 token, graduated / launched, a
    ///         launched 铸币飞轮 token: any sell or a buy without post-launch minting).
    error NotCurveToken();
    /// @notice 铸币飞轮 buy: `funds` does not pay for one share.
    error FundsTooLow();
    /// @notice 铸币飞轮 sell: `amount` is 0 or not whole shares.
    error NotWholeShares();
    /// @notice `feeRate` above MAX_FEE_RATE (500 = 5%).
    error FeeRateTooHigh();
    /// @notice A router fee is due but `feeRecipient` is address(0).
    error ZeroFeeRecipient();
    /// @notice BNB-quoted: msg.value != funds; ERC-20-quoted: msg.value != 0.
    error BadMsgValue();
    /// @notice `tryBuy` by token amount (four.meme `amount != 0`): buys by funds only.
    error AmountNotSupported();
    /// @notice BNB sent to the pad by anyone but WBNB (unwrapping).
    error OnlyWbnb();
    error BnbTransferFailed();
    /// @notice A forwarded trade left the pad's own balance of the quote other than it found it (it must never touch the
    ///         escrow of the pad's own tokens).
    error EscrowMoved();
}

