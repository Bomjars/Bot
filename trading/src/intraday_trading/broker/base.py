"""Broker interface.

Everything above `risk/` talks to a `Broker`, never to a specific vendor SDK — today
that's `AlpacaBroker` (paper only; see CLAUDE.md), later it could be an IBKR adapter
implementing the same `Protocol` without RiskManager or the execution engine changing at
all. Vendor-specific types (Alpaca's `OrderSide`, `TradeAccount`, ...) never cross this
boundary; everything here is a plain dataclass/enum owned by this codebase.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from typing import Protocol


class Side(StrEnum):
    BUY = "buy"
    SELL = "sell"


@dataclass(frozen=True)
class BracketOrderRequest:
    """An entry order that must always carry a stop-loss (RISK-010: RiskManager rejects
    any entry that doesn't build one of these with a stop set)."""

    client_order_id: str
    symbol: str
    side: Side
    qty: float
    stop_loss_price: float
    take_profit_price: float | None = None
    signal_strength: float | None = None
    """Carried through from the originating `EntrySignal`, purely so a backtest's
    `SimulatedBroker` can attach it to the resulting `TradeRecord` -- not used by any
    broker adapter for order placement itself."""

    def __post_init__(self) -> None:
        if self.qty <= 0:
            raise ValueError("qty must be positive")
        if self.stop_loss_price <= 0:
            raise ValueError("stop_loss_price must be positive")


@dataclass(frozen=True)
class OrderInfo:
    broker_order_id: str
    client_order_id: str
    symbol: str
    side: Side
    qty: float
    status: str
    filled_qty: float = 0.0
    filled_avg_price: float | None = None


@dataclass(frozen=True)
class PositionInfo:
    symbol: str
    qty: float
    side: Side
    avg_entry_price: float
    current_price: float
    unrealized_pl: float


@dataclass(frozen=True)
class AccountInfo:
    equity: float
    cash: float
    buying_power: float
    currency: str


@dataclass(frozen=True)
class BrokerClock:
    timestamp: datetime
    is_open: bool


class Broker(Protocol):
    def get_account(self) -> AccountInfo: ...

    def get_positions(self) -> list[PositionInfo]: ...

    def get_open_orders(self) -> list[OrderInfo]: ...

    def get_clock(self) -> BrokerClock: ...

    def submit_bracket_order(self, request: BracketOrderRequest) -> OrderInfo: ...

    def cancel_order(self, broker_order_id: str) -> None: ...

    def cancel_all_orders(self) -> None: ...

    def close_position(self, symbol: str) -> OrderInfo | None: ...

    def close_all_positions(self) -> None: ...


def make_client_order_id(*parts: str) -> str:
    """Deterministic client order id from a signal's natural key (EXEC-002): the same
    signal always produces the same id, so resubmitting after a crash-and-restart can't
    create a duplicate order — the broker rejects the second submission as a dupe instead.
    Alpaca caps client_order_id at 128 chars; we keep it far shorter and hash it so it's
    also safe for any future broker with a tighter limit.
    """
    key = "|".join(parts)
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()[:32]
    return f"itd-{digest}"
