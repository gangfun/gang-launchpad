# 测试网 · GangBond（Agent 押金承诺）

GangBond 已部署到 BSC 测试网，挂在第 10 套内盘上。两枚币都走过了一遍：V3 币完整走完罚没流程（发押金 → 违约 → 举报 → 分块回购，按真实出块买完），打新币走完了除取回以外的全部操作。取回要等满 7 天，2026-11-05 之后再补测。

- 链：BSC 测试网（chainId 97），2026-10-28
- 规格：`docs/SPEC-GANG-BOND-2026-10-28.md`；PR #39
- 驱动方式：CLI `gang bond … --testnet --calldata --from <addr>` 生成交易，`cast send --legacy` 签名发送（见文末「gas」）

## 地址

| 项 | 值 |
|---|---|
| GangBond | [`0x587f563749A321624b5710d6D77010F183a65d7E`](https://testnet.bscscan.com/address/0x587f563749A321624b5710d6D77010F183a65d7E) |
| 部署交易 | [`0xfeee09a1…4745b`](https://testnet.bscscan.com/tx/0xfeee09a1f53d4b28c93d6d33e15c8e83510aa9de4282a7f9d408474c4d84745b)，区块 139343423，gas 2,389,203 |
| 构造参数 | pad = 第 10 套 GangLaunchpad `0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`，wbnb = `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd` |
| 部署 / 创建者钱包 | `0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`（第 10 套 owner，两枚测试币的创建者） |
| 举报人钱包 | `0x3FBf068ad90d1904857c14f8E3218cFD80B85376`（本次新建，只用于举报和回购） |
| 源码验证 | 未做（缺 BscScan API key） |

CLI 已内置这个地址（`skill/gang-cli/src/bond.js` 的 `TESTNET_BOND`），`gang bond … --testnet` 不需要设环境变量。

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

B 的押金还在生效，留着下次测取回：2026-11-05 04:08 UTC 之后执行 `gang bond settle --token 0x08DA…88C2 --testnet`，预期 0.661409 MockSPCXB 退回创建者，守约次数加 1。

## gas：cast 发交易要用 legacy

`cast send` 默认发 EIP-1559 交易，只用 `--gas-price` 的话，小费（priority fee）是 1 wei。Chapel 验证者要求小费至少 0.1 gwei（官方节点的报错：`gas tip cap 1, minimum needed 100000000`），所以这些交易会一直卡在 publicnode 的内存池里不被打包，后面的 nonce 也跟着堵住。用 `cast send --legacy --gas-price 1gwei`，经官方节点 `https://data-seed-prebsc-1-s1.bnbchain.org:8545` 发送，就能正常打包。

CLI 的 `--calldata` 只输出 to / data / value，gas 由签名方决定；用 Agentic Wallet（`baw`）签名不受影响。

## 本次没测到

- 取回（`settle`）的真实上链：B 要等到 2026-11-05。取回逻辑在单测和主网分叉端到端里测过。
- 原生 BNB 支付：两枚测试币的报价币都不是 WBNB。BNB 和 `--use-wbnb` 两条路径在主网分叉端到端里测过。
- `baw` 签名：本次全部用 `--calldata` 加 cast 签名。
- 服务端索引和 keeper：还没做。
