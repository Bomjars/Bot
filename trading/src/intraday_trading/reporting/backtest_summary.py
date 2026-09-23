"""A plain-English summary of a strategy's logged backtest grid: the overfitting verdict,
how the grid did as a whole, the best config's return/drawdown/activity, and the same
figures for buy-and-hold over the same dates.

Evaluation only, computed after the grid has already run in full -- nothing here may
ever feed back into choosing a config or reshaping the grid (CLAUDE.md rule 7). The
"best config" is picked on the whole period, which flatters it by construction; that's
exactly why the CSCV/PBO verdict sits alongside it rather than being replaced by it.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
import pandas as pd
from scipy import stats

from intraday_trading.validation.cscv import cscv_pbo, evaluate
from intraday_trading.validation.psr_dsr import deflated_sharpe_ratio
from intraday_trading.validation.registry import TrialRegistry

TRADING_DAYS_PER_YEAR = 252
MIN_DAYS_FOR_CSCV = 32  # same floor as the dashboard's Validation Report

# docs/STRATEGY_SPEC_SPY.md §5, Table 3's preferred variant (current band + VWAP stop,
# vol-target sizing), May 2007 - April 2024, net of costs. The replication target for
# the paper_faithful run -- an upper bound, never a goal for the house_risk grid.
PAPER_TABLE3_ANNUAL_RETURN_PCT = 19.6
PAPER_TABLE3_SHARPE = 1.33
PAPER_TABLE3_MAX_DRAWDOWN_PCT = 25.0


@dataclass(frozen=True)
class Performance:
    days: int
    total_return_pct: float
    annual_return_pct: float
    annual_vol_pct: float
    sharpe: float  # annualised
    max_drawdown_pct: float
    active_day_pct: float  # share of days with any P&L at all -- a proxy for "it traded"


@dataclass(frozen=True)
class GridSummary:
    strategy: str
    n_trials: int
    n_date_ranges: int  # >1 means trials from different backtest runs are mixed together
    first_date: str
    last_date: str
    n_profitable: int
    median_annual_return_pct: float
    best_trial_id: int
    best_params: dict[str, object]
    best: Performance
    pbo: float | None  # None when there's too little data (or <2 trials) for CSCV
    p_oos_sharpe_negative: float | None
    cscv_passed: bool | None
    cscv_reason: str | None
    dsr: float | None


def _performance_from_equity(equity: np.ndarray, active_day_pct: float) -> Performance:
    """`equity[0]` is the starting value, `equity[1:]` one value per trading day."""
    days = len(equity) - 1
    growth = equity[-1] / equity[0]
    returns = equity[1:] / equity[:-1] - 1.0
    std = float(returns.std(ddof=1)) if days > 1 else 0.0
    annual_return = growth ** (TRADING_DAYS_PER_YEAR / days) - 1.0 if growth > 0 else -1.0
    running_peak = np.maximum.accumulate(equity)
    return Performance(
        days=days,
        total_return_pct=(growth - 1.0) * 100,
        annual_return_pct=annual_return * 100,
        annual_vol_pct=std * math.sqrt(TRADING_DAYS_PER_YEAR) * 100,
        sharpe=float(returns.mean()) / std * math.sqrt(TRADING_DAYS_PER_YEAR) if std else 0.0,
        max_drawdown_pct=float(np.max(1.0 - equity / running_peak)) * 100,
        active_day_pct=active_day_pct,
    )


def performance_from_daily_pnl(daily_pnl: pd.Series, starting_equity: float) -> Performance:
    """Daily P&L in account currency, as the trial registry stores it."""
    if starting_equity <= 0:
        raise ValueError("starting_equity must be positive")
    if daily_pnl.empty:
        raise ValueError("daily_pnl is empty")
    pnl = daily_pnl.to_numpy(dtype=float)
    equity = starting_equity + np.concatenate(([0.0], np.cumsum(pnl)))
    return _performance_from_equity(equity, float(np.mean(pnl != 0.0)) * 100)


def performance_from_prices(start_price: float, daily_closes: pd.Series) -> Performance:
    """Buy-and-hold: bought at `start_price` (the first bar's open), marked at each
    day's close."""
    if start_price <= 0:
        raise ValueError("start_price must be positive")
    if daily_closes.empty:
        raise ValueError("daily_closes is empty")
    equity = np.concatenate(([start_price], daily_closes.to_numpy(dtype=float)))
    return _performance_from_equity(equity, 100.0)


def summarize_grid(
    registry: TrialRegistry, strategy: str, starting_equity: float
) -> GridSummary | None:
    """None if `strategy` has no trials logged."""
    matrix = registry.daily_pnl_matrix(strategy)
    if matrix.empty:
        return None
    matrix = matrix.sort_index()
    filled = matrix.fillna(0.0)
    params = {t.trial_id: t.params for t in registry.get_trials(strategy)}

    date_ranges = {(col.first_valid_index(), col.last_valid_index()) for _, col in matrix.items()}
    performances = {
        int(trial_id): performance_from_daily_pnl(filled[trial_id], starting_equity)
        for trial_id in filled.columns
    }
    daily_sharpes = filled.apply(lambda c: c.mean() / c.std() if c.std() else 0.0)
    best_id = int(daily_sharpes.idxmax())  # type: ignore[call-overload]  # trial id column

    pbo = p_oos = dsr = None
    passed = reason = None
    if len(filled) >= MIN_DAYS_FOR_CSCV and filled.shape[1] >= 2:
        result = cscv_pbo(filled)
        verdict = evaluate(result)
        pbo, p_oos = result.pbo, result.p_oos_sharpe_negative
        passed, reason = verdict.passed, verdict.reason
        best_series = filled[best_id]
        try:
            dsr = deflated_sharpe_ratio(
                float(daily_sharpes[best_id]),
                registry.trial_count(strategy, include_retired=True),
                float(daily_sharpes.var()),
                len(best_series),
                float(stats.skew(best_series)),
                float(stats.kurtosis(best_series, fisher=False)),
            )
        except ValueError:
            dsr = None

    return GridSummary(
        strategy=strategy,
        n_trials=filled.shape[1],
        n_date_ranges=len(date_ranges),
        first_date=str(matrix.index[0]),
        last_date=str(matrix.index[-1]),
        n_profitable=sum(1 for p in performances.values() if p.total_return_pct > 0),
        median_annual_return_pct=float(
            np.median([p.annual_return_pct for p in performances.values()])
        ),
        best_trial_id=best_id,
        best_params=params[best_id],
        best=performances[best_id],
        pbo=pbo,
        p_oos_sharpe_negative=p_oos,
        cscv_passed=passed,
        cscv_reason=reason,
        dsr=dsr,
    )
