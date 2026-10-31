// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../../src/common/SharedPlatformFeeBucket.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {GangMintToken} from "../../src/flywheel/GangMintToken.sol";
import {MintTokenDeployer} from "../../src/flywheel/MintTokenDeployer.sol";
import {FlywheelTaxHandler} from "../../src/flywheel/FlywheelTaxHandler.sol";
import {GangFlywheelPad} from "../../src/flywheel/GangFlywheelPad.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {TwapMockPair, TwapMockPairFactory} from "../mocks/TwapMockPair.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";
import {MockWBNB} from "../mocks/MockWBNB.sol";

/// @notice The continuous-mint deployment on mocks: GangFlywheelPad (+ its two libraries, linked by forge),
///         FlywheelTaxHandler, MintTokenDeployer over the shared vault, bucket, migrator and registry, seeding
///         K-checked pairs that keep cumulative prices (TwapMockPair). Wired in the deploy order, `setMigrator` last.
abstract contract FlywheelFixture is Test {
    uint256 internal constant TPS = 100_000 ether;
    uint256 internal constant SHARES = 10_000;

    MockWBNB public wbnb;
    MockAgentId public agents;
    TwapMockPairFactory public factory;
    QuoteRegistry public quoteRegistry;
    SharedPlatformFeeBucket public bucket;
    SharedDividendVault public vault;
    SharedMigrator public migrator;
    MintTokenDeployer public deployer;
    FlywheelTaxHandler public handler;
    GangFlywheelPad public pad;

    address public owner = makeAddr("owner");
    address public feeVault = makeAddr("feeVault");
    address public keeper = makeAddr("keeper");
    address public dev;

    uint256 internal _nonce;

    function _deploy() internal {
        wbnb = new MockWBNB();
        vm.deal(address(wbnb), 1_000_000 ether); // backs unwraps of faucet-minted WBNB
        agents = new MockAgentId();
        factory = new TwapMockPairFactory();
        quoteRegistry = new QuoteRegistry(owner);
        bucket = new SharedPlatformFeeBucket(owner, feeVault);
        vault = new SharedDividendVault(owner);
        migrator = new SharedMigrator(owner, address(factory));
        deployer = new MintTokenDeployer(owner);
        handler = new FlywheelTaxHandler(owner, address(vault), address(bucket), address(0));
        pad = new GangFlywheelPad(
            owner,
            address(quoteRegistry),
            address(vault),
            address(bucket),
            address(handler),
            address(deployer),
            address(wbnb),
            address(factory)
        );
        vm.startPrank(owner);
        bucket.setOperator(address(pad), true);
        bucket.setOperator(address(handler), true);
        vault.setLaunchpad(address(pad), true);
        vault.setOperator(address(handler), address(pad));
        vault.setExcluded(address(migrator), true);
        vault.setExcluded(address(bucket), true);
        migrator.addLaunchpad(address(pad));
        deployer.setLaunchpad(address(pad), true);
        handler.setLaunchpad(address(pad));
        handler.setKeeper(keeper);
        pad.setAgentGate(true, address(agents));
        pad.setMigrator(address(migrator));
        vm.stopPrank();
        dev = _newAgent();
    }

    // ------------------------------------------------------------ actors
    function _newAgent() internal returns (address who) {
        who = address(uint160(uint256(keccak256(abi.encode("fly-agent", _nonce++)))));
        agents.mint(who, _nonce);
        vm.deal(who, 1_000 ether);
        wbnb.mintUnlimited(who, 1_000 ether);
        vm.prank(who);
        wbnb.approve(address(pad), type(uint256).max);
    }

    function _plain() internal returns (address who) {
        who = address(uint160(uint256(keccak256(abi.encode("fly-plain", _nonce++)))));
        vm.deal(who, 1_000 ether);
        wbnb.mintUnlimited(who, 1_000 ether);
        vm.prank(who);
        wbnb.approve(address(pad), type(uint256).max);
    }

    // ------------------------------------------------------------ configs
    /// @dev The "Agent Mint" (J) preset: 20 BNB raise, quota 10 + 1 per invite, standard tiers, 10% dev, 30% buy, 2%
    ///      sell; V2 post rules: guard off, 30-minute TWAP window.
    function _agentMint() internal pure returns (IFlywheelPad.FlyConfig memory c) {
        c = IFlywheelPad.FlyConfig({
            raiseBnb: 20 ether,
            baseQuota: 10,
            inviteBonus: 1,
            maxPerTx: 10,
            holdBps: 6_000,
            mintFeeBps: 100,
            exitFeeBps: 100,
            devCutBps: 1_000,
            buyBps: 3_000,
            sellTaxBps: 200,
            launchDelay: 60,
            window: 600,
            windowCapMul: 1,
            postMint: true,
            tierMode: 1,
            stepBps: 0,
            stepShares: 0,
            maxMulX100: 0,
            supplyCapMul: 100,
            guardBps: 0,
            twapWindow: 1800
        });
    }

    /// @dev The widest quota V2 allows with post-launch minting: 10, as the J preset (1,000 wallets fill the sale; V1
    ///      suites used 100). Guard off and a 30-minute window, as in `_agentMint`: the most permissive post rules.
    function _wide() internal pure returns (IFlywheelPad.FlyConfig memory c) {
        c = _agentMint();
        c.baseQuota = 10;
    }

    function _create(IFlywheelPad.FlyConfig memory c, uint256 devShares) internal returns (address t) {
        string[4] memory text = ["Fly", "FLY", "ipfs://logo", "ipfs://meta"];
        vm.prank(dev);
        t = pad.create(text, address(0), address(0), c, devShares);
    }

    // ------------------------------------------------------------ drive
    function _sale(address t) internal view returns (IFlywheelPad.Sale memory) {
        return pad.sales(t);
    }

    /// @dev Fresh Agents mint as much as one mint takes until the sale is filled.
    function _fill(address t) internal {
        for (uint256 i; i < 2_000 && _sale(t).filledAt == 0; i++) {
            address w = _newAgent();
            uint256 n = _sale(t).maxPerTx;
            vm.startPrank(w);
            while (pad.quotaLeft(t, w) > 0 && _sale(t).filledAt == 0) pad.mint(t, n, 1, address(0));
            vm.stopPrank();
        }
        require(_sale(t).filledAt != 0, "fixture: not filled");
    }

    function _fillAndLaunch(address t) internal {
        _fill(t);
        if (!_sale(t).launched) {
            vm.warp(vm.getBlockTimestamp() + _sale(t).launchDelay);
            pad.launch(t);
        }
    }

    // ------------------------------------------------------------ pool (Pancake V2 amounts, K-checked)
    function _amountOut(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 inFee = amountIn * 9975;
        return (inFee * rOut) / (rIn * 10_000 + inFee);
    }

    function _res(address t) internal view returns (uint256 rT, uint256 rQ) {
        TwapMockPair p = TwapMockPair(_sale(t).pair);
        (uint112 r0, uint112 r1,) = p.getReserves();
        (rT, rQ) = p.token0() == t ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _price(address t) internal view returns (uint256) {
        (uint256 rT, uint256 rQ) = _res(t);
        return (rQ * 1e18) / rT;
    }

    /// @dev Pool buy of `quoteIn` for `who` (the pair's gross output; `who` receives it less the buy tax).
    function _poolBuy(address t, address who, uint256 quoteIn) internal returns (uint256 out) {
        TwapMockPair p = TwapMockPair(_sale(t).pair);
        (uint256 rT, uint256 rQ) = _res(t);
        out = _amountOut(quoteIn, rQ, rT);
        wbnb.mintUnlimited(address(p), quoteIn);
        bool t0 = p.token0() == t;
        p.swap(t0 ? out : 0, t0 ? 0 : out, who, "");
    }

    /// @dev Pool sell of `amount` by `who` (taxed by the token; the swap-back chunk may run first). Returns quote out.
    function _poolSell(address t, address who, uint256 amount) internal returns (uint256 out) {
        TwapMockPair p = TwapMockPair(_sale(t).pair);
        vm.prank(who);
        IERC20(t).transfer(address(p), amount);
        (uint256 rT, uint256 rQ) = _res(t);
        uint256 inAmt = IERC20(t).balanceOf(address(p)) - rT;
        out = _amountOut(inAmt, rT, rQ);
        bool t0 = p.token0() == t;
        p.swap(t0 ? 0 : out, t0 ? out : 0, who, "");
    }
}
