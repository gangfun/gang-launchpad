# 主网上线手册 · LaunchpadV3 税收币 + 打新 + GangRouter

- 日期：2026-10-26 Asia/Shanghai，2026-10-27 按合并后的合约重写（写于上线前，上线当天照着做，做完在每一步后面记下交易哈希和地址）
- **2026-10-27 晚：合约合并（审计说明 §20，规格 `docs/SPEC-GANG-MERGED-2026-10-27.md`）**。V3 和打新合成一个内盘 `GangLaunchpad`（外加两个外部库 `CurveLogic` / `FairLogic`）、一个外盘处理合约 `GangTaxHandler`、一种代币 `GangToken`、一个 `GangRouter`。本手册 §0、§2–§9 已按合并后的结构改写；**§1 部署步骤由部署脚本分支（`feat/merge-scripts`）改写，以它为准**。§2 自检里的变量名以 §1 脚本的输出为准。
- **2026-10-27 下午：V3 内盘不收税（§19，审计说明 §19）**。部署的是含这项改动的合约（分支 `feat/v3-no-curve-tax`，合入 `main` 后以 `main` 为准）；部署步骤、接线、参数都不变。
- 代码：gang-launchpad，合约冻结在审计说明 §18 的修复提交（方案 A 合并 + 第四轮内部审计修复 + 外盘税卖出时自动小额换 + 按税产生时记账 + 第五轮内部审计修复及其 review；审计说明 `docs/AUDIT-BRIEF-2026-10-26.md` §15–§18）。合入 `main` 后以 `main` 为准
- 服务端 / keeper：gangfun-server，`keeper/` 以分支 `feat/keeper-ops` 为准（合入 `main` 后以 `main` 为准）
- 链：BSC 主网（chainId 56）
- 谁做：部署钱包跑脚本；多签签 §3 的交易；服务端 / keeper 由能上服务器的人改 env

---

## 0. 上线前要齐的东西

| # | 项 | 谁给 | 用在哪 |
|---|---|---|---|
| 1 | 多签地址（BSC 上的 Safe，2/3 或 3/5，签名人分开保管） | 你 | `OWNER` |
| 2 | 合作方主网金库地址 + 名称；确认它能收报价币（合约不拒收 ERC-20、USDT 没拉黑它） | 合作方 | §3 `GangTaxHandler.list` |
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
forge test   # 全部通过（个数见审计说明 §18 的结果）
BSC_RPC_URL=https://rpc-bsc.48.club forge test --match-path 'test/fork/*'   # 主网分叉（publicnode 会丢历史状态，用 48.club）
BSC_RPC_URL=https://rpc-bsc.48.club forge test --match-path 'test/audit5/**' --threads 1   # 审计回归（部署脚本测试改进程环境变量，要单线程）
```

---

## 1. 部署（部署钱包，按顺序；第 2、3 步必须在多签 accept 之前跑完）

```sh
export DEPLOYER_PRIVATE_KEY=0x…            # 只在这台机器的这个 shell 里
export OWNER=0x<多签>
# owner 和部署钱包是同一个钱包时（2026-10-27 首发：0x4EEd…19d3 既部署又持有 owner），OWNER 填它自己并加：
# export MAINNET_OWNER_IS_DEPLOYER=true   # 不加时脚本回滚 OwnerRequired；此时没有 acceptOwnership 这一步
export RECIPIENT=0x<合作方金库> RECIPIENT_LABEL="<合作方名称>"   # 可选：也可以之后由多签 list
# 可选：BURNER=0x… / FEE_VAULT=0x…  新手续费池的回购合约 / 金库（不填或填 0 = 照抄 V2 手续费池的）。
#   部署时就按它接线，脚本最后也按它核对；第 2 步复用时必须给和第 1 步相同的值（或都不填），否则 WiringCheck("bucket burner")
L="--libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3"
G="--with-gas-price <当时主网 gas price，wei> --priority-gas-price <同上>"   # 必须显式给：公共节点偶尔估出 1 wei，交易会卡住
R=https://bsc-dataseed1.defibit.io

