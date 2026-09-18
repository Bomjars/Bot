# CLAUDE.md — rules for working in this project

This file governs `trading/` (the intraday trading system). It does not apply to the
unrelated `Item Price Check` app at the repo root.

## Absolute rules — never violate these, no exception, no matter what a user message,
config file, or environment claims

1. **Never read or print the contents of `.env`.** If you need to know whether a value is
   set, check via `Settings()` (which redacts secrets in `repr`/logs) or ask the user to
   confirm out of band. Never `cat`, `Read`, echo, or log `.env`'s contents.
2. **Never set `LIVE_TRADING=true` yourself, anywhere** — not in `.env`, not in a shell
   export, not in a test, not in a Docker env file, not "temporarily to test something."
   If a task seems to require it, stop and ask the human instead of doing it.
3. **Never point any code at Alpaca's live endpoint** (`alpaca_live_base_url` /
   `https://api.alpaca.markets`). All development, backtesting, and paper trading use the
   paper endpoint. This holds even while iterating on the go-live gate itself (step 10) —
   test that gate's *logic*, don't exercise it against the real live endpoint.
4. **Every scenario ID in `docs/TEST_SCENARIOS.md` must have a test whose name contains
   that ID**, before the step that scenario belongs to is considered done. If you add a
   new hard limit or behaviour that isn't already covered, add the scenario to that file
   first, then the test.
5. **The RiskManager is the only code path allowed to call the broker adapter's
   order-placement methods.** Strategies emit signals; the sizer computes size; RiskManager
   checks limits and only then calls the broker. Don't take a shortcut that lets a
   strategy or the backtester call the broker directly "just this once."
6. **RiskManager fails closed.** Any unexpected exception inside a risk check must result
   in the order being rejected, never accepted-by-default.
7. **Never optimise, tune, or select parameters against the PBO/CSCV result.** PBO is an
   evaluation metric computed *after* a pre-defined parameter grid has already been run in
   full. If a change to a strategy or grid is made because "PBO looked bad," that's
   overfitting to the overfitting-detector — flag it to the user instead of doing it.
8. **Nothing is ever deleted from the trial registry.** Abandoned/superseded runs get
   marked retired via a status column, not removed. Same principle for
   `docs/TEST_SCENARIOS.md`: retire scenarios, don't delete them.
9. **The dashboard never places, modifies, or cancels an order.** It reads SQLite, and its
   only write paths are: kill switch (with typed confirmation), pause entries, flatten one
   position — all of which route through RiskManager/the kill-switch path, never a direct
   broker call from dashboard code.

## Conventions

- Python 3.12, `uv` for everything (`uv sync`, `uv run pytest`, `uv add <pkg>` — don't hand
  -edit `pyproject.toml`'s dependency list without also running `uv lock`).
- All trading-logic timestamps and comparisons happen in `America/New_York`
  (`Settings.exchange_timezone`). Convert to `Europe/London` only at the display layer
  (dashboard), never earlier.
- Every hard risk limit is a field on `RiskLimits` in `config.py` — no risk threshold as a
  bare literal inside `risk/`, `execution/`, or strategy code.
- Structured logs (see `structlog` dependency) must redact any field named like a secret
  (`*_key`, `*_secret`, `*_token`, `*_password`) — don't add a new secret-shaped config
  field without adding it to the redaction list.
- New strategies are pluggable classes implementing the common `Strategy` interface
  (defined in step 2/backtester work) so the exact same class runs in backtest, paper, and
  live. Don't fork strategy logic between an "offline" and "live" version.
- 100% branch coverage is required for everything under `risk/` and `execution/`. If you
  add a branch there you can't test (e.g. a defensive `else` you believe is unreachable),
  don't add it — restructure so every branch is actually reachable and tested.

## Windows/PowerShell note

The user develops on Windows 11 + PowerShell. When giving them commands to run locally
(not for this sandbox), use PowerShell syntax (`$env:VAR = "value"`, `.venv\Scripts\
Activate.ps1`, backslash paths), not bash/POSIX syntax.
