"""RiskManager's own record of what it believes it just opened -- independent of the
broker, so a reconciliation pass has something to recover a stop-loss FROM if the
broker's resting stop order goes missing (EXEC-007). See schema.sql for why this exists
at all; the broker remains the source of truth for whether a position is actually open.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from intraday_trading.storage.db import get_connection, init_db


@dataclass(frozen=True)
class PositionRecord:
    symbol: str
    stop_price: float
    take_profit_price: float | None
    client_order_id: str
    opened_at: str


class PositionRecordStore:
    def __init__(self, database_path: Path) -> None:
        self._database_path = database_path
        init_db(database_path)

    def record_open(
        self,
        symbol: str,
        stop_price: float,
        take_profit_price: float | None,
        client_order_id: str,
        opened_at: datetime,
    ) -> None:
        conn = get_connection(self._database_path)
        try:
            conn.execute(
                """
                INSERT INTO open_position_records
                    (symbol, stop_price, take_profit_price, client_order_id, opened_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (symbol) DO UPDATE SET
                    stop_price=excluded.stop_price,
                    take_profit_price=excluded.take_profit_price,
                    client_order_id=excluded.client_order_id,
                    opened_at=excluded.opened_at
                """,
                (symbol, stop_price, take_profit_price, client_order_id, opened_at.isoformat()),
            )
            conn.commit()
        finally:
            conn.close()

    def get(self, symbol: str) -> PositionRecord | None:
        conn = get_connection(self._database_path)
        try:
            row = conn.execute(
                "SELECT * FROM open_position_records WHERE symbol = ?", (symbol,)
            ).fetchone()
        finally:
            conn.close()
        if row is None:
            return None
        return PositionRecord(
            symbol=row["symbol"],
            stop_price=row["stop_price"],
            take_profit_price=row["take_profit_price"],
            client_order_id=row["client_order_id"],
            opened_at=row["opened_at"],
        )

    def remove(self, symbol: str) -> None:
        conn = get_connection(self._database_path)
        try:
            conn.execute("DELETE FROM open_position_records WHERE symbol = ?", (symbol,))
            conn.commit()
        finally:
            conn.close()

    def all(self) -> list[PositionRecord]:
        conn = get_connection(self._database_path)
        try:
            rows = conn.execute("SELECT * FROM open_position_records").fetchall()
        finally:
            conn.close()
        return [
            PositionRecord(
                symbol=row["symbol"],
                stop_price=row["stop_price"],
                take_profit_price=row["take_profit_price"],
                client_order_id=row["client_order_id"],
                opened_at=row["opened_at"],
            )
            for row in rows
        ]
