"""SPY intraday momentum ("Noise Area") strategy -- see docs/STRATEGY_SPEC_SPY.md, which
resolves every ambiguity the underlying paper (Zarattini, Aziz & Barbon, 2024) leaves
open. Implemented from that spec file, not the paper directly.

Two independent config axes:

- `stop_variant`: "opposite_band" (the paper's base model) or "curr_band_vwap" (its
  preferred model) -- which trailing-stop formula is checked at each decision time
  (spec §3).
- `mode`: "paper_faithful" (replication only, vol-target sizing with headroom up to the
  paper's 4x leverage) or "house_risk" (1x, the mode whose numbers matter for the
  go-live decision) -- spec §7. A strategy instance doesn't enforce this itself; whoever
  constructs it is responsible for pairing a `paper_faithful` instance's `leverage_cap`
  with a RiskManager whose `RiskLimits.max_leverage` was deliberately raised to match
  (never above 1.0 for any RiskManager that could ever route to a real broker -- see
  config.py's docstring on that field).

Two structural divergences from the paper, both forced by this codebase's existing
safety invariants rather than chosen for this strategy specifically:

1. Every entry, in both modes, still carries a real broker-side stop (RISK-010:
   RiskManager unconditionally rejects a zero-stop entry). It's set to the *opposite
   band value at entry time* -- one of the paper's own two named stop formulas, not an
   artificial safety add-on -- so it acts only as a backstop for an extreme intrabar
   move between decision times; the strategy's own decision-time check (whichever
   `stop_variant` is configured) is always at least as tight and controls in practice.
2. Sizing needs `StrategyContext.equity` and exit/reversal logic needs
   `StrategyContext.open_positions` (both added alongside this strategy) rather than the
   strategy tracking its own belief of account state -- avoiding silent drift after
   `RiskManager.check_session_flatten()` closes a position with no callback, or after a
   proposed signal is simply rejected.

State is accumulated incrementally, bar by bar, from what `on_bar` is actually handed --
never by re-scanning `context.history_by_symbol` (CLAUDE.md rule 9) or holding a
reference to anything outside the sanctioned `Bar`/`StrategyContext` path.
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass, field
from datetime import date, datetime, time
from statistics import stdev

import structlog

from intraday_trading.broker.base import Side
from intraday_trading.risk.signals import EntrySignal, ExitSignal
from intraday_trading.session.calendar import EXCHANGE_TZ
from intraday_trading.strategies.base import Bar, StrategyContext

logger = structlog.get_logger(__name__)

STOP_VARIANTS = ("opposite_band", "curr_band_vwap")
MODES = ("paper_faithful", "house_risk")
SIZING_MODES = ("vol_target", "fixed_notional")

SIZING_LOOKBACK_DAYS = 14
"""Spec §4: the position-sizing sigma is always a 14-day sample stdev of daily returns,
independent of the `lookback_days` config swept for the Noise Area band itself (spec §8's
parameter grid only sweeps the band's lookback, not this one)."""

FIRST_DECISION_TIME = time(10, 0)
MISSED_BAR_TOLERANCE_MINUTES = 5


@dataclass(frozen=True)
class SpyMomentumConfig:
    vm: float = 1.0
    """Volatility Multiplier (spec §2). Paper's headline results use 1.0."""
    lookback_days: int = 14
    decision_interval_minutes: int = 30
    stop_variant: str = "curr_band_vwap"
    mode: str = "house_risk"
    sizing: str = "vol_target"
    sigma_target: float = 0.02
    leverage_cap: float = 1.0
    """This strategy's own best-effort sizing cap -- RiskManager independently
    re-validates and may still reject (sizing/CLAUDE.md rule 5): the strategy proposes,
    RiskManager decides. Set to 4.0 only for a `paper_faithful` instance paired with a
    RiskManager whose `max_leverage` was likewise explicitly raised for that run."""
    assumed_spread_pct: float = 0.0005
    """1-minute OHLCV bars carry no bid/ask; this is a conservative constant stand-in
    for RiskManager's spread-width check (SPY's real spreads are far tighter)."""

    def __post_init__(self) -> None:
        if self.stop_variant not in STOP_VARIANTS:
            raise ValueError(f"stop_variant must be one of {STOP_VARIANTS}")
        if self.mode not in MODES:
            raise ValueError(f"mode must be one of {MODES}")
        if self.sizing not in SIZING_MODES:
            raise ValueError(f"sizing must be one of {SIZING_MODES}")
        if self.decision_interval_minutes not in (30, 60):
            raise ValueError("decision_interval_minutes must be 30 or 60")
        if self.lookback_days < 1:
            raise ValueError("lookback_days must be >= 1")


def _decision_grid(interval_minutes: int) -> tuple[time, ...]:
    minutes = (0, 30) if interval_minutes == 30 else (0,)
    grid = [
        time(hour, minute)
        for hour in range(10, 16)
        for minute in minutes
        if time(hour, minute) >= FIRST_DECISION_TIME
    ]
    return tuple(grid)


def _minutes_between(earlier: time, later: time) -> float:
    return (datetime.combine(date.min, later) - datetime.combine(date.min, earlier)).seconds / 60.0


@dataclass(frozen=True)
class _CompletedDay:
    session_open: float
    session_close: float
    decision_closes: dict[time, float]
    total_volume: float


@dataclass
class _DayState:
    session_date: date
    session_open: float
    prev_session_close: float | None
    last_close: float = 0.0
    vwap_num: float = 0.0
    vwap_den: float = 0.0
    decision_closes: dict[time, float] = field(default_factory=dict)
    resolved: set[time] = field(default_factory=set)
    shares_for_today: int | None = None

    @property
    def vwap(self) -> float:
        return self.vwap_num / self.vwap_den if self.vwap_den > 0 else self.last_close


class SpyMomentumStrategy:
    def __init__(self, symbol: str, config: SpyMomentumConfig, name: str = "spy_momentum") -> None:
        self.name = name
        self.symbol = symbol
        self._config = config
        self._grid = _decision_grid(config.decision_interval_minutes)
        self._days: deque[_CompletedDay] = deque(
            maxlen=max(config.lookback_days, SIZING_LOOKBACK_DAYS) + 1
        )
        self._day: _DayState | None = None
        self._seq = 0

    def on_bar(
        self, symbol: str, bar: Bar, context: StrategyContext
    ) -> list[EntrySignal | ExitSignal]:
        if symbol != self.symbol:
            return []

        local = bar.ts.astimezone(EXCHANGE_TZ)
        self._maybe_roll_day(local.date(), bar)
        day = self._day
        assert day is not None
        current_time = local.time()

        signals: list[EntrySignal | ExitSignal] = []

        # SPY-06/spec §6.6: catch up any decision time this bar has passed without an
        # exact-minute match, using the last bar seen if within the tolerance window.
        for grid_time in self._grid:
            if grid_time in day.resolved or grid_time >= current_time:
                continue
            if _minutes_between(grid_time, current_time) <= MISSED_BAR_TOLERANCE_MINUTES and (
                day.vwap_den > 0
            ):
                signals.extend(self._decide(day, grid_time, day.last_close, context))
            else:
                logger.warning(
                    "spy_momentum_missed_decision_time",
                    symbol=symbol,
                    decision_time=grid_time.isoformat(),
                )
            day.resolved.add(grid_time)

        typical_price = (bar.high + bar.low + bar.close) / 3.0
        day.vwap_num += typical_price * bar.volume
        day.vwap_den += bar.volume
        day.last_close = bar.close

        if current_time in self._grid and current_time not in day.resolved:
            signals.extend(self._decide(day, current_time, bar.close, context))
            day.resolved.add(current_time)

        return signals

    def _maybe_roll_day(self, current_date: date, bar: Bar) -> None:
        if self._day is not None and self._day.session_date == current_date:
            return
        if self._day is not None:
            for grid_time in self._grid:
                if grid_time not in self._day.resolved:
                    logger.warning(
                        "spy_momentum_missed_decision_time",
                        symbol=self.symbol,
                        decision_time=grid_time.isoformat(),
                        reason="session ended before this decision time (e.g. half day)",
                    )
            self._days.append(
                _CompletedDay(
                    session_open=self._day.session_open,
                    session_close=self._day.last_close,
                    decision_closes=dict(self._day.decision_closes),
                    total_volume=self._day.vwap_den,
                )
            )
        prev_close = self._days[-1].session_close if self._days else None
        self._day = _DayState(
            session_date=current_date, session_open=bar.open, prev_session_close=prev_close
        )

    def _decide(
        self, day: _DayState, decision_time: time, price: float, context: StrategyContext
    ) -> list[EntrySignal | ExitSignal]:
        day.decision_closes[decision_time] = price

        band = self._compute_band(day, decision_time)
        if band is None:
            return []  # SPY-10: insufficient history, already logged in _compute_band
        upper, lower = band

        position = context.open_positions.get(self.symbol)
        if position is None:
            if price > upper:
                return self._enter(day, decision_time, Side.BUY, price, upper, lower, context)
            if price < lower:
                return self._enter(day, decision_time, Side.SELL, price, upper, lower, context)
            return []

        current_side = position.side
        opposite_crossed = price < lower if current_side == Side.BUY else price > upper
        if opposite_crossed:
            new_side = Side.SELL if current_side == Side.BUY else Side.BUY
            return [
                self._exit(decision_time, "reversal"),
                *self._enter(day, decision_time, new_side, price, upper, lower, context),
            ]

        if self._config.stop_variant == "opposite_band":
            stop_level = lower if current_side == Side.BUY else upper
        else:
            stop_level = max(upper, day.vwap) if current_side == Side.BUY else min(lower, day.vwap)
        stop_crossed = price < stop_level if current_side == Side.BUY else price > stop_level
        if stop_crossed:
            return [self._exit(decision_time, "stop")]
        return []

    def _compute_band(self, day: _DayState, decision_time: time) -> tuple[float, float] | None:
        moves = [
            abs(completed.decision_closes[decision_time] / completed.session_open - 1)
            for completed in self._days
            if decision_time in completed.decision_closes and completed.session_open > 0
        ]
        if len(moves) < self._config.lookback_days:
            logger.info(
                "spy_momentum_insufficient_history",
                symbol=self.symbol,
                decision_time=decision_time.isoformat(),
                available_days=len(moves),
                required_days=self._config.lookback_days,
            )
            return None

        sigma = sum(moves[-self._config.lookback_days :]) / self._config.lookback_days
        anchor_high = max(day.session_open, day.prev_session_close or day.session_open)
        anchor_low = min(day.session_open, day.prev_session_close or day.session_open)
        upper = anchor_high * (1 + self._config.vm * sigma)
        lower = anchor_low * (1 - self._config.vm * sigma)
        return upper, lower

    def _sigma_spy(self) -> float | None:
        closes = [d.session_close for d in self._days]
        if len(closes) < SIZING_LOOKBACK_DAYS + 1:
            return None
        recent = closes[-(SIZING_LOOKBACK_DAYS + 1) :]
        returns = [recent[i] / recent[i - 1] - 1 for i in range(1, len(recent))]
        return stdev(returns)

    def _avg_dollar_volume(self) -> float:
        recent = list(self._days)[-self._config.lookback_days :]
        if not recent:
            return 0.0
        return sum(d.session_close * d.total_volume for d in recent) / len(recent)

    def _shares_for_today(self, day: _DayState, context: StrategyContext) -> int:
        if day.shares_for_today is not None:
            return day.shares_for_today
        if day.session_open <= 0:
            day.shares_for_today = 0
            return 0

        aum = context.equity
        if self._config.sizing == "fixed_notional":
            shares = math.floor(aum / day.session_open)
        else:
            sigma = self._sigma_spy()
            if sigma is None or sigma <= 0:
                shares = 0
            else:
                multiplier = min(self._config.leverage_cap, self._config.sigma_target / sigma)
                shares = math.floor(aum * multiplier / day.session_open)

        day.shares_for_today = max(shares, 0)
        return day.shares_for_today

    def _enter(
        self,
        day: _DayState,
        decision_time: time,
        side: Side,
        price: float,
        upper: float,
        lower: float,
        context: StrategyContext,
    ) -> list[EntrySignal | ExitSignal]:
        shares = self._shares_for_today(day, context)
        if shares <= 0:
            return []

        stop_price = lower if side == Side.BUY else upper
        self._seq += 1
        return [
            EntrySignal(
                strategy=self.name,
                symbol=self.symbol,
                side=side,
                qty=shares,
                entry_price=price,
                stop_price=stop_price,
                take_profit_price=None,
                current_price=price,
                avg_dollar_volume=self._avg_dollar_volume(),
                spread_pct=self._config.assumed_spread_pct,
                signal_seq=f"{self.name}-{self.symbol}-{decision_time.isoformat()}-{self._seq}",
                signal_strength=self._breakout_strength(side, price, upper, lower),
            )
        ]

    @staticmethod
    def _breakout_strength(side: Side, price: float, upper: float, lower: float) -> float | None:
        """How far past the crossed band edge this entry's price is, normalized by the
        band's own width -- e.g. 0.5 means the price cleared the edge by half the band's
        width. Purely descriptive (see risk/signals.py's EntrySignal.signal_strength);
        `None` only for the degenerate case of a zero-width band (upper == lower), which
        would make "normalized by width" undefined."""
        width = upper - lower
        if width <= 0:
            return None
        return (price - upper) / width if side == Side.BUY else (lower - price) / width

    def _exit(self, decision_time: time, reason: str) -> ExitSignal:
        self._seq += 1
        return ExitSignal(
            strategy=self.name,
            symbol=self.symbol,
            reason=reason,
            signal_seq=f"{self.name}-{self.symbol}-{decision_time.isoformat()}-exit-{self._seq}",
        )
