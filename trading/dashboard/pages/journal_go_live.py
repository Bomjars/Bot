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
from lib import actions, data, theme  # noqa: E402

from intraday_trading.config import load_settings  # noqa: E402
from intraday_trading.golive.gate import evaluate_go_live_gate  # noqa: E402

theme.apply()
settings = load_settings()

st.title("Journal & Go-Live")

st.subheader("Trade journal")
with st.container(border=True):
    orders = data.load_recent_orders(settings.database_path, limit=500)
    if not orders:
        st.write("No trades yet.")
    else:
        symbol_filter = st.selectbox(
            "Filter by symbol", ["All"] + sorted({o["symbol"] for o in orders})
        )
        rows = (
            orders
            if symbol_filter == "All"
            else [o for o in orders if o["symbol"] == symbol_filter]
        )
        st.dataframe(rows, width="stretch", hide_index=True)
        st.caption(
            "R multiple and exit reason aren't shown yet -- they need exit/fill data this "
            "build doesn't persist yet (see docs/PLAN.md). Candlestick replay of a selected "
            "trade needs the same data and is not available for the same reason."
        )

st.subheader("Go-live checklist")

strategies = data.known_strategies(settings.database_path)
verdict = evaluate_go_live_gate(
    settings.database_path,
    strategies,
    live_equity_cap_gbp=settings.live_equity_cap_gbp,
    min_paper_days=settings.go_live_min_paper_days,
    max_errors_lookback_days=settings.go_live_max_errors_lookback_days,
)

with st.container(border=True):
    met_count = sum(1 for check in verdict.checks if check.met)
    st.progress(
        met_count / len(verdict.checks),
        text=f"{met_count} of {len(verdict.checks)} checklist items met",
    )

    for check in verdict.checks:
        icon = "✅" if check.met else "⬜"
        st.write(f"{icon} **{check.name}**")
        st.caption(check.detail)

    col1, col2 = st.columns(2)
    with col1:
        if st.button("Mark kill switch tested", width="stretch"):
            actions.mark_kill_switch_tested(settings)
            st.rerun()
    with col2:
        if st.button("Mark reconciliation tested", width="stretch"):
            actions.mark_reconciliation_tested(settings)
            st.rerun()
    st.caption(
        "Only click these after you've actually run the drill in paper -- nothing else "
        "verifies that you did."
    )

    st.button(
        "🚀 GO LIVE",
        disabled=not verdict.all_met,
        type="primary",
        help="Locked until every checklist item above is met." if not verdict.all_met else None,
    )
