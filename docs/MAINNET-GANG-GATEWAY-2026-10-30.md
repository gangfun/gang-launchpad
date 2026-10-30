# 主网 · GangGateway（聚合器用的内盘网关）

GangGateway 已在 2026-10-30 部署到 BSC 主网。owner 和时间锁都归平台 Safe，网关通过主网 GangPadRegistry 找 pad。部署用的是合并 PR #76 之后的 `main`（`19f4fc0`），在 `git archive` 导出的干净目录里运行，本地未提交的改动不会混进去。

部署前完成的流程：审计 → 修复 → 复审 → 再次修复后复审 → 加卖出调用方白名单 → 白名单审计 → 修复后复审 → 测试网第二版验收（见审计说明 §25、`docs/TESTNET-GANG-GATEWAY-2026-10-30.md`）。

- 链：BSC 主网（chainId 56），区块 130610192（2026-10-30 13:36:26 +08:00）
- 规格：`docs/SPEC-GANG-GATEWAY-2026-10-30.md`；审计说明：§25

## 地址

| 项 | 值 |
|---|---|
| **GangGateway**（代理：用户授权、聚合器调用这个地址） | [`0x9dD16b73f624bdd8a210CBB2602FdF70f1B450B8`](https://bscscan.com/address/0x9dD16b73f624bdd8a210CBB2602FdF70f1B450B8) |
| 实现合约 | [`0xcC20bc90336729DA3a37005e2389DEB963f61360`](https://bscscan.com/address/0xcC20bc90336729DA3a37005e2389DEB963f61360) |
| ProxyAdmin（代理自己创建，owner 是时间锁） | `0x385690fa1459c90eb76728eE00E9c9937069Eec4` |
| TimelockController（48 小时；提案、执行、取消都只有 Safe，没有 admin；管网关升级） | `0xc5C02788CA0A1b6E9810B5CE3d6D49D5E8fe8e8B` |
| 网关 owner（管卖出调用方白名单，不经时间锁） | Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`（2/3） |
| 读取的 registry | `0x4fF77D4d9ac080939a24E1B805206bA094C44e5C`（主网 GangPadRegistry） |
| 部署钱包 | `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`（部署后对网关和时间锁没有任何权限） |
| 广播记录 | `broadcast/DeployGangGateway.s.sol/56/` |
| 源码验证 | 已在 BscScan 验证（2026-10-30）：实现合约 GangGateway、TimelockController 用 `forge verify-contract` 提交；代理 TransparentUpgradeableProxy 和 ProxyAdmin 与 registry 的字节码相同，BscScan 已自动匹配；代理已标记为指向实现合约。源码取自 `19f4fc0`，编译设置为 solc 0.8.28、via-ir、优化 200 次、cancun。提交前确认过四个合约本地编译的字节码与链上一致，包括 metadata（immutable 位置除外） |

部署交易，都在区块 130610192，gas 价格 0.05 gwei（legacy）：

| 交易 | gas |
|---|---|
| 实现合约 [`0xf3d9fbf0…4bb9`](https://bscscan.com/tx/0xf3d9fbf054a275e46528b09adafcd7e39f27572e95b95a375c2b5142c15e4bb9) | 1,585,283 |
| 时间锁 [`0xd686d67e…62ef`](https://bscscan.com/tx/0xd686d67e1e87d915d964748c8a0d0ccca2d1744f409b0c6f6e1f723b60e062ef) | 1,376,896 |
| 代理（在构造函数里调用 `initialize(registry, WBNB, Safe)`） [`0x2f2d09b3…91d3`](https://bscscan.com/tx/0x2f2d09b3ed049efc50b1611d7c28018913f4a7a32d01925c841cbb012b5d91d3) | 632,267 |

部署命令：`GANG_MAINNET_OK=true forge script script/DeployGangGateway.s.sol --rpc-url $BSC_RPC_URL --broadcast --legacy --with-gas-price 50000000`。`GANG_PAD_REGISTRY` 和 `OWNER` 都没有传，主网默认分别是 `M.PAD_REGISTRY` 和 Safe。广播前先模拟了一遍，自检通过。

## 部署后的检查

- **重跑自检**：用 `GANG_GATEWAY=0x9dD1…50B8` 跑 `DeployGangGateway`（不广播），结果通过。检查项：
  - registry：代码与本次构建一致、owner 是 Safe、pad 列表正确；
  - 网关代理代码；
  - 实现合约：代码与本次构建一致，已锁死；
  - ProxyAdmin：由代理自己创建，标准 OZ 代码，owner 是时间锁；
  - 时间锁：代码、48 小时延迟，只有 Safe 有提案 / 执行 / 取消角色，部署钱包没有任何角色；
  - 网关的 registry、WBNB；
  - 网关 owner 是 Safe，没有待接手的 owner。
- **链上直接调用**：
  - `owner()` 是 Safe，`pendingOwner()` 为 0；`registry()` 和 `wbnb()` 正确。
  - ProxyAdmin 的 `owner()` 是时间锁；时间锁 `getMinDelay()` 为 172800 秒（48 小时），Safe 有 `PROPOSER_ROLE`，部署钱包没有。
  - pad 上 `routers(网关)` 为 **false**（还没有列入）。
  - 最后一个币 `0xB043…13ed` 的 `getTokenInfo` 返回 status 1、BNB 计价、手续费 100、`graduationLeft` ≈ 14.96 BNB。
  - 没有列入之前，`tryBuy` 返回 0，符合预期。

## 列入 pad 之后（2026-10-30）

Safe 执行了下面第 1 步之后，链上直接调用：

- pad 上 `routers(网关)` 为 **true**；原 GangRouter `0xE040…79C4` 仍为 true；pad 的 owner 仍是 Safe，agent 门槛开着。
- 内盘币 `0x58C9…e67E`（BNB 计价）：`getTokenInfo` 返回 status 1、手续费 100；`tryBuy(币, 0, 0, 0.01 BNB)` 返回约 1,874,478 个币、手续费 0.0001 BNB、`amountMsgValue` 0.01 BNB；`trySell(币, 1000 个)` 返回非零。
- 不持有 Agent ID 的地址：`tryBuy` 返回 0，模拟 `buyTokenAMAP` 回滚 `NotAgent`。
- 还没有做真实的主网买卖（部署钱包没有 Agent ID）；白名单为空。

## Safe 操作（上线步骤）

1. **把网关列入 pad**（已执行）。
   - to：GangLaunchpad `0x15CFD2dc8278Fb87a1783ef42111618E20874365`
   - 调用：`setRouter(0x9dD16b73f624bdd8a210CBB2602FdF70f1B450B8, true)`
   - calldata：`0xc3c646740000000000000000000000009dd16b73f624bdd8a210cbb2602fdf70f1b450b80000000000000000000000000000000000000000000000000000000000000001`

   列入后，用户可以直接调网关买卖，卖出时 `from == msg.sender`，不需要加白；聚合器合约可以经网关买入。
2. **给聚合器合约加白**（卖出要用），按审计说明 §25.10 的五项清单审核对方合约之后再执行。
   - to：GangGateway `0x9dD16b73f624bdd8a210CBB2602FdF70f1B450B8`
   - 调用：`setCaller(<聚合器合约>, true)`
   - 合约会拒绝 EOA 和 7702 委托账户。也可以用 `GATEWAY_CALLERS=<地址> GANG_GATEWAY=0x9dD1…50B8` 重跑部署脚本，生成 calldata。
3. 紧急止损：Safe `setCaller(<地址>, false)` 移除单个调用方；`setRouter(网关, false)` 把整个网关从 pad 下架。两者都立即生效。
