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
- `script/DeployGangLaunchpad2.s.sol` self-check: `TARGET_GRAD_BNB() == 9 BNB`, and `graduationAmountFor(WBNB, 0,
  6 BNB) == 6 BNB` through the linked library (a 1.0 CurveLogic fails it).

## 6. Rollout

- The pad and CurveLogic change, so the testnet 2.0 is redeployed with its handler, router and modules.
- CLI: a `--grad <6|9|12|15>` option on curve create (default 9), and the target in `gang info`.
- Site: show each token's target and progress from `gradAmt`; never assume 15 BNB.
- Indexer: `GradTargetSet` (or `gradTargetOf`) per 2.0 curve token.
