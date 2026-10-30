# 测试网 · GangFlywheelPad（铸币飞轮，原名「持续打新」，kind 3）

- 链：BSC 测试网（chainId 97），2026-10-30
- 方案：issue #75
- 部署：`script/DeployFlywheel.s.sol`；验收：`script/FlywheelTestnetAccept.s.sol`（两个阶段，中间等开盘保护期结束）
- 发交易：`forge script … --broadcast --slow --legacy --with-gas-price 100000000`（原因见 `docs/TESTNET-GANG-BOND-2026-10-28.md`「gas」）
- 共享合约沿用第 10 套内盘（`GANG_PAD = 0xFebF…5BB1`）的 quote registry、分红 vault、平台费 bucket、migrator；测试网上这几个合约和发射台注册表都归部署钱包 `0xCa8e…00b6`，所以同一次运行里接好线（主网走多签批量，见部署脚本）

部署了两套，都登记在测试网发射台注册表里（只能追加）：

| 套 | 代码 | 本文 |
|---|---|---|
| 第二套（现行） | 主网前审计修复后：开池先开保护再付 dev 分成、开池后 mint 先收款再读价、`maxSpent`、dev 分成上限 10%、`pairFactory()` / `v3Factory()` | 第一部分 |
| 第一套 | 修复前 | 第二部分（保留作记录，不再使用） |

# 第一部分 · 第二套（现行）

