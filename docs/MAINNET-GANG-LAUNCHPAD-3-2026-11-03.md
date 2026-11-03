# 主网 · GangLaunchpad 3.0（可升级 pad，内置聚合器入口）

GangLaunchpad 3.0 于 2026-11-03 部署到 BSC 主网，平台 Safe 已执行批次 1–3：3.0 已开放，5 个老 pad 都已把它列为 router。

- **部署用的代码**：合并 PR #114 之后的 `main`（`0808027`），在 `git archive` 导出的干净目录里运行，本地未提交的改动不会混进去。
- **链接**：只链接了线上的 PoolCheck（`--libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B1…bDb3`）。其余三个库由 forge 用 CREATE2 部署：CurveLogic3 和 LegacyRoute 是新部署的；FairLogic 链上已有同一份代码，直接复用。
- **部署前完成的流程**：
  1. 三路审计 → 修复 → 两轮独立复审；
  2. 多跳卖出功能的增量审计 → 修复后复核；
  3. 上线前的全新整体审计（合约，以及部署和升级流程）→ 修复 → 复核；
  4. 测试网部署、验收，三次升级演练。

  详见 PR #114 和 `docs/TESTNET-GANG-LAUNCHPAD-3-2026-11-03.md`。
- **规格**：`docs/SPEC-GANG-LAUNCHPAD-3-2026-11-03.md`

## 地址

