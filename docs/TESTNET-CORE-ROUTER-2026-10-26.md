# 测试网 · 核心 + 路由（LaunchpadV3 / 打新 / GangRouter）

- 日期：2026-10-26 Asia/Shanghai
- 链：BSC 测试网（chainId 97）
- 代码：`feat/core-router`，含内部审计的修复（规格 `docs/SPEC-CORE-ROUTER-2026-10-26.md`，审计 `docs/AUDIT-BRIEF-2026-10-26.md` §10）
- 部署 / owner / keeper：`0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`
- 这一套（第 2 套核心 + 路由）取代：
  - 同日第 1 套核心 + 路由（V3 `0x3184…e541`、打新 `0x4D26…05F8`、路由 `0x499F…2C81`）：审计前的代码，已废弃。
  - `docs/TESTNET-LAUNCHPAD-V3-2026-10-26.md`、`docs/TESTNET-FAIR-MINT-2026-10-26.md` 里的部署（没有路由入口，已废弃；整轮记录仍可参考）。
- Agent ID 注册表和测试报价币沿用原来的，注册过的钱包继续可用。
- 与上一套的不同：V3 和打新**共用一份新的 QuoteRegistry 和 PlatformFeeBucket**（`script/SharedPlatform.sol`）；报价币只收 WBNB 和这份白名单里的 18 位币；所有接线做完之后才 `setMigrator`（核心从这一刻起可用）。

## 合约

