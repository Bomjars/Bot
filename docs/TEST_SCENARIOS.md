# Test Scenarios

Living document. Every scenario here must have at least one test whose name contains its
ID (e.g. `test_risk_001_daily_loss_halts_trading`). Nothing is deleted once a scenario ID
ships — if a scenario stops applying, mark it `Retired: <reason>` instead of removing it,
so history stays auditable (same principle as the trial registry).

**Priority**: `P0` must pass before any paper trading. `P1` must pass before any live
trading. Everything in `risk/` and `execution/` needs 100% branch coverage regardless of
individual scenario priority.

Scenario IDs are stable once assigned. New scenarios get new IDs appended to their
section; never renumber.

---

## SAFE — safety-critical invariants (config, kill switch, go-live gate)

| ID | Priority | Scenario |
|---|---|---|
| SAFE-001 | P0 | `Settings()` with no env vars set defaults `live_trading=False`. |
| SAFE-002 | P0 | `Settings(live_trading=True)` without the exact confirmation string raises a validation error and never constructs. |
| SAFE-003 | P0 | `Settings(live_trading=True, live_trading_confirmation="I UNDERSTAND THE RISK")` constructs successfully (this is the only way live_trading can be true). |
| SAFE-004 | P0 | The Alpaca broker adapter refuses to construct a live (non-paper) client unless `settings.live_trading is True` — i.e. even a correctly-confirmed live intent still requires the explicit live base URL, not just the flag. |
| SAFE-005 | P1 | The go-live gate (docs/GO_LIVE_CHECKLIST.md logic) returns `passed=False` with a specific unmet reason when any one of its checks is unmet, and `passed=True` only when all are met. |
| SAFE-006 | P0 | Application logs never contain the raw value of `ALPACA_API_KEY`, `ALPACA_SECRET_KEY`, `TELEGRAM_BOT_TOKEN`, or `DASHBOARD_PASSWORD` — structured logging redacts these fields by name. |
| SAFE-007 | P0 | Loading `.env` twice (module re-import) does not change `live_trading` from False to True as a side effect (no caching bug that skips validation on reload). |

## KILL — kill switch

