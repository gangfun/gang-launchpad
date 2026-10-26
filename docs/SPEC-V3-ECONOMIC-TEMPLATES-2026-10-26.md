# 规格 · LaunchpadV3 经济模型模版（对标 Flap vault）

> **已被取代（2026-10-26）**：改为「税收接收地址」方案，见 `SPEC-V3-TAX-RECIPIENT-2026-10-26.md`。模版工厂、模版作者分成已从代码中删除，本页仅作历史记录。

- 日期：2026-10-26 Asia/Shanghai
- 作者：Claude（本页为产品规格 + 接口草案；**非执行单**）
- 性质：**禁止主网广播**。合约已在 `feat/v3-economic-templates` 分支实现并通过 mock 单测，**未审计、未上测试网**。
- 来源：用户反馈「想要 Agent dev marketplace，像 flap 的自定义模版一样自定义经济模型」。
- 已拍板：① 模版**平台限定**（白名单）；④ 内盘税**可开可关**。
- 待批（Claude 建议）：② 平台 / 作者分成；③ 税率档位。

---

## 0. 一句话产品

发币时 Agent 选一个**平台上架的经济模型模版**和税率；每笔税 **30% 归平台、70% 归这个币**，70% 里按创建时定好的比例分给持币人分红和模版金库。V2 的「有税 / 无税」两轨变成 V3 的两个特例。

---

## 1. 规则

### 1.1 税率（待批）

| 项 | 规则 |
|---|---|
| 档位 | `taxBps ∈ {0, 100, 200, 300, 500}`；0 = 无税 |
| 可变性 | 创建时定死，终身不可改（不给调高税跑路的口子） |
| 不开 10% 的理由 | Agent 准入 + 1% 持仓上限的定位偏克制；来回 20% 会赶走套利与量化，检测工具也会标高风险 |

### 1.2 分账（待批）

每笔税（报价币计）：

| 去向 | 平台写的模版 | 外部作者写的模版 |
|---|---|---|
| 平台（PlatformFeeBucket → 80% 回购 GANG / 20% feeVault） | 30% | 20% |
| 模版作者（`owed`，拉取） | — | 10% |
| 代币侧：`dividendBps` → DividendVault，其余 → 模版金库 | 70% | 70% |

- 按比例抽，不按固定点数：税越高平台越多，利益一致；对 Agent 只有一个数要记。
- **对比 V2**：V2 有税轨平台拿外盘税 50%。V3 统一 30% 后，1% 档平台收入从成交额 0.5% 降到 0.3%。如要保住，可改成「1% 档平台 50%、其余 30%」——规则会变复杂，Claude 倾向统一 30%。
- 常量：`TaxRouterV3.PLATFORM_SHARE_BPS = 3000`、`AUTHOR_SHARE_BPS = 1000`（相对整笔税）。

| 档位 | 平台（成交额） | 代币侧（成交额） |
|---|---|---|
| 1% | 0.3% | 0.7% |
| 2% | 0.6% | 1.4% |
| 3% | 0.9% | 2.1% |
| 5% | 1.5% | 3.5% |

### 1.3 内盘税（已拍板：可开可关）

- `TaxConfig.bondingTax = true` 时，内盘买卖在 1% 协议费之外再收 `taxBps`，同样走 TaxRouterV3 的 70/30。
- 不单独设内盘档位，与外盘同一个 `taxBps`。
- 税先扣再入曲线 → 开了内盘税的币毕业略慢（目标仍 ≈15 BNB）。
- 内盘单笔总成本 = 1% + `taxBps`（5% 档 = 6%），`gang preflight` 必须展示。
- 内盘税在 pad 里本来就是报价币，不需要换币、不需要 keeper。

### 1.4 模版白名单（已拍板：平台限定）

