# 测试网 · GangVaultLaunchpad（2.0 金库版）

- 日期：2026-11-01 Asia/Shanghai
- 网络：BSC 测试网（97），和第 10 套 GangLaunchpad（1.0，`0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`）、2.0 并列，共用 1.0 的共享合约
- 内容：2.0 的 pad 加上锁仓金库入口。每个曲线币创建时绑定一个金库，只能用 `createWithVault` 创建。内盘期间：
  - `vaultLock`：用户钱包 → 金库，计入用户的 1% 额度；
  - `vaultRelease`：金库 → 用户钱包，不受 1% 限制。
  - 两个入口都要求用户 = `tx.origin` 且持有 Agent ID。金库自己不能在内盘买卖它绑定的币。
- 部署钱包：`0xCa8e…00b6`（测试网上它拥有全部共享合约，阶段 1 直接完成登记并开放）

当天共部署三版：
- **第三版（当前，主网用的就是这一版）** `0x9108e7b85e69060A5E626A04Ce6DEf323071C8a9`：在第二版基础上加了"指定发币钱包"，见文末一节。
- **第二版** `0xf7447D9ee5041eB3Ec3e8eF01ad652a48B956086`：源码按 `forge fmt` 格式化（只改了空白），部署脚本按独立审查修好。下面的地址、部署和验收记录都是这一版的。它仍然开放，金库方在上面做过一轮联调。
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

## 第三版：指定发币钱包

第二版上，任何持有 Agent ID 的钱包都能用 `createWithVault` 把新币绑到任意一个已登记的金库。第三版改为：
- owner 用 `setVaultCreator(vault, creator)` 为每个金库指定发币钱包（传 0 表示撤销）；
- `createWithVault` 只接受这个钱包，绑定成功后授权即清空，每次授权只能绑一个币，owner 可以再次授权；
- 金库下架时授权一并清除，重新上架不会恢复。

部署脚本新增 `VAULT_CREATOR`：测试网在阶段 1 直接设置；主网把它和金库登记放进同一个 Safe 批次，如果金库已经登记过，就单独打印一个批次。验收脚本每次发币前先授权，并检查授权用掉后变回 0。

独立审查：没有 High 或 Medium 问题，Low 和 Info 都已修复，并经过复核。

| 合约 | 地址 |
|---|---|
| **GangVaultLaunchpad** | [`0x9108e7b85e69060A5E626A04Ce6DEf323071C8a9`](https://testnet.bscscan.com/address/0x9108e7b85e69060A5E626A04Ce6DEf323071C8a9)，起始区块 140215635 |
| GangTaxHandler | [`0x43F71545a02E80c6Db3449487fa82Eecf2894125`](https://testnet.bscscan.com/address/0x43F71545a02E80c6Db3449487fa82Eecf2894125) |
| GangRouter（代理） | [`0x9bF3E197a6719Af856a7c82d23CABFdBcc184f69`](https://testnet.bscscan.com/address/0x9bF3E197a6719Af856a7c82d23CABFdBcc184f69) |
| GangRouter 实现 / ProxyAdmin / Timelock | `0x39349121e8E8F6DD332814178b8136816a4a054B` / `0xD4caf988ac9d257701f2097465aBB1FBE4E0a0af` / `0xaC57037B85cE6A18090E6F733fE8E5293544Ef55` |
| 测试金库 TestnetLockVault | [`0x83A09d7b11b644aB867255AB4A2B497950C090B6`](https://testnet.bscscan.com/address/0x83A09d7b11b644aB867255AB4A2B497950C090B6) |

**部署**：命令和第二版相同（不带 `VAULT`），22 笔交易全部成功，`self-check ok`。部署记录：`broadcast/DeployGangVaultLaunchpad.s.sol/97/run-1793547865782.json`。

**验收**：
- 第一次运行时，验收脚本里有一个"同一授权再发一次应被拒绝"的模拟探测。这个探测假冒部署钱包调用合约，让 forge 多算了部署钱包一个 nonce。结果只上链了前 6 笔（部署测试金库、登记、授权、发出币 `0x4581…0ae0`），之后的交易都因为 nonce 对不上没有发出。
- 删掉这个探测后，用同一个测试金库（`TEST_VAULT`）重跑：22 笔交易全部成功，`acceptance ok`。授权"只能用一次"改为检查用掉后变回 0：合约只接受和授权地址一致的调用者，授权为 0 时谁都发不了币。
- 部署记录：`broadcast/GangVaultLaunchpadTestnetAcceptance.s.sol/97/run-1793548025937.json`。

**链上复核**：
- 币 A `0xA6a1a26ed65Ba82F8c7422E5EF0E8f1A14BC0b8d` 在内盘，金库里留着没取回的部分；
- 币 B `0x168c8317A010391eCc05f1292f693d1AB629d410` 已毕业，金库余额为 0；
- 测试金库的授权已经用掉（为 0），钱包上限已重新打开，pad 已开放。

**金库方合约在毕业后的表现**：在本地测试网分叉上，用金库方部署在第二版上的真实合约，把他们的测试币买到毕业后接着测：
- 毕业后铸造和销毁都改走普通转账，到账数量正确，按 90% 退币；
- `burnRetained` 把留存全部烧进 0xdead；
- 金库对 pad 的授权始终为 0；
- pad 的 `vaultRelease` 返回 `AlreadyGraduated`。

## 待办

- 每个要接入的金库：由 pad owner 执行 `setVault(金库, true)`，新版 pad 上还要执行 `setVaultCreator(金库, 发币钱包)`；只有金库要收税时，才在 handler 上执行 `list(金库, label)`。
- 后端索引、网站显示、CLI `gang create --vault`。
- 主网：等用户明确同意。
