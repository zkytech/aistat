"""API clients aligned with CLIProxyClient / Sub2APIClient / DeepSeekClient."""

from __future__ import annotations

import time
from datetime import datetime, timezone
from typing import Any, Optional

from .config import CLIProxyConnection, DeepSeekConnection, Sub2APIConnection
from .http_util import HTTPError, request_json
from .models import (
    AuthAccount,
    MonthlyQuota,
    ProductUsage,
    WeeklyQuota,
    balance_string,
    clamp_percent,
    flexible_float,
    parse_date,
    resolve_provider,
)

MANAGEMENT_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
GROK_UA = "grok-pager/0.2.91 grok-shell/0.2.91 (macos; aarch64)"
CODEX_UA = "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal"

WEEKLY_BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
MONTHLY_BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing"
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
DEEPSEEK_BALANCE_URL = "https://api.deepseek.com/user/balance"


class CLIProxyClient:
    def __init__(self, connection: CLIProxyConnection):
        self.base_url = connection.normalized_base_url
        self.management_key = connection.normalized_management_key

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.management_key}",
            "Accept": "application/json",
            "User-Agent": MANAGEMENT_UA,
        }

    def _url(self, path: str) -> str:
        return f"{self.base_url}{path}"

    def fetch_accounts(self) -> list[AuthAccount]:
        if not self.base_url or not self.management_key:
            raise HTTPError(-1, "请先在 Settings 配置 baseURL 与 managementKey")
        data = request_json("GET", self._url("/v0/management/auth-files"), headers=self._headers())
        accounts_raw = _extract_auth_list(data)
        accounts: list[AuthAccount] = []
        for item in accounts_raw:
            if not isinstance(item, dict):
                continue
            acc = AuthAccount.from_dict(item)
            if resolve_provider(acc.provider):
                accounts.append(acc)
        return accounts

    def fetch_weekly_quota(self, account: AuthAccount) -> WeeklyQuota:
        provider = resolve_provider(account.provider)
        if provider == "Grok":
            return self._with_retry(lambda: self._fetch_grok_weekly(account.auth_index))
        if provider == "OpenAI":
            return self._with_retry(lambda: self._fetch_codex(account.auth_index))
        if provider == "Claude":
            return self._with_retry(lambda: self._fetch_claude(account.auth_index))
        raise HTTPError(-1, f"不支持的 provider: {account.provider}")

    def fetch_monthly_quota(self, account: AuthAccount) -> Optional[MonthlyQuota]:
        if resolve_provider(account.provider) != "Grok":
            return None
        return self._fetch_grok_monthly(account.auth_index)

    def _with_retry(self, op, times: int = 2):
        last: Optional[Exception] = None
        for attempt in range(times + 1):
            try:
                return op()
            except Exception as e:  # noqa: BLE001 — match Swift retry surface
                last = e
                if attempt < times:
                    time.sleep(0.15 * (attempt + 1))
        assert last is not None
        raise last

    def _api_call(self, auth_index: str, url: str, header: dict[str, str]) -> Any:
        body = {
            "authIndex": auth_index,
            "method": "GET",
            "url": url,
            "header": header,
        }
        return request_json(
            "POST",
            self._url("/v0/management/api-call"),
            headers=self._headers(),
            body=body,
            timeout=45.0,
        )

    def _fetch_grok_weekly(self, auth_index: str) -> WeeklyQuota:
        envelope = self._api_call(
            auth_index,
            WEEKLY_BILLING_URL,
            {
                "Authorization": "Bearer $TOKEN$",
                "x-xai-token-auth": "xai-grok-cli",
                "x-grok-client-version": "0.2.91",
                "accept": "*/*",
                "user-agent": GROK_UA,
            },
        )
        config = _billing_config_from_envelope(envelope)
        used = clamp_percent(flexible_float(config.get("creditUsagePercent")))
        period = config.get("currentPeriod") or {}
        products = []
        for p in config.get("productUsage") or []:
            if isinstance(p, dict):
                products.append(
                    ProductUsage(
                        product=str(p.get("product") or ""),
                        usage_percent=clamp_percent(flexible_float(p.get("usagePercent"))),
                    )
                )
        return WeeklyQuota(
            used_percent=used,
            period_start=parse_date(period.get("start")),
            period_end=parse_date(period.get("end")),
            product_usage=products,
        )

    def _fetch_grok_monthly(self, auth_index: str) -> Optional[MonthlyQuota]:
        envelope = self._api_call(
            auth_index,
            MONTHLY_BILLING_URL,
            {
                "Authorization": "Bearer $TOKEN$",
                "x-xai-token-auth": "xai-grok-cli",
                "x-grok-client-version": "0.2.91",
                "accept": "*/*",
                "user-agent": GROK_UA,
            },
        )
        config = _billing_config_from_envelope(envelope)
        limit = config.get("monthlyLimit") or {}
        used = config.get("used") or {}
        limit_val = limit.get("val") if isinstance(limit, dict) else None
        used_val = used.get("val") if isinstance(used, dict) else None
        if limit_val is None or used_val is None:
            return None
        try:
            return MonthlyQuota(limit_cents=int(limit_val), used_cents=int(used_val))
        except (TypeError, ValueError):
            return None

    def _fetch_codex(self, auth_index: str) -> WeeklyQuota:
        envelope = self._api_call(
            auth_index,
            CODEX_USAGE_URL,
            {
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "User-Agent": CODEX_UA,
            },
        )
        body = _ensure_envelope_body(envelope)
        return _codex_as_weekly(body if isinstance(body, dict) else {})

    def _fetch_claude(self, auth_index: str) -> WeeklyQuota:
        envelope = self._api_call(
            auth_index,
            CLAUDE_USAGE_URL,
            {
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
            },
        )
        body = _ensure_envelope_body(envelope)
        return _claude_as_weekly(body if isinstance(body, dict) else {})


