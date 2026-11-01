# 测试网 · GangVaultLaunchpad（2.0 金库版）

- 日期：2026-11-01 Asia/Shanghai
- 网络：BSC 测试网（97），和第 10 套 GangLaunchpad（1.0，`0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`）、2.0 并列，共用 1.0 的共享合约
- 内容：2.0 的 pad 加上锁仓金库入口。每个曲线币创建时绑定一个金库，只能用 `createWithVault` 创建。内盘期间：
  - `vaultLock`：用户钱包 → 金库，计入用户的 1% 额度；
  - `vaultRelease`：金库 → 用户钱包，不受 1% 限制。
  - 两个入口都要求用户 = `tx.origin` 且持有 Agent ID。金库自己不能在内盘买卖它绑定的币。
- 部署钱包：`0xCa8e…00b6`（测试网上它拥有全部共享合约，阶段 1 直接完成登记并开放）

当天部署过两次，两次的合约逻辑相同：
- **当前（第二版）**：源码按 `forge fmt` 格式化（只改了空白），部署脚本按独立审查修好。
- **第一版** `0x61Ddc00e07Cc6aD14732f6c35A0194E194E6ce0b`：已停止创建（`TokenDeployer.setLaunchpad(第一版, false)`，交易 [`0xe21c48d3…8a82`](https://testnet.bscscan.com/tx/0xe21c48d3749b5caa5edc9d0f4881c9d8ace65e397f8cc19eb02b48b366498a82)）。

## 地址

| 合约 | 地址 |
|---|---|
| **GangVaultLaunchpad** | [`0xf7447D9ee5041eB3Ec3e8eF01ad652a48B956086`](https://testnet.bscscan.com/address/0xf7447D9ee5041eB3Ec3e8eF01ad652a48B956086)，起始区块 140141084 |
| GangTaxHandler | [`0x5940385f4De9E38a9F414C000773a2629eacCBDB`](https://testnet.bscscan.com/address/0x5940385f4De9E38a9F414C000773a2629eacCBDB) |
| GangRouter（代理：pad 列入、用户授权的地址） | [`0x298288D76A1BA71999eb71D128526Ff656f689f7`](https://testnet.bscscan.com/address/0x298288D76A1BA71999eb71D128526Ff656f689f7) |
| GangRouter 实现 / ProxyAdmin / Timelock | `0xC2B77fA5c719Ab086F2BE15ff0e1CB3F0Dd99d7A` / `0xD87C3166Eb914Fa91E39d465FD44615F9375bFc9` / `0x87097291fF9917b46aD3117A5fFFB030878eA650` |
| CurveLogic / FairLogic / PoolCheck | `0x8Fcf0875201c91Ee192Fa8C995461Da7879Fa0f6` / `0x6A0484e4528B8Dd97017729B67Ab176875f83e98` / `0x76Ba001095De137b40D93e8A1493432Bd38bC00c` |
| 测试金库 TestnetLockVault（验收用替身，已 `setVault`，已列为 handler 税收接收方） | [`0x9E2C8Bc380fAaeC720f502419326828febB1874D`](https://testnet.bscscan.com/address/0x9E2C8Bc380fAaeC720f502419326828febB1874D) |
| GangPadRegistry（已 `addPad`） | `0xB11B…e56e` |
| GangGateway（已列入） | `0xb325…e091` |

没有部署 GangBond 和模块工厂（按设计）。也没有切换批次：1.0、2.0 照常创建。

## 部署

```
GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 GANG_GATEWAY=0xb325dde51129C592E443ecbEE1E219D14C66e091 \
  forge script script/DeployGangVaultLaunchpad.s.sol --rpc-url $BSC_TESTNET_RPC_URL --broadcast --legacy --with-gas-price 100000000 --slow
```

22 笔交易全部成功，自检 `self-check ok`。之后只读重跑阶段 2，用的是 `GANG_VAULT_PAD` / `GANG_VAULT_ROUTER` / `GANG_VAULT_PAD_BLOCK`（2.0 的 `GANG_PAD2` 等变量不会被读取）。

部署记录：`broadcast/DeployGangVaultLaunchpad.s.sol/97/run-1793514328916.json`。

### 主网流程演练（本地主网分叉，不上链）

在本地 anvil 主网分叉上用一个临时钱包，从头走了一遍主网路径：
1. 阶段 1 部署；
2. 冒充 Safe 执行 batch 1（共享合约登记）；
3. 阶段 2 交接 owner；
4. Safe 执行 batch 2（接受 owner，`setMigrator` 开放）；
5. 阶段 2 带 `VAULT`：打印单独的金库登记批次（`pad.setVault` + `handler.list`），打印前已在模拟里试跑；
6. Safe 执行金库批次后再跑阶段 2：`self-check ok`。

拦截检查也逐一触发过：
- 主网阶段 1 不带 `VAULT_PAD_NEW=true`；
- 主网阶段 1 带 `VAULT`；
- `GANG_VAULT_PAD` 指向 2.0；
- `VAULT` 是 router。

## 验收（`script/GangVaultLaunchpadTestnetAcceptance.s.sol`）

```
GANG_VAULT_PAD=0xf7447D9ee5041eB3Ec3e8eF01ad652a48B956086 GANG_VAULT_ROUTER=0x298288D76A1BA71999eb71D128526Ff656f689f7 \
  forge script script/GangVaultLaunchpadTestnetAcceptance.s.sol --tc GangVaultLaunchpadTestnetAcceptance \
  --rpc-url $BSC_TESTNET_RPC_URL --broadcast --legacy --with-gas-price 100000000 --slow
```

23 笔交易全部成功。每一步都在模拟里检查过：
- **币 A** [`0xebC71b20d6a6BfB238aEB55178DF72Aec0294aBD`](https://testnet.bscscan.com/address/0xebC71b20d6a6BfB238aEB55178DF72Aec0294aBD)：WBNB 计价，税 3% / 3%，无分红，税收接收方是金库，门槛 9 BNB。
  1. 经 Router 买入 0.002 BNB；
  2. 锁入一半：钱包余额、金库余额、`lockedOf` 都对得上，`walletRoom` = 1% − 余额 − 已锁；
  3. 取回其中大部分，其余留在金库；
  4. 把取回的币在 pad 上卖掉，卖出正常。
- **币 B** [`0xc345Ba5c296D0Ebc91e2406461a13E14f5E398a7`](https://testnet.bscscan.com/address/0xc345Ba5c296D0Ebc91e2406461a13E14f5E398a7)：测试报价币计价，税 3% / 3%，分红 40%，税收接收方是金库，门槛 6 BNB。
  1. 买入、锁入一半、取回大部分。每一步后，钱包和金库的分红份额都等于各自余额；
  2. 临时关闭钱包上限，一笔买到毕业，再打开上限。经共享 migrator 毕业，交易对 [`0x42a24230a6e9f0B0aaD431fe20b3A998031BcB2e`](https://testnet.bscscan.com/address/0x42a24230a6e9f0B0aaD431fe20b3A998031BcB2e)；
  3. 毕业后 `vaultRelease` 关闭，测试金库改用普通转账把剩下的币还给钱包。之后份额由代币自己同步。

部署记录：`broadcast/GangVaultLaunchpadTestnetAcceptance.s.sol/97/run-1793514403857.json`。

直接读链复核：
- `isVault(测试金库)` 为真；A、B 的 `vaultOf` 都是测试金库；
- A：金库余额 = `lockedOf(A, 部署钱包)`（锁入后没取回的部分），A 仍未毕业；
- B：已毕业，交易对已设置，金库余额为 0；
- 钱包上限已重新打开，pad 已开放（migrator 是共享 migrator），registry `isPad` 为真；
- 第一版已不能创建，第二版可以。

两次部署加验收合计约花 0.008 tBNB。

## 待办

- 合作方把自己的金库部署到测试网后，由 pad owner 执行 `setVault(金库, true)`，并在 handler 上 `list(金库, label)`，然后一起联调。
- 后端索引、网站显示、CLI `gang create --vault`。
- 主网：等用户明确同意。
