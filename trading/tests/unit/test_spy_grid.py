"""docs/STRATEGY_SPEC_SPY.md §8's grid: 192 house_risk configs + the paper's own
reference config. `run_and_log_grid` is exercised end-to-end here against small
synthetic bars (a handful of configs, not the full 192, and not real market data --
SPY-11/test_spy_momentum.py already documents why real historical data isn't available
in this sandbox); its job here is to prove the wiring (backtest -> daily P&L -> trial
registry) is correct, not to produce a meaningful backtest result.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta
from pathlib import Path

import pandas as pd
import pytest

from intraday_trading.backtest.costs import CostModel
from intraday_trading.config import RiskLimits
from intraday_trading.session.calendar import EXCHANGE_TZ
from intraday_trading.strategies.base import Bar
from intraday_trading.strategies.spy_grid import (
    DECISION_INTERVAL_VALUES,
    LOOKBACK_DAYS_VALUES,
    STOP_VARIANT_VALUES,
    VM_VALUES,
    GridRunConfig,
    bars_from_dataframe,
    daily_pnl_from_equity_curve,
    house_risk_grid,
    paper_reference_config,
    run_and_log_grid,
)
from intraday_trading.validation.registry import TrialRegistry


def test_house_risk_grid_has_exactly_192_configs() -> None:
    grid = house_risk_grid()
    assert (
        len(grid)
        == 192
        == len(VM_VALUES)
        * len(LOOKBACK_DAYS_VALUES)
        * len(DECISION_INTERVAL_VALUES)
        * len(STOP_VARIANT_VALUES)
    )


def test_house_risk_grid_configs_are_all_unique_and_house_risk() -> None:
    grid = house_risk_grid()
    assert len(set(grid)) == len(grid)  # frozen dataclass -> hashable, uniqueness checkable
    assert all(c.mode == "house_risk" for c in grid)
    assert all(c.sizing == "vol_target" for c in grid)


def test_house_risk_grid_respects_the_leverage_cap_override() -> None:
    grid = house_risk_grid(leverage_cap=1.0)
    assert all(c.leverage_cap == 1.0 for c in grid)


def test_paper_reference_config_matches_the_papers_own_settings() -> None:
    config = paper_reference_config(leverage_cap=4.0)
    assert config.vm == 1.0
    assert config.lookback_days == 14
    assert config.decision_interval_minutes == 30
    assert config.stop_variant == "curr_band_vwap"
    assert config.mode == "paper_faithful"
    assert config.sizing == "vol_target"
    assert config.leverage_cap == 4.0


def test_daily_pnl_from_equity_curve_resamples_to_one_value_per_day() -> None:
    day1 = datetime(2024, 1, 2, tzinfo=EXCHANGE_TZ)
    day2 = datetime(2024, 1, 3, tzinfo=EXCHANGE_TZ)
    equity_curve = [
        (day1 + timedelta(hours=1), 100_500.0),
        (day1 + timedelta(hours=6), 101_000.0),  # day 1 ends at 101,000
        (day2 + timedelta(hours=1), 100_800.0),
        (day2 + timedelta(hours=6), 102_000.0),  # day 2 ends at 102,000
    ]

    daily_pnl = daily_pnl_from_equity_curve(equity_curve, starting_equity=100_000.0)

    assert list(daily_pnl.index) == [date(2024, 1, 2), date(2024, 1, 3)]
    assert daily_pnl.iloc[0] == pytest.approx(1_000.0)  # 101,000 - 100,000 starting
    assert daily_pnl.iloc[1] == pytest.approx(1_000.0)  # 102,000 - 101,000


def test_daily_pnl_from_equity_curve_empty_is_empty() -> None:
    assert daily_pnl_from_equity_curve([], starting_equity=100_000.0).empty


def test_bars_from_dataframe_round_trips_and_sorts_chronologically() -> None:
    ts_late = pd.Timestamp("2024-01-02 10:01:00", tz="UTC")
    ts_early = pd.Timestamp("2024-01-02 10:00:00", tz="UTC")
    df = pd.DataFrame(
        [
            {
                "symbol": "SPY",
                "ts": ts_late,
                "open": 101.0,
                "high": 101.5,
                "low": 100.5,
                "close": 101.2,
                "volume": 1000.0,
                "feed": "iex",
            },
            {
                "symbol": "SPY",
                "ts": ts_early,
                "open": 100.0,
                "high": 100.5,
                "low": 99.5,
                "close": 100.2,
                "volume": 900.0,
                "feed": "iex",
            },
        ]
    )

    bars = bars_from_dataframe(df)

    assert [b.ts for b in bars] == [ts_early.to_pydatetime(), ts_late.to_pydatetime()]
    assert bars[0].close == 100.2
    assert bars[1].close == 101.2


def test_bars_from_dataframe_rejects_a_frame_missing_columns() -> None:
    with pytest.raises(ValueError, match="missing columns"):
        bars_from_dataframe(pd.DataFrame({"symbol": ["SPY"]}))


def _synthetic_multiday_bars(symbol: str, n_days: int) -> list[Bar]:
    """Enough days of a mild, alternating pattern to exercise the strategy end-to-end
    without ever needing to trade (RiskLimits stay default and tight) -- this test is
    about the grid-running plumbing, not about producing a realistic backtest."""
    bars = []
    base_date = date(2024, 1, 2)
    trading_days = 0
    d = base_date
    while trading_days < n_days:
        if d.weekday() < 5:  # skip weekends; exact NYSE holidays don't matter for this test
            open_price = 100.0 + (trading_days % 3)
            bars.append(
                Bar(
                    ts=datetime(d.year, d.month, d.day, 9, 30, tzinfo=EXCHANGE_TZ),
                    open=open_price,
                    high=open_price,
                    low=open_price,
                    close=open_price,
                    volume=1_000_000.0,
                )
            )
            bars.append(
                Bar(
                    ts=datetime(d.year, d.month, d.day, 10, 0, tzinfo=EXCHANGE_TZ),
                    open=open_price,
                    high=open_price,
                    low=open_price,
                    close=open_price * 1.001,
                    volume=1_000_000.0,
                )
            )
            trading_days += 1
        d = d + timedelta(days=1)
    return bars


def test_run_and_log_grid_logs_one_trial_per_config(tmp_path: Path) -> None:
    from intraday_trading.strategies.spy_momentum import SpyMomentumConfig

    symbol = "SPY"
    bars = {symbol: _synthetic_multiday_bars(symbol, n_days=20)}
    configs = [
        SpyMomentumConfig(lookback_days=10, sizing="fixed_notional", mode="house_risk"),
        SpyMomentumConfig(
            lookback_days=10,
            sizing="fixed_notional",
            mode="house_risk",
            stop_variant="opposite_band",
        ),
    ]
    db_path = tmp_path / "grid.db"
    run_config = GridRunConfig(
        starting_equity=100_000.0,
        cost_model=CostModel(),
        risk_limits=RiskLimits(min_avg_dollar_volume_usd=1.0, min_price_usd=0.01),
    )
    registry = TrialRegistry(db_path)

    trial_ids = run_and_log_grid(symbol, "spy_momentum", configs, bars, run_config, registry)

    assert len(trial_ids) == 2
    logged = registry.get_trials("spy_momentum")
    assert len(logged) == 2
    assert {t.trial_id for t in logged} == set(trial_ids)
    matrix = registry.daily_pnl_matrix("spy_momentum")
    assert matrix.shape[1] == 2
    assert len(matrix) > 0


def test_BT_008_each_grid_run_starts_from_fresh_risk_state(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A DRAWDOWN halt (and peak equity) from one config must not leak into the next --
    previously every run shared the real DB's single risk_state row, so one early
    config halting silently stopped every later config from ever trading."""
    import intraday_trading.strategies.spy_grid as spy_grid
    from intraday_trading.backtest.engine import run_backtest as real_run_backtest
    from intraday_trading.strategies.spy_momentum import SpyMomentumConfig

    seen_halted_at_start: list[bool] = []

    def _spy_run_backtest(strategy, bars, risk_manager, broker, time_box):  # type: ignore[no-untyped-def]
        seen_halted_at_start.append(risk_manager.is_halted())
        result = real_run_backtest(strategy, bars, risk_manager, broker, time_box)
        risk_manager.trip_kill_switch("first run halts itself")
        return result

    monkeypatch.setattr(spy_grid, "run_backtest", _spy_run_backtest)
    symbol = "SPY"
    bars = {symbol: _synthetic_multiday_bars(symbol, n_days=3)}
    run_config = GridRunConfig(
        starting_equity=100_000.0, cost_model=CostModel(), risk_limits=RiskLimits()
    )
    config = SpyMomentumConfig(lookback_days=10, sizing="fixed_notional", mode="house_risk")

    spy_grid.run_spy_config(symbol, config, bars, run_config)
    spy_grid.run_spy_config(symbol, config, bars, run_config)

    assert seen_halted_at_start == [False, False]


def test_BT_008_grid_run_never_touches_the_trading_database(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from intraday_trading.strategies.spy_momentum import SpyMomentumConfig

    monkeypatch.chdir(tmp_path)  # any stray relative-path DB would land here
    symbol = "SPY"
    bars = {symbol: _synthetic_multiday_bars(symbol, n_days=3)}
    run_config = GridRunConfig(
        starting_equity=100_000.0, cost_model=CostModel(), risk_limits=RiskLimits()
    )
    config = SpyMomentumConfig(lookback_days=10, sizing="fixed_notional", mode="house_risk")

    run_and_log_grid(
        symbol, "spy_momentum", [config], bars, run_config, TrialRegistry(tmp_path / "t.db")
    )

    assert sorted(p.name for p in tmp_path.iterdir()) == ["t.db"]
