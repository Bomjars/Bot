from __future__ import annotations

from pathlib import Path

from intraday_trading.broker.base import OrderInfo, Side
from intraday_trading.risk.signals import EntrySignal
from intraday_trading.storage.order_log import OrderLog


def _signal() -> EntrySignal:
    return EntrySignal(
        strategy="orb",
        symbol="AAPL",
        side=Side.BUY,
        qty=10,
        entry_price=100.0,
        stop_price=95.0,
        take_profit_price=None,
        current_price=100.0,
        avg_dollar_volume=10_000_000.0,
        spread_pct=0.001,
        signal_seq="seq-1",
    )


def _order() -> OrderInfo:
    return OrderInfo(
        broker_order_id="b1",
        client_order_id="c1",
        symbol="AAPL",
        side=Side.BUY,
        qty=10,
        status="filled",
        filled_qty=10,
        filled_avg_price=100.05,
    )


def test_log_and_recent_round_trip(tmp_path: Path) -> None:
    log = OrderLog(tmp_path / "orders.db")
    log.log(_signal(), _order())

    rows = log.recent()

    assert len(rows) == 1
    assert rows[0]["symbol"] == "AAPL"
    assert rows[0]["client_order_id"] == "c1"
    assert rows[0]["broker_order_id"] == "b1"


def test_count(tmp_path: Path) -> None:
    log = OrderLog(tmp_path / "orders.db")
    assert log.count() == 0
    log.log(_signal(), _order())
    assert log.count() == 1


def test_recent_respects_limit(tmp_path: Path) -> None:
    log = OrderLog(tmp_path / "orders.db")
    for _i in range(5):
        log.log(_signal(), _order())
    assert len(log.recent(limit=3)) == 3


def test_find_by_client_order_id_returns_the_matching_row(tmp_path: Path) -> None:
    log = OrderLog(tmp_path / "orders.db")
    log.log(_signal(), _order())

    row = log.find_by_client_order_id("c1")

    assert row is not None
    assert row["symbol"] == "AAPL"
    assert row["entry_price"] == 100.0


def test_find_by_client_order_id_returns_none_when_not_found(tmp_path: Path) -> None:
    log = OrderLog(tmp_path / "orders.db")
    assert log.find_by_client_order_id("nonexistent") is None
