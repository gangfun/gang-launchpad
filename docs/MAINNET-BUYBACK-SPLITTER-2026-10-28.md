# 主网 · GangHandlerAdmin + GangBuybackSplitterFactory（dev 税按比例回购）

- 链：BSC 主网（chainId 56），2026-10-28
- 规格：`docs/SPEC-BUYBACK-SPLITTER-2026-10-28.md`；测试网：`docs/TESTNET-BUYBACK-SPLITTER-2026-10-28.md`
- 源码：main `82e0481`（PR #48），合约与部署时用的 `07c0400` 相同
- 部署脚本：`script/DeployGangBuybackSplitterFactory.s.sol`，部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`

## 地址

| 项 | 地址 | 部署交易 |
|---|---|---|
| GangHandlerAdmin | [`0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985`](https://bscscan.com/address/0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985) | [`0x467b73e1…2787`](https://bscscan.com/tx/0x467b73e146d7858f28b25b099b45560de2c8c6e24466d0bf8b14f92196fc2787)，区块 130282032，gas 707,770 |
| GangBuybackSplitterFactory | [`0x6bcd79206da85Aa0643Db2164Ab887b468618546`](https://bscscan.com/address/0x6bcd79206da85Aa0643Db2164Ab887b468618546) | [`0xc89ab62d…d2c0`](https://bscscan.com/tx/0xc89ab62def015112baab75048979b21f9c1cbb746bdc0d4effbd67396067d2c0)，区块 130282037，gas 2,435,455 |
| GangBuybackSplitter（实现合约，工厂部署） | [`0x77D28168E424d58579623f93284Dd6E859e533BC`](https://bscscan.com/address/0x77D28168E424d58579623f93284Dd6E859e533BC) | 同上 |

接线（脚本检查模式 `HANDLER_ADMIN` / `SPLITTER_FACTORY` 已设，通过）：

| 项 | 值 |
|---|---|
| pad | GangLaunchpad `0x15CFD2dc8278Fb87a1783ef42111618E20874365` |
| tax handler | GangTaxHandler `0x6D8d3dE459629cBb7b552169a55D754db60cAe0c` |
| 管理合约的 owner | 多签 `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`（2/3，即 handler 现在的 owner） |
| 工厂的 pad / admin；实现合约的 pad / handler / factory | 全部对上 |

部署花费 0.000157 BNB（gas price 0.05 gwei，legacy）。

## 多签批量（已执行）

2026-10-28 由多签一次执行（Transaction Builder 批量）：[`0x3a976681…a41b`](https://bscscan.com/tx/0x3a97668130d5bc0fee3fe1367923eee6e94fac80363dae4c146a45982b0aa41b)，区块 130283285。

导入 Safe Transaction Builder：`docs/MAINNET-BUYBACK-SPLITTER-SAFE-BATCH-2026-10-28.json`。三笔，顺序不能变：

| # | to | 调用 | calldata |
|---|---|---|---|
| 1 | GangTaxHandler `0x6D8d…Ae0c` | `transferOwnership(0xF56A…E985)` | `0xf2fde38b…dad8fe985` |
| 2 | GangHandlerAdmin `0xF56A…E985` | `exec(0x79ba5097)` = 让 handler 执行 `acceptOwnership()` | `0x55f86501…79ba5097…` |
| 3 | GangHandlerAdmin `0xF56A…E985` | `setFactory(0x6bcd…8546, true)` | `0x71013c10…6bcd…01` |

执行后：
- handler 的 owner = GangHandlerAdmin；GangHandlerAdmin 的 owner 仍是多签。
- **多签以后对 handler 的操作都改成调 `GangHandlerAdmin.exec(<原来的 calldata>)`**，例如加白合作方 `exec(list(addr, label))`、`exec(delist(addr))`、换 keeper `exec(proposeKeeper(k))` / `exec(acceptKeeper())`、换 DEX router `exec(proposeDexRouter(r))` 等。
- 交回（撤销整个机制）：`GangHandlerAdmin.exec(transferOwnership(多签))`，再由多签调 `handler.acceptOwnership()`。

执行后核对（2026-10-28 已跑）：handler 的 owner = 管理合约、无待接收的 owner；管理合约 owner = 多签；工厂已允许；handler 的 keeper 不变（`0xB6f1…cFc7`）；脚本检查模式打印「nothing to do」；真实 Agent `0xf7A8…14aA` 静态调用 `factory.create(5000, salt)` 返回 `predict` 的地址（估算 gas 330,005）；keeper 对主网报「modules: 0 found」（经管理合约读取）。命令：

```sh
GANG_PAD=0x15CFD2dc8278Fb87a1783ef42111618E20874365 HANDLER_ADMIN=0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985 \
  SPLITTER_FACTORY=0x6bcd79206da85Aa0643Db2164Ab887b468618546 \
  forge script script/DeployGangBuybackSplitterFactory.s.sol --rpc-url https://bsc-dataseed.binance.org
