"""The go-live gate: every check from docs/GO_LIVE_CHECKLIST.md, computed from real
data or explicitly marked not-yet-verifiable -- never guessed. This is the single
implementation of what "ready to go live" means; the dashboard's Journal & Go-Live page
and the CLI's `golive status` command both call it rather than duplicating the logic.

Passing CSCV/PBO for a strategy (steps 6-7) is necessary but not sufficient: holdout
validation and the paper-vs-backtest expected-band comparison aren't implemented yet
(see docs/PLAN.md), so the two checks that depend on them can never fully pass today --
that's the honest, correct state for a system that has never placed a live trade.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from intraday_trading.storage.error_log import ErrorLog
from intraday_trading.storage.go_live_checklist_store import GoLiveChecklistStore
from intraday_trading.storage.order_log import OrderLog
from intraday_trading.validation.cscv import cscv_pbo, evaluate
from intraday_trading.validation.registry import TrialRegistry

MIN_DAYS_FOR_CSCV = 32  # divides evenly into 16 blocks of >= 2 days each
MAX_LIVE_EQUITY_CAP_GBP = 3_000.0


@dataclass(frozen=True)
class GoLiveCheck:
    name: str
    met: bool
    detail: str


@dataclass(frozen=True)
class GoLiveVerdict:
    checks: list[GoLiveCheck]

    @property
    def all_met(self) -> bool:
        return all(check.met for check in self.checks)


def _validation_check(database_path: Path, strategies: list[str]) -> GoLiveCheck:
    if not strategies:
        return GoLiveCheck("Validation and holdout passed", False, "No strategy specified.")

    registry = TrialRegistry(database_path)
    passing: list[str] = []
    for strategy in strategies:
        matrix = registry.daily_pnl_matrix(strategy)
        if matrix.empty or len(matrix) < MIN_DAYS_FOR_CSCV or matrix.shape[1] < 2:
            continue
        if evaluate(cscv_pbo(matrix.fillna(0.0))).passed:
            passing.append(strategy)

    return GoLiveCheck(
        "Validation and holdout passed",
        False,  # holdout validation isn't implemented yet -- see module docstring
        f"{len(passing)}/{len(strategies)} strategy(s) pass CSCV/PBO: "
        f"{', '.join(passing) or 'none'}. Holdout validation isn't implemented yet, so "
        "this can never fully pass today.",
    )


def _paper_days_check(database_path: Path, min_days: int) -> GoLiveCheck:
    days = OrderLog(database_path).count_distinct_days()
    return GoLiveCheck(
        f">= {min_days} paper-trading days within the expected band, slippage measured",
        False,  # the expected-band/slippage comparison isn't implemented yet
        f"{days}/{min_days} days recorded. The expected-band and slippage comparison "
        "against the backtest isn't implemented yet, so this can never fully pass "
        "today even once the day count alone is met.",
    )


def _no_unhandled_errors_check(database_path: Path, lookback_days: int) -> GoLiveCheck:
    count = ErrorLog(database_path).count_last_days(lookback_days)
    return GoLiveCheck(
        f"No unhandled errors in the last {lookback_days} days",
        count == 0,
        f"{count} error(s) logged in the last {lookback_days} days.",
    )


def _kill_switch_tested_check(database_path: Path) -> GoLiveCheck:
    state = GoLiveChecklistStore(database_path).load()
    return GoLiveCheck(
        "Kill switch tested",
        state.kill_switch_tested_at is not None,
        f"Last tested: {state.kill_switch_tested_at or 'never'}.",
    )


def _reconciliation_tested_check(database_path: Path) -> GoLiveCheck:
    state = GoLiveChecklistStore(database_path).load()
    return GoLiveCheck(
        "Reconciliation tested",
        state.reconciliation_tested_at is not None,
        f"Last tested: {state.reconciliation_tested_at or 'never'}.",
    )


def _live_cap_configured_check(live_equity_cap_gbp: float) -> GoLiveCheck:
    met = 0 < live_equity_cap_gbp <= MAX_LIVE_EQUITY_CAP_GBP
    return GoLiveCheck(
        f"Live equity cap configured at <= £{MAX_LIVE_EQUITY_CAP_GBP:,.0f}",
        met,
        f"live_equity_cap_gbp = £{live_equity_cap_gbp:,.0f}.",
    )


def evaluate_go_live_gate(
    database_path: Path,
    strategies: list[str],
    live_equity_cap_gbp: float,
    min_paper_days: int = 30,
    max_errors_lookback_days: int = 14,
) -> GoLiveVerdict:
    return GoLiveVerdict(
        checks=[
            _validation_check(database_path, strategies),
            _paper_days_check(database_path, min_paper_days),
            _no_unhandled_errors_check(database_path, max_errors_lookback_days),
            _kill_switch_tested_check(database_path),
            _reconciliation_tested_check(database_path),
            _live_cap_configured_check(live_equity_cap_gbp),
        ]
    )
