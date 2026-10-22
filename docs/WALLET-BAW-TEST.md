# Wallet · BAW-only (TEST) · 2026-10-22

**Host:** `45.78.200.239` only. No prod bake. No stocks on chain 56.

## Hard constraints

1. User can **connect** and **claim** 币股 dividends (`DividendVault.claim(token)` on Chapel 97).
2. **Only Binance Agentic Wallet / Binance Web3 Wallet** may connect for trade / deploy / claim signing.
3. MetaMask / OKX / generic injected / other WalletConnect → reject with `仅支持 Binance Agentic Wallet`.
4. Site still has **no open「发币」** entry; create stays Agent/`baw` path.

## Detection heuristic (`web/src/wallet/baw.js`)

| Priority | Signal |
|----------|--------|
| 1 | EIP-6963 `rdns` `com.binance.wallet` / `com.binance.w3w` / `com.binance.*` |
| 2 | `window.binancew3w.ethereum` (Binance App DApp browser) |
| 3 | `window.BinanceChain` or provider flags `isBinance` / `isBinanceWallet` / `isBinanceW3W` |

Rejected: MetaMask (`io.metamask*`), OKX (`com.okx*` / `com.okex*`), Coinbase, Phantom, plain `isMetaMask` without Binance flags.

## BAW vs browser

True **Agentic** path is CLI: `baw auth signin` + `baw contract-call preview|execute` (skill `@binance/agentic-wallet`). Browser cannot host the `baw` binary. Site UI:

- Connect button → Binance Web3 / in-app provider (same MPC family as Agentic Wallet when used in Binance App).
- Claim on `/stocks` and stock token pages when connected on Chapel.
- Agent deploy/buy: documented `baw contract-call` snippet under claim panel.

## Manual smoke (needs Binance Wallet / App)

1. Open `https://45.78.200.239/stocks` (self-signed → accept / `curl -k`).
2. With **only MetaMask** installed → Connect → expect 仅支持 Binance Agentic Wallet.
3. With Binance Wallet or Binance App DApp → Connect → switch/add Chapel 97 → see address.
4. Pick TBST (or indexed stock) → Claim → if `pending==0` expect revert/「暂无可领」; if accrued, confirm tx on testnet.bscscan.
5. Agent path: `baw contract-call preview --binanceChainId 97 --from <BAW> --to 0x2480… --inputData $(cast calldata "claim(address)" <TOKEN>)`.

## Blockers

- No BAW binary in CI / this box → claim E2E is manual.
- EIP-6963 rdns for “Agentic” specifically is not published separately from Binance Web3 Wallet; we treat Binance family as BAW-capable for TEST.