def _extract_auth_list(data: Any) -> list[Any]:
    if isinstance(data, list):
        return data
    if not isinstance(data, dict):
        return []
    for key in ("files", "auth_files", "data"):
        if isinstance(data.get(key), list):
            return data[key]
    return []


def _billing_config_from_envelope(envelope: Any) -> dict[str, Any]:
    body = envelope.get("body") if isinstance(envelope, dict) else None
    if isinstance(body, str):
        import json

        try:
            body = json.loads(body)
        except json.JSONDecodeError:
            body = {}
    if not isinstance(body, dict):
        body = {}
    config = body.get("config") if isinstance(body.get("config"), dict) else body
    return config if isinstance(config, dict) else {}


def _ensure_envelope_body(envelope: Any) -> Any:
    if not isinstance(envelope, dict):
        return {}
    status = envelope.get("status_code")
    if status is None:
        status = envelope.get("status")
    try:
        code = int(status) if status is not None else None
    except (TypeError, ValueError):
        code = None
    if code is not None and not (200 <= code < 300):
        body = envelope.get("body")
        snippet = str(body)[:240] if body is not None else "upstream error"
        raise HTTPError(code, snippet)
    body = envelope.get("body")
    if isinstance(body, str):
        import json

        try:
            return json.loads(body)
        except json.JSONDecodeError:
            return {}
    return body if body is not None else {}


def _window_used_percent(window: dict[str, Any]) -> Optional[float]:
    for key in ("used_percent", "usedPercent"):
        v = clamp_percent(flexible_float(window.get(key)))
        if v is not None:
            return v
    return None


def _window_reset_date(window: dict[str, Any]) -> Optional[datetime]:
    for key in ("reset_at", "resetAt"):
        d = parse_date(window.get(key))
        if d:
            return d
    for key in ("reset_after_seconds", "resetAfterSeconds"):
        secs = flexible_float(window.get(key))
        if secs is not None:
            return datetime.fromtimestamp(time.time() + secs).astimezone()
    return None


