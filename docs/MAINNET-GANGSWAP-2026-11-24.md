# 主网记录 · GangSwap

- 日期：2026-11-24（Asia/Shanghai）
- 网络：BSC 主网（56）
- 步骤和应急：`docs/MAINNET-RUNBOOK-GANGSWAP.md`；规格：`docs/SPEC-GANGSWAP-2026-11-22.md`
- 状态：**GangSwap 已部署，pad 3.0 和 registry 已升级，已登记并打开创建（2026-11-25）**。还没有正式版本的币毕业。

## 第 1 步：部署

代码：main `d2b508a`（`gangswap/` 和 `src/` 与 `a509292` 相同），从 GitHub 干净检出构建；gangswap 测试 140/140，`BUILD` 哈希与 `OpenGangSwap` 里固定的一致。部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`，gas price 0.05 gwei，先模拟后广播，五笔全部成功。

| 合约 | 地址 | 交易 | 区块 | gas |
|---|---|---|---|---|
| GangSwapMigrator | [`0x22e13298D48100420F2F386D70D18E498161B20b`](https://bscscan.com/address/0x22e13298D48100420F2F386D70D18E498161B20b) | `0x9fce2238a46b5df51bf79b7d972342dbef5f0d0ca29064aac8c2c82e16796130` | 135463501 | 905,484 |
| GangSwapBoost | `0x42A3dBcBb2339f52AE332cc480766003C43f1416` | `0x75ab0e3b51623a9ca6eaacb2299fea226fbbe1e8e8276fc43d51827060b5849a` | 135463506 | 799,916 |
| GangSwapFees | `0xa9D9a67D724d487f843d37db92162F6728c58900` | `0x4cd262a730964f0be99b9fce4a66eae656b098fc12af88ae65b601ceceeaa71a` | 135463512 | 934,950 |
| GangSwapFactory | `0xd0C15eB66e08596F9F534d0051F691b86Bc584F5` | `0x97026ff2e190dd1d5afc22fa2168622e9a137a24d032a80b9b4ef4791e66a259` | 135463516 | 2,247,275 |
| GangSwapRouter | `0xd685e3432472d0da34903888f96b0D0221bC779c` | `0x59e05cd7c98ebb78df961144b8aaee5148ea560541d42b0d3dd81a8b58f52e4b` | 135463520 | 2,877,541 |

### 链上核对

- `DeployGangSwap` 的 `check(migrator, router)` 通过；`wired()` = true，migrator 的 owner = Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`。
- 五笔部署交易的 input = 本次构建的创建代码 + 构造参数。
- router 的遮罩代码哈希和操作数次序等于 CLI 固定的值（`0x07886a19…005d`）。
- factory 没有任何 pair；pad 未登记；fees 还不是 bucket operator；pad 没有升级。
- 五个合约的源码都在 Sourcify（exact match）和 BscScan 验证。

`GANGSWAP_DEPLOY_TXS`（后面 `OpenGangSwap` 用）就是上表五笔交易，按表里的顺序。

## 第 2 步：部署 pad 3.0 和 registry 的新实现（没有升级）

`script/UpgradeGangLaunchpad3.s.sol`（`PAD3_REGISTRY_UPGRADE=true`、`GANG_MAINNET_OK=true`，链接主网 PoolCheck），代码同第 1 步。先模拟通过再广播，10 笔全部成功，gas price 0.05 gwei。**只部署，线上 pad 和 registry 的实现没有变**。

| 合约 | 地址 | 交易 | 区块 | gas |
|---|---|---|---|---|
| CurveLogic3 | `0x2A28c8E76b2AF6897EAbF72D8B573965c6c79094` | `0x6ee0e1fb0449380a68c9f2d4ffdb7d87b0006d27571b60aff5f391d8e061840f` | 135478949 | 4,142,417 |
| LegacyRoute | `0x8246E1138324fFd59d410eEBa98CD2f356580988` | `0xc310ad47f912c540aa505937c228b8a31f2b9a0efde1eeb5a00e7af1fb4296b1` | 135478952 | 2,561,224 |
| FlywheelPostLogic | `0x61467829c98A955B144618A7dF9a09d1A3d1C670` | `0x691d259314e409cb8ae024fd0f5a27a446aacdd8cf4fa02ebae3204349c2a218` | 135478954 | 1,981,891 |
| FlywheelLogic | `0x44a152A7020c9Da4E82c9a4a51a712575874E4f0` | `0xcb45bce7ff9c2a4cdfded35f14fe85102c0f7f606038cebb7393f36f46f804b4` | 135478956 | 4,538,934 |
| FairLogic | `0xa7DaC047b528ce3BB0a3Dd1c57A1C4c06e8343C3` | `0xaddaf45c053eab516c752cb4511dcb5fa10895550b2a99d3608717a97d1ecf93` | 135478958 | 3,281,290 |
| GangPadRegistry | `0x9d7C3D56ee2eC7bdc7b1eC2B85a5a7Eec91cb162` | `0x33cfe6e667c3a717fdd3c0ed2361cc8b806734d53f5fda6dafbfd3718aaec633` | 135478960 | 1,130,290 |
| Pad3FlyModule | `0x41E29b42A59Ef3662919E901395357379e069d11` | `0x9cb36712b0520f7b3912e2c39f854d6e55ec426162af412afd095105800324c9` | 135478962 | 4,816,091 |
| Pad3GradModule | `0xD476aa7643bd031E2612768347CE9c67214547a2` | `0x5690eb1d0547576a8d0ec8d340c1dd5ebb6491d3e769eb57e0679345193629a9` | 135478965 | 2,029,540 |
| Pad3Module | `0xF8ec5231838C5A07aa4f59BCDaa669Ed8e370225` | `0x592e577aa1d0f7ca4136bcd858853bc9f35842b811b9ff9d01d1cd24e8ffdc9f` | 135478968 | 5,063,326 |
| GangLaunchpad3 | `0x782f449D8476a873D4a1105a19B297E85e60246F` | `0xd58450fbb408963217c0ec4497716f0b6c3b22a7696da01d5e7b8811f6dfb256` | 135478970 | 4,984,426 |

