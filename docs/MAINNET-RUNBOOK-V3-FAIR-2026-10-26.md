# 主网上线手册 · LaunchpadV3 税收币 + 打新 + GangRouter

- 日期：2026-10-26 Asia/Shanghai，2026-10-27 按合并后的合约重写（写于上线前，上线当天照着做，做完在每一步后面记下交易哈希和地址）
- **2026-10-27 晚：合约合并（审计说明 §20，规格 `docs/SPEC-GANG-MERGED-2026-10-27.md`）**。V3 和打新合成一个内盘 `GangLaunchpad`（外加两个外部库 `CurveLogic` / `FairLogic`）、一个外盘处理合约 `GangTaxHandler`、一种代币 `GangToken`、一个 `GangRouter`。本手册 §0、§2–§9 已按合并后的结构改写；**§1 部署步骤由部署脚本分支（`feat/merge-scripts`）改写，以它为准**。§2 自检里的变量名以 §1 脚本的输出为准。
- **2026-10-27 下午：V3 内盘不收税（§19，审计说明 §19）**。部署的是含这项改动的合约（分支 `feat/v3-no-curve-tax`，合入 `main` 后以 `main` 为准）；部署步骤、接线、参数都不变。
- **2026-10-27 晚：GangRouter 改为可升级（审计说明 §21）**。路由是 `TransparentUpgradeableProxy` 背后的实现，代理地址固定，ProxyAdmin 归一个 48 小时的 `TimelockController`，时间锁只有 Safe 能提案 / 执行 / 取消；另加 Pancake V2 外盘买卖入口。分支 `feat/upgradeable-router`。§1 的部署步骤、自检，§2、§3 已按它更新；升级流程见 §10，外盘买卖见 §11。
- 代码：gang-launchpad，合约冻结在审计说明 §18 的修复提交（方案 A 合并 + 第四轮内部审计修复 + 外盘税卖出时自动小额换 + 按税产生时记账 + 第五轮内部审计修复及其 review；审计说明 `docs/AUDIT-BRIEF-2026-10-26.md` §15–§18）。合入 `main` 后以 `main` 为准
- 服务端 / keeper：gangfun-server，索引器和 `keeper/` 以分支 `feat/one-pad` 为准（它才支持合并内盘和 keeper 的 `PADS=`；合入 `main` 后以 `main` 为准）
- 链：BSC 主网（chainId 56）
- 谁做：部署钱包跑脚本；多签签 §3 的交易；服务端 / keeper 由能上服务器的人改 env

---

## 0. 上线前要齐的东西

| # | 项 | 谁给 | 用在哪 |
|---|---|---|---|
| 1 | 多签：Safe 1.5.0 `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`（2/3 签名生效；2026-10-27 起平台 owner，V1 / V2 / S / U 的老合约已对它 `transferOwnership`，等它 accept） | 已定 | `OWNER` |
| 2 | 合作方主网金库地址 + 名称；确认它能收报价币（合约不拒收 ERC-20、USDT 没拉黑它） | 合作方 | §3 `GangTaxHandler.list` |
| 3 | 合作方用的报价币（WBNB 或 USDT）。USDT 不用设换算额：发币时用 USDT/WBNB 池子换算（§1） | 合作方 | 发币参数 |
| 4 | 部署钱包：一个新热钱包，备 ≥ 0.03 BNB（`DeployGang` 一个脚本 35 笔、约 2,850 万 gas，按 0.1 gwei 估约 0.003 BNB，留余量） | 你 | `DEPLOYER_PRIVATE_KEY` |
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

## 1. 部署（部署钱包，一个脚本跑完）

2026-10-27 起合约已合并：一个内盘 `GangLaunchpad`（V3 曲线和打新都在里面，外部库 `CurveLogic` / `FairLogic`）、一个外盘税处理 `GangTaxHandler`、一个代币 `GangToken`。原来的 `DeployLaunchpadV3` / `DeployFairMint` / `DeployGangRouter` 三个脚本和共用合约复用（`QUOTE_REGISTRY` … `PEER_CORE`）已删除，改为一个脚本 `script/DeployGang.s.sol`。

```sh
set -a; . ~/Desktop/gang-mainnet.env; set +a   # 只放 DEPLOYER_PRIVATE_KEY；不要 echo
export OWNER=0x2866369F7acEFC9760bdE7779362fae5cD68B41E   # 平台 Safe（2/3）；主网必须给，不给回滚 OwnerRequired；填别的地址日志打 WARN
# 部署钱包仍是 0x4EEd…19d3。不要设 MAINNET_OWNER_IS_DEPLOYER（owner 不再是部署钱包；设了而 OWNER ≠ 部署钱包会回滚 OwnerNotDeployer）。
# 脚本结束时 7 个合约 owner = 部署钱包、pendingOwner = Safe，日志列出这 7 个地址并打印一份 Safe Transaction Builder JSON（§3）
# 可选：
#   RECIPIENT=0x<合作方金库> RECIPIENT_LABEL="<名称>"   部署时就列入白名单；不填则之后由 owner handler.list
#   KEEPER=0x…      默认 0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7（201 上 keeper 私钥对应的地址）；主网填别的地址必须再加
#                   KEEPER_OVERRIDE_OK=true，否则回滚 KeeperNotDefault（setKeeper 一生一次，填错要走 48 小时时间锁）
#   BURNER=0x… / FEE_VAULT=0x…   新手续费池的回购合约 / 金库；不填或填 0 = 照抄 V2 手续费池 0xBDDd…F111 的。
#                   部署时就按它接线，脚本最后也按它核对（R5-5）；主网覆盖成和 V2 不同的地址时日志打 WARN 行
#   TWAP_WINDOW=1800   V3 参考池 TWAP 窗口（秒），默认 1800，不能小于 600（否则回滚 TwapWindowTooShort）
#   ROUTER_TIMELOCK_DELAY   路由时间锁延迟（秒）。主网固定 172800（48 小时），不设即可；设成别的值回滚 MainnetTimelockDelay
L="--libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3"
G="--with-gas-price <当时主网 gas price，wei> --priority-gas-price <同上>"   # 必须显式给：公共节点偶尔估出 1 wei，交易会卡住
R=https://bsc-dataseed1.defibit.io

# 1) 先不带 --broadcast 模拟一遍（主网模拟不需要 GANG_MAINNET_OK），看日志和自检都通过
forge script script/DeployGang.s.sol --rpc-url $R $L
# 2) 广播
GANG_MAINNET_OK=true forge script script/DeployGang.s.sol --rpc-url $R --broadcast --slow $L $G
```

