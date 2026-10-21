<!-- gang docs chrome -->
<pre>
┌─ GANG / docs ──────────────────────────────────────────┐
│  SPEC · curve math & invariants (appendix)             │
│  ops: see README · status: fork OK / mainnet grad 未验 │
│       · no third-party audit · no multisig             │
└────────────────────────────────────────────────────────┘
</pre>

# Gang 规格 v1

## 1. 固定参数

| 参数 | 值 |
|---|---|
| 总供应 `TOTAL_SUPPLY` | 1e9 × 1e18 |
| 内盘出售量 `CURVE_SUPPLY` | 8e8 × 1e18（80%） |
| LP 代币量 `LP_SUPPLY` | 2e8 × 1e18（20%） |
| 毕业筹资 `GRADUATION_BNB` | 20 ether |
| 虚拟 BNB 储备 `VIRTUAL_BNB` | 20/3 ether = 6666666666666666667 wei |
| 虚拟代币储备 `VIRTUAL_TOKEN` | 16e9/15 × 1e18 ≈ 1066666666.667e18 |
| 手续费 `FEE_BPS` | 100（1%） |
| 单钱包上限 `MAX_PER_WALLET` | 1e7 × 1e18（总供应的 1%） |
| 创建费 | 0 |

## 2. 曲线

恒定乘积：`(VIRTUAL_BNB + realBnb) × (VIRTUAL_TOKEN − soldTokens) = k`，`k = VIRTUAL_BNB × VIRTUAL_TOKEN`。

两个虚拟储备由两条约束解出：

1. 卖出 8e8 代币时真实 BNB 恰为 20：`(vB + 20)(vT − 8e8) = vB·vT`
2. 曲线终点价等于 LP 开盘价，毕业瞬间无套利：`(vB + 20)/(vT − 8e8) = 20/2e8 = 1e-7`

解得 `vB = 20/3`，`vT = 16e9/15`。

| 指标 | 值 |
|---|---|
| 开盘价 | 6.25e-9 BNB / token，FDV 6.25 BNB |
| 毕业价 | 1e-7 BNB / token，FDV 100 BNB |
| 开盘→毕业涨幅 | 16× |
| 1 BNB 在开盘可买 | ≈ 1.39 亿 |
| 1 BNB 在已筹 10 BNB 时可买 | ≈ 2415 万 |
| 1 BNB 在已筹 19 BNB 时可买 | ≈ 1039 万 |

## 3. 买入 `buy(token, minTokensOut)`

1. 门禁：`isAgent(msg.sender)`，即 Agent ID `balanceOf(msg.sender) > 0`。
2. 钱包上限：`room = MAX_PER_WALLET − balanceOf(msg.sender)`，为 0 则 revert `WalletCapReached`。内盘期间转账锁定，所以余额即净持仓；卖出后额度恢复。
3. `fee = msg.value × 100 / 10000`，`bnbIn = msg.value − fee`。
4. 毕业上限：若 `realBnb + bnbIn > 20 ether`，`bnbIn = 20 ether − realBnb`。
5. `tokensOut = (vT − sold) − ceil(k / (vB + realBnb + bnbIn))`。
6. 钱包上限：若 `tokensOut > room`，`tokensOut = room`，反算 `bnbIn = ceil(k / (vT − sold − room)) − (vB + realBnb)`。
7. 任一上限生效时重算 `fee = min(ceil(bnbIn × 100 / 9900), msg.value − bnbIn)`，`refund = msg.value − bnbIn − fee` 退还 `msg.sender`。
8. 要求 `tokensOut >= minTokensOut`；更新储备，转代币，累计 `fee`。
9. 若 `realBnb == 20 ether` 触发 `_graduate()`。

推论：毕业至少需要 80 个不同的 Agentic Wallet（80 × 1% = 80%）。`quoteBuy(token, buyer, bnbGross)` 返回 `(tokensOut, bnbIn, fee, refund)`，与执行完全一致。

## 4. 卖出 `sell(token, tokensIn, minBnbOut)`

无门禁。

1. `bnbOut = (vB + realBnb) − k / (vT − sold + tokensIn)`
2. `fee = bnbOut × 100 / 10000`，用户得 `bnbOut − fee`，要求 `>= minBnbOut`。
3. 更新储备，收代币，付 BNB，`fee` 转金库。

## 5. 毕业 `_graduate()`

同一笔交易内：

1. 标记曲线关闭，`LaunchToken.unlock()` 解除转账锁。
2. `approve` 2e8 代币给 PancakeSwap V2 Router，`addLiquidityETH{value: 20 ether}`，`to = 0x…dEaD`。
3. 发事件 `Graduated(token, pair)`。

