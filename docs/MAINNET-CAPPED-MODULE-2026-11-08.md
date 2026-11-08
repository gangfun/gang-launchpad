# 主网 · 税收封顶收款模块工厂（GangCappedSplitterFactory，`capped-v1`）

- 链：BSC 主网（chainId 56），2026-11-08
- 规格：`docs/SPEC-CAPPED-MODULE-2026-11-08.md`；测试网记录：`docs/TESTNET-CAPPED-MODULE-2026-11-08.md`
- 源码：gang-launchpad main `524b30e`（PR #142）。合约文件和测试网上部署的逐字节一致
- 部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`；gas price 0.05 gwei，legacy

只部署一个新工厂，由多签允许。不改 3.0 pad、税处理器、GangHandlerAdmin 和分红金库；已有的币和模块不受影响。

## 部署

部署脚本 `script/DeployGangCappedSplitterFactory.s.sol`（主网只接受 GangLaunchpad 3.0 和它的 GangHandlerAdmin）。记录：`broadcast/DeployGangCappedSplitterFactory.s.sol/56/run-1794152771460.json`。

| 项 | 地址 / 交易 |
|---|---|
| GangCappedSplitterFactory | [`0x294E901ecb66af280C1cDD26fD871601d89a2Dca`](https://bscscan.com/address/0x294E901ecb66af280C1cDD26fD871601d89a2Dca)，部署 [`0x32466c8f…2954`](https://bscscan.com/tx/0x32466c8f63412fcfeaf403d938f5b4bf9e0b9bcb3dcd2ac0a11706f94fcd2954)，区块 132418984，gas 4,235,874 |
| GangCappedSplitter（实现合约，工厂部署） | [`0x09b4e56d60fA932048d3E0e11aF55E64e9612F19`](https://bscscan.com/address/0x09b4e56d60fA932048d3E0e11aF55E64e9612F19)，同一笔交易 |
| BscScan 源码验证 | 两个都已验证 |

部署花费约 0.0002 BNB。

接线（脚本检查模式 `CAPPED_FACTORY` 已设，通过；包括运行时字节码比对 `checkCode`）：

| 项 | 值 |
|---|---|
| pad | GangLaunchpad 3.0 `0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29` |
| tax handler | `0x99E882a21847012329351B598ceB93B135691b3B`，owner = GangHandlerAdmin |
| GangHandlerAdmin | `0xC833CEC2B283759003945C0Bf8C048aB1949Af76`，owner = 多签 `0x2866369F7acEFC9760bdE7779362fae5cD68B41E` |
| gangQuote | GANG `0x0c6302401aa5325C2E36F170f52C00B1d220B405` |

工厂没有 owner，不可升级。上限、报价币、比例和收款人都在 dev 克隆模块时写死，平台不能改。

签名前：

- 用合并后的 main 模拟部署，打印的批次和下表一致。
- 主网 fork 测试 `test/fork/CappedMainnetFork.t.sol` 逐个跑，3 个全过：WBNB 和 USDT 各走完一轮（建模块、建币、绑定、毕业、真实 PancakeSwap 交易收税、keeper 分块，收款人正好拿到上限，封顶后只回购和加池），以及报价币不对时绑定失败。
- 在主网 fork 上以多签身份原样执行这份批次 JSON，再对**线上这个工厂**走一遍：克隆模块（列入税处理器）、建币、绑定、转进 3 WBNB 拆分。收款人拿到上限 1 WBNB，2 WBNB 留作回购和加池。

## 多签批次（已执行）

`docs/MAINNET-CAPPED-SET-FACTORY-SAFE-BATCH-2026-11-08.json`，一笔：

| to | 调用 | calldata |
|---|---|---|
| GangHandlerAdmin `0xC833…Af76` | `setFactory(0x294E…2Dca, true)` | `0x71013c10…294e901e…01`，与部署脚本打印的一致 |

已执行 [`0xbad7622d…3b6d`](https://bscscan.com/tx/0xbad7622d3fb4458e54483b39b3ec9b44a06c5f1681dda4e36043994b52da3b6d)，区块 132420220。执行后 `isFactory(0x294E…2Dca)` = true。

## 配套

- 服务端 v1.2.84（gangfun-server #46）：indexer 和 keeper 认识 `capped-v1`，工厂从 GangHandlerAdmin 自动发现，生产不需要新配置。
- CLI 0.35.0：主网工厂内置（`gang create … --tax-cap …`、`gang capped …`）。
- 网站（gang-web-legacy #35）：币详情页的封顶面板和警告，在 CLI 0.35.0 发布后上线。
