"""RISK-022: every rejection is persisted with the triggering signal and the exact reason,
before the caller ever sees the rejection — so "why didn't it trade that?" is always
answerable from the database, not from memory or logs alone.
"""

from __future__ import annotations

import json
from dataclasses import asdict
from datetime import UTC, datetime
from pathlib import Path

from intraday_trading.risk.signals import EntrySignal
from intraday_trading.storage.db import get_connection, init_db


class RejectionLog:
    def __init__(self, database_path: Path) -> None:
        self._database_path = database_path
        init_db(database_path)

    def log(self, signal: EntrySignal, reason: str) -> None:
        conn = get_connection(self._database_path)
        try:
            conn.execute(
                """
                INSERT INTO rejections (ts, strategy, symbol, reason, signal_json)
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    datetime.now(tz=UTC).isoformat(),
                    signal.strategy,
                    signal.symbol,
                    reason,
                    json.dumps(asdict(signal), default=str),
                ),
            )
            conn.commit()
        finally:
            conn.close()

    def count(self) -> int:
        conn = get_connection(self._database_path)
        try:
            row = conn.execute("SELECT COUNT(*) AS n FROM rejections").fetchone()
            return int(row["n"])
        finally:
            conn.close()


class InMemoryRejectionLog(RejectionLog):
    """Same interface, no database: for backtests, whose historical rejections must
    never land in the real `rejections` table the dashboard's Live Monitor reads (they'd
    carry today's wall-clock timestamp and look like live rejections)."""

    def __init__(self) -> None:
        self.reasons: list[str] = []

    def log(self, signal: EntrySignal, reason: str) -> None:
        self.reasons.append(reason)

    def count(self) -> int:
        return len(self.reasons)
