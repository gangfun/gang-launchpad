// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice GangLaunchpad's types, events and errors, shared by the pad and its two logic libraries (CurveLogic,
///         FairLogic). Every event and error keeps the name, parameters and indexing LaunchpadV3 / FairMintPad had, so
///         topic0, selectors and decoding are unchanged for indexers and the CLI. The two `Created` events are
///         overloads (V3: 8 fields, 打新: 13 fields), each with its old topic0.
interface IGangLaunchpad {
    // ---------------------------------------------------------------- types
    /// @param buyTaxBps   Tax on pool buys after graduation (none on the curve). 0 together with sellTaxBps = untaxed
    ///                    (all fields zero); otherwise 100–500. Fixed for the token's life.
    /// @param sellTaxBps  Tax on pool sells after graduation (none on the curve), same bounds.
    /// @param dividendBps Share of each tax after the platform's 0.5% of volume that goes to holder dividends
    ///                    (0–10_000). The rest goes to `recipient`.
    /// @param recipient   Paid in quote: the creator itself, or a handler-listed address (e.g. a project vault). Fixed
    ///                    for the token's life.
    ///                    May be 0 only when dividendBps is 10_000.
    struct TaxConfig {
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 dividendBps;
        address recipient;
    }

    struct MintConfig {
        uint256 raiseBnb; // BNB-equivalent; converted to quote units at create
        uint16 capBps; // per-address cap, share of total supply (25–100: 0.25%–1%)
        uint16 holdBps; // reward line (6000–9000): out for good once balance < baseline × holdBps
        uint16 mintFeeBps; // on top of the principal at mint, to the platform at once
        uint16 exitFeeBps; // taken from the principal on withdraw (waived once the sale is stale)
    }

    /// @dev Same layout as LaunchpadV3.Curve (GangRouter and the indexer decode `curves` by it).
    struct Curve {
        address creator;
        address quote;
        uint128 realQuote;
        uint128 sold;
        uint128 gradAmt;
        uint128 virtualQuote;
        bool graduated;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 dividendBps;
        address pair;
        address refPair;
    }

    /// @dev Same layout as FairMintPad.Sale (GangRouter and the indexer decode `sales` by it).
    struct Sale {
        address creator;
        uint64 progressAt; // stale clock: the creator's mint, then each mint that lifts `sold` to markSold + STALE_STEP
        uint16 capShares;
        uint16 holdBps;
        address quote;
        uint16 sold;
        bool launched;
        uint16 mintFeeBps;
        uint16 exitFeeBps;
        address gate; // Agent ID registry snapshot; 0 = ungated
        uint128 sharePrice;
        address pair;
        address refPool;
        uint16 markSold; // `sold` when the stale clock last restarted
    }

    struct Position {
        uint16 shares;
    }

    enum Status {
        None,
        Minting,
        Launched
    }

    /// @dev The pad's mutable settings, one storage struct so the libraries get them as one storage pointer.
    struct Config {
        address pairFactory;
        address v3Factory;
        uint32 twapWindow;
        address migrator;
        address agentIdRegistry;
        bool agentGateEnabled;
        bool walletCapEnabled;
    }

    /// @dev The pad's immutables, handed to the libraries on every call (they can't read the pad's code).
    struct Deps {
        address quoteRegistry;
        address dividendVault;
        address platformBucket;
        address taxHandler;
        address tokenDeployer;
        address wbnb;
    }

