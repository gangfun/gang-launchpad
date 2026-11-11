# 测试网记录 · GangFloorModule（底价赎回收款模块，`floor-v1`）

- 日期：2026-11-11 Asia/Shanghai
- 网络：BSC 测试网（97），GangLaunchpad 3.0 代理 `0x0508232833aE6849c03b28F7aA248BBd5cFCceE2`，abcd 部署器 `0xB9c2CD0A9cDD118105E5c146D9235F4086164D84`（已启用）
- 规格：`docs/SPEC-FLOOR-MODULE-2026-11-11.md`
- 部署前：一轮独立审查（1 个中危、3 个低危，已处理）和一轮对修复的独立复审（无低危及以上遗留），见规格 §12、§13。没有外部审计
- 结论：部署和整轮合约验收通过。封顶前的赎回、收款人拿满上限、封顶后的赎回，金额都和合约规则逐 wei 一致，底价两次赎回后都上升
- 没做：CLI、keeper、服务端、网站都还没有对接，本次只验收合约

## 部署

| 项 | 地址 / 交易 |
|---|---|
| GangFloorModuleFactory | [`0x0804C018201D8fFe378b873b41B67f136dbdc3F8`](https://testnet.bscscan.com/address/0x0804C018201D8fFe378b873b41B67f136dbdc3F8)，区块 142099242，部署 [`0x2bbba285…00e1`](https://testnet.bscscan.com/tx/0x2bbba2850f53374fca3415358c6fda9bfd736eda939922430acd3a26fa2500e1) |
| 实现合约 | [`0x5B4212095A81672BF3889B7AF9abEd11A41aca70`](https://testnet.bscscan.com/address/0x5B4212095A81672BF3889B7AF9abEd11A41aca70)，`pad()` = 3.0，`gangQuote` = 0（测试网没有 GANG） |
| `admin.setFactory(factory, true)` | 3.0 的 GangHandlerAdmin `0x0fb8280B88a4DF00e8654cfE9cBd544D104a9D23`，区块 142099247，[`0x566e4096…cfc6`](https://testnet.bscscan.com/tx/0x566e4096525642b1765b4ba1294e874e4b7d19112e87478d7b1736a81174cfc6)。测试网由 owner 钱包直接执行，主网是多签 |
| 部署脚本检查 | 接线检查和运行时字节码比对在模拟阶段通过；部署后 `isFactory` = true |

记录：`broadcast/DeployGangFloorModuleFactory.s.sol/97/`。

## 验收：合约（`script/FloorTestnetAcceptance.s.sol`，再按 keeper 的方式发 `split`）

dev = 部署钱包。上限 0.001 测试报价币，封顶前 50% 给收款人（部署钱包 70%、一次性钱包 B 30%），其余进金库，赎回手续费 2%。报价币 MockSPCXB `0x02B3…F1c`（QuoteRegistry 里有，`keeperServes` = true）。币的买卖税 3%，分红 40%。

毕业用的一次性钱包沿用封顶模块验收的那一批（同一个派生标签，已注册 Agent），没有新钱包。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 发币前算出代币地址 | `0x5131B3147505c14CFb4e48ff0EeaD8471ec3ABcd`，此时地址上没有合约 | 无 |
| 为这个地址克隆模块 | [`0xc12a6c9A0a266Aa781ddd5a3FB7482B4c8Fe95A0`](https://testnet.bscscan.com/address/0xc12a6c9A0a266Aa781ddd5a3FB7482B4c8Fe95A0)，地址等于 `predict`；`floorToken` 是上面的地址，`token()` 仍为 0；上限、比例、手续费、收款人写入正确 | [`0x48302651…89f3`](https://testnet.bscscan.com/tx/0x4830265117897c40dd0833d021b9da3dda9df4e2dde111007ca2c50709b589f3) |
| `createWithSalt` 建币 FLRT（收款 = 模块） | [`0x5131B3147505c14CFb4e48ff0EeaD8471ec3ABcd`](https://testnet.bscscan.com/address/0x5131B3147505c14CFb4e48ff0EeaD8471ec3ABcd)，和预先算出的地址一致 | [`0xb61ff56b…7c4c`](https://testnet.bscscan.com/tx/0xb61ff56bb3d0a54dc7faa451bfd44a890f5302810a91df4a2b02b1f2625f7c4c) |
| `bind` | `token` / `quote` 写入 | [`0xc45df048…c071`](https://testnet.bscscan.com/tx/0xc45df0489258715cdba10ce3ffc2fb3f5189dd1fca97bf38661ea192a4dcc071) |
| 毕业、池子交易交税 | 一次性 Agent 买到毕业；交易对 [`0x3E7C…dBc3`](https://testnet.bscscan.com/address/0x3E7CAc351E813CFeba820244AC035fCEe635dBc3)；卖出时的 swap-back 付给模块 0.007868026816606558 | 327 笔全部成功，区块 142099832–142101226 |
| 拆分之前赎回 3,365,196.336456469102010738 枚 | 开头的拆分把收款人的份额记入上限并留在 `payeesPending`：按 50% 本该 0.003934…，只记到上限 0.001，`capReached` = true；金库 0.006868026816606558。持有人到手 0.000022650013508291，手续费 0.000000462245173638 留在金库，和 `previewRedeem` 一致。代币全额进 0xdead（没有收税）。收款人 B 的余额没变，没有人被推送，也没有欠款。实际用 gas 269,930 | [`0x80f85ef4…dece`](https://testnet.bscscan.com/tx/0x80f85ef445392a0aa0966486dad877fa37fdde972f1301668787f1bb0259dece) |
| 读回 | 模块余额 0.007845376803098267 = 金库 0.006845376803098267 + `payeesPending` 0.001；`previewWork` 到期 | 无 |
| `split()`（`cast send`，gas 由节点估算） | 推送预留的 0.001：B 收到 0.0003，部署钱包 0.0007；`payeesPending` 归零；`previewWork` 不再到期。实际用 gas 97,157 | [`0x6364de75…f969`](https://testnet.bscscan.com/tx/0x6364de757c8416c4962b09e4493063aeff560f0e2ae6d119faac5350acf1f969) |
| 封顶后再赎回 5,047,794.504684703653016107 枚（`--sig "finish()"`） | 到手 0.000033977314635727，手续费 0.000000693414584402，和预览一致；金库和流通量按数扣减。实际用 gas 167,997 | [`0xe3b06ffe…9412`](https://testnet.bscscan.com/tx/0xe3b06ffe2452f4e24c40bf6593988022b7e662968905e084fdcc43bfb15f9412) |
| 最终读回 | 模块余额 = 金库 0.006811399488462540，没有预留、欠款和未拆分；`paidTotal` = `capAmount` = 0.001；0xdead 里有 8,412,990.841141172755026845 枚 | 无 |
| 收回一次性钱包剩下的 gas | 0.0062817719 tBNB 回到部署钱包 | `--sig "sweep()"` |

### 每枚底价（`floorPrice()`，每 wei 代币对应的报价币 wei × 1e18）

| 时点 | 值 |
|---|---|
| 第一次赎回前 | 6,868,026 |
| 第一次赎回后 | 6,868,490 |
| 第二次赎回后 | 6,869,189 |

两次赎回后都上升，升幅来自留在金库的手续费。

### gas 的说明

`split()` 用 `cast send` 发，没有放进 forge 脚本：脚本给的 gas 上限低于合约每次推送前要求的约 36.5 万（`PUSH_GAS × 64/63 + PUSH_RESERVE`），会回滚 `PushStarved`，封顶模块验收时遇到过。赎回不推送收款人，没有这个要求，所以两笔赎回直接由脚本发出。

## 验收二：CLI（分支上的 `skill/gang-cli`，测试网工厂已内置）

CLI 生成交易（`--calldata`），`cast send` 发出，gas 由节点估算。dev = 部署钱包，报价币 MockSPCXB。

### 带收款人的发射

`gang create --name "Floor CLI Test" --symbol FLCT --buy-tax 3 --sell-tax 3 --dividend 40 --quote <MockSPCXB> --floor --redeem-fee 2 --tax-cap 0.0005 --tax-cap-share 50 --split self:70,B:30`，同一条命令跑四次。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 第 1 次：克隆模块 | CLI 先上传元数据、算出代币地址 `0xb504…abcd`，再为它克隆模块 [`0x4fEB0AbfCD691D3E96491AA3bf975C60acb17cfD`](https://testnet.bscscan.com/address/0x4fEB0AbfCD691D3E96491AA3bf975C60acb17cfD)。预览里有代币将来的地址、元数据地址、上限和收款人、封顶前后进金库的成交额比例（0.75% / 1.5%） | [`0xaede2984…bc66`](https://testnet.bscscan.com/tx/0xaede298427f95e41067b59d785939e25f234170d1a7dee1cabf1cf6fc08fbc66) |
| 中途把 `--buy-tax` 改成 4 再跑 | 拒绝：模块是为 3% / 3% 的代币克隆的，税率决定代币地址 | 无 |
| 中途把 `--redeem-fee` 改成 1 再跑 | 拒绝：和链上模块的设置不一致 | 无 |
| 第 2 次：建币 | 用第 1 步的 salt 和元数据；建币前向 pad 模拟一次，返回地址和计划的一致。代币 [`0xB504EFCcC556c4706C4416cD58671fB0047BaBCd`](https://testnet.bscscan.com/address/0xB504EFCcC556c4706C4416cD58671fB0047BaBCd) 落在预先算出的地址上 | [`0x2ad42b26…71b2`](https://testnet.bscscan.com/tx/0x2ad42b26e7ac36006db7b6d389999156911f42883822d47d9863f2ff3e2871b2) |
| 第 3 次：绑定 | `token()` 写入 | [`0x8bf39e56…3101`](https://testnet.bscscan.com/tx/0x8bf39e563c7a8e18e9eeee0b8cfea2ffb41d4ab9ccba3689874d752296c13101) |
| 第 4 次 | 只报告：发射完成 | 无 |
| 转进 0.0006，`gang floor distribute` | 收款人 0.0003（部署钱包 0.00021、B 0.00009），金库 0.0003，和预览一致 | [`0x8e255952…e312`](https://testnet.bscscan.com/tx/0x8e25595226b8827dcb76564ac2fdf4f45511281a0420e1581fb0eb7e449ee312) |
| 再转进 0.0004，`gang floor distribute` | 收款人 0.0002（0.00014 / 0.00006），正好用完上限，预览标出 `reachesCap` | [`0x185c24c0…2438`](https://testnet.bscscan.com/tx/0x185c24c0370ed38a95e53883629bc8741842838f03f10b37242a1e8b8ff32438) |
| 毕业前 `gang floor redeem` | 拒绝：还没毕业 | 无 |

### 赎回（在验收一的 FLRT 上）

`gang floor redeem --token <FLRT> --amount 1000000`：预览到手 0.000006731806121942、手续费 0.000000137383798406，并提示同样的代币在池子里卖出约得 0.0449，是赎回的约 6,600 倍，赎回是亏的。发出后实际到账 0.000006731806121942，和预览逐 wei 一致；100 万枚全部进 0xdead。交易 [`0x6d02d7eb…48db`](https://testnet.bscscan.com/tx/0x6d02d7ebc8ca6d4fd29cfbb1e34230b496535e4f9d255d4ddd1ee116f11b48db)，gas 167,949。

### 没有收款人的发射

`gang create --name "Pure Floor Test" --symbol PFLT --buy-tax 2 --sell-tax 4 --quote <MockSPCXB> --floor --redeem-fee 0`：克隆 [`0xe67707f8…8769`](https://testnet.bscscan.com/tx/0xe67707f8ee9a14d3c651e1b2cab13957a6dd75496311027bf3098ea279e68769)（模块 `0xFd0723f4e23E71206f855F56b9D1150f733dfF0a`）、建币 [`0x61ca3f00…e359`](https://testnet.bscscan.com/tx/0x61ca3f002351145e749de9608ae2274dbb36b6396de8fc79bec40fffbd16e359)（代币 `0x0CB3F862cDB0f4f1D33794c40cAFd1c15F68AbcD`，和预先算出的一致）、绑定 [`0x38d480d9…87e9`](https://testnet.bscscan.com/tx/0x38d480d9ec3cd4d7eda99200e82818171563c4107c46d32bf4b958afb6dc87e9)。读回：没有上限和收款人，手续费 0，模块由工厂创建（`verified`）。

### 发币前拒绝（不发交易）

没带税、和 `--buyback` / `--lp` / `--after-cap` / `--recipient` 同用、`--redeem-fee 6`、只给 `--redeem-fee`、不带 `--tax-cap` 却给 `--split` 或 `--tax-cap-share`、`--dividend 100`、打新或铸币飞轮加 `--floor`、主网（工厂还没有）：都在发交易之前拒绝。

### 审查修复后的复测

CLI 经过三轮独立审查（规格 §14）。第一轮修复改动了发射流程里“找本次建的币”和“建币没发出时怎么办”两处，所以又完整走了一遍：`gang create --name "Floor Recheck" --symbol FLRC --buy-tax 3 --sell-tax 3 --quote <MockSPCXB> --floor --tax-cap 0.001`。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 克隆模块 | 模块 `0xA86E54CB0D270d6B9047d6222Fc37144d8Ef74b8`，代币将来的地址 `0xe052…abcd` | [`0xf971bc3a…af28`](https://testnet.bscscan.com/tx/0xf971bc3a114915419a5797be3794097c2afcb7af68bf59c9d1577baead07af28) |
| 生成建币但不发出，再跑两次 | 每次都重建同一笔建币（同一个 salt），不再提示 `--restart` | 无 |
| 发出建币 | 代币 `0xe05279138b4100517B068C33c113fF824c80aBcd` 落在计划的地址上 | [`0x34b95e50…233a`](https://testnet.bscscan.com/tx/0x34b95e500486c6d48c327c8f57da7b0388afab0f367af0e085e8077c9ff8233a) |
| 绑定 | 发射完成，模块由工厂创建（`verified`） | [`0xdfee1fc2…a17f`](https://testnet.bscscan.com/tx/0xdfee1fc2c65eb6746e3581cc2d5a048c2563bb9a37dba48b20e40d09484ca17f) |
| 手写 `--recipient <验收一的底价模块>` 建币（只读） | 在上传和生成交易之前拒绝：底价模块不能手写 | 无 |

第二、三轮的修复没有再上链复测，由本地测试覆盖（`skill/gang-cli/test/floor.mjs`、`floor-launch.mjs`）。

## 本次没测到

- keeper 的 `work`、服务端索引、网站展示：都还没有对接。
- CLI 里 bond 守卫（赎回会破坏 dev 的 bond 时拒绝）、`gang tx` 按模块类型解码、未验证模块只显示警告：只有本地模拟节点的测试，没有上链验证。
- WBNB 报价；纯底价模块毕业后的赎回（只验收了发射）。
- 收款人拒收后记欠款和 `release`、换收款人、报价币短缺、其他资产打进 0xdead：单元测试和模糊测试覆盖（`test/gang/GangFloorModule.t.sol`、`GangFloorModulePending.t.sol`）。
- “市价跌破底价时买入再赎回有正收益”：要真实池子的价格，留给主网分叉测试。
- 部署脚本里只在主网生效的检查（3.0、admin、多签 owner、`gangQuote`、abcd 部署器已启用）。主网还没有启用 abcd 部署器，分叉测试也还没做。
