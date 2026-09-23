"""Persists RiskManager's halted state and daily/weekly counters across restarts
(RISK-008/009: a weekly-loss or drawdown halt must still be halted after a crash, not
silently cleared). Full broker-position reconciliation on restart is step 8 — this store
only covers RiskManager's own bookkeeping, not position state.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import date
from pathlib import Path

from intraday_trading.risk.signals import HaltType
from intraday_trading.storage.db import get_connection, init_db


@dataclass
class RiskState:
    trading_day: date | None = None
    daily_starting_equity: float | None = None
    week_start: date | None = None
    weekly_starting_equity: float | None = None
    peak_equity: float | None = None
    trades_today: int = 0
    halted: bool = False
    halt_type: HaltType = HaltType.NONE
    halt_reason: str | None = None


class RiskStateStore:
    def __init__(self, database_path: Path) -> None:
        self._database_path = database_path
        init_db(database_path)

    def load(self) -> RiskState:
        conn = get_connection(self._database_path)
        try:
            row = conn.execute("SELECT * FROM risk_state WHERE id = 1").fetchone()
        finally:
            conn.close()
        if row is None:
            return RiskState()
        return RiskState(
            trading_day=date.fromisoformat(row["trading_day"]) if row["trading_day"] else None,
            daily_starting_equity=row["daily_starting_equity"],
            week_start=date.fromisoformat(row["week_start"]) if row["week_start"] else None,
            weekly_starting_equity=row["weekly_starting_equity"],
            peak_equity=row["peak_equity"],
            trades_today=row["trades_today"],
            halted=bool(row["halted"]),
            halt_type=HaltType(row["halt_type"]) if row["halt_type"] else HaltType.NONE,
            halt_reason=row["halt_reason"],
        )

    def save(self, state: RiskState) -> None:
        conn = get_connection(self._database_path)
        try:
            conn.execute(
                """
                INSERT INTO risk_state (
                    id, trading_day, daily_starting_equity, week_start,
                    weekly_starting_equity, peak_equity, trades_today, halted,
                    halt_type, halt_reason
                ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET
                    trading_day=excluded.trading_day,
                    daily_starting_equity=excluded.daily_starting_equity,
                    week_start=excluded.week_start,
                    weekly_starting_equity=excluded.weekly_starting_equity,
                    peak_equity=excluded.peak_equity,
                    trades_today=excluded.trades_today,
                    halted=excluded.halted,
                    halt_type=excluded.halt_type,
                    halt_reason=excluded.halt_reason
                """,
                (
                    state.trading_day.isoformat() if state.trading_day else None,
                    state.daily_starting_equity,
                    state.week_start.isoformat() if state.week_start else None,
                    state.weekly_starting_equity,
                    state.peak_equity,
                    state.trades_today,
                    int(state.halted),
                    state.halt_type.value,
                    state.halt_reason,
                ),
            )
            conn.commit()
        finally:
            conn.close()


class InMemoryRiskStateStore(RiskStateStore):
    """Same interface, no database: for backtests, where each run must start from a
    fresh RiskState of its own. Sharing the real store's single `risk_state` row let one
    grid config's peak equity or DRAWDOWN halt leak into every later config, and let a
    backtest overwrite (or clear) the paper bot's real halt state."""

    def __init__(self) -> None:
        self._state = RiskState()

    def load(self) -> RiskState:
        return replace(self._state)

    def save(self, state: RiskState) -> None:
        self._state = replace(state)
