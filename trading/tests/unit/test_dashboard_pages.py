"""Smoke tests: every dashboard page must render without raising, against a fresh
(mostly empty) database and no real Alpaca connectivity. Broker calls are monkeypatched
to a fake so these tests never touch the network -- the pages' own try/except handling
around live broker calls is exactly what's being exercised here.
"""

from __future__ import annotations

from datetime import UTC, date, datetime
from pathlib import Path

import numpy as np
import pandas as pd
import pytest
from streamlit.testing.v1 import AppTest

from intraday_trading.broker.alpaca_broker import AlpacaBroker
from intraday_trading.broker.base import AccountInfo, OrderInfo, PositionInfo, Side
from intraday_trading.risk.signals import EntrySignal
from intraday_trading.storage.order_log import OrderLog
from intraday_trading.storage.position_record_store import PositionRecordStore
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.validation.registry import TrialRegistry

DASHBOARD_DIR = Path(__file__).resolve().parents[2] / "dashboard"


class _FakeBrokerForDashboard:
    def __init__(self, positions: list[PositionInfo] | None = None) -> None:
        self._positions = positions or []

    def get_account(self) -> AccountInfo:
        return AccountInfo(equity=100_000.0, cash=100_000.0, buying_power=100_000.0, currency="USD")

    def get_positions(self) -> list[PositionInfo]:
        return self._positions

    def get_clock(self):  # pragma: no cover -- not exercised by these pages
        from intraday_trading.broker.base import BrokerClock

        return BrokerClock(timestamp=datetime.now(tz=UTC), is_open=True)

    def cancel_all_orders(self) -> None:
        pass

    def close_all_positions(self) -> None:
        self._positions = []

    def close_position(self, symbol: str):
        self._positions = [p for p in self._positions if p.symbol != symbol]
        return None


def _populate_db(db_path: Path) -> None:
    rng = np.random.default_rng(1)
    n_days, n_configs = 32, 3
    dates = pd.date_range(start=date(2024, 1, 2), periods=n_days, freq="B")
    registry = TrialRegistry(db_path)
    for config_idx in range(n_configs):
        values = rng.normal(0, 1, size=n_days)
        if config_idx == 0:
            values = values + 0.5  # one config with a real edge
        registry.log_trial(
            "orb", {"atr_stop_fraction": 0.05 * (config_idx + 1)}, pd.Series(values, index=dates)
        )

    signal = EntrySignal(
        strategy="orb",
        symbol="AAPL",
        side=Side.BUY,
        qty=10,
        entry_price=100.0,
        stop_price=95.0,
        take_profit_price=None,
        current_price=100.0,
        avg_dollar_volume=10_000_000.0,
        spread_pct=0.001,
        signal_seq="seq-1",
    )
    order = OrderInfo("b1", "c1", "AAPL", Side.BUY, 10, "filled", 10, 100.05)
    OrderLog(db_path).log(signal, order)
    RejectionLog(db_path).log(signal, "price_below_minimum")
    PositionRecordStore(db_path).record_open(
        "AAPL",
        stop_price=95.0,
        take_profit_price=None,
        client_order_id="c1",
        opened_at=datetime.now(tz=UTC),
    )


def _patch_broker(
    monkeypatch: pytest.MonkeyPatch, positions: list[PositionInfo] | None = None
) -> None:
    fake = _FakeBrokerForDashboard(positions)
    monkeypatch.setattr(AlpacaBroker, "paper", classmethod(lambda cls, settings: fake))


