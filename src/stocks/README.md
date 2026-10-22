# Stocks track (币股轨) · PoC T0

Parallel launchpad for **A / bStock** quotes. **Does not modify** main-track `Launchpad` / `Migrator` / `LaunchToken`.

## Hard rules

- **NO MAINNET** deploy / `--broadcast` to chain 56.
- Tax **never** writes main-track `accruedFees`.
- Test graduation uses **tiny** quote amount (`1e18` MockSPCXB).
- Product default quote on mainnet would be SPCXB `0xbe9D…03E1`; tests use **MockSPCXB**.

## Economics (locked)

| Slice | BPS of notional | Destination |
|-------|-----------------|-------------|
| **Total tax** | **100 (1%)** | split 50/50 below |
| Dividend | 50 (0.5%) | `DividendVault` → holders claim quote |
| Platform | 50 (0.5%) | `PlatformFeeBucket` → 80% buyback-burn GANG / 20% feeVault |
| User-facing | — | 1% = 0.5% dividend + 0.4% GANG burn + 0.1% vault |

## Modules

| Contract | Role |
|----------|------|
| `QuoteRegistry` | Whitelist quote + graduation amount |
| `TaxLaunchToken` | Locked until graduate; pair hooks |
| `DividendVault` | Share accounting + manual claim |
| `PlatformFeeBucket` | Platform 0.5% accrual + 80/20 collect |
| `BuybackBurner` | Stub quote→GANG burn |
| `LaunchpadS` | ERC20-quote curve + 1% split (50/50) |
| `MigratorS` | `TOKEN/quote` pair + LP burn |

## How to test (T0)

```bash
cd /workspace/gang-launchpad
forge test --match-path 'test/stocks/*' -vv
```

Agent gate and wallet cap are **disabled** in the PoC test harness so one wallet can hit graduation.

## Min graduation params (test only)

```
IS_TESTNET_MIN_PARAMS = true
graduationQuoteAmount = 1e18   # 1 MockSPCXB
VIRTUAL_QUOTE ≈ 0.333e18
```

**Do not copy these into mainnet scripts.**

## Next (not this PR)

- Chapel deploy scripts without chain-56 broadcast
- Optional `buyWithBNB` + mock router
- Frontend Stocks env pointing at test addresses

## Chapel deploy (M2 · chainId 97 only)

```bash
# Dry-run (no broadcast)
./script/stocks/deploy-chapel.sh

# Broadcast — requires CHAPEL_PRIVATE_KEY or TESTNET_PRIVATE_KEY
# NEVER use DEPLOYER_PRIVATE_KEY / chain 56
CHAPEL_RPC_URL=https://bsc-testnet-rpc.publicnode.com \
CHAPEL_PRIVATE_KEY=0x… \
./script/stocks/deploy-chapel.sh --broadcast
```

Script asserts `block.chainid == 97` and reverts on 56. Deploys MockSPCXB + MockGANG + MockPairFactory + stocks stack with IS_TESTNET_MIN_PARAMS (graduation 1e18).
