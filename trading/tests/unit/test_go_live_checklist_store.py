from __future__ import annotations

from pathlib import Path

from intraday_trading.storage.go_live_checklist_store import GoLiveChecklistStore


def test_defaults_to_not_tested(tmp_path: Path) -> None:
    store = GoLiveChecklistStore(tmp_path / "golive.db")
    state = store.load()
    assert state.kill_switch_tested_at is None
    assert state.reconciliation_tested_at is None


def test_mark_kill_switch_tested(tmp_path: Path) -> None:
    store = GoLiveChecklistStore(tmp_path / "golive.db")
    store.mark_kill_switch_tested()
    state = store.load()
    assert state.kill_switch_tested_at is not None
    assert state.reconciliation_tested_at is None


def test_mark_reconciliation_tested_independently(tmp_path: Path) -> None:
    store = GoLiveChecklistStore(tmp_path / "golive.db")
    store.mark_kill_switch_tested()
    store.mark_reconciliation_tested()
    state = store.load()
    assert state.kill_switch_tested_at is not None
    assert state.reconciliation_tested_at is not None


def test_marking_twice_updates_timestamp(tmp_path: Path) -> None:
    store = GoLiveChecklistStore(tmp_path / "golive.db")
    store.mark_kill_switch_tested()
    first = store.load().kill_switch_tested_at
    store.mark_kill_switch_tested()
    second = store.load().kill_switch_tested_at
    assert first is not None
    assert second is not None