| 合约 | 地址 |
|---|---|
| GangRouter | [`0x3B497A335432f4A3f761063e44eb58D15F7fa57a`](https://testnet.bscscan.com/address/0x3B497A335432f4A3f761063e44eb58D15F7fa57a)（两个核心都已 `setRouter`） |
| QuoteRegistry（共用） | `0x9d4f74a6cf79fC60715ca4E549BB8CC3E4C7F556`（已列入：测试报价币、黑名单报价币，各 15 枚 = 15 BNB） |
| PlatformFeeBucket（共用） | `0xe492F9B8237b8b4A37760324811af4F44548C8A4`（operator：V3 核心、TaxRouterV3、打新核心、HolderRewardHandler） |
| LaunchpadV3（核心） | [`0x5D5068d11Cc3c768dc0Cc8F460a5593F5b76ce83`](https://testnet.bscscan.com/address/0x5D5068d11Cc3c768dc0Cc8F460a5593F5b76ce83)（部署区块 139051852） |
| ├ TaxRouterV3 | `0x2C6074D6911c162727e61940854137586A7B0199` |
| ├ RecipientRegistry | `0xD9A89f0FA0721a02C8db0c8Cf97D95FF4C4c53a6`（演示金库 `0xe22eEE60677911Ef25a359285Fb09786AC728c77` 已列入） |
| ├ PostGradTaxHandlerV3 | `0x8F1cE9c247BD9d4294e89BA6F894444576c02811` |
| ├ DividendVault | `0x9a73c7cFBe0dfAF649c106CAf77315945Be77780` |
| ├ MigratorV2 / TaxTokenDeployerV3 | `0x311Bd7180FeD284F1821ecC2168e37ae5460e5E1` / `0x0f1D7633c4D504e0696489E5164b188976293a90` |
| └ 黑名单报价币 tBUSD | `0x1D95440D1513f79BC366594BA7Afc6191e2Bd840` |
| FairMintPad（核心） | [`0x5ef164cc3A812a5892Ed6ab33e7754339dFcA1d7`](https://testnet.bscscan.com/address/0x5ef164cc3A812a5892Ed6ab33e7754339dFcA1d7)（部署区块 139051953） |
| ├ HolderRewardHandler | `0x2088bb02b81dd19cBe06Eee0A6A88111F6883cc4` |
| ├ DividendVault | `0x8F137205c8D6E160bFb245F335C21bEADa295017` |
| └ MigratorV2 / FairTokenDeployer | `0x2B250C6371B064fc5A8F830d478A55d4a61FBB30` / `0x27fEF3807b420b8D955c0f6036182bEd794B4377` |
| TestnetAgentId（沿用） | `0x24D0A2106AC3Ebf7d770d19f4aF0a5149ebe5B2a` |
| 测试报价币 MockSPCXB（沿用） | `0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c` |

## 路由冒烟（`script/RouterTestnetSmoke.s.sol`）

| 步骤 | 交易 | 结果 |
|---|---|---|
| V3 发币（WBNB 报价，买 2% / 卖 2%，接收地址 = 演示金库） `0xA5E0896051EaeD4639f005dC12EEF59DC9f966C0` | [`0xb440…a5dc`](https://testnet.bscscan.com/tx/0xb440700864f50a414a779ee7b9be6fcc5b5f4d0e322b1fcbf0dd62c229f6a5dc) | — |
| `router.v3BuyBNB` 0.002 BNB | [`0xb267…e915`](https://testnet.bscscan.com/tx/0xb267e696d9b52e6aa3bcbd77915b81350346e9fd0d8f76ac01a45d6b0898e915) | 413,706 枚到交易者本人 |
| 打新发起（WBNB，募集 5 BNB，dev 1 份直接付给核心） `0xb21848d4048D5983D26b038B5BC8542773A92502` | [`0x8322…c315`](https://testnet.bscscan.com/tx/0x8322a5893c7d763548c6c0d40031df8b8aadf8d3d3c557347fceb438c602c315) | — |
| `router.fairMintBNB` 2 份 | [`0x7842…093b`](https://testnet.bscscan.com/tx/0x7842ac884c5cf9206dc9739f1f9ebd1272fae4b6bb72ce000ef268357ac6093b) | 份额记在交易者名下（共 3 份），多发的 BNB 退回 |

部署 44 笔 + 冒烟 6 笔全部成功，结束后路由的 BNB 和 WBNB 余额都是 0。部署钱包 0.013208 → 0.007018 tBNB（含冒烟里转进合约的约 0.0045）。

毕业 / 发射 / 外盘税 / 补转的整轮这次在本地 anvil 测试网 fork 上跑（同一套脚本、同样先 V3 再打新共用 registry 和 bucket）：`LaunchpadV3TestnetE2E`、`FairMintTestnetE2E` 都通过，打新的税换回 0.036488、minter 5 领取 0.000184，与前两次整轮一致；共用 bucket 的累计数比以前大，因为里面还有 V3 那一轮的平台收入。测试网钱包余额不够在公网再跑两轮。

主网部署也在 BSC 主网状态上做过一次进程内模拟（不广播）：不设 `OWNER` 时脚本拒绝；设了多签地址后新 registry 列入 USDT、bucket 的金库和回购合约取自 V2 bucket、operator 和 keeper 接线检查都通过，所有合约进入「待多签 accept」状态。

## 复跑

```sh
G="--with-gas-price 100000000 --priority-gas-price 100000000"
R=https://bsc-testnet-rpc.publicnode.com
forge script script/DeployLaunchpadV3.s.sol --rpc-url $R --broadcast --slow $G           # 输出 QUOTE_REGISTRY / PLATFORM_BUCKET
QUOTE_REGISTRY=… PLATFORM_BUCKET=… forge script script/DeployFairMint.s.sol --rpc-url $R --broadcast --slow $G
V3_PAD=<V3_LAUNCHPAD> FAIR_PAD=<FAIR_MINT_PAD> forge script script/DeployGangRouter.s.sol --rpc-url $R --broadcast --slow $G
V3_PAD=… FAIR_PAD=… GANG_ROUTER=… forge script script/RouterTestnetSmoke.s.sol --rpc-url $R --broadcast --slow $G
```

主网：每个脚本都要 `OWNER=<多签>`，第二个脚本要在多签 `acceptOwnership()` 之前跑（之后 registry / bucket 不再归部署钱包）。`DeployFairMint` 在测试网默认沿用上面的 Agent ID 注册表和测试报价币（`NEW_MOCKS=true` 才新部署）；`FairMintTestnetE2E` 对已注册的打新钱包不再重复 `register()`。
