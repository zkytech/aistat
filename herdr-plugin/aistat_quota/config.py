"""Load AIstat Application Support config (same path / legacy migration as Swift)."""

from __future__ import annotations

import json
import os
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

DEFAULT_REFRESH_INTERVAL = 300
MINIMUM_REFRESH_INTERVAL = 60


def aistat_support_dir() -> Path:
    override = os.environ.get("AISTAT_CONFIG_DIR", "").strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "aistat"


def config_path() -> Path:
    return aistat_support_dir() / "config.json"


def cache_path() -> Path:
    """Prefer plugin state dir; fall back next to AIstat cache for cold start."""
    state = os.environ.get("HERDR_PLUGIN_STATE_DIR", "").strip()
    if state:
        return Path(state) / "quota-cache.json"
    return aistat_support_dir() / "quota-cache.herdr.json"


@dataclass
class CLIProxyConnection:
    id: str
    name: str
    base_url: str
    management_key: str
    prefer_near_refresh: bool = False

    @property
    def is_configured(self) -> bool:
        return bool(self.normalized_base_url and self.normalized_management_key)

    @property
    def display_name(self) -> str:
        name = self.name.strip()
        return name or "CLIProxyAPI"

    @property
    def normalized_base_url(self) -> str:
        return self.base_url.strip().rstrip("/")

    @property
    def normalized_management_key(self) -> str:
        return self.management_key.strip()


@dataclass
class Sub2APIConnection:
    id: str
    name: str
    base_url: str
    api_key: str

    @property
    def is_configured(self) -> bool:
        return bool(self.normalized_base_url and self.normalized_api_key)

    @property
    def display_name(self) -> str:
        name = self.name.strip()
        return name or "Sub2API"

    @property
    def normalized_base_url(self) -> str:
        return self.base_url.strip().rstrip("/")

    @property
    def normalized_api_key(self) -> str:
        return self.api_key.strip()


@dataclass
class DeepSeekConnection:
    id: str
    name: str
    api_key: str

    @property
    def is_configured(self) -> bool:
        return bool(self.normalized_api_key)

    @property
    def display_name(self) -> str:
        name = self.name.strip()
        return name or "DeepSeek"

    @property
    def normalized_api_key(self) -> str:
        return self.api_key.strip()


@dataclass
class AppConfiguration:
    cli_proxy_connections: list[CLIProxyConnection] = field(default_factory=list)
    sub2_api_connections: list[Sub2APIConnection] = field(default_factory=list)
    deepseek_connections: list[DeepSeekConnection] = field(default_factory=list)
    refresh_interval_seconds: int = DEFAULT_REFRESH_INTERVAL

    @property
    def is_configured(self) -> bool:
        return any(c.is_configured for c in self.cli_proxy_connections)

    @property
    def has_balance_sources(self) -> bool:
        return any(c.is_configured for c in self.sub2_api_connections) or any(
            c.is_configured for c in self.deepseek_connections
        )

    @property
    def has_any_data_source(self) -> bool:
        return self.is_configured or self.has_balance_sources

    @property
    def refresh_interval(self) -> float:
        return float(max(self.refresh_interval_seconds, MINIMUM_REFRESH_INTERVAL))


def _new_id() -> str:
    return str(uuid.uuid4())


def _parse_cli(raw: dict[str, Any]) -> CLIProxyConnection:
    return CLIProxyConnection(
        id=str(raw.get("id") or _new_id()),
        name=str(raw.get("name") or ""),
        base_url=str(raw.get("baseURL") or ""),
        management_key=str(raw.get("managementKey") or ""),
        prefer_near_refresh=bool(raw.get("preferNearRefreshAccounts") or False),
    )


def _parse_sub2(raw: dict[str, Any]) -> Sub2APIConnection:
    return Sub2APIConnection(
        id=str(raw.get("id") or _new_id()),
        name=str(raw.get("name") or ""),
        base_url=str(raw.get("baseURL") or ""),
        api_key=str(raw.get("apiKey") or ""),
    )


def _parse_deepseek(raw: dict[str, Any]) -> DeepSeekConnection:
    return DeepSeekConnection(
        id=str(raw.get("id") or _new_id()),
        name=str(raw.get("name") or ""),
        api_key=str(raw.get("apiKey") or ""),
    )


def load_configuration(path: Path | None = None) -> AppConfiguration:
    url = path or config_path()
    if not url.is_file():
        return AppConfiguration()

    try:
        data = json.loads(url.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return AppConfiguration()

    if not isinstance(data, dict):
        return AppConfiguration()

    interval = data.get("refreshIntervalSeconds", DEFAULT_REFRESH_INTERVAL)
    try:
        interval_i = int(interval)
    except (TypeError, ValueError):
        interval_i = DEFAULT_REFRESH_INTERVAL
    if interval_i <= 0:
        interval_i = DEFAULT_REFRESH_INTERVAL

    # Multi-connection shape (current) or legacy single-connection.
    if "cliProxyConnections" in data or "sub2APIConnections" in data:
        cli = [
            _parse_cli(item)
            for item in (data.get("cliProxyConnections") or [])
            if isinstance(item, dict)
        ]
        sub2 = [
            _parse_sub2(item)
            for item in (data.get("sub2APIConnections") or [])
            if isinstance(item, dict)
        ]
        deep = [
            _parse_deepseek(item)
            for item in (data.get("deepSeekConnections") or [])
            if isinstance(item, dict)
        ]
        return AppConfiguration(
            cli_proxy_connections=cli,
            sub2_api_connections=sub2,
            deepseek_connections=deep,
            refresh_interval_seconds=interval_i,
        )

    # Legacy migration → one named connection "默认".
    cli: list[CLIProxyConnection] = []
    base = str(data.get("baseURL") or "")
    key = str(data.get("managementKey") or "")
    if base.strip() or key.strip():
        cli.append(
            CLIProxyConnection(
                id=_new_id(),
                name="默认",
                base_url=base,
                management_key=key,
                prefer_near_refresh=bool(data.get("preferNearRefreshAccounts") or False),
            )
        )

    sub2: list[Sub2APIConnection] = []
    sbase = str(data.get("sub2APIBaseURL") or "")
    skey = str(data.get("sub2APIKey") or "")
    if sbase.strip() or skey.strip():
        sub2.append(
            Sub2APIConnection(
                id=_new_id(),
                name="默认",
                base_url=sbase,
                api_key=skey,
            )
        )

    return AppConfiguration(
        cli_proxy_connections=cli,
        sub2_api_connections=sub2,
        deepseek_connections=[],
        refresh_interval_seconds=interval_i,
    )
