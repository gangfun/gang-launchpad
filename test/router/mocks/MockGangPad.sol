// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// =====================================================================================================================
// MOCK — DELETE AT INTEGRATION (test/router/GangRouter.t.sol then deploys the real GangLaunchpad from GangFixture).
// A minimal GangLaunchpad for the router tests: the router-facing surface of the merged pad (curves / buyFor for V3,
// sales / previewMint / mintFor for 打新, routers, the Agent gate, the wallet cap, refunds) with the real getter layouts
// (IGangLaunchpad.Curve, 12 fields; IGangLaunchpad.Sale, 14 fields), the real error names and the V3 `Buy` event.
// Pricing is flat (no curve, no tax, no fees on the curve; 打新 at a fixed share price + mint fee).
// =====================================================================================================================

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGangLaunchpad} from "../../../src/gang/interfaces/IGangLaunchpad.sol";

contract MockPadToken is ERC20 {
    address internal immutable pad;

    constructor() ERC20("Mock", "MOCK") {
        pad = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == pad, "only pad");
        _mint(to, amount);
    }
}

contract MockGangPad is IGangLaunchpad {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_PER_WALLET = 10_000_000 ether;
    /// @dev Flat V3 price: tokens per whole quote unit (the 1% cap costs 0.5 quote).
    uint256 public constant TOKENS_PER_QUOTE = 20_000_000;
    uint256 public constant GRAD_AMT = 15 ether;
    uint256 public constant TOTAL_SHARES = 10_000;
    uint256 public constant TOKENS_PER_SHARE = 50_000 ether;
    uint128 public constant SHARE_PRICE = 15 ether / 10_000;

    address public immutable owner;
    address public immutable wbnb;
    IERC721 public immutable agentIdRegistry;
    bool public agentGateEnabled = true;

    mapping(address => bool) public routers;
    mapping(address => uint8) public kindOf;
    mapping(address => Curve) public curves;
    mapping(address => Sale) public sales;
    mapping(address => mapping(address => Position)) public positions;

    constructor(address owner_, address wbnb_, address agents_) {
        owner = owner_;
        wbnb = wbnb_;
        agentIdRegistry = IERC721(agents_);
    }

    function setRouter(address router, bool enabled) external {
        require(msg.sender == owner, "owner");
        routers[router] = enabled;
        emit RouterSet(router, enabled);
    }

    function setAgentGate(bool enabled) external {
        require(msg.sender == owner, "owner");
        agentGateEnabled = enabled;
    }

    function isAgent(address a) public view returns (bool) {
        return !agentGateEnabled || agentIdRegistry.balanceOf(a) > 0;
    }

    // ---------------------------------------------------------------- V3
    /// @dev Mock-only create (the real pad: `create(..., TaxConfig)`).
    function createCurve(address quote) external returns (address token) {
        token = address(new MockPadToken());
        kindOf[token] = 1;
        Curve storage c = curves[token];
        c.creator = msg.sender;
        c.quote = quote == address(0) ? wbnb : quote;
        c.gradAmt = uint128(GRAD_AMT);
    }

    function buy(address token, uint256 quoteIn, uint256 minTokensOut) external returns (uint256) {
        if (!isAgent(msg.sender)) revert NotAgent();
        return _buy(msg.sender, token, quoteIn, minTokensOut);
    }

    function buyFor(address trader, address token, uint256 quoteIn, uint256 minTokensOut) external returns (uint256) {
        if (!routers[msg.sender]) revert OnlyRouter();
        if (!agentGateEnabled) revert RouterNeedsGate();
        if (!isAgent(trader)) revert NotAgent();
        return _buy(trader, token, quoteIn, minTokensOut);
    }

    function _buy(address trader, address token, uint256 quoteIn, uint256 minTokensOut)
        internal
        returns (uint256 tokensOut)
    {
        Curve storage c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        if (c.graduated) revert AlreadyGraduated();
        if (quoteIn == 0) revert ZeroAmount();
        uint256 bal = IERC20(token).balanceOf(trader);
        if (bal >= MAX_PER_WALLET) revert WalletCapReached();
        uint256 used = quoteIn;
        uint256 left = c.gradAmt - c.realQuote;
        if (used > left) used = left;
        tokensOut = used * TOKENS_PER_QUOTE;
        if (tokensOut > MAX_PER_WALLET - bal) {
            tokensOut = MAX_PER_WALLET - bal;
            used = tokensOut / TOKENS_PER_QUOTE;
        }
        if (tokensOut < minTokensOut) revert Slippage();
        // pulls only what it uses: the rest stays with the caller (a router returns it)
        IERC20(c.quote).safeTransferFrom(msg.sender, address(this), used);
        c.realQuote += uint128(used);
        c.sold += uint128(tokensOut);
        MockPadToken(token).mint(trader, tokensOut);
        emit Buy(token, trader, used, 0, 0, tokensOut, c.realQuote);
        if (c.realQuote >= c.gradAmt) {
            c.graduated = true;
            c.pair = address(uint160(uint256(keccak256(abi.encode(token)))));
        }
    }

    // ---------------------------------------------------------------- 打新
    /// @dev Mock-only create (the real pad: `create(..., MintConfig, devShares)`): cap 100 shares, mint fee 1%, gated
    ///      by the current registry; the creator mints `devShares` in the same call, paid from its quote approval.
    function createSale(address quote, uint256 devShares) external returns (address token) {
        if (!isAgent(msg.sender)) revert NotAgent();
        token = address(new MockPadToken());
        kindOf[token] = 2;
        Sale storage s = sales[token];
        s.creator = msg.sender;
        s.quote = quote == address(0) ? wbnb : quote;
        s.capShares = 100;
        s.holdBps = 5000;
        s.mintFeeBps = 100;
        s.exitFeeBps = 200;
        s.gate = agentGateEnabled ? address(agentIdRegistry) : address(0);
        s.sharePrice = SHARE_PRICE;
        _mint(token, s, msg.sender, devShares, devShares);
    }

    function previewMint(address token, address user, uint256 shares)
        public
        view
        returns (uint256 accepted, uint256 cost, uint256 fee)
    {
        Sale storage s = sales[token];
        if (s.creator == address(0) || s.launched) return (0, 0, 0);
        accepted = _acceptable(s, positions[token][user].shares, shares);
        cost = accepted * s.sharePrice;
        fee = (cost * s.mintFeeBps) / BPS;
    }

    function mint(address token, uint256 shares, uint256 minShares) external returns (uint256) {
        Sale storage s = _minting(token);
        if (s.gate != address(0) && IERC721(s.gate).balanceOf(msg.sender) == 0) revert NotAgent();
        if (shares == 0) revert ZeroAmount();
        return _mint(token, s, msg.sender, shares, minShares);
    }

    function mintFor(address trader, address token, uint256 shares, uint256 minShares) external returns (uint256) {
        if (!routers[msg.sender]) revert OnlyRouter();
        Sale storage s = _minting(token);
        if (s.gate == address(0)) revert RouterNeedsGate();
        if (IERC721(s.gate).balanceOf(trader) == 0) revert NotAgent();
        if (shares == 0) revert ZeroAmount();
        return _mint(token, s, trader, shares, minShares);
    }

    /// @dev No exit fee in the mock (the real pad's stale rule waives it after 7 days, as the router test expects).
    function withdraw(address token, uint256 shares, uint256 minPayout) external returns (uint256 payout) {
        Sale storage s = _minting(token);
        Position storage p = positions[token][msg.sender];
        if (shares == 0 || shares > p.shares) revert BadAmount();
        payout = shares * s.sharePrice;
        if (payout < minPayout) revert Slippage();
        p.shares -= uint16(shares);
        s.sold -= uint16(shares);
        IERC20(s.quote).safeTransfer(msg.sender, payout);
    }

    function _mint(address token, Sale storage s, address trader, uint256 want, uint256 minShares)
        internal
        returns (uint256 accepted)
    {
        Position storage p = positions[token][trader];
        accepted = _acceptable(s, p.shares, want);
        if (accepted == 0) revert WalletCapReached();
        if (accepted < minShares) revert Slippage();
        uint256 cost = accepted * s.sharePrice;
        uint256 fee = (cost * s.mintFeeBps) / BPS;
        IERC20(s.quote).safeTransferFrom(msg.sender, address(this), cost + fee);
        p.shares += uint16(accepted);
        s.sold += uint16(accepted);
        MockPadToken(token).mint(trader, accepted * TOKENS_PER_SHARE);
        emit Minted(token, trader, accepted, cost, fee, p.shares, s.sold);
        if (s.sold == TOTAL_SHARES) {
            s.launched = true;
            s.pair = address(uint160(uint256(keccak256(abi.encode(token)))));
        }
    }

    function _acceptable(Sale storage s, uint256 held, uint256 want) internal view returns (uint256 a) {
        uint256 room = held >= s.capShares ? 0 : s.capShares - held;
        uint256 left = TOTAL_SHARES - s.sold;
        a = want;
        if (a > room) a = room;
        if (a > left) a = left;
    }

    function _minting(address token) internal view returns (Sale storage s) {
        s = sales[token];
        if (s.creator == address(0) || s.launched) revert UnknownToken();
    }
}