构建脚本也重新部署了 LegacyRoute、FairLogic、FlywheelLogic、FlywheelPostLogic 这几个库（共用的源文件变了，测试网上也一样）。十个合约的源码都已在 Sourcify 和 BscScan 验证。

探针（签名前再跑一次 `script/pad3-upgrade-probes.py`）：1,067 个币里 4 个带推广分成、没有任何绑定，没有底仓币，两个探针都为空。

### Safe 批次（已执行）

带 `PAD3_IMPL`、`PAD_REGISTRY_IMPL`、`PAD3_FLY_HANDLER`、`PAD3_FLY_VAULT_CORE` 只读重跑：新实现、模块、registry 实现逐字节是本次构建的代码，模拟升级并读回通过（25 个币、全部 GangSwap 状态、设置）。归档：[MAINNET-GANG-LAUNCHPAD-3-UPGRADE-GANGSWAP-SAFE-BATCH-2026-11-24.json](MAINNET-GANG-LAUNCHPAD-3-UPGRADE-GANGSWAP-SAFE-BATCH-2026-11-24.json)，SHA-256 `0d81d11344e4ecf9cb9ad804428958815b10256e0e8efa7c0043ba9efc0ebe75`。两笔，不转 BNB，顺序不能换：

| # | 目标 | 调用 |
|---|---|---|
| 1 | pad 的 ProxyAdmin `0xCe83Be827bf2B6bAFe0ca6d1320Dce965CE3df48` | `upgradeAndCall(0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29, 0x782f449D8476a873D4a1105a19B297E85e60246F, 0x)` |
| 2 | registry 的 ProxyAdmin `0x9efbcf84b80Ab437AE82c74E2D047b997172f84D` | `upgradeAndCall(0x4fF77D4d9ac080939a24E1B805206bA094C44e5C, 0x9d7C3D56ee2eC7bdc7b1eC2B85a5a7Eec91cb162, 0x)` |

**fork 复核**（anvil，主网区块 135481201，以 Safe 身份原样发送归档里的两笔）：都成功；两个实现槽是新地址，owner 仍是 Safe，`gangSwapMigrator()` = 0，`createGangSwap` 返回 `GangSwapNotOpen`；老币 `0x09bB6Ce8b9fa670EA91413D6Fb1167DDEb07abCD` 的 `getTokenInfo`、`curves` 和 registry 报价升级前后相同。随后用真实部署的 GangSwap 继续跑 `OpenGangSwap` 的 `list` 和 `open`（核对和完整演练通过、逐笔执行成功）。以上都只在 fork 上。

## 第 3 步：升级执行

