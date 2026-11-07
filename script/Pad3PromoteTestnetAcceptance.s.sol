// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";

interface IPromoteAgentIdLite {
    function balanceOf(address) external view returns (uint256);
    function register() external returns (uint256);
}

/// @dev A contract a wallet calls: `buyWithPromoter` must refuse it, for that reason, whatever it names.
contract PromoteAcceptanceCaller {
    bool public refused;

    function buy(address pad, address token, address promoter) external payable {
        try Pad3Module(payable(pad)).buyWithPromoter{value: msg.value}(token, msg.value, 0, promoter) {}
        catch (bytes memory e) {
            refused = bytes4(e) == IGangLaunchpad.TraderNotOrigin.selector;
        }
        (bool ok,) = msg.sender.call{value: address(this).balance}("");
        require(ok, "refund");
    }
}

/// @title Pad3PromoteTestnetAcceptance — the promoter share on BSC testnet, after its upgrade
/// @notice In four runs, because a script's checks only ever run in its simulation:
///         1. `run` (broadcast): the deploy wallet (an Agent ID holder) creates a WBNB curve token with a 20% share for 7
///            days and one without. Throwaway Agent wallets, on the real Agent ID registry and WBNB:
///            - `buyer`: first buy names `promoter`: bound; the fee splits to the wei. Then a plain entry buy, a direct
///              sell and an entry sell all pay. Naming another promoter changes nothing.
///            - `late`: first buy names nobody: never bound afterwards.
///            - `phished`: a contract it calls can't buy this way: refused as TraderNotOrigin, nothing written.
///            - the token without a share: the same buy leaves the creator its whole 70%, and writes no binding.
///            Prints the addresses and the amounts for step 2.
///         2. `verify(t, plain, stranger, owed, kept, plainKept)` (read only, after the broadcast): the terms, the
///            bindings, the refusal and the fee books read back from chain, the books to the wei against the
///            simulation's.
///         3. `claim(t, plain)` (broadcast): the promoter's claim and the creator's two; the pad's WBNB falls by exactly
///            that. `verifyClaim(t, plain, owed, promoterBefore, kept + plainKept, deployerBefore)` (read only) reads back
///            that each got its money.
///         4. `sweep()` (broadcast): what's left of the gas money back to the deploy wallet, from real balances.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, GANG_PAD3. Wallet keys derive from DEPLOYER_PRIVATE_KEY. Broadcast with
///      --slow --legacy --with-gas-price 100000000. Runs again with the same key.
contract Pad3PromoteTestnetAcceptance is Script {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant BPS = 10_000;
    uint16 internal constant SHARE = 2_000;
    uint32 internal constant WINDOW = 7 days;
    uint256 internal constant GROSS = 0.001 ether;
    uint256 internal constant GAS_MONEY = 0.01 ether;

    error Check(string what);

    GangLaunchpad3 internal p3;
    Pad3Module internal pm;
    IPromoteAgentIdLite internal agents;
    IERC20 internal wbnb;
    uint256 internal deployerPk;
    address internal deployer;

    function run() external {
        _env();
        if (!p3.isAgent(deployer)) revert Check("deploy wallet holds no Agent ID");

        uint256 buyerPk = _key("buyer");
        uint256 promoterPk = _key("promoter");
        uint256 latePk = _key("late");
        uint256 phishedPk = _key("phished");
        uint256 otherPk = _key("other");
        address buyer = vm.addr(buyerPk);
        address promoter = vm.addr(promoterPk);
        address other = vm.addr(otherPk);
        _ready(buyerPk);
        _ready(promoterPk);
        _ready(latePk);
        _ready(phishedPk);
        _ready(otherPk);

        vm.startBroadcast(deployerPk);
        address t = pm.createWithPromote(
            "Promote Acceptance",
            "PROMO",
            "",
            "",
            address(0),
            address(0),
            IGangLaunchpad.TaxConfig({buyTaxBps: 0, sellTaxBps: 0, dividendBps: 0, recipient: address(0)}),
            6 ether,
            SHARE,
            WINDOW
        );
        address plain = p3.createWithGradTarget(
            "Promote Acceptance Plain",
            "PLAIN",
            "",
            "",
            address(0),
            address(0),
            IGangLaunchpad.TaxConfig({buyTaxBps: 0, sellTaxBps: 0, dividendBps: 0, recipient: address(0)}),
            6 ether
        );
        vm.stopBroadcast();
        console.log("token with a share", t);
        console.log("token without one", plain);
        (uint16 share, uint32 window) = pm.promoteOf(t);
        _is(share == SHARE && window == WINDOW, "terms");

        // the first buy names the promoter: bound, and it already pays
        _is(pm.canBind(t, buyer, promoter), "canBind before the first buy");
        vm.startBroadcast(buyerPk);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);
        vm.stopBroadcast();
        (address bound, uint40 at, bool traded) = pm.bindingOf(t, buyer);
        _is(bound == promoter && at != 0 && traded, "bound");
        _is(pm.promoterFeeOf(t, promoter) == _cut(GROSS), "first buy pays the promoter");
        _is(p3.creatorFeeOf(t) == _creatorPart(GROSS) - _cut(GROSS), "the creator keeps the rest");

        // the entry's plain buy pays; another promoter changes nothing
        uint256 owed = pm.promoterFeeOf(t, promoter);
        vm.startBroadcast(buyerPk);
        p3.buyTokenAMAP{value: GROSS}(t, buyer, GROSS, 0);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, other);
        vm.stopBroadcast();
        (bound,,) = pm.bindingOf(t, buyer);
        _is(bound == promoter, "the first promoter stays");
        _is(pm.promoterFeeOf(t, other) == 0, "the other promoter gets nothing");
        _is(pm.promoterFeeOf(t, promoter) - owed == 2 * _cut(GROSS), "later buys pay");

        // both sells pay
        owed = pm.promoterFeeOf(t, promoter);
        uint256 part = IERC20(t).balanceOf(buyer) / 4;
        vm.startBroadcast(buyerPk);
        IERC20(t).approve(address(p3), part * 2);
        p3.sell(t, part, 0);
        _is(pm.promoterFeeOf(t, promoter) > owed, "a direct sell pays");
        owed = pm.promoterFeeOf(t, promoter);
        p3.sellToken(0, t, buyer, part, 0, 0, address(0));
        vm.stopBroadcast();
        _is(pm.promoterFeeOf(t, promoter) > owed, "an entry sell pays");

        // a first trade without a promoter: never bound afterwards
        address late = vm.addr(latePk);
        owed = pm.promoterFeeOf(t, promoter);
        vm.startBroadcast(latePk);
        p3.buyTokenAMAP{value: GROSS}(t, late, GROSS, 0);
        vm.stopBroadcast();
        _is(!pm.canBind(t, late, promoter), "canBind after a plain first trade");
        vm.startBroadcast(latePk);
        pm.buyWithPromoter{value: GROSS}(t, GROSS, 0, promoter);
        vm.stopBroadcast();
        (bound,, traded) = pm.bindingOf(t, late);
        _is(bound == address(0) && traded, "not bound after a plain first trade");
        _is(pm.promoterFeeOf(t, promoter) == owed, "an unbound wallet's trades pay no promoter");

        // a contract the wallet calls can't name a promoter for it
        address phished = vm.addr(phishedPk);
        vm.startBroadcast(deployerPk);
        PromoteAcceptanceCaller stranger = new PromoteAcceptanceCaller();
        vm.stopBroadcast();
        vm.startBroadcast(phishedPk);
        stranger.buy{value: GROSS}(address(p3), t, other);
        vm.stopBroadcast();
        (bound,, traded) = pm.bindingOf(t, phished);
        _is(stranger.refused(), "a contract is refused");
        _is(bound == address(0) && !traded, "nothing written for the wallet");
        _is(pm.promoterFeeOf(t, other) == 0, "its promoter gets nothing");

        // a token without a share: as before
        vm.startBroadcast(buyerPk);
        pm.buyWithPromoter{value: GROSS}(plain, GROSS, 0, promoter);
        vm.stopBroadcast();
        (bound,, traded) = pm.bindingOf(plain, buyer);
        _is(bound == address(0) && !traded, "nothing written on a token without a share");
        _is(p3.creatorFeeOf(plain) == _creatorPart(GROSS), "the creator's whole 70%");
        _is(pm.promoterFeeOf(plain, promoter) == 0, "no promoter earns on a token without a share");

        console.log("t", t);
        console.log("plain", plain);
        console.log("stranger", address(stranger));
        console.log("owed", pm.promoterFeeOf(t, promoter));
        console.log("kept", p3.creatorFeeOf(t));
        console.log("plainKept", p3.creatorFeeOf(plain));
        console.log("next: verify(t, plain, stranger, owed, kept, plainKept), then claim(t, plain), then sweep()");
    }

    /// @notice Step 2, read only: what `run` did, read from chain.
    function verify(address t, address plain, address stranger, uint256 owed, uint256 kept, uint256 plainKept)
        external
    {
        _env();
        address promoter = vm.addr(_key("promoter"));
        address other = vm.addr(_key("other"));
        (uint16 share, uint32 window) = pm.promoteOf(t);
        _is(share == SHARE && window == WINDOW, "terms on chain");
        (uint16 plainShare,) = pm.promoteOf(plain);
        _is(plainShare == 0, "no terms on the plain token");
        (address bound, uint40 at, bool traded) = pm.bindingOf(t, vm.addr(_key("buyer")));
        _is(
            bound == promoter && uint256(at) + WINDOW > block.timestamp && at <= block.timestamp && traded,
            "buyer bound on chain"
        );
        (bound,, traded) = pm.bindingOf(t, vm.addr(_key("late")));
        _is(bound == address(0) && traded, "late not bound on chain");
        (bound,, traded) = pm.bindingOf(t, vm.addr(_key("phished")));
        _is(bound == address(0) && !traded, "nothing written for phished on chain");
        _is(PromoteAcceptanceCaller(stranger).refused(), "the contract refused as TraderNotOrigin on chain");
        (bound,, traded) = pm.bindingOf(plain, vm.addr(_key("buyer")));
        _is(bound == address(0) && !traded, "nothing written on the plain token on chain");
        _is(pm.promoterFeeOf(t, other) == 0, "the other promoter earned nothing on chain");
        _is(pm.promoterFeeOf(plain, promoter) == 0, "no promoter earned on the plain token on chain");
        _is(pm.promoterFeeOf(t, promoter) == owed, "promoter's fee on chain, to the wei");
        _is(p3.creatorFeeOf(t) == kept, "creator's fee on chain, to the wei");
        _is(p3.creatorFeeOf(plain) == plainKept && plainKept == _creatorPart(GROSS), "plain token's fee on chain");
        console.log("verified on chain");
    }

    /// @notice Step 3: both claims. Checked in the simulation; `verifyClaim` reads them from chain.
    function claim(address t, address plain) external {
        _env();
        uint256 promoterPk = _key("promoter");
        address promoter = vm.addr(promoterPk);
        uint256 owed = pm.promoterFeeOf(t, promoter);
        uint256 kept = p3.creatorFeeOf(t);
        uint256 plainKept = p3.creatorFeeOf(plain);
        uint256 promoterBefore = wbnb.balanceOf(promoter);
        uint256 padBefore = wbnb.balanceOf(address(p3));
        uint256 deployerBefore = wbnb.balanceOf(deployer);
        console.log("promoterBefore", promoterBefore);
        console.log("deployerBefore", deployerBefore);
        vm.startBroadcast(promoterPk);
        pm.claimPromoterFee(t, promoter);
        vm.stopBroadcast();
        vm.startBroadcast(deployerPk);
        p3.claimCreatorFee(t, deployer);
        p3.claimCreatorFee(plain, deployer);
        vm.stopBroadcast();
        _is(wbnb.balanceOf(promoter) - promoterBefore == owed, "the promoter's claim");
        _is(padBefore - wbnb.balanceOf(address(p3)) == owed + kept + plainKept, "the pad paid what was owed");
    }

    /// @notice Read only: the claims, from chain: each got its money, the books are clear.
    function verifyClaim(
        address t,
        address plain,
        uint256 owed,
        uint256 promoterBefore,
        uint256 creatorOwed,
        uint256 deployerBefore
    ) external {
        _env();
        address promoter = vm.addr(_key("promoter"));
        _is(wbnb.balanceOf(promoter) - promoterBefore == owed, "the promoter's claim on chain");
        _is(wbnb.balanceOf(deployer) - deployerBefore == creatorOwed, "the creator's claims on chain");
        _is(pm.promoterFeeOf(t, promoter) == 0, "promoter's book cleared on chain");
        _is(p3.creatorFeeOf(t) == 0 && p3.creatorFeeOf(plain) == 0, "creator's books cleared on chain");
        console.log("claims verified on chain");
    }

    /// @notice Step 4: the throwaway wallets' real balances back to the deploy wallet.
    function sweep() external {
        _env();
        string[5] memory names = ["buyer", "promoter", "late", "phished", "other"];
        uint256 fee = 21_000 * 100_000_000; // --with-gas-price 100000000
        uint256 total;
        for (uint256 i; i < 5; i++) {
            uint256 pk = _key(names[i]);
            address who = vm.addr(pk);
            if (who.balance <= 2 * fee) continue;
            uint256 amount = who.balance - 2 * fee;
            vm.startBroadcast(pk);
            (bool ok,) = deployer.call{value: amount}("");
            vm.stopBroadcast();
            _is(ok, "sweep");
            total += amount;
        }
        console.log("swept", total);
    }

    function _env() internal {
        if (block.chainid != 97) revert Check("testnet only");
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPk);
        p3 = GangLaunchpad3(payable(vm.envAddress("GANG_PAD3")));
        pm = Pad3Module(payable(address(p3)));
        agents = IPromoteAgentIdLite(address(p3.agentIdRegistry()));
        wbnb = IERC20(p3.wbnb());
    }

    function _is(bool ok, string memory what) internal pure {
        if (!ok) revert Check(what);
    }

    function _creatorPart(uint256 gross) internal pure returns (uint256) {
        return (((gross * 100) / BPS) * 7_000) / BPS;
    }

    function _cut(uint256 gross) internal pure returns (uint256) {
        return (_creatorPart(gross) * SHARE) / BPS;
    }

    function _key(string memory name) internal view returns (uint256) {
        return (uint256(keccak256(abi.encode(deployerPk, "gang-promote-testnet", name))) % (SECP256K1_N - 1)) + 1;
    }

    /// @dev Gas money, and an Agent ID (anyone can `register()` on testnet's registry).
    function _ready(uint256 pk) internal {
        address who = vm.addr(pk);
        if (who.balance < GAS_MONEY) {
            vm.startBroadcast(deployerPk);
            (bool ok,) = who.call{value: GAS_MONEY - who.balance}("");
            vm.stopBroadcast();
            _is(ok, "gas money");
        }
        if (agents.balanceOf(who) == 0) {
            vm.startBroadcast(pk);
            agents.register();
            vm.stopBroadcast();
        }
    }
}
