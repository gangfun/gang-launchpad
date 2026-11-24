# 主网上线步骤 · GangSwap

- 状态：**准备阶段，主网没有做任何操作**。每一步都要用户明确同意，Safe 批次由 Safe 签名。
- 规格：`docs/SPEC-GANGSWAP-2026-11-22.md`（§13）；测试网记录：`docs/TESTNET-GANGSWAP-2026-11-23.md`；对接文档：`docs/GANGSWAP-INTEGRATION.md`
- 代码：main `a509292`。和主网正在运行的 pad 3.0 代码（`1fbab73`）相比，`src/` 的改动只有 GangSwap（11 个文件）。

## 开始前要定的

| 项 | 说明 |
|---|---|
| 外部审计 | 目前只有内部独立复审（没有遗留中危以上）。合约不可升级：出问题只能对新币关闭或换版本，已建的币仍按原版本毕业 |
| 第三方平台 | 至少 DexScreener 有行情、Binance Wallet 能交易，再打开创建 |
| 测试站 | 观察几天；用真实钱包和 Agent Wallet 走一遍 |
| server / web | 先发 server，再发 web。未打开创建前，GangSwap 功能不生效 |

## 步骤

### 1. 部署 GangSwap（约 1010 万 gas）

在干净检出里 `forge build --root gangswap --force`，然后在 `gangswap/` 跑 `script/DeployGangSwap.s.sol --broadcast`：`GANGSWAP_OWNER` = Safe，`WBNB`，`FEE_BUCKET` = pad 的 `platformBucket()`。广播后对链上跑 `check(migrator,router)`；在 BscScan 和 Sourcify 验证五个合约源码。

### 2. 配套

- CLI：把主网 router 写进 `GANGSWAP_VERSIONS.mainnet`（部署的 router 遮罩代码哈希应等于已固定的 `0x07886a19…005d`），发布 0.53.0。
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

`GANGSWAP_STEP=open`：`setGangSwapMigrator(migrator)`，立即对新币生效。执行后建一个小额测试币，走曲线买卖，确认 CLI、网站、索引一致。

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
