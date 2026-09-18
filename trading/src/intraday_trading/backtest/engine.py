"""Event-driven backtester. BT-001/BT-007: this drives the *exact same* `Strategy` and
`RiskManager` classes used live -- there is no separate "offline" strategy or risk logic
here, only a `SimulatedBroker` standing in for Alpaca and a `TimeBox` standing in for the
wall clock.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime

from intraday_trading.backtest.simulated_broker import SimulatedBroker, TradeRecord
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.session.clock import TimeBox
from intraday_trading.strategies.base import Bar, Strategy, StrategyContext


@dataclass(frozen=True)
class BacktestResult:
    equity_curve: list[tuple[datetime, float]]
    trades: list[TradeRecord]
    final_equity: float


def run_backtest(
    strategy: Strategy,
    bars_by_symbol: dict[str, list[Bar]],
    risk_manager: RiskManager,
    broker: SimulatedBroker,
    time_box: TimeBox,
) -> BacktestResult:
    """`time_box` must be the same `TimeBox` instance backing `risk_manager`'s
    `SessionClock` -- this is what lets `risk_manager.begin_session()` /
    `check_loss_limits()` / `check_session_flatten()` see simulated time advancing
    exactly as it would in the live loop, one bar at a time, in strict chronological
    order (ties broken by symbol name for determinism -- BT-006)."""
    events = sorted(
        ((bar.ts, symbol, bar) for symbol, bars in bars_by_symbol.items() for bar in bars),
        key=lambda event: (event[0], event[1]),
    )

    history: dict[str, list[Bar]] = defaultdict(list)
    equity_curve: list[tuple[datetime, float]] = []

    for ts, symbol, bar in events:
        time_box.value = ts
        broker.process_bar(symbol, bar)

        risk_manager.begin_session()
        risk_manager.check_loss_limits()
        risk_manager.check_session_flatten()

        history[symbol].append(bar)
        context = StrategyContext(current_time=ts, history_by_symbol=history)
        for signal in strategy.on_bar(symbol, bar, context):
            risk_manager.check_and_submit_entry(signal)

        equity_curve.append((ts, broker.get_account().equity))

    return BacktestResult(
        equity_curve=equity_curve,
        trades=list(broker.closed_trades),
        final_equity=broker.get_account().equity,
    )
