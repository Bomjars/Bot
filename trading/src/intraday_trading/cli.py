"""Command-line entry point.

`run-paper` and `kill` are real now. `run-paper` attaches `SpyMomentumStrategy` only when
`SPY` is in `--symbols` (see execution/wiring.py); step 7's ORB strategy has no spec yet,
so no other symbol proposes trades -- it will otherwise just sit there doing session/risk
bookkeeping and reconciliation without proposing anything. Both commands take
`--broker alpaca|ibkr` (default `alpaca`) but always talk to that broker's *paper*
endpoint only -- `.live()` exists on both adapters but neither this CLI nor
execution/wiring.py ever calls it (see CLAUDE.md).
"""

from __future__ import annotations

import logging
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

import pandas as pd
import structlog
import typer

from intraday_trading.alerting.telegram import TelegramAlerter
from intraday_trading.broker.ibkr_broker import IBKRBroker
from intraday_trading.config import load_settings
from intraday_trading.data.client import AlpacaMarketDataClient
from intraday_trading.dev.demo_data import generate_demo_data
from intraday_trading.execution.wiring import BROKER_PROVIDERS, build_paper_trading_components
from intraday_trading.golive.gate import evaluate_go_live_gate
from intraday_trading.killswitch.kill_switch import trip
from intraday_trading.reporting.backtest_summary import (
    PAPER_TABLE3_ANNUAL_RETURN_PCT,
    PAPER_TABLE3_MAX_DRAWDOWN_PCT,
    PAPER_TABLE3_SHARPE,
    Performance,
    performance_from_prices,
    summarize_grid,
)
from intraday_trading.reporting.benchmark import compute_benchmark_comparison, format_daily_report
from intraday_trading.session.calendar import EXCHANGE_TZ
from intraday_trading.storage.bar_store import BarStore
from intraday_trading.storage.go_live_checklist_store import GoLiveChecklistStore
from intraday_trading.storage.risk_state_store import RiskStateStore
from intraday_trading.strategies.spy_grid import (
    GridRunConfig,
    bars_from_dataframe,
    house_risk_grid,
    paper_cost_model,
    paper_faithful_risk_limits,
    paper_reference_config,
    run_and_log_grid,
)
from intraday_trading.strategies.spy_momentum import SpyMomentumConfig
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
report_app = typer.Typer(add_completion=False, help="Bot performance vs. a buy-and-hold benchmark.")
app.add_typer(report_app, name="report")


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
    broker: str = typer.Option(
        "alpaca", help=f"Which broker's paper endpoint to trade through: {BROKER_PROVIDERS}"
    ),
) -> None:
    """Start the paper-trading event loop against the chosen broker's *paper* endpoint.
    Attaches `SpyMomentumStrategy` only when `SPY` is in `--symbols` -- see the module
    docstring. Market data (bars) always comes from Alpaca regardless of `--broker` --
    see execution/wiring.py's module docstring for why."""
    if broker not in BROKER_PROVIDERS:
        typer.secho(
            f"--broker must be one of {BROKER_PROVIDERS}, got {broker!r}", fg=typer.colors.RED
        )
        raise typer.Exit(code=1)
    settings = load_settings()
    symbol_list = [s.strip() for s in symbols.split(",") if s.strip()]
    components = build_paper_trading_components(settings, symbol_list, broker_provider=broker)

    typer.echo(f"Starting paper-trading loop ({broker}) for symbols: {symbol_list or '(none)'}")
    components.loop.startup()
    try:
        while True:
            components.loop.run_once()
            time.sleep(poll_interval_seconds)
    except KeyboardInterrupt:
        typer.echo("Stopped.")


@app.command()
def kill(
    broker: str = typer.Option(
        "alpaca",
        help=f"Which broker's paper endpoint holds the positions to flatten: {BROKER_PROVIDERS}",
    ),
) -> None:
    """Trip the kill switch: cancel all orders and flatten all positions."""
    if broker not in BROKER_PROVIDERS:
        typer.secho(
            f"--broker must be one of {BROKER_PROVIDERS}, got {broker!r}", fg=typer.colors.RED
        )
        raise typer.Exit(code=1)
    settings = load_settings()
    components = build_paper_trading_components(settings, symbols=[], broker_provider=broker)
    trip(components.risk_manager, reason="manual CLI kill switch")
    typer.secho("Kill switch tripped: orders cancelled, positions flattened.", fg=typer.colors.RED)


