# 主网上线手册 · LaunchpadV3 税收币 + 打新 + GangRouter

- 日期：2026-10-26 Asia/Shanghai（写于上线前，上线当天照着做，做完在每一步后面记下交易哈希和地址）
- 代码：gang-launchpad `main`（合约冻结在 `47a063b`，审计说明 `docs/AUDIT-BRIEF-2026-10-26.md`）
- 链：BSC 主网（chainId 56）
- 谁做：部署钱包跑脚本；多签签 §3 的交易；服务端 / keeper 由能上服务器的人改 env

---

## 0. 上线前要齐的东西

| # | 项 | 谁给 | 用在哪 |
|---|---|---|---|
| 1 | 多签地址（BSC 上的 Safe，2/3 或 3/5，签名人分开保管） | 你 | `OWNER` |
| 2 | 合作方主网金库地址 + 名称；确认它能收报价币（合约不拒收 ERC-20、USDT 没拉黑它） | 合作方 | §3 `recipients.list` |
| 3 | 合作方用的报价币（WBNB 或 USDT） | 合作方 | 决定要不要维护 USDT 换算额 |
| 4 | `USDT_PER_15_BNB`：当天 15 BNB 折合多少 USDT（18 位小数，例：BNB = 745 USDT 时为 `11175000000000000000000`） | 部署当天算 | 部署脚本 |
| 5 | 部署钱包：一个新热钱包，备 ≥ 0.02 BNB（三个脚本约 45 笔，按 0.1 gwei 估约 0.005 BNB，留余量） | 你 | `DEPLOYER_PRIVATE_KEY` |
| 6 | 一个能查历史日志的 BSC RPC（keeper 和索引服务首次扫描要从部署区块开始） | 你 | `LOGS_RPC` / 索引 RPC |

部署前自检：

```sh
R=https://bsc-dataseed1.defibit.io
# PoolCheck 库：核心按地址链接、delegatecall 调用它，字节码必须和本仓库源码一致
cast code 0xd2B159820749f178503E4faBCB18A7Ae4492bDb3 --rpc-url $R | wc -c
forge inspect src/launchpad-v2/PoolCheck.sol:PoolCheck deployedBytecode | wc -c   # 两者一致（再逐字节 diff）
# V2 分账合约当前的金库与回购合约（新分账合约会照抄这两个）
cast call 0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111 "feeVault()(address)" --rpc-url $R   # 预期 0x3464…1Af4
cast call 0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111 "burner()(address)" --rpc-url $R     # 预期 GangBuybackBurner 0x3812…363B
forge test   # 全部通过
```

---

## 1. 部署（部署钱包，按顺序，第 2 步必须在多签 accept 之前跑完）

```sh
export DEPLOYER_PRIVATE_KEY=0x…            # 只在这台机器的这个 shell 里
export OWNER=0x<多签>
export USDT_PER_15_BNB=<§0 #4>
export RECIPIENT=0x<合作方金库> RECIPIENT_LABEL="<合作方名称>"   # 可选：也可以之后由多签 list
L="--libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3"
G="--with-gas-price <当时主网 gas price，wei> --priority-gas-price <同上>"   # 必须显式给：公共节点偶尔估出 1 wei，交易会卡住
R=https://bsc-dataseed1.defibit.io

# 1) V3：新建共用的 QuoteRegistry + PlatformFeeBucket，列入 USDT（固定换算额），整套 V3，最后 setMigrator
LAUNCHPAD_V3_MAINNET_OK=true forge script script/DeployLaunchpadV3.s.sol --rpc-url $R --broadcast --slow $L $G
#    记下：V3_LAUNCHPAD、V3_TAX_ROUTER、V3_RECIPIENT_REGISTRY、V3_POSTGRAD_HANDLER、V3_DIVIDEND_VAULT、V3_MIGRATOR、
#          QUOTE_REGISTRY、PLATFORM_BUCKET，以及 V3_LAUNCHPAD 的部署区块

# 2) 打新：复用上一步的 registry + bucket
QUOTE_REGISTRY=0x… PLATFORM_BUCKET=0x… FAIR_MINT_MAINNET_OK=true \
  forge script script/DeployFairMint.s.sol --rpc-url $R --broadcast --slow $L $G
#    记下：FAIR_MINT_PAD、HOLDER_REWARD_HANDLER、FAIR_DIVIDEND_VAULT、FAIR_MINT_MIGRATOR，以及 FAIR_MINT_PAD 的部署区块

# 3) 路由（两个核心的 owner 此时还是部署钱包，脚本直接 setRouter）
V3_PAD=0x… FAIR_PAD=0x… GANG_ROUTER_MAINNET_OK=true \
  forge script script/DeployGangRouter.s.sol --rpc-url $R --broadcast --slow $G
#    记下：GANG_ROUTER
```

