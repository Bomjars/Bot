"""Types passed into RiskManager and out of it. Kept separate from risk_manager.py so
strategies (steps 6-7) can import just the signal shape without importing RiskManager
itself.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

from intraday_trading.broker.base import Side


@dataclass(frozen=True)
class EntrySignal:
    """A strategy's proposed entry, before RiskManager has validated anything about it.
    `qty` is whatever the strategy's own sizer proposed (see sizing/position_sizer.py) —
    RiskManager checks it, it does not trust it."""

    strategy: str
    symbol: str
    side: Side
    qty: int
    entry_price: float
    stop_price: float
    take_profit_price: float | None
    current_price: float
    avg_dollar_volume: float
    spread_pct: float
    signal_seq: str
    """A per-signal-instance identifier (e.g. strategy+symbol+date+bar index) used to
    build a deterministic client_order_id (EXEC-002) — the same signal retried after a
    crash must produce the same id."""
    signal_strength: float | None = None
    """A strategy-defined, normalized measure of this entry's conviction (e.g. how far
    price broke out relative to the band width) -- None when a strategy doesn't compute
    one. Purely descriptive: RiskManager never checks or sizes on it. Persisted alongside
    the order so validation/signal_confidence.py can later bucket closed trades by it and
    report a backtested win-rate for a given strength range -- never a live guarantee."""


@dataclass(frozen=True)
class ExitSignal:
    """A strategy's request to close an existing open position -- e.g. a decision-time
    stop-out or the first leg of a reversal (STRAT-002). Deliberately has no size/stop
    fields: closing exposure only ever reduces risk, so unlike `EntrySignal` it is never
    rejected for a risk reason, only a no-op if there is nothing open on `symbol`."""

    strategy: str
    symbol: str
    reason: str
    signal_seq: str


class HaltType(StrEnum):
    NONE = "none"
    DAILY_LOSS = "daily_loss"
    WEEKLY_LOSS = "weekly_loss"
    DRAWDOWN = "drawdown"
    KILL_SWITCH = "kill_switch"
    RECONCILIATION_MISMATCH = "reconciliation_mismatch"
    CLOCK_DRIFT = "clock_drift"
    MANUAL_PAUSE = "manual_pause"


@dataclass(frozen=True)
class RiskDecision:
    accepted: bool
    reason: str | None = None
    broker_order_id: str | None = None
