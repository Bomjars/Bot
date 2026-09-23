from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

import pytest

from intraday_trading.broker.base import OrderInfo, Side
from intraday_trading.broker.ibkr_broker import FillEvent
from intraday_trading.execution.fill_recorder import record_fill
from intraday_trading.risk.signals import EntrySignal
from intraday_trading.storage.fill_log import FillLog
from intraday_trading.storage.order_log import OrderLog

T0 = datetime(2024, 1, 2, 15, 0, tzinfo=UTC)


def _log_an_order(order_log: OrderLog, client_order_id: str, entry_price: float = 100.0) -> None:
    signal = EntrySignal(
        strategy="spy_momentum",
        symbol="AAPL",
        side=Side.BUY,
        qty=10,
        entry_price=entry_price,
        stop_price=95.0,
        take_profit_price=None,
        current_price=entry_price,
        avg_dollar_volume=10_000_000.0,
        spread_pct=0.001,
        signal_seq="seq-1",
    )
    order = OrderInfo(
        broker_order_id="42",
        client_order_id=client_order_id,
        symbol="AAPL",
        side=Side.BUY,
        qty=10,
        status="accepted",
    )
    order_log.log(signal, order)


def test_record_fill_writes_a_fills_row_using_the_orders_expected_price(tmp_path: Path) -> None:
    db_path = tmp_path / "trading.db"
    order_log = OrderLog(db_path)
    fill_log = FillLog(db_path)
    _log_an_order(order_log, "itd-abc", entry_price=100.0)
    event = FillEvent(
        client_order_id="itd-abc",
        broker_order_id="42",
        symbol="AAPL",
        side=Side.BUY,
        qty=10.0,
        fill_price=100.5,
        commission=1.5,
        commission_currency="USD",
        ts=T0,
    )

    recorded = record_fill(fill_log, order_log, event)

    assert recorded is True
    rows = fill_log.recent()
    assert len(rows) == 1
    assert rows[0]["expected_price"] == pytest.approx(100.0)
    assert rows[0]["actual_price"] == pytest.approx(100.5)
    assert rows[0]["slippage"] == pytest.approx(0.5)
    assert rows[0]["commission"] == pytest.approx(1.5)


def test_record_fill_returns_false_when_no_matching_order(tmp_path: Path) -> None:
    db_path = tmp_path / "trading.db"
    order_log = OrderLog(db_path)
    fill_log = FillLog(db_path)
    event = FillEvent(
        client_order_id="unknown-order",
        broker_order_id="99",
        symbol="AAPL",
        side=Side.BUY,
        qty=10.0,
        fill_price=100.0,
        commission=1.0,
        commission_currency="USD",
        ts=T0,
    )

    recorded = record_fill(fill_log, order_log, event)

    assert recorded is False
    assert fill_log.recent() == []
