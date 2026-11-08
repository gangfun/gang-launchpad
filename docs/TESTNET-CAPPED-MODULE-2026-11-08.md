# 测试网记录 · GangCappedSplitter（税收封顶收款模块，`capped-v1`）

- 日期：2026-11-08 Asia/Shanghai
- 网络：BSC 测试网（97），GangLaunchpad 3.0 代理 `0x0508232833aE6849c03b28F7aA248BBd5cFCceE2`
- 规格：`docs/SPEC-CAPPED-MODULE-2026-11-08.md`
- 代码：分支 `feat/capped-module`（基于 main `ea52f78`）。合约源码和测试网上部署的完全一致：部署脚本的运行时字节码比对（`checkCode`）在本分支上对测试网工厂重跑通过
- 部署前：
  - 一轮审计，没有高中危，1 个低危（`capQuote` 可以是 dev 自己发的报价币，等于绕开上限），已修：建模块时只接受 keeper 服务的报价币，否则 `BadQuote`。
  - 一轮对照规格的测试复审，主要指出预览和实际拆分一致性（I-5）没有被测试证明，已补 harness 模糊测试。
  - 修复后的独立复审没有发现低危及以上问题；15 个变异测试全被测试抓到。
- 结论：部署和整轮验收通过。跨越上限那一笔、封顶前后的拆分、回购一块、加池一块，金额都和合约规则逐 wei 一致

## 部署

