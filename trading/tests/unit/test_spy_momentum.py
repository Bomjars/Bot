"""docs/STRATEGY_SPEC_SPY.md, scenarios SPY-01..11 (docs/TEST_SCENARIOS.md).

SPY-01/02/08/09/10 test the pure Noise Area / sizing formulas directly (white-box,
reaching into the module's private `_CompletedDay`/`_compute_band`/`_sigma_spy` --
acceptable here since these formulas, not just end-to-end behaviour, are the thing the
paper replication depends on getting exactly right). SPY-03..07 drive the strategy
through its public `on_bar` interface, the same one the backtester/paper loop uses.
"""

from __future__ import annotations

from datetime import date, datetime, time
from math import sqrt
from pathlib import Path

import pytest

from intraday_trading.backtest.costs import CostModel
from intraday_trading.backtest.engine import run_backtest
from intraday_trading.backtest.simulated_broker import SimulatedBroker
from intraday_trading.broker.base import PositionInfo, Side
from intraday_trading.config import RiskLimits
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.risk.signals import EntrySignal, ExitSignal
from intraday_trading.session.calendar import EXCHANGE_TZ, ExchangeCalendar
from intraday_trading.session.clock import SessionClock, TimeBox
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.storage.risk_state_store import RiskStateStore
from intraday_trading.strategies.base import Bar, StrategyContext
from intraday_trading.strategies.spy_momentum import (
    SIZING_LOOKBACK_DAYS,
    SpyMomentumConfig,
    SpyMomentumStrategy,
    _CompletedDay,
    _DayState,
)

SYMBOL = "SPY"


def _bar(day: date, hh: int, mm: int, close: float, volume: float = 1_000_000.0) -> Bar:
    ts = datetime(day.year, day.month, day.day, hh, mm, tzinfo=EXCHANGE_TZ)
    return Bar(ts=ts, open=close, high=close, low=close, close=close, volume=volume)


def _context(
    ts: datetime, equity: float = 100_000.0, position: PositionInfo | None = None
) -> StrategyContext:
    return StrategyContext(
        current_time=ts,
        history_by_symbol={},
        equity=equity,
        open_positions={SYMBOL: position} if position is not None else {},
    )


def _strategy(**overrides: object) -> SpyMomentumStrategy:
    config = SpyMomentumConfig(**overrides)  # type: ignore[arg-type]
    return SpyMomentumStrategy(symbol=SYMBOL, config=config)


def _feed_day(
    strategy: SpyMomentumStrategy,
    day: date,
    session_open: float,
    decision_closes: dict[time, float],
) -> None:
    """Warm-up helper: feeds an open bar plus one bar per (decision_time, close),
    ignoring any signals -- used only to build up `strategy._days` history."""
    open_bar = _bar(day, 9, 30, session_open)
    strategy.on_bar(SYMBOL, open_bar, _context(open_bar.ts))
    for t, price in sorted(decision_closes.items()):
        bar = _bar(day, t.hour, t.minute, price)
        strategy.on_bar(SYMBOL, bar, _context(bar.ts))


def test_SPY_01_sigma_matches_hand_calculation() -> None:
    strategy = _strategy(lookback_days=2)
    day1, day2, day3 = date(2024, 1, 2), date(2024, 1, 3), date(2024, 1, 4)

    _feed_day(strategy, day1, session_open=100.0, decision_closes={time(10, 0): 101.0})  # 1%
    _feed_day(strategy, day2, session_open=200.0, decision_closes={time(10, 0): 204.0})  # 2%

    open_bar = _bar(day3, 9, 30, 300.0)
    strategy.on_bar(SYMBOL, open_bar, _context(open_bar.ts))

    band = strategy._compute_band(strategy._day, time(10, 0))  # type: ignore[arg-type]
    assert band is not None
    sigma = (0.01 + 0.02) / 2
    upper, lower = band
    assert upper == pytest.approx(300.0 * (1 + sigma))  # anchor: today's open (300 > prev close)
    assert lower == pytest.approx(204.0 * (1 - sigma))  # anchor: previous close


