# 主网上线手册 · LaunchpadV3 税收币 + 打新 + GangRouter

- 日期：2026-10-26 Asia/Shanghai，2026-10-27 按合并后的合约重写（写于上线前，上线当天照着做，做完在每一步后面记下交易哈希和地址）
- 代码：gang-launchpad，合约冻结在 `ddce6b6`（方案 A 合并 + 第四轮内部审计修复 + 外盘税卖出时自动小额换 + 按税产生时记账；审计说明 `docs/AUDIT-BRIEF-2026-10-26.md` §15–§17）。合入 `main` 后以 `main` 为准
- 服务端 / keeper：gangfun-server，`keeper/` 以分支 `feat/keeper-ops` 为准（合入 `main` 后以 `main` 为准）
- 链：BSC 主网（chainId 56）
- 谁做：部署钱包跑脚本；多签签 §3 的交易；服务端 / keeper 由能上服务器的人改 env

---

## 0. 上线前要齐的东西

| # | 项 | 谁给 | 用在哪 |
|---|---|---|---|
| 1 | 多签地址（BSC 上的 Safe，2/3 或 3/5，签名人分开保管） | 你 | `OWNER` |
| 2 | 合作方主网金库地址 + 名称；确认它能收报价币（合约不拒收 ERC-20、USDT 没拉黑它） | 合作方 | §3 `TaxHandlerV3.list` |
| 3 | 合作方用的报价币（WBNB 或 USDT）。USDT 不用设换算额：发币时用 USDT/WBNB 池子换算（§1） | 合作方 | 发币参数 |
| 4 | 部署钱包：一个新热钱包，备 ≥ 0.03 BNB（三个脚本约 50 笔，按 0.1 gwei 估约 0.006 BNB，留余量） | 你 | `DEPLOYER_PRIVATE_KEY` |
| 5 | 一个**能查历史日志**的 BSC RPC（keeper 首次从部署区块开始扫事件；`bsc-dataseed` 直接拒绝 `eth_getLogs`，publicnode 只留几小时） | 你 | `LOGS_RPC` / 索引 RPC |
| 6 | 运维 Telegram 群的 chat id（报警用，**不是**公开频道 `TG_CHANNEL_ID`） | 你 | `ALERT_TG_CHAT_ID` |
| 7 | keeper 钱包 `0xB6f1…cFc7` 里 ≥ 0.1 BNB（健康检查低于 0.05 报警） | 你 | keeper |

部署前自检：

```sh
R=https://bsc-dataseed1.defibit.io
# PoolCheck 库：核心按地址链接、delegatecall 调用它，字节码必须和本仓库源码一致
cast code 0xd2B159820749f178503E4faBCB18A7Ae4492bDb3 --rpc-url $R | wc -c
forge inspect src/launchpad-v2/PoolCheck.sol:PoolCheck deployedBytecode | wc -c   # 两者一致（再逐字节 diff）
# V2 分账合约当前的金库与回购合约（新分账合约会照抄这两个）
cast call 0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111 "feeVault()(address)" --rpc-url $R   # 预期 0x3464…1Af4
cast call 0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111 "burner()(address)" --rpc-url $R     # 预期 GangBuybackBurner 0x3812…363B
# 主网 USDT 的参考池：Pancake V3 USDT/WBNB 0.01%，必须就是工厂登记的那个池子
cast call 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865 "getPool(address,address,uint24)(address)" \
  0x55d398326f99059fF775485246999027B3197955 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c 100 --rpc-url $R
#   预期 0x172fcD41E0913e95784454622d1c3724f546f849
forge test   # 全部通过（ddce6b6：487 个）
BSC_RPC_URL=https://rpc-bsc.48.club forge test --match-contract Fork   # 主网分叉（publicnode 会丢历史状态，用 48.club）
```

---

## 1. 部署（部署钱包，按顺序；第 2、3 步必须在多签 accept 之前跑完）

