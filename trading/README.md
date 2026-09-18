# Intraday Trading System

An automated intraday equities trading system for a £10,000 account, traded via Alpaca
(US equities). Paper trading only until the go-live gate in
[`docs/GO_LIVE_CHECKLIST.md`](docs/GO_LIVE_CHECKLIST.md) is passed (that file arrives in
step 10 — see [`docs/PLAN.md`](docs/PLAN.md) for the full build order).

Two strategies only, each replicated from a published paper as literally as the paper's
text allows, with every assumption flagged: see [`docs/PLAN.md`](docs/PLAN.md) section 5
for the current rule summaries and open questions — **read that before touching
`strategies/`**.

1. Opening Range Breakout on "Stocks in Play" (Zarattini, Barbon & Aziz, 2024).
2. SPY intraday momentum / "noise area" (Zarattini, Aziz & Barbon, 2024, building on Gao,
   Han, Li & Zhou, 2018, JFE).

## Status

Step 4 of 10 done (see `docs/PLAN.md`): broker interface + Alpaca paper adapter +
historical data client + SQLite bar store + exchange calendar/clock + RiskManager
(every hard risk limit, 100% branch coverage) + kill switch + event-driven backtester
with a cost model and a structural no-look-ahead guarantee. No validation engine or
strategy logic yet.

## Safety model, short version

- `LIVE_TRADING=false` by default, everywhere, always. Flipping it requires an explicit
  `.env` confirmation string **and** passing the go-live checklist — see `CLAUDE.md`.
- Every order passes through `RiskManager`, which is the only code allowed to call the
  broker's order-placement methods, and which fails closed on any unexpected error.
- A kill switch (CLI, a file flag, and a dashboard button) cancels all orders and flattens
  all positions from any of three independent entry points.

Full details in `CLAUDE.md` and `docs/PLAN.md`.

## Setup (Windows 11 + PowerShell)

This project uses [`uv`](https://docs.astral.sh/uv/) for Python and dependency management
— it will fetch Python 3.12 itself if you don't already have it, no separate Python
install needed.

```powershell
# from the trading/ directory
uv sync --extra dev --extra dashboard

Copy-Item .env.example .env
notepad .env   # fill in your Alpaca PAPER keys — never the live ones for now
```

`.env` is gitignored. Never commit it, and never ask an assistant to print it — see
`CLAUDE.md`.

## Running things

```powershell
uv run intraday-trading status      # sanity-check config, confirms LIVE_TRADING=false
uv run pytest                       # full test suite
uv run pytest -k SAFE                # just the safety-invariant tests, e.g.
uv run ruff check .
uv run mypy src
```

`run-paper` and `kill` exist as CLI stubs today and will do something real starting step 3
(kill switch) and step 8 (paper-trading loop).

## Repo layout

```
trading/
├── src/intraday_trading/
│   ├── config.py         Settings + RiskLimits (pydantic-settings, env-driven)
│   ├── cli.py             CLI entry point
│   ├── broker/            Broker interface + Alpaca adapter          (step 2)
│   ├── data/               Minute-bar client + bar store              (step 2)
│   ├── risk/                RiskManager — the only path to the broker  (step 3)
│   ├── sizing/               Position sizer (ATR/volatility-based)      (step 3)
│   ├── execution/              Order/fill/reconciliation engine          (step 2/3)
│   ├── backtest/                 Event-driven backtester + cost model      (step 4)
│   ├── validation/                 CSCV/PBO, PSR, MinTRL, DSR, trial registry (step 5)
│   ├── universe/                     "Stocks in play" scanner              (step 7)
│   ├── strategies/                     ORB + SPY momentum strategy classes  (step 6/7)
│   ├── session/                          Exchange calendar/clock, timezones (step 2)
│   ├── state/                              Restart-safe state + reconciler   (step 8)
│   ├── alerting/                             Telegram                        (step 8)
│   └── killswitch/                             Kill switch                    (step 3)
├── dashboard/            Streamlit app, 4 pages                              (step 9)
├── docs/                 PLAN.md (this build's design doc + paper summaries),
│                          GO_LIVE_CHECKLIST.md (step 10)
└── tests/{unit,integration}/
```

`docs/TEST_SCENARIOS.md` (the test scenario registry for the whole build) lives at the
**repo root** (`../docs/TEST_SCENARIOS.md`), not under `trading/`, since it was specified
at the repo root.

## Research grounding

Backtests are validated with CSCV/PBO (Bailey, Borwein, López de Prado & Zhu, 2015),
Probabilistic Sharpe Ratio and Minimum Track Record Length (Bailey & López de Prado,
2012), and Deflated Sharpe Ratio (Bailey & López de Prado, 2014), against a mandatory
trial registry that never deletes a run. Published paper results are treated as an upper
bound, not a target — see `docs/PLAN.md` section 6 (McLean & Pontiff, 2016). "Don't trade
it" is an accepted outcome of this process.
