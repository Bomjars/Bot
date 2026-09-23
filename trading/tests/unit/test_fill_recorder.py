from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

import pytest

from intraday_trading.broker.base import OrderInfo, Side
from intraday_trading.broker.ibkr_broker import FillEvent
from intraday_trading.execution.fill_recorder import (
    FxEstimate,
    record_event,
    record_fill,
    record_fx_conversion,
)
from intraday_trading.risk.signals import EntrySignal
from intraday_trading.storage.fill_log import FillLog
from intraday_trading.storage.fx_conversion_log import FxConversionLog
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


def _stock_fill(client_order_id: str = "itd-abc", currency: str = "USD") -> FillEvent:
    return FillEvent(
        client_order_id=client_order_id,
        broker_order_id="42",
        symbol="AAPL",
        side=Side.BUY,
        qty=10.0,
        fill_price=100.0,
        commission=1.0,
        commission_currency="USD",
        ts=T0,
        currency=currency,
        sec_type="STK",
    )


def _fx_fill() -> FillEvent:
    return FillEvent(
        client_order_id="",  # a conversion has no originating order
        broker_order_id="7",
        symbol="GBP",
        side=Side.SELL,
        qty=1_000.0,
        fill_price=1.27,
        commission=2.0,
        commission_currency="USD",
        ts=T0,
        currency="USD",
        sec_type="CASH",
    )


def test_fx_estimate_is_zero_when_currencies_match() -> None:
    estimate = FxEstimate(account_currency="USD", cost_per_fill_pct=0.002)
    assert estimate.cost("USD", notional=1_000.0) == 0.0


def test_fx_estimate_applies_the_rate_when_currencies_differ() -> None:
    estimate = FxEstimate(account_currency="GBP", cost_per_fill_pct=0.002)
    assert estimate.cost("USD", notional=1_000.0) == pytest.approx(2.0)


def test_EXEC_014_record_fill_stores_the_fx_cost_estimate(tmp_path: Path) -> None:
    db_path = tmp_path / "trading.db"
    order_log = OrderLog(db_path)
    fill_log = FillLog(db_path)
    _log_an_order(order_log, "itd-abc")
    estimate = FxEstimate(account_currency="GBP", cost_per_fill_pct=0.002)

    record_fill(fill_log, order_log, _stock_fill(currency="USD"), estimate)

    row = fill_log.recent()[0]
    assert row["currency"] == "USD"
    assert row["fx_cost"] == pytest.approx(10.0 * 100.0 * 0.002)


def test_record_fill_without_an_estimate_stores_zero_fx_cost(tmp_path: Path) -> None:
    db_path = tmp_path / "trading.db"
    order_log = OrderLog(db_path)
    fill_log = FillLog(db_path)
    _log_an_order(order_log, "itd-abc")

    record_fill(fill_log, order_log, _stock_fill())

    assert fill_log.recent()[0]["fx_cost"] == 0.0


def test_EXEC_014_record_fx_conversion_logs_the_measured_conversion(tmp_path: Path) -> None:
    fx_log = FxConversionLog(tmp_path / "trading.db")

    record_fx_conversion(fx_log, _fx_fill())

    row = fx_log.recent()[0]
    assert row["pair"] == "GBP.USD"
    assert row["side"] == "sell"
    assert row["amount"] == pytest.approx(1_000.0)
    assert row["rate"] == pytest.approx(1.27)
    assert row["commission"] == pytest.approx(2.0)


def test_EXEC_014_record_event_routes_a_conversion_to_the_fx_log(tmp_path: Path) -> None:
    db_path = tmp_path / "trading.db"
    order_log, fill_log, fx_log = OrderLog(db_path), FillLog(db_path), FxConversionLog(db_path)

    record_event(fill_log, fx_log, order_log, _fx_fill())

    assert len(fx_log.recent()) == 1
    assert fill_log.recent() == []  # not dropped as an "unmatched" stock fill


def test_record_event_routes_a_stock_fill_to_the_fill_log(tmp_path: Path) -> None:
    db_path = tmp_path / "trading.db"
    order_log, fill_log, fx_log = OrderLog(db_path), FillLog(db_path), FxConversionLog(db_path)
    _log_an_order(order_log, "itd-abc")

    record_event(fill_log, fx_log, order_log, _stock_fill())

    assert len(fill_log.recent()) == 1
    assert fx_log.recent() == []
