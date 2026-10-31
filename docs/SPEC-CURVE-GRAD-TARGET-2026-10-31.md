# V3 curve: graduation target picked by the creator (GangLaunchpad 2.0)

2026-10-31. Ships with the creator fee in GangLaunchpad 2.0 (`docs/SPEC-CURVE-CREATOR-FEE-2026-10-31.md`). 1.0 is
unchanged: every 1.0 curve graduates at 15 BNB.

## 1. Why

Devs reported that curves rarely graduate. A 1.0 curve graduates at a 15 BNB raise, which is a market cap of about
75 BNB. 2.0 lets the creator pick a lower target, and lowers the default.

## 2. Rules

- The target is BNB raised on the curve. It is one of **6 / 9 / 12 / 15 BNB** (`GRAD_BNB_TIERS()`). Any other value
  reverts `BadGradTarget()`.
- `create(...)` (the 1.0 signature) takes the default, **9 BNB** (`TARGET_GRAD_BNB()`).
- `createWithGradTarget(..., tax, gradBnb)` takes the creator's pick. Every other check of `create` applies unchanged:
  Agent gate, tax config, quote listing, reference pool.
- A non-WBNB quote converts the target as the fixed 15 BNB was converted. A QuoteRegistry rate ("15 BNB worth") is
  scaled to the target. A reference pool prices the target directly.
- The curve keeps its shape. The virtual quote is target / 3, and 800M tokens are sold on the curve. The market cap at
  graduation is about 5x the target:

| Target (BNB raised) | Start market cap (BNB) | Graduation market cap (BNB) | Pool at graduation |
|---|---|---|---|
| 6 | ≈ 1.9 | ≈ 30 | ≈ 6 BNB + 200M tokens |
| 9 (default) | ≈ 2.8 | ≈ 45 | ≈ 9 BNB + 200M tokens |
| 12 | ≈ 3.8 | ≈ 60 | ≈ 12 BNB + 200M tokens |
| 15 (1.0) | ≈ 4.7 | ≈ 75 | ≈ 15 BNB + 200M tokens |

