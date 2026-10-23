# 规格 · 两轨 Launchpad（有税 / 无税）取代 Soft·U·S

- 日期：2026-10-23 Asia/Shanghai
- 作者：Claude（本页为产品规格 + 合约意见；**非执行单**）
- 性质：**禁止主网广播 / 禁止改生产 FE**。等 Lazy 确认后再动链与 tip。
- 硬规则来源：Lazy 口述（数字勿改）。文中「Claude 建议」为待批项。
- 参考：现网 CREATE-GATE Soft `0x4E6f…80d7` / U `0xF81C…712cb` / S `0x60ae…430C1`；U 附属 DivVault `0x2E95…2F38` / Bucket `0xe314…260c` / PostGrad `0xfC12…ca2D` / Burner `0x2aC1…f8dF`；平台币 GANG `0x0c6302401aa5325C2E36F170f52C00B1d220B405`；feeVault `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4`（链上读自 U Bucket）。
- 链上核对（2026-10-23）：U `TAXED_MIN_SHARE=1e24`（100 万枚×1e18）、`TARGET_GRAD_BNB=15e18`、`PROTOCOL_FEE_BPS=100`、有税内盘 `DIVIDEND_TAX_BPS=50`+`PLATFORM_TAX_BPS=50`；DivVault `minimumShareBalance=1e24`。

---

## 0. 一句话产品

只留 **两条发射轨**：**无税（Untaxed）** 与 **有税（Taxed）**。准入 / 内盘税 / quote / 毕业条件两轨相同；唯一产品差在 **毕业后外盘是否继续抽 1% 并给持币人分红**。官方平台币已发射 → Soft / 旧主轨不再作为新产品入口。

---

## 1. Lazy 硬规则（照抄，勿改数字）

### 1.1 准入（两轨相同）

| # | 规则 |
|---|---|
| 1 | `create`：必须 BAW（`isAgent`） |
| 2 | 内盘 `buy`（及现有同级 `sell`）：必须 BAW |
| 3 | 每钱包内盘买入上限：供应量的 **1%**（`MAX_PER_WALLET = TOTAL_SUPPLY / 100`；现网 10_000_000 ether / 1e9 supply） |

### 1.2 无税轨 Untaxed

| 阶段 | 税 | 分配 |
|---|---|---|
| 内盘买卖 | **1%** | **80%** 回购平台币销毁 · **20%** 金库 |
| 毕业后外盘 | **无税** | — |

### 1.3 有税轨 Taxed

| 阶段 | 税 | 分配 |
|---|---|---|
| 内盘买卖 | **1%** | 与无税轨内盘相同：**80%** 回购 / **20%** 金库（**内盘不分红给持币人**） |
| 毕业后外盘 | 仍 **1%** | 见下表 |

外盘 1% 相对整笔税：

| 份额 | BPS（相对 10000） | 去向 |
|---|---|---|
| (a) **50%** | 5000 | 分红 → 持币 **> 1 万枚**该代币的用户（新产品口径；**勿用现网 100 万**） |
| (b) **40%** | 4000 | 回购平台币（= 余下 50% 的 80%） |
| (c) **10%** | 1000 | 金库（= 余下 50% 的 20%） |

实现上可继续：PostGrad 先 **50/50** → DividendVault / PlatformFeeBucket，Bucket `collect` 再 **80/20** → Burner / feeVault（相对整笔外盘税仍是 50/40/10）。

### 1.4 Quote / 毕业（两轨相同）

- DEV 可用 **BSC 上任意有池子的代币** 作 quote（币股或其他），**不限**现有 6 bStock 白名单。
- 毕业：募资到 quote 侧 **≈15 BNB 等值**（例：底池 NVDAB → 募到 ≈15 BNB 等值的 NVDAB 时毕业）。
- create 时锁定 `gradAmt`（现货路径，见 §4）。

---

## 2. Claude 建议 · 架构

### 2.1 一合约双模式 vs 两合约

**Claude 建议（待 Lazy 拍板）：一合约双模式。**

- 命名建议：`LaunchpadV2`（对外）/ 源码目录可叫 `LaunchpadCore`；`create(..., bool taxed, ...)`。
- FE 两个 tab：无税 / 有税 → 同一地址、同一 Migrator。
- 理由：
  1. Lazy 口述两轨仅差「外盘是否有税 + 分红」；准入 / 内盘 80/20 / quote / 15BNB 完全共享 → 拆两合约只增加 FE/indexer/keeper/地址表负担（正是现网 Soft·U·S 痛点）。
  2. 现网 `LaunchpadU` 已是 `taxed bool` 骨架；新产品是 **改内盘有税路径语义 + 降分红门槛**，不是要第二套 pad。
  3. Soft 语义（BNB-only / 20 BNB）明确不延续 → 不必保留 Soft 合约作新产品轨。

