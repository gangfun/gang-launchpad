import { SEVERITY } from './abi.js'

const BSCSCAN_TX = (hash) => `https://bscscan.com/tx/${hash}`
const BSCSCAN_ADDR = (a) => `https://bscscan.com/address/${a}`

export function formatAlert({ eventName, args, blockNumber, transactionHash, registry }) {
  const sev = SEVERITY[eventName] || 'info'
  const lines = [
    `[gang-agent-id] ${sev.toUpperCase()} ${eventName}`,
    `registry: ${registry}`,
    `block: ${blockNumber}`,
    `tx: ${BSCSCAN_TX(transactionHash)}`,
  ]
  if (args?.owner) lines.push(`owner: ${args.owner} ${BSCSCAN_ADDR(args.owner)}`)
  if (args?.handle) lines.push(`handle: ${args.handle}`)
  if (args?.signer) lines.push(`signer: ${args.signer} ${BSCSCAN_ADDR(args.signer)}`)
  if (args?.previousOwner) lines.push(`from: ${args.previousOwner}`)
  if (args?.newOwner) lines.push(`to: ${args.newOwner}`)
  if (args?.minLen != null) lines.push(`bounds: ${args.minLen}-${args.maxLen}`)
  if (args?.from != null && args?.to != null) {
    lines.push(`transfer: ${args.from} → ${args.to} tokenId=${args.tokenId}`)
  }
  if (eventName === 'AdminRegistered') {
    lines.push('NOTE: owner-only backdoor mint (no SPACE ID signer). Launchpad buy gate trusts this NFT.')
  }
  if (eventName === 'SignerChanged') {
    lines.push('NOTE: new signer can mint valid Agent IDs via register(); treat as gate-key rotation.')
  }
  return { severity: sev, text: lines.join('\n'), eventName }
}

export async function sendWebhook(url, payload) {
  if (!url) return false
  const body = typeof payload === 'string'
    ? JSON.stringify({ text: payload })
    : JSON.stringify(payload)
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body,
  })
  if (!res.ok) throw new Error(`webhook ${res.status}: ${await res.text().catch(() => '')}`)
  return true
}

/** Slack/Discord-ish: prefer {text}; also send severity for custom receivers. */
export function webhookBody(alert) {
  return {
    text: alert.text,
    severity: alert.severity,
    event: alert.eventName,
  }
}
