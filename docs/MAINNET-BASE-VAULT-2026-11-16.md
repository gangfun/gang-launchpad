# 主网 · 底仓金库（`base-v1`）

- 链：BSC 主网（chainId 56），2026-11-16
- 规格：`docs/SPEC-BASE-VAULT-V2-2026-11-12.md`；测试网记录：`docs/TESTNET-BASE-VAULT-2026-11-13.md`
- 源码：PR #156（已合并，合并提交 `9cac485`）。部署记录里的 `commit` 字段是该 PR 的最后一个提交 `59d0665`，`src/` 和合并后的 main 相同
- 部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`；gas price 0.05 gwei
- 状态：**只部署了金库实现合约**。3.0 pad 还没升级，`createWithBase` 还不能用

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

## 后续（spec §8）

1. **Safe 第一批**：`script/UpgradeGangLaunchpad3.s.sol`，**不设** `PAD3_BASE_VAULT_IMPL`，只升级。升级后 `createWithBase` 回滚 `BaseNotOpen`。
2. 服务端、网站（配置 `VITE_GANG_BASE_VAULT_IMPL3` = 上面的实现合约）、CLI 0.40.0 上线。
3. **Safe 第二批**：`script/SetGangBaseVaultImpl.s.sol`，`PAD3_BASE_VAULT_IMPL` = 上面的实现合约。脚本会再比对一次字节码，模拟 `setBaseVaultImpl` 并读回，然后打印单笔交易的 Safe 批次。不要为第二批重跑升级脚本。

每一步完成后在本文件补记录。
