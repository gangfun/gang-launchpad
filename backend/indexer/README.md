# Gang indexer

监听 Launchpad 的 `Created / Buy / Sell / Graduated` 事件写入 SQLite（Node 内置 `node:sqlite`），并提供网站和 Skill 用的 JSON 接口。

```bash
# v4 mainnet defaults (override as needed)
GANG_LAUNCHPAD=0x86854E8ee7D438ca9B52407DCF92D1616385dDcc \
GANG_START_BLOCK=128968738 \
GANG_RPC_URL=https://bsc-rpc.publicnode.com npm start
```
Wipe or raise `GANG_START_BLOCK` when switching from v3 so event history does not mix.

| 接口 | 说明 |
|---|---|
| `GET /search?q=<address prefix \| symbol \| name>` | 最多 8 条匹配 |
| `GET /stats` | 代币数、毕业数、成交数、24h 成交量、累计手续费 |
| `GET /tokens?sort=new\|hot\|graduated\|progress&limit=50` | 榜单。hot 按 24h 成交量 |
| `GET /tokens/:addr` | 单个代币：价格、FDV、进度、持有人数、24h 量 |
| `GET /tokens/:addr/trades?limit=50` | 成交记录，新到旧 |
| `GET /tokens/:addr/holders?limit=50` | 持有人和占比 |
| `GET /tokens/:addr/candles?res=1m\|5m\|15m\|1h\|4h\|1d&since=<ts>` | OHLCV，价格单位 BNB/token，量单位 BNB |

价格由事件里的储备状态按曲线公式重算，不依赖额外 RPC 调用；`getLogs` 区间会根据 RPC 限制自动收缩。