| 项 | 值 |
|---|---|
| **GangLaunchpad 3.0**（代理：永久地址，用户授权、聚合器调用的都是它） | [`0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29`](https://bscscan.com/address/0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29)，起始区块 131404298 |
| 实现合约 | [`0x6e697106BD525AAB8fc0DdC076bd54Be09Ed6231`](https://bscscan.com/address/0x6e697106BD525AAB8fc0DdC076bd54Be09Ed6231) |
| ProxyAdmin（由代理创建；owner 是平台 Safe，没有时间锁） | `0xCe83Be827bf2B6bAFe0ca6d1320Dce965CE3df48` |
| pad owner（Ownable2Step） | Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E` |
| GangTaxHandler（3.0 专用；owner 是 Safe） | [`0x99E882a21847012329351B598ceB93B135691b3B`](https://bscscan.com/address/0x99E882a21847012329351B598ceB93B135691b3B) |
| GangRouter 3.0（代理） | [`0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7`](https://bscscan.com/address/0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7) |
| GangRouter 实现 / ProxyAdmin / Timelock（48 小时，只有 Safe 一个角色） | `0xA60fB3141dC2942A5449C7FeAFb9038aDEA49b1F` / `0x3de754eeeCd87987a282397d41BDa11cb4DaFDFc` / `0x6d3FC39a5a96429d1942930A845f891cdB7A29A3` |
| CurveLogic3 / FairLogic / LegacyRoute / PoolCheck | `0x21DAC269a78BFF0d261783a191E9EbaAeF4e5913` / `0x34E18563622aE05e92FdaCA81a40D83652067c9D` / `0x30764D22EB16Bec685fB574f8ae17a6ecD45C7d1` / `0xd2B159820749f178503E4faBCB18A7Ae4492bDb3` |
| 共享合约（沿用 1.0 的） | QuoteRegistry `0x8b93…9F17`、平台费桶 `0xB8C4…A21b`、分红金库 `0x1BDB…1aCc`、迁移器 `0xfE38…3604`、TokenDeployer `0x3A54…4558`、GangPadRegistry `0x4fF7…4C5C` |
| 部署钱包 | `0x4EEd…19d3`。Safe 接手之后，它对 3.0、handler、router 都没有任何权限 |
| 广播记录 | `broadcast/DeployGangLaunchpad3.s.sol/56/` |
| 源码验证 | 全部已在 BscScan 验证（2026-11-03）。GangLaunchpad3 实现合约、CurveLogic3、LegacyRoute 用 `forge verify-contract` 提交（Etherscan v2 接口；solc 0.8.28、via-ir、优化 200 次、cancun；源码取自 `0808027`）。GangTaxHandler、GangRouter、TimelockController、两个 ProxyAdmin、两个代理、FairLogic，BscScan 按字节码自动匹配。两个代理都已标记指向各自的实现合约 |

## 部署过程

1. **阶段 1**：部署钱包发了 15 笔交易，全部成功，nonce 从 362 到 377。
   - 部署：两个库、handler、实现合约、代理（在构造函数里完成初始化）、router 及其时间锁；
   - 部署钱包自己完成的设置：handler 的 `setLaunchpad` 和 `setKeeper`；pad 的 router 和 Gateway 列表、Agent 门槛、V3 工厂、USDT 桥接池。

   广播前，在同一份代码上先模拟了一遍，读回检查全部通过。
2. **Safe 批次 1**（`docs/MAINNET-GANG-LAUNCHPAD-3-SAFE-BATCH-1-2026-11-03.json`，9 笔），执行交易 [`0x819eef6a…adb5`](https://bscscan.com/tx/0x819eef6afd3978960cb753f233253c3a1094f83adaa8638d257b2e438a17adb5)，区块 131407106：在分红金库、迁移器、TokenDeployer、平台费桶、GangPadRegistry 上登记 3.0。签名前，用链上状态只读重跑过阶段 2，重新生成的批次和这份完全一致。
3. **阶段 2**：
   - 读回检查通过（`self-check ok`），包括这几项：
     - 实现合约的代码，和用本次构建、相同依赖、在模拟里部署的参照合约逐字节一致，库地址也一致；
     - PoolCheck 是线上那一个；
     - 部署钱包的 nonce 等于 377 加上移交所有权的笔数，说明阶段 1 之后它没有发过别的交易；
     - handler 的接收方列表为空。
   - 部署钱包随后发了 2 笔 `transferOwnership(Safe)`（nonce 377 到 379）。
4. **Safe 批次 2**（`…-SAFE-BATCH-2-…json`，3 笔），执行交易 [`0x4163683b…8bc2`](https://bscscan.com/tx/0x4163683b2f6dd835b1df69ac44e3179e717b4710b2d636bfe8f033c44be48bc2)，区块 131407584：Safe 接受 handler 和 pad 的所有权，然后 `setMigrator`，3.0 开放。执行后核对：部署钱包的 nonce 仍是 379，pad 和 handler 的 owner 都是 Safe，没有待接收的 owner。
5. **Safe 批次 3**（`…-SAFE-BATCH-3-…json`，5 笔），执行交易 [`0x76219e76…0e6b`](https://bscscan.com/tx/0x76219e76a6fda9d6ba7a5510521a6712598ce26ddc4e36fa98ea5be09f3d0e6b)，区块 131408635：1.0、2.0、金库版、飞轮 V1 和 V2 都执行了 `setRouter(3.0, true)`。

## 部署后的检查

- 5 个老 pad 的 `routers(3.0)` 都是 `true`。
- 3.0 上，router 3.0 和 GangGateway 都已列为 router。`TOKEN_VERSION` 为 1，`initVersion` 为 1，Agent 门槛和 1% 钱包上限都开着，TWAP 是 1800 秒。
- 拿 2.0 上的曲线币 `0xb01c…5979` 对比报价：3.0 的 `tryBuy(0.01 BNB)` 和 GangGateway 一分不差，都是 3,508,422.2 个币。
- 用一个持有 Agent ID 的钱包，经 3.0 的 `buyTokenAMAP` 用 0.01 BNB 模拟买入这个币（eth_call，没有上链）：成交 3,508,422.2 个，和报价一致。

## 还没做的

- **批次 4（聚合器白名单）**：等聚合器提供 router 地址并完成代码审查。主网上需要同时提供 `CALLERS` 和 `CALLER_CODEHASHES`。
- **批次 5（1.0、2.0 停止发币）**：等 3.0 的模块（GangBond、各模块工厂、GangHandlerAdmin）、后端、网站、CLI 都切到 3.0 之后再执行（`CUTOVER=true`）。
- 合作方的税收接收方由 Safe 在 3.0 的 handler 上重新登记。
- 实时告警：代理的 `Upgraded` 事件、ProxyAdmin 的 owner 变更。

以后再跑阶段 2（打印批次 4、批次 5）或升级时，要用当前线上实现对应的那次提交运行（目前是 `0808027`），详见 spec §5、§6。

## 源码验证命令

```sh
V="--verifier etherscan --verifier-url https://api.etherscan.io/v2/api?chainid=56 --chain-id 56 --compiler-version 0.8.28 --optimizer-runs 200 --evm-version cancun --via-ir --watch"
POOL=src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
forge verify-contract 0x21DAC269a78BFF0d261783a191E9EbaAeF4e5913 src/gang/CurveLogic3.sol:CurveLogic3 $V --libraries $POOL
forge verify-contract 0x30764D22EB16Bec685fB574f8ae17a6ecD45C7d1 src/gang/LegacyRoute.sol:LegacyRoute $V
forge verify-contract 0x6e697106BD525AAB8fc0DdC076bd54Be09Ed6231 src/gang/GangLaunchpad3.sol:GangLaunchpad3 $V \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address,address)" \
    0x8b93919862830ea6A720B28C7D0C42fCbb849F17 0x1BDBDD73f51079c64BCA3917629c84c257921aCc 0xB8C4B68a62513240A5e44EFd78fFc35ac25bA21b \
    0x99E882a21847012329351B598ceB93B135691b3B 0x3A5432c562BcA145Faf21ef956C475c670d14558 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c \
    0x4fF77D4d9ac080939a24E1B805206bA094C44e5C) \
  --libraries $POOL --libraries src/gang/CurveLogic3.sol:CurveLogic3:0x21DAC269a78BFF0d261783a191E9EbaAeF4e5913 \
  --libraries src/gang/FairLogic.sol:FairLogic:0x34E18563622aE05e92FdaCA81a40D83652067c9D \
  --libraries src/gang/LegacyRoute.sol:LegacyRoute:0x30764D22EB16Bec685fB574f8ae17a6ecD45C7d1
```

API key 通过 `ETHERSCAN_API_KEY` 环境变量传入，不写在命令里。
