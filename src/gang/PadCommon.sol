// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {QuoteRegistry} from "../launchpad-v2/QuoteRegistry.sol";
import {IMigratorV2} from "../launchpad-v2/interfaces/IMigratorV2.sol";
import {PoolCheck} from "../launchpad-v2/PoolCheck.sol";
import {SharedDividendVault} from "../common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket as PlatformFeeBucket} from "../common/SharedPlatformFeeBucket.sol";
import {IGangLaunchpad} from "./interfaces/IGangLaunchpad.sol";
import {IGangPadToken, IGangTokenDeployer} from "./interfaces/IGangPadDeps.sol";

/// @title PadCommon — what the curve (V3) and 打新 paths of GangLaunchpad do the same way
/// @notice Internal library: compiled into CurveLogic, FairLogic and the pad itself; runs in the pad's context.
///         Quote rules, reference-pool pricing, the exact pull, the blocking fee push, and the migration into the pair.
library PadCommon {
    using SafeERC20 for IERC20;

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant BPS = 10_000;
    /// @dev The one vault floor of the pad (V3 `TAXED_MIN_SHARE` = 打新 `MIN_SHARE_BALANCE`): holders need a balance
    ///      strictly above it for dividend shares.
    uint256 internal constant MIN_SHARE = 10_000 ether;
    /// @dev QuoteRegistry rates are "15 BNB worth of quote" (V2 graduation target, 打新's REGISTRY_REF_BNB); toQuote
    ///      scales them to any BNB amount (a V3 graduation target, a 打新 raise).
    uint256 internal constant REF_BNB = 15 ether;
    uint256 internal constant MIN_REF_DEPTH_BNB = 1 ether;

    function poolCfg(IGangLaunchpad.Config storage c, address wbnb) internal view returns (PoolCheck.Cfg memory) {
        return PoolCheck.Cfg({wbnb: wbnb, v2Factory: c.pairFactory, v3Factory: c.v3Factory, twapWindow: c.twapWindow});
    }

    /// @dev The gate as set now (V3 checks every trade against it; 打新 snapshots it per sale).
    function isAgent(IGangLaunchpad.Config storage c, address account) internal view returns (bool) {
        if (!c.agentGateEnabled) return true;
        address gate = c.agentIdRegistry;
        return gate != address(0) && IERC721(gate).balanceOf(account) > 0;
    }

    /// @dev WBNB, or any 18-decimal ERC-20 (6 decimals would round holder dividends to 0 in the shared vault), priced
    ///      like LaunchpadV2: a QuoteRegistry fixed rate when set, else the creator's reference pool (`toQuote`).
    ///      2026-10-27 product decision: keep V2's reference-pool pricing (users are used to it), accepting internal
    ///      audit R2-1 again: a Pancake V2 pair (reserves) or a V3 pool without TWAP history is read at spot.
    ///      A fee-on-transfer quote is refused at its first pull (`pullExact`, audit 4).
    function requireQuote(IGangLaunchpad.Deps memory d, address quote) internal view {
        if (quote == d.wbnb) return;
        // low-level: a high-level call to an address without code reverts outside any try/catch
        (bool ok, bytes memory ret) = quote.staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        if (!ok || ret.length < 32 || abi.decode(ret, (uint256)) != 18) revert IGangLaunchpad.QuoteNotAllowed();
        // audit 4 (C-F3 / C-F4 / B-F1 / A-F2): never a token of this platform — a locked sibling pulled as a quote moves
        // past its wallet cap and lock; a dividend token held by the vault / bucket / a new pair earns rewards no one
        // can claim. TokenDeployer records every token of the pad (both kinds); the vault also knows registered ones.
        if (
            IGangTokenDeployer(d.tokenDeployer).isLaunchToken(quote)
                || SharedDividendVault(d.dividendVault).launchpadOf(quote) != address(0)
        ) revert IGangLaunchpad.QuoteNotAllowed();
    }

    /// @dev `bnbAmount` in quote units. V3 asks for its graduation target, 打新 for the raise; one rule set
    ///      (LaunchpadV2._lockGradAmt): WBNB → as is; QuoteRegistry rate (quoted for 15 BNB) → scaled; else the
    ///      creator's reference pool, bridged through bridgePoolOf when its other side is not WBNB, with a ≥ 1 BNB
    ///      depth floor.
    function toQuote(
        IGangLaunchpad.Config storage c,
        mapping(address => address) storage bridgePoolOf,
        IGangLaunchpad.Deps memory d,
        address quote,
        address refPool,
        uint256 bnbAmount
    ) internal view returns (uint256 amount, address refUsed) {
        if (quote == d.wbnb) return (bnbAmount, address(0));

        PoolCheck.Cfg memory cfg = poolCfg(c, d.wbnb);
        uint256 ov = QuoteRegistry(d.quoteRegistry).graduationAmount(quote);
        if (ov > 0) {
            if (refPool != address(0)) PoolCheck.counterOf(PoolCheck.inspect(cfg, refPool), quote);
            return (Math.mulDiv(ov, bnbAmount, REF_BNB), refPool);
        }

        if (refPool == address(0)) revert IGangLaunchpad.RefPoolRequired();
        PoolCheck.PoolInfo memory info = PoolCheck.inspect(cfg, refPool);
        address counter = PoolCheck.counterOf(info, quote);

        uint256 targetCounter;
        if (counter == d.wbnb) {
            targetCounter = bnbAmount;
        } else {
            address bridge = bridgePoolOf[counter];
            if (bridge == address(0)) revert IGangLaunchpad.NoBridgePool();
            PoolCheck.PoolInfo memory bInfo = PoolCheck.inspect(cfg, bridge);
            if (PoolCheck.counterOf(bInfo, counter) != d.wbnb) revert IGangLaunchpad.BridgeNotWbnb();
            targetCounter = PoolCheck.convert(cfg, bInfo, bridge, counter, bnbAmount);
        }

        uint256 minDepth = Math.mulDiv(targetCounter, MIN_REF_DEPTH_BNB, bnbAmount);
        if (PoolCheck.depthOf(info, refPool, counter) < minDepth) revert PoolCheck.ThinReferencePool();

        amount = PoolCheck.convert(cfg, info, refPool, quote, targetCounter);
        if (amount == 0) revert PoolCheck.GradAmtZero();
        refUsed = refPool;
    }

    /// @dev Audit 4 (A-F1 / B-F2 / C-F1/F2): a fee-on-transfer quote can't graduate / launch (the migrator forwards the
    ///      nominal amount) and under-funds the shared vault / bucket for every token on that quote: refused on the
    ///      first pull. msg.sender pays (the trader, or a router): the libraries run in the pad's call.
    function pullExact(address quote, uint256 amount) internal {
        uint256 before = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(quote).balanceOf(address(this)) - before != amount) revert IGangLaunchpad.FeeOnTransferQuote();
    }

    /// @dev Blocking push to the fee bucket: the V3 protocol fee and the 打新 mint fee (a refusing bucket fails the
    ///      trade). The 打新 exit fee is non-blocking instead (FairLogic, R3-2): withdraw must never depend on it.
    function toPlatform(IGangLaunchpad.Deps memory d, address quote, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(quote).forceApprove(d.platformBucket, amount);
        PlatformFeeBucket(d.platformBucket).notifyAccrual(quote, amount);
    }

    /// @dev Graduation / launch: one-shot on the token — unlock + exclude the migrator, the pair seeded and its LP
    ///      burned, then (taxed tokens only) the pair, where tax and share syncing start.
    function migrate(
        IGangLaunchpad.Config storage c,
        address token,
        address quote,
        uint256 tokenAmount,
        uint256 quoteAmount,
        bool withPair
    ) internal returns (address pair) {
        address migrator = c.migrator;
        IGangPadToken(token).unlock(migrator);
        IERC20(token).safeTransfer(migrator, tokenAmount);
        IERC20(quote).safeTransfer(migrator, quoteAmount);
        pair = IMigratorV2(migrator).migrate(token, quote, tokenAmount, quoteAmount);
        if (withPair) IGangPadToken(token).setPair(pair);
    }
}
