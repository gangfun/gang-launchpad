# 测试网 · 核心 + 路由（LaunchpadV3 / 打新 / GangRouter）

- 日期：2026-10-27 Asia/Shanghai（第 3 套）
- 链：BSC 测试网（chainId 97）
- 代码：`main` 上的 `cf96281`：两轮内部审计的修复，加上代币权限收紧和元数据 URI（审计说明 §12）
- 部署 / owner / keeper：`0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`
- 这一套取代：
  - 第 2 套（2026-10-26，`36d8a7e`）：V3 `0x5D50…ce83`、打新 `0x5ef1…A1d7`、路由 `0x3B49…a57a`。代币还带 `setTaxHandler` / `setPair` / `exclude`，已废弃。
  - 第 1 套（V3 `0x3184…e541`、打新 `0x4D26…05F8`、路由 `0x499F…2C81`）：审计前的代码，已废弃。
  - `docs/TESTNET-LAUNCHPAD-V3-2026-10-26.md`、`docs/TESTNET-FAIR-MINT-2026-10-26.md` 里的部署：没有路由入口，已废弃，整轮记录仍可参考。
- Agent ID 注册表和测试报价币沿用原来的，注册过的钱包继续可用。
- V3 和打新共用一份 QuoteRegistry 和 PlatformFeeBucket（`script/SharedPlatform.sol`）。报价币只收 WBNB 和这份白名单里设了固定换算额的 18 位币。所有接线完成后才 `setMigrator`。
- 代币：税处理合约在构造时写死；毕业或发射时 `unlock(migrator)`、`setPair` 各调一次，之后代币上没有任何管理函数；`contractURI()` / `metaURI()` 返回发币时传入的 URI。

## 合约

