# 主网：共享手续费池换成 RoutedBuybackBurner（2026-11-13，待上线）

BSC 主网（chainId 56）。合约 `src/buyback/RoutedBuybackBurner.sol`，部署脚本 `script/DeployRoutedBuybackBurner.s.sol`。

## 为什么换

LaunchpadV3 / 打新 / 铸币飞轮共用的 `SharedPlatformFeeBucket`（`0xB8C4…A21b`）只有 `collectPlatform`，80% 回购固定走 Pancake V2：quote → WBNB → GANG。内部审计 5（C-F2）有意删掉了 `collectPlatformSmart`，因为 keeper 自带的 Smart Router calldata 能把 80% 换去别处。

股票类报价币的深度在 Pancake V3（对 USDT），V2 上没有交易对，或者池子太浅。keeper 每轮都跳过这些币，`/burn` 面板上的「待结算手续费」就一直结不掉。2026-11-13 时卡住的余额：

| 报价币 | 卡住数量 | 约合 | V2 情况 |
|---|---|---|---|
| oANTHROPIC `0x24B5…760a` | 1.035 | $920 | 交易对只剩约 0.0008 WBNB |
| BABAB `0x4eF9…f4ec` | 3.608 | $334 | 有交易对，冲击约 5.6%（上限 3%） |
| EWYB `0xBE82…2Cb8` | 0.083 | $12 | 交易对比卡住的量还小 |
| wTCENTx `0x4133…9f9E` | 0.004 | $0.2 | 没有交易对 |

四个币经 Pancake V3 `quote →(0.25%)→ USDT →(0.01%)→ WBNB` 都有深度，冲击都在 1% 以内。

## 新合约做什么

- 入口和 GangBuybackBurner 一样：`buybackAndBurn(quote, amountIn, minGangOut)`。共享池调 `setBurner` 就能换上，池子不用重新部署，卡住的余额也不用迁移。
- `setV3Route(quote, path)` 只有 owner 能调。合约会检查 path 以 quote 开头、以 WBNB 结尾；fee 必须是 100 / 500 / 2500 / 10000 之一；中间不能经过 WBNB、GANG 或 quote 本身；最多 3 跳。传空 path 就恢复走 V2。
- 设了路线的 quote：先在 V3 上 exactInput 换成 WBNB（收款方固定是 burner 自己，必须把 amountIn 全部花完），再在 V2 上把 WBNB 换成 GANG；`minGangOut` 对整条路线兜底，换到的 GANG 全部转进黑洞。没设路线的 quote 照旧走 V2，GANG 收到就直接销毁。
- keeper 只能决定 `minGangOut`，选不了池子，也改不了收款方。`minGangOut` 和现在 V2 路线的风险一样，由 keeper 的冲击检查和 `SLIPPAGE_BPS` 管着，所以 C-F2 的结论不受影响。路线不让 keeper 选，是因为 V3 每对币有 4 个 fee 档，keeper 能挑一个自己铺了流动性的薄池子。
- 没有 `buybackAndBurnSmart`，只给共享池用。V2 / U / S 三个池继续用 GangBuybackBurner。
- router / smartRouter / wbnb / gang 都是 immutable，没有 setter。

## 测试（本地）

- `forge test --match-path test/buyback/RoutedBuybackBurner.t.sol`：17 个通过。覆盖 V3 路线、整条路线的 `minGangOut`、没花完 / 付给别人时回滚、清掉路线后回到 V2、各种不合法的 path，以及挂在 SharedPlatformFeeBucket 后面按 80% / 20% 分账。
- `BSC_RPC_URL=… forge test --match-path test/fork/RoutedBuybackBurner.t.sol`：5 个通过。在 BSC fork 上把共享池换到新 burner，用池子里真实卡住的余额收：oANTHROPIC 烧掉约 17.4 万 GANG、BABAB 约 6.3 万、EWYB 约 2,300、wTCENTx 约 38；20% 进 feeVault；WBNB / GANG 计价照旧可收。

## 上线步骤

1. 部署（任意 EOA，owner 设为 Safe）：

   ```bash
   forge script script/DeployRoutedBuybackBurner.s.sol --rpc-url bsc --broadcast --verify
   ```

   脚本会先在 V3 Quoter 上确认每条路线都能报价，然后打印 Safe Transaction Builder 的 JSON。
2. **Safe 执行之前**，先在正式站 keeper `.env` 设 `EXPECTED_ROUTED_BURNER=<新 burner>`（gangfun-server `keeper/keeper-v2-platform.sh`）。keeper 两个 burner 都认：共享池还挂着 GangBuybackBurner 时行为不变，换过去的下一轮就按新 burner 收，中间不断。反过来先换 burner、后配 env 的话，这段时间 keeper 每轮都会拒绝这个池子并报 ERROR，回购也会停。
3. Safe（`0x2866…B41E`）执行这份批量交易：4 笔 `setV3Route`，最后一笔是共享池的 `setBurner(新 burner)`。路线都到位之后池子才换 burner。
4. 手动跑一次 dry-run，确认 4 个币都显示 `via burner V3 route — simulation OK`。oANTHROPIC 约 1.45 BNB，在正式站 `MAX_ACCRUED_ETHER=6` 以内。

以后新出现的股票类报价币，如果 V2 不够深、V3 有路线，keeper 会告警（needroute），并给出完整的 `setV3Route(quote, path)` 参数，Safe 签一笔就行。

## 地址

| 合约 | 地址 |
|---|---|
| RoutedBuybackBurner（owner Safe `0x2866…B41E`） | 待部署 |
| SharedPlatformFeeBucket | `0xB8C4B68a62513240A5e44EFd78fFc35ac25bA21b` |
| 现在的 burner（GangBuybackBurner，V2 / U / S 继续用） | `0x38120bf40F8F19E6cc60622Bc7C5B005dfe5363B` |