# 应打印 "Safe batch: nothing to do (admin owns the handler, factory allowed)"
```

## 上主网前的演练（anvil 主网 fork，区块 130281857）

- 同一个脚本在 fork 上部署，地址与上面一致；冒充多签按上表执行 3 笔，全部成功：handler 的 owner = 管理合约，管理合约 owner = 多签，工厂已允许。
- 一个真实持有 Agent ID 的主网创建者（`0xf7A887D51dE8614E592B012076c8CcaE61e014aA`）调 `factory.create(5000, salt)`：克隆地址等于 `predict`，已加白，`moduleOf` = 工厂，dev / 比例正确。
- 多签经 `exec` 加白一个地址：成功。
- CLI（`GANG_RPC_URL` 指向 fork、`GANG_SPLITTER_FACTORY` = 工厂）：`gang create … --buyback 50` 给出克隆步骤。
- keeper `keeper-module-work.sh`（`PADS=main:0x15CF…4365`）：在 fork 上经管理合约找到 1 个模块；对真实主网（批量未执行）报「handler owner … is not a GangHandlerAdmin — no modules」，退出 0。

## 还要做的

1. ~~多签执行上面的批量~~（已执行，见上）。
2. CLI：主网工厂地址已写进 `skill/gang-cli/src/buyback.js`（`MAINNET_SPLITTER_FACTORY`），批量已执行，可以发版。
3. keeper：正式服务器 crontab 加 `keeper/crontab.txt` 里 `module-work` 那一行（`.env` 沿用 tax-process 的 `PADS` / `V3_PADS`、`KEEPER_PRIVATE_KEY`、`EXPECTED_KEEPER`，不用新增配置）；测站同样，或设 `MODULE_WORK_DISABLED=1`。
4. BscScan 源码验证（需要 `ETHERSCAN_API_KEY`；编译设置 solc 0.8.28、via-ir、优化 200 次、cancun，`foundry.toml` 已配好 `--chain bsc`）：

```sh
SAFE=0x2866369F7acEFC9760bdE7779362fae5cD68B41E; PAD=0x15CFD2dc8278Fb87a1783ef42111618E20874365
HANDLER=0x6D8d3dE459629cBb7b552169a55D754db60cAe0c; ADMIN=0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985
forge verify-contract $ADMIN src/gang/GangHandlerAdmin.sol:GangHandlerAdmin --chain bsc --watch \
  --constructor-args $(cast abi-encode "constructor(address,address)" $SAFE $HANDLER)
forge verify-contract 0x6bcd79206da85Aa0643Db2164Ab887b468618546 src/gang/GangBuybackSplitterFactory.sol:GangBuybackSplitterFactory \
  --chain bsc --watch --constructor-args $(cast abi-encode "constructor(address,address)" $PAD $ADMIN)
forge verify-contract 0x77D28168E424d58579623f93284Dd6E859e533BC src/gang/GangBuybackSplitter.sol:GangBuybackSplitter \
  --chain bsc --watch --constructor-args $(cast abi-encode "constructor(address)" $PAD)
```

   回购合约的克隆是 EIP-1167 最小代理，BscScan 会按实现合约识别。
5. 前端：合作方列表按 `GangHandlerAdmin.moduleOf` 过滤掉回购合约；币详情页展示 `buybackBps` 和 `pendingCut()`。
