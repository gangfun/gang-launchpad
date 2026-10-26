# 测试网 · 核心 + 路由（LaunchpadV3 / 打新 / GangRouter）

- 日期：2026-10-27 Asia/Shanghai（第 4 套）
- 链：BSC 测试网（chainId 97）
- 代码：`main` 上的 `13da13b`，即审计说明的冻结点（两轮内部审计的修复、§12 代币权限收紧与元数据 JSON 地址、§13 外盘税合约加固）
- 部署 / owner / keeper：`0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`
- 这一套取代：
  - 第 3 套（`cf96281`）：V3 `0x2202…8330`、打新 `0x69bf…4F53`、路由 `0x1ABd…daE1`。`create` 还没有 `metaURI` 参数，已废弃。
  - 第 2 套（`36d8a7e`）：V3 `0x5D50…ce83`、打新 `0x5ef1…A1d7`、路由 `0x3B49…a57a`，已废弃。
  - 第 1 套（V3 `0x3184…e541`、打新 `0x4D26…05F8`、路由 `0x499F…2C81`）：审计前的代码，已废弃。
  - `docs/TESTNET-LAUNCHPAD-V3-2026-10-26.md`、`docs/TESTNET-FAIR-MINT-2026-10-26.md` 里的部署：没有路由入口，已废弃，整轮记录仍可参考。
- Agent ID 注册表和测试报价币沿用原来的，注册过的钱包继续可用。
- 测站 239 的索引服务已指向这一套（`/opt/gang-test/indexer.env`），网站 `/v3`、`/mint` 和行情（`?testnet=1`）显示的都是这一套的数据。

## 合约