| 合约 | 地址 |
|---|---|
| GangRouter | [`0x1ABd2da0A7aB9eb4797FCC36a8aC19a42382daE1`](https://testnet.bscscan.com/address/0x1ABd2da0A7aB9eb4797FCC36a8aC19a42382daE1)（两个核心都已 `setRouter`） |
| QuoteRegistry（共用） | `0xD699BB0870de60b59DD25D55315A4c61559c864E`（已列入：测试报价币、黑名单报价币，各 15 枚 = 15 BNB） |
| PlatformFeeBucket（共用） | `0x58cbD53955F2CE9B094b10A0c2c50e1f33AddEe3`（operator：V3 核心、TaxRouterV3、打新核心、HolderRewardHandler） |
| LaunchpadV3（核心） | [`0x2202F7898e7e0b77d2Bb46d661d88d1Ffa7D8330`](https://testnet.bscscan.com/address/0x2202F7898e7e0b77d2Bb46d661d88d1Ffa7D8330)（部署区块 139064695） |
| ├ TaxRouterV3 | `0x3F3E788F5D8F6D1D47e10042e081C550711e9244` |
| ├ RecipientRegistry | `0xFb5ace56B524f05Bdf9C85101eaeC89b72fC24B2`（演示金库 `0xe22eEE60677911Ef25a359285Fb09786AC728c77` 已列入） |
| ├ PostGradTaxHandlerV3 | `0x21e169139bEF8158c66072cF72a9CbBBE44E0A16` |
| ├ DividendVault | `0xd844d5564d81c021Eff9B1B6E498bd61Efe62bf1`（已排除 migrator） |
| ├ MigratorV2 / TaxTokenDeployerV3 | `0x9f241cbA558e02f25c00F87B0B1e69dE14C8E58e` / `0xeD501c7De6F0E476dD632D37ea74E78fc0754BBe` |
| └ 黑名单报价币 tBUSD | `0x1CaC6F82f39975C1245c5D08d80FE63feeA1A456` |
| FairMintPad（核心） | [`0x69bfa8459b01e3705Aa8C0397557E537F2024F53`](https://testnet.bscscan.com/address/0x69bfa8459b01e3705Aa8C0397557E537F2024F53)（部署区块 139064796） |
| ├ HolderRewardHandler | `0x4e5EA2B32a41b1cCbec2E865BDc34841384E3Eeb` |
| ├ DividendVault | `0xd3C2cb58707e0FA97A86B3f4E0a39D140B1F80cf` |
| └ MigratorV2 / FairTokenDeployer | `0x7208720D7f9aC4f0F013119D88e48B7e6eE5c481` / `0x812405b06a528cEd099D557aC508f1E04dd52d29` |
| TestnetAgentId（沿用） | `0x24D0A2106AC3Ebf7d770d19f4aF0a5149ebe5B2a` |
| 测试报价币 MockSPCXB（沿用） | `0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c` |

部署 45 笔全部成功（V3 27 笔、打新 15 笔、路由 3 笔），部署记录里没有私钥。

## 路由冒烟（`script/RouterTestnetSmoke.s.sol`）

| 步骤 | 交易 | 结果 |
|---|---|---|
| V3 发币（WBNB 报价，买 2% / 卖 2%，接收地址 = 演示金库） `0x37FdD2ce57e35Ece0c172736C347ECec10aAcb6B` | [`0x38e8…3c84`](https://testnet.bscscan.com/tx/0x38e854f9322279dbbdd219773640285d1661bc6e3d3d3416373e553aab693c84) | `taxHandler()` = 上面的 PostGradTaxHandlerV3 |
| `router.v3BuyBNB` 0.002 BNB | [`0xbaee…40f7`](https://testnet.bscscan.com/tx/0xbaee0225cf682640781e4978f89f4a6450fe67e3a843a3a930d11430f3c940f7) | 413,706 枚到交易者本人，路由余额 0 |
| 打新发起（WBNB，募集 5 BNB，dev 1 份直接付给核心） `0xff44Ef8226e71ee22952aaaB1F19E74813FC9F8E` | [`0xb6d0…9542`](https://testnet.bscscan.com/tx/0xb6d02bc88c803db1b6046c522c952baa97fc76187c2dfb062aef01ab9e809542) | — |
| `router.fairMintBNB` 2 份 | **没发出去** | 部署钱包余额差约 0.0002 tBNB；补充测试币后补跑这一步 |

毕业、发射、外盘税、补发欠款的整轮在本地 anvil 测试网 fork 上跑过（同一套脚本，先 V3 再打新，共用 registry 和 bucket），`LaunchpadV3TestnetE2E`、`FairMintTestnetE2E` 都通过：
- 打新：税换回 0.036488，minter 5 领取 0.000184，与前几次整轮一致。
- V3：欠款、外盘累计税和平台部分与前几次一致。
- V3 整轮要加 `--skip-simulation`，由节点逐笔估 gas。forge 默认在同一次模拟里估所有交易，存储已经被前面的交易「预热」过，池子卖出那笔会估低，导致 gas 不够。这是部署工具的问题，不是合约的。

## 复跑

```sh
G="--with-gas-price 100000000 --priority-gas-price 100000000"
R=https://bsc-testnet-rpc.publicnode.com
forge script script/DeployLaunchpadV3.s.sol --rpc-url $R --broadcast --slow $G           # 输出 QUOTE_REGISTRY / PLATFORM_BUCKET
QUOTE_REGISTRY=… PLATFORM_BUCKET=… forge script script/DeployFairMint.s.sol --rpc-url $R --broadcast --slow $G
V3_PAD=<V3_LAUNCHPAD> FAIR_PAD=<FAIR_MINT_PAD> forge script script/DeployGangRouter.s.sol --rpc-url $R --broadcast --slow $G
V3_PAD=… FAIR_PAD=… GANG_ROUTER=… forge script script/RouterTestnetSmoke.s.sol --rpc-url $R --broadcast --slow $G
```

主网：每个脚本都要 `OWNER=<多签>`，第二个脚本必须在多签 `acceptOwnership()` 之前跑，之后 registry 和 bucket 就不再归部署钱包。`DeployFairMint` 在测试网默认沿用上面的 Agent ID 注册表和测试报价币（`NEW_MOCKS=true` 才新部署）。`FairMintTestnetE2E` 对已注册的打新钱包不再重复 `register()`。
