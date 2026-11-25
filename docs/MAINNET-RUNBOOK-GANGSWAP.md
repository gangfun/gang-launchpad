# 主网上线步骤 · GangSwap

- 状态：**GangSwap 已部署，pad 和 registry 已升级，已登记并打开（2026-11-24 至 25）**，见 `docs/MAINNET-GANGSWAP-2026-11-24.md`。阶段 A 改用隔离的主网部署验收，之后决定保持打开、观察，有异常再关闭；下面「小范围开放」的 A / B 步骤是原计划，没有照做。每一步都要用户明确同意，Safe 批次由 Safe 签名。
- 规格：`docs/SPEC-GANGSWAP-2026-11-22.md`（§13）；测试网记录：`docs/TESTNET-GANGSWAP-2026-11-23.md`；对接文档：`docs/GANGSWAP-INTEGRATION.md`
- 代码：main `a509292`。和主网正在运行的 pad 3.0 代码（`1fbab73`）相比，`src/` 的改动只有 GangSwap（11 个文件）。

## 开始前要定的

| 项 | 说明 |
|---|---|
| 外部审计 | **已定：不做外部审计，改为小范围分阶段开放**（见下）。目前只有内部独立复审（没有遗留中危以上）。合约不可升级：出问题只能对新币关闭或换版本，已建的币仍按原版本毕业 |
| 第三方平台 | 至少 DexScreener 有行情、Binance Wallet 能交易，再进入阶段 C |
| 测试站 | 观察几天；用真实钱包和 Agent Wallet 走一遍 |
| server / web | 先发 server，再发 web。未打开创建前，GangSwap 功能不生效 |

## 小范围开放

合约没有白名单：打开期间，任何 Agent ID 钱包都能建 GangSwap 币。所以用「短时间打开、建完就关」来控制数量。关闭只影响新建，已建的币照常交易和毕业。

| 阶段 | 做什么 | 进入下一阶段的条件 |
|---|---|---|
| A | 打开 → 我们自己建 1 个 6 BNB 档的币 → 立即关闭。用 Agent 窗口，走完曲线、毕业、真实 40 步回购、买卖、领手续费、卖回 | 每一步和演练一致；indexer、网站、CLI、keeper 数字一致 |
| B | 分次短时间打开，邀请 3～5 个 dev 各建 1 个 6 BNB 档的币，建完就关。**提前告诉 dev**：第三方平台可能还不支持，毕业后只能在 gang.fun 和 CLI 交易 | 至少 2 个币真实毕业；观察 7 天，没有异常告警 |
| C | 长期打开，CLI 公开发布 | 平台支持情况和 B 的结果都满意 |

- A、B 期间 CLI 0.53.0 不公开发布，给受邀 dev 单独的版本；网站的建币提示会在打开期间自动出现。
- 每次打开和关闭各要一笔 Safe 交易。打开后先看 `GangSwapCreated` 日志，再关闭；发现非受邀的币也立即关闭。
- 单币的资金上限是它的募资额（6 BNB 档约 6 BNB，毕业后池子约 4.8 BNB 真实储备，约 1.2 BNB 进回购）。
- 立即停止的条件：pair 的真实储备和 `realQuoteReserve() + feeAccrued()` 对不上、回购无法执行、毕业回滚、任何无法解释的余额差。停止 = `setGangSwapMigrator(0)`，再排查。

## 步骤

### 1. 部署 GangSwap（约 1010 万 gas）

在干净检出里 `forge build --root gangswap --force`，然后在 `gangswap/` 跑 `script/DeployGangSwap.s.sol --broadcast`：`GANGSWAP_OWNER` = Safe，`WBNB`，`FEE_BUCKET` = pad 的 `platformBucket()`。广播后对链上跑 `check(migrator,router)`；在 BscScan 和 Sourcify 验证五个合约源码。

### 2. 配套

- CLI（公开发布等阶段 C）：把主网 router 写进 `GANGSWAP_VERSIONS.mainnet`（部署的 router 遮罩代码哈希应等于已固定的 `0x07886a19…005d`），阶段 A、B 只给自己和受邀 dev 用，阶段 C 再发布 0.53.0。
- web：`GANGSWAP_CHAINS[56].routers`（或构建变量）；server：索引的 router 映射和 keeper 配置。

