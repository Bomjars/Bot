"""Shared test double for the `Broker` protocol itself (as opposed to
test_broker_alpaca.py's FakeTradingClient, which fakes alpaca-py one layer further down).
Used by RiskManager tests and, later, backtester/execution tests."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime

from intraday_trading.broker.base import (
    AccountInfo,
    BracketOrderRequest,
    BrokerClock,
    OrderInfo,
    PositionInfo,
)


@dataclass
class FakeBroker:
    equity: float = 100_000.0
    cash: float = 100_000.0
    buying_power: float = 100_000.0
    positions: list[PositionInfo] = field(default_factory=list)
    submitted_orders: list[BracketOrderRequest] = field(default_factory=list)
    cancel_all_called: int = 0
    close_all_called: int = 0
    raise_on_submit: Exception | None = None
    raise_on_close: Exception | None = None
    is_open: bool = True

    def get_account(self) -> AccountInfo:
        return AccountInfo(
            equity=self.equity, cash=self.cash, buying_power=self.buying_power, currency="USD"
        )

    def get_positions(self) -> list[PositionInfo]:
        return list(self.positions)

    def get_open_orders(self) -> list[OrderInfo]:
        return []

    def get_clock(self) -> BrokerClock:
        return BrokerClock(timestamp=datetime.now(tz=UTC), is_open=self.is_open)

    def submit_bracket_order(self, request: BracketOrderRequest) -> OrderInfo:
        if self.raise_on_submit is not None:
            raise self.raise_on_submit
        self.submitted_orders.append(request)
        return OrderInfo(
            broker_order_id=f"order-{len(self.submitted_orders)}",
            client_order_id=request.client_order_id,
            symbol=request.symbol,
            side=request.side,
            qty=request.qty,
            status="accepted",
        )

    def cancel_order(self, broker_order_id: str) -> None:
        pass

    def cancel_all_orders(self) -> None:
        self.cancel_all_called += 1

    def close_position(self, symbol: str) -> OrderInfo | None:
        if self.raise_on_close is not None:
            raise self.raise_on_close
        matched = next((p for p in self.positions if p.symbol == symbol), None)
        self.positions = [p for p in self.positions if p.symbol != symbol]
        if matched is None:
            return None
        return OrderInfo(
            broker_order_id="close-order-1",
            client_order_id="close-client-1",
            symbol=symbol,
            side=matched.side,
            qty=matched.qty,
            status="filled",
            filled_qty=matched.qty,
            filled_avg_price=matched.current_price,
        )

    def close_all_positions(self) -> None:
        self.close_all_called += 1
        self.positions = []
