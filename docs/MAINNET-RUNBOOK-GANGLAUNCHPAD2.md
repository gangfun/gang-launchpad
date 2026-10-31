# 主网上线步骤 · GangLaunchpad 2.0

适用于 PR #97（creator 分成 + 可选毕业门槛）。这些步骤来自 2026-10-31 的全面审计（C：部署路径）并已按修复后的脚本更新。每一步都要在上一步的回执全部成功后再做。

## 0. 前提

- PR #97 已合并。本地非 fork 测试、`GangLaunchpad2DeployFork`、`GangLaunchpad2DeployGuardsFork` 已全部通过（逐个 `--match-path` 单独跑）。
- 用户已明确同意上主网。
- 后端、网站、CLI 的 2.0 支持都已就绪，但还没切换（等第 9 步）。

## 1. 干净的 shell

只设：
- `GANG_PAD=0x15CFD2dc8278Fb87a1783ef42111618E20874365`（1.0）
- `OWNER=0x2866369F7acEFC9760bdE7779362fae5cD68B41E`（平台 Safe）
- RPC 和部署私钥（从环境文件读，不打印）

以下都**不能**设：
- `KEEPER*`、`TWAP_WINDOW`、`RECIPIENT*`、`FEE_VAULT`、`BURNER`
- `MAINNET_OWNER_IS_DEPLOYER`
- `GANG_PAD2`、`GANG_ROUTER2`、`HANDLER_ADMIN`、`GANG_BOND`、`ADMIN_OWNER`

## 2. 阶段 1

1. 先模拟一遍：不带 `--broadcast`，带 `--libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3`。看到 `Safe batch 1` 就说明 batch 1 之前的检查都过了。
2. 再正式广播：`GANG_MAINNET_OK=true`，带 `--broadcast --slow`。
3. 确认所有回执成功，记下 `GANG_PAD2`、`GANG_ROUTER2`、`GANG_PAD2_BLOCK`。

## 3. 核对 batch 1

带 `GANG_PAD2` / `GANG_ROUTER2` 只读重跑（不带 `--broadcast`），用链上状态重新生成 batch 1，再和第 2 步的输出、`run-latest.json` 逐个地址比对。

重跑时脚本会再检查一遍：pad 和 handler 是这把部署私钥部署的，现在仍归它，也还没开始交接。

## 4. Safe batch 1（9 笔，撤不回）

依次登记到共享合约：
- vault：`setLaunchpad` / `setMinimumShareBalance` / `setOperator` / `setExcluded(router)`；
- migrator：`addLaunchpad`；
- TokenDeployer：`setLaunchpad`；
- bucket：`setOperator` ×2；
- registry：`addPad`。

## 5. 阶段 2

1. 带 `GANG_PAD2` / `GANG_ROUTER2` / `GANG_PAD2_BLOCK` 广播。自检显示 `self-check ok`，并发起 pad 和 handler 的交接。
2. Safe batch 2：accept handler、accept pad、`setMigrator`。执行后 2.0 开放。
3. 只读重跑一次。应显示 nothing left，并打印 batch 3，**马上存好**。

## 6. 模块

每个脚本都用 `GANG_PAD2=<2.0>`。主网上脚本只认已登记、归 Safe 的 2.0，残留的 `GANG_PAD`（1.0）不会被用到。

1. `DeployGangBuybackSplitterFactory`：部署 admin2 和回购 factory。要求 Safe 持有 handler，且没有进行中的交接。Safe 再执行：
   - `handler.transferOwnership(admin2)`
   - `admin2.exec(acceptOwnership())`
   - `admin2.setFactory(buyback, true)`
2. `DeployGangSplitModuleFactory` 和 `DeployGangLiquiditySplitterFactory`，都带 `HANDLER_ADMIN=admin2`。Safe 再一批执行两个 `setFactory`。
3. `DeployGangBond`。
4. 用 `cast call` 核对：各 factory 的 `pad()` 和 bond 的 `pad()` 都是 2.0，`admin2.isFactory` 都为真。
5. 阶段 2 再只读跑一次：admin2 持有 handler 时也应该是 `self-check ok`。

## 7. 合作方 recipient

Safe 执行 `admin2.exec(list(合作方, label))`。只迁真正的合作方：1.0 上由模块 factory 克隆出来的 recipient 绑定的是 1.0，不能迁过来（用 1.0 admin 的 `moduleOf(r)==0` 过滤）。

## 8. 后端、网站、CLI

- indexer：加 `gang:<pad2>@<block>`、bond 和 router（`GANG_PAD_ROUTERS`）；
- keeper：加 bond；
- 网站：填主网 2.0 地址；
- CLI：在 `GANG_GENS.mainnet` 加 2.0，发布 0.22.0。

三边各自验证通过。

## 9. 切换

最后执行 Safe batch 3：`TokenDeployer.setLaunchpad(1.0, false)`。1.0 停止创建新币，已有的币照常交易、毕业、领取。
