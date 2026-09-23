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

-- Cost realism: every fill's actual price/commission against what the order expected,
-- so slippage is a queryable number rather than a guess. Written from
-- storage/fill_log.py, fed by a broker-specific fill poller (IBKR's fills arrive
-- asynchronously; see broker/ibkr_broker.py's poll_fills()) -- deliberately separate
-- from `orders`, which records the request, not the outcome.
CREATE TABLE IF NOT EXISTS fills (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    client_order_id TEXT NOT NULL,
    broker_order_id TEXT NOT NULL,
    symbol TEXT NOT NULL,
    side TEXT NOT NULL,
    qty REAL NOT NULL,
    expected_price REAL NOT NULL,
    actual_price REAL NOT NULL,
    slippage REAL NOT NULL,   -- (actual - expected) signed so positive always costs money
    commission REAL NOT NULL,
    commission_currency TEXT NOT NULL,
    currency TEXT NOT NULL DEFAULT 'USD',  -- the instrument's trading currency
    fx_cost REAL NOT NULL DEFAULT 0.0      -- estimated, in `currency`; see Settings.fx_cost_per_fill_pct
);
-- (currency/fx_cost were added after `fills` first shipped -- db.py's _ADDED_COLUMNS
-- adds them to a database created before that.)

CREATE INDEX IF NOT EXISTS idx_fills_client_order_id ON fills (client_order_id);

-- Measured FX cost: every actual currency conversion the broker executed (e.g. an IBKR
-- GBP.USD trade), with its real rate and commission -- as opposed to fills.fx_cost,
-- which is only an estimate. Written from execution/fill_recorder.py.
CREATE TABLE IF NOT EXISTS fx_conversions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    broker_order_id TEXT NOT NULL,
    pair TEXT NOT NULL,        -- e.g. 'GBP.USD'
    side TEXT NOT NULL,        -- 'buy' = bought the base currency (GBP in GBP.USD)
    amount REAL NOT NULL,      -- in the base currency
    rate REAL NOT NULL,        -- quote currency per unit of base
    commission REAL NOT NULL,
    commission_currency TEXT NOT NULL
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

-- Every unhandled error the event loop caught, for the go-live gate's "no unhandled
-- errors in the last N days" check (GOLIVE-003) -- structlog/Telegram alert on its own
-- isn't queryable, so this is the durable record.
CREATE TABLE IF NOT EXISTS errors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    message TEXT NOT NULL
);

-- Single-row table (id always 1): a human operator's record of having deliberately
-- exercised the kill switch and a restart/reconciliation in paper, once each -- the
-- go-live gate's "kill switch and reconciliation tested" check (GOLIVE-004). Nothing
-- here can be set by an automated process; only an explicit CLI/dashboard action writes
-- to it, since the whole point is a human vouching that they did the drill.
CREATE TABLE IF NOT EXISTS go_live_checklist (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    kill_switch_tested_at TEXT,
    reconciliation_tested_at TEXT
);
