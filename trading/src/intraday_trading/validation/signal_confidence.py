"""Bucketed win-rate by signal strength: descriptive analytics over an *already-run*
backtest's closed trades, never fed into a risk decision or a parameter choice (CLAUDE.md
rule 7 doesn't apply here -- this never influences which strategy/config is chosen, it
only summarizes trades a grid run already produced). Trades are grouped into bands of
`EntrySignal.signal_strength` (risk/signals.py), and each band's realized win rate is
what the dashboard shows next to a new signal of similar strength -- explicitly a
backtest-derived statistic, not a live guarantee (McLean & Pontiff, 2016: published/
backtested edges shrink out-of-sample).
"""

from __future__ import annotations

import bisect
from dataclasses import dataclass
from typing import Protocol

DEFAULT_BUCKET_EDGES: tuple[float, ...] = (0.1, 0.25, 0.5, 1.0)
"""Upper edges of the finite buckets. The resulting table always has one more bucket
than this: [0, edges[0]), [edges[0], edges[1]), ..., [edges[-1], +inf)."""


class ClosedTrade(Protocol):
    """Structural type, not an import from backtest/ -- this module only needs these two
    fields, from whatever produced a closed trade (today, always
    `backtest.simulated_broker.TradeRecord`)."""

    signal_strength: float | None
    realized_pnl: float


@dataclass(frozen=True)
class ConfidenceBucket:
    low: float
    high: float
    """`float("inf")` for the open-ended top bucket."""
    n: int
    n_wins: int

    @property
    def win_rate(self) -> float | None:
        """`None` when `n == 0` -- an untested bucket's win rate isn't 0%, it's unknown,
        and the dashboard must show that distinction rather than a fabricated number."""
        return self.n_wins / self.n if self.n > 0 else None

    def contains(self, signal_strength: float) -> bool:
        return self.low <= signal_strength < self.high


@dataclass(frozen=True)
class SignalConfidenceTable:
    buckets: tuple[ConfidenceBucket, ...]

    def lookup(self, signal_strength: float) -> ConfidenceBucket | None:
        """The bucket `signal_strength` falls into, or `None` for a negative input (a
        breakout distance is never negative by construction -- see
        `SpyMomentumStrategy._breakout_strength` -- so this only guards against a bad
        caller rather than a case that occurs in practice)."""
        for bucket in self.buckets:
            if bucket.contains(signal_strength):
                return bucket
        return None


def build_confidence_table(
    trades: list[ClosedTrade], edges: tuple[float, ...] = DEFAULT_BUCKET_EDGES
) -> SignalConfidenceTable:
    """Buckets `trades` by `signal_strength` and counts wins (`realized_pnl > 0`) per
    bucket. Trades with `signal_strength is None` (a strategy that doesn't compute one)
    or negative (shouldn't occur -- see `ConfidenceBucket.lookup`) are excluded rather
    than silently sorted into a bucket they don't really belong in.
    """
    if len(edges) < 1:
        raise ValueError("edges must have at least one boundary")
    if list(edges) != sorted(set(edges)):
        raise ValueError("edges must be strictly increasing")

    bounds = (0.0, *edges, float("inf"))
    n_buckets = len(bounds) - 1
    counts = [0] * n_buckets
    wins = [0] * n_buckets

    for trade in trades:
        strength = trade.signal_strength
        if strength is None or strength < 0:
            continue
        idx = bisect.bisect_right(edges, strength)
        counts[idx] += 1
        if trade.realized_pnl > 0:
            wins[idx] += 1

    buckets = tuple(
        ConfidenceBucket(low=bounds[i], high=bounds[i + 1], n=counts[i], n_wins=wins[i])
        for i in range(n_buckets)
    )
    return SignalConfidenceTable(buckets=buckets)