def _window_kind_label(window: dict[str, Any], default: str) -> str:
    secs = flexible_float(window.get("limit_window_seconds") or window.get("limitWindowSeconds"))
    if secs is None:
        return default
    if abs(secs - 18_000) < 1:
        return "5 小时限额"
    if abs(secs - 604_800) < 1:
        return "周限额"
    if 2_419_200 <= secs <= 2_678_400:
        return "月度限额"
    if secs >= 86_400:
        days = int(round(secs / 86_400))
        return f"{days} 天限额"
    hours = max(int(round(secs / 3_600)), 1)
    return f"{hours} 小时限额"


def _codex_rate_windows(rate_limit: Optional[dict[str, Any]], prefix: Optional[str]) -> list[tuple[str, dict]]:
    if not rate_limit:
        return []
    result: list[tuple[str, dict]] = []
    primary = rate_limit.get("primary_window") or rate_limit.get("primaryWindow")
    secondary = rate_limit.get("secondary_window") or rate_limit.get("secondaryWindow")
    if isinstance(primary, dict):
        kind = _window_kind_label(primary, "5 小时限额")
        label = f"{prefix} {kind}" if prefix else kind
        result.append((label, primary))
    if isinstance(secondary, dict):
        kind = _window_kind_label(secondary, "周限额")
        label = f"{prefix} {kind}" if prefix else kind
        result.append((label, secondary))
    return result


def _codex_as_weekly(body: dict[str, Any]) -> WeeklyQuota:
    windows: list[tuple[str, dict]] = []
    rate = body.get("rate_limit") or body.get("rateLimit")
    if isinstance(rate, dict):
        windows.extend(_codex_rate_windows(rate, None))
    cr = body.get("code_review_rate_limit") or body.get("codeReviewRateLimit")
    if isinstance(cr, dict):
        windows.extend(_codex_rate_windows(cr, "代码审查"))
    additional = body.get("additional_rate_limits") or body.get("additionalRateLimits") or []
    if isinstance(additional, list):
        for item in additional:
            if not isinstance(item, dict):
                continue
            name = (item.get("name") or "").strip()
            prefix = name if name else "附加"
            rl = item.get("rate_limit") or item.get("rateLimit")
            if isinstance(rl, dict):
                windows.extend(_codex_rate_windows(rl, prefix))
            else:
                windows.extend(_codex_rate_windows(item, prefix))

    products: list[ProductUsage] = []
    primary_window: Optional[dict] = None
    primary_used = -1.0
    for label, window in windows:
        used = _window_used_percent(window)
        if used is None:
            continue
        products.append(ProductUsage(product=label, usage_percent=used))
        if used >= primary_used:
            primary_used = used
            primary_window = window

    return WeeklyQuota(
        used_percent=_window_used_percent(primary_window) if primary_window else None,
        period_start=None,
        period_end=_window_reset_date(primary_window) if primary_window else None,
        product_usage=products,
    )


def _claude_window(data: Optional[dict[str, Any]]) -> Optional[tuple[float, Optional[datetime]]]:
    if not isinstance(data, dict):
        return None
    util = clamp_percent(flexible_float(data.get("utilization")))
    if util is None:
        util = 0.0
    reset = parse_date(data.get("resets_at") or data.get("resetsAt"))
    return util, reset


def _claude_as_weekly(body: dict[str, Any]) -> WeeklyQuota:
    labeled = [
        ("5 小时限额", body.get("five_hour")),
        ("7 天限额", body.get("seven_day")),
        ("7 天 OAuth 应用", body.get("seven_day_oauth_apps")),
        ("7 天 Opus", body.get("seven_day_opus")),
        ("7 天 Sonnet", body.get("seven_day_sonnet")),
        ("7 天 Cowork", body.get("seven_day_cowork")),
    ]
    products: list[ProductUsage] = []
    primary_util = -1.0
    primary_reset: Optional[datetime] = None
    primary_used: Optional[float] = None
    for label, raw in labeled:
        parsed = _claude_window(raw if isinstance(raw, dict) else None)
        if parsed is None:
            continue
        util, reset = parsed
        products.append(ProductUsage(product=label, usage_percent=util))
        if util >= primary_util:
            primary_util = util
            primary_used = util
            primary_reset = reset
    return WeeklyQuota(
        used_percent=primary_used,
        period_start=None,
        period_end=primary_reset,
        product_usage=products,
    )


