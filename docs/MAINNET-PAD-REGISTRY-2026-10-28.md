# 主网 · GangPadRegistry（聚合器用的 pad registry）

GangPadRegistry 已在 2026-10-28 部署到 BSC 主网，owner 是平台 Safe，登记了主网 GangLaunchpad。部署用的代码是合并 PR #44、#45 之后的 `main`（`1169dd7`）：在 `git archive` 导出的干净目录里运行，不受本地未提交改动的影响。

- 链：BSC 主网（chainId 56），区块 130255805（2026-10-28 17:17:14 +08:00）
- 规格：`docs/SPEC-PAD-REGISTRY-2026-10-28.md`；审计说明 §24；测试网：`docs/TESTNET-PAD-REGISTRY-2026-10-28.md`

## 地址

| 项 | 值 |
|---|---|
| **GangPadRegistry**（代理，聚合器记这个地址） | [`0x4fF77D4d9ac080939a24E1B805206bA094C44e5C`](https://bscscan.com/address/0x4fF77D4d9ac080939a24E1B805206bA094C44e5C) |
| 实现合约 | [`0x84DA18f55493032eDdB99c85726bD25f182080b5`](https://bscscan.com/address/0x84DA18f55493032eDdB99c85726bD25f182080b5) |
| ProxyAdmin（代理自己创建的） | `0x9efbcf84b80Ab437AE82c74E2D047b997172f84D` |
| owner（`addPad`、两步转移）和 ProxyAdmin 的 owner（升级） | Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`（2/3），不经时间锁 |
| 已登记的 pad | GangLaunchpad `0x15CFD2dc8278Fb87a1783ef42111618E20874365`（在 `initialize` 里登记） |
| 部署钱包 | `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`（部署后对 registry 没有任何权限） |
| 部署交易 | 实现合约 [`0xef4a408d…efa31`](https://bscscan.com/tx/0xef4a408d61511f723bf5481b95c21733f7a1808f40767cf7702811c95c0efa31)，gas 1,078,376；代理 [`0x81b413ca…cbc2`](https://bscscan.com/tx/0x81b413ca7af76b12396b2faba5e9ea32eba803cf01f761bea79427fe4b84cbc2)，gas 663,470；gas 价格 0.05 gwei（legacy） |
| 广播记录 | `broadcast/DeployGangPadRegistry.s.sol/56/` |
| 源码验证 | 已在 BscScan 验证（2026-10-28）：实现合约 GangPadRegistry、代理 TransparentUpgradeableProxy（已标记为代理并指向实现合约）、ProxyAdmin 三个合约，源码取自 `1169dd7`，编译设置为 solc 0.8.28、via-ir、优化 200 次、cancun。验证前确认过：本地编译出的实现合约字节码与链上一致，包括 metadata |

部署命令：`GANG_PAD=0x15CF…4365 GANG_MAINNET_OK=true forge script script/DeployGangPadRegistry.s.sol --rpc-url $BSC_RPC_URL --broadcast --legacy --with-gas-price 50000000`。`OWNER` 没有传，主网默认就是 Safe。多签在部署时什么都不用签。

## 部署后的检查

- **重跑自检**：用 `GANG_PAD_REGISTRY=0x4fF7…4e5C` 跑 `DeployGangPadRegistry`（不广播），结果通过。检查项包括：代理代码；实现合约的代码（与本次构建一致，已锁死）；ProxyAdmin（代理自己创建、标准 OZ 代码、owner 是 Safe）；registry 的 owner 是 Safe、没有待接手的 owner、pad 列表只有主网 pad；`padOf(pad)` 为 0；`padOf(最后一个币)` 返回 pad。
- **链上直接调用**：
  - `owner()` 和 ProxyAdmin 的 `owner()` 都是 Safe，`pendingOwner()` 为 0，`pads()` 为 `[0x15CF…4365]`。
  - 当时 pad 上有 127 个币。抽查第一个和最后一个，`lookup` 分别返回 `(pad, 2)`（打新币）和 `(pad, 1)`（曲线币），和 pad 自己的 `kindOf` 一致。
- **报价核对（主网 fork，用的是已部署的 registry）**：
  - 模拟 pad owner 把一个测试路由加进白名单，用发币人（持有 Agent ID）当交易钱包。
  - 在 6 条还在内盘的 WBNB 曲线上，各买入 0.003 BNB 再全部卖出。`previewBuy` / `previewSell` 和真实的 `buyFor` / `sellFor` 结果逐 wei 一致（成交量、退款、卖出所得）。
  - 这个测试是临时的，没有提交。仓库里的同类测试是 `test/fork/PadRegistryTestnetFork.t.sol`（测试网）。

## 权限说明

owner 是 Safe 本身，不经时间锁：Safe 执行 `addPad` 或升级，立即生效。聚合器想及时发现改动，可以监控 registry 的 `PadAdded`、`OwnershipTransferStarted` 和代理的 `Upgraded` 事件。紧急止损仍然用 pad 自己的 `setRouter(路由, false)`。
