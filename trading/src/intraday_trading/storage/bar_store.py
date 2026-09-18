"""SQLite-backed bar store.

The one hard invariant here is DATA-002: `get_bars` must never return a bar timestamped
after `as_of`, when `as_of` is given. Every caller doing "what did we know at decision
time T" (the universe scanner, a strategy's opening-range read) must pass `as_of=T`
rather than relying on `end` alone — `end` is just the query window, `as_of` is the
look-ahead guard.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime
from pathlib import Path

import pandas as pd

from intraday_trading.data.client import BAR_COLUMNS
from intraday_trading.storage.db import get_connection, init_db


def _as_utc(ts: pd.Timestamp) -> pd.Timestamp:
    return ts.tz_localize("UTC") if ts.tzinfo is None else ts.tz_convert("UTC")


class BarStore:
    def __init__(self, database_path: Path) -> None:
        self._database_path = database_path
        init_db(database_path)

    def _connect(self) -> sqlite3.Connection:
        return get_connection(self._database_path)

    def upsert_bars(self, bars: pd.DataFrame) -> int:
        if bars.empty:
            return 0
        missing = set(BAR_COLUMNS) - set(bars.columns)
        if missing:
            raise ValueError(f"bars frame missing columns: {sorted(missing)}")

        records = bars[BAR_COLUMNS].to_dict("records")
        rows = [
            (
                str(record["symbol"]),
                _as_utc(pd.Timestamp(record["ts"])).isoformat(),
                str(record["feed"]),
                float(record["open"]),
                float(record["high"]),
                float(record["low"]),
                float(record["close"]),
                float(record["volume"]),
            )
            for record in records
        ]
        conn = self._connect()
        try:
            conn.executemany(
                """
                INSERT INTO bars (symbol, ts, feed, open, high, low, close, volume)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (symbol, ts, feed) DO UPDATE SET
                    open=excluded.open, high=excluded.high, low=excluded.low,
                    close=excluded.close, volume=excluded.volume
                """,
                rows,
            )
            conn.commit()
            return len(rows)
        finally:
            conn.close()

    def get_bars(
        self,
        symbol: str,
        start: datetime,
        end: datetime,
        feed: str,
        as_of: datetime | None = None,
    ) -> pd.DataFrame:
        effective_end = min(end, as_of) if as_of is not None else end
        conn = self._connect()
        try:
            rows = conn.execute(
                """
                SELECT symbol, ts, open, high, low, close, volume, feed
                FROM bars
                WHERE symbol = ? AND feed = ? AND ts >= ? AND ts < ?
                ORDER BY ts ASC
                """,
                (
                    symbol,
                    feed,
                    _as_utc(pd.Timestamp(start)).isoformat(),
                    _as_utc(pd.Timestamp(effective_end)).isoformat(),
                ),
            ).fetchall()
        finally:
            conn.close()

        df = pd.DataFrame(rows, columns=BAR_COLUMNS)
        if not df.empty:
            df["ts"] = pd.to_datetime(df["ts"], utc=True)
        return df