脚本做的事（一次运行，主网 38 笔交易（比可升级路由之前多 3 笔：时间锁、代理、分红合约排除代理），forge 估算约 3,161 万 gas，按 0.1 gwei 约 0.0032 BNB；2026-10-27 晚用可升级路由版本在主网 fork 上 dry-run 实测，OWNER = Safe，自检通过）：

| 步骤 | 内容 |
|---|---|
| 库 | forge 先部署两个外部库 `CurveLogic`、`FairLogic`（见下面「外部库」）；`PoolCheck` 按地址链接线上 `0xd2B1…bDb3`，不重新部署 |
| 部署 | `QuoteRegistry` → `SharedPlatformFeeBucket`（金库 = `FEE_VAULT`）→ `SharedDividendVault` → `SharedMigrator`（Pancake V2 factory）→ `TokenDeployer` → `GangTaxHandler`（换币路由 = Pancake V2 Router02）→ `GangLaunchpad` → 路由：`GangRouter` 实现（构造时锁死）→ `TimelockController(48 小时, proposer = executor = Safe, admin = 0)` → `TransparentUpgradeableProxy(实现, 时间锁, initialize(pad, WBNB, Pancake V2 Router02))`（代理在构造时初始化，并自动部署 `ProxyAdmin`，owner = 时间锁） |
| 手续费池 | `setBurner(BURNER)`、`setKeeper(KEEPER)`（一生一次）、operator = pad 和 handler |
| 分红金库 | `setLaunchpad(pad)`（同时排除 pad）、门槛 10,000 枚、`setOperator(handler, pad)`（只能绑一次，同时排除 handler）、排除 migrator、手续费池和路由代理（金库自己在构造时已排除；路由只在一笔外盘卖出里过手代币，排除后不为它写份额，每笔省约 9 万 gas） |
| 迁移 / 代币部署 | `migrator.addLaunchpad(pad)`、`tokenDeployer.setLaunchpad(pad, true)` |
| 处理合约 | `setLaunchpad(pad)`（一次性）、`setKeeper(KEEPER)`（一生一次）、`list(RECIPIENT)`（设了才做） |
| 内盘 | `setRouter(路由代理)`（只登记代理，不登记实现）、`setAgentGate(true, Agent ID 0x60B9…022F)`、`setV3Factory(Pancake V3)`、TWAP 窗口、`setBridgePool(USDT, USDT/WBNB V3)` |
| **最后** | `pad.setMigrator(migrator)`：开放发币（A-1：前面全部接好之后才开放） |
| 交接 | 7 个合约 `transferOwnership(OWNER)`（OWNER = 部署钱包时跳过） |

日志里记下（`--- GANG ADDRESSES ---` 一段）：`GANG_PAD`、`GANG_PAD_BLOCK`、`GANG_TAX_HANDLER`、`GANG_ROUTER`（代理：内盘登记它、用户调用它，以后升级也不变）、`GANG_ROUTER_IMPL`、`GANG_ROUTER_PROXY_ADMIN`、`GANG_ROUTER_TIMELOCK`、`QUOTE_REGISTRY`、`PLATFORM_BUCKET`、`DIVIDEND_VAULT`、`MIGRATOR`、`TOKEN_DEPLOYER`、`AGENT_ID`、`USDT_REF_POOL`。后面的 `--- server env ---` 一段（`# indexer.env` / `# keeper/.env` 两行注释下面每行一条，可以原样贴）就是 §4、§5 要填的行。
`GANG_PAD_BLOCK` 是模拟时的区块，不晚于实际上链区块，可以直接当索引 / keeper 的起始区块；要精确值看 `broadcast/DeployGang.s.sol/56/run-latest.json` 里 `GangLaunchpad` 那笔 receipt 的 `blockNumber`。

