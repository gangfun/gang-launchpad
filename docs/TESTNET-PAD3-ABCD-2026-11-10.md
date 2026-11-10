# Pad 3.0 abcd rollout: BSC testnet acceptance (2026-11-10)

The existing testnet Pad 3.0 proxy was upgraded and its abcd factory activated. Mainnet activation is a separate rollout step.

| Component | Address |
|---|---|
| Pad 3.0 proxy | `0x0508232833aE6849c03b28F7aA248BBd5cFCceE2` |
| Pad3VanityDeployer | `0xB9c2CD0A9cDD118105E5c146D9235F4086164D84` |
| New implementation | `0x8FB06d2E4598AdaDd3C82F26eC3dCCC5D2d09A69` |
| Pad3Module | `0x56395cd3572c72d062b96cce345c62812edc26f0` |
| Pad3FlyModule | `0x25f5f7425f52929c1c5fe171356685d8e18805ee` |

The deployment script sent one successful transaction. The upgrade script sent eight successful transactions, including deployment of three libraries, two modules and the implementation, followed by the upgrade and activation. The existing shared dependencies and flywheel handler/vault core were retained. Forge-generated records are under `broadcast/DeployPad3Vanity.s.sol/97/` and `broadcast/UpgradeGangLaunchpad3.s.sol/97/`.

## Seven-entry on-chain acceptance

`script/Pad3VanityTestnetAcceptance.s.sol` sent 39 successful transactions. All seven predicted token addresses matched their deployments and ended in abcd (checksum capitalization may differ).

| Launch entry | Token |
|---|---|
| Untaxed curve | [`0xD483E400981aDe7C7b463270e9A71965459EABCD`](https://testnet.bscscan.com/address/0xD483E400981aDe7C7b463270e9A71965459EABCD) |
| Taxed curve | [`0xf40228161ca489b749b45c6C7359dFDc2e81aBcD`](https://testnet.bscscan.com/address/0xf40228161ca489b749b45c6C7359dFDc2e81aBcD) |
| Custom graduation target | [`0x2E50F5029b5A0eD6d09D2b722a672D48AcBDabCD`](https://testnet.bscscan.com/address/0x2E50F5029b5A0eD6d09D2b722a672D48AcBDabCD) |
| Fair mint | [`0x61EFc32b6Fd8d5a6216e2ab1B54838E144AcAbcd`](https://testnet.bscscan.com/address/0x61EFc32b6Fd8d5a6216e2ab1B54838E144AcAbcd) |
| Mint flywheel | [`0xf14E0F9382ECA66831AF083336a7C40B1605AbCD`](https://testnet.bscscan.com/address/0xf14E0F9382ECA66831AF083336a7C40B1605AbCD) |
| Vault-bound curve | [`0x328733f1752D037dAf58220D55D6A0688c9eABCD`](https://testnet.bscscan.com/address/0x328733f1752D037dAf58220D55D6A0688c9eABCD) |
| Promoter-share curve | [`0xB32ff7492cD3012E28D2CDe95663DD46bA29ABcD`](https://testnet.bscscan.com/address/0xB32ff7492cD3012E28D2CDe95663DD46bA29ABcD) |

Live read-back confirmed each token's kind, factory registration and registry discovery, balances after native buys/sells, cleared sell allowances, vault binding and promoter terms. The temporary demo vault was delisted after the check. The pre-activation legacy curve `0x16953ac26e0396473742d4021436c464280985f7` also completed its buy/sell round trip. Records: `broadcast/Pad3VanityTestnetAcceptance.s.sol/97/`.

## CLI candidate acceptance

The local 0.38.0 candidate created three more tokens using final uploaded metadata. Every CLI prediction matched the on-chain token event. Curve buy/sell and fair/fly mint/withdraw calls succeeded; these three test positions were closed. Unused wrapped funding was returned to native BNB.

| Kind | Token | Create transaction |
|---|---|---|
| curve | [`0x526e140aa5CDD7Ca387F65B0a03984C52d5Dabcd`](https://testnet.bscscan.com/address/0x526e140aa5CDD7Ca387F65B0a03984C52d5Dabcd) | [`0x3688e8af…`](https://testnet.bscscan.com/tx/0x3688e8af545820e96c9ce8725fcfc113565e897b1a4a1de8c48b5109e394d937) |
| fair | [`0xef762cc97524a0A7a0A0b307b5eEAB37a604abcD`](https://testnet.bscscan.com/address/0xef762cc97524a0A7a0A0b307b5eEAB37a604abcD) | [`0x80eb17fb…`](https://testnet.bscscan.com/tx/0x80eb17fbb03958100f76173fbe36989bb4f45e48d4b592019bc601357d8fd77e) |
| fly | [`0x841596FCd1EdaBa8e327B8af6AEf533880AfabCD`](https://testnet.bscscan.com/address/0x841596FCd1EdaBa8e327B8af6AEf533880AfabCD) | [`0x052ee8a2…`](https://testnet.bscscan.com/tx/0x052ee8a2883f74b30b647428ee049f1dff38d2f5ee537fa3e65eabdb2878d8cb) |

## Local and mainnet-fork validation

- The new acceptance flow passed against the local full-stack fixture.
- `test/fork/Pad3VanityUpgradeFork.t.sol` passed against the live BSC mainnet state: the upgrade script compared the newest 25 token records, then the proxy was upgraded and the factory activated on the fork. The same seven-entry acceptance and legacy round trip passed. Agent IDs were mocked only on the fork; no mainnet transactions were broadcast.
- The fork also records proxy writes during upgrade plus activation: only the ERC-1967 implementation slot and the new factory namespace slot are written. Historical business storage is untouched.
- The CLI candidate passed all 29 test files after incorporating the current main branch.
- Earlier full Pad 3.0 historical regression: 811 passed, 0 failed, 0 skipped.

Before mainnet activation, merge the reviewed implementation, publish the versioned CLI through its existing release workflow, deploy/verify the mainnet contracts, and rehearse the final Safe batch against the then-current chain state.
