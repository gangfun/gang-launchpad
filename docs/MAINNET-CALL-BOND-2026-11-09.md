# 主网记录 · GangCallBond（喊单保证金）

- 日期：2026-11-09 Asia/Shanghai
- 网络：BSC 主网（56），绑定 GangLaunchpad 3.0 代理 `0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29`
- 规格：`docs/SPEC-AGENT-CALLS-2026-11-09.md` §5；测试网记录：`docs/TESTNET-CALL-BOND-2026-11-09.md`
- 代码：main 上的 `src/gang/GangCallBond.sol`（合并提交 `733e2eb`，PR #147），部署时的源码和这份完全一致
- 部署前：规格两轮审查；合约一轮审计（没有 Critical / High / Medium，两个 Low 已修）和修复后复审；测试网部署和验收前三步通过；主网 fork 测试 `test/fork/CallBondMainnetFork.t.sol` 3/3 通过（见下）

## 部署

| 项 | 值 |
|---|---|
| GangCallBond | [`0x6d6e4A36e9a231cCc932151cdbFb087Cf3860c3D`](https://bscscan.com/address/0x6d6e4A36e9a231cCc932151cdbFb087Cf3860c3D) |
| 交易 | [`0x8978cd2e6106c7eb510c483f35a3bc6f55226a1f5bc5f4aa571913a588c84bdc`](https://bscscan.com/tx/0x8978cd2e6106c7eb510c483f35a3bc6f55226a1f5bc5f4aa571913a588c84bdc)，区块 132609869（2026-11-09 23:39 +08），gas 2,246,446 |
| 部署钱包 | `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`（部署后没有任何权限） |
| owner | 平台 Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`，构造时直接设定（不需要 Safe 签名接受）；只能换结算方和 `veto`，不能放弃所有权 |
| 结算方 | `0x044AF34C6530067ACe8F2cdaf88404a6B968c155`（专用钱包，不和其他任务共用） |
| 报价币 | WBNB `0xbb4C…095c`，USDT `0x55d3…7955`，USDC `0x8AC7…580d`，USD1 `0x8d0D…8B0d` |

记录：`broadcast/DeployGangCallBond.s.sol/56/run-latest.json`。

## 部署后核对（读链）

- 回执 status 1，合约地址与脚本输出一致。
- `pad()`、`wbnb()`、`quote1..3()`、`owner()`、`settler()` 与上表一致；`pendingOwner()` 为 0；`bondCount()` 为 0。
- 运行时代码 9,766 字节，与本地编译结果长度相同；不同的字节只在构造时写入的 immutable 地址位置。
- 带 `GANG_CALL_BOND` 只读重跑部署脚本：接线检查全部通过。
- BscScan 源码验证通过（2026-11-09，编译器 v0.8.28，optimizer 200 runs，via-IR）。

## 主网 fork 测试（`test/fork/CallBondMainnetFork.t.sol`）

在主网 fork 上用部署脚本部署，对着现行的 3.0 pad（Agent ID 用 mock，钱包上限关闭），三个测试都通过：

- WBNB 计价的新币：喊单者买入、押 1 WBNB；跟单者买入时 calldata 尾部带跟单引用；喊单者在内盘卖出一半，第三方举报：举报人 0.01、销毁 0.5、赔付池 0.49，逐 wei 一致；结算方发 root，争议期后跟单者领取，余额销毁后合约里不剩。
- USDT 计价的新币：押 100 USDT；曲线买满、毕业进真实的 Pancake 交易对；两步结算，100 USDT 全额退回（毕业后的闪电借币检查对真实交易对生效）。
- 拒绝范围外的代币：已毕业的现有代币、不是这个 pad 的地址都押不了；Safe 不能放弃所有权。

运行方式：`BSC_RPC_URL=<主网节点> forge test --match-contract CallBondMainnetForkTest --match-test <名字>`，每个测试单独跑。

## 还没做

- 正式环境的举报 keeper、到期结算和赔付任务：服务端已部署（v1.2.90），但没配置合约地址，所以都没有运行。配置前要给结算方和 keeper 钱包各充少量 BNB 作 gas。
- CLI 0.37.0 发版：本 PR 把主网地址写进 CLI，发版在服务端任务启动之后。