```sh
export DEPLOYER_PRIVATE_KEY=0x…            # 只在这台机器的这个 shell 里
export OWNER=0x<多签>
export RECIPIENT=0x<合作方金库> RECIPIENT_LABEL="<合作方名称>"   # 可选：也可以之后由多签 list
L="--libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3"
G="--with-gas-price <当时主网 gas price，wei> --priority-gas-price <同上>"   # 必须显式给：公共节点偶尔估出 1 wei，交易会卡住
R=https://bsc-dataseed1.defibit.io

# 1) V3：新建五个共用合约（QuoteRegistry、SharedPlatformFeeBucket、SharedDividendVault、SharedMigrator、TokenDeployer），
#    再建 TaxHandlerV3 + LaunchpadV3，接线，最后 setMigrator
LAUNCHPAD_V3_MAINNET_OK=true forge script script/DeployLaunchpadV3.s.sol --rpc-url $R --broadcast --slow $L $G
#    日志里记下：V3_LAUNCHPAD、V3_TAX_HANDLER、QUOTE_REGISTRY、PLATFORM_BUCKET、DIVIDEND_VAULT、MIGRATOR、
#    TOKEN_DEPLOYER、AGENT_ID、USDT_REF_POOL，以及 V3_LAUNCHPAD 的部署区块

# 2) 打新：五个共用合约全部复用上一步的，外加 PEER_CORE=第一步的 V3_LAUNCHPAD（脚本要求五个要么全传要么全不传，
#    只传一部分直接回滚 PartialShared；PEER_CORE 用来核对 V3 核心挂在同一套分红 / 迁移 / 部署合约上）
QUOTE_REGISTRY=0x… PLATFORM_BUCKET=0x… DIVIDEND_VAULT=0x… MIGRATOR=0x… TOKEN_DEPLOYER=0x… PEER_CORE=0x… \
FAIR_MINT_MAINNET_OK=true forge script script/DeployFairMint.s.sol --rpc-url $R --broadcast --slow $L $G
#    记下：FAIR_MINT_PAD、HOLDER_REWARD_HANDLER，以及 FAIR_MINT_PAD 的部署区块

# 3) 路由（两个核心的 owner 此时还是部署钱包，脚本直接 setRouter）
V3_PAD=0x… FAIR_PAD=0x… GANG_ROUTER_MAINNET_OK=true \
  forge script script/DeployGangRouter.s.sol --rpc-url $R --broadcast --slow $G
#    记下：GANG_ROUTER
```

- 第 2 步复用时，脚本要求部署钱包仍是这五个合约的 owner（多签还没 accept），否则 `NotDeployerOwned` 直接退出；`MIGRATOR` 的 factory 不对会 `WiringCheck("MIGRATOR factory")`。
- 两个脚本结束时都做接线自检（`_check` / `_checkCore` / `_checkBucket`），任何一项不对直接报错：核心在分红合约、迁移合约、代币部署合约的白名单里；分红合约的 operator 是本核心的 handler；分红合约排除了自己、迁移合约、手续费池；门槛 10,000 枚；bucket 的 operator 是核心和 handler、keeper 正确；Agent 准入开启；V3 单地址上限开启；接收地址已列入（若设了 `RECIPIENT`）。
- 主网**不登记任何报价币**：USDT 发币时用 `USDT_REF_POOL`（Pancake V3 USDT/WBNB 0.01% 池 `0x172f…f849`，30 分钟 TWAP）换算毕业额 / 募集额；CLI 对主网 USDT 默认用这个池子（`--ref-pool` 可省）。其它 18 位报价币由发币人自带参考池（V2 池读储备、V3 池读 TWAP，没有观测历史时读现价，见审计说明 §4.2 R2-1 的已接受风险）。
- 换币路由（Pancake V2 Router02 `0x10ED…024E`）在构造 handler 时传入；之后要改只能 `proposeDexRouter` → 48 小时 → `acceptDexRouter`（§8）。
- 每个脚本跑完，检查 `broadcast/<脚本>/56/run-latest.json` 里所有 receipt 的 status 都是 `0x1`，并确认文件里没有私钥，再提交到仓库。
- 部署完成后，部署钱包把剩余 BNB 转走，之后不再使用（§3 之后它不应再有任何权限，见 §2 的核对）。

---

## 2. 部署后、多签接受前的链上自检

