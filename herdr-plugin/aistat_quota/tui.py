"""Interactive TUI main panel — cache-only view; refresh is fire-and-forget."""

from __future__ import annotations

import os
import re
import select
import sys
import termios
import time
import tty
from dataclasses import dataclass, field
from typing import Optional

from .async_refresh import is_refresh_running, spawn_refresh_async
from .config import AppConfiguration, config_path, load_configuration
from .models import (
    AccountQuota,
    BalanceEntry,
    format_display_date,
    format_reset_countdown,
    progress_bar,
    provider_short,
    remaining_color_code,
    remaining_text,
    status_symbol,
)
from .store import QuotaSnapshot, load_cache, placeholder_balances

# ANSI
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
CLEAR = "\033[2J\033[H"
HIDE_CURSOR = "\033[?25l"
SHOW_CURSOR = "\033[?25h"
MOUSE_ON = "\033[?1000h\033[?1006h"
MOUSE_OFF = "\033[?1000l\033[?1006l"

COLOR = {
    "red": RED,
    "green": GREEN,
    "yellow": YELLOW,
    "dim": DIM,
    "cyan": CYAN,
}

NAME_MAX = 16
BAR_WIDTH = 16
PANEL_WIDTH = 56


def _use_color() -> bool:
    return sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def c(text: str, name: Optional[str] = None, bold: bool = False) -> str:
    if not _use_color():
        return text
    if not name and not bold:
        return text
    parts: list[str] = []
    if bold:
        parts.append(BOLD)
    if name:
        parts.append(COLOR.get(name, ""))
    return f"{''.join(parts)}{text}{RESET}"


def truncate_name(name: str, max_len: int = NAME_MAX) -> str:
    name = (name or "").strip()
    if len(name) <= max_len:
        return name
    if max_len <= 1:
        return "…"
    return name[: max_len - 1] + "…"


@dataclass
class Row:
    kind: str  # balance | account | header | message
    key: str
    balance: Optional[BalanceEntry] = None
    account: Optional[AccountQuota] = None
    label: str = ""


@dataclass
class LayoutMeta:
    row_screen_lines: dict[int, int] = field(default_factory=dict)
    footer_refresh_line: int = 0


def build_rows(snapshot: QuotaSnapshot, config: AppConfiguration) -> list[Row]:
    rows: list[Row] = []
    balances = snapshot.balance_entries
    if not balances and config.has_balance_sources:
        balances = placeholder_balances(config)

    if balances:
        rows.append(Row(kind="header", key="h-balance", label="余额"))
        for b in balances:
            rows.append(Row(kind="balance", key=f"b:{b.id}", balance=b))

    if not config.has_any_data_source:
        msg = snapshot.global_error or "请先在设置中配置 CLIProxyAPI、Sub2API 或 DeepSeek。"
        rows.append(Row(kind="message", key="m-empty", label=msg))
        return rows

    if config.is_configured:
        if not snapshot.account_groups:
            if snapshot.global_error:
                rows.append(Row(kind="message", key="m-cli", label=snapshot.global_error))
            else:
                rows.append(
                    Row(
                        kind="message",
                        key="m-cli",
                        label="暂无缓存账号。按 r 触发后台刷新，下次打开查看。",
                    )
                )
        else:
            for group in snapshot.account_groups:
                title = group.connection_name
                if group.error:
                    title = f"{title}  !"
                rows.append(Row(kind="header", key=f"h:{group.connection_id}", label=title))
                if group.error and not group.accounts:
                    rows.append(Row(kind="message", key=f"e:{group.connection_id}", label=group.error))
                elif not group.accounts:
                    rows.append(
                        Row(kind="message", key=f"m:{group.connection_id}", label="暂无订阅账号")
                    )
                else:
                    for acc in group.accounts:
                        rows.append(Row(kind="account", key=f"a:{acc.id}", account=acc))
    return rows


def selectable_indices(rows: list[Row]) -> list[int]:
    return [i for i, r in enumerate(rows) if r.kind in ("balance", "account")]