def test_SPY_02_boundaries_anchor_on_the_higher_and_lower_of_open_vs_prev_close() -> None:
    day1, day2 = date(2024, 1, 2), date(2024, 1, 3)

    # Previous close (101) above today's open (90): upper anchors on the previous close.
    strategy_a = _strategy(lookback_days=1)
    _feed_day(strategy_a, day1, session_open=100.0, decision_closes={time(10, 0): 101.0})
    open_bar_a = _bar(day2, 9, 30, 90.0)
    strategy_a.on_bar(SYMBOL, open_bar_a, _context(open_bar_a.ts))
    upper_a, lower_a = strategy_a._compute_band(strategy_a._day, time(10, 0))  # type: ignore[arg-type]
    assert upper_a == pytest.approx(101.0 * 1.01)  # anchored on previous close
    assert lower_a == pytest.approx(90.0 * 0.99)  # anchored on today's open

    # Previous close (101) below today's open (150): upper anchors on today's open.
    strategy_b = _strategy(lookback_days=1)
    _feed_day(strategy_b, day1, session_open=100.0, decision_closes={time(10, 0): 101.0})
    open_bar_b = _bar(day2, 9, 30, 150.0)
    strategy_b.on_bar(SYMBOL, open_bar_b, _context(open_bar_b.ts))
    upper_b, lower_b = strategy_b._compute_band(strategy_b._day, time(10, 0))  # type: ignore[arg-type]
    assert upper_b == pytest.approx(150.0 * 1.01)  # anchored on today's open
    assert lower_b == pytest.approx(101.0 * 0.99)  # anchored on previous close


def test_SPY_03_no_trade_until_the_next_decision_time() -> None:
    strategy = _strategy(lookback_days=1, sizing="fixed_notional")
    day1, day2 = date(2024, 1, 2), date(2024, 1, 3)
    # Both 10:00 and 10:30 need historical data: bands are computed per time-of-day, and
    # this test's entry lands at the 10:30 decision, not 10:00.
    _feed_day(
        strategy,
        day1,
        session_open=100.0,
        decision_closes={time(10, 0): 100.5, time(10, 30): 100.5},
    )

    open_bar = _bar(day2, 9, 30, 100.0)
    strategy.on_bar(SYMBOL, open_bar, _context(open_bar.ts))

    off_grid_bar = _bar(
        day2, 10, 17, 200.0
    )  # way above any plausible band, but not a decision time
    signals = strategy.on_bar(SYMBOL, off_grid_bar, _context(off_grid_bar.ts))
    assert signals == []

    decision_bar = _bar(day2, 10, 30, 200.0)
    signals = strategy.on_bar(SYMBOL, decision_bar, _context(decision_bar.ts))
    assert len(signals) == 1
    assert isinstance(signals[0], EntrySignal)


def test_SPY_04_price_above_band_enters_long_never_short() -> None:
    strategy = _strategy(lookback_days=1, sizing="fixed_notional")
    day1, day2 = date(2024, 1, 2), date(2024, 1, 3)
    _feed_day(strategy, day1, session_open=100.0, decision_closes={time(10, 0): 100.5})

    open_bar = _bar(day2, 9, 30, 100.0)
    strategy.on_bar(SYMBOL, open_bar, _context(open_bar.ts))

    entry_bar = _bar(day2, 10, 0, 200.0)  # comfortably above the band
    signals = strategy.on_bar(SYMBOL, entry_bar, _context(entry_bar.ts))

    assert len(signals) == 1
    assert isinstance(signals[0], EntrySignal)
    assert signals[0].side == Side.BUY


