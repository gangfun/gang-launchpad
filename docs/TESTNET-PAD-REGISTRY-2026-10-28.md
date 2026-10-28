# 测试网 · GangPadRegistry（聚合器用的 pad registry）

GangPadRegistry 已部署到 BSC 测试网，登记了第 10 套内盘。部署时用的就是 PR #44（`feat/pad-registry`）里的代码，脚本跑完后用 `GANG_PAD_REGISTRY` 重跑了一遍自检，结果通过。

- 链：BSC 测试网（chainId 97），2026-10-28
- 规格：`docs/SPEC-PAD-REGISTRY-2026-10-28.md`；审计说明 §24

## 地址

| 项 | 值 |
|---|---|
| GangPadRegistry（代理，聚合器记这个地址） | [`0xB11B83C83DEd269B040faecC1D61B4885BA8e56e`](https://testnet.bscscan.com/address/0xB11B83C83DEd269B040faecC1D61B4885BA8e56e) |
| 实现合约 | [`0x3B85b3DB7565b852D06cCB021555a46471b800Cf`](https://testnet.bscscan.com/address/0x3B85b3DB7565b852D06cCB021555a46471b800Cf) |
| ProxyAdmin（代理自己创建的） | `0xb66f0A3a15bCCE3166C8904Cb215745fa7154bb9` |
| owner（`addPad`、升级） | `0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`（部署钱包，也是第 10 套的 owner；测试网没用时间锁） |
| 已登记的 pad | 第 10 套 GangLaunchpad `0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`（在 `initialize` 里登记） |
| 部署交易 | 实现合约 [`0x13b681be…3758`](https://testnet.bscscan.com/tx/0x13b681bec4fd229015b0ee2bbd1eaaa48e227e7a166415cfa27a7e68ea763758)，gas 1,078,388；代理 [`0x4e0384ed…ff8d`](https://testnet.bscscan.com/tx/0x4e0384edc5991fdbba1918bf3f867627310077e17d865044314ed7cfe609ff8d)，gas 663,434；都在区块 139392144 |
| 源码验证 | 未做（缺 BscScan API key） |

## 部署过程

1. `forge script script/DeployGangPadRegistry.s.sol --broadcast`（`GANG_PAD` = 第 10 套）发出两笔 CREATE 交易，nonce 2696、2697。forge 按 EIP-1559 估出的 gas 价格只有 1 wei（`maxFeePerGas = maxPriorityFeePerGas = 1`）。Chapel 验证者要求小费至少 0.1 gwei，所以这两笔一直卡在内存池里不被打包，原因和 `docs/TESTNET-GANG-BOND-2026-10-28.md` 末尾「gas」一节相同。
2. 停掉 forge，从它的广播记录里取出这两笔交易的原始数据：实现合约那笔与本地编译的 `GangPadRegistry` 创建码逐字节一致。用相同的 nonce 和数据，以 `cast send --legacy --gas-price 0.1gwei --create` 重新发送，替换掉卡住的两笔。CREATE 地址只由部署钱包和 nonce 决定，所以合约地址和 forge 记录的一致。
3. forge 的广播记录（`run-latest.json`）里记的是被替换掉的交易哈希，没有提交；真实的交易哈希见上表。

以后在测试网上部署，直接给 forge 加 `--legacy --with-gas-price 100000000`。

## 部署后的检查

重跑自检：用 `DEPLOYER_PRIVATE_KEY`、`GANG_PAD`，加上 `GANG_PAD_REGISTRY=0xB11B…e56e` 跑 `forge script script/DeployGangPadRegistry.s.sol`（不广播），所有检查都通过：代理代码、实现合约代码（已锁死）、ProxyAdmin（代码、owner）、registry 的 owner 和 pad 列表、`padOf(pad)` 为 0、`padOf(最后一个币)` 返回 pad。

链上直接调用的结果（区块 139392144 之后）：

| 调用 | 结果 |
|---|---|
| `owner()` / `pads()` | `0xCa8e…00b6` / `[0xFebF…5BB1]` |
| `lookup(0x48e9…eE74)`（曲线币） | `(0xFebF…5BB1, 1)` |
| `lookup(0x08DA…88C2)`（打新币） | `(0xFebF…5BB1, 2)` |
| `padOf(0xFebF…5BB1)`（pad 自己） | `0x0` |
| `previewBuy(0x48e9…, 0x0, 0.01 BNB)` | 2,107,826.5 枚，实收 0.01，手续费 0.0001，退款 0 |
| `previewBuy(0x48e9…, 0x0, 5 BNB)` | 10,000,000 枚（钱包上限），实收 0.0478，手续费 0.000478，退款 4.9522 |
| `previewSell(0x48e9…, 0x0, 1,000,000 枚)` | `(0, 0)`：这条曲线还没人买过，卖出量超过已售量 |

报价和真实 `buyFor` / `sellFor` 的逐 wei 核对见 `test/fork/PadRegistryTestnetFork.t.sol`。它在测试网 fork 上部署一个 registry，用第 10 套 pad 已部署的字节码和真实状态做核对，4 个用例全部通过。

## 给聚合器联调

- registry：`0xB11B83C83DEd269B040faecC1D61B4885BA8e56e`
- 第 10 套 pad：`0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`。聚合器的测试网路由由 pad owner 执行 `setRouter(路由, true)` 加进白名单。
- 交易钱包需要测试网 Agent ID：调用 `0x24D0A2106AC3Ebf7d770d19f4aF0a5149ebe5B2a` 的 `register()`，每个地址一个。
