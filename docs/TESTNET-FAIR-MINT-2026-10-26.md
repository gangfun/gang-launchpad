# 测试网 · 打新发射部署与整轮记录

> **已废弃（2026-10-26）**：这一套核心没有路由入口，现行测试网部署见 `docs/TESTNET-CORE-ROUTER-2026-10-26.md`。下面的整轮记录仍然有效（核心原有路径没有改）。

- 日期：2026-10-26 Asia/Shanghai
- 链：BSC 测试网（chainId 97），PancakeSwap V2 测试网工厂 / 路由
- 代码：`feat/fair-mint` 提交 bd38caa（打新 / 撤出手续费分开设；含审计 G-01 修复）
- 部署 / owner / keeper：`0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`
- 规格：`docs/SPEC-FAIR-MINT-2026-10-26.md`

## 合约

| 合约 | 地址 |
|---|---|
| FairMintPad | [`0x6B0ECAAe1Cf9A733ab98F2ad90A4d48c9a7790A3`](https://testnet.bscscan.com/address/0x6B0ECAAe1Cf9A733ab98F2ad90A4d48c9a7790A3)（部署区块 138988909） |
| HolderRewardHandler | [`0xFC1Ef57D60C3B1d1037961e99FdBd563A2dF0de8`](https://testnet.bscscan.com/address/0xFC1Ef57D60C3B1d1037961e99FdBd563A2dF0de8) |
| DividendVault（打新专用，底线 10,000 枚） | [`0xde842f9A337Fb5cd439791E7C744651957f2a427`](https://testnet.bscscan.com/address/0xde842f9A337Fb5cd439791E7C744651957f2a427) |
| MigratorV2 | [`0x2d2553F43920417F6a2f60d7650d7485DBB721a1`](https://testnet.bscscan.com/address/0x2d2553F43920417F6a2f60d7650d7485DBB721a1) |
| FairTokenDeployer | [`0x864B0Dc900e742197c3e73B0e7c105E161Cc9A39`](https://testnet.bscscan.com/address/0x864B0Dc900e742197c3e73B0e7c105E161Cc9A39) |
| QuoteRegistry | [`0x837F04F5Ada8c9479eDaEFF54f483a4Fc3d66266`](https://testnet.bscscan.com/address/0x837F04F5Ada8c9479eDaEFF54f483a4Fc3d66266) |
| PlatformFeeBucket | [`0xDb1616557415Aa621f6B8F37DfB48c1870fa36EC`](https://testnet.bscscan.com/address/0xDb1616557415Aa621f6B8F37DfB48c1870fa36EC) |
| TestnetAgentId（灵魂绑定，自助 `register()`） | [`0x24D0A2106AC3Ebf7d770d19f4aF0a5149ebe5B2a`](https://testnet.bscscan.com/address/0x24D0A2106AC3Ebf7d770d19f4aF0a5149ebe5B2a) |
| 测试报价币 MockSPCXB（`mint(to, amount)` 每地址上限 1000） | [`0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c`](https://testnet.bscscan.com/address/0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c) |
| PoolCheck（library，CREATE2） | [`0xEDc4532A7637Ca70553F988246619a8f9fE6b6d2`](https://testnet.bscscan.com/address/0xEDc4532A7637Ca70553F988246619a8f9fE6b6d2) |

QuoteRegistry 里测试报价币的覆盖值 = 15 枚 / 15 BNB，所以募集 15 BNB 的币按 15 枚测试币募集，每份 0.0015 枚。

## 整轮记录（测试代币 FAIRT，打新 1% / 撤出 1%）

| 步骤 | 交易 |
|---|---|
| 代币 `0x56C60541b59977FF8220c96594C260CdD9df4Af2`，池子 `0xdd701e5B977F4940E4183771678abb980D968F0d` | — |
| 创建（dev 自打 1 份） | [`0x7e69…31ab`](https://testnet.bscscan.com/tx/0x7e69f35102c95f43a0494fe41fb822022ad18eca69c53f1b33e96e5d0c5e31ab) |
| 第 100 个地址打满并发射（建池，约 250 万 gas） | [`0xe8c5…1552`](https://testnet.bscscan.com/tx/0xe8c5e3a3e61c777bb61c64f88d6923d5411e0a30bd50b55b43f9d49029b31552) |
| 开盘买入 3 枚测试币 | [`0x8e84…84b4`](https://testnet.bscscan.com/tx/0x8e84b772f3336f8a9e8f0bb8f0cfd4fe0034a84f11d3864a5529c576f0bb84b4) |
| minter 0 卖出 55%（出局） | [`0x4a6e…cd06`](https://testnet.bscscan.com/tx/0x4a6e886f7fe5914b0d8c23d3470e254fdbe58276acd57b4484d9743b9530cd06) |
| keeper `process` 分账 | [`0x8cb5…6559`](https://testnet.bscscan.com/tx/0x8cb5aea373927b81d57b15a0f6732d90bf9e043bc71ad09b5231fd55dcff6559) |
| minter 5 领奖励 | [`0x39fa…733e`](https://testnet.bscscan.com/tx/0x39fae847b267b255acf68aa697d8d66480fd1b54c4210f33d48197685bb6733e) |

510 笔全部成功：税换回 0.03649 枚，持有人 / 平台各一半；minter 5 领取 0.000184 枚（100 份 / 9,900 合格份）；平台累计 0.16824 = 打新手续费 0.15 + 税的一半。

## 费率分开设（测试代币 FST，打新 1% / 撤出 2%）

代币 [`0xc81c3a8f5289641d76b27194a0365ccc5edff2d5`](https://testnet.bscscan.com/address/0xc81c3a8f5289641d76b27194a0365ccc5edff2d5)，72 小时，开放中。交易都由 `gang fair … --calldata` 生成、cast 发送：

| 步骤 | 实际 | 应为 |
|---|---|---|
| 创建（`--mint-fee 1 --exit-fee 2`，dev 自打 5 份） | `gang fair info` 读出 `mintFeePct: 1`、`exitFeePct: 2` | — |
| 打新 10 份 | 付 0.01515 | 10 × 0.0015 × 1.01 = 0.01515 |
| 撤出 4 份 | 收 0.00588 | 4 × 0.0015 × 0.98 = 0.00588 |

## 花费

| 项 | tBNB |
|---|---|
| 部署（20 笔） | 0.0011 |
| 整轮（510 笔） | 0.0043 gas + 0.0109 预付给打新地址（每个 0.0001） |
| 费率测试（4 笔） | < 0.0001 |

## 已废弃（不要再用）

| 部署 | FairMintPad | 原因 |
|---|---|---|
| 第 1 套 | `0xa23e88EF1AE6A71E797Dc1191F135F4F92bf8cc9` | 审计 G-01 修复之前 |
| 第 2 套 | `0x2f45c4814A540B0F6E9A25497DEc7B8C6CAA8963` | 手续费固定 1%，`Created` 事件和 `sales()` 字段与现版本不同 |

## 踩坑

1. 不显式给 gas 价格时，forge 有一次拿到 1 wei 的估价，交易卡在交易池里。测试网命令一律加 `--with-gas-price 100000000 --priority-gas-price 100000000`。
2. 脚本里路由交易的截止时间在模拟时就定死了，而 500 多笔交易逐笔广播要十几分钟，第一次的开盘买入因此过期失败。现在截止时间改为 1 天；脚本也支持 `TOKEN=<已发射的代币>`，只跑买卖之后的步骤。
3. 整轮脚本要在本地模拟 500 多笔交易、耗时数分钟：BNB Chain 官方测试网节点（data-seed-prebsc）只保留很短的状态，会报 `missing trie node`；publicnode 能跑完但偶尔超时 / TLS 断开。用 publicnode，失败时先确认部署钱包 nonce 没动（没广播）再重跑。单笔交易和 CLI 读链用官方节点更稳。