def _warmed_up_strategy_with_open_long(
    day2: date, entry_price: float = 110.0
) -> tuple[SpyMomentumStrategy, EntrySignal]:
    """Shared setup for SPY-05/06: one warm-up day with symmetric 1% moves at both 10:00
    and 10:30, then a long entered at day2's 10:00 decision."""
    strategy = _strategy(lookback_days=1, stop_variant="curr_band_vwap", sizing="fixed_notional")
    day1 = date(2024, 1, 2)
    _feed_day(
        strategy, day1, session_open=100.0, decision_closes={time(10, 0): 101.0, time(10, 30): 99.0}
    )

    open_bar = _bar(day2, 9, 30, 100.0)
    strategy.on_bar(SYMBOL, open_bar, _context(open_bar.ts))

    entry_bar = _bar(day2, 10, 0, entry_price)  # above upper (~101.0) -> triggers a long
    signals = strategy.on_bar(SYMBOL, entry_bar, _context(entry_bar.ts))
    assert len(signals) == 1 and isinstance(signals[0], EntrySignal)
    return strategy, signals[0]


def test_SPY_05_reversal_closes_and_reopens_opposite_with_costed_fills_both_sides() -> None:
    day2 = date(2024, 1, 3)
    strategy, entry = _warmed_up_strategy_with_open_long(day2)
    open_position = PositionInfo(
        symbol=SYMBOL,
        qty=entry.qty,
        side=Side.BUY,
        avg_entry_price=entry.entry_price,
        current_price=95.0,
        unrealized_pl=0.0,
    )

    # Price has fallen through the lower band (~98.01) at the 10:30 decision -> reversal.
    reversal_bar = _bar(day2, 10, 30, 95.0)
    signals = strategy.on_bar(
        SYMBOL, reversal_bar, _context(reversal_bar.ts, position=open_position)
    )

    assert len(signals) == 2
    assert isinstance(signals[0], ExitSignal) and signals[0].reason == "reversal"
    assert isinstance(signals[1], EntrySignal) and signals[1].side == Side.SELL
    # BT-003 elsewhere proves the cost model actually deducts commission/slippage on
    # every fill; this only proves the strategy emits both costed legs of the reversal
    # (an ExitSignal for the close, an EntrySignal for the reopen), in order.


def test_SPY_06_stop_only_closes_with_no_reopen() -> None:
    day2 = date(2024, 1, 3)
    strategy, entry = _warmed_up_strategy_with_open_long(day2, entry_price=110.0)
    open_position = PositionInfo(
        symbol=SYMBOL,
        qty=entry.qty,
        side=Side.BUY,
        avg_entry_price=entry.entry_price,
        current_price=99.0,
        unrealized_pl=0.0,
    )

    # Price at 99.0 is still above the lower band (~98.01, no reversal) but the running
    # VWAP (pulled up by the 110.0 entry bar) is well above the upper band, so
    # max(upper, vwap) is the binding stop and 99.0 is below it.
    stop_bar = _bar(day2, 10, 30, 99.0)
    signals = strategy.on_bar(SYMBOL, stop_bar, _context(stop_bar.ts, position=open_position))

    assert len(signals) == 1
    assert isinstance(signals[0], ExitSignal)
    assert signals[0].reason == "stop"


