# 测试网 · 打新发射部署与整轮记录

- 日期：2026-10-26 Asia/Shanghai
- 链：BSC 测试网（chainId 97），PancakeSwap V2 测试网工厂 / 路由
- 代码：`feat/fair-mint` 提交 7d06b8a（含审计 G-01 修复）
- 部署 / owner / keeper：`0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`
- 规格：`docs/SPEC-FAIR-MINT-2026-10-26.md`

## 合约

| 合约 | 地址 |
|---|---|
| FairMintPad | [`0x2f45c4814A540B0F6E9A25497DEc7B8C6CAA8963`](https://testnet.bscscan.com/address/0x2f45c4814A540B0F6E9A25497DEc7B8C6CAA8963) |
| HolderRewardHandler | [`0xb428C7797f095b72ce0ed4edbB4B4db0d7572347`](https://testnet.bscscan.com/address/0xb428C7797f095b72ce0ed4edbB4B4db0d7572347) |
| DividendVault（打新专用，底线 10,000 枚） | [`0xB143DfbE8231159243B77b68237eBB45573C8df8`](https://testnet.bscscan.com/address/0xB143DfbE8231159243B77b68237eBB45573C8df8) |
| MigratorV2 | [`0xDa16595DD52D3c2a6db348e2a313F27fB0fAAB4D`](https://testnet.bscscan.com/address/0xDa16595DD52D3c2a6db348e2a313F27fB0fAAB4D) |
| FairTokenDeployer | [`0x6eEa8Ce2dAF324d3ffdaE79CE1C1A45a483D1174`](https://testnet.bscscan.com/address/0x6eEa8Ce2dAF324d3ffdaE79CE1C1A45a483D1174) |
| QuoteRegistry | [`0x801322aa4BD1cCb22266BDc73854397943f8581A`](https://testnet.bscscan.com/address/0x801322aa4BD1cCb22266BDc73854397943f8581A) |
| PlatformFeeBucket | [`0xF15a57F93aE3953B958cC4E11D9A553A0bbA6BE4`](https://testnet.bscscan.com/address/0xF15a57F93aE3953B958cC4E11D9A553A0bbA6BE4) |
| TestnetAgentId（灵魂绑定，自助 `register()`） | [`0x0707da8FC2eb4055B1E2e84E211f22faA35C4606`](https://testnet.bscscan.com/address/0x0707da8FC2eb4055B1E2e84E211f22faA35C4606) |
| 测试报价币 MockSPCXB（`mint(to, amount)` 每地址上限 1000） | [`0xc3F3fe3383939759e39E9f55A5F1e7b113ee26ce`](https://testnet.bscscan.com/address/0xc3F3fe3383939759e39E9f55A5F1e7b113ee26ce) |
| PoolCheck（library，CREATE2） | [`0xEDc4532A7637Ca70553F988246619a8f9fE6b6d2`](https://testnet.bscscan.com/address/0xEDc4532A7637Ca70553F988246619a8f9fE6b6d2) |

QuoteRegistry 里测试报价币的覆盖值 = 15 枚 / 15 BNB，所以募集 15 BNB 的币按 15 枚测试币募集，每份 0.0015 枚。

## 整轮记录（测试代币 FAIRT）

| 步骤 | 交易 |
|---|---|
| 代币 `0xf4FCefA7E655AF18A50982bcE6A6a442CDF67F21`，池子 `0xa790B91f036FE46aA0068DB5DAF43762463B59AE` | — |
| 创建（dev 自打 1 份） | [`0xd840…9958`](https://testnet.bscscan.com/tx/0xd84017ab29c7f754e87873b7f56fdb86596266fa1d6cb336ef19a4313cc89958) |
| 第 100 个地址打满并发射（建池，约 250 万 gas） | [`0xec4d…702d`](https://testnet.bscscan.com/tx/0xec4db720c34db647e4292da0de215b6d450c285b28f99f7f5d0117908e4b702d) |
| 开盘买入 3 枚测试币 | [`0x3396…be734`](https://testnet.bscscan.com/tx/0x33962b154638189845dd999b554ade582157ec20a287cc52fc0531bec91be734) |
| minter 0 卖出 55%（出局） | [`0x5a8e…a9a9`](https://testnet.bscscan.com/tx/0x5a8ef9f8105bbc0c6229a6ee1ca29e3353c873c723b1a22c5a987401ef1da9a9) |
| keeper `process` 分账 | [`0x3cdb…055a`](https://testnet.bscscan.com/tx/0x3cdbc2342b519aa720299f1e18469acb8712f1ad5ee93157909ed75cfdd5055a) |
| minter 5 领奖励 | [`0xdd2a…bc89`](https://testnet.bscscan.com/tx/0xdd2a9c28871b44a4a611f83f53669d229d002a3ba890f0a820788815d1a4bc89) |

链上核对（整轮结束后用 `cast` 读）：

| 项 | 结果 |
|---|---|
| 状态 | Launched；代币已解锁；taxHandler = HolderRewardHandler |
| LP | 除 Pancake 固定锁住的 1000 份外全部在 0xdead |
| minter 0 | 持仓 225 万（45%），`isOut = true`，份额 0 |
| minter 5 | 份额 500 万（满额），领取 0.000184 枚，待领 0 |
| 合格份额总计 | 4.95 亿 = 9,900 份 × 5 万（minter 0 已出局） |
| 分账 | 税换回 0.03649 枚：持有人 0.01824 / 平台 0.01824；分红合约余额 = 0.01824 − 已领 0.000184 |
| 平台累计 | 0.16824 = 打新手续费 0.15 + 税的一半 |

## 花费

| 项 | tBNB |
|---|---|
| 部署（20 笔） | 0.0011 |
| 建币 + 100 个地址打满（505 笔） | 0.0042 gas + 0.0218 预付给打新地址 |
| 买卖 / 分账 / 领取（6 笔） | 0.0001 |

## 已废弃

修复审计 G-01 之前部署过一套（FairMintPad `0xa23e88EF1AE6A71E797Dc1191F135F4F92bf8cc9`），没有跑整轮，不要再用。

## 踩坑

1. 不显式给 gas 价格时，forge 有一次拿到 1 wei 的估价，交易卡在交易池里。测试网命令一律加 `--with-gas-price 100000000 --priority-gas-price 100000000`。
2. 脚本里路由交易的截止时间在模拟时就定死了，而 500 多笔交易逐笔广播要十几分钟，第一次的开盘买入因此过期失败。现在截止时间改为 1 天；脚本也支持 `TOKEN=<已发射的代币>`，只跑买卖之后的步骤。
