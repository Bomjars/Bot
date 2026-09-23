"""The SPY momentum parameter grid (docs/STRATEGY_SPEC_SPY.md §8): 192 `house_risk`
configs for the CSCV/PBO go-live decision, plus the paper's own single reference config
for the replication comparison (§5's Table 3).

Building and running the grid are kept separate: the grid itself (`house_risk_grid`,
`paper_reference_config`) is pure and fully testable without any market data; running it
(`run_and_log_grid`) needs real historical SPY bars, which this sandbox has no network
access to fetch -- see docs/PLAN.md and SPY-11 in tests/unit/test_spy_momentum.py. The
CLI's `backtest spy` command (cli.py) is the intended way to actually run this, on a
machine with real Alpaca paper keys and outbound network access.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import asdict, dataclass
from datetime import datetime

import pandas as pd

from intraday_trading.backtest.costs import CostModel
from intraday_trading.backtest.engine import run_backtest
from intraday_trading.backtest.simulated_broker import SimulatedBroker
from intraday_trading.config import RiskLimits
from intraday_trading.data.client import BAR_COLUMNS
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.session.calendar import EXCHANGE_TZ, ExchangeCalendar
from intraday_trading.session.clock import SessionClock, TimeBox
from intraday_trading.storage.rejection_log import InMemoryRejectionLog
from intraday_trading.storage.risk_state_store import InMemoryRiskStateStore
from intraday_trading.strategies.base import Bar
from intraday_trading.strategies.spy_momentum import SpyMomentumConfig, SpyMomentumStrategy
from intraday_trading.validation.registry import TrialRegistry

VM_VALUES: tuple[float, ...] = tuple(round(0.5 + 0.1 * i, 1) for i in range(16))  # 0.5 .. 2.0
LOOKBACK_DAYS_VALUES: tuple[int, ...] = (10, 14, 20)
DECISION_INTERVAL_VALUES: tuple[int, ...] = (30, 60)
STOP_VARIANT_VALUES: tuple[str, ...] = ("opposite_band", "curr_band_vwap")


def house_risk_grid(leverage_cap: float = 1.0) -> list[SpyMomentumConfig]:
    """192 economically-sensible configs (spec §8), all `house_risk` -- the grid that
    matters for the go-live decision (CLAUDE.md rule 7: run in full, never pruned or
    reselected based on how any one config's result looks)."""
    return [
        SpyMomentumConfig(
            vm=vm,
            lookback_days=lookback_days,
            decision_interval_minutes=decision_interval,
            stop_variant=stop_variant,
            mode="house_risk",
            sizing="vol_target",
            leverage_cap=leverage_cap,
        )
        for vm in VM_VALUES
        for lookback_days in LOOKBACK_DAYS_VALUES
        for decision_interval in DECISION_INTERVAL_VALUES
        for stop_variant in STOP_VARIANT_VALUES
    ]


def paper_reference_config(leverage_cap: float = 4.0) -> SpyMomentumConfig:
    """The paper's own settings (VM 1.0, 14-day lookback, 30-min decisions, curr_band_vwap
    stop, vol-target sizing) -- the single `paper_faithful` run compared against Table 3,
    never part of the CSCV grid itself."""
    return SpyMomentumConfig(
        vm=1.0,
        lookback_days=14,
        decision_interval_minutes=30,
        stop_variant="curr_band_vwap",
        mode="paper_faithful",
        sizing="vol_target",
        leverage_cap=leverage_cap,
    )


def paper_faithful_risk_limits(base: RiskLimits) -> RiskLimits:
    """The limits the paper_faithful reference run is checked against: `base` with every
    house rule the paper doesn't have lifted -- up to 4x leverage/position size, no
    cash-only rule (RISK-026), no daily/weekly/drawdown halts (one 5% losing week would
    otherwise halt it for the rest of the run), trading until the close. Replication
    only: never used for the go-live grid or any RiskManager wired to a real broker.

    Risk per trade is only raised to its 5% ceiling, so on very wide-stop days the
    position is still sized below the paper's -- a known, stated gap in the replication.
    """
    return base.model_copy(
        update={
            "max_leverage": 4.0,
            "max_position_pct_of_equity": 4.0,
            "max_risk_per_trade_pct": 0.05,
            "daily_loss_limit_pct": 1.0,
            "weekly_loss_limit_pct": 1.0,
            "drawdown_circuit_breaker_pct": 1.0,
            "cash_account_only": False,
            # 1, not 0: a 0-minute flatten only fires on a 16:00 bar, and regular-session
            # minute bars end at 15:59 -- so it never fired and positions were carried
            # overnight, which the paper never does. The 15:59 bar's close is the close.
            "flatten_before_close_minutes": 1,
            "no_entry_last_minutes": 0,
        }
    )


def paper_cost_model() -> CostModel:
    """Spec §5's costs exactly: $0.0035/share commission and $0.001/share slippage, and
    nothing else. CostModel's own defaults add 5 bps slippage + 2 bps spread per fill
    (~$0.27/share on a $450 SPY, ~50x the paper's figure); leaving those on silently
    made the first real grid run cost-bound (BT-010)."""
    return CostModel(
        commission_per_share=0.0035,
        slippage_per_share=0.001,
        slippage_bps=0.0,
        spread_bps=0.0,
    )


def bars_from_dataframe(df: pd.DataFrame) -> list[Bar]:
    """Converts a `BAR_COLUMNS`-shaped DataFrame (BarStore.get_bars/AlpacaMarketDataClient)
    into the `Bar` sequence the backtester consumes, sorted chronologically."""
    missing = set(BAR_COLUMNS) - set(df.columns)
    if missing:
        raise ValueError(f"bars frame missing columns: {sorted(missing)}")
    ordered = df.sort_values("ts")
    return [
        Bar(
            ts=pd.Timestamp(record["ts"]).to_pydatetime(),
            open=float(record["open"]),
            high=float(record["high"]),
            low=float(record["low"]),
            close=float(record["close"]),
            volume=float(record["volume"]),
        )
        for record in ordered.to_dict("records")
    ]


def daily_pnl_from_equity_curve(
    equity_curve: list[tuple[datetime, float]], starting_equity: float
) -> pd.Series:
    """Resamples a bar-by-bar equity curve to one P&L value per calendar date (exchange
    time): each day's last-seen equity minus the previous day's, first day minus
    `starting_equity` -- exactly the shape `TrialRegistry.log_trial` needs."""
    if not equity_curve:
        return pd.Series(dtype=float)
    frame = pd.DataFrame(equity_curve, columns=["ts", "equity"])
    frame["date"] = [pd.Timestamp(ts).astimezone(EXCHANGE_TZ).date() for ts in frame["ts"]]
    daily_close = frame.groupby("date")["equity"].last().sort_index()
    previous = daily_close.shift(1)
    previous.iloc[0] = starting_equity
    return daily_close - previous


@dataclass(frozen=True)
class GridRunConfig:
    """Everything a single grid config's backtest needs besides the strategy config
    itself and the bars -- shared across every run in the grid. Deliberately no database
    path: each run's risk state and rejections live in memory (see run_spy_config)."""

    starting_equity: float
    cost_model: CostModel
    risk_limits: RiskLimits
    leveraged_etf_symbols: frozenset[str] = frozenset()


def run_spy_config(
    symbol: str,
    strategy_config: SpyMomentumConfig,
    bars: dict[str, list[Bar]],
    run_config: GridRunConfig,
    calendar: ExchangeCalendar | None = None,
) -> pd.Series:
    """Runs one config through the real backtester/RiskManager/SimulatedBroker pipeline
    (BT-007: no shortcut around RiskManager, even for a grid run) and returns its daily
    P&L series.

    Each run gets its own fresh, in-memory RiskState and rejection log -- exactly like its
    fresh SimulatedBroker -- so no config's halts or peak equity can leak into the next,
    and nothing touches the real trading database's risk state. `calendar` can be shared
    across runs (it only caches immutable exchange sessions)."""
    time_box = TimeBox(bars[symbol][0].ts)
    clock_calendar = calendar if calendar is not None else ExchangeCalendar()
    clock = SessionClock(
        calendar=clock_calendar,
        no_entry_first_minutes=run_config.risk_limits.no_entry_first_minutes,
        no_entry_last_minutes=run_config.risk_limits.no_entry_last_minutes,
        flatten_before_close_minutes=run_config.risk_limits.flatten_before_close_minutes,
        now_provider=time_box,
    )
    broker = SimulatedBroker(
        starting_equity=run_config.starting_equity, cost_model=run_config.cost_model
    )
    risk_manager = RiskManager(
        broker=broker,
        limits=run_config.risk_limits,
        clock=clock,
        state_store=InMemoryRiskStateStore(),
        rejection_log=InMemoryRejectionLog(),
        leveraged_etf_symbols=run_config.leveraged_etf_symbols,
    )
    strategy = SpyMomentumStrategy(
        symbol=symbol,
        config=strategy_config,
        risk_limits=run_config.risk_limits,
        calendar=clock_calendar,
    )
    result = run_backtest(strategy, bars, risk_manager, broker, time_box)
    return daily_pnl_from_equity_curve(result.equity_curve, run_config.starting_equity)


def run_and_log_grid(
    symbol: str,
    strategy_name: str,
    configs: list[SpyMomentumConfig],
    bars: dict[str, list[Bar]],
    run_config: GridRunConfig,
    registry: TrialRegistry,
    on_progress: Callable[[int, int, SpyMomentumConfig], None] | None = None,
) -> list[int]:
    """Runs every config in `configs`, logging each to the trial registry with its full
    daily P&L series (VAL-006) -- never a subset chosen after seeing partial results
    (CLAUDE.md rule 7). Returns the logged trial ids, in `configs` order. `on_progress`,
    if given, is called as (done, total, config) after each config is logged."""
    trial_ids = []
    calendar = ExchangeCalendar()
    for done, strategy_config in enumerate(configs, start=1):
        daily_pnl = run_spy_config(symbol, strategy_config, bars, run_config, calendar)
        trial_ids.append(registry.log_trial(strategy_name, asdict(strategy_config), daily_pnl))
        if on_progress is not None:
            on_progress(done, len(configs), strategy_config)
    return trial_ids
