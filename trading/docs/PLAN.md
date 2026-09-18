# Plan, research findings, and rule summaries

Status: **Step 1 of 10.** Strategy code (steps 6–7) is intentionally not started. This
document is what you asked to confirm or correct before it is.

## 1. Repo layout decision (already made, per your answer)

This repo (`Bomjars/Bot`) has an unrelated existing app at its root ("Item Price Check",
Flask + SQLite). The trading system lives entirely under `trading/` so the two are
independent: separate `pyproject.toml`, separate `.venv`, separate tests. Nothing at the
repo root was touched except adding `docs/TEST_SCENARIOS.md` (which your prompt named at
the repo root, and which the whole project — not just `trading/` — is scored against).

```
Bot/
├── server.py, public/, db/, tests/      ← existing Item Price Check app, untouched
├── docs/TEST_SCENARIOS.md               ← test scenario registry (all 10 steps)
└── trading/                             ← everything below is new
    ├── pyproject.toml (uv, Python 3.12)
    ├── README.md, CLAUDE.md
    ├── docs/PLAN.md                     ← this file
    ├── src/intraday_trading/
    │   ├── config.py                    ← Settings/RiskLimits (pydantic-settings) — done
    │   ├── cli.py                       ← skeleton CLI — done
    │   ├── broker/ data/ strategies/ risk/ sizing/ execution/
    │   ├── backtest/ validation/ universe/ session/ state/
    │   └── alerting/ killswitch/ storage/  ← all empty, step 2+
    ├── dashboard/                        ← step 9
    └── tests/{unit,integration}/
```

## 2. Alpaca account & regulatory findings

Researched live (Sept 2026), sources cited. Confidence noted where the agent could not
read a page directly (this sandbox's egress proxy blocks `docs.alpaca.markets` and
`alpaca.markets` directly — findings are from search-result snippets of those exact pages,
not a direct fetch. **Please spot-check the two Alpaca links below yourself before we rely
on the specific multiplier numbers.**)

