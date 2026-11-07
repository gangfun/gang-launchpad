/** Agent-rail BFF client. Real Binance web sign-in when the BFF reports stub: false. */
const BASE = '/api/agent-wallet'

async function req(path, { method = 'GET', csrf, body } = {}) {
  const headers = { Accept: 'application/json' }
  if (csrf) headers['X-CSRF-Token'] = csrf
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  const res = await fetch(`${BASE}${path}`, {
    method,
    credentials: 'same-origin',
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const json = await res.json().catch(() => ({}))
  if (!res.ok) {
    const err = new Error(json?.message || `agent-wallet ${res.status}`)
    err.status = res.status
    err.payload = json
    throw err
  }
  return json?.data ?? json
}

export const agentApi = {
  getSession: () => req('/session'),
  beginSignin: (csrf) => req('/signins', { method: 'POST', csrf }),
  pollSignin: (uid) => req(`/signins/${encodeURIComponent(uid)}`),
  simulateSignin: (uid, csrf, address) =>
    req(`/signins/${encodeURIComponent(uid)}/simulate`, {
      method: 'POST',
      csrf,
      body: address ? { address } : {},
    }),
  disconnect: (csrf) => req('/session', { method: 'DELETE', csrf }),
}

export const AGENT_SIGNIN_POLL_MS = 2000
export const AGENT_SIGNIN_TIMEOUT_MS = 300_000
