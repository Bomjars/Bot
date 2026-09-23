"""Bot P&L vs. buy-and-hold of the same instrument, over the same window -- a plain
sanity check that never feeds back into any trading decision (unlike CSCV/PBO, this
isn't a validation-module output CLAUDE.md rule 7 forbids tuning against; it exists
purely to answer "did the bot actually do anything for me today"). Pure arithmetic here
-- broker-specific price fetching lives in broker/ibkr_broker.py's get_daily_closes().
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class BenchmarkComparison:
    bot_pnl: float
    bot_return_pct: float
    benchmark_pnl: float
    benchmark_return_pct: float

    @property
    def outperformance_pct(self) -> float:
        """The bot's return minus the benchmark's, in percentage points -- positive
        means the bot beat simply buying and holding the instrument."""
        return self.bot_return_pct - self.benchmark_return_pct


def compute_benchmark_comparison(
    starting_equity: float,
    current_equity: float,
    benchmark_start_price: float,
    benchmark_current_price: float,
) -> BenchmarkComparison:
    """`benchmark_pnl`/`benchmark_return_pct` answer "what would `starting_equity` be
    worth today if it had bought and held the benchmark instrument instead" -- i.e. the
    same starting capital, not a fixed share count, so the comparison is apples-to-apples
    regardless of the instrument's price level."""
    if starting_equity <= 0:
        raise ValueError("starting_equity must be positive")
    if benchmark_start_price <= 0:
        raise ValueError("benchmark_start_price must be positive")

    bot_pnl = current_equity - starting_equity
    bot_return_pct = bot_pnl / starting_equity

    benchmark_return_pct = (benchmark_current_price - benchmark_start_price) / benchmark_start_price
    benchmark_pnl = starting_equity * benchmark_return_pct

    return BenchmarkComparison(
        bot_pnl=bot_pnl,
        bot_return_pct=bot_return_pct,
        benchmark_pnl=benchmark_pnl,
        benchmark_return_pct=benchmark_return_pct,
    )


def format_daily_report(symbol: str, comparison: BenchmarkComparison) -> str:
    verdict = "beat" if comparison.outperformance_pct >= 0 else "lagged"
    return (
        f"Bot: {comparison.bot_pnl:+,.2f} ({comparison.bot_return_pct:+.2%})\n"
        f"Buy & hold {symbol}: {comparison.benchmark_pnl:+,.2f} "
        f"({comparison.benchmark_return_pct:+.2%})\n"
        f"Bot {verdict} buy & hold by {abs(comparison.outperformance_pct):.2%}."
    )
