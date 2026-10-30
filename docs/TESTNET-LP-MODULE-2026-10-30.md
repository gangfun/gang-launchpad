# 测试网记录 · GangLiquiditySplitter（税收自动加池子模块，`lp-burn-v1`）

- 日期：2026-10-30 ~ 10-31 Asia/Shanghai
- 网络：BSC 测试网（97），第 10 套 pad `0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`
- 代码：PR #91，分支 `feat/lp-module` 的 `0c9a13a`
- 部署前：一轮内部审计（无 Critical / High / Medium；L-1 和 I-4、I-5、I-6、I-7 已修）和修复后的独立复审（可以上测试网，无新问题）
- 结论：部署和整轮验收通过；拆分和每一块加池的金额与合约规则逐 wei 一致

## 部署

| 项 | 地址 / 交易 |
|---|---|
| GangLiquiditySplitterFactory | [`0xA729C60FCa0Bd0D28a55E22126D3fE412AA41591`](https://testnet.bscscan.com/address/0xA729C60FCa0Bd0D28a55E22126D3fE412AA41591)，部署 [`0x89c1d6f7…e51e`](https://testnet.bscscan.com/tx/0x89c1d6f7174858af3e51239adb85b2c42192fbc855bad4a1a2b033809624e51e)（gas 2,749,835） |
| 实现合约 | [`0x802656FEb07A7f9D754B848A0049141446d21782`](https://testnet.bscscan.com/address/0x802656FEb07A7f9D754B848A0049141446d21782) |
| `admin.setFactory(factory, true)` | 管理合约 v2 `0xBc2d…9a4d`，[`0xc377b16d…9733`](https://testnet.bscscan.com/tx/0xc377b16df77bd0ff9efac886f9c4750e061cf8c1789a5f22edbeb7accd9d9733)（gas 97,584）；测试网由 owner 钱包直接执行，主网是多签 |
| 部署脚本检查 | 接线检查、运行时字节码比对（`checkCode`）在模拟阶段通过 |

## 验收（`script/LpTestnetAcceptance.s.sol` + 照 keeper 方式发的 `work`）

dev = 部署钱包，加池比例 70%，dev 那份给一次性钱包 B（`payee`）。报价币 MockSPCXB `0x02B3…F1c`（QuoteRegistry 里有）。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 克隆模块（70%，payee = B） | [`0x275e03608E37b11E1F50Bd2636349d743FE6e1a9`](https://testnet.bscscan.com/address/0x275e03608E37b11E1F50Bd2636349d743FE6e1a9)，地址等于 `predict` | [`0x0cfa3bac…9d2b`](https://testnet.bscscan.com/tx/0x0cfa3bac53d6699901ee12abb0e2d163957f48519ad7ccdaacc4745fbf9a9d2b) |
| 建币 LPT（买卖税 3%，分红 40%，收款 = 模块） | [`0x2b9A60b68B95AaB5213C2749ADC82a5FbD3e62dd`](https://testnet.bscscan.com/address/0x2b9A60b68B95AaB5213C2749ADC82a5FbD3e62dd) | [`0x14a0d226…5025`](https://testnet.bscscan.com/tx/0x14a0d226be14cbbca9085be8689df2b60353e6d059e4d5da217b655b50cb5025) |
| `bind` | `token` / `quote` 写入 | [`0xb8cbcc77…8777`](https://testnet.bscscan.com/tx/0xb8cbcc77715ce70c5b1d7b63ac05f43b16ac0ce13a37f551beaa8d67897a8777) |
| 毕业 | 一次性 Agent 各买 1% 直到毕业；交易对 [`0x1b68…2055`](https://testnet.bscscan.com/address/0x1b68A01751d7d248ad4b9643B4dF471B3C3e2055)，毕业 LP 在 0xdead | 两次广播共 408 笔全部成功（第一次因一次性钱包预付 gas 不够中断在第 9 笔，见下） |
| 池子交易交税 | 部署钱包买 0.5、卖一半；卖出时的 swap-back 付给模块 0.007707490904267348 | [`0xdf831349…0d28`](https://testnet.bscscan.com/tx/0xdf831349e49763dbbef62080c1374e9ba13ed9c12325d457dfed3af0e5ff0d28) |
| `split` | 70% 留作加池 0.005395243632987143，30% 推给 B 0.002312247271280205，逐 wei 一致 | [`0x99f9b1c8…70d`](https://testnet.bscscan.com/tx/0x99f9b1c88ebd783c1f9dbfdf7d0f1b0f1683485d21021bffd484c4e6723cf70d) |
| 第一次 `addChunk(0)` | 只记 TWAP 观测点，不交易 | [`0x4f3659db…2f2a`](https://testnet.bscscan.com/tx/0x4f3659dbe307c8d46cd3c89036cd96a59d6c8fe9e1fb7aec8a6bd298f2216f2a) |
| 补 1 枚报价币给模块 | 让待加池子的量超过 keeper 门槛（报价币储备的 0.05%），走 keeper 的路径 | [`0xe438845b…f411`](https://testnet.bscscan.com/tx/0xe438845ba0a7734c74c41406e37d88b980d9c0c80ada97bc830665803924f411) |
| 10 分钟后，keeper 方式的第一块：`previewWork` → `cast estimate` × 1.3 → `work(minOut)` | due = true；`Split(1.0, 0.7, 0.3)`，B 收到 0.3；`LiquidityAdded(quoteIn 0.072162182416848806, tokensIn 471,929.41…, liquidity 128,440,727,404,373,191,086, left 0.633233061216138337)`：`lpLeft` 0.705395… → 0.633233…，差额 = `quoteIn`；0xdead 的 LP 增加量 = `liquidity`；模块不持有代币、不持有 LP；块中 swap-back 付进的 0.004496680342401150 留在 `unsplit`。估算 744,761，实际 628,825 | [`0xd38932e2…b79b`](https://testnet.bscscan.com/tx/0xd38932e2b88bf812078b55324669f60a5daab1b6e8d128c73d2d2a8b2cc7b79b) |
| 4 分钟内再调 | `previewWork` = (false, 0)；`cast estimate` 回滚 `AddTooSoon`（`0xd86de2a8`） | 只读 |
| 4 分钟后第二块 | 先拆分 swap-back 付进的部分（70% → `lpLeft` 0.636380737455819142），`quoteIn` 0.072468513078077053 后剩 0.563912224377742089，逐 wei 一致；0xdead 的 LP 增加 128,742,039,299,260,425,691 = `liquidity`。估算 622,263，实际 528,141 | [`0x5798765f…148d`](https://testnet.bscscan.com/tx/0x5798765f1b22db4dc27cddff5143e3d52c16db79f020e5cdcd279d1c6a76148d) |
| 收回一次性钱包剩下的 gas | 0.00332 tBNB 回到部署钱包 | `--sig "sweep()"` |

花费：第一轮两次广播约 3,796 万 gas（毕业占大部分），按 0.1 gwei 约 0.0038 tBNB；一次性钱包的预付 gas 已收回 0.00332 tBNB。

## 中断的一次广播

第一次跑验收时加了 `--gas-estimate-multiplier 200`，forge 给每笔交易的 gas limit 翻倍，而脚本按 60 万 gas 给一次性钱包预付 gas，第 10 笔（一个一次性钱包的买入）报「insufficient funds」，前 9 笔（克隆、建币、bind 等）已上链。去掉这个参数后用 `LP_MODULE`、`TOKEN` 续跑，399 笔全部成功。合约无关。

## gas

每块的 gas 在 53 万 ~ 63 万（测试网），主网 fork 上 56 万 ~ 73 万：存币那一步会让 handler 先卖一块已收的税（GangToken 给它最多 60 万 gas）。keeper 用节点估算 × 1.3 发送（和本次一样）是够的；不能按固定值或压低。

## 本次没测到（单测覆盖：`test/gang/GangLiquiditySplitter.t.sol` 30 个，`GangLiquiditySplitterPairTax.t.sol` 3 个，主网 fork 2 个）

- 改比例（调高立刻生效、调低 3 天公告、过期作废）、改 payee、payee 被拉黑记欠款和 `releaseDev`、余额被扣按比例缩减、`sweep`。
- 价格被拉高 2% 以上时不加池、拉盘后每 4 分钟最多一块。
- 有人往交易对里塞报价币时 keeper 的 `work(minOut)` 不失败（审计 L-1）。
- 转进交易对收税的报价币。
- 主网的多签 owner 检查（只在 chainid 56 生效）。

## 复跑

```sh
# 部署工厂（测试网由 owner 钱包直接 setFactory）
GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 HANDLER_ADMIN=0xBc2d7A1f2E86A7586f31A324aDaE3d38bFd49a4d \
  DEPLOYER_PRIVATE_KEY=… forge script script/DeployGangLiquiditySplitterFactory.s.sol \
  --rpc-url https://bsc-testnet-rpc.publicnode.com --broadcast --slow --legacy --with-gas-price 100000000

# 验收第一轮（续跑：LP_MODULE、TOKEN；池子交易做过以后 SKIP_POOL=true）
LP_FACTORY=0xA729C60FCa0Bd0D28a55E22126D3fE412AA41591 DEPLOYER_PRIVATE_KEY=… \
  forge script script/LpTestnetAcceptance.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com \
  --broadcast --slow --legacy --with-gas-price 100000000

# 10 分钟后，照 keeper 发一块（gas 由节点估算）
M=0x275e03608E37b11E1F50Bd2636349d743FE6e1a9
MIN=$(cast call $M "previewWork()(bool,uint256)" --rpc-url … | sed -n 2p | awk '{print $1}')
cast send $M "work(uint256)" $MIN --private-key … --rpc-url … --legacy --gas-price 100000000

# 看状态
LP_MODULE=$M DEPLOYER_PRIVATE_KEY=… forge script script/LpTestnetAcceptance.s.sol --sig "report()" --rpc-url …
```
