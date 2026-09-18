"""DASH-001: the dashboard never places, modifies, or cancels an order directly -- every
write path goes through RiskManager (lib/actions.py calls RiskManager methods only; it
may call read-only Broker methods like get_account()/get_positions(), but never an
order-mutating one).
"""

from __future__ import annotations

import re
from pathlib import Path

DASHBOARD_ROOT = Path(__file__).resolve().parents[2] / "dashboard"
FORBIDDEN_PATTERNS = [
    re.compile(r"\.submit_bracket_order\("),
    re.compile(r"\.cancel_all_orders\("),
    re.compile(r"\.cancel_order\("),
    re.compile(r"\.close_all_positions\("),
    re.compile(r"\.close_position\("),
]


def test_DASH_001_no_dashboard_file_calls_broker_order_methods_directly() -> None:
    offending: list[str] = []
    for path in DASHBOARD_ROOT.rglob("*.py"):
        text = path.read_text()
        for pattern in FORBIDDEN_PATTERNS:
            if pattern.search(text):
                offending.append(f"{path.relative_to(DASHBOARD_ROOT)}: {pattern.pattern}")

    assert offending == [], f"dashboard code calling broker order methods directly: {offending}"
