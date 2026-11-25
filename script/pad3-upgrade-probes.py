#!/usr/bin/env python3
"""The probe lists UpgradeGangLaunchpad3 needs (PAD3_PROMOTE_PROBES, PAD3_BASE_PROBES), read from the chain.

Public nodes return incomplete logs, so nothing here uses eth_getLogs: every token of the pad is asked (Multicall3) for its
kind, promoter share, opening base and agent window; the wallets of the tokens with a share come from the API's trades and
each one's binding is read on chain (curve trades: a wallet bound only through a pool module is not found). Read-only. Needs `cast` (Foundry).

  python3 -I script/pad3-upgrade-probes.py [--rpc URL] [--api https://gang.fun/api] [--pad 0x...]
"""
import argparse, collections, json, subprocess, sys, time, urllib.request

a = argparse.ArgumentParser()
a.add_argument('--rpc', default='https://bsc-dataseed.bnbchain.org')
a.add_argument('--api', default='https://gang.fun/api')
a.add_argument('--pad', default='0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29')
A = a.parse_args()
PAD, MULTICALL = A.pad[2:].lower(), '0xcA11bde05977b3631167028862bE2a173976CA11'
word = lambda n: '%064x' % n


def sel(sig):
    return subprocess.check_output(['cast', 'sig', sig], text=True).strip()[2:]


def post(body):
    req = urllib.request.Request(A.rpc, json.dumps(body).encode(), {'content-type': 'application/json', 'user-agent': 'curl'})
    return json.load(urllib.request.urlopen(req, timeout=30))


def call(data):
    err = None
    for i in range(8):
        try:
            r = post({'jsonrpc': '2.0', 'id': 1, 'method': 'eth_call', 'params': [{'to': MULTICALL, 'data': data}, 'latest']})
            if 'result' in r:
                return r['result']
            err = r.get('error')
        except Exception as e:
            err = e
        time.sleep(1)
    sys.exit(f'eth_call failed: {err}')


def multi(datas):
    """tryAggregate(false, (pad, data)[]) -> [(ok, hex)]"""
    heads, body, off = [], '', 32 * len(datas)
    for d in datas:
        n = len(d) // 2
        enc = '0' * 24 + PAD + word(64) + word(n) + d.ljust((n + 31) // 32 * 64, '0')
        heads.append(word(off))
        body += enc
        off += len(enc) // 2
    r = call('0x' + sel('tryAggregate(bool,(address,bytes)[])') + word(0) + word(64) + word(len(datas)) + ''.join(heads) + body)[2:]
    arr, out = r[128:], []
    for i in range(int(r[64:128], 16)):
        o = int(arr[i * 64:i * 64 + 64], 16) * 2
        size = int(arr[o + 128:o + 192], 16)
        out.append((int(arr[o:o + 64], 16), arr[o + 192:o + 192 + size * 2]))
    return out


def get(path):
    for i in range(5):
        try:
            return json.load(urllib.request.urlopen(urllib.request.Request(A.api + path, headers={'user-agent': 'curl'}), timeout=30))
        except Exception as e:
            err = e
            time.sleep(1)
    sys.exit(f'API {path}: {err}')


n = int(multi([sel('tokenCount()')])[0][1], 16)
tokens = []
for i in range(0, n, 200):
    tokens += ['0x' + x[1][-40:] for x in multi([sel('allTokens(uint256)') + word(j) for j in range(i, min(n, i + 200))])]
if len(set(tokens)) != n:
    sys.exit(f'{len(set(tokens))} tokens read of {n}')


def each(sig):
    """[(ok, hex)] of every token; one that does not answer stops the run (a missing answer is not "none")"""
    s, out = sel(sig), []
    for i in range(0, n, 150):
        out += multi([s + '0' * 24 + t[2:] for t in tokens[i:i + 150]])
    bad = [t for t, x in zip(tokens, out) if not x[0] or not x[1]]
    if bad:
        sys.exit(f'{sig}: {len(bad)} token(s) did not answer, first {bad[0]}')
    return out


print('tokens', n, 'kinds', dict(collections.Counter(int(x[1], 16) for x in each('kindOf(address)'))))
share = [t for t, x in zip(tokens, each('promoteOf(address)')) if int(x[1][:64], 16)]
base = [t for t, x in zip(tokens, each('baseVaultOf(address)')) if int(x[1], 16)]
print('agent windows', sum(1 for x in each('agentOpenAt(address)') if int(x[1], 16)))
GS = [t for t, x in zip(tokens, each('gangSwapMigratorOf(address)')) if int(x[1], 16)]
grad = [(t, int(x[1][:64], 16)) for t, x in zip(tokens, each('gradReward(address)')) if int(x[1][:64], 16)]
names = {1: 'curve', 2: 'booked', 3: 'refunded', 4: 'closed'}
# information only: UpgradeGangLaunchpad3 finds these by itself and compares every one
print('GangSwap tokens', len(GS), '; graduation rewards', dict(collections.Counter(names[s] for _, s in grad)), '; both', len(set(GS) & {t for t, _ in grad}))
print('tokens with a promoter share', len(share), '; with an opening base', len(base))

pairs = []
for t in share:
    wallets, trades, seen = set(), 0, set()
    for page in range(1000):
        d = get(f'/v3/tokens/{t}/trades?limit=200&offset={page * 200}')
        items = d.get('items') or d.get('trades') or []
        fresh = [x for x in items if (x.get('tx'), x.get('side'), x.get('tokens'), x.get('trader')) not in seen]
        seen |= {(x.get('tx'), x.get('side'), x.get('tokens'), x.get('trader')) for x in items}
        wallets |= {x['trader'].lower() for x in items if x.get('trader')}
        trades += len(fresh)
        if len(items) < 200:
            break
        if not fresh:
            sys.exit(f'{t}: the API repeats its pages, the trade list is incomplete')
    s, ws, bound = sel('bindingOf(address,address)'), sorted(wallets), 0
    for i in range(0, len(ws), 100):
        chunk = ws[i:i + 100]
        for w, (ok, ret) in zip(chunk, multi([s + '0' * 24 + t[2:] + '0' * 24 + w[2:] for w in chunk])):
            if not ok:
                sys.exit(f'bindingOf({t}, {w}) did not answer')
            if int(ret[:64], 16):
                pairs += [t, w]
                bound += 1
    print(' ', t, 'trades', trades, 'wallets', len(ws), 'bound', bound)
print('PAD3_PROMOTE_PROBES=' + ','.join(pairs))
print('PAD3_BASE_PROBES=' + ','.join(base))
