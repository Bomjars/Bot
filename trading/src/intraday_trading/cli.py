"""Command-line entry point.

Skeleton only for now — `run-paper` and `kill` are wired up in later steps (paper-trading
loop is step 8, kill switch logic is part of step 3/8). This exists so `uv run
intraday-trading --help` works from day one and so the safety checks below are visible
from the very first commit.
"""

from __future__ import annotations

import sys

import typer

from intraday_trading.config import load_settings

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
def run_paper() -> None:
    """Start the paper-trading event loop. Not implemented yet (step 8)."""
    typer.secho(
        "run-paper is not implemented yet (see docs/PLAN.md, step 8).",
        fg=typer.colors.YELLOW,
    )
    raise SystemExit(1)


@app.command()
def kill() -> None:
    """Trip the kill switch: cancel all orders and flatten all positions. Not implemented yet."""
    typer.secho(
        "kill switch is not implemented yet (see docs/PLAN.md, step 3/8).",
        fg=typer.colors.YELLOW,
    )
    raise SystemExit(1)


def main() -> None:
    app()


if __name__ == "__main__":
    main()
    sys.exit(0)
