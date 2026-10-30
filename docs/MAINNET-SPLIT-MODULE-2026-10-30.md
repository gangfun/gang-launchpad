# 主网 · GangSplitModuleFactory（多人分账收款模块，`split-v1`）

- 链：BSC 主网（chainId 56），2026-10-30
- 源码：PR #79（分支 `feat/split-module`），合约与测试网部署时的 `d9e0834` 相同；部署时用的是这个分支与当时 main（`b498b5c`）合并后的树，两边的 `src/gang/` 依赖文件没有差别
- 测试网：`docs/TESTNET-SPLIT-MODULE-2026-10-30.md`
- 部署脚本：`script/DeployGangSplitModuleFactory.s.sol`，部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`

## 地址

| 项 | 地址 / 交易 |
|---|---|
| GangSplitModuleFactory | [`0x27e08271E52B2D129c824CD245e69471a8d3067c`](https://bscscan.com/address/0x27e08271E52B2D129c824CD245e69471a8d3067c)，部署 [`0x3b698f9a…7e2c`](https://bscscan.com/tx/0x3b698f9a4a39a045baac3f3d635f51857d39e494e90dc6f10d3551f475767e2c)，区块 130666237，gas 2,340,160 |
| GangSplitModule（实现合约，工厂部署） | [`0x9500f6CfEe5bEEEe2F554C557cDfc5eF903AdDd8`](https://bscscan.com/address/0x9500f6CfEe5bEEEe2F554C557cDfc5eF903AdDd8)，同一笔交易 |
| BscScan 源码验证 | 两个都已验证（solc 0.8.28，按 `foundry.toml`） |

部署花费约 0.000117 BNB（gas price 0.05 gwei，legacy）。

接线（脚本检查模式 `SPLIT_FACTORY` 已设，通过；包括运行时字节码比对 `checkCode`）：

| 项 | 值 |
|---|---|
| pad | GangLaunchpad `0x15CFD2dc8278Fb87a1783ef42111618E20874365` |
| tax handler | GangTaxHandler `0x6D8d3dE459629cBb7b552169a55D754db60cAe0c`，owner = GangHandlerAdmin |
| GangHandlerAdmin | `0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985`，owner = 多签 `0x2866369F7acEFC9760bdE7779362fae5cD68B41E` |
| 实现合约的 `gangQuote` | GANG `0x0c6302401aa5325C2E36F170f52C00B1d220B405`（keeper 自动分账的报价币：WBNB、GANG、QuoteRegistry 里的报价币） |

## 多签批量（待执行）

导入 Safe Transaction Builder：`docs/MAINNET-SPLIT-MODULE-SAFE-BATCH-2026-10-30.json`。一笔：

| to | 调用 | calldata |
|---|---|---|
| GangHandlerAdmin `0xF56A…E985` | `setFactory(0x27e0…067c, true)` | `0x71013c10…27e08271…01`，与部署脚本打印的一致 |

已有的回购工厂不受影响。执行后核对：

```sh
GANG_PAD=0x15CFD2dc8278Fb87a1783ef42111618E20874365 HANDLER_ADMIN=0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985 \
  SPLIT_FACTORY=0x27e08271E52B2D129c824CD245e69471a8d3067c \
  forge script script/DeployGangSplitModuleFactory.s.sol --rpc-url https://bsc-dataseed.binance.org
# 执行前打印一笔 Safe 调用；执行后不再打印 Safe 调用
```

## 上主网前的演练（主网 fork）

`test/fork/SplitMainnetFork.t.sol`（需要 `BSC_RPC_URL`，没有时跳过），部署前（区块约 130,665,500）跑过，2 个全过：

- 按部署脚本的方式部署工厂；部署脚本的 `check`、`checkCode` 通过；冒充多签执行上面那一笔之后，`pendingBatch` 为空；handler 的 owner 仍是管理合约，管理合约 owner 仍是多签。
- 一个 Agent（Agent ID 用 mock）克隆 60% / 30% / 10% 的分账模块：地址等于 `predict`，`moduleType` = `split-v1`，`moduleOf` = 工厂，handler 上已加白；用它当收款地址建 WBNB 计价的有税币（买卖税 2%），`bind` 成功；`keeperServes` 对 WBNB 和 GANG 都是 true，毕业前 `previewWork` 不 due；分别打入 WBNB 和 GANG 后 `distribute`，三人按份额到账（取整余数给第一位），模块里不剩、欠款为 0。
- 毕业后池子交税、keeper `work` 的整轮在测试网走过（见测试网记录）。

## 调用方注意

每次推送前合约要求剩余 gas ≥ 约 36.5 万（`PUSH_GAS × 64/63 + PUSH_RESERVE`），所以 `distribute` / `work` / `release` / `setPayee` 的 gas limit 要用节点的 `eth_estimateGas`，不能按实际用量或固定值给，否则回滚 `PushStarved`（测试网记录「两笔失败」）。

## 还要做的

1. 服务端（indexer、keeper）和网站认 `split-v1`。
2. 多签执行上面的批量。
3. CLI 发版：`gang create … --split`、`gang split …`，主网工厂地址指向 `0x27e0…067c`。
