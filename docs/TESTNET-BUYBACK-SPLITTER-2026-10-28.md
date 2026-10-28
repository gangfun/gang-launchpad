# 测试网 · GangBuybackSplitter（dev 税按比例回购销毁）

回购合约挂在第 10 套内盘上，走完了接入的全部步骤：部署并检查 → 多签 `list` 和 `setExcluded` → dev 建币时 recipient 填它 → `bind` → 毕业 → 池子里卖出交税 → keeper `process` → 拆分 → `burnChunk` 买入并销毁。比例调整（提高、申请下调、取消下调）和部署脚本的检查模式也都在链上跑过。

- 链：BSC 测试网（chainId 97），2026-10-28
- 规格：`docs/SPEC-BUYBACK-SPLITTER-2026-10-28.md`
- 合约：`src/gang/GangBuybackSplitter.sol`；部署 / 检查脚本：`script/DeployGangBuybackSplitter.s.sol`
- 发交易：`cast send --legacy --gas-price 0.1gwei`（原因见 `docs/TESTNET-GANG-BOND-2026-10-28.md`「gas」）

## 地址

| 项 | 值 |
|---|---|
| GangBuybackSplitter | [`0xB43bDcDDd88A6C327e5A8763f02EA3cbe960c0C9`](https://testnet.bscscan.com/address/0xB43bDcDDd88A6C327e5A8763f02EA3cbe960c0C9) |
| 部署交易 | [`0x0a056a20…0ce1`](https://testnet.bscscan.com/tx/0x0a056a2077f23e434a3646fdf72671dc86327eab478b44ecd3d4a1b342e10ce1)，区块 139392504，gas 1,869,807 |
| 构造参数 | pad = 第 10 套 GangLaunchpad `0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`，dev = `0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`，buybackBps = 5000 |
| tax handler / 分红金库 | `0xe1902C3eBA6b6114e48051fbC78603EA32cdCa7c` / `0xF6925641E547A7Dd40f971E61C7cd51624231d69` |
| 测试币 BBST | [`0xD0cE4Ae83032FA3dbB5C96813A51C83DAf3DA83a`](https://testnet.bscscan.com/address/0xD0cE4Ae83032FA3dbB5C96813A51C83DAf3DA83a)：V3，报价币 MockSPCXB（`0x02B3…CF1c`），买卖税各 3%，分红 50%，recipient = 回购合约 |
| 交易对 | `0x21D1819A885A84F0bCf5f5EaFB2a42E738ce3498`（Pancake 测试网 V2） |
| 源码验证 | 未做（缺 BscScan API key） |

测试网上 dev 和平台 owner 是同一个钱包（第 10 套的 owner `0xCa8e…00b6`，持有 Agent ID）：`list` / `setExcluded` 用它签名，建币、改比例也用它。主网上两者分开：dev 只签建币和改比例，`list` / `setExcluded` 由 Safe 执行。

## 接入

| 步骤 | 结果 | 交易 |
|---|---|---|
| 部署脚本（`SPLITTER_DEV`、`SPLITTER_BPS=5000`）：部署后 `verify`（真 pad、本仓库代码）+ `expect`（dev、比例、无待执行下调），打印 Safe 批量 | 通过 | 见上表 |
| `handler.list(splitter, "buyback splitter (testnet)")` | 成功，`isListed = true`，gas 99,221 | [`0x6336c588…daa5`](https://testnet.bscscan.com/tx/0x6336c588768b598d0cef76efef22a8d439a8830a1da77f2874e90275a99cdaa5) |
| `divVault.setExcluded(splitter, true)` | 成功，gas 50,408 | [`0xa63060a5…918c`](https://testnet.bscscan.com/tx/0xa63060a5605ed579f7506fb999d1db3568734301eb3978c36b838999fd1d918c) |
| dev `create`（recipient = 回购合约） | 成功，gas 1,622,424 | [`0xa5728340…ec15`](https://testnet.bscscan.com/tx/0xa5728340e6adf2dd2d685ad8bae19188e06afaff3bd2bc33c33ec66b8a4fec15) |
| `bind(BBST)` | 成功，`token` / `quote` 写入，gas 98,547 | [`0xb14b4703…9247`](https://testnet.bscscan.com/tx/0xb14b47039d163c90e0575c561511048f96a7af6f1384e990ec7fe20e3a199247) |

## 毕业、交税、拆分

- 毕业：dev 在内盘买到 1% 上限（1,000 万枚），之后 79 个测试 Agent（`GangTestnetE2E` 的 `gang-v3-testnet` 钱包）各买到 1%，最后一笔毕业建池。共 163 笔（含给买家预付 gas），1,950 万 gas，全部成功；最后一笔 [`0x8a3975bf…c088`](https://testnet.bscscan.com/tx/0x8a3975bf10c7216ca6201bbc53d580cfebf0a93af1248cd18c5b08e8793dc088)。买家剩下的 gas 随后收回（80 笔转账，共 0.009163 tBNB）。
- 交税：dev 在池子里卖 3 次，每次 200 万枚（[`0x49ac208e…dee8`](https://testnet.bscscan.com/tx/0x49ac208e8096886f041c1ea59fc58c6fc427e5045b8059bde5faa9ce05b2dee8)、[`0xb2f31209…30af`](https://testnet.bscscan.com/tx/0xb2f312099d2a3af446eb9fa9507758feb25d42a08487d5c62582d28edefe30af)、[`0x8d90ae72…f080`](https://testnet.bscscan.com/tx/0x8d90ae726f664e9e3da33367c429927534050806226568e3e3905f62c7c3f080)）。卖出途中 handler 的 swap-back 卖掉了一部分累计税，回购合约已收到 0.003632 MockSPCXB。
- `process(BBST, 60,000 枚, minQuoteOut = 预估 × 97%)`：把剩下的累计税卖完，回购合约再收到 0.001764，待拆分合计 0.005397。gas 298,892，[`0x43bb28f6…c986`](https://testnet.bscscan.com/tx/0x43bb28f69c5f9a3e0c7965be53d1a8ffa07c9fc1accf076ff899e9258208c986)。`minQuoteOut` 填 0 会被拒绝（`ZeroAmount`）。

## 回购（`burnChunk`）

| 时间（UTC） | 结果 | 花费（MockSPCXB） | 销毁（枚） | 剩余 `buybackLeft` | gas | 交易 |
|---|---|---|---|---|---|---|
| 09:02 | 先按 50% 拆分：dev 收到 0.0026984，留作回购 0.0026984（向下取整，少 1 wei）；缓存交易对，只记观测点 | 0 | 0 | 0.0026984 | 198,927 | [`0x5495d784…b58d`](https://testnet.bscscan.com/tx/0x5495d784430ffe29ead395efa216648f92634212295ac6eaf4526149a6d7b58d) |
| 09:13 | 买入并销毁（`minTokensOut` = 预览值） | 0.0026984 | 36,922.957 | 0 | 348,288 | [`0x5a153de9…8188`](https://testnet.bscscan.com/tx/0x5a153de928e6cffa15830bb5ff40a5afda9ae0a344e0804f27c9cc08b8858188) |

- 实际销毁量等于 `previewBurn` 的预览值（已扣 3% 买入税），0xdead 余额增加的正是这个数。
- 交易对报价币储备约 14.57，单块上限 0.5% ≈ 0.0728，所以这次一块就买完。
- 买完后回购合约持有 0 枚代币、0 报价币，金库里的份额为 0（已排除，回购途中没有写份额）。再调 `burnChunk` 报 `NothingToBurn`，`releaseDev` 报 `NothingOwed`。

## 比例调整与部署脚本检查

| 步骤 | 结果 | 交易 |
|---|---|---|
| `setBuybackBps(6000)`（提高） | 立即生效，gas 42,625 | [`0xd2f9665e…12f5`](https://testnet.bscscan.com/tx/0xd2f9665e5f26a61525964551f88da8f5225cce8c4196e74b0ec27682a16312f5) |
| `setBuybackBps(5000)`（下调） | 进入公告期：比例仍是 6000，`pendingCut` = (true, 5000, 3 天后)，gas 30,482 | [`0x2bb1d7b6…5bd4`](https://testnet.bscscan.com/tx/0x2bb1d7b6a544e7be4fd1ba607ac8ee7f020a1696b66bf69a0967e30189e75bd4) |
| 检查模式（`SPLITTER` 已设）在公告期内 | 拒绝：`WiringCheck("splitter.pendingCut")` | 只模拟 |
| `setBuybackBps(6000)`（设回原值） | 取消下调：发出 `BuybackBpsProposalCancelled` 和 `BuybackBpsSet`，`pendingCut` = (false, 0, 0)，gas 44,020 | [`0x42059b54…aa14`](https://testnet.bscscan.com/tx/0x42059b54deea801405c70f8a1c7b86e11d54aca3e1a120fd6f7c89ceb2a2aa14) |
| 检查模式，`SPLITTER_BPS=6000` | 通过，Safe 批量两项都提示已完成（already listed / already excluded） | 只模拟 |
| 检查模式，`SPLITTER_BPS=5000` | 拒绝：`WiringCheck("splitter.buybackBps")` | 只模拟 |
| 陌生人 `setBuybackBps` / 没有申请时 `applyBuybackBps` | `NotDev` / `NoProposal` | 只模拟 |

当前状态：比例 6000，没有待执行的下调。

## 花费

整轮约 2,737 万 gas，按 0.1 gwei 合 0.0027 tBNB；其中毕业的 163 笔占 1,950 万。

## 本次没测到（在单测里覆盖：`test/gang/GangBuybackSplitter.t.sol`，22 个）

- 下调公告期满后执行（`applyBuybackBps`）、过期作废：要等 3 天 / 10 天。
- dev 被报价币拉黑时记为欠款（`devOwed`）、之后 `releaseDev`；余额被扣时两部分按比例分摊。
- 价格被拉高时跳过（spot 比 TWAP 高 2% 以上）和滑点保护。
- `sweep` 别的资产。

## 复跑

```sh
# 部署 + 检查（打印 Safe 批量）
GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 SPLITTER_DEV=<dev> SPLITTER_BPS=5000 DEPLOYER_PRIVATE_KEY=… \
  forge script script/DeployGangBuybackSplitter.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com \
  --broadcast --legacy --with-gas-price 100000000

# 只检查别人部署的那个
GANG_PAD=… SPLITTER=<splitter> SPLITTER_DEV=<dev> SPLITTER_BPS=<bps> \
  forge script script/DeployGangBuybackSplitter.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com
```

`--slow` 广播时不要用官方节点 `data-seed-prebsc-1-s1` 做 `--rpc-url`：它不是归档节点，forge 模拟到一半会报 `missing trie node`（这次第一次跑毕业就停在模拟阶段，什么都没发出去）。用 publicnode 模拟和发送，加 `--legacy`。
