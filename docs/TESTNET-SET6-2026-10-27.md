# 测试网第 6 套 · 卖出时自动小额换 + 第五轮审计修复

- 日期：2026-10-27 Asia/Shanghai
- 链：BSC 测试网（chainId 97）
- 代码：`feat/swapback` 上的 `3077301`。合约与 `98cab5c` 一致：
  - 外盘税改为卖出时自动小额换；
  - 分红按交税时记账；
  - 第五轮内部审计修复（审计说明 §15–§17）。
- 部署 / owner / keeper：`0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`
- 这一套取代第 5 套：
  - 打新 `0xF134…1f05`；
  - 路由 `0x8614…59E1`；
  - 沿用第 4 套的 V3 `0x4B6a…8dc4`。

  第 5 套的外盘税是攒着一次卖光的，没有每区块额度和 keeper 时间锁，已废弃。
- Agent ID 注册表和测试报价币沿用原来的，注册过的钱包继续可用。

## 合约

| 合约 | 地址 | 部署区块 |
|---|---|---|
| LaunchpadV3（核心） | [`0x4d353264317ecc9f9FAf72220bBe702F4C869908`](https://testnet.bscscan.com/address/0x4d353264317ecc9f9FAf72220bBe702F4C869908) | 139126805 |
| ├ TaxHandlerV3 | `0xEBa5C69990c9d1C5C963b20BFAABf4d0F57C026b` | |
| └ 黑名单报价币 tBUSD | `0x7AD14317eCa8DFF3DD242113189D3E824a8FC928` | |
| FairMintPad（核心） | [`0xcbB924E3ab1fA564627506C56c98721222df6636`](https://testnet.bscscan.com/address/0xcbB924E3ab1fA564627506C56c98721222df6636) | 139126941 |
| └ HolderRewardHandler | `0xA3E45445CADcE0eB29B6b7d9fc5D3eABF1b9bc83` | |
| GangRouter | [`0x2F38dDd911F64C6a37cFbC54903AfA014e8941FE`](https://testnet.bscscan.com/address/0x2F38dDd911F64C6a37cFbC54903AfA014e8941FE)（两个核心都已 `setRouter`） | 139127044 |
| QuoteRegistry（共用） | `0x9003981d55642248EEc54Fad441a7B8fDddbd407` | |
| SharedPlatformFeeBucket（共用，没有 `collectPlatformSmart`） | `0x43A931d7670287834597290701acb5AA59deb05D` | |
| SharedDividendVault（共用） | `0xbB78a3FE5D4924015dE3854cC8cC4F86490799f6` | |
| SharedMigrator（共用） | `0xbb47f0C5E81c1F7fc819E300bbED8395A995f338` | |
| TokenDeployer（共用） | `0xAC590a037A0AA7e129a5e3A6696eee820C174bf5` | |
| TestnetAgentId（沿用） | `0x24D0A2106AC3Ebf7d770d19f4aF0a5149ebe5B2a` | |
| 测试报价币 MockSPCXB（沿用） | `0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c` | |

部署共 43 笔，全部成功：V3 26 笔、打新 14 笔、路由 3 笔。打新这一步把五个共用合约全部传入，并传了 `PEER_CORE` = V3 核心。部署记录里没有私钥。

服务端配置：

```
V3_PADS=v3t6:0x4d353264317ecc9f9FAf72220bBe702F4C869908@139126805
FAIR_PADS=fairt6:0xcbB924E3ab1fA564627506C56c98721222df6636@139126941
GANG_V3_PAD=0x4d353264317ecc9f9FAf72220bBe702F4C869908    GANG_V3_START_BLOCK=139126805
GANG_FAIR_PAD=0xcbB924E3ab1fA564627506C56c98721222df6636  GANG_FAIR_START_BLOCK=139126941
```

## 公开整轮

### V3（`script/LaunchpadV3TestnetE2E.s.sol`，加 `--skip-simulation`）

- 币 A：`0xDd6F855626fb39F76081C381715D7C85d994063b`，交易对 `0xadB643431CB6d15BBD4E5621e6BDfB97732D14C8`。
  - 内盘买卖过；80 个 Agent 打满后毕业。
  - 外盘先买一笔、再卖一笔。卖出那笔在区块 139128840 顺带换了一块税（`OuterTaxProcessed` ×1），卖出 1.2878e23 枚。
  - 处理合约上剩 1.1310e23 枚待卖，留给 keeper 补位。
- 币 B：`0x28C744e6c6A1Aa2e31359Fc5D2A842aFB253a00B`，用黑名单报价币，接收地址被拉黑。
  - 内盘买入时推送失败，记为欠款 731731113206935。
  - 之后接收地址解除拉黑，等 keeper 或任何人释放。
- keeper 补位：`process(A, 1.1310e23, minOut)`，minOut 取 Pancake 报价的 95%。
  - 交易 [`0x967a…377b`](https://testnet.bscscan.com/tx/0x967a4efe776b8553e4394a906fa1dc9368bc344f446c409c1d58ca5ca6cd377b)，区块 139132318，gas 214,904。
  - 剩下的税一次卖完（小于本区块额度），换回约 0.00853 报价币。之后 `accruedTax` = 0，`windowOf` = (139132318, 1.1310e23)。
  - 第一次用 publicnode 发的那笔停在它的交易池里，节点没有广播出去。改用 `data-seed-prebsc-1-s1.bnbchain.org`，以同一 nonce、1 gwei 重发后上链。

### 打新（`script/FairMintTestnetE2E.s.sol`，加 `--skip-simulation`）

- 币 `0x9e2045408daCD99a5253b4a5f849FcEFEC44e10D`，交易对 `0xe0c4BB86a638208EfDE8D7A741Bc4068E3536D8B`。
- 100 个地址打满后发射。
- 外盘买一笔；一个打新地址卖到线下，被取消资格（`Disqualified`）。
- 换税 2 次（`OuterTaxProcessed` / `TaxChunkSold` 各 2 次）：
  - 卖出时顺带换一块；
  - keeper `process` 补一块。
  - 两次合计换回 0.007288 报价币；处理合约上已没有待卖的税。
- 第 5 个打新地址领取 0.000184；平台手续费池累计 0.40368。

## 复跑

```sh
G="--with-gas-price 100000000 --priority-gas-price 100000000"
R=https://bsc-testnet-rpc.publicnode.com
forge script script/DeployLaunchpadV3.s.sol --rpc-url $R --broadcast --slow $G   # 输出五个共用合约地址
QUOTE_REGISTRY=… PLATFORM_BUCKET=… DIVIDEND_VAULT=… MIGRATOR=… TOKEN_DEPLOYER=… PEER_CORE=<V3_LAUNCHPAD> \
  forge script script/DeployFairMint.s.sol --rpc-url $R --broadcast --slow $G
V3_PAD=<V3_LAUNCHPAD> FAIR_PAD=<FAIR_MINT_PAD> forge script script/DeployGangRouter.s.sol --rpc-url $R --broadcast --slow $G
PAD=<V3_LAUNCHPAD> BLACKLIST_QUOTE=… forge script script/LaunchpadV3TestnetE2E.s.sol --rpc-url $R --broadcast --slow --skip-simulation $G
PAD=<FAIR_MINT_PAD> TEST_QUOTE=0x02B3…CF1c forge script script/FairMintTestnetE2E.s.sol --rpc-url $R --broadcast --slow --skip-simulation $G
```

部署脚本的 fork 回归测试（`test/audit5/audit5c/DeployScriptsFork.t.sol`）要加 `--threads 1`。原因是脚本通过 `vm.setEnv` 读配置，环境变量是进程共享的，同一文件里的测试并行跑会互相覆盖。
