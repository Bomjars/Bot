"""`status`, the `golive` subcommands, `backtest spy`, and `seed-demo-data` are exercised
here -- `run-paper` and `kill` construct a real broker and immediately reconcile against
the network (see execution/wiring.py and CLAUDE.md), so they're deliberately never
invoked in a test beyond their `--broker` argument validation, which happens before any
broker is constructed. `backtest spy` also touches the network (real historical bars),
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
from intraday_trading.broker.ibkr_broker import IBKRBroker
from intraday_trading.cli import app
from intraday_trading.data.client import AlpacaMarketDataClient
from intraday_trading.storage.go_live_checklist_store import GoLiveChecklistStore
from intraday_trading.storage.risk_state_store import RiskStateStore
from intraday_trading.strategies.spy_momentum import SpyMomentumConfig
from intraday_trading.validation.registry import TrialRegistry

runner = CliRunner()


def test_status_reports_live_trading_false_by_default(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")

    result = runner.invoke(app, ["status"])

    assert result.exit_code == 0
    assert "live_trading: False" in result.stdout


def test_run_paper_rejects_an_unknown_broker(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")

    result = runner.invoke(app, ["run-paper", "--broker", "bogus"])

    assert result.exit_code == 1
    assert "broker" in result.stdout


def test_kill_rejects_an_unknown_broker(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")

    result = runner.invoke(app, ["kill", "--broker", "bogus"])

    assert result.exit_code == 1
    assert "broker" in result.stdout


@dataclass
class _FakeReportIB:
    equity: float = 101_000.0
    closes: list[tuple[object, float]] | None = None

    def accountSummary(self):  # type: ignore[no-untyped-def]
        from ib_async import AccountValue

        return [
            AccountValue(
                account="U1",
                tag="NetLiquidation",
                value=str(self.equity),
                currency="USD",
                modelCode="",
            ),
            AccountValue(
                account="U1",
                tag="SettledCash",
                value=str(self.equity),
                currency="USD",
                modelCode="",
            ),
            AccountValue(
                account="U1",
                tag="BuyingPower",
                value=str(self.equity),
                currency="USD",
                modelCode="",
            ),
        ]

    def qualifyContracts(self, *contracts):  # type: ignore[no-untyped-def]
        return list(contracts)

    def reqHistoricalData(self, contract, **kwargs):  # type: ignore[no-untyped-def]
        from datetime import date

        from ib_async import BarData

        if self.closes is not None:
            return [BarData(date=d, close=c) for d, c in self.closes]
        return [
            BarData(date=date(2024, 1, 1), close=500.0),
            BarData(date=date(2024, 1, 2), close=505.0),
        ]


def test_report_daily_requires_a_started_session(monkeypatch, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(tmp_path / "report.db"))

    result = runner.invoke(app, ["report", "daily"])

    assert result.exit_code == 1
    assert "run `run-paper` first" in result.stdout


def test_report_daily_prints_the_comparison(monkeypatch, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    db_path = tmp_path / "report.db"
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(db_path))
    from intraday_trading.risk.signals import HaltType
    from intraday_trading.storage.risk_state_store import RiskState

    store = RiskStateStore(db_path)
    state = RiskState(daily_starting_equity=100_000.0, halt_type=HaltType.NONE)
    store.save(state)

    fake_broker = IBKRBroker(ib=_FakeReportIB(equity=101_000.0))
    monkeypatch.setattr(IBKRBroker, "paper", classmethod(lambda cls, settings: fake_broker))

    result = runner.invoke(app, ["report", "daily", "--symbol", "SPY"])

    assert result.exit_code == 0, result.stdout
    assert "Bot:" in result.stdout
    assert "SPY" in result.stdout


def test_report_daily_fails_with_insufficient_historical_data(monkeypatch, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    db_path = tmp_path / "report.db"
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(db_path))
    from intraday_trading.storage.risk_state_store import RiskState

    RiskStateStore(db_path).save(RiskState(daily_starting_equity=100_000.0))

    fake_broker = IBKRBroker(ib=_FakeReportIB(closes=[]))
    monkeypatch.setattr(IBKRBroker, "paper", classmethod(lambda cls, settings: fake_broker))

    result = runner.invoke(app, ["report", "daily"])

    assert result.exit_code == 1
    assert "Not enough historical data" in result.stdout


def test_report_daily_notify_sends_a_telegram_summary(monkeypatch, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    db_path = tmp_path / "report.db"
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(db_path))
    from intraday_trading.storage.risk_state_store import RiskState

    RiskStateStore(db_path).save(RiskState(daily_starting_equity=100_000.0))

    fake_broker = IBKRBroker(ib=_FakeReportIB())
    monkeypatch.setattr(IBKRBroker, "paper", classmethod(lambda cls, settings: fake_broker))
    sent = []
    monkeypatch.setattr(cli.TelegramAlerter, "daily_summary", lambda self, text: sent.append(text))

    result = runner.invoke(app, ["report", "daily", "--notify"])

    assert result.exit_code == 0, result.stdout
    assert len(sent) == 1


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

    assert "[3/3] vm=1.0 lookback=20d" in result.stdout  # per-config progress

    registry = TrialRegistry(db_path)
    assert len(registry.get_trials("spy_momentum")) == 3
    assert len(registry.get_trials("spy_momentum_paper_faithful")) == 1


def test_BT_008_backtest_spy_leaves_real_risk_state_and_log_config_alone(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The paper bot's real risk state must survive a backtest byte-for-byte (the grid
    used to share -- and overwrite -- the real risk_state row: its trading day, baselines
    and peak equity), no backtest rejection may land in the real rejections table, and
    quieting info logs must not outlive the command."""
    import sqlite3
    from datetime import date

    import structlog

    from intraday_trading.storage.risk_state_store import RiskState, RiskStateStore

    db_path = tmp_path / "backtest.db"
    real_state = RiskState(
        trading_day=date(2026, 9, 22),
        daily_starting_equity=10_000.0,
        week_start=date(2026, 9, 21),
        weekly_starting_equity=10_000.0,
        peak_equity=10_000.0,
        trades_today=2,
    )
    RiskStateStore(db_path).save(real_state)
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(db_path))
    monkeypatch.setattr(
        AlpacaMarketDataClient,
        "from_settings",
        classmethod(lambda cls, settings: cls(_FakeHistoricalDataClient(_one_day_spy_bars()))),
    )
    monkeypatch.setattr(cli, "house_risk_grid", lambda: [SpyMomentumConfig(lookback_days=10)])
    log_config_before = structlog.get_config()

    result = runner.invoke(app, ["backtest", "spy", "--start", "2024-01-02", "--end", "2024-01-03"])

    assert result.exit_code == 0, result.stdout
    assert RiskStateStore(db_path).load() == real_state
    conn = sqlite3.connect(db_path)
    try:
        assert conn.execute("SELECT COUNT(*) FROM rejections").fetchone()[0] == 0
    finally:
        conn.close()
    assert structlog.get_config() == log_config_before


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


