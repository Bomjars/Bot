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
