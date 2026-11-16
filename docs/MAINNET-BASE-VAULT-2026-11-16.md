# 主网 · 底仓金库（`base-v1`）

- 链：BSC 主网（chainId 56），2026-11-16
- 规格：`docs/SPEC-BASE-VAULT-V2-2026-11-12.md`；测试网记录：`docs/TESTNET-BASE-VAULT-2026-11-13.md`
- 源码：PR #156（已合并，合并提交 `9cac485`）。部署记录里的 `commit` 字段是该 PR 的最后一个提交 `59d0665`，`src/` 和合并后的 main 相同
- 部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`；gas price 0.05 gwei
- 状态：金库实现合约已部署；**Safe 第一批（只升级）已于 2026-11-16 执行**，3.0 代理已在新实现上。`createWithBase` 仍然关闭（`BaseNotOpen`），服务端 v1.2.101、网站 v1.2.129 / v1.2.130、CLI 0.40.0 已上线；**Safe 第二批（开放底仓）已生成，等待签名**

## 部署

部署脚本 `script/DeployGangBaseVault.s.sol`（主网要求 `GANG_MAINNET_OK`，且 `GANG_PAD3` 必须是 3.0 代理）。记录：`broadcast/DeployGangBaseVault.s.sol/56/run-1794760468473.json`。

| 项 | 地址 / 交易 |
|---|---|
| GangBaseVault 实现合约 | [`0x6ff43a038524a46b9F537c0725c17356DCfF0F3b`](https://bscscan.com/address/0x6ff43a038524a46b9F537c0725c17356DCfF0F3b)，部署 [`0x8f8c0f5c…aa20`](https://bscscan.com/tx/0x8f8c0f5c6a8fcb9c6bdf53adccb9a65d9f100c7d262a6e5142f1e4442409aa20)，区块 133768451，gas 477,913 |
| `pad()` | GangLaunchpad 3.0 `0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29`（读回一致） |
| 字节码 | 链上运行时字节码把 `pad` 不可变量（出现 2 次）置零后，和本次构建的 `deployedBytecode` 逐字节一致 |
| 源码验证 | Sourcify：exact match（创建和运行时字节码都一致），[链接](https://repo.sourcify.dev/56/0x6ff43a038524a46b9F537c0725c17356DCfF0F3b)。BscScan：已验证（2026-11-16 通过 Etherscan v2 接口提交） |

部署花费约 0.0000239 BNB。

实现合约只被 pad 当作 EIP-1167 克隆的模板；在 owner 调用 `setBaseVaultImpl` 之前，没有任何代码会用到它。

## 3.0 新实现（第一批要用的合约）

`script/UpgradeGangLaunchpad3.s.sol`，**没有设** `PAD3_BASE_VAULT_IMPL`（也没有设 `PAD3_ABCD_DEPLOYER`：abcd 已经启用）。只链接线上的 PoolCheck，其余没变的库（FairLogic、LegacyRoute、FlywheelLogic、FlywheelPostLogic）沿用链上已有的 CREATE2 地址；完整列表在部署记录的 `libraries` 字段里。记录：`broadcast/UpgradeGangLaunchpad3.s.sol/56/run-1794806080911.json`。

| 合约 | 地址 | 部署交易 | 区块 | gas |
|---|---|---|---|---|
| CurveLogic3（库，CREATE2） | [`0x322742BcC882aa1708E3c6D0375c0541364ebb04`](https://bscscan.com/address/0x322742BcC882aa1708E3c6D0375c0541364ebb04) | [`0x39dc474b…c88b`](https://bscscan.com/tx/0x39dc474b03d47ffa51260ac0e8cc23c8d3d35da00df6184e5c4c1c89770dc88b) | 133869792 | 3,417,737 |
| Pad3FlyModule | [`0x2fe084a9158ce5039d40324a159c5ab66cf54078`](https://bscscan.com/address/0x2fe084a9158ce5039d40324a159c5ab66cf54078) | [`0xd59587c4…e89d`](https://bscscan.com/tx/0xd59587c4c064dcbd6b3512f151b081389ce503b4fc619e875ba99daa1389e89d) | 133869795 | 4,816,115 |
| Pad3Module | [`0x63a9bc1b16eaffa9e3fd75496d6b3ceafdcb0b4c`](https://bscscan.com/address/0x63a9bc1b16eaffa9e3fd75496d6b3ceafdcb0b4c) | [`0xed148a0d…56ba`](https://bscscan.com/tx/0xed148a0db81d3f84ddd530967f979f98374d9d77d708d8bcdbd4784c013156ba) | 133869798 | 3,960,229 |
| GangLaunchpad3 新实现 | [`0xbf15a9B05BBaE720B7cA9a4D87833634Ed90C1BC`](https://bscscan.com/address/0xbf15a9B05BBaE720B7cA9a4D87833634Ed90C1BC) | [`0x0f51e50f…d5e0`](https://bscscan.com/tx/0x0f51e50f5f9fb3c9869a0cdc60c44f777f29a74ac723ddf53d76df92457ed5e0) | 133869801 | 4,843,991 |

四笔全部成功，共 17,038,072 gas，花费 0.0008519036 BNB。飞轮的 handler、vault core 和代币部署器沿用线上的（脚本从当前实现读出）。源码验证：四个都已在 BscScan 验证（2026-11-16，Etherscan v2 接口）。

脚本先在模拟里以 Safe 身份执行升级，再读回比对：最新 25 个币的记录和视图、pad 设置、阶段 2 的全部读回，都和升级前一致。然后带 `PAD3_IMPL`、`PAD3_FLY_HANDLER`、`PAD3_FLY_VAULT_CORE` 只读重跑，打印出第一批。没有设 `PAD3_PROMOTE_PROBES`：部署用的 RPC 不支持 `eth_getLogs`，公共节点的日志又不完整，拿不到完整的绑定名单。上一次升级（abcd）也没有设。推广分成的命名空间由 `test/gang3/Pad3Promote.t.sol` 固定，带分成的币如果在 25 个样本里，它的条款也会比对。

## Safe 第一批（已执行）

归档文件：[MAINNET-GANG-LAUNCHPAD-3-UPGRADE-BASE-SAFE-BATCH-2026-11-16.json](MAINNET-GANG-LAUNCHPAD-3-UPGRADE-BASE-SAFE-BATCH-2026-11-16.json)，SHA-256 `4c007916b0cb561a44eaefae5838e5bf94d693a7f0a4bd55d2212ad96892fcc7`。已执行交易：[`0x48244fdd…2debf`](https://bscscan.com/tx/0x48244fdd365653f3add898d997de417f2f5c77afc7deb16e33f9ff73c5e2debf)，区块 133874706（2026-11-16 13:51 UTC+8），gas 84,578，费用 0.0000042289 BNB。Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`，两位持有者签名，nonce 52，safeTxHash `0xe6c077b2…e5e4`。一笔，不转 BNB：

