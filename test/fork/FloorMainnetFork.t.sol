// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {GangFloorModule} from "../../src/gang/GangFloorModule.sol";
import {GangFloorModuleFactory} from "../../src/gang/GangFloorModuleFactory.sol";
import {DeployGangFloorModuleFactory} from "../../script/DeployGangFloorModuleFactory.s.sol";
import {Pad3VanitySalt} from "../../script/Pad3VanitySalt.sol";

interface IFloorForkRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IFloorForkHandler {
    function maxChunk(address token) external view returns (uint256);
    function process(address token, uint256 amount, uint256 minQuoteOut) external returns (uint256);
    function keeper() external view returns (address);
}

/// @notice GangFloorModuleFactory on a BSC mainnet fork, against the live GangLaunchpad 3.0 with its abcd (CREATE2)
///         deployer on, its GangTaxHandler and GangHandlerAdmin, and PancakeSwap: deployed by its script — whose
///         mainnet-only checks (3.0, its admin, the Safe as owner, GANG, the abcd deployer) run here for the first time —
///         and allowed by the one Safe call the script prints. An Agent computes its token's address, clones a floor
///         module for it (a cap in the quote, 50% to itself and a KOL until then, a 2% redemption fee), creates the token
///         at that address with createWithSalt, binds it; the curve graduates into a real Pancake pair; pool trades
///         through the real router pay the tax; the live keeper role sells it into the module; the payees get exactly the
///         cap; holders redeem to the wei and the floor rises; once the floor is above the pool price, buying in the pool
///         and redeeming pays more than it costs. Agent IDs are mocked and the wallet cap is off, so a few buyers fill
///         the curve. No broadcast.
/// @dev Needs BSC_RPC_URL (skipped without it). Run each test alone (the script reads process-wide env vars).
contract FloorMainnetForkTest is Test {
    address constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    address constant LIVE_ADMIN = 0xC833CEC2B283759003945C0Bf8C048aB1949Af76;
    address constant GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint16 constant TAX = 300;
    uint16 constant FEE = 200;

    IGangPad p = IGangPad(PAD3);
    DeployGangFloorModuleFactory script;
    GangFloorModuleFactory factory;
    GangFloorModule m;
    address dev = makeAddr("floor-fork-dev");
    address kol = makeAddr("floor-fork-kol");
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
        assertTrue(Pad3Module(payable(PAD3)).vanityDeployer() != address(0), "the abcd deployer is on");
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        vm.prank(SAFE);
        GangLaunchpad3(payable(PAD3)).setWalletCapEnabled(false);
        uint256 pk = uint256(keccak256("floor module fork test: throwaway, never funded"));
        vm.deal(vm.addr(pk), 1 ether);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        vm.setEnv("GANG_PAD2", vm.toString(address(0)));
        vm.setEnv("HANDLER_ADMIN", vm.toString(LIVE_ADMIN));
        vm.setEnv("FLOOR_FACTORY", vm.toString(address(0)));
        vm.setEnv("GANG_QUOTE", vm.toString(GANG));
        // the run: deploys, then check() with every mainnet-only check, checkCode, and prints the one Safe call
        script = new DeployGangFloorModuleFactory();
        factory = script.run();
        assertTrue(script.vanityEnabled(PAD3));
        bytes[] memory batch = script.pendingBatch(LIVE_ADMIN, address(factory));
        assertEq(batch.length, 1, "one Safe call");
        (address to, bytes memory data) = this.cut(batch[0]);
        assertEq(to, LIVE_ADMIN);
        vm.prank(SAFE);
        (bool ok,) = to.call(data);
        assertTrue(ok, "the Safe's call");
        assertEq(script.pendingBatch(LIVE_ADMIN, address(factory)).length, 0);
        script.check(PAD3, LIVE_ADMIN, address(factory));
        assertEq(GangFloorModule(factory.implementation()).gangQuote(), GANG);
        assertTrue(factory.vanityEnabled());
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
        a = makeAddr(string.concat("floor-fork-agent-", vm.toString(_n++)));
    }

    function _path(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        (path[0], path[1]) = (a, b);
    }

    /// @dev The token's address first, the module cloned for it, the token created there (refPool for a non-WBNB
    ///      quote), bound; then graduated into a real pair.
    function _token(address quote_, address refPool, uint256 cap) internal {
        quote = quote_;
        Pad3VanityDeployer vd = Pad3VanityDeployer(Pad3Module(payable(PAD3)).vanityDeployer());
        bytes32 h = vd.tokenInitCodeHash("Floor", "FLR", "m", p.taxHandler(), TAX, TAX, false);
        (bytes32 salt, address at) = Pad3VanitySalt.find(address(vd), dev, h);
        assertEq(uint16(uint160(at)), 0xabcd);
        assertEq(at.code.length, 0, "the token does not exist yet");

        address[] memory payees = new address[](2);
        (payees[0], payees[1]) = (dev, kol);
        uint16[] memory shares = new uint16[](2);
        (shares[0], shares[1]) = (7_000, 3_000);
        vm.prank(dev);
        m = GangFloorModule(factory.create(at, quote_, cap, 5_000, FEE, payees, shares, bytes32(uint256(1))));
        assertEq(m.moduleType(), bytes32("floor-v1"));
        assertEq(m.floorToken(), at);
        assertTrue(m.keeperServes(quote_));

        bytes memory data = abi.encodeWithSignature(
            "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))",
            "Floor",
            "FLR",
            "l",
            "m",
            quote_,
            refPool,
            IGangLaunchpad.TaxConfig(TAX, TAX, 4_000, address(m))
        );
        vm.prank(dev, dev);
        t = Pad3Module(payable(PAD3)).createWithSalt(salt, data);
        assertEq(t, at, "the token is at the address the module was cloned for");
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
            IFloorForkRouter(M.PANCAKE_V2_ROUTER)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    size, 0, _path(quote, t), trader, vm.getBlockTimestamp() + 60
                );
            IFloorForkRouter(M.PANCAKE_V2_ROUTER)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    IERC20(t).balanceOf(trader), 0, _path(t, quote), trader, vm.getBlockTimestamp() + 60
                );
            vm.stopPrank();
            _next(60);
        }
        IFloorForkHandler h = IFloorForkHandler(p.taxHandler());
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

    /// @dev A holder: tokens bought in the pool through the real router, approved to the module.
    function _holder(uint256 spend) internal returns (address who) {
        who = _agent();
        deal(quote, who, spend);
        vm.startPrank(who, who);
        IERC20(quote).approve(M.PANCAKE_V2_ROUTER, type(uint256).max);
        IFloorForkRouter(M.PANCAKE_V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                spend, 0, _path(quote, t), who, vm.getBlockTimestamp() + 60
            );
        IERC20(t).approve(address(m), type(uint256).max);
        vm.stopPrank();
    }

    function _run(address quote_, address refPool) internal {
        uint256 dev0 = IERC20(quote_).balanceOf(dev);
        uint256 kol0 = IERC20(quote_).balanceOf(kol);
        // a cap the first sold tax crosses, with an odd wei so the crossing split is cut to the wei
        uint256 cap = (quote_ == M.WBNB ? 0.002 ether : 1 ether) + 7;
        _token(quote_, refPool, cap);
        _poolTrades(6);
        assertGt(m.unsplit(), cap * 2, "the tax crosses the cap");

        // a redemption before any split: it counts the payees' part and sets it aside, pushing nobody
        address alice = _holder(p.gradAmtOf(t) / 20);
        uint256 a = IERC20(t).balanceOf(alice) / 3;
        uint256 supply = IERC20(t).totalSupply() - IERC20(t).balanceOf(DEAD);
        assertEq(m.floorSupply(), supply);
        uint256 incoming = m.unsplit();
        uint256 treasury = incoming - cap;
        assertEq(m.treasury(), treasury, "the view counts what a split would add");
        uint256 gross = (a * treasury) / supply;
        uint256 out = gross - (gross * FEE) / 10_000;
        (uint256 pOut,) = m.previewRedeem(a);
        assertEq(pOut, out);
        uint256 price0 = m.floorPrice();
        uint256 deadBefore = IERC20(t).balanceOf(DEAD);
        uint256 handlerBefore = IERC20(t).balanceOf(p.taxHandler());
        uint256 q0 = IERC20(quote_).balanceOf(alice);
        vm.prank(alice);
        assertEq(m.redeem(a, out, alice), out);
        assertEq(IERC20(quote_).balanceOf(alice) - q0, out, "paid to the wei");
        assertEq(IERC20(t).balanceOf(DEAD) - deadBefore, a, "all of it to 0xdead");
        assertEq(IERC20(t).balanceOf(p.taxHandler()), handlerBefore, "no tax on a redemption");
        assertEq(m.payeesPending(), cap, "the payees' part set aside");
        assertTrue(m.capReached());
        assertEq(IERC20(quote_).balanceOf(dev) - dev0 + IERC20(quote_).balanceOf(kol) - kol0, 0, "pushed nobody");
        assertGt(m.floorPrice(), price0, "the fee raised the floor");

        // the keeper pushes what was set aside: the payees get exactly the cap
        (bool due,) = m.previewWork();
        assertTrue(due);
        m.work(0);
        assertEq(m.payeesPending(), 0);
        assertEq(
            IERC20(quote_).balanceOf(dev) - dev0 + IERC20(quote_).balanceOf(kol) - kol0, cap, "the cap, to the wei"
        );
        assertEq(IERC20(quote_).balanceOf(address(m)), m.treasuryHeld(), "books = balance");

        // more tax after the cap: all of it is the treasury
        uint256 held1 = m.treasuryHeld();
        _poolTrades(2);
        uint256 more = m.unsplit();
        assertGt(more, 0, "more tax arrived");
        m.split();
        assertEq(m.treasuryHeld(), held1 + more, "all of it to the treasury");
        assertEq(IERC20(quote_).balanceOf(dev) - dev0 + IERC20(quote_).balanceOf(kol) - kol0, cap, "not a wei more");

        // once the floor is above the pool price, buying in the pool and redeeming pays more than it costs: here the
        // treasury is lifted by a gift (anyone may send the quote to the module)
        deal(quote_, address(m), IERC20(quote_).balanceOf(address(m)) + p.gradAmtOf(t) * 50);
        m.split();
        uint256 spend = p.gradAmtOf(t) / 50;
        address arb = _holder(spend);
        uint256 got = IERC20(t).balanceOf(arb);
        (uint256 back,) = m.previewRedeem(got);
        vm.prank(arb);
        m.redeem(got, back, arb);
        assertGt(IERC20(quote_).balanceOf(arb), spend, "the floor above the pool: buying and redeeming pays");
        assertEq(IERC20(quote_).balanceOf(address(m)), m.treasuryHeld(), "books = balance");
    }

    function test_wbnb_launchCapRedeem() public {
        if (!_live()) return;
        _run(M.WBNB, address(0));
    }

    function test_usdt_launchCapRedeem() public {
        if (!_live()) return;
        _run(M.USDT, M.USDT_WBNB_V3);
    }

    /// @dev The factory clones only for an abcd address with no code yet; bind takes only that token.
    function test_factoryAndBindGuards() public {
        if (!_live()) return;
        address[] memory none = new address[](0);
        uint16[] memory noneS = new uint16[](0);
        vm.startPrank(dev);
        vm.expectRevert(GangFloorModuleFactory.BadToken.selector);
        factory.create(address(uint160(0x1234)), M.WBNB, 0, 0, FEE, none, noneS, bytes32(uint256(9)));
        vm.expectRevert(GangFloorModuleFactory.BadToken.selector); // an existing token, wherever it is
        factory.create(GANG, M.WBNB, 0, 0, FEE, none, noneS, bytes32(uint256(9)));
        vm.stopPrank();
        // a token of the same dev at another address is never bound
        Pad3VanityDeployer vd = Pad3VanityDeployer(Pad3Module(payable(PAD3)).vanityDeployer());
        (, address at) = Pad3VanitySalt.find(
            address(vd), dev, vd.tokenInitCodeHash("Floor", "FLR", "m", p.taxHandler(), TAX, TAX, false)
        );
        vm.prank(dev);
        m = GangFloorModule(factory.create(at, M.WBNB, 0, 0, FEE, none, noneS, bytes32(uint256(10))));
        (bytes32 salt2,) = Pad3VanitySalt.find(
            address(vd), dev, vd.tokenInitCodeHash("Decoy", "DCY", "m", p.taxHandler(), TAX, TAX, false)
        );
        bytes memory decoy = abi.encodeWithSignature(
            "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))",
            "Decoy",
            "DCY",
            "l",
            "m",
            M.WBNB,
            address(0),
            IGangLaunchpad.TaxConfig(TAX, TAX, 0, address(m))
        );
        vm.prank(dev, dev);
        address d = Pad3Module(payable(PAD3)).createWithSalt(salt2, decoy);
        vm.expectRevert(GangFloorModule.WrongToken.selector);
        m.bind(d);
    }
}
