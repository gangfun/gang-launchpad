// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SharedDividendVault} from "../../../src/common/SharedDividendVault.sol";

contract A5Quote is ERC20("Q", "Q") {
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @dev Plays the core for two tokens that share one quote. Keeps an exact (1e18-scaled) model of every holder's units
///      per batch and checks the vault against it after each call.
contract VaultActor is Test {
    SharedDividendVault public vault;
    A5Quote public quote;
    address[2] public tokens = [address(0x7a70), address(0x7a71)];
    address[5] public users = [address(0xA1), address(0xA2), address(0xA3), address(0xA4), address(0xA5)];

    // model
    mapping(uint256 t => mapping(uint256 u => uint256)) public mShares;
    mapping(uint256 t => mapping(uint256 b => mapping(uint256 u => uint256))) public mUnitsX;
    mapping(uint256 t => mapping(uint256 u => uint256)) public claimed;
    mapping(uint256 t => uint256) public quoteIn;
    mapping(uint256 t => uint256) public quoteOut;
    mapping(uint256 t => uint256) public nAccruals;
    uint256 public ops;
    uint256 public maxRatio = 2; // quote per unit, ≤ this (keeps the rounding tolerance simple)

    constructor() {
        quote = new A5Quote();
        vault = new SharedDividendVault(address(this));
        vault.setLaunchpad(address(this), true);
        vault.registerToken(tokens[0], address(quote));
        vault.registerToken(tokens[1], address(quote));
        quote.approve(address(vault), type(uint256).max);
    }

    function _mag(uint256 r) internal pure returns (uint256) {
        uint256 k = r % 6;
        if (k == 0) return 1 + (r >> 8) % 3; // 1..3 wei
        if (k == 1) return 1 + (r >> 8) % 1e9;
        if (k == 2) return 1 + (r >> 8) % 1e18;
        if (k == 3) return 1 + (r >> 8) % 1e24;
        if (k == 4) return 1 + (r >> 8) % 1e27;
        return 1e27 - (r >> 8) % 1e9; // near the supply
    }

    function _snapOther(uint256 t) internal view returns (uint256[5] memory p) {
        for (uint256 i = 0; i < 5; i++) p[i] = vault.pending(tokens[1 - t], users[i]);
    }

    function _checkOther(uint256 t, uint256[5] memory p) internal view {
        for (uint256 i = 0; i < 5; i++) {
            require(vault.pending(tokens[1 - t], users[i]) == p[i], "cross-token leak");
        }
    }

    function setShare(uint256 t, uint256 u, uint256 r) external {
        t %= 2;
        u %= 5;
        uint256 s = r % 4 == 0 ? 0 : _mag(r >> 2);
        uint256[5] memory o = _snapOther(t);
        vault.setShare(tokens[t], users[u], s);
        mShares[t][u] = s;
        ops++;
        _checkOther(t, o);
    }

    function accrue(uint256 t, uint256 r) external {
        t %= 2;
        uint256 ts = vault.totalShares(tokens[t]);
        if (ts == 0) return;
        uint256 units = _mag(r);
        (uint64 open,,) = vault.pipeOf(tokens[t]);
        uint256 b = open == 0 ? 1 : open;
        for (uint256 i = 0; i < 5; i++) {
            if (mShares[t][i] > 0) mUnitsX[t][b][i] += Math.mulDiv(units * 1e18, mShares[t][i], ts);
        }
        uint256[5] memory o = _snapOther(t);
        vault.accrueDividendUnits(tokens[t], units);
        nAccruals[t]++;
        ops++;
        _checkOther(t, o);
    }

    function convert(uint256 t, uint256 r) external {
        t %= 2;
        uint256 unsold = vault.unsoldUnits(tokens[t]);
        if (unsold == 0) return;
        uint256 k = r % 4;
        uint256 units = k == 0 ? unsold : k == 1 ? 1 : 1 + (r >> 2) % unsold;
        uint256 amount = (r >> 100) % (units * maxRatio + 1);
        quote.mint(address(this), amount);
        uint256[5] memory o = _snapOther(t);
        vault.convertDividend(tokens[t], units, amount);
        quoteIn[t] += amount;
        ops++;
        _checkOther(t, o);
    }

    function claim(uint256 t, uint256 u) external {
        t %= 2;
        u %= 5;
        uint256 p = vault.pending(tokens[t], users[u]);
        if (p == 0) return;
        uint256[5] memory o = _snapOther(t);
        uint256 b0 = quote.balanceOf(users[u]);
        vm.prank(users[u]);
        vault.claim(tokens[t]);
        require(quote.balanceOf(users[u]) - b0 == p, "claim != pending");
        claimed[t][u] += p;
        quoteOut[t] += p;
        ops++;
        _checkOther(t, o);
    }

    /// @dev Many accrue/sell cycles in one call (drift / many batches between a holder's touches).
    function cycles(uint256 t, uint256 r) external {
        t %= 2;
        if (vault.totalShares(tokens[t]) == 0) return;
        uint256 n = 1 + r % 40;
        for (uint256 i = 0; i < n; i++) {
            uint256 rr = uint256(keccak256(abi.encode(r, i)));
            this.accrue(t, rr);
            this.convert(t, rr >> 128);
        }
    }

    // ------------------------------------------------------------- views for the invariants
    function exactClaimableX(uint256 t, uint256 u) public view returns (int256) {
        (,, uint64 settled) = vault.pipeOf(tokens[t]);
        uint256 sum;
        for (uint256 b = 1; b <= settled; b++) {
            (uint128 bu,, uint256 bq,,) = vault.batchOf(tokens[t], b);
            sum += Math.mulDiv(mUnitsX[t][b][u], bq, bu);
        }
        return int256(sum) - int256(claimed[t][u] * 1e18);
    }

    function exactUnsettledX(uint256 t, uint256 u) public view returns (uint256 sum) {
        (uint64 open,, uint64 settled) = vault.pipeOf(tokens[t]);
        for (uint256 b = settled + 1; b <= open; b++) {
            sum += mUnitsX[t][b][u];
        }
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 120
contract VaultUnitsInvariantTest is Test {
    VaultActor actor;

    function setUp() public {
        actor = new VaultActor();
        targetContract(address(actor));
        bytes4[] memory sels = new bytes4[](5);
        sels[0] = VaultActor.setShare.selector;
        sels[1] = VaultActor.accrue.selector;
        sels[2] = VaultActor.convert.selector;
        sels[3] = VaultActor.claim.selector;
        sels[4] = VaultActor.cycles.selector;
        targetSelector(FuzzSelector({addr: address(actor), selectors: sels}));
    }

    /// @dev No holder is ever credited more than exactly theirs; and only rounding below it.
    function invariant_exactness() public view {
        SharedDividendVault v = actor.vault();
        for (uint256 t = 0; t < 2; t++) {
            for (uint256 u = 0; u < 5; u++) {
                int256 ex = actor.exactClaimableX(t, u);
                int256 got = int256(v.pending(actor.tokens(t), actor.users(u)) * 1e18);
                assertLe(got, ex + int256(actor.nAccruals(t) * actor.maxRatio() + 1), "over-credited");
                assertGe(got + int256((actor.ops() + 2) * 3e18), ex, "under-credited beyond rounding");
                uint256 pu = v.pendingUnits(actor.tokens(t), actor.users(u));
                assertLe(pu * 1e18, actor.exactUnsettledX(t, u) + actor.nAccruals(t) + 1, "units over");
            }
        }
    }

    /// @dev Per token: quote in − quote out − the selling batch's quote (earmarked) ≥ Σ claimable; Σ units ≤ unsettled.
    function invariant_solvency() public view {
        SharedDividendVault v = actor.vault();
        uint256 owedAll;
        for (uint256 t = 0; t < 2; t++) {
            address tok = actor.tokens(t);
            uint256 owed;
            uint256 units;
            for (uint256 u = 0; u < 5; u++) {
                owed += v.pending(tok, actor.users(u));
                units += v.pendingUnits(tok, actor.users(u));
            }
            (uint64 open, uint64 selling,) = v.pipeOf(tok);
            uint256 sq;
            uint256 su;
            if (selling != 0) (su,, sq,,) = _b(v, tok, selling);
            uint256 ou;
            if (open != 0) (ou,,,,) = _b(v, tok, open);
            assertGe(actor.quoteIn(t) - actor.quoteOut(t), owed + sq, "token insolvent");
            assertLe(units, su + ou, "units > unsettled batches");
            owedAll += owed;
        }
        assertGe(actor.quote().balanceOf(address(v)), owedAll, "vault insolvent");
    }

    /// @dev Sell everything left, then everything is claimable and still backed.
    function invariant_drain() public {
        uint256 snap = vm.snapshotState();
        SharedDividendVault v = actor.vault();
        for (uint256 t = 0; t < 2; t++) {
            address tok = actor.tokens(t);
            uint256 unsold = v.unsoldUnits(tok);
            if (unsold > 0) {
                actor.quote().mint(address(actor), unsold); // the actor is the core; the vault pulls from it
                vm.prank(address(actor));
                v.convertDividend(tok, unsold, unsold);
            }
            uint256 owed;
            for (uint256 u = 0; u < 5; u++) {
                owed += v.pending(tok, actor.users(u));
                assertEq(v.pendingUnits(tok, actor.users(u)), 0, "units left after drain");
            }
            assertLe(owed, actor.quoteIn(t) + unsold - actor.quoteOut(t), "drained token insolvent");
        }
        vm.revertToState(snap);
    }

    function _b(SharedDividendVault v, address tok, uint256 id)
        internal
        view
        returns (uint256 units, uint256 sold, uint256 q, uint256 acc, uint256 cum)
    {
        (uint128 a, uint128 b, uint256 c, uint256 d, uint256 e) = v.batchOf(tok, id);
        return (a, b, c, d, e);
    }
}