```sh
c() { cast call "$@" --rpc-url $R; }
ALL="$V3_LAUNCHPAD $V3_TAX_HANDLER $FAIR_MINT_PAD $HOLDER_REWARD_HANDLER $QUOTE_REGISTRY $PLATFORM_BUCKET \
     $DIVIDEND_VAULT $MIGRATOR $TOKEN_DEPLOYER"
# 9 个合约：owner 还是部署钱包，pendingOwner 是多签
for a in $ALL; do echo $a $(c $a "owner()(address)") $(c $a "pendingOwner()(address)"); done
# 手续费池：4 个 operator、金库、回购、keeper
for o in $V3_LAUNCHPAD $V3_TAX_HANDLER $FAIR_MINT_PAD $HOLDER_REWARD_HANDLER; do c $PLATFORM_BUCKET "operators(address)(bool)" $o; done
c $PLATFORM_BUCKET "burner()(address)"; c $PLATFORM_BUCKET "feeVault()(address)"; c $PLATFORM_BUCKET "keeper()(address)"
# 分红合约：两个核心各绑一个 operator（只能绑一次），排除名单
c $DIVIDEND_VAULT "operatorFor(address)(address)" $V3_LAUNCHPAD      # = V3_TAX_HANDLER
c $DIVIDEND_VAULT "operatorFor(address)(address)" $FAIR_MINT_PAD     # = HOLDER_REWARD_HANDLER
for x in $DIVIDEND_VAULT $MIGRATOR $PLATFORM_BUCKET; do c $DIVIDEND_VAULT "excluded(address)(bool)" $x; done   # 都 true
c $DIVIDEND_VAULT "minimumShareBalanceOf(address)(uint256)" $V3_LAUNCHPAD        # 10000e18
# 迁移合约 / 代币部署合约：两个核心都在白名单里
c $MIGRATOR "launchpads(address)(bool)" $V3_LAUNCHPAD; c $MIGRATOR "launchpads(address)(bool)" $FAIR_MINT_PAD
c $TOKEN_DEPLOYER "launchpads(address)(bool)" $V3_LAUNCHPAD; c $TOKEN_DEPLOYER "launchpads(address)(bool)" $FAIR_MINT_PAD
# handler：keeper、换币路由、没有待生效的路由提议
for h in $V3_TAX_HANDLER $HOLDER_REWARD_HANDLER; do c $h "keeper()(address)"; c $h "dexRouter()(address)"; done
# 路由、准入
c $V3_LAUNCHPAD "routers(address)(bool)" $GANG_ROUTER; c $FAIR_MINT_PAD "routers(address)(bool)" $GANG_ROUTER
c $V3_LAUNCHPAD "agentIdRegistry()(address)"   # 0x60B9…022F（真实 Agent ID）
```

---

## 3. 多签要签的交易

**必须（从这一刻起所有合约归多签）**：对下面 9 个合约各调一次 `acceptOwnership()`：

| # | 合约 | 地址 | 多签之后能做什么（详见审计说明 §4） |
|---|---|---|---|
| 1 | LaunchpadV3 | `V3_LAUNCHPAD` | 路由名单、准入、单地址上限、参考池相关设置 |
| 2 | TaxHandlerV3 | `V3_TAX_HANDLER` | 接收地址白名单 `list` / `delist`、keeper、换币路由（48 小时时间锁） |
| 3 | FairMintPad | `FAIR_MINT_PAD` | 路由名单、准入（只影响之后的 sale）、参考池相关设置 |
| 4 | HolderRewardHandler | `HOLDER_REWARD_HANDLER` | keeper、换币路由（48 小时时间锁） |
| 5 | QuoteRegistry（共用） | `QUOTE_REGISTRY` | 给某个报价币设固定换算额（可选；设了就优先于参考池） |
| 6 | SharedPlatformFeeBucket（共用） | `PLATFORM_BUCKET` | operator、金库、回购合约、keeper（换人要 `proposeKeeper` → 48 小时 → `acceptKeeper`）、7 天应急出口；只有固定路径的 `collectPlatform`，没有 `collectPlatformSmart` |
| 7 | SharedDividendVault（共用） | `DIVIDEND_VAULT` | 核心白名单（移除只停新登记）、排除地址、新币的门槛；operator 已绑定，不能再改 |
| 8 | SharedMigrator（共用） | `MIGRATOR` | 只能再加核心，不能移除 |
| 9 | TokenDeployer（共用） | `TOKEN_DEPLOYER` | 能部署代币的核心名单 |

