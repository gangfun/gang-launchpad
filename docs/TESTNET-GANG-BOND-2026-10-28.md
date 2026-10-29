# 测试网 · GangBond（Agent 押金承诺）

GangBond 在 BSC 测试网部署了四版，都挂在第 10 套内盘上：

| 版本 | 地址 | 区别 | 本文 |
|---|---|---|---|
| 第一版 | `0x587f563749A321624b5710d6D77010F183a65d7E` | 只能在毕业 / 开盘后押 | A、B 节 |
| 第二版 | `0x5a99F3eFf9D34cc8785f7D375eb565bDe7F2d716` | 发币后随时可押，承诺期从毕业 / 开盘起算；30 天兜底退款任何人可调 | C 节 |
| 第三版 | `0xB034cFeb81Cbd29EE3d0CD6a0885766B6F10EBE3` | 同第二版，退款改成 dev 发起 + 3 天公告期（内部审查二） | D 节 |
| 第四版（CLI 0.15.0 起内置） | `0xd6a8dd5d1E6641a34A255f25Db2B3ED397CB1086` | 主网前审计（`docs/AUDIT-GANG-BOND-2026-10-29.md`）：两块回购之间至少 4 分钟，`settle` 分两步（申请后 1 小时） | F 节 |

第一版：两枚币都走过了一遍：V3 币完整走完罚没流程（发押金 → 违约 → 举报 → 分块回购，按真实出块买完），打新币走完了除取回以外的全部操作。取回要等满 7 天，2026-11-05 之后再补测。

- 链：BSC 测试网（chainId 97），2026-10-28
- 规格：`docs/SPEC-GANG-BOND-2026-10-28.md`；PR #39
- 驱动方式：CLI `gang bond … --testnet --calldata --from <addr>` 生成交易，`cast send --legacy` 签名发送（见文末「gas」）

## 地址（第一版）

