# 规格 · 聚合器用的 pad registry（GangPadRegistry）

- 日期：2026-10-28 Asia/Shanghai
- 作者：Claude（按 claude.ai 文档「Gang 聚合器接入说明」里规划的 registry 实现）
- 性质：**测试网已部署（`0xB11B…e56e`，登记第 10 套 pad，见 `docs/TESTNET-PAD-REGISTRY-2026-10-28.md`），主网还没部署**。合约 `src/gang/GangPadRegistry.sol`，接口 `src/gang/interfaces/IGangPadRegistry.sol`，测试 `test/gang/GangPadRegistry.t.sol`，部署脚本 `script/DeployGangPadRegistry.s.sol`（自检 `script/GangPadRegistryDeployLib.sol`）。审计说明见 `docs/AUDIT-BRIEF-2026-10-26.md` §24。

## 一句话

聚合器只记一个永久不变的地址：`padOf(token)` 告诉它这个币是不是 Gang 币、该调哪个 pad；`previewBuy` / `previewSell` 给出和 `buyFor` / `sellFor` 逐 wei 一致的曲线报价。以后上线 V4、V5 pad，只要在 registry 登记一次，聚合器的代码不用改。

## 接口

| 函数 | 返回 | 说明 |
|---|---|---|
| `padOf(token)` | `pad` | 已登记、并且列有这个币的 pad；其他情况都返回 0。毕业 / 开盘后仍返回原 pad。代币无法让它回滚 |
| `lookup(token)` | `(pad, kind)` | 同上，再加上 `kindOf`（1 = 曲线，2 = 打新）。遇到不认识的 kind 请跳过 |
| `isPad(pad)` / `padCount()` / `padAt(i)` / `pads()` | | 已登记的 pad，按登记顺序 |
| `previewBuy(token, trader, quoteIn)` | `(tokensOut, spent, fee, refund)` | `spent` 是 pad 实收的报价币（含 1% 手续费）；`refund` 是钱包上限或毕业截断后退给 trader 的部分；`spent + refund = quoteIn` |
| `previewSell(token, trader, tokensIn)` | `(quoteOut, fee)` | 扣 1% 手续费后付给路由的报价币 |

报价的约定：

- `buyFor` / `sellFor` 会回滚的情况一律返回 0：不是曲线币、已毕业、准入不过、钱包已满、数量为 0、`quoteIn` 超过 `type(uint256).max / 100`、卖出超过曲线已售量。
- `trader` 填 0 地址时按新钱包报价：不查准入，钱包额度按满额算。
- 卖出预览不检查 trader 的余额和授权，那是路由自己要保证的。
- 打新的报价仍然直接用 pad 的 `previewMint` / `previewWithdraw`。

## 怎么判断 `padOf`

1. 以 1 万 gas 上限 `staticcall` 代币的 `launchpad()`，只读返回数据的前 32 字节。调用失败、返回不足 32 字节、或者返回的不是地址（高 96 位不为 0），都返回 0。
2. 这个地址必须已经在 registry 登记。
3. pad 的 `kindOf(token)` 必须不为 0，也就是这个币确实是这个 pad 发的。指向真 pad 的假币，在这一步返回 0。

## 权限与升级

| 项 | 主网 | 测试网 |
|---|---|---|
| 部署形态 | `TransparentUpgradeableProxy`，代理地址永久不变 | 同左 |
| registry `owner`（`addPad`、两步转移） | GangRouter 现有的 48 小时 TimelockController（`0x3911…04C5`，提案 / 执行 / 取消都只给 Safe） | `OWNER` 环境变量，默认是部署钱包 |
| ProxyAdmin 的 owner（升级） | 同一个时间锁 | 同上 |
| 初始 pad | 部署时在 `initialize` 里登记 `GANG_PAD`，不用等时间锁 | 同左 |