**脚本结束时的自检 `_check`**（任何一项不对直接报 `WiringCheck("<项>")`，广播的交易已经上链，但不要往下做，先查原因）：
- pad：registry / vault / bucket / handler / tokenDeployer / WBNB / pairFactory 都是本次部署的；`migrator` 已设；Agent 准入开启且是真实 Agent ID；单地址上限开启；V3 factory、TWAP 窗口、USDT 中转池正确；路由已列入；两个门槛常量 `TAXED_MIN_SHARE == MIN_SHARE_BALANCE == 10,000 枚`。
- 外部库：`graduationAmountOf(WBNB)` 走 `CurveLogic` 返回 15 BNB、`previewCreate(WBNB, 15 BNB)` 走 `FairLogic` 返回 15 BNB / 每份 0.0015，证明两个库都已部署并链接（库地址没有代码时 delegatecall 返回空，这两个调用会失败）；主网再走一遍 USDT：`graduationAmountOf(USDT, USDT_REF_POOL) > 0`、`previewCreate(USDT, USDT_REF_POOL, 5 BNB)` 不回滚，证明库里链接的 PoolCheck 可用。
- 只有真 pad 才有的：`CURVE_SUPPLY() == 8 亿`、`MINT_SUPPLY() == 5 亿`、`checkTaxConfig` 对一个合法配置返回 `(true, "")`、对买税 6% 返回 `(false, 原因)`（旧的部署用 stub 过不了这几项；主网另核对 Agent ID 是 `0x60B9…022F`）。
- 上线参数（审计说明 §22）：`MIN_CAP_BPS == 25`、`MAX_CAP_BPS == 100`、`MIN_HOLD_BPS == 6000`、`MAX_HOLD_BPS == 9000`；`checkTaxConfigFor(x, 买卖税各 3%、分红 0、接收地址 = x)` 返回 `(true, "")`，x 是一个没人列入白名单的地址（证明发币人自己当接收地址这条规则在线上合约里）。报 `WiringCheck("pad fair bounds")` / `WiringCheck("pad.checkTaxConfigFor")` 说明部署的不是本分支的代码。
- 处理合约：`launchpad == pad`、vault / bucket 正确、keeper 正确且 `keeperSet`、换币路由是 Router02 且没有待生效的提议、接收地址已列入（设了 `RECIPIENT` 时）。
- 分红金库：pad 在白名单、门槛 10k、operator 双向绑定、排除了自己 / migrator / bucket / pad / handler / 路由代理。
- 手续费池：operator 是 pad 和 handler、keeper 正确且 `keeperSet`、金库和回购合约等于 `FEE_VAULT` / `BURNER`（不填时等于 V2 手续费池的；主网必须有回购合约）。
- 迁移合约的 factory 是 Pancake V2、pad 在迁移合约和代币部署合约的白名单里；主网没有登记 USDT 的固定换算额。
- 路由（审计说明 §21.2）：
  - 代理的 ERC-1967 实现槽 = `GANG_ROUTER_IMPL`，实现的代码就是本仓库这一版 `GangRouter`（codehash），实现已锁死（初始化槽 = `uint64` 最大值、`pad()` = 0），不能再被初始化；
  - 管理员槽 = `GANG_ROUTER_PROXY_ADMIN`，它是代理构造时自己创建的那个（代理的第一个 CREATE）、代码是标准 OZ ProxyAdmin，owner = `GANG_ROUTER_TIMELOCK`；
  - 代理地址上的代码就是 OZ 5.1 `TransparentUpgradeableProxy`（本次构建的产物，`_admin` 填成 ProxyAdmin 后比对 keccak）；
  - 代理已初始化，`pad()`、`v3()`、`fair()` 都是本 pad，`wbnb()` 和 `pancakeRouter()`（Router02 `0x10ED…024E`）正确，Router02 的 `factory()` = `0xcA14…0c73`、`WETH()` = WBNB；
  - 时间锁代码是标准 OZ TimelockController，`getMinDelay()` ≥ 48 小时；**主网上角色持有者必须是 Safe `0x2866…B41E`**（`OWNER` 是谁都一样，`MAINNET_OWNER_IS_DEPLOYER=true` 时也给 Safe）；Safe 有 PROPOSER / EXECUTOR / CANCELLER；`address(0)` 没有任何角色；部署钱包没有任何角色；`DEFAULT_ADMIN_ROLE` 只有时间锁自己（Safe、部署钱包都没有）；
  - 内盘的路由名单里有代理，没有实现合约（也没有 ProxyAdmin / 时间锁）。
- owner：7 个合约的 owner 或 pendingOwner 是 `OWNER`；`OWNER` = 部署钱包时 owner 就是它、没有 pendingOwner。

**外部库 `CurveLogic` / `FairLogic`**：
- 不用手动部署、不用传 `--libraries`：forge script 发现未链接的库会先部署再链接。Foundry 1.8.6 实测（主网和测试网 dry-run）：两个库是广播的**前两笔**交易，类型是 `CREATE2`，经确定性部署合约 `0x4e59b44847b379578588920cA78FbF26c0B4956C`（BSC 主网和测试网上都有）部署，盐为 0，所以地址只取决于库的字节码；`run-latest.json` 顶层的 `libraries` 字段列出它们的地址。
- `CurveLogic` / `FairLogic` 内部再按地址链接 PoolCheck：主网用 `$L` 链接线上 `0xd2B1…bDb3`（dry-run 的 `libraries` 字段里能看到这三个地址）；测试网不传 `$L`，forge 把 PoolCheck 也按同样方式部署（测试网 dry-run：前三笔是 PoolCheck、CurveLogic、FairLogic 的 CREATE2）。
- 如果同一份库字节码已经在这个地址上（例如上一次广播中途失败、库已上链），重跑时把它们也写进 `--libraries`：`--libraries src/gang/CurveLogic.sol:CurveLogic:<地址> --libraries src/gang/FairLogic.sol:FairLogic:<地址>`（地址见上次的 `run-latest.json`）。广播中途断了优先用 `--resume` 续发，不要重跑。
- 验证合约源码时（`--verify`）两个库会一起验证；不验证也不影响使用。

**重跑 / 换机器核对**（要打印 server env 时再加 `GANG_PAD_BLOCK=<区块>`，不加就不打印那几行，不会出现 `@0`）：`GANG_PAD=<pad> GANG_ROUTER=<路由代理> forge script script/DeployGang.s.sol --rpc-url $R $L` 不部署、不接线，只把 owner 交接补齐（幂等）并重新跑一遍 `_check`（路由的实现 / ProxyAdmin / 时间锁从代理的槽里读回再逐项核对；路由升级过之后「router impl code」一项会报错，属预期，用新版本的仓库重跑）；`OWNER` 和第一次的 pendingOwner 不一致时回滚 `PendingOwnerMismatch`，不会覆盖。

其它：
- 处理合约和手续费池的 `setKeeper` 由脚本在部署时调用，**合约一生只能调一次**（`keeperSet()` 变为 true）；之后换 keeper 只能 `proposeKeeper` → 48 小时 → `acceptKeeper`（审计说明 §18 R5-4）。
- 主网**不登记任何报价币**：USDT 发币时用 `USDT_REF_POOL`（Pancake V3 USDT/WBNB 0.01% 池 `0x172f…f849`，30 分钟 TWAP）换算毕业额 / 募集额。其它 18 位报价币由发币人自带参考池。
- 换币路由（Pancake V2 Router02 `0x10ED…024E`）在构造 handler 时传入；之后要改只能 `proposeDexRouter` → 48 小时 → `acceptDexRouter`。
- 跑完检查 `broadcast/DeployGang.s.sol/56/run-latest.json` 里所有 receipt 的 status 都是 `0x1`，确认文件里没有私钥，再提交到仓库。
- 部署完成后删掉 `~/Desktop/gang-mainnet.env` 和 `~/Downloads` 下那份私钥文件；Safe accept 之后部署钱包 `0x4EEd` 不再有任何角色，把剩余 BNB 转走、不再使用。

