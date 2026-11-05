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

## 第二次升级：多跳卖出（所得付给 `to`）

新增 four.meme 同签名的 `sellToken(origin, token, from, to, amount, minFunds)`：卖出所得付给 `to`，`to` 必须是发起调用的白名单合约本身。用 `script/UpgradeGangLaunchpad3.s.sol` 升级（命令同上）：

- 新实现 [`0x4E907049E918869Fa7348b5A37627B757BD56474`](https://testnet.bscscan.com/address/0x4E907049E918869Fa7348b5A37627B757BD56474)；
- 升级交易 [`0x64fd1b84…5f28`](https://testnet.bscscan.com/tx/0x64fd1b8407382fb2771745923b1e9a2fee26255067df9769686b498b8c135f28)；
- 模拟里比对了升级前后的设置和 2 个币的记录，读回检查通过；
- 记录：`broadcast/UpgradeGangLaunchpad3.s.sol/97/run-1793681441614.json`。

升级后重跑验收（`OLD_PADS` 为 1.0 和 2.0，带 `GANG_GATEWAY`），29 笔交易全部成功，记录在 `broadcast/GangLaunchpad3TestnetAcceptance.s.sol/97/run-1793681484794.json`。测了三个币：

- 3.0 的币 [`0xB44856a33c1c541648908cE924De7D59B0feF49d`](https://testnet.bscscan.com/address/0xB44856a33c1c541648908cE924De7D59B0feF49d)
- 1.0 的币 [`0x07Bf5C4C68c5eac8f530598D2b8C1Ae77a7dCd0a`](https://testnet.bscscan.com/address/0x07Bf5C4C68c5eac8f530598D2b8C1Ae77a7dCd0a)
- 2.0 的币 [`0x2060a91729203CbcB20793c231F05a2d298418bD`](https://testnet.bscscan.com/address/0x2060a91729203CbcB20793c231F05a2d298418bD)

每个币先买入，再卖出四分之一。卖出走的是多跳路由合约 [`0x00BA13e28e99Ad7cb1821A95A63addD3001134db`](https://testnet.bscscan.com/address/0x00BA13e28e99Ad7cb1821A95A63addD3001134db)：卖出所得先到路由合约，由它交给下一跳（这里是转回卖家），金额等于 `trySell` 报价，路由合约上不留余额。剩下的照第一次验收的方式卖出：一半经适配合约卖出并收 1% 路由费，另一半直接卖出。另外 Gateway 买入了 3.0 的币。

读链复核：3.0 的 BNB 余额为 0；3.0 名下这两个老币的余额都是 0；3.0 给 1.0、2.0 的 WBNB 授权都是 0。

## 第三次升级：上线前的最终审计修复

上线前又做了一轮全新的独立审计，分合约、部署和升级流程两路进行。合约这一路改了一处：`setRouter` 现在只接受合约地址。其余修复都在部署脚本和升级脚本里，详见 spec 的 §5 和 §6。

这次升级用的是新版升级脚本，它会在模拟里用这次的构建现场部署一份参照实现合约，和新实现逐字节比对。
- 新实现 [`0x64625481aFEf2705f779dc58E7316694A91473Eb`](https://testnet.bscscan.com/address/0x64625481aFEf2705f779dc58E7316694A91473Eb)，升级交易 [`0x6d25ba02…5852`](https://testnet.bscscan.com/tx/0x6d25ba02d206697aa95512aa1c9a0b5656dc28be9502f72f6e8c87cca54d5852)，记录在 `broadcast/UpgradeGangLaunchpad3.s.sol/97/run-1793693421984.json`。
- 升级前后比对了 3 个币的记录，结果一致。
- 升级后只读重跑阶段 2，`self-check ok`。实现合约的代码与参照合约逐字节一致，库也对得上。
- 升级后跑了验收（3.0 的币和 2.0 的币，包括多跳卖出），20 笔交易全部成功，记录在 `broadcast/GangLaunchpad3TestnetAcceptance.s.sol/97/run-1793693488007.json`。

## 模块套装（2026-11-03）

和主网一样，3.0 有自己的一套模块（`docs/MAINNET-GANG-LAUNCHPAD-3-MODULES-2026-11-03.md`）。测试网上部署钱包同时持有 handler 和 admin，脚本自己发了 Safe 那部分交易。脚本都带 `GANG_PAD3=0x0508232833aE6849c03b28F7aA248BBd5cFCceE2`，后四个再带 `HANDLER_ADMIN`。

| 合约 | 地址 |
|---|---|
| GangHandlerAdmin | [`0x0fb8280B88a4DF00e8654cfE9cBd544D104a9D23`](https://testnet.bscscan.com/address/0x0fb8280B88a4DF00e8654cfE9cBd544D104a9D23)（已持有 handler `0x4C57…d228`） |
| GangBuybackSplitterFactory | [`0x3533E63EF0386adfBC96227C50f1b82EEA18d110`](https://testnet.bscscan.com/address/0x3533E63EF0386adfBC96227C50f1b82EEA18d110) |
| GangSplitModuleFactory | [`0xf8d4FA57FD65Bf16427Eef653518811fFa2606dc`](https://testnet.bscscan.com/address/0xf8d4FA57FD65Bf16427Eef653518811fFa2606dc) |
| GangLiquiditySplitterFactory | [`0x4A3aC160eAF4A2747046b119631988D5D8056B07`](https://testnet.bscscan.com/address/0x4A3aC160eAF4A2747046b119631988D5D8056B07) |
| GangComboSplitterFactory | [`0xdc1687961c8aAf5A0340c1A73b604cf3a2be543C`](https://testnet.bscscan.com/address/0xdc1687961c8aAf5A0340c1A73b604cf3a2be543C) |
| GangBond | [`0xa87727dc3CC28a44709649A22aDbD77287B99fc1`](https://testnet.bscscan.com/address/0xa87727dc3CC28a44709649A22aDbD77287B99fc1) |

测试网没有 GANG，Split 和 Combo 的 `gangQuote` 为 0。读链核对：四个工厂和 bond 的 `pad()` 都是 3.0，`isFactory` 都为真。

组合模块验收（`script/ComboTestnetAcceptance.s.sol`，`COMBO_FACTORY` 为上面的组合工厂）：克隆模块 `0x3a7d…8Fbe`，在 3.0 上创建测试报价币计价的税币 `0xc945…0318` 并绑定，毕业进入 Pancake 池，池子买卖收税，卖出的 swap-back 付给模块。326 笔交易里，最后一笔 forge 发出的 `split()` 因为 gas 上限偏低报 `PushStarved`（已知情况），改用节点估算 gas 重发后成功：30% 回购、30% 加池留出，其余 70 / 30 付给部署钱包和 B，金额与报价一致。之后用 `sweep()` 收回了临时钱包剩下的 gas。记录在 `broadcast/ComboTestnetAcceptance.s.sol/97/`。

## 第四次升级：金库模式（Pad3Module）

规格见 spec §9。用 `script/UpgradeGangLaunchpad3.s.sol`（命令同上，`CALLERS` 不变）：

- 新实现 [`0xe042BABE90a01bE98f9135c5f9B5CCC15e91e0e3`](https://testnet.bscscan.com/address/0xe042BABE90a01bE98f9135c5f9B5CCC15e91e0e3)，它指向的模块 [`0x240d8a4faf6dE25db3373a1A79887aF00ED8Ca5C`](https://testnet.bscscan.com/address/0x240d8a4faf6dE25db3373a1A79887aF00ED8Ca5C)。升级交易 [`0xc5c6a4e0…d1db`](https://testnet.bscscan.com/tx/0xc5c6a4e0113035d51045aaa23e63152504f2cbec6b955b673e7205e9338cd1db)，记录在 `broadcast/UpgradeGangLaunchpad3.s.sol/97/run-1793710211513.json`。
- 模拟里比对了升级前后 5 个币的记录和计算结果，一致（这是第一次升级到金库模式，升级前没有金库状态可比）；实现合约和模块的代码都和参照逐字节一致，阶段 2 读回 `self-check ok`。

金库验收（`script/GangVaultLaunchpadTestnetAcceptance.s.sol`，`GANG_VAULT_PAD` = 3.0 代理，`GANG_VAULT_ROUTER` = 3.0 的 router）：25 笔交易全部成功，记录在 `broadcast/GangVaultLaunchpadTestnetAcceptance.s.sol/97/run-1793710321070.json`。测试金库 `0x206B…FEBd` 由多签角色（测试网是部署钱包）登记并加进 handler 白名单。handler 现在归模块套装的 GangHandlerAdmin，所以脚本改成也接受“handler 归部署钱包持有的 admin”，经 `admin.exec(list)` 加白。

- A 币（WBNB 计价）[`0xEeC9Bd3C1d5B52f95A35F0F2aA3D6899200854b2`](https://testnet.bscscan.com/address/0xEeC9Bd3C1d5B52f95A35F0F2aA3D6899200854b2)：经 router 买入，锁一半，释放其中四分之三，释放的部分卖出；每一步核对钱包、金库余额、`lockedOf`，以及 `walletRoom` = 1% − 余额 − 锁仓量。
- B 币（测试报价币计价，分红 40%）[`0xb7dc921AcdC54265AA26fd4C25e73251Be962518`](https://testnet.bscscan.com/address/0xb7dc921AcdC54265AA26fd4C25e73251Be962518)：锁仓和释放时，钱包和金库的分红份额都等于余额；买过毕业门槛后毕业（池子 `0xAa92…b250`），金库里剩下的币毕业后照常转回。

升级后重跑 3.0 验收（`OLD_PADS` 为 1.0 和 2.0，带 `GANG_GATEWAY`）：29 笔交易全部成功，记录在 `broadcast/GangLaunchpad3TestnetAcceptance.s.sol/97/run-1793710457177.json`。3.0 的币、经 3.0 转发的 1.0 和 2.0 的币都走了一遍：入口买入、多跳卖出、带路由费卖出、直接卖出；Gateway 也买入了 3.0 的币。

## 第五次升级：打新经入口交易

规格见 spec §2「打新」、§3。用 `script/UpgradeGangLaunchpad3.s.sol`（命令同上）：

- 新实现 [`0xcfECd267C02945BE11B8cd8C6874df7D89963a21`](https://testnet.bscscan.com/address/0xcfECd267C02945BE11B8cd8C6874df7D89963a21)，模块 [`0xe68bcde17ccfe2890aac2cf9ecd0c8c8f6894471`](https://testnet.bscscan.com/address/0xe68bcde17ccfe2890aac2cf9ecd0c8c8f6894471)；FairLogic 和 LegacyRoute 有改动，这次新部署了这两个库。升级交易 [`0x1d1c0793…cd5a`](https://testnet.bscscan.com/tx/0x1d1c0793f6a0378608b68a529d81f44f87e25c5ebedbdf96742843697e3fcd5a)，记录在 `broadcast/UpgradeGangLaunchpad3.s.sol/97/run-1793732316906.json`。
- 模拟里比对了 25 个币（含测试网上已有的打新发售），阶段 2 读回 `self-check ok`。

打新入口验收（`script/Pad3FairEntryTestnetAcceptance.s.sol`，`OLD_PADS` 为 1.0 和 2.0）：21 笔交易全部成功，记录在 `broadcast/Pad3FairEntryTestnetAcceptance.s.sol/97/run-1793732378766.json`。在 3.0、1.0、2.0 上各建一个设了门槛的 WBNB 打新，各自经 3.0 的入口：status 为 1；按 `tryBuy` 给的 `amountMsgValue` 用原生 BNB 买入，成交的数量和花费与报价一致到 wei（24 份）；卖回一半，所得等于 `trySell`，授权正好用完。

- 3.0 的发售 [`0x3aB4966ADd59292bAf4692DeeD6C2EAf8e0Bc7aB`](https://testnet.bscscan.com/address/0x3aB4966ADd59292bAf4692DeeD6C2EAf8e0Bc7aB)
- 1.0 的发售，经 3.0 转发 [`0x6Ce3DBDBFF29134EEC72F9d44b5f5b018dB10BEd`](https://testnet.bscscan.com/address/0x6Ce3DBDBFF29134EEC72F9d44b5f5b018dB10BEd)
- 2.0 的发售，经 3.0 转发 [`0x8c02c120EbE82Cf2c679B4942875eEaBd8E8de5F`](https://testnet.bscscan.com/address/0x8c02c120EbE82Cf2c679B4942875eEaBd8E8de5F)

升级后重跑 3.0 验收：29 笔交易全部成功（`broadcast/GangLaunchpad3TestnetAcceptance.s.sol/97/run-1793732455413.json`），曲线币、转发的老币、多跳卖出、Gateway 都照常。

## 第六次升级：铸币飞轮

规格见 spec §10。用 `script/UpgradeGangLaunchpad3.s.sol`（命令同上，另加 `PAD3_FLY_TOKEN_DEPLOYER=0x61efEAdD550EaAc2257d5d1A5327df82397C712f`，即测试网 V2 的 MintTokenDeployer）：14 笔交易全部成功，记录在 `broadcast/UpgradeGangLaunchpad3.s.sol/97/run-1793770459557.json`。

- 新实现 [`0xB26fAb9696E557fb7958F1B492c646d8F5ACA6c6`](https://testnet.bscscan.com/address/0xB26fAb9696E557fb7958F1B492c646d8F5ACA6c6)，模块 [`0x68bb9b004F0b62dA24b78539A155bB75841Cd2ff`](https://testnet.bscscan.com/address/0x68bb9b004F0b62dA24b78539A155bB75841Cd2ff)，飞轮模块 [`0x3Fd50Ed75F6DdCDD6615E81eAAd72f679FeD1d29`](https://testnet.bscscan.com/address/0x3Fd50Ed75F6DdCDD6615E81eAAd72f679FeD1d29)
- 飞轮税 handler [`0x2d03F8638F8D1Bcb6836670C20edE0e47d65231f`](https://testnet.bscscan.com/address/0x2d03F8638F8D1Bcb6836670C20edE0e47d65231f)，飞轮的金库 core [`0x570B68854a3117d6c4081875B74CD4563C586494`](https://testnet.bscscan.com/address/0x570B68854a3117d6c4081875B74CD4563C586494)
- 模拟里比对了 25 个币，阶段 2 读回 `self-check ok`。接线和升级在同一次运行里发出；主网这些接线由 Safe 批次完成。

铸币飞轮验收（`script/Pad3FlyTestnetAcceptance.s.sol`）：9 笔交易全部成功，记录在 `broadcast/Pad3FlyTestnetAcceptance.s.sol/97/run-1793770522978.json`。发售 [`0x58fDC010FCaE18fB1E8D277BA23D8eA6c3114dd4`](https://testnet.bscscan.com/address/0x58fDC010FCaE18fB1E8D277BA23D8eA6c3114dd4)：kind 3，份额大小 100,000，在共享金库里挂在飞轮的 core 下，门槛 1,000；经入口用 BNB 买入、卖回一份，数额和 `tryBuy`、`trySell` 一致；再用 V2 自己的 `mint`、`withdraw`，基线和金库份额一致。开盘要 3,000 份，来自多个 Agent 钱包，由主网 fork 测试覆盖（`test/fork/Pad3FlyUpgradeFork.t.sol`）。

升级后重跑已有模式的验收，全部成功：

- 3.0 验收（`OLD_PADS` 为 1.0 和 2.0，带 `GANG_GATEWAY`）：29 笔，`broadcast/GangLaunchpad3TestnetAcceptance.s.sol/97/run-1793770589306.json`
- 打新入口验收（`OLD_PADS` 同上）：21 笔，`broadcast/Pad3FairEntryTestnetAcceptance.s.sol/97/run-1793770678645.json`
- 金库验收（`GANG_VAULT_PAD` = 3.0 代理，`GANG_VAULT_ROUTER` = 3.0 的 router）：25 笔，`broadcast/GangVaultLaunchpadTestnetAcceptance.s.sol/97/run-1793770805959.json`

## 第七次升级：推广分成

规格见 `docs/SPEC-PROMOTER-SHARE-2026-11-04.md`。用 `script/UpgradeGangLaunchpad3.s.sol`（命令同上，另加 `PAD3_FLY_HANDLER`、`PAD3_FLY_VAULT_CORE`、`PAD3_FLY_TOKEN_DEPLOYER`，都是上一次升级的地址）：9 笔交易全部成功，记录在 `broadcast/UpgradeGangLaunchpad3.s.sol/97/run-1793819517506.json`。

- 新实现 [`0x25BB52143e2805BD4a7fb653Ba89f0C7eF907C85`](https://testnet.bscscan.com/address/0x25BB52143e2805BD4a7fb653Ba89f0C7eF907C85)，模块 [`0xA03aD2A58617aca65478D46c25B5920B50Af9078`](https://testnet.bscscan.com/address/0xA03aD2A58617aca65478D46c25B5920B50Af9078)，升级交易 [`0x2e8dfe7d…7c80`](https://testnet.bscscan.com/tx/0x2e8dfe7d3fc8b79e4c00615d4fed3fe41866c7e9f573aab967e078b494837c80)。
- 模拟里比对了 25 个币的记录和计算结果，一致；实现合约和模块的代码都和参照逐字节一致。

推广分成验收（`script/Pad3PromoteTestnetAcceptance.s.sol`）分四步，因为脚本内部的检查只在模拟里运行，上链后要单独读链：

1. `run`：23 笔交易全部成功，`broadcast/Pad3PromoteTestnetAcceptance.s.sol/97/run-1793819585393.json`。分成币 [`0x8eC7B7fb5e92Ca5194c1238ad47BbA107a67B9F3`](https://testnet.bscscan.com/address/0x8eC7B7fb5e92Ca5194c1238ad47BbA107a67B9F3)（20%，7 天），普通币 [`0x021B934cBEbae1E6E8FBd3185b1a414f4e20de06`](https://testnet.bscscan.com/address/0x021B934cBEbae1E6E8FBd3185b1a414f4e20de06)。
2. `verify`（只读）：条款、绑定、合约调用被拒（`TraderNotOrigin`）和手续费账本，读链核对都通过，账本和模拟逐 wei 一致：推广人 6,280,542,512,184 wei，creator 39,122,170,048,738 wei；普通币的 creator 拿到完整的 70%，即 7,000,000,000,000 wei。
3. `claim` 和 `verifyClaim`（只读）：推广人和 creator 都领到了对应的金额，账本清零。
4. `sweep`：一次性钱包的余额退回部署钱包。

绑定的首次买入是 [`0x22b9f208…6a5f`](https://testnet.bscscan.com/tx/0x22b9f208a4f43d08043308f8cf5cd66b7d5b062199a90317ac397353e7d06a5f)。

升级后重跑已有模式的验收，全部成功：

- 3.0 验收（`OLD_PADS` 为 1.0 和 2.0，带 `GANG_GATEWAY`）：29 笔，`broadcast/GangLaunchpad3TestnetAcceptance.s.sol/97/run-1793819765911.json`
- 打新入口验收（`OLD_PADS` 同上）：21 笔，`broadcast/Pad3FairEntryTestnetAcceptance.s.sol/97/run-1793819875246.json`
- 铸币飞轮验收：9 笔，`broadcast/Pad3FlyTestnetAcceptance.s.sol/97/run-1793819963405.json`
- 金库验收（`GANG_VAULT_PAD` = 3.0 代理，`GANG_VAULT_ROUTER` = 3.0 的 router）：25 笔，`broadcast/GangVaultLaunchpadTestnetAcceptance.s.sol/97/run-1793820045884.json`

这次升级之后，源码只撤回了 `IGangLaunchpad.sol` 里的一句注释（模块工厂的源码树里有它，见推广分成规格 §6），并在 `IGangPromote.sol` 补了一句注释。合约逻辑没变，但测试网上的实现和最终源码差元数据哈希。

## 推广分成延续到外盘（2026-11-05）

规格：`docs/SPEC-PROMOTER-POOL-SHARE-2026-11-05.md`。部署在已升级的测试网 3.0 上：

| 合约 | 地址 |
|---|---|
| GangPromotePoolModuleFactory | [`0x7a68A65d27591a21C44f91015F930422BA79F1c2`](https://testnet.bscscan.com/address/0x7a68A65d27591a21C44f91015F930422BA79F1c2) |
| 模块实现 | [`0x2d31A432A3717fE6B9DB84d958091606CbD3BD16`](https://testnet.bscscan.com/address/0x2d31A432A3717fE6B9DB84d958091606CbD3BD16) |
| 验收用的模块 | [`0x1E1b4c56334A5612E8097fDed18135f2745D33DC`](https://testnet.bscscan.com/address/0x1E1b4c56334A5612E8097fDed18135f2745D33DC) |
| 验收用的代币 | [`0xa51C0F4dC49754C9F8aF535E52D342Ed357DdE9F`](https://testnet.bscscan.com/address/0xa51C0F4dC49754C9F8aF535E52D342Ed357DdE9F)（买税 2%、卖税 4%、分红 20%、分成 20%、有效期 7 天） |

验收（`script/PromotePoolTestnetAcceptance.s.sol`）：

- 真实 pad、handler 和 Pancake 交易对上，从建币、内盘绑定、毕业到外盘 2 笔买入和 6 笔卖出全部上链。
- 结算：`scripts/promote-settle/settle.mjs` 对真实节点算出的金额，和另一份独立写的先进先出计算一致，精确到 wei。推广人 1231862562865088，dev 967934423293402，合计等于托管 2199796986158490。
- 先发布一个错误的 root 并由 owner `veto`，再用同一区块发布正确的 root；`--check` 不带 `--prev` 从头复算，和链上一致。
- 第一次 `work` 回滚 `PushStarved`：forge 按模拟用量估 gas，不够。这是预期行为，见规格 §6；之后用 `--gas-estimate-multiplier 500` 成功。
- 争议期是真实的 2 天，所以领取在本地分叉上验证：争议期内领取回滚，到期后推广人和 dev 都领到准确金额，模块清零；第二期 `--prev` 结算、发布、`--check` 和领取都正确。真实链上的领取要等争议期结束。

## CLI 0.31.0 的推广分成（2026-11-05）

用 `gang … --testnet --calldata` 生成交易，再用 `cast send` 发到测试网（`baw` 不支持测试网）：

- 带税发币 [`0x85895787e6D6c6BBB52C04B35b538FEE5EA7546E`](https://testnet.bscscan.com/address/0x85895787e6D6c6BBB52C04B35b538FEE5EA7546E)：`--promote` 依次走完克隆模块 [`0x7d16Ff6E27122e671B2D487Bf8ebd12850746A80`](https://testnet.bscscan.com/address/0x7d16Ff6E27122e671B2D487Bf8ebd12850746A80)、建币、`bind`；`gang buy --promoter` 用 BNB 买入并绑定，`gang promote claim` 领到准确金额。
- 无税、其他计价币 [`0xEaCe59BEaE31B89975c84Af6F573CcF9C98763Ea`](https://testnet.bscscan.com/address/0xEaCe59BEaE31B89975c84Af6F573CcF9C98763Ea)：只有内盘分成，走授权后买入，在同一计价币里领取。
- `gang promote claim-pool`（激活 root、领取、拒绝错误金额、手动给 `--cumulative` 和 `--proof`）只在本地分叉上验证，用假的 gang.fun 接口；真实链上的领取要等验收模块的争议期结束。