- 三个脚本结束时都会做接线自检，任何一项不对会直接报错。
- 每个脚本跑完，检查 `broadcast/<脚本>/56/run-latest.json` 里所有 receipt 的 status 都是 `0x1`，并确认文件里没有私钥，再提交到仓库。
- 部署完成后，部署钱包把剩余 BNB 转走，之后不再使用。

---

## 2. 部署后、多签接受前的链上自检

```sh
c() { cast call "$@" --rpc-url $R; }
# 每个合约：owner 还是部署钱包，pendingOwner 是多签
for a in $V3_LAUNCHPAD $V3_TAX_ROUTER $V3_RECIPIENT_REGISTRY $V3_POSTGRAD_HANDLER $V3_DIVIDEND_VAULT \
         $FAIR_MINT_PAD $HOLDER_REWARD_HANDLER $FAIR_DIVIDEND_VAULT $QUOTE_REGISTRY $PLATFORM_BUCKET; do
  echo $a $(c $a "owner()(address)") $(c $a "pendingOwner()(address)"); done
c $PLATFORM_BUCKET "operators(address)(bool)" $V3_LAUNCHPAD          # 4 个都应为 true
c $PLATFORM_BUCKET "operators(address)(bool)" $V3_TAX_ROUTER
c $PLATFORM_BUCKET "operators(address)(bool)" $FAIR_MINT_PAD
c $PLATFORM_BUCKET "operators(address)(bool)" $HOLDER_REWARD_HANDLER
c $PLATFORM_BUCKET "burner()(address)"; c $PLATFORM_BUCKET "feeVault()(address)"; c $PLATFORM_BUCKET "keeper()(address)"
c $QUOTE_REGISTRY "quotes(address)(bool,uint256)" 0x55d398326f99059fF775485246999027B3197955   # true, USDT_PER_15_BNB
c $V3_DIVIDEND_VAULT "excluded(address)(bool)" $V3_MIGRATOR                                    # true
c $V3_LAUNCHPAD "routers(address)(bool)" $GANG_ROUTER; c $FAIR_MINT_PAD "routers(address)(bool)" $GANG_ROUTER
c $V3_LAUNCHPAD "agentIdRegistry()(address)"   # 0x60B9…022F（真实 Agent ID）
```

---

## 3. 多签要签的交易

**必须（核心从这一刻起才完全归多签）**：对下面 10 个合约各调一次 `acceptOwnership()`：

| # | 合约 | 地址 |
|---|---|---|
| 1 | LaunchpadV3 | `V3_LAUNCHPAD` |
| 2 | TaxRouterV3 | `V3_TAX_ROUTER` |
| 3 | RecipientRegistry | `V3_RECIPIENT_REGISTRY` |
| 4 | PostGradTaxHandlerV3 | `V3_POSTGRAD_HANDLER` |
| 5 | DividendVault（V3） | `V3_DIVIDEND_VAULT` |
| 6 | FairMintPad | `FAIR_MINT_PAD` |
| 7 | HolderRewardHandler | `HOLDER_REWARD_HANDLER` |
| 8 | DividendVault（打新） | `FAIR_DIVIDEND_VAULT` |
| 9 | QuoteRegistry（共用） | `QUOTE_REGISTRY` |
| 10 | PlatformFeeBucket（共用） | `PLATFORM_BUCKET` |

