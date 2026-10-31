// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SharedDividendVault} from "../common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket as PlatformFeeBucket} from "../common/SharedPlatformFeeBucket.sol";
import {IMigratorV2} from "../launchpad-v2/interfaces/IMigratorV2.sol";
import {IGangLaunchpad} from "../gang/interfaces/IGangLaunchpad.sol";
import {PadCommon} from "../gang/PadCommon.sol";
import {IFlywheelPad} from "./interfaces/IFlywheelPad.sol";

/// @notice The slice of GangMintToken the pad calls.
interface IFlyToken {
    function padMint(address to, uint256 amount) external;
    function reclaim(address from, uint256 amount) external;
    function pullFor(address owner, address spender, uint256 amount) external;
    function unlock(address migrator) external;
    function setPair(address pair) external;
}

/// @notice The slice of FlywheelTaxHandler the pad calls.
interface IFlyHandler {
    function register(address token, address quote, address recipient) external;
    function onLaunch(address token, uint64 protectedUntil, address gate, uint256 cap) external;
    function requalify(address token, address user) external;
    function observe(address token) external;
    function isOut(address token, address user) external view returns (bool);
    function syncShares(address token, address from, address to) external;
}

interface IMintTokenDeployer {
    function deploy(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        address handler,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint256 startSupply,
        uint256 maxSupply
    ) external returns (address token);
}