def test_SPY_07_house_mode_is_flat_before_the_close_via_risk_manager_session_flatten(
    tmp_path: Path,
) -> None:
    strategy = _strategy(lookback_days=1, sizing="vol_target", sigma_target=0.02, leverage_cap=1.0)

    # Seed 15 days of sizing/band history directly (bypassing on_bar) so day-under-test
    # doesn't need 15 real days fed through the engine: 14 days of a large, clearly-non-
    # trivial alternating daily return (so sigma_SPY is comfortably above sigma_target,
    # keeping the resulting position small and safely within every default RiskLimits),
    # plus a 15th day carrying the one decision-time close the band itself needs.
    closes = [100.0]
    for i in range(1, 14):
        closes.append(closes[-1] * (1.10 if i % 2 else 1 / 1.10))
    closes.append(100.1)
    for i, close in enumerate(closes):
        strategy._days.append(
            _CompletedDay(
                session_open=100.0,
                session_close=close,
                decision_closes={time(10, 0): 100.1} if i == len(closes) - 1 else {},
                total_volume=1_000_000.0,
            )
        )
    assert len(closes) == SIZING_LOOKBACK_DAYS + 1

    day = date(2024, 1, 2)  # a known NYSE trading day, per test_backtest_engine.py
    bars = {
        SYMBOL: [
            _bar(day, 9, 30, 100.0),
            _bar(day, 10, 0, 100.21),  # just above the (tiny) band -> long entry
            _bar(day, 15, 55, 100.21),  # inside the flatten window (close - 10min)
        ]
    }

    time_box = TimeBox(bars[SYMBOL][0].ts)
    clock = SessionClock(
        calendar=ExchangeCalendar(),
        no_entry_first_minutes=RiskLimits().no_entry_first_minutes,
        no_entry_last_minutes=RiskLimits().no_entry_last_minutes,
        flatten_before_close_minutes=RiskLimits().flatten_before_close_minutes,
        now_provider=time_box,
    )
    db = tmp_path / "spy_flatten.db"
    broker = SimulatedBroker(starting_equity=100_000.0, cost_model=CostModel())
    # notional (~20,242) is just over the default 20% cap once priced at the entry
    # decision rather than the open -- loosened slightly for this test only.
    risk_manager = RiskManager(
        broker=broker,
        limits=RiskLimits(max_position_pct_of_equity=0.25),
        clock=clock,
        state_store=RiskStateStore(db),
        rejection_log=RejectionLog(db),
    )

    result = run_backtest(strategy, bars, risk_manager, broker, time_box)

    assert len(result.trades) >= 1  # the entry (and its forced flatten) actually happened
    assert broker.get_positions() == []