| 项 | 值 |
|---|---|
| GangFlywheelPad | [`0xD6482850aCAC74BA889804931Fc797294777951c`](https://testnet.bscscan.com/address/0xD6482850aCAC74BA889804931Fc797294777951c)，`KIND = 3` |
| FlywheelTaxHandler | [`0xCE084a4aF0059eB1620769a4daB7A9372A9cd315`](https://testnet.bscscan.com/address/0xCE084a4aF0059eB1620769a4daB7A9372A9cd315) |
| MintTokenDeployer | [`0x61efEAdD550EaAc2257d5d1A5327df82397C712f`](https://testnet.bscscan.com/address/0x61efEAdD550EaAc2257d5d1A5327df82397C712f) |
| 外部库 | FlywheelLogic `0xA2538eB3B15CEa212e3bC7226Ae5a3D3eF53501B`、FlywheelPostLogic `0xDc7a3f71014a4AB161007f96B652F8494269F044` |
| 部署 | 18 笔，0 失败，gas 合计 18,697,497，区块 139,749,672–139,749,747；pad [`0x1c6afa8b…03dd`](https://testnet.bscscan.com/tx/0x1c6afa8ba170acc96908dfa80860896d32f40f71120c98e9256890d0851003dd)、注册表 `addPad` [`0x8972624a…0327`](https://testnet.bscscan.com/tx/0x8972624aef4d8d734f9f5dbcae770df37537a8e0078f66e16a5989f947750327)、`setMigrator`（OWNER 就是部署钱包，当场调用）[`0x027cace6…6b5d`](https://testnet.bscscan.com/tx/0x027cace6ccceda706072347d36212fed53c8fc6845d6a205a14e5d33468b6b5d)；记录 `broadcast/DeployFlywheel.s.sol/97/run-1793338157910.json` |

验收（同一个脚本，阶段 2 的开池后 mint 带 `maxSpent = 预览的 paid + fee`）：

| 项 | 值 |
|---|---|
| 测试币发射 | [`0x35F2b5c500516C0F906B9dEeDD863f277C41C7fc`](https://testnet.bscscan.com/address/0x35F2b5c500516C0F906B9dEeDD863f277C41C7fc)，pair `0x980D64BcDF4EC86014D9a5Ca5D4daDe31254F763`；WBNB 发射 `0x36b9400D47f1B3a096DE9E03d0F0377b341F6A2F` |
| 阶段 1 | 404 笔，0 失败（30 个钱包已有 Agent ID），gas 64,128,663，区块 139,750,113–139,751,895；`openEarly` [`0x71557b4c…81c4`](https://testnet.bscscan.com/tx/0x71557b4ccd5cfdde591e11c88f14e641e30f288c0e6c8791b3c823bc557d81c4)（gas 2,512,688）；`mintWithBnb` [`0xae302c35…908d`](https://testnet.bscscan.com/tx/0xae302c35bd93082c2a8b1c226f36f9e526d48fad60865ffefffd6f0c17c0908d)；卖回 [`0xe5c72595…59d5`](https://testnet.bscscan.com/tx/0xe5c72595252af6a44042ed3e626625c54739901b50a7d4ad09cbd0bc094659d5)、[`0x8d4800c0…fc66`](https://testnet.bscscan.com/tx/0x8d4800c0dad30e968384035f421cbc6bf85beec64b9be73cd24a266b7772fc66) |
| 保护期探针 | [`0x86765387…3069`](https://testnet.bscscan.com/tx/0x8676538730eef55bd54131e20169317455d4eb37e1b6b5b8140b19ececa43069)：`cast run` 回放的拒绝原因 `ProtectionNotAgent()`；保护期到 `1793339457` |
| 阶段 2 | 10 笔，0 失败，一次跑通：`mintPost` × 5（[`0xd0fe292e…0daf`](https://testnet.bscscan.com/tx/0xd0fe292ea5c24b137d6a8510717feab9324cf675cf58913573e23d951a550daf) 等，gas 约 468,600，首笔 570,238）、router 买入 [`0xd28838b4…16a8`](https://testnet.bscscan.com/tx/0xd28838b4dbe7fdbe55e18d40237d67eac45ea93c90d60843018e7c1a6d8616a8)、keeper `process` [`0xcdc4fa1d…90a5`](https://testnet.bscscan.com/tx/0xcdc4fa1d4cd65c958a0263cc76daaac4f715bf6bd8bb3e920d907ee9917090a5)、router 卖出 [`0xc4e798fe…998d`](https://testnet.bscscan.com/tx/0xc4e798fecee0f6271f0651fb6e44dfffc7aa17d5d393b2cc61f0322425d8998d) |
| 链上核对 | `registry.lookup(token) = (0xD648…951c, 3)`；验收钱包有待领取的持有人奖励 |

部署钱包剩 0.212 tBNB。

# 第二部分 · 第一套（修复前，已被第二套取代）

## 部署

| 项 | 值 |
|---|---|
| GangFlywheelPad | [`0x7E3000c87950Ac3C9e05622d3A58E001F96D937e`](https://testnet.bscscan.com/address/0x7E3000c87950Ac3C9e05622d3A58E001F96D937e)（17,973 字节），`KIND = 3` |
| FlywheelTaxHandler | [`0xF7d7566305f33561151d9354dD9F6926bAD8E7A5`](https://testnet.bscscan.com/address/0xF7d7566305f33561151d9354dD9F6926bAD8E7A5)（23,910 字节），keeper = 部署钱包 |
| MintTokenDeployer | [`0xD4f0fB929d34a77D9FA982Ff05f531c73b8C1F82`](https://testnet.bscscan.com/address/0xD4f0fB929d34a77D9FA982Ff05f531c73b8C1F82) |
| 外部库 | FlywheelLogic `0x2aff9B8548B1dbbD5F581989C29442A665634824`、FlywheelPostLogic `0x1F166aE8754E89865902C34A93dcA301A1053E81` |
| owner | 三个合约都是 `0xCa8e…00b6` |
| Agent ID 门控 | 开，测试网 TestnetAgentId `0x24D0…5B2a`（任何人可自行 `register()`） |
| 交易 | 18 笔，0 失败，gas 合计 18,686,565，区块 139,732,623–139,732,704；记录 `broadcast/DeployFlywheel.s.sol/97/run-1793330485867.json` |

接线（同一次运行）：

| 操作 | 交易 |
|---|---|
| vault `setLaunchpad(pad, true)` | [`0x3bd2497b…f56d`](https://testnet.bscscan.com/tx/0x3bd2497b4a9f06622f0afdd577a9b25170a3e813cab41e610f263dbb8171f56d) |
| vault `setMinimumShareBalance(pad, 1,000 枚)` | [`0x57c6c0f0…23c7`](https://testnet.bscscan.com/tx/0x57c6c0f0877de1aed8424d583b914f24ba1f007f9e6af577ca3bac54fa2c23c7) |
| vault `setOperator(handler, pad)` | [`0x0331bcc5…7a39`](https://testnet.bscscan.com/tx/0x0331bcc5571d64d681454bf87a5fe4d23ec633ced71986c9b40aa5c875097a39) |
| migrator `addLaunchpad(pad)` | [`0xbba1aaf2…8506`](https://testnet.bscscan.com/tx/0xbba1aaf2206d719d458246af7643b2f64f1fcb267ded1837e44e3ba07bc98506) |
| bucket `setOperator` × 2（pad、handler） | [`0xfb89e894…f806`](https://testnet.bscscan.com/tx/0xfb89e8941bbfa444eaee6463f04d83be9e9da6b320ff6972c404262345f2b806)、[`0x49dd51e3…742e`](https://testnet.bscscan.com/tx/0x49dd51e3d0b7e7965e42abe65de8d0f025223a9da6b12621dbf921832df4742e) |
| 发射台注册表 `0xB11B…e56e` `addPad(pad)` | [`0xff50e730…de69`](https://testnet.bscscan.com/tx/0xff50e730fb5d319460ce005a55eace1b0402a816fe3d9456d0575fecb5dade69) |
| pad `setMigrator`（最后一步） | [`0x665792ef…5a56`](https://testnet.bscscan.com/tx/0x665792eff169ed20f36ced38d543668de261e3fcf54555480d88f2f14f615a56) |

部署后链上核对：`registry.isPad(pad) = true`，`pad.migrator() = 0xaE31…2e20`，`agentGateEnabled = true`，脚本自检 `self-check ok`。

## 验收阶段 1：预售、邀请、卖回、BNB 支付、提前开盘、开盘保护

测试币（MockSPCXB `0x02B3…CF1c`）计价的发射：募集 3、单钱包配额 100、`launchDelay 0`、保护期 300 秒。30 个一次性钱包（由部署钱包私钥和序号派生，只在脚本里用）各自注册 Agent ID，沿邀请链铸币，其中一个卖回再铸；另一个 WBNB 计价的发射测 BNB 支付找零和卖回。

| 项 | 值 |
|---|---|
| 测试币发射 ACCEPT_TOKEN | [`0x10033FDe42B70360ED7076175d4bf50C27DE9b5D`](https://testnet.bscscan.com/address/0x10033FDe42B70360ED7076175d4bf50C27DE9b5D)，pair `0x393e2D8adff792aE630AaaDE99ABe15e004c1fDB` |
| WBNB 发射 | [`0xfA8af8031dc49128183d52Afca3E9F153d111be3`](https://testnet.bscscan.com/address/0xfA8af8031dc49128183d52Afca3E9F153d111be3) |
| 交易 | 434 笔，0 失败，gas 合计 66,848,545，区块 139,733,067–139,734,988 |
| 预售 `mint` | 301 笔，gas 中位数 168,432（161,376–248,221） |
| `create` | [`0xcbcdd324…f757`](https://testnet.bscscan.com/tx/0xcbcdd3245ad6b824df4fa6360307786a56607667ed846f6e88b942cd43cef757)（gas 2,162,975）、[`0xa7460ebf…cd98`](https://testnet.bscscan.com/tx/0xa7460ebf7fb3ea3cedd6c62474e3c600676ac9189297ee3afcf27af7edfbcd98)（gas 2,126,546） |
| 卖回 `withdraw` | [`0xecfe56a7…8559`](https://testnet.bscscan.com/tx/0xecfe56a77ef44503e67c311484d489e4b728721249f3f5d7267a453b035f8559)、[`0xb0c10495…6b09`](https://testnet.bscscan.com/tx/0xb0c1049572b131a6ca72f79934a8ad5a24c17e012ddde675c6a5b9752c5f6b09) |
| `mintWithBnb`（找零退回） | [`0xca6ade3e…c1c3`](https://testnet.bscscan.com/tx/0xca6ade3e409db5d6501bd3c5b738a26e5afe8a1fe9866753c51070839667c1c3) |
| `openEarly`（卖出 3,010 份，同一笔里开盘） | [`0xdc1d0907…bdc5f`](https://testnet.bscscan.com/tx/0xdc1d0907038bdb945ab52d354bf8267c13bfe666fbb780aa7100012b0dbbdc5f)（gas 2,512,710） |
| 保护期探针（无 Agent ID 的合约买入） | [`0x79dbec83…d15f`](https://testnet.bscscan.com/tx/0x79dbec8332884ea28ab520b0b42dd5d6b3d415da54e358075012802c0f2dd15f)：`refused() = true`，`cast run` 回放的拒绝原因是 `ProtectionNotAgent()` |

保护期结束时间以链上 `handler.protectionOf(token).until` 为准（本次 `1793331851`）。`--slow` 下开盘那笔比模拟晚上链，脚本打印的模拟时间不准；保护期内用有 Agent ID 的钱包超额买入，模拟里被 `ProtectionCapExceeded()` 拒绝。

## 验收阶段 2：开盘后铸币、router 买卖、keeper、持有人奖励、注册表

| 项 | 交易 |
|---|---|
| `mintPost` × 5（预览与实际一致：`tokensOut`、`paid + fee`） | [`0x82f877f1…23e8`](https://testnet.bscscan.com/tx/0x82f877f1bc480d6c28249060d5d255657e37f1728a43188b7cd029b008ce23e8)、[`0x561aad55…9505`](https://testnet.bscscan.com/tx/0x561aad55a0692884b2b7c77052cf0a075a8d8f26351041c05da0220033db9505)、[`0x70f0cf31…7cf7d`](https://testnet.bscscan.com/tx/0x70f0cf318fa703c6dcd5c3067d73e7a2b33ad4cbe05bf0001a5be38e2497cf7d)、[`0xc6475f90…efa6`](https://testnet.bscscan.com/tx/0xc6475f907d1a1ebc37535d126046bfd9b6da3a701a72a425fe5c46a0af93efa6)、[`0xa7dbe6e2…367d`](https://testnet.bscscan.com/tx/0xa7dbe6e2445fc16db9a3667eb445ff86cb2852c4166c95d9f54dcddec5f1367d)，gas 约 468,000 |
| Pancake router 买入 | [`0xf1a7b414…8f7c`](https://testnet.bscscan.com/tx/0xf1a7b4146441bc4d4fc58ef0d0937f1cbea018fe9e20c1a2965f7f81b68b8f7c)（gas 335,833） |
| keeper `process` | [`0x72842c8c…203a`](https://testnet.bscscan.com/tx/0x72842c8cba1eed08b136fd56f80c7fb50d5d8714e6f2176c60f3069c30d7203a)（gas 413,610） |
| Pancake router 卖出（带 `swapBack`） | [`0x1619c28b…00a2`](https://testnet.bscscan.com/tx/0x1619c28bad0993582eeb823b39a835df5db732fb6df91e8970bf1aba9a5800a2)（gas 353,936） |

链上核对：`registry.lookup(token) = (0x7E30…937e, 3)`；30 个验收钱包都有待领取的持有人奖励（`vault.pending` / `pendingUnits` 大于 0）。

第一次跑阶段 2 时，前 5 笔 `mintPost` 上链成功（[`0xc9a025b0…4505`](https://testnet.bscscan.com/tx/0xc9a025b0665502243ead5dd92a4847f47d25b83bd06025e5725fcce905754505) 等，首笔 gas 569,608），router 买入 [`0xb8e3f968…9a84`](https://testnet.bscscan.com/tx/0xb8e3f968030ae261ca6ac292dbd2834fbd9a1844c1470efe035a935336f29a84) 失败：脚本把模拟时的 `block.timestamp` 当 deadline，`--slow` 下上链时已过期（Pancake `EXPIRED`）。合约没有问题，验收脚本改了三处：

- router 的 deadline 改成 `block.timestamp + 1 hours`；
- keeper `process` 放在卖出之前：forge 广播前把所有交易放在同一个区块里重新模拟，卖出后同一区块内价格低于参考价，`process` 按设计拒绝（`PriceBelowReference`）；
- 开盘后铸币跳过配额已用完的钱包（重跑时第一次的 5 个钱包 `quotaLeft = 0`，预览正确返回不可铸），阶段 2 开头先查链上保护期是否已结束。

## 余额

第一套跑完后部署钱包从 0.348 tBNB 剩 0.225 tBNB（含给 30 个验收钱包的 gas）。
