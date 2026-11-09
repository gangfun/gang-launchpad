# 测试网记录 · GangCallBond（喊单保证金）

- 日期：2026-11-09 Asia/Shanghai
- 网络：BSC 测试网（97），GangLaunchpad 3.0 代理 `0x0508232833aE6849c03b28F7aA248BBd5cFCceE2`
- 规格：`docs/SPEC-AGENT-CALLS-2026-11-09.md` §5
- 部署前：一轮合约审计（没有 Critical / High / Medium，L-1、L-2 已修）、修复后独立复审（没有新问题）、本窗口代码检查（3 处建议已改）。本地 `GangCallBondTest` 36 个全部通过。

## 部署

| 项 | 地址 / 交易 |
|---|---|
| GangCallBond | [`0xBE2B8519278E9D31B6c4040bAd35f727fD5d2A70`](https://testnet.bscscan.com/address/0xBE2B8519278E9D31B6c4040bAd35f727fD5d2A70)，区块 141708762 |
| 构造参数 | pad = 3.0 代理，wbnb = `0xae13…a7cd`，报价币 = 测试报价币 `0x02B3…F1c`（另两个位置为 0），owner = 部署钱包 `0xCa8e…00b6`，结算方 = 由部署钥匙派生的一次性钱包 `0x9Df2b3bF0790aCf5e9024E58C198B4Bf659E07A6` |
| 部署脚本检查 | pad 的 `TOKEN_VERSION` = 1、`wbnb` 一致；部署后 `pad`、`wbnb`、报价币、owner、结算方读回一致；带 `GANG_CALL_BOND` 只读重跑通过 |

记录：`broadcast/DeployGangCallBond.s.sol/97/run-latest.json`。

## 验收（`script/CallBondTestnetAcceptance.s.sol`，分五次运行）

钱包：部署钱包（举报人、owner），喊单者 C `0xd902e5f6eE639b29e2D0c5377F68A59d6729299d`，跟单者 F1 `0x8a2c…3468`、F2 `0x0b57…f684`，结算方。除部署钱包外都由部署钥匙派生，并在测试网 Agent ID 上自助注册。

### 1. `setup()`：建币、喊单者买入

| 步骤 | 结果 |
|---|---|
| 建三个 3.0 内盘币 | T1 [`0xBfF08B3a1Bc29d84e8487684d77a7D19F019F5d5`](https://testnet.bscscan.com/address/0xBfF08B3a1Bc29d84e8487684d77a7D19F019F5d5)、T2 [`0x9140D4b7a3d86957030FD5a0ff2E860bCf70bf04`](https://testnet.bscscan.com/address/0x9140D4b7a3d86957030FD5a0ff2E860bCf70bf04)（WBNB），T3 [`0x08bEd5b54e131D553CAc59B2fc6fCfcc5fFa7d4a`](https://testnet.bscscan.com/address/0x08bEd5b54e131D553CAc59B2fc6fCfcc5fFa7d4a)（测试报价币） |
| C 各买 0.002 | 喊单交易：T1 `0xff5b3097…bb8d`、T2 `0x624bdfa0…9d9a`、T3 `0x40e64f10…60ed` |

14 笔交易全部成功。

### 2. `bonds()`：押保证金、跟单、违约举报

| 步骤 | 结果 |
|---|---|
| C 押 A（T1）、B（T2）、D（T3） | 各 0.01，`hold` = 全部余额，48 小时；id 1、2、3；合约收到 0.02 WBNB、0.01 测试报价币 |
| F1、F2 跟单买 T1 | 0.002 和 0.004 WBNB；calldata 尾部是 `gang` 03 + T1 的喊单交易哈希（链上读回 `…67616e6703ff5b3097…bb8d`） |
| C 卖出 T1 的一半，部署钱包举报 A | 举报人 0.0001（1%），0xdead 0.005（50%），赔付池 0.0049（49%），逐 wei 一致；交易 `0xe34d2ced…a1f2`，区块 141709034 |
| C 卖出 T3 的 1 wei，自己举报 D | 0xdead 0.0051（51%），赔付池 0.0049 |

19 笔交易全部成功。读链：A、D 为 Reported，B 为 Active，合约持有 0.0149 WBNB（B 的 0.01 + A 的赔付池）和 0.0049 测试报价币。

### 3. `roots()`：发 root、否决、重发

| 步骤 | 结果 | 交易 |
|---|---|---|
| 结算方发一个把赔付池全给 C 的 root | 发布成功（合约不判断叶子是谁） | `0x7263f526…6f6e` |
| owner `veto` | root 清空，`vetoAt` 写入 | `0x814d85fa…a55d` |
| 结算方重发真实 root | F1 0.00147、F2 0.00294（赔付池的 90%，按跟单金额 1:2）；`total` = 0.00441 | `0x73348944…3c79` |

4 笔交易全部成功（含给结算方打 gas 钱）。领取从 2026-11-11 19:36 +08 起。

### 4. `claims()`：领取、销毁余额、申请结算 B

（待运行：2026-11-11 19:36 +08 之后。）

### 5. `settleB()`：B 退回

（待运行：申请结算 1 小时后。）

## 跟单绑定推广人（`buyWithPromoter` 带跟单引用）

给服务端核对「`buyWithPromoter` 的买入算跟单、并记成跟单绑定」用的一笔真实交易（规格 §4、§6）：

| 步骤 | 结果 | 交易 |
|---|---|---|
| 部署钱包 `createWithPromote`（分成 20%，30 天） | 代币 [`0x4e3379b4ead786e0c953746c7b6c3f4d4bd8d9c6`](https://testnet.bscscan.com/address/0x4e3379b4ead786e0c953746c7b6c3f4d4bd8d9c6) | `0x19af68b5…703c` |
| 喊单者 C 买入 0.0009 WBNB（喊单交易） | 成功 | `0x981ce8a0…6266` |
| 跟单者 F3 `0x4845…6575` 用 `buyWithPromoter(token, 0.001, 0, C)` 买入，calldata 尾部是 `gang` 03 + 喊单交易哈希 | `bindingOf(token, F3)` = C，已绑定 | `0x440a5b99…93f8` |

## 本次没测到（单测覆盖）

- 毕业后的结算和闪电借币检查（测试网凑不齐毕业的买单）、`vaultLock` 算违约、28 天和 60 天的发布窗口、90 天领取期满后的销毁、第三方不能替喊单者卖出：`test/gang/GangCallBond.t.sol`。
- 赔付按损失计算（规格 §5.3）属于服务端结算任务，还没写；这里的 root 按跟单金额比例手算，只验证合约的发布、否决、领取和销毁。
