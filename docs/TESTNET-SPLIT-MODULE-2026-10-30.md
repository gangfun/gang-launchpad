# 测试网记录 · GangSplitModule（多人分账收款模块）

- 日期：2026-10-30 Asia/Shanghai
- 网络：BSC 测试网（97），第 10 套 pad `0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`
- 代码：PR #79，分支 `feat/split-module` 的 `d9e0834`（`src/gang/GangSplitModule.sol`、`src/gang/GangSplitModuleFactory.sol`）
- 部署前：一轮内部审计、两轮修复复审、一轮上测试网前的独立审查和它的修复复审，Low 及以上全部修复
- 结论：部署和整轮验收通过；所有分账金额与合约规则逐 wei 一致

## 部署

| 项 | 地址 / 交易 |
|---|---|
| GangSplitModuleFactory | [`0x5F7dC7502E945A860Cf49cca72dA8bD60Fb1567E`](https://testnet.bscscan.com/address/0x5F7dC7502E945A860Cf49cca72dA8bD60Fb1567E)，部署 [`0x2356ee9a…7d33`](https://testnet.bscscan.com/tx/0x2356ee9a8b3d015cf1efa9e9eebe0d5a8b7547545c7bf5a344bd2bafc7f57d33)（gas 2,339,932） |
| 实现合约 | [`0xDAc2472CF5C4a04fC7DA8f82fA1ba1f9d821C741`](https://testnet.bscscan.com/address/0xDAc2472CF5C4a04fC7DA8f82fA1ba1f9d821C741)，`gangQuote` = 0（测试网没有 GANG） |
| `admin.setFactory(factory, true)` | 管理合约 v2 `0xBc2d…9a4d`，[`0xfff6e867…79d0`](https://testnet.bscscan.com/tx/0xfff6e867a4d7af3392049e8b1d3f165811c49d6c3064e8bb74e46441826f79d0)（gas 97,584）；测试网由 owner 钱包 `0xCa8e…00b6` 直接执行，主网是多签 |
| 部署脚本检查 | 接线检查、运行时字节码比对（`checkCode`）在模拟阶段通过 |

## 验收（`script/SplitTestnetAcceptance.s.sol`）

收款人：部署钱包 60%、B `0x5574…91b6` 30%、C 10%（之后 C 把自己这份换到 C2 `0x39a8…cdB8`）。B、C、C2 都是由部署钥匙推出来的一次性钱包。报价币 MockSPCXB `0x02B3…F1c`（QuoteRegistry 里有，`keeperServes` = true）。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 克隆模块 | [`0xcb6c10D4C35EE7515749863F499d97AC642969a3`](https://testnet.bscscan.com/address/0xcb6c10D4C35EE7515749863F499d97AC642969a3)，地址等于 `predict`，同一笔里加白（`isListed` = true，`moduleOf` = 工厂），gas 428,947 | [`0x17814a53…7d0f`](https://testnet.bscscan.com/tx/0x17814a533ec9439ba376b4e7ab4209ee274a174f6221dd5554ea4a73e20e7d0f) |
| 建币 SPLT（买卖税 2%，分红 50%，收款 = 模块） | [`0x7efA16Cb02E5628BB958865313154C14fFB3689B`](https://testnet.bscscan.com/address/0x7efA16Cb02E5628BB958865313154C14fFB3689B)，gas 1,622,268 | [`0x3b6c0e95…60e8`](https://testnet.bscscan.com/tx/0x3b6c0e953927d9796b3bedf0f72970fcc90805e90157419bbcf90110cb5260e8) |
| `bind` | `token` / `quote` 写入，gas 103,426 | [`0xc50dca51…6a95`](https://testnet.bscscan.com/tx/0xc50dca51648d933347a9495942100adaf6ae85343c2d43205f62ea4794ba6a95) |
| 毕业 | 部署钱包买到 1%，一次性 Agent 各买 1% 直到毕业；交易对 `0xDc62…5c2B` | 同一轮，共 404 笔全部成功 |
| 池子交易交税 | 部署钱包买 0.5、卖出一半，卖出时的 swap-back 付给模块 0.003855023411612415 | 同上 |
| keeper：`previewWork` → `work(0)` | due = true；B 1,156,507,023,483,724、C 385,502,341,161,241、部署钱包 2,313,014,046,967,450（余数归第一位），之后未分 0、欠款 0。gas 158,510 | [`0xfae66d3e…890f`](https://testnet.bscscan.com/tx/0xfae66d3e6c650576b991e3f7e1563e11ab18a519d3e9f60e1851c5897ee4890f) |
| 别的资产：0.001 WBNB 转给模块，`distribute(WBNB)` | 按同样份额：0.0006 / 0.0003 / 0.0001。gas 117,531 | [`0xe6845818…c301`](https://testnet.bscscan.com/tx/0xe6845818a535a5d8a4b23214b6a63d7199077bddb64ecdcad6c4c4ac6963c301) |
| C `setPayee(2, C2)` | C2 写入第 3 位，份额不变。gas 52,258 | [`0xa6c1e404…4240`](https://testnet.bscscan.com/tx/0xa6c1e404bd6cee8b330f052efd903f7eb0d0f57268858e30510bb1ecd0e34240) |
| 1 枚报价币转给模块，`distribute`（`cast send`，gas 由 `eth_estimateGas` 估） | 估算 474,098，实际 104,652；C2 收到 0.1 | [`0xb65ee736…cfff1`](https://testnet.bscscan.com/tx/0xb65ee736b30064a4d850106f7b8686aaef175b92cd81ff64a86743ca4e2cfff1) |
| 最终状态 | 模块里报价币和 WBNB 都是 0，欠款都是 0；`previewWork` = (false, 0) | 只读 |
| 收回一次性钱包剩下的 gas | 0.003325 tBNB 回到部署钱包 | 80 笔转账 |

花费：三次广播共约 3,989 万 gas（主轮 3,773 万，毕业占大部分；续跑 48 万；收回 168 万），按 0.1 gwei 合约 0.004 tBNB；一次性钱包的预付 gas 已收回 0.003325 tBNB。

## 两笔失败：gas limit 不能按「模拟用量 × 系数」给

验收里有两笔交易回滚 `PushStarved`，钱都没动：

| 交易 | 调用 | forge 给的 gas limit | 实际需要 |
|---|---|---|---|
| [`0x15f255c0…60a7`](https://testnet.bscscan.com/tx/0x15f255c08db02b5514941e1276398c1e0b59e34c023db435c16259d5aba360a7) | `work(0)` | 218,940（模拟用量 × 1.3） | 续跑时给 673,664 成功（实际用 158,510） |
| [`0x0f9f4181…fd8a`](https://testnet.bscscan.com/tx/0x0f9f4181a62562ed6c533d5a2429cb3d3f2be3ab3fb41c12fdda3140c077fd8a) | `distribute(quote)` | 432,868（模拟用量 × 4） | `eth_estimateGas` 对同样的调用估出 474,098 |

原因是设计如此：每次推送开始前合约要求至少剩 `PUSH_GAS × 64/63 + PUSH_RESERVE` ≈ 36.5 万 gas，保证代币拿满 `PUSH_GAS`，不能被压低 gas 把推送「饿」成欠款（上测试网前审查 L-1）。所以需要的 gas limit ≈ 最后一次推送之前已经用掉的 gas + 36.5 万，比实际用量高几十万。

- `eth_estimateGas`（钱包、`cast send`、keeper 用的方式）按二分查找给出够用的值，第二次用它就成功了。
- forge script 按本地模拟用量乘系数给 gas limit，不够；用 forge 脚本调分账要给很大的 `--gas-estimate-multiplier`，或者改用 `cast send`。
- CLI 和 keeper 不要自己写死或压低 gas limit。

## 本次没测到（单测覆盖：`test/gang/GangSplitModule.t.sol`，25 个）

- 收款人被拉黑时记欠款、下次推送补发、`release` 分次领取。
- 余额被扣时欠款按比例缩减。
- 拒收时烧光 gas、带单笔上限、返回值异常、代理合约代币。
- keeper 不服务的报价币（从 QuoteRegistry 下架后不 due）。
- 主网的 `GANG_QUOTE` 和多签 owner 检查（只在 chainid 56 生效）。

## 复跑

```sh
# 部署工厂（管理合约已是 handler 的 owner；测试网由 owner 钱包直接 setFactory）
GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 HANDLER_ADMIN=0xBc2d7A1f2E86A7586f31A324aDaE3d38bFd49a4d \
  DEPLOYER_PRIVATE_KEY=… forge script script/DeployGangSplitModuleFactory.s.sol \
  --rpc-url https://bsc-testnet-rpc.publicnode.com --broadcast --legacy --with-gas-price 100000000

# 验收（续跑：SPLIT_MODULE、TOKEN；池子交易做过以后 SKIP_POOL=true）
SPLIT_FACTORY=0x5F7dC7502E945A860Cf49cca72dA8bD60Fb1567E DEPLOYER_PRIVATE_KEY=… \
  forge script script/SplitTestnetAcceptance.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com \
  --broadcast --slow --legacy --with-gas-price 100000000 --gas-estimate-multiplier 600
# 收回一次性钱包的 gas
DEPLOYER_PRIVATE_KEY=… forge script script/SplitTestnetAcceptance.s.sol --sig "sweep()" \
  --rpc-url https://bsc-testnet-rpc.publicnode.com --broadcast --slow --legacy --with-gas-price 100000000
```