| 项 | 值 |
|---|---|
| GangBond | [`0x587f563749A321624b5710d6D77010F183a65d7E`](https://testnet.bscscan.com/address/0x587f563749A321624b5710d6D77010F183a65d7E) |
| 部署交易 | [`0xfeee09a1…4745b`](https://testnet.bscscan.com/tx/0xfeee09a1f53d4b28c93d6d33e15c8e83510aa9de4282a7f9d408474c4d84745b)，区块 139343423，gas 2,389,203 |
| 构造参数 | pad = 第 10 套 GangLaunchpad `0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`，wbnb = `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd` |
| 部署 / 创建者钱包 | `0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`（第 10 套 owner，两枚测试币的创建者） |
| 举报人钱包 | `0x3FBf068ad90d1904857c14f8E3218cFD80B85376`（本次新建，只用于举报和回购） |
| 源码验证 | 第一版未做；第四版 `0xd6a8…1086` 已验证（2026-10-29） |

CLI 现在内置的是第三版地址（见 D 节）；要操作第一版上的押金（比如 B 币 11-05 之后的取回），加 `GANG_TESTNET_BOND=0x587f563749A321624b5710d6D77010F183a65d7E`。

## A｜V3 币完整罚没流程

币 `0x45271F59f5726c9Fdf537b813bCa732Da215389F`：已毕业，报价币 MockSPCXB（`0x02B3…CF1c`），买卖税各 2%，交易对 `0x957c…5b24`（Pancake 测试网 V2，报价币储备约 15.15）。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 授权报价币给 GangBond | 成功 | [`0xb50814e2…0a2b`](https://testnet.bscscan.com/tx/0xb50814e2461bc83e935c089d5f2626cefc33e9425a5f421a0b2c4ecabcbd0a2b) |
| `post`：押 0.3，X = 5,000,000（总量 0.5%），7 天 | 成功，覆盖率 82.2%（「押金」档），gas 232,936 | [`0x3fdc0b70…30cc`](https://testnet.bscscan.com/tx/0x3fdc0b70df8f45d4b8a7e9db2285bbe912beae76dcc87b6ef22e30ce148f30cc) |
| 卖出保护：卖 300 万（会低于 X） | CLI 拒绝，给出 `maxSellKeepingBond` 1,933,582 | 只预览 |
| 卖出保护：卖 50 万（余量内） | 放行，预览带 `bondCheck.headroomAfter` | 只预览 |
| 未违约时举报 | CLI 拒绝（`NotViolated`） | 只预览 |
| 到期前取回 | CLI 拒绝（`NotDue`） | 只预览 |
| 创建者把 2,500,000 转到别的地址（违约） | 成功，余额 4,433,582 < X，`isViolated = true` | [`0xfa25c415…42f1c`](https://testnet.bscscan.com/tx/0xfa25c4155c60876efa21465816d548c9ee6dc8eec8060535c44f58d6f2342f1c) |
| 违约后创建者再卖 | CLI 提示「押金已经破了」 | 只预览 |
| 举报人 `report` | 成功，举报人收到 0.003（1%），`burnLeft` 0.297，gas 95,036 | [`0xd8ad1854…de7c`](https://testnet.bscscan.com/tx/0xd8ad18541e44ac23cca43b42b9c493a30ab426ddb5f192aad46ef86960bfde7c) |

回购（`burnChunk`，举报人调用，按真实出块大约每 10.5 分钟一次）：

| 时间（UTC） | 结果 | 花费（MockSPCXB） | 销毁（枚） | 剩余 `burnLeft` | gas | 交易 |
|---|---|---|---|---|---|---|
| 03:06 | 只记观测点 | 0 | 0 | 0.297 | 133,199 | [`0x8d77d841…bd05`](https://testnet.bscscan.com/tx/0x8d77d84108ccfa443f0cf6b10f2f226062c5ca7dde585adfbe9009205118bd05) |
| 03:16 | 距观测不到 10 分钟，不买 | 0 | 0 | 0.297 | 52,839 | [`0x63f05638…982b`](https://testnet.bscscan.com/tx/0x63f05638657ec7e47c9ba0602bc83be74b599998831cca36d0f47d981e59982b) |
| 03:26 | 第 1 块 | 0.075754 | 963,170 | 0.221246 | 333,825 | [`0xb7fa3f59…1c5b`](https://testnet.bscscan.com/tx/0xb7fa3f59bb5646354beba18a7cc9eb50717043d143012ce02b43bbdd71511c5b) |
| 03:37 | 第 2 块 | 0.076133 | 958,390 | 0.145113 | 268,366 | [`0x4247b953…5707`](https://testnet.bscscan.com/tx/0x4247b953b4662b7187b51adba39145e9626eeca3701e97356bf46ce49e435707) |
| 03:48 | 第 3 块 | 0.076514 | 953,634 | 0.068599 | 268,366 | [`0xd993a9c6…afa0`](https://testnet.bscscan.com/tx/0xd993a9c6850a370d577a4b5d1ae963f8eef74e9e54727d2d3116a671ae0bafa0) |
| 03:58 | 第 4 块（最后一块） | 0.068599 | 846,967 | 0 | 268,362 | [`0xb1163590…8eca`](https://testnet.bscscan.com/tx/0xb1163590d0d36a8441ccfc7721538a33ef6195b6aec65faa878fde4dbf318eca) |

- 合计花费 0.297，销毁 3,722,161.72 枚到 0xdead。每块实际销毁量都等于预览值（`previewBurn` 已扣 2% 买入税）。
- 每块约占交易对报价币储备的 0.5%（第 4 块受 `burnLeft` 限制）。买完后状态为 Slashed、`burnLeft = 0`，创建者可以押下一轮。
- 创建者记录：押过 2 次，守约 0 次，违约 1 次（同一个钱包也是 B 的创建者）。

## B｜打新币，取回以外的全部操作

币 `0x08DAfFbceB4f06B21eA04FF816a582aBed7988C2`：已开盘，报价币 MockSPCXB，交易对 `0x56BF…14AE`。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 授权 + `post`：押 0.2，X = 60,000,000，7 天 | 成功，覆盖率 9.07%（无标识档），gas 200,093 | [`0x8aa6121e…3c1d`](https://testnet.bscscan.com/tx/0x8aa6121e3c09437f1e31430c53ffae5a1d05f9610aba1f91717c3ac1e2f83c1d)、[`0x32a892d7…7a36`](https://testnet.bscscan.com/tx/0x32a892d79283805d81c28baaf3821eb3bd04fa54b92c795314edd61500f77a36) |
| 授权 + `topUp --cover 30`：加 0.461409 | 成功，押金 0.661409，覆盖率 30% | [`0x0f090d0a…31e6c`](https://testnet.bscscan.com/tx/0x0f090d0abb7a8805af8914c1d43079ae34cb0b68de29a5d8df959d6877531e6c)、[`0x89df0d94…200c1e`](https://testnet.bscscan.com/tx/0x89df0d9418f4494ebee7d31c5388689029745ececa8b9bdd4a477aa843200c1e) |
| `raiseHold`：X 提高到 65,000,000 | 成功，覆盖率降到 27.97% | [`0x8f9e6832…2abb`](https://testnet.bscscan.com/tx/0x8f9e68323797d4a5a1f5851dc34626f7700352efbf2d8d6056ab226943c62abb) |
| `extend`：T 延后 1 天，到 2026-11-05 04:08 UTC | 成功 | [`0x6b8a6e9c…b2b9fc`](https://testnet.bscscan.com/tx/0x6b8a6e9c456d119bd9a15ca2f4a1599b15bd08f5109620f50e9862dab6b2b9fc) |
| X 往下调、重复 post | CLI 拒绝（X 只能提高；`BondLive`） | 只预览 |
| 卖出保护：`gang fair sell` 卖 2000 万 / 100 万 | 前者拒绝（`maxSellKeepingBond` 17,412,454），后者放行 | 只预览 |
| 到期前取回 | CLI 拒绝（`NotDue`） | 只预览 |

B 的押金还在生效，留着下次测取回：2026-11-05 04:08 UTC 之后执行 `GANG_TESTNET_BOND=0x587f563749A321624b5710d6D77010F183a65d7E gang bond settle --token 0x08DA…88C2 --testnet`（第一版合约），预期 0.661409 MockSPCXB 退回创建者，守约次数加 1。

## C｜第二版：在内盘上押金

| 项 | 值 |
|---|---|
| GangBond（第二版） | [`0x5a99F3eFf9D34cc8785f7D375eb565bDe7F2d716`](https://testnet.bscscan.com/address/0x5a99F3eFf9D34cc8785f7D375eb565bDe7F2d716) |
| 部署交易 | [`0xdd50dbf4…4698`](https://testnet.bscscan.com/tx/0xdd50dbf47df86ff6f3a9ab61b4bad5254fc0373b157024f9c137add2111a4698)，区块 139370168，gas 2,732,393 |

币 `0x10fF6DBa8c74c8Fa571094CA57F1E126B23Da935`：V3，还在内盘（距毕业约 15 WBNB），报价币 WBNB，创建者持有 211,116 枚。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 内盘上 `post --cover 100` | CLI 拒绝：没有交易对，没法给 X 定价，要用 `--amount` | 只预览 |
| `post`：押 0.01 BNB（原生 BNB），X = 150,000，7 天 | 成功，状态「待开始」：`deadline` 为空，可退款日期 2026-11-27，gas 202,919 | [`0x83cfdd08…a18b`](https://testnet.bscscan.com/tx/0x83cfdd083acf262a3e0af125833c551fd68b1ecebf7f6232fabd38aa4218a18b) |
| 毕业前 `start` / `settle` / `refund` | CLI 分别提示：还没毕业 / 还没开始计时 / 要等满 30 天 | 只预览 |
| `extend 3 天` | 成功，时长 7 → 10 天，仍待开始 | [`0xfef7e1a4…6721`](https://testnet.bscscan.com/tx/0xfef7e1a449546990eb0534cf7f81112b7020fa9feea5d38f9fdb12479c2a6721) |
| 内盘卖出保护：卖 10 万 / 5 万 | 前者拒绝（`maxSellKeepingBond` 61,116），后者放行并带 `bondCheck` | 只预览 |
| 创建者 `gang v3 sell --amount 100000 --break-bond`（内盘卖出） | 成功，余额 111,116 < X，链上 `isViolated = true` | [`0x77acd196…d50d`](https://testnet.bscscan.com/tx/0x77acd196323559ba855094379a3db3037f3c447f346b6461da3db381e3b2d50d) |
| 举报人 `report`（内盘上） | 成功，举报人收到 0.0001 WBNB（1%），`burnLeft` 0.0099 | [`0x9e8f7229…9739`](https://testnet.bscscan.com/tx/0x9e8f722975569ebe7f29aaa89441b93616077ce8ed05e0ba70276611a9c47739) |
| 毕业前 `burn` | 回滚 `NotTradable`；状态里写明等毕业，2026-11-27 前还没毕业就把报价币转 0xdead | 只预览 |

这枚币要毕业得有人在内盘买满约 15 WBNB，测试网上没法凑齐，所以「毕业后开始计时」「30 天退款」「30 天后报价币转 0xdead」在单测和主网分叉上验证（规格文档「测试」一节）。2026-11-27 之后可以在这里补测报价币转 0xdead：`gang bond burn --token 0x10fF…a935 --testnet`。

## E｜一条命令发射（`gang create --dev-buy --bond`、`gang fair create --bond`）

同一条命令反复运行，每次签名发出它给出的那笔交易（GangBond 第三版）：

| 命令 | 每次运行的结果 | 币 |
|---|---|---|
| `gang create --symbol BLT1449 --dev-buy 0.01 --bond 0.005 --bond-days 7` | 发币 → dev 内盘买入 2,107,826 枚 → 押金（X = 全部，待开始）→ done | [`0xA7F1…2e42`](https://testnet.bscscan.com/address/0xA7F1B8838ed7Be80D33Eef2025759a8b21Ea2e42) |
| `gang fair create --symbol BFT1453 --shares 1 --bond 0.002 --bond-days 7` | 发币（含 1 份 dev 份额，50,000 枚）→ 押金（待开始）→ done | [`0xF8F7…d392`](https://testnet.bscscan.com/address/0xF8F7d668896BA0735e5e82CeA47B80Fb27f5d392) |
| `gang create --symbol DBT1454 --dev-buy 0.002`（不押金） | 发币 → dev 内盘买入 422,233 枚 → done | [`0x48e9…eE74`](https://testnet.bscscan.com/address/0x48e93738985c06AafcA502Dc7e29722E4F68eE74) |

测试中发现并修掉两个问题：

- 完成后原先会删掉本地发射计划，再跑一次同一条命令就从头又发了一个币（测试网因此多出 `0x1153…9aAe`、`0x1AFD…37B5` 两个测试币）。现在完成后计划保留 7 天，再跑只会重复报告完成；要用同样的名称和代号再发，必须加 `--restart`。
- 打新发币前的授权步骤被当成了「已发币」，下一次运行就去找新币，结果停住。现在只有发币那一笔预览成功才记计划。

修复后，完成后再跑一次同一条命令，只返回 `done`，不生成交易。之后又加了一层：完成状态记进计划（连同找到的币地址），所以 dev 后来把币卖光（`DBT1454` 实测：内盘全部卖出，余额 0）再跑，仍然只报告完成，不会重新买入。

## gas：cast 发交易要用 legacy

`cast send` 默认发 EIP-1559 交易，只用 `--gas-price` 的话，小费（priority fee）是 1 wei。Chapel 验证者要求小费至少 0.1 gwei（官方节点的报错：`gas tip cap 1, minimum needed 100000000`），所以这些交易会一直卡在 publicnode 的内存池里不被打包，后面的 nonce 也跟着堵住。用 `cast send --legacy --gas-price 1gwei`，经官方节点 `https://data-seed-prebsc-1-s1.bnbchain.org:8545` 发送，就能正常打包。

CLI 的 `--calldata` 只输出 to / data / value，gas 由签名方决定；用 Agentic Wallet（`baw`）签名不受影响。

## 本次没测到

- 取回（`settle`）的真实上链：B 要等到 2026-11-05。取回逻辑在单测和主网分叉端到端里测过。
- 第二 / 三版的毕业后开始计时、两步退款和报价币销毁：测试网凑不齐毕业，在单测和主网分叉上测过；C 币 2026-11-27 之后可补测报价币销毁。
- 打新卖回份额的保护：测试网上没有正在打新、创建者持有份额的币，在主网分叉上测过。

## D｜第三版：退款改成 dev 发起 + 3 天公告期

| 项 | 值 |
|---|---|
| GangBond（第三版） | [`0xB034cFeb81Cbd29EE3d0CD6a0885766B6F10EBE3`](https://testnet.bscscan.com/address/0xB034cFeb81Cbd29EE3d0CD6a0885766B6F10EBE3) |
| 部署交易 | [`0x0730733e…8851`](https://testnet.bscscan.com/tx/0x0730733e34c8667b65648cf52b07bf1de7c6df2c775f4671257e040b628a8851)，区块 139374309，gas 2,841,254 |

同一枚内盘币 `0x10fF…a935`（创建者此时持有 111,116 枚）：

| 步骤 | 结果 | 交易 |
|---|---|---|
| `post`：押 0.01 BNB，X = 100,000，7 天 | 成功，待开始，可申请退款的日期 2026-11-27，gas 202,980 | [`0x4491dbb1…82f5`](https://testnet.bscscan.com/tx/0x4491dbb16bae3391b01e26aca2369ce054567d9b5cca32871d8cd87038b282f5) |
| 陌生人 `refund` | CLI 拒绝：只有创建者能申请 | 只预览 |
| 创建者不满 30 天 `refund` | CLI 拒绝，给出可申请日期 | 只预览 |
| 毕业前 `start` | CLI 拒绝 | 只预览 |
| 内盘卖出保护：卖 2 万 / 5 千 | 前者拒绝（`maxSellKeepingBond` 11,116），后者放行 | 只预览 |

这笔押金保持生效、没有违约，留着补测两步退款：2026-11-27 06:34 UTC 之后，创建者执行 `gang bond refund --token 0x10fF…a935 --testnet` 申请（开始 3 天公告期），3 天后再执行一次取回 0.01 WBNB。两步退款已在主网分叉上跑通（申请 → 公告期内执行被拒 → 3 天后取回）。
- `--use-wbnb` 支付：在主网分叉端到端里测过（原生 BNB 支付已在 C 节上链）。
- `baw` 签名：本次全部用 `--calldata` 加 cast 签名。
- 服务端索引和 keeper：还没做。

## F｜第四版：审计修复（2026-10-29）

| 项 | 值 |
|---|---|
| GangBond（第四版） | [`0xd6a8dd5d1E6641a34A255f25Db2B3ED397CB1086`](https://testnet.bscscan.com/address/0xd6a8dd5d1E6641a34A255f25Db2B3ED397CB1086) |
| 部署交易 | [`0x3e1a5587…1d44`](https://testnet.bscscan.com/tx/0x3e1a5587fe808a1e188f483727bb2ea27ac8fa3b9e35905b0599e48417d11d44)，区块 139463214，gas 2,969,709；链上读到 `CHUNK_GAP` 240、`SETTLE_DELAY` 3600 |

打新币 `0x08DA…88C2`（已开盘，报价币 MockSPCXB，交易对报价币储备约 17.8），创建者 `0xCa8e…00b6`，举报人 `0x3FBf…5376`。全程用 CLI（`GANG_TESTNET_BOND` 指向第四版）生成交易，cast `--legacy` 发送：

| 步骤 | 结果 | 交易 |
|---|---|---|
| 授权报价币 | 成功 | [`0xa153aaad…2742`](https://testnet.bscscan.com/tx/0xa153aaada878d868d3f1973e43098f55e88b4822a9749a7a6a718f27e2932742) |
| `post`：押 0.3，X = 82,412,454（创建者几乎全部持仓），7 天 | 成功，覆盖率 10.36%，gas 234,483 | [`0x646230a3…a70b`](https://testnet.bscscan.com/tx/0x646230a3a917530c24afcb398a9035b585045996def482c34c60958da65fa70b) |
| 创建者转出 1 枚（低于 X） | 违约 | [`0xbc1cce36…6b69`](https://testnet.bscscan.com/tx/0xbc1cce36b8c7ad12de5d79a0d69eb4e0bffcdce5328a6b7e7bf01ace35eb6b69) |
| 举报 | 举报人得 0.003，回购余 0.297 | [`0x04d203c0…75c4`](https://testnet.bscscan.com/tx/0x04d203c00328a8446e06275a259623e0ec8d9eae741ac7a579533216d49475c4) |
| 首次 `burn` | 只记观测点 | [`0xbb7077df…6023`](https://testnet.bscscan.com/tx/0xbb7077df5a724dfa904476bfa3a6ee0fed3e9f73bf8c44a2aa65f86985416023) |
| 10 分钟后第 1 块 | 0.0892 报价币，约 206.5 万枚到 0xdead | [`0xc77a52e0…48b0`](https://testnet.bscscan.com/tx/0xc77a52e0b91abe866191a49375b22c454b98a2662dfe1b37c4e0a6dd4c7b48b0) |
| 紧接着再 `burn` | CLI 模拟回滚 `BurnTooSoon`，不发送 | 只预览 |
| 第 2 块（隔 252 秒） | 0.0897，约 205.5 万枚 | [`0xa0801d81…26d7`](https://testnet.bscscan.com/tx/0xa0801d81316a7364ddc82686bc3fcae660110da5ae2470ecce09d71073c826d7) |
| 第 3 块（隔 249 秒） | 0.0901，约 204.5 万枚 | [`0x5a761fa4…722f`](https://testnet.bscscan.com/tx/0x5a761fa4adb95041a77ea79af6e576f44e605b619d8c310d99a4ca88f957722f) |
| 第 4 块（隔 252 秒） | 剩余 0.0280，约 63.0 万枚，`burnLeft` 归零 | [`0xcb7a5919…0c3d`](https://testnet.bscscan.com/tx/0xcb7a59190c118cae5a4a4136b5a21ef6f717a35ff19f660597184b40b38a0c3d) |

两步 `settle` 要等满 7 天的承诺期，测试网上没等，在 BSC 主网分叉（anvil，本地，未广播）上用 CLI 跑通：
- 到期前 `settle` 被拒；
- 到期后卖出全部被卖出保护拦下，加 `--settle-first` 时给出 `requestSettle`；
- 一小时内再次 `settle` 和 `--settle-first` 都被拒，并给出 `settleRunsAt`；
- `status` 显示 `settleRequested`；
- 一小时后 `settle`，0.1 WBNB 回到创建者。

### F2｜两步取回补测（进行中）

V3 币 `0x4527…389F`（已毕业，报价币 MockSPCXB，创建者持有 4,433,582 枚），在第四版上再押一笔，到期后由 keeper 在真实测试网上走两步取回：

| 步骤 | 结果 | 交易 |
|---|---|---|
| 授权报价币 | 成功 | [`0x0854d847…22b6`](https://testnet.bscscan.com/tx/0x0854d8470217afde6998201a9e3c5bf1a7dcdfc5a8a49a9dfc1624019a8622b6) |
| `post`：押 0.1，X = 2,000,000，7 天 | 成功，覆盖率 64.96%（「押金」档），期限 **2026-11-04 20:01:57 UTC**，gas 216,036 | [`0xe56e419c…6706`](https://testnet.bscscan.com/tx/0xe56e419c8fe1319e83fb4317512570a7bcee3703136020c011768b1899b46706) |
| 到期前 `settle` | CLI 拒绝（`NotDue`，剩 604,797 秒） | 只预览 |

到期后由测站 239 上的押金 keeper 自动完成两步：每 5 分钟一次的 cron（`keeper-bond.sh --broadcast`，只配了 `BONDS=bondt4:0xd6a8…1086@139463214`，没有别的 keeper 任务）。它会先发 `requestSettle`，1 小时后再发 `settle`。keeper 钱包 `0x3Ef9CDAC70f13c04eD24d88534a8039B87fbF3c3` 由创建者钱包转入 0.02 tBNB（[`0x0302198b…6be1`](https://testnet.bscscan.com/tx/0x0302198bfffeeb92a89cb0f8e36e3908e425df3073e00d7fc283bd8ee9b76be1)），私钥只存在 239 的 `/opt/gang/keeper/.env` 里。到期后查看：

- 239 上的 `/opt/gang/keeper/logs/keeper-bond.log`；
- `gang bond status --token 0x45271F59f5726c9Fdf537b813bCa732Da215389F --testnet`（`settleRequested` → `settled`）；
- 测站 `/api/bonds/0x4527…`，phase 依次是 `due` → `settle-requested` → `settled`。

第三版上留着的 `0x10fF…a935` 两步退款补测照旧，要加 `GANG_TESTNET_BOND=0xB034cFeb81Cbd29EE3d0CD6a0885766B6F10EBE3`。