@pytest.mark.parametrize(
    ("mode_leverage_cap", "expected_multiplier"),
    [(4.0, 2.0), (1.0, 1.0)],
    ids=["paper_faithful_2x", "house_risk_capped_1x"],
)
def test_SPY_08_sizing_multiplier_uncapped_below_cap_capped_above(
    mode_leverage_cap: float, expected_multiplier: float
) -> None:
    # sigma_SPY = 1%, sigma_target = 2% -> uncapped multiplier would be 2.0x.
    strategy = _seeded_sizing_strategy(target_sigma=0.01, leverage_cap=mode_leverage_cap)
    day = _DayState(session_date=date(2024, 1, 2), session_open=100.0, prev_session_close=None)

    shares = strategy._shares_for_today(
        day, _context(datetime(2024, 1, 2, 10, 0, tzinfo=EXCHANGE_TZ))
    )

    expected_shares = int((100_000.0 * expected_multiplier) // 100.0)
    assert shares == expected_shares


@pytest.mark.parametrize(
    ("mode_leverage_cap", "expected_multiplier"),
    [(4.0, 4.0), (1.0, 1.0)],
    ids=["paper_faithful_capped_4x", "house_risk_capped_1x"],
)
def test_SPY_09_sizing_multiplier_capped_at_the_mode_ceiling(
    mode_leverage_cap: float, expected_multiplier: float
) -> None:
    # sigma_SPY = 0.2%, sigma_target = 2% -> uncapped multiplier would be 10x, always capped.
    strategy = _seeded_sizing_strategy(target_sigma=0.002, leverage_cap=mode_leverage_cap)
    day = _DayState(session_date=date(2024, 1, 2), session_open=100.0, prev_session_close=None)

    shares = strategy._shares_for_today(
        day, _context(datetime(2024, 1, 2, 10, 0, tzinfo=EXCHANGE_TZ))
    )

    expected_shares = int((100_000.0 * expected_multiplier) // 100.0)
    assert shares == expected_shares


def _seeded_sizing_strategy(target_sigma: float, leverage_cap: float) -> SpyMomentumStrategy:
    """Seeds exactly 15 daily closes whose sample stdev of returns is `target_sigma`,
    using an alternating +a/-a sequence (14 returns, 7 of each): sample stdev (ddof=1)
    of such a sequence is `a * sqrt(14/13)`, so solving for `a` hits any target exactly."""
    strategy = _strategy(sizing="vol_target", sigma_target=0.02, leverage_cap=leverage_cap)
    a = target_sigma / sqrt(14 / 13)
    closes = [100.0]
    for i in range(14):
        closes.append(closes[-1] * (1 + a if i % 2 == 0 else 1 - a))
    for close in closes:
        strategy._days.append(
            _CompletedDay(
                session_open=100.0, session_close=close, decision_closes={}, total_volume=0.0
            )
        )
    sigma = strategy._sigma_spy()
    assert sigma is not None and sigma == pytest.approx(target_sigma, rel=1e-6)
    return strategy


def test_SPY_10_insufficient_history_emits_no_signals() -> None:
    strategy = _strategy(lookback_days=14)
    day1, day2 = date(2024, 1, 2), date(2024, 1, 3)
    # Only one warm-up day, far short of the configured 14.
    _feed_day(strategy, day1, session_open=100.0, decision_closes={time(10, 0): 101.0})

    open_bar = _bar(day2, 9, 30, 100.0)
    strategy.on_bar(SYMBOL, open_bar, _context(open_bar.ts))
    assert strategy._compute_band(strategy._day, time(10, 0)) is None  # type: ignore[arg-type]

    breakout_bar = _bar(day2, 10, 0, 500.0)  # would obviously breach any real band
    signals = strategy.on_bar(SYMBOL, breakout_bar, _context(breakout_bar.ts))
    assert signals == []


@pytest.mark.skip(
    reason="SPY-11: real historical Alpaca bars aren't available in this sandbox "
    "(no network egress to fetch them); run this replication manually against real "
    "paper-account historical data per docs/STRATEGY_SPEC_SPY.md section 5 before "
    "treating the strategy as validated for paper trading."
)
def test_SPY_11_replicates_the_papers_own_settings_within_tolerance() -> None:
    raise NotImplementedError


def _limited_strategy(limits: RiskLimits) -> SpyMomentumStrategy:
    return SpyMomentumStrategy(
        symbol=SYMBOL, config=SpyMomentumConfig(sizing="fixed_notional"), risk_limits=limits
    )


def test_SPY_12_entry_is_capped_by_max_position_pct() -> None:
    strategy = _limited_strategy(RiskLimits(max_position_pct_of_equity=0.20))
    # 100k equity at $100 -> 1,000 shares uncapped; 20% cap -> 200. The $1 stop allows
    # 1,000 shares under 1% risk, so the position cap is what binds.
    shares = strategy._fit_to_risk_limits(1_000, price=100.0, stop_price=99.0, equity=100_000.0)
    assert shares == 200
    assert shares * 100.0 <= 100_000.0 * 0.20


def test_SPY_12_entry_is_capped_by_risk_per_trade() -> None:
    strategy = _limited_strategy(RiskLimits(max_position_pct_of_equity=1.0))
    # 1% of 100k = $1,000 risk; $4 stop distance -> 250 shares.
    shares = strategy._fit_to_risk_limits(1_000, price=100.0, stop_price=96.0, equity=100_000.0)
    assert shares == 250
    assert shares * 4.0 <= 100_000.0 * 0.01


def test_SPY_12_leverage_caps_a_raised_position_limit() -> None:
    strategy = _limited_strategy(
        RiskLimits(max_position_pct_of_equity=4.0, max_leverage=1.0, max_risk_per_trade_pct=0.05)
    )
    shares = strategy._fit_to_risk_limits(4_000, price=100.0, stop_price=99.9, equity=100_000.0)
    assert shares == 1_000  # 1x, not 4x


def test_SPY_12_never_sizes_up() -> None:
    strategy = _limited_strategy(RiskLimits(max_position_pct_of_equity=1.0))
    assert strategy._fit_to_risk_limits(10, 100.0, 99.0, 100_000.0) == 10


def test_SPY_12_no_limits_means_spec_sizing_unchanged() -> None:
    strategy = _strategy()
    assert strategy._fit_to_risk_limits(1_000, 100.0, 99.0, 100_000.0) == 1_000


def _random_walk_bars(n_days: int, seed: int) -> list[Bar]:
    import random
    from datetime import timedelta

    rng = random.Random(seed)
    calendar = ExchangeCalendar()
    bars: list[Bar] = []
    day, days, price = date(2023, 1, 3), 0, 400.0
    while days < n_days:
        session = calendar.session_for_date(day)
        if session is not None:
            ts = session.open
            while ts < session.close:
                price *= 1 + rng.gauss(0, 0.0006)
                bars.append(
                    Bar(ts=ts, open=price, high=price, low=price, close=price, volume=20_000)
                )
                ts += timedelta(minutes=1)
            days += 1
        day += timedelta(days=1)
    return bars


def test_SPY_12_a_default_limits_backtest_actually_trades() -> None:
    """The regression test for the grid that logged 202 all-zero trials: with the real
    default RiskLimits (1% risk/trade, 20% per position), realistic bars must produce
    trades -- previously every single entry was rejected as position_pct_exceeded."""
    from intraday_trading.strategies.spy_grid import GridRunConfig, run_spy_config

    bars = {SYMBOL: _random_walk_bars(n_days=40, seed=11)}
    run_config = GridRunConfig(
        starting_equity=100_000.0, cost_model=CostModel(), risk_limits=RiskLimits()
    )

    daily_pnl = run_spy_config(SYMBOL, SpyMomentumConfig(lookback_days=10), bars, run_config)

    assert (daily_pnl != 0).sum() > 5


def test_SPY_13_extended_hours_and_holiday_bars_are_ignored() -> None:
    strategy = _strategy()
    day = date(2024, 1, 2)
    premarket = _bar(day, 4, 0, 470.0)
    session_open = _bar(day, 9, 30, 475.0)
    after_hours = _bar(day, 17, 0, 480.0)
    holiday = _bar(date(2024, 1, 15), 10, 0, 490.0)  # Martin Luther King Jr. Day

    for bar in (premarket, session_open, after_hours, holiday):
        assert strategy.on_bar(SYMBOL, bar, _context(bar.ts)) == []

    assert strategy._day is not None
    assert strategy._day.session_open == 475.0  # not the 04:00 pre-market price
    assert strategy._day.last_close == 475.0  # after-hours/holiday bars never counted
    assert strategy._day.vwap_den == session_open.volume


def test_SPY_14_paper_faithful_run_never_holds_overnight() -> None:
    from intraday_trading.storage.rejection_log import InMemoryRejectionLog
    from intraday_trading.storage.risk_state_store import InMemoryRiskStateStore
    from intraday_trading.strategies.spy_grid import (
        paper_cost_model,
        paper_faithful_risk_limits,
        paper_reference_config,
    )

    bars = {SYMBOL: _random_walk_bars(n_days=40, seed=11)}
    limits = paper_faithful_risk_limits(RiskLimits())
    time_box = TimeBox(bars[SYMBOL][0].ts)
    clock = SessionClock(
        calendar=ExchangeCalendar(),
        no_entry_first_minutes=limits.no_entry_first_minutes,
        no_entry_last_minutes=limits.no_entry_last_minutes,
        flatten_before_close_minutes=limits.flatten_before_close_minutes,
        now_provider=time_box,
    )
    broker = SimulatedBroker(starting_equity=100_000.0, cost_model=paper_cost_model())
    risk_manager = RiskManager(
        broker=broker,
        limits=limits,
        clock=clock,
        state_store=InMemoryRiskStateStore(),
        rejection_log=InMemoryRejectionLog(),
    )
    strategy = SpyMomentumStrategy(
        symbol=SYMBOL, config=paper_reference_config(), risk_limits=limits
    )

    result = run_backtest(strategy, bars, risk_manager, broker, time_box)

    assert len(result.trades) > 5
    for trade in result.trades:
        entry = trade.entry_time.astimezone(EXCHANGE_TZ)
        exit_ = trade.exit_time.astimezone(EXCHANGE_TZ)
        assert entry.date() == exit_.date(), trade
    assert broker.get_positions() == []