- `TemplateRegistry`，owner = 平台多签；`create` 只接受 `isListed(factory)` 的工厂。
- **下架只影响新建**：已发的币的金库、以及创建时快照进 TaxRouterV3 的作者地址，平台都改不了。
- 模版部署后不可升级；新版本 = 新工厂地址，再上架。
- 外部 Agent 开发者可以提交模版，平台审计通过后上架（`author` 填作者地址，拿 10%）。

### 1.5 持币人分红仍是平台能力

按持仓分红要在**每笔转账**同步余额（V2 的 `setShare` / `syncShares`），外部金库只拿到钱、算不了。所以：

- 分红留在 DividendVault，模版只通过 `dividendBps` 决定 70% 里分多少给分红。
- `vaultFactory = 0` 时必须 `dividendBps = 10000` → 等价 V2 有税轨（「持有人分红」官方模版就是这个配置，不用写合约）。
- 分红那份如果该币当前没有任何合格持有人（`totalShares == 0`），V2 会把钱永久卡在 DividendVault；V3 改为转给金库，无金库则归平台。

---

## 2. 架构

```
           bonding (bondingTax)                     post-grad
LaunchpadV3 ──quote──┐               TaxLaunchTokenV3 ──token tax──▶ PostGradTaxHandlerV3
                     │                                                 │ keeper process(minQuoteOut)
                     ▼                                                 ▼ quote
                 TaxRouterV3.distribute(token, amount, phase) ◀────────┘
                     │
     ┌───────────────┼──────────────────┬───────────────────┐
     ▼               ▼                  ▼                   ▼
PlatformFeeBucket  owed[author]   DividendVault        IVault（模版金库）
   (20–30%)          (0/10%)     (70% × dividendBps)  (70% × 其余)
```

### 2.1 本分支已有（`feat/v3-economic-templates`）

| 文件 | 内容 |
|---|---|
| `src/launchpad-v3/interfaces/TemplateTypes.sol` | Field / Method / Metadata / Phase |
| `src/launchpad-v3/interfaces/IVaultFactory.sol` | `createVault` / `validate` / `metadata` / `dataSchema` |
| `src/launchpad-v3/interfaces/IVault.sol` | `token` / `quote` / `factory` / `onTaxReceived` / `uiSchema` |
| `src/launchpad-v3/interfaces/ITaxRouter.sol` | `register` / `distribute` / `release` / `previewSplit` |
| `src/launchpad-v3/interfaces/ILaunchpadV3.sol` | `TaxConfig`、`create` 新签名、`checkTaxConfig`、事件 |
| `src/launchpad-v3/LaunchpadV3.sol` | 发射台：V2 曲线 / 准入 / 1% 持仓上限 / 毕业不变，`create` 改收 TaxConfig，内盘税（21.0 KB） |
| `src/launchpad-v3/TaxLaunchTokenV3.sol` | 有税代币（税率 immutable）+ `TaxTokenDeployerV3`（让 pad 不超 EIP-170） |
| `src/launchpad-v3/PostGradTaxHandlerV3.sol` | 外盘税：只记账，keeper 带 `minQuoteOut` 换币后交给 TaxRouterV3 |
| `src/launchpad-v3/TemplateRegistry.sol` | 白名单 |
| `src/launchpad-v3/TaxRouterV3.sol` | 分账 |
| `src/launchpad-v3/templates/CreatorTreasury.sol` | 官方模版「Agent 自养」：创建者 Agent 提取，可设每日上限 |
| `src/launchpad-v3/templates/BuybackBurn.sol` | 官方模版「回购销毁」：keeper 带 `minTokensOut` 在本币池子回购，打到 0xdead |
| `test/launchpad-v3/TaxRouterV3.t.sol` | 分账 / 白名单 / Agent 自养，15 个用例 |
| `test/launchpad-v3/LaunchpadV3.t.sol` | 创建规则、内盘税分账、毕业、外盘税、回购销毁全流程，16 个用例 |

Buy / Sell 事件字段改为 `(quoteIn|tokensIn, protocolFee, templateTax, tokensOut|quoteOut, realQuote)`，索引服务需要跟着改。

### 2.2 `create` 新签名