| 项 | 地址 / 交易 |
|---|---|
| GangCappedSplitterFactory | [`0xe3f61865d98993dd39c136Af19651C6F6686498A`](https://testnet.bscscan.com/address/0xe3f61865d98993dd39c136Af19651C6F6686498A)，区块 141527185，部署 [`0xdc747868…1fae`](https://testnet.bscscan.com/tx/0xdc74786861ba4ad8d24b7774eed491c427fb32984ddf38f6b4af95cb21f22fae) |
| 实现合约 | [`0xC0e773761404CDbca05769a326cC7ca704b6C4ca`](https://testnet.bscscan.com/address/0xC0e773761404CDbca05769a326cC7ca704b6C4ca)，`pad()` = 3.0，`gangQuote` = 0（测试网没有 GANG） |
| `admin.setFactory(factory, true)` | 3.0 的 GangHandlerAdmin `0x0fb8280B88a4DF00e8654cfE9cBd544D104a9D23`，区块 141527190，[`0x6ba56465…4f53`](https://testnet.bscscan.com/tx/0x6ba56465dae998d7077615b87a6a2dba4430c698af646e4827065e58cfc74f53)。测试网由 owner 钱包直接执行，主网是多签 |
| 部署脚本检查 | 接线检查和运行时字节码比对在模拟阶段通过；部署后 `isFactory` = true |

记录：`broadcast/DeployGangCappedSplitterFactory.s.sol/97/run-1794138104540.json`。

## 验收一：合约（`script/CappedTestnetAcceptance.s.sol`，再按 keeper 的方式发 `split` / `work`）

dev = 部署钱包。上限 0.001 测试报价币，封顶前 50% 给收款人（部署钱包 70%、一次性钱包 B 30%），其余 70% 回购、30% 加池。报价币 MockSPCXB `0x02B3…F1c`（QuoteRegistry 里有，`keeperServes` = true）。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 克隆模块 | [`0x65EfDb985B4B05a282176A480Ac1455dc809aEf3`](https://testnet.bscscan.com/address/0x65EfDb985B4B05a282176A480Ac1455dc809aEf3)，地址等于 `predict`，上限、比例和收款人写入正确 | [`0xa82892e0…e8bc`](https://testnet.bscscan.com/tx/0xa82892e02b8afb5aae3ae1098a98a0d0324540d99bfd0b69cc37679c66cbe8bc) |
| 建币 CAPT（买卖税 3%，分红 40%，收款 = 模块） | [`0x95d18dc6356AA526CF3ecbace5006E8C6e1AE023`](https://testnet.bscscan.com/address/0x95d18dc6356AA526CF3ecbace5006E8C6e1AE023) | [`0x1166fca0…b918`](https://testnet.bscscan.com/tx/0x1166fca0418bf041899212f230c9e59a8d54901967f10b4dcd8ad3b85a51b918) |
| `bind` | `token` / `quote` 写入 | [`0xaf022bf7…fe7d`](https://testnet.bscscan.com/tx/0xaf022bf7bfb621ad35e2c8bc273fe6e9d1ef15e20c73cba5062b755fbe8dfe7d) |
| 毕业、池子交易交税 | 一次性 Agent 买到毕业；交易对 [`0x99bD…a2fA`](https://testnet.bscscan.com/address/0x99bD518Cce69942D47dEe8C6F009D21d1291a2fA)；卖出时的 swap-back 付给模块 0.007868026816606558 | 404 笔全部成功（记录 `broadcast/CappedTestnetAcceptance.s.sol/97/run-1794138244801.json`） |
| `split()`（`cast send`，gas 由节点估算） | 一笔跨过上限：收款人按 50% 本该拿 0.003934…，只拿到上限 0.001（B 0.0003，部署钱包 0.0007）；其余 0.006868026816606558 里回购 0.004807618771624590、加池 0.002060408044981968，逐 wei 一致；`paidTotal` = `capAmount`，`capReached` = true。实际用 gas 189,471 | [`0x282d58d6…cced5`](https://testnet.bscscan.com/tx/0x282d58d66a5ea24b82434415419879ba722e3e2a3eae64df051c51bf464cced5) |
| keeper 第一次 `work`：动作字节 = 3（记观察点） | 观察点写入，不交易 | [`0x92d663ff…2bde`](https://testnet.bscscan.com/tx/0x92d663ff915c707b983d431a66ed69bfdfead33bed536ed1b5b9353660a22bde) |
| 10 分钟后 keeper `work`：动作字节 = 1（回购那部分更大） | 回购余额 0.004807618771624590 全部花掉（低于每块上限），买到的代币进 0xdead，模块不留代币。实际用 gas 329,825 | [`0x4af648ef…c961`](https://testnet.bscscan.com/tx/0x4af648efe3efaa0ba70ab238ca052162911bf1b5eeec54a96f763d3485bbc961) |
| 加池一块（`gang capped chunk`，CLI 生成的交易） | 加池余额 0.002060408044981968 低于 keeper 的起做门槛（交易对报价币储备的 0.05%），所以 keeper 不做，用 CLI 手动做：`LiquidityAdded`，0xdead 的 LP 增加 4.545535630478877043；模块不持有代币和 LP。实际用 gas 576,924 | [`0xb251ab48…b584`](https://testnet.bscscan.com/tx/0xb251ab4896136b60eac7fe3f78385ec030d774d095ff4c472b5cbbe44be2b584) |
| 收回一次性钱包剩下的 gas | 0.0052756 tBNB 回到部署钱包 | `--sig "sweep()"` |

**`split()` 第一次回滚 `PushStarved`（钱没动）**：forge 脚本给的 gas 上限是 261,705，而合约每次推送前要求剩余 gas 不少于约 36.5 万（`PUSH_GAS × 64/63 + PUSH_RESERVE`，同组合模块）。改用 `cast send` 让节点估算后一次成功。和组合模块、Split 模块一样，调用方必须用节点估算的 gas；CLI 从不自己设 gas 上限。

## 验收二：CLI（分支上的 `skill/gang-cli`，测试网工厂已内置）

CLI 生成交易，`cast send` 发出。dev = 部署钱包，收款人 = 部署钱包 70%、一次性钱包 B 30%，报价币 WBNB。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 发币前拒绝 | 不带税、和 `--buyback` 同用、只给 `--tax-cap-share`、`--after-cap` 合计不是 100、普通创建带 `--cap`（打新的参数）：5 种都在发交易之前拒绝 | 无 |
| `gang create … --buy-tax 3 --sell-tax 3 --dividend 40 --tax-cap 0.0005 --tax-cap-share 50 --split self:70,B:30 --after-cap buyback:70,lp:30` | 三步：克隆模块 [`0x3B4F516EA904225237c0547a687Dc7BD01bdA0d3`](https://testnet.bscscan.com/address/0x3B4F516EA904225237c0547a687Dc7BD01bdA0d3)、建币 [`0x8650C44094e2247362cf90d4dea8499870016fF7`](https://testnet.bscscan.com/address/0x8650C44094e2247362cf90d4dea8499870016fF7)、绑定。链上读回：`capQuote` = WBNB，`capAmount` = 0.0005，`payBps` = 5000，`buybackOfRestBps` = 7000。预览里有封顶前后的去向、估算多少池子成交量会封顶、封顶管什么不管什么、"永久不可改"的说明 | [`0xc7b6bf15…c021`](https://testnet.bscscan.com/tx/0xc7b6bf15f01fb0ad6b9b74186b08be3e04412a030f32856a2d60e1075eece021)、[`0x3fc3c79e…3f5d`](https://testnet.bscscan.com/tx/0x3fc3c79e5c57ef3189f341b98535c9f15c1f279e97a660d89ebbdbbd9e183f5d)、[`0xfb88b92a…f277`](https://testnet.bscscan.com/tx/0xfb88b92ad8f4e892d9a1ffda0fb3a84c78083996dedfecb3b9ebbb9fb861f277) |
| 转进 0.0006 WBNB，`gang capped distribute` | 收款人 0.0003（部署钱包 0.00021、B 0.00009），回购 0.00021、加池 0.00009，和预览一致；`paidTotal` = 0.0003 | [`0x28f3ce63…7189`](https://testnet.bscscan.com/tx/0x28f3ce6309efa63d7795958d788aee5d6cce100ddcb6d34eca663eb1fdb17189) |
| 再转进 0.0004，`gang capped distribute` | 按 50% 本该给 0.0002，正好是剩下的额度：`paidTotal` = `capAmount`，事件有 `Split` 和 `CapReached` | [`0x15e719bd…8761`](https://testnet.bscscan.com/tx/0x15e719bd86898bd56f121d1b7dd3f6e4269d7e964164a1ef2d91d5fda9368761) |
| 转进 0.001 测试报价币（不是绑定的报价币），`gang capped distribute --asset` | 全部进 0xdead，收款人没拿到；`gang capped release --asset` 被 CLI 拒绝（这种资产不会欠给收款人） | — |
| `gang info`、`gang capped status` | 显示收款模块是 capped、上限进度 100%、`reached` = true | 无 |

## 本次没测到（单测覆盖）

- `test/gang/GangCappedSplitter.t.sol` 30 个，`GangCappedSplitterPairTax.t.sol` 2 个，`GangCappedSplitterPreview.t.sol` 5 个（含 harness 模糊测试），主网 fork `test/fork/CappedMainnetFork.t.sol` 3 个（3.0、真实 PancakeSwap，WBNB 和 USDT 各跑一遍完整流程，加报价币不对时绑不上）。
- 收款人拒收后记欠款、欠款计入上限、`release` 分次补发、换地址带走欠款、余额被扣时按比例缩减且 `paidTotal` 不回退。
- 十个耗尽 gas 的收款人、两个同报价币的币共用一个上限、诱饵绑定、拉盘后暂停、转进交易对收税的报价币。
- 主网的 3.0 / admin / 多签 owner / `gangQuote` 检查（只在 chainid 56 生效）。
