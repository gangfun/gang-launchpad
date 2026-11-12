# 主网 · 底价赎回模块工厂（GangFloorModuleFactory，`floor-v1`）

- 链：BSC 主网（chainId 56），2026-11-12
- 规格：`docs/SPEC-FLOOR-MODULE-2026-11-11.md`；测试网记录：`docs/TESTNET-FLOOR-MODULE-2026-11-11.md`
- 源码：分支 `claude/tax-token-innovative-mechanics-3e3515` 的 `1f61453`（PR #152，尚未合并），其中已合入 main `d3a5cf9`（abcd 主网上线）。部署记录里的 `commit` 字段就是这个提交
- 部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`；gas price 0.05 gwei，legacy
- 状态：**工厂已部署，多签尚未放行**。放行之前没有人能用它克隆模块

只部署一个新工厂。不改 3.0 pad、税处理器、GangHandlerAdmin、分红金库和 abcd 部署器；已有的币和模块不受影响。

## 部署

部署脚本 `script/DeployGangFloorModuleFactory.s.sol`。主网上只接受 GangLaunchpad 3.0 和它的 GangHandlerAdmin，并要求 pad 已启用 abcd 部署器。记录：`broadcast/DeployGangFloorModuleFactory.s.sol/56/run-1794468961891.json`。

| 项 | 地址 / 交易 |
|---|---|
| GangFloorModuleFactory | [`0x057d2C1557a0E8298a1E00834D6064497f5DC2fC`](https://bscscan.com/address/0x057d2C1557a0E8298a1E00834D6064497f5DC2fC)，部署 [`0xe95b13df…b122`](https://bscscan.com/tx/0xe95b13df6e6197ec7032b423e8f53374f6653fe647e81c588e240a245180b122)，区块 133121257，gas 3,294,931 |
| GangFloorModule（实现合约，工厂部署） | [`0xEfCF4C7FE1B6AD4eEe89723E1F97449CeA507e21`](https://bscscan.com/address/0xEfCF4C7FE1B6AD4eEe89723E1F97449CeA507e21)，同一笔交易 |
| BscScan 源码验证 | 未做：需要 API key |

部署花费 0.00016474655 BNB。

接线（以 `FLOOR_FACTORY` 指向已部署的工厂重跑脚本，接线检查、主网专属检查和运行时字节码比对 `checkCode` 都通过）：

| 项 | 值 |
|---|---|
| pad | GangLaunchpad 3.0 `0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29`，abcd 部署器 `0x8e7691ed55E0c3268118019A68c62eA6d0a6F8DE` 已启用 |
| tax handler | `0x99E882a21847012329351B598ceB93B135691b3B`，owner = GangHandlerAdmin |
| GangHandlerAdmin | `0xC833CEC2B283759003945C0Bf8C048aB1949Af76`，owner = 多签 `0x2866369F7acEFC9760bdE7779362fae5cD68B41E` |
| gangQuote | GANG `0x0c6302401aa5325C2E36F170f52C00B1d220B405` |

链上读回：工厂 `pad()`、`admin()`、`implementation()` 如上，`vanityEnabled()` = true，`count()` = 0；实现合约 `moduleType()` = `floor-v1`，`factory()` = 工厂，`taxHandler()` 如上；`admin.isFactory(工厂)` = false（等多签）。

工厂没有 owner，不可升级。模块服务的代币地址、报价币、赎回手续费、上限和收款人都在 dev 克隆时写死，平台不能改。

部署前后的验证：

- 部署前：主网 fork 测试 `test/fork/FloorMainnetFork.t.sol` 逐个跑，全部通过。部署脚本在 chainid 56 上跑完；先算地址再克隆、`createWithSalt` 建币、绑定、毕业进真实 PancakeSwap、池子交易交税、keeper 卖税、封顶前赎回、收款人恰好拿到上限、封顶后全部进金库、底价高于池价时“池子买入再赎回”有正收益；WBNB 和 USDT 各一遍，另有工厂和绑定的拒绝用例。
- 部署后：同一个测试文件的 `test_liveFactory_safeBatchThenLaunch` 在主网 fork 上对**线上这个工厂**重跑脚本检查，再以多签身份原样执行下面这份批次 JSON（只有一笔、发给 GangHandlerAdmin、调用数据和脚本打印的一致），然后走完上面的整条流程。通过。

## 多签批次（待执行）

`docs/MAINNET-FLOOR-SET-FACTORY-SAFE-BATCH-2026-11-12.json`，一笔，不转 BNB：

| to | 调用 | calldata |
|---|---|---|
| GangHandlerAdmin `0xC833…Af76` | `setFactory(0x057d…C2fC, true)` | `0x71013c10…057d2c15…01`，与部署脚本打印的一致 |

文件 SHA-256：`c8592f9ba32a8e3b97a8778d19499a8e4de5b936952f04c9256ade72b49766f5`。

**放行前的前置条件**（规格 §7、§8）：服务端和网站先能识别 `floor-v1`——核对模块来源（`GangHandlerAdmin.moduleOf` 等于这个工厂）、只在模块是为这个币克隆的时候展示底价、展示税里进金库的比例。放行之后任何 Agent 都能建底价币。

## 配套

- CLI：主网工厂地址已写进 `skill/gang-cli`（`gangpad.js`），尚未发版。多签放行之前，主网上 `gang create … --floor` 在克隆那一步的模拟就会回滚 `NotFactory`，不上传任何东西、不生成交易。
- 服务端（keeper、索引）和网站：尚未开始。