def _summary_env(monkeypatch: pytest.MonkeyPatch, db_path: Path) -> None:
    monkeypatch.setenv("ALPACA_API_KEY", "fake")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "fake")
    monkeypatch.setenv("DATABASE_PATH", str(db_path))
    monkeypatch.setenv("ALPACA_DATA_FEED", "iex")


def _log_summary_trials(registry: TrialRegistry, strategy: str, n_trials: int) -> None:
    import numpy as np

    rng = np.random.default_rng(3)
    days = pd.bdate_range("2024-01-02", periods=64).date
    for i in range(n_trials):
        pnl = pd.Series(rng.normal(10.0 * i, 20.0, len(days)), index=days)
        registry.log_trial(
            strategy,
            {"vm": 1.0 + i / 10, "lookback_days": 14, "stop_variant": "curr_band_vwap"},
            pnl,
        )


def test_BT_009_backtest_summary_prints_plain_english_numbers(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from intraday_trading.storage.bar_store import BarStore

    db_path = tmp_path / "summary.db"
    _summary_env(monkeypatch, db_path)
    registry = TrialRegistry(db_path)
    _log_summary_trials(registry, "spy_momentum", n_trials=3)
    _log_summary_trials(registry, "spy_momentum_paper_faithful", n_trials=1)
    days = pd.bdate_range("2024-01-02", periods=64)
    BarStore(db_path).upsert_bars(
        pd.DataFrame(
            {
                "symbol": "SPY",
                "ts": [
                    pd.Timestamp(d).tz_localize("America/New_York") + pd.Timedelta(hours=10)
                    for d in days
                ],
                "open": 470.0,
                "high": 471.0,
                "low": 469.0,
                "close": [470.0 + i for i in range(len(days))],
                "volume": 1_000.0,
                "feed": "iex",
            }
        )
    )

    result = runner.invoke(app, ["backtest", "summary"])

    assert result.exit_code == 0, result.stdout
    out = result.stdout
    assert "spy_momentum: 3 configs, 2024-01-02 to" in out
    assert "Overfitting check (CSCV/PBO)" in out
    assert "profitable after costs:" in out
    assert "Best config (trial" in out
    assert "vm=1.2" in out  # strongest drift
    assert "Buy and hold SPY, same dates" in out
    assert "no stored SPY bars" not in out
    assert "Paper's own settings" in out
    assert "the paper reported: 19.6% per year" in out
    assert "WARNING" not in out


def test_backtest_summary_warns_on_mixed_runs_and_missing_bars(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    db_path = tmp_path / "summary.db"
    _summary_env(monkeypatch, db_path)
    registry = TrialRegistry(db_path)
    _log_summary_trials(registry, "spy_momentum", n_trials=2)
    registry.log_trial(
        "spy_momentum",
        {"vm": 3.0},
        pd.Series([1.0] * 5, index=pd.bdate_range("2024-06-03", periods=5).date),
    )

    result = runner.invoke(app, ["backtest", "summary"])

    assert result.exit_code == 0, result.stdout
    assert "WARNING: these trials cover 2 different date ranges" in result.stdout
    assert "no stored SPY bars for these dates" in result.stdout
    assert "Paper's own settings" not in result.stdout


def test_backtest_summary_too_little_data_for_cscv(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    db_path = tmp_path / "summary.db"
    _summary_env(monkeypatch, db_path)
    TrialRegistry(db_path).log_trial(
        "spy_momentum",
        {"vm": 1.0},
        pd.Series([1.0, -1.0, 2.0], index=pd.bdate_range("2024-01-02", periods=3).date),
    )

    result = runner.invoke(app, ["backtest", "summary"])

    assert result.exit_code == 0, result.stdout
    assert "not enough data to run it" in result.stdout
    assert "DSR" not in result.stdout


def test_backtest_summary_exits_1_without_trials(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _summary_env(monkeypatch, tmp_path / "summary.db")

    result = runner.invoke(app, ["backtest", "summary", "--strategy", "nope"])

    assert result.exit_code == 1
    assert "No trials logged for 'nope'" in result.stdout


def test_VAL_015_backtest_retire_retires_without_deleting(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    db_path = tmp_path / "retire.db"
    _summary_env(monkeypatch, db_path)
    registry = TrialRegistry(db_path)
    _log_summary_trials(registry, "spy_momentum", n_trials=3)

    result = runner.invoke(
        app, ["backtest", "retire", "--strategy", "spy_momentum", "--reason", "sizing bug"]
    )

    assert result.exit_code == 0, result.stdout
    assert "Retired 3 trial(s) of 'spy_momentum'" in result.stdout
    assert registry.trial_count("spy_momentum") == 3
    assert registry.get_trials("spy_momentum", include_retired=False) == []
    summary = runner.invoke(app, ["backtest", "summary"])
    assert summary.exit_code == 1  # nothing active left to summarise


def test_backtest_retire_requires_a_reason(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _summary_env(monkeypatch, tmp_path / "retire.db")
    result = runner.invoke(app, ["backtest", "retire", "--strategy", "spy_momentum"])
    assert result.exit_code != 0
