# Intraday Trading System

An automated intraday equities trading system for a £10,000 account, traded via Alpaca
or Interactive Brokers (US equities/ETFs only — no UK-listed shares, see RISK-027).
Paper trading only until the go-live gate in
[`docs/GO_LIVE_CHECKLIST.md`](docs/GO_LIVE_CHECKLIST.md) is passed (that file arrives in
step 10 — see [`docs/PLAN.md`](docs/PLAN.md) for the full build order).

Two strategies only, each replicated from a published paper as literally as the paper's
text allows, with every assumption flagged: see [`docs/PLAN.md`](docs/PLAN.md) section 5
for the current rule summaries and open questions — **read that before touching
`strategies/`**.

1. Opening Range Breakout on "Stocks in Play" (Zarattini, Barbon & Aziz, 2024). **Not
   started** — waiting on its own `docs/STRATEGY_SPEC_SPY.md`-equivalent spec file.
2. SPY intraday momentum / "noise area" (Zarattini, Aziz & Barbon, 2024, building on Gao,
   Han, Li & Zhou, 2018, JFE). **Built** — `strategies/spy_momentum.py`, from
   [`docs/STRATEGY_SPEC_SPY.md`](docs/STRATEGY_SPEC_SPY.md).

## Status

Steps 1–6 and 8–10 of 10 done (see `docs/PLAN.md`); step 7 (ORB) still waiting on its
paper spec. Broker interface + Alpaca paper adapter + historical data client + SQLite bar
store + exchange calendar/clock + RiskManager (every hard risk limit, 100% branch
coverage) + kill switch + event-driven backtester with a cost model and a structural
no-look-ahead guarantee + validation module (trial registry, CSCV/PBO, PSR/MinTRL/DSR) +
the SPY intraday momentum strategy (`strategies/spy_momentum.py`, both a `house_risk` and
a `paper_faithful`-for-replication-only mode, plus its 192-config parameter grid in
`strategies/spy_grid.py`) + paper-trading loop with reconciliation and Telegram alerting
+ a 4-page Streamlit dashboard + the go-live checklist (`docs/GO_LIVE_CHECKLIST.md`),
enforced in code by `golive/gate.py` and surfaced via both the CLI (`golive status`) and
the dashboard's Journal & Go-Live page.

