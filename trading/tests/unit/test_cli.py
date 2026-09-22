"""`status`, the `golive` subcommands, `backtest spy`, and `seed-demo-data` are exercised
here -- `run-paper` and `kill` construct a real AlpacaBroker and immediately reconcile
against the network (see execution/wiring.py and CLAUDE.md), so they're deliberately
never invoked in a test. `backtest spy` also touches the network (real historical bars),
but only through `AlpacaMarketDataClient`, whose *underlying* vendor client is easy to
fake (same pattern as test_data_client.py) while still exercising this file's own
fetch/store/run/log logic for real.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import pandas as pd
import pytest
from typer.testing import CliRunner

from intraday_trading import cli
from intraday_trading.cli import app
from intraday_trading.data.client import AlpacaMarketDataClient
from intraday_trading.storage.go_live_checklist_store import GoLiveChecklistStore
from intraday_trading.strategies.spy_momentum import SpyMomentumConfig
from intraday_trading.validation.registry import TrialRegistry

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


@dataclass
class _FakeBarSet:
    df: pd.DataFrame


class _FakeHistoricalDataClient:
    def __init__(self, df: pd.DataFrame) -> None:
        self._df = df

    def get_stock_bars(self, request_params):  # type: ignore[no-untyped-def]
        return _FakeBarSet(df=self._df)


def _one_day_spy_bars() -> pd.DataFrame:
    index = pd.MultiIndex.from_tuples(
        [
            ("SPY", pd.Timestamp("2024-01-02 09:30", tz="UTC")),
            ("SPY", pd.Timestamp("2024-01-02 10:00", tz="UTC")),
        ],
        names=["symbol", "timestamp"],
    )
    return pd.DataFrame(
        {
            "open": [470.0, 470.5],
            "high": [470.5, 471.0],
            "low": [469.5, 470.0],
            "close": [470.2, 470.8],
            "volume": [1_000_000, 900_000],
        },
        index=index,
    )


def test_backtest_spy_fetches_runs_the_grid_and_logs_trials(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The grid-running/logging pipeline end-to-end, against a real `AlpacaMarketDataClient`
    with only its underlying network client swapped out -- one day of bars, deliberately
    too little history for any config to ever trade, so this stays fast while still
    proving the fetch -> store -> run grid -> log -> paper_faithful reference -> log
    sequence is wired correctly. The real 192-config grid's *size* is proven separately
    and cheaply in test_spy_grid.py; here the grid is patched down to 3 configs purely to
    keep this end-to-end test fast (192 real backtests would take well over a minute)."""
    db_path = tmp_path / "backtest.db"
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(db_path))
    monkeypatch.setattr(
        AlpacaMarketDataClient,
        "from_settings",
        classmethod(lambda cls, settings: cls(_FakeHistoricalDataClient(_one_day_spy_bars()))),
    )
    tiny_grid = [
        SpyMomentumConfig(lookback_days=10, mode="house_risk"),
        SpyMomentumConfig(lookback_days=14, mode="house_risk"),
        SpyMomentumConfig(lookback_days=20, mode="house_risk"),
    ]
    monkeypatch.setattr(cli, "house_risk_grid", lambda: tiny_grid)

    result = runner.invoke(app, ["backtest", "spy", "--start", "2024-01-02", "--end", "2024-01-03"])

    assert result.exit_code == 0, result.stdout
    assert "Logged 3 trials under strategy=spy_momentum" in result.stdout
    assert "Logged 1 paper_faithful reference trial" in result.stdout

    registry = TrialRegistry(db_path)
    assert len(registry.get_trials("spy_momentum")) == 3
    assert len(registry.get_trials("spy_momentum_paper_faithful")) == 1


def test_seed_demo_data_writes_to_the_given_path(monkeypatch, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    real_db = tmp_path / "real.db"
    demo_db = tmp_path / "demo.db"
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(real_db))

    result = runner.invoke(app, ["seed-demo-data", "--database-path", str(demo_db)])

    assert result.exit_code == 0, result.stdout
    assert demo_db.exists()
    assert not real_db.exists()  # never touched the real database
    assert TrialRegistry(demo_db).get_trials("spy_momentum")


def test_seed_demo_data_refuses_to_target_the_real_database(monkeypatch, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    real_db = tmp_path / "real.db"
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(real_db))

    result = runner.invoke(app, ["seed-demo-data", "--database-path", str(real_db)])

    assert result.exit_code == 1
    assert "Refusing" in result.stdout
    assert not real_db.exists()


def test_seed_demo_data_refuses_to_overwrite_without_force(monkeypatch, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    real_db = tmp_path / "real.db"
    demo_db = tmp_path / "demo.db"
    demo_db.write_text("not a real database, just proving it wasn't touched")
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(real_db))

    result = runner.invoke(app, ["seed-demo-data", "--database-path", str(demo_db)])

    assert result.exit_code == 1
    assert "already exists" in result.stdout
    assert demo_db.read_text() == "not a real database, just proving it wasn't touched"

    result = runner.invoke(app, ["seed-demo-data", "--database-path", str(demo_db), "--force"])

    assert result.exit_code == 0, result.stdout
    assert TrialRegistry(demo_db).get_trials("spy_momentum")
