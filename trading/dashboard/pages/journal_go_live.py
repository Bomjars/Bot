"""Page 4: Journal & Go-Live. The trade list is real (from the orders table); R-multiple,
exit reason, and the candlestick replay all need exit/fill data this build doesn't
persist yet. The go-live checklist checks whatever is actually verifiable today and is
honest about the rest -- the GO LIVE button is disabled unless every item is met, and
right now none of them are, which is the correct state for a system that has never
placed a single paper trade.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import streamlit as st  # noqa: E402
from lib import data, theme  # noqa: E402

from intraday_trading.config import load_settings  # noqa: E402
from intraday_trading.validation.cscv import cscv_pbo, evaluate  # noqa: E402
from intraday_trading.validation.registry import TrialRegistry  # noqa: E402

theme.apply()
settings = load_settings()

st.title("Journal & Go-Live")

st.subheader("Trade journal")
orders = data.load_recent_orders(settings.database_path, limit=500)
if not orders:
    st.write("No trades yet.")
else:
    symbol_filter = st.selectbox(
        "Filter by symbol", ["All"] + sorted({o["symbol"] for o in orders})
    )
    rows = orders if symbol_filter == "All" else [o for o in orders if o["symbol"] == symbol_filter]
    st.dataframe(rows, width="stretch", hide_index=True)
    st.caption(
        "R multiple and exit reason aren't shown yet -- they need exit/fill data this "
        "build doesn't persist yet (see docs/PLAN.md). Candlestick replay of a selected "
        "trade needs the same data and is not available for the same reason."
    )

st.divider()
st.subheader("Go-live checklist")

strategies = data.known_strategies(settings.database_path)
validated_strategies = []
for strategy in strategies:
    registry = TrialRegistry(settings.database_path)
    matrix = registry.daily_pnl_matrix(strategy)
    if matrix.empty or len(matrix) < 32 or matrix.shape[1] < 2:
        continue
    if evaluate(cscv_pbo(matrix.fillna(0.0))).passed:
        validated_strategies.append(strategy)

checks = [
    (
        "Validation and holdout passed for at least one strategy",
        len(validated_strategies) > 0,
        f"{len(validated_strategies)} strategy(s) passing: "
        f"{', '.join(validated_strategies) or 'none'}. Holdout validation isn't "
        "implemented yet, so this can never fully pass today.",
    ),
    (
        "≥ 30 paper-trading days within the expected band",
        False,
        "Paper-day counting exists (Page 3); the expected-band comparison doesn't yet.",
    ),
    (
        "No unhandled errors in the last 2 weeks",
        False,
        "Not tracked yet -- no persisted error log to check against.",
    ),
    (
        "Kill switch and reconciliation tested",
        False,
        "Not tracked yet -- no record of a deliberate kill-switch/reconciliation drill.",
    ),
]

met_count = sum(1 for _, met, _ in checks if met)
st.progress(met_count / len(checks), text=f"{met_count} of {len(checks)} checklist items met")

for label, met, note in checks:
    icon = "✅" if met else "⬜"
    st.write(f"{icon} **{label}**")
    st.caption(note)

all_met = met_count == len(checks)
st.button(
    "🚀 GO LIVE",
    disabled=not all_met,
    type="primary",
    help="Locked until every checklist item above is met." if not all_met else None,
)