接受后，再跑一遍 §2 的 owner 循环，确认 9 个合约的 owner 都是多签，pendingOwner 都是 `0x0`。GangRouter 没有 owner。**部署钱包此后不应有任何角色**：它不是任何合约的 owner、keeper 或 operator（keeper 是 `KEEPER` 默认的 `0xB6f1…cFc7`）。

**合作方**（部署时没设 `RECIPIENT` 的话）：`TaxHandlerV3.list(<合作方金库>, "<名称>")`。

**建议，不挡上线**：
- V2 那几份（owner 现为普通钱包 `0x4EEd…`）：`0x4EEd` 对 V2 发射台、分账合约 `0xBDDd…F111`、QuoteRegistry `0x053C…060D`、DividendVault 分别 `transferOwnership(多签)`，多签逐个 `acceptOwnership()`。
- 回购合约 GangBuybackBurner `0x3812…363B`（owner 也是 `0x4EEd`，能改兑换路由，从而截走回购那一部分）：同样转给多签。

---

## 4. 服务端（正式站 indexer.env，不进仓库）

```
GANG_FAIR_PAD=<FAIR_MINT_PAD>
GANG_FAIR_START_BLOCK=<FAIR_MINT_PAD 部署区块>
GANG_FAIR_CHAIN_ID=56
GANG_FAIR_RPC_URLS=<§0 #5 的 RPC>
GANG_V3_PAD=<V3_LAUNCHPAD>
GANG_V3_START_BLOCK=<V3_LAUNCHPAD 部署区块>
GANG_V3_CHAIN_ID=56
GANG_V3_RPC_URLS=<§0 #5 的 RPC>
```

重启索引服务后检查：
- `/fair/config`、`/v3/config` 返回 `enabled: true`，地址和区块与上面一致，`contracts` 里有 `taxHandler`、`vault`。
- `/burn` 列出了新的 SharedPlatformFeeBucket（索引器从两个核心的 `platformBucket()` 自动发现）。
- `/health?strict=1` 返回 200（健康检查会轮询它）。

网站上「打新」「税收币」入口由这两个接口决定，不用另外改前端。

---

## 5. keeper（正式站 keeper/.env 与 crontab，不进仓库）

```
KEEPER_PRIVATE_KEY=…                       # keeper 钱包 0xB6f1…cFc7
BSC_RPC_URL=<发交易用的 RPC，最好私有>
LOGS_RPC=<§0 #5，必须能查日志；keeper 启动时先探测，查不了直接 exit 9>
# 每个核心一条：label:地址@部署区块。keeper 从核心读 taxHandler() / platformBucket()，处理合约和手续费池都不用另外填
V3_PADS=v3:<V3_LAUNCHPAD>@<V3 部署区块>
FAIR_PADS=fair:<FAIR_MINT_PAD>@<打新部署区块>
SLIPPAGE_BPS=150                           # 每块的最低成交额 = 这一块的报价 × (1 − 1.5%)
MAX_CHUNKS_PER_RUN=20                      # 每个币每次运行最多卖 20 块（每块 ≤ 池子代币储备 0.5%）
ALERT_TG_CHAT_ID=<§0 #6>                   # 报警发运维群；不配时报警打到 stderr 并非零退出
```

- `TAX_HANDLERS` / `TAX_ROUTERS` 留空：两个核心的处理合约会自动接上（TaxHandlerV3 同时负责外盘税和接收地址欠款补发）。
- 三个列表全空时 `keeper-tax-process.sh` 以 7 退出并报警；只有确实不该跑的机器才设 `TAX_PROCESS_DISABLED=1`。
- 平台费：`keeper-v2-platform.sh` 会从两个核心读出新的 SharedPlatformFeeBucket、从索引器取报价币清单，不用往 `PLATFORM_BUCKETS` 里手填；它只调固定路径的 `collectPlatform`（新手续费池没有 `collectPlatformSmart`）。V2 那三个分账合约照旧在默认清单里（V2 的分红 / 存量税按用户决定不处理，脚本不会对 V2 币调 `process`）。
- crontab 用仓库里的 `keeper/crontab.txt`：所有任务都经 `cron-run.sh` 包一层（非零退出就报警）；外盘税 `*/10 * * * *`；健康检查 `keeper-health.sh` 每 30 分钟。
- keeper 地址必须等于两个 handler 和新手续费池的 `keeper()`（部署脚本已按 `KEEPER` 设好）。
- 后续建议：发交易单独用私有 RPC（`BSC_RPC_URL`），读和查日志用 `LOGS_RPC`，降低分块卖出被夹的风险。