| ID | Priority | Scenario |
|---|---|---|
| KILL-001 | P0 | CLI `kill` command cancels all open orders then flattens all open positions, in that order (cancel before flatten, so a fill racing the flatten can't leave a naked position). |
| KILL-002 | P0 | Creating the kill-switch file (`data/KILL_SWITCH`) is detected by the running event loop within one polling interval and triggers the same cancel-then-flatten sequence as the CLI. |
| KILL-003 | P0 | Dashboard kill-switch button requires the typed confirmation string before it calls the same kill path (no single click can trigger it). |
| KILL-004 | P0 | After a kill-switch trip, the system enters a halted state that blocks all new entries until manually re-enabled, even after a restart. |
| KILL-005 | P1 | Kill switch triggered mid-flatten (one leg fills, one is rejected) retries the rejected leg until flat or halts with an alert if it cannot confirm flat within a timeout. |
| KILL-006 | P0 | All three kill-switch entry points (CLI, file flag, dashboard) route through the exact same underlying function — no divergent code paths. |

## RISK — RiskManager hard limits (config-driven; fails closed)

| ID | Priority | Scenario |
|---|---|---|
| RISK-001 | P0 | An order sized so that (entry − stop) × shares exceeds `max_risk_per_trade_pct` of current equity is rejected. |
| RISK-002 | P0 | An order sized within the risk-per-trade limit, using the ATR-based stop distance, is accepted. |
| RISK-003 | P0 | An order that would open a 4th concurrent position when `max_open_positions=3` is rejected. |
| RISK-004 | P0 | An order whose notional exceeds `max_position_pct_of_equity` of equity is rejected, even if risk-per-trade is within limits (e.g. a very tight stop on a large notional). |
| RISK-005 | P0 | Any order implying leverage > `max_leverage` (1.0) is rejected. |
| RISK-006 | P0 | An order on a symbol in a configured leveraged-ETF exclusion list is rejected regardless of other checks. |
| RISK-007 | P0 | Once realised + unrealised daily P&L drops to −2% of the day's starting equity, RiskManager flattens all positions and blocks further entries for the rest of the session. |
| RISK-008 | P0 | Once realised weekly P&L drops to −5% of the week's starting equity, RiskManager halts entries for the rest of the week and stays halted after a restart until manually re-enabled. |
| RISK-009 | P0 | Once equity drawdown from its peak-since-inception reaches 10%, RiskManager flattens all positions, halts, and raises an alert — and remains halted after a restart until manually re-enabled. |
| RISK-010 | P0 | Every accepted entry order carries a bracket (stop-loss, and take-profit/exit leg if the strategy defines one) — an entry request without a valid stop is rejected before it reaches the broker adapter. |
| RISK-011 | P0 | The 11th order attempt in a session, after 10 already executed, is rejected regardless of the account's risk numbers otherwise being fine. |
| RISK-012 | P0 | An entry attempted before `no_entry_first_minutes` after the open is rejected. |
| RISK-013 | P0 | An entry attempted after `no_entry_last_minutes` before the close is rejected. |
| RISK-014 | P0 | All open positions are flattened automatically `flatten_before_close_minutes` before the close, without requiring a strategy signal. |
| RISK-015 | P0 | On a half-day (early close per Alpaca's calendar), the no-entry and flatten windows are computed from the actual early close time, not a hardcoded 16:00 ET. |
| RISK-016 | P0 | No entries are attempted on a day the exchange calendar marks as a holiday. |
| RISK-017 | P0 | An order on a symbol priced below `min_price_usd` is rejected. |
| RISK-018 | P0 | An order on a symbol whose trailing average dollar volume is below `min_avg_dollar_volume_usd` is rejected. |
| RISK-019 | P0 | An order on a symbol whose current quoted spread exceeds `max_spread_pct` is rejected. |
| RISK-020 | P0 | When RiskManager's own limit-check code raises an unexpected exception (simulated), the order is rejected (fail closed), not passed through, and the exception is logged and alerted. |
| RISK-021 | P0 | RiskManager is the only code path with a reference to the broker's order-placement method — a static/import-graph check (or equivalent runtime guard) confirms strategies and the sizer cannot call the broker adapter directly. |
| RISK-022 | P0 | Every rejection reason is persisted to the `rejections` table with the triggering order request and the specific limit breached, before the caller receives the rejection. |
| RISK-023 | P0 | All risk-limit values are read from `Settings.risk` (config), not hardcoded — changing a config value changes the enforced limit without a code change (parametrised test across each limit). |
| RISK-024 | P0 | Two orders submitted concurrently that would each individually pass but together breach `max_open_positions` or the daily loss limit — only one is accepted (no race condition double-accept). |
| RISK-025 | P1 | A partially filled entry (e.g. 60% filled) is risk-checked using the filled quantity, not the requested quantity, when computing current exposure for subsequent orders. |

## EXEC — execution engine / broker adapter

| ID | Priority | Scenario |
|---|---|---|
| EXEC-001 | P0 | A validated order is submitted to the broker as a bracket order (entry + stop-loss, + take-profit if applicable) in a single request where the broker API supports it. |
| EXEC-002 | P0 | Client order IDs are deterministic/idempotent per signal — resubmitting the same signal after a crash-and-restart does not create a duplicate order. |
| EXEC-003 | P0 | A rejected order from the broker (e.g. insufficient buying power) is logged, alerted, and does not crash the event loop. |
| EXEC-004 | P0 | A partial fill updates the position state to the filled quantity and leaves the remainder of the order live/tracked correctly. |
| EXEC-005 | P0 | On websocket disconnect, the client reconnects with exponential backoff and resyncs state from the broker's REST API before resuming. |
| EXEC-006 | P0 | On restart, position and order state is rebuilt entirely from the broker's current account/positions/orders endpoints, not from local SQLite alone (broker is source of truth). |
| EXEC-007 | P0 | If reconciliation finds an open position with no corresponding live stop-loss order at the broker, a stop is re-placed immediately, before any other action. |
| EXEC-008 | P0 | If reconciliation finds a broker position with no matching local record at all (e.g. manual intervention), it is surfaced as an alert and the system halts entries until acknowledged, rather than silently adopting or ignoring it. |
| EXEC-009 | P0 | Broker rate-limit responses (HTTP 429) trigger a backoff-and-retry, not an immediate failure or a busy-loop. |
| EXEC-010 | P0 | A clock-drift check comparing local time to the broker/exchange clock beyond a configured threshold halts new entries and alerts, rather than trading on a skewed clock. |
| EXEC-011 | P1 | Every order placed while `settings.live_trading is False` uses the paper base URL exclusively — a unit test asserts no code path can reach the live base URL with `live_trading=False`. |
| EXEC-012 | P1 | Every order placed while `settings.live_trading is True` still passes through RiskManager unchanged (going live does not bypass or relax any check). |

## BROKER — Alpaca-specific account rules

| ID | Priority | Scenario |
|---|---|---|
| BROKER-001 | P1 | Account-status check surfaces whether the account is PDT-flagged and what buying power Alpaca currently extends, per the findings in docs/PLAN.md, and RiskManager's leverage cap (1.0x) is enforced independently of whatever buying power Alpaca offers. |
| BROKER-002 | P1 | If the account is a cash account, the sizer/RiskManager accounts for unsettled-funds limits (no order is sized against cash that has not yet settled T+1). |
| BROKER-003 | P0 | The data client's configured feed (`iex` or `sip`) is logged at startup and surfaced on the dashboard status row, so a backtest-vs-paper feed mismatch is never silent. |

## DATA — market data layer

| ID | Priority | Scenario |
|---|---|---|
| DATA-001 | P0 | Minute bars are stored with an explicit source feed tag (`iex`/`sip`) so backtests can't silently mix feeds. |
| DATA-002 | P0 | The bar store never returns a bar whose timestamp is after the "as-of" time requested by a caller (no look-ahead at the storage layer). |
| DATA-003 | P0 | Requesting bars for a time range spanning a gap (e.g. halted symbol) returns only the bars that exist, without fabricating fill-in bars. |
| DATA-004 | P1 | A backtest run against IEX-only historical bars and the same run against SIP bars (where available) produce different opening-range values on at least one sampled day, and this difference is surfaced in the validation report, not hidden. |

## UNIV — universe scanner ("stocks in play")

| ID | Priority | Scenario |
|---|---|---|
| UNIV-001 | P0 | The relative-volume ranking used to select stocks in play, at decision time T, uses only bars with timestamp ≤ T — feeding the scanner a synthetic future bar and asserting it is never used. |
| UNIV-002 | P0 | Symbols priced below `min_price_usd` or with average dollar volume below `min_avg_dontar_volume_usd` never appear in the selected universe, even if they rank top by relative volume. |
| UNIV-003 | P0 | The scanner returns exactly top-N by the configured ranking, deterministically, for a fixed synthetic input (no nondeterministic ordering on ties). |
| UNIV-004 | P0 | Leveraged ETFs and symbols on the exclusion list never appear in the selected universe. |
| UNIV-005 | P1 | For the historical backtest universe, a symbol that was later delisted is still selectable on dates before its delisting, if the survivorship-bias-free data source in use provides it (test skipped/xfail with a clear message if no such source is configured yet). |

## SESSION — clock, calendar, timezones

| ID | Priority | Scenario |
|---|---|---|
| SESSION-001 | P0 | All trading-logic timestamps are computed in `America/New_York`; a UK-time input is never used directly for a no-entry/flatten decision. |
| SESSION-002 | P0 | The dashboard displays session times in `Europe/London`, correctly shifted across a BST/GMT transition. |
| SESSION-003 | P0 | On an Alpaca-calendar half-day, no-entry/flatten windows shift with the early close. |
| SESSION-004 | P0 | On an Alpaca-calendar holiday, the session clock reports "no session" and the event loop takes no trading action. |
| SESSION-005 | P1 | A DST transition day (spring-forward/fall-back) does not shift the *exchange-time* trading windows by an hour — only the displayed UK time changes relationship to them. |

## BT — backtester

| ID | Priority | Scenario |
|---|---|---|
| BT-001 | P0 | The exact same `Strategy` class instance/code path used in the backtester is used in the paper/live event loop — no strategy logic is duplicated or forked between the two. |
| BT-002 | P0 | A strategy that references a future bar (deliberately buggy test double) is caught by an automated look-ahead check and fails the test, not silently produces optimistic results. |
| BT-003 | P0 | The cost model deducts commissions, a spread+slippage estimate, and FX cost (GBP↔USD) from every simulated fill. |
| BT-004 | P0 | Rerunning a backtest at 2× the configured slippage produces a result that is logged and compared against the 1× run in the trial registry, not silently discarded. |
| BT-005 | P0 | Backtest equity curve construction never uses a bar's close to decide an action that, per the strategy's own rules, could only be decided using data available earlier in that same bar (no intrabar look-ahead). |
| BT-006 | P0 | A backtest run is fully deterministic given the same inputs and config (same trades, same P&L, byte-identical trial registry row) across two runs. |
| BT-007 | P0 | The backtester enforces the same RiskManager limits as live (same class, same config) — a backtest is not allowed to exceed `max_open_positions` etc. |

## VAL — validation (CSCV/PBO, PSR, MinTRL, DSR, trial registry)

| ID | Priority | Scenario |
|---|---|---|
| VAL-001 | P0 | CSCV run on a synthetic pure-random-walk return matrix (no real edge, many configs) produces a high PBO (test asserts PBO above a threshold, e.g. > 0.4). |
| VAL-002 | P0 | CSCV run on a synthetic matrix with one config carrying an injected, consistent positive-Sharpe effect produces a low PBO (test asserts PBO below a threshold, e.g. < 0.1). |
| VAL-003 | P0 | CSCV with S=16 blocks generates exactly C(16,8)=12,870 IS/OOS splits, and every split's IS and OOS halves are disjoint and contiguous-block-based. |
| VAL-004 | P0 | For each split, the OOS relative rank ω is in (0,1) and λ=ln(ω/(1−ω)) is finite (ω never exactly 0 or 1 causes a handled edge case, not a crash). |
| VAL-005 | P0 | PBO is computed as the share of splits with λ≤0, matching a hand-computed value on a small fixed synthetic example. |
| VAL-006 | P0 | The trial registry logs every parameter combination ever run, with its full daily P&L series on a shared date index, and a deleted/abandoned run is marked retired in a status column rather than removed from the table. |
| VAL-007 | P0 | Deflated Sharpe Ratio computation uses the trial registry's actual trial count (including abandoned/retired trials) for that strategy, not just the trials in the final report. |
| VAL-008 | P0 | Probabilistic Sharpe Ratio and Minimum Track Record Length are computed per Bailey & López de Prado (2012) and match published worked-example values within tolerance (regression test against a known example). |
| VAL-009 | P0 | For an optimiser-driven search (as opposed to a fixed grid), only the search's converged result is logged as a trial — intermediate optimiser iterations are not each logged as separate trials. |
| VAL-010 | P0 | The validation report explicitly rejects a strategy (verdict = fail) when PBO > 0.05, independent of how good the headline backtest Sharpe looks. |
| VAL-011 | P0 | CSCV/PBO is never used as an optimisation objective anywhere in the codebase — a search over the codebase for any code path that varies strategy parameters based on a PBO value fails a static-analysis test. |
| VAL-012 | P1 | Walk-forward validation results and the final untouched holdout result are computed from disjoint date ranges, verified programmatically (no overlap). |
| VAL-013 | P1 | The holdout dataset cannot be read by any code path before the walk-forward gate has already produced a pass verdict (enforced by directory/flag access check, not just convention). |

## STATE — state & reconciliation

| ID | Priority | Scenario |
|---|---|---|
| STATE-001 | P0 | On process restart, in-memory state (positions, halted flags, today's trade count) is rebuilt to match the broker and local SQLite history, with the broker's values winning any conflict. |
| STATE-002 | P0 | A halted state (daily loss, weekly loss, or drawdown breaker) persists across a restart — the system does not silently resume trading after a crash. |
| STATE-003 | P1 | Reconciliation run twice in a row with no state change between runs is a no-op (idempotent) and does not double-alert or double-log. |

## ALERT — Telegram alerting

| ID | Priority | Scenario |
|---|---|---|
| ALERT-001 | P0 | A halt (daily loss, weekly loss, drawdown breaker, or kill switch) sends a Telegram alert immediately, not batched into the daily summary. |
| ALERT-002 | P0 | An unhandled error in the event loop triggers an instant Telegram alert before/while the loop fails safe. |
| ALERT-003 | P1 | A websocket disconnect lasting longer than a configured threshold triggers a Telegram alert. |
| ALERT-004 | P1 | The daily post-close summary is sent once per trading day, after flatten-and-close bookkeeping completes, and never sent twice for the same date. |
| ALERT-005 | P0 | If Telegram credentials are unset, alerting is skipped (logged locally) rather than raising and crashing the caller. |

## DASH — dashboard

| ID | Priority | Scenario |
|---|---|---|
| DASH-001 | P0 | No code path in the dashboard package can place, modify, or cancel an order — a static check confirms the dashboard never imports the broker adapter's write methods, only RiskManager-gated kill/pause/flatten and read-only data access. |
| DASH-002 | P0 | The kill-switch button requires the exact typed confirmation string; any other input leaves the system untouched. |
| DASH-003 | P1 | When exposed outside localhost, the dashboard requires the configured password; with no password configured, it refuses to bind to a non-localhost interface. |

## GOLIVE — go-live gate

| ID | Priority | Scenario |
|---|---|---|
| GOLIVE-001 | P1 | The go-live check fails while fewer than 30 paper-trading days are recorded. |
| GOLIVE-002 | P1 | The go-live check fails if measured paper slippage/paper P&L falls outside the backtest's expected band, even with 30+ days elapsed. |
| GOLIVE-003 | P1 | The go-live check fails if any unhandled error was logged in the last 14 days. |
| GOLIVE-004 | P1 | The go-live check fails if the kill switch or reconciliation-on-restart has not been exercised (tested) at least once in paper. |
| GOLIVE-005 | P1 | Even when the go-live check passes, `live_trading` still requires the SAFE-002/SAFE-003 confirmation string — passing the checklist alone cannot flip live trading on. |
| GOLIVE-006 | P1 | A live order's notional is capped at the configured live ceiling (≤ £3k equivalent) independently of account equity, until that cap is deliberately raised in config. |

---

Retired scenarios: none yet.
