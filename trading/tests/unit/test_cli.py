"""Only the `status` command is exercised here -- `run-paper` and `kill` construct a
real AlpacaBroker and immediately reconcile against the network (see execution/wiring.py
and CLAUDE.md), so they're deliberately never invoked in a test.
"""

from __future__ import annotations

from typer.testing import CliRunner

from intraday_trading.cli import app

runner = CliRunner()


def test_status_reports_live_trading_false_by_default(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")

    result = runner.invoke(app, ["status"])

    assert result.exit_code == 0
    assert "live_trading: False" in result.stdout
