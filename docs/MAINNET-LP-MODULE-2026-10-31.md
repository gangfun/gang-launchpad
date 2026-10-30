# 主网 · GangLiquiditySplitterFactory（税收自动加池子模块，`lp-burn-v1`）

- 链：BSC 主网（chainId 56），2026-10-31
- 源码：PR #91（分支 `feat/lp-module`，`51181ae`），合约与测试网部署时的 `0c9a13a` 相同；部署时 main 是 `e73dc6e`，PR 分支就基于它
- 测试网：`docs/TESTNET-LP-MODULE-2026-10-30.md`
- 部署脚本：`script/DeployGangLiquiditySplitterFactory.s.sol`，部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`

## 地址

| 项 | 地址 / 交易 |
|---|---|
| GangLiquiditySplitterFactory | [`0xE0436867dAFcf42Ee1418083251a9B8B61F0C248`](https://bscscan.com/address/0xE0436867dAFcf42Ee1418083251a9B8B61F0C248)，部署 [`0x2ebed265…a758`](https://bscscan.com/tx/0x2ebed2653d507d926394b6ae5214af10cc2ba0ade13cddbf9293a6093a35a758)，区块 130698949，gas 2,749,835 |
| GangLiquiditySplitter（实现合约，工厂部署） | [`0x3B453e1ba5bb70B7AE9254789C5C08ccaFeE3151`](https://bscscan.com/address/0x3B453e1ba5bb70B7AE9254789C5C08ccaFeE3151)，同一笔交易 |
| BscScan 源码验证 | 两个都已验证（solc 0.8.28，按 `foundry.toml`） |

部署花费约 0.000137 BNB（gas price 0.05 gwei，legacy）。

接线（脚本检查模式 `LP_FACTORY` 已设，通过；包括运行时字节码比对 `checkCode`）：

| 项 | 值 |
|---|---|
| pad | GangLaunchpad `0x15CFD2dc8278Fb87a1783ef42111618E20874365` |
| tax handler | GangTaxHandler `0x6D8d3dE459629cBb7b552169a55D754db60cAe0c`，owner = GangHandlerAdmin |
| GangHandlerAdmin | `0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985`，owner = 多签 `0x2866369F7acEFC9760bdE7779362fae5cD68B41E` |

## 多签批量（待执行）

导入 Safe Transaction Builder：`docs/MAINNET-LP-MODULE-SAFE-BATCH-2026-10-31.json`。一笔：

| to | 调用 | calldata |
|---|---|---|
| GangHandlerAdmin `0xF56A…E985` | `setFactory(0xE043…C248, true)` | `0x71013c10…e0436867…01`，与部署脚本打印的一致 |

已有的回购工厂、分账工厂不受影响。在服务端（indexer、keeper）和网站认 `lp-burn-v1` 之后执行。执行后核对：

```sh
GANG_PAD=0x15CFD2dc8278Fb87a1783ef42111618E20874365 HANDLER_ADMIN=0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985 \
  LP_FACTORY=0xE0436867dAFcf42Ee1418083251a9B8B61F0C248 \
  forge script script/DeployGangLiquiditySplitterFactory.s.sol --rpc-url https://bsc-dataseed.binance.org
# 执行前打印一笔 Safe 调用；执行后应打印 "Safe batch: nothing to do (factory allowed)"
```

## 上主网前的演练（主网 fork）

`test/fork/LpMainnetFork.t.sol`（需要 `BSC_RPC_URL`，没有时跳过），部署前在合并后的树上跑过，2 个全过：

- 按部署脚本的方式部署工厂；`check`、`checkCode` 通过；冒充多签执行上面那一笔之后 `pendingBatch` 为空；handler 的 owner 仍是管理合约。
- 一个 Agent（Agent ID 用 mock）克隆 70% 的加池模块，用它当收款地址建 WBNB 计价的有税币（买卖税 3%，分红 40%），`bind`；一次性买家把内盘买到毕业，真实的 PancakeSwap 交易对建好，毕业 LP 在 0xdead；池子卖出交税，keeper 的 `process` 付给模块；四块加池：每块花掉的报价币在 chunk 的一半到全额之间，铸出真实的 Pancake LP 到 0xdead，模块不持有代币、不持有 LP；handler 的 swap-back 在块中付给本模块，留到下一次拆分。

同一棵树上的全量测试：1147 个通过、0 失败、135 个跳过（fork 测试，没设 RPC）。

## 调用方注意

一块加池在真实交易对上要 0.53M ~ 0.75M gas（存币那一步会让 handler 先卖一块已收的税，GangToken 给它最多 60 万 gas）。`work` / `addChunk` 的 gas limit 用节点的 `eth_estimateGas`，不能按固定值或压低，否则回滚 `SwapBackOutOfGas`。

## 还要做的

1. 服务端（indexer、keeper：drain 类型加 `lp-burn-v1`，`AddTooSoon` 当「不是现在」）和网站认 `lp-burn-v1`。
2. 多签执行上面的批量。
3. CLI 发版：`gang create … --lp <0-100> [--lp-to <addr>]`、`gang lp …`，主网工厂地址指向 `0xE043…C248`。