# 1) V3：新建五个共用合约（QuoteRegistry、SharedPlatformFeeBucket、SharedDividendVault、SharedMigrator、TokenDeployer），
#    再建 TaxHandlerV3 + LaunchpadV3，接线，最后 setMigrator
LAUNCHPAD_V3_MAINNET_OK=true forge script script/DeployLaunchpadV3.s.sol --rpc-url $R --broadcast --slow $L $G
#    日志里记下：V3_LAUNCHPAD、V3_TAX_HANDLER、QUOTE_REGISTRY、PLATFORM_BUCKET、DIVIDEND_VAULT、MIGRATOR、
#    TOKEN_DEPLOYER、AGENT_ID、USDT_REF_POOL，以及 V3_LAUNCHPAD 的部署区块

# 2) 打新：五个共用合约全部复用上一步的，外加 PEER_CORE=第一步的 V3_LAUNCHPAD（脚本要求五个要么全传要么全不传，
#    只传一部分直接回滚 PartialShared；PEER_CORE 用来核对 V3 核心用的是同一个 QUOTE_REGISTRY、PLATFORM_BUCKET，
#    在这个手续费池里是 operator，并挂在同一套分红 / 迁移 / 部署合约上，任何一项不对报 WiringCheck("peer core …")）
QUOTE_REGISTRY=0x… PLATFORM_BUCKET=0x… DIVIDEND_VAULT=0x… MIGRATOR=0x… TOKEN_DEPLOYER=0x… PEER_CORE=0x… \
FAIR_MINT_MAINNET_OK=true forge script script/DeployFairMint.s.sol --rpc-url $R --broadcast --slow $L $G
#    记下：FAIR_MINT_PAD、HOLDER_REWARD_HANDLER，以及 FAIR_MINT_PAD 的部署区块

# 3) 路由（两个核心的 owner 此时还是部署钱包，脚本直接 setRouter）
V3_PAD=0x… FAIR_PAD=0x… GANG_ROUTER_MAINNET_OK=true \
  forge script script/DeployGangRouter.s.sol --rpc-url $R --broadcast --slow $G
