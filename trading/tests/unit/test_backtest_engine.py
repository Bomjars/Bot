from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

from intraday_trading.backtest.costs import CostModel
from intraday_trading.backtest.engine import run_backtest
from intraday_trading.backtest.simulated_broker import SimulatedBroker
from intraday_trading.broker.base import Side
from intraday_trading.config import RiskLimits
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.risk.signals import EntrySignal
from intraday_trading.session.calendar import EXCHANGE_TZ, ExchangeCalendar
from intraday_trading.session.clock import SessionClock, TimeBox
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.storage.risk_state_store import RiskStateStore
from intraday_trading.strategies.base import Bar, StrategyContext

T0 = datetime(2024, 1, 2, 9, 45, tzinfo=EXCHANGE_TZ)  # well inside the 9:30-16:00 ET session


def _flat_bars(symbol: str, n: int, price: float = 100.0) -> list[Bar]:
    return [
        Bar(
            ts=T0 + timedelta(minutes=i),
            open=price,
            high=price,
            low=price,
            close=price,
            volume=1000.0,
        )
        for i in range(n)
    ]


def _setup(
    tmp_path: Path, limits: RiskLimits | None = None
) -> tuple[RiskManager, SimulatedBroker, TimeBox]:
    time_box = TimeBox(T0)
    clock = SessionClock(
        calendar=ExchangeCalendar(),
        no_entry_first_minutes=0,
        no_entry_last_minutes=0,
        flatten_before_close_minutes=0,
        now_provider=time_box,
    )
    db = tmp_path / "bt.db"
    broker = SimulatedBroker(starting_equity=100_000.0, cost_model=CostModel())
    risk_manager = RiskManager(
        broker=broker,
        limits=limits or RiskLimits(min_avg_dollar_volume_usd=1.0, min_price_usd=0.01),
        clock=clock,
        state_store=RiskStateStore(db),
        rejection_log=RejectionLog(db),
    )
    return risk_manager, broker, time_box


class OneShotBuyStrategy:
    name = "one_shot_buy"

    def __init__(self, symbol: str, qty: int = 10, stop_offset: float = 5.0) -> None:
        self.symbol = symbol
        self.qty = qty
        self.stop_offset = stop_offset
        self._entered = False

    def on_bar(self, symbol: str, bar: Bar, context: StrategyContext) -> list[EntrySignal]:
        if symbol != self.symbol or self._entered:
            return []
        self._entered = True
        return [
            EntrySignal(
                strategy=self.name,
                symbol=symbol,
                side=Side.BUY,
                qty=self.qty,
                entry_price=bar.close,
                stop_price=bar.close - self.stop_offset,
                take_profit_price=None,
                current_price=bar.close,
                avg_dollar_volume=10_000_000.0,
                spread_pct=0.001,
                signal_seq="seq-1",
            )
        ]


class AlwaysBuyStrategy:
    """Emits a fresh entry signal on every bar, unconditionally -- used to prove
    RiskManager's limits (not the strategy's own restraint) are what caps activity."""

    name = "always_buy"

    def __init__(self, symbol: str) -> None:
        self.symbol = symbol
        self._seq = 0

    def on_bar(self, symbol: str, bar: Bar, context: StrategyContext) -> list[EntrySignal]:
        if symbol != self.symbol:
            return []
        self._seq += 1
        return [
            EntrySignal(
                strategy=self.name,
                symbol=symbol,
                side=Side.BUY,
                qty=1,
                entry_price=bar.close,
                stop_price=bar.close - 90.0,
                take_profit_price=None,
                current_price=bar.close,
                avg_dollar_volume=10_000_000.0,
                spread_pct=0.001,
                signal_seq=f"seq-{self._seq}",
            )
        ]


class LookaheadAssertingStrategy:
    """BT-002/BT-005: on every single call, asserts the structural no-look-ahead
    guarantee holds -- history for any symbol never contains a bar timestamped after
    the current bar being processed."""

    name = "lookahead_check"

    def on_bar(self, symbol: str, bar: Bar, context: StrategyContext) -> list[EntrySignal]:
        assert bar.ts == context.current_time
        for sym, bars in context.history_by_symbol.items():
            for past_bar in bars:
                assert past_bar.ts <= context.current_time, (
                    f"look-ahead: {sym} bar at {past_bar.ts} visible at "
                    f"current_time={context.current_time}"
                )
        return []


