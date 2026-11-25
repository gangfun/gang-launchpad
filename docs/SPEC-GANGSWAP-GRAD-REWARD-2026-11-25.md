# 规格 · GangSwap 曲线币的冲毕业奖励（dev 自己出钱）

- 日期：2026-11-25
- 状态：**已实现，本地测试和主网 fork 通过；没有独立评审，没有上测试网和主网**
- 基础：`SPEC-GRAD-REWARD-2026-11-17.md`（冲毕业奖励）、`SPEC-GANGSWAP-2026-11-22.md`（GangSwap，可选的毕业去处）
- 改掉的决定：GangSwap 规格 D3「第一期不带任何模块」里的「冲毕业奖励」一项。其余不变：WBNB 计价、无税、不带底仓、金库、推广分成、倒计时奖励

## 1. 做什么

创建 GangSwap 曲线币（`kindOf` 4）时，dev 可以同时放一笔奖励池。规则和类型 1 的冲毕业奖励完全一样：记最后 N 笔计入的买入，毕业时按规则分给这些买家；没毕业可以公示 7 天后撤回。

曲线的三个钩子（`onBuy` / `onSell` / `onGraduate`）和领取、结算、回收、撤回、查询本来就不看类型，所以类型 4 只缺一个创建入口。

## 2. 入口

`createGangSwapWithGradReward(name, symbol, logoURI, metaURI, gradBnb, migrator, cfg)`，在 `Pad3Module`，接口在 `IGangSwapPad`。

= `createGangSwap` 的检查 + `createWithGradReward` 的检查，按下面的顺序：

1. 奖励开关开着（`GradNotOpen`），`cfg` 在范围内（`BadGradConfig`，范围同奖励规格 §7）；
2. `carryBps`、`promoteBps`、`promoteWindow` 都必须是 0，否则 `BadGradConfig`。不静默丢弃；
3. GangSwap 开着（`GangSwapNotOpen`），`migrator` 是 pad 当前的版本（`GangSwapVersionChanged`）；
4. 和 `createGangSwap` 一样建币，发 `GangSwapCreated`；
5. 用 `pullExact` 从创建人拉 `cfg.seed` 的 WBNB，再写奖励，最后发 `GradRewardSet`（`countdown` 固定为 0）。

- 两个开关都要开。任何一个关闭只影响新建，已建的币照常交易、毕业、领奖。
- 不是 payable，种子钱要先 approve 给 pad。拉取失败（余额或授权不够、到账不足）整笔回滚，不会留下没有奖励的币。
- 加进了 `createWithSalt` 和 `createWithAgentWindow` 的名单，可以三层嵌套。pad 主体不用改：fallback 本来就把没定义的选择器转给 `Pad3Module`。
- 没有倒计时模块，所以没人能领的部分（零头、180 天没领的、没有一笔有效买入时的全部）都退给 dev；`retryCarry` 永远是 `NoCarryOwed`。
- `buyWithPromoter` 照旧拒绝类型 4。

共用代码：`_checkGradConfig`（开关和范围）、`_fundGrad`（拉钱、写奖励、发事件）、`_createGangSwap`（版本检查、建币、记录、事件）。`createWithGradReward` 和 `createGangSwap` 改成调用它们，检查、执行和事件的顺序都没变。

## 3. 钱的边界

- 种子钱只记在 `Reward.pot`，不进 `realQuote`、`creatorFeeOf`，也不进报价。曲线价格、手续费、毕业线、`tryBuy` / `trySell`、registry 报价都不受影响。
- 毕业时 pad 只授权迁移合约拿 `realQuote`（`PadCommon.migrateVia`），奖励池留在 pad。池子的有效储备、虚拟储备 V、回购资金和没有奖励的 GangSwap 币完全相同（测试逐项比较）。
- `_graduate` 先迁移、再 `onGraduate` 记账。迁移合约是 owner 设定并在创建时固定的版本，同一笔交易里有 pad 的重入锁。
- 毕业后的回购和奖励无关，回购钱在回购合约里，奖励钱在 pad 里。
- 没有新的存储：两个命名空间（`gang.pad3.gradreward`、`gang.pad3.gangswap`）的布局和 slot 都不变，pad 的存储布局不变。

## 4. 经济含义（要对外说清楚）

