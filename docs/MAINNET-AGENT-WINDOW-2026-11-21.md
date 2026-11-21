# 主网记录 · Agent 专属窗口

- 日期：2026-11-21（Asia/Shanghai）
- 网络：BSC 主网（56）。GangLaunchpad 3.0 代理 `0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29`，GangPadRegistry 代理 `0x4fF77D4d9ac080939a24E1B805206bA094C44e5C`，owner 都是 Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`
- 规格：`docs/SPEC-AGENT-WINDOW-2026-11-20.md`（§11 审计记录，§9.2 签名清单）；测试网记录：`docs/TESTNET-AGENT-WINDOW-2026-11-21.md`
- 部署的代码：PR #182 的 `1fbab73`（审计修复复审后的版本，和测试网验收的代码相同）
- 上线前已完成：
  - 链下规则（§6）：服务端的 Agent ID 检查已部署到生产，结算脚本（#184、#185）随之更新；生产用的节点对未升级 pad 的 `agentOpenAt` 返回 code 3；
  - CLI `--agent-window`（#183，0.49.0，待发布）。
- 状态：**已上线**。Safe 于 2026-11-21 13:43（UTC+8）执行升级批次，pad 和 registry 都已是新实现。

## 部署

用 `script/UpgradeGangLaunchpad3.s.sol`，带 `PAD3_REGISTRY_UPGRADE=true` 和 `GANG_MAINNET_OK=true`，部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`，gas price 0.05 gwei。只链接线上的 PoolCheck `0xd2B159820749f178503E4faBCB18A7Ae4492bDb3`；没改动的库（FairLogic、LegacyRoute、FlywheelLogic、FlywheelPostLogic）沿用链上已有的地址。

广播前先做了一次不广播的模拟（主网最新状态）：以 Safe 身份执行升级后读回，最新 25 个币的记录和视图、pad 设置、阶段 2 读回、registry 的 `padOf` 和报价全部一致。