**备选（不推荐）：** `LaunchpadUntaxed` + `LaunchpadTaxed` 两合约。仅当 Lazy 坚持「有税轨要独立升级/暂停」或审计强制隔离时采用；成本是双 Migrator、双 wire、双 indexer startBlock。

### 2.2 与现网 U 的关键语义差（为何必须 redeploy，不能「只留现网 U」）

| 点 | 现网 U `0xF81C…` | 新产品硬规则 |
|---|---|---|
| 有税 **内盘** | `50 bps` 进 DividendVault + `50 bps` 进 Bucket（持币人内盘就开始分红） | 内盘 **整笔 1% 只走 80/20**（回购/金库）；**内盘不分红** |
| 分红门槛 | `TAXED_MIN_SHARE = 1_000_000 ether`（100 万枚） | **> 1 万枚** → `10_000 ether`（假设 18 decimals） |
| Soft / S | 并存三轨 | 新产品入口只两轨；Soft/S 只读归档 |

→ 常量与内盘分支均非 proxy → **新产品 pad 必 redeploy**。现网 U 上已发射币（含 `0x97ac…`）继续走旧语义，不迁。

### 2.3 附属合约：复用 vs 重写

| 组件 | Claude 建议 | 说明 |
|---|---|---|
| **LaunchpadV2** | **新部署** | 内盘统一 80/20；`TAXED_MIN_SHARE=10_000 ether`；保留 BAW / walletCap / any-pool / 15e18 |
| **Migrator**（V2） | **新部署** | 绑定新 pad；毕业建 Pancake V2 pair + LP burn（沿用现 MigratorU 逻辑） |
| **TaxLaunchToken** | **复用源码**（随 create 新实例） | `OUTER_TAX_BPS=100` 已对；外盘仅 pair 成交抽税（与现一致） |
| **LaunchToken**（无税） | **复用源码** | 无 transfer tax |
| **PoolCheck + ThinWbnb** | **复用库**（编进 pad） | `spotGradAmt` + `MIN_RESERVE_WBNB=1 ether`；见 §4 |
| **QuoteRegistry** | **可选薄复用 / 可不挂** | 任意有池后主路径不靠白名单；若保留，仅作 `graduationQuoteAmount` **ops override**（稀有 quote），**不再**当 create 准入白名单 |
| **DividendVault** | **新部署（强烈建议）** | 现网 U vault `minimumShareBalance=1e24`；`ensureMinimumShareBalance` 只能抬高。新产品 1 万门槛若写进旧 vault，会与已发「100 万门槛」币互相污染。owner `setMinimumShareBalance` 虽可下调，但会误伤旧币 → **V2 独立 DivVault，默认/ensure = 10_000 ether** |
| **PostGradTaxHandler** | **新部署** | 绑新 DivVault + 新 Bucket；`process` 仍 50/50 |
| **PlatformFeeBucket** | **新部署**（或确认可安全共用） | 80/20 collect → Burner / feeVault。**feeVault 地址可共用**现网 `0x3464…1Af4`（Lazy 待确认） |
| **BuybackBurner** | **可复用地址** `0x2aC1…f8dF` | `gang()=GANG 0x0c63…B405` 已正确；新 Bucket 指向同一 Burner 即可（Lazy 待确认是否共用） |
| Soft / S 全套附属 | **不动** | 只读跑完；不 wire 进 V2 |

### 2.4 命名与 FE 文案

- 合约：`LaunchpadV2`；事件/DB `lane = v2_untaxed | v2_taxed`。
- FE create：两个模式，不再出现 Soft / U / S 字样；老币详情横幅「legacy · 按旧轨规则」。
- 对外可以说「Gang Pair · 无税 / 有税」，避免「U 轨」内部代号泄漏到用户面。

---

## 3. 与现网 Soft / U / S 差异表

