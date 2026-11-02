# 主网 · GangGateway V2（铸币飞轮）升级

2026-11-02 用户同意上主网。网关代理 `0x9dD16b73f624bdd8a210CBB2602FdF70f1B450B8` 原地升级到 V2（AUDIT-BRIEF §26，规格 `docs/SPEC-GANG-GATEWAY-2026-10-30.md`「铸币飞轮」一节）：地址、owner、卖出白名单和用户的授权都不变。升级经 48 小时时间锁，由 Safe 提案和执行。

- 代码：合并 PR #108 后的 `main`（`b19e0a8`），在 `git archive` 导出的干净目录里编译和部署。本地编译的实现合约和测试网验收用的两个实现（`0xeE20…228e`、`0x4FBD…C6f`）逐字节相同，包括 metadata。
- 流程：审计 → 修复 → 独立复审 → 测试网验收（`docs/TESTNET-GANG-GATEWAY-V2-FLYWHEEL-2026-11-02.md`）。

## 已完成

| 项 | 值 |
|---|---|
| 新实现合约 | [`0x025026A332B262ce447b7e73412159574cE2B060`](https://bscscan.com/address/0x025026A332B262ce447b7e73412159574cE2B060)，已在 BscScan 验证（solc 0.8.28、via-ir、优化 200 次、cancun），构造函数里已锁死（不能初始化） |
| 部署交易 | [`0xbce29694…4fd7`](https://bscscan.com/tx/0xbce29694323bf6deec9a0e4e682776164e33a6b1d66d9d0baf422c80365f4fd7)，区块 131,237,472，2,586,772 gas，0.05 gwei（legacy） |
| 部署命令 | `GANG_MAINNET_OK=true forge script script/UpgradeGangGateway.s.sol --rpc-url $BSC_RPC_URL --broadcast --slow --legacy --with-gas-price 50000000`（部署钱包不是时间锁的提案人，脚本只部署实现合约） |
| 时间锁操作 id | `0x7877d153da8516056c8a4395356ef0ef44056370c3e8b8e200efacb460108d33`（target ProxyAdmin `0x3856…Eec4`，value 0，`upgradeAndCall(网关代理, 0x0250…B060, "")`，predecessor 0，salt 0，delay 172,800 秒） |

## 待 Safe 执行

1. **第 1 批（现在）**：`docs/MAINNET-GANG-GATEWAY-V2-SAFE-BATCH-1-SCHEDULE-2026-11-02.json`，1 笔：时间锁 `0xc5C0…8e8B` 的 `schedule`。
2. **第 2 批（第 1 批执行 48 小时后）**：`docs/MAINNET-GANG-GATEWAY-V2-SAFE-BATCH-2-EXECUTE-LIST-2026-11-02.json`，3 笔，一次执行：
   - 时间锁 `execute`（代理切到 `0x0250…B060`）；
   - 飞轮 V1 pad `0x631e…B029` 的 `setRouter(网关, true)`；
   - 飞轮 V2 pad `0x2818…8a5a` 的 `setRouter(网关, true)`。

两批都在主网 fork 上按 Safe 的身份逐笔重放过（批量文件里的原始 calldata）：第 1 批成功；48 小时内第 2 批回滚；48 小时后第 2 批 3 笔都成功，之后代理指向新实现、完整自检（`GangGatewayDeployLib.check`）通过、两个飞轮 pad 都列入网关、卖出白名单保持不变，在线上 V1 飞轮币上经网关买入，成交和 `tryBuy` 一致。

48 小时里新代码公开在链上；Safe 可以在执行前用时间锁的 `cancel(操作 id)` 取消。

## 执行后核对

- `cast implementation 0x9dD1…50B8` 为 `0x0250…B060`；用 `GATEWAY_IMPL=0x0250…B060` 重跑 `UpgradeGangGateway`（不广播）走第 3 步：自检通过，列出所有 pad 都已列入网关。
- 两个飞轮 pad 的 `routers(网关)` 为 true。
- 抽查一个开盘前的飞轮币：`getTokenInfo` status 1，`tryBuy` 有报价。
