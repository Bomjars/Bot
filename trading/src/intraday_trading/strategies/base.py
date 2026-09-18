"""The Strategy interface: the same class runs unmodified in backtest, paper, and live
(BT-001). A strategy only ever sees market data through `StrategyContext`, which is
built incrementally by whichever engine is driving it (backtester today; the paper/live
event loop in step 8) — it is never handed a pre-loaded DataFrame spanning the future, so
look-ahead through the sanctioned data path is structurally impossible, not just
runtime-checked (see BT-002/BT-005 and CLAUDE.md's data-access rule for strategy code).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

from intraday_trading.risk.signals import EntrySignal


@dataclass(frozen=True)
class Bar:
    ts: datetime
    open: float
    high: float
    low: float
    close: float
    volume: float


@dataclass(frozen=True)
class StrategyContext:
    """Handed to a strategy on every bar event. `current_time` is the only notion of
    "now" a strategy may reason from; `history_by_symbol` holds only bars whose
    timestamp is <= `current_time`, for every symbol, because the engine only ever
    appends to it as sim time advances — it cannot contain a bar from the future because
    that bar simply hasn't been appended yet at the point a strategy is called.
    """

    current_time: datetime
    history_by_symbol: dict[str, list[Bar]]

    def bars_for(self, symbol: str) -> list[Bar]:
        return self.history_by_symbol.get(symbol, [])


class Strategy(Protocol):
    name: str

    def on_bar(self, symbol: str, bar: Bar, context: StrategyContext) -> list[EntrySignal]:
        """Called once per bar per symbol, in chronological order (ties broken by symbol
        name for determinism, BT-006). Returns zero or more proposed entries; each still
        passes through RiskManager, which may reject any of them."""
        ...
