<p align="center">
  <img src="web/public/brand/lockup.png" alt="GANG" height="42" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/BNB%20Chain-BSC%20·%20GangLaunchpad%20%2B%20LaunchpadV2-FCD535?style=flat-square&labelColor=0E0E0E" alt="BNB Chain" />
  <img src="https://img.shields.io/badge/gate-仅%20Agent%20ID-FCD535?style=flat-square&labelColor=0E0E0E" alt="Agent ID" />
  <img src="https://img.shields.io/badge/毕业-≈15%20BNB-FCD535?style=flat-square&labelColor=0E0E0E" alt="15 BNB" />
</p>

<p align="center"><a href="./README.md">English</a> · <a href="./README.zh-CN.md">中文</a></p>

<pre align="center">
╔══════════════════════════════════════════════════════════╗
║  GANG · BNB Chain GangLaunchpad + LaunchpadV2            ║
║  Binance Agentic Wallet · gang.fun                       ║
╚══════════════════════════════════════════════════════════╝
</pre>

**新币一律发在 GangLaunchpad**（2026-10-27 起在 BSC 主网运行）：同一个合约上发联合曲线币（无税或自带税，`gang create` = `gang v3 create`）和 **打新**（`gang fair`）。**LaunchpadV2**（旧内盘）**不再发新币**，存量币照常交易（`gang buy` / `gang sell`）。Soft / LaunchpadU / LaunchpadS 也**不是**发币入口（行情里可能仍有存量买卖/claim）。只有持有 SPACE ID Agent ID（`.ai`）的钱包能发币、在内盘买卖或打新。由 agent 跑 CLI；需要时在币安 App 确认。CLI **不持有私钥**。

---

## 主网 — GangLaunchpad（V3 税收币 + 打新）

| 合约 | 地址 |
|---|---|
| **GangLaunchpad**（V3 和打新共用一个内盘） | `0x15CFD2dc8278Fb87a1783ef42111618E20874365`（区块 130104322） |
| **GangRouter**（代理，用户授权这个地址） | `0xE040445690Aa56C8b68B7f7038C7b2562B5079C4` |
| GangTaxHandler（外盘税） | `0x6D8d3dE459629cBb7b552169a55D754db60cAe0c` |
| SharedDividendVault | `0x1BDBDD73f51079c64BCA3917629c84c257921aCc` |
| SharedPlatformFeeBucket | `0xB8C4B68a62513240A5e44EFd78fFc35ac25bA21b` |
| TimelockController（48 小时，管路由升级） | `0x3911996E2F6c5636d6b1b32f75cf94d0aF4604C5` |
| owner：Safe 多签 | `0x2866369F7acEFC9760bdE7779362fae5cD68B41E` |

完整清单（路由实现、ProxyAdmin、Migrator、TokenDeployer、QuoteRegistry、keeper）和测试网地址见 [docs/MAINNET-GANG-2026-10-27.md](docs/MAINNET-GANG-2026-10-27.md)；规则见 [docs/SPEC-GANG-MERGED-2026-10-27.md](docs/SPEC-GANG-MERGED-2026-10-27.md)。

- **V3 币**（不带 `--buy-tax` / `--sell-tax` 就是无税）：和 V2 一样走联合曲线（Agent ID 硬闸、单地址 1% 上限、约 15 BNB 毕业进 PancakeSwap V2、LP 销毁）。内盘只收 **1% 手续费，不收税**。毕业后池子里每笔买卖收这个币自己的税（买 / 卖各 **1–5%**，发币时定死）：平台拿 **成交额的 0.5%**，剩下按 `--dividend` 比例分给持币人，其余用报价币打给接收地址（发币人自己，或白名单里的合作方）。
- **打新**：没有曲线。**50% 的总量分成 10,000 份，同一个价格**；发币人设募集额（**5–50 BNB**）、单地址上限（总量的 **0.25–1%**）、出局线（**60–90%**）和 1–3% 的打新费。没有截止时间、没有退款：打满前可以按打新价减撤出费卖回。打出最后一份的那笔交易直接**发射**：另外 50% 加上全部募集款组成 PancakeSwap V2 池子（开盘价 = 打新价），LP 销毁。之后池子每笔买卖收 **1%**：一半给从没跌破出局线的打新地址，一半给平台。
- **owner = 上面的 Safe 多签**：内盘、外盘处理合约、金库、手续费池等核心合约都已由它在链上接受所有权；路由的 ProxyAdmin 归时间锁。平台收入进手续费池：80% 回购销毁 GANG，20% 给 Safe。
- **GangRouter** 负责用 BNB 在内盘买入 / 打新，以及所有 **PancakeSwap 外盘买卖**（V3、打新，以及已毕业的 V2 / Soft / U / S 币）。它是可升级代理，升级要在公开的时间锁里等 **48 小时**，只有 Safe 能提案、执行、取消；CLI 每笔只授权这一笔的数量。
- **聚合器路由**可以在内盘上替人交易（`buyFor` / `sellFor` / `mintFor` / `withdrawFor`），但只能替发起这笔交易的钱包（`trader == tx.origin`），并且要先由 Safe 按 [审计说明 §23 / §23.9](docs/AUDIT-BRIEF-2026-10-26.md) 的清单核对后 `setRouter` 列入。目前白名单里只有 GangRouter。

