# 测试网记录 · Agent 专属窗口

- 日期：2026-11-21（Asia/Shanghai）
- 网络：BSC 测试网（97）。GangLaunchpad 3.0 代理 `0x0508232833aE6849c03b28F7aA248BBd5cFCceE2`（abcd、底仓金库、冲毕业奖励都已开启），GangPadRegistry 代理 `0xB11B83C83DEd269B040faecC1D61B4885BA8e56e`
- 规格：`docs/SPEC-AGENT-WINDOW-2026-11-20.md`；§11 是审计记录
- 部署前完成的审查：
  - spec 审阅两轮；
  - 代码审阅一轮，修复后复审一轮；
  - 正式审计三份，分 A 曲线核心、B 集成、C 升级路径；
  - 修复后复审一轮，再加一次快速复审。

  最后一轮没有发现中危及以上问题。没有外部审计。
- 部署的代码：PR #182 的 `f9ae8f8`
- 结论：升级已在测试网执行。窗口期内的规则、开放后的规则和毕业都在链上验收通过。开放后上限取消，所以这次一个钱包就能把币买到毕业。以前测试网上做不到毕业，因为在 1% 上限下要大约 80 个 Agent 钱包。

## 部署

用 `script/UpgradeGangLaunchpad3.s.sol`，带 `PAD3_REGISTRY_UPGRADE=true`，pad 和 registry 在同一次运行里升级。环境变量和 `docs/TESTNET-GRAD-REWARD-2026-11-17.md` 的升级相同：`GANG_PAD`、`GANG_GATEWAY`、`GANG_PAD3`、`GANG_ROUTER3`、`GANG_PAD3_BLOCK`、`CALLERS`、`PAD3_BASE_PROBES`。另外加了 `GANG_PAD_REGISTRY` 和 `PAD3_REGISTRY_UPGRADE`。

- 只链接了测试网的 PoolCheck `0x76Ba001095De137b40D93e8A1493432Bd38bC00c`。没改动的库，forge 直接复用了已部署的版本。
- 部署钱包同时是两个 ProxyAdmin 的 owner，所以脚本直接发送了两笔升级。

先做了一次不广播的模拟，结果：
- 比对了最新 25 个币的记录和设置；
- 升级 pad 后跑了阶段 2 读回；
- 升级 registry 后跑了 `GangPadRegistryDeployLib.check`；
- 比较了每个已登记 pad 最新 25 个币的 `padOf`，以及新钱包和固定探针地址的报价；
- 全部通过，之后才广播。

