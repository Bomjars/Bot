"""reporting/backtest_summary.py (BT-009): the plain-English numbers behind a grid."""

from __future__ import annotations

from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

from intraday_trading.reporting.backtest_summary import (
    performance_from_daily_pnl,
    performance_from_prices,
    summarize_grid,
)
from intraday_trading.validation.registry import TrialRegistry


def _dates(n: int, start: date = date(2020, 1, 1)) -> list[date]:
    return [start + timedelta(days=i) for i in range(n)]


def test_BT_009_total_return_and_drawdown_from_daily_pnl() -> None:
    pnl = pd.Series([100.0, -300.0, 0.0, 400.0], index=_dates(4))

    perf = performance_from_daily_pnl(pnl, starting_equity=1_000.0)

    assert perf.days == 4
    assert perf.total_return_pct == pytest.approx(20.0)  # 1000 -> 1200
    assert perf.max_drawdown_pct == pytest.approx(300 / 1100 * 100)  # 1100 -> 800
    assert perf.active_day_pct == pytest.approx(75.0)  # one flat day


def test_annual_return_compounds_over_252_days() -> None:
    pnl = pd.Series([0.0] * 251 + [1_000.0], index=_dates(252))
    perf = performance_from_daily_pnl(pnl, starting_equity=10_000.0)
    assert perf.annual_return_pct == pytest.approx(10.0)


def test_a_wiped_out_account_reports_minus_100_per_year() -> None:
    perf = performance_from_daily_pnl(pd.Series([-1_000.0], index=_dates(1)), 1_000.0)
    assert perf.annual_return_pct == -100.0
    assert perf.sharpe == 0.0  # one day -- no volatility estimate


def test_sharpe_is_positive_for_steady_gains() -> None:
    rng = np.random.default_rng(0)
    pnl = pd.Series(10.0 + rng.normal(0, 5, 500), index=_dates(500))
    perf = performance_from_daily_pnl(pnl, 10_000.0)
    assert perf.sharpe > 1.0
    assert perf.annual_vol_pct > 0


def test_performance_from_daily_pnl_rejects_bad_inputs() -> None:
    with pytest.raises(ValueError, match="starting_equity"):
        performance_from_daily_pnl(pd.Series([1.0]), 0.0)
    with pytest.raises(ValueError, match="empty"):
        performance_from_daily_pnl(pd.Series(dtype=float), 1.0)


def test_BT_009_buy_and_hold_from_prices() -> None:
    perf = performance_from_prices(100.0, pd.Series([110.0, 88.0, 121.0], index=_dates(3)))
    assert perf.total_return_pct == pytest.approx(21.0)
    assert perf.max_drawdown_pct == pytest.approx(20.0)  # 110 -> 88
    assert perf.active_day_pct == 100.0


def test_performance_from_prices_rejects_bad_inputs() -> None:
    with pytest.raises(ValueError, match="start_price"):
        performance_from_prices(0.0, pd.Series([1.0]))
    with pytest.raises(ValueError, match="empty"):
        performance_from_prices(1.0, pd.Series(dtype=float))


def _log_grid(registry: TrialRegistry, strategy: str, n_trials: int, n_days: int) -> None:
    rng = np.random.default_rng(1)
    for i in range(n_trials):
        pnl = pd.Series(rng.normal(5.0 * (i - 1), 5.0, n_days), index=_dates(n_days))
        registry.log_trial(strategy, {"vm": 1.0 + i / 10}, pnl)


def test_summarize_grid_returns_none_without_trials(tmp_path: Path) -> None:
    assert summarize_grid(TrialRegistry(tmp_path / "r.db"), "nope", 1_000.0) is None


def test_BT_009_summarize_grid_reports_verdict_best_config_and_breadth(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "r.db")
    _log_grid(registry, "s", n_trials=4, n_days=64)

    summary = summarize_grid(registry, "s", starting_equity=10_000.0)

    assert summary is not None
    assert summary.n_trials == 4
    assert summary.n_date_ranges == 1
    assert summary.first_date == "2020-01-01"
    assert summary.best.days == 64
    assert summary.best_params["vm"] == pytest.approx(1.3)  # the strongest drift
    assert 0 <= summary.n_profitable <= 4
    assert summary.pbo is not None and 0.0 <= summary.pbo <= 1.0
    assert summary.cscv_passed is not None
    assert summary.dsr is not None


def test_summarize_grid_skips_cscv_when_too_little_data(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "r.db")
    _log_grid(registry, "s", n_trials=3, n_days=10)

    summary = summarize_grid(registry, "s", starting_equity=10_000.0)

    assert summary is not None
    assert summary.pbo is None
    assert summary.cscv_passed is None
    assert summary.dsr is None


def test_BT_009_mixed_backtest_runs_are_detected(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "r.db")
    _log_grid(registry, "s", n_trials=2, n_days=64)
    registry.log_trial("s", {"vm": 9.0}, pd.Series([1.0] * 5, index=_dates(5, date(2020, 2, 1))))

    summary = summarize_grid(registry, "s", starting_equity=10_000.0)

    assert summary is not None
    assert summary.n_date_ranges == 2


def test_dsr_is_none_when_it_cannot_be_computed(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    import intraday_trading.reporting.backtest_summary as module

    def _raise(*args: object) -> float:
        raise ValueError("degenerate")

    monkeypatch.setattr(module, "deflated_sharpe_ratio", _raise)
    registry = TrialRegistry(tmp_path / "r.db")
    _log_grid(registry, "s", n_trials=3, n_days=64)

    summary = summarize_grid(registry, "s", starting_equity=10_000.0)

    assert summary is not None
    assert summary.pbo is not None
    assert summary.dsr is None


def test_dsr_is_none_rather_than_nan_for_a_flat_grid(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "r.db")
    for i in range(3):
        registry.log_trial("s", {"vm": float(i)}, pd.Series([0.0] * 64, index=_dates(64)))

    summary = summarize_grid(registry, "s", starting_equity=10_000.0)

    assert summary is not None
    assert summary.dsr is None
    assert summary.cscv_passed is False
    assert summary.cscv_reason is not None and "3/3 configs never traded" in summary.cscv_reason


def test_VAL_015_summary_ignores_retired_trials(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "r.db")
    _log_grid(registry, "s", n_trials=3, n_days=64)
    registry.retire_all("s", reason="bad run")

    assert summarize_grid(registry, "s", starting_equity=10_000.0) is None
