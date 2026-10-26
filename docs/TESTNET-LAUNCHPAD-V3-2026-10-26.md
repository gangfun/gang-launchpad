# 测试网 · LaunchpadV3（税收接收地址）部署与整轮记录

- 日期：2026-10-26 Asia/Shanghai
- 链：BSC 测试网（chainId 97），PancakeSwap V2 测试网工厂 / 路由
- 代码：`feat/v3-tax-recipient`，合约为提交 53e536d；脚本 `script/DeployLaunchpadV3.s.sol`、`script/LaunchpadV3TestnetE2E.s.sol`
- 部署 / owner / keeper：`0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`
- 规格：`docs/SPEC-V3-TAX-RECIPIENT-2026-10-26.md`

## 合约

| 合约 | 地址 |
|---|---|
| LaunchpadV3 | [`0xFFE9a823FbA62d0a77d4f8bB83965299b5664395`](https://testnet.bscscan.com/address/0xFFE9a823FbA62d0a77d4f8bB83965299b5664395)（部署区块 139006483） |
| TaxRouterV3 | [`0x6a4a00119e7B3334a2681EE26302be6a0Ae5e5F6`](https://testnet.bscscan.com/address/0x6a4a00119e7B3334a2681EE26302be6a0Ae5e5F6) |
| RecipientRegistry（接收地址白名单） | [`0x1754E5BC9f48282D042D8964190De81376BdfbCB`](https://testnet.bscscan.com/address/0x1754E5BC9f48282D042D8964190De81376BdfbCB) |
| PostGradTaxHandlerV3 | [`0x1910ccD962A854430e0B8611EE9d87aF0D5dfE1A`](https://testnet.bscscan.com/address/0x1910ccD962A854430e0B8611EE9d87aF0D5dfE1A) |
| DividendVault（V3 专用，底线 10,000 枚） | [`0xFED69B0E29dbdcDE254307f18ac1E64Ee9482768`](https://testnet.bscscan.com/address/0xFED69B0E29dbdcDE254307f18ac1E64Ee9482768) |
| MigratorV2 | [`0xFCc0Ef4ff64AFa8C153D60C99D36dEac6ff3075C`](https://testnet.bscscan.com/address/0xFCc0Ef4ff64AFa8C153D60C99D36dEac6ff3075C) |
| TaxTokenDeployerV3 | [`0x289A19EF6c150dd52be256dD5b54dd0501441773`](https://testnet.bscscan.com/address/0x289A19EF6c150dd52be256dD5b54dd0501441773) |
| QuoteRegistry | [`0x4a7A9A4592fDC000299D471447CfbeDF160BE569`](https://testnet.bscscan.com/address/0x4a7A9A4592fDC000299D471447CfbeDF160BE569) |
| PlatformFeeBucket | [`0xDD649e7F74aD1719b81454D4612fCC062722836b`](https://testnet.bscscan.com/address/0xDD649e7F74aD1719b81454D4612fCC062722836b) |
| TestnetAgentId（与打新测试网共用） | [`0x24D0A2106AC3Ebf7d770d19f4aF0a5149ebe5B2a`](https://testnet.bscscan.com/address/0x24D0A2106AC3Ebf7d770d19f4aF0a5149ebe5B2a) |
| 测试报价币 MockSPCXB（与打新测试网共用） | [`0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c`](https://testnet.bscscan.com/address/0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c) |
| 黑名单报价币 tBUSD（`mint` 任何人可调，`setBlocked` 仅部署者） | [`0x67203AB0B5eC75296b988f289ACCe11DDab19399`](https://testnet.bscscan.com/address/0x67203AB0B5eC75296b988f289ACCe11DDab19399) |
| 演示金库（已加白名单；没人持有私钥，余额只会因收税增长） | [`0xe22eEE60677911Ef25a359285Fb09786AC728c77`](https://testnet.bscscan.com/address/0xe22eEE60677911Ef25a359285Fb09786AC728c77) |

QuoteRegistry 里两个测试报价币的覆盖值都是 15 枚 / 15 BNB，所以毕业线 ≈ 15 枚测试币。

测试网的 PlatformFeeBucket 只接了 pad 和 router 作为 operator，没有设 keeper / burner（测试网没有 GANG 回购），平台抽成只累计、不做回购；V3 税收流程不受影响。

## 整轮记录

两个测试代币都是买 2% / 卖 2%、持币分红 0、接收地址 = 演示金库，所以平台每笔拿成交额的 0.5%，金库拿 1.5%（税的 75%）。

| 步骤 | 交易 | 结果 |
|---|---|---|
| A 创建（V3T，测试报价币） `0xe01F90c2A78810381ecfa2d62c050f32212E08B6` | [`0x292e…1b7f`](https://testnet.bscscan.com/tx/0x292e0e10dcf968a4949cb1fc43c70db2b3df2d51791f0dafd0b33a69d24e1b7f) | `TaxConfigured` |
| A 内盘买 0.05 | [`0x1267…8aed`](https://testnet.bscscan.com/tx/0x1267b544fd591f4806b0fd065df04a21e648d6e1768475ee5b834d29d92b8aed) | `TaxPaid` 0.000731731 直接到金库 |
| A 内盘卖一半 | [`0x95d0…8af6`](https://testnet.bscscan.com/tx/0x95d017050865a81cb3db1356c0dbe8cc0e7b0d66b49f1b202befaafe63e08af6) | `TaxPaid` 到金库 |
| B 创建（V3O，黑名单报价币） `0x311947216EDc84f5a267C171Af788b74e19281C8` | [`0x4de4…f125`](https://testnet.bscscan.com/tx/0x4de464e4276dbbb0f56658d73405870dc779c7e8f6a7457a404806ef7560f125) | — |
| 拉黑金库后 B 内盘买 0.05 | [`0x2e78…9d98`](https://testnet.bscscan.com/tx/0x2e780217adf6e01a238350e2b6e91e0f77486e6aa9a7cb9ad03b156215a49d98) | 转账失败不回滚：`TaxOwed` 0.000731731，`owedOf(B)` 记账；随后解除拉黑 |
| 80 个 Agent 各买到 1% 上限，最后一笔毕业建池（约 245 万 gas），池子 `0x294967feAc7C12fe743e89D981F69f6A251213F5` | [`0x13ce…3324`](https://testnet.bscscan.com/tx/0x13ced7fef45423d21396224350f7078fffc7457d6ba45431addfda7985233324) | 内盘每笔 `TaxPaid` |
| A 外盘买 0.5 | [`0x6dc6…5982`](https://testnet.bscscan.com/tx/0x6dc67e1a1e00be970b7606e2e5dcf201f23c134c4a9fbff4c060924473a55982) | 税（本币）留在 handler |
| A 外盘卖一半 | [`0xfdbd…664d`](https://testnet.bscscan.com/tx/0xfdbd8627ead03c37f0ca5fff272c8d518bb562350dab5614f073f982ee30664d) | handler `accruedTax` 241,885.93 枚，其中平台部分 60,471.48（正好 25%） |

整轮 417 笔全部成功，共 4,192 万 gas。

## keeper（gangfun-server `keeper/keeper-tax-process.sh`）

```
TAX_HANDLERS=v3:0x1910ccD962A854430e0B8611EE9d87aF0D5dfE1A@139006483
TAX_ROUTERS=v3:0x6a4a00119e7B3334a2681EE26302be6a0Ae5e5F6@139006483
MIN_PROCESS_QUOTE=0.0001
```

先 dry-run（模拟通过），再 `--broadcast`：

| 步骤 | 交易 | 结果 |
|---|---|---|
| `process(A, 0.017692)`（预计换回 0.018240，滑点 3%，价格冲击 38bps） | [`0xd0f9…8137`](https://testnet.bscscan.com/tx/0xd0f9505961d1d07f59dba92b80940f04385ec96f56ab7d7de3e9f4df860e8137) | `TaxPaid` 0.013687 到金库（= 换回额 × 75%），其余进平台；`accruedTax(A)` 清零 |
| `release(B)` | [`0x862e…4e34`](https://testnet.bscscan.com/tx/0x862ebf6d8188eefdc0b94f92df5d23b68a9622fdc570934f0cd0a6140f694e34) | `TaxPaid` 0.000731731 tBUSD 到金库；`owedOf(B)` 清零 |

最后状态：金库 0.246369 测试报价币 + 0.000731731 tBUSD；平台 bucket 0.237245 测试报价币 + 0.000731731 tBUSD。

本地 fork 上先完整彩排过一遍（部署 25 笔、整轮 418 笔、keeper 两笔，结果与上表一致），才在测试网上广播。

## 花费

全部按 0.1 gwei 计。

| 项 | tBNB |
|---|---|
| 部署（25 笔，1,325 万 gas） | 0.001325 |
| 整轮：部署钱包自己的交易 | 0.000606 |
| 整轮：80 个买家各自的交易（从预付里扣） | 0.003587 |
| keeper（2 笔，31.6 万 gas） | 0.000032 |
| 回收（`sweep()`，80 笔转账，从预付里扣） | 0.000168 |
| 留在买家钱包的零头（每个 2× 转账费减去实际花掉的 1×） | 0.000168 |
| 合计（部署钱包余额 0.027647 → 0.021762） | 0.005885 |

预付 0.0075 里买家只烧掉了一半左右（毕业前最后 5 个各拿 10 倍，只有触发毕业那一笔真正用到），其余 0.003577 由 `sweep()` 收回。

## 复跑

```sh
# 部署（新的一套）
DEPLOYER_PRIVATE_KEY=… forge script script/DeployLaunchpadV3.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com \
  --broadcast --slow --with-gas-price 100000000 --priority-gas-price 100000000
# 整轮；中途失败可带 TOKEN_A / TOKEN_B 续跑（新 pad 上 allTokens(0) = A、allTokens(1) = B）
DEPLOYER_PRIVATE_KEY=… PAD=<V3_LAUNCHPAD> BLACKLIST_QUOTE=<BLACKLIST_QUOTE> \
  forge script script/LaunchpadV3TestnetE2E.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com \
  --broadcast --slow --with-gas-price 100000000 --priority-gas-price 100000000
# 整轮跑完后单独一次：把买家没烧完的 gas 钱收回部署钱包（读链上余额；不能和整轮放在同一次，模拟不扣 gas 会高估余额）
DEPLOYER_PRIVATE_KEY=… forge script script/LaunchpadV3TestnetE2E.s.sol --sig "sweep()" \
  --rpc-url https://bsc-testnet-rpc.publicnode.com --broadcast --slow --with-gas-price 100000000 --priority-gas-price 100000000
```

换 gas 价格时同时设 `GAS_PRICE_WEI`（默认 0.1 gwei），买家预付和回收预留都按它算。

踩坑同打新测试网（`docs/TESTNET-FAIR-MINT-2026-10-26.md`）：显式给 gas 价格；长脚本用 publicnode，不用官方 data-seed 节点；新部署钱包要先有测试网 Agent ID（整轮脚本会自己 `register()`）。