**测试网**（第 8 套）：同一个脚本，不需要 `OWNER`（默认部署钱包，路由时间锁的三个角色也给它）、不需要 `$L`；`ROUTER_TIMELOCK_DELAY` 可以设短（例如 `600`）用来演练升级；默认复用测试网 Agent ID 和测试报价币，新部署一个黑名单报价币（`BLACKLIST_QUOTE` 可指定已有的），两种报价币按 15 枚 = 15 BNB 登记固定换算额，演示金库 `0xe22e…8c77` 列入白名单，keeper = 部署钱包。

```sh
T=https://data-seed-prebsc-1-s1.bnbchain.org:8545
# 测试网节点要求优先费 ≥ 0.1 gwei：只给 --with-gas-price 时 forge 按 1 wei 的优先费发，交易全部被拒（gas tip cap 1）
forge script script/DeployGang.s.sol --rpc-url $T --broadcast --slow --with-gas-price 100000000 --priority-gas-price 100000000
# 整轮：V3（测试报价币有税币内盘买卖 → 80 个 Agent 打满毕业 → 外盘买卖顺带换块 → keeper process；WBNB 币经路由买；
#       黑名单报价币欠款 → release）+ 打新（100 个地址打满发射 → 外盘买入 → 有人卖到出局线以下 → keeper process → 领取）
#   必须 --slow --skip-simulation：keeper 的 process 要在前面的成交上链之后的区块里执行（同一区块里会因
#   每区块额度 / 参考价回滚），forge 默认的上链前模拟把所有交易放在同一个区块里，会误报失败
GANG_PAD=<GANG_PAD> GANG_ROUTER=<GANG_ROUTER> BLACKLIST_QUOTE=<BLACKLIST_QUOTE> GAS_PRICE_WEI=100000000 \
  forge script script/GangTestnetE2E.s.sol --rpc-url $T --broadcast --slow --skip-simulation --with-gas-price 100000000 --priority-gas-price 100000000
#   断点续跑：TOKEN_A / TOKEN_B / TOKEN_W / TOKEN_F 填上次日志里的币地址；SKIP_V3 / SKIP_FAIR / SKIP_B / SKIP_W=true 跳过整段
#   B 币用自己的一组 80 个钱包（gang-v3-owed-testnet）：模拟不扣 gas，复用 A 的钱包会少发 gas、在链上半路停下；现在一次跑完
# 收回 minter 剩下的 gas 钱（必须单独跑）
forge script script/GangTestnetE2E.s.sol --sig "sweep()" --rpc-url $T --broadcast --slow --with-gas-price 100000000 --priority-gas-price 100000000
```

**给已有的内盘挂可升级路由**（主网上 `OWNER` 必须是 Safe，否则回滚 `OwnerNotSafe`；例如测试网第 8 套 `0x4f73…94e7`，owner 是部署钱包 `0xCa8e…00b6`，脚本直接 `setRouter` 并在分红合约里排除代理；部署钱包不是 owner 时脚本打印 owner 要调的两笔 calldata）：

```sh
GANG_PAD=0x4f7391D69cbf62891Ba8db929c323cd2609b94e7 ROUTER_TIMELOCK_DELAY=600 \
  forge script script/DeployGangRouterUpgradeable.s.sol --rpc-url $T --broadcast --slow --with-gas-price 100000000 --priority-gas-price 100000000
# 重跑核对：再加 GANG_ROUTER=<上次的代理>，不发交易；旧路由仍在内盘名单里，要停用由 owner setRouter(旧路由, false)
```

部署脚本测试（主网和测试网 fork，不广播；进程级环境变量，必须单线程）：

```sh
BSC_RPC_URL=https://rpc-bsc.48.club BSC_TESTNET_RPC_URL=$T \
  forge test --match-path 'test/audit5/**/Deploy*' --threads 1 \
  --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
```

---

## 2. 部署后的链上复核（脚本的 `_check` 已做过一遍，这里用 cast 再看一眼）

合并后只有一个内盘、一个处理合约。下面的变量：`GANG_PAD`（GangLaunchpad）、`GANG_TAX_HANDLER`（GangTaxHandler）、`GANG_ROUTER`，以及共用的 `QUOTE_REGISTRY`、`PLATFORM_BUCKET`、`DIVIDEND_VAULT`、`MIGRATOR`、`TOKEN_DEPLOYER`。名字以 §1 脚本日志 `--- GANG ADDRESSES ---` 为准。两个库（`CurveLogic` / `FairLogic`）的地址不在日志里，由 forge 按 CREATE2 部署；下面经内盘调用两个库的 view 能返回，就说明链接正确。