| 项 | 地址 / 交易 | 区块 | gas |
|---|---|---|---|
| CurveLogic3 | [`0x130b8bbf87fb3f577798d7bd6bc410d869996433`](https://testnet.bscscan.com/address/0x130b8bbf87fb3f577798d7bd6bc410d869996433) | 143878360 | 3,878,158 |
| GangPadRegistry 新实现 | [`0xbf1b207b8f70cb645bac4e510812802e3745232a`](https://testnet.bscscan.com/address/0xbf1b207b8f70cb645bac4e510812802e3745232a) | 143878365 | 1,125,092 |
| Pad3FlyModule（代码不变，构建脚本连带部署） | [`0x485254fb5dd1572721cba9acde7315b1ce5aee6b`](https://testnet.bscscan.com/address/0x485254fb5dd1572721cba9acde7315b1ce5aee6b) | 143878370 | 4,816,115 |
| Pad3GradModule | [`0x09f49a7a50ac3a830d74a99712c520e1f0487362`](https://testnet.bscscan.com/address/0x09f49a7a50ac3a830d74a99712c520e1f0487362) | 143878374 | 2,024,337 |
| Pad3Module | [`0xe06211d54c3138cd9637d3507a46c2126069d1f8`](https://testnet.bscscan.com/address/0xe06211d54c3138cd9637d3507a46c2126069d1f8) | 143878379 | 4,765,648 |
| GangLaunchpad3 新实现 | [`0xab823980734aca295e66ed15b6dc866798c7f7f2`](https://testnet.bscscan.com/address/0xab823980734aca295e66ed15b6dc866798c7f7f2) | 143878385 | 4,966,453 |
| pad 的 `upgradeAndCall` | [`0xc1f6ae30…4fa9`](https://testnet.bscscan.com/tx/0xc1f6ae304e50e2709c7b3dba77a4a0df5f92432a2a0523d9a14a023c6aca4fa9) | 143878387 | 37,347 |
| registry 的 `upgradeAndCall` | [`0x1169afd0…268e`](https://testnet.bscscan.com/tx/0x1169afd01d0a07e042cfa4f13a52f395fb7bf5a42903490f9e69f3680450268e) | 143878392 | 37,347 |

- 8 笔交易全部成功。记录：`broadcast/UpgradeGangLaunchpad3.s.sol/97/run-1795199375081.json`。
- 链上读回：
  - pad 的实现槽 = 新实现；`module()` = 上表的 Pad3Module，它的 `gradModule()` 和 `flyModule()` 都是上表的地址；
  - registry 的实现槽 = 新实现；owner 没变，仍是部署钱包；登记的 pad 仍是 10 个；
  - `MAX_AGENT_WINDOW_MINUTES()` = 1440；
  - 最新 6 个老币（曲线、飞轮、打新各类都有）`agentOpenAt` = 0，`walletCapOn` = true。
- 第一次广播时，运行脚本把 `--broadcast --slow` 当成一个参数传给了 forge，forge 在发任何交易前就拒绝运行了，链上没有发生任何事。修好参数拆分后重新广播。

## 验收（`script/AgentWindowTestnetAcceptance.s.sol`）

- dev = 部署钱包（持有 Agent ID）。
- 「没有 Agent ID 的交易者」由 dev 部署的合约 `WindowTestTrader` 扮演。没有新建钱包：开放后合约也能交易，正好可以用来验收。
- 报价币是测试网已上架的 MockSPCXB `0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c`，6 BNB 档，毕业额 6 个。
- 老币 `OLD_TOKEN` 是升级前链上最新的曲线币 `0x14b776b6f27a1F5373be6d12456B62589210aBCD`。
- 两个阶段都先做不广播的模拟，通过后再广播。

### 阶段 1：窗口期内

| 步骤 | 结果 | 交易 | gas |
|---|---|---|---|
| `createWithAgentWindow(1, createWithSalt(salt, createWithGradTarget(…)))` | 代币 [`0x858093c2bBBB7a140F4c7C43d3Ce01f9c6b1AbCD`](https://testnet.bscscan.com/address/0x858093c2bBBB7a140F4c7C43d3Ce01f9c6b1AbCD)，和事先算出的 abcd 地址一致；`openAt` = 1795199618，即建币区块时间 + 60 秒 | [`0x4ac1cc0e…16ec`](https://testnet.bscscan.com/tx/0x4ac1cc0ebf6efca05f85853d123a888a27c23f9fd8b6370f91ef9223f8e316ec) | 1,505,706 |
| 部署 `WindowTestTrader` | [`0x7933dA94718E27C7a68Eef27aB7575B91A8C4682`](https://testnet.bscscan.com/address/0x7933dA94718E27C7a68Eef27aB7575B91A8C4682) | [`0xbe1bbea9…bb6`](https://testnet.bscscan.com/tx/0xbe1bbea97388e3033dde520660f34f685a1917a0fc05083a4a61dac3de751bb6) | 325,338 |
| dev（agent）买 0.05 | 被 1% 上限截断，正好得到 10,000,000 枚，超出的部分退回 | [`0x1f4ca03b…9e50`](https://testnet.bscscan.com/tx/0x1f4ca03ba7ff941bd270e4771ddbf094ae889ff8b69e51a0913eeeff1a6b9e50) | 211,403 |
| 给交易者转 0.05 MockSPCXB | — | [`0x93370428…8cc1`](https://testnet.bscscan.com/tx/0x93370428705d8d03c4daaf1b5ed53fe5151feee860ad35ca08e8538b84998cc1) | 51,294 |
| 交易者买入新币、买入老币（只模拟，不广播） | 都回滚 `NotAgent`；`canTradeCurve` 为 false；pad 的 `tryBuy` 和 registry 的 `previewBuy` 都报 0 | 无 | — |

另一笔是 MockSPCXB 的 approve [`0xc481cf75…a9cf`](https://testnet.bscscan.com/tx/0xc481cf75ed966f35b7dcea20a5e92841c3f314bf633ddff17e081a73ac24a9cf)。5 笔交易全部成功。记录：`broadcast/AgentWindowTestnetAcceptance.s.sol/97/run-1795199556281.json`。

窗口结束前直接读链（区块时间 1795199595）：`agentWindowOpen` = false，`canTradeCurve(token, trader)` = false，`walletCapOn` = true，registry 给交易者的报价 = 0，dev 持有 10,000,000 枚。

### 阶段 2：开放后

链上 `agentWindowOpen` 在区块时间 1795199619 变为 true，之后运行。

| 步骤 | 结果 | 交易 | gas |
|---|---|---|---|
| 交易者买 0.04 | 成交数量等于 registry 事先给交易者的报价 | [`0xd3754afe…ede6a`](https://testnet.bscscan.com/tx/0xd3754afe0a15cc3eb23e5284b78f171cac75805d1d5679292408b615d1bede6a) | 174,779 |
| 交易者卖出四分之一 | 成功 | [`0x59228ae0…1849`](https://testnet.bscscan.com/tx/0x59228ae00967b331eb6995213ab8ce15dcac1a8a99e900c326d8a00e5dd51849) | 154,287 |
| 给交易者转「剩余毕业额 + 1」个 MockSPCXB | — | [`0x460b61db…9fe0`](https://testnet.bscscan.com/tx/0x460b61db5792226d6897179a1b2ba713a5b50070aef653e2b11a003259799fe0) | 34,230 |
| 交易者一笔买到毕业 | 迁移到 Pancake 测试网交易对 [`0x388e221628Da6eC0BdE1C62fc04b45D5d1241b31`](https://testnet.bscscan.com/address/0x388e221628Da6eC0BdE1C62fc04b45D5d1241b31) | [`0x5fa85e48…4c5f`](https://testnet.bscscan.com/tx/0x5fa85e48e3694ad0f924ac0ab1663b615635bde2a847746bc3a4ade82fba4c5f) | 2,377,153 |
| 交易者把剩余报价币退回 dev | — | [`0xc8204ea7…483e`](https://testnet.bscscan.com/tx/0xc8204ea7c60bf817686a47c7a2cec0a9299005eadfead87807d15bad232e483e) | 33,909 |
| 老币（只模拟，不广播） | 交易者仍被拒（`NotAgent`），报价为 0 | 无 | — |

5 笔交易全部成功。记录：`broadcast/AgentWindowTestnetAcceptance.s.sol/97/run-1795199675716.json`。

毕业后读链：
- `getTokenInfo` 状态为 2（池子），剩余毕业额为 0；
- 交易对里有 200,000,000 枚代币和 6 个 MockSPCXB；
- 交易者（没有 Agent ID 的合约）持有 790,000,000 枚，即 79%，远超 1%；dev 持有 10,000,000 枚；
- 老币 `canTradeCurve(old, trader)` 仍为 false。

## 没做

- **聚合器入口（GangGateway、`buyTokenAMAP`）由普通钱包买入**：这些入口要求交易者就是发起交易的钱包（`trader == tx.origin`），合约做不到，而这次没有新建 EOA。这条路径由单元测试 `test_open_everyEntry` 和主网 fork `test/fork/Pad3AgentWindowFork.t.sol` 覆盖。
- **冲毕业奖励币带窗口时的计数**：由单元测试覆盖（开放后只计 agent 的买入；普通钱包推到毕业时，名单上的 agent 拿走整个奖池）。
- **推广分成币带窗口**：由单元测试覆盖（开放后普通钱包能买入，但不会被绑定）。
- **`PAD3_PROMOTE_PROBES`**：升级脚本提示，有推广分成的币但这次没设这个变量，所以绑定关系和收益没有逐个比对。测试网上接受了；**主网签名前必须按 `PromoterBound` 日志设好**，`PAD3_BASE_PROBES` 也一样（spec §9.2）。
- **重跑其他测试网验收**（vanity 验收、金库验收）：这次没跑。窗口不影响没设窗口的币，升级脚本的读回也已比对了最新 25 个币。

## 花费

部署钱包 tBNB 从 0.0706 降到 0.0679，约 0.0027，全部是 gas。MockSPCXB 净用掉约 6.1 个：6 个进了交易对，0.05 换成了 dev 自己的持仓，交易者剩下的报价币已退回。
