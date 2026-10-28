// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGangPadRegistry} from "./interfaces/IGangPadRegistry.sol";

/// @dev The slice of a Gang pad (GangLaunchpad and every later generation, which keep these selectors and layouts) the
///      registry reads. `curves` keeps the 12-field layout GangRouter and the CLI decode.
interface IGangPadQuoteView {
    function kindOf(address token) external view returns (uint8);
    function curves(address token)
        external
        view
        returns (
            address creator,
            address quote,
            uint128 realQuote,
            uint128 sold,
            uint128 gradAmt,
            uint128 virtualQuote,
            bool graduated,
            uint16 buyTaxBps,
            uint16 sellTaxBps,
            uint16 dividendBps,
            address pair,
            address refPair
        );
    function walletCapEnabled() external view returns (bool);
    function walletRoom(address token, address buyer) external view returns (uint256);
    function agentGateEnabled() external view returns (bool);
    function isAgent(address account) external view returns (bool);
    function VIRTUAL_TOKEN() external view returns (uint256);
    function PROTOCOL_FEE_BPS() external view returns (uint256);
}

/// @dev GangToken's pointer to the pad that created it.
interface IGangTokenPad {
    function launchpad() external view returns (address);
}

/// @title GangPadRegistry — the one address aggregators use to find a token's Gang pad and to quote its curve
/// @notice `padOf(token)` reads the token's own `launchpad()` and accepts it only when that pad is registered here AND
///         the pad lists the token (`kindOf != 0`), so a look-alike token pointing at a real pad, or any token pointing
///         at an unregistered contract, reads as address(0). `previewBuy` / `previewSell` repeat CurveLogic's math on
///         the pad's own state (constant product on virtual reserves, 1% fee, graduation cut, wallet cap) and match
///         `buyFor` / `sellFor` to the wei; pads with other curve constants are refused at `addPad` until the registry
///         is upgraded to quote them.
///         Deployed as the logic of a TransparentUpgradeableProxy: aggregators keep the proxy address for good. On
///         mainnet both the proxy's ProxyAdmin and this registry's `owner` are the platform Safe (2 of 3, no
///         timelock); aggregators can watch `PadAdded` and the proxy's `Upgraded`. The pads registered at deploy go in
///         through `initialize`. The registry holds no funds and calls nothing that writes.
/// @dev STORAGE LAYOUT (proxy storage). Upgrade rule: a new variable takes its slot from `__gap` (declared right before
///      it) and the gap shrinks by the same number of slots; never reorder, retype or remove a variable, and never
///      change the inheritance list:
///        slot 0      owner
///        slot 1      pendingOwner
///        slot 2      _pads (length; elements at keccak256(2))
///        slot 3      isPad
///        slots 4–49  __gap (46 slots)
///      Initializable keeps its flag in its ERC-7201 slot (not in the sequential layout). A new version that needs
///      set-up uses `reinitializer(2)`.
contract GangPadRegistry is IGangPadRegistry, Initializable {
    uint256 internal constant BPS = 10_000;
    /// @dev CurveLogic's constants (GangLaunchpad.VIRTUAL_TOKEN / PROTOCOL_FEE_BPS); `addPad` checks the pad agrees.
    uint256 internal constant VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667;
    uint256 internal constant FEE_BPS = 100;
    uint8 internal constant KIND_CURVE = 1;
    /// @dev Gas for the token's `launchpad()` in `padOf`: GangToken returns an immutable (well under 1k); a token that
    ///      burns more just reads as not a Gang token.
    uint256 internal constant LOOKUP_GAS = 10_000;

    address public owner;
    address public pendingOwner;
    address[] internal _pads;
    mapping(address => bool) public isPad;
    /// @dev Reserved for appended state in later versions (see the layout above).
    uint256[46] private __gap;

    /// @dev Curve state read once per quote.
    struct CurveState {
        uint256 realQuote;
        uint256 sold;
        uint256 gradAmt;
        uint256 virtualQuote;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @dev The implementation itself can never be initialized: only a proxy's storage holds an owner.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Run once, by the proxy's constructor (TransparentUpgradeableProxy's `_data`), in the deploy transaction.
    /// @param owner_ Registers pads and hands the role on (mainnet: the platform Safe).
    /// @param pads_  Pads registered at deploy (mainnet: the live GangLaunchpad), with the same checks as `addPad`.
    function initialize(address owner_, address[] calldata pads_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        for (uint256 i; i < pads_.length; i++) {
            _addPad(pads_[i]);
        }
    }

    // ---------------------------------------------------------------- owner
    /// @notice Register a new pad generation. Append-only: there is no way to remove or repoint a pad (an emergency
    ///         stop is the pad's own `setRouter(router, false)`).
    function addPad(address pad) external onlyOwner {
        _addPad(pad);
    }

    /// @notice Step 1 of a hand-over; `newOwner` must call `acceptOwnership`. address(0) cancels a pending one.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ---------------------------------------------------------------- discovery
    /// @inheritdoc IGangPadRegistry
    function padOf(address token) external view returns (address pad) {
        (pad,) = _lookup(token);
    }

    /// @inheritdoc IGangPadRegistry
    function lookup(address token) external view returns (address pad, uint8 kind) {
        return _lookup(token);
    }

    function padCount() external view returns (uint256) {
        return _pads.length;
    }

    function padAt(uint256 i) external view returns (address) {
        return _pads[i];
    }

    function pads() external view returns (address[] memory) {
        return _pads;
    }

    // ---------------------------------------------------------------- quotes (CurveLogic, wei for wei)
    /// @inheritdoc IGangPadRegistry
    function previewBuy(address token, address trader, uint256 quoteIn)
        external
        view
        returns (uint256 tokensOut, uint256 spent, uint256 fee, uint256 refund)
    {
        (IGangPadQuoteView p, CurveState memory s, bool live) = _curve(token, trader);
        // past type(uint256).max / FEE_BPS the pad's own fee math overflows (the buy reverts)
        if (!live || quoteIn == 0 || quoteIn > type(uint256).max / FEE_BPS) return (0, 0, 0, 0);

        // CurveLogic._prepBuy: the wallet cap first, then the fee, the graduation cut, the cap cut
        bool capped = p.walletCapEnabled();
        uint256 room = capped ? p.walletRoom(token, trader) : type(uint256).max;
        if (room == 0) return (0, 0, 0, 0);

        spent = quoteIn;
        fee = (quoteIn * FEE_BPS) / BPS;
        uint256 net = quoteIn - fee;
        uint256 remaining = s.gradAmt - s.realQuote;
        if (net > remaining) {
            (spent, fee, net) = _spentFor(quoteIn, remaining);
            if (net > remaining) net = remaining;
        }

        tokensOut = _tokensOut(s, net);
        if (tokensOut > room) {
            tokensOut = room;
            (spent, fee,) = _spentFor(quoteIn, _quoteInFor(s, room));
        }
        refund = quoteIn - spent;
    }

    /// @inheritdoc IGangPadRegistry
    function previewSell(address token, address trader, uint256 tokensIn)
        external
        view
        returns (uint256 quoteOut, uint256 fee)
    {
        (, CurveState memory s, bool live) = _curve(token, trader);
        if (!live || tokensIn == 0 || tokensIn > s.sold) return (0, 0);

        uint256 k = s.virtualQuote * VIRTUAL_TOKEN;
        uint256 gross = (s.virtualQuote + s.realQuote) - Math.ceilDiv(k, VIRTUAL_TOKEN - s.sold + tokensIn);
        if (gross > s.realQuote) return (0, 0);
        fee = (gross * FEE_BPS) / BPS;
        quoteOut = gross - fee;
    }

    // ---------------------------------------------------------------- internal
    /// @dev The registered pad that lists `token`, and its kind; (0, 0) for anything else.
    function _lookup(address token) internal view returns (address pad, uint8 kind) {
        bytes4 sel = IGangTokenPad.launchpad.selector;
        uint256 word;
        // only the first 32 bytes are copied, under a gas cap: a token cannot make this revert or run out of gas
        assembly ("memory-safe") {
            mstore(0x00, sel)
            let ok := staticcall(LOOKUP_GAS, token, 0x00, 0x04, 0x00, 0x20)
            if and(ok, gt(returndatasize(), 0x1f)) { word := mload(0x00) }
        }
        if (word == 0 || word >> 160 != 0) return (address(0), 0);
        pad = address(uint160(word));
        if (!isPad[pad]) return (address(0), 0);
        kind = IGangPadQuoteView(pad).kindOf(token);
        if (kind == 0) pad = address(0);
    }

    function _addPad(address pad) internal {
        if (pad == address(0)) revert ZeroAddress();
        if (pad.code.length == 0) revert NotAContract();
        if (isPad[pad]) revert AlreadyPad();
        IGangPadQuoteView p = IGangPadQuoteView(pad);
        if (p.VIRTUAL_TOKEN() != VIRTUAL_TOKEN || p.PROTOCOL_FEE_BPS() != FEE_BPS) revert CurveMathMismatch();
        isPad[pad] = true;
        _pads.push(pad);
        emit PadAdded(pad, _pads.length - 1);
    }

    /// @dev The curve of `token` on its registered pad; `live` false wherever buy / sell would revert before the math
    ///      (not a registered curve token, graduated, the gate shuts `trader` out).
    function _curve(address token, address trader)
        internal
        view
        returns (IGangPadQuoteView p, CurveState memory s, bool live)
    {
        (address pad, uint8 kind) = _lookup(token);
        p = IGangPadQuoteView(pad);
        if (kind != KIND_CURVE) return (p, s, false);
        (
            address creator,,
            uint128 realQuote,
            uint128 sold,
            uint128 gradAmt,
            uint128 virtualQuote,
            bool graduated,,,,,
        ) = p.curves(token);
        if (creator == address(0) || graduated) return (p, s, false);
        if (trader != address(0) && p.agentGateEnabled() && !p.isAgent(trader)) return (p, s, false);
        s = CurveState({realQuote: realQuote, sold: sold, gradAmt: gradAmt, virtualQuote: virtualQuote});
        live = true;
    }

    /// @dev CurveLogic._recomputeFee: the gross that buys `net` after the fee (capped at quoteIn), its fee, and the net
    ///      that gross really leaves.
    function _spentFor(uint256 quoteIn, uint256 net)
        internal
        pure
        returns (uint256 spentGross, uint256 fee, uint256 netOut)
    {
        spentGross = Math.ceilDiv(net * BPS, BPS - FEE_BPS);
        if (spentGross > quoteIn) spentGross = quoteIn;
        fee = (spentGross * FEE_BPS) / BPS;
        netOut = spentGross - fee;
    }

    function _tokensOut(CurveState memory s, uint256 quoteIn) internal pure returns (uint256) {
        uint256 k = s.virtualQuote * VIRTUAL_TOKEN;
        return (VIRTUAL_TOKEN - s.sold) - Math.ceilDiv(k, s.virtualQuote + s.realQuote + quoteIn);
    }

    function _quoteInFor(CurveState memory s, uint256 tokensOut) internal pure returns (uint256) {
        uint256 k = s.virtualQuote * VIRTUAL_TOKEN;
        return Math.ceilDiv(k, VIRTUAL_TOKEN - s.sold - tokensOut) - (s.virtualQuote + s.realQuote);
    }
}