@pytest.fixture(autouse=True)
def _no_network(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _patch_broker(monkeypatch)
    monkeypatch.setenv("ALPACA_API_KEY", "test-key")
    monkeypatch.setenv("ALPACA_SECRET_KEY", "test-secret")
    monkeypatch.setenv("DATABASE_PATH", str(tmp_path / "dashboard.db"))
    monkeypatch.setenv("KILL_SWITCH_FILE", str(tmp_path / "KILL_SWITCH"))


@pytest.mark.parametrize(
    "page_name",
    ["live_monitor.py", "validation_report.py", "paper_vs_backtest.py", "journal_go_live.py"],
)
def test_page_renders_without_raising(page_name: str) -> None:
    at = AppTest.from_file(str(DASHBOARD_DIR / "pages" / page_name), default_timeout=30)
    at.run()
    assert not at.exception


def test_live_monitor_shows_running_state_on_a_fresh_database() -> None:
    at = AppTest.from_file(str(DASHBOARD_DIR / "pages" / "live_monitor.py"), default_timeout=30)
    at.run()
    assert not at.exception
    body_text = " ".join(s.value for s in at.success) + " ".join(s.value for s in at.error)
    assert "RUNNING" in body_text or "HALTED" in body_text


def test_validation_report_shows_empty_state_with_no_trials() -> None:
    at = AppTest.from_file(
        str(DASHBOARD_DIR / "pages" / "validation_report.py"), default_timeout=30
    )
    at.run()
    assert not at.exception
    assert any("No strategy has logged any trials yet" in i.value for i in at.info)


def test_validation_report_with_populated_trials(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    db_path = tmp_path / "populated.db"
    _populate_db(db_path)
    monkeypatch.setenv("DATABASE_PATH", str(db_path))

    at = AppTest.from_file(
        str(DASHBOARD_DIR / "pages" / "validation_report.py"), default_timeout=30
    )
    at.run()

    assert not at.exception
    assert any(t.label == "orb" for t in at.tabs)


def test_validation_report_survives_degenerate_is_sharpe_spread(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Real-world crash (found by running `backtest spy` against a short date range,
    which had only logged two configs with identical daily P&L so far): every split's
    selected IS Sharpe was numerically identical, making the IS-vs-OOS scatter's trend
    line a singular least-squares fit -- np.polyfit raised LinAlgError, taking the whole
    page down. Two configs with the exact same series reproduces that zero-variance
    case directly, rather than relying on being unlucky with random data."""
    db_path = tmp_path / "degenerate.db"
    n_days = 32
    dates = pd.date_range(start=date(2024, 1, 2), periods=n_days, freq="B")
    identical_series = pd.Series(np.zeros(n_days), index=dates)
    registry = TrialRegistry(db_path)
    registry.log_trial("spy_momentum", {"vm": 1.0}, identical_series)
    registry.log_trial("spy_momentum", {"vm": 1.1}, identical_series)
    monkeypatch.setenv("DATABASE_PATH", str(db_path))

    at = AppTest.from_file(
        str(DASHBOARD_DIR / "pages" / "validation_report.py"), default_timeout=30
    )
    at.run()

    assert not at.exception
    assert any(t.label == "spy_momentum" for t in at.tabs)


def test_live_monitor_with_open_position(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    db_path = tmp_path / "populated.db"
    _populate_db(db_path)
    monkeypatch.setenv("DATABASE_PATH", str(db_path))
    _patch_broker(
        monkeypatch,
        positions=[PositionInfo("AAPL", 10, Side.BUY, 100.0, 101.0, 10.0)],
    )

    at = AppTest.from_file(str(DASHBOARD_DIR / "pages" / "live_monitor.py"), default_timeout=30)
    at.run()

    assert not at.exception


def test_journal_with_orders_and_trials(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    db_path = tmp_path / "populated.db"
    _populate_db(db_path)
    monkeypatch.setenv("DATABASE_PATH", str(db_path))

    at = AppTest.from_file(str(DASHBOARD_DIR / "pages" / "journal_go_live.py"), default_timeout=30)
    at.run()

    assert not at.exception


def test_GOLIVE_004_mark_tested_buttons_persist(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from intraday_trading.storage.go_live_checklist_store import GoLiveChecklistStore

    db_path = tmp_path / "populated.db"
    _populate_db(db_path)
    monkeypatch.setenv("DATABASE_PATH", str(db_path))

    at = AppTest.from_file(str(DASHBOARD_DIR / "pages" / "journal_go_live.py"), default_timeout=30)
    at.run()
    assert not at.exception

    next(b for b in at.button if "kill switch tested" in b.label).click()
    at.run()
    assert not at.exception
    assert GoLiveChecklistStore(db_path).load().kill_switch_tested_at is not None

    next(b for b in at.button if "reconciliation tested" in b.label).click()
    at.run()
    assert not at.exception
    assert GoLiveChecklistStore(db_path).load().reconciliation_tested_at is not None


def test_paper_vs_backtest_with_orders(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    db_path = tmp_path / "populated.db"
    _populate_db(db_path)
    monkeypatch.setenv("DATABASE_PATH", str(db_path))

    at = AppTest.from_file(
        str(DASHBOARD_DIR / "pages" / "paper_vs_backtest.py"), default_timeout=30
    )
    at.run()

    assert not at.exception


def test_DASH_002_kill_switch_requires_exact_confirmation_text(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from intraday_trading.storage.risk_state_store import RiskStateStore

    db_path = tmp_path / "main.db"
    monkeypatch.setenv("DATABASE_PATH", str(db_path))
    monkeypatch.setenv("KILL_SWITCH_FILE", str(tmp_path / "KILL_SWITCH"))
    _patch_broker(monkeypatch)

    at = AppTest.from_file(str(DASHBOARD_DIR / "main.py"), default_timeout=30)
    at.run()
    assert not at.exception

    at.text_input[0].set_value("wrong phrase")
    kill_button = next(b for b in at.button if "KILL" in b.label)
    kill_button.click()
    at.run()

    assert not at.exception
    assert any("exactly to confirm" in e.value for e in at.error)
    assert RiskStateStore(db_path).load().halted is False

    at.text_input[0].set_value("KILL EVERYTHING")
    kill_button = next(b for b in at.button if "KILL" in b.label)
    kill_button.click()
    at.run()

    assert not at.exception
    assert RiskStateStore(db_path).load().halted is True


def test_DASH_003_password_gate_blocks_until_correct_password(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("DATABASE_PATH", str(tmp_path / "main.db"))
    monkeypatch.setenv("KILL_SWITCH_FILE", str(tmp_path / "KILL_SWITCH"))
    monkeypatch.setenv("DASHBOARD_PASSWORD", "s3cret")

    at = AppTest.from_file(str(DASHBOARD_DIR / "main.py"), default_timeout=30)
    at.run()

    assert not at.exception
    assert any("Sign in" in t.value for t in at.title)
    assert at.sidebar.success == []  # PAPER badge etc. not rendered yet

    at.text_input[0].set_value("wrong")
    at.button[0].click()
    at.run()
    assert any("Wrong password" in e.value for e in at.error)

    at.text_input[0].set_value("s3cret")
    at.button[0].click()
    at.run()

    assert not at.exception
    assert any(s.value == "🟢 PAPER" for s in at.sidebar.success)


def test_no_password_gate_when_unconfigured(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("DATABASE_PATH", str(tmp_path / "main.db"))
    monkeypatch.setenv("KILL_SWITCH_FILE", str(tmp_path / "KILL_SWITCH"))
    monkeypatch.delenv("DASHBOARD_PASSWORD", raising=False)

    at = AppTest.from_file(str(DASHBOARD_DIR / "main.py"), default_timeout=30)
    at.run()

    assert not at.exception
    assert any(s.value == "🟢 PAPER" for s in at.sidebar.success)
