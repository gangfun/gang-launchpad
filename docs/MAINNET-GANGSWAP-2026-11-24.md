# 主网记录 · GangSwap

- 日期：2026-11-24（Asia/Shanghai）
- 网络：BSC 主网（56）
- 步骤和应急：`docs/MAINNET-RUNBOOK-GANGSWAP.md`；规格：`docs/SPEC-GANGSWAP-2026-11-22.md`
- 状态：**只完成第 1 步（部署合约）**。pad 没有升级，没有登记，创建没有打开，对现有功能没有影响。

## 第 1 步：部署

代码：main `d2b508a`（`gangswap/` 和 `src/` 与 `a509292` 相同），从 GitHub 干净检出构建；gangswap 测试 140/140，`BUILD` 哈希与 `OpenGangSwap` 里固定的一致。部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`，gas price 0.05 gwei，先模拟后广播，五笔全部成功。

| 合约 | 地址 | 交易 | 区块 | gas |
|---|---|---|---|---|
| GangSwapMigrator | [`0x22e13298D48100420F2F386D70D18E498161B20b`](https://bscscan.com/address/0x22e13298D48100420F2F386D70D18E498161B20b) | `0x9fce2238a46b5df51bf79b7d972342dbef5f0d0ca29064aac8c2c82e16796130` | 135463501 | 905,484 |
| GangSwapBoost | `0x42A3dBcBb2339f52AE332cc480766003C43f1416` | `0x75ab0e3b51623a9ca6eaacb2299fea226fbbe1e8e8276fc43d51827060b5849a` | 135463506 | 799,916 |
| GangSwapFees | `0xa9D9a67D724d487f843d37db92162F6728c58900` | `0x4cd262a730964f0be99b9fce4a66eae656b098fc12af88ae65b601ceceeaa71a` | 135463512 | 934,950 |
| GangSwapFactory | `0xd0C15eB66e08596F9F534d0051F691b86Bc584F5` | `0x97026ff2e190dd1d5afc22fa2168622e9a137a24d032a80b9b4ef4791e66a259` | 135463516 | 2,247,275 |
| GangSwapRouter | `0xd685e3432472d0da34903888f96b0D0221bC779c` | `0x59e05cd7c98ebb78df961144b8aaee5148ea560541d42b0d3dd81a8b58f52e4b` | 135463520 | 2,877,541 |

### 链上核对

- `DeployGangSwap` 的 `check(migrator, router)` 通过；`wired()` = true，migrator 的 owner = Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`。
- 五笔部署交易的 input = 本次构建的创建代码 + 构造参数。
- router 的遮罩代码哈希和操作数次序等于 CLI 固定的值（`0x07886a19…005d`）。
- factory 没有任何 pair；pad 未登记；fees 还不是 bucket operator；pad 没有升级。
- 五个合约的源码都在 Sourcify（exact match）和 BscScan 验证。

`GANGSWAP_DEPLOY_TXS`（后面 `OpenGangSwap` 用）就是上表五笔交易，按表里的顺序。