交易 [`0xc2da3a87d1fd31a3bd5cb64c9631f3e5883549369403f67f68bad7d1fc12bc7b`](https://bscscan.com/tx/0xc2da3a87d1fd31a3bd5cb64c9631f3e5883549369403f67f68bad7d1fc12bc7b)，区块 135485276，Safe nonce 60（执行后 61）。

执行后核对：

- 实现槽：pad = `0x782f449D8476a873D4a1105a19B297E85e60246F`，registry = `0x9d7C3D56ee2eC7bdc7b1eC2B85a5a7Eec91cb162`；`module()` = `0xF8ec5231838C5A07aa4f59BCDaa669Ed8e370225`，它的 `gradModule()`、`flyModule()` 是上表的地址；两个 owner 仍是 Safe。
- pad 设置不变：agent gate 和 1% 上限仍开启，migrator、abcd、底仓金库实现、冲毕业奖励的设置和升级前相同，`MAX_AGENT_WINDOW_MINUTES()` = 1440。
- `gangSwapMigrator()` = 0，`createGangSwap` 返回 `GangSwapNotOpen`。
- **全部 1,068 个币**在升级前一个区块和升级区块上逐个比较：`kindOf`、`curves`、`getTokenInfo`、`walletCapOn`、`agentOpenAt`、`promoteOf`，以及 registry 的买入和卖出报价，共 8 项，没有差别。

签名前没有再做一次探针和 fork 复核（Safe 先签了）；上面的逐币比较覆盖了它们要看的内容，推广绑定除外：升级前查到的是没有绑定。

## 第 4 步：登记（2026-11-25）

`OpenGangSwap` `GANGSWAP_STEP=list` 在主网只读核对通过（运行代码、部署交易的创建代码、指向、owner；模拟里完整走一个币），打印的批次归档：[MAINNET-GANGSWAP-LIST-SAFE-BATCH-2026-11-25.json](MAINNET-GANGSWAP-LIST-SAFE-BATCH-2026-11-25.json)，SHA-256 `26a50ec7a31f4d1c21d75a599843cb3a82ba0ccdffde0999c4879e92b4343f06`。主网 fork（区块 135491599）上以 Safe 身份原样执行，两笔成功，创建仍关闭。

执行：交易 [`0xb6b550e1ef3ed017c0f256449c60ecf6c87e3db6198cfa5f28bcd6d952f4e17f`](https://bscscan.com/tx/0xb6b550e1ef3ed017c0f256449c60ecf6c87e3db6198cfa5f28bcd6d952f4e17f)，区块 135492044，Safe nonce 61（执行后 62）。

核对：migrator 登记了 pad 3.0、没有登记 1.0 pad，bucket 的 operator 有 GangSwapFees、原有的 pad 授权不变；migrator 和 bucket 的 owner 仍是 Safe，`wired()` = true，没有任何 pair；`gangSwapMigrator()` = 0，`createGangSwap` 返回 `GangSwapNotOpen`。

## 第 5 步：打开（2026-11-25）

批次归档：[MAINNET-GANGSWAP-OPEN-SAFE-BATCH-2026-11-25.json](MAINNET-GANGSWAP-OPEN-SAFE-BATCH-2026-11-25.json)，SHA-256 `e1db0cbbbb01cca87212ea4b54a2ebb63018de049eeb80980243cf2e811f4fd3`，一笔 `setGangSwapMigrator(0x22e13298D48100420F2F386D70D18E498161B20b)`。

执行：交易 [`0xac63f91445928288e5ae03211143997e903f65bf3914bfb2d0ffd8d44af7c7e4`](https://bscscan.com/tx/0xac63f91445928288e5ae03211143997e903f65bf3914bfb2d0ffd8d44af7c7e4)，区块 135505289，Safe nonce 62（执行后 63）。核对：`gangSwapMigrator()` = `0x22e1…B20b`。第一个币在区块 135505610 创建，`kindOf` = 4，版本正确。

决定：隔离验收通过后保持打开、观察，有异常再由 Safe 执行 `setGangSwapMigrator(0)`。CLI 0.53.0 已公开发布。

## 主网隔离验收（2026-11-25）

另外部署一套同样的合约代码，用真实 WBNB，曲线只允许验收钱包买卖，和正式版本没有关系：

| 合约 | 地址 |
|---|---|
| pad | `0xa5Ed346AfB5cD8D7CdDce8a02d0D55b51EC0198B` |
| migrator | `0x4F53325AD55536d70Bd68131FFE27C807D27497c` |
| boost | `0xeD731dbCBD18e7eD8360ebA68EA7Ce49Eb93074F` |
| factory | `0x0053eb9B66DB1d5D2fE5dDF84f9CB3E487c83121` |
| fees | `0x24873965a56D5D5A4d262a67274865979CdB6876` |
| router | `0x71310eAf34584389408D8847a3ef86482B9998Db` |
| token | `0xb532b2374B820a74916311d46B8AcF02804E791f` |
| pair | `0x52c9843cfCdeC52363BB5B8027478C172581b40D` |

- 6 BNB 档，一笔买到毕业：真实储备 4.8、虚拟储备 1.2，LP 全部销毁。
- 40 步回购按真实时间全部成功，1.2 WBNB 用完，买到的币打到 `0x…dEaD`。
- 曲线买到的 8 亿枚全部换回，收到 5.9366 WBNB，和报价一致；池子剩余真实储备约 0.0514 WBNB，池子加销毁正好等于总量。
- 创建者手续费已领：曲线 0.0424、池子约 0.0084。
- 净成本约 0.073 BNB（不含部署和回购的 gas），和 fork 演练一致。

没有覆盖：用 router 在毕业后的池子里买入；正式 keeper、indexer 和网站配合一个真实毕业的币。
