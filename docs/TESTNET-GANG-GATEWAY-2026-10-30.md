# 测试网 · GangGateway（聚合器用的内盘网关）

GangGateway 已部署到 BSC 测试网，由 GangPadRegistry 测试网实例 `0xB11B…e56e` 找 pad，只在第 10 套 pad 上列入。部署前已走完「审计 → 修复 → 复审 → 修复后再复审」（审计说明 §25.5、§25.7），部署后重跑自检通过，验收脚本在链上跑通。

- 链：BSC 测试网（chainId 97），2026-10-30，区块 139741687
- 代码：PR #76（`feat/gang-gateway`）；规格 `docs/SPEC-GANG-GATEWAY-2026-10-30.md`；审计说明 §25

## 地址

| 项 | 值 |
|---|---|
| **GangGateway（代理：用户授权、聚合器调用这个地址）** | [`0x5020f4197A4E855474B464cD3617C048dd65635c`](https://testnet.bscscan.com/address/0x5020f4197A4E855474B464cD3617C048dd65635c) |
| 实现合约 | `0xECA95223729FFaef3Fa4A957f2ef56294342aE63` |
| ProxyAdmin（代理自己创建，owner = 时间锁） | `0x45AcFd9471861815557e83Be8599eA3E19724173` |
| TimelockController（48 小时；提案 / 执行 / 取消 = 部署钱包，没有 admin） | `0xB95D4e091E26700bD313ba36d5aA4371A5B2442C` |
| 读的 registry | `0xB11B83C83DEd269B040faecC1D61B4885BA8e56e` |
| 已列入的 pad | 第 10 套 GangLaunchpad `0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`（`routers(网关) = true`） |
| 没有列入的 pad | registry 里另一个团队的测试 pad `0x7E30…937e`：部署时用 `GANG_PAD` 排除，没有改动 |

部署交易（`broadcast/DeployGangGateway.s.sol/97/run-latest.json`）：

| 交易 | gas |
|---|---|
| 实现合约 [`0x54e3ac22…ac7d`](https://testnet.bscscan.com/tx/0x54e3ac229df359f8650f72637b83d995df112ce89454171ac76b85175961ac7d) | 1,376,591 |
| 时间锁 [`0xd2ff34fa…3a29`](https://testnet.bscscan.com/tx/0xd2ff34fab22684b5bf568859b56d1a5197d34f5c2e89761188411c935b8e3a29) | 1,376,872 |
| 代理（构造时初始化） [`0x4b7c1ef7…919b`](https://testnet.bscscan.com/tx/0x4b7c1ef73fbe83f4a3f5debb7f86c054015e2df4e5938b7db31e76555b08919b) | 607,862 |
| 第 10 套 `setRouter(网关, true)` [`0x64057481…89dc`](https://testnet.bscscan.com/tx/0x64057481d398f327454f24ede76c98643d0d6d918449ca877a8816ce4edf89dc) | 49,225 |

源码尚未在 BscScan 验证（需要 API key）。

## 部署命令

```bash
DEPLOYER_PRIVATE_KEY=… GANG_PAD_REGISTRY=0xB11B83C83DEd269B040faecC1D61B4885BA8e56e \
GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 \
  forge script script/DeployGangGateway.s.sol --rpc-url $BSC_TESTNET_RPC_URL --broadcast --legacy --with-gas-price 100000000
```

部署前先模拟了一遍（不广播），registry 自检、网关自检都通过。部署后加上 `GANG_GATEWAY=0x5020…635c` 重跑（不广播），自检全部通过：代理代码、实现合约（本次构建的代码，已锁死）、ProxyAdmin、时间锁的角色和延迟、registry、WBNB，以及 registry 本身的检查。

## 验收

`script/GatewayTestnetAcceptance.s.sol`（`--tc GatewayTestnetAcceptance`），用部署钱包（持有 Agent ID）在第 10 套上跑。每一步都先在本地模拟、校验，通过后才广播：

| 步骤 | 交易 | gas | 结果 |
|---|---|---|---|
| 创建 WBNB 计价的无税曲线币 `0x903C…B14d` | [`0xe55d5321…2730`](https://testnet.bscscan.com/tx/0xe55d5321fc0e596c10cf3f35a91a3e8b2d4b9bdf92912aead42b86777f492730) | 1,352,445 | `getTokenInfo` = (1, BNB, 0, 100, 15 BNB) |
| 部署聚合器式 adapter `0x3737…F707`（trader = 它的 msg.sender，卖出收 1% 手续费） | [`0xc63d784c…1509`](https://testnet.bscscan.com/tx/0xc63d784c0e0dc4e81ca4f9b8d77a6ab27f2ac872a529702a9eac5e83de061509) | 231,054 | |
| 经 adapter 用 0.002 BNB 买 | [`0x4c5a06df…a9fc`](https://testnet.bscscan.com/tx/0x4c5a06df922db57225381d85a79a025b09b7228abfc104b4ea84465062b7a9fc) | 250,062 | 买到 422,232.80 枚，和 `tryBuy` 一致；`fundsUsed` = 0.002 |
| 精确授权一半 | [`0xe9e5fe7d…e224`](https://testnet.bscscan.com/tx/0xe9e5fe7d92027b8e5284c318cf61262822c379b6671c92487faf9ebd34ade224) | 46,027 | |
| 经 adapter 卖一半，1% 路由手续费给演示金库 | [`0xb1d0d252…c3f4`](https://testnet.bscscan.com/tx/0xb1d0d252e9015744d9fe5c2632aefce7c7ea7c3ba841257f274a19f80f47c3f4) | 218,707 | 卖家得 0.000970491 BNB，手续费 0.000009803 BNB，合计等于 `trySell`；授权归 0 |
| 精确授权剩下一半 | [`0x68c513c9…85ce`](https://testnet.bscscan.com/tx/0x68c513c99f302524d5238c1a8b49620982a9683a69711b62c1644a07567a85ce) | 46,027 | |
| 直接调网关卖剩下一半，不收手续费 | [`0xa1aa679a…2610`](https://testnet.bscscan.com/tx/0xa1aa679a664a5546dc0541a62a15c5d3412740965153f24c97fa636a4d472610) | 185,561 | 得 0.000979906 BNB，等于 `trySell` |

每一步之后都检查了：网关和 adapter 的 BNB、WBNB 余额为 0，网关不持有代币，钱包的代币余额正确，对网关的授权为 0。验收后用 `cast` 读链上状态：钱包代币余额 0、对网关的授权 0、网关 BNB / WBNB 都是 0；曲线卖回到 0，`graduationLeft` 回到 15 BNB。

### 拒绝路径（链上 `eth_call`）

| 调用 | 结果 |
|---|---|
| 别人发起的交易里卖部署钱包的币（`from` ≠ origin） | `TraderNotOrigin` |
| 别人发起的交易里替部署钱包买（`to` ≠ origin） | `TraderNotOrigin` |
| 没有 Agent ID 的钱包买 | `NotAgent`；`tryBuy` 对它返回 0 |
| `feeRate = 501` | `FeeRateTooHigh` |
| BNB 计价但 `msg.value ≠ funds` | `BadMsgValue` |
| 对没有列入网关的 pad（`0x7E30…`）上的币 `tryBuy` | 0（audit L-1） |

### `getTokenInfo` 逐个核对第 10 套的 19 个币

| 情况 | 数量 | 结果 |
|---|---|---|
| 在内盘的曲线币（WBNB 和测试计价币） | 10 | status 1，pair 为 0，`protocolFeeBps` 100，`graduationLeft` 等于 pad 的剩余量 |
| 已毕业的曲线币 | 7 | status 2，pair 是迁移出的池子，`protocolFeeBps` 0 |
| 已发射的打新币 | 1 | status 2，有 pair |
| 打新进行中 | 1 | status 3 |