| 维度 | Soft（新 `0x4E6f` / 旧 `0x315B`） | U `0xF81C` | S `0x60ae` | **新产品 V2** |
|---|---|---|---|---|
| 产品去留 | **停更 / 只读**；新产品不延续 Soft | 已发币只读跑完；**不作为新发射入口** | 冻结 create / 只读 | **唯一新入口** |
| create 门禁 | isAgent | isAgent | isAgent + **isQuoted 白名单** | isAgent（同 U） |
| 内盘 buy/sell | isAgent | isAgent | isAgent | isAgent |
| 每钱包上限 | 1% supply | 1% | 1% | **1%（两轨）** |
| quote | 固定 BNB | 任意有池（PoolCheck） | **仅 6 bStock 白名单** | **任意有池**（同 U） |
| 毕业线 | **20 BNB** 常量 | **15 BNB** 等值锁定 | 15 BNB 等值 | **≈15 BNB 等值** |
| 内盘税 | 1% → 平台 80/20 | 无税：1%→80/20；**有税：50% 分红 + 50% 平台** | 有税内盘同 U 族 | **两轨内盘皆 1%→80/20**（有税内盘也不再分给持币人） |
| 外盘税 | 无（非 TaxLaunchToken） | 有税：`OUTER_TAX_BPS=100`；无税：无 | 同有税 | 无税轨无；有税轨 **1%** → 50/40/10 |
| 分红门槛 | — | **100 万枚** | 同族 | **> 1 万枚** |
| Soft 去留 | 新产品不管 | — | — | **不部署 Soft 替代品** |

---

## 4. 毕业 ≈15 BNB 等值怎么定

### 4.1 现货路径（建议沿用现网 U）

```
TARGET_GRAD_BNB = 15 ether
gradAmt = (quote == WBNB)
        ? TARGET_GRAD_BNB
        : PoolCheck.spotGradAmt(pair, wbnb, TARGET_GRAD_BNB, MIN_RESERVE_WBNB)
        // = targetBnb * reserveQuote / reserveWbnb
```

- create 时写入 curve 并 **锁定** `gradAmt`（之后现货波动不改毕业线）。
- 可选：`QuoteRegistry.graduationQuoteAmount(quote)` ops override（稀有/稳定币 ops 手填）；主路径不依赖白名单 `isQuoted`。

**Claude 判断：现网 PoolCheck.spotGradAmt + create 锁定对「≈15 BNB」够用。** 不引入 TWAP/预言机，除非 Lazy 要求抗操纵更强（见 §7）。

### 4.2 任意有池安全门槛（建议写进 V2，与现 U 对齐）

| 门槛 | 建议值 | 作用 |
|---|---|---|
| 必须存在 factory 规范 pair | `getPair(quote,WBNB) != 0` 且 == 传入 pair（防假 pair，现 M1） | 拒自建假池 |
| `MIN_RESERVE_WBNB` | **1 ether**（现网） | 拒尘埃池 / 闪贷瞬间抬价设 grad |
| reserves > 0 | `_requireReserves` | 拒空池 |
| FoT / 奇怪 ERC20 | **不在链上全面检测**（成本高） | FE 预检 + 风险标；create 失败靠 transfer/报价 revert；**待 Lazy 是否加 transfer 探测** |
| 无流动性 | PairEmpty / ThinWbnbReserve revert | create 直接失败 |

### 4.3 FE 预检（链下，不改生产本轮）

提交前 `eth_call` 模拟 resolve + spotGradAmt；显示「将锁定 gradAmt = X quote（≈15 BNB）」；不过则拦。

---

## 5. 外盘分红门槛：1 万枚

### 5.1 单位（写死）

- 假设代币 **18 decimals**（现 `TaxLaunchToken.TOTAL_SUPPLY = 1_000_000_000 ether`）。
- 门槛 raw：`MIN_HOLDER_SHARE = 10_000 * 10^18 = 10_000 ether = 1e22`。
- 语义：**余额 > 1 万枚** → 实现用 `newShare < minimumShareBalance → 0` 时，若「超过」含等于，应设 `minimumShareBalance = 10_000 ether + 1 wei` **或** 文档约定「≥ 1 万」。  
  **Claude 建议交 Lazy：口径「超过 1 万」→ 链上用 `>= 10_000 ether + 1` 或 `> 10_000 ether`；产品文案写「持仓超过 1 万枚」。** 实现倾向：`minimumShareBalance = 10_000 ether + 1`，`setShare` 仍用现有 `<` 清零逻辑，等价于「≥ 10000+1 wei」。更干净的改法：`setShare` 改为 `<= 10_000 ether → 0`（严格「超过」）。**待 Lazy 选严格性。**

### 5.2 改哪里

