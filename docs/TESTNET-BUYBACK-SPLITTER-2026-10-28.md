# 测试网 · GangBuybackSplitter（dev 税按比例回购销毁）

第 10 套内盘上跑了两版：

| 版本 | 接入方式 | 本文 |
|---|---|---|
| 第二版（现行：管理合约 `0xBc2d…9a4d`、工厂 `0x08b9…a87D`，v2 回购模块带收款地址） | GangHandlerAdmin 接管 handler 的 owner，dev 用 CLI `gang create … --buyback <pct>` 自己克隆回购合约（工厂在同一笔交易里加白），keeper 走通用的 `previewWork` / `work` | 第一部分 |
| 第一版 | 每个 dev 由平台部署一个回购合约，多签逐个 `list` 和 `setExcluded` | 第二部分（保留作记录；回购合约 `0xB43b…c0C9` 仍在白名单上，但不在 `modules()` 里，新 keeper 不管它） |

- 链：BSC 测试网（chainId 97），2026-10-28
- 规格：`docs/SPEC-BUYBACK-SPLITTER-2026-10-28.md`
- 发交易：`cast send --legacy --gas-price 0.1gwei`（原因见 `docs/TESTNET-GANG-BOND-2026-10-28.md`「gas」）；CLI 步骤用 `--calldata --from` 取出交易，cast 签名发送

# 第一部分 · 第二版：管理合约 + 工厂 + CLI

## 部署（`script/DeployGangBuybackSplitterFactory.s.sol`）

