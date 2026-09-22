"""Command-line entry point.

`run-paper` and `kill` are real now. `run-paper` attaches `SpyMomentumStrategy` only when
`SPY` is in `--symbols` (see execution/wiring.py); step 7's ORB strategy has no spec yet,
so no other symbol proposes trades -- it will otherwise just sit there doing session/risk
bookkeeping and reconciliation without proposing anything. Both commands always talk to
Alpaca's *paper* endpoint only (`AlpacaBroker.paper()` is the only broker constructor
that exists in this codebase -- see CLAUDE.md).
"""

from __future__ import annotations

import sys
import time
from dataclasses import asdict
from datetime import datetime
from pathlib import Path

import typer

from intraday_trading.backtest.costs import CostModel
from intraday_trading.config import load_settings
from intraday_trading.data.client import AlpacaMarketDataClient
from intraday_trading.dev.demo_data import generate_demo_data
from intraday_trading.execution.wiring import build_paper_trading_components
from intraday_trading.golive.gate import evaluate_go_live_gate
from intraday_trading.killswitch.kill_switch import trip
from intraday_trading.session.calendar import EXCHANGE_TZ
from intraday_trading.storage.bar_store import BarStore
from intraday_trading.storage.closed_trade_log import ClosedTradeLog
from intraday_trading.storage.go_live_checklist_store import GoLiveChecklistStore
from intraday_trading.strategies.spy_grid import (
    GridRunConfig,
    bars_from_dataframe,
    house_risk_grid,
    paper_reference_config,
    run_and_log_grid,
    run_spy_config_with_trades,
)
from intraday_trading.validation.registry import TrialRegistry

DEFAULT_DEMO_DATABASE_PATH = Path("data/demo.db")

app = typer.Typer(add_completion=False)
golive_app = typer.Typer(
    add_completion=False, help="The go-live gate -- docs/GO_LIVE_CHECKLIST.md."
)
app.add_typer(golive_app, name="golive")
backtest_app = typer.Typer(
    add_completion=False, help="Run a strategy's parameter grid against real historical data."
)
app.add_typer(backtest_app, name="backtest")


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
    """Start the paper-trading event loop against Alpaca's paper endpoint. Attaches
    `SpyMomentumStrategy` only when `SPY` is in `--symbols` -- see the module docstring."""
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