`run-paper` still runs with zero strategies attached by default (nothing wires the SPY
strategy into `execution/wiring.py` automatically — see `docs/PLAN.md` §14), so most of
the dashboard is still an honest empty state, and two of the six go-live checks can never
fully pass yet either (holdout validation and the expected-band/slippage comparison
aren't implemented — see `docs/PLAN.md` §13). The SPY strategy itself has never been run
against real historical data in this environment (no outbound network access here) —
`uv run intraday-trading backtest spy --start ... --end ...` is built and tested (see
`docs/PLAN.md` §14) but still needs to actually be run, with real Alpaca paper keys, and
its printed CSCV/PBO verdict and paper-replication numbers checked against the paper's
own Table 3, before this strategy is validated for paper trading.

An Interactive Brokers adapter (`broker/ibkr_broker.py`, via `ib_async`) now exists
alongside Alpaca's, implementing the exact same `Broker` interface — `execution/wiring.py`
and the CLI's `--broker` flag pick which one `RiskManager` trades through, unchanged
either way. It adds cost-realism logging (`storage/fill_log.py`: expected vs. actual
fill price, commission, signed slippage, and a per-fill FX cost estimate; plus
`storage/fx_conversion_log.py`: every GBP↔USD conversion IBKR actually executes, with
its real rate and commission), reconnect-with-backoff for IBKR's persistent
socket connection, and duplicate-order prevention (RISK-028) that also protects the
Alpaca path. Like Alpaca, it has never actually been run against a live Gateway in this
environment (no outbound network access here) — the adapter is fully unit-tested against
a fake `IB` client, but connecting to a real paper Gateway and confirming an order
round-trips correctly is still an outstanding manual step.

## Safety model, short version

- `LIVE_TRADING=false` by default, everywhere, always. Flipping it requires an explicit
  `.env` confirmation string **and** passing the go-live checklist — see `CLAUDE.md`.
- Every order passes through `RiskManager`, which is the only code allowed to call the
  broker's order-placement methods, and which fails closed on any unexpected error.
- Hard limits (same for either broker): 1% max risk per trade, 3% max daily loss (halts
  the rest of the day), 15% max drawdown from peak (halts until manually re-enabled), 5
  max open positions, no leverage/margin (cash account only — RISK-026), US-listed/USD
  instruments only (RISK-027).
- A kill switch (CLI, a file flag, and a dashboard button) cancels all orders and flattens
  all positions from any of three independent entry points.
- A signal's deterministic `client_order_id` is checked against the order log before
  resubmission, so a crash-and-restart retry can never create a duplicate order
  (RISK-028).

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

**To trade through Interactive Brokers instead of (or alongside) Alpaca**: install and
run [IB Gateway](https://www.interactivebrokers.com/en/trading/ibgateway-stable.php) (or
TWS) in **paper** mode and log in — this codebase never launches or configures Gateway
itself, it only connects to a socket Gateway already has open. Paper mode listens on
port `4002` by default (`IBKR_PORT` in `.env`); nothing in this codebase can reach the
live port (`4001`) unless `LIVE_TRADING=true`, which itself needs the confirmation
string above. Alpaca paper keys are still needed even when trading through IBKR — market
data (bars) always comes from Alpaca (see `execution/wiring.py`'s module docstring).

## Running things

```powershell
uv run intraday-trading status      # sanity-check config, confirms LIVE_TRADING=false
uv run pytest                       # full test suite
uv run pytest -k SAFE                # just the safety-invariant tests, e.g.
uv run ruff check .
uv run mypy src
```

```powershell
uv run intraday-trading run-paper --symbols SPY,AAPL              # Alpaca paper (default)
uv run intraday-trading run-paper --symbols SPY --broker ibkr     # IB Gateway paper instead
uv run intraday-trading kill --broker ibkr                        # trips the kill switch now
```

Both `--broker` values talk to that broker's **paper** endpoint only — `.live()` exists
on both adapters but neither this CLI nor `execution/wiring.py` ever calls it (see
CLAUDE.md). `run-paper` attaches `SpyMomentumStrategy` only when `SPY` is in `--symbols`,
so other symbols just get session/risk bookkeeping and reconciliation without a trade
proposed for them.

```powershell
# Compares the running paper session's P&L against buy-and-hold of --symbol over the
# same window, using IBKR's account state and historical prices. Needs a run-paper
# session already begun today. --notify also sends it to Telegram.
uv run intraday-trading report daily --symbol SPY --notify
```

```powershell
# Fetches real SPY minute bars, runs the full 192-config house_risk grid plus the
# paper's own paper_faithful reference config, logs every trial. Needs real Alpaca paper
# keys and network access -- see docs/PLAN.md §14 for what to check in the output.
uv run intraday-trading backtest spy --start 2015-01-01 --end 2024-05-01
```

Budget roughly 2–3 hours for that full 2015–2024 range (about 50–60 µs per bar per
config, measured; your PC may differ). It prints one `[n/192]` line per finished config.
Try a short range first (e.g. `--start 2024-01-01 --end 2024-05-01`, a few minutes) to
check your keys and the pipeline. Each config runs with its own fresh, in-memory risk
state (BT-008), so a backtest never reads or changes the paper bot's real halt state or
rejection log in `data\trading.db`. It only adds bars and trial-registry rows.

```powershell
uv run intraday-trading backtest summary                               # the numbers, in plain English
uv run intraday-trading golive status --strategies spy_momentum       # every check + verdict
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

**To preview what a populated dashboard looks like**, without touching real trading
data:

```powershell
uv run intraday-trading seed-demo-data   # writes to data\demo.db by default
$env:DATABASE_PATH = "data\demo.db"
uv run streamlit run dashboard\main.py
```

Every number in `data\demo.db` is synthetic (`dev/demo_data.py`) — the command refuses
to write to your real `DATABASE_PATH`, and this file is never read by anything except
what you deliberately point at it.

## Repo layout

```
trading/
├── src/intraday_trading/
│   ├── config.py         Settings + RiskLimits (pydantic-settings, env-driven)
│   ├── cli.py             CLI entry point
│   ├── broker/            Broker interface + Alpaca + IBKR (ib_async) adapters (step 2)
│   ├── data/               Minute-bar client + bar store              (step 2)
│   ├── risk/                RiskManager — the only path to the broker  (step 3)
│   ├── sizing/               Position sizer (ATR/volatility-based)      (step 3)
│   ├── execution/              Order/fill/reconciliation engine          (step 2/3)
│   ├── backtest/                 Event-driven backtester + cost model      (step 4)
│   ├── validation/                 CSCV/PBO, PSR, MinTRL, DSR, trial registry (step 5)
│   ├── universe/                     "Stocks in play" scanner              (step 7, TBD)
│   ├── strategies/                     spy_momentum.py + spy_grid.py (done, step 6);
│   │                                    ORB strategy TBD (step 7)
│   ├── golive/                            The go-live gate (step 10)
│   ├── session/                            Exchange calendar/clock, timezones (step 2)
│   ├── state/                                Restart-safe state + reconciler   (step 8)
│   ├── alerting/                               Telegram                        (step 8)
│   ├── reporting/                               Bot vs. buy-and-hold benchmark
│   └── killswitch/                               Kill switch                    (step 3)
├── dashboard/            Streamlit app, 4 pages: main.py + pages/ + lib/     (step 9)
├── docs/                 PLAN.md (this build's design doc + paper summaries),
│                          GO_LIVE_CHECKLIST.md (step 10),
│                          STRATEGY_SPEC_SPY.md (step 6)
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