#    记下：GANG_ROUTER
```

- 第 2 步复用时，脚本要求部署钱包仍是这五个合约的 owner（多签还没 accept），否则 `NotDeployerOwned` 直接退出；`MIGRATOR` 的 factory 不对会 `WiringCheck("MIGRATOR factory")`。
- 两个脚本结束时都做接线自检（`_check` / `_checkCore` / `_checkBucket`），任何一项不对直接报错：核心在分红合约、迁移合约、代币部署合约的白名单里；分红合约的 operator 是本核心的 handler；分红合约排除了自己、迁移合约、手续费池；门槛 10,000 枚；bucket 的 operator 是核心和 handler、keeper 正确、回购合约和金库等于 `BURNER` / `FEE_VAULT`（不填时等于 V2 手续费池的）；复用时 `PEER_CORE` 的报价币登记合约和手续费池与传入的一致；Agent 准入开启；V3 单地址上限开启；接收地址已列入（若设了 `RECIPIENT`）。
- 处理合约和手续费池的 `setKeeper` 由脚本在部署时调用，**合约一生只能调一次**（`keeperSet()` 变为 true）；之后换 keeper 只能 `proposeKeeper` → 48 小时 → `acceptKeeper`，改成 0 再 `setKeeper` 的老路已经堵上（审计说明 §18 R5-4）。
- 主网**不登记任何报价币**：USDT 发币时用 `USDT_REF_POOL`（Pancake V3 USDT/WBNB 0.01% 池 `0x172f…f849`，30 分钟 TWAP）换算毕业额 / 募集额；CLI 对主网 USDT 默认用这个池子（`--ref-pool` 可省）。其它 18 位报价币由发币人自带参考池（V2 池读储备、V3 池读 TWAP，没有观测历史时读现价，见审计说明 §4.2 R2-1 的已接受风险）。
- 换币路由（Pancake V2 Router02 `0x10ED…024E`）在构造 handler 时传入；之后要改只能 `proposeDexRouter` → 48 小时 → `acceptDexRouter`（§8）。
- 每个脚本跑完，检查 `broadcast/<脚本>/56/run-latest.json` 里所有 receipt 的 status 都是 `0x1`，并确认文件里没有私钥，再提交到仓库。
- 部署完成后，部署钱包把剩余 BNB 转走，之后不再使用（§3 之后它不应再有任何权限，见 §2 的核对）。

---

## 2. 部署后、多签接受前的链上自检

合并后只有一个内盘、一个处理合约。下面的变量：`PAD`（GangLaunchpad）、`TAX_HANDLER`（GangTaxHandler）、`CURVE_LOGIC` / `FAIR_LOGIC`（两个库）、`GANG_ROUTER`，以及共用的 `QUOTE_REGISTRY`、`PLATFORM_BUCKET`、`DIVIDEND_VAULT`、`MIGRATOR`、`TOKEN_DEPLOYER`（保留时）。名字以 §1 脚本日志为准。

```sh
c() { cast call "$@" --rpc-url $R; }
ALL="$PAD $TAX_HANDLER $QUOTE_REGISTRY $PLATFORM_BUCKET $DIVIDEND_VAULT $MIGRATOR $TOKEN_DEPLOYER"   # 去掉 TokenDeployer 时少一个
# 带 owner 的合约：owner 还是部署钱包，pendingOwner 是多签（MAINNET_OWNER_IS_DEPLOYER=true 时 owner 就是部署钱包、pendingOwner 为 0）
for a in $ALL; do echo $a $(c $a "owner()(address)") $(c $a "pendingOwner()(address)"); done
# 内盘：两种币都在这一个地址上
c $PAD "taxHandler()(address)"; c $PAD "dividendVault()(address)"; c $PAD "platformBucket()(address)"; c $PAD "migrator()(address)"
c $PAD "agentIdRegistry()(address)"   # 0x60B9…022F（真实 Agent ID）
c $PAD "agentGateEnabled()(bool)"; c $PAD "walletCapEnabled()(bool)"   # 都 true
c $PAD "TAXED_MIN_SHARE()(uint256)"; c $PAD "MIN_SHARE_BALANCE()(uint256)"   # 两个都是 10000e18
# 两个库：内盘字节码里链接的就是这两个地址，且它们都链接了主网 PoolCheck（核对方法以 §1 脚本的自检为准）
cast code $CURVE_LOGIC --rpc-url $R | wc -c; cast code $FAIR_LOGIC --rpc-url $R | wc -c
# 处理合约：一次性的内盘、keeper、换币路由
c $TAX_HANDLER "launchpad()(address)"   # = PAD
c $TAX_HANDLER "keeper()(address)"; c $TAX_HANDLER "keeperSet()(bool)"; c $TAX_HANDLER "dexRouter()(address)"
# 手续费池：2 个 operator（内盘、处理合约）、金库、回购、keeper
for o in $PAD $TAX_HANDLER; do c $PLATFORM_BUCKET "operators(address)(bool)" $o; done
c $PLATFORM_BUCKET "burner()(address)"; c $PLATFORM_BUCKET "feeVault()(address)"; c $PLATFORM_BUCKET "keeper()(address)"
c $PLATFORM_BUCKET "keeperSet()(bool)"   # true：setKeeper 已用掉，之后换人只能走 48 小时时间锁
# 分红合约：一个内盘只绑一个 operator（只能绑一次），排除名单，门槛
c $DIVIDEND_VAULT "operatorFor(address)(address)" $PAD      # = TAX_HANDLER
for x in $DIVIDEND_VAULT $MIGRATOR $PLATFORM_BUCKET; do c $DIVIDEND_VAULT "excluded(address)(bool)" $x; done   # 都 true
c $DIVIDEND_VAULT "minimumShareBalanceOf(address)(uint256)" $PAD        # 10000e18
# 迁移合约 / 代币部署合约：内盘在白名单里
c $MIGRATOR "launchpads(address)(bool)" $PAD
c $TOKEN_DEPLOYER "launchpads(address)(bool)" $PAD    # 去掉 TokenDeployer 时跳过
# 路由：v3() 和 fair() 都是同一个内盘；内盘把它列为路由
c $GANG_ROUTER "v3()(address)"; c $GANG_ROUTER "fair()(address)"   # 都 = PAD
c $PAD "routers(address)(bool)" $GANG_ROUTER
```

---

## 3. 多签要签的交易

**必须（从这一刻起所有合约归多签）**：对下面每个带 owner 的合约各调一次 `acceptOwnership()`（`MAINNET_OWNER_IS_DEPLOYER=true` 时没有这一步，之后另行 `transferOwnership(多签)`）。合并前是 9 个，合并后是 6 个，保留 TokenDeployer 时 7 个：

| # | 合约 | 地址 | 多签之后能做什么（详见审计说明 §4、§20，规格 §8） |
|---|---|---|---|
| 1 | GangLaunchpad | `PAD` | 路由名单、准入（V3 立即生效；打新只影响之后的 sale）、V3 单地址上限、参考池相关设置（V3 池子工厂、TWAP 窗口、中转池、pair 工厂） |
| 2 | GangTaxHandler | `TAX_HANDLER` | 接收地址白名单 `list` / `delist`、keeper、换币路由（48 小时时间锁）；两种币的外盘税都在这里 |
| 3 | QuoteRegistry（共用） | `QUOTE_REGISTRY` | 给某个报价币设固定换算额（可选；设了就优先于参考池） |
| 4 | SharedPlatformFeeBucket（共用） | `PLATFORM_BUCKET` | operator、金库、回购合约、keeper（换人要 `proposeKeeper` → 48 小时 → `acceptKeeper`）、7 天应急出口；只有固定路径的 `collectPlatform`，没有 `collectPlatformSmart`；多签自己也能直接 `collectPlatform` |
| 5 | SharedDividendVault（共用） | `DIVIDEND_VAULT` | 内盘白名单（移除只停新登记）、排除地址、新币的门槛；operator 已绑定，不能再改 |
| 6 | SharedMigrator（共用） | `MIGRATOR` | 只能再加内盘，不能移除 |
| 7 | TokenDeployer（保留时） | `TOKEN_DEPLOYER` | 能部署代币的内盘名单 |

两个库（`CurveLogic` / `FairLogic`）和 GangRouter 没有 owner。

接受后，再跑一遍 §2 的 owner 循环，确认每个合约的 owner 都是多签，pendingOwner 都是 `0x0`。**部署钱包此后不应有任何角色**：它不是任何合约的 owner、keeper 或 operator（keeper 是 `KEEPER` 默认的 `0xB6f1…cFc7`）。

**合作方**（部署时没设 `RECIPIENT` 的话）：`GangTaxHandler.list(<合作方金库>, "<名称>")`。

**建议，不挡上线**：
- V2 那几份（owner 现为普通钱包 `0x4EEd…`）：`0x4EEd` 对 V2 发射台、分账合约 `0xBDDd…F111`、QuoteRegistry `0x053C…060D`、DividendVault 分别 `transferOwnership(多签)`，多签逐个 `acceptOwnership()`。
- 回购合约 GangBuybackBurner `0x3812…363B`（owner 也是 `0x4EEd`，能改兑换路由，从而截走回购那一部分）：同样转给多签。

---

## 4. 服务端（正式站 indexer.env，不进仓库）

合并后 V3 和打新是同一个内盘：两组变量填**同一个地址、同一个部署区块**。索引器的两条轨道各扫一遍同一个地址，按事件 topic0 分开（两个 `Created` 是不同的重载，topic0 不同）。

```
GANG_FAIR_PAD=<PAD>
GANG_FAIR_START_BLOCK=<PAD 部署区块>
GANG_FAIR_CHAIN_ID=56
GANG_FAIR_RPC_URLS=<§0 #5 的 RPC>
GANG_V3_PAD=<PAD>
GANG_V3_START_BLOCK=<PAD 部署区块>
GANG_V3_CHAIN_ID=56
GANG_V3_RPC_URLS=<§0 #5 的 RPC>
```

服务端要先合入合并配套的改动（审计说明 §20.10；合并方案 §8.1）：
- 处理合约上两种币共用的基类事件（`TaxChunkSold`、`HolderConversionDeferred`、`ShareWriteFailed`）按币过滤到各自的轨道，否则会重复记账。
- `postgrad_events` 的唯一键加上轨道（数据库迁移）：按报价币记的 `PlatformOwed` / `PlatformFlushed` 两条轨道都要能落库。

重启索引服务后检查：
- `/fair/config`、`/v3/config` 返回 `enabled: true`，两个接口里的内盘地址、区块、`taxHandler`、`vault` 都相同。
- `/burn` 列出了新的 SharedPlatformFeeBucket（索引器从内盘的 `platformBucket()` 自动发现，按地址去重）。
- 一个 V3 币只出现在 V3 列表里，一个打新币只出现在打新列表里。
- `/health?strict=1` 返回 200（健康检查会轮询它）。

网站上「打新」「税收币」入口由这两个接口决定，不用另外改前端。

---

## 5. keeper（正式站 keeper/.env 与 crontab，不进仓库）

```
KEEPER_PRIVATE_KEY=…                       # keeper 钱包 0xB6f1…cFc7
BSC_RPC_URL=<发交易用的 RPC，最好私有>
LOGS_RPC=<§0 #5，必须能查日志；keeper 启动时先探测，查不了直接 exit 9>
# label:地址@部署区块。keeper 从内盘读 taxHandler() / platformBucket()，处理合约和手续费池都不用另外填（按地址去重）
V3_PADS=v3:<PAD>@<PAD 部署区块>             # 合并后两条指向同一个内盘
FAIR_PADS=fair:<PAD>@<PAD 部署区块>
SLIPPAGE_BPS=150                           # 每块的最低成交额 = 这一块的报价 × (1 − 1.5%)
MAX_CHUNKS_PER_RUN=20                      # 每个币每次运行最多卖 20 块（每块 ≤ 池子代币储备 0.5%）
ALERT_TG_CHAT_ID=<§0 #6>                   # 报警发运维群；不配时报警打到 stderr 并非零退出
```

- `TAX_HANDLERS` / `TAX_ROUTERS` 留空：内盘的处理合约会自动接上（GangTaxHandler 同时负责两种币的外盘税和 V3 接收地址欠款补发）。
- **keeper 脚本要先合入合并配套的改动**：两个份额补写循环原来用 `launchpadOf == pad && quoteOf != 0` 挑币，合并后两种币都满足。V3 的循环要加 `kindOf(t) == 1`，打新的加 `kindOf(t) == 2`（读内盘的 `kindOf(address)(uint8)`），否则会按 V3 的余额规则处理打新币，反复「补写失败」后报警。
- 三个列表全空时 `keeper-tax-process.sh` 以 7 退出并报警；只有确实不该跑的机器才设 `TAX_PROCESS_DISABLED=1`。
- 平台费：`keeper-v2-platform.sh` 会从内盘读出新的 SharedPlatformFeeBucket、从索引器取报价币清单，不用往 `PLATFORM_BUCKETS` 里手填；它只调固定路径的 `collectPlatform`（新手续费池没有 `collectPlatformSmart`）。V2 那三个分账合约照旧在默认清单里（V2 的分红 / 存量税按用户决定不处理，脚本不会对 V2 币调 `process`）。
- crontab 用仓库里的 `keeper/crontab.txt`：所有任务都经 `cron-run.sh` 包一层（非零退出就报警）；外盘税 `*/10 * * * *`；健康检查 `keeper-health.sh` 每 30 分钟。
- keeper 地址必须等于 GangTaxHandler 和新手续费池的 `keeper()`（部署脚本已按 `KEEPER` 设好）。
- 后续建议：发交易单独用私有 RPC（`BSC_RPC_URL`），读和查日志用 `LOGS_RPC`，降低分块卖出被夹的风险。
- `collectPlatform(quote, minGangOut)` 的 `minGangOut` 合约不设下限，完全靠 keeper 按链上报价给（审计说明 K-20）：keeper 热钱包被盗时，这一笔回购可被夹。keeper 钱包只放够付 gas 的 BNB；怀疑被盗时多签立即 `proposeKeeper(新地址)`（48 小时后 `acceptKeeper`），在此之前多签可以自己 `collectPlatform`，并在服务器上停掉 keeper 的 cron。时间锁约束的是**换 keeper**，不约束多签：多签本来就能直接 `process` / `collectPlatform`。

---

## 6. CLI

- 合并后 `gang v3` 和 `gang fair` 共用一个内盘地址。把 `skill/gang-cli/src/gangpad.js` 里的 `MAINNET_GANG.pad` / `MAINNET_GANG.router` 填成上面的 `PAD` / `GANG_ROUTER`（目前留空，可用 `GANG_PAD` / `GANG_ROUTER` 环境变量临时指定；旧的 `GANG_V3_PAD` / `GANG_FAIR_PAD` 仍可用）。
- 测试网第 8 套部署后，同一个文件里填 `TESTNET_SET8.pad` / `TESTNET_SET8.router`；没填时测试网仍用第 7 套。
- `gang v3 info` 拿到打新币（或 `gang fair info` 拿到 V3 币）时，CLI 按内盘的 `kindOf` 提示改用另一个命令。
- 更新文档里「只在测试网」的说法，升版本号，然后发布。
- 打新的参数范围（合约强制，CLI 同样校验）：募集 5–50 BNB 等值、单地址上限 0.25%–0.5%、出局线 30%–80%、打新费 1%–3%、撤出费 1%–2%；没有截止时间。卖回是 `withdraw(token, shares, minPayout)`，CLI 用 `previewWithdraw` 减 0.1% 作 `minPayout`。
- 领取：`gang v3 claim` / `gang fair claim`；`gang v3 status` / `gang fair status` 显示「可领」和「已按交税时记账、还没卖出」的部分（按现价估算并标明）。
- **CLI 发布的那一刻就是对公众开放创建的那一刻**（网站上的打新和税收币页面只能查看，发币和打新要通过 CLI）。如果要分阶段放开，前一两周先不发布 CLI，只让合作方和内部用 `GANG_*_PAD` 环境变量发币。合约本身挡不住别人直接调用，所以这只能降低早期的资金规模，不是硬限制。

---

## 7. 上线检查

**上线当天（不等第一个币毕业）**：
- [ ] 在服务器上以 root 手动干跑一次 `keeper-tax-process.sh`（不带 `--broadcast`）：首行显示 `v3_pads=… fair_pads=…`（同一个地址），处理合约只出现一次、`known_tokens=…`，没有 ERROR；份额补写循环只列 V3 币 / 只列打新币（`kindOf` 过滤生效）
- [ ] `crontab -l` 里有 `*/10` 的 tax-process、`*/30` 的 keeper-health，所有任务都经 `cron-run.sh`
- [ ] 手动跑一次 `keeper-health.sh`：输出 `ok`；再故意让它报一次（例如临时把 `MIN_KEEPER_BNB` 设得比余额高），确认运维群收到报警
- [ ] `/v3/config`、`/fair/config`、`/burn`、`/health?strict=1` 都正常（§4）

**第一批真实交易后**：
- [ ] 合作方发第一个币（小额）：`TaxConfigured` 事件；内盘买卖只扣 1%（`Buy` / `Sell` 里 `tax` = 0，接收地址这时收不到钱，§19）；毕业后第一笔外盘税卖出后接收地址收到第一笔 `TaxPaid`
- [ ] 一个打新 sale 跑通：打新、卖回（到手 = 打新价 × 份数 − 撤出费，与 `previewWithdraw` 一致）、打满发射、池子开盘价等于打新价
- [ ] 经 GangRouter 用 BNB 买和打新各一笔，结束后路由余额为 0
- [ ] 毕业 / 发射后第一笔池子卖出：日志里有 `TaxChunkSold(…, swapBack = true)`，卖家实际到手与 `previewSell` 一致；持有人 `pendingUnits` 在交税时增加、这批卖完后转成可领 `pending`
- [ ] 只有买单的一段时间后：keeper 日志里有分块 `process`，每块 ≤ `maxChunk`，攒下的税被卖完
- [ ] `collectPlatform` 成功，新手续费池的 80% 进入回购、20% 进入金库
- [ ] 网站 `/token/<地址>` 的税收币 / 打新面板与链上数据一致，分红块的可领金额与 `pending` 一致
- [ ] 内盘 `kindOf`：V3 币返回 1、打新币返回 2；V3 币上调 `withdraw` 和打新币上调 `buy` 都回滚
- [ ] 漏洞赏金上线（如果决定开）

---

## 8. 日常运维

| 事项 | 什么时候 | 怎么做 |
|---|---|---|
| 外盘税 | 自动 | 每笔卖出顺带卖一小块（≤ 这笔卖单的 25%）；没有卖单时 keeper 每 10 分钟分块补位。每个币每区块一个额度（池子代币储备的 0.5%），卖出和 keeper 共用，所以同一区块里第二次 `process` 会回滚 `ZeroAmount`，价格比区块参考价低 2% 以上会回滚 `PriceBelowReference`——都是等下一个区块再卖，不是故障。健康检查在未卖税 > 池子代币储备 1% 时报警 |
| 分红兑现被拒（`HolderConversionDeferred`） | 健康检查报「pendingHolderQuote 卡住」 | 说明分红合约当时拒绝兑现。查清原因后任何人调 `handler.flushHolders(token)`；keeper 每次运行也会自动重试 |
| 平台那份被拒（`PlatformOwed`） | 健康检查报「owedPlatformOf 卡住」 | 说明手续费池拒收（operator 被撤等）。恢复后任何人调 `handler.flushPlatform(quote)`；keeper 自动重试 |
| `SwapBackFailed` | 健康检查报警 | 某个币卖单顺带的那一块失败了（卖单本身照常成交）。查池子和报价币状态（报价币暂停 / 拉黑了池子或处理合约、报价币异常）；池子里有未同步的余额本身不会让它失败（处理合约会先收走、卖完再退回，审计说明 §18 R5-O1）；keeper 分块补位照常进行 |
| 用户反馈卖出回滚 `SellDuringFlashSwap` | 用户 / 聚合器报错 | 有意为之（审计说明 §18 R5-1a、K-21）：在 Pancake 闪电兑换回调里付币的卖出一律拒绝。让用户经 Router02 或 CLI / 网站卖出。若池子的报价币余额长期低于储备（会负 rebase 的报价币），任何人对池子调一次 `sync()` 即可恢复 |
| 链上看到处理合约和池子之间成对的转账 | 有人加流动性到一半、或往池子转了币时的卖出 | 正常（审计说明 §18 R5-O1）：`swapBack` 把池子里多出的两边先 `skim` 到处理合约、卖完这一块再原样转回。索引 / 对账时这对转账不算税币流水；加流动性两种顺序、任何金额都不受影响 |
| 接收地址欠款 | keeper 日志 / 健康检查里出现 `owedOf > 0` | 联系合作方处理收款问题；能收款之后 keeper 或任何人都能 `GangTaxHandler.release(token)` |
| 接新合作方 | 需要时 | 多签 `GangTaxHandler.list(地址, 名称)` |
| 非官方池子分红 | 发现某个 V3 币在别的 DEX 或 V3 池子里有大额持仓 | 多签 `SharedDividendVault.setExcluded(pool, true)`，**同一批交易里** `GangTaxHandler.syncShares(token, pool, 0)` |
| 排除某个地址（G-01） | 需要时 | 同上：排除和 `syncShares(token, user, 0)` 放在同一批 |
| 打新撤出费欠款 | `GangLaunchpad.owedFee(报价币) > 0`（健康检查报警） | 说明手续费池拒收过内盘。恢复后任何人 `flushFees(quote)` |
| 打新卖回时分红合约拒写 | 出现 `ShareWriteFailed`（内盘或 handler 发出；按发出事件的合约过滤——任何人都能让 GangTaxHandler 发出这个事件；合并后两种币的 handler 事件来自同一个地址，再按币的 `kindOf` 分开） | 份额会在下次同步时纠正；发射后 keeper 对这些地址调 `syncShares` |
| 改换币路由 | 需要时 | 多签 `proposeDexRouter(新路由)`，48 小时后 `acceptDexRouter()`；期间可 `cancelDexRouter()`；`address(0)` = 直接对池子卖 |
| 停滞的 sale | 网站「停滞」标记（7 天新增不到 10 份） | 无需处理：卖回免撤出费，任何人仍可把它打满 |

---

## 9. 出问题时能做什么

合约不可升级，也没有暂停开关。能用的手段只有这些：

| 情况 | 手段 | 效果 |
|---|---|---|
| 路由有问题 | 多签对内盘 `setRouter(GANG_ROUTER, false)`（合并后只有一个内盘，一笔就关掉两种币的路由入口） | 路由入口立即关闭，直接买、直接打新照常 |
| 某个报价币有问题 | 没有链上开关：报价币不再走白名单（任意 18 位币都能发） | 只能在网站和 CLI 上不展示 / 拒绝这个报价币；给它设固定换算额只改变毕业额，不能禁用 |
| 某个接收地址有问题 | 多签 `GangTaxHandler.delist(地址)` | 之后不能再用它发新币，已有的币照常打款 |
| 需要停止新发币 | 保留 TokenDeployer 时：多签 `TokenDeployer.setLaunchpad(PAD, false)`（之后所有 `create` 都 revert，**V3 和打新一起停**，合并后没法只停一种）；改用 TokenFactory 库时没有这个开关【待定】。网站和 CLI 下线入口 | 已有的币、曲线、sale 照常；分红合约里移除核心只停「新登记」，不影响已有币 |
| 合约本身有漏洞 | 重新部署修复版，网站和 CLI 切到新地址；旧合约里的钱只能等用户按原规则自己取回 | 已经在旧合约里的资金无法迁移 |

不要做的事：
- 撤掉内盘在 SharedPlatformFeeBucket 的 operator：V3 内盘买卖、打新的打新和发射会全部 revert（审计说明 A-1）；打新卖回不受影响（撤出费记为 `owedFee`），外盘税照常卖出（平台那份记为 `owedPlatformOf`）。
- 调高分红门槛 `setMinimumShareBalance`：只影响之后登记的新币（门槛在登记时按币快照），已有币不变，没必要改。
- 指望「解绑 operator」来止损：分红合约的 operator 每个内盘只能绑定一次，不能解绑、不能换。
- 用 `setKeeper` 换 keeper：处理合约和手续费池的 `setKeeper` 一生只能调一次（部署脚本已经用掉），先 `proposeKeeper(0)` 再 `setKeeper` 也不行；换人走 `proposeKeeper` → 48 小时 → `acceptKeeper`，期间可以 `cancelKeeper`（审计说明 §17 C-F6、§18 R5-4）。
- 把普通钱包设为分红排除：`setExcluded` 只接受有代码的地址（池子、锁仓合约等），排除钱包会回滚 `NotAContract`；EIP-7702 委托过的钱包（代码是 23 字节的 `0xef0100…`）也按普通钱包处理（§17 C-F5、§18 R5-2）。
