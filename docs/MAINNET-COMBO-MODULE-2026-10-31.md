# 主网 · GangComboSplitterFactory（组合收款模块：回购 + 加池 + 分账，`combo-v1`）

- 链：BSC 主网（chainId 56），2026-10-31
- 源码：PR #95（分支 `feat/combo-module`，`b99bc6f`），合约与测试网部署时相同；`b99bc6f` 已包含部署时的 main `123a8cb`
- 测试网：`docs/TESTNET-COMBO-MODULE-2026-10-31.md`
- 部署脚本：`script/DeployGangComboSplitterFactory.s.sol`，部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`

## 地址

| 项 | 地址 / 交易 |
|---|---|
| GangComboSplitterFactory | [`0xd33C38BE3f8472b3013167830F0638C1704e1DBd`](https://bscscan.com/address/0xd33C38BE3f8472b3013167830F0638C1704e1DBd)，部署 [`0x34209c01…8e07`](https://bscscan.com/tx/0x34209c01dba09bddd591ddec8c8ecd36e6a4ed123bfe3426bc287554a51e8e07)，区块 130805977，gas 4,216,121 |
| GangComboSplitter（实现合约，工厂部署） | [`0x38F2d4A74BBdE29E32b2D641fdA23828cC2850Df`](https://bscscan.com/address/0x38F2d4A74BBdE29E32b2D641fdA23828cC2850Df)，同一笔交易；`gangQuote` = GANG `0x0c6302401aa5325C2E36F170f52C00B1d220B405` |
| BscScan 源码验证 | 两个都已验证（solc 0.8.28，按 `foundry.toml`） |

部署花费约 0.000211 BNB（gas price 0.05 gwei，legacy）。

接线（脚本在模拟和广播里都检查通过，包括运行时字节码比对 `checkCode`）：

| 项 | 值 |
|---|---|
| pad | GangLaunchpad（1.0）`0x15CFD2dc8278Fb87a1783ef42111618E20874365` |
| tax handler | GangTaxHandler `0x6D8d3dE459629cBb7b552169a55D754db60cAe0c`，owner = GangHandlerAdmin |
| GangHandlerAdmin | `0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985`，owner = 多签 `0x2866369F7acEFC9760bdE7779362fae5cD68B41E` |

这个工厂只服务 1.0 的 pad。GangLaunchpad 2.0 有自己的 handler 和 GangHandlerAdmin，上主网时要用同一个脚本（`GANG_PAD` 指向 2.0，`HANDLER_ADMIN` 指向 2.0 的 admin）再部署一个组合工厂，和回购、分账、加池工厂一起由多签在 2.0 的 admin 上允许。

## 多签批量（已执行）

导入 Safe Transaction Builder：`docs/MAINNET-COMBO-MODULE-SAFE-BATCH-2026-10-31.json`。一笔：

| to | 调用 | calldata |
|---|---|---|
| GangHandlerAdmin `0xF56A…E985` | `setFactory(0xd33C…1DBd, true)` | `0x71013c10…d33c38be…01`，与部署脚本打印的一致 |

已有的回购、分账、加池工厂不受影响。2026-10-31 在服务端（gangfun-server v1.2.62：indexer、keeper）和网站（gang-web-legacy v1.2.99）认 `combo-v1` 并上线之后，由多签执行：[`0xa0276851…f7f8`](https://bscscan.com/tx/0xa0276851dcf82aaefc296289b4419b53a105b81ff3d78f809108eddb436cf7f8)，区块 130811492。

执行后核对（2026-10-31 已跑）：新工厂已允许；分账工厂 `0x27e0…067c`、加池工厂 `0xE043…C248` 仍允许；handler 的 owner 仍是管理合约、没有待接收的 owner；管理合约 owner 仍是多签；脚本检查模式打印「nothing to do」；真实 Agent `0xf7A8…14aA` 静态调用 `factory.create(3000, 3000, [自己, 另一个地址], [7000, 3000], salt)` 返回 `predict` 的地址（估算 gas 432,087）。命令：

```sh
GANG_PAD=0x15CFD2dc8278Fb87a1783ef42111618E20874365 HANDLER_ADMIN=0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985 \
  COMBO_FACTORY=0xd33C38BE3f8472b3013167830F0638C1704e1DBd \
  forge script script/DeployGangComboSplitterFactory.s.sol --rpc-url https://bsc-dataseed.binance.org
# 应打印 "Safe batch: nothing to do (factory allowed)"
```

## 上主网前的演练（主网 fork）

`test/fork/ComboMainnetFork.t.sol`（需要 `BSC_RPC_URL`，没有时跳过），部署前在 `b99bc6f` 上跑过，2 个全过：

- 按部署脚本的方式部署工厂；`check`、`checkCode` 通过；冒充多签执行上面那一笔之后 `pendingBatch` 为空。
- 一个 Agent 克隆组合模块（回购 30%、加池 30%，其余 70 / 30 给自己和一个 KOL），用它当收款地址建 WBNB 计价的有税币，`bind`；把内盘买到毕业，真实的 PancakeSwap 交易对建好；池子交易交税（另给模块补 0.5 WBNB，让块数够多）；keeper 按 `previewWork` / `work` 循环：回购和加池都做了，代币和真实的 Pancake LP 进 0xdead，KOL 收到分成。Agent ID 用 mock。

同一棵树上的全量测试：1190 个通过、0 失败、137 个跳过（fork 测试，没设 RPC）。

## 调用方注意

- `split` / `work` / `distribute` / `release` 推送收款人时，每个收款人要求剩余 gas 约 36.5 万以上，否则回滚 `PushStarved`；一块加池 0.55M ~ 0.75M gas。gas limit 一律用节点的 `eth_estimateGas`，不能按「模拟用量 × 系数」或固定值。
- keeper 把 `previewWork` 返回的 `minOut` 原样传给 `work`（最高字节是计划的动作）。

## 还要做的

1. ~~服务端（indexer、keeper：drain 类型加 `combo-v1`，`ChunkTooSoon` 当「不是现在」）和网站认 `combo-v1` 并上线~~（2026-10-31 已上线：gangfun-server v1.2.62、gang-web-legacy v1.2.99）。
2. ~~多签执行上面的批量~~（已执行，见上）。
3. ~~CLI 发版：`gang create … --buyback <pct> --lp <pct> [--split <addr>:<pct>,…]`（两个及以上）、`gang combo …`，主网工厂地址指向 `0xd33C…1DBd`~~（2026-10-31：PR #96 合并，`@gangfun/cli` 0.22.0 已在 npm）。
4. ~~网站文档改为主网已开放~~（2026-10-31：gang-web-legacy v1.2.100）。
5. GangLaunchpad 2.0 上主网时：用同一个脚本给 2.0 部署组合工厂，多签在 2.0 的 admin 上 `setFactory`；CLI 按 pad 版本选工厂（PR #98）。测试网 2.0 已部署并验收，见测试网记录。
