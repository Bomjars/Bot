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
from intraday_trading.golive.gate import evaluate_go_live_gate
from intraday_trading.killswitch.kill_switch import trip
from intraday_trading.storage.go_live_checklist_store import GoLiveChecklistStore

app = typer.Typer(add_completion=False)
golive_app = typer.Typer(
    add_completion=False, help="The go-live gate -- docs/GO_LIVE_CHECKLIST.md."
)
app.add_typer(golive_app, name="golive")


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


@golive_app.command("status")
def golive_status(
    strategies: str = typer.Option(
        "", help="Comma-separated strategy names to check, e.g. orb,spy_momentum"
    ),
) -> None:
    """Print every go-live check and an overall verdict. See docs/GO_LIVE_CHECKLIST.md."""
    settings = load_settings()
    strategy_list = [s.strip() for s in strategies.split(",") if s.strip()]
    verdict = evaluate_go_live_gate(
        settings.database_path,
        strategy_list,
        live_equity_cap_gbp=settings.live_equity_cap_gbp,
        min_paper_days=settings.go_live_min_paper_days,
        max_errors_lookback_days=settings.go_live_max_errors_lookback_days,
    )
    for check in verdict.checks:
        icon, color = ("PASS", typer.colors.GREEN) if check.met else ("FAIL", typer.colors.RED)
        typer.secho(f"[{icon}] {check.name}", fg=color, bold=True)
        typer.echo(f"       {check.detail}")
    typer.echo()
    if verdict.all_met:
        typer.secho("GO-LIVE GATE: PASSED", fg=typer.colors.GREEN, bold=True)
    else:
        typer.secho("GO-LIVE GATE: NOT PASSED", fg=typer.colors.RED, bold=True)


@golive_app.command("mark-kill-switch-tested")
def golive_mark_kill_switch_tested() -> None:
    """Record that a human deliberately tripped the kill switch in paper and confirmed
    it worked. Only run this after you've actually done that -- nothing else checks."""
    settings = load_settings()
    GoLiveChecklistStore(settings.database_path).mark_kill_switch_tested()
    typer.secho("Recorded: kill switch tested.", fg=typer.colors.GREEN)


@golive_app.command("mark-reconciliation-tested")
def golive_mark_reconciliation_tested() -> None:
    """Record that a human deliberately restarted the paper loop and confirmed
    reconciliation worked. Only run this after you've actually done that."""
    settings = load_settings()
    GoLiveChecklistStore(settings.database_path).mark_reconciliation_tested()
    typer.secho("Recorded: reconciliation tested.", fg=typer.colors.GREEN)


def main() -> None:
    app()


if __name__ == "__main__":
    main()
    sys.exit(0)
