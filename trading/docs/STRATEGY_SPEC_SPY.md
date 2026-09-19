# Strategy Spec — SPY Intraday Momentum (Noise Area)

Source: Zarattini, Aziz & Barbon, "Beat the Market: An Effective Intraday Momentum Strategy for S&P500 ETF (SPY)", Swiss Finance Institute Research Paper 24-97, first version 10 May 2024, this version 22 Sep 2025.

Save as `docs/STRATEGY_SPEC_SPY.md`. Claude Code implements from this file, not from the paper. Section 6 lists assumptions that need a decision; section 7 lists where our risk rules deliberately differ from the paper.

---

## 1. Instrument and data

- Single instrument: **SPY**. Regular session only, 09:30–16:00 ET.
- 1-minute OHLCV bars. The paper used IQFeed, May 2007 – April 2024. Alpaca is named in the paper's FAQ as an acceptable alternative (7 years of free intraday data), so expect a shorter history.
- Daily bars (or derived daily closes/opens) are needed for the volatility sizing.
- Warm-up: at least 14 prior trading days before the first signal.

## 2. The Noise Area

Computed per day `t`, per time of day `HH:MM`.

**Step 1 — same-time-of-day moves over the previous 14 days.** For `i = 1..14`:

```
move[t-i, HH:MM] = | Close[t-i, HH:MM] / Open[t-i, 09:30] - 1 |
```

**Step 2 — average move (sigma):**

```
sigma[t, HH:MM] = (1/14) * sum over i=1..14 of move[t-i, HH:MM]
```

**Step 3 — boundaries for day t**, anchored on today's open and yesterday's close so overnight gaps widen the band on the gap side:

```
UpperBound[t, HH:MM] = max(Open[t, 09:30], Close[t-1, 16:00]) * (1 + VM * sigma[t, HH:MM])
LowerBound[t, HH:MM] = min(Open[t, 09:30], Close[t-1, 16:00]) * (1 - VM * sigma[t, HH:MM])
```

`VM` is the **Volatility Multiplier**. The paper's headline results use **VM = 1.0**; its sensitivity analysis (Figure 9) sweeps 0.5–2.0 and finds the best risk-adjusted result near 1.5, but the authors deliberately report VM = 1.

The Noise Area is `[LowerBound, UpperBound]`. Inside it, no position. The band is time-of-day dependent and typically widens through the session.

## 3. Trading rules

**Decision times.** The strategy acts **only at HH:00 and HH:30**. The first decision of the day is at **10:00**. Nothing is triggered between decision times, including stops. This is deliberate: it filters out transient spikes.

**Entry.** At a decision time, with no position open:

- price above `UpperBound` → go **long**
- price below `LowerBound` → go **short**
- otherwise → stay flat

**Reversal.** If a position is open and at a decision time price has crossed to the *opposite* boundary, close the position and open a new one in the opposite direction, in the same action.