@backtest_app.command("spy")
def backtest_spy(
    start: str = typer.Option(..., help="Start date, YYYY-MM-DD (ET, inclusive)"),
    end: str = typer.Option(..., help="End date, YYYY-MM-DD (ET, exclusive)"),
    starting_equity: float = typer.Option(
        100_000.0, help="Starting equity (USD) for each backtest run in the grid"
    ),
) -> None:
    """Fetch real SPY minute bars for [start, end) via Alpaca, run the full 192-config
    house_risk grid (docs/STRATEGY_SPEC_SPY.md §8) plus the paper's own reference config,
    and log every trial to the registry. Needs real Alpaca (paper) API keys and outbound
    network access; tests exercise the full orchestration with only the underlying
    network client swapped out (see test_cli.py's `test_backtest_spy_...` test)."""
    settings = load_settings()
    start_dt = datetime.fromisoformat(start).replace(tzinfo=EXCHANGE_TZ)
    end_dt = datetime.fromisoformat(end).replace(tzinfo=EXCHANGE_TZ)

    data_client = AlpacaMarketDataClient.from_settings(settings)
    bar_store = BarStore(settings.database_path)

    typer.echo(f"Fetching SPY minute bars {start} -> {end} ({settings.alpaca_data_feed.value})...")
    fetched = data_client.get_minute_bars(["SPY"], start_dt, end_dt, settings.alpaca_data_feed)
    bar_store.upsert_bars(fetched)
    df = bar_store.get_bars("SPY", start_dt, end_dt, settings.alpaca_data_feed.value)
    if df.empty:
        typer.secho("No bars returned for that range -- nothing to run.", fg=typer.colors.RED)
        raise typer.Exit(code=1)
    bars = {"SPY": bars_from_dataframe(df)}
    typer.echo(f"{len(bars['SPY'])} bars loaded.")

    registry = TrialRegistry(settings.database_path)
    # Spec §5's own cost assumptions: $0.0035/share commission, $0.001/share slippage,
    # no separate bps-based spread (the paper's own reported figures already fold it in).
    cost_model = CostModel(commission_per_share=0.0035, slippage_per_share=0.001)

    house_risk_run_config = GridRunConfig(
        starting_equity=starting_equity,
        cost_model=cost_model,
        risk_limits=settings.risk,
        database_path=settings.database_path,
    )
    grid = house_risk_grid()
    typer.echo(f"Running {len(grid)} house_risk configs (this is the go-live decision grid)...")
    trial_ids = run_and_log_grid("SPY", "spy_momentum", grid, bars, house_risk_run_config, registry)
    typer.echo(f"Logged {len(trial_ids)} trials under strategy=spy_momentum.")

    paper_faithful_limits = settings.risk.model_copy(
        update={"max_leverage": 4.0, "flatten_before_close_minutes": 0, "no_entry_last_minutes": 0}
    )
    paper_run_config = GridRunConfig(
        starting_equity=starting_equity,
        cost_model=cost_model,
        risk_limits=paper_faithful_limits,
        database_path=settings.database_path,
    )
    typer.echo(
        "Running the paper's own reference config (paper_faithful, for Table 3 comparison)..."
    )
    paper_daily_pnl, paper_trades = run_spy_config_with_trades(
        "SPY", paper_reference_config(), bars, paper_run_config
    )
    registry.log_trial(
        "spy_momentum_paper_faithful", asdict(paper_reference_config()), paper_daily_pnl
    )
    typer.echo("Logged 1 paper_faithful reference trial.")

    # Only this single, pre-defined reference config's trades are persisted -- never the
    # 192-config grid's, which would mix a well-behaved config's trades with an overfit
    # one's under the same "spy_momentum" bucket (see run_spy_config_with_trades'
    # docstring).
    ClosedTradeLog(settings.database_path).log_many("spy_momentum", paper_trades)
    typer.echo(
        f"Logged {len(paper_trades)} closed trade(s) for the signal-confidence bucketed "
        "win-rate (Validation Report / Live Monitor pages)."
    )
    typer.echo(
        "Run `intraday-trading golive status --strategies spy_momentum` for the "
        "CSCV/PBO verdict, or open the dashboard's Validation Report page."
    )


@app.command("seed-demo-data")
def seed_demo_data(
    database_path_str: str = typer.Option(
        "",
        "--database-path",
        help=(
            "Where to write synthetic demo data. Defaults to data/demo.db -- a file "
            "separate from your real database, since every number this writes is "
            "fabricated (numpy.random, not a real backtest or trade) and must never "
            "be mistaken for real trading history or fed into a real go-live decision."
        ),
    ),
    force: bool = typer.Option(False, help="Overwrite the file if it already exists."),
) -> None:
    """Populate a demo database with synthetic SPY-momentum trials, orders, and
    rejections, purely so the dashboard has something populated to render for a
    design/UI preview -- see dev/demo_data.py. Point the dashboard at it with
    DATABASE_PATH set to this file; never point it at your real database."""
    database_path = Path(database_path_str) if database_path_str else DEFAULT_DEMO_DATABASE_PATH
    settings = load_settings()
    if database_path.resolve() == settings.database_path.resolve():
        typer.secho(
            "Refusing to seed synthetic data into your real DATABASE_PATH. Pass a "
            "different --database-path (the default, data/demo.db, is fine).",
            fg=typer.colors.RED,
        )
        raise typer.Exit(code=1)
    if database_path.exists() and not force:
        typer.secho(
            f"{database_path} already exists -- pass --force to overwrite.",
            fg=typer.colors.RED,
        )
        raise typer.Exit(code=1)

    database_path.parent.mkdir(parents=True, exist_ok=True)
    if database_path.exists():
        database_path.unlink()

    generate_demo_data(database_path)
    typer.secho(f"Wrote synthetic demo data to {database_path}.", fg=typer.colors.GREEN)
    typer.echo(
        "Point the dashboard at it, e.g. in PowerShell:\n"
        f'  $env:DATABASE_PATH = "{database_path}"; uv run streamlit run dashboard\\main.py'
    )


def main() -> None:
    app()


if __name__ == "__main__":
    main()
    sys.exit(0)