| 位置 | 现网 | V2 |
|---|---|---|
| `LaunchpadU.TAXED_MIN_SHARE` | `1_000_000 ether` | → `10_000 ether`（或 +1 wei，见上） |
| create 时 `dividendVault.ensureMinimumShareBalance(TAXED_MIN_SHARE)` | 抬到 100 万 | 新 DivVault 上 ensure 到 1 万 |
| `DividendVault.setShare` | `newShare < minimumShareBalance → 0` | **逻辑可复用**；仅改默认/ensure 值 |
| `PostGradTaxHandler` sync | `balanceOf` → `setShare` | 不变；门槛在 vault |
| claim | 无额外余额检查（靠 shares） | 不变 |

**不要**在现网 U DivVault 上直接下调：已发税币按 100 万设计；下调会让小户突然进分红池、稀释老户。

### 5.3 sync 时机（与现 TaxLaunchToken 一致，待确认）

- 外盘：pair 买卖触发 `_transfer` 税 + handler sync from/to。
- pair 自身 shares 强制 0（防 skim）。
- **Claude 建议：** 继续「每次相关 transfer sync 当前 `balanceOf`」；不做单独 cron。是否改成「仅当余额跨过 1 万阈值才写」属 gas 优化，非必须。

---

## 6. 迁移 / 废弃（不执行，只列清单）

### 6.1 链上

| 对象 | 处置 |
|---|---|
| 新 Soft `0x4E6f…` | 只读归档；不再 create（FE 下线；无 pause 则接受直调残留） |
| 旧 Soft `0x315B…` | 只读；活币按 **20 BNB** 跑完；keeper cron 保留至到期 |
| U `0xF81C…` + 附属 | 已发币（含税币 `0x97ac…`）继续旧语义（内盘 50/50、门槛 100 万、外盘 1%）；**不再作新发射入口** |
| S `0x60ae…` | 冻结 create；已发币跑完 |
| **LaunchpadV2 + 新附属** | Lazy 确认后才部署；新产品只走这里 |

**不迁池、不强毕、不改已发币参数。**

### 6.2 链下切流清单（拍板后执行，本文不跑）

**FE**

- [ ] create 只留 V2「无税 / 有税」；下线 Soft / U / S create
- [ ] quote：BNB 快捷 + 任意 ERC20 + PoolCheck 预检
- [ ] 老币详情：legacy 横幅（Soft 20 / U·S 旧规则）
- [ ] 地址表换 V2 pad + Migrator + PostGrad + DivVault + Bucket
- [ ] 税币 metrics 继续 quote 单位（NVDAB 等），不折 BNB（已定口径）

**indexer**

- [ ] 监听 V2 `Created` / swap / graduate；`lane=v2_untaxed|v2_taxed`
- [ ] Soft / U / S 继续听，标 `legacy=true`
- [ ] startBlock = V2 Deploy 收据

**keeper**

- [ ] 接 V2 毕业 / PostGrad `process` / Bucket collect（若非全自动）
- [ ] 旧 Soft cron 保留至到期；现网 U 税币 process 保留至无活跃

**QuoteRegistry**

- [ ] 不再 `setQuote` 扩白名单；S 冻结

---

## 7. 给 Lazy 的不确定点（必须拍板，Claude 不擅自定）

1. **一合约双模式（LaunchpadV2 + taxed bool）vs 两合约？** Claude 建议一合约。
2. **外盘分红「超过 1 万枚」严格性：** `> 10000` vs `>= 10000`？链上用 `minimumShareBalance = 10_000 ether + 1` 还是改 `setShare` 比较符？
3. **外盘税是否仅 pair 成交**（与现 `TaxLaunchToken`：非 pair 转账不税）？Claude 建议保持「仅 pair」。
4. **金库 / 回购是否共用现网** `feeVault 0x3464…` + `BuybackBurner 0x2aC1…`（GANG `0x0c63…`）？还是 V2 全新一套？
5. **现网 U 已发有税币内盘仍 50/50 分红**——产品上是否接受「新旧两套内盘语义并存」直到旧币毕业？（Claude：接受，不迁）
6. **任意 quote 的 FoT / 无池：** 仅 FE 预检 + 现 PoolCheck，还是 create 加 `transfer` 探测 / 更高 `MIN_RESERVE_WBNB`？
7. **毕业定价抗操纵：** 现货 create 锁定是否够？是否要 TWAP 或最短池龄？
8. **平台币地址确认：** 回购目标是否锁定 GANG `0x0c6302401aa5325C2E36F170f52C00B1d220B405`（现 Burner.gang）？
9. **S / Soft 无 pause 直调残留：** 接受 FE 隐藏 + indexer legacy，还是 P2 加 pause 需再 redeploy 旧垫？
10. **广播时机：** 规格确认 → 测试网 / Chapel 干跑 → Lazy 书面确认 → 主网 Deploy+Wire；**在此之前零广播。**