def format_balance_line(entry: BalanceEntry, selected: bool) -> str:
    name = truncate_name(entry.name, 14)
    daily = f"今{entry.daily_usage_text}" if entry.daily_usage_text else ""
    if entry.error:
        right_plain = "错误"
        right = c("错误", "red")
    elif entry.balance_text:
        right_plain = entry.balance_text
        right = c(entry.balance_text, "green", bold=True)
    else:
        right_plain = "--"
        right = c("--", "dim")
    mid = f" {c(daily, 'dim')}" if daily else ""
    if selected:
        mid_plain = f" {daily}" if daily else ""
        return c(f"▸ 💳 {name}{mid_plain}  {right_plain}", "cyan", bold=True)
    return f"  💳 {name}{mid}  {right}"


def format_account_line(item: AccountQuota, selected: bool) -> str:
    status = item.resolved_status()
    sym = status_symbol(status)
    color = {
        "disabled": "dim",
        "error": "red",
        "exhausted": "red",
        "unavailable": "red",
        "active": "green",
    }.get(status, "green")
    rem = item.weekly.remaining_percent if item.weekly else None
    rem_color = remaining_color_code(rem, has_error=bool(item.error_message))
    bar = progress_bar(rem, width=BAR_WIDTH)
    rem_txt = f"{remaining_text(item):>4}"
    reset = format_reset_countdown(item.weekly.period_end if item.weekly else None)
    if item.error_message and not item.weekly:
        reset = "失败"
    if reset.startswith("重置 "):
        reset = reset[3:]
    prov = provider_short(item.account.provider)
    name = truncate_name(item.account.display_name, NAME_MAX)

    body = (
        f"{c(sym, color)} {c(prov, 'dim')} "
        f"{c(bar, rem_color)}{c(rem_txt, rem_color, bold=True)} "
        f"{name}  {c(reset, 'dim')}"
    )
    prefix = c("▸ ", "cyan", bold=True) if selected else "  "
    return prefix + body


def render_main(
    snapshot: QuotaSnapshot,
    config: AppConfiguration,
    rows: list[Row],
    selected_idx: int,
    status_line: str = "",
    bg_refreshing: bool = False,
) -> tuple[str, LayoutMeta]:
    meta = LayoutMeta()
    lines: list[str] = []
    title = c("账号额度", "cyan", bold=True)
    if bg_refreshing:
        title += c("  后台刷新中", "dim")
    lines.append(title)
    lines.append(c("─" * PANEL_WIDTH, "dim"))

    screen_line = 3
    if not rows:
        lines.append(c("  （无内容）", "dim"))
        screen_line += 1
    else:
        for i, row in enumerate(rows):
            selected = i == selected_idx and row.kind in ("balance", "account")
            if row.kind == "header":
                lines.append("")
                screen_line += 1
                lines.append(c(f"▸ {row.label}", "dim", bold=True))
                screen_line += 1
            elif row.kind == "message":
                lines.append(
                    c(
                        f"  {row.label}",
                        "yellow" if ("错误" in row.label or "失败" in row.label) else "dim",
                    )
                )
                screen_line += 1
            elif row.kind == "balance" and row.balance:
                lines.append(format_balance_line(row.balance, selected))
                meta.row_screen_lines[screen_line] = i
                screen_line += 1
            elif row.kind == "account" and row.account:
                lines.append(format_account_line(row.account, selected))
                meta.row_screen_lines[screen_line] = i
                screen_line += 1

    lines.append("")
    screen_line += 1
    lines.append(c("─" * PANEL_WIDTH, "dim"))
    screen_line += 1

    last = (
        f"缓存 {format_display_date(snapshot.last_refresh_at)}"
        if snapshot.last_refresh_at
        else "尚无缓存"
    )
    footer = f"{c('[r]', 'cyan')}后台刷新  {c(last, 'dim')}  {c('[o]', 'cyan')}配置  {c('[q]', 'cyan')}退出"
    lines.append(footer)
    meta.footer_refresh_line = screen_line
    screen_line += 1
    lines.append(c("↑↓/点击 选择  Enter/双击 详情  r 触发刷新(不等待)  q 退出", "dim"))
    if status_line:
        lines.append(c(status_line, "yellow"))
    return "\n".join(lines), meta