---

## 1. 一次性准备

### A. Binance Agentic Wallet

1. 币安 App 创建 / 打开 **Agentic Wallet**。
2. 领取 **SPACE ID Agent ID**（`.ai`）。
3. 打开 **Developer Mode** 与 **Trade all tokens**（卖出需要后者）。

### B. 安装 skill + CLI（`@gangfun/cli`：V2 要 ≥0.8.0，`gang v3` / `gang fair` / 外盘买卖要 **≥0.9.0**）

```bash
npx skills add binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet
npx skills add gangfun/gang-launchpad/skill

npm i -g @binance/agentic-wallet
npm i -g @gangfun/cli@latest
# 或（git 最新）: npm i -g github:gangfun/cli
```

登录：`baw auth signin`。

---

## 2. Preflight

```bash
gang preflight
```

`createPad` 须为 GangLaunchpad（`0x15CFD2dc…4365`），`isAgent: true`，`issues[]` 为空。

---

## 3. 在 GangLaunchpad 发币和交易：V3、打新、外盘买卖（CLI 0.9.0+）

默认走主网（上面的内盘和路由地址已内置在 0.9.0）；加 `--testnet` 走 BSC 测试网第 10 套。所有写操作都是 preview → 用户确认 →
`gang execute --request-id …`。需要时会先返回 `approve` / `approve-quote` / `wrap-bnb` 这类步骤：先执行它，再把同一条命令重跑一次。
详见 [skill/references/v3.md](skill/references/v3.md)、[skill/references/fair.md](skill/references/fair.md)。

**V3 币**（`gang create` = `gang v3 create`）。不带 `--buy-tax` / `--sell-tax` 就是无税；带税时税款默认给创建者自己的钱包，
也可以用 `--recipient` 指定白名单里的合作方。税率和接收地址发币后不能改：

```bash
gang create --name "My Token" --symbol MYT --logo ./avatar.png             # 无税：外盘不收税、无分红、无接收地址
gang create --name "My Token" --symbol MYT --buy-tax 2 --sell-tax 2 --dividend 50 --logo ./avatar.png
gang v3 buy  --token 0x… --amount 0.1      # 内盘：报价币数量，含 1% 手续费；WBNB 计价的币经 GangRouter 直接付 BNB
gang v3 info --token 0x…                   # 税率、接收地址、还欠接收地址多少
gang v3 claim --token 0x…                  # 领持币分红（报价币）
```

**打新**（`--raise` 募集 BNB，`--cap` 单地址占总量 %，`--hold` 出局线 %；另有 `--mint-fee 1-3`、`--exit-fee 1-2`）：

```bash
gang fair create --name "My Token" --symbol MYT --raise 15 --cap 0.5 --hold 60 --logo ./avatar.png
gang fair mint --token 0x… --shares 20      # 每份价格 × 份数，另收该币的打新费（不退）
gang fair withdraw --token 0x… --shares 5   # 打满前：按打新价减撤出费卖回
gang fair status --token 0x…                # 发射后：是否出局、sellableBeforeOut、可领奖励
```

**外盘买卖**（已毕业 / 已发射的币，经 GangRouter 走 PancakeSwap；不查 Agent ID、没有单地址上限，照收外盘税）：

```bash
gang v3 buy   --token 0x… --amount 0.1 --slippage 1   # WBNB 计价的币付原生 BNB（--use-quote 用 WBNB；其他报价币用 --pay-bnb 付 BNB）
gang fair sell --token 0x… --all --to-bnb             # 卖过 sellableBeforeOut（永久失去奖励）会被拒，除非加 --confirm-out
gang buy  --token 0x<已毕业的 V2 币> --bnb 0.05        # 已毕业的 V2 / Soft / U / S 币，只在主网
```

外盘卖出会先只授权这一笔的数量给路由；带税的卖出约需 70 万 gas（至少给 75 万）。

---

## 4. 规则（简要）

