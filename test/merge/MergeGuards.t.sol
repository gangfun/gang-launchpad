// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GangFixture} from "../utils/GangFixture.sol";
import {GangToken} from "../../src/gang/GangToken.sol";
import {GangTaxHandler} from "../../src/gang/GangTaxHandler.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {CurveLogic} from "../../src/gang/CurveLogic.sol";
import {FairLogic} from "../../src/gang/FairLogic.sol";
import {PostGradHandlerBase} from "../../src/common/PostGradHandlerBase.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {PoolCheck} from "../../src/launchpad-v2/PoolCheck.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Interface freeze for the merge (merge plan §7.3, §10.2: written before the merged code). The downstream
///         (indexer, keeper, CLI, GangRouter) keeps working with zero changes only if every event keeps its topic0,
///         indexing and parameter names, every function its selector, and `curves` / `sales` their field order. The
///         event strings below are copied verbatim from the downstream code; the function and event lists of the old
///         contracts are taken from the origin/main (bad3142) build artifacts.
///         The rest are the merge-specific safety checks: kind isolation in the one handler, `reclaim` only on 打新
///         tokens, untaxed tokens never calling the handler, V3 and 打新 money kept apart in the one pad (§5.4), the
///         logic libraries not callable on their own, contract sizes, and the one share floor.
contract MergeGuardsTest is GangFixture {
    struct Ev {
        string name;
        string canonical;
        string[] types;
        string[] names;
        bool[] isIdx;
        uint256 nIndexed;
    }

    string internal constant PAD_ART = "/out/GangLaunchpad.sol/GangLaunchpad.json";
    string internal constant HANDLER_ART = "/out/GangTaxHandler.sol/GangTaxHandler.json";
    string internal constant TOKEN_ART = "/out/GangToken.sol/GangToken.json";
    string internal constant VAULT_ART = "/out/SharedDividendVault.sol/SharedDividendVault.json";

    /// @dev Below EIP-170 (24,576) with a 512-byte margin (merge plan §1.7).
    uint256 internal constant SIZE_LIMIT = 24_064;

    function setUp() public {
        _deployGang(address(this)); // this test is the handler's keeper (`process`)
    }

    // ================================================================ downstream strings (verbatim)
    /// @dev gangfun-server indexer/src/v3.js V3_PAD_EVENTS + fairMint.js FAIR_PAD_EVENTS, and the CLI's
    ///      skill/gang-cli/src/v3.js / fair.js PAD_ABI events. All emitted by the one pad.
    function _downstreamPadEvents() internal pure returns (string[] memory s) {
        s = new string[](16);
        // v3.js V3_PAD_EVENTS (CLI v3.js:53-57 has the same strings)
        s[0] =
            "event Created(address indexed token, address indexed creator, string name, string symbol, string logoURI, address indexed quote, address refPair, uint256 gradAmt)";
        s[1] =
            "event TaxConfigured(address indexed token, uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address indexed recipient)";
        s[2] = "event VirtualQuoteLocked(address indexed token, uint256 virtualQuote)";
        s[3] =
            "event Buy(address indexed token, address indexed buyer, uint256 quoteIn, uint256 protocolFee, uint256 tax, uint256 tokensOut, uint256 realQuote)";
        s[4] =
            "event Sell(address indexed token, address indexed seller, uint256 tokensIn, uint256 protocolFee, uint256 tax, uint256 quoteOut, uint256 realQuote)";
        s[5] =
            "event Graduated(address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount)";
        // fairMint.js FAIR_PAD_EVENTS (CLI fair.js:54-57 has the first four)
        s[6] =
            "event Created(address indexed token, address indexed creator, string name, string symbol, string logoURI, address indexed quote, address refPool, uint256 raiseBnb, uint256 sharePrice, uint256 capShares, uint256 holdBps, uint256 mintFeeBps, uint256 exitFeeBps)";
        s[7] =
            "event Minted(address indexed token, address indexed user, uint256 shares, uint256 cost, uint256 fee, uint256 userShares, uint256 sold)";
        s[8] =
            "event Withdrawn(address indexed token, address indexed user, uint256 shares, uint256 payout, uint256 fee, uint256 userShares, uint256 sold)";
        s[9] =
            "event Launched(address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount)";
        s[10] = "event ShareWriteFailed(address indexed token, address indexed user, uint256 share)";
        s[11] = "event FeeOwed(address indexed quote, uint256 amount)";
        s[12] = "event FeesFlushed(address indexed quote, uint256 amount)";
        // creator fee (70% of the curve's 1%, SPEC-CURVE-CREATOR-FEE-2026-10-31): new; the indexer and CLI add them
        s[13] = "event CreatorFeeAccrued(address indexed token, address indexed creator, uint256 amount)";
        s[14] =
            "event CreatorFeeClaimed(address indexed token, address indexed creator, address indexed to, uint256 amount)";
        // graduation target the creator picked (SPEC-CURVE-GRAD-TARGET-2026-10-31): new
        s[15] = "event GradTargetSet(address indexed token, uint256 gradBnb)";
    }

    /// @dev Events the indexer / CLI read from the one tax handler: v3.js V3_ROUTER_EVENTS, V3_REGISTRY_EVENTS,
    ///      postGrad.js POSTGRAD_HANDLER_EVENTS, KEEPER_EVENT_SIGS, SHARE_WRITE_FAILED, OUTER_TAX_PROCESSED_EVENTS,
    ///      fairMint.js FAIR_HANDLER_EVENTS (Disqualified), CLI v3.js:63-65.
    function _downstreamHandlerEvents() internal pure returns (string[] memory s) {
        s = new string[](17);
        // v3.js V3_ROUTER_EVENTS (CLI v3.js:63-65)
        s[0] =
            "event TaxDistributed(address indexed token, uint8 phase, uint256 amount, uint256 toPlatform, uint256 toDividend, uint256 toRecipient)";
        s[1] = "event TaxPaid(address indexed token, address indexed recipient, address indexed quote, uint256 amount)";
        s[2] = "event TaxOwed(address indexed token, address indexed recipient, address indexed quote, uint256 amount)";
        // v3.js V3_REGISTRY_EVENTS (the recipient whitelist is on the handler)
        s[3] = "event Listed(address indexed recipient, string label)";
        s[4] = "event Delisted(address indexed recipient)";
        // postGrad.js OUTER_TAX_PROCESSED_EVENTS: both overloads (V3: platformQuote; 打新: toHolders, toPlatform)
        s[5] =
            "event OuterTaxProcessed(address indexed token, address indexed quote, uint256 taxTokens, uint256 quoteOut, uint256 platformQuote)";
        s[6] =
            "event OuterTaxProcessed(address indexed token, address indexed quote, uint256 taxTokens, uint256 quoteOut, uint256 toHolders, uint256 toPlatform)";
        // fairMint.js FAIR_HANDLER_EVENTS
        s[7] = "event Disqualified(address indexed token, address indexed user, uint256 balance, uint256 baseline)";
        // postGrad.js POSTGRAD_HANDLER_EVENTS
        s[8] =
            "event TaxChunkSold(address indexed token, uint256 taxTokens, uint256 quoteOut, uint256 holderUnits, bool swapBack)";
        s[9] = "event HolderConversionDeferred(address indexed token, uint256 units, uint256 quote)";
        s[10] = "event PlatformOwed(address indexed quote, uint256 amount)";
        s[11] = "event PlatformFlushed(address indexed quote, uint256 amount)";
        // postGrad.js KEEPER_EVENT_SIGS
        s[12] = "event KeeperSet(address indexed keeper)";
        s[13] = "event KeeperProposed(address indexed keeper, uint256 eta)";
        s[14] = "event KeeperCancelled(address indexed keeper)";
        // postGrad.js SHARE_WRITE_FAILED (the handler's guarded share writes)
        s[15] = "event ShareWriteFailed(address indexed token, address indexed user, uint256 share)";
        // postGrad.js reads the token's SwapBackFailed; the handler side is TaxAccrued (kept by the base, old ABI)
        s[16] =
            "event TaxAccrued(address indexed token, address indexed from, address indexed to, uint256 taxAmount, uint256 accrued)";
    }

    /// @dev postGrad.js SWAPBACK_FAILED (emitted by the token).
    function _downstreamTokenEvents() internal pure returns (string[] memory s) {
        s = new string[](1);
        s[0] = "event SwapBackFailed()";
    }

    /// @dev fairMint.js FAIR_VAULT_EVENTS, CLI steps.js:143 / fair.js:67 (the vault is unchanged by the merge).
    function _downstreamVaultEvents() internal pure returns (string[] memory s) {
        s = new string[](1);
        s[0] = "event DividendClaimed(address indexed token, address indexed user, uint256 amount)";
    }

    // ================================================================ origin/main ABI (bad3142 build artifacts)
    /// @dev Function lists: the merged contract must keep every one (same signature = same selector), except the ones
    ///      the plan removes on purpose (listed in `test_merge_removedSelectors`).
    // PAD: LaunchpadV3+FairMintPad at origin/main, minus []
    function _oldPADFns() internal pure returns (string[] memory s) {
        s = new string[](89);
        s[0] = "BPS()";
        s[1] = "CURVE_SUPPLY()";
        s[2] = "LP_SUPPLY()";
        s[3] = "MAX_CAP_BPS()";
        s[4] = "MAX_EXIT_FEE_BPS()";
        s[5] = "MAX_HOLD_BPS()";
        s[6] = "MAX_MINT_FEE_BPS()";
        s[7] = "MAX_PER_WALLET()";
        s[8] = "MAX_RAISE_BNB()";
        s[9] = "MAX_TAX_BPS()";
        s[10] = "MINT_SUPPLY()";
        s[11] = "MIN_CAP_BPS()";
        s[12] = "MIN_FEE_BPS()";
        s[13] = "MIN_GRAD_AMT()";
        s[14] = "MIN_HOLD_BPS()";
        s[15] = "MIN_RAISE_BNB()";
        s[16] = "MIN_REF_DEPTH_BNB()";
        s[17] = "MIN_SHARE_BALANCE()";
        s[18] = "MIN_TAX_BPS()";
        s[19] = "PLATFORM_TAX_BPS()";
        s[20] = "PROTOCOL_FEE_BPS()";
        s[21] = "REGISTRY_REF_BNB()";
        s[22] = "STALE_AFTER()";
        s[23] = "STALE_STEP()";
        s[24] = "TARGET_GRAD_BNB()";
        s[25] = "TAXED_MIN_SHARE()";
        s[26] = "TOKENS_PER_SHARE()";
        s[27] = "TOTAL_SHARES()";
        s[28] = "TOTAL_SUPPLY()";
        s[29] = "VIRTUAL_TOKEN()";
        s[30] = "acceptOwnership()";
        s[31] = "agentGateEnabled()";
        s[32] = "agentIdRegistry()";
        s[33] = "allTokens(uint256)";
        s[34] = "baselineOf(address,address)";
        s[35] = "bridgePoolOf(address)";
        s[36] = "buy(address,uint256,uint256)";
        s[37] = "buyFor(address,address,uint256,uint256)";
        s[38] = "checkConfig((uint256,uint16,uint16,uint16,uint16),uint256)";
        s[39] = "checkTaxConfig((uint16,uint16,uint16,address))";
        s[40] = "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))";
        s[41] = "create(string,string,string,string,address,address,(uint256,uint16,uint16,uint16,uint16),uint256)";
        s[42] = "curves(address)";
        s[43] = "dividendVault()";
        s[44] = "exitFeeBpsOf(address)";
        s[45] = "flushFees(address)";
        s[46] = "gradAmtOf(address)";
        s[47] = "graduationAmountOf(address,address)";
        s[48] = "graduationRemaining(address)";
        s[49] = "holdBpsOf(address)";
        s[50] = "isAgent(address)";
        s[51] = "logoURIOf(address)";
        s[52] = "migrator()";
        s[53] = "mint(address,uint256,uint256)";
        s[54] = "mintFor(address,address,uint256,uint256)";
        s[55] = "owedFee(address)";
        s[56] = "owner()";
        s[57] = "pairFactory()";
        s[58] = "pendingOwner()";
        s[59] = "platformBucket()";
        s[60] = "positions(address,address)";
        s[61] = "previewCreate(address,address,uint256)";
        s[62] = "previewMint(address,address,uint256)";
        s[63] = "previewWithdraw(address,address,uint256)";
        s[64] = "quoteRegistry()";
        s[65] = "renounceOwnership()";
        s[66] = "routers(address)";
        s[67] = "sales(address)";
        s[68] = "sell(address,uint256,uint256)";
        s[69] = "setAgentGate(bool,address)";
        s[70] = "setBridgePool(address,address)";
        s[71] = "setMigrator(address)";
        s[72] = "setPairFactory(address)";
        s[73] = "setRouter(address,bool)";
        s[74] = "setTwapWindow(uint32)";
        s[75] = "setV3Factory(address)";
        s[76] = "setWalletCapEnabled(bool)";
        s[77] = "status(address)";
        s[78] = "taxConfigOf(address)";
        s[79] = "taxHandler()";
        s[80] = "tokenCount()";
        s[81] = "tokenDeployer()";
        s[82] = "transferOwnership(address)";
        s[83] = "twapWindow()";
        s[84] = "v3Factory()";
        s[85] = "walletCapEnabled()";
        s[86] = "walletRoom(address,address)";
        s[87] = "wbnb()";
        s[88] = "withdraw(address,uint256,uint256)";
    }

    function _oldPADEvents() internal pure returns (string[] memory s) {
        s = new string[](23);
        s[0] = "event AgentGateUpdated(bool enabled, address registry)"; // FairMintPad
        s[1] = "event BridgePoolSet(address indexed asset, address indexed pool)"; // FairMintPad
        s[2] =
            "event Buy(address indexed token, address indexed buyer, uint256 quoteIn, uint256 protocolFee, uint256 tax, uint256 tokensOut, uint256 realQuote)"; // LaunchpadV3
        s[3] =
            "event Created(address indexed token, address indexed creator, string name, string symbol, string logoURI, address indexed quote, address refPair, uint256 gradAmt)"; // LaunchpadV3
        s[4] =
            "event Created(address indexed token, address indexed creator, string name, string symbol, string logoURI, address indexed quote, address refPool, uint256 raiseBnb, uint256 sharePrice, uint256 capShares, uint256 holdBps, uint256 mintFeeBps, uint256 exitFeeBps)"; // FairMintPad
        s[5] = "event FeeOwed(address indexed quote, uint256 amount)"; // FairMintPad
        s[6] = "event FeesFlushed(address indexed quote, uint256 amount)"; // FairMintPad
        s[7] =
            "event Graduated(address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount)"; // LaunchpadV3
        s[8] =
            "event Launched(address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount)"; // FairMintPad
        s[9] = "event MigratorSet(address indexed migrator)"; // FairMintPad
        s[10] =
            "event Minted(address indexed token, address indexed user, uint256 shares, uint256 cost, uint256 fee, uint256 userShares, uint256 sold)"; // FairMintPad
        s[11] = "event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)"; // FairMintPad
        s[12] = "event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)"; // FairMintPad
        s[13] = "event PairFactorySet(address indexed factory)"; // LaunchpadV3
        s[14] = "event RouterSet(address indexed router, bool enabled)"; // FairMintPad
        s[15] =
            "event Sell(address indexed token, address indexed seller, uint256 tokensIn, uint256 protocolFee, uint256 tax, uint256 quoteOut, uint256 realQuote)"; // LaunchpadV3
        s[16] = "event ShareWriteFailed(address indexed token, address indexed user, uint256 share)"; // FairMintPad
        s[17] =
            "event TaxConfigured(address indexed token, uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address indexed recipient)"; // LaunchpadV3
        s[18] = "event TwapWindowUpdated(uint32 window)"; // FairMintPad
        s[19] = "event V3FactorySet(address indexed factory)"; // FairMintPad
        s[20] = "event VirtualQuoteLocked(address indexed token, uint256 virtualQuote)"; // LaunchpadV3
        s[21] = "event WalletCapUpdated(bool enabled)"; // LaunchpadV3
        s[22] =
            "event Withdrawn(address indexed token, address indexed user, uint256 shares, uint256 payout, uint256 fee, uint256 userShares, uint256 sold)"; // FairMintPad
    }

    // HANDLER: TaxHandlerV3+HolderRewardHandler at origin/main, minus ['distribute(address,uint256,uint256,uint8)', 'notifyTax(address,address,address,uint256)', 'pad()', 'previewSplit(address,uint256,uint256)', 'register(address,address,address,uint16)', 'setPad(address)']
    function _oldHANDLERFns() internal pure returns (string[] memory s) {
        s = new string[](61);
        s[0] = "BPS()";
        s[1] = "CHUNK_MAX_BPS()";
        s[2] = "DEX_FEE_DEN()";
        s[3] = "DEX_FEE_NUM()";
        s[4] = "DEX_ROUTER_DELAY()";
        s[5] = "HOLDER_SHARE_BPS()";
        s[6] = "KEEPER_DELAY()";
        s[7] = "MAX_PRICE_DROP_BPS()";
        s[8] = "PLATFORM_TAX_BPS()";
        s[9] = "SWAP_BACK_SELL_BPS()";
        s[10] = "SWAP_BACK_SLIPPAGE_BPS()";
        s[11] = "acceptDexRouter()";
        s[12] = "acceptKeeper()";
        s[13] = "acceptOwnership()";
        s[14] = "accruedPlatformTax(address)";
        s[15] = "accruedTax(address)";
        s[16] = "cancelDexRouter()";
        s[17] = "cancelKeeper()";
        s[18] = "delist(address)";
        s[19] = "dexRouter()";
        s[20] = "dexRouterEta()";
        s[21] = "dividendVault()";
        s[22] = "eligibleShare(address,address)";
        s[23] = "entries(address)";
        s[24] = "flushHolders(address)";
        s[25] = "flushPlatform(address)";
        s[26] = "isListed(address)";
        s[27] = "isOut(address,address)";
        s[28] = "keeper()";
        s[29] = "keeperEta()";
        s[30] = "keeperSet()";
        s[31] = "launchpad()";
        s[32] = "list(address,string)";
        s[33] = "maxChunk(address)";
        s[34] = "notifyTax(address,address,address,uint256,uint256)"; // origin/main: rateBps uint16 (widened on purpose)
        s[35] = "owedOf(address)";
        s[36] = "owedPlatformOf(address)";
        s[37] = "owedTotalOf(address)";
        s[38] = "owner()";
        s[39] = "pendingDexRouter()";
        s[40] = "pendingHolderQuote(address)";
        s[41] = "pendingHolderUnits(address)";
        s[42] = "pendingKeeper()";
        s[43] = "pendingOwner()";
        s[44] = "platformBucket()";
        s[45] = "previewSell(address,uint256)";
        s[46] = "previewSellNextBlock(address,uint256)";
        s[47] = "process(address,uint256,uint256)";
        s[48] = "proposeDexRouter(address)";
        s[49] = "proposeKeeper(address)";
        s[50] = "recipients()";
        s[51] = "refOf(address)";
        s[52] = "release(address)";
        s[53] = "renounceOwnership()";
        s[54] = "routeOf(address)";
        s[55] = "setKeeper(address)";
        s[56] = "setLaunchpad(address)";
        s[57] = "swapBack(address,uint256)";
        s[58] = "syncShares(address,address,address)";
        s[59] = "transferOwnership(address)";
        s[60] = "windowOf(address)";
    }

    function _oldHANDLEREvents() internal pure returns (string[] memory s) {
        s = new string[](24);
        s[0] = "event Delisted(address indexed recipient)"; // TaxHandlerV3
        s[1] = "event DexRouterCancelled(address indexed router)"; // HolderRewardHandler
        s[2] = "event DexRouterProposed(address indexed router, uint256 eta)"; // HolderRewardHandler
        s[3] = "event DexRouterSet(address indexed router)"; // HolderRewardHandler
        s[4] = "event Disqualified(address indexed token, address indexed user, uint256 balance, uint256 baseline)"; // HolderRewardHandler
        s[5] = "event HolderConversionDeferred(address indexed token, uint256 units, uint256 quote)"; // HolderRewardHandler
        s[6] = "event KeeperCancelled(address indexed keeper)"; // HolderRewardHandler
        s[7] = "event KeeperProposed(address indexed keeper, uint256 eta)"; // HolderRewardHandler
        s[8] = "event KeeperSet(address indexed keeper)"; // HolderRewardHandler
        s[9] = "event LaunchpadSet(address indexed launchpad)"; // TaxHandlerV3
        s[10] = "event Listed(address indexed recipient, string label)"; // TaxHandlerV3
        s[11] =
            "event OuterTaxProcessed(address indexed token, address indexed quote, uint256 taxTokens, uint256 quoteOut, uint256 platformQuote)"; // TaxHandlerV3
        s[12] =
            "event OuterTaxProcessed(address indexed token, address indexed quote, uint256 taxTokens, uint256 quoteOut, uint256 toHolders, uint256 toPlatform)"; // HolderRewardHandler
        s[13] = "event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)"; // HolderRewardHandler
        s[14] = "event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)"; // HolderRewardHandler
        s[15] = "event PlatformFlushed(address indexed quote, uint256 amount)"; // HolderRewardHandler
        s[16] = "event PlatformOwed(address indexed quote, uint256 amount)"; // HolderRewardHandler
        s[17] =
            "event RouteRegistered(address indexed token, address quote, address indexed recipient, uint16 dividendBps)"; // TaxHandlerV3
        s[18] = "event ShareWriteFailed(address indexed token, address indexed user, uint256 share)"; // HolderRewardHandler
        s[19] =
            "event TaxAccrued(address indexed token, address indexed from, address indexed to, uint256 taxAmount, uint256 accrued)"; // HolderRewardHandler
        s[20] =
            "event TaxChunkSold(address indexed token, uint256 taxTokens, uint256 quoteOut, uint256 holderUnits, bool swapBack)"; // HolderRewardHandler
        s[21] =
            "event TaxDistributed(address indexed token, uint8 phase, uint256 amount, uint256 toPlatform, uint256 toDividend, uint256 toRecipient)"; // TaxHandlerV3
        s[22] = "event TaxOwed(address indexed token, address indexed recipient, address indexed quote, uint256 amount)"; // TaxHandlerV3
        s[23] = "event TaxPaid(address indexed token, address indexed recipient, address indexed quote, uint256 amount)"; // TaxHandlerV3
    }

    // TOKEN: TaxLaunchTokenV3+FairToken+LaunchTokenV3 at origin/main, minus ['TAX_BPS()', 'unlock()']
    function _oldTOKENFns() internal pure returns (string[] memory s) {
        s = new string[](24);
        s[0] = "BPS()";
        s[1] = "SWAP_BACK_GAS()";
        s[2] = "TOTAL_SUPPLY()";
        s[3] = "allowance(address,address)";
        s[4] = "approve(address,uint256)";
        s[5] = "balanceOf(address)";
        s[6] = "buyTaxBps()";
        s[7] = "contractURI()";
        s[8] = "decimals()";
        s[9] = "isExcluded(address)";
        s[10] = "launchpad()";
        s[11] = "locked()";
        s[12] = "metaURI()";
        s[13] = "name()";
        s[14] = "pair()";
        s[15] = "reclaim(address,uint256)";
        s[16] = "sellTaxBps()";
        s[17] = "setPair(address)";
        s[18] = "symbol()";
        s[19] = "taxHandler()";
        s[20] = "totalSupply()";
        s[21] = "transfer(address,uint256)";
        s[22] = "transferFrom(address,address,uint256)";
        s[23] = "unlock(address)";
    }

    function _oldTOKENEvents() internal pure returns (string[] memory s) {
        s = new string[](8);
        s[0] = "event Approval(address indexed owner, address indexed spender, uint256 value)"; // LaunchTokenV3
        s[1] = "event Excluded(address indexed account, bool excluded)"; // FairToken
        s[2] = "event OuterTax(address indexed from, address indexed to, uint256 taxed, uint256 net)"; // FairToken
        s[3] = "event PairSet(address indexed pair)"; // FairToken
        s[4] = "event SwapBackFailed()"; // FairToken
        s[5] = "event TaxHandlerSet(address indexed handler)"; // FairToken
        s[6] = "event Transfer(address indexed from, address indexed to, uint256 value)"; // LaunchTokenV3
        s[7] = "event Unlocked()"; // LaunchTokenV3
    }

    function _oldVAULTEvents() internal pure returns (string[] memory s) {
        s = new string[](12);
        s[0] = "event DividendBatchSettled(address indexed token, uint256 indexed batch, uint256 units, uint256 quote)"; // SharedDividendVault
        s[1] = "event DividendClaimed(address indexed token, address indexed user, uint256 amount)"; // SharedDividendVault
        s[2] = "event DividendConverted(address indexed token, uint256 units, uint256 quote)"; // SharedDividendVault
        s[3] = "event DividendUnitsAccrued(address indexed token, uint256 indexed batch, uint256 units)"; // SharedDividendVault
        s[4] = "event Excluded(address indexed account, bool excluded)"; // SharedDividendVault
        s[5] = "event LaunchpadSet(address indexed launchpad, bool enabled)"; // SharedDividendVault
        s[6] = "event MinimumShareBalanceUpdated(address indexed launchpad, uint256 amount)"; // SharedDividendVault
        s[7] = "event OperatorSet(address indexed account, address indexed launchpad)"; // SharedDividendVault
        s[8] = "event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)"; // SharedDividendVault
        s[9] = "event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)"; // SharedDividendVault
        s[10] = "event ShareUpdated(address indexed token, address indexed user, uint256 share)"; // SharedDividendVault
        s[11] = "event TokenRegistered(address indexed token, address indexed quote, address indexed launchpad)"; // SharedDividendVault
    }

    // ================================================================ parsing helpers
    /// @dev viem human-readable event ("event Name(type [indexed] name, ...)") → name, canonical signature, params.
    function _parse(string memory s) internal pure returns (Ev memory e) {
        string[] memory a = vm.split(s, "(");
        e.name = vm.trim(vm.replace(a[0], "event ", ""));
        string memory params = vm.trim(vm.replace(a[1], ")", ""));
        if (bytes(params).length == 0) {
            e.types = new string[](0);
            e.names = new string[](0);
            e.isIdx = new bool[](0);
            e.canonical = string.concat(e.name, "()");
            return e;
        }
        string[] memory ps = vm.split(params, ",");
        e.types = new string[](ps.length);
        e.names = new string[](ps.length);
        e.isIdx = new bool[](ps.length);
        string memory canon = string.concat(e.name, "(");
        for (uint256 i = 0; i < ps.length; i++) {
            string[] memory w = vm.split(vm.trim(ps[i]), " ");
            e.types[i] = w[0];
            e.names[i] = w[w.length - 1];
            e.isIdx[i] = w.length == 3 && keccak256(bytes(w[1])) == keccak256("indexed");
            if (e.isIdx[i]) e.nIndexed++;
            canon = string.concat(canon, i == 0 ? "" : ",", w[0]);
        }
        e.canonical = string.concat(canon, ")");
    }

    function _topic0(Ev memory e) internal pure returns (bytes32) {
        return keccak256(bytes(e.canonical));
    }

    function _art(string memory rel) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), rel));
    }

    /// @dev The ABI's event entries, each cut to `Name","inputs":[...]` (split once per artifact: the JSON is large).
    function _eventEntries(string memory json) internal pure returns (string[] memory es) {
        string memory abiPart = vm.split(json, '"bytecode":')[0];
        string[] memory raw = vm.split(abiPart, '{"type":"event","name":"');
        es = new string[](raw.length - 1);
        for (uint256 k = 1; k < raw.length; k++) {
            es[k - 1] = vm.split(raw[k], '"anonymous"')[0];
        }
    }

    /// @dev True when the ABI has this event with the same parameter names, types and indexing, in order (any one of
    ///      the overloads of that name).
    function _abiHasEvent(string[] memory es, Ev memory e) internal pure returns (bool) {
        string memory head = string.concat(e.name, '","inputs":[');
        for (uint256 k = 0; k < es.length; k++) {
            if (vm.indexOf(es[k], head) != 0) continue;
            string[] memory pieces = vm.split(es[k], '{"name":"');
            if (pieces.length - 1 != e.types.length) continue;
            bool ok = true;
            for (uint256 i = 0; i < e.types.length; i++) {
                string memory want = string.concat(
                    e.names[i], '","type":"', e.types[i], '","indexed":', e.isIdx[i] ? "true" : "false", ","
                );
                if (vm.indexOf(pieces[i + 1], want) != 0) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    function _methods(string memory json) internal pure returns (string memory) {
        return vm.split(vm.split(json, '"methodIdentifiers":{')[1], "}")[0];
    }

    function _hasMethod(string memory methods, string memory sig) internal pure returns (bool) {
        return vm.contains(methods, string.concat('"', sig, '":"'));
    }

    function _hex4(bytes4 sel) internal pure returns (string memory) {
        return vm.replace(vm.toString(abi.encodePacked(sel)), "0x", "");
    }

    /// @dev `sig` hashes to the selector origin/main had, and the merged contract has exactly that entry.
    function _sel(string memory methods, string memory sig, bytes4 sel) internal pure {
        assertEq(bytes4(keccak256(bytes(sig))), sel, string.concat("selector drift: ", sig));
        assertTrue(
            vm.contains(methods, string.concat('"', sig, '":"', _hex4(sel), '"')), string.concat("missing fn: ", sig)
        );
    }

    function _checkEvents(string[] memory es, string[] memory list, string memory who) internal pure {
        for (uint256 i = 0; i < list.length; i++) {
            Ev memory e = _parse(list[i]);
            assertTrue(_abiHasEvent(es, e), string.concat(who, " ABI lacks / changed: ", list[i]));
        }
    }

    function _checkFns(string memory methods, string[] memory list, string memory who) internal pure {
        for (uint256 i = 0; i < list.length; i++) {
            assertTrue(_hasMethod(methods, list[i]), string.concat(who, " lost: ", list[i]));
        }
    }

    function _word(bytes memory ret, uint256 i) internal pure returns (uint256 w) {
        assembly {
            w := mload(add(ret, add(32, mul(i, 32))))
        }
    }

    // ================================================================ 1. interface freeze
    /// @notice topic0 + indexing + parameter names of every event the downstream decodes, and of every event the old
    ///         contracts had: the merged contracts' ABIs must carry each one unchanged. (topic0 = keccak of the
    ///         canonical signature, which the ABI entry fixes; the names matter because viem decodes args by name.)
    function test_merge_eventTopics() public view {
        string[] memory padJ = _eventEntries(_art(PAD_ART));
        string[] memory hJ = _eventEntries(_art(HANDLER_ART));
        string[] memory tJ = _eventEntries(_art(TOKEN_ART));
        string[] memory vJ = _eventEntries(_art(VAULT_ART));

        _checkEvents(padJ, _downstreamPadEvents(), "pad");
        _checkEvents(hJ, _downstreamHandlerEvents(), "handler");
        _checkEvents(tJ, _downstreamTokenEvents(), "token");
        _checkEvents(vJ, _downstreamVaultEvents(), "vault");

        _checkEvents(padJ, _oldPADEvents(), "pad (origin/main)");
        _checkEvents(hJ, _oldHANDLEREvents(), "handler (origin/main)");
        _checkEvents(tJ, _oldTOKENEvents(), "token (origin/main)");
        _checkEvents(vJ, _oldVAULTEvents(), "vault (origin/main)");

        // the overloads keep their old topic0 (pinned, from origin/main logs)
        assertEq(
            _topic0(_parse(_downstreamPadEvents()[0])),
            keccak256("Created(address,address,string,string,string,address,address,uint256)")
        );
        assertEq(
            _topic0(_parse(_downstreamPadEvents()[6])),
            keccak256(
                "Created(address,address,string,string,string,address,address,uint256,uint256,uint256,uint256,uint256,uint256)"
            )
        );
        assertEq(
            _topic0(_parse(_downstreamHandlerEvents()[5])),
            keccak256("OuterTaxProcessed(address,address,uint256,uint256,uint256)")
        );
        assertEq(
            _topic0(_parse(_downstreamHandlerEvents()[6])),
            keccak256("OuterTaxProcessed(address,address,uint256,uint256,uint256,uint256)")
        );
        // the Solidity declarations the contracts emit with (non-overloaded ones) hash the same
        assertEq(IGangLaunchpad.Buy.selector, _topic0(_parse(_downstreamPadEvents()[3])));
        assertEq(IGangLaunchpad.Sell.selector, _topic0(_parse(_downstreamPadEvents()[4])));
        assertEq(IGangLaunchpad.Minted.selector, _topic0(_parse(_downstreamPadEvents()[7])));
        assertEq(IGangLaunchpad.Withdrawn.selector, _topic0(_parse(_downstreamPadEvents()[8])));
        assertEq(GangTaxHandler.TaxDistributed.selector, _topic0(_parse(_downstreamHandlerEvents()[0])));
        assertEq(GangTaxHandler.Disqualified.selector, _topic0(_parse(_downstreamHandlerEvents()[7])));
        assertEq(GangToken.SwapBackFailed.selector, keccak256("SwapBackFailed()"));
    }

    /// @notice The logs actually emitted in a full round (both kinds, both creates, curve trades, graduation, mints,
    ///         a sell-back, launch, pool trades with tax, keeper process, owed + release, claim) have a known topic0
    ///         for their emitter and the indexing the downstream decodes them with (topics.length == indexed + 1).
    ///         Catches a library emitting its own variant of an event the pad's ABI declares differently.
    function test_merge_eventTopics_emitted() public {
        vm.recordLogs();
        _fullRound();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Ev[] memory padEv = _parseAll(_cat(_downstreamPadEvents(), _oldPADEvents()));
        Ev[] memory hEv = _parseAll(_cat(_downstreamHandlerEvents(), _oldHANDLEREvents()));
        Ev[] memory tEv = _parseAll(_cat(_downstreamTokenEvents(), _oldTOKENEvents()));
        Ev[] memory vEv = _parseAll(_cat(_downstreamVaultEvents(), _oldVAULTEvents()));

        bytes32[] memory seen = new bytes32[](logs.length);
        uint256 nSeen;
        for (uint256 i = 0; i < logs.length; i++) {
            address a = logs[i].emitter;
            Ev[] memory set;
            if (a == address(pad)) set = padEv;
            else if (a == address(handler)) set = hEv;
            else if (a == address(divVault)) set = vEv;
            else if (_isGangToken(a)) set = tEv;
            else continue;
            bytes32 t0 = logs[i].topics[0];
            bool known;
            for (uint256 k = 0; k < set.length; k++) {
                if (_topic0(set[k]) == t0) {
                    known = true;
                    assertEq(logs[i].topics.length, set[k].nIndexed + 1, string.concat("indexing: ", set[k].canonical));
                    break;
                }
            }
            assertTrue(known, string.concat("unknown event from ", vm.toString(a), ": ", vm.toString(t0)));
            seen[nSeen++] = t0;
        }

        // the ones the indexer builds its tables from must all show up in this round
        string[] memory must = new string[](16);
        must[0] = _downstreamPadEvents()[0]; // Created (V3)
        must[1] = _downstreamPadEvents()[1]; // TaxConfigured
        must[2] = _downstreamPadEvents()[3]; // Buy
        must[3] = _downstreamPadEvents()[4]; // Sell
        must[4] = _downstreamPadEvents()[5]; // Graduated
        must[5] = _downstreamPadEvents()[6]; // Created (打新)
        must[6] = _downstreamPadEvents()[7]; // Minted
        must[7] = _downstreamPadEvents()[8]; // Withdrawn
        must[8] = _downstreamPadEvents()[9]; // Launched
        must[9] = _downstreamHandlerEvents()[0]; // TaxDistributed
        must[10] = _downstreamHandlerEvents()[1]; // TaxPaid
        must[11] = _downstreamHandlerEvents()[2]; // TaxOwed
        must[12] = _downstreamHandlerEvents()[5]; // OuterTaxProcessed (V3)
        must[13] = _downstreamHandlerEvents()[6]; // OuterTaxProcessed (打新)
        must[14] = _downstreamHandlerEvents()[8]; // TaxChunkSold
        must[15] = _downstreamVaultEvents()[0]; // DividendClaimed
        for (uint256 m = 0; m < must.length; m++) {
            bytes32 t0 = _topic0(_parse(must[m]));
            bool found;
            for (uint256 i = 0; i < nSeen && !found; i++) {
                found = seen[i] == t0;
            }
            assertTrue(found, string.concat("not emitted in the round: ", must[m]));
        }
    }

    /// @notice Selectors the CLI, the router, the keeper and the token→handler hooks call are the origin/main ones
    ///         (hex pinned from the bad3142 artifacts), and every other function the old contracts had is still there.
    function test_merge_selectors() public view {
        string memory P = _methods(_art(PAD_ART));
        string memory H = _methods(_art(HANDLER_ART));
        string memory T = _methods(_art(TOKEN_ART));

        // pad — V3 (LaunchpadV3)
        _sel(P, "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))", 0x63071473);
        _sel(P, "buy(address,uint256,uint256)", 0xa59ac6dd);
        _sel(P, "buyFor(address,address,uint256,uint256)", 0xf6819293);
        _sel(P, "sell(address,uint256,uint256)", 0x6a272462);
        _sel(P, "curves(address)", 0x2cc3dc6e);
        _sel(P, "taxConfigOf(address)", 0xede5d50a);
        _sel(P, "checkTaxConfig((uint16,uint16,uint16,address))", 0x68c9f7e0);
        _sel(P, "walletRoom(address,address)", 0x5a955a03);
        _sel(P, "graduationRemaining(address)", 0xa751cd9f);
        _sel(P, "graduationAmountOf(address,address)", 0x0d5d3c4d);
        _sel(P, "isAgent(address)", 0x1ffbb064);
        // pad — 打新 (FairMintPad)
        _sel(
            P,
            "create(string,string,string,string,address,address,(uint256,uint16,uint16,uint16,uint16),uint256)",
            0xe127863c
        );
        _sel(P, "mint(address,uint256,uint256)", 0x156e29f6);
        _sel(P, "mintFor(address,address,uint256,uint256)", 0x27d3f054);
        _sel(P, "withdraw(address,uint256,uint256)", 0xb5c5f672);
        _sel(P, "flushFees(address)", 0x66ab383d);
        _sel(P, "sales(address)", 0xc6b9f06a);
        _sel(P, "positions(address,address)", 0x4bd21445);
        _sel(P, "previewMint(address,address,uint256)", 0x23c5b7ed);
        _sel(P, "previewWithdraw(address,address,uint256)", 0xe3537a5e);
        _sel(P, "previewCreate(address,address,uint256)", 0xea40f135);
        _sel(P, "checkConfig((uint256,uint16,uint16,uint16,uint16),uint256)", 0xb12421b0);
        _sel(P, "exitFeeBpsOf(address)", 0x152ca9e0);
        _sel(P, "status(address)", 0x645b8b1b);
        _sel(P, "baselineOf(address,address)", 0x67de170e);
        _sel(P, "holdBpsOf(address)", 0xff7a5727);
        // handler (TaxHandlerV3 + HolderRewardHandler)
        _sel(H, "process(address,uint256,uint256)", 0x89085312);
        _sel(H, "release(address)", 0x19165587);
        _sel(H, "swapBack(address,uint256)", 0x5050282c);
        _sel(H, "syncShares(address,address,address)", 0xb4baa247);
        // notifyTax: the one 5-argument hook, rateBps widened to uint256 on purpose (IGangTaxHandler). Only the token
        // calls it (no downstream), so the new selector is pinned here and `test_merge_tokenCallsHandlerHooks` checks
        // that GangToken really calls this one.
        _sel(H, "notifyTax(address,address,address,uint256,uint256)", 0x689b638e);
        _sel(H, "owedOf(address)", 0x228db984);
        _sel(H, "routeOf(address)", 0x988c8dcb);
        _sel(H, "isListed(address)", 0xf794062e);
        _sel(H, "entries(address)", 0xf29ee125);
        _sel(H, "accruedTax(address)", 0xbaabea44);
        _sel(H, "maxChunk(address)", 0x64cd8c5c);
        _sel(H, "previewSell(address,uint256)", 0xe5f0f5cc);
        _sel(H, "previewSellNextBlock(address,uint256)", 0x3d96b951);
        _sel(H, "isOut(address,address)", 0xb5d110d4);
        _sel(H, "eligibleShare(address,address)", 0x8613c4a0);
        // token
        _sel(T, "unlock(address)", 0x2f6c493c);
        _sel(T, "setPair(address)", 0x8187f516);
        _sel(T, "reclaim(address,uint256)", 0x8bd317eb);

        // every other function of the old contracts
        _checkFns(P, _oldPADFns(), "pad");
        _checkFns(H, _oldHANDLERFns(), "handler");
        _checkFns(T, _oldTOKENFns(), "token");

        // new on purpose (merge plan §1.3 / §2.2 / §1.2)
        assertTrue(_hasMethod(P, "kindOf(address)"), "pad.kindOf");
        // 2026-10-27 (AUDIT-BRIEF §22): the creator-aware preflight is an addition; checkTaxConfig keeps 0x68c9f7e0
        _sel(P, "checkTaxConfigFor(address,(uint16,uint16,uint16,address))", 0x1020b11c);
        // 2026-10-27 (AUDIT-BRIEF §23): aggregator sells / withdraws (listed router, trader == tx.origin, allowance)
        _sel(P, "sellFor(address,address,uint256,uint256)", 0x9d10cdb1);
        _sel(P, "withdrawFor(address,address,uint256,uint256)", 0x60382b4e);
        _sel(T, "pullFor(address,address,uint256)", 0x7d18ac71);
        assertTrue(_hasMethod(H, "register(address,address,address,uint16,uint8)"), "handler.register(kind)");
        assertTrue(_hasMethod(T, "reclaimable()"), "token.reclaimable");
    }

    /// @notice What the merge drops on purpose, and the token powers §12 says never exist.
    function test_merge_removedSelectors() public view {
        string memory H = _methods(_art(HANDLER_ART));
        string memory T = _methods(_art(TOKEN_ART));
        // handler: 打新's 4-arg notifyTax / setPad / pad, the V3 4-arg register, the curve-tax path (§19)
        assertFalse(_hasMethod(H, "notifyTax(address,address,address,uint256)"), "4-arg notifyTax");
        assertFalse(
            _hasMethod(H, "notifyTax(address,address,address,uint256,uint16)"), "uint16-rate notifyTax (old V3)"
        );
        assertFalse(_hasMethod(H, "setPad(address)"), "setPad");
        assertFalse(_hasMethod(H, "pad()"), "pad()");
        assertFalse(_hasMethod(H, "register(address,address,address,uint16)"), "4-arg register");
        assertFalse(_hasMethod(H, "distribute(address,uint256,uint256,uint8)"), "distribute (curve tax)");
        assertFalse(_hasMethod(H, "previewSplit(address,uint256,uint256)"), "previewSplit (curve tax)");
        // token: LaunchTokenV3's unlock(), FairToken's TAX_BPS; no admin left after graduation (§12)
        assertFalse(_hasMethod(T, "unlock()"), "unlock()");
        assertFalse(_hasMethod(T, "setTaxHandler(address)"), "setTaxHandler");
        assertFalse(_hasMethod(T, "burn(uint256)"), "burn");
        assertFalse(_hasMethod(T, "setExcluded(address,bool)"), "setExcluded");
        assertFalse(_hasMethod(T, "exclude(address)"), "exclude");
    }

    /// @notice `curves` / `sales` / `positions` / `taxConfigOf` / `routeOf` return the old words in the old order
    ///         (GangRouter, the indexer and the CLI decode them positionally).
    function test_merge_getterLayout() public {
        address alice = _newAgent();
        address bob = _newAgent();

        // ---- curves: 12 words
        address tV = _createV3(alice, address(wbnb), _tax(300, 200, 4000, treasury));
        vm.prank(bob);
        uint256 got = pad.buy(tV, 1 ether, 0);
        (bool ok, bytes memory ret) = address(pad).staticcall(abi.encodeWithSignature("curves(address)", tV));
        assertTrue(ok);
        assertEq(ret.length, 12 * 32, "curves: 12 words");
        assertEq(address(uint160(_word(ret, 0))), alice, "creator");
        assertEq(address(uint160(_word(ret, 1))), address(wbnb), "quote");
        assertEq(
            _word(ret, 2), wbnb.balanceOf(address(pad)) - pad.creatorFeeOf(tV), "realQuote (only curve on the pad)"
        );
        assertEq(_word(ret, 3), got, "sold");
        (bool ok2, bytes memory g) = address(pad).staticcall(abi.encodeWithSignature("gradAmtOf(address)", tV));
        assertTrue(ok2);
        assertEq(_word(ret, 4), abi.decode(g, (uint256)), "gradAmt");
        assertGt(_word(ret, 5), 0, "virtualQuote");
        assertEq(_word(ret, 6), 0, "graduated");
        assertEq(_word(ret, 7), 300, "buyTaxBps");
        assertEq(_word(ret, 8), 200, "sellTaxBps");
        assertEq(_word(ret, 9), 4000, "dividendBps");
        assertEq(_word(ret, 10), 0, "pair");
        assertEq(_word(ret, 11), 0, "refPair");

        // ---- taxConfigOf: 4 words
        (ok, ret) = address(pad).staticcall(abi.encodeWithSignature("taxConfigOf(address)", tV));
        assertTrue(ok);
        assertEq(ret.length, 4 * 32);
        assertEq(_word(ret, 0), 300);
        assertEq(_word(ret, 1), 200);
        assertEq(_word(ret, 2), 4000);
        assertEq(address(uint160(_word(ret, 3))), treasury);

        // ---- sales: 14 words
        address tF = _createFair(alice, address(wbnb), _mintCfg(10 ether, 50, 6_000, 150, 120), 7);
        (ok, ret) = address(pad).staticcall(abi.encodeWithSignature("sales(address)", tF));
        assertTrue(ok);
        assertEq(ret.length, 14 * 32, "sales: 14 words");
        assertEq(address(uint160(_word(ret, 0))), alice, "creator");
        assertEq(_word(ret, 1), block.timestamp, "progressAt");
        assertEq(_word(ret, 2), 100, "capShares (0.5% of supply / 50k)");
        assertEq(_word(ret, 3), 6_000, "holdBps");
        assertEq(address(uint160(_word(ret, 4))), address(wbnb), "quote");
        assertEq(_word(ret, 5), 7, "sold");
        assertEq(_word(ret, 6), 0, "launched");
        assertEq(_word(ret, 7), 150, "mintFeeBps");
        assertEq(_word(ret, 8), 120, "exitFeeBps");
        assertEq(address(uint160(_word(ret, 9))), address(agents), "gate (snapshot)");
        assertEq(_word(ret, 10), uint256(10 ether) / TOTAL_SHARES, "sharePrice");
        assertEq(_word(ret, 11), 0, "pair");
        assertEq(_word(ret, 12), 0, "refPool");
        assertLe(_word(ret, 13), 7, "markSold");

        // ---- positions: 1 word
        (ok, ret) = address(pad).staticcall(abi.encodeWithSignature("positions(address,address)", tF, alice));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(_word(ret, 0), 7);

        // ---- handler.routeOf: the old 3 words first (quote, recipient, dividendBps); kind after them
        (ok, ret) = address(handler).staticcall(abi.encodeWithSignature("routeOf(address)", tV));
        assertTrue(ok);
        assertGe(ret.length, 3 * 32);
        assertEq(address(uint160(_word(ret, 0))), address(wbnb));
        assertEq(address(uint160(_word(ret, 1))), treasury);
        assertEq(_word(ret, 2), 4000);
        if (ret.length >= 4 * 32) assertEq(_word(ret, 3), KIND_CURVE, "route kind (curve)");
        (ok, ret) = address(handler).staticcall(abi.encodeWithSignature("routeOf(address)", tF));
        assertTrue(ok);
        assertEq(address(uint160(_word(ret, 0))), address(wbnb));
        assertEq(address(uint160(_word(ret, 1))), address(0), "fair: no recipient");
        assertEq(_word(ret, 2), 5_000, "fair: half to holders");
        if (ret.length >= 4 * 32) assertEq(_word(ret, 3), KIND_FAIR, "route kind (fair)");
    }

    // ================================================================ 2. kind isolation (end to end)
    // The handler-level cases (a test contract playing the pad) are in HandlerKindIsolation.t.sol; these go through
    // the real pad, its libraries and real GangTokens, so a wrong `kind` written at create, or a token calling the
    // wrong hook, shows up here.
    /// @notice kindOf is written once at create, matches the handler's route, and each kind's entry points refuse
    ///         the other kind's tokens.
    function test_merge_kindIsolation_padEntry() public {
        address alice = _newAgent();
        address tV = _createV3(alice, address(wbnb), _tax(300, 300, 5000, treasury));
        address tU = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        address tF = _createFair(alice, address(wbnb), 10);

        assertEq(pad.kindOf(tV), KIND_CURVE);
        assertEq(pad.kindOf(tU), KIND_CURVE);
        assertEq(pad.kindOf(tF), KIND_FAIR);
        assertEq(pad.kindOf(address(wbnb)), KIND_NONE);
        (,,, uint8 kV) = handler.routeOf(tV);
        (,,, uint8 kF) = handler.routeOf(tF);
        (,,, uint8 kU) = handler.routeOf(tU);
        assertEq(kV, KIND_CURVE);
        assertEq(kF, KIND_FAIR);
        assertEq(kU, KIND_NONE, "untaxed: never registered with the handler");

        vm.startPrank(alice);
        vm.expectRevert();
        pad.buy(tF, 1 ether, 0);
        vm.expectRevert();
        pad.sell(tF, 1, 0);
        vm.expectRevert();
        pad.mint(tV, 1, 1);
        vm.expectRevert();
        pad.mint(tU, 1, 1);
        vm.expectRevert();
        pad.withdraw(tV, 1, 0);
        vm.stopPrank();

        // the other kind's views say nothing about it
        assertEq(pad.baselineOf(tV, alice), 0, "no baseline on a curve token");
        assertEq(pad.holdBpsOf(tV), 0, "no hold line on a curve token");
        assertEq(uint8(pad.status(tV)), uint8(IGangLaunchpad.Status.None), "curve token has no sale");
        assertEq(_curveQuote(tF), address(0), "sale has no curve");
        assertEq(_saleQuote(tV), address(0), "curve has no sale");

        // still the same after both reach the pool
        _graduate(tV);
        _fill(tF);
        assertEq(pad.kindOf(tV), KIND_CURVE, "kind fixed");
        assertEq(pad.kindOf(tF), KIND_FAIR, "kind fixed");
    }

    /// @dev Both kinds live on the pool, both on one vault core (`launchpadOf` is the same pad): alice minted the
    ///      打新 token, bob bought both in the pool afterwards.
    function _twoKindsLive() internal returns (address tV, address tF, address alice, address bob) {
        alice = _newAgent();
        bob = _newAgent();
        tV = _createV3(alice, address(wbnb), _tax(300, 300, 5000, treasury));
        tF = _createFair(alice, address(wbnb), 100);
        _graduate(tV);
        _fill(tF);
        assertEq(divVault.launchpadOf(tV), address(pad));
        assertEq(divVault.launchpadOf(tF), address(pad));
        _poolBuy(tV, address(wbnb), _curvePair(tV), bob, 2 ether);
        _poolBuy(tF, address(wbnb), _salePair(tF), bob, 2 ether);
    }

    /// @notice R2-3 / merge plan §4.2: the share rule follows the token's kind, not the vault core (same for both).
    function test_merge_kindIsolation_e2e_syncShares() public {
        (address tV, address tF, address alice, address bob) = _twoKindsLive();
        address stranger = makeAddr("stranger");

        // curve rule: the balance; fair rule: min(balance, baseline), 0 without a baseline
        assertGt(IERC20(tV).balanceOf(bob), MIN_SHARE);
        assertEq(divVault.shares(tV, bob), IERC20(tV).balanceOf(bob), "V3: share = balance");
        assertGt(IERC20(tF).balanceOf(bob), MIN_SHARE);
        assertEq(divVault.shares(tF, bob), 0, "fair: a pool buyer has no baseline");
        uint256 base = pad.baselineOf(tF, alice);
        assertEq(base, 100 * TOKENS_PER_SHARE);

        // alice receives more than her baseline: capped at it (the curve rule would give her the balance)
        uint256 half = IERC20(tF).balanceOf(bob) / 2;
        vm.prank(bob);
        IERC20(tF).transfer(alice, half);
        assertGt(IERC20(tF).balanceOf(alice), base);
        assertEq(divVault.shares(tF, alice), base, "fair: capped at the baseline");

        // anyone re-syncing (both orders, both tokens) changes nothing
        vm.startPrank(stranger);
        handler.syncShares(tF, bob, alice);
        handler.syncShares(tV, alice, bob);
        handler.syncShares(tF, alice, bob);
        vm.stopPrank();
        assertEq(divVault.shares(tF, bob), 0);
        assertEq(divVault.shares(tF, alice), base);
        assertEq(divVault.shares(tV, bob), IERC20(tV).balanceOf(bob));

        // fair-only state never appears on a curve token
        assertFalse(handler.isOut(tV, bob));
        assertEq(handler.eligibleShare(tV, bob), 0, "eligibleShare is fair-only");

        // out below the hold line: share 0 for good, buying back does not restore it
        uint256 bal = IERC20(tF).balanceOf(alice);
        vm.prank(alice);
        IERC20(tF).transfer(bob, bal - (base * 4_000) / 10_000); // 40% of baseline < 50% hold line
        assertTrue(handler.isOut(tF, alice), "out");
        assertEq(divVault.shares(tF, alice), 0, "out: share 0");
        vm.prank(bob);
        IERC20(tF).transfer(alice, base);
        assertTrue(handler.isOut(tF, alice), "out stays out");
        assertEq(divVault.shares(tF, alice), 0, "out stays 0");
        // ...while the curve token's holders are untouched by any of it
        assertEq(divVault.shares(tV, bob), IERC20(tV).balanceOf(bob));
    }

    /// @notice notifyTax only for routes the pad registered; the platform's part follows the kind (Curve: 0.5% of
    ///         volume out of the tax; Fair: none, half to holders); the seller is synced before the credit (A-6).
    function test_merge_kindIsolation_e2e_notifyTax() public {
        (address tV, address tF,, address bob) = _twoKindsLive();

        // an unregistered token pointing at the handler can't accrue there (A-F3 / C-F10)
        address fake = makeAddr("fakeToken");
        vm.prank(fake);
        vm.expectRevert(GangTaxHandler.UnknownToken.selector);
        handler.notifyTax(fake, bob, fake, 1 ether, 300);
        GangToken rogue = new GangToken("R", "R", "", address(this), address(handler), 300, 300, false);
        rogue.unlock(makeAddr("mig"));
        address rp = makeAddr("roguePair");
        rogue.setPair(rp);
        rogue.transfer(bob, 10 ether); // from the (excluded) launchpad: untaxed
        vm.prank(bob);
        vm.expectRevert(GangTaxHandler.UnknownToken.selector);
        rogue.transfer(rp, 1 ether); // a taxed sell: the handler refuses the unregistered token
        // a token can only notify for itself
        address fPair = _salePair(tF);
        vm.prank(tV);
        vm.expectRevert();
        handler.notifyTax(tF, bob, fPair, 1 ether, 100);

        // per sell: holders' units credited (vault DividendUnitsAccrued) vs the tax taken (handler TaxAccrued)
        uint256 platF0 = handler.accruedPlatformTax(tF);
        vm.roll(block.number + 1);
        vm.recordLogs();
        _poolSell(tF, _salePair(tF), bob, IERC20(tF).balanceOf(bob) / 3);
        (uint256 taxF, uint256 unitsF) = _taxAndUnits(vm.getRecordedLogs(), tF);
        assertGt(taxF, 0);
        // Fair: no platform part at tax time, half of the tax to holders
        assertEq(platF0, 0);
        assertEq(handler.accruedPlatformTax(tF), 0, "fair: no platform part");
        assertEq(unitsF, (taxF * 5_000) / 10_000, "fair: half the tax to holders");

        // Curve (300 bps, 50% dividends): platform = tax × 50 / 300 first, holders half of the rest
        vm.roll(block.number + 1);
        vm.recordLogs();
        _poolSell(tV, _curvePair(tV), bob, IERC20(tV).balanceOf(bob) / 3);
        (uint256 taxV, uint256 unitsV) = _taxAndUnits(vm.getRecordedLogs(), tV);
        assertGt(taxV, 0);
        uint256 platV = (taxV * 50) / 300;
        assertEq(unitsV, ((taxV - platV) * 5_000) / 10_000, "curve: holders' part after the platform's 0.5%");
        assertGt(handler.accruedPlatformTax(tV), 0, "curve: platform part accrues");
    }

    bytes32 internal constant TAX_ACCRUED = keccak256("TaxAccrued(address,address,address,uint256,uint256)");
    bytes32 internal constant UNITS_ACCRUED = keccak256("DividendUnitsAccrued(address,uint256,uint256)");

    function _taxAndUnits(Vm.Log[] memory logs, address token) internal view returns (uint256 tax, uint256 units) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length < 2 || logs[i].topics[1] != bytes32(uint256(uint160(token)))) continue;
            if (logs[i].emitter == address(handler) && logs[i].topics[0] == TAX_ACCRUED) {
                (uint256 t,) = abi.decode(logs[i].data, (uint256, uint256));
                tax += t;
            } else if (logs[i].emitter == address(divVault) && logs[i].topics[0] == UNITS_ACCRUED) {
                units += abi.decode(logs[i].data, (uint256));
            }
        }
    }

    /// @notice swapBack only for registered tokens and only by the token itself; a chunk of one kind's token never
    ///         touches the other kind's accrued tax.
    function test_merge_kindIsolation_e2e_swapBack() public {
        (address tV, address tF,, address bob) = _twoKindsLive();
        address fake = makeAddr("fakeToken");
        vm.prank(fake);
        vm.expectRevert(GangTaxHandler.UnknownToken.selector);
        handler.swapBack(fake, 1 ether);
        vm.prank(bob);
        vm.expectRevert(PostGradHandlerBase.OnlyToken.selector);
        handler.swapBack(tV, 1 ether);
        vm.prank(tV);
        vm.expectRevert();
        handler.swapBack(tF, 1 ether);

        // accrue some tax on both, then sell one: only its own accrued tax moves
        _poolSell(tV, _curvePair(tV), bob, IERC20(tV).balanceOf(bob) / 4);
        _poolSell(tF, _salePair(tF), bob, IERC20(tF).balanceOf(bob) / 4);
        vm.roll(block.number + 1);
        uint256 accF = handler.accruedTax(tF);
        uint256 hF = IERC20(tF).balanceOf(address(handler));
        _poolSell(tV, _curvePair(tV), bob, IERC20(tV).balanceOf(bob) / 4);
        assertEq(handler.accruedTax(tF), accF, "V3 sell left the fair token's tax alone");
        assertEq(IERC20(tF).balanceOf(address(handler)), hF);
        vm.roll(block.number + 1);
        uint256 accV = handler.accruedTax(tV);
        uint256 hV = IERC20(tV).balanceOf(address(handler));
        _poolSell(tF, _salePair(tF), bob, IERC20(tF).balanceOf(bob) / 4);
        assertEq(handler.accruedTax(tV), accV, "fair sell left the V3 token's tax alone");
        assertEq(IERC20(tV).balanceOf(address(handler)), hV);
    }

    /// @notice The token's hooks land on the handler's functions (GangToken and GangTaxHandler agree on the
    ///         selectors): a taxed pool sell calls swapBack and notifyTax, every transfer after the pair calls
    ///         syncShares — for both kinds.
    function test_merge_tokenCallsHandlerHooks() public {
        (address tV, address tF,, address bob) = _twoKindsLive();
        address[2] memory ts = [tV, tF];
        for (uint256 i = 0; i < 2; i++) {
            address pair = pad.kindOf(ts[i]) == KIND_CURVE ? _curvePair(ts[i]) : _salePair(ts[i]);
            vm.roll(block.number + 1);
            vm.expectCall(address(handler), abi.encodeWithSelector(GangTaxHandler.swapBack.selector, ts[i]));
            vm.expectCall(address(handler), abi.encodeWithSelector(GangTaxHandler.notifyTax.selector, ts[i]));
            vm.expectCall(address(handler), abi.encodeWithSelector(GangTaxHandler.syncShares.selector, ts[i]));
            _poolSell(ts[i], pair, bob, IERC20(ts[i]).balanceOf(bob) / 5);
            assertGt(handler.accruedTax(ts[i]), 0, "the sell's tax accrued");
        }
    }

    // ================================================================ 3. token kinds (end to end)
    // Token-level cases (a test contract playing the pad) are in test/gang/GangToken.t.sol (feat/merge-token); these
    // go through the real pad: create → curve / mint → graduation / launch → pool.
    /// @notice §12: `reclaim` only on 打新 tokens and only while locked; a V3 token (taxed or not) never has it.
    function test_merge_e2e_reclaimOnlyFair() public {
        address alice = _newAgent();
        address tV = _createV3(alice, address(wbnb), _tax(300, 300, 5000, treasury));
        address tU = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        address tF = _createFair(alice, address(wbnb), 10);
        vm.prank(alice);
        pad.buy(tV, 0.5 ether, 0);
        vm.prank(alice);
        pad.buy(tU, 0.5 ether, 0);

        assertFalse(GangToken(tV).reclaimable());
        assertFalse(GangToken(tU).reclaimable());
        assertTrue(GangToken(tF).reclaimable());

        vm.startPrank(address(pad));
        vm.expectRevert(GangToken.NotReclaimable.selector);
        GangToken(tV).reclaim(alice, 1);
        vm.expectRevert(GangToken.NotReclaimable.selector);
        GangToken(tU).reclaim(alice, 1);
        vm.stopPrank();

        // 打新: the pad pulls back on withdraw while minting
        uint256 bal = IERC20(tF).balanceOf(alice);
        vm.prank(alice);
        pad.withdraw(tF, 5, 0);
        assertEq(IERC20(tF).balanceOf(alice), bal - 5 * TOKENS_PER_SHARE, "withdraw reclaims");
        // ...and never after launch
        _fill(tF);
        vm.prank(address(pad));
        vm.expectRevert(GangToken.NotLocked.selector);
        GangToken(tF).reclaim(alice, 1);
        // nobody but the pad
        vm.prank(alice);
        vm.expectRevert(GangToken.OnlyLaunchpad.selector);
        GangToken(tV).reclaim(alice, 1);
    }

    /// @notice An untaxed V3 token is never registered with the handler, never gets a pair set, and none of its
    ///         transfers (curve, graduation, pool, wallet to wallet) ever calls the handler.
    function test_merge_e2e_untaxedNeverHooks() public {
        address alice = _newAgent();
        address bob = _newAgent();
        vm.expectCall(address(handler), abi.encodeWithSelector(GangTaxHandler.register.selector), 0);
        vm.expectCall(address(handler), abi.encodeWithSelector(GangTaxHandler.notifyTax.selector), 0);
        vm.expectCall(address(handler), abi.encodeWithSelector(GangTaxHandler.syncShares.selector), 0);
        vm.expectCall(address(handler), abi.encodeWithSelector(GangTaxHandler.swapBack.selector), 0);

        address tU = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        assertEq(GangToken(tU).buyTaxBps(), 0);
        assertEq(GangToken(tU).sellTaxBps(), 0);
        vm.prank(alice);
        pad.buy(tU, 1 ether, 0);
        vm.startPrank(alice);
        IERC20(tU).approve(address(pad), type(uint256).max);
        pad.sell(tU, IERC20(tU).balanceOf(alice) / 2, 0);
        vm.stopPrank();
        _graduate(tU);

        address pair = _curvePair(tU);
        assertTrue(pair != address(0), "migrated to a pair");
        assertEq(GangToken(tU).pair(), address(0), "token pair never set");
        assertFalse(GangToken(tU).locked());
        assertEq(divVault.quoteOf(tU), address(0), "not in the vault");

        vm.prank(address(pad));
        vm.expectRevert(GangToken.Untaxed.selector);
        GangToken(tU).setPair(pair);

        uint256 out = _poolBuy(tU, address(wbnb), pair, bob, 1 ether);
        assertEq(IERC20(tU).balanceOf(bob), out, "untaxed pool buy: no tax");
        _poolSell(tU, pair, bob, out / 2);
        uint256 rest = IERC20(tU).balanceOf(bob);
        vm.prank(bob);
        IERC20(tU).transfer(alice, rest);
        assertEq(IERC20(tU).balanceOf(address(handler)), 0);
    }

    // ================================================================ 4. one pad, one WBNB balance (§5.4)
    address[] internal _accHolders;

    /// @dev balanceOf(pad, q) == Σ live sales' principal + owedFee[q] + Σ live curves' realQuote + dust, dust ≥ 0 and
    ///      never shrinking. Returns the new dust.
    function _checkPadBalance(address q, address[] memory curvesL, address[] memory salesL, uint256 dust0)
        internal
        view
        returns (uint256 dust)
    {
        uint256 accounted = pad.owedFee(q);
        for (uint256 i = 0; i < salesL.length; i++) {
            if (_saleQuote(salesL[i]) != q || _launched(salesL[i])) continue;
            uint256 price = _sharePrice(salesL[i]);
            uint256 sum;
            for (uint256 j = 0; j < _accHolders.length; j++) {
                sum += pad.positions(salesL[i], _accHolders[j]);
            }
            assertEq(sum, _saleSold(salesL[i]), "every position is tracked");
            accounted += sum * price;
        }
        for (uint256 i = 0; i < curvesL.length; i++) {
            if (_curveQuote(curvesL[i]) != q) continue;
            accounted += pad.creatorFeeOf(curvesL[i]); // kept for the creator, live or graduated
            if (!_graduated(curvesL[i])) accounted += _curveRealQuote(curvesL[i]);
        }
        uint256 bal = IERC20(q).balanceOf(address(pad));
        assertGe(bal, accounted, "pad quote >= escrow + owed fees + live realQuote + creator fees");
        dust = bal - accounted;
        assertGe(dust, dust0, "dust never shrinks");
    }

    function _onNewAgent(address who) internal override {
        _accHolders.push(who);
    }

    /// @notice V3 curves and 打新 sales on the same WBNB, interleaved: sell-backs and the launch never touch a curve's
    ///         realQuote, a graduation never touches a sale's escrow (exact accounting, dust only grows).
    function test_merge_sameQuoteIsolation_wbnb() public {
        address alice = _newAgent();
        address bob = _newAgent();
        address[] memory cs = new address[](2);
        address[] memory ss = new address[](2);
        cs[0] = _createV3(alice, address(wbnb), _tax(300, 300, 5000, treasury));
        uint256 d = _checkPadBalance(address(wbnb), cs, ss, 0);
        ss[0] = _createFair(alice, address(wbnb), 20);
        d = _checkPadBalance(address(wbnb), cs, ss, d);
        cs[1] = _createV3(bob, address(wbnb), _tax(0, 0, 0, address(0)));
        ss[1] = _createFair(bob, address(wbnb), _mintCfg(5 ether, 25, 6_000, 300, 200), 10);
        d = _checkPadBalance(address(wbnb), cs, ss, d);

        for (uint256 r = 0; r < 6; r++) {
            address who = r % 2 == 0 ? alice : bob;
            uint256 i = (r / 2) % 2;
            uint256 j = 1 - i;
            vm.prank(who);
            pad.buy(cs[i], 0.3 ether + r * 0.1 ether, 0);
            d = _checkPadBalance(address(wbnb), cs, ss, d);
            vm.prank(who);
            try pad.mint(ss[j], 7, 1) {} catch {}
            d = _checkPadBalance(address(wbnb), cs, ss, d);
            uint16 held = pad.positions(ss[i], who);
            if (held > 1) {
                vm.prank(who);
                pad.withdraw(ss[i], held / 2, 0);
                d = _checkPadBalance(address(wbnb), cs, ss, d);
            }
            uint256 bal = IERC20(cs[j]).balanceOf(who);
            if (bal > 0) {
                vm.startPrank(who);
                IERC20(cs[j]).approve(address(pad), type(uint256).max);
                pad.sell(cs[j], bal / 3, 0);
                vm.stopPrank();
                d = _checkPadBalance(address(wbnb), cs, ss, d);
            }
            if (r == 2) vm.warp(block.timestamp + 8 days); // stale: exits without a fee
        }

        // launch one sale while both curves are live, graduate one curve while a sale is live, then the rest
        uint256 real0 = _curveRealQuote(cs[0]) + _curveRealQuote(cs[1]);
        _fill(ss[0]);
        d = _checkPadBalance(address(wbnb), cs, ss, d);
        assertEq(_curveRealQuote(cs[0]) + _curveRealQuote(cs[1]), real0, "launch moved no curve quote");
        _graduate(cs[0]);
        d = _checkPadBalance(address(wbnb), cs, ss, d);
        _graduate(cs[1]);
        d = _checkPadBalance(address(wbnb), cs, ss, d);
        vm.warp(block.timestamp + 8 days);
        address m = _accHolders[_accHolders.length - 1];
        vm.prank(m);
        pad.mint(ss[1], 3, 1);
        vm.prank(m);
        pad.withdraw(ss[1], 3, 0);
        d = _checkPadBalance(address(wbnb), cs, ss, d);
        _fill(ss[1]);
        d = _checkPadBalance(address(wbnb), cs, ss, d);
        assertEq(
            wbnb.balanceOf(address(pad)),
            pad.owedFee(address(wbnb)) + pad.creatorFeeOf(cs[0]) + pad.creatorFeeOf(cs[1]) + d,
            "all done: owed fees + creator fees + dust only"
        );
        assertLt(d, 1e9, "dust is rounding only");
    }

    // ================================================================ 5. libraries, sizes, floors
    /// @notice The logic libraries run only by delegatecall from the pad: a direct call to any state-changing entry
    ///         reverts (Solidity's library call guard), so nothing can be done "as the library".
    function test_merge_libsNotDirectlyCallable() public {
        address curveLib = address(CurveLogic);
        address fairLib = address(FairLogic);
        assertGt(curveLib.code.length, 0, "CurveLogic deployed + linked");
        assertGt(fairLib.code.length, 0, "FairLogic deployed + linked");
        bytes memory junk = abi.encode(uint256(1), address(this), uint256(2), uint256(3), uint256(4), uint256(5));
        bytes4[3] memory cSel = [CurveLogic.create.selector, CurveLogic.buy.selector, CurveLogic.sell.selector];
        for (uint256 i = 0; i < cSel.length; i++) {
            (bool ok,) = curveLib.call(abi.encodePacked(cSel[i], junk));
            assertFalse(ok, "CurveLogic callable directly");
        }
        bytes4[4] memory fSel = [
            FairLogic.create.selector,
            FairLogic.mint.selector,
            FairLogic.withdraw.selector,
            FairLogic.flushFees.selector
        ];
        for (uint256 i = 0; i < fSel.length; i++) {
            (bool ok,) = fairLib.call(abi.encodePacked(fSel[i], junk));
            assertFalse(ok, "FairLogic callable directly");
        }
        // and with value: never
        vm.deal(address(this), 1 ether);
        (bool okv,) = curveLib.call{value: 1}(abi.encodePacked(cSel[1], junk));
        assertFalse(okv);
    }

    /// @notice Every merged contract (and a token of each kind) stays under 24,064 bytes (EIP-170 minus 512).
    function test_merge_sizes() public {
        address alice = _newAgent();
        address tV = _createV3(alice, address(wbnb), _tax(300, 300, 5000, treasury));
        address tU = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        address tF = _createFair(alice, address(wbnb), 10);
        address[9] memory a = [
            address(pad),
            address(handler),
            address(CurveLogic),
            address(FairLogic),
            address(router),
            address(tokenDeployer),
            tV,
            tU,
            tF
        ];
        string[9] memory n = [
            "GangLaunchpad",
            "GangTaxHandler",
            "CurveLogic",
            "FairLogic",
            "GangRouter",
            "TokenDeployer",
            "GangToken V3 taxed",
            "GangToken V3 untaxed",
            "GangToken fair"
        ];
        for (uint256 i = 0; i < a.length; i++) {
            emit log_named_uint(n[i], a[i].code.length);
            assertLt(a[i].code.length, SIZE_LIMIT, n[i]);
        }
        // one token bytecode for all three kinds (same code; only immutables differ)
        assertEq(tV.code.length, tU.code.length);
        assertEq(tV.code.length, tF.code.length);
    }

    /// @notice Reverts raised inside the delegatecalled code (PoolCheck via PadCommon, OZ SafeCast / SafeERC20 in the
    ///         libraries) are declared on the pad too, so they are in its ABI and decode on explorers, with the
    ///         selectors of the originals.
    function test_merge_libraryErrorsInPadAbi() public view {
        string memory abiPart = vm.split(_art(PAD_ART), '"bytecode":')[0];
        assertTrue(vm.contains(abiPart, '{"type":"error","name":"ThinReferencePool","inputs":[]}'), "ThinReferencePool");
        assertTrue(vm.contains(abiPart, '{"type":"error","name":"GradAmtZero","inputs":[]}'), "GradAmtZero");
        assertTrue(
            vm.contains(
                abiPart,
                '{"type":"error","name":"SafeCastOverflowedUintDowncast","inputs":[{"name":"bits","type":"uint8","internalType":"uint8"},{"name":"value","type":"uint256","internalType":"uint256"}]}'
            ),
            "SafeCastOverflowedUintDowncast"
        );
        assertTrue(
            vm.contains(
                abiPart,
                '{"type":"error","name":"SafeERC20FailedOperation","inputs":[{"name":"token","type":"address","internalType":"address"}]}'
            ),
            "SafeERC20FailedOperation"
        );
        assertEq(IGangLaunchpad.ThinReferencePool.selector, PoolCheck.ThinReferencePool.selector);
        assertEq(IGangLaunchpad.GradAmtZero.selector, PoolCheck.GradAmtZero.selector);
        assertEq(
            IGangLaunchpad.SafeCastOverflowedUintDowncast.selector, SafeCast.SafeCastOverflowedUintDowncast.selector
        );
        assertEq(IGangLaunchpad.SafeERC20FailedOperation.selector, SafeERC20.SafeERC20FailedOperation.selector);
    }

    /// @notice The pad needs a pair factory at construction (ZeroAddress, as the old FairMintPad).
    function test_merge_constructorNeedsPairFactory() public {
        vm.expectRevert(IGangLaunchpad.ZeroAddress.selector);
        new GangLaunchpad(
            owner,
            address(quoteRegistry),
            address(divVault),
            address(bucket),
            address(handler),
            address(tokenDeployer),
            address(wbnb),
            address(0)
        );
    }

    /// @notice One core, one share floor (§5.3): the V3 and the 打新 constants are the same number, the vault's floor
    ///         for the pad is it, and both kinds' tokens snapshot it.
    function test_merge_floorConstantsEqual() public {
        assertEq(pad.TAXED_MIN_SHARE(), MIN_SHARE);
        assertEq(pad.MIN_SHARE_BALANCE(), MIN_SHARE);
        assertEq(pad.TAXED_MIN_SHARE(), pad.MIN_SHARE_BALANCE());
        assertEq(divVault.minimumShareBalanceOf(address(pad)), MIN_SHARE);
        address alice = _newAgent();
        address tV = _createV3(alice, address(wbnb), _tax(300, 300, 5000, treasury));
        address tF = _createFair(alice, address(wbnb), 10);
        assertEq(divVault.tokenMinimumShareBalance(tV), MIN_SHARE);
        assertEq(divVault.tokenMinimumShareBalance(tF), MIN_SHARE);
        // a floor the owner raised above it stops both kinds' creates (C-F4), at the same line
        vm.prank(owner);
        divVault.setMinimumShareBalance(address(pad), MIN_SHARE + 1);
        vm.prank(alice);
        vm.expectRevert(IGangLaunchpad.VaultFloorTooHigh.selector);
        pad.create("C", "C", "", "", address(wbnb), address(0), _tax(300, 300, 5000, treasury));
        vm.prank(alice);
        vm.expectRevert(IGangLaunchpad.VaultFloorTooHigh.selector);
        pad.create("F", "F", "", "", address(wbnb), address(0), _mintCfg(10 ether, 50, 6_000, 100, 100), 1);
    }

    // ================================================================ the full round for the emitted-events check
    function _isGangToken(address a) internal view returns (bool) {
        return pad.kindOf(a) != KIND_NONE;
    }

    function _cat(string[] memory a, string[] memory b) internal pure returns (string[] memory c) {
        c = new string[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            c[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            c[a.length + i] = b[i];
        }
    }

    function _parseAll(string[] memory s) internal pure returns (Ev[] memory e) {
        e = new Ev[](s.length);
        for (uint256 i = 0; i < s.length; i++) {
            e[i] = _parse(s[i]);
        }
    }

    function _fullRound() internal {
        address alice = _newAgent();
        address bob = _newAgent();
        // V3 taxed with dividends on WBNB, untaxed on WBNB, taxed with a recipient on the blacklisting quote, 打新
        address tV = _createV3(alice, address(wbnb), _tax(300, 300, 5000, treasury));
        address tU = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        address tB = _createV3(alice, address(blq), _tax(500, 500, 0, treasury));
        address tF = _createFair(alice, address(wbnb), 100);
        vm.prank(bob);
        pad.buy(tV, 1 ether, 0);
        vm.startPrank(bob);
        IERC20(tV).approve(address(pad), type(uint256).max);
        pad.sell(tV, IERC20(tV).balanceOf(bob) / 2, 0);
        vm.stopPrank();
        vm.prank(bob);
        pad.mint(tF, 10, 1);
        vm.prank(bob);
        pad.withdraw(tF, 4, 0);
        _graduate(tV);
        _graduate(tU);
        _graduate(tB);
        _fill(tF);

        // the blacklisting quote refuses the recipient: tB's recipient legs become owed (released at the end)
        blq.setBlocked(treasury, true);
        // pool trades with tax (swap-backs run on the sells)
        for (uint256 r = 0; r < 3; r++) {
            vm.roll(block.number + 1);
            _poolBuy(tV, address(wbnb), _curvePair(tV), bob, 1 ether);
            _poolBuy(tF, address(wbnb), _salePair(tF), bob, 1 ether);
            _poolBuy(tB, address(blq), _curvePair(tB), bob, 1 ether);
            vm.roll(block.number + 1);
            _poolSell(tV, _curvePair(tV), bob, IERC20(tV).balanceOf(bob) / 3);
            _poolSell(tF, _salePair(tF), bob, IERC20(tF).balanceOf(bob) / 3);
            _poolSell(tB, _curvePair(tB), bob, IERC20(tB).balanceOf(bob) / 3);
        }
        // keeper sells (what the swap-backs left)
        vm.roll(block.number + 1);
        address[3] memory ts = [tV, tF, tB];
        for (uint256 i = 0; i < 3; i++) {
            uint256 c = handler.maxChunk(ts[i]);
            if (c > 0) {
                try handler.process(ts[i], c, 1) {} catch {}
            }
        }
        blq.setBlocked(treasury, false);
        if (handler.owedOf(tB) > 0) handler.release(tB);
        // a claim on the dividend token
        address[2] memory us = [alice, bob];
        for (uint256 i = 0; i < 2; i++) {
            vm.startPrank(us[i]);
            try divVault.claim(tV) {} catch {}
            try divVault.claim(tF) {} catch {}
            vm.stopPrank();
        }
    }
}