def render_account_detail(item: AccountQuota) -> str:
    lines: list[str] = []
    status = item.resolved_status()
    lines.append(c(f"{provider_short(item.account.provider)}  {item.account.display_name}", "cyan", bold=True))
    lines.append(c(f"状态: {status}", "dim"))
    lines.append(c("─" * 48, "dim"))
    lines.append(c("周额度", bold=True))
    if item.weekly:
        rem = item.weekly.remaining_percent
        used = item.weekly.used_percent
        lines.append(
            f"  剩余   {c(f'{rem:.0f}%' if rem is not None else '--', remaining_color_code(rem))}"
        )
        lines.append(f"  已用   {f'{used:.0f}%' if used is not None else '--'}")
        if item.weekly.period_start:
            lines.append(f"  周期开始  {format_display_date(item.weekly.period_start)}")
        if item.weekly.period_end:
            lines.append(f"  重置时间  {format_display_date(item.weekly.period_end)}")
            lines.append(f"  距重置    {format_reset_countdown(item.weekly.period_end)}")
        if item.weekly.product_usage:
            lines.append("")
            lines.append(c("产品用量", bold=True))
            for p in item.weekly.product_usage:
                pr = p.remaining_percent
                lines.append(
                    f"  {p.product}  {c(f'{pr:.0f}%' if pr is not None else '--', remaining_color_code(pr))}"
                )
    elif item.error_message:
        lines.append(c(f"  {item.error_message}", "red"))
    else:
        lines.append(c("  暂无周限额数据", "dim"))

    if item.monthly:
        lines.append("")
        lines.append(c("月度额度", bold=True))
        lines.append(f"  剩余   ${item.monthly.remaining_cents / 100:.2f}")
        lines.append(f"  总额   ${item.monthly.limit_cents / 100:.2f}")
        if item.monthly.remaining_percent is not None:
            rp = item.monthly.remaining_percent
            lines.append(f"  剩余比例  {c(f'{rp:.0f}%', remaining_color_code(rp))}")

    lines.append("")
    lines.append(c("账号信息", bold=True))
    if item.account.status_message:
        lines.append(f"  状态说明  {item.account.status_message}")
    if item.account.next_retry_after:
        lines.append(f"  下次重试  {item.account.next_retry_after}")
    if item.account.success is not None:
        lines.append(f"  成功请求  {item.account.success}")
    if item.account.failed is not None:
        lines.append(f"  失败请求  {item.account.failed}")
    lines.append(f"  Auth Index  {item.account.auth_index}")
    if item.error_message:
        lines.append(c(f"  错误  {item.error_message}", "red"))
    lines.append("")
    lines.append(c("按任意键/点击 返回…", "dim"))
    return "\n".join(lines)


def render_balance_detail(entry: BalanceEntry) -> str:
    lines: list[str] = []
    lines.append(c(f"💳  {entry.name}", "cyan", bold=True))
    lines.append(c(f"状态: {'错误' if entry.error else '正常'}", "dim"))
    lines.append(c("─" * 48, "dim"))
    if entry.error:
        lines.append(c(entry.error, "red"))
    else:
        lines.append(c("余额", bold=True))
        lines.append(f"  可用余额  {entry.balance_text or '--'}")
        if entry.daily_usage_text:
            lines.append(f"  今日消费  {entry.daily_usage_text}")
        if entry.plan_name:
            lines.append(f"  套餐      {entry.plan_name}")
    lines.append("")
    lines.append(c("按任意键/点击 返回…", "dim"))
    return "\n".join(lines)


_MOUSE_RE = re.compile(r"^\x1b\[<(\d+);(\d+);(\d+)([Mm])")