| 项 | 地址 | 交易 | 区块 | gas |
|---|---|---|---|---|
| CurveLogic3（库，CREATE2） | [`0x4b8975f2C95E9A72109Bb3233E1af5436cEb7340`](https://bscscan.com/address/0x4b8975f2C95E9A72109Bb3233E1af5436cEb7340) | [`0xc1385fbd…5cb1`](https://bscscan.com/tx/0xc1385fbd69b01edf516df0aa92270332b42434d5bf349227d718471c9fa45cb1) | 134830518 | 3,878,182 |
| GangPadRegistry 新实现 | [`0xaB1Fd667387aBF4aFD4c57e06b964648fa9EF301`](https://bscscan.com/address/0xaB1Fd667387aBF4aFD4c57e06b964648fa9EF301) | [`0x96a36208…b3ee`](https://bscscan.com/tx/0x96a362084843c6bb330875617201cd78d347d55f78f20992ba0e9358e704b3ee) | 134830521 | 1,125,092 |
| Pad3FlyModule（代码不变，构建脚本连带部署） | [`0xED80D66287b22F0a60AFbE843AAEe1E89a9c8AD1`](https://bscscan.com/address/0xED80D66287b22F0a60AFbE843AAEe1E89a9c8AD1) | [`0xb3cb1d27…d2e1`](https://bscscan.com/tx/0xb3cb1d27fb5607b70cfe730bcddb74a2901945ed3aeaf9f5df16e72d4497d2e1) | 134830524 | 4,816,115 |
| Pad3GradModule | [`0x8cA0309061Ac396880C1B5FCDb92c88746CCA7dc`](https://bscscan.com/address/0x8cA0309061Ac396880C1B5FCDb92c88746CCA7dc) | [`0xa3841f50…2ae5`](https://bscscan.com/tx/0xa3841f50b39033203c94a5085bc8ce510d86ada69248373babd33f97bbd82ae5) | 134830527 | 2,024,337 |
| Pad3Module | [`0xFBcD889D03f2839cd8EB26AE64D521662EdfA536`](https://bscscan.com/address/0xFBcD889D03f2839cd8EB26AE64D521662EdfA536) | [`0xe4ce8f68…d4f5`](https://bscscan.com/tx/0xe4ce8f6866271e83b2927cc2633273a74af416c3a30cb38650ff490bd7f3d4f5) | 134830529 | 4,765,648 |
| GangLaunchpad3 新实现 | [`0x40E9E53AAA7b7fe1Be14cDfd56fdAb3D97B3a448`](https://bscscan.com/address/0x40E9E53AAA7b7fe1Be14cDfd56fdAb3D97B3a448) | [`0x862aa155…d339`](https://bscscan.com/tx/0x862aa155e8a34144d464a5423b39e8560f6750811eb51df10e6edfc26d59d339) | 134830531 | 4,966,465 |

六笔回执都是成功。记录：`broadcast/UpgradeGangLaunchpad3.s.sol/56/run-latest.json`。

## Safe 批次

带 `PAD3_IMPL`、`PAD_REGISTRY_IMPL`、`PAD3_FLY_HANDLER`（`0x7De9…3ba0`）、`PAD3_FLY_VAULT_CORE`（`0x9d90…767E`）只读重跑脚本：逐字节核对新实现和各模块、registry 实现都是本次构建的代码，模拟执行并读回通过，打印出批次。

归档文件：[MAINNET-GANG-LAUNCHPAD-3-UPGRADE-AGENT-WINDOW-SAFE-BATCH-2026-11-21.json](MAINNET-GANG-LAUNCHPAD-3-UPGRADE-AGENT-WINDOW-SAFE-BATCH-2026-11-21.json)，SHA-256 `d426ee4962d06f6be164b71ed2ddf31d75c8022bb32b917495d92b8b81b4ce93`。两笔，都不转 BNB，顺序不能换：

| # | 目标 | 调用 |
|---|---|---|
| 1 | pad 的 ProxyAdmin `0xCe83Be827bf2B6bAFe0ca6d1320Dce965CE3df48` | `upgradeAndCall(0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29, 0x40E9E53AAA7b7fe1Be14cDfd56fdAb3D97B3a448, 0x)` |
| 2 | registry 的 ProxyAdmin `0x9efbcf84b80Ab437AE82c74E2D047b997172f84D` | `upgradeAndCall(0x4fF77D4d9ac080939a24E1B805206bA094C44e5C, 0xaB1Fd667387aBF4aFD4c57e06b964648fa9EF301, 0x)` |

### 签名前的核对

- **探针**：`PAD3_PROMOTE_PROBES` 和 `PAD3_BASE_PROBES` 为空。从 pad 部署区块 131404374 起按 5 万块一段扫了全部 `PromoterBound` 日志，从 133760000 起扫了全部 `BaseCreated` 日志（至区块 134828477），两种事件在主网上都还没有出现过；同一节点在最近 5 万块里返回了 pad 的 14 条 `TradeV1`，说明节点会返回日志。脚本打印的 base 探针 WARNING 因此不影响。
- **fork 演练**（anvil 分叉主网区块 134831564）：以 Safe 身份原样发送归档 JSON 的两笔交易，都成功；pad 和 registry 的实现槽是上面的新地址；`MAX_AGENT_WINDOW_MINUTES()` = 1440；最新的老币 `0x8fF01b83b36D5e4FB51F06A0950D680A54d4abcd` 的 `agentOpenAt` = 0，`walletCapOn` = true，没有 Agent ID 的钱包 `canTradeCurve` = false、registry 报价 0（升级前后相同）；两个代理的 owner 仍是 Safe。
- **fork 测试**：`test/fork/Pad3AgentWindowFork.t.sol` 在主网最新区块重跑，通过（1 passed, 0 failed）：自己部署同一份代码，执行它打印的批次，再带窗口发币；窗口期内拒绝非 agent，开放后非 agent 合约按 registry 报价买入、超过 1%，一笔买到毕业。
- **节点回报 revert 的方式**：未升级的 pad 上 `agentOpenAt` 在四个公共主网节点都返回 JSON-RPC code 3，服务端和结算脚本据此判断“没有窗口”。
- **源码验证**：六个新合约都已在 Sourcify 验证（match）。Etherscan v2 的免费 key 已不支持 BSC，BscScan 验证没有做（需要付费 key 或网页手动提交），留作上线后补做。字节码已由脚本逐字节核对。

## 执行

交易 [`0xa8b20493…88c0`](https://bscscan.com/tx/0xa8b20493ef7c23708b2bdba89da5a5c34302428663dbcacf27328bb1f10c88c0)，区块 134833222（2026-11-21 13:43 UTC+8），gas 112,300，gas price 0.05 gwei。Safe `0x2866…B41E` nonce 59（执行后下一个 nonce 是 60）。回执成功，日志：pad 代理和 registry 代理各一条 `Upgraded`，Safe 一条 `ExecutionSuccess`。

## 执行后核对

- 实现槽：pad = `0x40E9E53AAA7b7fe1Be14cDfd56fdAb3D97B3a448`，registry = `0xaB1Fd667387aBF4aFD4c57e06b964648fa9EF301`；`module()` = `0xFBcD…A536`，它的 `gradModule()` = `0x8cA0…A7dc`；两个代理的 owner 仍是 Safe。
- `MAX_AGENT_WINDOW_MINUTES()` = 1440。
- 最新的老币 `0x8fF01b83b36D5e4FB51F06A0950D680A54d4abcd`：`agentOpenAt` = 0，`walletCapOn` = true（和 `walletCapEnabled()` 一致），没有 Agent ID 的钱包 `canTradeCurve` = false。
- CLI 0.49.0 已发布（gangfun/cli `012b236`，npm `@gangfun/cli@0.49.0`）；`npx @gangfun/cli@0.49.0 info` 在主网读到老币 `agentWindow.set = false`。
- 待做：第一个真实窗口币的报价和交易核对；BscScan 源码验证；网站展示和 `capabilities.json` 刷新。

升级不回滚（spec §9.4）：出问题只做前滚修复。
