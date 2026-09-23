"""storage/db.py's additive column migration: a database created before a column was
added to an existing table must gain that column in place, keeping its rows -- nothing
dropped or rewritten."""

from __future__ import annotations

import sqlite3
from pathlib import Path

from intraday_trading.storage.db import init_db


def _create_pre_fx_fills_table(db_path: Path) -> None:
    """The `fills` table exactly as it first shipped, before currency/fx_cost."""
    conn = sqlite3.connect(db_path)
    conn.execute(
        """
        CREATE TABLE fills (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            client_order_id TEXT NOT NULL,
            broker_order_id TEXT NOT NULL,
            symbol TEXT NOT NULL,
            side TEXT NOT NULL,
            qty REAL NOT NULL,
            expected_price REAL NOT NULL,
            actual_price REAL NOT NULL,
            slippage REAL NOT NULL,
            commission REAL NOT NULL,
            commission_currency TEXT NOT NULL
        )
        """
    )
    conn.execute(
        "INSERT INTO fills (ts, client_order_id, broker_order_id, symbol, side, qty, "
        "expected_price, actual_price, slippage, commission, commission_currency) "
        "VALUES ('2024-01-02T15:00:00+00:00', 'itd-1', '1', 'SPY', 'buy', 10, 500, 500.5, "
        "0.5, 1.0, 'USD')"
    )
    conn.commit()
    conn.close()


def _columns(db_path: Path, table: str) -> set[str]:
    conn = sqlite3.connect(db_path)
    try:
        return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
    finally:
        conn.close()


def test_init_db_adds_missing_columns_to_an_existing_table(tmp_path: Path) -> None:
    db_path = tmp_path / "old.db"
    _create_pre_fx_fills_table(db_path)

    init_db(db_path)

    assert {"currency", "fx_cost"} <= _columns(db_path, "fills")
    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute("SELECT symbol, currency, fx_cost FROM fills").fetchall()
    finally:
        conn.close()
    assert rows == [("SPY", "USD", 0.0)]  # existing row kept, new columns defaulted


def test_init_db_is_idempotent(tmp_path: Path) -> None:
    db_path = tmp_path / "fresh.db"
    init_db(db_path)
    init_db(db_path)  # must not try to re-add columns that already exist

    assert {"currency", "fx_cost"} <= _columns(db_path, "fills")
    assert "fx_conversions" in {
        row[0]
        for row in sqlite3.connect(db_path).execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )
    }
