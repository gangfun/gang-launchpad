# REFPOOL 改动说明（2026-10-23）

**目的：** 兑现需求「Dev 可用任意在 BSC 上有池子的代币作底池，募到 ≈15 BNB 等值发射」。Dev 自己填参考池地址，合约不再只认 V2 quote/WBNB。

## 改了什么

| 文件 | 改动 |
|---|---|
| `src/PoolCheck.sol` | 重写。`inspect` 识别 V2 pair / V3 pool 并到对应工厂验证是官方池（`PoolNotFactory`）；`counterOf` 校验 quote 在池内；`depthOf` 读对手资产深度；`convert` 按池价把一种资产换算成另一种（V2 储备比、V3 `observe()` TWAP，观测不足时回退 `slot0` 现货） |
| `src/libraries/TickMath.sol` | 新增，Uniswap V3 `getSqrtRatioAtTick`，用于 TWAP tick → 价格 |
| `src/LaunchpadV2.sol` | `create` 改为 `(…, taxed, quote, refPool)`，两轨统一；新增 `v3Factory`、`twapWindow`（默认 1800s）、`bridgePoolOf` 及 setter；`_lockGradAmt` 按「WBNB → 覆盖值 → 参考池」三级决定 gradAmt，对手资产非 WBNB 时经桥接池换算；参考池对手侧深度 ≥ 1 BNB 等值；新增 `graduationAmountOf(quote, refPool)` 预览；删除 `defaultGraduationQuoteAmount` 与 `MIN_RESERVE_WBNB` |
| `test/LaunchpadV2.t.sol` | create 调用改为 6 参数；`ThinWbnbReserve` → `ThinReferencePool` |
| `test/V2E2E.t.sol` | 新增 8 个主网 fork 测试 |

## 没改的

`TaxLaunchToken`、`DividendVault`、`PlatformFeeBucket`、`MigratorV2`、曲线数学与毕业流程均未动。

## 同批清理（2026-10-23 第二次）

| 文件 | 删除 / 修改 |
|---|---|
| `src/LaunchpadV2.sol` | 删 `isDev`、`setDev`、`_requireDev`、`NotDev`、`DevUpdated`（create 由 Agent 门控制，白名单已无意义） |
| `src/BuybackBurner.sol` | 删 `maxSlippageBps`、`setMaxSlippageBps`、`_quoteAmountsOut`、`NoRoute`、`SlippageBpsTooHigh`、`MaxSlippageBpsUpdated`（minOut 一律由调用方给出） |
| `src/QuoteRegistry.sol` | 删 `nativeSwapEnabled` 字段、`setNativeSwapEnabled`、`nativeSwapEnabled()`；`QuoteUpdated` 事件减为 3 个参数；`quotes()` getter 的返回元组相应减少一个字段 |
| `src/PostGradTaxHandler.sol` | 继承改为 `Ownable2Step`（此前只改了 import） |

未做：重新部署 BuybackBurner 是部署决策，不在源码范围。

## 安全要点

- 假池：V2 用 `getPair(token0, token1) == pool`，V3 用 `getPool(token0, token1, fee) == pool`，非工厂池一律 revert。
- 价格操纵：V3 默认 30 分钟 TWAP；V2 仍是现货，Dev 填薄 V2 池时可被夹，前端应展示池深并提示。
- 桥接池由 owner 登记且必须是「资产/WBNB」的官方池，防止用假桥接池抬高 15 BNB 的换算值。
- 参考池不是毕业池：毕业仍在我们自己新建的 V2 token/quote 对，LP 烧至 dead。

## 测试

- 单元：15 / 15。
- fork（BSC 主网，真实 NVDAB、USDT、Pancake V2/V3 工厂与池）：8 / 8，见 README REFPOOL 节数据。

## 前端 / 运营变更

- create 多一个 `refPool` 参数；建议前端让用户先填池子地址，调 `graduationAmountOf(quote, refPool)` 显示「需募集 X 枚 ≈ Y 美元」及池子深度，失败时按 revert 原因提示。
- 部署清单加 `setV3Factory` 与各稳定币的 `setBridgePool`。