**Trailing stop** (the paper's preferred variant, "Curr. Band + VWAP"), checked only at decision times:

```
Long  stop level = max( UpperBound[t, HH:MM], VWAP[t, HH:MM] )
Short stop level = min( LowerBound[t, HH:MM], VWAP[t, HH:MM] )
```

A long is closed when price crosses below its stop level; a short when price crosses above. Note the band used is the **current** (time-of-day) band, so the stop tightens as the session progresses. VWAP is the session VWAP computed from regular-hours data only.

**End of day.** Any open position is closed at the 16:00 close. Nothing is held overnight.

**Stop variants to implement** (both are in the paper and both belong in the parameter grid):

- `opposite_band`: stop at the opposite boundary only (the paper's base model)
- `curr_band_vwap`: the max/min formula above (the paper's preferred model)

## 4. Position sizing

**Paper-faithful mode.** Volatility targeting with `sigma_target = 2%` daily:

```
Shares[t] = floor( AUM[t-1] * min(4, sigma_target / sigma_SPY[t]) / Open[t, 09:30] )

sigma_SPY[t] = sample std dev of the last 14 daily returns   (divisor 13, mean over 14)
```

Leverage is capped at **4x**. Share count is fixed at the open and used for every trade that day.

The paper's simpler variants use 100% of equity with no volatility targeting; keep that as a `fixed_notional` option for replication.

## 5. Costs and reported results

Backtest costs from the paper: commission **$0.0035 per share** (Interactive Brokers entry level) and slippage **$0.001 per share** (their measured average over 1,000+ live trades; median $0.0005). Their Figure 10 shows total return falling steeply as commission rises, so cost assumptions matter a lot.

Published results, May 2007 – April 2024, net of costs — treat these as the upper bound to replicate against, not as an expectation:

| Variant | Sizing | Total return | Annual | Vol | Sharpe | Max DD | Hit | Trades |
|---|---|---|---|---|---|---|---|---|
| Stop at opposite band | 100% | 178% | 6.2% | 10.9% | 0.61 | 21% | 54% | 5,494 |
| Stop at current band + VWAP | 100% | 380% | 9.7% | 7.7% | 1.24 | 12% | 43% | 7,668 |
| Stop at current band + VWAP | Vol-target | 1,985% | 19.6% | 14.3% | 1.33 | 25% | 43% | 7,668 |
| SPY buy & hold | — | 227% | 7.2% | 20.2% | 0.45 | 56% | 54% | — |

About 1.8 trades per day on the preferred variant; annualised alpha 19.6% with beta near zero. Replication is judged a success if our numbers land in the same region over the same dates and costs; a large gap means an implementation difference, and Claude Code should find it before anything else.

## 6. Ambiguities — implement as configurable, and tell me which you chose

1. **What "price" means at a decision time.** The paper's slippage study sends market orders just before minute `HH:MM` and measures against `Open[HH:MM]`. Suggested implementation: evaluate the signal on the close of the bar ending at `HH:MM`, and fill at the open of the next minute plus slippage. No look-ahead.
2. **VWAP definition.** The paper says VWAP uses market-hours data only, starting at the open, but doesn't give the per-bar price. Suggested: cumulative `sum(typical_price * volume) / sum(volume)` with `typical_price = (H + L + C) / 3`. Make the price source a config value.
3. **Reversal on the same bar.** Assume close-then-open with two fills, both paying costs.
4. **Half days (13:00 close).** Decision times up to the close; flatten at the close. The paper doesn't discuss this.
5. **Rounding.** `floor` for share count, as written. Zero shares means no trade that day.
6. **Missing bar at a decision time.** Use the last completed bar within the same 5-minute window; otherwise skip that decision time and log it.

## 7. Where our risk rules deliberately differ from the paper

The paper's model takes up to 4x leverage, holds one position with no fixed per-trade stop, and exits at the 16:00 close. Our house rules are 1x leverage, 1% risk per trade with a hard stop at the broker, and flatten 10 minutes before the close. These conflict, so implement **two modes**:

- `mode: paper_faithful` — for replication only, and only ever in the backtester and paper trading. Never eligible for live.
- `mode: house_risk` — leverage capped at 1x, a hard protective stop sent as a bracket order alongside the entry (initially at the trailing-stop level, so the broker holds a stop even between decision times), flatten 10 minutes before the close, and all RiskManager limits applied.

Report both in the validation report, side by side. Expect `house_risk` to return materially less than the paper; that's the cost of the safety rules, and it's the number that matters for the go-live decision.

## 8. Parameter grid for the CSCV / PBO run

192 configs, all economically sensible:

- `VM`: 0.5 to 2.0 in steps of 0.1 (16 values) — the paper's own sweep
- `lookback_days`: 10, 14, 20 (3)
- `decision_interval`: 30 min, 60 min (2)
- `stop_variant`: `opposite_band`, `curr_band_vwap` (2)

Fixed across the grid: `sigma_target = 2%`, leverage cap per mode, costs as in section 5. Run the whole grid in `house_risk` mode for the go-live decision, and the paper's own settings (VM 1.0, 14 days, 30 min, `curr_band_vwap`, vol-target sizing) as the replication reference.

Every config goes in the trial registry with its full daily P&L series, then into CSCV with S = 16. Reject the strategy if PBO > 0.05.

## 9. Tests to add to TEST_SCENARIOS.md (SPY-specific)

| ID | Given | When | Then |
|---|---|---|---|
| SPY-01 | 14 days of known bars | sigma computed for 10:00 | Matches a hand calculation |
| SPY-02 | Previous close above today's open | Boundaries computed | Upper uses the previous close, lower uses the open |
| SPY-03 | Price above the upper band at 10:17 | Bar processed | No trade until 10:30 |
| SPY-04 | Price above the band at 10:00 | Decision | Long entry; a short is impossible while above the band |
| SPY-05 | Long open, price below the lower band at a decision time | Decision | Position reversed to short, two fills, costs charged twice |
| SPY-06 | Long open, price below max(current band, VWAP) | Decision | Position closed |
| SPY-07 | Open position at the close | 16:00 (house mode: 15:50) | Flat, no overnight position |
| SPY-08 | sigma_SPY = 1% daily, target 2% | Sizing | Leverage 2x in paper mode, capped at 1x in house mode |
| SPY-09 | sigma_SPY = 0.2% | Sizing | Leverage capped at 4x (paper) / 1x (house) |
| SPY-10 | Fewer than 14 prior days | Startup | No signals, logged as insufficient history |
| SPY-11 | Paper's settings, same dates and costs | Backtest | Results within a stated tolerance of Table 3; any gap is explained |