---

## 6. CLI

- 把 `skill/gang-cli/src/fair.js`、`v3.js` 里 mainnet 的 `pad`、`router` 改成上面的地址（目前是 `null`，可用 `GANG_FAIR_PAD` / `GANG_V3_PAD` / `GANG_ROUTER` 环境变量临时指定）。
- 更新文档里「只在测试网」的说法，升版本号，然后发布。
- 打新的参数范围（合约强制，CLI 同样校验）：募集 5–50 BNB 等值、单地址上限 0.25%–0.5%、出局线 30%–80%、打新费 1%–3%、撤出费 1%–2%；没有截止时间。卖回是 `withdraw(token, shares, minPayout)`，CLI 用 `previewWithdraw` 减 0.1% 作 `minPayout`。
- 领取：`gang v3 claim` / `gang fair claim`；`gang v3 status` / `gang fair status` 显示「可领」和「已按交税时记账、还没卖出」的部分（按现价估算并标明）。
- **CLI 发布的那一刻就是对公众开放创建的那一刻**（网站上的打新和税收币页面只能查看，发币和打新要通过 CLI）。如果要分阶段放开，前一两周先不发布 CLI，只让合作方和内部用 `GANG_*_PAD` 环境变量发币。合约本身挡不住别人直接调用，所以这只能降低早期的资金规模，不是硬限制。

---

## 7. 上线检查

**上线当天（不等第一个币毕业）**：
- [ ] 在服务器上以 root 手动干跑一次 `keeper-tax-process.sh`（不带 `--broadcast`）：首行显示 `v3_pads=… fair_pads=…`，两个 handler 都 `known_tokens=…`，没有 ERROR
- [ ] `crontab -l` 里有 `*/10` 的 tax-process、`*/30` 的 keeper-health，所有任务都经 `cron-run.sh`
- [ ] 手动跑一次 `keeper-health.sh`：输出 `ok`；再故意让它报一次（例如临时把 `MIN_KEEPER_BNB` 设得比余额高），确认运维群收到报警
- [ ] `/v3/config`、`/fair/config`、`/burn`、`/health?strict=1` 都正常（§4）

**第一批真实交易后**：
- [ ] 合作方发第一个币（小额）：`TaxConfigured` 事件、接收地址收到第一笔 `TaxPaid`
- [ ] 一个打新 sale 跑通：打新、卖回（到手 = 打新价 × 份数 − 撤出费，与 `previewWithdraw` 一致）、打满发射、池子开盘价等于打新价
- [ ] 经 GangRouter 用 BNB 买和打新各一笔，结束后路由余额为 0
- [ ] 毕业 / 发射后第一笔池子卖出：日志里有 `TaxChunkSold(…, swapBack = true)`，卖家实际到手与 `previewSell` 一致；持有人 `pendingUnits` 在交税时增加、这批卖完后转成可领 `pending`
- [ ] 只有买单的一段时间后：keeper 日志里有分块 `process`，每块 ≤ `maxChunk`，攒下的税被卖完
- [ ] `collectPlatform` 成功，新手续费池的 80% 进入回购、20% 进入金库
- [ ] 网站 `/token/<地址>` 的税收币 / 打新面板与链上数据一致，分红块的可领金额与 `pending` 一致
- [ ] 漏洞赏金上线（如果决定开）

---

## 8. 日常运维