```sh
c() { cast call "$@" --rpc-url $R; }
ALL="$GANG_PAD $GANG_TAX_HANDLER $QUOTE_REGISTRY $PLATFORM_BUCKET $DIVIDEND_VAULT $MIGRATOR $TOKEN_DEPLOYER"
# 7 个带 owner 的合约：Safe accept 之前 owner 是部署钱包 0x4EEd…、pendingOwner 是 Safe 0x2866…B41E；accept 之后 owner = Safe、pendingOwner = 0x0
for a in $ALL; do echo $a $(c $a "owner()(address)") $(c $a "pendingOwner()(address)"); done
# 内盘：两种币都在这一个地址上
c $GANG_PAD "taxHandler()(address)"; c $GANG_PAD "dividendVault()(address)"; c $GANG_PAD "platformBucket()(address)"; c $GANG_PAD "migrator()(address)"
c $GANG_PAD "agentIdRegistry()(address)"   # 0x60B9…022F（真实 Agent ID）
c $GANG_PAD "agentGateEnabled()(bool)"; c $GANG_PAD "walletCapEnabled()(bool)"   # 都 true
c $GANG_PAD "TAXED_MIN_SHARE()(uint256)"; c $GANG_PAD "MIN_SHARE_BALANCE()(uint256)"   # 两个都是 10000e18
# 两个库：下面两条能返回就说明内盘链接的 CurveLogic / FairLogic 在线，且它们链接的 PoolCheck 可用（脚本 _check 也查过）
c $GANG_PAD "graduationAmountOf(address,address)(uint256)" 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c 0x0000000000000000000000000000000000000000   # 15e18
c $GANG_PAD "previewCreate(address,address,uint256)(uint256,uint256)" 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 15000000000000000000
# 处理合约：一次性的内盘、keeper、换币路由
c $GANG_TAX_HANDLER "launchpad()(address)"   # = GANG_PAD
c $GANG_TAX_HANDLER "keeper()(address)"; c $GANG_TAX_HANDLER "keeperSet()(bool)"
c $GANG_TAX_HANDLER "dexRouter()(address)"; c $GANG_TAX_HANDLER "pendingDexRouter()(address)"   # Router02 / 0x0
# 手续费池：2 个 operator（内盘、处理合约）、金库、回购、keeper
for o in $GANG_PAD $GANG_TAX_HANDLER; do c $PLATFORM_BUCKET "operators(address)(bool)" $o; done
c $PLATFORM_BUCKET "burner()(address)"; c $PLATFORM_BUCKET "feeVault()(address)"; c $PLATFORM_BUCKET "keeper()(address)"
c $PLATFORM_BUCKET "keeperSet()(bool)"   # true：setKeeper 已用掉，之后换人只能走 48 小时时间锁
# 分红合约：一个内盘只绑一个 operator（只能绑一次），排除名单，门槛
c $DIVIDEND_VAULT "operatorFor(address)(address)" $GANG_PAD      # = GANG_TAX_HANDLER
for x in $DIVIDEND_VAULT $MIGRATOR $PLATFORM_BUCKET $GANG_PAD $GANG_TAX_HANDLER; do c $DIVIDEND_VAULT "excluded(address)(bool)" $x; done   # 都 true
c $DIVIDEND_VAULT "minimumShareBalanceOf(address)(uint256)" $GANG_PAD        # 10000e18
# 迁移合约 / 代币部署合约：内盘在白名单里
c $MIGRATOR "launchpads(address)(bool)" $GANG_PAD; c $TOKEN_DEPLOYER "launchpads(address)(bool)" $GANG_PAD
# 路由：v3() 和 fair() 都是同一个内盘；内盘把代理列为路由、没有列实现
c $GANG_ROUTER "v3()(address)"; c $GANG_ROUTER "fair()(address)"   # 都 = GANG_PAD
c $GANG_ROUTER "wbnb()(address)"; c $GANG_ROUTER "pancakeRouter()(address)"   # WBNB / 0x10ED…024E
c $GANG_PAD "routers(address)(bool)" $GANG_ROUTER        # true
c $GANG_PAD "routers(address)(bool)" $GANG_ROUTER_IMPL   # false
c $DIVIDEND_VAULT "excluded(address)(bool)" $GANG_ROUTER # true
# 路由代理的 ERC-1967 槽：实现 / 管理员
cast storage $GANG_ROUTER 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $R   # = GANG_ROUTER_IMPL
cast storage $GANG_ROUTER 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103 --rpc-url $R   # = GANG_ROUTER_PROXY_ADMIN
c $GANG_ROUTER_PROXY_ADMIN "owner()(address)"            # = GANG_ROUTER_TIMELOCK
# 时间锁：48 小时；Safe 有三个角色；部署钱包、address(0) 都没有；admin 只有时间锁自己
c $GANG_ROUTER_TIMELOCK "getMinDelay()(uint256)"         # 172800
SAFE=0x2866369F7acEFC9760bdE7779362fae5cD68B41E; DEP=0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3
P=$(c $GANG_ROUTER_TIMELOCK "PROPOSER_ROLE()(bytes32)"); E=$(c $GANG_ROUTER_TIMELOCK "EXECUTOR_ROLE()(bytes32)"); X=$(c $GANG_ROUTER_TIMELOCK "CANCELLER_ROLE()(bytes32)"); A=0x0000000000000000000000000000000000000000000000000000000000000000
for role in $P $E $X; do echo $(c $GANG_ROUTER_TIMELOCK "hasRole(bytes32,address)(bool)" $role $SAFE) $(c $GANG_ROUTER_TIMELOCK "hasRole(bytes32,address)(bool)" $role $DEP) $(c $GANG_ROUTER_TIMELOCK "hasRole(bytes32,address)(bool)" $role 0x0000000000000000000000000000000000000000); done   # 每行 true false false
c $GANG_ROUTER_TIMELOCK "hasRole(bytes32,address)(bool)" $A $GANG_ROUTER_TIMELOCK   # true
for w in $SAFE $DEP; do c $GANG_ROUTER_TIMELOCK "hasRole(bytes32,address)(bool)" $A $w; done   # 都 false
```

---

## 3. 多签要签的交易

