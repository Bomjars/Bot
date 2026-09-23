"""Central configuration.

Everything that affects risk, sessions, or trading behaviour is a field here so it can be
set from `.env` / environment variables and audited, rather than buried as a literal in
strategy or risk code. See CLAUDE.md for the safety invariants around `live_trading`.
"""

from __future__ import annotations

from enum import StrEnum
from pathlib import Path

from pydantic import BaseModel, Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

REPO_ROOT = Path(__file__).resolve().parents[2]


class DataFeed(StrEnum):
    IEX = "iex"
    SIP = "sip"


class RiskLimits(BaseModel):
    """Hard limits enforced by RiskManager before every order. All configurable, all
    checked; nothing here is a suggestion. See docs/PLAN.md for provenance of each number.
    """

    max_risk_per_trade_pct: float = Field(default=0.01, gt=0, le=0.05)
    max_open_positions: int = Field(default=5, ge=1)
    max_position_pct_of_equity: float = Field(default=0.20, gt=0, le=1.0)
    max_leverage: float = Field(default=1.0, ge=1.0, le=4.0)
    """Locked at 1.0 by default and for every real (paper/live) trading config -- see
    docs/PLAN.md §2. The upper bound only exists so a `paper_faithful` backtest/paper
    RiskManager (docs/STRATEGY_SPEC_SPY.md §7, STRAT-004) can be explicitly constructed
    with headroom up to the paper's own 4x, for replication purposes only; nothing in
    `execution/wiring.py` (the only place a real broker gets wired up) ever sets this
    above 1.0."""
    allow_leveraged_etfs: bool = False

    daily_loss_limit_pct: float = Field(default=0.03, gt=0, le=1.0)
    weekly_loss_limit_pct: float = Field(default=0.05, gt=0, le=1.0)
    drawdown_circuit_breaker_pct: float = Field(default=0.15, gt=0, le=1.0)

    cash_account_only: bool = True
    """No margin, ever: an entry's notional may not exceed the broker's reported
    settled cash (RiskManager checks this independently of `max_leverage`, which only
    bounds notional-vs-equity and wouldn't by itself catch a margin-account order sized
    against unsettled or borrowed buying power)."""
    allowed_currencies: tuple[str, ...] = ("USD",)
    """Every entry's instrument currency must be in this set -- rejects UK-listed
    (GBP) shares by default (0.5% stamp duty, and simply out of scope for now), not
    just leveraged ETFs. `EntrySignal.currency` defaults to "USD" so existing
    Alpaca/SPY signals are unaffected."""

    max_trades_per_day: int = Field(default=10, ge=1)
    no_entry_first_minutes: int = Field(default=15, ge=0)
    no_entry_last_minutes: int = Field(default=30, ge=0)
    flatten_before_close_minutes: int = Field(default=10, ge=0)

    min_price_usd: float = Field(default=5.0, gt=0)
    min_avg_dollar_volume_usd: float = Field(default=500_000.0, gt=0)
    max_spread_pct: float = Field(default=0.005, gt=0)

    require_bracket_orders: bool = True

    @model_validator(mode="after")
    def _flatten_before_gte_last_entry(self) -> RiskLimits:
        if self.flatten_before_close_minutes > self.no_entry_last_minutes:
            raise ValueError(
                "flatten_before_close_minutes must be <= no_entry_last_minutes: "
                "otherwise positions could open after the flatten cutoff already passed"
            )
        return self


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        env_nested_delimiter="__",
        extra="forbid",
    )

    # --- Safety-critical: never true except via the go-live gate. See CLAUDE.md. ---
    live_trading: bool = False
    live_trading_confirmation: str = ""

    # --- Alpaca ---
    alpaca_api_key: str = ""
    alpaca_secret_key: str = ""
    alpaca_paper_base_url: str = "https://paper-api.alpaca.markets"
    alpaca_live_base_url: str = "https://api.alpaca.markets"
    alpaca_data_feed: DataFeed = DataFeed.IEX

    # --- Interactive Brokers (IB Gateway / TWS) ---
    ibkr_host: str = "127.0.0.1"
    ibkr_port: int = Field(default=4002, gt=0, lt=65536)
    """Used by `IBKRBroker.paper()` -- IB Gateway's default paper-trading socket port.
    Configurable (e.g. multiple Gateway instances on one machine) but never the live
    port: `IBKRBroker.live()` uses `ibkr_live_port` instead, and only ever constructs
    when `settings.live_trading is True` (see broker/ibkr_broker.py and CLAUDE.md)."""
    ibkr_live_port: int = Field(default=4001, gt=0, lt=65536)
    ibkr_client_id: int = Field(default=1, ge=0)

    # --- Account ---
    account_currency: str = "GBP"
    starting_equity_gbp: float = 10_000.0
    fx_cost_per_fill_pct: float = Field(default=0.0, ge=0, le=0.05)
    """Estimated FX cost per fill, as a fraction of the fill's notional, applied only when
    the instrument's currency differs from `account_currency` -- recorded in
    `fills.fx_cost`. Default 0.0 assumes the backtest's own model (backtest/costs.py):
    convert GBP to USD once to fund the account, then every trade happens in USD with no
    per-trade conversion. If your broker instead auto-converts on every trade, set this
    from its fee schedule. Actual conversions the broker executes are logged separately,
    measured rather than estimated, in `fx_conversions` (storage/fx_conversion_log.py)."""

    # --- Sessions / calendar ---
    exchange_timezone: str = "America/New_York"
    display_timezone: str = "Europe/London"

    # --- Storage ---
    database_path: Path = REPO_ROOT / "data" / "trading.db"

    # --- Alerting ---
    telegram_bot_token: str = ""
    telegram_chat_id: str = ""

    # --- Dashboard ---
    dashboard_password: str = ""

    # --- Kill switch ---
    kill_switch_file: Path = REPO_ROOT / "data" / "KILL_SWITCH"

    # --- Go-live gate (docs/GO_LIVE_CHECKLIST.md, golive/gate.py) ---
    live_equity_cap_gbp: float = Field(default=3_000.0, gt=0)
    """Hard ceiling on notional per live order, independent of account equity
    (GOLIVE-006). Deliberately not enforced in paper mode -- it's specifically the
    "start small" constraint for the first live capital, not a general position-size
    limit (that's `RiskLimits.max_position_pct_of_equity`)."""
    approx_gbp_usd_rate: float = Field(default=1.27, gt=0)
    """A manually-updated approximation, not a live FX feed -- used only to convert
    `live_equity_cap_gbp` into a USD notional cap for RiskManager. Not precise enough
    for accounting; update it periodically if GBP/USD moves a lot."""
    go_live_min_paper_days: int = Field(default=30, ge=1)
    go_live_max_errors_lookback_days: int = Field(default=14, ge=1)

    risk: RiskLimits = Field(default_factory=RiskLimits)

    @model_validator(mode="after")
    def _live_trading_requires_explicit_confirmation(self) -> Settings:
        if self.live_trading and self.live_trading_confirmation != "I UNDERSTAND THE RISK":
            raise ValueError(
                "live_trading=true requires LIVE_TRADING_CONFIRMATION="
                "'I UNDERSTAND THE RISK' in the environment. This is intentionally not "
                "convenient. See the go-live gate in CLAUDE.md / docs/GO_LIVE_CHECKLIST.md."
            )
        return self


def load_settings() -> Settings:
    return Settings()
