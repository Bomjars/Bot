"""Alpaca implementation of the `Broker` interface. Paper only — see CLAUDE.md; there is
deliberately no code path in this class that can reach Alpaca's live endpoint. The
`alpaca.trading.client.TradingClient` is injected rather than constructed internally by
default, so tests exercise this class against a fake without any network access; use
`AlpacaBroker.paper()` to get a real one wired to your `.env` paper keys.
"""

from __future__ import annotations

from alpaca.trading.client import TradingClient
from alpaca.trading.enums import OrderClass, OrderSide, QueryOrderStatus, TimeInForce
from alpaca.trading.models import Order as AlpacaOrder
from alpaca.trading.models import Position as AlpacaPosition
from alpaca.trading.requests import (
    GetOrdersRequest,
    MarketOrderRequest,
    StopLossRequest,
    TakeProfitRequest,
)

from intraday_trading.broker.base import (
    AccountInfo,
    BracketOrderRequest,
    BrokerClock,
    OrderInfo,
    PositionInfo,
    Side,
)
from intraday_trading.config import Settings

_SIDE_TO_ALPACA = {Side.BUY: OrderSide.BUY, Side.SELL: OrderSide.SELL}
_SIDE_FROM_ALPACA = {v: k for k, v in _SIDE_TO_ALPACA.items()}


def _order_info_from_alpaca(order: AlpacaOrder) -> OrderInfo:
    if order.symbol is None or order.side is None:
        raise ValueError(f"Alpaca order missing symbol/side: {order!r}")
    return OrderInfo(
        broker_order_id=str(order.id),
        client_order_id=order.client_order_id or "",
        symbol=order.symbol,
        side=_SIDE_FROM_ALPACA[order.side],
        qty=float(order.qty) if order.qty is not None else 0.0,
        status=str(order.status.value if hasattr(order.status, "value") else order.status),
        filled_qty=float(order.filled_qty or 0.0),
        filled_avg_price=float(order.filled_avg_price) if order.filled_avg_price else None,
    )


def _position_info_from_alpaca(position: AlpacaPosition) -> PositionInfo:
    qty = float(position.qty)
    return PositionInfo(
        symbol=position.symbol,
        qty=abs(qty),
        side=Side.BUY if qty >= 0 else Side.SELL,
        avg_entry_price=float(position.avg_entry_price),
        current_price=float(position.current_price) if position.current_price else 0.0,
        unrealized_pl=float(position.unrealized_pl) if position.unrealized_pl else 0.0,
    )


class AlpacaBroker:
    def __init__(self, client: TradingClient) -> None:
        self._client = client

    @classmethod
    def paper(cls, settings: Settings) -> AlpacaBroker:
        """The only supported way to construct this class from `Settings` — always
        `paper=True`. There is intentionally no `.live(...)` classmethod yet; that arrives
        with the go-live gate (step 10), not before."""
        client = TradingClient(
            api_key=settings.alpaca_api_key,
            secret_key=settings.alpaca_secret_key,
            paper=True,
        )
        return cls(client)

    def get_account(self) -> AccountInfo:
        account = self._client.get_account()
        if isinstance(account, dict):
            raise TypeError(f"unexpected raw dict response from Alpaca: {account!r}")
        if account.portfolio_value is None or account.cash is None or account.buying_power is None:
            raise ValueError(f"Alpaca account missing required fields: {account!r}")
        return AccountInfo(
            equity=float(account.portfolio_value),
            cash=float(account.cash),
            buying_power=float(account.buying_power),
            currency=account.currency or "USD",
        )

    def get_positions(self) -> list[PositionInfo]:
        positions = self._client.get_all_positions()
        if isinstance(positions, dict):
            raise TypeError(f"unexpected raw dict response from Alpaca: {positions!r}")
        return [_position_info_from_alpaca(p) for p in positions]

    def get_open_orders(self) -> list[OrderInfo]:
        orders = self._client.get_orders(filter=GetOrdersRequest(status=QueryOrderStatus.OPEN))
        if isinstance(orders, dict):
            raise TypeError(f"unexpected raw dict response from Alpaca: {orders!r}")
        return [_order_info_from_alpaca(o) for o in orders]

    def get_clock(self) -> BrokerClock:
        clock = self._client.get_clock()
        if isinstance(clock, dict):
            raise TypeError(f"unexpected raw dict response from Alpaca: {clock!r}")
        return BrokerClock(timestamp=clock.timestamp, is_open=clock.is_open)

    def submit_bracket_order(self, request: BracketOrderRequest) -> OrderInfo:
        # Alpaca's own validation requires OrderClass.BRACKET to carry *both* legs; a
        # stop-only exit (our strategies have no profit target, see docs/PLAN.md) uses
        # OrderClass.OTO instead — one-triggers-other with just the stop-loss leg. Either
        # way, RISK-010 holds: a stop-loss is always present.
        take_profit_price = request.take_profit_price
        order_data = MarketOrderRequest(
            symbol=request.symbol,
            qty=request.qty,
            side=_SIDE_TO_ALPACA[request.side],
            time_in_force=TimeInForce.DAY,
            order_class=OrderClass.BRACKET if take_profit_price is not None else OrderClass.OTO,
            client_order_id=request.client_order_id,
            stop_loss=StopLossRequest(stop_price=request.stop_loss_price),
            take_profit=(
                TakeProfitRequest(limit_price=take_profit_price)
                if take_profit_price is not None
                else None
            ),
        )
        order = self._client.submit_order(order_data)
        if isinstance(order, dict):
            raise TypeError(f"unexpected raw dict response from Alpaca: {order!r}")
        return _order_info_from_alpaca(order)

    def cancel_order(self, broker_order_id: str) -> None:
        self._client.cancel_order_by_id(broker_order_id)

    def cancel_all_orders(self) -> None:
        self._client.cancel_orders()

    def close_position(self, symbol: str) -> OrderInfo | None:
        response = self._client.close_position(symbol)
        if response is None or isinstance(response, dict):
            return None
        return _order_info_from_alpaca(response)

    def close_all_positions(self) -> None:
        self._client.close_all_positions(cancel_orders=True)
