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

Step 10 of 10 done (see `docs/PLAN.md`): broker interface + Alpaca paper adapter +
historical data client + SQLite bar store + exchange calendar/clock + RiskManager
(every hard risk limit, 100% branch coverage) + kill switch + event-driven backtester
with a cost model and a structural no-look-ahead guarantee + validation module (trial
registry, CSCV/PBO, PSR/MinTRL/DSR) + paper-trading loop with reconciliation and
Telegram alerting + a 4-page Streamlit dashboard + the go-live checklist
(`docs/GO_LIVE_CHECKLIST.md`), enforced in code by `golive/gate.py` and surfaced via both
the CLI (`golive status`) and the dashboard's Journal & Go-Live page. No strategy logic
yet — waiting on the paper text, see `docs/PLAN.md` §5; `run-paper` currently runs with
zero strategies attached, so most of the dashboard is an honest empty state, and two of
the six go-live checks can never fully pass yet either (holdout validation and the
expected-band/slippage comparison aren't implemented — see `docs/PLAN.md` §13) — this is
the correct state for a system that has never placed a trade.

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

```powershell
uv run intraday-trading run-paper --symbols SPY,AAPL   # starts the paper-trading loop
uv run intraday-trading kill                            # trips the kill switch now
```

Both talk to Alpaca's **paper** endpoint only — there is no live path in this codebase
yet (see CLAUDE.md). `run-paper` currently runs with an empty strategy list (steps 6–7
aren't built), so it will do session/risk bookkeeping and reconciliation without ever
proposing a trade.

```powershell
uv run intraday-trading golive status --strategies orb,spy_momentum   # every check + verdict
uv run intraday-trading golive mark-kill-switch-tested                # after running the drill in paper
uv run intraday-trading golive mark-reconciliation-tested             # after running the drill in paper
```

See `docs/GO_LIVE_CHECKLIST.md` for what each check means and why two of them can never
fully pass yet.

## Dashboard

```powershell
uv run streamlit run dashboard\main.py
```

Or double-click `start_dashboard.bat` once `uv sync --extra dev --extra dashboard` has
been run. Opens at `http://localhost:8501`. To view it on your phone: same Wi-Fi, then
`http://<this-PC's-LAN-IP>:8501` — no extra setup needed since Streamlit binds to all
interfaces when you use `--server.address 0.0.0.0` (add that flag if you want LAN
access; the default is localhost-only). Set `DASHBOARD_PASSWORD` in `.env` before doing
that — the app requires it whenever it's set, and skips the check entirely when it
isn't (see `docs/PLAN.md` §12).

Read-only except three controls (kill switch, pause entries, flatten one position), all
routed through `RiskManager` — the dashboard itself never calls the broker's
order-placement methods (enforced by a static test, `DASH-001`). Since this build has
never placed a trade yet, most of the Paper vs Backtest and Journal pages are an honest
empty state rather than placeholder numbers; the Validation Report page computes
CSCV/PBO/PSR/DSR live from whatever's actually in the trial registry.

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
├── dashboard/            Streamlit app, 4 pages: main.py + pages/ + lib/     (step 9)
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
