import { createPublicClient, http, fallback, zeroAddress } from 'viem'
import { bsc } from 'viem/chains'
import { EVENTS, MINT_EVENTS, SEVERITY } from './abi.js'
import { formatAlert, sendWebhook, webhookBody } from './alert.js'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

export class AgentIdMonitor {
  constructor({
    rpcUrls,
    registry,
    startBlock,
    batch = 50,
    stateFile = './agent-id-monitor.state.json',
    webhook,
    logMints = false,
    alertMinSeverity = 'medium',
    log = console.log,
  }) {
    this.registry = registry
    this.startBlock = BigInt(startBlock)
    this.batch = BigInt(batch)
    this.stateFile = stateFile
    this.webhook = webhook || null
    this.logMints = logMints
    this.alertMinSeverity = alertMinSeverity
    this.log = log
    const urls = (rpcUrls || []).filter(Boolean)
    const transport = urls.length > 1
      ? fallback(urls.map((u) => http(u, { retryCount: 2, retryDelay: 800 })), { rank: true, retryCount: 3 })
      : http(urls[0], { retryCount: 3, retryDelay: 800 })
    this.client = createPublicClient({ chain: bsc, transport })
    this.events = this.logMints ? [...EVENTS, ...MINT_EVENTS] : EVENTS
    this.rank = { critical: 40, high: 30, medium: 20, low: 10, info: 0 }
  }

  loadCursor() {
    try {
      const j = JSON.parse(readFileSync(this.stateFile, 'utf8'))
      if (j.lastBlock != null) return BigInt(j.lastBlock)
    } catch {}
    return this.startBlock - 1n
  }

  saveCursor(block) {
    mkdirSync(dirname(this.stateFile) || '.', { recursive: true })
    writeFileSync(this.stateFile, JSON.stringify({ lastBlock: block.toString(), updatedAt: new Date().toISOString() }))
  }

  shouldAlert(eventName) {
    const sev = SEVERITY[eventName] || 'info'
    return (this.rank[sev] ?? 0) >= (this.rank[this.alertMinSeverity] ?? 20)
  }

  async handleLog(l) {
    // Skip non-mint Transfers when logging mints (soulbound: only mint from 0x0)
    if (l.eventName === 'Transfer') {
      if (l.args.from?.toLowerCase() !== zeroAddress) return
    }
    const alert = formatAlert({
      eventName: l.eventName,
      args: l.args,
      blockNumber: l.blockNumber.toString(),
      transactionHash: l.transactionHash,
      registry: this.registry,
    })
    this.log(alert.text)
    if (!this.shouldAlert(l.eventName)) return
    if (this.webhook) {
      try {
        await sendWebhook(this.webhook, webhookBody(alert))
      } catch (e) {
        this.log('webhook error:', e.message)
      }
    }
  }

  async syncOnce() {
    const head = await this.client.getBlockNumber()
    let from = this.loadCursor() + 1n
    let span = this.batch
    while (from <= head) {
      const to = from + span - 1n > head ? head : from + span - 1n
      let logs
      try {
        logs = await this.client.getLogs({
          address: this.registry,
          events: this.events,
          fromBlock: from,
          toBlock: to,
        })
      } catch (e) {
        if (/limit|range|too many|exceed|Invalid parameters/i.test(e.message) && span > 50n) {
          span /= 2n
          this.log(`getLogs limited, span -> ${span}`)
          await new Promise((r) => setTimeout(r, 400))
          continue
        }
        throw e
      }
      logs.sort((a, b) =>
        a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : Number(a.blockNumber - b.blockNumber),
      )
      for (const l of logs) await this.handleLog(l)
      this.saveCursor(to)
      if (logs.length) this.log(`scanned ${from}-${to}: ${logs.length} events`)
      from = to + 1n
      if (span < this.batch) span = span * 2n > this.batch ? this.batch : span * 2n
      await new Promise((r) => setTimeout(r, 100))
    }
    return head
  }

  async run(intervalMs = 5000) {
    for (;;) {
      try {
        const head = await this.syncOnce()
        this.log(`ok @ ${head}`)
      } catch (e) {
        this.log('sync error:', e.message)
      }
      await new Promise((r) => setTimeout(r, intervalMs))
    }
  }
}
