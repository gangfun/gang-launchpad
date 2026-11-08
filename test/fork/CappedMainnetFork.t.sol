// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {GangCappedSplitter} from "../../src/gang/GangCappedSplitter.sol";
import {GangCappedSplitterFactory} from "../../src/gang/GangCappedSplitterFactory.sol";
import {DeployGangCappedSplitterFactory} from "../../script/DeployGangCappedSplitterFactory.s.sol";

interface ICappedForkRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ICappedForkHandler {
    function maxChunk(address token) external view returns (uint256);
    function process(address token, uint256 amount, uint256 minQuoteOut) external returns (uint256);
    function keeper() external view returns (address);
}

interface ICappedForkPair {
    function balanceOf(address) external view returns (uint256);
}

/// @notice GangCappedSplitterFactory on a BSC mainnet fork, against the live GangLaunchpad 3.0, its GangTaxHandler and
///         GangHandlerAdmin, and PancakeSwap: deployed by its script and allowed by the Safe call the script prints; an
///         Agent clones a capped splitter (cap in the quote, 50% to itself and a KOL until then, the rest 70% buy-back /
///         30% liquidity), creates a tax token naming it, binds it; the curve graduates into a real Pancake pair; pool
///         trades through the real router pay the tax; the live keeper role sells it; the keeper's loop (previewWork /
///         work) pays the payees exactly the cap, then only burns and adds real LP to 0xdead. Agent IDs are mocked and
///         the wallet cap is off, so a few buyers fill the curve. No broadcast.
/// @dev Needs BSC_RPC_URL (skipped without it). Run each test alone (the script reads process-wide env vars).
contract CappedMainnetForkTest is Test {
    address constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    address constant LIVE_ADMIN = 0xC833CEC2B283759003945C0Bf8C048aB1949Af76;
    address constant GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint16 constant TAX = 300;

    IGangPad p = IGangPad(PAD3);
    DeployGangCappedSplitterFactory script;
    GangCappedSplitterFactory factory;
    GangCappedSplitter m;
    address dev = makeAddr("capped-fork-dev");
    address kol = makeAddr("capped-fork-kol");
    address t;
    address quote;
    address pair;
    uint256 internal _n;

    function _live() internal returns (bool) {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        vm.prank(SAFE);
        GangLaunchpad3(payable(PAD3)).setWalletCapEnabled(false);
        uint256 pk = uint256(keccak256("capped splitter fork test: throwaway, never funded"));
        vm.deal(vm.addr(pk), 1 ether);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        vm.setEnv("GANG_PAD2", vm.toString(address(0)));
        vm.setEnv("HANDLER_ADMIN", vm.toString(LIVE_ADMIN));
        vm.setEnv("CAPPED_FACTORY", vm.toString(address(0)));
        vm.setEnv("GANG_QUOTE", vm.toString(GANG));
        script = new DeployGangCappedSplitterFactory();
        factory = script.run();
        bytes[] memory batch = script.pendingBatch(LIVE_ADMIN, address(factory));
        assertEq(batch.length, 1, "one Safe call");
        (address to, bytes memory data) = this.cut(batch[0]);
        vm.prank(SAFE);
        (bool ok,) = to.call(data);
        assertTrue(ok, "the Safe's call");
        assertEq(script.pendingBatch(LIVE_ADMIN, address(factory)).length, 0);
        assertEq(GangCappedSplitter(factory.implementation()).gangQuote(), GANG);
        return true;
    }

    function cut(bytes calldata c) external pure returns (address, bytes memory) {
        return (address(bytes20(c[:20])), c[20:]);
    }

    function _next(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(vm.getBlockNumber() + 2);
    }

    function _agent() internal returns (address a) {
        a = makeAddr(string.concat("capped-fork-agent-", vm.toString(_n++)));
    }

    function _path(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        (path[0], path[1]) = (a, b);
    }

    /// @dev The module, the token naming it (refPool for a non-WBNB quote), bound; then graduated into a real pair.
    function _token(address quote_, address refPool, uint256 cap) internal {
        quote = quote_;
        address[] memory payees = new address[](2);
        (payees[0], payees[1]) = (dev, kol);
        uint16[] memory shares = new uint16[](2);
        (shares[0], shares[1]) = (7_000, 3_000);
        vm.prank(dev);
        m = GangCappedSplitter(factory.create(quote_, cap, 5_000, 7_000, payees, shares, bytes32(uint256(1))));
        assertEq(m.moduleType(), bytes32("capped-v1"));
        assertTrue(m.keeperServes(quote_));
        vm.prank(dev, dev);
        t = p.create("Capped", "CAP", "l", "m", quote_, refPool, IGangLaunchpad.TaxConfig(TAX, TAX, 4_000, address(m)));
        m.bind(t);
        assertEq(m.token(), t);
        assertEq(m.quote(), quote_);

        bool graduated;
        uint256 per = p.gradAmtOf(t) / 3;
        for (uint256 i; i < 10 && !graduated; i++) {
            address b = _agent();
            deal(quote, b, per);
            vm.startPrank(b, b);
            IERC20(quote).approve(PAD3, type(uint256).max);
            try p.buy(t, per, 0) {} catch {}
            vm.stopPrank();
            (,,,,,, graduated,,,, pair,) = p.curves(t);
        }
        assertTrue(graduated, "graduated");
        assertGt(pair.code.length, 0, "a real pair");
    }

    /// @dev Real router trades both ways, then the live keeper role sells the tax into the module.
    function _poolTrades(uint256 rounds) internal {
        address trader = _agent();
        uint256 size = p.gradAmtOf(t) / 10;
        for (uint256 i; i < rounds; i++) {
            deal(quote, trader, IERC20(quote).balanceOf(trader) + size);
            vm.startPrank(trader, trader);
            IERC20(quote).approve(M.PANCAKE_V2_ROUTER, type(uint256).max);
            IERC20(t).approve(M.PANCAKE_V2_ROUTER, type(uint256).max);
            ICappedForkRouter(M.PANCAKE_V2_ROUTER)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    size, 0, _path(quote, t), trader, vm.getBlockTimestamp() + 60
                );
            ICappedForkRouter(M.PANCAKE_V2_ROUTER)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    IERC20(t).balanceOf(trader), 0, _path(t, quote), trader, vm.getBlockTimestamp() + 60
                );
            vm.stopPrank();
            _next(60);
        }
        ICappedForkHandler h = ICappedForkHandler(p.taxHandler());
        uint256 sold;
        for (uint256 i; i < 10; i++) {
            _next(60);
            uint256 chunk = h.maxChunk(t);
            if (chunk == 0) break;
            vm.prank(h.keeper());
            try h.process(t, chunk, 1) {
                sold++;
            } catch {
                break;
            }
        }
        assertGt(sold, 0, "the keeper sold tax");
    }

    function _keeperLoop(uint256 rounds) internal returns (uint256 acts) {
        for (uint256 i; i < rounds; i++) {
            (bool due, uint256 minOut) = m.previewWork();
            if (due) {
                m.work(minOut);
                acts++;
            }
            _next(4 minutes);
        }
    }

    function _crossTheCap(address quote_, address refPool) internal {
        uint256 dev0 = IERC20(quote_).balanceOf(dev);
        uint256 kol0 = IERC20(quote_).balanceOf(kol);
        // a cap the first sold tax crosses, with an odd wei so the crossing split is cut to the wei
        uint256 cap = (quote_ == M.WBNB ? 0.002 ether : 1 ether) + 7;
        _token(quote_, refPool, cap);
        _poolTrades(6);
        assertGt(m.unsplit(), cap * 2, "the tax crosses the cap");
        uint256 dead0 = IERC20(t).balanceOf(DEAD);
        uint256 lp0 = ICappedForkPair(pair).balanceOf(DEAD);
        assertGt(_keeperLoop(120), 2, "the keeper acted");
        m.split();
        assertTrue(m.capReached());
        assertEq(m.paidTotal(), cap);
        uint256 got = IERC20(quote_).balanceOf(dev) - dev0 + IERC20(quote_).balanceOf(kol) - kol0;
        assertEq(got, cap, "the payees: the cap, to the wei");
        assertGt(IERC20(t).balanceOf(DEAD), dead0, "bought back and burned");
        assertGt(ICappedForkPair(pair).balanceOf(DEAD), lp0, "LP locked at 0xdead");
        assertEq(IERC20(t).balanceOf(address(m)), 0);
        assertEq(ICappedForkPair(pair).balanceOf(address(m)), 0);
        assertEq(IERC20(quote_).balanceOf(address(m)), m.buybackLeft() + m.lpLeft() + m.unsplit(), "books = balance");

        // more tax after the cap: none of it to the payees, all of it to the buy-back and liquidity
        uint256 dead1 = IERC20(t).balanceOf(DEAD);
        uint256 lp1 = ICappedForkPair(pair).balanceOf(DEAD);
        uint256 setAside1 = m.buybackLeft() + m.lpLeft();
        _poolTrades(2);
        uint256 incoming = m.unsplit();
        assertGt(incoming, 0, "more tax arrived");
        m.split();
        assertEq(m.buybackLeft() + m.lpLeft(), setAside1 + incoming, "all of it set aside");
        _keeperLoop(60);
        m.split();
        assertEq(IERC20(quote_).balanceOf(dev) - dev0 + IERC20(quote_).balanceOf(kol) - kol0, cap);
        assertGt(IERC20(t).balanceOf(DEAD), dead1, "bought back after the cap");
        assertGt(ICappedForkPair(pair).balanceOf(DEAD), lp1, "liquidity added after the cap");
    }

    function test_wbnb_capThenBuybackAndLp() public {
        if (!_live()) return;
        _crossTheCap(M.WBNB, address(0));
    }

    function test_usdt_capThenBuybackAndLp() public {
        if (!_live()) return;
        _crossTheCap(M.USDT, M.USDT_WBNB_V3);
    }

    /// @dev A token in another quote can't be bound: the cap is counted in its own quote.
    function test_wrongQuoteRefused() public {
        if (!_live()) return;
        address[] memory payees = new address[](1);
        payees[0] = dev;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10_000;
        vm.prank(dev);
        m = GangCappedSplitter(factory.create(M.WBNB, 1 ether, 5_000, 7_000, payees, shares, bytes32(uint256(2))));
        vm.prank(dev, dev);
        t = p.create(
            "Capped", "CAP", "l", "m", M.USDT, M.USDT_WBNB_V3, IGangLaunchpad.TaxConfig(TAX, TAX, 4_000, address(m))
        );
        vm.expectRevert(GangCappedSplitter.WrongQuote.selector);
        m.bind(t);
    }
}
