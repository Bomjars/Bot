from __future__ import annotations

from datetime import UTC, datetime, timedelta

from intraday_trading.execution.clock_drift import clock_drift_seconds, exceeds_threshold

T0 = datetime(2024, 1, 2, 12, 0, tzinfo=UTC)


def test_drift_seconds_positive_when_local_ahead() -> None:
    assert clock_drift_seconds(T0 + timedelta(seconds=10), T0) == 10.0


def test_drift_seconds_negative_when_local_behind() -> None:
    assert clock_drift_seconds(T0 - timedelta(seconds=10), T0) == -10.0


def test_EXEC_010_within_threshold_does_not_exceed() -> None:
    assert exceeds_threshold(T0 + timedelta(seconds=3), T0, threshold_seconds=5) is False


def test_EXEC_010_beyond_threshold_exceeds_in_either_direction() -> None:
    assert exceeds_threshold(T0 + timedelta(seconds=10), T0, threshold_seconds=5) is True
    assert exceeds_threshold(T0 - timedelta(seconds=10), T0, threshold_seconds=5) is True


def test_exactly_at_threshold_does_not_exceed() -> None:
    assert exceeds_threshold(T0 + timedelta(seconds=5), T0, threshold_seconds=5) is False
