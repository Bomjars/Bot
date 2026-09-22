"""Page 1: Live Monitor. Auto-refreshes every 8s. Read-only except Pause entries and
per-position Flatten, both routed through RiskManager (lib/actions.py).
"""

from __future__ import annotations

import sys
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import plotly.graph_objects as go  # noqa: E402
import streamlit as st  # noqa: E402
from lib import actions, data, format, theme  # noqa: E402
from streamlit_autorefresh import st_autorefresh  # noqa: E402

from intraday_trading.config import load_settings  # noqa: E402
from intraday_trading.session.calendar import EXCHANGE_TZ, ExchangeCalendar  # noqa: E402
from intraday_trading.session.clock import SessionClock  # noqa: E402

theme.apply()
settings = load_settings()
st_autorefresh(interval=8_000, key="live_monitor_refresh")

st.title("Live Monitor")

with st.expander("What do these terms mean?"):
    st.markdown(
        "- **HALTED** — the RiskManager (the only code allowed to place orders) has "
        "stopped trading because a hard risk limit was breached; it will not resume "
        "until re-enabled below.\n"
        "- **STALE** — the dashboard couldn't reach the broker just now, so figures on "
        "this page may be a little out of date. Trading itself isn't necessarily "
        "affected.\n"
        "- **Drawdown from peak** — how far current account equity has fallen from its "
        "highest-ever point, as a percentage.\n"
        "- **Flatten** — close a position immediately at the market price.\n"
        "- **Pause entries** — stop opening *new* positions; existing ones are left "
        "alone (they still get flattened/stopped as normal)."
    )

risk_state = data.load_risk_state(settings.database_path)
snapshot = actions.load_live_snapshot(settings)

# --- State banner -----------------------------------------------------------
if risk_state.halted:
    st.error(
        f"HALTED — {risk_state.halt_type.value}: {risk_state.halt_reason or 'no reason recorded'}"
    )
elif snapshot.error:
    st.warning("STALE — broker unreachable, figures below may be out of date")
else:
    st.success("RUNNING")

st.caption(
    "How to read this: green means running normally; amber/red banners need attention "
    "before anything else on this page."
)

# --- Risk gauges --------------------------------------------------------------
st.subheader("Risk limits")
risk_card = st.container(border=True)
current_equity = snapshot.account.equity if snapshot.account else None


def _gauge(title: str, value: float, limit: float, suffix: str = "") -> go.Figure:
    pct_used = 0.0 if limit == 0 else min(abs(value) / abs(limit), 1.5)
    fig = go.Figure(
        go.Indicator(
            mode="gauge+number",
            value=value,
            number={"suffix": suffix},
            title={"text": title},
            gauge={
                "axis": {"range": [0, limit]},
                "bar": {"color": theme.gauge_color(pct_used)},
            },
        )
    )
    fig.update_layout(height=180, margin={"l": 20, "r": 20, "t": 40, "b": 10})
    return fig


gauge_cols = risk_card.columns(5)

if current_equity and risk_state.daily_starting_equity:
    daily_loss_pct = max(
        0.0, -(current_equity - risk_state.daily_starting_equity) / risk_state.daily_starting_equity
    )
else:
    daily_loss_pct = 0.0
with gauge_cols[0]:
    st.plotly_chart(
        _gauge("Daily loss", daily_loss_pct, settings.risk.daily_loss_limit_pct, suffix=""),
        width="stretch",
    )

if current_equity and risk_state.weekly_starting_equity:
    weekly_loss_pct = max(
        0.0,
        -(current_equity - risk_state.weekly_starting_equity) / risk_state.weekly_starting_equity,
    )
else:
    weekly_loss_pct = 0.0
with gauge_cols[1]:
    st.plotly_chart(
        _gauge("Weekly loss", weekly_loss_pct, settings.risk.weekly_loss_limit_pct),
        width="stretch",
    )

if current_equity and risk_state.peak_equity:
    drawdown_pct = max(0.0, (risk_state.peak_equity - current_equity) / risk_state.peak_equity)
else:
    drawdown_pct = 0.0
with gauge_cols[2]:
    st.plotly_chart(
        _gauge("Drawdown from peak", drawdown_pct, settings.risk.drawdown_circuit_breaker_pct),
        width="stretch",
    )

with gauge_cols[3]:
    st.plotly_chart(
        _gauge("Open positions", len(snapshot.positions), settings.risk.max_open_positions),
        width="stretch",
    )

with gauge_cols[4]:
    st.plotly_chart(
        _gauge("Trades today", risk_state.trades_today, settings.risk.max_trades_per_day),
        width="stretch",
    )

st.caption("How to read this: green under 70% of the limit, amber 70-90%, red at 90%+.")

# --- Equity vs SPY ------------------------------------------------------------
st.subheader("Intraday equity vs SPY")
with st.container(border=True):
    st.info(
        "No equity history recorded yet — this fills in once the paper-trading loop has "
        "run for at least one session. See docs/PLAN.md."
    )

