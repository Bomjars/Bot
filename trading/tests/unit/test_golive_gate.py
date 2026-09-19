from __future__ import annotations

from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd
import pytest
from pydantic import ValidationError

from intraday_trading.broker.base import OrderInfo, Side
from intraday_trading.config import Settings
from intraday_trading.golive.gate import MIN_DAYS_FOR_CSCV, evaluate_go_live_gate
from intraday_trading.risk.signals import EntrySignal
from intraday_trading.storage.error_log import ErrorLog
from intraday_trading.storage.go_live_checklist_store import GoLiveChecklistStore
from intraday_trading.storage.order_log import OrderLog
from intraday_trading.validation.registry import TrialRegistry


def _signal(symbol: str = "AAPL") -> EntrySignal:
    return EntrySignal(
        strategy="orb",
        symbol=symbol,
        side=Side.BUY,
        qty=10,
        entry_price=100.0,
        stop_price=95.0,
        take_profit_price=None,
        current_price=100.0,
        avg_dollar_volume=10_000_000.0,
        spread_pct=0.001,
        signal_seq="seq-1",
    )


def test_GOLIVE_001_GOLIVE_002_GOLIVE_003_GOLIVE_004_GOLIVE_005_fresh_db_fails_every_check(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "golive.db"
    verdict = evaluate_go_live_gate(db_path, strategies=["orb"], live_equity_cap_gbp=3_000.0)

    assert verdict.all_met is False
    by_name = {c.name: c for c in verdict.checks}
    assert by_name["Validation and holdout passed"].met is False
    assert any("paper-trading days" in name for name in by_name)
    assert by_name["Kill switch tested"].met is False
    assert by_name["Reconciliation tested"].met is False
    # the cap-configuration check CAN pass on a fresh DB -- it's a config sanity check,
    # not data-dependent, so it's the one legitimately-met item here
    assert by_name["Live equity cap configured at <= £3,000"].met is True


def test_GOLIVE_001_validation_check_never_fully_passes_without_holdout(tmp_path: Path) -> None:
    db_path = tmp_path / "golive.db"
    rng = np.random.default_rng(1)
    dates = pd.date_range(start=date(2024, 1, 2), periods=MIN_DAYS_FOR_CSCV, freq="B")
    registry = TrialRegistry(db_path)
    for i in range(3):
        values = rng.normal(0, 1, size=MIN_DAYS_FOR_CSCV) + (2.0 if i == 0 else 0.0)
        registry.log_trial("orb", {"x": i}, pd.Series(values, index=dates))

    verdict = evaluate_go_live_gate(db_path, strategies=["orb"], live_equity_cap_gbp=3_000.0)

    check = next(c for c in verdict.checks if c.name == "Validation and holdout passed")
    # Even with a strong enough injected edge that CSCV/PBO genuinely passes, this check
    # still can't be fully met, because holdout validation isn't implemented yet.
    assert check.met is False
    assert "1/1 strategy(s) pass CSCV/PBO: orb" in check.detail
    assert "Holdout validation isn't implemented" in check.detail


def test_GOLIVE_006_live_cap_check_fails_above_threshold(tmp_path: Path) -> None:
    verdict = evaluate_go_live_gate(
        tmp_path / "golive.db", strategies=[], live_equity_cap_gbp=5_000.0
    )
    check = next(c for c in verdict.checks if "Live equity cap" in c.name)
    assert check.met is False


def test_GOLIVE_003_error_check_fails_with_recent_errors(tmp_path: Path) -> None:
    db_path = tmp_path / "golive.db"
    ErrorLog(db_path).log("something broke")

    verdict = evaluate_go_live_gate(db_path, strategies=[], live_equity_cap_gbp=3_000.0)

    check = next(c for c in verdict.checks if "unhandled errors" in c.name)
    assert check.met is False
    assert "1 error" in check.detail


def test_GOLIVE_004_kill_switch_and_reconciliation_checks_pass_once_marked(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "golive.db"
    store = GoLiveChecklistStore(db_path)
    store.mark_kill_switch_tested()
    store.mark_reconciliation_tested()

    verdict = evaluate_go_live_gate(db_path, strategies=[], live_equity_cap_gbp=3_000.0)

    assert next(c for c in verdict.checks if c.name == "Kill switch tested").met is True
    assert next(c for c in verdict.checks if c.name == "Reconciliation tested").met is True


def test_GOLIVE_002_paper_days_check_reflects_real_order_count(tmp_path: Path) -> None:
    db_path = tmp_path / "golive.db"
    order_log = OrderLog(db_path)
    order_log.log(_signal(), OrderInfo("b1", "c1", "AAPL", Side.BUY, 10, "filled", 10, 100.0))

    verdict = evaluate_go_live_gate(
        db_path, strategies=[], live_equity_cap_gbp=3_000.0, min_paper_days=30
    )

    check = next(c for c in verdict.checks if "paper-trading days" in c.name)
    assert "1/30" in check.detail
    assert check.met is False  # band comparison still not implemented, even at 30+ days


def test_GOLIVE_005_passing_checklist_items_does_not_bypass_live_trading_confirmation(
    tmp_path: Path,
) -> None:
    """The go-live gate and the SAFE-002/003 confirmation requirement are deliberately
    independent: nothing in Settings reads `evaluate_go_live_gate`'s verdict, so even
    marking every human-gated checklist item as done cannot substitute for the exact
    confirmation string when flipping `live_trading`."""
    db_path = tmp_path / "golive.db"
    store = GoLiveChecklistStore(db_path)
    store.mark_kill_switch_tested()
    store.mark_reconciliation_tested()

    with pytest.raises(ValidationError, match="LIVE_TRADING_CONFIRMATION"):
        Settings(
            alpaca_api_key="fake",
            alpaca_secret_key="fake",
            database_path=db_path,
            live_trading=True,
        )


def test_all_met_is_false_unless_every_check_passes(tmp_path: Path) -> None:
    db_path = tmp_path / "golive.db"
    store = GoLiveChecklistStore(db_path)
    store.mark_kill_switch_tested()
    store.mark_reconciliation_tested()

    verdict = evaluate_go_live_gate(db_path, strategies=[], live_equity_cap_gbp=3_000.0)

    assert verdict.all_met is False  # validation/paper-days/errors checks still unmet