- **奖励是 dev 自己的钱**，平台不出钱，也不从曲线、手续费或回购里出。
- **dev 可以用自己最后的买入把奖励赢回来**，和类型 1 一样：名单只看买入顺序和花费，不排除创建人和他的其他钱包。所以奖励池的大小不等于「一定会发给别人的钱」，页面和 CLI 不能这么写。
- 推毕业的钱如果 ≥ N × `minBuy`，拆成 N 笔可以占满名单（奖励规格 §13 已知限制，没有变）。dev 用 `minBuy` 和 N 控制。
- 毕业那一笔的额外份额上限 50%（`lastBps`）。买家拿到的币在 GangSwap 池子里，价格风险自己承担；GangSwap 毕业后有按时间表的回购，公开可见，冲毕业的人会把它算进去。这和奖励叠加，会让临近毕业的买入更集中。
- 卖回曲线就失去之前的资格；毕业前全部卖回的话名单里没有一笔有效。门槛开着时，毕业那一笔一定有效，所以只有门槛关闭过才会全部退给 dev。
- Agent 窗口过后任何钱包都能交易，但只有持 Agent ID 的买入计入名单；非 Agent 的钱包可以把币推过毕业线，这时 `lastBps` 那份给名单里最新的一格有效买入。
- **平台出钱的活动奖金仍然不包括 GangSwap 币**（活动规则和入选条件在链下，合约不改）。理由没有变：平台的钱和可以自己赢回来的奖励不能叠在一起算。
- 撤回的规则没有变：满 `refundAfter` 后申请，公示 7 天，3 天内执行，毕业作废申请。

## 5. 攻击面

| 点 | 结论 |
|---|---|
| 拉种子钱时重入 | WBNB 没有回调；入口有 `nonReentrant`，模块的领取、撤回、结算也共用 proxy 的锁。测试用会回调的 WBNB 验证六个入口都被挡住 |
| 先建币后拉钱 | 失败整笔回滚，包括代币、记录、待用的窗口和 salt |
| 嵌套时替别人付钱 | 三层都是 delegatecall，`msg.sender` 一直是创建人；窗口和 salt 也按创建人登记 |
| 迁移合约版本切换 | 创建人传入看到的版本；已建的币按自己的版本毕业并发奖 |
| 迁移失败卡住奖励 | 和没有奖励的 GangSwap 币一样，毕业那一笔整体回滚，奖励仍是 ACTIVE，dev 可以走撤回 |
| 毕业那一笔的 gas | 只多 2 到 3 个 SSTORE 和事件，不遍历名单，不调用外部合约 |

## 6. 大小和 gas

| 合约 | 之前 | 现在 | 余量（24,576） |
|---|---|---|---|
| `Pad3Module` | 22,911 | 24,005 | 571 |
| `Pad3GradModule` | 8,911 | 8,935 | 15,641 |
| `GangLaunchpad3` | 22,433 | 22,433（源码没改，只换 `module` 这个 immutable） | 2,143 |
| `Pad3FlyModule` | 21,777 | 21,777（没改，脚本会重新部署） | 2,799 |
| `CurveLogic3` 和其他库 | — | 没改 | — |

`Pad3Module` 快满了：下一个功能要先把一部分搬出去。

毕业那一笔（测试桩，单笔交易，含迁移）：

| 情况 | gas |
|---|---|
| GangSwap，没有奖励 | 2,469,885 |
| 有奖励，名单 20 格已满（覆盖旧格） | 2,476,143（+6,258） |
| 有奖励，写一个全新的第 20 格（最贵） | 2,493,242（+23,357） |

第一次领取（顺带数 20 格）272,327。fork 上的数字见 §8。

## 7. 升级

这是 pad 3.0 的一次升级：新的 `Pad3GradModule`、`Pad3Module`、pad 实现。脚本也会重新部署 `Pad3FlyModule`（代码没变，依赖照读线上的）。**没有** registry、迁移合约、回购、手续费合约、router 的改动，没有存储变化，没有 reinitializer，没有新的 owner 操作（两个开关在主网都已经开着）。

`CurveLogic3` 等库和 `Pad3FlyModule`、`GangPadRegistry`、`GangLaunchpad3` 的本地构建和主网正在运行的代码比过：除了末尾 32 字节的 metadata 哈希（随构建设置变），其余逐字节相同（库地址和 immutable 除外）。脚本照旧由 forge 重新部署这些库；要继续用线上的库地址，用 `--libraries` 指定。

`script/UpgradeGangLaunchpad3.s.sol` 的改动：

- 升级前后比较 `gradRewardDeps` 和**每一个**有奖励的币（按原始状态字查找，所以命名空间被移动也看得出来）：5 个存储字、`gradReward`、`gradEntries`、名单里每个买家的 `gradClaimable`；
- GangSwap 币照旧逐个比较（包括已毕业的），最新 25 个币照旧比较；
- 升级后的应答检查：直接调用、经 `createWithAgentWindow`、（abcd 开着时）经 `createWithSalt`，空配置都要被拒（`BadGradConfig`；奖励关着时 `GradNotOpen`）；奖励开着时，合法配置加错误版本也都要被拒（`GangSwapVersionChanged`，带当前版本；GangSwap 关着时 `GangSwapNotOpen`）。这只证明入口已接上、两个名单已加上、请求能走到版本检查，**不证明建币能成功**（发币、拉种子钱、写奖励）：那由 Foundry 和 fork 测试证明，部署的代码由脚本逐字节比对。

`script/pad3-upgrade-probes.py` 多报 GangSwap 币和奖励币的数量（只读，供对照）。

