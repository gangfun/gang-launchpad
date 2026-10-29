import { DatabaseSync } from 'node:sqlite'

export function openDb(path) {
  const db = new DatabaseSync(path)
  db.exec(`
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS tokens (
      address TEXT PRIMARY KEY, name TEXT, symbol TEXT, creator TEXT,
      created_block INTEGER, created_ts INTEGER, created_tx TEXT,
      real_bnb TEXT DEFAULT '0', sold TEXT DEFAULT '0', graduated INTEGER DEFAULT 0, pair TEXT,
      graduated_ts INTEGER, last_price TEXT DEFAULT '0', trades INTEGER DEFAULT 0, last_trade_ts INTEGER
    );
    CREATE TABLE IF NOT EXISTS trades (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      token TEXT, side TEXT, trader TEXT, bnb TEXT, fee TEXT, tokens TEXT, real_bnb TEXT, price TEXT,
      block INTEGER, ts INTEGER, tx TEXT, log_index INTEGER,
      UNIQUE(tx, log_index)
    );
    CREATE INDEX IF NOT EXISTS trades_token_ts ON trades(token, ts);
    CREATE INDEX IF NOT EXISTS trades_ts ON trades(ts);
    CREATE TABLE IF NOT EXISTS holders (
      token TEXT, holder TEXT, balance TEXT, PRIMARY KEY(token, holder)
    );
    CREATE TABLE IF NOT EXISTS handles (
      address TEXT PRIMARY KEY,
      handle TEXT NOT NULL DEFAULT '',
      checked_ts INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS handles_checked ON handles(checked_ts);
    CREATE TABLE IF NOT EXISTS curve_buyers (
      address TEXT PRIMARY KEY,
      is_agent INTEGER NOT NULL DEFAULT 0,
      checked_ts INTEGER NOT NULL DEFAULT 0,
      first_buy_ts INTEGER
    );
    CREATE INDEX IF NOT EXISTS curve_buyers_agent ON curve_buyers(is_agent);
  `)
  // Repair: older indexer zeroed real_bnb on Graduated → UI showed 0/20
  try {
    db.prepare("UPDATE tokens SET real_bnb='20000000000000000000' WHERE graduated=1 AND CAST(real_bnb AS REAL) < 1e19").run()
  } catch { /* ignore */ }
  return db
}

export const getMeta = (db, k) => db.prepare('SELECT value FROM meta WHERE key=?').get(k)?.value
export const setMeta = (db, k, v) => db.prepare('INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value').run(k, String(v))
