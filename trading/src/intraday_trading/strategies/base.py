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

from intraday_trading.broker.base import PositionInfo
from intraday_trading.risk.signals import EntrySignal, ExitSignal


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
    equity: float
    """Current account equity (STRAT-001), read through this sanctioned path -- like
    `history_by_symbol`, it's a snapshot the driving engine takes once per bar, never a
    live reference a strategy could poll or hold onto between calls."""
    open_positions: dict[str, PositionInfo]
    """The broker's real open positions, keyed by symbol (STRAT-001) -- a snapshot taken
    the same way as `equity`. Exists so a strategy checks ground truth instead of
    tracking its own belief of what's open, which could silently drift after
    `RiskManager.check_session_flatten()` closes a position with no callback to the
    strategy, or after a proposed signal is rejected."""

    def bars_for(self, symbol: str) -> list[Bar]:
        return self.history_by_symbol.get(symbol, [])


class Strategy(Protocol):
    name: str

    def on_bar(
        self, symbol: str, bar: Bar, context: StrategyContext
    ) -> list[EntrySignal | ExitSignal]:
        """Called once per bar per symbol, in chronological order (ties broken by symbol
        name for determinism, BT-006). Returns zero or more proposed entries/exits, in
        the order they should be applied (STRAT-002: a reversal is an `ExitSignal`
        followed by an `EntrySignal` in the same call) -- each still passes through
        RiskManager, which may reject any of them."""
        ...  # pragma: no cover -- Protocol stub, never executed
