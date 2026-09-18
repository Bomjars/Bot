-- Additive only: later steps add more CREATE TABLE IF NOT EXISTS statements here.
-- Nothing is ever dropped or altered destructively (see CLAUDE.md: the trial registry
-- and by extension this schema never lose history).

CREATE TABLE IF NOT EXISTS bars (
    symbol TEXT NOT NULL,
    ts TEXT NOT NULL,       -- ISO 8601, UTC
    feed TEXT NOT NULL,     -- 'iex' or 'sip' (DATA-001: never mix silently)
    open REAL NOT NULL,
    high REAL NOT NULL,
    low REAL NOT NULL,
    close REAL NOT NULL,
    volume REAL NOT NULL,
    PRIMARY KEY (symbol, ts, feed)
);

CREATE INDEX IF NOT EXISTS idx_bars_symbol_ts ON bars (symbol, ts);

CREATE TABLE IF NOT EXISTS rejections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    strategy TEXT NOT NULL,
    symbol TEXT NOT NULL,
    reason TEXT NOT NULL,
    signal_json TEXT NOT NULL
);

-- Single-row table (id always 1): RiskManager's halted state and today's/this week's
-- counters, so a restart resumes halted rather than silently trading again (RISK-008/009).
CREATE TABLE IF NOT EXISTS risk_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    trading_day TEXT,
    daily_starting_equity REAL,
    week_start TEXT,
    weekly_starting_equity REAL,
    peak_equity REAL,
    trades_today INTEGER NOT NULL DEFAULT 0,
    halted INTEGER NOT NULL DEFAULT 0,
    halt_type TEXT,
    halt_reason TEXT
);