接受后，再跑一遍 §2 的 owner 循环，确认 10 个合约的 owner 都是多签，pendingOwner 都是 `0x0`。

**合作方**（部署时没设 `RECIPIENT` 的话）：`RecipientRegistry.list(<合作方金库>, "<名称>")`。

**建议，不挡上线**：
- V2 那几份（owner 现为普通钱包 `0x4EEd…`）：`0x4EEd` 对 V2 发射台、分账合约 `0xBDDd…F111`、QuoteRegistry `0x053C…060D`、DividendVault 分别 `transferOwnership(多签)`，多签逐个 `acceptOwnership()`。
- 回购合约 GangBuybackBurner `0x3812…363B`（owner 也是 `0x4EEd`，能改兑换路由，从而截走回购那一部分）：同样转给多签。

---

## 4. 服务端（正式站 indexer.env，不进仓库）

```
GANG_FAIR_PAD=<FAIR_MINT_PAD>
GANG_FAIR_START_BLOCK=<FAIR_MINT_PAD 部署区块>
GANG_FAIR_CHAIN_ID=56
GANG_FAIR_RPC_URLS=<§0 #6 的 RPC>
GANG_V3_PAD=<V3_LAUNCHPAD>
GANG_V3_START_BLOCK=<V3_LAUNCHPAD 部署区块>
GANG_V3_CHAIN_ID=56
GANG_V3_RPC_URLS=<§0 #6 的 RPC>
```

重启索引服务后检查 `/fair/config`、`/v3/config` 返回 `enabled: true`，地址和区块与上面一致。网站上「打新」「税收币」入口由这两个接口决定，不用另外改前端。

---

## 5. keeper（正式站 keeper/.env 与 crontab，不进仓库）

```
# 外盘税：两个 handler + V3 欠款补发（keeper-tax-process.sh）
TAX_HANDLERS=v3:<V3_POSTGRAD_HANDLER>@<V3 部署区块>,fair:<HOLDER_REWARD_HANDLER>@<打新部署区块>
TAX_ROUTERS=v3:<V3_TAX_ROUTER>@<V3 部署区块>
SLIPPAGE_BPS=150                 # 审计说明 K-15：容忍度不超过 1–2%，一次性卖出会被夹
LOGS_RPC=<§0 #6 的 RPC>
# 平台费：在原来三个分账合约后面加新的（keeper-v2-platform.sh）
PLATFORM_BUCKETS=v2:0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111,u:0xe314efeB69229386baAd32034f4C06c196F6260c,s:0xad34653E20a33bE38340a837b0C67d85C899dEeC,nc:<PLATFORM_BUCKET>
```

- crontab：把外盘税那一行从每小时改为每 10 分钟（`*/10 * * * *`），保证每批卖出量小。
- keeper 地址必须等于两个 handler 和新分账合约的 `keeper()`（部署脚本已按 `KEEPER` 设好，默认 `0xB6f1…cFc7`）。
- 先不带 `--broadcast` 手动跑一次两个脚本，确认能识别新合约、模拟全部通过。
- 后续建议：给 `keeper-tax-process.sh` 加一个只用于发送交易的私有 RPC（目前读和发用同一个 `BSC_RPC`），进一步降低被夹的风险。

---

## 6. CLI