PancakeSwap V2 Router（BSC 主网）：`0x10ED43C718714eb63d5aA57B78B54704E256024E`。

## 6. 转账锁

`LaunchToken` 在 `locked == true` 时仅允许 `from == Launchpad`（曲线卖出代币给买家）或 `msg.sender == Launchpad`（曲线回收代币）。毕业时由 Launchpad 调 `unlock()`，不可逆。

## 7. 门禁

### 7a. 链上门禁（主路径）：Agent ID NFT

Binance Wallet 领取 .ai Agent ID 时会在 BSC 上 mint 一个 **soulbound ERC-721**：

| 项目 | 值 |
|---|---|
| 合约 | `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` |
| name / symbol | SPACE ID Agent ID / AI |
| 可转让 | 否，`transferFrom` / `safeTransferFrom` 均 revert（自定义错误 `0xa4420a95`） |
| 代理 | 否（ERC-1967 implementation slot 为空） |
| mint 入口 | `0x8580974c(string name, uint256 deadline, bytes sig)`，需要 65 字节后端签名授权 |
| 发起方 | Agentic Wallet 地址本身（普通 EOA，自己付 gas） |

因为 mint 需要后端签名、且 NFT 不可转让，`agentIdRegistry.balanceOf(msg.sender) > 0` 即可作为"调用者是 Binance Agentic Wallet"的链上证明。`buy()` 传空 `sig` 走此路径。

### 7b. 管理员权限（加固后）

| 函数 | 约束 |
|---|---|
| `setMigrator` | 只能设置一次，之后永久不可变；`create()` 在未设置前拒绝。 |
| `proposeAgentIdRegistry` / `applyAgentIdRegistry` / `cancelAgentIdRegistry` | 注册表变更需 24 小时时间锁，提案即发事件。 |
| `setFeeVault` | 仅影响平台手续费去向。 |
| `collectFees` / `sweepExcess` / `withdraw` | 任何人可调；`sweepExcess` 只能动 `balance − totalRealBnb − accruedFees − totalPending` 这部分被强塞进来的 BNB。 |

凭证（voucher）路径已删除：门禁只认链上 Agent ID，平台方没有任何"签个字就能买"的后门。

### 7c. 付款兜底

退款和卖出付款用 `_pay`：`call` 失败（例如合约钱包没有 `receive`）时不回滚，而是记入 `pendingWithdrawals[to]`，由对方自行 `withdraw()`。这保证触发毕业的最后一笔买入不会因为买家收不到退款而失败。

## 8. 不变量（fuzz 目标）

- `(vB + realBnb) × (vT − sold) >= k`（取整只对协议有利）
- `realBnb <= 20 ether`，`sold <= CURVE_SUPPLY`
- 任意地址 `balanceOf <= MAX_PER_WALLET`（毕业前）
- 合约 BNB 余额 == totalRealBnb + accruedFees + totalPending
- 任意买后立即卖，用户 BNB 不增加
- 毕业后 Launchpad 对该代币余额为 0，曲线函数全部 revert

## 9. 实现备注

- **迁移绕过 Router，直接对 Pair 操作**：Migrator 先 `createPair`（若不存在），把 WBNB 和代币直接转入 pair 后调用 `pair.mint(0xdEaD)`。原因：若走 `router.addLiquidityETH`，攻击者可以在毕业前向 pair 捐 WBNB 并调用 `sync()`，使储备变成"只有 WBNB 没有代币"，Router 的 `quote()` 会 revert，毕业永久失败。直接 mint 时捐赠只会变成被销毁的额外流动性。fork 测试 `test_graduation_survivesWbnbDonationGriefing` 覆盖此场景。
- **代币转账锁使 pair 在毕业前不可能持有代币**，所以不存在"毕业前 pair 已有代币储备导致价格偏离"的问题。锁的规则是：`from` 必须是 Launchpad，或者 `msg.sender` 是 Launchpad（即 `sell` 里的 `transferFrom`）。持有人连"转回 Launchpad"都不行，因此 Launchpad 持仓恒等于 `TOTAL_SUPPLY − sold`，毕业时也用这个值而不是 `balanceOf`。
- **手续费采用 pull 模式**：先累计在 `accruedFees`，任何人可调 `collectFees()` 推到金库，避免金库合约异常导致买卖失败。
- **取整方向**：`_tokensOut` 与 `_bnbOut` 都用 `ceilDiv` 计算新储备，保证 `(vB+realBnb)(vT−sold) ≥ k` 恒成立，取整只对协议有利。