| 合约 | 地址 |
|---|---|
| GangRouter | [`0x5627EeA369eEa6e4Cf50E67DabF1DF0ae75B13a5`](https://testnet.bscscan.com/address/0x5627EeA369eEa6e4Cf50E67DabF1DF0ae75B13a5)（两个核心都已 `setRouter`） |
| QuoteRegistry（共用） | `0x0c5032B957Bd0eFC288c29b4DCA6fBC6106702Bf`（已列入：测试报价币、黑名单报价币，各 15 枚 = 15 BNB） |
| PlatformFeeBucket（共用） | `0x18B38d973C16F0cc40F2cAdcF52c2405441Fe8e6`（operator：V3 核心、TaxRouterV3、打新核心、HolderRewardHandler） |
| LaunchpadV3（核心） | [`0x4B6a0E82E7357719D6204E5d6197Ef2C71E08dc4`](https://testnet.bscscan.com/address/0x4B6a0E82E7357719D6204E5d6197Ef2C71E08dc4)（部署区块 139070021） |
| ├ TaxRouterV3 | `0x47A1169e27d5C6E0D3772A8A2DdE20c176B2d43c` |
| ├ RecipientRegistry | `0x226Ef2c8702Dfcd27FE631Ce1aA5256f397561Cc`（演示金库 `0xe22eEE60677911Ef25a359285Fb09786AC728c77` 已列入） |
| ├ PostGradTaxHandlerV3 | `0x46e41011dBFF9A3A13935c3620077983E1d68821` |
| ├ DividendVault | `0x5caA76dF1Ed048264BA1032c590D384F7a73aCbF`（已排除 migrator） |
| ├ MigratorV2 / TaxTokenDeployerV3 | `0x5feE6e36F9fF86a7dBCECB072AfcCBd8103b7aB6` / `0x22b9F71Bc73E3B907FA76143c02FDEd67195938A` |
| └ 黑名单报价币 tBUSD | `0xe7b1Aa33bb3D31FD1e01f3Aa99f97C7fB6e01473` |
| FairMintPad（核心） | [`0xf1438254098aA1E0A6Ac58b204CfBa68A2383017`](https://testnet.bscscan.com/address/0xf1438254098aA1E0A6Ac58b204CfBa68A2383017)（部署区块 139070132） |
| ├ HolderRewardHandler | `0x91ae2C847733B935Fa8A72f2313dD1B979d4804F` |
| ├ DividendVault | `0x9b8587B968907eAC4407f09d1633116b9f42E240` |
| └ MigratorV2 / FairTokenDeployer | `0x792f84820730dd3793eA0f22C1D5273a1709aAf1` / `0x25b481Ea7FEb5725936865167E6523F09948ae97` |
| TestnetAgentId（沿用） | `0x24D0A2106AC3Ebf7d770d19f4aF0a5149ebe5B2a` |
| 测试报价币 MockSPCXB（沿用） | `0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c` |

部署 45 笔全部成功（V3 27 笔、打新 15 笔、路由 3 笔），部署记录里没有私钥。

## 路由冒烟（`script/RouterTestnetSmoke.s.sol`）

| 步骤 | 交易 | 结果 |
|---|---|---|
| V3 发币（WBNB 报价，买 2% / 卖 2%，接收地址 = 演示金库） RV3 `0x47ee6F30da4fab3078d95afd752FD8b159f446E1` | [`0x1f39…9e96`](https://testnet.bscscan.com/tx/0x1f39964dc30ce943433c75c4ad0ecc0593c793ecb6487dbaa56eaa1945e09e96) | 新的 `create`（带 `metaURI`） |
| `router.v3BuyBNB` 0.002 BNB | [`0x7cbe…7917`](https://testnet.bscscan.com/tx/0x7cbeb27344e9a3ea3b138efba65885277c78f8ce7680f62b96ac371d45547917) | 413,706 枚到交易者本人 |
| 打新发起（WBNB，募集 5 BNB，dev 1 份直接付给核心） RFT `0x570430cdD94BBC38ad45fdf5E822333Ac4aAb144` | [`0x8b1a…fca0`](https://testnet.bscscan.com/tx/0x8b1a74dca026752039b45311b541dd4f0c971954c653db07bd25e0d29fa0fca0) | — |
| `router.fairMintBNB` 2 份 | [`0x3155…af0c`](https://testnet.bscscan.com/tx/0x315530802a5e8f7a9ea1079662c02d4c59ca85c8b8d54d94f095de76f188af0c) | 份额记在交易者名下（共 3 份），多发的 BNB 退回 |

冒烟 6 笔全部成功，结束后路由的 BNB 和 WBNB 余额都是 0。

## 公网整轮（这一套第一次在公网测试网上跑完整轮）

| 整轮 | 结果 |
|---|---|
| `LaunchpadV3TestnetE2E`（加 `--skip-simulation`） | V3T `0x3AFc5f3a6f825A03145EBB8d790e043db866A2a4` 毕业（池子 `0xEA8270C5bd453D1cE1A4a6B8CFC3D8Ab59108D23`），外盘税累计 241,885.93 枚、平台部分 60,471.48 枚；演示金库收到 0.4793 测试报价币。V3O `0xa678eA7961eE7122f8146746DE6a4eEd2BBBAc9D`：接收地址被拉黑时记欠款 0.000732 tBUSD，解除拉黑后补发（[`0x807b…d1ee`](https://testnet.bscscan.com/tx/0x807bd8251eab9c4c339495810db3294b777e826de54bbf5fc624dca11106d1ee)），欠款归零、金库收到这笔 |
| `FairMintTestnetE2E` | FAIRT `0x5A79d4371f4d0B5Eb33630feCc609A9B0236865c`：100 个地址打满并发射（池子 `0xb865168e90db98BA01cfE29E6a9dfa1a36c13bdb`），外盘税换回 0.036488，minter 5 领取 0.000184，共用 bucket 累计 0.400927 |

两轮的关键数字与之前在本地 fork 上跑的完全一致。

V3 整轮要加 `--skip-simulation`，由节点逐笔估 gas。forge 默认在同一次模拟里估所有交易，这时存储已经被前面的交易「预热」过，池子卖出那一笔会估低、gas 不够。这是部署工具的问题，不是合约的问题。

## 复跑

```sh
G="--with-gas-price 100000000 --priority-gas-price 100000000"
R=https://bsc-testnet-rpc.publicnode.com
forge script script/DeployLaunchpadV3.s.sol --rpc-url $R --broadcast --slow $G           # 输出 QUOTE_REGISTRY / PLATFORM_BUCKET
QUOTE_REGISTRY=… PLATFORM_BUCKET=… forge script script/DeployFairMint.s.sol --rpc-url $R --broadcast --slow $G
V3_PAD=<V3_LAUNCHPAD> FAIR_PAD=<FAIR_MINT_PAD> forge script script/DeployGangRouter.s.sol --rpc-url $R --broadcast --slow $G
V3_PAD=… FAIR_PAD=… GANG_ROUTER=… forge script script/RouterTestnetSmoke.s.sol --rpc-url $R --broadcast --slow $G
PAD=<V3_LAUNCHPAD> BLACKLIST_QUOTE=… forge script script/LaunchpadV3TestnetE2E.s.sol --rpc-url $R --broadcast --skip-simulation --slow $G
PAD=<FAIR_MINT_PAD> TEST_QUOTE=… forge script script/FairMintTestnetE2E.s.sol --rpc-url $R --broadcast --slow $G
```

主网：每个脚本都要 `OWNER=<多签>`，第二个脚本必须在多签 `acceptOwnership()` 之前跑，之后 registry 和 bucket 就不再归部署钱包。`DeployFairMint` 在测试网默认沿用上面的 Agent ID 注册表和测试报价币（`NEW_MOCKS=true` 才新部署）。`FairMintTestnetE2E` 对已注册的打新钱包不再重复 `register()`。
