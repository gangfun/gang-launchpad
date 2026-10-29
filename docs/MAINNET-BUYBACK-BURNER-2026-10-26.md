# 主网：GangBuybackBurner 替换回购合约（2026-10-26）

BSC 主网（chainId 56），区块 129919401，部署脚本 `script/DeployGangBuybackBurner.s.sol`（提交 fc5e62e），记录在 `broadcast/DeployGangBuybackBurner.s.sol/56/run-latest.json`。

## 为什么换

旧回购合约遇到计价币是 GANG 时走 GANG→WBNB→GANG，同一个交易对必定回滚，GANG 计价的平台费领不出来（换之前 V2 / U 分账合约里卡着约 55 万 / 43 万 GANG）。`GangBuybackBurner` 收到 GANG 直接转到黑洞地址，其它计价币行为不变。

## 地址

| 合约 | 地址 |
|---|---|
| GangBuybackBurner（owner `0x4EEd…19d3`） | `0x38120bf40F8F19E6cc60622Bc7C5B005dfe5363B` |
| 旧 BuybackBurner（V2 / U 用，已停用） | `0x2aC14C462901F990ae7647D6AcafEaf50Cc8f8dF` |
| 旧 BuybackBurner（S 用，已停用） | `0x508F1547e2AA9d3A93532AeeD5396B918E1c4A4b` |

## 交易

| 操作 | 交易 |
|---|---|
| 部署 GangBuybackBurner | `0xf8edf68356df1223dbec9e9b238c6b710d05f46a530a5e1746c591664f317aad` |
| V2 分账 `0xBDDd…F111` setBurner | `0xf0d37799acc87fc3416bc62e2544395a7886eaf6b247db863a54c80075d8125e` |
| U 分账 `0xe314…260c` setBurner | `0xd561aa2ef6bb428cb55e846ddbbd347a668bd762151d331c9b6d288573303a9c` |
| S 分账 `0xad34…dEeC` setBurner | `0x254f2608cda9bdaf080bb1ed86e2535455020d8d5bc695fd832a5508fef2bcba` |

## 链上自检（部署后）

- `router` = Pancake V2 `0x10ED…024E`，`smartRouter` = `0x13f4…8Dd4`，`wbnb`、`gang` 为主网地址，无待接受的 owner 转移。
- 链上代码与 `src/buyback/GangBuybackBurner.sol` 本地编译结果逐字节一致。
- 三个分账合约的 `burner()` 都指向新地址。
- keeper 预演（`keeper-v2-platform.sh` 不带 `--broadcast`）：10 笔 `collectPlatform` 模拟全部通过，其中 V2 / U 的 GANG 各一笔。