**必须（从这一刻起所有合约归 Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`）**：Safe 对下面 7 个合约各调一次 `acceptOwnership()`（selector `0x79ba5097`，无参数，value 0）。最省事的做法：把部署日志 `--- Safe Transaction Builder JSON ---` 下面那一行存成 `.json`，在 Safe 的 Transaction Builder 里 Load，核对 7 个 `to` 与日志 `PENDING owner` 列出的地址一致，一笔批量交易发起，2/3 签名后执行。合并前是 9 个，合并后是 7 个（含 TokenDeployer）：

| # | 合约 | 地址 | 多签之后能做什么（详见审计说明 §4、§20，规格 §8） |
|---|---|---|---|
| 1 | GangLaunchpad | `GANG_PAD` | 路由名单、准入（V3 立即生效；打新只影响之后的 sale）、V3 单地址上限、参考池相关设置（V3 池子工厂、TWAP 窗口、中转池、pair 工厂） |
| 2 | GangTaxHandler | `GANG_TAX_HANDLER` | 接收地址白名单 `list` / `delist`、keeper、换币路由（48 小时时间锁）；两种币的外盘税都在这里 |
| 3 | QuoteRegistry（共用） | `QUOTE_REGISTRY` | 给某个报价币设固定换算额（可选；设了就优先于参考池） |
| 4 | SharedPlatformFeeBucket（共用） | `PLATFORM_BUCKET` | operator、金库、回购合约、keeper（换人要 `proposeKeeper` → 48 小时 → `acceptKeeper`）、7 天应急出口；只有固定路径的 `collectPlatform`，没有 `collectPlatformSmart`；多签自己也能直接 `collectPlatform` |
| 5 | SharedDividendVault（共用） | `DIVIDEND_VAULT` | 内盘白名单（移除只停新登记）、排除地址、新币的门槛；operator 已绑定，不能再改 |
| 6 | SharedMigrator（共用） | `MIGRATOR` | 只能再加内盘，不能移除 |
| 7 | TokenDeployer | `TOKEN_DEPLOYER` | 能部署代币的内盘名单 |

两个库（`CurveLogic` / `FairLogic`）没有 owner。**路由不需要 accept**：时间锁没有 owner，ProxyAdmin 的 owner 构造时就是时间锁。路由的权限：

| 合约 | 地址 | 谁 | 能做什么 |
|---|---|---|---|
| GangRouter（代理） | `GANG_ROUTER` | 任何人 | 买、打新、外盘买卖；没有管理函数 |
| ProxyAdmin | `GANG_ROUTER_PROXY_ADMIN` | owner = 时间锁 | `upgradeAndCall(代理, 新实现, data)`，以及转移 / 放弃自己的所有权，都只能由时间锁执行 |
| TimelockController | `GANG_ROUTER_TIMELOCK` | Safe（PROPOSER / EXECUTOR / CANCELLER） | `schedule` → 至少 48 小时 → `execute`；期间可 `cancel`。没有 admin：改角色、改延迟也要经时间锁自己的提案，同样等 48 小时 |
| — | 部署钱包 `0x4EEd…19d3` | — | 无任何角色 |

接受后，再跑一遍 §2 的 owner 循环，确认每个合约的 owner 都是 Safe `0x2866…B41E`，pendingOwner 都是 `0x0`；也可以用 `OWNER=0x2866…B41E GANG_PAD=… GANG_ROUTER=…` 重跑脚本核对（不发交易，`_check` 通过即可）。**部署钱包此后不应有任何角色**：它不是任何合约的 owner、keeper 或 operator（keeper 是 `KEEPER` 默认的 `0xB6f1…cFc7`）。

**合作方**（部署时没设 `RECIPIENT` 的话）：`GangTaxHandler.list(<合作方金库>, "<名称>")`（`GANG_TAX_HANDLER`）。

**建议，不挡上线**：
- V1 / V2 / S / U 的老合约：`0x4EEd` 已于 2026-10-27 对它们 `transferOwnership(Safe)`，Safe 用另一份 Transaction Builder JSON 逐个 `acceptOwnership()`（不在本手册范围；accept 之前 owner 仍是 `0x4EEd`）。
- 回购合约 GangBuybackBurner `0x3812…363B`（能改兑换路由，从而截走回购那一部分）：确认它在上面那批里，owner 最终是 Safe。

---

## 4. 服务端（正式站 201 indexer.env，不进仓库）

合并后 V3 和打新是同一个内盘：两组变量填**同一个地址、同一个部署区块**（服务端 `feat/one-pad` 支持）。索引器的两条轨道各扫一遍同一个地址，按事件 topic0 分开（两个 `Created` 是不同的重载，topic0 不同）。值直接抄部署日志 `--- server env ---` 那一段：

```
GANG_V3_PAD=<GANG_PAD>
GANG_V3_START_BLOCK=<GANG_PAD_BLOCK>
GANG_V3_CHAIN_ID=56
GANG_V3_RPC_URLS=<§0 #5 的 RPC>
GANG_FAIR_PAD=<GANG_PAD>                   # 和 GANG_V3_PAD 同一个地址
GANG_FAIR_START_BLOCK=<GANG_PAD_BLOCK>     # 同一个区块
GANG_FAIR_CHAIN_ID=56
GANG_FAIR_RPC_URLS=<§0 #5 的 RPC>
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
# 合并内盘：一条 PADS=label:pad@部署区块（同时算 V3 和打新）。keeper 从 pad 读 taxHandler() / platformBucket()，处理合约和手续费池都不用另外填
PADS=gang:<GANG_PAD>@<GANG_PAD_BLOCK>
V3_PADS=                                   # 留空：合并后的 pad 只写在 PADS 里（或者两条都填同一个地址，keeper 同样按一个合并内盘处理）
FAIR_PADS=                                 # 留空
EXPECTED_KEEPER=0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7
SLIPPAGE_BPS=150                           # 每块的最低成交额 = 这一块的报价 × (1 − 1.5%)
MAX_CHUNKS_PER_RUN=20                      # 每个币每次运行最多卖 20 块（每块 ≤ 池子代币储备 0.5%）
ALERT_TG_CHAT_ID=<§0 #6>                   # 报警发运维群；不配时报警打到 stderr 并非零退出
```

- `TAX_HANDLERS` / `TAX_ROUTERS` 留空：内盘的处理合约会自动接上（GangTaxHandler 同时负责两种币的外盘税和 V3 接收地址欠款补发）。
- **keeper 脚本要先合入合并配套的改动**：两个份额补写循环原来用 `launchpadOf == pad && quoteOf != 0` 挑币，合并后两种币都满足。V3 的循环要加 `kindOf(t) == 1`，打新的加 `kindOf(t) == 2`（读内盘的 `kindOf(address)(uint8)`），否则会按 V3 的余额规则处理打新币，反复「补写失败」后报警。
- `PADS` / `V3_PADS` / `FAIR_PADS` 全空时 `keeper-tax-process.sh` 以 7 退出并报警；只有确实不该跑的机器才设 `TAX_PROCESS_DISABLED=1`。
- 平台费：`keeper-v2-platform.sh` 会从内盘读出新的 SharedPlatformFeeBucket、从索引器取报价币清单，不用往 `PLATFORM_BUCKETS` 里手填；它只调固定路径的 `collectPlatform`（新手续费池没有 `collectPlatformSmart`）。V2 那三个分账合约照旧在默认清单里（V2 的分红 / 存量税按用户决定不处理，脚本不会对 V2 币调 `process`）。
- crontab 用仓库里的 `keeper/crontab.txt`：所有任务都经 `cron-run.sh` 包一层（非零退出就报警）；外盘税 `*/10 * * * *`；健康检查 `keeper-health.sh` 每 30 分钟。
- keeper 地址必须等于 GangTaxHandler 和新手续费池的 `keeper()`（部署脚本已按 `KEEPER` 设好）。
- 后续建议：发交易单独用私有 RPC（`BSC_RPC_URL`），读和查日志用 `LOGS_RPC`，降低分块卖出被夹的风险。
- `collectPlatform(quote, minGangOut)` 的 `minGangOut` 合约不设下限，完全靠 keeper 按链上报价给（审计说明 K-20）：keeper 热钱包被盗时，这一笔回购可被夹。keeper 钱包只放够付 gas 的 BNB；怀疑被盗时多签立即 `proposeKeeper(新地址)`（48 小时后 `acceptKeeper`），在此之前多签可以自己 `collectPlatform`，并在服务器上停掉 keeper 的 cron。时间锁约束的是**换 keeper**，不约束多签：多签本来就能直接 `process` / `collectPlatform`。

---

## 6. CLI

- 合并后 `gang v3` 和 `gang fair` 共用一个内盘地址。把 `skill/gang-cli/src/gangpad.js` 里的 `MAINNET_GANG.pad` / `MAINNET_GANG.router` 填成上面的 `GANG_PAD` / `GANG_ROUTER`（目前留空，可用 `GANG_PAD` / `GANG_ROUTER` 环境变量临时指定；旧的 `GANG_V3_PAD` / `GANG_FAIR_PAD` 仍可用）。
- 测试网第 8 套部署后，同一个文件里填 `TESTNET_SET8.pad` / `TESTNET_SET8.router`；没填时测试网仍用第 7 套。
- `gang v3 info` 拿到打新币（或 `gang fair info` 拿到 V3 币）时，CLI 按内盘的 `kindOf` 提示改用另一个命令。
- 更新文档里「只在测试网」的说法，升版本号，然后发布。
- 打新的参数范围（合约强制，CLI 同样校验）：募集 5–50 BNB 等值、单地址上限 0.25%–1%（1% 时至少 50 个地址打满）、出局线 60%–90%（CLI 默认 60%）、打新费 1%–3%、撤出费 1%–2%；没有截止时间。卖回是 `withdraw(token, shares, minPayout)`，CLI 用 `previewWithdraw` 减 0.1% 作 `minPayout`。
- V3 接收地址可以是发币人自己（不需要进白名单）或白名单里的合作方；CLI 用 `checkTaxConfigFor(发币钱包, tax)` 预检查（内盘没有这个函数时退回 `checkTaxConfig`）。服务端 / 网站做预检查时也要用带 creator 的版本，否则发币人自己当接收地址会被误报 `recipient not listed`。
- 领取：`gang v3 claim` / `gang fair claim`；`gang v3 status` / `gang fair status` 显示「可领」和「已按交税时记账、还没卖出」的部分（按现价估算并标明）。
- **CLI 发布的那一刻就是对公众开放创建的那一刻**（网站上的打新和税收币页面只能查看，发币和打新要通过 CLI）。如果要分阶段放开，前一两周先不发布 CLI，只让合作方和内部用 `GANG_*_PAD` 环境变量发币。合约本身挡不住别人直接调用，所以这只能降低早期的资金规模，不是硬限制。

---

## 7. 上线检查

**上线当天（不等第一个币毕业）**：
- [ ] 在服务器上以 root 手动干跑一次 `keeper-tax-process.sh`（不带 `--broadcast`）：首行显示 `merged_pads=…`（按 §5 用 `PADS` 时；两条列表填同一地址时是 `v3_pads=… fair_pads=…` 同一个地址），处理合约只出现一次、`known_tokens=…`，没有 ERROR；份额补写循环只列 V3 币 / 只列打新币（`kindOf` 过滤生效）
- [ ] `crontab -l` 里有 `*/10` 的 tax-process、`*/30` 的 keeper-health，所有任务都经 `cron-run.sh`
- [ ] 手动跑一次 `keeper-health.sh`：输出 `ok`；再故意让它报一次（例如临时把 `MIN_KEEPER_BNB` 设得比余额高），确认运维群收到报警
- [ ] `/v3/config`、`/fair/config`、`/burn`、`/health?strict=1` 都正常（§4）

**第一批真实交易后**：
- [ ] 合作方发第一个币（小额）：`TaxConfigured` 事件；内盘买卖只扣 1%（`Buy` / `Sell` 里 `tax` = 0，接收地址这时收不到钱，§19）；毕业后第一笔外盘税卖出后接收地址收到第一笔 `TaxPaid`
- [ ] 一个打新 sale 跑通：打新、卖回（到手 = 打新价 × 份数 − 撤出费，与 `previewWithdraw` 一致）、打满发射、池子开盘价等于打新价
- [ ] 经 GangRouter 用 BNB 买和打新各一笔，结束后路由余额为 0
- [ ] 一个已毕业 / 发射的币经路由外盘买卖各一笔（`poolBuyBNB` / `poolSellForBNB`，§11），结束后路由的 BNB / WBNB / 报价币 / 代币余额和对 Pancake 的授权都是 0
- [ ] 订阅路由时间锁 `GANG_ROUTER_TIMELOCK` 的 `CallScheduled` 事件并报警到运维群（任何升级提案都要有人看到）
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
| **不要关 Agent 准入** | 任何时候（主网） | 多签**不要**调 `GangLaunchpad.setAgentGate(false, …)`。V3 和打新共用这一个开关：关闭期间新建的打新 sale 在创建时把「无准入」永久快照进 sale，之后再打开也改不回来；这些 sale 的 `mintFor`（网站经 GangRouter 用 BNB 打新）会一直回滚 `RouterNeedsGate`，只能直接 `mint`。关闭期间 V3 的 `buyFor`（经路由买）也会回滚 `RouterNeedsGate`（V3 按当下开关，重新打开后恢复）。要换 Agent ID 合约时用 `setAgentGate(true, 新地址)`，不要先关再开 |

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

---

## 10. 升级路由（时间锁 48 小时）

升级只换实现，代理地址 `GANG_ROUTER` 不变：内盘不用重新 `setRouter`，用户不用重新授权。规则见审计说明 §21.1（存储只能在后面追加，从 `__gap` 里取；新版本要初始化就用 `reinitializer(2)`）。

1. **准备**：新实现在分支上写好、测完；用 `forge inspect GangRouter storageLayout` 对比新旧布局，旧变量的 slot 和类型一个都不能变。部署新实现（任何钱包都行，它没有权限）：`forge create src/router/GangRouter.sol:GangRouter --rpc-url $R …`，记下 `NEW_IMPL`。确认 `cast storage $NEW_IMPL 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00` 是 `0x…ffffffffffffffff`（实现已锁死）。
2. **拼调用**（`DATA` 为空就是 `0x`；新版本要初始化时填 `cast calldata "initializeV2(...)" …`）：
   ```sh
   CALL=$(cast calldata "upgradeAndCall(address,address,bytes)" $GANG_ROUTER $NEW_IMPL 0x)
   SALT=$(cast keccak "gang-router-upgrade-<日期>")
   ```
3. **提案（Safe，2/3）**：Safe Transaction Builder 里对 `GANG_ROUTER_TIMELOCK` 调 `schedule(address target, uint256 value, bytes data, bytes32 predecessor, bytes32 salt, uint256 delay)`，参数 `target = GANG_ROUTER_PROXY_ADMIN`、`value = 0`、`data = $CALL`、`predecessor = 0x00…00`、`salt = $SALT`、`delay = 172800`（小于 172800 回滚 `TimelockInsufficientDelay`）。
4. **链上确认提案**（任何人可查，这 48 小时是公示期）：
   ```sh
   ID=$(c $GANG_ROUTER_TIMELOCK "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" $GANG_ROUTER_PROXY_ADMIN 0 $CALL 0x0000000000000000000000000000000000000000000000000000000000000000 $SALT)
   c $GANG_ROUTER_TIMELOCK "isOperationPending(bytes32)(bool)" $ID    # true
   c $GANG_ROUTER_TIMELOCK "getTimestamp(bytes32)(uint256)" $ID       # 最早可执行的时间（unix 秒）= 提案区块时间 + 172800
   ```
   时间锁的 `CallScheduled(id, 0, target, value, data, predecessor, delay)` 事件就是公示，报警应在这时响。发现提案不对：Safe 调 `cancel(ID)`（2/3）。
5. **等 48 小时后执行（Safe，2/3）**：对时间锁调 `execute(target, value, data, predecessor, salt)`，参数和第 3 步完全一样。早于 `getTimestamp` 执行回滚 `TimelockUnexpectedOperationState`。
6. **链上确认升级**：
   ```sh
   c $GANG_ROUTER_TIMELOCK "isOperationDone(bytes32)(bool)" $ID       # true
   cast storage $GANG_ROUTER 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $R   # = NEW_IMPL
   c $GANG_ROUTER "pad()(address)"; c $GANG_ROUTER "wbnb()(address)"; c $GANG_ROUTER "pancakeRouter()(address)"   # 都不变
   c $GANG_PAD "routers(address)(bool)" $GANG_ROUTER   # 仍是 true
   ```
   代理会发出 `Upgraded(NEW_IMPL)` 事件。然后经路由小额买 / 卖各一笔，确认路由余额为 0。
7. 测试网演练：`DeployGangRouterUpgradeable` 用 `ROUTER_TIMELOCK_DELAY=600` 部署，部署钱包就是 proposer / executor，按上面 3–6 步用 `cast send` 走一遍。

## 11. 经路由外盘买卖（Pancake V2）

V2、V3、打新三种币只要有 Pancake V2 交易对都能用（审计说明 §21.3）。`quote` 由调用方传，合约不核对它和代币的关系（交易对不存在时 Pancake 回滚）。最低值按调用者实际到账（扣过税）检查。

| 函数 | 路径 | 授权 |
|---|---|---|
| `poolBuyBNB(token, quote, minTokensOut, deadline)` payable | `[WBNB, token]` 或 `[WBNB, quote, token]` | 不用授权 |
| `poolBuy(token, quote, quoteIn, minTokensOut, deadline)` | `[quote, token]` | 报价币授权给路由代理，**只授权本次 `quoteIn`** |
| `poolSell(token, quote, amountIn, minQuoteOut, deadline)` | `[token, quote]` | 代币授权给路由代理，**只授权本次 `amountIn`** |
| `poolSellForBNB(token, quote, amountIn, minBnbOut, deadline)` | `[token, WBNB]` 或 `[token, quote, WBNB]` | 同上 |

- 路由给 Pancake 的授权每笔恰好是本次数量、用完归零；每笔之后路由的 BNB / WBNB / 报价币 / 代币余额都是 0。
- 只授权本次用量的原因：路由可升级，恶意升级（虽然要先公示 48 小时）能动用户对代理的长期授权（审计说明 §21.4）。
- 错误：`Expired`（过了 deadline）、`ZeroAmount`（金额为 0 或实际到账为 0）、`TooLittleReceived(received, minimum)`（滑点）。
- **gas**（主网 fork，真实 Pancake，一笔带一块 swap-back 的有税 V3 币卖出）：经路由 `poolSell` 约 **69.8 万**（路由已被分红合约排除，部署后的状态；不排除时约 78.8 万），直接在 Pancake Router02 上卖约 62.0 万。有税币卖出会顺带卖一块攒下的税（swap-back 上限 60 万 gas），钱包 / 前端估 gas 时给足（建议 gas limit ≥ 90 万）；gas 给少了 swap-back 不会被悄悄跳过，而是整笔回滚 `SwapBackOutOfGas`。

## 19. V3 内盘不收税（2026-10-27 用户决定）

审计说明 §19。部署步骤、脚本、环境变量、接线自检都不变；变化在上线后的核对和对外说明：

- 内盘买卖只扣 1% 手续费（进 SharedPlatformFeeBucket），`Buy` / `Sell` 事件里 `tax` 恒为 0；接收地址、分红合约、TaxHandlerV3 在毕业前收不到任何报价币。合作方要知道：**收入从毕业后的第一笔外盘税开始**。
- 外盘税不变（卖出时自动小额换、keeper 分块补位、交税时记账），§5 的 keeper 和 §8 的日常运维照旧。
- 分红合约只剩外盘分红：`depositReward` / `accRewardPerShare` / `rewardDebt` / `RewardDeposited` 已删除。索引器里订阅共用分红合约 `RewardDeposited` 的地方不会再收到事件（不报错）。
- §7「第一批真实交易后」的第一条已按此改：内盘只看 1% 手续费，`TaxPaid` 要等毕业后第一笔外盘税。
- 测试网第 8 套按这版合约部署（用户来做），239 再切一次。
