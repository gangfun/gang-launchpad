# 测试网记录 · GangSwap

- 日期：2026-11-23（Asia/Shanghai）
- 网络：BSC 测试网（97）
- 规格：`docs/SPEC-GANGSWAP-2026-11-22.md`
- 部署的代码：PR #197 的 `2a373d6`。部署前这个提交通过了独立复审（没有低危及以上的合约问题）。没有外部审计。
- 结论：pad 3.0 已升级，GangSwap 已部署并开放。曲线买卖在正式测试网 pad 上通过；毕业、回购、兑换、手续费在一套隔离部署上通过（原因见下）。

## 正式测试网

pad 3.0 代理 `0x0508232833aE6849c03b28F7aA248BBd5cFCceE2`，GangPadRegistry 代理 `0xB11B83C83DEd269B040faecC1D61B4885BA8e56e`。

1. `script/UpgradeGangLaunchpad3.s.sol`（`PAD3_REGISTRY_UPGRADE=true`）先模拟（比对 25 个币）再广播，12 笔全部成功。链上读回：pad 实现 `0x0906397DBa124795312D63A7B54B17680DD8EcAf`，registry 实现 `0x1964eEb7c5e3Bc30bFa35155bC8214192C0C3d18`，`gangSwapMigrator()` = 0。脚本提示没有设 `PAD3_PROMOTE_PROBES`，推广绑定和收益没有比对。
2. `gangswap/script/DeployGangSwap.s.sol`，5 笔全部成功；广播后再对链上跑 `check`，通过。

| 合约 | 地址 |
|---|---|
| GangSwapMigrator | `0x1B942d7eA4B9C2229e6776150d989ab1E6aDD36A` |
| GangSwapBoost | `0xBcE63184f8BA913eD1dE6002fEdDe587305F00Ea` |
| GangSwapFees | `0xDbA8FEBB6aC9Da3eEb9A8805E4053C42763B7236` |
| GangSwapFactory | `0x90aF66E555E8C90fFFd0780cF4ca56A8313CEA36` |
| GangSwapRouter | `0x1EAdAEe9b7C04Db9b828CcC342c3Ef2355722d94` |

3. 开放前 `createGangSwap` 返回 `GangSwapNotOpen`（eth_call）。依次执行 `addLaunchpad`（`0x6cd68d28…b254`）、`bucket.setOperator(fees, true)`（`0x20c1c0eb…36aa`）、`setGangSwapMigrator`（`0x41cb03d2…4a4e`），读回一致。
4. `PHASE=4`：`createWithSalt` 建币 `0xB8800BeB0D7aC090F333e1018700fE9674a4aBcD`（kind 4），`buyTokenAMAP` 用 0.005 tBNB 买入，再卖出一半，全部成功。
5. CLI（未发布分支，只读和 `--calldata` 预览，没有用真实 Agentic Wallet）：info、status、buy、sell（授权步骤）、creator-fee、create 都正常；create 带上了当前版本地址。把 `GANG_TESTNET_SWAP_ROUTER` 指到上面的 router 时没有警告，不设时提示“这个版本毕业后无法交易”。链上 router 的遮罩代码哈希等于 CLI 固定的 `0x07886a19…005d`。

## 隔离部署（毕业验收）

测试网钱包的 tBNB 不够真实毕业（6 BNB 档）。`script/GangSwapTestnetAcceptance.s.sol` 另外部署了一整套：pad 3.0、GangSwap 的代码不变，WBNB 换成可增发的 mock，Agent ID 换成 mock。它不在正式 pad、registry 和 CLI 配置里，用完即弃。pad `0x8CDeE4BEE24acbD395349778aF83698325663B51`，mock WBNB `0x4054E65E4c73cA0Abc30239C012D31DA34361F74`。

| | 版本 A | 版本 B |
|---|---|---|
| migrator | `0x6C6cea50cF3688Bf5514dF9ad36CfD5260cCB2CC` | `0x2C0e994A1F0045bb81ED6E42D8f146Adf353B13A` |
| router | `0x5208FB39e8b219e08381E76a6a13Ad9c35668902` | `0x474F382f2D4Bf6B328d2540Ef1771AD76f83BaC8` |
| 代币 | `0xA52AF3F9f6c351D82d35FEB270b9FbA018bd6f48` | `0x09455103A6411582373371DDb48c6797177158A1` |
| 毕业后的 pair | `0x43b45367beDf402C6c3DA2eDa011427C041bAEfb` | `0xb238f10c852F9A1017E2a628aAA2203E2C537289` |

- **版本**：A 当前时建币 A，再切到 B。点名 A 的创建被拒：`GangSwapVersionChanged(B)`（eth_call）。B 是当前版本时，A 的币仍然毕业到 A 自己的 pair。
- **毕业**（1 分钟 Agent 窗口开放后，由合约交易者买入、卖出、再买到毕业）：两个币都是 status 4、费率 100、剩余 0；pair 有效储备 = 6，虚拟储备 1.2，真实 4.8；LP 全部在 0xdead 或零地址；boost 拿到 1.2。
- **回购**：按真实时间执行，两个币各 40 步，共 80 笔全部成功（区块 144423201–144424244）；首步约 18.9 万 gas，之后约 12 万；结束后 boost 余额为 0。每个币销毁 41,257,278 枚。
- **兑换**：GangSwapRouter 的 BNB 买入（fee-on-transfer 路径）和 mock WBNB 买入都等于报价；手续费 70% 给创建者、30% 进 bucket，领取数额一致。
- **全部卖回后**：两个池各剩真实储备 0.0516（与主网 fork 测试的 0.0515 接近），代币全部在池子里或已销毁。

阶段 1 的最后两笔（建币 B、部署交易者）因为脚本在模拟里用掉了一个 nonce 而没能由 forge 发出，改用 cast 手工发送；脚本已修（模拟后回滚），修后没有重新广播阶段 1。阶段 1 的广播记录因此是 48 笔收据，里面的 TRADER 地址没有使用，实际的是 `0x37a6d29f2a94b8e93d6556141b067072d720c1bb`。

## 没有验证的

- 真实 WBNB 上的毕业（主网 fork 测试覆盖）、其他档位、真实 Agentic Wallet。
- boost 间隔未到时的拒绝（`TooEarly`）没有在链上单独触发（单元测试覆盖）。
- CLI 在毕业后的交易和领取（隔离部署不在 CLI 配置里；主网 fork 上测过）。
- keeper 的回购循环、server、web。