### 3. 升级 pad 3.0 和 GangPadRegistry（约 4700 万 gas，含连带部署）

1. **探针**：`python3 -I script/pad3-upgrade-probes.py`，把输出的 `PAD3_PROMOTE_PROBES`、`PAD3_BASE_PROBES` 填进环境变量。**签名前再跑一次**。公共节点的日志不完整，不要用 `eth_getLogs` 找。
   - 2026-11-24：1,061 个币（1,058 个曲线、2 个飞轮、1 个打新）；4 个有推广分成，没有任何绑定；没有底仓币。两个探针都为空。
2. `script/UpgradeGangLaunchpad3.s.sol`（`PAD3_REGISTRY_UPGRADE=true`、`GANG_MAINNET_OK=true`，链接主网 PoolCheck），先不广播模拟一次，再广播（只部署）。
3. 带 `PAD3_IMPL`、`PAD_REGISTRY_IMPL`、`PAD3_FLY_HANDLER`、`PAD3_FLY_VAULT_CORE` 只读重跑，打印 Safe 批次（2 笔：pad、registry）；验证源码；签名前在主网 fork 上原样执行一次。
4. Safe 执行后核对：实现槽、`module()`、两个 owner、`gangSwapMigrator()` = 0（**创建仍关闭**），抽查老币。

脚本要逐个读全部币，用稳定的节点跑。

### 4. 登记（Safe 批次 2 笔）

`script/OpenGangSwap.s.sol`，`GANGSWAP_STEP=list`，`GANGSWAP_DEPLOY_TXS` = 部署时的五笔交易（migrator,boost,fees,factory,router）。批次：migrator `addLaunchpad(pad)`、bucket `setOperator(fees, true)`。创建仍关闭。

### 5. 确认各端就绪

人工确认：keeper 的回购服务在跑并告警正常（主网要求 `KEEPER_BROADCAST_RPC`）；indexer、web、CLI 都认得这个版本；第三方平台状态。脚本看不到这些。

### 6. 打开（Safe 批次 1 笔）

`GANGSWAP_STEP=open`：`setGangSwapMigrator(migrator)`，立即对新币生效。执行后按「小范围开放」的阶段 A 走。建完用 `setGangSwapMigrator(0)` 关闭。

## 回退和应急

- **打开后发现问题**：Safe 执行 `setGangSwapMigrator(0)`，立即关闭新币创建。已建的 GangSwap 币照旧买卖、照旧毕业。
- **换版本**：部署新的一套，`list` 后 `open` 加 `GANGSWAP_REPLACE=true`。旧版本的手续费合约**不能**撤 bucket 授权。
- **pad 升级**：不支持退回没有 GangSwap 的实现（升级脚本会拒绝）；只做前滚修复。
- **回购停住**：`GangSwapBoost.step` 任何人都能调，可以手工执行（gas limit 给 300,000）。
- **手续费进不了 bucket**：创建者那 70% 不受影响，平台那份暂存，重新授权后 `flushPlatform`。

## 主网 fork 演练（2026-11-24，区块 135452559，anvil）

用 anvil 自带的测试账号部署，Safe 步骤用模拟身份发送；真实主网没有任何交易。

| 步骤 | 结果 |
|---|---|
| 部署 GangSwap、链上 `check` | 通过 |
| 升级前 `OpenGangSwap` | 拒绝：`pad does not serve GangSwap` |
| 升级脚本部署（模拟读回 25 个币）→ 只读重跑打印批次 → 执行 2 笔 | 通过；`gangSwapMigrator()` = 0 |
| 未登记就 `open` | 拒绝：`the list step is not on chain yet` |
| `list` 核对（运行代码、创建代码、指向、owner）+ 完整演练 → 执行 2 笔 | 通过 |
| `open` 核对 + 完整演练 → 执行 1 笔 | 通过；`gangSwapMigrator()` = 新 migrator |
| `setGangSwapMigrator(0)` 后建币 | 拒绝：`GangSwapNotOpen` |

没有覆盖：真实 Agent ID 钱包建币、毕业后真实时间的回购（测试网和本地联调覆盖）、升级脚本里推广绑定的比对（目前没有绑定）、Safe 界面导入 JSON。fork 用了几个公共节点轮流重试，个别节点会拒绝归档请求。
