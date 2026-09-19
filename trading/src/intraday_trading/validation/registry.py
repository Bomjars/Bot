"""The trial registry: every parameter combination ever backtested, with its full daily
P&L series on a common date index. Nothing is ever deleted -- an abandoned run gets
`retire()`'d, which sets a status column, not a `DELETE`. `DeflatedSharpeRatio` (see
`psr_dsr.py`) needs the *total* number of trials ever attempted, retired ones included,
because a strategy that quietly discarded its failed attempts before computing DSR would
understate how much multiple-testing correction it actually needs.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import pandas as pd

from intraday_trading.storage.db import get_connection, init_db


@dataclass(frozen=True)
class TrialRecord:
    trial_id: int
    strategy: str
    params: dict[str, object]
    search_type: str
    status: str
    retired_reason: str | None
    created_at: str


class TrialRegistry:
    def __init__(self, database_path: Path) -> None:
        self._database_path = database_path
        init_db(database_path)

    def log_trial(
        self,
        strategy: str,
        params: dict[str, object],
        daily_pnl: pd.Series,
        search_type: str = "grid",
    ) -> int:
        """`daily_pnl` must be indexed by date (any type `str()`-convertible to an ISO
        date, e.g. `datetime.date` or a `pd.DatetimeIndex`) -> that day's P&L."""
        if search_type not in ("grid", "optimizer"):
            raise ValueError(f"search_type must be 'grid' or 'optimizer', got {search_type!r}")

        conn = get_connection(self._database_path)
        try:
            cursor = conn.execute(
                """
                INSERT INTO trials (strategy, params_json, search_type, created_at)
                VALUES (?, ?, ?, ?)
                """,
                (
                    strategy,
                    json.dumps(params, sort_keys=True),
                    search_type,
                    datetime.now(tz=UTC).isoformat(),
                ),
            )
            trial_id = int(cursor.lastrowid)  # type: ignore[arg-type]
            conn.executemany(
                "INSERT INTO trial_daily_pnl (trial_id, date, pnl) VALUES (?, ?, ?)",
                [(trial_id, _date_key(idx), float(value)) for idx, value in daily_pnl.items()],
            )
            conn.commit()
            return trial_id
        finally:
            conn.close()

    def retire_trial(self, trial_id: int, reason: str) -> None:
        conn = get_connection(self._database_path)
        try:
            conn.execute(
                "UPDATE trials SET status = 'retired', retired_reason = ? WHERE id = ?",
                (reason, trial_id),
            )
            conn.commit()
        finally:
            conn.close()

    def get_trials(self, strategy: str, include_retired: bool = True) -> list[TrialRecord]:
        conn = get_connection(self._database_path)
        try:
            query = "SELECT * FROM trials WHERE strategy = ?"
            if not include_retired:
                query += " AND status = 'active'"
            rows = conn.execute(query, (strategy,)).fetchall()
        finally:
            conn.close()
        return [
            TrialRecord(
                trial_id=row["id"],
                strategy=row["strategy"],
                params=json.loads(row["params_json"]),
                search_type=row["search_type"],
                status=row["status"],
                retired_reason=row["retired_reason"],
                created_at=row["created_at"],
            )
            for row in rows
        ]

    def trial_count(self, strategy: str, include_retired: bool = True) -> int:
        """The count `DeflatedSharpeRatio` should use -- includes retired trials by
        default, since they were still attempted (see module docstring)."""
        return len(self.get_trials(strategy, include_retired=include_retired))

    def daily_pnl_matrix(self, strategy: str, trial_ids: list[int] | None = None) -> pd.DataFrame:
        """Rows = dates, columns = trial ids, exactly the shape CSCV needs. Trials with
        gaps in their date coverage are left as NaN for those dates -- CSCV callers
        should drop/align as needed rather than have this silently fabricate zeros."""
        trials = self.get_trials(strategy, include_retired=True)
        if trial_ids is not None:
            trials = [t for t in trials if t.trial_id in trial_ids]
        if not trials:
            return pd.DataFrame()

        conn = get_connection(self._database_path)
        try:
            frames = []
            for trial in trials:
                rows = conn.execute(
                    "SELECT date, pnl FROM trial_daily_pnl WHERE trial_id = ? ORDER BY date",
                    (trial.trial_id,),
                ).fetchall()
                series = pd.Series({row["date"]: row["pnl"] for row in rows}, name=trial.trial_id)
                frames.append(series)
        finally:
            conn.close()
        return pd.concat(frames, axis=1)


def _date_key(index_value: object) -> str:
    if isinstance(index_value, datetime):
        return index_value.date().isoformat()
    return str(index_value)
