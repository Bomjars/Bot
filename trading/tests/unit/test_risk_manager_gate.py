"""RISK-021: RiskManager is the only production code path allowed to call the broker's
order-placement method. A strategy, the sizer, or anything else calling
`broker.submit_bracket_order(...)` directly would bypass every check in RiskManager.
"""

from __future__ import annotations

import re
from pathlib import Path

SRC_ROOT = Path(__file__).resolve().parents[2] / "src" / "intraday_trading"
CALL_PATTERN = re.compile(r"\.submit_bracket_order\(")
ALLOWED_CALLERS = {SRC_ROOT / "risk" / "risk_manager.py"}


def test_RISK_021_only_risk_manager_calls_submit_bracket_order() -> None:
    offending: list[str] = []
    for path in SRC_ROOT.rglob("*.py"):
        if path in ALLOWED_CALLERS:
            continue
        text = path.read_text()
        if CALL_PATTERN.search(text):
            offending.append(str(path.relative_to(SRC_ROOT)))

    assert offending == [], f"submit_bracket_order called outside RiskManager in: {offending}"
