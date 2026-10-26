# 测试网 · 核心 + 路由（LaunchpadV3 / 打新 / GangRouter）

- 日期：2026-10-26 Asia/Shanghai
- 链：BSC 测试网（chainId 97）
- 代码：`feat/core-router`（规格 `docs/SPEC-CORE-ROUTER-2026-10-26.md`）
- 部署 / owner / keeper：`0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`
- 这一套取代 `docs/TESTNET-LAUNCHPAD-V3-2026-10-26.md` 和 `docs/TESTNET-FAIR-MINT-2026-10-26.md` 里的部署（那两套核心没有 `buyFor` / `mintFor`，已废弃；整轮记录仍可参考）。Agent ID 注册表和测试报价币沿用原来的，注册过的钱包继续可用。

## 合约

| 合约 | 地址 |
|---|---|
| GangRouter | [`0x499F9a4417A0d547628bd75cd51C6663D69a2C81`](https://testnet.bscscan.com/address/0x499F9a4417A0d547628bd75cd51C6663D69a2C81)（两个核心都已 `setRouter`） |
| LaunchpadV3（核心） | [`0x3184c8E2E5049693f09D8Eb8EB6b06A5D46ee541`](https://testnet.bscscan.com/address/0x3184c8E2E5049693f09D8Eb8EB6b06A5D46ee541)（部署区块 139025639） |
| ├ TaxRouterV3 | `0x93ECb17d165748c21dBEe6F917e3c978E13f9D13` |
| ├ RecipientRegistry | `0xbA571a6F7C0b917f31C5E9b495dCAF03e758057E`（演示金库 `0xe22eEE60677911Ef25a359285Fb09786AC728c77` 已列入） |
| ├ PostGradTaxHandlerV3 | `0x0A83864755716db0B275C803C24e93e22a69Bc12` |
| ├ DividendVault | `0x5403f7Ee3346745fF72C1ea70eaC67EA00f7d78D` |
| ├ MigratorV2 / TaxTokenDeployerV3 | `0xf9095dA04857809433cCAA785F90671ed770b2ac` / `0xc332f59cD05031c513c2388e099760204b71C9cd` |
| ├ QuoteRegistry / PlatformFeeBucket | `0x886F90fEd09C444DE0BfcA3aF59209436FaFf2F3` / `0xbb50276c23F531BCaD03f7D63E16Fd09ddE685C6` |
| └ 黑名单报价币 tBUSD | `0xA03a4776C8f84634a4309A1404b683926cA1ed4b` |
| FairMintPad（核心） | [`0x4D26D94D52b7439FCb5777a7E36990e10d8105F8`](https://testnet.bscscan.com/address/0x4D26D94D52b7439FCb5777a7E36990e10d8105F8)（部署区块 139025782） |
| ├ HolderRewardHandler | `0xE64F670A4Bffb412A2C158E4D968C84bb9aad8a3` |
| ├ DividendVault | `0xBB984B676f318477AbF1b6920c36eeDA99AdA2CA` |
| ├ MigratorV2 / FairTokenDeployer | `0x3Edfa79b18118907D379F9e47f481dA5bc189EcF` / `0xb80890B41944e42715158B3Fb22824D31fb8c24a` |
| └ QuoteRegistry / PlatformFeeBucket | `0xFAe1496f2cC96e0E31C58518c26D8a5123A40f38` / `0x18f92fA16D82658e2Da27354Ad8D46e6fc9Fa87b` |
| TestnetAgentId（沿用） | `0x24D0A2106AC3Ebf7d770d19f4aF0a5149ebe5B2a` |
| 测试报价币 MockSPCXB（沿用） | `0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c` |

## 路由冒烟（`script/RouterTestnetSmoke.s.sol`）

| 步骤 | 交易 | 结果 |
|---|---|---|
| V3 发币 RV3（WBNB 报价，买 2% / 卖 2%，接收地址 = 演示金库） `0xE13c9507F3bD8239271EcBD3c9ce4ca5DdB8d7c0` | [`0x3bf8…12f0`](https://testnet.bscscan.com/tx/0x3bf8aee72ed26e44473fbe824f2ababa23cd66e43939ad269556e56de8eb12f0) | — |
| `router.v3BuyBNB` 0.002 BNB | [`0x307b…baad`](https://testnet.bscscan.com/tx/0x307bd16abebeb4a423dbc019a32e23b13e7d0a40f35f444eb481ddaea35ebaad) | 413,706 枚到交易者本人，路由余额 0 |
| 打新发起 RFT（WBNB，募集 5 BNB，dev 1 份直接付给核心） `0xAB02C502d8f5Bd5f3D53cb8af3d2F5f6f61C719c` | [`0xcc6e…a1f2`](https://testnet.bscscan.com/tx/0xcc6e593c1917f68ca24932673ac46ecf6c071df5b3a7565926b37cd14f97a1f2) | — |
| `router.fairMintBNB` 2 份，发 0.002 BNB | [`0x8f64…c0e2`](https://testnet.bscscan.com/tx/0x8f641c738ce7aa2cb4ec1045eb39127ebc9aaac574346978401cf995adccc0e2) | 份额记在交易者名下（共 3 份），多发的 BNB 退回，路由余额 0 |

部署 46 笔 + 冒烟 6 笔全部成功，部署钱包 0.021534 → 0.015259 tBNB（含冒烟里转进合约的约 0.0045）。

毕业 / 发射 / 外盘税 / 补转这些核心流程的整轮这次只在测试网 fork 上跑（`LaunchpadV3TestnetE2E`、`FairMintTestnetE2E` 都通过，打新的税换回 0.03649、minter 5 领取 0.000184、平台累计 0.16824，与第一次测试网整轮一致），没有在测试网上再广播一遍：这两个核心只多了路由入口，原有路径的整轮已在旧部署上实测过，测试网钱包余额也不够再跑两轮。

## 复跑

```sh
G="--with-gas-price 100000000 --priority-gas-price 100000000"
forge script script/DeployLaunchpadV3.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com --broadcast --slow $G
forge script script/DeployFairMint.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com --broadcast --slow $G
V3_PAD=<V3_LAUNCHPAD> FAIR_PAD=<FAIR_MINT_PAD> forge script script/DeployGangRouter.s.sol --rpc-url … --broadcast --slow $G
V3_PAD=… FAIR_PAD=… GANG_ROUTER=… forge script script/RouterTestnetSmoke.s.sol --rpc-url … --broadcast --slow $G
```

`DeployFairMint` 在测试网默认沿用上面的 Agent ID 注册表和测试报价币（`NEW_MOCKS=true` 才新部署）；`FairMintTestnetE2E` 对已注册的打新钱包不再重复 `register()`。
