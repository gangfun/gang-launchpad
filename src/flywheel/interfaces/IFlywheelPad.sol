// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Types, events and errors of GangFlywheelPad (持续打新 / continuous mint), V2.
interface IFlywheelPad {
    /// @notice What a dev chooses at create (platform limits in `FlywheelLogic.checkConfig`). `guardBps` and
    ///         `twapWindow` must be valid even when `postMint` is off (e.g. 0 and 1,800): create checks them regardless.
    struct FlyConfig {
        uint256 raiseBnb; // 3–50 BNB worth: the 10,000 pre-launch shares' price in all
        uint16 baseQuota; // 5–100 shares per wallet (5–10 with postMint), before and after launch together
        uint8 inviteBonus; // 0–3 shares of quota per invited wallet's first mint (0–1 with postMint)
        uint8 maxPerTx; // 1–10 shares per mint
        uint16 holdBps; // 6,000–9,000: holder reward hold line
        uint16 mintFeeBps; // 100–300: on top of every mint, to the platform
        uint16 exitFeeBps; // 100–200: pre-launch sell-back fee
        uint16 devCutBps; // 0–1,000 (audit A-F2: above it a creator's alts minting and selling paid): of every other wallet's mint, to the creator (pre-launch: held until launch)
        uint16 buyBps; // 0–5,000: of each post-launch mint's pool money, bought from the pool
        uint16 sellTaxBps; // 100–200 (buy tax is 1%)
        uint32 launchDelay; // 0–300 s between filling (or opening early) and launch
        uint32 window; // 300–1,800 s of launch protection
        uint8 windowCapMul; // 1–2: protection cap = baseQuota × this, in pre-launch share tokens
        bool postMint; // minting continues after launch (only on a sale created with the Agent ID gate on)
        uint8 tierMode; // 0 flat, 1 standard 353-step table, 2 linear
        uint16 stepBps; // linear: 0–1,000 per step
        uint32 stepShares; // linear: 100–100,000 shares per step, counted from share 10,001 (the first post-launch)
        uint16 maxMulX100; // linear: 100–1,000 (×1–×10)
        uint16 supplyCapMul; // postMint: 10–500 × the full pre-launch supply (both sides)
        uint16 guardBps; // post-launch TWAP guard: 0 (off), 1,500, 2,000 or 3,000 (refused this far below the TWAP); must be valid even with postMint off
        uint32 twapWindow; // post-launch TWAP window: 900 or 1,800 s; must be valid even with postMint off
    }

    /// @notice A sale's post-launch rules (V2), kept beside `Sale` so its getter's ABI stays as it was: `postRulesOf`.
    struct PostRules {
        uint16 guardBps;
        uint32 twapWindow;
    }

    /// @notice One sale. Rules are fixed at create; the rest is state.
    struct Sale {
        address creator;
        address quote;
        address gate; // Agent ID registry snapshot (0 = ungated)
        address pair;
        uint128 basePrice; // quote per share before launch (and the ×1 of the tier table)
        uint64 totalShares; // shares minted, before and after launch (drives the tier table)
        uint64 filledAt; // 0 until filled or opened early
        uint64 progressAt; // stale clock (sell-back fee waiver)
        uint16 sold; // pre-launch shares held by minters
        uint16 creatorShares; // of which the creator's own (no dev cut on them)
        uint16 markSold;
        uint16 baseQuota;
        uint16 holdBps;
        uint16 mintFeeBps;
        uint16 exitFeeBps;
        uint16 devCutBps;
        uint16 buyBps;
        uint32 launchDelay;
        uint32 window;
        uint8 inviteBonus;
        uint8 maxPerTx;
        uint8 windowCapMul;
        uint8 tierMode;
        uint16 stepBps;
        uint32 stepShares;
        uint16 maxMulX100;
        bool postMint;
        bool launched;
    }

    /// @notice One wallet in one sale.
    struct Account {
        uint32 preShares; // pre-launch shares it can still sell back
        uint32 used; // quota used, before and after launch
        uint32 bonus; // quota earned from invites
        bool minted; // minted at least once (can refer; is no longer referable)
        uint64 windowStart; // post-launch pace window
        uint128 windowSpent;
        uint256 baseline; // tokens minted since it last qualified (holder rule)
    }

    event Created(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string logoURI,
        address quote,
        uint256 basePrice,
        FlyConfig cfg
    );
    event Minted(
        address indexed token, address indexed trader, uint256 shares, uint256 cost, uint256 fee, uint256 sold
    );
    event Withdrawn(address indexed token, address indexed trader, uint256 shares, uint256 payout, uint256 fee);
    event Referred(address indexed token, address indexed referrer, address indexed invitee, uint256 bonus);
    event Filled(address indexed token, uint256 sold, bool early);
    event Launched(address indexed token, address pair, uint256 poolTokens, uint256 poolQuote, uint256 devCut);
    event PostMinted(
        address indexed token,
        address indexed trader,
        uint256 shares,
        uint256 paid,
        uint256 fee,
        uint256 devCut,
        uint256 tokensOut,
        uint256 boughtQuote
    );
    event DevPaid(address indexed token, address indexed creator, uint256 amount);
    event DevOwed(address indexed token, address indexed creator, uint256 amount);
    event FeeOwed(address indexed quote, uint256 amount);
    event FeesFlushed(address indexed quote, uint256 amount);
    event ShareWriteFailed(address indexed token, address indexed user, uint256 share);
    event MigratorSet(address migrator);
    event AgentGateUpdated(bool enabled, address registry);
    event PairFactorySet(address factory);
    event V3FactorySet(address factory);
    /// @notice The reference-pool pricing window changed (non-BNB quotes at create); not a sale's TWAP window.
    event TwapWindowUpdated(uint32 window);
    event BridgePoolSet(address indexed asset, address pool);
    event RouterSet(address indexed router, bool enabled);

    error ZeroAddress();
    error ZeroAmount();
    error BadAmount();
    error BadConfig(string reason);
    error UnknownToken();
    error NotAgent();
    error NotMinting();
    error NotLaunched();
    error NotFilled();
    error TooEarly();
    error OnlyCreator();
    error Slippage();
    error PriceBelowAverage();
    error PriceAbovePool();
    error PaceExceeded();
    error PostMintOff();
    error MigratorNotSet();
    error MigratorAlreadySet();
    error WrongMigrator();
    error VaultFloorTooHigh();
    error PriceTooSmall();
    error NothingOwed();
    error BnbNotQuote();
    error BnbShort();
    error OnlyRouter();
    error TraderNotOrigin();
    error RouterNeedsGate();
    error TooFewShares();
}
