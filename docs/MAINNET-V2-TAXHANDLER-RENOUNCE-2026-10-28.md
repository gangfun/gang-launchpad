# 主网操作记录：V2 税处理合约弃权（2026-10-28）

BSC 主网（chainId 56）。多签放弃了 LaunchpadV2 的 PostGradTaxHandler `0xa2bd8e511Cf01aA8F9693a841FD6ee6E30253e29` 的全部权限：先清 keeper，再放弃 owner。从此没有人能调 `process`，V2 有税币收上来的税币永久锁在合约里，不会卖进池子。

| 项 | 值 |
|---|---|
| 交易 | [`0x2c7364ab3ee54463e4004e2ce83a24c9d4f58cb932a88c4f2695e572b91bd120`](https://bscscan.com/tx/0x2c7364ab3ee54463e4004e2ce83a24c9d4f58cb932a88c4f2695e572b91bd120) |
| 区块 / 时间 | 130222557 / 2026-10-28 13:07:46（UTC+8） |
| 执行方 | Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`（2/3，nonce 6），签名人 `0xB0E5fDE72F50E93F7a20dc5790Ff3EEF6240cA28` 提交 |
| 批量内容 | 1. `setKeeper(0x0)`（`0x748747e6` + 32 字节 0）<br>2. `renounceOwnership()`（`0x715018a6`） |
| 事件 | `KeeperSet(0x0)` → `OwnershipTransferred(Safe → 0x0)` → Safe `ExecutionSuccess` |

## 1. 为什么做

V2 有税币毕业后，池子里每笔买卖收 1% 的**币**，暂存在 PostGradTaxHandler（`notifyTax` 只记账），要等 keeper 调 `process` 卖成报价币，再 50% 进 DividendVault、50% 进 PlatformFeeBucket。主网上 `process` 一次都没跑过：已毕业的 6 个币的 `accruedTax` 都等于合约余额，持币人一直没有分红。积压的币占各自总量的 3%–9%，用户担心平台一跑 `process` 就是砸盘。

合约里没有 burn 或提币函数，代币的 `burn()` 只有 LaunchpadV2 能调。可选的做法是：

- 正常 `process`：会把积压的币一次性卖进池子，正是用户担心的事。
- 临时 `setRouter` 换成「销毁路由」，让 `process` 把币转进 `0xdead`：需要写新合约、fork 测试；之后新收的税仍要有人定期处理。
- 清 keeper 并弃权：不用新合约，`process` 永远调不了，税币永久冻结。**采用这个。**

只清 owner 不够：keeper 还能 `process`，而且之后没人能撤掉它。只清 keeper 也不够：owner 能自己 `process`、换 keeper，或者 `setRouter` 换成任意合约拿走授权的币。两步必须按「先清 keeper、再弃权」的顺序放在同一笔批量里，反过来弃权后就调不了 `setKeeper`。

## 2. 影响范围

owner / keeper 是按合约设的，V2 所有有税币共用这一个税处理合约（LaunchpadV2 `taxHandler()` = `0xa2bd…3e29`），所以影响全部 V2 有税币，不能只针对某几个币：

- 2026-10-28 扫描 LaunchpadV2 的 674 个币（区块约 130213300）：476 个有税，其中 6 个已毕业（见第 4 节），其余还在内盘、不收外盘税。
- 已毕业的币：现有积压和以后每笔交易的 1% 税永久冻结，**不再有外盘分红**。
- 没毕业的有税币：将来毕业后同样收税、同样冻结、永不分红。LaunchpadV2 没有暂停开关；CLI 已拒绝 `--taxed`，网站的 V2 有税币创建入口需确认已关闭。
- 平台在 V2 有税币上的 50% 外盘税收入也没有了。
- 正常买卖不受影响：`notifyTax`、`syncShares` 没有权限检查，照常运行。
- 没有动的合约：LaunchpadV2、DividendVault `0x5e2Dd1D439b251d64B4147D8947445f83f3A2D62`、PlatformFeeBucket `0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111` 的 owner 仍是 Safe。后两个里面只有报价币，和砸盘无关；保留权限便于以后排查。

## 3. 验证

**执行前（fork 主网模拟）**：anvil fork，冒充 Safe 发出同样两笔调用。之后 `owner()`、`keeper()`、`pendingOwner()` 都是零地址；原 keeper、Safe、任意地址调 `process` 都回滚 `OnlyKeeperOrOwner`；Safe 调 `setKeeper` / `setRouter` 回滚 `OwnableUnauthorizedAccount`；从池子转出 1000 枚大肥鱼（模拟买入）正常完成，到账 990 枚，10 枚税进 `accruedTax`。

**执行后（主网，区块 130222663）**：

- `owner()`、`keeper()`、`pendingOwner()` 都是 `0x0000000000000000000000000000000000000000`。
- 用 `eth_call` 以 Safe 和原 keeper `0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7` 调 `process`，都回滚 `OnlyKeeperOrOwner`。
- 6 个币对 Pancake 路由 `0x10ED43C718714eb63d5aA57B78B54704E256024E` 的授权额度都是 0（`router()` 仍指向它，但只有 `process` 会授权）。

任何人可以在 BscScan 的 Read Contract 里核对 `owner` 和 `keeper`，或者：

```bash
cast call 0xa2bd8e511Cf01aA8F9693a841FD6ee6E30253e29 "owner()(address)"  --rpc-url $BSC_RPC_URL
cast call 0xa2bd8e511Cf01aA8F9693a841FD6ee6E30253e29 "keeper()(address)" --rpc-url $BSC_RPC_URL
```

## 4. 冻结的税币（区块 130222663）

| 币 | 地址 | 报价币 | 冻结量 | 占总量 |
|---|---|---|---|---|
| TURF | `0x4b1f0B4aC6D634f223cEA6379CE855f372fFAC65` | GANG | 93,680,397 | 9.4% |
| 大肥鱼 | `0xD421E4368Ac7d3878D589bb60ec22Dd54002feE8` | FXIon | 90,116,438 | 9.0% |
| 蚂蚁 | `0x5e9305a3d099b44bB7C50E2EEdb6EcF5bd322435` | oANTHROPIC | 76,157,741 | 7.6% |
| AGI | `0x400067859346b77Ee6A838e8ce6B8e712F96177A` | GANG | 57,756,872 | 5.8% |
| bibi | `0x1E358076f379C091c0479fa0A4CD574D7a58C5dc` | BNCB | 50,393,941 | 5.0% |
| 帮派 | `0x9B11fd27e9Ec60aA2514EFe5afea1210C3d7bA00` | GANG | 34,874,905 | 3.5% |

合计约 4.03 亿枚。这些币还在交易，以后的税会继续进这个合约，数字只增不减。币留在合约里，区块浏览器会把它列为前几大持有人；对外说明时以 `owner` / `keeper` 为零地址为准。