class Sub2APIClient:
    def __init__(self, connection: Sub2APIConnection):
        self.base_url = connection.normalized_base_url
        self.api_key = connection.normalized_api_key

    def fetch_usage(self) -> dict[str, Any]:
        if not self.base_url or not self.api_key:
            raise HTTPError(-1, "请先在 Settings 配置 Sub2API baseURL 与 API Key")
        data = request_json(
            "GET",
            f"{self.base_url}/v1/usage",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Accept": "application/json",
                "User-Agent": MANAGEMENT_UA,
            },
        )
        return data if isinstance(data, dict) else {}


def sub2_available_balance(usage: dict[str, Any]) -> Optional[float]:
    remaining = flexible_float(usage.get("remaining"))
    if remaining is not None:
        return max(remaining, 0.0)
    quota = usage.get("quota") if isinstance(usage.get("quota"), dict) else {}
    qrem = flexible_float(quota.get("remaining"))
    if qrem is not None:
        return max(qrem, 0.0)
    balance = flexible_float(usage.get("balance"))
    if balance is not None:
        return max(balance, 0.0)
    sub = usage.get("subscription") if isinstance(usage.get("subscription"), dict) else {}
    for limit_k, used_k in (
        ("monthly_limit_usd", "monthly_usage_usd"),
        ("weekly_limit_usd", "weekly_usage_usd"),
        ("daily_limit_usd", "daily_usage_usd"),
    ):
        lim = flexible_float(sub.get(limit_k))
        used = flexible_float(sub.get(used_k))
        if lim is not None and used is not None:
            return max(lim - used, 0.0)
    return None


def sub2_daily_usage_text(usage: dict[str, Any]) -> Optional[str]:
    unit = usage.get("unit")
    stats = usage.get("usage") if isinstance(usage.get("usage"), dict) else {}
    today = stats.get("today") if isinstance(stats.get("today"), dict) else {}
    value = flexible_float(today.get("actual_cost"))
    if value is None:
        value = flexible_float(today.get("cost"))
    if value is None:
        sub = usage.get("subscription") if isinstance(usage.get("subscription"), dict) else {}
        value = flexible_float(sub.get("daily_usage_usd"))
    if value is None:
        return None
    return balance_string(value, str(unit) if unit else "USD")


class DeepSeekClient:
    def __init__(self, connection: DeepSeekConnection):
        self.api_key = connection.normalized_api_key

    def fetch_balance(self) -> dict[str, Any]:
        if not self.api_key:
            raise HTTPError(-1, "请先在 Settings 配置 DeepSeek API Key")
        data = request_json(
            "GET",
            DEEPSEEK_BALANCE_URL,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Accept": "application/json",
                "User-Agent": MANAGEMENT_UA,
            },
        )
        return _reduce_deepseek(data if isinstance(data, dict) else {})


def _reduce_deepseek(data: dict[str, Any]) -> dict[str, Any]:
    is_available = data.get("is_available", True)
    infos = data.get("balance_infos")
    if isinstance(infos, list):
        parsed: list[tuple[str, Optional[float]]] = []
        for info in infos:
            if not isinstance(info, dict):
                continue
            currency = str(info.get("currency") or "")
            total = flexible_float(info.get("total_balance"))
            parsed.append((currency, total))

        def pick() -> tuple[Optional[str], Optional[float]]:
            for c, t in parsed:
                if c.upper() == "USD" and (t or 0) > 0:
                    return c, t
            for c, t in parsed:
                if (t or 0) > 0:
                    return c, t
            for c, t in parsed:
                if c.upper() == "USD":
                    return c, t
            if parsed:
                return parsed[0]
            return None, None

        currency, total = pick()
        return {"is_available": bool(is_available), "currency": currency, "total_balance": total}

    return {
        "is_available": bool(data.get("is_available", True)),
        "currency": data.get("currency"),
        "total_balance": flexible_float(data.get("total_balance") or data.get("totalBalance")),
    }
