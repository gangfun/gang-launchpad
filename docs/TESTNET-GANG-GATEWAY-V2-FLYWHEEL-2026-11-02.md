# 测试网 · GangGateway V2（铸币飞轮）

- 链：BSC 测试网（chainId 97），2026-11-02
- 代码：网关 V2（AUDIT-BRIEF §26），审计 → 修复 → 独立复审之后的版本；规格 `docs/SPEC-GANG-GATEWAY-2026-10-30.md`「铸币飞轮」一节。
- 两件事：
  1. 新部署一个**验收用网关**，只列入测试网 V2 飞轮 pad，在上面跑完验收；
  2. 聚合器联调用的网关 `0xb325dde51129C592E443ecbEE1E219D14C66e091` **原地升级**：新实现已部署、升级已在 48 小时时间锁里排队，到时执行后再列入测试网的飞轮 pad。地址和用户授权都不变。

## 1. 验收用网关

| 项 | 地址 |
|---|---|
| GangGateway（代理） | [`0x10C079F2d2f9Cf87de7974fD2935BcD1418f132a`](https://testnet.bscscan.com/address/0x10C079F2d2f9Cf87de7974fD2935BcD1418f132a) |
| 实现合约（V2） | `0xeE20FC7D5bDAd1d65A59E42Fa446C3380e82228e` |
| ProxyAdmin | `0x98A6c1d3dD00663d9c87A9Bbb483ECe2Fe71b932` |
| TimelockController（48 小时；角色 = 部署钱包） | `0xa678C74DD49dB9cA4d6CbEeE4D0193b04B6C2095` |
| 读的 registry | `0xB11B83C83DEd269B040faecC1D61B4885BA8e56e` |
| 列入的 pad | 测试网 GangFlywheelPad V2 `0x706973e4F08dBf1604Cf540d0168428521e0E3d6`（只列入这一个，`GANG_PAD`） |

部署：`DeployGangGateway`，`GANG_PAD_REGISTRY=0xB11B…e56e GANG_PAD=0x7069…E3d6`，4 笔，区块 140,375,050–140,375,064，合计 4,644,593 gas；自检通过。

| 交易 | gas |
|---|---|
| 实现合约 [`0xd135d02f…096b`](https://testnet.bscscan.com/tx/0xd135d02fc4091bcc398de059075a539d3408282f2502fc6094807e4ce2aa096b) | 2,586,772 |
| 时间锁 [`0x71b7f24c…89e6`](https://testnet.bscscan.com/tx/0x71b7f24c1b9af2d6a4fe164162a40f82de61c52f301e08cd2a734d2abf6689e6) | 1,376,872 |
| 代理 [`0x88844b60…9600`](https://testnet.bscscan.com/tx/0x88844b60312698db54210dbd7c6b732c81ff25ba6d08d93a09e2c3efb7349600) | 632,262 |
| V2 飞轮 pad `setRouter(网关, true)` [`0xdc7dd2e5…66ee`](https://testnet.bscscan.com/tx/0xdc7dd2e59b943768088d8608adcb4f4676f069bda6b0619c07b9fc047daa66ee) | 48,687 |

## 2. 验收

`script/GatewayFlywheelTestnetAcceptance.s.sol`（`--tc GatewayFlywheelTestnetAcceptance`），部署钱包（有 Agent ID、是验收网关的 owner）执行，24 笔全部成功，区块 140,375,327–140,375,423，合计 7,402,764 gas。每一步之后都检查：网关和 adapter 没有任何余额，网关对 pad 的授权为 0，用户对网关的代币授权为 0。

- 新建两个 sale（J 模板，护栏关闭）：BNB 计价 [`0x3d4B7331284dc8cba14637c316A8f54AcAd2FB4b`](https://testnet.bscscan.com/address/0x3d4B7331284dc8cba14637c316A8f54AcAd2FB4b)，测试报价币 MockSPCXB 计价 [`0x16D21dc3D84607DDcd1b7BeEaD85A5ae8F5F2D81`](https://testnet.bscscan.com/address/0x16D21dc3D84607DDcd1b7BeEaD85A5ae8F5F2D81)。
- 聚合器式 adapter [`0x325d847a664376eD02Ee5d8D3331B077CB820217`](https://testnet.bscscan.com/address/0x325d847a664376eD02Ee5d8D3331B077CB820217)（取自己的 msg.sender 当交易者，卖出收 1% 路由费给演示金库），`setCaller` 之前不在白名单，之后在。

| 步骤 | 交易 | gas | 结果 |
|---|---|---|---|
| BNB sale：经 adapter 买，`funds` = 3 份价格 + 半份 | [`0x47e0c038…b450`](https://testnet.bscscan.com/tx/0x47e0c0380195cc6953966100ab5863aa3c543021734826a7fa6bf4c422a3b450) | 269,277 | 买到 3 份（300,000 枚），花 0.000909 BNB，和 `tryBuy` 一致；多出的半份以 WBNB 退给用户 |
| BNB sale：精确授权 2 份，经 adapter 卖回 | [`0x5ff0ddbb…f005`](https://testnet.bscscan.com/tx/0x5ff0ddbbe0bf550817c05ae1c21bcf16068b7dac8b06900efff9f6db42ebf005) | 251,125 | 卖家得 0.00058806 BNB，路由费 0.00000594 BNB，合计等于 `trySell`（份价减 1% 退出费），和 pad 的 `previewWithdraw` 一致 |
| BNB sale：第 3 份直接在网关卖回 | [`0x325e5465…a76b`](https://testnet.bscscan.com/tx/0x325e5465d96f0e6fe9e6478a001857c7b3f2c29abd33c032886fbfe72310a76b) | 219,895 | 得 0.000297 BNB，等于 `trySell` |
| 测试币 sale：经 adapter 买（ERC-20 路径） | [`0x2096e352…c84b`](https://testnet.bscscan.com/tx/0x2096e352a0d2b4ec6fc4a9f8cf1ad95db296d966654813d66b8b2b684d35c84b) | 285,932 | 买到 3 份，花 0.000909 MockSPCXB，和 `tryBuy` 一致（`amountApproval = funds`）；多出的部分以测试币退回 |
| 测试币 sale：经 adapter 卖回 2 份 | [`0x01dd89bb…876c`](https://testnet.bscscan.com/tx/0x01dd89bb4e387a1878ad47f5b3feca865a2b0426d33e7f3e96ab553f4bd2876c) | 240,433 | 和 BNB sale 相同的金额，以测试币支付 |
| 测试币 sale：第 3 份直接卖回 | [`0xd1671019…ad29`](https://testnet.bscscan.com/tx/0xd16710199ab8e033bf660947d1fb6a86fdd240de008d93a05e5d273982acad29) | 210,283 | 等于 `trySell` |
| 已开盘的 A 币 [`0x42b3…b2b7`](https://testnet.bscscan.com/address/0x42b34E3832F976f1EBa4A81E6ED294F224f3B2b7)：经 adapter 开盘后买（`mintPostFor`） | [`0xe1d7db72…d9ff`](https://testnet.bscscan.com/tx/0xe1d7db7243b5e2af44ecb9f47b7962f2c6602a207e6809508376622d0932d9ff) | 705,559 | 用 0.05 测试币的预算买到 1,436,016.85 枚，花 0.00303，和 `tryBuy` 一致；之后 `trySell` 为 0（开盘后走交易对） |

## 3. `0xb325…e091` 的升级（排队中）

`UpgradeGangGateway`，`GANG_GATEWAY=0xb325…e091`（测试网上部署钱包是时间锁的提案人和执行人，脚本直接发送）。

| 项 | 值 |
|---|---|
| 新实现合约 | `0x4FBD3Ddd85BFeDf04114e529dF90501356294C6f`（[`0xedbfe480…6029`](https://testnet.bscscan.com/tx/0xedbfe480ce4d0f7092ec6b3a91ace8a6aefdb1395b4d4d498f075dc7affa6029)，区块 140,375,520） |
| schedule | [`0xe798e6d6…b3b9`](https://testnet.bscscan.com/tx/0xe798e6d687423e0c72fb4a183dd7c99f6e48cd8ea789be74056dcfb955efb3b9)，区块 140,375,524 |
| 操作 id | `0xd78437e44560e1f27fa2f2e89ad3d43fc0ae7d5c4e12b8f995e5230d74df8435` |
| 最早可执行 | 2026-11-04 19:43:21 +08:00 |

到时用同样的命令再跑两次：第一次执行升级，第二次自检并把网关列入测试网的飞轮 pad（V1 两套 `0x7E30…937e`、`0xD648…951c` 和 V2 `0x7069…E3d6`）。

```sh
DEPLOYER_PRIVATE_KEY=… GANG_GATEWAY=0xb325dde51129C592E443ecbEE1E219D14C66e091 \
GATEWAY_IMPL=0x4FBD3Ddd85BFeDf04114e529dF90501356294C6f \
forge script script/UpgradeGangGateway.s.sol --rpc-url $CHAPEL_RPC_URL --broadcast --slow --legacy --with-gas-price 100000000
```
