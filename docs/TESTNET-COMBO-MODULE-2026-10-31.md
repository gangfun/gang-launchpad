# 测试网记录 · GangComboSplitter（组合收款模块：回购 + 加池 + 分账，`combo-v1`）

- 日期：2026-10-31 Asia/Shanghai
- 网络：BSC 测试网（97），第 10 套 pad `0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`
- 代码：PR #95，分支 `feat/combo-module`（与 main `123a8cb` 合并后的树）
- 部署前：一轮内部审计（1 中 2 低，全部修复，各有在旧代码上失败的回归测试）和修复后的独立复审（发现 L-2 修复引入的一个低危：绑定前 `distribute` 会把已到账的税当作别的资产处理，已修；可以上测试网）
- 结论：部署和整轮验收通过；三路拆分、回购一块、加池一块的金额与合约规则逐 wei 一致

## 部署

| 项 | 地址 / 交易 |
|---|---|
| GangComboSplitterFactory | [`0x52a8f90a92E5C1828b4436a0B99C6b293f7F4CFE`](https://testnet.bscscan.com/address/0x52a8f90a92E5C1828b4436a0B99C6b293f7F4CFE)，部署 [`0xebb423ba…5096`](https://testnet.bscscan.com/tx/0xebb423bad8b2c975d2927e8e7d15b6ce2865a6b2a69c3bf925f95e31cf785096) |
| 实现合约 | [`0xC29bc697EeFe09b5E1A4F12310E4614aD3601951`](https://testnet.bscscan.com/address/0xC29bc697EeFe09b5E1A4F12310E4614aD3601951)，`gangQuote` = 0（测试网没有 GANG） |
| `admin.setFactory(factory, true)` | 管理合约 v2 `0xBc2d…9a4d`，[`0x0c6a9a4b…cb82`](https://testnet.bscscan.com/tx/0x0c6a9a4b76b3a1c0c37036eb1147f4852c4852980a99b891eb860453040ecb82)；测试网由 owner 钱包直接执行，主网是多签 |
| 部署脚本检查 | 接线检查、运行时字节码比对（`checkCode`）在模拟阶段通过 |

## 验收（`script/ComboTestnetAcceptance.s.sol` + 照 keeper 方式发的 `split` / `work`）

dev = 部署钱包；回购 30%、加池 30%，其余 40% 分给部署钱包 70%、一次性钱包 B 30%。报价币 MockSPCXB `0x02B3…F1c`（QuoteRegistry 里有，`keeperServes` = true）。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 克隆模块 | [`0x4c11467D51e865431AbfB17e9659c84db33d87A7`](https://testnet.bscscan.com/address/0x4c11467D51e865431AbfB17e9659c84db33d87A7)，地址等于 `predict`，比例和收款人写入正确 | [`0xdf0f0d7d…4d3f`](https://testnet.bscscan.com/tx/0xdf0f0d7d5fbbb536ed3a69e3702a0cda718a5040ef84b66e4065eaada0284d3f) |
| 建币 CMBT（买卖税 3%，分红 40%，收款 = 模块） | [`0x2D729Fa911DDAED70591b3B9aA7d842f86D85986`](https://testnet.bscscan.com/address/0x2D729Fa911DDAED70591b3B9aA7d842f86D85986) | [`0x5c4d4622…6d96`](https://testnet.bscscan.com/tx/0x5c4d46228a285267856816dd5443f0cab93534ed313accc61ed21fe4a53f6d96) |
| `bind` | `token` / `quote` 写入 | [`0x9fceabd9…a4`](https://testnet.bscscan.com/tx/0x9fceabd9ba4d171de2f3853ede5895708099c99903a8d78cb887228ea56b2fa4) |
| 毕业、池子交易交税 | 一次性 Agent 各买 1% 直到毕业；交易对 [`0x1A8E…b9e9`](https://testnet.bscscan.com/address/0x1A8E662f25BA2841d43E69cCD2Ed8e122653b9e9)；卖出时的 swap-back 付给模块 0.072129968705886310 | 多次续跑共 499 笔全部成功（见下） |
| `split()`（`cast send`，gas 由节点估算） | 回购 0.021638990611765893、加池 0.021638990611765893（各 30%），B 0.008655596244706357、部署钱包 0.020196391237648167（剩下 40% 的 30% / 70%），逐 wei 一致。估算 505,029，实际 163,849 | [`0x6e333812…c69f`](https://testnet.bscscan.com/tx/0x6e3338124b33a0a1f153a8caf012643552a511c0d38e5d83f3a133178395c69f) |
| keeper 第一次 `work`：`previewWork` 的动作字节 = 3（记观察点） | 观察点写入，不交易 | [`0x487df460…b052`](https://testnet.bscscan.com/tx/0x487df4600c67f6b9044302837830fc43105b72d0b3101db19c795dd2b83bb052) |
| 10 分钟后 keeper `work`：动作字节 = 1（两部分一样多，回购优先） | `BoughtBack(0.021638990611765893, 287,757.67…, 0)`：回购余额全部花掉（低于每块上限）；0xdead 的代币增加量 = 烧掉的数量；模块不留代币。估算 394,027，实际 329,771 | [`0x3c07b8bd…bec3`](https://testnet.bscscan.com/tx/0x3c07b8bd1dfc3f7b242efb5bea5a5ef8669d033544eb65fd741da587b1b8bec3) |
| 4 分钟后 keeper `work`：动作字节 = 2（现在加池那部分更大） | `LiquidityAdded(quoteIn 0.020977945724816719, tokensIn 139,256.67…, liquidity 37,601,813,969,907,572,742, left 0.000661044886949174)`：加池余额 0.021638… → 0.000661…，差额 = `quoteIn`；0xdead 的 LP 增加量 = `liquidity`；模块不持有代币、不持有 LP。估算 683,879，实际 583,994 | [`0xd5157aa9…ea52`](https://testnet.bscscan.com/tx/0xd5157aa9bf6f916a4bac8e256075ecfb40711bc0a141c5ee9fa1b0c8a186ea52) |
| 收回一次性钱包剩下的 gas | 0.0033 tBNB 回到部署钱包 | `--sig "sweep()"` |

CLI（PR #96）在同一个测试网工厂上另建了一个组合模块 `0x8Da5…B932` 走完 CLI 流程：克隆、建币、绑定、分发一个杂散代币（60% 进 0xdead、40% 给收款人）、分发绑定的 WBNB、收款人换地址。

## 两类中断

- **nonce 冲突**：第一轮广播到第 240 笔时，CLI agent 正用同一个部署钱包在测试网发交易，forge 报「EOA nonce changed unexpectedly」。暂停另一边后用 `COMBO_MODULE`、`TOKEN` 续跑，跳过已完成的步骤。
- **`split()` 回滚 `PushStarved`（5 次，钱没动）**：forge 脚本按「模拟用量 × 系数」给 gas limit（这几笔只给到 113,501 gas 就停），而每次推送前合约要求剩余 gas ≥ 约 36.5 万（`PUSH_GAS × 64/63 + PUSH_RESERVE`，同 Split 模块）。改用 `cast send`（节点估算 505,029）一次成功。调用方必须用节点估算 gas，和 Split、自动加池模块相同。

## 本次没测到（单测覆盖：`test/gang/GangComboSplitter.t.sol` 25 个，`GangComboSplitterPairTax.t.sol` 2 个，主网 fork 2 个）

- 收款人被拉黑记欠款、`release` 分次补发、余额被扣按比例缩减。
- 一点灰尘调 `chunk` 抢占间隔（审计 M-1）、过时的 keeper 计划（L-1）、诱饵绑定（L-2）、绑定前不拆分。
- 拉盘后暂停、转进交易对收税的报价币。
- 主网的多签 owner 和 `gangQuote` 检查（只在 chainid 56 生效）。

## GangLaunchpad 2.0（测试网第二轮）

2.0 是新一代 pad，有自己的 handler 和 GangHandlerAdmin；组合工厂只认一个 pad，所以每代各部署一个。合约代码与上面相同（同一个提交），只换 `GANG_PAD` / `HANDLER_ADMIN`。

| 项 | 地址 / 交易 |
|---|---|
| pad（2.0） | `0xb14d415f70D7F99f0D93Bd3BF76e0D6b38b53B3E`，handler `0x5d77…4278`，admin `0xEbFD66D7959f345cbE8023Fa09bDe6f6C8D2eF38` |
| GangComboSplitterFactory | [`0x312c86F7139b3e3a75ee66b4D5Bfdbe5077584BD`](https://testnet.bscscan.com/address/0x312c86F7139b3e3a75ee66b4D5Bfdbe5077584BD)，部署 [`0x27f33fed…120d`](https://testnet.bscscan.com/tx/0x27f33fed3a7a437b2ed838edea357be83fb7fdca56c2585c36ed4b3e40b5120d) |
| 实现合约 | [`0x43e36F4D953C74B40a7E382693dc77d96467C914`](https://testnet.bscscan.com/address/0x43e36F4D953C74B40a7E382693dc77d96467C914) |
| `admin.setFactory(factory, true)` | [`0x36f8fef1…1e86`](https://testnet.bscscan.com/tx/0x36f8fef132fe67f6e6c109001016a7160cbdeb11e26a10a6c3dbce694b0d1e86)（部署钱包是 2.0 admin 的 owner，脚本直接执行） |

同一个验收脚本（`COMBO_FACTORY` 指向 2.0 的工厂；比例、收款人同上）：

| 步骤 | 结果 | 交易 |
|---|---|---|
| 克隆模块 | [`0x4Ea62AfA019a3Df382B96D23628F2236A9EE26Fa`](https://testnet.bscscan.com/address/0x4Ea62AfA019a3Df382B96D23628F2236A9EE26Fa) | [`0xa024bbbd…d320`](https://testnet.bscscan.com/tx/0xa024bbbd9b8f7beab14dfc515f8fccdba570afabcad25e0ee86e96967298d320) |
| 在 2.0 上建币（买卖税 3%，分红 40%，毕业目标默认 9 BNB） | [`0xb664b14463887302127AaCc44ea4DA80Af8E35ee`](https://testnet.bscscan.com/address/0xb664b14463887302127AaCc44ea4DA80Af8E35ee)，交易对 `0xBfF7…6B15` | [`0x257e1e75…23fc`](https://testnet.bscscan.com/tx/0x257e1e75c458fb1dccf1a17082aaf415dad6c25ab981020fb415924829f123fc) |
| `bind` | 通过（2.0 的 `kindOf` / `curves` / `routeOf` 与 1.0 相同） | [`0xa7a969e2…0b5d`](https://testnet.bscscan.com/tx/0xa7a969e29b380cdd4a597c39560381c2b947a712fe383b585ec945dde8d70b5d) |
| 毕业、池子买卖交税 | 一次运行 326 笔，325 笔成功上链，剩下 1 笔是下面的 `split()` | |
| `split()` | forge 给的 gas limit 只有 113,501，回滚 `PushStarved`（同第一轮，钱没动）；改用 keeper 方式 `work(previewWork().minOut)`（动作字节 4，节点估算 503,568）：回购、加池各 0.002360408044981967，B 0.000944163217992787、部署钱包 0.002203047508649837，逐 wei 一致 | [`0xcaa88743…71f5`](https://testnet.bscscan.com/tx/0xcaa88743e352887be7b4ba27afda38550f6bb2fea6f7ecc02fdbc47afbd171f5) |
| 等税攒够 | 2.0 这轮税少，回购 / 加池余额都低于储备的 0.05%（`WORK_MIN_BPS`，约 0.0045），`previewWork` 按设计不 due；部署钱包直接转给模块 0.02 测试报价币 | [`0xe8fa7a56…5009`](https://testnet.bscscan.com/tx/0xe8fa7a560bb53c05192ca81cf515dbfa4637d53339119175f27595691cfd5009) |
| keeper `work`：动作字节 3 | 先拆分（回购、加池各 +0.006，即 0.02 的 30%），再记观察点 | [`0x29141a1c…8a71`](https://testnet.bscscan.com/tx/0x29141a1ca6f4581b50e605c2ff7103bb7d47b61bf911ce98e25fcbd081688a71) |
| 10 分钟后：动作字节 1 | `BoughtBack(0.008360408044981967, 178,844.63…, 0)`：回购余额花完；同数量的代币转进 0xdead | [`0x06ce234f…faae3`](https://testnet.bscscan.com/tx/0x06ce234fa263d3cd0a75d3ef3cc46445c466dfa894bd74fd4d08a535339faae3) |
| 4 分钟后：动作字节 2 | `LiquidityAdded(quoteIn 0.008104463673810194, tokensIn 86,619.31…, liquidity 18,435,368,871,107,957,657, left 0.000255944371171773)`：加池余额减少 = `quoteIn`；铸给 0xdead 的 LP = `liquidity`；存币时 handler 的 swap-back 在块中付给模块 0.000504495801998308，留到下次拆分 | [`0x31655617…cf73`](https://testnet.bscscan.com/tx/0x316556170afa8e89b78291e7f4fa62e03606045d8646ec25dabf88a168c6cf73) |
| 收尾 | 模块不持有代币、不持有 LP；一次性钱包剩下的 0.0063 tBNB 收回 | `--sig "sweep()"` |

2.0 的内盘创作者分成（`creatorFeeOf` = 0.0636）记在 pad 里给 dev 自己领，不经过组合模块，两者互不影响。CLI（PR #98，2.0 那一版）按 pad 版本选组合工厂：在 2.0 上建币时用 2.0 的工厂，模块和币在同一个 pad 上。

## 复跑

```sh
# 部署工厂（测试网由 owner 钱包直接 setFactory）
GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 HANDLER_ADMIN=0xBc2d7A1f2E86A7586f31A324aDaE3d38bFd49a4d \
  DEPLOYER_PRIVATE_KEY=… forge script script/DeployGangComboSplitterFactory.s.sol \
  --rpc-url https://bsc-testnet-rpc.publicnode.com --broadcast --slow --legacy --with-gas-price 100000000

# 验收第一轮（续跑：COMBO_MODULE、TOKEN）；拆分那一步若因 gas limit 回滚，用 cast send 发 split()
COMBO_FACTORY=0x52a8f90a92E5C1828b4436a0B99C6b293f7F4CFE DEPLOYER_PRIVATE_KEY=… \
  forge script script/ComboTestnetAcceptance.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com \
  --broadcast --slow --legacy --with-gas-price 100000000

# 照 keeper：previewWork 的 minOut 原样传给 work（最高字节是计划的动作）
M=0x4c11467D51e865431AbfB17e9659c84db33d87A7
MIN=$(cast call $M "previewWork()(bool,uint256)" --rpc-url … | sed -n 2p | awk '{print $1}')
cast send $M "work(uint256)" $MIN --private-key … --rpc-url … --legacy --gas-price 100000000
```
