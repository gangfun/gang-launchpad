// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What an aggregator calls to trade a Gang token on its bonding curve, laid out like four.meme's inner pool
///         (TokenManager2 + Helper3): the user approves this gateway once, any contract calls it with no whitelist
///         and no signature, and the seller (`from`) must be the wallet that sent the tx. The address never changes
///         (a proxy); every Gang pad generation the GangPadRegistry knows and that lists this gateway is served.
interface IGangGateway {
    /// @param caller msg.sender of the gateway call (the aggregator, or the user itself)
    event GatewayBuy(
        address indexed token, address indexed trader, address indexed caller, uint256 fundsUsed, uint256 amountOut
    );
    /// @param funds what the pad paid for the tokens (after its 1% fee): fundsToSeller + routerFee
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

    /// @notice `token` is not on a live Gang curve (not a Gang token, a 打新 token, or already graduated).
    error NotCurveToken();
    /// @notice `feeRate` above MAX_FEE_RATE (500 = 5%).
    error FeeRateTooHigh();
    /// @notice A router fee is due but `feeRecipient` is address(0).
    error ZeroFeeRecipient();
    /// @notice What the seller gets (after the pad's fee and the router fee) is below `minFunds`.
    error Slippage();
    /// @notice BNB-quoted: msg.value != funds; ERC-20-quoted: msg.value != 0.
    error BadMsgValue();
    /// @notice `tryBuy` by token amount (four.meme `amount != 0`): only buys by funds are supported.
    error AmountNotSupported();
    error OnlyWbnb();
    error BnbTransferFailed();
    error NotDeployed();

    /// @notice Where `token` trades now, by its pad's state (the pad GangPadRegistry trusts for it).
    /// @return status 0 = not a Gang token; 1 = on its curve; 2 = graduated / launched (trade on the PancakeSwap V2
    ///         `pair`); 3 = a 打新 sale still minting (not tradable here). Status 1 says where the token is, not that
    ///         this gateway can trade it now (its pad may not list the gateway, or have its gate off): a non-zero
    ///         tryBuy / trySell does
    /// @return quote address(0) for WBNB (this gateway takes and pays native BNB), else the quote ERC-20
    /// @return pair the PancakeSwap V2 pair once status == 2, else address(0)
    /// @return protocolFeeBps the pad's fee on every curve trade (100 = 1%) while on the curve (status 1), else 0
    /// @return graduationLeft quote the curve still needs to graduate (status 1), else 0: net of the 1% fee (paying it
    ///         takes about graduationLeft * 10000 / 9900)
    function getTokenInfo(address token)
        external
        view
        returns (uint8 status, address quote, address pair, uint256 protocolFeeBps, uint256 graduationLeft);

    /// @notice Helper3.tryBuy's return layout, with the trader added (Helper3: tryBuy(token, amount, funds), so the
    ///         selector differs); buys by funds only (`amount` must be 0). What
    ///         `buyTokenAMAP(token, trader, funds, 0)` would do now; all estimates 0 when it would revert (not a curve
    ///         token, the pad does not list this gateway or has its gate off, `trader` fails the gate, wallet cap
    ///         reached, funds 0). `trader` = address(0): a fresh wallet, no gate check.
    /// @return tokenManager this gateway (the address to approve / call)
    /// @return quote address(0) for BNB
    /// @return estimatedAmount tokens `trader` gets (after the 1% wallet cap / graduation cut)
    /// @return estimatedCost quote the pad keeps (fee included); funds - estimatedCost is refunded to `trader`
    /// @return estimatedFee the pad's 1% fee
    /// @return amountMsgValue msg.value to send with these funds (BNB-quoted), else 0
    /// @return amountApproval quote allowance the caller must give this gateway (ERC-20-quoted), else 0
    /// @return amountFunds = estimatedCost: passing it as `funds` buys the same amount with nothing refunded
    function tryBuy(address token, address trader, uint256 amount, uint256 funds)
        external
        view
        returns (
            address tokenManager,
            address quote,
            uint256 estimatedAmount,
            uint256 estimatedCost,
            uint256 estimatedFee,
            uint256 amountMsgValue,
            uint256 amountApproval,
            uint256 amountFunds
        );

    /// @notice Helper3.trySell's name and return layout: what selling `amount` pays now (after the pad's 1% fee,
    ///         before any router fee) and that fee; both 0 when the sell would revert (not a curve token, the pad does
    ///         not list this gateway, amount 0 or above what the curve sold) — and 0 for dust that sells for nothing
    ///         (sellToken would take the tokens and pay 0: treat funds == 0 as "do not sell"). The seller's balance,
    ///         allowance and gate are not checked.
    function trySell(address token, uint256 amount)
        external
        view
        returns (address tokenManager, address quote, uint256 funds, uint256 fee);

    /// @notice Buy with `funds` of the quote; tokens go to `to`, which must be the wallet that sent the tx
    ///         (TraderNotOrigin from the pad otherwise). BNB-quoted: msg.value == funds. ERC-20-quoted: msg.value == 0
    ///         and `funds` is pulled from msg.sender (approve this gateway). When the 1% wallet cap or graduation cuts
    ///         the buy, the pad refunds the unused part straight to `to` in the quote ERC-20 (WBNB for a BNB-quoted
    ///         token), never to msg.sender. The Agent gate and the wallet cap are `to`'s.
    /// @return amountOut tokens `to` received (its balance change), at least `minAmount`
    /// @return fundsUsed funds the pad kept (funds minus that refund)
    function buyTokenAMAP(address token, address to, uint256 funds, uint256 minAmount)
        external
        payable
        returns (uint256 amountOut, uint256 fundsUsed);

    /// @notice four.meme's open sell (TokenManager2.sellToken with a router fee): any contract may call it, so any
    ///         contract the seller calls can sell what the seller approved to this gateway, at a price it may move in
    ///         the same tx: approve exact amounts (AUDIT-BRIEF §25). Sells
    ///         `amount` of `from`'s tokens, `from` being the wallet that sent the tx (TraderNotOrigin from the pad
    ///         otherwise), with the allowance `from` gave THIS gateway on the token. The tokens go from `from` straight
    ///         into the pad. Of what the pad pays, `feeRate` / 10000 goes to `feeRecipient` and the rest to `from`,
    ///         as native BNB for a BNB-quoted token, else in the quote ERC-20.
    /// @param origin ignored (four.meme's reserved field; pass 0)
    /// @param minFunds the least `from` must end up with: after the pad's 1% fee AND the router fee
    /// @param feeRate router fee in basis points, at most 500 (5%)
    /// @return fundsToSeller what `from` received
    function sellToken(
        uint256 origin,
        address token,
        address from,
        uint256 amount,
        uint256 minFunds,
        uint256 feeRate,
        address feeRecipient
    ) external returns (uint256 fundsToSeller);
}