/// @title FlywheelLogic — GangFlywheelPad's create, pre-launch mint / sell-back, early opening and launch
/// @notice External library: the pad delegatecalls it, so it runs on the pad's storage, balance and msg.sender, and its
///         events come from the pad. Before launch: 10,000 shares at one price; every wallet mints within its quota
///         (base + invites, shared with post-launch minting); shares can be sold back at the mint price less the exit
///         fee (none once the sale is stale) until the sale is filled or opened early. The dev's cut of each payment is
///         held here until launch, so a sell-back refunds it. Launch seeds the pair at the mint price with the raise
///         and the sold tokens, both less the dev's cut, and starts the launch protection and the price oracle.
library FlywheelLogic {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant TOTAL_SHARES = 10_000;
    uint256 internal constant TOKENS_PER_SHARE = 100_000 ether;
    /// @dev Tokens before launch, both sides at most: the minters' and the pool's.
    uint256 internal constant PRE_SUPPLY = 2 * TOTAL_SHARES * TOKENS_PER_SHARE;
    uint256 internal constant MIN_RAISE_BNB = 3 ether;
    uint256 internal constant MAX_RAISE_BNB = 50 ether;
    uint256 internal constant STALE_AFTER = 7 days;
    uint256 internal constant STALE_STEP = 10;
    uint256 internal constant EARLY_OPEN_SHARES = 3_000; // 30%
    /// @notice A filled sale not launched this long after it could be lets minters sell back again (escrow never
    ///         stuck behind a launch that can't happen; internal audit A-L1).
    uint256 internal constant LAUNCH_GRACE = 7 days;
    /// @dev The raise must leave the pair's uint112 reserves room for post-launch mints (internal audit A-L1).
    uint256 internal constant MAX_RAISE_QUOTE = type(uint112).max / 1e6;
    uint16 internal constant BUY_TAX_BPS = 100;
    /// @dev Holders need a balance strictly above this for vault shares (the pad's floor in the shared vault).
    uint256 internal constant MIN_SHARE = 1_000 ether;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint8 internal constant KIND = 3;
    /// @notice V2: the largest base quota a sale with post-launch minting may set.
    uint16 internal constant MAX_POST_QUOTA = 10;

    // ---------------------------------------------------------------- create
    function create(
        IGangLaunchpad.Config storage c,
        mapping(address => IFlywheelPad.Sale) storage sales,
        mapping(address => mapping(address => IFlywheelPad.Account)) storage accounts,
        mapping(address => uint256) storage owedDev,
        mapping(address => IFlywheelPad.PostRules) storage postRules,
        mapping(address => address) storage bridgePoolOf,
        IGangLaunchpad.Deps memory d,
        string[4] calldata text, // name, symbol, logoURI, metaURI
        address quote,
        address refPool,
        IFlywheelPad.FlyConfig calldata cfg,
        uint256 devShares
    ) external returns (address token) {
        if (c.migrator == address(0)) revert IFlywheelPad.MigratorNotSet();
        address gate = _currentGate(c);
        _requireAgent(gate, msg.sender);
        string memory reason = checkConfig(cfg, devShares);
        if (bytes(reason).length != 0) revert IFlywheelPad.BadConfig(reason);
        // without the one-wallet-per-person gate, quotas don't bound a creator minting through fresh wallets to collect
        // its own cut (review R2-1 L-2): an ungated sale takes none
        if (gate == address(0) && cfg.devCutBps != 0) {
            revert IFlywheelPad.BadConfig("devCutBps must be 0 when ungated");
        }
        // post-launch mints are priced at the pool and bounded per Agent ID (quota): without the gate nothing bounds
        // the wallets a dump-then-mint can use (audit V2 A-L1)
        if (gate == address(0) && cfg.postMint) revert IFlywheelPad.BadConfig("postMint needs the Agent ID gate");
        SharedDividendVault vault = SharedDividendVault(d.dividendVault);
        if (vault.minimumShareBalanceOf(address(this)) > MIN_SHARE) revert IFlywheelPad.VaultFloorTooHigh();

        if (quote == address(0)) quote = d.wbnb;
        PadCommon.requireQuote(d, quote);
        (uint256 raiseQuote,) = PadCommon.toQuote(c, bridgePoolOf, d, quote, refPool, cfg.raiseBnb);
        uint256 price = raiseQuote / TOTAL_SHARES;
        if (price == 0) revert IFlywheelPad.PriceTooSmall();
        if (raiseQuote > MAX_RAISE_QUOTE) revert IFlywheelPad.BadConfig("raise too large in this quote");

        uint256 cap = cfg.postMint ? PRE_SUPPLY * cfg.supplyCapMul : PRE_SUPPLY;
        token = IMintTokenDeployer(d.tokenDeployer)
            .deploy(text[0], text[1], text[3], d.taxHandler, BUY_TAX_BPS, cfg.sellTaxBps, 0, cap);
        vault.ensureMinimumShareBalance(MIN_SHARE);
        vault.registerToken(token, quote);
        IFlyHandler(d.taxHandler).register(token, quote, msg.sender);

        IFlywheelPad.Sale storage s = sales[token];
        s.creator = msg.sender;
        s.quote = quote;
        s.gate = gate;
        s.basePrice = price.toUint128();
        s.baseQuota = cfg.baseQuota;
        s.holdBps = cfg.holdBps;
        s.mintFeeBps = cfg.mintFeeBps;
        s.exitFeeBps = cfg.exitFeeBps;
        s.devCutBps = cfg.devCutBps;
        s.buyBps = cfg.buyBps;
        s.launchDelay = cfg.launchDelay;
        s.window = cfg.window;
        s.inviteBonus = cfg.inviteBonus;
        s.maxPerTx = cfg.maxPerTx;
        s.windowCapMul = cfg.windowCapMul;
        s.tierMode = cfg.tierMode;
        s.stepBps = cfg.stepBps;
        s.stepShares = cfg.stepShares;
        s.maxMulX100 = cfg.maxMulX100;
        s.postMint = cfg.postMint;
        postRules[token] = IFlywheelPad.PostRules({guardBps: cfg.guardBps, twapWindow: cfg.twapWindow});

        emit IFlywheelPad.Created(token, msg.sender, text[0], text[1], text[2], quote, price, cfg);
        _mint(c, sales, accounts, owedDev, d, msg.sender, token, devShares, devShares, address(0), 0);
    }

    /// @notice Every reason `create` would refuse `cfg` (empty = fine), except the ones that depend on the pad's Agent
    ///         ID gate (the pad's `checkConfig` adds those). `guardBps` and `twapWindow` are checked even with postMint
    ///         off.
    function checkConfig(IFlywheelPad.FlyConfig calldata cfg, uint256 devShares) public pure returns (string memory) {
        if (cfg.raiseBnb < MIN_RAISE_BNB || cfg.raiseBnb > MAX_RAISE_BNB) return "raiseBnb must be 3-50 BNB";
        if (cfg.baseQuota < 5 || cfg.baseQuota > 100) return "baseQuota must be 5-100";
        // V2: post-launch mints are priced at the pool, so a quota bounds what a dump-then-mint with many Agent IDs
        // can take (the J-preset grid in test/flywheel/FlywheelV2.t.sol)
        if (cfg.postMint && cfg.baseQuota > MAX_POST_QUOTA) return "baseQuota must be 5-10 with postMint";
        if (cfg.inviteBonus > 3) return "inviteBonus must be 0-3";
        // V2: invite shares add to what one dump-then-mint can take with its Agent IDs (audit V2 A-M1)
        if (cfg.postMint && cfg.inviteBonus > 1) return "inviteBonus must be 0-1 with postMint";
        if (cfg.maxPerTx < 1 || cfg.maxPerTx > 10) return "maxPerTx must be 1-10";
        if (cfg.holdBps < 6_000 || cfg.holdBps > 9_000) return "holdBps must be 6000-9000";
        if (cfg.mintFeeBps < 100 || cfg.mintFeeBps > 300) return "mintFeeBps must be 100-300";
        if (cfg.exitFeeBps < 100 || cfg.exitFeeBps > 200) return "exitFeeBps must be 100-200";
        if (cfg.devCutBps > 1_000) return "devCutBps must be 0-1000";
        if (cfg.buyBps > 5_000) return "buyBps must be 0-5000";
        if (cfg.sellTaxBps < 100 || cfg.sellTaxBps > 200) return "sellTaxBps must be 100-200";
        if (cfg.launchDelay > 300) return "launchDelay must be 0-300";
        if (cfg.window < 300 || cfg.window > 1_800) return "window must be 300-1800";
        if (cfg.windowCapMul < 1 || cfg.windowCapMul > 2) return "windowCapMul must be 1-2";
        if (cfg.tierMode > 2) return "tierMode must be 0-2";
        if (cfg.tierMode == 2) {
            if (cfg.stepBps > 1_000) return "stepBps must be 0-1000";
            if (cfg.stepShares < 100 || cfg.stepShares > 100_000) return "stepShares must be 100-100000";
            if (cfg.maxMulX100 < 100 || cfg.maxMulX100 > 1_000) return "maxMulX100 must be 100-1000";
        }
        if (cfg.postMint && (cfg.supplyCapMul < 10 || cfg.supplyCapMul > 500)) return "supplyCapMul must be 10-500";
        if (cfg.guardBps != 0 && cfg.guardBps != 1_500 && cfg.guardBps != 2_000 && cfg.guardBps != 3_000) {
            return "guardBps must be 0, 1500, 2000 or 3000";
        }
        if (cfg.twapWindow != 900 && cfg.twapWindow != 1_800) return "twapWindow must be 900 or 1800";
        if (devShares == 0 || devShares > cfg.baseQuota || devShares > cfg.maxPerTx) {
            return "devShares must be 1..min(baseQuota, maxPerTx)";
        }
        return "";
    }

    // ---------------------------------------------------------------- pre-launch
    /// @param bnbIn BNB the caller sent (already wrapped by the pad); 0 = pay in the quote with an allowance.
    function mint(
        IGangLaunchpad.Config storage c,
        mapping(address => IFlywheelPad.Sale) storage sales,
        mapping(address => mapping(address => IFlywheelPad.Account)) storage accounts,
        mapping(address => uint256) storage owedDev,
        IGangLaunchpad.Deps memory d,
        address trader,
        address token,
        uint256 shares,
        uint256 minShares,
        address referrer,
        uint256 bnbIn
    ) external returns (uint256 spent) {
        if (shares == 0) revert IFlywheelPad.ZeroAmount();
        IFlywheelPad.Sale storage s = minting(sales, token);
        _requireAgent(s.gate, trader);
        return _mint(c, sales, accounts, owedDev, d, trader, token, shares, minShares, referrer, bnbIn);
    }

    function withdraw(
        mapping(address => IFlywheelPad.Sale) storage sales,
        mapping(address => mapping(address => IFlywheelPad.Account)) storage accounts,
        mapping(address => uint256) storage owedFee,
        IGangLaunchpad.Deps memory d,
        address trader,
        bool viaCaller,
        address token,
        uint256 shares,
        uint256 minPayout
    ) external returns (uint256 payout) {
        IFlywheelPad.Sale storage s = sales[token];
        if (!withdrawable(s)) revert IFlywheelPad.NotMinting();
        IFlywheelPad.Account storage a = accounts[token][trader];
        if (shares == 0 || shares > a.preShares) revert IFlywheelPad.BadAmount();
        uint256 principal = shares * s.basePrice;
        uint256 fee = (principal * exitFeeBps(s)) / BPS;
        payout = principal - fee;
        if (payout < minPayout) revert IFlywheelPad.Slippage();

        uint32 n = shares.toUint32();
        a.preShares -= n;
        a.used -= n;
        s.sold -= uint16(n);
        if (trader == s.creator) s.creatorShares -= uint16(n);
        s.totalShares -= n;
        uint256 tokens = shares * TOKENS_PER_SHARE;
        a.baseline -= tokens;
        // direct: the pad takes the tokens back; via a listed router: with the allowance the trader gave the router
        if (viaCaller) IFlyToken(token).pullFor(trader, msg.sender, tokens);
        else IFlyToken(token).reclaim(trader, tokens);
        _setShareOnExit(d, token, trader, a.baseline);
        IERC20(s.quote).safeTransfer(msg.sender, payout);
        _exitFeeToPlatform(owedFee, d, s.quote, fee);
        emit IFlywheelPad.Withdrawn(token, trader, shares, payout, fee);
    }

    /// @notice The creator opens the pool before the sale fills, once at least 30% is sold.
    function openEarly(
        IGangLaunchpad.Config storage c,
        mapping(address => IFlywheelPad.Sale) storage sales,
        mapping(address => uint256) storage owedDev,
        IGangLaunchpad.Deps memory d,
        address token
    ) external {
        IFlywheelPad.Sale storage s = minting(sales, token);
        if (msg.sender != s.creator) revert IFlywheelPad.OnlyCreator();
        if (s.sold < EARLY_OPEN_SHARES) revert IFlywheelPad.TooEarly();
        _filled(c, s, owedDev, d, token, true);
    }

    /// @notice Anyone, once the sale is filled (or opened early) and `launchDelay` has passed.
    function launch(
        IGangLaunchpad.Config storage c,
        mapping(address => IFlywheelPad.Sale) storage sales,
        mapping(address => uint256) storage owedDev,
        IGangLaunchpad.Deps memory d,
        address token
    ) external {
        IFlywheelPad.Sale storage s = sales[token];
        if (s.creator == address(0)) revert IFlywheelPad.UnknownToken();
        if (s.launched) revert IFlywheelPad.NotMinting();
        if (s.filledAt == 0) revert IFlywheelPad.NotFilled();
        if (block.timestamp < uint256(s.filledAt) + s.launchDelay) revert IFlywheelPad.TooEarly();
        // after the grace period sell-backs can shrink a filled sale: below the early-open floor it only refunds (a
        // tiny pool would leave every post-launch mint above the pace cap; review R2-1 L-1)
        if (s.sold < EARLY_OPEN_SHARES) revert IFlywheelPad.TooFewShares();
        _launch(c, s, owedDev, d, token);
    }

    // ---------------------------------------------------------------- views (also used by the pad)
    /// @dev The sale, if it is still taking pre-launch mints / sell-backs (created, not filled, not launched).
    function minting(mapping(address => IFlywheelPad.Sale) storage sales, address token)
        internal
        view
        returns (IFlywheelPad.Sale storage s)
    {
        s = sales[token];
        if (s.creator == address(0)) revert IFlywheelPad.UnknownToken();
        if (s.launched || s.filledAt != 0) revert IFlywheelPad.NotMinting();
    }

    /// @dev Sell-backs: before the sale fills (or opens early), or once a filled sale has gone LAUNCH_GRACE past its
    ///      launch time without launching.
    function withdrawable(IFlywheelPad.Sale storage s) internal view returns (bool) {
        if (s.creator == address(0) || s.launched) return false;
        if (s.filledAt == 0) return true;
        return block.timestamp >= uint256(s.filledAt) + s.launchDelay + LAUNCH_GRACE;
    }

    function exitFeeBps(IFlywheelPad.Sale storage s) internal view returns (uint256) {
        return block.timestamp >= uint256(s.progressAt) + STALE_AFTER ? 0 : s.exitFeeBps;
    }

    // ---------------------------------------------------------------- internal
    function _mint(
        IGangLaunchpad.Config storage c,
        mapping(address => IFlywheelPad.Sale) storage sales,
        mapping(address => mapping(address => IFlywheelPad.Account)) storage accounts,
        mapping(address => uint256) storage owedDev,
        IGangLaunchpad.Deps memory d,
        address trader,
        address token,
        uint256 want,
        uint256 minShares,
        address referrer,
        uint256 bnbIn
    ) private returns (uint256 spent) {
        IFlywheelPad.Sale storage s = sales[token];
        IFlywheelPad.Account storage a = accounts[token][trader];
        uint256 accepted = _acceptable(s, a, want, TOTAL_SHARES - s.sold);
        if (accepted == 0) revert IFlywheelPad.ZeroAmount();
        if (accepted < minShares) revert IFlywheelPad.Slippage();

        uint256 cost = accepted * s.basePrice;
        uint256 fee = (cost * s.mintFeeBps) / BPS;
        spent = cost + fee;
        collect(s.quote, spent, bnbIn);
        PadCommon.toPlatform(d, s.quote, fee);

        uint32 n = accepted.toUint32();
        s.sold += uint16(n);
        if (trader == s.creator) s.creatorShares += uint16(n);
        s.totalShares += n;
        a.preShares += n;
        a.used += n;
        refer(s, accounts, token, trader, a, referrer);
        // only progress restarts the stale clock (R3-1): the creator's mint, or `sold` up STALE_STEP since the restart
        if (s.progressAt == 0 || s.sold >= uint256(s.markSold) + STALE_STEP) {
            s.progressAt = uint64(block.timestamp);
            s.markSold = s.sold;
        }

        uint256 tokens = accepted * TOKENS_PER_SHARE;
        a.baseline += tokens;
        _giveTokens(token, trader, tokens);
        SharedDividendVault(d.dividendVault).setShare(token, trader, a.baseline);
        emit IFlywheelPad.Minted(token, trader, accepted, cost, fee, s.sold);

        if (s.sold == TOTAL_SHARES) _filled(c, s, owedDev, d, token, false);
    }

    /// @dev Shares a wallet can mint now: its quota left, the per-mint cap, and `left` (pre-launch shares left).
    function _acceptable(IFlywheelPad.Sale storage s, IFlywheelPad.Account storage a, uint256 want, uint256 left)
        internal
        view
        returns (uint256)
    {
        uint256 quota = uint256(s.baseQuota) + a.bonus;
        uint256 room = a.used >= quota ? 0 : quota - a.used;
        uint256 n = want < room ? want : room;
        if (n > s.maxPerTx) n = s.maxPerTx;
        return n < left ? n : left;
    }

    /// @dev On a wallet's first mint: a referrer that holds an Agent ID (gated sales), is not the wallet and has minted
    ///      itself earns `inviteBonus` shares of quota. Marks the wallet as having minted. Shared with post-launch.
    function refer(
        IFlywheelPad.Sale storage s,
        mapping(address => mapping(address => IFlywheelPad.Account)) storage accounts,
        address token,
        address trader,
        IFlywheelPad.Account storage a,
        address referrer
    ) internal {
        if (a.minted) return;
        a.minted = true;
        if (referrer == address(0) || referrer == trader || s.inviteBonus == 0) return;
        IFlywheelPad.Account storage r = accounts[token][referrer];
        if (!r.minted) return;
        if (s.gate != address(0) && IERC721(s.gate).balanceOf(referrer) == 0) return;
        r.bonus += s.inviteBonus;
        emit IFlywheelPad.Referred(token, referrer, trader, s.inviteBonus);
    }

    /// @dev Pays `amount` of `quote` in: from BNB the pad already wrapped (`bnbIn`, WBNB sales only), else pulled from
    ///      msg.sender exactly (a fee-on-transfer quote is refused).
    function collect(address quote, uint256 amount, uint256 bnbIn) internal {
        if (bnbIn == 0) {
            PadCommon.pullExact(quote, amount);
        } else if (amount > bnbIn) {
            revert IFlywheelPad.BnbShort();
        }
    }

    /// @dev Tokens back from sell-backs (held by the pad) go out first; the rest is minted.
    function _giveTokens(address token, address to, uint256 amount) private {
        uint256 held = IERC20(token).balanceOf(address(this));
        uint256 fromHeld = held < amount ? held : amount;
        if (fromHeld != 0) IERC20(token).safeTransfer(to, fromHeld);
        if (amount > fromHeld) IFlyToken(token).padMint(to, amount - fromHeld);
    }

    function _filled(
        IGangLaunchpad.Config storage c,
        IFlywheelPad.Sale storage s,
        mapping(address => uint256) storage owedDev,
        IGangLaunchpad.Deps memory d,
        address token,
        bool early
    ) private {
        s.filledAt = uint64(block.timestamp);
        emit IFlywheelPad.Filled(token, s.sold, early);
        if (s.launchDelay == 0) _launch(c, s, owedDev, d, token);
    }

    /// @dev Pool at the mint price: the raise and the sold tokens, both less the dev's cut (which goes to the creator).
    ///      The creator's own shares carry no cut (internal audit B-M1: a cut on its own payments came back to it, so
    ///      minting and selling at once paid). Tokens held from sell-backs go in first; anything beyond the pool's share
    ///      goes to 0xdead.
    function _launch(
        IGangLaunchpad.Config storage c,
        IFlywheelPad.Sale storage s,
        mapping(address => uint256) storage owedDev,
        IGangLaunchpad.Deps memory d,
        address token
    ) private {
        s.launched = true;
        address quote = s.quote;
        uint256 principal = uint256(s.sold) * s.basePrice;
        uint256 cutShares = uint256(s.sold) - s.creatorShares;
        uint256 devCut = (cutShares * s.basePrice * s.devCutBps) / BPS;
        uint256 poolTokens = uint256(s.sold) * TOKENS_PER_SHARE - (cutShares * TOKENS_PER_SHARE * s.devCutBps) / BPS;
        uint256 poolQuote = principal - devCut;

        address migrator = c.migrator;
        IFlyToken(token).unlock(migrator);
        uint256 held = IERC20(token).balanceOf(address(this));
        if (held < poolTokens) IFlyToken(token).padMint(address(this), poolTokens - held);
        else if (held > poolTokens) IERC20(token).safeTransfer(DEAD, held - poolTokens);
        IERC20(token).safeTransfer(migrator, poolTokens);
        IERC20(quote).safeTransfer(migrator, poolQuote);
        address pair = IMigratorV2(migrator).migrate(token, quote, poolTokens, poolQuote);
        IFlyToken(token).setPair(pair);
        s.pair = pair;
        // protection and oracle on before the cut goes out: a quote calling the creator back (ERC777-style) must
        // not let it trade the new pool unprotected and seed the oracle (audit B-L1)
        uint256 cap = uint256(s.baseQuota) * s.windowCapMul * TOKENS_PER_SHARE;
        IFlyHandler(d.taxHandler).onLaunch(token, uint64(block.timestamp + s.window), s.gate, cap);
        payDev(owedDev, s, token, devCut);
        emit IFlywheelPad.Launched(token, pair, poolTokens, poolQuote, devCut);
    }

    /// @dev The creator's cut, pushed now; a failed push is owed (`claimDev`, anyone).
    function payDev(
        mapping(address => uint256) storage owedDev,
        IFlywheelPad.Sale storage s,
        address token,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        address quote = s.quote;
        (bool ok, bytes memory ret) = quote.call(abi.encodeCall(IERC20.transfer, (s.creator, amount)));
        if (ok && (ret.length == 0 ? quote.code.length > 0 : ret.length >= 32 && abi.decode(ret, (bool)))) {
            emit IFlywheelPad.DevPaid(token, s.creator, amount);
        } else {
            owedDev[token] += amount;
            emit IFlywheelPad.DevOwed(token, s.creator, amount);
        }
    }

    function _currentGate(IGangLaunchpad.Config storage c) private view returns (address) {
        if (!c.agentGateEnabled) return address(0);
        address reg = c.agentIdRegistry;
        if (reg == address(0)) revert IFlywheelPad.NotAgent();
        return reg;
    }

    function _requireAgent(address gate, address account) internal view {
        if (gate != address(0) && IERC721(gate).balanceOf(account) == 0) revert IFlywheelPad.NotAgent();
    }

    /// @dev A sell-back must not depend on the vault (it is the only way out); a starved call is refused (A-5).
    function _setShareOnExit(IGangLaunchpad.Deps memory d, address token, address user, uint256 share) private {
        uint256 gasBefore = gasleft();
        try SharedDividendVault(d.dividendVault).setShare(token, user, share) {}
        catch {
            if (gasleft() <= gasBefore / 63) revert IGangLaunchpad.OutOfGas();
            emit IFlywheelPad.ShareWriteFailed(token, user, share);
        }
    }

    /// @dev Nor on the fee bucket (R3-2): a refused exit fee is owed (`flushFees`).
    function _exitFeeToPlatform(
        mapping(address => uint256) storage owedFee,
        IGangLaunchpad.Deps memory d,
        address quote,
        uint256 fee
    ) private {
        if (fee == 0) return;
        IERC20(quote).forceApprove(d.platformBucket, fee);
        try PlatformFeeBucket(d.platformBucket).notifyAccrual(quote, fee) {}
        catch {
            IERC20(quote).forceApprove(d.platformBucket, 0);
            owedFee[quote] += fee;
            emit IFlywheelPad.FeeOwed(quote, fee);
        }
    }
}