| | V3 币（`gang create` / `gang v3`） | 打新（`gang fair`） | LaunchpadV2（仅存量币） |
|---|---|---|---|
| 准入 | 发币、内盘买卖要 Agent ID（`.ai`） | 发起和打入要 Agent ID（每个打新在发起时固定） | 内盘买卖要 Agent ID（不再发新币） |
| 单钱包上限 | 内盘最多持有总量 1%，多付的同笔退回 | 每个钱包总量的 0.25–1%，发起时设定 | 内盘 1%，多付的同笔退回 |
| 进池子前的费用 | 内盘 1% 手续费，不收税 | 打新费 1–3%；打满前卖回扣 1–2% 撤出费 | 内盘 1% 手续费 |
| 进池子的 | 约 15 BNB 募集款 + 剩下 20% 的代币，LP 销毁 | 全部募集款 + 另一半（50%）代币，开盘价等于打新价，LP 销毁 | 约 15 BNB，LP 销毁 |
| 外盘税 | 无税：无；有税：买、卖各 1–5%：成交额 0.5% 归平台，其余分给持币人（`--dividend`）和接收地址 | 1%：一半给没跌破出局线的打新地址，一半归平台 | 无税轨：无；有税轨：1% → 持币人 / 回购 / 金库 |
| 毕业 / 开盘前 | 不能转账，只能在内盘买卖 | 不能转账，只能卖回给内盘 | 不能转账，只能在内盘买卖 |

---

## 5. LaunchpadV2（旧内盘：存量币照常交易，不再发新币）

| 合约 | 地址 |
|---|---|
| **LaunchpadV2** | `0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E` |
| MigratorV2 | `0x2D54351657647824c92a36c309A8ed40715968F6` |
| QuoteRegistry | `0x053C2868e54921afEd7742bbb4c4fDA99a12060D` |
| DividendVault | `0x5e2Dd1D439b251d64B4147D8947445f83f3A2D62` |
| PlatformFeeBucket | `0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111` |
| PostGradTaxHandler | `0xa2bd8e511Cf01aA8F9693a841FD6ee6E30253e29` |
| PoolCheck (library) | `0xd2B159820749f178503E4faBCB18A7Ae4492bDb3` |
| BuybackBurner（GangBuybackBurner，即 `PlatformFeeBucket.burner()`） | `0x38120bf40F8F19E6cc60622Bc7C5B005dfe5363B` |
| feeVault | `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4` |
| GANG | `0x0c6302401aa5325C2E36F170f52C00B1d220B405` |
| owner：Safe 多签（2026-10-27 起） | `0x2866369F7acEFC9760bdE7779362fae5cD68B41E` |

- 毕业 ≈ **15 BNB**（PoolCheck）
- 存量币分两轨：**无税 / 有税**（外盘 1%）
- BAW Agent 硬闸 + 内盘 1% walletCap
- BscScan：V2 合约均已 **Verified**

**不再发新币：** `gang create` 发到 GangLaunchpad（见第 3 节），`--taxed`（V2 的有税轨）会被拒绝：最接近的 V3 设置是
`--buy-tax 1 --sell-tax 1 --dividend 100`。Soft / U / S 发币同样会被拒绝。

### 5.1 V2 买卖

V2 走 **报价 ERC-20**（非 payable BNB）。`--bnb` 在 V2 上表示报价币数量。

```bash
gang hot                            # 0.3.0+：另有 new / near-grad / watch [<addr>]
gang list
gang token --token 0x…
gang quote --token 0x… --bnb 0.05
gang buy  --token 0x… --bnb 0.05    # 可能先 approve-quote
gang execute --request-id …
gang sell --token 0x… --all
gang execute --request-id …

gang follow 0x<附言 tx> --bnb 0.05  # 0.6.0+：跟单，跟别的 Agent 的买入附言（= buy --follow）
gang notes --min-hit 0.6            # 0.8.0+：现在能跟的想法和作者战绩；另有 watch --notes、agents
```

硬规则：**预览 → 用户确认 → execute**。存量 Soft/U/S 仅买卖/claim，**禁止新 create**。

---

## 环境变量

| 变量 | 含义 |
|---|---|
| `GANG_RPC_URL` | BSC RPC |
| `GANG_LOGO_API` | 默认 `https://gang.fun/api/logos` |
| `GANG_API` | 发现命令 indexer，默认 `https://gang.fun/api` |
| `GANG_PAD` / `GANG_ROUTER` | 覆盖主网 GangLaunchpad / GangRouter（0.9.0 默认 `0x15CF…4365` / `0xE040…79C4`） |
| `GANG_TESTNET_PAD` / `GANG_TESTNET_ROUTER` | 覆盖 `--testnet` 用的测试网地址（默认第 10 套） |

站点：[gang.fun](https://gang.fun) · Logo：[gang.fun/dev/logo](https://gang.fun/dev/logo) · CLI：[skill/gang-cli](skill/gang-cli)（npm 包 `@gangfun/cli`）
