"""dev/demo_data.py: purely synthetic data for previewing a populated dashboard. These
tests check the generator writes a coherent, non-degenerate dataset (real dates spread
across distinct days, a CSCV-passable trial set) -- not that any particular number is
"correct", since none of it represents anything real.
"""

from __future__ import annotations

from pathlib import Path

from intraday_trading.dev.demo_data import (
    N_DEMO_CLOSED_TRADES,
    N_DEMO_CONFIGS,
    N_DEMO_TRADE_DAYS,
    generate_demo_data,
)
from intraday_trading.storage.closed_trade_log import ClosedTradeLog
from intraday_trading.storage.order_log import OrderLog
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.validation.cscv import cscv_pbo, evaluate
from intraday_trading.validation.registry import TrialRegistry
from intraday_trading.validation.signal_confidence import build_confidence_table


def test_generate_demo_data_populates_trials_orders_and_rejections(tmp_path: Path) -> None:
    db_path = tmp_path / "demo.db"

    generate_demo_data(db_path)

    registry = TrialRegistry(db_path)
    trials = registry.get_trials("spy_momentum")
    assert len(trials) == N_DEMO_CONFIGS
    assert len(registry.get_trials("spy_momentum_paper_faithful")) == 1

    assert OrderLog(db_path).count_distinct_days() == N_DEMO_TRADE_DAYS
    assert RejectionLog(db_path).count() > 0


def test_generate_demo_data_populates_orders_with_a_signal_strength(tmp_path: Path) -> None:
    db_path = tmp_path / "demo.db"
    generate_demo_data(db_path)

    orders = OrderLog(db_path).recent(limit=N_DEMO_TRADE_DAYS)
    assert all(order["signal_strength"] is not None for order in orders)


def test_generate_demo_data_populates_a_bucketable_closed_trade_set(tmp_path: Path) -> None:
    db_path = tmp_path / "demo.db"
    generate_demo_data(db_path)

    closed_trade_log = ClosedTradeLog(db_path)
    assert closed_trade_log.count("spy_momentum") == N_DEMO_CLOSED_TRADES
    trades = closed_trade_log.load("spy_momentum")
    assert all(trade.signal_strength is not None for trade in trades)

    table = build_confidence_table(trades)
    assert sum(bucket.n for bucket in table.buckets) == N_DEMO_CLOSED_TRADES
    # At least one bucket has enough trades for its win rate to mean something --
    # this is what makes the demo dashboard's confidence card show a real number.
    assert any(bucket.n >= 5 for bucket in table.buckets)


def test_generate_demo_data_produces_a_cscv_passable_trial_set(tmp_path: Path) -> None:
    """Not asserting the CSCV verdict itself is stable API to depend on, but this
    generator is meant to demo a *populated* validation report -- a matrix too small
    or too degenerate to run CSCV on at all would defeat that purpose."""
    db_path = tmp_path / "demo.db"
    generate_demo_data(db_path)

    matrix = TrialRegistry(db_path).daily_pnl_matrix("spy_momentum")
    assert matrix.shape[1] == N_DEMO_CONFIGS
    assert len(matrix) >= 32  # dashboard's MIN_DAYS_FOR_CSCV

    result = cscv_pbo(matrix.fillna(0.0))
    verdict = evaluate(result)
    assert verdict.passed  # tuned to demo a realistic PASS, not a rigged one


def test_generate_demo_data_is_deterministic(tmp_path: Path) -> None:
    db_a, db_b = tmp_path / "a.db", tmp_path / "b.db"
    generate_demo_data(db_a, seed=3)
    generate_demo_data(db_b, seed=3)

    matrix_a = TrialRegistry(db_a).daily_pnl_matrix("spy_momentum")
    matrix_b = TrialRegistry(db_b).daily_pnl_matrix("spy_momentum")
    assert matrix_a.equals(matrix_b)