---

## 8. 实现顺序（P0→P2）与 redeploy 清单

### 8.1 Redeploy / 复用清单

| 项 | 动作 |
|---|---|
| LaunchpadV2 | **必新部署** |
| MigratorV2 | **必新部署** |
| DividendVault（V2） | **必新部署**（门槛 1 万；隔离旧 100 万币） |
| PostGradTaxHandler（V2） | **必新部署** |
| PlatformFeeBucket（V2） | **建议新部署**；feeVault 指针可共用 |
| BuybackBurner | **可复用** `0x2aC1…`（待 Lazy） |
| feeVault | **可复用** `0x3464…`（待 Lazy） |
| GANG | **复用** `0x0c63…B405` |
| PoolCheck / 代币实现 | **复用源码** |
| Soft / U / S 现网 | **不 redeploy**；只读 |
| 生产 FE tip | **本规格阶段不改**；确认后再出 tip |

### 8.2 顺序

**P0 — 规格冻结（本页）**

1. Lazy 回 §7（至少：一/两合约、1 万严格性、Burner/feeVault 共用、GANG 确认）。
2. 冻结 ABI：`create(name,symbol,logo,taxed,pairOrQuote)`；内盘费仅 `PROTOCOL_FEE_BPS=100` → Bucket；有税外盘不变 50/50+80/20。

**P1 — 实现与测试（无主网广播）**

1. 从 `LaunchpadU.sol` fork → `LaunchpadV2.sol`：删有税内盘 DIV/PLAT 分叉，有税/无税内盘皆走 100 bps → Bucket；`TAXED_MIN_SHARE=10_000 ether`（或 §7 定值）。
2. 新 DivVault / Bucket / PostGrad；Wire 脚本（setLaunchpad、setOperator、Burner、feeVault）。
3. 单测：内盘两轨费用去向；外盘 1% 拆分；门槛 9999 / 10000 / 10001；any-pool create + gradAmt 锁定；BAW / walletCap。
4. Chapel 或 fork 干跑；BscScan verify 草稿（主网后）。

**P2 — 主网（仅 Lazy 书面确认后）**

1. Deploy + Wire；写 `MAINNET-V2-ADDRESSES-….md`。
2. FE / indexer / keeper 切流（§6.2）；Soft/U/S create 下线。
3. 监控首枚无税 + 首枚有税至毕业 + 一笔外盘税 process。

---

## 9. 内盘 / 外盘资金流（对照图）

```
【两轨 · 内盘 1%】
  quoteIn/Out
    └─ 100 bps ──► PlatformFeeBucket
                      ├─ collect 80% ──► BuybackBurner ──► GANG ──► burn(dead)
                      └─ collect 20% ──► feeVault
    └─ 9900 bps ──► 曲线 / 用户

【仅有税轨 · 外盘 1% · TaxLaunchToken】
  pair buy/sell transfer
    └─ 100 bps token ──► PostGradTaxHandler.process
                           ├─ 50% quote ──► DividendVault（shares：余额 > 1万枚）
                           └─ 50% quote ──► PlatformFeeBucket
                                              ├─ 80% ──► Burner → GANG burn
                                              └─ 20% ──► feeVault
         （相对整笔外盘税 = 持有人 50% / 回购 40% / 金库 10%）

【无税轨 · 外盘】
  LaunchToken，无 OUTER_TAX；DEX 正常买卖
```

---

## 10. 明确边界

- 本文 **不是** 执行单：无主网 `send`、无生产 FE tip、无 keeper 改 cron。
- 数字以 Lazy §1 为准；与现网 U 冲突处以新产品为准（通过 **新部署** 实现，不改旧币）。
- bot 只协调；代码与产品意见由 Claude 扛；资金 / 生产 / 广播等 Lazy。

---

## 11. 自检

- [x] 路径：`/workspace/baw-real-check/SPEC-DUAL-TRACK-TAXED-UNTAXED-2026-10-23.md`
- [x] 含架构建议（一合约双模式）
- [x] 含 Soft/U/S 差异表
- [x] 含 15 BNB 等值 + PoolCheck
- [x] 含 1 万枚门槛与 DivVault 隔离
- [x] 含迁移清单与 P0–P2
- [x] 含 Lazy 待决（§7）
- [x] 标明未广播