def _read_event(timeout: float = 0.25) -> Optional[str | tuple]:
    if not sys.stdin.isatty():
        return None
    r, _, _ = select.select([sys.stdin], [], [], timeout)
    if not r:
        return None
    ch = sys.stdin.read(1)
    if ch != "\x1b":
        if ch in ("\r", "\n"):
            return "enter"
        return ch

    buf = ch
    while True:
        r2, _, _ = select.select([sys.stdin], [], [], 0.03)
        if not r2:
            break
        buf += sys.stdin.read(1)
        if buf.endswith("M") or buf.endswith("m"):
            break
        if len(buf) >= 3 and buf[1] == "[" and buf[2] in "ABCD":
            break
        if len(buf) > 64:
            break

    m = _MOUSE_RE.match(buf)
    if m:
        btn = int(m.group(1))
        col = int(m.group(2))
        row = int(m.group(3))
        press = m.group(4) == "M"
        if press and btn == 0:
            return ("click", col, row)
        if press and btn in (64, 65):
            return "up" if btn == 64 else "down"
        return None

    if buf == "\x1b":
        return "esc"
    if buf.startswith("\x1b["):
        if buf.endswith("A"):
            return "up"
        if buf.endswith("B"):
            return "down"
        if buf.endswith("C"):
            return "right"
        if buf.endswith("D"):
            return "left"
    return "esc"


def run_panel() -> int:
    """
    Open panel from disk cache only. Never blocks on network.

    Opening / pressing r only detaches a background refresh process;
    this process keeps showing the snapshot loaded at start until quit.
    """
    config = load_configuration()
    snapshot = load_cache() or QuotaSnapshot()
    if not snapshot.balance_entries and not snapshot.account_groups:
        if config.has_balance_sources:
            snapshot.balance_entries = placeholder_balances(config)
        if config.has_any_data_source and not snapshot.accounts:
            snapshot.global_error = "暂无缓存。已可按 r 触发后台刷新，下次打开加载结果。"

    # Fire-and-forget on open (does not wait).
    started, msg = spawn_refresh_async()
    status = msg if started else (msg if is_refresh_running() else "")

    fd = sys.stdin.fileno() if sys.stdin.isatty() else None
    old_settings = None
    if fd is not None:
        old_settings = termios.tcgetattr(fd)
        tty.setcbreak(fd)

    layout = LayoutMeta()
    last_click: tuple[float, int, int] = (0.0, 0, 0)

    try:
        if sys.stdout.isatty():
            sys.stdout.write(HIDE_CURSOR + MOUSE_ON)
            sys.stdout.flush()

        rows = build_rows(snapshot, config)
        selectable = selectable_indices(rows)
        sel_pos = 0
        selected_idx = selectable[sel_pos] if selectable else -1
        selected_key: Optional[str] = rows[selected_idx].key if selected_idx >= 0 else None
        # Clear one-shot open status after first paint cycle
        status_ttl = time.time() + 4.0 if status else 0.0

        while True:
            bg = is_refresh_running()
            rows = build_rows(snapshot, config)
            selectable = selectable_indices(rows)
            if selectable:
                if selected_idx not in selectable:
                    selected_idx, sel_pos = _restore_selection(rows, selectable, selected_key)
                else:
                    sel_pos = selectable.index(selected_idx)
                    selected_key = rows[selected_idx].key
            else:
                selected_idx = -1
                sel_pos = 0
                selected_key = None

            show_status = status if (status and time.time() < status_ttl) else (
                "后台刷新中 · 下次打开见新数据" if bg and not status else status if status else ""
            )
            if status and time.time() >= status_ttl and not bg:
                status = ""

            layout = _draw(snapshot, config, selected_idx, show_status, bg)

            event = _read_event(0.3)
            if event is None:
                continue

            if isinstance(event, tuple) and event[0] == "click":
                _, col, row = event
                now = time.time()
                is_double = (
                    now - last_click[0] < 0.45
                    and last_click[2] == row
                    and abs(last_click[1] - col) <= 2
                )
                last_click = (now, col, row)

                if row == layout.footer_refresh_line:
                    if col <= 12:
                        event = "r"
                    elif col >= 36:
                        event = "q"
                    elif 20 <= col <= 32:
                        event = "o"
                    else:
                        continue
                elif row in layout.row_screen_lines:
                    idx = layout.row_screen_lines[row]
                    if idx < len(rows) and rows[idx].kind in ("balance", "account"):
                        selected_idx = idx
                        selected_key = rows[idx].key
                        if idx in selectable:
                            sel_pos = selectable.index(idx)
                        if is_double:
                            event = "enter"
                        else:
                            continue
                    else:
                        continue
                else:
                    continue

            if event in ("q", "Q", "esc"):
                break
            if event in ("r", "R"):
                ok, message = spawn_refresh_async()
                status = message
                status_ttl = time.time() + 5.0
            elif event in ("o", "O"):
                path = str(config_path())
                try:
                    if sys.platform == "darwin":
                        os.system(f'open "{path}"')  # noqa: S605
                    status = f"配置: {path}"
                    status_ttl = time.time() + 4.0
                except Exception:  # noqa: BLE001
                    status = path
                    status_ttl = time.time() + 4.0
            elif event == "up" and selectable:
                sel_pos = (sel_pos - 1) % len(selectable)
                selected_idx = selectable[sel_pos]
                selected_key = rows[selected_idx].key
            elif event == "down" and selectable:
                sel_pos = (sel_pos + 1) % len(selectable)
                selected_idx = selectable[sel_pos]
                selected_key = rows[selected_idx].key
            elif event == "j" and selectable:
                sel_pos = (sel_pos + 1) % len(selectable)
                selected_idx = selectable[sel_pos]
                selected_key = rows[selected_idx].key
            elif event == "k" and selectable:
                sel_pos = (sel_pos - 1) % len(selectable)
                selected_idx = selectable[sel_pos]
                selected_key = rows[selected_idx].key
            elif event == "enter" and selected_idx >= 0 and selected_idx < len(rows):
                row = rows[selected_idx]
                if row.kind == "account" and row.account:
                    _show_detail(render_account_detail(row.account), fd)
                elif row.kind == "balance" and row.balance:
                    _show_detail(render_balance_detail(row.balance), fd)

        return 0
    finally:
        if sys.stdout.isatty():
            sys.stdout.write(MOUSE_OFF + SHOW_CURSOR + "\n")
            sys.stdout.flush()
        if fd is not None and old_settings is not None:
            termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)


