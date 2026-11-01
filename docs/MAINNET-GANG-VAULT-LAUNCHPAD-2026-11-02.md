# 主网 · GangVaultLaunchpad（2.0 金库版）

BSC 主网（chainId 56），2026-11-02 部署。代码为 `main` 的 `d8090c0`（PR #102 合并）。

- **是什么**：2.0 的 pad 加上锁仓金库入口。每个曲线币只能用 `createWithVault` 创建，创建时就和一个已登记的金库永久绑定。内盘期间：
  - `vaultLock`：用户钱包 → 金库，计入用户的 1% 额度；
  - `vaultRelease`：金库 → 用户钱包，不受 1% 限制。
- **发币权限**：只有 Safe 用 `setVaultCreator` 为这个金库指定的钱包，才能把币绑到该金库。每次指定只能发一个币。
- **共用合约**：和 1.0、2.0 共用分红金库、平台手续费池、毕业迁移合约、TokenDeployer、报价登记表和 pad 登记表。
- **没有接的**：GangBond 和各个模块 factory 都没接（按设计）。也没有切换批次，1.0 和 2.0 照常创建。
- **状态**：已开放，Safe 拥有 pad 和 handler。金库还没登记。

## 地址

| 合约 | 地址 |
|---|---|
| **GangVaultLaunchpad**（pad，部署区块 131081707） | [`0xE90851A90C6278E3d6e4C24320101f8B13D90A11`](https://bscscan.com/address/0xE90851A90C6278E3d6e4C24320101f8B13D90A11#code) |
| GangTaxHandler（owner = 平台 Safe） | [`0x9B3B7A2865dAe845585a7778d1a12bf398c61182`](https://bscscan.com/address/0x9B3B7A2865dAe845585a7778d1a12bf398c61182) |
| CurveLogic（这个 pad 链接的库） | [`0x504D57676358B5f181A76216653d3F182587336d`](https://bscscan.com/address/0x504D57676358B5f181A76216653d3F182587336d#code) |
| FairLogic（与 2.0 相同） | [`0x34E18563622aE05e92FdaCA81a40D83652067c9D`](https://bscscan.com/address/0x34E18563622aE05e92FdaCA81a40D83652067c9D) |
| GangRouter（proxy，用户授权这个地址） | [`0xAcd4944A4090c13d9DACAe60f3019cef9d9bB1Ad`](https://bscscan.com/address/0xAcd4944A4090c13d9DACAe60f3019cef9d9bB1Ad) |
| GangRouter 实现 | [`0xFC3e9E153A2b26c1e7D133329302036E896691C9`](https://bscscan.com/address/0xFC3e9E153A2b26c1e7D133329302036E896691C9) |
| ProxyAdmin（owner = timelock） | [`0x7eBc059f6B40591A8d4719A1009F884Cb85cc96D`](https://bscscan.com/address/0x7eBc059f6B40591A8d4719A1009F884Cb85cc96D) |
| TimelockController（48 小时；proposer / executor / canceller = 平台 Safe） | [`0xe0bdcd6C6C2a637C222b6817Ea6596d3027c4B6d`](https://bscscan.com/address/0xe0bdcd6C6C2a637C222b6817Ea6596d3027c4B6d) |

- **参数**：和 2.0 相同。
  - `CREATOR_FEE_SHARE_BPS` = 7000；
  - 毕业档位 6 / 9 / 12 / 15 BNB；
  - keeper、Agent gate、V3 factory、USDT 桥接池与 2.0 相同。
- **BscScan 验证**：
  - pad 和 CurveLogic 手动提交，参数是 solc 0.8.28、via-ir、optimizer 200、cancun。pad 链接 CurveLogic、FairLogic、PoolCheck，CurveLogic 链接 PoolCheck。
  - handler、Router 实现、代理、ProxyAdmin、Timelock 的字节码和已经验证过的合约相同，BscScan 自动显示为已验证。

## 部署（部署钱包）

按 `docs/MAINNET-RUNBOOK-GANGLAUNCHPAD2.md` 执行。

1. **干净的环境**：只设 `GANG_PAD`（1.0）、`OWNER`（平台 Safe）、RPC、部署私钥和 `VAULT_PAD_NEW=true`，库链接带 PoolCheck。
2. **阶段 1**：先模拟，再广播。13 笔交易全部成功，共花 0.00078 BNB。
   - 部署：
     - CurveLogic [`0x86d1ac7a…4704`](https://bscscan.com/tx/0x86d1ac7addc25ab861275251729ae192ab906eb39b066494dbf3350c7f164704)
     - handler [`0xcc2efeb9…79f9`](https://bscscan.com/tx/0xcc2efeb905b7e6fb79545a0eff89813e23938677306b8604a26cab07e3b179f9)
     - pad [`0x97825cad…6630`](https://bscscan.com/tx/0x97825cad6bdfe2a08dc6aea125048369d11d51e0ded50c3e2af170e0b0896630)
     - Router 实现 [`0xd9b567c8…b0d0`](https://bscscan.com/tx/0xd9b567c8a052d479bcc781f170e07afe70c60f7cd3e8a35788f46cb857dbb0d0)
     - Timelock [`0xdc45e32b…2066`](https://bscscan.com/tx/0xdc45e32baabb38292f1f42333592ea30a7a9b4f5e14ec12a6053069b10ff2066)
     - Router proxy [`0x24a0f2ef…2848`](https://bscscan.com/tx/0x24a0f2efe6744521fa1d17ed27d193cecb6eaebf1e683bba173771f661d02848)
   - 接线：handler `setLaunchpad` / `setKeeper`；pad 列入 Router 和 GangGateway；设置 Agent gate、V3 factory 和 USDT 桥接池。
   - 广播后只读重跑：用链上状态重新生成的 batch 1 与广播时的输出逐字节一致。
3. **阶段 2**：自检 `self-check ok`，发起 handler 和 pad 向 Safe 的交接（[`0x61eaa3ac…daf3`](https://bscscan.com/tx/0x61eaa3acff51b90068cf85a98f91059bf87acd90a1105a547f89cb260d55daf3)、[`0x27e8784e…7256`](https://bscscan.com/tx/0x27e8784e9177c30159b83530e1d643b664c61411e86812defa3e6fe85e8c7256)）。
4. **batch 2 之后只读重跑**：`self-check ok`，并提示 Safe 已没有待执行的批次，pad 已开放。

部署前，整套主网流程先在本地主网分叉上演练过一遍：用一次性部署钱包，冒充 Safe 执行 batch 1、batch 2 和金库登记批次。

部署记录（forge 生成）：`broadcast/DeployGangVaultLaunchpad.s.sol/56/` 下：
- `run-1793550841626.json`：阶段 1；
- `run-1793551315682.json`：阶段 2，与当前的 `run-latest.json` 是同一份。

### 部署前修的一处自检

`DeployGang.s.sol` 的主网自检原来要求 USDT 不在报价登记表上。2026-11-01 Safe 登记了 USDT、USDC 和 USD1（见 PR #100），所以阶段 2 会停在 `"mainnet USDT listed"`。

部署真正依赖的是"USDT 没有毕业金额的覆盖值"，所以这条检查改成 `graduationAmount(USDT) == 0`（PR #102）。

## Safe 批次（平台 Safe）

1. **batch 1（9 笔，登记到共享合约）**：[`0xd12a7d8b…4290`](https://bscscan.com/tx/0xd12a7d8b4f376c5997032e8b03554a61ff8378a05d74572570eb5ebde0444290)，区块 131082479。
   - 分红金库：`setLaunchpad` / `setMinimumShareBalance`（10,000 枚）/ `setOperator(handler, pad)` / `setExcluded(router)`；
   - 迁移合约：`addLaunchpad`；
   - TokenDeployer：`setLaunchpad`；
   - 平台手续费池：`setOperator` ×2；
   - pad 登记表：`addPad`。
   
   阶段 2 的自检覆盖了这 9 项，全部通过。
2. **batch 2（3 笔）**：[`0x6b79592a…1b04`](https://bscscan.com/tx/0x6b79592ab161736901406eeb5aafb4923686392a58713b120acf058cc84d1b04)，区块 131083062。
   - handler、pad `acceptOwnership`；
   - pad `setMigrator(共享迁移合约 0xfE38…4604)`。
   
   读回结果：pad 和 handler 的 owner 都是 Safe，没有待交接的；migrator 是共享迁移合约。

## 登记金库（每个金库一次）

1. 金库方用 `pad_ = 0xE908…0A11` 部署金库，并在 BscScan 验证源码。
2. 我们核对源码，确认它调用的是 `vaultLock` / `vaultRelease`，并按 `token.locked()` 在内盘和毕业后两种转账方式之间切换。
3. 带 `GANG_VAULT_PAD` / `GANG_VAULT_ROUTER` / `GANG_VAULT_PAD_BLOCK`、`VAULT=<金库>`、`VAULT_CREATOR=<发币钱包>` 只读跑阶段 2。脚本先在模拟里执行一遍，再打印 Safe 批次：
   - `pad.setVault(金库, true)`；
   - `handler.list(金库, label)`，只在 handler 还没登记它时才有；
   - `pad.setVaultCreator(金库, 发币钱包)`。
4. Safe 执行后，发币钱包调用 `createWithVault(..., 金库)` 发币。每次指定只能用一次，要再发一个币需要重新指定。

## 待办

- 金库方的主网金库：登记批次，以及之后的发币记录。
- 后端 indexer / keeper 和网站加上主网配置。