@report_app.command("daily")
def report_daily(
    symbol: str = typer.Option("SPY", help="Instrument to compare buy-and-hold against"),
    notify: bool = typer.Option(False, help="Also send this report via Telegram"),
) -> None:
    """Compare the paper account's P&L since today's starting equity against simply
    buying and holding `--symbol` over the same window. Uses IBKR's account state and
    historical prices (IBKRBroker.get_daily_closes) -- requires IB Gateway reachable on
    the configured paper port, and at least one `run-paper` session already begun today
    (RiskStateStore.daily_starting_equity)."""
    settings = load_settings()
    risk_state = RiskStateStore(settings.database_path).load()
    if risk_state.daily_starting_equity is None:
        typer.secho(
            "No trading session recorded yet today -- run `run-paper` first.",
            fg=typer.colors.RED,
        )
        raise typer.Exit(code=1)

    broker = IBKRBroker.paper(settings)
    account = broker.get_account()
    closes = broker.get_daily_closes(symbol, duration_str="2 D")
    if len(closes) < 2:
        typer.secho(f"Not enough historical data returned for {symbol!r}.", fg=typer.colors.RED)
        raise typer.Exit(code=1)

    comparison = compute_benchmark_comparison(
        starting_equity=risk_state.daily_starting_equity,
        current_equity=account.equity,
        benchmark_start_price=closes[-2][1],
        benchmark_current_price=closes[-1][1],
    )
    report_text = format_daily_report(symbol, comparison)
    typer.echo(report_text)

    if notify:
        alerter = TelegramAlerter(settings.telegram_bot_token, settings.telegram_chat_id)
        alerter.daily_summary(report_text)


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


def _echo_grid_progress(done: int, total: int, config: SpyMomentumConfig) -> None:
    typer.echo(
        f"  [{done}/{total}] vm={config.vm} lookback={config.lookback_days}d "
        f"every={config.decision_interval_minutes}min stop={config.stop_variant}"
    )


