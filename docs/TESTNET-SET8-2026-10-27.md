# 测试网第 8 套 · 合并后的合约（一个内盘）（已被取代）

> 本文原是第 8 套的记录模板，没有填完。第 8 套之后又部署了第 9 套，**当前是第 10 套**（含审计说明 §23 的聚合器入口）。
> 第 10 套的地址和整轮结果见 [`MAINNET-GANG-2026-10-27.md`](MAINNET-GANG-2026-10-27.md) 末尾；主网地址也在那里。
> CLI 的测试网常量沿用 `TESTNET_SET8` 这个名字，指向的是第 10 套（`skill/gang-cli/src/gangpad.js`）。

- 链：BSC 测试网（chainId 97），2026-10-27
- 合约：合并后的结构（一个内盘 `GangLaunchpad`、一个 `GangTaxHandler`、一种 `GangToken`、一个 `GangRouter`；审计说明 §20，规格 `docs/SPEC-GANG-MERGED-2026-10-27.md`），取代第 7 套（`docs/TESTNET-SET7-2026-10-27.md`）。

仓库里记下的第 8 套地址（2026-10-27 链上核对）：

| 合约 | 地址 | 出处 |
|---|---|---|
| GangLaunchpad | `0x4f7391D69cbf62891Ba8db929c323cd2609b94e7` | 运行手册 §1「给已有的内盘挂可升级路由」、`script/DeployGangRouterUpgradeable.s.sol` 注释 |
| GangRouter（不可升级的旧版，没有外盘买卖入口） | `0xaeC638b258521ba2C39ADd5dAA3038F2c95C5747` | 提交 `1456a93`（CLI 当时的 `TESTNET_SET8`）；`skill/references/v3.md` 里拿它举例「旧路由会被 CLI 拒绝」 |
| owner（部署钱包） | `0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6` | 链上 `owner()` |

其余合约地址、部署区块和第 8 套的整轮结果没有记录，这里不补。第 9 套的地址仓库里也没有记录。
