"""Kill switch: the same underlying trip goes through CLI, file-flag, and dashboard
entry points (KILL-006) — none of them talk to the broker directly, all of them call
`RiskManager.trip_kill_switch`, which is the only thing that cancels-then-flattens.
"""

from __future__ import annotations

from pathlib import Path

from intraday_trading.risk.risk_manager import RiskManager

CONFIRMATION_PHRASE = "KILL EVERYTHING"


def trip(risk_manager: RiskManager, reason: str = "manual kill switch") -> None:
    risk_manager.trip_kill_switch(reason)


def is_kill_file_present(kill_switch_file: Path) -> bool:
    return kill_switch_file.exists()


def confirm_dashboard_kill(typed_text: str, risk_manager: RiskManager) -> bool:
    """KILL-003: the dashboard button is a no-op unless the typed text matches exactly."""
    if typed_text != CONFIRMATION_PHRASE:
        return False
    trip(risk_manager, reason="dashboard kill switch")
    return True
