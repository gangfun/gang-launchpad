# 测试网第 8 套 · 合并后的合约（一个内盘）

> 模板：地址、区块、提交号、整轮结果都还没填（标【待填】）。部署完成后照第 7 套的格式补齐，再把 CLI 的 `TESTNET_SET8` 填上（见文末）。

- 日期：2026-10-27 Asia/Shanghai
- 链：BSC 测试网（chainId 97）
- 代码：`main` 的 【待填：提交号】。和第 7 套相比：
  - V3 内盘不收税，只收 1% 手续费；金库删掉内盘分红路径（审计说明 §19）；
  - 合约合并：V3 和打新共用一个内盘 `GangLaunchpad`（外部库 `CurveLogic` / `FairLogic`）、一个外盘处理合约 `GangTaxHandler`、一种代币 `GangToken`、一个 `GangRouter`（审计说明 §20，规格 `docs/SPEC-GANG-MERGED-2026-10-27.md`）。
- 部署 / owner / keeper：【待填】
- 部署脚本：【待填：脚本名和命令，以 `feat/merge-scripts` 为准】
- 取代第 7 套（`docs/TESTNET-SET7-2026-10-27.md`）。第 7 套的两个内盘不再更新，CLI 在填好第 8 套之前仍指向第 7 套。

## 合约

| 合约 | 地址 | 部署区块 |
|---|---|---|
| GangLaunchpad（V3 + 打新） | 【待填】 | 【待填】 |
| ├ CurveLogic（库） | 【待填】 | |
| ├ FairLogic（库） | 【待填】 | |
| ├ GangTaxHandler | 【待填】 | |
| └ 黑名单报价币 tBUSD（测试欠款用） | 【待填】 | |
| GangRouter | 【待填】 | 【待填】 |
| QuoteRegistry | 【待填】 | |
| SharedPlatformFeeBucket | 【待填】 | |
| SharedDividendVault | 【待填】 | |
| SharedMigrator | 【待填】 | |
| TokenDeployer（保留时；改用 TokenFactory 库时填库地址） | 【待填】 | |
| PoolCheck（库，测试网） | 【待填】 | |

部署交易：【待填：笔数、是否全部成功、有无重发】

各合约运行时字节（`forge build --sizes`，同审计说明 §20.8）：

| 合约 | 字节 |
|---|---|
| GangLaunchpad | 【待填】 |
| CurveLogic | 【待填】 |
| FairLogic | 【待填】 |
| GangTaxHandler | 【待填】 |
| GangToken | 【待填】 |
| GangRouter | 【待填】 |

## 链上自检

按运行手册 §2 跑一遍，记下结果：

- [ ] 各合约 owner / pendingOwner 正确
- [ ] `GangTaxHandler.launchpad()` = 内盘；`SharedDividendVault.operatorFor(内盘)` = 处理合约
- [ ] 手续费池 operator 只有内盘和处理合约两个
- [ ] `GangRouter.v3()` = `GangRouter.fair()` = 内盘；内盘 `routers(GangRouter)` = true
- [ ] `TAXED_MIN_SHARE` = `MIN_SHARE_BALANCE` = 10,000 枚
- [ ] 内盘 `kindOf`：V3 币 1、打新币 2、其它地址 0

服务端配置（两组填同一个地址、同一个区块）：

```
V3_PADS=v3t8:<内盘>@<区块>
FAIR_PADS=fairt8:<内盘>@<区块>
GANG_V3_PAD=<内盘>    GANG_V3_START_BLOCK=<区块>
GANG_FAIR_PAD=<内盘>  GANG_FAIR_START_BLOCK=<区块>
```

## 公开整轮

- **V3 有税（有分红、有接收地址）**
  - 币：【待填】，交易对：【待填】
  - [ ] 内盘买卖只扣 1%：`Buy` / `Sell` 的 `tax` = 0，接收地址、金库、处理合约收不到报价币
  - [ ] 打满毕业；外盘先买后卖，卖出时顺带换了一块（`TaxChunkSold`）
  - [ ] 接收地址收到 `TaxPaid`；持有人 `pendingUnits` 在交税时增加、这批卖完后转成可领 `pending`
- **V3 无税**
  - 币：【待填】
  - [ ] 毕业后没有设 pair；池子买卖不调用处理合约
- **V3 接收地址被拉黑**
  - 币：【待填】
  - [ ] 推送失败记为欠款（`TaxOwed`），金额：【待填】
- **打新**
  - 币：【待填】，交易对：【待填】
  - [ ] 打新、卖回（到手 = `previewWithdraw`）、打满发射，池子开盘价 = 打新价
  - [ ] 外盘卖出顺带换块 / keeper `process` 补位，`OuterTaxProcessed`（打新版，6 个字段）
  - [ ] 一个打新地址卖到线下被取消资格（`Disqualified`）；另一个地址领到奖励，金额：【待填】
- **跨种类**
  - [ ] 同一个 WBNB 下，V3 曲线买卖和打新卖回交替进行，内盘的 WBNB 余额 = 未发射 sale 本金 + `owedFee` + 未毕业曲线 `realQuote`（+ 零头）
  - [ ] 对 V3 币调 `withdraw`、对打新币调 `buy` 都回滚
  - [ ] CLI：`gang v3 info --token <打新币> --testnet` 提示改用 `gang fair`，反过来也一样
- **路由**
  - [ ] 用 BNB 经 GangRouter 买 V3、打新各一笔，结束后路由余额为 0
- **keeper**
  - [ ] 干跑一次 `keeper-tax-process.sh`：处理合约只出现一次；份额补写循环按 `kindOf` 分开

遇到的问题：【待填】

## 填完之后

1. CLI：`skill/gang-cli/src/gangpad.js` 里填 `TESTNET_SET8 = { pad: '<内盘>', router: '<GangRouter>' }`，测试网就切到第 8 套（第 7 套的地址留作兼容，确认无误后可删）。
2. 服务端测试站的 `V3_PADS` / `FAIR_PADS` / `GANG_*_PAD` 换成上面的配置，重启索引器后核对 `/v3/config`、`/fair/config` 的地址相同。
3. 把本文顶部的「模板」提示删掉。
