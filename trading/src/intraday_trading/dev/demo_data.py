"""Synthetic demo data -- purely so a fresh dashboard has something to render for a
design/UI preview. Every number generated here is fabricated with `numpy.random`, not
computed from any real backtest or trade.

This is intentionally kept separate from anything the live system reads for a real
decision: it is never imported by `dashboard/`, `cli.py`'s real commands, or any
go-live/paper-trading code path -- only `cli.py`'s `seed-demo-data` command calls it,
and that command refuses to target the same database as `Settings.database_path` (see
cli.py). CLAUDE.md's "never fabricate a number on a dashboard page" rule governs what
the *live* system shows for real state; it doesn't forbid a clearly separate, clearly
fake demo dataset like this one, as long as it can never be mistaken for real history.
"""

from __future__ import annotations

from dataclasses import asdict
from datetime import UTC
from pathlib import Path

import numpy as np
import pandas as pd

from intraday_trading.broker.base import OrderInfo, Side
from intraday_trading.risk.signals import EntrySignal
from intraday_trading.storage.order_log import OrderLog
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.strategies.spy_grid import house_risk_grid, paper_reference_config
from intraday_trading.validation.registry import TrialRegistry

N_DEMO_DAYS = 60
N_DEMO_CONFIGS = 24
N_DEMO_TRADE_DAYS = 12
DEMO_BASE_PRICE = 520.0

_REJECTION_REASONS = ("position_pct_exceeded", "spread_too_wide", "max_trades_per_day_reached")


def generate_demo_data(database_path: Path, seed: int = 7) -> None:
    """Populates `database_path` with a synthetic trial registry, order log, and
    rejection log -- enough for every dashboard page to render its populated state
    instead of an empty one. Deterministic given `seed`, so a demo looks the same
    every time it's regenerated."""
    rng = np.random.default_rng(seed)
    _seed_trials(database_path, rng)
    _seed_orders_and_rejections(database_path, rng)


def _seed_trials(database_path: Path, rng: np.random.Generator) -> None:
    registry = TrialRegistry(database_path)
    dates = pd.bdate_range(end=pd.Timestamp.today().normalize(), periods=N_DEMO_DAYS)

    for i, config in enumerate(house_risk_grid()[:N_DEMO_CONFIGS]):
        # A handful of configs carry a consistent edge; the rest are pure noise -- a
        # "most configs don't survive CSCV, a few do" pattern. The edge size (0.004,
        # tuned empirically against this module's own n_days/n_configs/noise, not
        # against any real strategy's PBO -- CLAUDE.md rule 7 governs real strategy
        # parameters, not this fabricated demo dataset) is what reliably keeps PBO
        # under the 5% threshold here; a much smaller edge is swamped by the noise
        # configs and PBO comes out high, which is a legitimate result but a less
        # useful one to demo with.
        edge = 0.004 if i % 6 == 0 else 0.0
        daily_pnl = rng.normal(loc=edge, scale=0.006, size=N_DEMO_DAYS) * 100_000.0
        registry.log_trial("spy_momentum", asdict(config), pd.Series(daily_pnl, index=dates))

    paper_pnl = rng.normal(loc=0.0015, scale=0.01, size=N_DEMO_DAYS) * 100_000.0
    registry.log_trial(
        "spy_momentum_paper_faithful",
        asdict(paper_reference_config()),
        pd.Series(paper_pnl, index=dates),
    )


def _demo_signal(side: Side, price: float, qty: int, seq: str) -> EntrySignal:
    stop = price - 2.0 if side == Side.BUY else price + 2.0
    return EntrySignal(
        strategy="spy_momentum",
        symbol="SPY",
        side=side,
        qty=qty,
        entry_price=price,
        stop_price=stop,
        take_profit_price=None,
        current_price=price,
        avg_dollar_volume=8_000_000_000.0,
        spread_pct=0.0004,
        signal_seq=seq,
    )


def _seed_orders_and_rejections(database_path: Path, rng: np.random.Generator) -> None:
    order_log = OrderLog(database_path)
    rejection_log = RejectionLog(database_path)

    trade_dates = pd.bdate_range(end=pd.Timestamp.today().normalize(), periods=N_DEMO_TRADE_DAYS)
    for i, day in enumerate(trade_dates):
        price = DEMO_BASE_PRICE + float(rng.normal(0, 3))
        side = Side.BUY if rng.random() > 0.4 else Side.SELL
        qty = int(rng.integers(50, 250))
        signal = _demo_signal(side, price, qty, seq=f"demo-order-{i}")
        order = OrderInfo(
            broker_order_id=f"demo-order-{i}",
            client_order_id=f"demo-client-{i}",
            symbol="SPY",
            side=side,
            qty=qty,
            status="filled",
            filled_qty=qty,
            filled_avg_price=price,
        )
        # Backdated to `day` at a plausible mid-session time, one order per distinct
        # trade date -- otherwise every order would land on "today" (OrderLog.log's
        # default), collapsing all 12 demo trade-days into one for GOLIVE-001's count.
        ts = day.to_pydatetime().replace(hour=15, minute=30, tzinfo=UTC)
        order_log.log(signal, order, ts=ts)

    for i, reason in enumerate(_REJECTION_REASONS * 2):
        signal = _demo_signal(Side.BUY, DEMO_BASE_PRICE, 500, seq=f"demo-rejected-{i}")
        rejection_log.log(signal, reason)