- 只增不删：登记后的 pad 不能删除，也不能改指向。紧急止损用 pad 自己的 `setRouter(路由, false)`，当块生效。
- 登记时核对 pad 的 `VIRTUAL_TOKEN` 和 `PROTOCOL_FEE_BPS`。新一代 pad 改了曲线公式，就先经时间锁升级 registry 的报价逻辑，再登记 pad。
- 存储布局：slot 0 `owner`、1 `pendingOwner`、2 `_pads`、3 `isPad`、4–49 `__gap`（46 个）。新变量从 `__gap` 取槽，`test_layout_v1` 会锁住当前布局。

## 部署

```
# 主网（部署钱包签名；多签在部署时什么都不用签；BSC_RPC_URL 供 --rpc-url bsc 使用）
DEPLOYER_PRIVATE_KEY=<部署钱包私钥> \
GANG_PAD=0x15CFD2dc8278Fb87a1783ef42111618E20874365 \
GANG_ROUTER=0xE040445690Aa56C8b68B7f7038C7b2562B5079C4 \
GANG_MAINNET_OK=true \
forge script script/DeployGangPadRegistry.s.sol --rpc-url bsc --broadcast --legacy --with-gas-price <当前 cast gas-price>

# 测试网：forge 按 EIP-1559 估的小费只有 1 wei，Chapel 要求至少 0.1 gwei，必须写明 gas 价格
DEPLOYER_PRIVATE_KEY=… GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 \
forge script script/DeployGangPadRegistry.s.sol --rpc-url bsc_testnet --broadcast --legacy --with-gas-price 100000000

# 重跑自检（不部署）
DEPLOYER_PRIVATE_KEY=… GANG_PAD=… GANG_ROUTER=… GANG_PAD_REGISTRY=<代理地址> forge script script/DeployGangPadRegistry.s.sol --rpc-url bsc
```

自检内容：代理代码、实现（本次构建的代码，已锁死）、ProxyAdmin（代理自己创建的、标准 OZ 代码、owner 正确）、registry 的 owner 和 pad 列表；主网还会按 GangRouter 部署的标准核对时间锁；最后确认 `padOf(pad)` 为 0、`padOf(pad 最后一个币)` 返回 pad。代码比对会屏蔽 metadata 哈希（审计说明 §24.4）。

部署后要做的事：把代理地址补进 README 的地址表和接入说明文档，并发给已接入的聚合器。

## 测试

- `test/gang/GangPadRegistry.t.sol`：20 个，包括两个 fuzz（各 1,000 轮），拿真实的 `buyFor` / `sellFor` 逐 wei 核对报价。
- `test/router/SameCode.t.sol`：3 个，覆盖部署自检用的代码比对，其中一个要 `BSC_RPC_URL`，在主网 fork 上跑。
- `test/fork/PadRegistryTestnetFork.t.sol`：4 个，要 `BSC_TESTNET_RPC_URL`。在测试网第 10 套 pad（`0xFebF…5BB1`）的 fork 上部署 registry，由 pad owner 把一个测试路由加进白名单，用新注册了 Agent ID 的钱包交易。覆盖（2026-10-28 的链上状态：9 个币，其中 5 条还在内盘的 WBNB 曲线）：每个币的 `padOf` / `lookup`；每条在内盘的 WBNB 曲线各做一次小额买入和几次卖出，离毕业还远的曲线再做一次被钱包上限截断的买入；关掉上限后一笔买入经真实的 migrator 和 Pancake 毕业。所有报价都和真实的 `buyFor` / `sellFor` 逐 wei 一致；准入不过的钱包和打新币返回 0。fork 用的是测试网最新状态，每个用例按当时的链上状态挑选可用的曲线，没有可用曲线时跳过。
- 主网和测试网 fork 模拟 `DeployGangPadRegistry`（没有广播）都已通过。

## 还没做

- 主网部署。
- README 地址表、CLI（`skill/gang-cli`）改用 registry 查 pad：当前 CLI 用的是固定的 pad 地址，暂时不用改。