| 项 | 值 |
|---|---|
| GangHandlerAdmin | [`0x4FcF8C9F7e43987A9080C832Aadf95F40f4ca2a3`](https://testnet.bscscan.com/address/0x4FcF8C9F7e43987A9080C832Aadf95F40f4ca2a3)，owner = `0xCa8e…00b6`（第 10 套 owner），handler = `0xe190…Ca7c` |
| GangBuybackSplitterFactory | [`0x2EBecb75D7C929912800f12ef7b52A63A14CA80E`](https://testnet.bscscan.com/address/0x2EBecb75D7C929912800f12ef7b52A63A14CA80E)，实现合约 `0x220D7dd2A0C16df599d6Cdef60Ebd8cb3340EEef` |
| 部署 | admin [`0xb128d292…0fb3`](https://testnet.bscscan.com/tx/0xb128d2923d341f33a1d43ca4dcdaf99e9ece483dd836b44dbdd4a009b5630fb3)（gas 636,160）、工厂 + 实现 [`0x8a0d207c…8c18`](https://testnet.bscscan.com/tx/0x8a0d207cf80693e5a2a30bd24494d6de58cbfba85f9f6fa15a0bafec62e68c18)（gas 2,381,506） |
| 批量（测试网由 owner 钱包直接执行，主网是多签） | `handler.transferOwnership(admin)` [`0x9f022d40…f2b5`](https://testnet.bscscan.com/tx/0x9f022d40f521c947b36cbad981ea8091b98e311f53e6690a66741b5eb4f0f2b5)、`admin.exec(acceptOwnership())` [`0x9c808002…ed41`](https://testnet.bscscan.com/tx/0x9c80800206bf418493185420212702dc1f0cd7b81894c0e4b421aa958e99ed41)、`admin.setFactory(factory, true)` [`0x1fcfe132…574b`](https://testnet.bscscan.com/tx/0x1fcfe1324b48df33f27aa350b46f3a89376bdbf9e2bb0b51300711e150d4574b) |

这是第一个管理合约和工厂（下称 v1）；审查后加了分页和确定性克隆，换成了下一节的 v2。

## 换新版管理合约（v1 → v2，现行）

| 项 | 值 |
|---|---|
| GangHandlerAdmin v2 | [`0xBc2d7A1f2E86A7586f31A324aDaE3d38bFd49a4d`](https://testnet.bscscan.com/address/0xBc2d7A1f2E86A7586f31A324aDaE3d38bFd49a4d)（加了 `modulesFrom`），owner = `0xCa8e…00b6` |
| GangBuybackSplitterFactory v2 | [`0x71e997B0d9eBa9678eD3d8C57622009a190d2a87`](https://testnet.bscscan.com/address/0x71e997B0d9eBa9678eD3d8C57622009a190d2a87)（`create(bps, salt)` / `predict`），实现合约 `0xEaB21041e9160594ddC348099e376a6ddA45aDf5`；已被 v3 工厂取代并停用（见「v3 工厂」一节） |
| 部署 | admin [`0xa13f98ee…1b16`](https://testnet.bscscan.com/tx/0xa13f98eefdc30c518dbc351e515fd33ec464e13105a38ecfee68ca9825561b16)（gas 707,758）、工厂 + 实现 [`0xbb5c85f7…0ad1`](https://testnet.bscscan.com/tx/0xbb5c85f7bd8a7013fb3d2055a73082f470499729ff7b18c44a1065690b6d0ad1)（gas 2,413,583） |
| 迁移批量（脚本识别出 handler 在 v1 管理合约手里） | `adminV1.exec(transferOwnership(adminV2))` [`0x772c37a9…1e2f`](https://testnet.bscscan.com/tx/0x772c37a91179987fb870bff2931192de978e0036fcf37570a5ca4625a8652e1f)、`adminV2.exec(acceptOwnership())` [`0x3ea96bd6…e557`](https://testnet.bscscan.com/tx/0x3ea96bd699297abeb9dd69badaf88f82c8c424a065c903f76d6d8dcaad10e557)、`adminV2.setFactory(factoryV2, true)` [`0x358d945d…edcf`](https://testnet.bscscan.com/tx/0x358d945d5d9e893a205c05bc52230a6e568890141803cec8dc2476004438edcf) |

v1 工厂克隆的 `0xBCb5…8A39`（BBFT）仍在 handler 白名单上、照常收税，但不在 v2 的 `modules()` 里：keeper 要服务它就用 `MODULES` 补上（下文 keeper 一节就这么测的）。v1 工厂已经不能再加白（handler 不归 v1 管理合约了）。

**第 10 套 handler 的 owner 现在是 GangHandlerAdmin v2。** owner 钱包对 handler 的管理操作（list / delist、换 keeper 等）要经 `adminV2.exec(<calldata>)`。交回：`adminV2.exec(transferOwnership(0xCa8e…00b6))`，再由 owner 钱包调 `handler.acceptOwnership()`（交回后工厂就不能再加白，CLI 的 `--buyback` 在测试网上会失败）。

## CLI 一键发射（`gang create … --buyback 50`，v1 工厂）

```
gang create --name "Buyback Factory Test" --symbol BBFT --buy-tax 3 --sell-tax 3 --dividend 50 --buyback 50 --dev-buy 0.5 \
  --quote 0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c --testnet --calldata --from 0xCa8e…00b6
```

同一条命令跑了 5 次：

| `launch.stage` | 结果 | 交易 |
|---|---|---|
| `buyback-splitter` | 克隆回购合约 [`0xBCb5334145535502aC819903B0a0304fF5CE8A39`](https://testnet.bscscan.com/address/0xBCb5334145535502aC819903B0a0304fF5CE8A39)（50%），同一笔里加白，gas 347,453 | [`0xcb284f3e…7129`](https://testnet.bscscan.com/tx/0xcb284f3e122e269cd5960c024143921d886dc4491f0a9d00253151de8c4a7129) |
| `create` | BBST 之后的新币 BBFT [`0x25EFfB4D210AfEa703258222f50D9CF28b72Dc46`](https://testnet.bscscan.com/address/0x25EFfB4D210AfEa703258222f50D9CF28b72Dc46)，route 的 recipient = 回购合约，gas 1,710,223 | [`0xfa607316…9610`](https://testnet.bscscan.com/tx/0xfa6073167e345ac0523712b8710491196039fc81d5138d1e6be750c4bc599610) |
| `bind` | gas 103,462 | [`0x7d431e13…d29b`](https://testnet.bscscan.com/tx/0x7d431e13ce56be2d238f78543392f4457b0f93621507c840ab00610fd9afd29b) |
| `dev-buy` | 买到 1% 上限 | [`0x0b7d1ca1…4e44`](https://testnet.bscscan.com/tx/0x0b7d1ca1f7565efea4db91314e5ca44804787daa4ff9eac43597ae20312e4e44) |
| `done` | 报告里带 `buyback`（回购合约、比例、待回购金额） | — |

`gang v3 info --token 0x25EF…Dc46` 的 `recipientLabel` 是 `buyback-burn-v1`，并在 `buyback` 下给出同样的状态。

比例（`gang buyback …`）：

| 命令 | 结果 | 交易 |
|---|---|---|
| `set --pct 60` | 立即生效 | [`0x314a8b58…1e52`](https://testnet.bscscan.com/tx/0x314a8b5857361ea1d95a99e5b7526fed889390e790bfeafb4df9c7f8c7fe1e52) |
| `set --pct 40` | `ask-cut`：`pendingCut` = 40%，10-31 10:27 起可执行、11-07 作废 | [`0x0bc517c7…c8d2`](https://testnet.bscscan.com/tx/0x0bc517c7a11b852838d9a00bd3937a1309cf4505815f746dff52814c8ea4c8d2) |
| `apply` | CLI 拒绝：3 天公告期没到 | 只预览 |
| `set --pct 60` | 取消下调，`pendingCut` 为空 | [`0x91d0d6ff…ce2a`](https://testnet.bscscan.com/tx/0x91d0d6ff5160f647197a18a4a8d555156fb9b3157a8291858ce8b117aafdce2a) |
| 别的地址 `set` | CLI 拒绝：只有 dev 能改 | 只预览 |

## 毕业、交税、keeper（gangfun-server `keeper/keeper-module-work.sh`）

- 毕业：79 个测试 Agent 各买 1%，169 笔全部成功，1,947 万 gas；交易对 `0xc57f4DE5C6A0728402fbEEF08778fe80d56808e7`。买家剩下的 gas 收回（79 笔，0.004787 tBNB）。
- 交税：dev 在池子里卖 3 次各 200 万枚，`process` 卖完剩下的 6 万枚累计税（[`0xae823ed9…8127`](https://testnet.bscscan.com/tx/0xae823ed9aa59475c4db12cf5160aa826c987ecc586d43e78206c06603a778127)）。回购合约待拆分 0.005397。
- keeper（分支 `feat/buyback-burn-keeper` 的 `keeper-module-work.sh`，本机运行，`PADS=t10:…`，测试网钥匙当 keeper）：从 `handler.owner()` = admin 的 `modules()` 找到 1 个模块。

| 时间（UTC） | `previewWork` | keeper | 交易 |
|---|---|---|---|
| 10:36 | due，`minOut` 0（第一次观测） | dry-run 通过；`--broadcast` 发 `work(0)`：按 60% 拆分（回购 0.0032381），记观测点 | [`0x84d59202…ec1a`](https://testnet.bscscan.com/tx/0x84d59202a8958f1746113d2b084c87fd101424568d2583b8972d7fda5453ec1a) |
| 10:36 | not due | 不发 | — |
| 10:46 | due，`minOut` = 预览销毁量 × 99% | `work(43,862.85 枚)`：花 0.0032381，销毁 44,305.91 枚（等于预览值），回购余额清零 | [`0x5a2b0230…b689`](https://testnet.bscscan.com/tx/0x5a2b0230797e7cda4e46e3812cae28db0b4d309ad16b50f92e7db972c876b689) |
| 10:46 | not due | 不发 | — |

这一版没有从分红中排除回购合约（规格 §6）。

## v2：确定性克隆、续接规则、keeper 只在发送时加锁

CLI（内置 v2 工厂）：

| 情况 | 结果 | 交易 |
|---|---|---|
| `gang create … --symbol BBST2 --buyback 40` 第一次 | 给出 `factory.create(4000, salt)`，并提前给出地址（salt 随机、记进 plan） | 只预览 |
| 不执行就重跑 | 「the buy-back splitter is not on chain yet」，提示等待或 `--restart` | — |
| `--restart` 后执行克隆 | 回购合约 [`0xa08c7311bdd5Dc923c0012efDe197B52D942f233`](https://testnet.bscscan.com/address/0xa08c7311bdd5Dc923c0012efDe197B52D942f233)，地址等于预测值，gas 326,224 | [`0x744a3bdb…bbbd`](https://testnet.bscscan.com/tx/0x744a3bdb9e1dc96068ba0b5a352a9f30beda22c579b271b9b97329ee56dbfbbd) |
| 改成 `--buyback 30` 重跑 | 拒绝：这次启动的回购合约是 40% | — |
| 去掉 `--buyback` 重跑 | 拒绝：这次启动是带 `--buyback` 开始的 | — |
| 按原命令重跑 | 建币 BBST2 `0x631Bb7f86b6Dfa508E8C639f8431eDe9A50D0177` → `bind` → done，`buybackBps` 4000 | [`0x41c40863…e531`](https://testnet.bscscan.com/tx/0x41c408639ed978e26334b226765313acd021fcfc749704fda4adbee69fbfe531)、[`0x2eb37693…aaa1`](https://testnet.bscscan.com/tx/0x2eb37693b8d97f4d97ba2d7f7320ac98c4ed4c25b5e4ab97489593fe5b42aaa1) |
| 不带回购的启动 NBBT，建币执行后重跑加上 `--buyback 50` | 拒绝：这次启动建币时没有 `--buyback`（不会再克隆、也不会建第二个币）；按原命令重跑接着 dev 买入 | [`0xcec2d3bd…6f91`](https://testnet.bscscan.com/tx/0xcec2d3bda59d562c01042b31b42bc1b046bc01da4ed4fe7abf864990ce1e6f91)、[`0x552456a1…a494`](https://testnet.bscscan.com/tx/0x552456a1e6e01b3e99c97d4831ff041b1f6b670fbcd551d62ce664c6df0fa494) |

keeper（`7208423` 的 `keeper-module-work.sh`，macOS 自带的 bash 3.2，`MODULE_PAGE=1` 强制分页，`MODULES` 补上 v1 的 `0xBCb5…8A39`，往它铸 0.01 MockSPCXB）：

| 情况 | 结果 | 交易 |
|---|---|---|
| 扫描 | 2 个模块（v2 管理合约分页读到 1 个 + `MODULES`），扫描不加锁，1 个到点 | — |
| 发送 | 拿锁、重新 `previewWork`，`work(81,224.55 枚)`：销毁 82,045.00 枚（等于预览值），回购余额清零 | [`0x3522b4db…aba9`](https://testnet.bscscan.com/tx/0x3522b4db0af30488e2327e2a7a2d0964b53724cdbac65940a732094c39d6aba9) |
| `SCAN_MAX_SEC=0` | WARN「scan stopped after 0s at 0 / 2」，退出码 5 | — |

## v3 工厂：最低金额（`WORK_MIN_BPS`）

实现合约加了最低金额：回购余额低于交易对报价币储备的 0.05% 时 `previewWork` 不报到点。管理合约不变（v2），只换工厂：

| 项 | 值 |
|---|---|
| GangBuybackSplitterFactory v3（现行，CLI 内置） | [`0x0Ff5C8801BdeaDac374fC14fEd6e7B31977c9DA1`](https://testnet.bscscan.com/address/0x0Ff5C8801BdeaDac374fC14fEd6e7B31977c9DA1)，实现合约 `0x666429D8978167F6003792c442a8e3958C6d5997`；部署 [`0x158da28e…f691`](https://testnet.bscscan.com/tx/0x158da28ea253c1e6059e2c8dc67e158229ce7920e5c5fbcd2388f4799b5bf691)（gas 2,435,455） |
| 批量（`HANDLER_ADMIN` 已设，只有一笔） | `adminV2.setFactory(factoryV3, true)` [`0xb7aa2c37…68df`](https://testnet.bscscan.com/tx/0xb7aa2c37822ce1d1ae5d75d3d080267ffa564bf7f0df3fe34edb3cfd8b6868df)；脚本同时列出 v2 工厂仍被允许，附停用交易 |
| 源码验证 | v2 管理合约、v3 工厂和实现合约已在 BscScan 测试网验证（2026-10-28，`--verifier-url "https://api.etherscan.io/v2/api?chainid=97"`） |
| 停用 v2 工厂（可选那一笔） | `adminV2.setFactory(factoryV2, false)` [`0x5a03e66c…9caa`](https://testnet.bscscan.com/tx/0x5a03e66cf785ba6c2ba67489c7171b7b034902b8a3cb75f7d68264e29ece9caa) |

CLI 一键发射 BBFL（`--buyback 50 --dev-buy 0.5`）：克隆 [`0x28585D12C24e36425bc82cA33f55cDAe10CE24f0`](https://testnet.bscscan.com/address/0x28585D12C24e36425bc82cA33f55cDAe10CE24f0)（[`0xba053cb4…c83c`](https://testnet.bscscan.com/tx/0xba053cb4ec36c56218c2f600d7ab41da22a2fe07d195dd13a46ca9e5d9f2c83c)）→ 建币 `0x693515C0669Ef28a61a095D8c898C85C2a03C454` → bind → dev 买入 → done。毕业（171 笔，全部成功），交易对 `0x07F2…8EfB`，报价币储备 15，所以门槛 = 0.0075。

| 时间（UTC） | 情况 | `previewWork` / keeper（`ac5f142`） | 交易 |
|---|---|---|---|
| 11:13 | 铸 0.01 进回购合约（50%：回购部分 0.005 < 0.0075） | `false`；keeper「scanned 2 / 2, due 0」 | [`0xfa127004…f8bcb`](https://testnet.bscscan.com/tx/0xfa1270043a733b40ecbc6c4400991c067e0a6022b4004878fd17792fea7f8bcb) |
| 11:13 | 再铸 0.01（回购部分 0.01） | `true, 0`：keeper 发 `work(0)`（拆分、记观测点），之后又不到点 | [`0x79bcd2d2…e7a1`](https://testnet.bscscan.com/tx/0x79bcd2d2affd3777fcc0652b84f05916909d8cadc051027e778ae9074669e7a1) |
| 11:24 | 窗口满 | `work(127,635.02 枚)`：花 0.01，销毁 128,924.27 枚（等于预览值），回购余额清零 | [`0xf3efb4dd…5375`](https://testnet.bscscan.com/tx/0xf3efb4dd2e68437e31e82155ad653007ff169f0756e3bc23bd8ed53feff45375) |

## v4 / v5 工厂：收款地址（`buyback-burn-v2`）

v2 回购模块：回购以外的部分打给 `payee`（默认 dev，建币时 `--buyback-to` 指定，dev 随时 `setPayee`）。管理合约不变（v2），只换工厂：

| 项 | 值 |
|---|---|
| GangBuybackSplitterFactory v5（现行，CLI 内置） | [`0x08b9E2Cf5F666b55F262239b19e25de25b8ba87D`](https://testnet.bscscan.com/address/0x08b9E2Cf5F666b55F262239b19e25de25b8ba87D)，实现合约 `0xD6e7122a815A7A4C017576d5374E1691D6BAb1Ac`；部署 [`0x96a5d70a…da43`](https://testnet.bscscan.com/tx/0x96a5d70aa801dbec448f7012e98d375f59bf0af2fc20544213f0b9767d89da43)，`setFactory` [`0x83aa3b0d…2409`](https://testnet.bscscan.com/tx/0x83aa3b0de4e6bc56ae10290884774220cf8205e27f8a8c18261ee1363eb92409)；停用 v4 [`0xb0b9dfe8…7f55`](https://testnet.bscscan.com/tx/0xb0b9dfe89462b5ba95f9b4705ea0ea62091f41ac09950826878fce0c5cab7f55)。比 v4 多一条：payee 不能是回购合约自己（`BadPayee`，自查时补上：付给自己会把 dev 那份在下次拆分里又拆一遍） |
| GangBuybackSplitterFactory v4（已停用） | [`0x2a56B8Ee199827F2A8E241BC91def360569278Ec`](https://testnet.bscscan.com/address/0x2a56B8Ee199827F2A8E241BC91def360569278Ec)，实现合约 `0x980A1832B71995Ce8a1457362D077C7CeEE9C5Ca`；部署 [`0x8f65ccc8…6db2`](https://testnet.bscscan.com/tx/0x8f65ccc8697d17ab14c0abbda01df3519fdb01367930e961e78e422dcf1d6db2)（gas 2,534,545） |
| `adminV2.setFactory(factoryV4, true)` | [`0x6bcb4fa3…3d41`](https://testnet.bscscan.com/tx/0x6bcb4fa382fa7fb631845b41980a1b6191bb181e97c469e74369dbda493e3d41) |
| 停用 v3 工厂 | [`0x96b66604…c22a`](https://testnet.bscscan.com/tx/0x96b66604d2758526419d477411a8463345901739bfe84dbdad021092f209c22a) |

CLI（`gang create … --buyback 50 --buyback-to 0x…be1ef`）：

| 情况 | 结果 | 交易 |
|---|---|---|
| 克隆 | `buyback-burn-v2` 回购合约 [`0xE634ac01ACbe165b21ACE0301E423D223bbae2Df`](https://testnet.bscscan.com/address/0xE634ac01ACbe165b21ACE0301E423D223bbae2Df)，payee = `…be1ef` | [`0xd3702755…995b`](https://testnet.bscscan.com/tx/0xd37027552fcf2e860657ded003bd215bcd4dbbf8ab0f85c7ec3dcec6cd60995b) |
| 改成别的 `--buyback-to`、或去掉它重跑 | 拒绝：这次启动的回购合约付给 `…BE1Ef` | — |
| 地址校验和不对（大小写混写错） | 拒绝，提示写成校验和格式或全小写 | — |
| 建币 PAYT `0xFC908B6191547E42C22D12f1fe94a0b3aA9a6a92` → bind → done | `buyback.payee` = `…BE1Ef` | [`0x30ceda74…b7fb`](https://testnet.bscscan.com/tx/0x30ceda74dca4d0e52c016bb973a31a0afbf21db600a03c192e941e647348b7fb)、[`0x29e66cc9…c226`](https://testnet.bscscan.com/tx/0x29e66cc904464ea45759b48cb039d2d0375543b07236416f76e6b9b58433c226) |
| 铸 0.02 进回购合约、`split()` | payee 收到 0.01，dev 没收到，回购余额 0.01 | [`0x92d8485c…8952`](https://testnet.bscscan.com/tx/0x92d8485cea51f8b0db6b7106970623839ce0ec4da113ef24d5b327ea14708952) |
| `gang buyback set-payee --to 0x…c0ffee` | 立即生效 | [`0x02eb46e6…276c`](https://testnet.bscscan.com/tx/0x02eb46e66e5f3dd5d68164edb60ed6858c19d9d4b8cd82b8bdcd80519d57276c) |
| 再铸 0.02、`split()` | 新 payee 收到 0.01，旧 payee 不变 | [`0x65d9adc9…e7cf`](https://testnet.bscscan.com/tx/0x65d9adc9431627e97ebba1d9e059c867e1f7c3a3f110875dd6f25ac5a095e7cf) |
| 陌生地址 `set-payee`、设成当前 payee、对 v1 回购合约（BBFL）`set-payee` | CLI 拒绝 | — |

v5 复测：CLI `--buyback 40 --buyback-to 0x…be1ef` 发 PAY5 `0xD861D8F708f12f13AD926877B0050Cf255b4E4d3`（回购合约 `0x3f538e24e44EF0023a7DC84FD76bfB02fb4a2f95`，克隆 [`0xaf34a95c…b05d`](https://testnet.bscscan.com/tx/0xaf34a95c07572fa99bc211b8017c62ec1db6a97ee1de0b14092f10543268b05d)）；铸 0.01、`split()`：payee 收到 0.006，回购余额 0.004（[`0xbe85c7ed…d30c`](https://testnet.bscscan.com/tx/0xbe85c7ed5c8758454c00a4adb31c23d7149e6de6c3f59015a0450666e72ed30c)）；`setPayee(回购合约自己)` 回滚 `BadPayee`。

## 没测到

- 下调公告期满后执行（`gang buyback apply`）：BBFT 上的下调已取消；要等 3 天。单测覆盖执行、作废、取消。
- `gang buyback release` / `bind` 单独用：launch 里的 bind 已上链；release 要报价币拉黑 dev，单测覆盖。
- 拉盘后暂停、恢复：第一版的 keeper 一节在链上测过（同样的合约逻辑），`previewWork` 在拉盘后的行为由单测 `test_work_dueWhenItActs` 覆盖。
- 主网：要多签执行第 2 步的批量（handler owner 转给管理合约），并在服务器上装 `keeper-module-work.sh` 的 cron。

## 复跑

```sh
# 管理合约 + 工厂（打印多签批量；测试网上 owner 钱包是部署者时直接执行）
GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 DEPLOYER_PRIVATE_KEY=… \
  forge script script/DeployGangBuybackSplitterFactory.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com \
  --broadcast --slow --legacy --with-gas-price 100000000
# 只核对已部署的
GANG_PAD=… HANDLER_ADMIN=0xBc2d…9a4d SPLITTER_FACTORY=0x0Ff5…9DA1 \
  forge script script/DeployGangBuybackSplitterFactory.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com
# keeper（gangfun-server）
PADS=t10:0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1@0 BSC_RPC=https://bsc-testnet-rpc.publicnode.com \
  keeper/keeper-module-work.sh            # dry-run；--broadcast 要 KEEPER_PRIVATE_KEY = EXPECTED_KEEPER，GAS_ARGS="--legacy --gas-price 100000000"
```

# 第二部分 · 第一版：逐个部署、多签 list

以下是第一版的记录（合约代码与现行版本的拆分 / 回购规则相同，只是构造方式不同；部署脚本 `script/DeployGangBuybackSplitter.s.sol` 已换成 `DeployGangBuybackSplitterFactory.s.sol`，keeper 一节用的 `keeper-buyback-burn.sh` 已换成 `keeper-module-work.sh`）。

第一版回购合约挂在第 10 套内盘上，走完了接入的全部步骤：部署并检查 → 多签 `list` 和 `setExcluded` → dev 建币时 recipient 填它 → `bind` → 毕业 → 池子里卖出交税 → keeper `process` → 拆分 → `burnChunk` 买入并销毁。比例调整（提高、申请下调、取消下调）和部署脚本的检查模式也都在链上跑过。

- 链：BSC 测试网（chainId 97），2026-10-28
- 规格：`docs/SPEC-BUYBACK-SPLITTER-2026-10-28.md`
- 合约：`src/gang/GangBuybackSplitter.sol`；部署 / 检查脚本：`script/DeployGangBuybackSplitter.s.sol`
- 发交易：`cast send --legacy --gas-price 0.1gwei`（原因见 `docs/TESTNET-GANG-BOND-2026-10-28.md`「gas」）

### 地址

| 项 | 值 |
|---|---|
| GangBuybackSplitter | [`0xB43bDcDDd88A6C327e5A8763f02EA3cbe960c0C9`](https://testnet.bscscan.com/address/0xB43bDcDDd88A6C327e5A8763f02EA3cbe960c0C9) |
| 部署交易 | [`0x0a056a20…0ce1`](https://testnet.bscscan.com/tx/0x0a056a2077f23e434a3646fdf72671dc86327eab478b44ecd3d4a1b342e10ce1)，区块 139392504，gas 1,869,807 |
| 构造参数 | pad = 第 10 套 GangLaunchpad `0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`，dev = `0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6`，buybackBps = 5000 |
| tax handler / 分红金库 | `0xe1902C3eBA6b6114e48051fbC78603EA32cdCa7c` / `0xF6925641E547A7Dd40f971E61C7cd51624231d69` |
| 测试币 BBST | [`0xD0cE4Ae83032FA3dbB5C96813A51C83DAf3DA83a`](https://testnet.bscscan.com/address/0xD0cE4Ae83032FA3dbB5C96813A51C83DAf3DA83a)：V3，报价币 MockSPCXB（`0x02B3…CF1c`），买卖税各 3%，分红 50%，recipient = 回购合约 |
| 交易对 | `0x21D1819A885A84F0bCf5f5EaFB2a42E738ce3498`（Pancake 测试网 V2） |
| 源码验证 | 未做（缺 BscScan API key） |

测试网上 dev 和平台 owner 是同一个钱包（第 10 套的 owner `0xCa8e…00b6`，持有 Agent ID）：`list` / `setExcluded` 用它签名，建币、改比例也用它。主网上两者分开：dev 只签建币和改比例，`list` / `setExcluded` 由 Safe 执行。

### 接入

| 步骤 | 结果 | 交易 |
|---|---|---|
| 部署脚本（`SPLITTER_DEV`、`SPLITTER_BPS=5000`）：部署后 `verify`（真 pad、本仓库代码）+ `expect`（dev、比例、无待执行下调），打印 Safe 批量 | 通过 | 见上表 |
| `handler.list(splitter, "buyback splitter (testnet)")` | 成功，`isListed = true`，gas 99,221 | [`0x6336c588…daa5`](https://testnet.bscscan.com/tx/0x6336c588768b598d0cef76efef22a8d439a8830a1da77f2874e90275a99cdaa5) |
| `divVault.setExcluded(splitter, true)` | 成功，gas 50,408 | [`0xa63060a5…918c`](https://testnet.bscscan.com/tx/0xa63060a5605ed579f7506fb999d1db3568734301eb3978c36b838999fd1d918c) |
| dev `create`（recipient = 回购合约） | 成功，gas 1,622,424 | [`0xa5728340…ec15`](https://testnet.bscscan.com/tx/0xa5728340e6adf2dd2d685ad8bae19188e06afaff3bd2bc33c33ec66b8a4fec15) |
| `bind(BBST)` | 成功，`token` / `quote` 写入，gas 98,547 | [`0xb14b4703…9247`](https://testnet.bscscan.com/tx/0xb14b47039d163c90e0575c561511048f96a7af6f1384e990ec7fe20e3a199247) |

### 毕业、交税、拆分

- 毕业：dev 在内盘买到 1% 上限（1,000 万枚），之后 79 个测试 Agent（`GangTestnetE2E` 的 `gang-v3-testnet` 钱包）各买到 1%，最后一笔毕业建池。共 163 笔（含给买家预付 gas），1,950 万 gas，全部成功；最后一笔 [`0x8a3975bf…c088`](https://testnet.bscscan.com/tx/0x8a3975bf10c7216ca6201bbc53d580cfebf0a93af1248cd18c5b08e8793dc088)。买家剩下的 gas 随后收回（80 笔转账，共 0.009163 tBNB）。
- 交税：dev 在池子里卖 3 次，每次 200 万枚（[`0x49ac208e…dee8`](https://testnet.bscscan.com/tx/0x49ac208e8096886f041c1ea59fc58c6fc427e5045b8059bde5faa9ce05b2dee8)、[`0xb2f31209…30af`](https://testnet.bscscan.com/tx/0xb2f312099d2a3af446eb9fa9507758feb25d42a08487d5c62582d28edefe30af)、[`0x8d90ae72…f080`](https://testnet.bscscan.com/tx/0x8d90ae726f664e9e3da33367c429927534050806226568e3e3905f62c7c3f080)）。卖出途中 handler 的 swap-back 卖掉了一部分累计税，回购合约已收到 0.003632 MockSPCXB。
- `process(BBST, 60,000 枚, minQuoteOut = 预估 × 97%)`：把剩下的累计税卖完，回购合约再收到 0.001764，待拆分合计 0.005397。gas 298,892，[`0x43bb28f6…c986`](https://testnet.bscscan.com/tx/0x43bb28f69c5f9a3e0c7965be53d1a8ffa07c9fc1accf076ff899e9258208c986)。`minQuoteOut` 填 0 会被拒绝（`ZeroAmount`）。

### 回购（`burnChunk`）

| 时间（UTC） | 结果 | 花费（MockSPCXB） | 销毁（枚） | 剩余 `buybackLeft` | gas | 交易 |
|---|---|---|---|---|---|---|
| 09:02 | 先按 50% 拆分：dev 收到 0.0026984，留作回购 0.0026984（向下取整，少 1 wei）；缓存交易对，只记观测点 | 0 | 0 | 0.0026984 | 198,927 | [`0x5495d784…b58d`](https://testnet.bscscan.com/tx/0x5495d784430ffe29ead395efa216648f92634212295ac6eaf4526149a6d7b58d) |
| 09:13 | 买入并销毁（`minTokensOut` = 预览值） | 0.0026984 | 36,922.957 | 0 | 348,288 | [`0x5a153de9…8188`](https://testnet.bscscan.com/tx/0x5a153de928e6cffa15830bb5ff40a5afda9ae0a344e0804f27c9cc08b8858188) |

- 实际销毁量等于 `previewBurn` 的预览值（已扣 3% 买入税），0xdead 余额增加的正是这个数。
- 交易对报价币储备约 14.57，单块上限 0.5% ≈ 0.0728，所以这次一块就买完。
- 买完后回购合约持有 0 枚代币、0 报价币，金库里的份额为 0（已排除，回购途中没有写份额）。再调 `burnChunk` 报 `NothingToBurn`，`releaseDev` 报 `NothingOwed`。

### 比例调整与部署脚本检查

| 步骤 | 结果 | 交易 |
|---|---|---|
| `setBuybackBps(6000)`（提高） | 立即生效，gas 42,625 | [`0xd2f9665e…12f5`](https://testnet.bscscan.com/tx/0xd2f9665e5f26a61525964551f88da8f5225cce8c4196e74b0ec27682a16312f5) |
| `setBuybackBps(5000)`（下调） | 进入公告期：比例仍是 6000，`pendingCut` = (true, 5000, 3 天后)，gas 30,482 | [`0x2bb1d7b6…5bd4`](https://testnet.bscscan.com/tx/0x2bb1d7b6a544e7be4fd1ba607ac8ee7f020a1696b66bf69a0967e30189e75bd4) |
| 检查模式（`SPLITTER` 已设）在公告期内 | 拒绝：`WiringCheck("splitter.pendingCut")` | 只模拟 |
| `setBuybackBps(6000)`（设回原值） | 取消下调：发出 `BuybackBpsProposalCancelled` 和 `BuybackBpsSet`，`pendingCut` = (false, 0, 0)，gas 44,020 | [`0x42059b54…aa14`](https://testnet.bscscan.com/tx/0x42059b54deea801405c70f8a1c7b86e11d54aca3e1a120fd6f7c89ceb2a2aa14) |
| 检查模式，`SPLITTER_BPS=6000` | 通过，Safe 批量两项都提示已完成（already listed / already excluded） | 只模拟 |
| 检查模式，`SPLITTER_BPS=5000` | 拒绝：`WiringCheck("splitter.buybackBps")` | 只模拟 |
| 陌生人 `setBuybackBps` / 没有申请时 `applyBuybackBps` | `NotDev` / `NoProposal` | 只模拟 |

当前状态：比例 6000，没有待执行的下调。

### keeper（gangfun-server `keeper/keeper-buyback-burn.sh`）

脚本在 gangfun-server 分支 `feat/buyback-burn-keeper`（`90d0d54`），本机运行，配置 `PADS=t10:0xFebF…5BB1@…`，测试网钥匙当 keeper（`EXPECTED_KEEPER` 设成它），`GAS_ARGS="--legacy --gas-price 100000000"`。回购合约从 handler 白名单里自动找到（演示金库没有被误认）。为了有东西可买，直接往回购合约铸 MockSPCXB 当作到账的税（比例此时是 6000）。

| 时间（UTC） | 情况 | keeper 做了什么 | 交易 |
|---|---|---|---|
| 09:19 | 铸 0.02 进回购合约（[`0xae7ecad7…f358`](https://testnet.bscscan.com/tx/0xae7ecad7d79981abe504d07e69cb78d6cba49cf31941106467af2f9c3e61f358)） | dry-run 显示可买；`--broadcast` 买一块：0.012 → 销毁 164,034.78 枚，等于预览值（`minTokensOut` = 预览 − 1%） | [`0x96c72926…7800`](https://testnet.bscscan.com/tx/0x96c7292647991f4c39a292460a4ae4260b5c8cb93c6e4b10b328c10efa347800) |
| 09:19 | 刚买完 | 再跑一次：nothing to buy back，不发交易 | — |
| 09:20 | 池子里买入 0.5 报价币把价格拉高约 7%（[`0xb24abb50…7ded`](https://testnet.bscscan.com/tx/0xb24abb5005ad67eeebae72d3485d93706de638bb2df4820c91985f4b97557ded)），再铸 0.02（[`0x1f884bce…d342`](https://testnet.bscscan.com/tx/0x1f884bceb142aab2cf655b8e5c5451968ef7fa0090423db957bb08752783d342)） | `previewBurn` 不可买 → 只发观测调用 `burnChunk(0)`（顺带拆分，回购余额 0.012），记下时间 | [`0xc48187da…25bb`](https://testnet.bscscan.com/tx/0xc48187dab003cc4f31a12530cbd5811f6d412f76c0a26a8bd33b1a17143625bb) |
| 09:20 | 11 秒后 | not ready, observed 11s ago — waiting，不发交易 | — |
| 09:31 | 观测点推进到 09:31，均价窗口 09:13–09:31 里高价只占一部分，现价仍比均价高 2% 以上 | 观测调用，不买 | [`0x2495d7cd…5cf3`](https://testnet.bscscan.com/tx/0x2495d7cdd2905c1e8994bfc39a3824c45696d3704c59e83605eebd86db145cf3) |
| 09:41 | 均价窗口 09:31–09:41 全是拉高后的价格 | 恢复买入：0.012 → 销毁 153,098.96 枚，等于预览值；回购余额清零 | [`0xf7164347…09a0`](https://testnet.bscscan.com/tx/0xf7164347feb96e4680ce99f2022b1ab0295df09596cdaf152e81904e06d009a0) |

本机有 `flock` 但没有 `/run`，所以测试时设了 `KEEPER_LOCK`；服务器上用默认的 `/run/gang-keeper.lock`，和其它任务共用。

### 花费

整轮约 2,737 万 gas，按 0.1 gwei 合 0.0027 tBNB；其中毕业的 163 笔占 1,950 万。

### 本次没测到（在单测里覆盖：`test/gang/GangBuybackSplitter.t.sol`，22 个）

- 下调公告期满后执行（`applyBuybackBps`）、过期作废：要等 3 天 / 10 天。
- dev 被报价币拉黑时记为欠款（`devOwed`）、之后 `releaseDev`；余额被扣时两部分按比例分摊。
- 滑点保护（`minTokensOut`）的回滚。价格被拉高时跳过、之后恢复，已在上面 keeper 一节上链测过。
- `sweep` 别的资产。

### 复跑

```sh
# 部署 + 检查（打印 Safe 批量）
GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 SPLITTER_DEV=<dev> SPLITTER_BPS=5000 DEPLOYER_PRIVATE_KEY=… \
  forge script script/DeployGangBuybackSplitter.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com \
  --broadcast --legacy --with-gas-price 100000000

# 只检查别人部署的那个
GANG_PAD=… SPLITTER=<splitter> SPLITTER_DEV=<dev> SPLITTER_BPS=<bps> \
  forge script script/DeployGangBuybackSplitter.s.sol --rpc-url https://bsc-testnet-rpc.publicnode.com
```

`--slow` 广播时不要用官方节点 `data-seed-prebsc-1-s1` 做 `--rpc-url`：它不是归档节点，forge 模拟到一半会报 `missing trie node`（这次第一次跑毕业就停在模拟阶段，什么都没发出去）。用 publicnode 模拟和发送，加 `--legacy`。
