"""A human operator's record of having deliberately exercised the kill switch and a
restart/reconciliation in paper, once each. Nothing here is set automatically -- the
whole point of GOLIVE-004 is a human vouching that they actually did the drill, not the
system inferring it from other activity.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from intraday_trading.storage.db import get_connection, init_db


@dataclass(frozen=True)
class GoLiveChecklistState:
    kill_switch_tested_at: str | None = None
    reconciliation_tested_at: str | None = None


class GoLiveChecklistStore:
    def __init__(self, database_path: Path) -> None:
        self._database_path = database_path
        init_db(database_path)

    def load(self) -> GoLiveChecklistState:
        conn = get_connection(self._database_path)
        try:
            row = conn.execute("SELECT * FROM go_live_checklist WHERE id = 1").fetchone()
        finally:
            conn.close()
        if row is None:
            return GoLiveChecklistState()
        return GoLiveChecklistState(
            kill_switch_tested_at=row["kill_switch_tested_at"],
            reconciliation_tested_at=row["reconciliation_tested_at"],
        )

    def mark_kill_switch_tested(self) -> None:
        self._mark("kill_switch_tested_at")

    def mark_reconciliation_tested(self) -> None:
        self._mark("reconciliation_tested_at")

    def _mark(self, column: str) -> None:
        assert column in ("kill_switch_tested_at", "reconciliation_tested_at")
        now = datetime.now(tz=UTC).isoformat()
        conn = get_connection(self._database_path)
        try:
            # `column` is always one of the two literal names hardcoded above, never
            # caller input, so this f-string is safe despite not being parameterized.
            conn.execute(
                f"""
                INSERT INTO go_live_checklist (id, {column}) VALUES (1, ?)
                ON CONFLICT (id) DO UPDATE SET {column} = excluded.{column}
                """,
                (now,),
            )
            conn.commit()
        finally:
            conn.close()