- The 1% wallet cap is per token supply, so graduation still needs at least 80 wallets at every target.
- 打新 is unchanged (its raise is already the creator's pick, 5-50 BNB).

## 3. Interface (2.0 pad)

- `createWithGradTarget(string name, string symbol, string logoURI, string metaURI, address quote, address refPool,
  TaxConfig tax, uint256 gradBnb) returns (address token)`
- `gradTargetOf(address token) view returns (uint256)`: the picked target in BNB; 0 for a token that isn't a curve
  token of this pad.
- `graduationAmountFor(address quote, address refPool, uint256 gradBnb) view returns (uint256)`: what
  `createWithGradTarget` would lock, in the quote.
- `graduationAmountOf(address quote, address refPool)`: same signature as 1.0, now for the default target.
- `GRAD_BNB_TIERS() pure returns (uint256[4])`; `TARGET_GRAD_BNB()` = 9 BNB (1.0: 15 BNB).
- Event `GradTargetSet(address indexed token, uint256 gradBnb)`, after `Created` and `TaxConfigured`.
- Error `BadGradTarget()`.
- Unchanged: `curves()` layout, `Created` (its `gradAmt` is the target in the quote), `gradAmtOf`,
  `graduationRemaining`.

Readers should take each token's `gradAmt` (or `gradTargetOf`) and must not assume 15 BNB.

## 4. Risks

- **Thinner pools at low targets.** A 6 BNB target opens the pool with about 6 BNB of liquidity, so the first pool
  trades move the price more. The minimum stays at 6 BNB for this reason.
- **Cheaper self-graduation.** A creator can graduate its own token for less (still across 80+ wallets). With the 70%
  creator fee, a 6 BNB wash costs about 0.3% of the volume. Graduation by itself pays the creator nothing.
- **Earlier snipes buy more of the supply per BNB.** The cap of 10M tokens per wallet is reached with less BNB at a low
  target (about 0.02 BNB at the start of a 6 BNB curve, against about 0.05 BNB at 15 BNB).

## 5. Tests

- `test/gang/GradTarget.t.sol`:
  - the constants and tiers;
  - default 9 BNB;
  - each tier locks its amount and virtual quote, and the view equals what create locks;
  - a registry quote scales;
  - off-tier values revert in create and in the view;
  - create's other checks still apply;
  - each tier graduates at its target with the pool at about 5x the target.
- `test/gang/GradTargetPricing.t.sol` (from the audit's PoCs):
  - every tier needs 80+ wallets;
  - `create` equals a picked 9 BNB;
  - a taxed dividend token at 6 BNB graduates and its pool tax is processed;
  - reference and bridge pools scale linearly, with the same 1 BNB depth floor at every tier;
  - the `MIN_GRAD_AMT` edge of a registry rate;
  - rounding of a registry amount.
- `invariant_v3GradTargetFixed` (CoreInvariants; half the created curves pick a target): the target is a tier,
  `gradAmt` is the view's price of it, and the virtual quote is `gradAmt / 3`.
- `script/DeployGangLaunchpad2.s.sol` self-check, all through the linked library (a 1.0 CurveLogic fails before Safe
  batch 1):
  - `TARGET_GRAD_BNB() == 9 BNB`;
  - `graduationAmountFor(WBNB, 0, 6 BNB) == 6 BNB`;
  - `graduationAmountFor(WBNB, 0, 10 BNB)` reverts `BadGradTarget`.

## 6. Rollout

- The pad and CurveLogic change, so the testnet 2.0 is redeployed with its handler, router and modules.
- CLI: a `--grad <6|9|12|15>` option on curve create (default 9), and the target in `gang info`.
- Site: show each token's target and progress from `gradAmt`; never assume 15 BNB.
- Indexer: `GradTargetSet` (or `gradTargetOf`) per 2.0 curve token.

## 7. Audit record

2026-10-31, independent audit of the first commit of this change: no finding above info. The info items were
addressed:
- the tier list now has one definition (`CurveLogic.MIN_GRAD_BNB` / `MAX_GRAD_BNB` / `GRAD_BNB_STEP`);
- the deploy self-check gained the off-tier probe;
- the library-check message names the 1.0-library case;
- the event tests check the token topic;
- the invariant checks the virtual quote;
- the PoCs became `GradTargetPricing.t.sol`;
- stale 15 BNB comments are fixed.

Left for the CLI release: the skill / CLI docs still say 15 BNB. The CLI should preview with `graduationAmountFor`, so
a creator sees a `GradAmtTooSmall` quote before sending.

## 8. Full audit of 2.0 (both features together)

2026-10-31. Three independent audits of all of GangLaunchpad 2.0 at `7e450b8` against the 1.0 source (`68c8312`):
- **A, the curve core:** pad, CurveLogic, FairLogic, PadCommon, PoolCheck, migrator;
- **B, after graduation:** token, tax handler, vault, bucket, modules, GangBond, registry, gateway, router;
- **C, the mainnet deployment path:** scripts, Safe batches, self-checks.

None found anything at medium or above. The lows are fixed:

| Finding | Fix |
|---|---|
| A L-1: no upper bound on the graduation amount / 打新 raise in the quote. Above uint112 the Pancake pair can't take it, so the curve never graduates (the sale never launches). 1.0 has the same gap; 2.0 adds a motive, the 0.7% creator fee on a curve that never ends. | `MAX_QUOTE_AMOUNT = type(uint112).max / 4` (room for donations to the pair). Create (both kinds), `graduationAmountFor` / `graduationAmountOf` and `previewCreate` revert `QuoteAmountTooLarge()` above it. |
| C L-1: in phase 2 before the listing, a pad the deploy key doesn't own could reach Safe batch 1. | Before batch 1, the pad and handler must have been deployed by this deployer (one of its CREATE addresses), still be owned by it, and have no hand-over started. |
| C L-2: the buy-back script, run while the handler hand-over is half done, made the deployer the new admin's owner. | On mainnet the Safe must hold the handler with nothing pending, `ADMIN_OWNER` must be empty or the Safe, and the admin must be owned by the Safe. |
| C L-3: the four module scripts pinned 1.0, and a leftover `GANG_PAD` = 1.0 in a 2.0 shell could bind a new GangBond to 1.0 for good. | `GangModulePadScript`: on mainnet the scripts read only `GANG_PAD2`. It must be a 2.0 pad (`CREATOR_FEE_SHARE_BPS` 7000), not 1.0, in the live pad registry, and owned by the Safe. |
| C info-1: phase 2 refused once a GangHandlerAdmin held the handler. | A GangHandlerAdmin over the handler, owned by the Safe, is accepted as its holder. |
| C info-5: a pending bucket keeper change was not checked. | Phase 1 refuses one. |

Info items left as they are:
- B: thin pools take proportionally more keeper rounds to sell a given absolute tax.
- B: keepers should use a near-quote `minQuoteOut`.
- B: the creator can claim the creator fee into its own module.
- A: a creator-supplied quote makes the BNB target cosmetic. Show `gradAmt` and the quote, not only `gradTargetOf`.
- C: `TWAP_WINDOW=0` fails closed.

Tests added:
- `GradTargetPricing.t.sol` `test_quoteAmountAboveCap_refused`;
- `test/fork/GangLaunchpad2DeployGuardsFork.t.sol`, on a mainnet fork, covering:
  - a foreign pad refused before batch 1;
  - our own pad with a hand-over started, refused;
  - phase 2 with an admin holding the handler;
  - a pending bucket keeper;
  - the buy-back guards;
  - the module scripts binding only to 2.0.