    // ---------------------------------------------------------------- V3 (curve) events
    /// @dev Same as V2 minus `taxed`; the tax side is in `TaxConfigured` (always emitted, also for untaxed).
    event Created(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string logoURI,
        address indexed quote,
        address refPair,
        uint256 gradAmt
    );
    event TaxConfigured(
        address indexed token, uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address indexed recipient
    );
    /// @dev `tax` is always 0: the curve charges only the 1% protocol fee (spec §19). `protocolFee` is the whole 1%;
    ///      `CreatorFeeAccrued` says how much of it the creator got (the rest went to the bucket).
    event Buy(
        address indexed token,
        address indexed buyer,
        uint256 quoteIn,
        uint256 protocolFee,
        uint256 tax,
        uint256 tokensOut,
        uint256 realQuote
    );
    /// @dev `tax` is always 0 and `protocolFee` the whole 1% (as `Buy`).
    event Sell(
        address indexed token,
        address indexed seller,
        uint256 tokensIn,
        uint256 protocolFee,
        uint256 tax,
        uint256 quoteOut,
        uint256 realQuote
    );
    /// @notice The creator's part of one curve trade's 1% fee (`CREATOR_FEE_SHARE_BPS` of it), kept for the creator.
    event CreatorFeeAccrued(address indexed token, address indexed creator, uint256 amount);
    /// @notice The creator took everything kept for it on `token`, in the token's quote.
    event CreatorFeeClaimed(address indexed token, address indexed creator, address indexed to, uint256 amount);
    event VirtualQuoteLocked(address indexed token, uint256 virtualQuote);
    /// @notice The graduation target the creator picked, in BNB raised (`gradAmt` in `Created` is it in the quote).
    event GradTargetSet(address indexed token, uint256 gradBnb);
    event Graduated(
        address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount
    );

    // ---------------------------------------------------------------- 打新 events
    event Created(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string logoURI,
        address indexed quote,
        address refPool,
        uint256 raiseBnb,
        uint256 sharePrice,
        uint256 capShares,
        uint256 holdBps,
        uint256 mintFeeBps,
        uint256 exitFeeBps
    );
    event Minted(
        address indexed token,
        address indexed user,
        uint256 shares,
        uint256 cost,
        uint256 fee,
        uint256 userShares,
        uint256 sold
    );
    event Withdrawn(
        address indexed token,
        address indexed user,
        uint256 shares,
        uint256 payout,
        uint256 fee,
        uint256 userShares,
        uint256 sold
    );
    event Launched(
        address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount
    );
    /// @notice The vault refused the exit's share write: `user` keeps its old share until someone `syncShares` it.
    event ShareWriteFailed(address indexed token, address indexed user, uint256 share);
    event FeeOwed(address indexed quote, uint256 amount);
    event FeesFlushed(address indexed quote, uint256 amount);

    // ---------------------------------------------------------------- admin events (same on both old cores)
    event MigratorSet(address indexed migrator);
    event PairFactorySet(address indexed factory);
    event AgentGateUpdated(bool enabled, address registry);
    event WalletCapUpdated(bool enabled);
    event V3FactorySet(address indexed factory);
    event TwapWindowUpdated(uint32 window);
    event BridgePoolSet(address indexed asset, address indexed pool);
    event RouterSet(address indexed router, bool enabled);

    // ---------------------------------------------------------------- errors
    // both
    error UnknownToken();
    error ZeroAmount();
    error Slippage();
    error NotAgent();
    error WalletCapReached();
    error MigratorNotSet();
    error MigratorAlreadySet();
    error ZeroAddress();
    error RefPoolRequired();
    error NoBridgePool();
    error BridgeNotWbnb();
    /// @notice buyFor / sellFor / mintFor / withdrawFor: the caller is not a listed router.
    error OnlyRouter();
    /// @notice buyFor / sellFor / mintFor / withdrawFor: `trader` is not the wallet that sent the tx (AUDIT-BRIEF §23).
    error TraderNotOrigin();
    error QuoteNotAllowed();
    error FeeOnTransferQuote();
    error WrongMigrator();
    error RouterNeedsGate();
    error VaultFloorTooHigh();
    // V3
    error AlreadyGraduated();
    error GradAmtTooSmall();
    error BadGradTarget();
    error BadTaxConfig(string reason);
    error NotCreator();
    // 打新
    error BadConfig(string reason);
    error NotMinting();
    error BadAmount();
    error PriceTooSmall();
    error OutOfGas();
    // Raised inside the libraries the pad delegatecalls (PoolCheck via PadCommon, OZ SafeCast / SafeERC20 in
    // CurveLogic / FairLogic / PadCommon). Declared here so they are in the pad's ABI and decode on explorers;
    // same signatures as the originals, so the selectors are the same.
    error ThinReferencePool();
    error GradAmtZero();
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);
    error SafeERC20FailedOperation(address token);
}
