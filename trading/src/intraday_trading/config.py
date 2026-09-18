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
    max_open_positions: int = Field(default=3, ge=1)
    max_position_pct_of_equity: float = Field(default=0.20, gt=0, le=1.0)
    max_leverage: float = Field(default=1.0, ge=1.0, le=1.0)
    allow_leveraged_etfs: bool = False

    daily_loss_limit_pct: float = Field(default=0.02, gt=0, le=1.0)
    weekly_loss_limit_pct: float = Field(default=0.05, gt=0, le=1.0)
    drawdown_circuit_breaker_pct: float = Field(default=0.10, gt=0, le=1.0)

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

    # --- Account ---
    account_currency: str = "GBP"
    starting_equity_gbp: float = 10_000.0

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
