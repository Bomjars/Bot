"""The backtest-only in-memory stand-ins for RiskStateStore/RejectionLog (BT-008)."""

from __future__ import annotations

from intraday_trading.broker.base import Side
from intraday_trading.risk.signals import EntrySignal, HaltType
from intraday_trading.storage.rejection_log import InMemoryRejectionLog
from intraday_trading.storage.risk_state_store import InMemoryRiskStateStore, RiskState


def test_BT_008_in_memory_risk_state_starts_fresh_and_round_trips() -> None:
    store = InMemoryRiskStateStore()
    assert store.load() == RiskState()

    store.save(RiskState(peak_equity=123.0, halted=True, halt_type=HaltType.DRAWDOWN))

    loaded = store.load()
    assert loaded.peak_equity == 123.0
    assert loaded.halt_type == HaltType.DRAWDOWN
    assert InMemoryRiskStateStore().load() == RiskState()  # separate instances, separate state


def test_in_memory_risk_state_returns_copies() -> None:
    store = InMemoryRiskStateStore()
    state = store.load()
    state.trades_today = 99  # mutating a loaded copy must not change what's stored
    assert store.load().trades_today == 0


def test_BT_008_in_memory_rejection_log_counts_reasons() -> None:
    log = InMemoryRejectionLog()
    assert log.count() == 0
    log.log(_signal(), "halted: test")
    assert log.count() == 1
    assert log.reasons == ["halted: test"]


def _signal() -> EntrySignal:
    return EntrySignal(
        strategy="t",
        symbol="SPY",
        side=Side.BUY,
        qty=1,
        entry_price=100.0,
        stop_price=99.0,
        take_profit_price=None,
        current_price=100.0,
        avg_dollar_volume=1e9,
        spread_pct=0.0,
        signal_seq="1",
    )