| 顺序 | 目标 | 调用 |
|---|---|---|
| 1 | ProxyAdmin `0xCe83Be827bf2B6bAFe0ca6d1320Dce965CE3df48` | `upgradeAndCall(0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29, 0xbf15a9B05BBaE720B7cA9a4D87833634Ed90C1BC, 0x)` |

签名前的 fork 演练（`test/fork/Pad3BaseUpgradeFork.t.sol`，2026-11-16，主网最新状态，约区块 133870700；公共归档节点；Agent ID 只在 fork 里模拟，没有广播）：2 通过、0 失败。

- `test_fork_signedBatchThenOpenBase`（`PAD3_FORK_BATCH` = 上面的 JSON，`PAD3_BASE_VAULT_IMPL` = 已部署的金库实现合约）：检查链、Safe、只有一笔、目标是 ProxyAdmin、不转 BNB、calldata 就是升级到新实现且不带初始化调用；以 Safe 身份原样执行后，代理只写了实现地址槽；owner 和 abcd 部署器不变；`baseVaultImpl()` = 0，经 `createWithSalt` 调 `createWithBase` 回滚 `BaseNotOpen`；升级前建的 abcd 币照常买入；abcd 上线时用的七种创建入口验收（含一个线上老曲线币的买卖）通过；`SetGangBaseVaultImpl` 对已部署的实现合约检查通过、只打印不发送；Safe 设置后，不带税 5% / 30 天、带税 3% / 10% / 90 天两个底仓币买到毕业，释放三分之一、到期全部转给创建人。
- `test_fork_upgradeSetImplCreateGraduateRelease`：在 fork 里从头跑一遍两批流程（脚本自己部署），同样通过。

执行后核对：

