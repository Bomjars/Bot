from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

import pytest

from intraday_trading.backtest.simulated_broker import TradeRecord
from intraday_trading.broker.base import Side
from intraday_trading.storage.closed_trade_log import ClosedTradeLog

T0 = datetime(2024, 1, 2, 10, 0, tzinfo=UTC)
T1 = datetime(2024, 1, 2, 10, 30, tzinfo=UTC)


def _trade(signal_strength: float | None = 0.3) -> TradeRecord:
    return TradeRecord(
        symbol="SPY",
        side=Side.BUY,
        qty=10,
        entry_price=100.0,
        exit_price=101.0,
        entry_time=T0,
        exit_time=T1,
        exit_reason="stop",
        realized_pnl=10.0,
        total_commission=0.5,
        signal_strength=signal_strength,
    )


def test_log_many_and_load_round_trip(tmp_path: Path) -> None:
    log = ClosedTradeLog(tmp_path / "trades.db")
    log.log_many("spy_momentum", [_trade()])

    rows = log.load("spy_momentum")

    assert len(rows) == 1
    row = rows[0]
    assert row.strategy == "spy_momentum"
    assert row.symbol == "SPY"
    assert row.realized_pnl == pytest.approx(10.0)
    assert row.signal_strength == pytest.approx(0.3)


def test_signal_strength_round_trips_as_none(tmp_path: Path) -> None:
    log = ClosedTradeLog(tmp_path / "trades.db")
    log.log_many("spy_momentum", [_trade(signal_strength=None)])

    assert log.load("spy_momentum")[0].signal_strength is None


def test_load_is_scoped_to_the_given_strategy(tmp_path: Path) -> None:
    log = ClosedTradeLog(tmp_path / "trades.db")
    log.log_many("spy_momentum", [_trade()])
    log.log_many("other_strategy", [_trade()])

    assert len(log.load("spy_momentum")) == 1
    assert len(log.load("other_strategy")) == 1


def test_count(tmp_path: Path) -> None:
    log = ClosedTradeLog(tmp_path / "trades.db")
    assert log.count("spy_momentum") == 0
    log.log_many("spy_momentum", [_trade(), _trade()])
    assert log.count("spy_momentum") == 2


def test_log_many_with_an_empty_list_is_a_no_op(tmp_path: Path) -> None:
    log = ClosedTradeLog(tmp_path / "trades.db")
    log.log_many("spy_momentum", [])
    assert log.count("spy_momentum") == 0
