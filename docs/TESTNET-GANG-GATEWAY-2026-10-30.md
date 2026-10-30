# 测试网 · GangGateway（聚合器用的内盘网关）

当前测试网版本是**带卖出调用方白名单的第二版**。它读 GangPadRegistry 测试网实例 `0xB11B…e56e`，只列入第 10 套 pad。部署前，白名单改动做过独立审计，修复后又做了复审（审计说明 §25.10）。部署后重跑自检通过，验收脚本在链上跑通。第一版没有白名单，已从 pad 下架，见文末。

- 链：BSC 测试网（chainId 97），2026-10-30，部署区块 139747015
- 代码：PR #76（`feat/gang-gateway`）；规格见 `docs/SPEC-GANG-GATEWAY-2026-10-30.md`，审计说明见 §25

## 地址（第二版，当前）

| 项 | 值 |
|---|---|
| **GangGateway（代理：用户授权、聚合器调用这个地址）** | [`0xb325dde51129C592E443ecbEE1E219D14C66e091`](https://testnet.bscscan.com/address/0xb325dde51129C592E443ecbEE1E219D14C66e091) |
| 实现合约 | `0xDcd5f5939b29B759Fb174F6e05BEBBFa7BC2BCec` |
| ProxyAdmin（代理自己创建，owner = 时间锁） | `0xbddc324695A4D8bbF15E6C1b8F2F517731857d35` |
| TimelockController（48 小时；提案 / 执行 / 取消 = 部署钱包，没有 admin） | `0xCfF288Dc01C47fc4f56a9d731ABf47739823495E` |
| 网关 owner（管卖出调用方白名单） | 部署钱包 `0xCa8e…00b6` |
| 读的 registry | `0xB11B83C83DEd269B040faecC1D61B4885BA8e56e` |
| 已列入的 pad | 第 10 套 GangLaunchpad `0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1` |
| 没有列入的 pad | registry 里另一个团队的测试 pad `0x7E30…937e`：用 `GANG_PAD` 排除，没有改动 |
| 已加白的卖出调用方 | 验收用的 adapter `0x19c83FA4934EF247D5AFd258b121590C5C7fC6AB` |

部署交易（`broadcast/DeployGangGateway.s.sol/97/run-latest.json`）：

| 交易 | gas |
|---|---|
| 实现合约 [`0x2376356f…94d0`](https://testnet.bscscan.com/tx/0x2376356f656771a9cd3bcc567b827fc2e4a627fcfdcf9e3e98b30541154794d0) | 1,585,283 |
| 时间锁 [`0x7ff0dcf9…a7e7`](https://testnet.bscscan.com/tx/0x7ff0dcf98b7d6572e2409db6de33d444e1cf2913edfcb0191b84c96e18f8a7e7) | 1,376,872 |
| 代理（构造时初始化，owner = 部署钱包） [`0x89194352…6e33`](https://testnet.bscscan.com/tx/0x8919435237c9e4d00c7401f9d1ec40b51ef80e7d2f5f45de5352ba41adc66e33) | 632,267 |
| 第 10 套 `setRouter(网关, true)` [`0x7b0c77cc…f527`](https://testnet.bscscan.com/tx/0x7b0c77cca846ae65bd394865f2ed5a7f47601a8f1efb97b27756834b78d4f527) | 49,225 |

源码已在 BscScan 测试网验证（2026-10-30）：实现合约、时间锁、代理（已标记为指向实现合约）、ProxyAdmin 四个都已验证。源码取自 `19f4fc0`，编译设置为 solc 0.8.28、via-ir、优化 200 次、cancun；提交前确认过本地编译的字节码与链上一致。

## 部署命令

```bash
DEPLOYER_PRIVATE_KEY=… GANG_PAD_REGISTRY=0xB11B83C83DEd269B040faecC1D61B4885BA8e56e \
GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 \
  forge script script/DeployGangGateway.s.sol --rpc-url $BSC_TESTNET_RPC_URL --broadcast --legacy --with-gas-price 100000000
```

部署后加上 `GANG_GATEWAY=0xb325…e091` 重跑一遍（不广播），自检全部通过。检查项包括：

- 代理代码；
- 实现合约是本次构建的代码，且已锁死；
- ProxyAdmin；
- 时间锁的角色和延迟；
- registry、WBNB；
- 网关 owner 等于部署钱包，且没有待接受的转移；
- registry 本身的检查。

## 验收

脚本是 `script/GatewayTestnetAcceptance.s.sol`（`--tc GatewayTestnetAcceptance`），用部署钱包在第 10 套上跑。部署钱包持有 Agent ID，也是网关 owner。每一步都先在本地模拟、校验，通过后才广播：

| 步骤 | 交易 | gas | 结果 |
|---|---|---|---|
| 创建 WBNB 计价的无税曲线币 `0x835d…1140` | [`0x76b4d140…d84e`](https://testnet.bscscan.com/tx/0x76b4d140cd9cc9032f8966ab7cbf3001b5ec5ea35d08144d92c43d7267eed84e) | 1,352,445 | `getTokenInfo` = (1, BNB, 0, 100, 15 BNB) |
| 部署聚合器式 adapter `0x19c8…C6AB`（trader 取它自己的 msg.sender，卖出收 1% 手续费） | [`0x7b0d4832…590a`](https://testnet.bscscan.com/tx/0x7b0d4832e56713ea4ad3883ecea474b3a7607aa9ea3db697bb2fdea53bc5590a) | 231,054 | 部署后 `isCaller` 为 false |
| owner `setCaller(adapter, true)` | [`0xa5875552…a460`](https://testnet.bscscan.com/tx/0xa587555202a5fe053adfbdb8e8dd568073ce46ca093cfa172f807235c4d3a460) | 55,331 | `isCaller` 为 true |
| 经 adapter 用 0.002 BNB 买 | [`0x2a9e6397…0b3d`](https://testnet.bscscan.com/tx/0x2a9e6397848512b14923aec35d2c9fdc1ce5085c16e7e7c7af3de491735d0b3d) | 250,084 | 买到 422,232.80 枚，和 `tryBuy` 一致 |
| 精确授权一半 | [`0x1cc223ca…993e`](https://testnet.bscscan.com/tx/0x1cc223ca41101d1a9aabdc7baa0c98d6be94fff60922d0d3a7e4abf2cd4a993e) | 46,027 | |
| 经 adapter 卖一半，1% 路由手续费给演示金库 | [`0x45347133…77f7`](https://testnet.bscscan.com/tx/0x45347133abf679fcd45b5ce3e41424d1285a615627f3758d93d1987a157f77f7) | 197,037 | 卖家得 0.000970491 BNB，手续费 0.000009803 BNB，两者合计等于 `trySell`；卖完授权归 0 |
| 精确授权另一半 | [`0xbf9b2c6d…a4cf`](https://testnet.bscscan.com/tx/0xbf9b2c6d3562b4f89c08275f911ed89db2095dd7b62f310206ab301a69e6a4cf) | 46,027 | |
| 钱包直接调网关卖另一半（`from == msg.sender`，不需要加白），不收手续费 | [`0x001cb95f…0c79`](https://testnet.bscscan.com/tx/0x001cb95f106f71f5ae2d3b8c40a5677bb6226509e2ca688f31b1bdf27e170c79) | 185,722 | 得 0.000979906 BNB，等于 `trySell` |

每一步之后都检查了以下几项：

- 网关和 adapter 的 BNB、WBNB 余额为 0，网关不持有代币；
- 钱包的代币余额正确；
- 钱包对网关的授权为 0。

验收结束后用 `cast` 读链上状态，结果一致：

- 钱包代币余额为 0，对网关的授权为 0；
- 网关的 BNB、WBNB 余额都是 0；
- 第 10 套上，新网关的 `routers` 为 true，旧网关为 false；
- adapter 的 `isCaller` 为 true。

### 拒绝路径（链上 `eth_call`）

| 调用 | 结果 |
|---|---|
| 别的 EOA 调 `sellToken(from = 部署钱包)` | `NotWhitelisted` |
| 没加白的合约调 `sellToken(from = 部署钱包)` | `NotWhitelisted` |
| owner `setCaller(EOA, true)` | `NotAContract` |
| 非 owner 调 `setCaller` | `OnlyOwner` |
| 别人发起的交易里替部署钱包买（`to` ≠ origin） | `TraderNotOrigin` |
| 没有 Agent ID 的钱包买 | `NotAgent` |
| `feeRate = 501` | `FeeRateTooHigh` |
| 已下架的第一版网关买入 | pad 回滚 `OnlyRouter` |

## 第一版（没有白名单，已下架）

第一版网关是 `0x5020f4197A4E855474B464cD3617C048dd65635c`（区块 139741687 部署，同一套流程验收通过）。它的卖出路径谁都能调，有审计 M-1 的钓鱼风险。

第二版验收通过后，在第 10 套上执行 `setRouter(0x5020…635c, false)` 下架：[`0xf7f768de…7629`](https://testnet.bscscan.com/tx/0xf7f768de088c0ecf765db951cad62717fdc5480f6f0ac21bd1aa83cb81667629)，区块 139747140。下架后它的买卖都会回滚 `OnlyRouter`。

第一版不能原地升级成第二版：它的 owner 槽是 0，也没有 `reinitializer`；测试网时间锁又是 48 小时。所以第二版是重新部署的。第一版的部署记录在 git 历史里（PR #76 的第二个提交）。