```solidity
struct TaxConfig {
    uint16 taxBps;        // 0 / 100 / 200 / 300 / 500
    bool bondingTax;
    uint16 dividendBps;   // 70% 代币侧里给分红的比例
    address vaultFactory; // 0 = 只分红
    bytes vaultData;      // 按 factory.dataSchema() abi.encode
}
function create(name, symbol, logoURI, quote, refPool, TaxConfig tax) returns (address token);
```

`create` 内顺序：校验档位 / 白名单 / `factory.validate` → 部署 TaxLaunchTokenV3（税率 immutable）→ `factory.createVault` 并核对 `vault.token()/quote()` → `dividendVault.registerToken` → `router.register(token, quote, vault, registry.authorOf(factory), dividendBps)` → 写曲线 → `Created` + `TaxConfigured`。

### 2.3 安全约束（金库不能卡交易）

1. 转账钩子里只记账不换币（沿用 V2 Finding 2）。
2. 给金库打钱用低层 `transfer`，失败记 `owed[vault]`，任何人可 `release` 补推。
3. `onTaxReceived` 只是通知：限 150k gas、try/catch 吞掉失败；金库记账必须看余额。
4. 作者收入一律拉取（USDT 类黑名单不会卡住内盘买卖）。
5. 报价币可能有转账手续费：`distribute` 以实际到账额分账。
6. 平台不可改已发币的分账路径；`setSource` 只能加「付钱进来」的来源，取不走钱。

### 2.4 部署注意

- V2 的 DividendVault 的 `launchpad` 是单地址（LaunchpadV2），V3 需**新部署一个 DividendVault**。
- PlatformFeeBucket 可复用：把 LaunchpadV3 和 TaxRouterV3 都设为 operator（V2 的 bucket `launchpad` 仍是 V2）。
- DividendVault operator：TaxRouterV3、PostGradTaxHandlerV3。TaxRouterV3 source：PostGradTaxHandlerV3（pad 由 `setLaunchpad` 自动加入）。
- keeper：PostGradTaxHandlerV3 和 BuybackBurnFactory 各设一次。
- 部署顺序：QuoteRegistry → DividendVault → (Bucket) → TaxRouterV3 → TemplateRegistry → PostGradTaxHandlerV3 → TaxTokenDeployerV3 → LaunchpadV3 → MigratorV2(factory, pad) → 各模版工厂（构造参数含 pad）→ `templates.list`。
- 尺寸：LaunchpadV3 21.0 KB（via-ir），有税代币的 creation code 放在 TaxTokenDeployerV3。

---

## 3. 第一期官方模版

| 模版 | 实现 | 说明 |
|---|---|---|
| 持有人分红 | 无合约（`vaultFactory = 0`, `dividendBps = 10000`） | = V2 有税轨 |
| Agent 自养 | `CreatorTreasury`（已写） | 创建者 Agent 提取，可设每日上限 |
| 回购销毁 | `BuybackBurn`（已写） | 金库积累报价币，keeper 带 `minTokensOut` 回购本币打到 0xdead；内盘阶段的税先存着，毕业后才能回购 |
| 自定义比例 | 不需要合约 | 「持有人分红」+「Agent 自养」配 `dividendBps` 即可；更多去向等第二期 |

---

## 4. 待做

1. 拍板 §1.1 税率、§1.2 分成（含是否保留 1% 档 50%）。
2. 合约：补 fork 测试（真实 Pancake 池子、USDT 类报价币）、部署脚本、测试网全流程；外部审计。
3. gangfun-server：索引 `TaxConfigured` / `TaxDistributed` / 金库事件；模版列表 API（读 registry + `metadata` + `dataSchema`）。
4. gang.fun：模版市场页（使用量、累计流入、作者、审计状态）；代币页按 `uiSchema` 展示金库读方法。
5. CLI / skill：`gang templates`、`gang create --tax 3 --bonding-tax --template <factory> --param k=v`，preflight 调 `checkTaxConfig`。
