"""SQLite connection + schema helper shared by every store (bars today; orders, fills,
positions, rejections, trials, validation_results as later steps add them to schema.sql).
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

_SCHEMA_PATH = Path(__file__).resolve().parent / "schema.sql"

# Columns added to an existing table after it first shipped. `CREATE TABLE IF NOT EXISTS`
# never alters a table that already exists, so a database created before a column was
# added needs it added explicitly -- additive only, matching schema.sql's own rule that
# nothing is ever dropped or altered destructively.
_ADDED_COLUMNS: dict[str, dict[str, str]] = {
    "fills": {
        "currency": "TEXT NOT NULL DEFAULT 'USD'",
        "fx_cost": "REAL NOT NULL DEFAULT 0.0",
    },
}


def get_connection(database_path: Path) -> sqlite3.Connection:
    database_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(database_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db(database_path: Path) -> None:
    conn = get_connection(database_path)
    try:
        # Explicit encoding: Path.read_text() defaults to the platform's locale
        # encoding, which is cp1252 on Windows -- wrong for a UTF-8 repo.
        conn.executescript(_SCHEMA_PATH.read_text(encoding="utf-8"))
        for table, columns in _ADDED_COLUMNS.items():
            existing = {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}
            for column, ddl in columns.items():
                if column not in existing:
                    conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}")
        conn.commit()
    finally:
        conn.close()
