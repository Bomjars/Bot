"""Dark, card-based "fintech" theme: CSS injected once from every page via `apply()`,
plus a matching Plotly template so charts read as part of the same system rather than
Streamlit's defaults. Deliberately CSS-only against Streamlit's stable, documented
`data-testid` hooks (metrics, alerts, buttons, tabs, dataframes, bordered containers) --
no page's Python logic, text, or component structure changes here, so every existing
dashboard test (which asserts on those exact values) keeps passing untouched.
"""

from __future__ import annotations

import plotly.graph_objects as go
import plotly.io as pio
import streamlit as st

# --- Palette ------------------------------------------------------------------
BACKGROUND = "#0a0b10"
SURFACE = "#14161f"
SURFACE_RAISED = "#1a1d29"
BORDER = "rgba(255, 255, 255, 0.08)"
TEXT = "#f2f3f7"
MUTED = "#8b93a7"
GREEN = "#22c55e"
AMBER = "#f59e0b"
RED = "#ef4444"
ACCENT = "#6366f1"

_TEMPLATE_NAME = "intraday_dark"
_FONT = "'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"


def apply() -> None:
    st.markdown(
        f"""
        <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');

        html, body, .stApp, [class*="css"] {{
            font-family: {_FONT};
        }}
        .stApp {{
            background-color: {BACKGROUND};
            color: {TEXT};
        }}

        /* Sidebar */
        [data-testid="stSidebar"] {{
            background-color: {SURFACE};
            border-right: 1px solid {BORDER};
        }}
        [data-testid="stSidebar"] .stMarkdown h4 {{
            color: {MUTED};
            text-transform: uppercase;
            font-size: 0.75rem;
            letter-spacing: 0.06em;
        }}

        /* Headings */
        h1, h2, h3 {{ font-weight: 700; letter-spacing: -0.01em; }}
        h1 {{ font-size: 1.9rem; }}

        /* Metrics -> stat cards */
        [data-testid="stMetric"] {{
            background: {SURFACE_RAISED};
            border: 1px solid {BORDER};
            border-radius: 14px;
            padding: 1rem 1.1rem;
            box-shadow: 0 1px 2px rgba(0,0,0,0.4), 0 8px 24px rgba(0,0,0,0.25);
        }}
        [data-testid="stMetricLabel"] {{
            color: {MUTED};
            font-size: 0.78rem;
            text-transform: uppercase;
            letter-spacing: 0.04em;
        }}
        [data-testid="stMetricValue"] {{
            font-weight: 700;
            font-size: 1.6rem;
            color: {TEXT};
        }}

        /* Bordered containers -> cards */
        div[data-testid="stVerticalBlockBorderWrapper"] {{
            background: {SURFACE_RAISED};
            border: 1px solid {BORDER};
            border-radius: 16px;
            padding: 0.25rem 0.25rem;
            box-shadow: 0 1px 2px rgba(0,0,0,0.4), 0 8px 24px rgba(0,0,0,0.25);
        }}

        /* Alerts (success/error/warning/info) -> status cards */
        [data-testid="stAlert"] {{
            border-radius: 12px;
            border: 1px solid {BORDER};
            font-weight: 500;
        }}

        /* Buttons */
        .stButton > button {{
            border-radius: 10px;
            border: 1px solid {BORDER};
            background: {SURFACE_RAISED};
            color: {TEXT};
            font-weight: 600;
            transition: transform 0.05s ease, border-color 0.15s ease;
        }}
        .stButton > button:hover {{
            border-color: {ACCENT};
            color: {ACCENT};
        }}
        .stButton > button[kind="primary"] {{
            background: {ACCENT};
            border-color: {ACCENT};
            color: white;
        }}
        .stButton > button[kind="primary"]:hover {{
            filter: brightness(1.1);
            color: white;
        }}

        /* Text inputs */
        .stTextInput input {{
            background: {SURFACE};
            border: 1px solid {BORDER};
            border-radius: 10px;
            color: {TEXT};
        }}
        .stTextInput input:focus {{
            border-color: {ACCENT};
            box-shadow: 0 0 0 1px {ACCENT};
        }}

        /* Tabs */
        [data-testid="stTabs"] button[data-baseweb="tab"] {{
            font-weight: 600;
            color: {MUTED};
        }}
        [data-testid="stTabs"] button[aria-selected="true"] {{
            color: {ACCENT};
        }}
        [data-testid="stTabs"] [data-baseweb="tab-highlight"] {{
            background-color: {ACCENT};
            height: 2px;
        }}

        /* Dataframes / tables */
        [data-testid="stDataFrame"] {{
            border-radius: 12px;
            border: 1px solid {BORDER};
            overflow: hidden;
        }}

        /* Progress bar */
        [data-testid="stProgress"] > div > div {{
            background-color: {ACCENT};
            border-radius: 8px;
        }}

        /* Dividers */
        hr {{ border-color: {BORDER}; }}

        /* Captions */
        [data-testid="stCaptionContainer"] {{ color: {MUTED}; }}
        </style>
        """,
        unsafe_allow_html=True,
    )
    if _TEMPLATE_NAME not in pio.templates:
        pio.templates[_TEMPLATE_NAME] = go.layout.Template(
            layout=go.Layout(
                paper_bgcolor="rgba(0,0,0,0)",
                plot_bgcolor="rgba(0,0,0,0)",
                font={"color": TEXT, "family": "Inter, sans-serif"},
                xaxis={"gridcolor": BORDER, "zerolinecolor": BORDER},
                yaxis={"gridcolor": BORDER, "zerolinecolor": BORDER},
                colorway=[ACCENT, GREEN, AMBER, RED, MUTED],
            )
        )
    pio.templates.default = _TEMPLATE_NAME


def gauge_color(pct_of_limit: float) -> str:
    """Green / amber >=70% / red >=90% of a limit, per the spec."""
    if pct_of_limit >= 0.90:
        return RED
    if pct_of_limit >= 0.70:
        return AMBER
    return GREEN
