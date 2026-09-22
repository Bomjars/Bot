"""Page 0: Getting Started. A welcome/onboarding page for a first-time user -- setup
checklist, copy-paste commands, and links to the other pages. Read-only, like every
other page (CLAUDE.md): it only checks `Settings` (which redacts secrets) and calls the
same `actions.load_live_snapshot` the sidebar already uses, never anything that reads or
prints `.env` itself.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import streamlit as st  # noqa: E402
from lib import actions, data, theme  # noqa: E402

from intraday_trading.config import load_settings  # noqa: E402

theme.apply()
settings = load_settings()

st.title("👋 Getting Started")

st.markdown(
    "This dashboard controls an **automated intraday trading system** for a paper "
    "(simulated-money) Alpaca account. It is **paper trading only** -- nothing here can "
    "place a real order until the go-live checklist on the Journal & Go-Live page is "
    "fully met, and even then, going live requires an explicit `.env` confirmation "
    "outside this dashboard (see `CLAUDE.md`)."
)

if settings.live_trading:
    st.error("🔴 LIVE_TRADING=true is set -- this build still refuses to place live orders.")
else:
    st.success("🟢 Paper trading only (LIVE_TRADING=false).")

st.subheader("Setup checklist")
with st.container(border=True):
    keys_configured = bool(settings.alpaca_api_key) and bool(settings.alpaca_secret_key)
    snapshot = actions.load_live_snapshot(settings)
    broker_reachable = snapshot.error is None
    has_strategies = bool(data.known_strategies(settings.database_path))
    has_orders = data.count_paper_days(settings.database_path) > 0

    checklist = [
        ("Alpaca paper API keys set in `.env`", keys_configured),
        ("Broker reachable", broker_reachable),
        ("A strategy has logged backtest trials", has_strategies),
        ("At least one order logged (paper trading has run)", has_orders),
    ]
    for label, met in checklist:
        st.write(f"{'✅' if met else '⬜'} {label}")

    if not keys_configured:
        st.caption(
            "Copy `.env.example` to `.env` and fill in your Alpaca **paper** keys -- "
            "never the live ones (see the README)."
        )
    if keys_configured and not broker_reachable:
        st.caption(f"Broker call failed: {snapshot.error}")

st.subheader("Try it with demo data")
with st.container(border=True):
    st.markdown(
        "Every other page is an honest empty state until a real backtest and some paper "
        "trading history exist. To see what a populated dashboard looks like first, seed "
        "a separate, clearly-fake demo database -- every number in it is synthetic "
        "(`numpy.random`, see `dev/demo_data.py`), and the command refuses to touch your "
        "real `DATABASE_PATH`."
    )
    st.code(
        "uv run intraday-trading seed-demo-data\n"
        '$env:DATABASE_PATH = "data\\demo.db"; uv run streamlit run dashboard\\main.py',
        language="powershell",
    )

st.subheader("Run the real thing")
with st.container(border=True):
    st.markdown("**Check your setup:**")
    st.code("uv run intraday-trading status", language="powershell")
    st.markdown("**Run the test suite:**")
    st.code("uv run pytest", language="powershell")
    st.markdown(
        "**Run the SPY momentum strategy's parameter grid** against real historical "
        "data (needs real Alpaca paper keys and network access):"
    )
    st.code(
        "uv run intraday-trading backtest spy --start 2015-01-01 --end 2024-05-01",
        language="powershell",
    )
    st.markdown("**Start paper trading:**")
    st.code("uv run intraday-trading run-paper --symbols SPY", language="powershell")

st.subheader("Where to go next")
with st.container(border=True):
    st.page_link(
        "pages/live_monitor.py",
        label="Live Monitor -- what's happening right now",
        icon="🟢",
    )
    st.page_link(
        "pages/validation_report.py",
        label="Validation Report -- is a strategy's backtest trustworthy?",
        icon="🧪",
    )
    st.page_link(
        "pages/paper_vs_backtest.py",
        label="Paper vs Backtest -- does live trading match the backtest?",
        icon="⚖️",
    )
    st.page_link(
        "pages/journal_go_live.py",
        label="Journal & Go-Live -- trade history and the go-live checklist",
        icon="🚀",
    )
