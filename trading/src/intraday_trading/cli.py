"""Command-line entry point.

`run-paper` and `kill` are real now, but note: `run-paper` starts an empty strategy list
until steps 6-7 ship real strategies (see execution/wiring.py) -- it will sit there doing
session/risk bookkeeping and reconciliation without ever proposing a trade. Both commands
always talk to Alpaca's *paper* endpoint only (`AlpacaBroker.paper()` is the only broker
constructor that exists in this codebase -- see CLAUDE.md).
"""

from __future__ import annotations

import sys
import time

import typer

from intraday_trading.config import load_settings
from intraday_trading.execution.wiring import build_paper_trading_components
from intraday_trading.killswitch.kill_switch import trip

app = typer.Typer(add_completion=False)


@app.command()
def status() -> None:
    """Print resolved settings (secrets redacted) and sanity-check the environment."""
    settings = load_settings()
    typer.echo(f"live_trading: {settings.live_trading}")
    typer.echo(f"alpaca_data_feed: {settings.alpaca_data_feed.value}")
    typer.echo(f"database_path: {settings.database_path}")
    typer.echo(f"risk.max_trades_per_day: {settings.risk.max_trades_per_day}")
    if settings.live_trading:
        typer.secho(
            "LIVE_TRADING=true — this build refuses to place live orders regardless; "
            "see CLAUDE.md.",
            fg=typer.colors.RED,
            bold=True,
        )


@app.command("run-paper")
def run_paper(
    symbols: str = typer.Option("", help="Comma-separated symbols to poll, e.g. SPY,AAPL"),
    poll_interval_seconds: float = typer.Option(5.0, help="Seconds between loop iterations"),
) -> None:
    """Start the paper-trading event loop against Alpaca's paper endpoint. Runs with no
    strategies attached until steps 6-7 land -- see the module docstring."""
    settings = load_settings()
    symbol_list = [s.strip() for s in symbols.split(",") if s.strip()]
    components = build_paper_trading_components(settings, symbol_list)

    typer.echo(f"Starting paper-trading loop for symbols: {symbol_list or '(none)'}")
    components.loop.startup()
    try:
        while True:
            components.loop.run_once()
            time.sleep(poll_interval_seconds)
    except KeyboardInterrupt:
        typer.echo("Stopped.")


@app.command()
def kill() -> None:
    """Trip the kill switch: cancel all orders and flatten all positions."""
    settings = load_settings()
    components = build_paper_trading_components(settings, symbols=[])
    trip(components.risk_manager, reason="manual CLI kill switch")
    typer.secho("Kill switch tripped: orders cancelled, positions flattened.", fg=typer.colors.RED)


def main() -> None:
    app()


if __name__ == "__main__":
    main()
    sys.exit(0)
