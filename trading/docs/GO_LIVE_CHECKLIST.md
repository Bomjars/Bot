# Go-live checklist

Paper trading only, always, until every item below is met. This is not a formality: the
system enforces it in code (`src/intraday_trading/golive/gate.py`), and the dashboard's
"GO LIVE" button (Journal & Go-Live page) is disabled unless every item is met. There is
still no code path that can place a live order today — `AlpacaBroker.paper()` is the only
broker constructor that exists (see `CLAUDE.md`) — so even a fully passed gate does not by
itself enable live trading; it only removes the go-live *validation* blocker. Actually
flipping `LIVE_TRADING=true` additionally requires the exact confirmation string in
`.env` (`LIVE_TRADING_CONFIRMATION`), which is a deliberate, separate, human step.

## The six checks

Run `uv run intraday-trading golive status --strategies orb,spy_momentum` (or open the
Journal & Go-Live dashboard page) to see these evaluated live against real data. Nothing
here is ever guessed or faked — a check that cannot yet be computed (because the
infrastructure it depends on doesn't exist yet) is reported as **not met**, with an
explicit reason, rather than skipped or assumed.

1. **Validation and holdout passed.** Each strategy must pass CSCV/PBO (Bailey, Borwein,
   López de Prado & Zhu, 2015) on its full trial registry — computed live from
   `TrialRegistry.daily_pnl_matrix()`. This is necessary but **not sufficient**: a
   separate holdout-set validation step (train/validate on disjoint date ranges) is not
   implemented yet, so this check can never fully pass today even for a strategy with a
   clean CSCV/PBO result. See `docs/PLAN.md` for the holdout-validation gap.
2. **≥ `GO_LIVE_MIN_PAPER_DAYS` (default 30) paper-trading days within the expected band,
   slippage measured.** The day count itself is real (`OrderLog.count_distinct_days()`),
   but the "expected band" comparison against the backtest, and slippage measurement,
   aren't implemented yet (see the Paper vs Backtest dashboard page) — so, like check 1,
   this can never fully pass today even once the day count alone is satisfied.
3. **No unhandled errors in the last `GO_LIVE_MAX_ERRORS_LOOKBACK_DAYS` (default 14)
   days.** Every unhandled exception the paper-trading loop's `run_once()` catches is
   persisted to the `errors` table (`ErrorLog`) as well as alerted via Telegram. This
   check queries that table directly, so it's a genuine pass/fail once the loop has been
   running.
4. **Kill switch tested.** A human must have deliberately tripped the kill switch in
   paper trading and confirmed it worked (all orders cancelled, all positions flattened,
   trading halted), then recorded that with
   `uv run intraday-trading golive mark-kill-switch-tested` or the matching dashboard
   button. Nothing automated can satisfy this — it exists specifically because a human
   needs to have actually run the drill, not just trust that the code is correct.
5. **Reconciliation tested.** A human must have deliberately restarted the paper-trading
   loop (or otherwise forced a state/broker desync) and confirmed the reconciler caught
   and corrected it, then recorded that with
   `uv run intraday-trading golive mark-reconciliation-tested` or the matching dashboard
   button. Same reasoning as check 4.
6. **Live equity cap configured at ≤ £3,000.** `LIVE_EQUITY_CAP_GBP` in `.env` must be
   set to a positive value no greater than £3,000 (per the original spec: "start live
   with ≤ £2–3k; scale only after 3 months matching paper"). This is a config check, not
   a behavioural one — the actual enforcement of the cap happens at
   `RiskManager.live_notional_cap_usd`, which rejects any order whose notional would
   exceed the GBP cap converted to USD via `APPROX_GBP_USD_RATE`, and which is wired to a
   non-`None` value only when `settings.live_trading` is `True`.

## After the gate passes

The gate passing is the validation-and-drill half of "ready." The original spec's full
condition for actually scaling further is: **3 months of live trading matching the paper
results**, still capped at ≤ £3,000, before any increase. That 3-month comparison isn't
something code can check in advance — it's a standing review, not a one-time gate.

## What is deliberately NOT in this checklist

- **Broker/API reliability, margin calls, regulatory changes** — operational risks, not
  validation risks; covered by the kill switch and RiskManager's hard limits, not this
  gate.
- **Strategy performance being "good enough"** — CSCV/PBO tells you whether a result is
  likely to be overfit, not whether it's profitable enough to bother trading; that's a
  human judgement call once the validation report is in front of you. Per `CLAUDE.md`
  rule 7, PBO/PSR/DSR/MinTRL results must never be used to go back and tune parameters —
  "don't trade it" is an accepted outcome of this process, not a bug to route around.
