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

from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

import pandas as pd

from intraday_trading.backtest.costs import CostModel
from intraday_trading.backtest.engine import run_backtest
from intraday_trading.backtest.simulated_broker import SimulatedBroker, TradeRecord
from intraday_trading.config import RiskLimits
from intraday_trading.data.client import BAR_COLUMNS
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.session.calendar import EXCHANGE_TZ, ExchangeCalendar
from intraday_trading.session.clock import SessionClock, TimeBox
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.storage.risk_state_store import RiskStateStore
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
    itself and the bars -- shared across every run in the grid."""

    starting_equity: float
    cost_model: CostModel
    risk_limits: RiskLimits
    database_path: Path
    leveraged_etf_symbols: frozenset[str] = frozenset()


def run_spy_config(
    symbol: str,
    strategy_config: SpyMomentumConfig,
    bars: dict[str, list[Bar]],
    run_config: GridRunConfig,
) -> pd.Series:
    """Runs one config through the real backtester/RiskManager/SimulatedBroker pipeline
    (BT-007: no shortcut around RiskManager, even for a grid run) and returns its daily
    P&L series."""
    daily_pnl, _trades = run_spy_config_with_trades(symbol, strategy_config, bars, run_config)
    return daily_pnl


def run_spy_config_with_trades(
    symbol: str,
    strategy_config: SpyMomentumConfig,
    bars: dict[str, list[Bar]],
    run_config: GridRunConfig,
) -> tuple[pd.Series, list[TradeRecord]]:
    """Same run as `run_spy_config`, but also returns the closed trades (with their
    signal_strength) -- for validation/signal_confidence.py's bucketed win-rate, only
    ever called for a single fixed, pre-defined config (e.g. the paper_faithful
    reference), never for every point in the 192-config grid: persisting every grid
    config's trades into one shared `closed_trades` bucket would mix a well-behaved
    config's trades with an overfit one's, and CLAUDE.md rule 7 forbids picking a
    "best" config to persist instead by looking at results."""
    time_box = TimeBox(bars[symbol][0].ts)
    clock = SessionClock(
        calendar=ExchangeCalendar(),
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
        state_store=RiskStateStore(run_config.database_path),
        rejection_log=RejectionLog(run_config.database_path),
        leveraged_etf_symbols=run_config.leveraged_etf_symbols,
    )
    strategy = SpyMomentumStrategy(symbol=symbol, config=strategy_config)
    result = run_backtest(strategy, bars, risk_manager, broker, time_box)
    daily_pnl = daily_pnl_from_equity_curve(result.equity_curve, run_config.starting_equity)
    return daily_pnl, result.trades


def run_and_log_grid(
    symbol: str,
    strategy_name: str,
    configs: list[SpyMomentumConfig],
    bars: dict[str, list[Bar]],
    run_config: GridRunConfig,
    registry: TrialRegistry,
) -> list[int]:
    """Runs every config in `configs`, logging each to the trial registry with its full
    daily P&L series (VAL-006) -- never a subset chosen after seeing partial results
    (CLAUDE.md rule 7). Returns the logged trial ids, in `configs` order."""
    trial_ids = []
    for strategy_config in configs:
        daily_pnl = run_spy_config(symbol, strategy_config, bars, run_config)
        trial_ids.append(registry.log_trial(strategy_name, asdict(strategy_config), daily_pnl))
    return trial_ids