| 事项 | 什么时候 | 怎么做 |
|---|---|---|
| 外盘税 | 自动 | 每笔卖出顺带卖一小块（≤ 这笔卖单的 25%）；没有卖单时 keeper 每 10 分钟分块补位。每个币每区块一个额度（池子代币储备的 0.5%），卖出和 keeper 共用，所以同一区块里第二次 `process` 会回滚 `ZeroAmount`，价格比区块参考价低 2% 以上会回滚 `PriceBelowReference`——都是等下一个区块再卖，不是故障。健康检查在未卖税 > 池子代币储备 1% 时报警 |
| 分红兑现被拒（`HolderConversionDeferred`） | 健康检查报「pendingHolderQuote 卡住」 | 说明分红合约当时拒绝兑现。查清原因后任何人调 `handler.flushHolders(token)`；keeper 每次运行也会自动重试 |
| 平台那份被拒（`PlatformOwed`） | 健康检查报「owedPlatformOf 卡住」 | 说明手续费池拒收（operator 被撤等）。恢复后任何人调 `handler.flushPlatform(quote)`；keeper 自动重试 |
| `SwapBackFailed` | 健康检查报警 | 某个币卖单顺带的那一块失败了（卖单本身照常成交）。查池子状态（储备 / 余额不同步、报价币异常）；keeper 分块补位照常进行 |
| 接收地址欠款 | keeper 日志 / 健康检查里出现 `owedOf > 0` | 联系合作方处理收款问题；能收款之后 keeper 或任何人都能 `TaxHandlerV3.release(token)` |
| 接新合作方 | 需要时 | 多签 `TaxHandlerV3.list(地址, 名称)` |
| 非官方池子分红 | 发现某个 V3 币在别的 DEX 或 V3 池子里有大额持仓 | 多签 `SharedDividendVault.setExcluded(pool, true)`，**同一批交易里** `TaxHandlerV3.syncShares(token, pool, 0)` |
| 排除某个地址（G-01） | 需要时 | 同上：排除和 `syncShares(token, user, 0)` 放在同一批 |
| 打新撤出费欠款 | `FairMintPad.owedFee(报价币) > 0`（健康检查报警） | 说明手续费池拒收过核心。恢复后任何人 `flushFees(quote)` |
| 打新卖回时分红合约拒写 | 出现 `ShareWriteFailed`（核心或 handler 发出；按发出事件的合约过滤——任何人都能让 TaxHandlerV3 对打新币发出这个事件） | 份额会在下次同步时纠正；发射后 keeper 对这些地址调 `syncShares` |
| 改换币路由 | 需要时 | 多签 `proposeDexRouter(新路由)`，48 小时后 `acceptDexRouter()`；期间可 `cancelDexRouter()`；`address(0)` = 直接对池子卖 |
| 停滞的 sale | 网站「停滞」标记（7 天新增不到 10 份） | 无需处理：卖回免撤出费，任何人仍可把它打满 |

---

## 9. 出问题时能做什么

合约不可升级，也没有暂停开关。能用的手段只有这些：

| 情况 | 手段 | 效果 |
|---|---|---|
| 路由有问题 | 多签对两个核心 `setRouter(GANG_ROUTER, false)` | 路由入口立即关闭，直接买、直接打新照常 |
| 某个报价币有问题 | 没有链上开关：报价币不再走白名单（任意 18 位币都能发） | 只能在网站和 CLI 上不展示 / 拒绝这个报价币；给它设固定换算额只改变毕业额，不能禁用 |
| 某个接收地址有问题 | 多签 `TaxHandlerV3.delist(地址)` | 之后不能再用它发新币，已有的币照常打款 |
| 需要停止新发币 | 多签 `TokenDeployer.setLaunchpad(核心, false)`（该核心之后所有 `create` 都 revert）；网站和 CLI 下线入口 | 已有的币、曲线、sale 照常；分红合约里移除核心只停「新登记」，不影响已有币 |
| 合约本身有漏洞 | 重新部署修复版，网站和 CLI 切到新地址；旧合约里的钱只能等用户按原规则自己取回 | 已经在旧合约里的资金无法迁移 |

不要做的事：
- 撤掉核心在 SharedPlatformFeeBucket 的 operator：V3 内盘买卖、打新的打新和发射会全部 revert（审计说明 A-1）；打新卖回不受影响（撤出费记为 `owedFee`），外盘税照常卖出（平台那份记为 `owedPlatformOf`）。
- 调高分红门槛 `setMinimumShareBalance`：只影响之后登记的新币（门槛在登记时按币快照），已有币不变，没必要改。
- 指望「解绑 operator」来止损：分红合约的 operator 每个核心只能绑定一次，不能解绑、不能换。
- 用 `setKeeper` 换 keeper：处理合约和手续费池的 `setKeeper` 只能在部署时设一次，之后换人走 `proposeKeeper` → 48 小时 → `acceptKeeper`，期间可以 `cancelKeeper`（审计说明 §17 C-F6）。
- 把普通钱包设为分红排除：`setExcluded` 只接受有代码的地址（池子、锁仓合约等），排除钱包会回滚 `NotAContract`（§17 C-F5）。