主网要用的环境（**这些必须都不设**，它们是以前各次上线的一次性步骤）：

| 变量 | 设了会怎样 |
|---|---|
| `PAD3_REGISTRY_UPGRADE`、`PAD_REGISTRY_IMPL` | registry 已经是这份代码，`PAD3_REGISTRY_UPGRADE` 会被脚本拒绝；单独设 `PAD_REGISTRY_IMPL` 没有作用 |
| `PAD3_GRAD_REWARD`、`PAD3_GRAD_HANDLER_ADMIN`、`PAD3_GRAD_COUNTDOWN_FACTORY` | 奖励已经打开，`PAD3_GRAD_REWARD` 会被拒绝；另两个单独设没有作用 |
| `PAD3_ABCD_DEPLOYER` | 已经启用，会被拒绝 |
| `PAD3_BASE_VAULT_IMPL` | 和线上相同会被拒绝；换成另一份同样代码的地址会进批次，脚本会打印警告 |
| `PAD3_INIT_CALL` | 没有新的 reinitializer，会被拒绝 |

`PAD3_FLY_*` 可以不设，设了必须等于线上的值。第二次（只读）运行要设 `PAD3_IMPL`。批次里只要有 `upgradeAndCall` 以外的交易（包括脚本自己找到的铸币飞轮登记），脚本就打印 `WARNING: the batch is NOT the upgrade alone`。这次升级的批次必须只有一笔：到 pad 的 ProxyAdmin，value 0，`upgradeAndCall(pad, 新实现, 0x)`；看到警告就停。

过期的东西：

- `test/fork/Pad3GangSwapFork.t.sol`、`Pad3GradRewardFork.t.sol`、`Pad3AgentWindowFork.t.sol`、`Pad3GradCarryFork.t.sol` 等 fork 测试是按各自上线前的主网状态写的（例如「升级后 GangSwap 仍关闭」「奖励还没设」），只能配旧区块和存档节点跑，没有改。
- `Pad3GangSwapStore` 和 `GangLaunchpad3` 里「no modules」的注释没有改，这样 `CurveLogic3` 和 pad 主体的源文件完全不动。奖励不是模块（不绑定任何合约），注释仍然成立。
- `SPEC-GANGSWAP-2026-11-22.md` D3 的「冲毕业奖励」一项以本文为准。

链下还没做：CLI（`--venue gangswap` 配 `--grad-reward`、种子钱授权、估 gas）、server（`GradRewardSet` 配类型 4 的展示）、web。

## 8. 测试

- `test/gang3/Pad3GangSwapGrad.t.sol`：创建、事件顺序、每个坏配置、开关、版本、拉款失败、重入、salt / 窗口嵌套、报价和曲线交易逐 wei 对比、名单、门槛开关、毕业和没有奖励的币逐项对比、领取、结算、回收、撤回的全部路径、全部卖回、版本切换、多种币混合的偿付能力 fuzz、存储写入、升级脚本的比较和应答检查。
- `test/fork/Pad3GangSwapGradFork.t.sol`（主网最新区块，公共节点）：跑升级脚本（先部署再只读重跑），以 Safe 身份执行，只写实现槽；类型 1、类型 1 带奖励、GangSwap 三种现有创建到毕业的整套流程，在线上实现和新实现上日志、记录、余额逐字节相同；升级前创建的三种币和两个已毕业的币（GangSwap、类型 1 带奖励并已领一部分）升级后记录和 registry 报价不变，没毕业的照常毕业，没领的照常领；新入口建的币（窗口 + salt + 奖励）走完曲线、毕业、回购、领取、回收。

结果（2026-11-25）：

- `Pad3GangSwapGrad.t.sol`：26 个新测试通过（偿付能力 fuzz 1,000 轮）。
- fork：公共节点（不是存档节点，保留约 5,000 个区块以上的状态）从最新区块跑完，约 13 分钟。一次创建（窗口 + salt + 奖励）约 163 万 gas；线上版本的毕业那一笔，名单 20 格已满，约 246 到 249 万 gas（两次运行，区块 135604214、135606290）。部署后的大小和 §6 一致。
- 主网现状（只读探针）：1,084 个币，9 个 GangSwap 币都还在曲线上，1 个奖励币（类型 1，还在曲线上），37 个 Agent 窗口，4 个推广分成币没有任何绑定，没有底仓币；两个探针列表都为空。
- 没有验证：全部 1,084 个币逐个比较（脚本比较最新 25 个、全部 GangSwap 币、全部奖励币）；真实的旧版 CLI、server 和网站。
- 变异检查：新代码 23 处、升级脚本 9 处，共 32 个；31 个第一次就被发现，剩下 1 个（升级脚本里直接调用的那条应答检查，和另外两条重叠）补了测试后也被发现。
- 全量 Foundry（不含 fork），`b426644`，独立干净运行：2,493 通过 / 0 失败 / 199 跳过（跳过的是没有 RPC 的 fork 测试）。`gangswap/` 140 / 140。