# --- Session schedule (UK time) ----------------------------------------------
st.subheader("Session schedule (UK time)")
with st.container(border=True):
    calendar = ExchangeCalendar()
    now_et = datetime.now(tz=EXCHANGE_TZ)
    session = calendar.session_for_date(now_et.date())
    if session is None:
        st.write("No trading session today.")
    else:
        no_entry_until = session.open + timedelta(minutes=settings.risk.no_entry_first_minutes)
        flatten_from = session.close - timedelta(minutes=settings.risk.flatten_before_close_minutes)
        schedule_cols = st.columns(4)
        schedule_cols[0].metric(
            "Open", SessionClock.to_display_timezone(session.open).strftime("%H:%M")
        )
        schedule_cols[1].metric(
            "No entries until", SessionClock.to_display_timezone(no_entry_until).strftime("%H:%M")
        )
        schedule_cols[2].metric(
            "Flatten from", SessionClock.to_display_timezone(flatten_from).strftime("%H:%M")
        )
        schedule_cols[3].metric(
            "Close", SessionClock.to_display_timezone(session.close).strftime("%H:%M")
        )

# --- Controls -----------------------------------------------------------------
st.subheader("Controls")
with st.container(border=True):
    control_cols = st.columns(2)
    with control_cols[0]:
        if risk_state.halted:
            if st.button("▶️ Re-enable trading", width="stretch"):
                actions.re_enable(settings)
                st.rerun()
        else:
            if st.button("⏸️ Pause entries", width="stretch"):
                actions.pause_entries(settings)
                st.rerun()

# --- Open positions -------------------------------------------------------------
st.subheader("Open positions")
with st.container(border=True):
    records_by_symbol = {
        r.symbol: r for r in data.load_open_position_records(settings.database_path)
    }
    if not snapshot.positions:
        st.write("No open positions.")
    else:
        for position in snapshot.positions:
            record = records_by_symbol.get(position.symbol)
            cols = st.columns([1, 1, 1, 1, 1, 1, 1])
            cols[0].write(f"**{position.symbol}**")
            cols[1].write(f"entry {format.money(position.avg_entry_price)}")
            cols[2].write(f"last {format.money(position.current_price)}")
            cols[3].write(f"stop {format.money(record.stop_price) if record else '—'}")
            cols[4].write(f"P&L {format.money(position.unrealized_pl)}")
            held = format.since(record.opened_at) if record else "—"
            cols[5].write(f"since {held}")
            if cols[6].button("Flatten", key=f"flatten_{position.symbol}"):
                actions.flatten_one(settings, position.symbol)
                st.rerun()

# --- Signal confidence (backtest-derived) --------------------------------------
st.subheader("Signal confidence")
with st.container(border=True):
    known_strategies = data.known_strategies(settings.database_path)
    confidence_tables = {
        s: data.load_signal_confidence_table(settings.database_path, s) for s in known_strategies
    }
    if not known_strategies:
        st.info(
            "No strategy has logged any trials yet -- this fills in once a backtest has "
            "been run (see the Validation Report page)."
        )
    else:
        st.caption(
            "Backtested win rate by breakout strength, from each strategy's logged "
            "closed trades -- a historical statistic, not a guarantee for the next "
            "signal of similar strength (published/backtested edges shrink "
            "out-of-sample; McLean & Pontiff, 2016)."
        )
        for strategy_name, table in confidence_tables.items():
            n_total = sum(b.n for b in table.buckets)
            if n_total == 0:
                continue
            st.write(f"**{strategy_name}**")
            rows = [
                {
                    "breakout strength": (
                        f"{b.low:.2f} - {'∞' if b.high == float('inf') else f'{b.high:.2f}'}"
                    ),
                    "trades": b.n,
                    "win rate": f"{b.win_rate:.0%}" if b.win_rate is not None else "n/a",
                }
                for b in table.buckets
            ]
            st.dataframe(rows, width="stretch", hide_index=True)
        if all(sum(b.n for b in t.buckets) == 0 for t in confidence_tables.values()):
            st.info("No closed trades logged yet for any known strategy.")

# --- Activity feed --------------------------------------------------------------
st.subheader("Activity feed")
orders = data.load_recent_orders(settings.database_path, limit=20)
rejections = data.load_recent_rejections(settings.database_path, limit=20)


def _order_detail(order: dict[str, object]) -> str:
    detail = f"{order['side']} {order['qty']} {order['symbol']}"
    strength = order.get("signal_strength")
    if strength is None:
        return detail
    table = confidence_tables.get(str(order["strategy"]))
    bucket = table.lookup(float(strength)) if table is not None else None
    if bucket is None or bucket.win_rate is None:
        return f"{detail} (strength {float(strength):.2f})"
    return (
        f"{detail} (strength {float(strength):.2f}, backtested win rate "
        f"{bucket.win_rate:.0%}, n={bucket.n})"
    )


feed = sorted(
    [{"ts": o["ts"], "kind": "order", "detail": _order_detail(o)} for o in orders]
    + [
        {"ts": r["ts"], "kind": "rejection", "detail": f"{r['symbol']}: {r['reason']}"}
        for r in rejections
    ],
    key=lambda row: row["ts"],
    reverse=True,
)[:20]
with st.container(border=True):
    if not feed:
        st.write("No activity yet.")
    else:
        st.dataframe(feed, width="stretch", hide_index=True)
        st.caption(
            "A signal's 'backtested win rate' (when shown) is this strategy's historical "
            "win rate for breakout signals of similar strength -- not a live guarantee."
        )
