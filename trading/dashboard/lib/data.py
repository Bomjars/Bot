"""Read-only SQLite access for the dashboard. Every function here only SELECTs -- the
dashboard's only write paths are kill switch / pause / flatten, in actions.py, all
routed through RiskManager (CLAUDE.md: the dashboard never places, modifies, or cancels
an order directly).
"""

from __future__ import annotations

from pathlib import Path

from intraday_trading.storage.db import get_connection, init_db
from intraday_trading.storage.order_log import OrderLog
from intraday_trading.storage.position_record_store import PositionRecord, PositionRecordStore
from intraday_trading.storage.risk_state_store import RiskState, RiskStateStore
from intraday_trading.validation.registry import TrialRecord, TrialRegistry


def load_risk_state(db_path: Path) -> RiskState:
    return RiskStateStore(db_path).load()


def load_recent_orders(db_path: Path, limit: int = 200) -> list[dict[str, object]]:
    return OrderLog(db_path).recent(limit)


def load_recent_rejections(db_path: Path, limit: int = 50) -> list[dict[str, object]]:
    init_db(db_path)
    conn = get_connection(db_path)
    try:
        rows = conn.execute(
            "SELECT * FROM rejections ORDER BY ts DESC LIMIT ?", (limit,)
        ).fetchall()
    finally:
        conn.close()
    return [dict(row) for row in rows]


def load_open_position_records(db_path: Path) -> list[PositionRecord]:
    return PositionRecordStore(db_path).all()


def known_strategies(db_path: Path) -> list[str]:
    init_db(db_path)
    conn = get_connection(db_path)
    try:
        rows = conn.execute("SELECT DISTINCT strategy FROM trials ORDER BY strategy").fetchall()
    finally:
        conn.close()
    return [str(row["strategy"]) for row in rows]


def load_trials(db_path: Path, strategy: str) -> list[TrialRecord]:
    return TrialRegistry(db_path).get_trials(strategy, include_retired=True)


def trial_count(db_path: Path, strategy: str) -> int:
    return TrialRegistry(db_path).trial_count(strategy)


def count_paper_days(db_path: Path) -> int:
    """Distinct calendar dates (from order timestamps) with at least one order logged."""
    init_db(db_path)
    conn = get_connection(db_path)
    try:
        row = conn.execute("SELECT COUNT(DISTINCT substr(ts, 1, 10)) AS n FROM orders").fetchone()
        return int(row["n"])
    finally:
        conn.close()
