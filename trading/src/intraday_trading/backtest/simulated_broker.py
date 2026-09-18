"""A `Broker` implementation backed entirely by simulated fills, so the exact same
`RiskManager` that gates live/paper orders also gates backtested ones (BT-007). Resting
orders (stops, cancels) aren't modeled as separate broker-side objects here — a bracket
order fills immediately at the current bar's price (adjusted by the cost model), and its
stop/take-profit levels are tracked as attributes of the open position, checked against
each subsequent bar's high/low in `process_bar`. This is a deliberate simplification:
partial fills and order-book queueing are not part of this model.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime

from intraday_trading.backtest.costs import CostModel
from intraday_trading.broker.base import (
    AccountInfo,
    BracketOrderRequest,
    BrokerClock,
    OrderInfo,
    PositionInfo,
    Side,
)
from intraday_trading.strategies.base import Bar


def _opposite(side: Side) -> Side:
    return Side.SELL if side == Side.BUY else Side.BUY


def _signed(side: Side) -> float:
    return 1.0 if side == Side.BUY else -1.0


@dataclass
class _OpenPosition:
    symbol: str
    side: Side
    qty: float
    entry_price: float
    stop_price: float
    take_profit_price: float | None
    entry_time: datetime


@dataclass(frozen=True)
class TradeRecord:
    symbol: str
    side: Side
    qty: float
    entry_price: float
    exit_price: float
    entry_time: datetime
    exit_time: datetime
    exit_reason: str
    realized_pnl: float
    total_commission: float


@dataclass
class SimulatedBroker:
    starting_equity: float
    cost_model: CostModel = field(default_factory=CostModel)
    current_time: datetime | None = None
    cash: float = field(init=False)
    positions: dict[str, _OpenPosition] = field(default_factory=dict, init=False)
    current_prices: dict[str, float] = field(default_factory=dict, init=False)
    closed_trades: list[TradeRecord] = field(default_factory=list, init=False)
    _order_seq: int = field(default=0, init=False)

    def __post_init__(self) -> None:
        self.cash = self.starting_equity

    def _unrealized_pnl(self, pos: _OpenPosition) -> float:
        price = self.current_prices.get(pos.symbol, pos.entry_price)
        return (price - pos.entry_price) * pos.qty * _signed(pos.side)

    def get_account(self) -> AccountInfo:
        equity = self.cash + sum(self._unrealized_pnl(p) for p in self.positions.values())
        return AccountInfo(equity=equity, cash=self.cash, buying_power=equity, currency="USD")

    def get_positions(self) -> list[PositionInfo]:
        return [
            PositionInfo(
                symbol=p.symbol,
                qty=p.qty,
                side=p.side,
                avg_entry_price=p.entry_price,
                current_price=self.current_prices.get(p.symbol, p.entry_price),
                unrealized_pl=self._unrealized_pnl(p),
            )
            for p in self.positions.values()
        ]

    def get_open_orders(self) -> list[OrderInfo]:
        return []

    def get_clock(self) -> BrokerClock:
        assert self.current_time is not None, "process_bar must run before get_clock"
        return BrokerClock(timestamp=self.current_time, is_open=True)

    def submit_bracket_order(self, request: BracketOrderRequest) -> OrderInfo:
        quoted = self.current_prices.get(request.symbol, request.stop_loss_price)
        fill_price = self.cost_model.fill_price(request.side, quoted)
        commission = self.cost_model.commission(request.qty)
        self.cash -= commission

        assert self.current_time is not None
        self.positions[request.symbol] = _OpenPosition(
            symbol=request.symbol,
            side=request.side,
            qty=request.qty,
            entry_price=fill_price,
            stop_price=request.stop_loss_price,
            take_profit_price=request.take_profit_price,
            entry_time=self.current_time,
        )
        self._order_seq += 1
        return OrderInfo(
            broker_order_id=f"sim-{self._order_seq}",
            client_order_id=request.client_order_id,
            symbol=request.symbol,
            side=request.side,
            qty=request.qty,
            status="filled",
            filled_qty=request.qty,
            filled_avg_price=fill_price,
        )

    def cancel_order(self, broker_order_id: str) -> None:
        pass  # no resting orders are modeled; everything fills immediately

    def cancel_all_orders(self) -> None:
        pass

    def close_position(self, symbol: str) -> OrderInfo | None:
        return self._close_at_price(symbol, self.current_prices.get(symbol), "manual_close")

    def close_all_positions(self) -> None:
        for symbol in list(self.positions):
            self._close_at_price(symbol, self.current_prices.get(symbol), "flatten")

    def process_bar(self, symbol: str, bar: Bar) -> None:
        """Called once per bar, before the strategy sees it: checks whether this bar's
        high/low would have triggered the position's resting stop or target, closing it
        at that trigger price if so, then marks the position to this bar's close."""
        self.current_time = bar.ts
        position = self.positions.get(symbol)
        if position is not None:
            hit_stop = (
                bar.low <= position.stop_price
                if position.side == Side.BUY
                else bar.high >= position.stop_price
            )
            hit_target = position.take_profit_price is not None and (
                bar.high >= position.take_profit_price
                if position.side == Side.BUY
                else bar.low <= position.take_profit_price
            )
            if hit_stop:
                # Conservative convention: if both trigger in the same bar, the stop
                # (the worse outcome) is assumed to have fired first.
                self._close_at_price(symbol, position.stop_price, "stop_loss")
            elif hit_target:
                self._close_at_price(symbol, position.take_profit_price, "take_profit")

        self.current_prices[symbol] = bar.close

    def _close_at_price(self, symbol: str, price: float | None, reason: str) -> OrderInfo | None:
        position = self.positions.pop(symbol, None)
        if position is None or price is None:
            return None

        exit_price = self.cost_model.fill_price(_opposite(position.side), price)
        commission = self.cost_model.commission(position.qty)
        realized_pnl = (exit_price - position.entry_price) * position.qty * _signed(position.side)
        self.cash += realized_pnl - commission

        assert self.current_time is not None
        self.closed_trades.append(
            TradeRecord(
                symbol=symbol,
                side=position.side,
                qty=position.qty,
                entry_price=position.entry_price,
                exit_price=exit_price,
                entry_time=position.entry_time,
                exit_time=self.current_time,
                exit_reason=reason,
                realized_pnl=realized_pnl,
                total_commission=commission,
            )
        )
        self._order_seq += 1
        return OrderInfo(
            broker_order_id=f"sim-{self._order_seq}",
            client_order_id=f"close-{symbol}",
            symbol=symbol,
            side=_opposite(position.side),
            qty=position.qty,
            status="filled",
            filled_qty=position.qty,
            filled_avg_price=exit_price,
        )