- **PDT is already moot.** The SEC's FINRA rule change (SR-FINRA-2025-017, effective 4 Jun
  2026) is live, and Alpaca has already rolled out its replacement "Intraday Margin
  Framework": the equity threshold for 4x intraday buying power dropped from $25k to just
  **$2,000**, and Alpaca is retiring the old `pattern_day_trader`/`daytrade_count` API
  fields by 6 Jul 2026. Source: [Alpaca blog](https://alpaca.markets/blog/finra-retires-the-pdt-rule-introducing-alpacas-new-intraday-margin-framework/).
  **Practical effect for you: you can make more than 3 day trades per week from day one,
  on a normal margin account, with no $25k requirement.** This removes what would have
  been the single biggest constraint on the plan.
- **Alpaca has no real taxable "cash account."** Every standard taxable account is a Reg-T
  margin account; sub-$2,000 equity gets forced to 1x ("limited margin"). Only IRAs are
  cash-like. Source: [Alpaca cash accounts](https://alpaca.markets/support/alpaca-cash-accounts).
  So "cash account to avoid PDT" isn't an available option here, and (per the point above)
  isn't needed anyway.
- **Recommendation: open/use a standard margin account, fund ~£10k, and self-impose the
  1x cap entirely in `RiskManager.max_leverage=1.0`** — ignore the 4x intraday buying power
  Alpaca will offer. This avoids T+1-settlement round-trip limits a real cash account would
  impose, while `RiskManager` still hard-enforces no leverage regardless of what the
  broker allows. Flat-by-close avoids Reg-T overnight maintenance-margin exposure. If a
  position isn't flattened correctly and equity ends the day short of maintenance margin,
  Alpaca can liquidate without notice — another reason `RISK-014`/`KILL-*` flatten logic is
  P0 before paper trading, not a nice-to-have.
- **Open question for you:** do you want me to go ahead and treat "standard margin
  account, self-imposed 1x" as decided, or do you want to look into it further first? I'll
  proceed on that basis unless you say otherwise.

## 3. Data feed: IEX vs SIP

- Free/basic Alpaca plan = **IEX only** (~2–2.5% of consolidated US volume) for both
  streaming and historical minute bars. Paid "Algo Trader Plus" = full **SIP** (100%),
  both live and historical. Free-tier historical SIP queries are only allowed ≥15 minutes
  delayed, so on the free plan, backtesting is IEX-only, period.
  Source: [Market Data FAQ](https://docs.alpaca.markets/us/docs/market-data-faq).
- **Bias this introduces:** IEX-only bars miss prints from every other venue and dark
  pools, can show different open/close prints than the real consolidated tape, and
  understate volume heavily (one cited example: ~12,630 IEX trades vs 535,000+
  consolidated trades for AAPL on a single day). For the SPY strategy this mostly affects
  volume-based filters less (SPY is enormous even on IEX alone) but the printed open/high/
  low/close and the "noise band" computed from them can differ from what a SIP-based
  investor sees. **For the stocks-in-play ORB strategy this bias is much worse**: relative
  volume ranking and the opening-range candle itself are exactly the inputs IEX
  under-represents most for thinner names.
- `config.py` defaults to `alpaca_data_feed=iex` and the plan is: **start on IEX (free)
  for paper trading and initial validation**, log/tag every bar with its feed (`DATA-001`),
  and treat SIP as a paid upgrade to consider once the strategies are otherwise validated
  — not something to buy before we know the strategies are worth running at all. I'll
  surface the feed prominently on the dashboard (`BROKER-003`) so a feed mismatch between
  backtest and paper is never silent. Tell me if you'd rather pay for SIP from day one
  instead.

## 4. Survivorship-bias-free universe (stocks-in-play backtest)

Alpaca does not appear to offer a delisted-securities archive — no evidence found either
way from search, flagged as unconfirmed rather than a firm "no". Realistic retail-scale
alternatives, none confirmed against Alpaca's own offering:
- **Norgate Data** — dedicated survivorship-bias-free US equities, delisted history back
  to the 1950s. **EOD only, no intraday bars** — usable for universe *membership* history,
  not for actually simulating the 5-minute opening range on delisted names.
- **Nasdaq Data Link / Sharadar Core US Equities** — similar: active + delisted tickers,
  point-in-time, but also EOD only.
- **Polygon.io** — has intraday minute bars and multi-year history (paid tiers from
  ~$29–199/mo), but I could not confirm how complete its delisted-ticker coverage is for
  thin microcaps specifically — flagged low-confidence, needs verification before relying
  on it for the ORB backtest.
- **CRSP** is the academic gold standard but institutional-priced, not realistic here.

**This is a genuine open problem, not solved by step 1.** My plan: build the ORB
backtester (step 7) to accept a pluggable universe-history provider, ship it initially
using Alpaca's own (survivorship-*biased*) historical universe with a loud disclaimer in
every ORB validation report, and revisit a paid data source only once everything else
about the strategy looks worth the spend. Flag if you'd rather solve this before step 7
instead of after.

## 5. Paper rule summaries — READ THIS BEFORE CONFIRMING

I could not fetch the SSRN PDFs directly (the sandbox's network policy blocks SSRN,
ResearchGate, Semantic Scholar, and most paper-hosting/blog domains — only GitHub was
reachable). Everything below is reconstructed from search-engine snippets of *secondary*
sources (blog replications, aggregator summaries), cross-checked against each other where
possible. Numbers that showed up consistently across ≥2 independent sources are marked
**(higher confidence)**; single-source or inferred numbers are marked **(low confidence)**,
and outright unresolved conflicts are marked **⚠ CONFLICT**. Given your instruction to
treat this as a literal-replication project, I do not think we should write strategy code
against several of these numbers without you either (a) getting me the actual PDF text for
SSRN 4729284 and SSRN 4824172, or (b) explicitly approving the assumption I'd otherwise
make. I've proposed a concrete default for each gap so you can approve/override quickly
rather than having to resolve it from scratch.

### 5a. Zarattini, Barbon & Aziz (2024), "A Profitable Day Trading Strategy For The U.S.
Equity Market" (SSRN 4729284) — Opening Range Breakout on Stocks in Play

| Rule | Paper says (confidence) | My proposed default if unconfirmed |
|---|---|---|
| Base universe | ~7,000 US equities, or possibly pre-filtered to ~1,000 most liquid — sources disagree which is the raw universe vs. the filtered one **(low confidence)** | Start from Alpaca's tradable-assets list, apply the filters below, no separate "top 1,000 liquid" pre-filter unless you tell me otherwise |
| Liquidity/price filter | price > $5; 14-day avg. daily volume ≥ 1,000,000 shares; 14-day daily-bar ATR($) > $0.50 **(higher confidence, 2+ sources agree)** | Use exactly these three as configured `RiskLimits`/universe filters |
| Selection metric | Rank by **Relative Volume in the first 5 minutes** = today's first-5-min volume ÷ 14-day average first-5-min volume; trade only **top 20** by RV **(higher confidence)** | Implement exactly this; N=20 configurable |
| Opening range | First 5-minute candle, 9:30–9:35 ET **(higher confidence)** | As stated |
| Entry direction | Long if the opening 5-min candle closes above its open; short if it closes below. Unclear whether entry is *at* the candle's close (momentum-continuation) or on a subsequent *breakout* of the candle's high/low **(low confidence — "ORB" naming suggests breakout, but no source clearly separated the two)** | **Ask you to pick, since this changes the code meaningfully**: (A) enter at market immediately at 9:35 in the candle's direction, or (B) place stop orders at the candle's high/low and enter only on a breakout through one of them, whichever triggers first. See open question below. |
| Stop-loss | ⚠ **CONFLICT**: one description says stop = 10% of 14-day ATR($) from entry; another describes the stop as the opening range's own low/high — these could both be true in different papers (this multi-stock paper vs. the companion single-name QQQ paper, SSRN 4416622) and got conflated by my sources | **My default: stop = entry ± (0.10 × 14-day ATR($)),** since your own prompt already specifies "stop at a fraction of 14-day ATR" — please confirm 10% is the right fraction, or give me the number from the PDF |
| Profit target | Reported as 10× the stop distance (10R) for ~97–98% of trades exiting via stop or close rather than target — **but this figure is documented for the companion QQQ paper and may not apply to this multi-stock paper (low confidence, possible conflation)** | Your prompt says "exit at the close" with no target mentioned — **my default: no profit target, exit only via stop or at the close**, matching your prompt over the uncertain 10R figure. Confirm this is right. |
| Exit (no stop/target hit) | Liquidate at market close, flat overnight always **(higher confidence, matches your prompt)** | As stated |
| Position sizing | Risk ~1% of capital per trade, sized off the stop distance; paper describes leverage up to 4x **(low confidence on the 4x)** | Your hard limits already say ≤1% risk/trade and 1x max leverage — **I will use your limits, not the paper's, since your prompt explicitly caps leverage at 1x regardless of what the paper used.** This is exactly the kind of "treat published results as an upper bound" case McLean & Pontiff would predict — the paper's own leverage inflates its reported returns. |
| Reported backtest (upper bound only) | Jan 2016–Dec 2023, ~7,000 US stocks, top-20-by-RV portfolio: total return ~1,600–1,637%, annualized ~36–41.6%, Sharpe ~2.8 **(low-medium confidence, range reflects source imprecision)**; SPY buy-and-hold benchmark ~198% same period | Recorded here only as the ceiling we compare our validated, cost-and-1x-adjusted result against — not a target |

### 5b. Zarattini, Aziz & Barbon (2024), "Beat the Market: An Effective Intraday Momentum
Strategy for SPY" (SSRN 4824172), informed by Gao, Han, Li & Zhou (2018, JFE)

**Gao, Han, Li & Zhou (2018) — the underlying empirical finding (higher confidence, 2+
sources agree):** first half-hour return = close-to-open move from prior close to 10:00am;
last half-hour return = move into the 4:00pm close. Regression: first-half-hour return
positively and significantly predicts last-half-hour return (slope ×100 = 6.94, R²=1.6%,
significant at 1%), on SPY 1993–2013, stronger on high-volatility/high-volume/recession/
macro-news days. This is a *predictive signal*, not a trading rule by itself.

**Zarattini/Aziz/Barbon's "Beat the Market" strategy:**

| Rule | Paper says (confidence) | My proposed default if unconfirmed |
|---|---|---|
| "Noise area" construction | Each day, upper/lower bands around the day's open price, offset by the *average* absolute intraday return up to that time-of-day computed over a trailing lookback (reported as 14 trading days by one source), with an adjustment for a prior overnight gap **(medium confidence — construction logic agreed by the one detailed source I found, but not the exact "k" multiplier, and not whether it's plain-average or stdev-scaled)** | **Ask you before implementing.** This is the single most consequential unresolved number in either paper — it directly sets how often the strategy trades. I do not want to guess a stdev multiplier here. |
| Signal check frequency | Unclear whether checked continuously (any tick outside the band triggers) or only at hour/half-hour marks **(low confidence)** | Default to continuous (bar-by-bar) unless you tell me the paper says otherwise |
| Entry | Enter (long above the upper band, short below the lower band) when price moves outside the noise area **(medium confidence on direction; this is a momentum/breakout-continuation strategy, not mean-reversion)** | As stated, pending the band formula above |
| Exit | At market close, or earlier if price reverts back inside the noise area; "dynamic trailing stops" mentioned but exact formula **not found — flagged unconfirmed** | Default: exit at close or on reversion into the band; **no trailing stop until you can confirm one**, since inventing a stop formula the paper didn't specify would misrepresent it as a replication |
| Leverage | Mentioned in passing by a third-party implementation (margin-call behaviour) but exact ratio not found **(unconfirmed)** | Same as above: your prompt's 1x cap overrides regardless |
| Reported backtest | SPY, 2007–early 2024, total return 1,985% net of costs, annualized 19.6%, Sharpe 1.33 **(medium confidence)** | Recorded as the ceiling only |

### Open questions I need from you before writing any strategy code (steps 6–7)

1. **Can you get me the actual SSRN PDF text** for 4729284 and 4824172 (e.g. download and
   paste, or paste the relevant methodology section)? This resolves every ⚠/low-confidence
   row above directly instead of me guessing.
2. If not available: for the **ORB entry rule**, momentum-continuation-at-close (A) or
   breakout-of-range (B)?
3. For the **ORB stop**, is 10% of 14-day ATR($) the right fraction — or do you have the
   paper's actual number?
4. For the **ORB profit target**, confirm "no target, exit only via stop or close" (matches
   your prompt) rather than the possibly-conflated 10R figure.
5. For the **SPY noise band**, I need the actual formula (average-return-based vs.
   stdev-based, and the multiplier) — I don't have a safe default to propose here.
6. Margin account + self-imposed 1x (section 2), and IEX-first data (section 3): proceed
   on that basis, or do you want to revisit either first?

I've marked every row above where I'm using a default instead of a confirmed number so it's
auditable later — this table itself is effectively the "assumptions log" your prompt asked
for. **I have not written any strategy code.** Steps 2–5 (broker, risk manager, backtester
engine, validation engine) don't depend on any of these open questions — they're generic
infrastructure — so I'd like your go-ahead to continue building those while you get me
answers on the strategy-specific questions above, rather than blocking everything on it.

## 6. McLean & Pontiff (2016) framing

Both papers' headline returns should be read as ceilings, not targets, for two independent
reasons layered on top of each other: (1) published anomalies see average post-publication
return decay of roughly 50% (McLean & Pontiff), and (2) both papers' own reported figures
use leverage and (possibly) a profit-target assumption we are deliberately not replicating,
per your 1x cap. The validation report (step 5+) will show our backtest's Sharpe/CAGR next
to the paper's reported figures explicitly so the gap is visible, not asserted.