def test_BT_001_same_strategy_and_risk_manager_classes_drive_the_backtest(tmp_path: Path) -> None:
    risk_manager, broker, time_box = _setup(tmp_path)
    strategy = OneShotBuyStrategy("AAPL")
    bars = {"AAPL": _flat_bars("AAPL", 5)}

    result = run_backtest(strategy, bars, risk_manager, broker, time_box)

    assert len(result.equity_curve) == 5
    assert len(broker.get_positions()) == 1  # the one-shot entry was accepted


def test_BT_002_BT_005_lookahead_guarantee_holds_across_a_full_run(tmp_path: Path) -> None:
    risk_manager, broker, time_box = _setup(tmp_path)
    strategy = LookaheadAssertingStrategy()
    bars = {
        "AAPL": _flat_bars("AAPL", 10, price=100.0),
        "MSFT": _flat_bars("MSFT", 10, price=200.0),
    }

    # No AssertionError propagating out means the guarantee held for every call.
    run_backtest(strategy, bars, risk_manager, broker, time_box)


def test_BT_006_backtest_is_deterministic(tmp_path: Path) -> None:
    bars = {"AAPL": _flat_bars("AAPL", 5)}

    risk_manager_a, broker_a, time_box_a = _setup(tmp_path / "a")
    result_a = run_backtest(OneShotBuyStrategy("AAPL"), bars, risk_manager_a, broker_a, time_box_a)

    risk_manager_b, broker_b, time_box_b = _setup(tmp_path / "b")
    result_b = run_backtest(OneShotBuyStrategy("AAPL"), bars, risk_manager_b, broker_b, time_box_b)

    assert result_a.equity_curve == result_b.equity_curve
    assert result_a.final_equity == result_b.final_equity
    assert len(result_a.trades) == len(result_b.trades)


def test_BT_007_risk_manager_limits_apply_inside_the_backtest(tmp_path: Path) -> None:
    limits = RiskLimits(
        max_open_positions=1,
        min_avg_dollar_volume_usd=1.0,
        min_price_usd=0.01,
        max_trades_per_day=50,
    )
    risk_manager, broker, time_box = _setup(tmp_path, limits=limits)
    strategy = AlwaysBuyStrategy("AAPL")
    bars = {"AAPL": _flat_bars("AAPL", 10)}

    run_backtest(strategy, bars, risk_manager, broker, time_box)

    # Every bar after the first proposed another entry; max_open_positions=1 must have
    # rejected all of them once the first was accepted.
    assert len(broker.get_positions()) == 1


def test_BT_003_BT_004_costs_reduce_equity_and_scale_with_multiplier(tmp_path: Path) -> None:
    bars = {"AAPL": _flat_bars("AAPL", 3)}
    strategy = OneShotBuyStrategy("AAPL")

    rm_free, broker_free, tb_free = _setup(tmp_path / "free")
    broker_free.cost_model = CostModel(commission_min=0, slippage_bps=0, spread_bps=0)
    result_free = run_backtest(strategy, bars, rm_free, broker_free, tb_free)

    rm_1x, broker_1x, tb_1x = _setup(tmp_path / "1x")
    broker_1x.cost_model = CostModel(commission_min=1.0, slippage_bps=5.0, spread_bps=2.0)
    result_1x = run_backtest(OneShotBuyStrategy("AAPL"), bars, rm_1x, broker_1x, tb_1x)

    rm_2x, broker_2x, tb_2x = _setup(tmp_path / "2x")
    broker_2x.cost_model = broker_1x.cost_model.at_multiplier(2.0)
    result_2x = run_backtest(OneShotBuyStrategy("AAPL"), bars, rm_2x, broker_2x, tb_2x)

    assert result_1x.final_equity < result_free.final_equity
    assert result_2x.final_equity <= result_1x.final_equity