- 把 `skill/gang-cli/src/fair.js`、`v3.js` 里 mainnet 的 `pad`、`router` 改成上面的地址（目前是 `null`，可用 `GANG_FAIR_PAD` / `GANG_V3_PAD` / `GANG_ROUTER` 环境变量临时指定）。
- 更新文档里「只在测试网」的说法，升版本号，然后发布。
- 发布前用主网地址做一次 `gang v3 create … --calldata --from <内部钱包>` 演练（不签名不广播，但会真实上传图标和元数据 JSON）：输出里要有 `metaURI` 和 `metadata`，打开 `metaURI` 能看到正确的 JSON（name、symbol、image、external_link、twitter），`image` 能打开图标。元数据上链后不能改。
- **CLI 发布的那一刻就是对公众开放创建的那一刻**（网站上的打新和税收币页面只能查看，发币和打新要通过 CLI）。如果要分阶段放开，前一两周先不发布 CLI，只让合作方和内部用 `GANG_*_PAD` 环境变量发币。合约本身挡不住别人直接调用，所以这只能降低早期的资金规模，不是硬限制。

---

## 7. 上线后的检查

- [ ] 合作方发第一个币（小额）：`TaxConfigured` 事件、接收地址收到第一笔 `TaxPaid`
- [ ] 第一个币的 `contractURI()` / `metaURI()` 返回元数据 JSON 的地址，能打开、内容正确；发射台 `logoURIOf` 是图标地址
- [ ] 行情页（不带 `?testnet=1`）出现税收币卡片和「打新」标签（只在服务端配了主网 `GANG_V3_*` / `GANG_FAIR_*` 之后）
- [ ] 一个打新 sale 跑通：打新、撤出、打满发射、池子开盘价等于打新价
- [ ] 经 GangRouter 用 BNB 买和打新各一笔，结束后路由余额为 0
- [ ] keeper 第一次 `process` 和 `collectPlatform` 成功，新分账合约的 80% 进入回购、20% 进入金库
- [ ] 网站 `/v3`、`/mint` 页面与链上数据一致
- [ ] 漏洞赏金上线（如果决定开）

---

## 8. 日常运维

| 事项 | 什么时候 | 怎么做 |
|---|---|---|
| USDT 换算额 | BNB 价格偏离当前换算额超过 10% | 多签 `QuoteRegistry.setQuote(USDT, true, <新的 15 BNB 合多少 USDT>)`，只影响之后创建的币 |
| 非官方池子分红 | 发现某个 V3 币在别的 DEX 或 V3 池子里有大额持仓 | 多签 `DividendVault.setExcluded(pool, true)`，**同一批交易里** `PostGradTaxHandlerV3.syncShares(token, pool, 0)` |
| 排除某个地址（G-01） | 需要时 | 同上：排除和 `syncShares(token, user, 0)` 放在同一批 |
| 欠款 | keeper 日志里出现 `owedOf > 0` | 联系合作方处理收款问题；能收款之后 keeper 或任何人都能 `release` |
| 接新合作方 | 需要时 | 多签 `RecipientRegistry.list(地址, 名称)` |

---

## 9. 出问题时能做什么

合约不可升级，也没有暂停开关。能用的手段只有这些：

| 情况 | 手段 | 效果 |
|---|---|---|
| 路由有问题 | 多签对两个核心 `setRouter(GANG_ROUTER, false)` | 路由入口立即关闭，直接买、直接打新照常 |
| 某个报价币有问题 | 多签 `QuoteRegistry.setQuote(币, false, 0)` | 之后不能再用这个币发新币，已有的不受影响 |
| 某个接收地址有问题 | 多签 `RecipientRegistry.delist(地址)` | 之后不能再用它发新币，已有的币照常打款 |
| 需要停止新发币 | 网站和 CLI 下线入口；服务端去掉 `GANG_*_PAD` | 只能挡住通过我们入口的用户，挡不住直接调合约的人 |
| 合约本身有漏洞 | 重新部署修复版，网站和 CLI 切到新地址；旧合约里的钱只能等用户按原规则自己取回 | 已经在旧合约里的资金无法迁移 |

不要做的事：
- 撤掉核心在分账合约的 operator 权限：V3 内盘买卖、打新撤出和发射会全部 revert（审计说明 A-1）。
- 撤掉 PostGradTaxHandlerV3 在分红合约的 operator 权限：毕业后的 V3 代币将无法转账（K-7）。
