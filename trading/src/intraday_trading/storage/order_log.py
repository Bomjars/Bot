"""Mirrors RejectionLog: every ACCEPTED entry, for the dashboard's activity feed and
journal (step 9, Page 4). Exits/fills still live only at the broker for now.
"""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

from intraday_trading.broker.base import OrderInfo
from intraday_trading.risk.signals import EntrySignal
from intraday_trading.storage.db import get_connection, init_db


class OrderLog:
    def __init__(self, database_path: Path) -> None:
        self._database_path = database_path
        init_db(database_path)

    def log(self, signal: EntrySignal, order: OrderInfo, ts: datetime | None = None) -> None:
        """`ts` defaults to now -- only ever overridden by dev/demo_data.py, to spread
        synthetic orders across distinct historical dates rather than collapsing them
        all onto "today"."""
        conn = get_connection(self._database_path)
        try:
            conn.execute(
                """
                INSERT INTO orders (
                    ts, strategy, symbol, side, qty, entry_price, stop_price,
                    take_profit_price, client_order_id, broker_order_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    (ts or datetime.now(tz=UTC)).isoformat(),
                    signal.strategy,
                    signal.symbol,
                    signal.side.value,
                    signal.qty,
                    signal.entry_price,
                    signal.stop_price,
                    signal.take_profit_price,
                    order.client_order_id,
                    order.broker_order_id,
                ),
            )
            conn.commit()
        finally:
            conn.close()

    def recent(self, limit: int = 100) -> list[dict[str, object]]:
        conn = get_connection(self._database_path)
        try:
            rows = conn.execute(
                "SELECT * FROM orders ORDER BY ts DESC LIMIT ?", (limit,)
            ).fetchall()
        finally:
            conn.close()
        return [dict(row) for row in rows]

    def find_by_client_order_id(self, client_order_id: str) -> dict[str, object] | None:
        """Looks up the order this `client_order_id` was already logged under, if any --
        used both for duplicate-order prevention (RiskManager checks this before
        resubmitting a signal) and to recover a fill's *expected* price when a broker's
        fill event (e.g. IBKR's async execDetails) arrives later than submission."""
        conn = get_connection(self._database_path)
        try:
            row = conn.execute(
                "SELECT * FROM orders WHERE client_order_id = ? ORDER BY ts DESC LIMIT 1",
                (client_order_id,),
            ).fetchone()
        finally:
            conn.close()
        return dict(row) if row is not None else None

    def count(self) -> int:
        conn = get_connection(self._database_path)
        try:
            row = conn.execute("SELECT COUNT(*) AS n FROM orders").fetchone()
            return int(row["n"])
        finally:
            conn.close()

    def count_distinct_days(self) -> int:
        """Distinct calendar dates with at least one order logged -- the go-live gate's
        "paper-trading days" count (GOLIVE-001)."""
        conn = get_connection(self._database_path)
        try:
            row = conn.execute(
                "SELECT COUNT(DISTINCT substr(ts, 1, 10)) AS n FROM orders"
            ).fetchone()
            return int(row["n"])
        finally:
            conn.close()