@backtest_app.command("spy")
def backtest_spy(
    start: str = typer.Option(..., help="Start date, YYYY-MM-DD (ET, inclusive)"),
    end: str = typer.Option(..., help="End date, YYYY-MM-DD (ET, exclusive)"),
    starting_equity: float = typer.Option(
        100_000.0, help="Starting equity (USD) for each backtest run in the grid"
    ),
    reference_only: bool = typer.Option(
        False,
        help="Only run the paper's own reference config (a few minutes) -- a quick "
        "replication check before committing hours to the full grid",
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

    # The strategy logs an info line per decision time while its lookback window fills
    # (~170 per config, ~32k over the grid) -- quiet info logs for this command only,
    # keeping warnings/errors, and restore whatever was configured afterwards.
    previous_log_config = structlog.get_config()
    structlog.configure(wrapper_class=structlog.make_filtering_bound_logger(logging.WARNING))
    try:
        registry = TrialRegistry(settings.database_path)
        cost_model = paper_cost_model()  # spec §5's costs exactly (BT-010)

        house_risk_run_config = GridRunConfig(
            starting_equity=starting_equity,
            cost_model=cost_model,
            risk_limits=settings.risk,
        )
        if reference_only:
            typer.echo("--reference-only: skipping the house_risk grid.")
        else:
            grid = house_risk_grid()
            typer.echo(
                f"Running {len(grid)} house_risk configs (this is the go-live decision grid)..."
            )
            trial_ids = run_and_log_grid(
                "SPY",
                "spy_momentum",
                grid,
                bars,
                house_risk_run_config,
                registry,
                on_progress=_echo_grid_progress,
            )
            typer.echo(f"Logged {len(trial_ids)} trials under strategy=spy_momentum.")

        paper_faithful_limits = paper_faithful_risk_limits(settings.risk)
        paper_run_config = GridRunConfig(
            starting_equity=starting_equity,
            cost_model=cost_model,
            risk_limits=paper_faithful_limits,
        )
        typer.echo(
            "Running the paper's own reference config (paper_faithful, for Table 3 comparison)..."
        )
        paper_trial_ids = run_and_log_grid(
            "SPY",
            "spy_momentum_paper_faithful",
            [paper_reference_config()],
            bars,
            paper_run_config,
            registry,
        )
        typer.echo(f"Logged {len(paper_trial_ids)} paper_faithful reference trial(s).")
    finally:
        structlog.configure(**previous_log_config)
    typer.echo(
        "Run `intraday-trading golive status --strategies spy_momentum` for the "
        "CSCV/PBO verdict, or open the dashboard's Validation Report page."
    )


def _fmt_perf_lines(perf: Performance) -> list[str]:
    return [
        f"  return per year:  {perf.annual_return_pct:6.1f}%   "
        f"(total {perf.total_return_pct:,.0f}%)",
        f"  worst drop:       {perf.max_drawdown_pct:6.1f}%   (peak to trough)",
        f"  Sharpe ratio:     {perf.sharpe:6.2f}    (return per unit of risk; >1 is good)",
        f"  ups and downs:    {perf.annual_vol_pct:6.1f}%   per year",
    ]


@backtest_app.command("summary")
def backtest_summary(
    strategy: str = typer.Option("spy_momentum", help="Strategy name in the trial registry"),
    symbol: str = typer.Option("SPY", help="Instrument for the buy-and-hold comparison"),
    starting_equity: float = typer.Option(
        100_000.0, help="The --starting-equity the backtest was run with (USD)"
    ),
) -> None:
    """Plain-English numbers behind a logged backtest grid: the overfitting verdict, how
    the grid did overall, the best config vs buy-and-hold, and the paper_faithful run vs
    the paper's own Table 3. Read-only -- it never changes the registry."""
    settings = load_settings()
    registry = TrialRegistry(settings.database_path)
    summary = summarize_grid(registry, strategy, starting_equity)
    if summary is None:
        typer.secho(f"No trials logged for {strategy!r}.", fg=typer.colors.RED)
        raise typer.Exit(code=1)

    typer.secho(
        f"{strategy}: {summary.n_trials} configs, {summary.first_date} to "
        f"{summary.last_date} ({summary.best.days:,} trading days)",
        bold=True,
    )
    if summary.n_date_ranges > 1:
        typer.secho(
            f"  WARNING: these trials cover {summary.n_date_ranges} different date ranges "
            "(more than one backtest run is mixed together) -- the numbers below are "
            "distorted until the extra runs are retired.",
            fg=typer.colors.YELLOW,
        )

    typer.echo()
    typer.secho("Overfitting check (CSCV/PBO)", bold=True)
    if summary.pbo is None or summary.p_oos_sharpe_negative is None:
        typer.echo("  not enough data to run it")
    else:
        status = "PASS" if summary.cscv_passed else "FAIL"
        typer.echo(f"  {status}: {summary.cscv_reason}")
        typer.echo(f"  PBO {summary.pbo:.1%}: chance the config that looked best was just lucky")
        typer.echo(
            f"  {summary.p_oos_sharpe_negative:.1%}: chance the chosen config loses money "
            "on data it wasn't picked on"
        )
    if summary.dsr is not None:
        typer.echo(
            f"  DSR {summary.dsr:.1%}: confidence the best config's edge is real after "
            f"allowing for {registry.trial_count(strategy)} tries (>95% is strong)"
        )

    typer.echo()
    typer.secho(f"All {summary.n_trials} configs", bold=True)
    typer.echo(f"  profitable after costs: {summary.n_profitable}/{summary.n_trials}")
    typer.echo(f"  median return per year: {summary.median_annual_return_pct:.1f}%")

    typer.echo()
    typer.secho(
        f"Best config (trial {summary.best_trial_id}; picked on the whole period, so flattering)",
        bold=True,
    )
    shown = ("vm", "lookback_days", "decision_interval_minutes", "stop_variant", "sizing")
    typer.echo(
        "  " + ", ".join(f"{k}={summary.best_params[k]}" for k in shown if k in summary.best_params)
    )
    for line in _fmt_perf_lines(summary.best):
        typer.echo(line)
    typer.echo(f"  days with a trade:  {summary.best.active_day_pct:5.1f}%")

    start_dt = datetime.fromisoformat(summary.first_date).replace(tzinfo=EXCHANGE_TZ)
    end_dt = datetime.fromisoformat(summary.last_date).replace(tzinfo=EXCHANGE_TZ) + timedelta(
        days=1
    )
    bars = BarStore(settings.database_path).get_bars(
        symbol, start_dt, end_dt, settings.alpaca_data_feed.value
    )
    typer.echo()
    typer.secho(f"Buy and hold {symbol}, same dates", bold=True)
    if bars.empty:
        typer.echo(f"  no stored {symbol} bars for these dates -- can't compare")
    else:
        dates = [pd.Timestamp(ts).astimezone(EXCHANGE_TZ).date() for ts in bars["ts"]]
        daily_closes = bars.assign(date=dates).groupby("date")["close"].last()
        for line in _fmt_perf_lines(
            performance_from_prices(float(bars["open"].iloc[0]), daily_closes)
        ):
            typer.echo(line)

    paper = summarize_grid(registry, f"{strategy}_paper_faithful", starting_equity)
    if paper is not None:
        typer.echo()
        typer.secho(
            "Paper's own settings (paper_faithful, up to 4x leverage -- replication only)",
            bold=True,
        )
        for line in _fmt_perf_lines(paper.best):
            typer.echo(line)
        typer.echo(
            f"  the paper reported: {PAPER_TABLE3_ANNUAL_RETURN_PCT}% per year, Sharpe "
            f"{PAPER_TABLE3_SHARPE}, worst drop {PAPER_TABLE3_MAX_DRAWDOWN_PCT}% "
            "(May 2007 - Apr 2024, so different dates)"
        )


@backtest_app.command("retire")
def backtest_retire(
    strategy: str = typer.Option(..., help="Strategy whose active trials to retire"),
    reason: str = typer.Option(..., help="Why -- stored with every retired trial"),
) -> None:
    """Mark every still-active trial of a strategy as retired, e.g. a whole grid run
    that had a bug in it. Nothing is deleted (CLAUDE.md rule 8): retired trials drop out
    of the CSCV/PBO verdict but still count towards DSR's total number of attempts."""
    settings = load_settings()
    retired = TrialRegistry(settings.database_path).retire_all(strategy, reason)
    typer.echo(f"Retired {retired} trial(s) of {strategy!r} (kept in the registry, not deleted).")


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
