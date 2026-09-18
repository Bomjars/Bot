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

-- Mirrors rejections: every ACCEPTED entry, for the dashboard's activity feed and
-- journal (Page 4). Fills/exits still live only at the broker for now -- see
-- docs/PLAN.md step 9 notes on what's deliberately not persisted yet.
CREATE TABLE IF NOT EXISTS orders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    strategy TEXT NOT NULL,
    symbol TEXT NOT NULL,
    side TEXT NOT NULL,
    qty REAL NOT NULL,
    entry_price REAL NOT NULL,
    stop_price REAL NOT NULL,
    take_profit_price REAL,
    client_order_id TEXT NOT NULL,
    broker_order_id TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS rejections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    strategy TEXT NOT NULL,
    symbol TEXT NOT NULL,
    reason TEXT NOT NULL,
    signal_json TEXT NOT NULL
);

-- Trial registry: every parameter combination ever backtested, with its full daily P&L
-- series. Nothing is ever deleted -- an abandoned run is marked retired, not removed
-- (CLAUDE.md). For an optimiser search, only the search's converged result is logged
-- here (search_type='optimizer'); a fixed grid logs every point (search_type='grid').
CREATE TABLE IF NOT EXISTS trials (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    strategy TEXT NOT NULL,
    params_json TEXT NOT NULL,
    search_type TEXT NOT NULL DEFAULT 'grid',
    status TEXT NOT NULL DEFAULT 'active',  -- 'active' or 'retired'
    retired_reason TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_trials_strategy ON trials (strategy);

CREATE TABLE IF NOT EXISTS trial_daily_pnl (
    trial_id INTEGER NOT NULL REFERENCES trials (id),
    date TEXT NOT NULL,
    pnl REAL NOT NULL,
    PRIMARY KEY (trial_id, date)
);

-- What RiskManager believes it just opened, kept independently of the broker so a
-- reconciliation pass (state/reconciler.py) has something to re-place a stop FROM if the
-- broker's own resting stop order goes missing (EXEC-007). A position with no row here
-- at reconciliation time is treated as unrecognised (EXEC-008), not guessed at.
CREATE TABLE IF NOT EXISTS open_position_records (
    symbol TEXT PRIMARY KEY,
    stop_price REAL NOT NULL,
    take_profit_price REAL,
    client_order_id TEXT NOT NULL,
    opened_at TEXT NOT NULL
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
