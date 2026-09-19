"""Every unhandled error the event loop caught, persisted so the go-live gate's "no
unhandled errors in the last N days" check (GOLIVE-003) is something we can actually
query, not just something that scrolled past in a log file or a Telegram alert.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path

from intraday_trading.storage.db import get_connection, init_db


class ErrorLog:
    def __init__(self, database_path: Path) -> None:
        self._database_path = database_path
        init_db(database_path)

    def log(self, message: str) -> None:
        conn = get_connection(self._database_path)
        try:
            conn.execute(
                "INSERT INTO errors (ts, message) VALUES (?, ?)",
                (datetime.now(tz=UTC).isoformat(), message),
            )
            conn.commit()
        finally:
            conn.close()

    def count_since(self, cutoff: datetime) -> int:
        conn = get_connection(self._database_path)
        try:
            row = conn.execute(
                "SELECT COUNT(*) AS n FROM errors WHERE ts >= ?", (cutoff.isoformat(),)
            ).fetchone()
            return int(row["n"])
        finally:
            conn.close()

    def count_last_days(self, days: int) -> int:
        return self.count_since(datetime.now(tz=UTC) - timedelta(days=days))