def _restore_selection(
    rows: list[Row],
    selectable: list[int],
    selected_key: Optional[str],
) -> tuple[int, int]:
    if not selectable:
        return -1, 0
    if selected_key:
        for pos, idx in enumerate(selectable):
            if rows[idx].key == selected_key:
                return idx, pos
    return selectable[0], 0


def _draw(
    snapshot: QuotaSnapshot,
    config: AppConfiguration,
    selected_idx: int,
    status: str,
    bg_refreshing: bool = False,
) -> LayoutMeta:
    rows = build_rows(snapshot, config)
    text, meta = render_main(
        snapshot, config, rows, selected_idx, status, bg_refreshing=bg_refreshing
    )
    if sys.stdout.isatty():
        sys.stdout.write(CLEAR + text)
    else:
        sys.stdout.write(text + "\n")
    sys.stdout.flush()
    return meta


def _show_detail(text: str, fd: Optional[int]) -> None:
    if sys.stdout.isatty():
        sys.stdout.write(CLEAR + text)
        sys.stdout.flush()
        if fd is not None:
            while True:
                ev = _read_event(timeout=120.0)
                if ev is not None:
                    break
        else:
            try:
                input()
            except EOFError:
                pass
    else:
        sys.stdout.write(text + "\n")
        sys.stdout.flush()


def print_summary(snapshot: QuotaSnapshot, config: AppConfiguration) -> None:
    rows = build_rows(snapshot, config)
    text, _ = render_main(snapshot, config, rows, selected_idx=-1)
    print(text)
