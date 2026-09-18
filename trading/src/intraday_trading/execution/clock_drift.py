"""EXEC-010: trading on a clock skewed from the broker's own risks misjudging the
session windows RiskManager enforces (RISK-012/013/014), even if the risk logic itself
is otherwise correct. Checked once per loop iteration in `event_loop.py`.
"""

from __future__ import annotations

from datetime import datetime


def clock_drift_seconds(local_now: datetime, broker_now: datetime) -> float:
    return (local_now - broker_now).total_seconds()


def exceeds_threshold(local_now: datetime, broker_now: datetime, threshold_seconds: float) -> bool:
    return abs(clock_drift_seconds(local_now, broker_now)) > threshold_seconds
