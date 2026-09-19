"""`status` and the `golive` subcommands are exercised here -- `run-paper` and `kill`
construct a real AlpacaBroker and immediately reconcile against the network (see
execution/wiring.py and CLAUDE.md), so they're deliberately never invoked in a test.
"""

from __future__ import annotations

from pathlib import Path

from typer.testing import CliRunner

from intraday_trading.cli import app
from intraday_trading.storage.go_live_checklist_store import GoLiveChecklistStore

runner = CliRunner()


def test_status_reports_live_trading_false_by_default(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")

    result = runner.invoke(app, ["status"])

    assert result.exit_code == 0
    assert "live_trading: False" in result.stdout


def test_golive_status_reports_not_passed_on_fresh_database(monkeypatch, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(tmp_path / "cli.db"))

    result = runner.invoke(app, ["golive", "status"])

    assert result.exit_code == 0
    assert "GO-LIVE GATE: NOT PASSED" in result.stdout
    assert "[FAIL] Kill switch tested" in result.stdout


def test_golive_mark_kill_switch_tested_persists(monkeypatch, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    db_path = tmp_path / "cli.db"
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(db_path))

    result = runner.invoke(app, ["golive", "mark-kill-switch-tested"])

    assert result.exit_code == 0
    assert GoLiveChecklistStore(db_path).load().kill_switch_tested_at is not None


def test_golive_mark_reconciliation_tested_persists(monkeypatch, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    db_path = tmp_path / "cli.db"
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(db_path))

    result = runner.invoke(app, ["golive", "mark-reconciliation-tested"])

    assert result.exit_code == 0
    assert GoLiveChecklistStore(db_path).load().reconciliation_tested_at is not None


def test_golive_status_can_pass_the_easy_checks(monkeypatch, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    db_path = tmp_path / "cli.db"
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(db_path))
    GoLiveChecklistStore(db_path).mark_kill_switch_tested()
    GoLiveChecklistStore(db_path).mark_reconciliation_tested()

    result = runner.invoke(app, ["golive", "status"])

    assert result.exit_code == 0
    assert "[PASS] Kill switch tested" in result.stdout
    assert "[PASS] Reconciliation tested" in result.stdout
    assert "GO-LIVE GATE: NOT PASSED" in result.stdout  # other checks still unmet
