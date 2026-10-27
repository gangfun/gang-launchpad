# 测试网第 7 套 · 第五轮修复 review 之后的最终代码

- 日期：2026-10-27 Asia/Shanghai
- 链：BSC 测试网（chainId 97）
- 代码：`feat/swapback` 的 `c4c25ec`。和第 6 套相比，多了下面这些修复（审计说明 §18）：
  - 卖出时换块，池子有多出的余额时先 skim 收走，卖完这一块再原样退回；
  - 闪电兑换写法的卖出直接回滚 `SellDuringFlashSwap`；
  - keeper 只能设一次；
  - 用 7702 委托的钱包不能被排除出分红；
  - 部署脚本加强了对 peer core 的核对。
- 部署 / owner / keeper：`0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`
- 取代第 6 套（`docs/TESTNET-SET6-2026-10-27.md`），第 6 套已废弃。

## 合约

| 合约 | 地址 | 部署区块 |
|---|---|---|
| LaunchpadV3 | `0x771b6dAA5240e3Cc0F0819535E8200774AFedEED` | 139152847 |
| ├ TaxHandlerV3 | `0xda01dABd94923483Bfb69545375836A7f4C25642` | |
| └ 黑名单报价币 tBUSD | `0xcd691cE70262442C83cb973Ec420697EaaC8c679` | |
| FairMintPad | `0xF45C221cF453d3943b00F905f66d66e34380956A` | 139155431 |
| └ HolderRewardHandler | `0xba5effd817548597E4Abf937d565C0E6D75Aa651` | |
| GangRouter | `0x9dBb3D25Ff5c8107814fBD96A88D6eD015dfA279` | 139155542 |
| QuoteRegistry（共用） | `0xCb15F0E85a0cC0885551C5E765D0A8338C925cCD` | |
| SharedPlatformFeeBucket（共用） | `0xA3b9b92e82Eebe8D604d931b09e72cdc1377325F` | |
| SharedDividendVault（共用） | `0xed0B49BbE339dFD52d138591d602e61a2C3edD53` | |
| SharedMigrator（共用） | `0x9b12dDC19651752084f33c7C11D4ADb0469eF99b` | |
| TokenDeployer（共用） | `0x7A95877B6541f7a9801d27B49F23BEb579AE873E` | |

43 笔部署交易全部成功。打新的第一次部署在发出前就停了：节点返回 `nonce changed unexpectedly`，一笔都没上链。之后重新部署成功，所以打新的部署区块比 V3 晚。

服务端配置：

```
V3_PADS=v3t7:0x771b6dAA5240e3Cc0F0819535E8200774AFedEED@139152847
FAIR_PADS=fairt7:0xF45C221cF453d3943b00F905f66d66e34380956A@139155431
GANG_V3_PAD=0x771b6dAA5240e3Cc0F0819535E8200774AFedEED    GANG_V3_START_BLOCK=139152847
GANG_FAIR_PAD=0xF45C221cF453d3943b00F905f66d66e34380956A  GANG_FAIR_START_BLOCK=139155431
```

## 公开整轮

- **V3**
  - 币 A：`0xEF42a7A40306Cc57017702af2648C63363cd38af`，交易对 `0x93A637723DEcE5b409b90a41Fc088D1546aaEd4E`。内盘买卖后打满毕业，外盘先买后卖，卖出时顺带换了一块。
  - 币 B：`0xAB9B1AD5034BC9FceA7ea9870Bd8def5C206ae13`。接收地址被拉黑时，推送失败的部分记为欠款，共 731731113206935。
- **打新**
  - 币 `0xAA89B214Df97Cd4D4e522D90534111418A1f6C19`，交易对 `0xFf6269A421a9Fe105224237cd75Dce9bC97b179E`。
  - 100 个地址打满后发射。外盘有一笔买入；一个打新地址卖到线下，被取消资格。
  - 换税两次，`OuterTaxProcessed` 和 `TaxChunkSold` 各 2 条：一次是卖出时顺带换，一次是 keeper `process` 补位。两次合计换回 0.007288，处理合约上已经没有待卖的税。
  - 第 5 个打新地址领取 0.000184。
  - 第一次跑整轮时，data-seed 节点在本地预执行阶段报 `missing trie node`，还没发出交易；改用 publicnode 后跑通。
