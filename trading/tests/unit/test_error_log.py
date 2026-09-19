from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path

from intraday_trading.storage.error_log import ErrorLog


def test_log_and_count_since(tmp_path: Path) -> None:
    log = ErrorLog(tmp_path / "errors.db")
    log.log("boom")

    assert log.count_since(datetime.now(tz=UTC) - timedelta(minutes=1)) == 1
    assert log.count_since(datetime.now(tz=UTC) + timedelta(minutes=1)) == 0


def test_count_last_days(tmp_path: Path) -> None:
    log = ErrorLog(tmp_path / "errors.db")
    assert log.count_last_days(14) == 0
    log.log("boom")
    assert log.count_last_days(14) == 1
    assert log.count_last_days(0) == 0
