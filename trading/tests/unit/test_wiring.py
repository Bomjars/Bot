"""Constructing the real components from Settings must never touch the network --
alpaca-py's client constructors just store credentials, they don't connect until a
method is called. This lets us test the wiring itself (right types, right object graph)
without any real Alpaca keys.
"""

from __future__ import annotations

from pathlib import Path

from intraday_trading.broker.alpaca_broker import AlpacaBroker
from intraday_trading.config import Settings
from intraday_trading.execution.event_loop import PaperTradingLoop
from intraday_trading.execution.wiring import build_paper_trading_components
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.state.reconciler import Reconciler


def test_build_paper_trading_components_wires_everything_without_network(tmp_path: Path) -> None:
    settings = Settings(
        alpaca_api_key="fake-key",
        alpaca_secret_key="fake-secret",
        database_path=tmp_path / "wiring.db",
        kill_switch_file=tmp_path / "KILL_SWITCH",
    )

    components = build_paper_trading_components(settings, symbols=["AAPL", "SPY"])

    assert isinstance(components.broker, AlpacaBroker)
    assert isinstance(components.risk_manager, RiskManager)
    assert isinstance(components.reconciler, Reconciler)
    assert isinstance(components.loop, PaperTradingLoop)


def test_build_with_no_symbols(tmp_path: Path) -> None:
    settings = Settings(
        alpaca_api_key="fake-key",
        alpaca_secret_key="fake-secret",
        database_path=tmp_path / "wiring.db",
        kill_switch_file=tmp_path / "KILL_SWITCH",
    )

    components = build_paper_trading_components(settings, symbols=[])

    assert isinstance(components.loop, PaperTradingLoop)