- Safe 交易服务里 nonce 52 的 `to`、`value`、`data` 和归档 JSON 完全一致，`operation` = 0（直接调用，没有经 MultiSend）。
- 回执：状态成功，代理发出 `Upgraded(0xbf15a9B05BBaE720B7cA9a4D87833634Ed90C1BC)`，Safe 发出 `ExecutionSuccess`（safeTxHash 同上）。
- 读回：实现地址槽 = 新实现；`module()` = 新的 Pad3Module `0x63a9…0b4c`；`baseVaultImpl()` = 0；`vanityDeployer()` 仍是 `0x8e76…F8DE`；pad 和 ProxyAdmin 的 owner 仍是 Safe；Safe nonce 53，阈值 2。
- `SetGangBaseVaultImpl` 对执行后的主网状态只读运行，检查全部通过并打印出第二批（一笔 `setBaseVaultImpl(0x6ff4…0F3b)`）。签名前要再生成一次，这次没有存档。
- 执行后的主网状态（区块 133875100 之后）上重跑 `test_fork_signedBatchThenOpenBase`：1 通过、0 失败。批次在已升级的代理上再执行一次只是重写同一个实现地址；后面的七种创建入口、老曲线币买卖、第二批以及两个底仓币的毕业和释放全部通过。Agent ID 只在 fork 里模拟，没有在主网发测试币或做测试交易。

## 链下上线（2026-11-16）

- 服务端 v1.2.101（gangfun-server #57）：索引 `BaseCreated` 和金库事件、底仓币的保证金规则、释放 keeper。生产 keeper：pad-watch 的 3.0 预期实现改为新实现；`base-release` 定时任务已装上，`BASE_PADS` 未设时不做任何事。
- 网站 v1.2.129（gang-web-legacy #48，`VITE_GANG_BASE_VAULT_IMPL3` = 上面的金库实现合约）和 v1.2.130（#50：`capabilities.json`、`llms.txt`、指南的 CLI 0.40.0 说明）。
- CLI 0.40.0（#161，npm 和 MCP Registry）：从 pad 读 `baseVaultImpl()`，开放前 `--base` 在发送前就停下并提示未开放。

## Safe 第二批（等待签名）

归档文件：[MAINNET-GANG-LAUNCHPAD-3-OPEN-BASE-SAFE-BATCH-2026-11-16.json](MAINNET-GANG-LAUNCHPAD-3-OPEN-BASE-SAFE-BATCH-2026-11-16.json)，SHA-256 `66f027f66b08d3409296604f7f2a0610f85eadd5191478b3f1279c0ae3de1d09`。由 `script/SetGangBaseVaultImpl.s.sol` 对执行第一批后的主网状态生成。Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`，一笔，不转 BNB，立即生效：

| 顺序 | 目标 | 调用 |
|---|---|---|
| 1 | Pad 3.0 代理 `0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29` | `setBaseVaultImpl(0x6ff43a038524a46b9F537c0725c17356DCfF0F3b)` |

脚本的检查：链是主网，pad 是 3.0 代理且已是底仓构建，owner 是 Safe，当前 `baseVaultImpl()` = 0，实现合约的代码和本次构建（`pad` 固定为该代理）逐字节一致；以 Safe 身份模拟设置并读回，然后回滚。

签名前的 fork 演练（`test/fork/Pad3BaseUpgradeFork.t.sol` 的 `test_fork_secondBatchOpensBase`，`PAD3_FORK_BATCH2` = 上面的 JSON；2026-11-16，执行第一批后的主网最新状态，约区块 133,935,701 之前；公共归档节点；Agent ID 只在 fork 里模拟，没有广播）：1 通过、0 失败。

- 检查链、Safe、只有一笔、目标是代理、不转 BNB、calldata 就是 `setBaseVaultImpl(实现合约)`，实现合约的 `pad()` 是该代理；`SetGangBaseVaultImpl` 对同一实现合约检查通过。
- 以 Safe 身份原样执行后，代理只写了底仓命名空间；实现地址、abcd 部署器、owner 都不变。
- abcd 上线时的七种创建入口（含一个线上老曲线币的买卖）通过；不带税 5% / 30 天、带税 3% / 10% / 90 天两个底仓币买到毕业，真实 Pancake V2 交易对拿到 2 亿枚和 6 WBNB，释放三分之一、到期全部转给创建人。

执行后要做：读回 `baseVaultImpl()`；生产 keeper 设 `BASE_PADS=gl3:0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29@<执行区块>`；第一个真实底仓币出来后核对服务端、网站和 CLI 的显示。

## 后续（spec §8）

1. ~~Safe 第一批~~：已执行（见上）。
2. ~~服务端、网站、CLI 0.40.0 上线~~：已完成（见上）。
3. **Safe 第二批**（已生成，见上）：`script/SetGangBaseVaultImpl.s.sol`，`PAD3_BASE_VAULT_IMPL` = 上面的实现合约。脚本会再比对一次字节码，模拟 `setBaseVaultImpl` 并读回，然后打印单笔交易的 Safe 批次。不要为第二批重跑升级脚本。

每一步完成后在本文件补记录。
