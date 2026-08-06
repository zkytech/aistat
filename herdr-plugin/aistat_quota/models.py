"""Display models aligned with AIstat Swift Quota / AuthAccount types."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Optional


def clamp_percent(value: Optional[float]) -> Optional[float]:
    if value is None:
        return None
    try:
        v = float(value)
    except (TypeError, ValueError):
        return None
    return min(max(v, 0.0), 100.0)


def flexible_float(value: Any) -> Optional[float]:
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def parse_date(value: Any) -> Optional[datetime]:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        # Heuristic: ms vs s
        ts = float(value)
        if ts > 1e12:
            ts /= 1000.0
        return datetime.fromtimestamp(ts, tz=timezone.utc).astimezone()
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    # ISO-8601 variants
    candidates = [text]
    if text.endswith("Z"):
        candidates.append(text[:-1] + "+00:00")
    for c in candidates:
        try:
            # fromisoformat handles fractional seconds and offsets in 3.11+
            dt = datetime.fromisoformat(c.replace("Z", "+00:00") if c.endswith("Z") else c)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone()
        except ValueError:
            continue
    return None


def format_display_date(dt: Optional[datetime]) -> str:
    if dt is None:
        return "--"
    local = dt.astimezone()
    return local.strftime("%Y-%m-%d %H:%M:%S")


def format_reset_countdown(until: Optional[datetime], now: Optional[datetime] = None) -> str:
    """WidgetResetFormatter / RelativeResetFormatter parity."""
    if until is None:
        return "重置 --"
    now = now or datetime.now().astimezone()
    if until.tzinfo is None:
        until = until.replace(tzinfo=timezone.utc).astimezone()
    seconds = (until - now).total_seconds()
    if seconds <= 0:
        return "已到期"
    total_minutes = int(seconds) // 60
    if total_minutes < 1:
        return "即将重置"
    days = total_minutes // (60 * 24)
    hours = (total_minutes % (60 * 24)) // 60
    minutes = total_minutes % 60
    if days > 0:
        if hours > 0:
            return f"{days}天{hours}时"
        return f"{days}天"
    if hours > 0:
        if minutes > 0:
            return f"{hours}时{minutes}分"
        return f"{hours}时"
    return f"{minutes}分"


def balance_string(value: float, unit: Optional[str]) -> str:
    amount = f"{value:.2f}"
    raw = (unit or "USD").strip()
    if raw in ("$", "¥", "€", "£"):
        return f"{raw}{amount}"
    symbol = {
        "USD": "$",
        "US$": "$",
        "CNY": "¥",
        "RMB": "¥",
        "EUR": "€",
        "GBP": "£",
    }.get(raw.upper())
    if symbol:
        return f"{symbol}{amount}"
    code = raw.upper() if raw else "USD"
    return f"{amount} {code}"


SUPPORTED_PROVIDERS = {
    "openai": "OpenAI",
    "codex": "OpenAI",
    "claude": "Claude",
    "anthropic": "Claude",
    "xai": "Grok",
    "grok": "Grok",
}


def resolve_provider(raw: str) -> Optional[str]:
    key = (raw or "").strip().lower()
    return SUPPORTED_PROVIDERS.get(key)


def provider_short(raw: str) -> str:
    name = resolve_provider(raw)
    if name == "OpenAI":
        return "OAI"
    if name == "Claude":
        return "CLD"
    if name == "Grok":
        return "GRK"
    return "???"


@dataclass
class ProductUsage:
    product: str
    usage_percent: Optional[float]

    @property
    def remaining_percent(self) -> Optional[float]:
        if self.usage_percent is None:
            return None
        return clamp_percent(100.0 - self.usage_percent)


@dataclass
class WeeklyQuota:
    used_percent: Optional[float] = None
    period_start: Optional[datetime] = None
    period_end: Optional[datetime] = None
    product_usage: list[ProductUsage] = field(default_factory=list)

    @property
    def remaining_percent(self) -> Optional[float]:
        if self.used_percent is None:
            return None
        return clamp_percent(100.0 - self.used_percent)

    @property
    def is_exhausted(self) -> bool:
        rem = self.remaining_percent
        return rem is not None and rem <= 0

    def filling_missing_usage(self, monthly: Optional["MonthlyQuota"]) -> "WeeklyQuota":
        if self.used_percent is not None:
            return self
        if monthly is None or monthly.limit_cents <= 0:
            return self
        capped = min(max(monthly.used_cents, 0), monthly.limit_cents)
        percent = clamp_percent(capped / monthly.limit_cents * 100.0)
        return WeeklyQuota(
            used_percent=percent,
            period_start=self.period_start,
            period_end=self.period_end,
            product_usage=list(self.product_usage),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "usedPercent": self.used_percent,
            "periodStart": self.period_start.isoformat() if self.period_start else None,
            "periodEnd": self.period_end.isoformat() if self.period_end else None,
            "productUsage": [
                {"product": p.product, "usagePercent": p.usage_percent} for p in self.product_usage
            ],
        }

    @classmethod
    def from_dict(cls, data: Optional[dict[str, Any]]) -> Optional["WeeklyQuota"]:
        if not data:
            return None
        products = []
        for p in data.get("productUsage") or []:
            if isinstance(p, dict):
                products.append(
                    ProductUsage(
                        product=str(p.get("product") or ""),
                        usage_percent=clamp_percent(flexible_float(p.get("usagePercent"))),
                    )
                )
        return cls(
            used_percent=clamp_percent(flexible_float(data.get("usedPercent"))),
            period_start=parse_date(data.get("periodStart")),
            period_end=parse_date(data.get("periodEnd")),
            product_usage=products,
        )


@dataclass
class MonthlyQuota:
    limit_cents: int
    used_cents: int

    @property
    def remaining_cents(self) -> int:
        return max(self.limit_cents - self.used_cents, 0)

    @property
    def remaining_percent(self) -> Optional[float]:
        if self.limit_cents <= 0:
            return None
        return clamp_percent(self.remaining_cents / self.limit_cents * 100.0)

    def to_dict(self) -> dict[str, Any]:
        return {"limitCents": self.limit_cents, "usedCents": self.used_cents}

    @classmethod
    def from_dict(cls, data: Optional[dict[str, Any]]) -> Optional["MonthlyQuota"]:
        if not data:
            return None
        try:
            return cls(limit_cents=int(data["limitCents"]), used_cents=int(data["usedCents"]))
        except (KeyError, TypeError, ValueError):
            return None


@dataclass
class AuthAccount:
    provider: str
    auth_index: str
    email: Optional[str] = None
    account: Optional[str] = None
    label: Optional[str] = None
    name: Optional[str] = None
    status: Optional[str] = None
    unavailable: bool = False
    status_message: Optional[str] = None
    disabled: bool = False
    next_retry_after: Optional[str] = None
    success: Optional[int] = None
    failed: Optional[int] = None

    @property
    def display_name(self) -> str:
        for candidate in (self.email, self.account, self.label):
            if candidate and candidate.strip():
                return candidate.strip()
        return self.auth_index

    def to_dict(self) -> dict[str, Any]:
        return {
            "provider": self.provider,
            "email": self.email,
            "account": self.account,
            "label": self.label,
            "name": self.name,
            "auth_index": self.auth_index,
            "status": self.status,
            "unavailable": self.unavailable,
            "status_message": self.status_message,
            "disabled": self.disabled,
            "next_retry_after": self.next_retry_after,
            "success": self.success,
            "failed": self.failed,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "AuthAccount":
        auth_index = data.get("auth_index")
        if auth_index is None:
            auth_index = data.get("authIndex", "")
        return cls(
            provider=str(data.get("provider") or ""),
            email=data.get("email"),
            account=data.get("account"),
            label=data.get("label"),
            name=data.get("name"),
            auth_index=str(auth_index),
            status=data.get("status"),
            unavailable=bool(data.get("unavailable") or False),
            status_message=data.get("status_message") or data.get("statusMessage"),
            disabled=bool(data.get("disabled") or False),
            next_retry_after=data.get("next_retry_after") or data.get("nextRetryAfter"),
            success=data.get("success"),
            failed=data.get("failed"),
        )


@dataclass
class AccountQuota:
    connection_id: str
    connection_name: str
    account: AuthAccount
    weekly: Optional[WeeklyQuota] = None
    monthly: Optional[MonthlyQuota] = None
    error_message: Optional[str] = None

    @property
    def id(self) -> str:
        return f"{self.connection_id}:{self.account.auth_index}"

    def resolved_status(self) -> str:
        """AccountQuotaStatus priority: disabled → error → exhausted → unavailable → status → active."""
        if self.account.disabled:
            return "disabled"
        if self.error_message:
            return "error"
        if self.weekly and self.weekly.is_exhausted:
            return "exhausted"
        if self.account.unavailable:
            return "unavailable"
        status = (self.account.status or "").strip()
        if status:
            return status
        return "active"

    def to_dict(self) -> dict[str, Any]:
        return {
            "connectionID": self.connection_id,
            "connectionName": self.connection_name,
            "account": self.account.to_dict(),
            "weekly": self.weekly.to_dict() if self.weekly else None,
            "monthly": self.monthly.to_dict() if self.monthly else None,
            "errorMessage": self.error_message,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "AccountQuota":
        acc = data.get("account") or {}
        return cls(
            connection_id=str(data.get("connectionID") or ""),
            connection_name=str(data.get("connectionName") or ""),
            account=AuthAccount.from_dict(acc if isinstance(acc, dict) else {}),
            weekly=WeeklyQuota.from_dict(data.get("weekly") if isinstance(data.get("weekly"), dict) else None),
            monthly=MonthlyQuota.from_dict(data.get("monthly") if isinstance(data.get("monthly"), dict) else None),
            error_message=data.get("errorMessage"),
        )


@dataclass
class CLIProxyAccountGroup:
    connection_id: str
    connection_name: str
    accounts: list[AccountQuota] = field(default_factory=list)
    error: Optional[str] = None

    @property
    def id(self) -> str:
        return self.connection_id

    def to_dict(self) -> dict[str, Any]:
        return {
            "connectionID": self.connection_id,
            "connectionName": self.connection_name,
            "accounts": [a.to_dict() for a in self.accounts],
            "error": self.error,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "CLIProxyAccountGroup":
        accounts = [
            AccountQuota.from_dict(a)
            for a in (data.get("accounts") or [])
            if isinstance(a, dict)
        ]
        return cls(
            connection_id=str(data.get("connectionID") or ""),
            connection_name=str(data.get("connectionName") or ""),
            accounts=accounts,
            error=data.get("error"),
        )


@dataclass
class BalanceEntry:
    id: str
    name: str
    balance_text: Optional[str] = None
    plan_name: Optional[str] = None
    daily_usage_text: Optional[str] = None
    error: Optional[str] = None
    kind: str = "balance"  # sub2api | deepseek

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "balanceText": self.balance_text,
            "planName": self.plan_name,
            "dailyUsageText": self.daily_usage_text,
            "error": self.error,
            "kind": self.kind,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "BalanceEntry":
        return cls(
            id=str(data.get("id") or ""),
            name=str(data.get("name") or ""),
            balance_text=data.get("balanceText"),
            plan_name=data.get("planName"),
            daily_usage_text=data.get("dailyUsageText"),
            error=data.get("error"),
            kind=str(data.get("kind") or "balance"),
        )


def remaining_text(item: AccountQuota) -> str:
    if item.error_message:
        return "!!"
    rem = item.weekly.remaining_percent if item.weekly else None
    if rem is None:
        return "--"
    return f"{rem:.0f}%"


def remaining_color_code(remaining: Optional[float], has_error: bool = False) -> str:
    """ANSI color name key for TUI."""
    if has_error:
        return "red"
    if remaining is None:
        return "dim"
    if remaining <= 0:
        return "red"
    if remaining <= 20:
        return "yellow"
    return "green"


def status_symbol(status: str) -> str:
    return {
        "disabled": "−",
        "error": "!",
        "exhausted": "×",
        "unavailable": "/",
        "active": "●",
    }.get(status, "●")


def progress_bar(remaining: Optional[float], width: int = 10) -> str:
    if remaining is None:
        return "[" + "·" * width + "]"
    filled = int(round(remaining / 100.0 * width))
    filled = max(0, min(width, filled))
    return "[" + "█" * filled + "░" * (width - filled) + "]"
