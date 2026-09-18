"""AlpacaBroker exercised entirely against a fake TradingClient — no network access, no
real Alpaca keys needed. Verifies the adapter maps our vendor-neutral Broker interface
onto alpaca-py's request/response shapes correctly, and that bracket orders always carry
a stop (RISK-010) with the client_order_id we were given (EXEC-002).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime

from alpaca.trading.enums import OrderSide

import intraday_trading.broker.alpaca_broker as alpaca_broker_module
from intraday_trading.broker.alpaca_broker import AlpacaBroker
from intraday_trading.broker.base import BracketOrderRequest, Side
from intraday_trading.config import Settings


@dataclass
class FakeOrder:
    id: str = "order-1"
    client_order_id: str = "itd-abc"
    symbol: str = "AAPL"
    side: OrderSide = OrderSide.BUY
    qty: str = "10"
    status: str = "accepted"
    filled_qty: str = "0"
    filled_avg_price: str | None = None


@dataclass
class FakePosition:
    symbol: str = "AAPL"
    qty: str = "10"
    avg_entry_price: str = "100.0"
    current_price: str = "101.5"
    unrealized_pl: str = "15.0"


@dataclass
class FakeAccount:
    portfolio_value: str = "10000.0"
    cash: str = "5000.0"
    buying_power: str = "10000.0"
    currency: str = "USD"


@dataclass
class FakeClock:
    timestamp: datetime = field(default_factory=lambda: datetime(2024, 1, 2, 14, 30, tzinfo=UTC))
    is_open: bool = True


class FakeTradingClient:
    def __init__(self) -> None:
        self.submitted_orders: list = []
        self.cancelled_ids: list[str] = []
        self.cancel_all_called = False
        self.closed_symbols: list[str] = []
        self.close_all_called = False

    def get_account(self) -> FakeAccount:
        return FakeAccount()

    def get_all_positions(self) -> list[FakePosition]:
        return [FakePosition()]

    def get_orders(self, filter=None) -> list[FakeOrder]:
        return [FakeOrder()]

    def get_clock(self) -> FakeClock:
        return FakeClock()

    def submit_order(self, order_data) -> FakeOrder:
        self.submitted_orders.append(order_data)
        return FakeOrder(client_order_id=order_data.client_order_id)

    def cancel_order_by_id(self, order_id: str) -> None:
        self.cancelled_ids.append(order_id)

    def cancel_orders(self) -> None:
        self.cancel_all_called = True

    def close_position(self, symbol: str, close_options=None) -> FakeOrder:
        self.closed_symbols.append(symbol)
        return FakeOrder(symbol=symbol)

    def close_all_positions(self, cancel_orders: bool | None = None) -> list:
        self.close_all_called = True
        return []


def test_get_account_maps_portfolio_value_to_equity() -> None:
    broker = AlpacaBroker(FakeTradingClient())
    account = broker.get_account()
    assert account.equity == 10000.0
    assert account.cash == 5000.0
    assert account.currency == "USD"


def test_get_positions_maps_side_from_signed_qty() -> None:
    broker = AlpacaBroker(FakeTradingClient())
    positions = broker.get_positions()
    assert positions[0].symbol == "AAPL"
    assert positions[0].side == Side.BUY
    assert positions[0].qty == 10.0


def test_get_open_orders_maps_status_and_symbol() -> None:
    broker = AlpacaBroker(FakeTradingClient())
    orders = broker.get_open_orders()
    assert orders[0].symbol == "AAPL"
    assert orders[0].status == "accepted"


def test_get_clock_passes_through() -> None:
    broker = AlpacaBroker(FakeTradingClient())
    clock = broker.get_clock()
    assert clock.is_open is True


def test_EXEC_001_bracket_order_always_carries_stop_loss() -> None:
    client = FakeTradingClient()
    broker = AlpacaBroker(client)
    request = BracketOrderRequest(
        client_order_id="itd-fixed-id",
        symbol="AAPL",
        side=Side.BUY,
        qty=10,
        stop_loss_price=95.0,
        take_profit_price=None,
    )

    result = broker.submit_bracket_order(request)

    assert len(client.submitted_orders) == 1
    submitted = client.submitted_orders[0]
    # No take-profit price -> OTO (one-triggers-other) with just the stop leg; Alpaca's
    # own OrderClass.BRACKET requires both legs, which our stop-only exits don't have.
    assert submitted.order_class.value == "oto"
    assert submitted.stop_loss.stop_price == 95.0
    assert submitted.client_order_id == "itd-fixed-id"
    assert result.client_order_id == "itd-fixed-id"


def test_EXEC_001_bracket_order_uses_bracket_class_with_take_profit() -> None:
    client = FakeTradingClient()
    broker = AlpacaBroker(client)
    request = BracketOrderRequest(
        client_order_id="itd-fixed-id-2",
        symbol="AAPL",
        side=Side.BUY,
        qty=10,
        stop_loss_price=95.0,
        take_profit_price=110.0,
    )

    broker.submit_bracket_order(request)

    submitted = client.submitted_orders[0]
    assert submitted.order_class.value == "bracket"
    assert submitted.take_profit.limit_price == 110.0


def test_cancel_order_delegates_to_client() -> None:
    client = FakeTradingClient()
    broker = AlpacaBroker(client)
    broker.cancel_order("order-1")
    assert client.cancelled_ids == ["order-1"]


def test_KILL_001_cancel_all_then_flatten_all() -> None:
    client = FakeTradingClient()
    broker = AlpacaBroker(client)
    broker.cancel_all_orders()
    broker.close_all_positions()
    assert client.cancel_all_called is True
    assert client.close_all_called is True


def test_close_position_delegates_to_client() -> None:
    client = FakeTradingClient()
    broker = AlpacaBroker(client)
    broker.close_position("AAPL")
    assert client.closed_symbols == ["AAPL"]


def test_SAFE_004_paper_classmethod_always_passes_paper_true(monkeypatch) -> None:
    captured: dict = {}

    class SpyTradingClient:
        def __init__(self, api_key: str, secret_key: str, paper: bool) -> None:
            captured["api_key"] = api_key
            captured["paper"] = paper

    monkeypatch.setattr(alpaca_broker_module, "TradingClient", SpyTradingClient)
    settings = Settings(alpaca_api_key="k", alpaca_secret_key="s")

    AlpacaBroker.paper(settings)

    assert captured["paper"] is True
    assert not hasattr(AlpacaBroker, "live")
