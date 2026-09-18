"""Page 2: Validation Report, one tab per strategy. Everything here is computed live
from the trial registry (SQLite) using the real validation module -- CSCV/PBO, PSR,
DSR, MinTRL are not mocked. Charts/cards that need data this system doesn't collect yet
(a registered 2x-slippage rerun, a locked holdout set, historical SPY bars for
benchmarking, a 2-parameter grid for a heatmap) say so plainly instead of inventing a
number -- see docs/PLAN.md.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import plotly.graph_objects as go  # noqa: E402
import streamlit as st  # noqa: E402
from lib import data, theme  # noqa: E402
from scipy import stats  # noqa: E402

from intraday_trading.config import load_settings  # noqa: E402
from intraday_trading.validation.cscv import cscv_pbo, evaluate  # noqa: E402
from intraday_trading.validation.psr_dsr import (  # noqa: E402
    deflated_sharpe_ratio,
    minimum_track_record_length,
    probabilistic_sharpe_ratio,
)
from intraday_trading.validation.registry import TrialRegistry  # noqa: E402

theme.apply()
settings = load_settings()

st.title("Validation Report")

strategies = data.known_strategies(settings.database_path)
if not strategies:
    st.info(
        "No strategy has logged any trials yet. This page fills in once a strategy's "
        "parameter grid has been backtested and registered (steps 6-7)."
    )
    st.stop()

MIN_DAYS_FOR_CSCV = 32  # needs to divide evenly into 16 blocks of >=2 days


def _best_trial_column(matrix: pd.DataFrame) -> int:
    sharpes = matrix.apply(lambda col: col.mean() / col.std() if col.std() else 0.0)
    return int(sharpes.idxmax())


tabs = st.tabs(strategies)
for tab, strategy in zip(tabs, strategies, strict=True):
    with tab:
        registry = TrialRegistry(settings.database_path)
        registry_matrix = registry.daily_pnl_matrix(strategy)

        n_trials_total = registry.trial_count(strategy, include_retired=True)
        st.caption(f"{n_trials_total} trial(s) logged for **{strategy}** (retired included).")

        if (
            registry_matrix.empty
            or len(registry_matrix) < MIN_DAYS_FOR_CSCV
            or registry_matrix.shape[1] < 2
        ):
            st.warning(
                f"Not enough data for CSCV yet: need >= {MIN_DAYS_FOR_CSCV} days across "
                ">= 2 configurations on a shared date index."
            )
            continue

        filled = registry_matrix.fillna(0.0)
        result = cscv_pbo(filled)
        verdict = evaluate(result)

        best_id = _best_trial_column(filled)
        best_series = filled[best_id]
        n_obs = len(best_series)
        observed_sharpe = (
            float(best_series.mean() / best_series.std()) if best_series.std() else 0.0
        )
        skewness = float(stats.skew(best_series)) if n_obs > 2 else 0.0
        kurtosis = float(stats.kurtosis(best_series, fisher=False)) if n_obs > 2 else 3.0
        sharpe_variance = float(
            filled.apply(lambda c: c.mean() / c.std() if c.std() else 0.0).var()
        )

        if verdict.passed:
            st.success(f"PASS — {verdict.reason}")
        else:
            st.error(f"FAIL — {verdict.reason}")

        card_cols = st.columns(6)
        card_cols[0].metric(
            "PBO", f"{result.pbo:.1%}", help="Probability of Backtest Overfitting; reject above 5%."
        )
        try:
            psr = probabilistic_sharpe_ratio(observed_sharpe, 0.0, n_obs, skewness, kurtosis)
            card_cols[1].metric("PSR", f"{psr:.1%}")
        except ValueError:
            card_cols[1].metric("PSR", "n/a")
        try:
            dsr = deflated_sharpe_ratio(
                observed_sharpe, max(n_trials_total, 1), sharpe_variance, n_obs, skewness, kurtosis
            )
            card_cols[2].metric("DSR", f"{dsr:.1%}")
        except ValueError:
            card_cols[2].metric("DSR", "n/a")
        mintrl = minimum_track_record_length(observed_sharpe, 0.0, skewness, kurtosis)
        card_cols[3].metric("MinTRL", "∞" if mintrl == float("inf") else f"{mintrl:.0f}d")
        card_cols[4].metric(
            "2x-slippage SR", "not logged", help="No trial tagged as a 2x-slippage rerun was found."
        )
        card_cols[5].metric(
            "Holdout", "not run", help="Final holdout validation isn't implemented yet."
        )

        st.caption(
            "How to read this: PBO/PSR/DSR/MinTRL are computed from the best-Sharpe "
            "trial in the registry; the last two cards need data this build doesn't "
            "collect yet, so they say so rather than guessing."
        )

        chart_cols = st.columns(2)
        with chart_cols[0]:
            fig = go.Figure(go.Histogram(x=result.logits, marker_color=theme.ACCENT))
            fig.update_layout(title="Logit histogram", height=320)
            st.plotly_chart(fig, width="stretch")
            st.caption("How to read this: mass to the left of 0 is overfitting; PBO is that share.")

        with chart_cols[1]:
            fig = go.Figure(
                go.Scatter(
                    x=result.is_sharpes,
                    y=result.oos_sharpes,
                    mode="markers",
                    marker_color=theme.ACCENT,
                )
            )
            if len(result.is_sharpes) >= 2:
                slope, intercept = np.polyfit(result.is_sharpes, result.oos_sharpes, 1)
                xs = np.linspace(min(result.is_sharpes), max(result.is_sharpes), 20)
                fig.add_trace(
                    go.Scatter(x=xs, y=slope * xs + intercept, mode="lines", line_color=theme.RED)
                )
            fig.update_layout(
                title="IS vs OOS Sharpe",
                xaxis_title="IS Sharpe",
                yaxis_title="OOS Sharpe",
                height=320,
            )
            st.plotly_chart(fig, width="stretch")
            st.caption(
                "How to read this: a flat or negative slope means in-sample skill isn't predictive."
            )

        chart_cols2 = st.columns(2)
        with chart_cols2[0]:
            selected_sorted = np.sort(result.oos_sharpes)
            pooled_sorted = np.sort(result.oos_sharpes_pooled)
            fig = go.Figure()
            fig.add_trace(
                go.Scatter(
                    x=selected_sorted, y=np.linspace(0, 1, len(selected_sorted)), name="selected"
                )
            )
            fig.add_trace(
                go.Scatter(
                    x=pooled_sorted, y=np.linspace(0, 1, len(pooled_sorted)), name="all configs"
                )
            )
            fig.update_layout(title="Stochastic dominance (OOS Sharpe CDF)", height=320)
            st.plotly_chart(fig, width="stretch")
            st.caption("How to read this: the selected line to the right of 'all' is a good sign.")

        with chart_cols2[1]:
            st.info("Parameter heatmap needs 2 varying grid params — not available for this grid.")

        equity_curve = best_series.cumsum()
        chart_cols3 = st.columns(2)
        with chart_cols3[0]:
            fig = go.Figure(
                go.Scatter(
                    x=list(range(len(equity_curve))), y=equity_curve.to_numpy(), mode="lines"
                )
            )
            fig.update_layout(
                title="Best-trial equity (SPY benchmark not wired in yet)", height=320
            )
            st.plotly_chart(fig, width="stretch")
            st.caption("How to read this: cumulative P&L of the best trial in the registry.")

        with chart_cols3[1]:
            running_max = equity_curve.cummax()
            underwater = equity_curve - running_max
            fig = go.Figure(
                go.Scatter(x=list(range(len(underwater))), y=underwater.to_numpy(), fill="tozeroy")
            )
            fig.update_layout(title="Underwater drawdown", height=320)
            st.plotly_chart(fig, width="stretch")
            st.caption("How to read this: depth and duration below zero is time spent in drawdown.")

        chart_cols4 = st.columns(2)
        with chart_cols4[0]:
            rng = np.random.default_rng(0)
            daily = best_series.to_numpy()
            paths = np.array(
                [np.cumsum(rng.choice(daily, size=len(daily), replace=True)) for _ in range(200)]
            )
            fig = go.Figure()
            for lo, hi, opacity in [(5, 95, 0.15), (25, 75, 0.3)]:
                fig.add_trace(
                    go.Scatter(
                        x=list(range(paths.shape[1])),
                        y=np.percentile(paths, hi, axis=0),
                        line={"width": 0},
                        showlegend=False,
                    )
                )
                fig.add_trace(
                    go.Scatter(
                        x=list(range(paths.shape[1])),
                        y=np.percentile(paths, lo, axis=0),
                        fill="tonexty",
                        line={"width": 0},
                        opacity=opacity,
                        showlegend=False,
                    )
                )
            fig.add_trace(
                go.Scatter(x=list(range(paths.shape[1])), y=np.median(paths, axis=0), name="median")
            )
            fig.update_layout(title="Monte Carlo fan (resampled daily P&L)", height=320)
            st.plotly_chart(fig, width="stretch")
            st.caption(
                "How to read this: the spread is what luck alone could do to these daily returns."
            )

        with chart_cols4[1]:
            by_year = best_series.copy()
            by_year.index = pd.to_datetime(by_year.index)
            yearly = by_year.groupby(by_year.index.year).sum()
            fig = go.Figure(go.Bar(x=yearly.index.astype(str), y=yearly.to_numpy()))
            fig.update_layout(title="Returns by year", height=320)
            st.plotly_chart(fig, width="stretch")
            st.caption("How to read this: one bad year dominating the total is a red flag.")
