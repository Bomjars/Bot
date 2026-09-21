"""Page 3: Paper vs Backtest. Needs paper-trading history and a stored backtest
expectation band, neither of which exist yet -- this system hasn't traded a single
paper day. Structure is real; the numbers are honest zeros until step 8's loop has
actually run for a while.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import streamlit as st  # noqa: E402
from lib import data, theme  # noqa: E402

from intraday_trading.config import load_settings  # noqa: E402

theme.apply()
settings = load_settings()

st.title("Paper vs Backtest")

paper_days = data.count_paper_days(settings.database_path)
orders = data.load_recent_orders(settings.database_path, limit=10_000)
paper_pnl_note = "not available yet — needs fills/exits persisted, see docs/PLAN.md"

with st.container(border=True):
    kpi_cols = st.columns(4)
    kpi_cols[0].metric(
        "Paper days",
        f"{paper_days}/30",
        help="Distinct calendar dates with at least one order logged. 30 is the "
        "minimum before go-live is considered.",
    )
    kpi_cols[1].metric("Paper P&L", "n/a")
    kpi_cols[2].metric(
        "Expected 90% band",
        "n/a",
        help="The range of daily P&L the backtest would predict with 90% confidence -- "
        "paper trading falling far outside it is a warning sign, not just a curiosity.",
    )
    kpi_cols[3].metric(
        "Measured slippage",
        "n/a",
        help="Real fill price vs. the price the strategy expected, per trade -- checks "
        "whether the backtest's cost assumptions hold up live.",
    )
    st.caption(
        "How to read this: paper days counts distinct dates with at least one order "
        "logged; the other three KPIs need exit/fill data this build doesn't persist yet."
    )

st.subheader("Paper P&L vs expected band")
with st.container(border=True):
    if paper_days == 0:
        st.info("No paper-trading days recorded yet.")
    else:
        st.info(paper_pnl_note)

st.subheader("Slippage per trade vs assumed")
with st.container(border=True):
    st.info(paper_pnl_note)

st.subheader("Weekly summary")
with st.container(border=True):
    if not orders:
        st.write("No orders logged yet.")
    else:
        st.dataframe(orders, width="stretch", hide_index=True)
