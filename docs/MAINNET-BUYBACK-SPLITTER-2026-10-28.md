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

## v2 工厂：收款地址（`buyback-burn-v2`，PR #53）

dev 可以把回购以外的那份打给别的地址（`payee`，建币时 `--buyback-to`，之后随时 `set-payee`）。管理合约不变，只加一个工厂：

| 项 | 值 |
|---|---|
| GangBuybackSplitterFactory v2 | [`0x93467Cb38B9Cb7f6EF3b67d2226Eb8b77ca58F2f`](https://bscscan.com/address/0x93467Cb38B9Cb7f6EF3b67d2226Eb8b77ca58F2f)，实现合约 [`0x5Ac016FF863BCbd2bC4c84B595A99A7D3eF9D94f`](https://bscscan.com/address/0x5Ac016FF863BCbd2bC4c84B595A99A7D3eF9D94f)；两个都已在 BscScan 验证 |
| 部署 | [`0x0a2cd45b…13d1`](https://bscscan.com/tx/0x0a2cd45b3f26958ff135c7d8488a9a271a14329415b4ab267bb3a636521613d1)，区块 130307842，gas 2,540,839，部署钱包 `0x4EEd…19d3` |
| 多签批量 | `docs/MAINNET-BUYBACK-SPLITTER-V2-SAFE-BATCH-2026-10-28.json`：一笔 `GangHandlerAdmin.setFactory(0x9346…8F2f, true)`，2026-10-28 已执行：[`0x8a6a7e09…100d`](https://bscscan.com/tx/0x8a6a7e09a0540fca0724cd3c7fec682078e674777b137d1b614f10c03ac2100d)，区块 130308783。执行后核对：v2 / v1 工厂都允许，handler owner 仍是管理合约，脚本检查模式「nothing to do」，真实 Agent 对 v2 `create(…, payee)` 的静态调用返回 `predict` 的地址（估算 gas 338,547） |
| v1 工厂 `0x6bcd…8546` | 保持允许，直到 CLI 用户都换到 0.14.0（0.13.0 调的是 v1 的两参数 `create`）；之后可由多签 `setFactory(0x6bcd…8546, false)` 停用，它克隆出去的合约照常工作 |

演练（anvil 主网 fork，区块 130307708）：同一脚本部署 → 冒充多签 `setFactory` → 真实 Agent `0xf7A8…14aA` 以 40%、payee `0x…be1ef` 克隆（地址等于 `predict`，已加白，`moduleOf` = v2 工厂）→ 建 WBNB 币并 bind → 打入 1 WBNB 拆分：payee 收到 0.6、dev 0、回购余额 0.4 → `setPayee` 后再拆：新 payee 收到 0.6、旧的不变 → `setPayee(自己)` 回滚 `BadPayee`、陌生地址回滚 `NotDev` → v1 工厂仍能克隆。

## v3：两块之间的间隔（`buyback-burn-v3`，GangBond 审计 H-1）——计划，未部署

GangBond 审计（`docs/AUDIT-GANG-BOND-2026-10-29.md` H-1、I-5）发现：价格拉高并维持 10 分钟后，均价追上来，回购每个区块都能买一块，攻击者每块卖回，几秒就买光整笔余额。splitter 照搬了同一套回购逻辑，v1、v2 同样成立。v3 加 `CHUNK_GAP` = 4 分钟（两块之间至少隔 4 分钟，`lastBurnBlock` 改为 `lastBurnAt`，不到时间回滚 `BurnTooSoon`，`previewBurn` / `previewWork` 报不能买），和 GangBond PR #54 的修法一致。详见规格 §4。

**现有主网 splitter 的风险（2026-10-29，区块 130341146 核对）**：管理合约下 4 个模块，全是 v1；v2 工厂没有克隆。4 个币都还在内盘、没有交易对，毕业前不收外盘税，所以报价币余额和 `buybackLeft` 全是 0，目前没有可被攻击的钱。

| splitter（v1） | 币 | 比例 | 报价币余额 |
|---|---|---|---|
| `0x9165…68E0` | GQ `0x86cc…103c` | 50% | 0 WBNB |
| `0xB82b…975D` | gang球 `0x5eca…1f7b` | 50% | 0 WBNB |
| `0xE5f7…a9Fa` | 钢球 `0x69fa…DAb9` | 100% | 0 WBNB |
| `0x8f86…B294` | GANGBALL `0x45f8…3eb5` | 100% | 0 GANG |

毕业后风险等于当时攒着的回购余额：平时只有 keeper 两轮之间（5 分钟）的税；价格持续上涨时回购暂停，余额会越攒越多。v1 克隆改不了，也没法改接收地址（币的 recipient 建币时就定了）。

**计划**（需要用户同意后执行）：

1. 部署 v3 工厂（`DeployGangBuybackSplitterFactory.s.sol`，同一个管理合约），BscScan 验证工厂和实现合约。
2. 多签批量：`setFactory(v3, true)`、`setFactory(v2 0x9346…8F2f, false)`、`setFactory(v1 0x6bcd…8546, false)`。停用 v1、v2 只影响新建（旧 CLI 发币会在 `listModule` 回滚 `NotFactory`），已有克隆照常工作。
3. 发 CLI：主网工厂地址指向 v3，最低版本提到新版本（0.13 / 0.14 / 0.15 发带回购的币会失败）。
4. 服务端和网站认 `buyback-burn-v3`：keeper `keeper-module-work.sh` 的 `NOT_NOW` 加 `BurnTooSoon`（v3 间隔内被别人抢先买了会这样回滚，不该报警）；indexer `src/splitters.js` 的 `BUYBACK_MODULES` 和网站 `src/buyback.js` 的类型列表加 v3（v3 有 payee，读 payee 的分支按 v2 处理）。这一步要在第 2 步之前上线。
5. 现有 4 个 v1 币：通知两位 dev 风险和选项——保持不变（keeper 会及时买掉，风险是毕业后价格持续拉高、余额攒大时被高位卖给回购）；或 `gang buyback set --pct 0` 在 3 天公告后关掉回购（之后全部给 dev）。
6. ~~测试网先走一遍~~：2026-10-29 已完成（PR #58 合并后）：测试网工厂 v6 `0x7E63…2BBe` 放行、v5 停用，CLI 发 GAPT、毕业、两块回购相隔 247 秒，间隔内回滚 `BurnTooSoon`。见 `docs/TESTNET-BUYBACK-SPLITTER-2026-10-28.md`「v6 工厂」。

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
4. ~~BscScan 源码验证~~（2026-10-28 已完成：GangHandlerAdmin、GangBuybackSplitterFactory、GangBuybackSplitter 实现合约三个都已验证，solc 0.8.28、优化 200 次、cancun；BscScan 接口读回的合约名和源码都对）。用的命令如下；这个 forge 版本要显式写 Etherscan v2 的 `chainid`，否则会先提交到 Sourcify、再因缺 `chainid` 报错（`--verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=56" --chain-id 56`）：

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
