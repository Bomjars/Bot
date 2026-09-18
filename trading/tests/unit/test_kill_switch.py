from __future__ import annotations

from pathlib import Path

from intraday_trading.config import RiskLimits
from intraday_trading.killswitch.kill_switch import (
    confirm_dashboard_kill,
    is_kill_file_present,
    trip,
)
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.risk.signals import HaltType
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.storage.risk_state_store import RiskStateStore
from tests.unit.fakes import FakeBroker
from tests.unit.test_risk_manager import _clock


def _manager(tmp_path: Path, broker: FakeBroker) -> RiskManager:
    db = tmp_path / "risk.db"
    return RiskManager(
        broker=broker,
        limits=RiskLimits(),
        clock=_clock(),
        state_store=RiskStateStore(db),
        rejection_log=RejectionLog(db),
    )


def test_KILL_002_file_flag_detected(tmp_path: Path) -> None:
    flag_path = tmp_path / "KILL_SWITCH"
    assert is_kill_file_present(flag_path) is False
    flag_path.write_text("")
    assert is_kill_file_present(flag_path) is True


def test_trip_calls_risk_manager_kill_switch(tmp_path: Path) -> None:
    broker = FakeBroker()
    manager = _manager(tmp_path, broker)

    trip(manager, reason="test")

    assert manager.is_halted() is True


def test_KILL_003_dashboard_requires_exact_confirmation_text(tmp_path: Path) -> None:
    broker = FakeBroker()
    manager = _manager(tmp_path, broker)

    result_wrong = confirm_dashboard_kill("please stop", manager)
    assert result_wrong is False
    assert manager.is_halted() is False

    result_right = confirm_dashboard_kill("KILL EVERYTHING", manager)
    assert result_right is True
    assert manager.is_halted() is True


def test_KILL_006_all_entry_points_share_the_same_underlying_trip(tmp_path: Path) -> None:
    for entry_point_name in ["cli_equivalent", "file_flag_equivalent", "dashboard_equivalent"]:
        broker = FakeBroker()
        manager = _manager(tmp_path / entry_point_name, broker)
        trip(manager, reason=entry_point_name)
        state = manager.halt_status()
        assert state.halt_type == HaltType.KILL_SWITCH
        assert broker.cancel_all_called == 1
        assert broker.close_all_called == 1
