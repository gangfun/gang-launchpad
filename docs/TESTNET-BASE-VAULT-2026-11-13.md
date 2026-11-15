# 测试网记录 · 底仓金库（`base-v1`）

- 日期：2026-11-13 Asia/Shanghai
- 网络：BSC 测试网（97），GangLaunchpad 3.0 代理 `0x0508232833aE6849c03b28F7aA248BBd5cFCceE2`，abcd 已启用
- 规格：`docs/SPEC-BASE-VAULT-V2-2026-11-12.md`
- 部署前：实现做过一轮独立评审（无中危及以上），评审提出的两个低危（升级脚本、测试缺口）补上后又复审一轮（无中危及以上）。没有外部审计
- 结论：升级、设置金库实现合约、经 `createWithSalt` 创建带底仓的币，链上读回全部符合规则。毕业和释放没有在测试网做（见「没做」），由主网 fork 测试覆盖

## 部署

| 项 | 地址 / 交易 |
|---|---|
| GangBaseVault 实现合约 | [`0x388275db72F8AbAC993e641Ec1826816966b5eDf`](https://testnet.bscscan.com/address/0x388275db72F8AbAC993e641Ec1826816966b5eDf)，`pad()` = 3.0 代理，区块 142344638，[`0x42f3a291…2e11`](https://testnet.bscscan.com/tx/0x42f3a291d649b8f39072a9b9f2281f9c2b5cb70e56416fb1587930a0e3ee2e11) |
| CurveLogic3 | [`0x5AA475Fd446f3418A4F8f444dC7f0Bfd43EEd70E`](https://testnet.bscscan.com/address/0x5AA475Fd446f3418A4F8f444dC7f0Bfd43EEd70E) |
| Pad3Module | [`0x1d86963823741995D68357B85E155ba1E895F8A5`](https://testnet.bscscan.com/address/0x1d86963823741995D68357B85E155ba1E895F8A5) |
| Pad3FlyModule（代码不变，构建脚本连带部署） | [`0x28d0f022d80a1f901b37ab82c0a03727a103d460`](https://testnet.bscscan.com/address/0x28d0f022d80a1f901b37ab82c0a03727a103d460) |
| GangLaunchpad3 新实现 | [`0x3A86A580511BB075066857E9f9a185CF13AaB6BF`](https://testnet.bscscan.com/address/0x3A86A580511BB075066857E9f9a185CF13AaB6BF) |
| `upgradeAndCall` | 区块 142345511，[`0x969e9d4b…825b`](https://testnet.bscscan.com/tx/0x969e9d4b6d90bc33405cffb7edc227806a10da91670e97b223a15f1bb703825b) |
| `setBaseVaultImpl` | 区块 142345515，[`0x2f09b25c…51cf`](https://testnet.bscscan.com/tx/0x2f09b25c3d361c90a668791843c03764d45ac389268e3f0e9977ab6f8d9d51cf) |

- 升级用 `script/UpgradeGangLaunchpad3.s.sol`，环境变量和 `docs/TESTNET-GANG-LAUNCHPAD-3-2026-11-03.md` 的升级演练相同，另加 `PAD3_BASE_VAULT_IMPL`；只链接测试网的 PoolCheck `0x76Ba…C00c`，其余库由 forge 用 CREATE2 部署。
- 广播前的模拟：比对了最新 25 个币的记录和设置；金库实现合约和本次构建逐字节一致；`setBaseVaultImpl` 在设置比对之后执行。
- 10 笔交易全部成功（5 个库、2 个模块、实现合约、升级、`setBaseVaultImpl`）。读回 `baseVaultImpl()` = 上面的实现合约，`module()` = 新的 Pad3Module。
- 记录：`broadcast/DeployGangBaseVault.s.sol/97/`、`broadcast/UpgradeGangLaunchpad3.s.sol/97/`。

## 验收（`script/BaseTestnetAcceptance.s.sol`）

dev = 部署钱包（Agent）。毕业档 6 BNB，底仓 5%，释放期 30 天，不带税。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 经 `createWithSalt` 调 `createWithBase`，付 0.099354197714853454 tBNB（= `previewBaseCost(6 BNB, 500)`） | 代币 [`0x275Cb24972Ce867C42787fB8B478CA7D32a7Abcd`](https://testnet.bscscan.com/address/0x275Cb24972Ce867C42787fB8B478CA7D32a7Abcd)，和事先算出的地址一致，以 abcd 结尾；gas 1,735,217 | [`0xcbdac732…9b25`](https://testnet.bscscan.com/tx/0xcbdac732995a471384ba65d7a7883a66b837ad53428175698f2945f9c2859b25) |
| 读回 | 金库 [`0xe024F832567cFDEf820F0B1b661374C4B49EC5A0`](https://testnet.bscscan.com/address/0xe024F832567cFDEf820F0B1b661374C4B49EC5A0)；`baseOf` = 金库余额 = 5,000 万枚；金库的 `creator` = dev、`duration` = 30 天、`startAt` = 0；曲线 `sold` = 底仓、`realQuote` = 花费 − 1% 手续费；创建人手续费 = 手续费的 70%；pad 的 WBNB 增量 = `realQuote` + 创建人手续费；pad 的原生 BNB 余额不变；代币仍锁定 | 无 |
| 毕业前调 `release`（只在模拟里调，不广播） | 回滚 `NotGraduated` | 无 |
| dev 自己的钱包在曲线上买 0.002 再全部卖出 | 成功；dev 代币余额回到 0；金库余额仍等于 `baseOf` | [`buy`](https://testnet.bscscan.com/tx/0xc19b40b0a1ed1daf1c758bf015e761ddafe29c67bd927ce8ef0d3cc53a566277)、[`sell`](https://testnet.bscscan.com/tx/0xc07d6872dd3120938670af7009ec037395c4f12748c4588cfd921459ffa290b3) |

记录：`broadcast/BaseTestnetAcceptance.s.sol/97/`。

## 主网 fork（`test/fork/Pad3BaseUpgradeFork.t.sol`）

在主网区块 133203090 上 fork（公共归档节点；不固定区块时，普通节点在测试跑到一分钟左右后丢了状态）：

1. 部署金库实现合约，用 `PAD3_BASE_VAULT_IMPL` 运行升级脚本，比对通过；
2. 按 Safe 批次的顺序发出：升级 → `setBaseVaultImpl`。代理只写了实现地址槽和底仓命名空间；
3. 升级前用 `createWithSalt` 建的老币，升级后照常买入；
4. 直接调用 `createWithBase` 回滚 `VanityContextRequired`（主网已开 abcd）；
5. 经 `createWithSalt` 建两个底仓币：不带税 5% / 30 天，带税 3% / 3%、收款人是创建人、10% / 90 天。两个都买到毕业，真实 Pancake V2 交易对拿到 2 亿枚和 6 WBNB；释放在三分之一时点转出三分之一，到期全部转给创建人，没有扣税。

Agent 身份只在 fork 里模拟，没有往主网广播任何交易。结果：1 / 1 通过。

## 没做

- **测试网毕业和释放**：底仓只支持 WBNB，买到毕业最少要 6 tBNB，部署钱包只有 0.24 tBNB。这部分由主网 fork 覆盖。要在测试网补做，需要先给部署钱包补约 6.5 tBNB。
- CLI、服务端、网页都还没有对接，本次只验收合约。

## 花费

部署钱包 tBNB 从 0.2447 降到 0.1906，其中 0.0994 是底仓花费（留在曲线里），其余是 gas。
