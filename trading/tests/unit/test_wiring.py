"""Constructing the real components from Settings must never touch the network --
alpaca-py's client constructors just store credentials, they don't connect until a
method is called. This lets us test the wiring itself (right types, right object graph)
without any real Alpaca keys.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from intraday_trading.broker.alpaca_broker import AlpacaBroker
from intraday_trading.broker.ibkr_broker import IBKRBroker
from intraday_trading.config import Settings
from intraday_trading.execution.event_loop import PaperTradingLoop
from intraday_trading.execution.wiring import build_paper_trading_components
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.state.reconciler import Reconciler
from intraday_trading.strategies.spy_momentum import SpyMomentumStrategy


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


def test_no_live_notional_cap_when_not_live(tmp_path: Path) -> None:
    settings = Settings(
        alpaca_api_key="fake-key",
        alpaca_secret_key="fake-secret",
        database_path=tmp_path / "wiring.db",
        kill_switch_file=tmp_path / "KILL_SWITCH",
        live_trading=False,
    )

    components = build_paper_trading_components(settings, symbols=[])

    assert components.risk_manager.live_notional_cap_usd is None


def test_GOLIVE_006_live_notional_cap_set_when_live_trading_confirmed(tmp_path: Path) -> None:
    settings = Settings(
        alpaca_api_key="fake-key",
        alpaca_secret_key="fake-secret",
        database_path=tmp_path / "wiring.db",
        kill_switch_file=tmp_path / "KILL_SWITCH",
        live_trading=True,
        live_trading_confirmation="I UNDERSTAND THE RISK",
        live_equity_cap_gbp=3_000.0,
        approx_gbp_usd_rate=1.25,
    )

    components = build_paper_trading_components(settings, symbols=[])

    assert components.risk_manager.live_notional_cap_usd == 3_750.0
    # Still the paper broker -- there is no .live() constructor in this codebase yet.
    assert isinstance(components.broker, AlpacaBroker)


def test_spy_strategy_attached_when_spy_is_requested(tmp_path: Path) -> None:
    settings = Settings(
        alpaca_api_key="fake-key",
        alpaca_secret_key="fake-secret",
        database_path=tmp_path / "wiring.db",
        kill_switch_file=tmp_path / "KILL_SWITCH",
    )

    components = build_paper_trading_components(settings, symbols=["AAPL", "spy"])

    strategies = components.loop._strategies  # type: ignore[attr-defined]
    assert len(strategies) == 1
    assert isinstance(strategies[0], SpyMomentumStrategy)
    assert strategies[0].symbol == "SPY"


def test_spy_strategy_not_attached_when_spy_not_requested(tmp_path: Path) -> None:
    settings = Settings(
        alpaca_api_key="fake-key",
        alpaca_secret_key="fake-secret",
        database_path=tmp_path / "wiring.db",
        kill_switch_file=tmp_path / "KILL_SWITCH",
    )

    components = build_paper_trading_components(settings, symbols=["AAPL"])

    assert components.loop._strategies == []  # type: ignore[attr-defined]


def test_alpaca_provider_has_no_connection_guard_or_fill_poller(tmp_path: Path) -> None:
    settings = Settings(
        alpaca_api_key="fake-key",
        alpaca_secret_key="fake-secret",
        database_path=tmp_path / "wiring.db",
        kill_switch_file=tmp_path / "KILL_SWITCH",
    )

    components = build_paper_trading_components(settings, symbols=[], broker_provider="alpaca")

    assert components.loop._connection_guard is None  # type: ignore[attr-defined]
    assert components.loop._fill_poller is None  # type: ignore[attr-defined]


def test_ibkr_provider_wires_an_ibkr_broker_without_network(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # IB.connect() dials a real socket immediately (unlike alpaca-py's TradingClient,
    # which only stores credentials) -- .paper() is monkeypatched so this test never
    # attempts one, mirroring how test_cli.py fakes AlpacaMarketDataClient.from_settings.
    fake_broker = IBKRBroker(ib=object())  # type: ignore[arg-type]
    monkeypatch.setattr(IBKRBroker, "paper", classmethod(lambda cls, settings: fake_broker))
    settings = Settings(
        alpaca_api_key="fake-key",
        alpaca_secret_key="fake-secret",
        database_path=tmp_path / "wiring.db",
        kill_switch_file=tmp_path / "KILL_SWITCH",
    )

    components = build_paper_trading_components(settings, symbols=[], broker_provider="ibkr")

    assert components.broker is fake_broker
    assert components.loop._connection_guard is not None  # type: ignore[attr-defined]
    assert components.loop._fill_poller is not None  # type: ignore[attr-defined]


def test_ibkr_connection_guard_reconnects_when_disconnected(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from dataclasses import dataclass, field

    @dataclass
    class _FakeIB:
        connected: bool = False
        connect_calls: list[tuple[str, int, int]] = field(default_factory=list)

        def isConnected(self) -> bool:
            return self.connected

        def connect(self, host: str, port: int, clientId: int = 1) -> None:
            self.connect_calls.append((host, port, clientId))
            self.connected = True

        def fills(self) -> list[object]:
            return []

    fake_ib = _FakeIB()
    fake_broker = IBKRBroker(ib=fake_ib)  # type: ignore[arg-type]
    monkeypatch.setattr(IBKRBroker, "paper", classmethod(lambda cls, settings: fake_broker))
    settings = Settings(
        alpaca_api_key="fake-key",
        alpaca_secret_key="fake-secret",
        database_path=tmp_path / "wiring.db",
        kill_switch_file=tmp_path / "KILL_SWITCH",
    )

    components = build_paper_trading_components(settings, symbols=[], broker_provider="ibkr")
    components.loop._connection_guard()  # type: ignore[misc]

    assert fake_ib.connected is True
    assert len(fake_ib.connect_calls) == 1


def test_ibkr_connection_guard_is_a_no_op_when_already_connected(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from dataclasses import dataclass, field

    @dataclass
    class _FakeIB:
        connected: bool = True
        connect_calls: list[tuple[str, int, int]] = field(default_factory=list)

        def isConnected(self) -> bool:
            return self.connected

        def connect(self, host: str, port: int, clientId: int = 1) -> None:
            self.connect_calls.append((host, port, clientId))

        def fills(self) -> list[object]:
            return []

    fake_ib = _FakeIB()
    fake_broker = IBKRBroker(ib=fake_ib)  # type: ignore[arg-type]
    monkeypatch.setattr(IBKRBroker, "paper", classmethod(lambda cls, settings: fake_broker))
    settings = Settings(
        alpaca_api_key="fake-key",
        alpaca_secret_key="fake-secret",
        database_path=tmp_path / "wiring.db",
        kill_switch_file=tmp_path / "KILL_SWITCH",
    )

    components = build_paper_trading_components(settings, symbols=[], broker_provider="ibkr")
    components.loop._connection_guard()  # type: ignore[misc]

    assert fake_ib.connect_calls == []  # already connected -- never redialed


def test_ibkr_fill_poller_drains_fills_via_record_fill(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from dataclasses import dataclass, field
    from datetime import UTC, datetime

    from ib_async import CommissionReport, Execution, Fill, Stock

    @dataclass
    class _FakeIB:
        connected: bool = True
        fill_events: list[Fill] = field(default_factory=list)

        def isConnected(self) -> bool:
            return self.connected

        def fills(self) -> list[Fill]:
            return list(self.fill_events)

    execution = Execution(
        execId="exec-1",
        orderId=1,
        orderRef="itd-unmatched",  # no matching order -- record_fill just returns False
        side="BOT",
        shares=10.0,
        price=100.0,
        time=datetime(2024, 1, 2, 15, 0, tzinfo=UTC),
    )
    commission = CommissionReport(execId="exec-1", commission=1.0, currency="USD")
    fake_ib = _FakeIB(fill_events=[Fill(Stock("AAPL"), execution, commission, execution.time)])
    fake_broker = IBKRBroker(ib=fake_ib)  # type: ignore[arg-type]
    monkeypatch.setattr(IBKRBroker, "paper", classmethod(lambda cls, settings: fake_broker))
    settings = Settings(
        alpaca_api_key="fake-key",
        alpaca_secret_key="fake-secret",
        database_path=tmp_path / "wiring.db",
        kill_switch_file=tmp_path / "KILL_SWITCH",
    )

    components = build_paper_trading_components(settings, symbols=[], broker_provider="ibkr")

    components.loop._fill_poller()  # type: ignore[misc]  # must not raise


def test_EXEC_014_ibkr_fill_poller_logs_a_currency_conversion(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from dataclasses import dataclass, field
    from datetime import UTC, datetime

    from ib_async import CommissionReport, Execution, Fill, Forex

    from intraday_trading.storage.fx_conversion_log import FxConversionLog

    @dataclass
    class _FakeIB:
        fill_events: list[Fill] = field(default_factory=list)

        def fills(self) -> list[Fill]:
            return list(self.fill_events)

    ts = datetime(2024, 1, 2, 15, 0, tzinfo=UTC)
    execution = Execution(execId="fx-1", orderId=9, side="SLD", shares=1_000.0, price=1.27)
    commission = CommissionReport(execId="fx-1", commission=2.0, currency="USD")
    fake_ib = _FakeIB(fill_events=[Fill(Forex("GBPUSD"), execution, commission, ts)])
    fake_broker = IBKRBroker(ib=fake_ib)  # type: ignore[arg-type]
    monkeypatch.setattr(IBKRBroker, "paper", classmethod(lambda cls, settings: fake_broker))
    db_path = tmp_path / "wiring.db"
    settings = Settings(
        alpaca_api_key="fake-key",
        alpaca_secret_key="fake-secret",
        database_path=db_path,
        kill_switch_file=tmp_path / "KILL_SWITCH",
    )

    components = build_paper_trading_components(settings, symbols=[], broker_provider="ibkr")
    components.loop._fill_poller()  # type: ignore[misc]

    rows = FxConversionLog(db_path).recent()
    assert len(rows) == 1
    assert rows[0]["pair"] == "GBP.USD"
    assert rows[0]["commission"] == 2.0


def test_unknown_broker_provider_raises(tmp_path: Path) -> None:
    settings = Settings(
        alpaca_api_key="fake-key",
        alpaca_secret_key="fake-secret",
        database_path=tmp_path / "wiring.db",
        kill_switch_file=tmp_path / "KILL_SWITCH",
    )

    with pytest.raises(ValueError, match="broker_provider"):
        build_paper_trading_components(settings, symbols=[], broker_provider="bogus")
