"""Dark theme: CSS injected once from main.py, plus a matching Plotly template so every
chart reads as part of the same system rather than Streamlit's light-mode default.
"""

from __future__ import annotations

import plotly.graph_objects as go
import plotly.io as pio
import streamlit as st

BACKGROUND = "#0e1117"
SURFACE = "#1b1f2b"
TEXT = "#e6e6e6"
MUTED = "#8b93a7"
GREEN = "#3ecf8e"
AMBER = "#f5a524"
RED = "#f5455c"
ACCENT = "#5b8def"

_TEMPLATE_NAME = "intraday_dark"


def apply() -> None:
    st.markdown(
        f"""
        <style>
        .stApp {{ background-color: {BACKGROUND}; color: {TEXT}; }}
        [data-testid="stSidebar"] {{ background-color: {SURFACE}; }}
        </style>
        """,
        unsafe_allow_html=True,
    )
    if _TEMPLATE_NAME not in pio.templates:
        pio.templates[_TEMPLATE_NAME] = go.layout.Template(
            layout=go.Layout(
                paper_bgcolor=BACKGROUND,
                plot_bgcolor=BACKGROUND,
                font={"color": TEXT},
                xaxis={"gridcolor": SURFACE, "zerolinecolor": SURFACE},
                yaxis={"gridcolor": SURFACE, "zerolinecolor": SURFACE},
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
