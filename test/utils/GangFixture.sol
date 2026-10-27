// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {MockPairFactory, MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../../src/common/SharedPlatformFeeBucket.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangTaxHandler} from "../../src/gang/GangTaxHandler.sol";
import {GangToken} from "../../src/gang/GangToken.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangRouter} from "../../src/router/GangRouter.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";
import {MockWBNB} from "../mocks/MockWBNB.sol";

/// @dev 18-decimal quote that can refuse transfers to one address (a recipient whose pushes fail and become owed).
contract GangBlacklistQuote is ERC20("Blacklist USD", "BUSD") {
    mapping(address => bool) public blocked;

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blacklisted");
        super._update(from, to, value);
    }
}

/// @notice One whole merged deployment on mocks (merge plan §7.1): GangLaunchpad (+ CurveLogic / FairLogic, linked by
///         forge) and GangTaxHandler over the shared vault, bucket, migrator, registry and TokenDeployer, behind
///         GangRouter. Wired in the deploy script's order: everything first, `pad.setMigrator` last (A-1).
/// @dev Names follow the old suites (`pad`, `handler`, `divVault`, `bucket`, `migrator`, `tokenDeployer`, `agents`,
///      `quoteRegistry`) so most migrated cases only change their import. Three quotes are listed: WBNB, an 18-decimal
///      test quote (fixed 15-BNB equivalent in the registry) and a quote that can blacklist the tax recipient.
abstract contract GangFixture is Test {
    // ---------------------------------------------------------------- constants the tests rely on
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant TOKENS_PER_SHARE = 50_000 ether;
    uint256 internal constant TOTAL_SHARES = 10_000;
    uint256 internal constant MIN_SHARE = 10_000 ether;
    uint8 internal constant KIND_NONE = 0;
    uint8 internal constant KIND_CURVE = 1;
    uint8 internal constant KIND_FAIR = 2;

    // ---------------------------------------------------------------- the deployment
    MockWBNB public wbnb;
    MockSPCXB public quoteTok;
    GangBlacklistQuote public blq;
    MockAgentId public agents;
    MockPairFactory public pairFactory;
    QuoteRegistry public quoteRegistry;
    SharedPlatformFeeBucket public bucket;
    SharedDividendVault public divVault;
    SharedMigrator public migrator;
    TokenDeployer public tokenDeployer;
    GangTaxHandler public handler;
    GangLaunchpad public pad;
    GangRouter public router;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public feeVault = makeAddr("feeVault");

    uint256 internal _agentNonce;
    uint256 internal _nextAgentId = 1;

    /// @param keeper the handler's keeper (`process`); the invariant handler passes itself.
    function _deployGang(address keeper) internal {
        wbnb = new MockWBNB();
        vm.deal(address(wbnb), 1_000_000 ether); // backs unwraps of faucet-minted WBNB
        quoteTok = new MockSPCXB();
        blq = new GangBlacklistQuote();
        agents = new MockAgentId();
        pairFactory = new MockPairFactory();

        quoteRegistry = new QuoteRegistry(owner);
        bucket = new SharedPlatformFeeBucket(owner, feeVault);
        divVault = new SharedDividendVault(owner);
        migrator = new SharedMigrator(owner, address(pairFactory));
        tokenDeployer = new TokenDeployer(owner);
        handler = new GangTaxHandler(owner, address(divVault), address(bucket), address(0));
        pad = new GangLaunchpad(
            owner,
            address(quoteRegistry),
            address(divVault),
            address(bucket),
            address(handler),
            address(tokenDeployer),
            address(wbnb),
            address(pairFactory)
        );
        router = new GangRouter(address(pad), address(wbnb));

        vm.startPrank(owner);
        quoteRegistry.setQuote(address(quoteTok), true, 15 ether);
        quoteRegistry.setQuote(address(blq), true, 15 ether);
        bucket.setOperator(address(pad), true);
        bucket.setOperator(address(handler), true);
        // one core, one floor (merge plan §5.3: TAXED_MIN_SHARE == MIN_SHARE_BALANCE == 10k), one operator (F4a)
        divVault.setLaunchpad(address(pad), true);
        divVault.setMinimumShareBalance(address(pad), MIN_SHARE);
        divVault.setOperator(address(handler), address(pad));
        divVault.setExcluded(address(migrator), true);
        divVault.setExcluded(address(bucket), true);
        migrator.addLaunchpad(address(pad));
        tokenDeployer.setLaunchpad(address(pad), true);
        handler.setLaunchpad(address(pad));
        handler.setKeeper(keeper);
        handler.list(treasury, "partner treasury");
        pad.setAgentGate(true, address(agents));
        pad.setRouter(address(router), true);
        pad.setMigrator(address(migrator)); // last (A-1)
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- actors
    /// @dev A fresh Agent with 1,000 of each quote (and BNB), approved to the pad and the router.
    function _newAgent() internal returns (address who) {
        who = address(uint160(uint256(keccak256(abi.encode("gang-agent", _agentNonce++)))));
        agents.mint(who, _nextAgentId++);
        vm.deal(who, 1_000 ether);
        wbnb.mintUnlimited(who, 1_000 ether);
        quoteTok.mintUnlimited(who, 1_000 ether);
        blq.mint(who, 1_000 ether);
        vm.startPrank(who);
        wbnb.approve(address(pad), type(uint256).max);
        quoteTok.approve(address(pad), type(uint256).max);
        blq.approve(address(pad), type(uint256).max);
        wbnb.approve(address(router), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        blq.approve(address(router), type(uint256).max);
        vm.stopPrank();
        _onNewAgent(who);
    }

    /// @dev Hook for suites that track every address that ever held a token.
    function _onNewAgent(address who) internal virtual {}

    function _mintQuote(address q, address to, uint256 amount) internal {
        if (q == address(wbnb)) wbnb.mintUnlimited(to, amount);
        else if (q == address(quoteTok)) quoteTok.mintUnlimited(to, amount);
        else blq.mint(to, amount);
    }

    // ---------------------------------------------------------------- create
    function _tax(uint16 buyBps, uint16 sellBps, uint16 dividendBps, address recipient)
        internal
        pure
        returns (IGangLaunchpad.TaxConfig memory)
    {
        return IGangLaunchpad.TaxConfig({
            buyTaxBps: buyBps, sellTaxBps: sellBps, dividendBps: dividendBps, recipient: recipient
        });
    }

    function _createV3(address creator, address quote, IGangLaunchpad.TaxConfig memory tax)
        internal
        returns (address t)
    {
        vm.prank(creator);
        t = pad.create("Curve", "CRV", "logo", "meta", quote, address(0), tax);
    }

    function _mintCfg(uint256 raiseBnb, uint16 capBps, uint16 holdBps, uint16 mintFeeBps, uint16 exitFeeBps)
        internal
        pure
        returns (IGangLaunchpad.MintConfig memory)
    {
        return IGangLaunchpad.MintConfig({
            raiseBnb: raiseBnb, capBps: capBps, holdBps: holdBps, mintFeeBps: mintFeeBps, exitFeeBps: exitFeeBps
        });
    }

    /// @dev Default 打新: 10 BNB raise, 0.5% cap (50 shares), 50% hold line, 1% mint fee, 1% exit fee.
    function _createFair(address creator, address quote, uint256 devShares) internal returns (address t) {
        t = _createFair(creator, quote, _mintCfg(10 ether, 50, 5_000, 100, 100), devShares);
    }

    function _createFair(address creator, address quote, IGangLaunchpad.MintConfig memory cfg, uint256 devShares)
        internal
        returns (address t)
    {
        vm.prank(creator);
        t = pad.create("Fair", "FAIR", "logo", "meta", quote, address(0), cfg, devShares);
    }

    // ---------------------------------------------------------------- getters by name (the old tuple layouts)
    function _curveQuote(address t) internal view returns (address q) {
        (, q,,,,,,,,,,) = pad.curves(t);
    }

    function _curveRealQuote(address t) internal view returns (uint256 r) {
        (,, r,,,,,,,,,) = pad.curves(t);
    }

    function _curveSold(address t) internal view returns (uint256 s) {
        (,,, s,,,,,,,,) = pad.curves(t);
    }

    function _graduated(address t) internal view returns (bool g) {
        (,,,,,, g,,,,,) = pad.curves(t);
    }

    function _curvePair(address t) internal view returns (address p) {
        (,,,,,,,,,, p,) = pad.curves(t);
    }

    function _saleQuote(address t) internal view returns (address q) {
        (,,,, q,,,,,,,,,) = pad.sales(t);
    }

    function _saleSold(address t) internal view returns (uint16 s) {
        (,,,,, s,,,,,,,,) = pad.sales(t);
    }

    function _launched(address t) internal view returns (bool l) {
        (,,,,,, l,,,,,,,) = pad.sales(t);
    }

    function _sharePrice(address t) internal view returns (uint256 p) {
        (,,,,,,,,,, p,,,) = pad.sales(t);
    }

    function _salePair(address t) internal view returns (address p) {
        (,,,,,,,,,,, p,,) = pad.sales(t);
    }

    // ---------------------------------------------------------------- drive to graduation / launch
    /// @dev Fresh Agents buy `step` each (the 1% wallet cap truncates) until the curve graduates.
    function _graduate(address t) internal {
        for (uint256 i = 0; i < 400 && !_graduated(t); i++) {
            address w = _newAgent();
            vm.prank(w);
            pad.buy(t, 1 ether, 0);
        }
        require(_graduated(t), "fixture: did not graduate");
    }

    /// @dev Fresh Agents mint up to the cap until the sale fills (it launches in that same tx).
    function _fill(address t) internal {
        for (uint256 i = 0; i < 800 && !_launched(t); i++) {
            address w = _newAgent();
            vm.prank(w);
            pad.mint(t, TOTAL_SHARES, 1);
        }
        require(_launched(t), "fixture: did not launch");
    }

    // ---------------------------------------------------------------- pool trades on a MockPair (no K check)
    function _reserves(address token, address pair) internal view returns (uint256 rT, uint256 rQ) {
        (uint112 r0, uint112 r1,) = MockPair(pair).getReserves();
        (rT, rQ) = MockPair(pair).token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _pairSwapOut(address pair, address token, bool tokenOut, uint256 out, address to) internal {
        if ((MockPair(pair).token0() == token) == tokenOut) MockPair(pair).swap(out, 0, to, "");
        else MockPair(pair).swap(0, out, to, "");
    }

    /// @dev Pool buy: `quoteIn` lands in the pair, `who` takes half the constant-product amount out. Returns tokens out.
    function _poolBuy(address token, address quote, address pair, address who, uint256 quoteIn)
        internal
        returns (uint256 out)
    {
        _mintQuote(quote, pair, quoteIn);
        (uint256 rT, uint256 rQ) = _reserves(token, pair);
        if (rT == 0 || rQ == 0) return 0;
        out = (quoteIn * rT) / (rQ + quoteIn) / 2;
        if (out == 0) return 0;
        _pairSwapOut(pair, token, true, out, who);
    }

    /// @dev Pool sell: `who` sends `amount` into the pair (taxed by the token), takes half the CP quote out.
    function _poolSell(address token, address pair, address who, uint256 amount) internal returns (uint256 out) {
        if (amount == 0) return 0;
        vm.prank(who);
        IERC20(token).transfer(pair, amount);
        (uint256 rT, uint256 rQ) = _reserves(token, pair);
        uint256 bal = IERC20(token).balanceOf(pair);
        if (bal <= rT) return 0;
        out = ((bal - rT) * rQ) / bal / 2;
        if (out == 0) return 0;
        _pairSwapOut(pair, token, false, out, who);
    }

    function _gangToken(address t) internal pure returns (GangToken) {
        return GangToken(t);
    }
}
