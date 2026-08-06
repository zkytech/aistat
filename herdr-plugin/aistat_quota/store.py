"""Refresh orchestration aligned with QuotaStore (without priority write-back)."""

from __future__ import annotations

import json
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

from .clients import (
    CLIProxyClient,
    DeepSeekClient,
    Sub2APIClient,
    sub2_available_balance,
    sub2_daily_usage_text,
)
from .config import AppConfiguration, cache_path, load_configuration
from .models import (
    AccountQuota,
    BalanceEntry,
    CLIProxyAccountGroup,
    balance_string,
    flexible_float,
)


@dataclass
class QuotaSnapshot:
    account_groups: list[CLIProxyAccountGroup] = field(default_factory=list)
    balance_entries: list[BalanceEntry] = field(default_factory=list)
    last_refresh_at: Optional[datetime] = None
    global_error: Optional[str] = None
    is_refreshing: bool = False

    @property
    def accounts(self) -> list[AccountQuota]:
        return [a for g in self.account_groups for a in g.accounts]

    def to_dict(self) -> dict:
        return {
            "accountGroups": [g.to_dict() for g in self.account_groups],
            "balanceEntries": [b.to_dict() for b in self.balance_entries],
            "lastRefreshAt": self.last_refresh_at.isoformat() if self.last_refresh_at else None,
            "globalError": self.global_error,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "QuotaSnapshot":
        groups = [
            CLIProxyAccountGroup.from_dict(g)
            for g in (data.get("accountGroups") or [])
            if isinstance(g, dict)
        ]
        balances = [
            BalanceEntry.from_dict(b)
            for b in (data.get("balanceEntries") or [])
            if isinstance(b, dict)
        ]
        last = data.get("lastRefreshAt")
        last_dt = None
        if isinstance(last, str) and last:
            try:
                last_dt = datetime.fromisoformat(last)
            except ValueError:
                last_dt = None
        return cls(
            account_groups=groups,
            balance_entries=balances,
            last_refresh_at=last_dt,
            global_error=data.get("globalError"),
        )


def load_cache(path: Optional[Path] = None) -> Optional[QuotaSnapshot]:
    url = path or cache_path()
    if not url.is_file():
        # Also try AIstat's quota-cache if present (Swift format may differ — skip on failure).
        alt = Path.home() / "Library" / "Application Support" / "aistat" / "quota-cache.herdr.json"
        if url != alt and alt.is_file():
            url = alt
        else:
            return None
    try:
        data = json.loads(url.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return None
        snap = QuotaSnapshot.from_dict(data)
        if not snap.account_groups and not snap.balance_entries:
            return None
        return snap
    except (OSError, json.JSONDecodeError):
        return None


def save_cache(snapshot: QuotaSnapshot, path: Optional[Path] = None) -> None:
    url = path or cache_path()
    try:
        url.parent.mkdir(parents=True, exist_ok=True)
        # Privacy-safe: no keys; strip transient errors from cache.
        clean = QuotaSnapshot(
            account_groups=[
                CLIProxyAccountGroup(
                    connection_id=g.connection_id,
                    connection_name=g.connection_name,
                    accounts=[
                        AccountQuota(
                            connection_id=a.connection_id,
                            connection_name=a.connection_name,
                            account=a.account,
                            weekly=a.weekly,
                            monthly=a.monthly,
                            error_message=None if (a.weekly or a.monthly) else a.error_message,
                        )
                        for a in g.accounts
                    ],
                    error=None,
                )
                for g in snapshot.account_groups
            ],
            balance_entries=[
                BalanceEntry(
                    id=b.id,
                    name=b.name,
                    balance_text=b.balance_text,
                    plan_name=b.plan_name,
                    daily_usage_text=b.daily_usage_text,
                    error=None if b.balance_text else b.error,
                    kind=b.kind,
                )
                for b in snapshot.balance_entries
                if b.balance_text or b.error
            ],
            last_refresh_at=snapshot.last_refresh_at,
            global_error=None,
        )
        payload = json.dumps(clean.to_dict(), ensure_ascii=False, indent=2)
        tmp = url.with_suffix(url.suffix + ".tmp")
        tmp.write_text(payload, encoding="utf-8")
        os.replace(tmp, url)
        try:
            os.chmod(url, 0o600)
        except OSError:
            pass
    except OSError:
        pass


def _refresh_cli_group(
    connection,
    previous: Optional[CLIProxyAccountGroup],
    include_monthly: bool = True,
) -> tuple[CLIProxyAccountGroup, bool]:
    name = connection.display_name
    previous_by_auth = {
        a.account.auth_index: a for a in (previous.accounts if previous else [])
    }
    client = CLIProxyClient(connection)
    try:
        accounts = client.fetch_accounts()
    except Exception as e:  # noqa: BLE001
        if previous and previous.accounts:
            return (
                CLIProxyAccountGroup(
                    connection_id=connection.id,
                    connection_name=name,
                    accounts=previous.accounts,
                    error=None,
                ),
                False,
            )
        return (
            CLIProxyAccountGroup(
                connection_id=connection.id,
                connection_name=name,
                accounts=[],
                error=str(e),
            ),
            False,
        )

    if not accounts:
        return (
            CLIProxyAccountGroup(
                connection_id=connection.id,
                connection_name=name,
                accounts=[],
                error=None,
            ),
            True,
        )

    seeded: list[AccountQuota] = []
    for acc in accounts:
        prior = previous_by_auth.get(acc.auth_index)
        seeded.append(
            AccountQuota(
                connection_id=connection.id,
                connection_name=name,
                account=acc,
                weekly=prior.weekly if prior else None,
                monthly=prior.monthly if prior else None,
                error_message=None,
            )
        )

    def fetch_one(index: int, item: AccountQuota) -> tuple[int, Optional[object], Optional[object], bool, Optional[str]]:
        try:
            weekly = client.fetch_weekly_quota(item.account)
            monthly = None
            if include_monthly:
                try:
                    monthly = client.fetch_monthly_quota(item.account)
                except Exception:  # noqa: BLE001
                    monthly = item.monthly
            weekly = weekly.filling_missing_usage(monthly)
            return index, weekly, monthly, True, None
        except Exception as e:  # noqa: BLE001
            # Keep previous; surface soft error only when no previous weekly.
            err = None
            if item.weekly is None:
                err = str(e)
            return index, None, None, False, err

    results: list[tuple] = []
    with ThreadPoolExecutor(max_workers=min(8, max(len(seeded), 1))) as pool:
        futures = [pool.submit(fetch_one, i, item) for i, item in enumerate(seeded)]
        for fut in as_completed(futures):
            results.append(fut.result())

    for index, weekly, monthly, succeeded, err in results:
        if succeeded:
            seeded[index].weekly = weekly  # type: ignore[assignment]
            if include_monthly and monthly is not None:
                seeded[index].monthly = monthly  # type: ignore[assignment]
            seeded[index].error_message = None
        elif err:
            seeded[index].error_message = err

    # Sort by refresh proximity if preferNearRefresh (read-only; no priority write-back).
    if connection.prefer_near_refresh:
        now = datetime.now().astimezone()

        def distance(item: AccountQuota) -> float:
            if item.weekly and item.weekly.period_end:
                return abs((item.weekly.period_end - now).total_seconds())
            return float("inf")

        seeded.sort(key=lambda a: (distance(a), a.account.display_name.lower(), a.account.auth_index))

    return (
        CLIProxyAccountGroup(
            connection_id=connection.id,
            connection_name=name,
            accounts=seeded,
            error=None,
        ),
        True,
    )


def _refresh_sub2(connection, previous: Optional[BalanceEntry]) -> tuple[BalanceEntry, bool]:
    client = Sub2APIClient(connection)
    try:
        usage = client.fetch_usage()
        bal = sub2_available_balance(usage)
        text = balance_string(bal, usage.get("unit")) if bal is not None else None
        return (
            BalanceEntry(
                id=connection.id,
                name=connection.display_name,
                balance_text=text,
                plan_name=usage.get("planName") or usage.get("plan_name"),
                daily_usage_text=sub2_daily_usage_text(usage),
                error=None,
                kind="sub2api",
            ),
            True,
        )
    except Exception as e:  # noqa: BLE001
        if previous and previous.balance_text:
            return (
                BalanceEntry(
                    id=connection.id,
                    name=connection.display_name,
                    balance_text=previous.balance_text,
                    plan_name=previous.plan_name,
                    daily_usage_text=previous.daily_usage_text,
                    error=None,
                    kind="sub2api",
                ),
                False,
            )
        return (
            BalanceEntry(
                id=connection.id,
                name=connection.display_name,
                balance_text=None,
                error=str(e),
                kind="sub2api",
            ),
            False,
        )


def _refresh_deepseek(connection, previous: Optional[BalanceEntry]) -> tuple[BalanceEntry, bool]:
    client = DeepSeekClient(connection)
    try:
        bal = client.fetch_balance()
        total = flexible_float(bal.get("total_balance"))
        currency = bal.get("currency")
        unavailable = (not bal.get("is_available", True)) and total is None
        if unavailable:
            return (
                BalanceEntry(
                    id=connection.id,
                    name=connection.display_name,
                    balance_text=None,
                    error="账户不可用",
                    kind="deepseek",
                ),
                True,
            )
        text = balance_string(total, str(currency) if currency else "USD") if total is not None else None
        return (
            BalanceEntry(
                id=connection.id,
                name=connection.display_name,
                balance_text=text,
                error=None,
                kind="deepseek",
            ),
            True,
        )
    except Exception as e:  # noqa: BLE001
        if previous and previous.balance_text:
            return (
                BalanceEntry(
                    id=connection.id,
                    name=connection.display_name,
                    balance_text=previous.balance_text,
                    plan_name=previous.plan_name,
                    error=None,
                    kind="deepseek",
                ),
                False,
            )
        return (
            BalanceEntry(
                id=connection.id,
                name=connection.display_name,
                balance_text=None,
                error=str(e),
                kind="deepseek",
            ),
            False,
        )


def refresh(
    configuration: Optional[AppConfiguration] = None,
    previous: Optional[QuotaSnapshot] = None,
    include_monthly: bool = True,
) -> QuotaSnapshot:
    config = configuration or load_configuration()
    prev = previous or QuotaSnapshot()

    cli_conns = [c for c in config.cli_proxy_connections if c.is_configured]
    sub2_conns = [c for c in config.sub2_api_connections if c.is_configured]
    ds_conns = [c for c in config.deepseek_connections if c.is_configured]

    if not cli_conns and not sub2_conns and not ds_conns:
        return QuotaSnapshot(
            global_error="请先在 Settings 配置 baseURL 与 managementKey",
        )

    prev_groups = {g.connection_id: g for g in prev.account_groups}
    prev_bal = {b.id: b for b in prev.balance_entries}

    next_groups: list[CLIProxyAccountGroup] = []
    next_balances: list[BalanceEntry] = []
    any_success = False

    # Parallel: each CLIProxy connection + each balance source.
    with ThreadPoolExecutor(max_workers=8) as pool:
        cli_futs = {
            pool.submit(_refresh_cli_group, c, prev_groups.get(c.id), include_monthly): ("cli", i, c)
            for i, c in enumerate(cli_conns)
        }
        sub2_futs = {
            pool.submit(_refresh_sub2, c, prev_bal.get(c.id)): ("sub2", i, c)
            for i, c in enumerate(sub2_conns)
        }
        ds_futs = {
            pool.submit(_refresh_deepseek, c, prev_bal.get(c.id)): ("ds", i, c)
            for i, c in enumerate(ds_conns)
        }

        cli_results: list[tuple[int, CLIProxyAccountGroup, bool]] = []
        sub2_results: list[tuple[int, BalanceEntry, bool]] = []
        ds_results: list[tuple[int, BalanceEntry, bool]] = []

        for fut in as_completed({**cli_futs, **sub2_futs, **ds_futs}):
            kind, index, _conn = {**cli_futs, **sub2_futs, **ds_futs}[fut]
            try:
                result, ok = fut.result()
            except Exception as e:  # noqa: BLE001
                if kind == "cli":
                    result = CLIProxyAccountGroup(
                        connection_id=_conn.id,
                        connection_name=_conn.display_name,
                        accounts=[],
                        error=str(e),
                    )
                    ok = False
                else:
                    result = BalanceEntry(
                        id=_conn.id,
                        name=_conn.display_name,
                        error=str(e),
                        kind="sub2api" if kind == "sub2" else "deepseek",
                    )
                    ok = False
            if kind == "cli":
                cli_results.append((index, result, ok))  # type: ignore[arg-type]
            elif kind == "sub2":
                sub2_results.append((index, result, ok))  # type: ignore[arg-type]
            else:
                ds_results.append((index, result, ok))  # type: ignore[arg-type]
            if ok:
                any_success = True

    cli_results.sort(key=lambda x: x[0])
    sub2_results.sort(key=lambda x: x[0])
    ds_results.sort(key=lambda x: x[0])
    next_groups = [r[1] for r in cli_results]
    next_balances = [r[1] for r in sub2_results] + [r[1] for r in ds_results]

    if not any_success and (prev.account_groups or prev.balance_entries):
        # Complete failure: keep previous live UI.
        return QuotaSnapshot(
            account_groups=prev.account_groups,
            balance_entries=prev.balance_entries,
            last_refresh_at=prev.last_refresh_at,
            global_error=None,
        )

    snap = QuotaSnapshot(
        account_groups=next_groups,
        balance_entries=next_balances,
        last_refresh_at=datetime.now().astimezone(),
        global_error=None,
    )
    save_cache(snap)
    return snap


def placeholder_balances(config: AppConfiguration) -> list[BalanceEntry]:
    return [
        BalanceEntry(id=c.id, name=c.display_name, kind="sub2api")
        for c in config.sub2_api_connections
        if c.is_configured
    ] + [
        BalanceEntry(id=c.id, name=c.display_name, kind="deepseek")
        for c in config.deepseek_connections
        if c.is_configured
    ]
