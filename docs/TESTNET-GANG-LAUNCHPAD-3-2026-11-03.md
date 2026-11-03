# 测试网 · GangLaunchpad 3.0（可升级 pad，内置聚合器入口）

- 日期：2026-11-03 Asia/Shanghai
- 网络：BSC 测试网（97）。和第 10 套 GangLaunchpad 1.0（`0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`）、2.0 并列，共用 1.0 的共享合约。
- 规格：`docs/SPEC-GANG-LAUNCHPAD-3-2026-11-03.md`
- 部署钱包：`0xCa8e…00b6`。测试网上共享合约和老 pad 都归它所有，所以阶段 1 就直接完成了登记、开放和老 pad 的 router 设置。测试网上的 ProxyAdmin 也归它，主网上归平台 Safe。

## 地址

| 合约 | 地址 |
|---|---|
| **GangLaunchpad 3.0（代理：唯一的永久地址）** | [`0x0508232833aE6849c03b28F7aA248BBd5cFCceE2`](https://testnet.bscscan.com/address/0x0508232833aE6849c03b28F7aA248BBd5cFCceE2)，起始区块 140496214 |
| 实现合约（当前，升级演练后的） | [`0xb45FA6Dec061D752feA2E6f05BE09e94aC26C8fa`](https://testnet.bscscan.com/address/0xb45FA6Dec061D752feA2E6f05BE09e94aC26C8fa) |
| 实现合约（首次部署） | `0x6D7Ea206594b754f6de7f4fB41CD8AeA3B3D082d` |
| ProxyAdmin | `0x7222Aa82F4913E7B4b776f096A7eBD104375E2FD` |
| GangTaxHandler（3.0） | `0x4C57123468e0C91295c63aA520F3086C1499d228` |
| GangRouter 3.0（代理） | `0x09544Fd87c5Ff2c4fb05885A76861A12e83f87b9` |
| GangRouter 实现 / ProxyAdmin / Timelock | `0x432Fdf126329b9DabBC6387c60C6740874EBA7e1` / `0x13E8738D42d4248f9D63f27fDadCf54Cbb9719b2` / `0xC885c8f7ae901Ee8fdb60b400B292B298295B3Dc` |
| CurveLogic3 / LegacyRoute（新部署） | `0x1cf80A626D08F00f7cd12209580067940FBFA23F` / `0xfb7f21A073eEC2980295BF204264aBEBF9B000c4` |
| FairLogic / PoolCheck（沿用已部署的） | `0x6A0484e4528B8Dd97017729B67Ab176875f83e98` / `0x76Ba001095De137b40D93e8A1493432Bd38bC00c` |
| GangPadRegistry（已 `addPad(3.0)`） | `0xB11B83C83DEd269B040faecC1D61B4885BA8e56e` |
| GangGateway（3.0 已把它列为 router） | `0xb325dde51129C592E443ecbEE1E219D14C66e091` |

Registry 里其余 9 个 pad 都已把 3.0 列为 router（`setRouter(3.0, true)`，读链核对过），其中包括 1.0 `0xFebF…5BB1`、2.0 `0xb14d…3B3E` 和更早的 `0x6381…39be`、三版金库 pad（`0x61Dd…ce0b`、`0xf744…6086`、`0x9108…C8a9`）、飞轮 V2 `0x7069…E3d6`，以及 `0x7E30…937e`、`0xD648…951c`。没有执行切换批次，1.0 和 2.0 照常发币。

## 部署

```
GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 GANG_GATEWAY=0xb325dde51129C592E443ecbEE1E219D14C66e091 \
GANG_PAD2=0xb14d415f70D7F99f0D93Bd3BF76e0D6b38b53B3E \
  forge script script/DeployGangLaunchpad3.s.sol --rpc-url $BSC_TESTNET_RPC_URL --broadcast --legacy --with-gas-price 100000000 --slow
```

- 34 笔交易全部成功，`self-check ok`。
- 之后带 `GANG_PAD3` / `GANG_ROUTER3` / `GANG_PAD3_BLOCK` 只读重跑阶段 2，结果也是 `self-check ok`。
- 部署记录：`broadcast/DeployGangLaunchpad3.s.sol/97/run-1793674134430.json`。

## 验收（`script/GangLaunchpad3TestnetAcceptance.s.sol`）

```
GANG_PAD3=0x0508232833aE6849c03b28F7aA248BBd5cFCceE2 \
OLD_PADS=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1,0xb14d415f70D7F99f0D93Bd3BF76e0D6b38b53B3E \
GANG_GATEWAY=0xb325dde51129C592E443ecbEE1E219D14C66e091 \
  forge script script/GangLaunchpad3TestnetAcceptance.s.sol --tc GangLaunchpad3TestnetAcceptance \
  --rpc-url $BSC_TESTNET_RPC_URL --broadcast --legacy --with-gas-price 100000000 --slow
```

21 笔交易全部成功，记录见 `broadcast/GangLaunchpad3TestnetAcceptance.s.sol/97/run-1793674376408.json`。

测了三个币，每个币都走同样三步：经聚合器风格的适配合约用原生 BNB 买入 0.002 BNB；卖出一半，付 1% 路由手续费，到账 BNB；剩下一半直接在入口卖出，不付手续费。三个币分别是：

- **3.0 自己的币** [`0xeBdA03db2422dE16CFA2361Cc81D6202bD1b61ea`](https://testnet.bscscan.com/address/0xeBdA03db2422dE16CFA2361Cc81D6202bD1b61ea)：规则版本为 1，Registry 能查到它属于 3.0。
- **1.0 的币，经 3.0 转发** [`0x3F45305694B9cF07b6566be52332616A614170e5`](https://testnet.bscscan.com/address/0x3F45305694B9cF07b6566be52332616A614170e5)
- **2.0 的币，经 3.0 转发** [`0x40cb7DFD8488588d91C8d5C88ae6e44D70b35195`](https://testnet.bscscan.com/address/0x40cb7DFD8488588d91C8d5C88ae6e44D70b35195)

另外用线上的 GangGateway 买入了 3.0 的币：Gateway 通过 Registry 找到 3.0，再以 router 身份下单。

每一步都先在模拟里核对：成交和报价一致到 wei，路由手续费到账，3.0 和适配合约里没有剩下 BNB；转发的币不会动到 3.0 自己的 WBNB，也没有残留授权。

上链后直接读链复核：3.0 的 BNB 余额为 0；3.0 持有的两个老币余额都是 0；3.0 给 1.0、2.0 的 WBNB 授权都是 0；适配合约的 `isCaller` 为真。

## 升级演练（`script/UpgradeGangLaunchpad3.s.sol`）

```
GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 GANG_GATEWAY=0xb325dde51129C592E443ecbEE1E219D14C66e091 \
GANG_PAD3=0x0508232833aE6849c03b28F7aA248BBd5cFCceE2 GANG_ROUTER3=0x09544Fd87c5Ff2c4fb05885A76861A12e83f87b9 \
GANG_PAD3_BLOCK=140496214 CALLERS=0xAA0fe2cbD9F9F077448aaBE0a4013142E63EC5cc \
  forge script script/UpgradeGangLaunchpad3.s.sol --rpc-url $BSC_TESTNET_RPC_URL --broadcast --legacy --with-gas-price 100000000 --slow
```

1. 脚本用这次构建部署了新实现 `0xb45F…C8fa`，依赖地址读自当前实现。
2. 比对了 7 个依赖、锁定状态和版本号。
3. 在模拟里以 ProxyAdmin owner 的身份执行升级，比对升级前后的设置和币记录，阶段 2 读回 `self-check ok`。
4. 以上全部通过后发出升级交易 [`0x1b57c7db…f283d`](https://testnet.bscscan.com/tx/0x1b57c7db4d02e72344117dedd940037bed25f9a59ae08ce93566eb8cca9f283d)。记录见 `broadcast/UpgradeGangLaunchpad3.s.sol/97/run-1793674481095.json`。

升级之后：
- 代理的实现槽位已指向新实现；
- 只读重跑阶段 2，结果是 `self-check ok`；
- 又跑了一遍验收脚本（只测 3.0 的币），新币 [`0x3eaDa1C4Ddc99A1E6Bc9aFA425e96c2fb9E4E953`](https://testnet.bscscan.com/address/0x3eaDa1C4Ddc99A1E6Bc9aFA425e96c2fb9E4E953) 的买入、经适配合约卖出、直接卖出都成功。记录见 `broadcast/GangLaunchpad3TestnetAcceptance.s.sol/97/run-1793674537263.json`。

## 没在测试网上做的

- **金库 pad 和飞轮 V2 的币经 3.0 转发**：在主网 fork 测试 `test/fork/GangLaunchpad3DeployFork.t.sol` 里测过。测试网上这两个 pad 也已经把 3.0 列为 router。
- **切换批次**：没执行。
- **模块**：GangBond、各模块工厂都没有为 3.0 部署。
