"""Dashboard entry point: `streamlit run dashboard/main.py`.

Sidebar chrome (PAPER/LIVE badge, feed/broker status, kill switch) lives here so it
persists across every page; each page's own content is in pages/*.py. The dashboard is
read-only except for the three controls below (kill switch here; pause/flatten on the
Live Monitor page) -- every one of them routes through RiskManager via lib/actions.py,
never a direct broker call from this package (CLAUDE.md).
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import streamlit as st  # noqa: E402
from lib import actions, theme  # noqa: E402

from intraday_trading.config import load_settings  # noqa: E402
from intraday_trading.killswitch.kill_switch import CONFIRMATION_PHRASE  # noqa: E402

st.set_page_config(page_title="Intraday Trading", page_icon="📈", layout="wide")
theme.apply()

settings = load_settings()

# DASH-003: local-only use needs no password (Streamlit binds to localhost by default);
# if a password is configured at all, require it before rendering anything else -- this
# is what "password if exposed" means in practice, since the app itself can't reliably
# detect its own bind address from inside a page script.
if settings.dashboard_password and not st.session_state.get("authenticated"):
    st.title("🔒 Sign in")
    entered = st.text_input("Password", type="password")
    if st.button("Sign in"):
        if entered == settings.dashboard_password:
            st.session_state["authenticated"] = True
            st.rerun()
        else:
            st.error("Wrong password.")
    st.stop()

pages = [
    st.Page("pages/live_monitor.py", title="Live Monitor", icon="🟢", default=True),
    st.Page("pages/validation_report.py", title="Validation Report", icon="🧪"),
    st.Page("pages/paper_vs_backtest.py", title="Paper vs Backtest", icon="⚖️"),
    st.Page("pages/journal_go_live.py", title="Journal & Go-Live", icon="🚀"),
]

with st.sidebar:
    if settings.live_trading:
        st.error("🔴 LIVE", icon="🔴")
    else:
        st.success("🟢 PAPER", icon="🟢")

    st.caption(f"Data feed: **{settings.alpaca_data_feed.value.upper()}**")

    snapshot = actions.load_live_snapshot(settings)
    if snapshot.error:
        st.error("Broker: unreachable", icon="⚠️")
        with st.expander("Details"):
            st.code(snapshot.error)
    else:
        st.success("Broker: connected", icon="✅")

    st.divider()
    st.markdown("#### Kill switch")
    st.caption("Cancels every order and flattens every position, immediately.")
    typed = st.text_input("Type to confirm", key="kill_confirm", placeholder=CONFIRMATION_PHRASE)
    if st.button("🛑 KILL SWITCH", type="primary", width="stretch"):
        if typed == CONFIRMATION_PHRASE:
            try:
                actions.trip_kill_switch(settings)
                st.success("Kill switch tripped.")
            except Exception as exc:  # broker unreachable, etc. -- never crash the page
                st.error(f"Kill switch call failed: {exc}")
        else:
            st.error(f"Type '{CONFIRMATION_PHRASE}' exactly to confirm.")

nav = st.navigation(pages)
nav.run()
