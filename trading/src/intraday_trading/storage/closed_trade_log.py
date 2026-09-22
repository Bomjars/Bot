"""Persists closed trades from a backtest run, signal_strength included, so
validation/signal_confidence.py's bucketed win-rate can be computed from data that
outlives the Python process that produced it (the dashboard reads this table; it never
re-runs a backtest itself). Only ever written by `backtest spy`'s CLI command or
dev/demo_data.py's synthetic set -- see schema.sql's comment on why paper/live trading
can't populate this table yet.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from intraday_trading.backtest.simulated_broker import TradeRecord
from intraday_trading.storage.db import get_connection, init_db


@dataclass(frozen=True)
class PersistedClosedTrade:
    """A `closed_trades` row. Deliberately structurally compatible with validation/
    signal_confidence.py's `ClosedTrade` Protocol (`.signal_strength`/`.realized_pnl`)
    so `ClosedTradeLog.load()`'s result can be passed straight into
    `build_confidence_table` with no adapter."""

    strategy: str
    symbol: str
    side: str
    qty: float
    entry_price: float
    exit_price: float
    entry_time: str
    exit_time: str
    exit_reason: str
    realized_pnl: float
    total_commission: float
    signal_strength: float | None


class ClosedTradeLog:
    def __init__(self, database_path: Path) -> None:
        self._database_path = database_path
        init_db(database_path)

    def log_many(self, strategy: str, trades: Sequence[TradeRecord]) -> None:
        conn = get_connection(self._database_path)
        try:
            conn.executemany(
                """
                INSERT INTO closed_trades (
                    strategy, symbol, side, qty, entry_price, exit_price, entry_time,
                    exit_time, exit_reason, realized_pnl, total_commission, signal_strength
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        strategy,
                        trade.symbol,
                        trade.side.value,
                        trade.qty,
                        trade.entry_price,
                        trade.exit_price,
                        trade.entry_time.isoformat(),
                        trade.exit_time.isoformat(),
                        trade.exit_reason,
                        trade.realized_pnl,
                        trade.total_commission,
                        trade.signal_strength,
                    )
                    for trade in trades
                ],
            )
            conn.commit()
        finally:
            conn.close()

    def count(self, strategy: str) -> int:
        conn = get_connection(self._database_path)
        try:
            row = conn.execute(
                "SELECT COUNT(*) AS n FROM closed_trades WHERE strategy = ?", (strategy,)
            ).fetchone()
            return int(row["n"])
        finally:
            conn.close()

    def load(self, strategy: str) -> list[PersistedClosedTrade]:
        conn = get_connection(self._database_path)
        try:
            rows = conn.execute(
                "SELECT * FROM closed_trades WHERE strategy = ? ORDER BY exit_time", (strategy,)
            ).fetchall()
        finally:
            conn.close()
        return [
            PersistedClosedTrade(
                strategy=row["strategy"],
                symbol=row["symbol"],
                side=row["side"],
                qty=row["qty"],
                entry_price=row["entry_price"],
                exit_price=row["exit_price"],
                entry_time=row["entry_time"],
                exit_time=row["exit_time"],
                exit_reason=row["exit_reason"],
                realized_pnl=row["realized_pnl"],
                total_commission=row["total_commission"],
                signal_strength=row["signal_strength"],
            )
            for row in rows
        ]
