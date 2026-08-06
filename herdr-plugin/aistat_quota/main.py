"""CLI entrypoints for Herdr actions / panes."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path


def _herdr_bin() -> str:
    return os.environ.get("HERDR_BIN_PATH") or "herdr"


def cmd_open(_args: argparse.Namespace) -> int:
    """Open the main quota pane via Herdr CLI when available; else run panel inline."""
    herdr = _herdr_bin()
    plugin_id = os.environ.get("HERDR_PLUGIN_ID", "aistat.quota")
    # Prefer Herdr pane open when socket is available.
    try:
        result = subprocess.run(
            [
                herdr,
                "plugin",
                "pane",
                "open",
                "--plugin",
                plugin_id,
                "--entrypoint",
                "main",
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0:
            if result.stdout:
                sys.stdout.write(result.stdout)
            return 0
        # Fall through to inline panel if Herdr cannot open pane (e.g. no server).
        if result.stderr:
            sys.stderr.write(result.stderr)
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass

    from .tui import run_panel

    return run_panel()


def cmd_panel(_args: argparse.Namespace) -> int:
    from .tui import run_panel

    return run_panel()


def cmd_refresh(_args: argparse.Namespace) -> int:
    """Blocking refresh (for CLI / background worker). Writes cache then exits."""
    import time

    from .async_refresh import lock_path
    from .config import config_path, load_configuration
    from .store import load_cache, refresh

    config = load_configuration()
    if not config.has_any_data_source:
        print("未配置任何数据源。请编辑 AIstat 配置：")
        print(config_path())
        return 1

    lock = lock_path()
    if getattr(_args, "background", False):
        try:
            lock.parent.mkdir(parents=True, exist_ok=True)
            lock.write_text(f"{os.getpid()} {time.time():.3f}\n", encoding="utf-8")
        except OSError:
            pass

    try:
        prev = load_cache()
        snap = refresh(config, previous=prev)
        n_acc = len(snap.accounts)
        n_bal = len(snap.balance_entries)
        print(f"已刷新：{n_bal} 个余额源，{n_acc} 个订阅账号。")
        if snap.last_refresh_at:
            print(f"时间：{snap.last_refresh_at.isoformat()}")
        return 0
    finally:
        if getattr(_args, "background", False):
            try:
                lock.unlink(missing_ok=True)
            except OSError:
                pass


def cmd_show(_args: argparse.Namespace) -> int:
    """Print summary from cache only (use --force to block on network)."""
    from .config import load_configuration
    from .store import QuotaSnapshot, load_cache, refresh
    from .tui import print_summary

    config = load_configuration()
    snap = load_cache()
    if _args.force:
        if config.has_any_data_source:
            snap = refresh(config, previous=snap)
        else:
            snap = QuotaSnapshot(global_error="请先在设置中配置 CLIProxyAPI、Sub2API 或 DeepSeek。")
    if snap is None:
        snap = QuotaSnapshot(
            global_error="暂无缓存。按 r 触发后台刷新，下次打开即可看到数据。"
            if config.has_any_data_source
            else "请先在设置中配置 CLIProxyAPI、Sub2API 或 DeepSeek。"
        )
    print_summary(snap, config)
    return 0


def main(argv: list[str] | None = None) -> int:
    # Ensure plugin root is on sys.path when launched as `python3 -m aistat_quota`
    # from herdr-plugin/ cwd (Herdr sets cwd to plugin root).
    root = Path(__file__).resolve().parent.parent
    if str(root) not in sys.path:
        sys.path.insert(0, str(root))

    parser = argparse.ArgumentParser(prog="aistat-quota", description="AIstat Quota Herdr plugin")
    sub = parser.add_subparsers(dest="command", required=True)

    p_open = sub.add_parser("open", help="打开额度面板（plugin.pane.open 或内嵌）")
    p_open.set_defaults(func=cmd_open)

    p_panel = sub.add_parser("panel", help="运行交互式主面板（pane entrypoint）")
    p_panel.set_defaults(func=cmd_panel)

    p_refresh = sub.add_parser("refresh", help="拉取额度并写入缓存（阻塞；后台 worker 用）")
    p_refresh.add_argument(
        "--background",
        action="store_true",
        help="后台 worker 模式：维护 refresh.lock",
    )
    p_refresh.set_defaults(func=cmd_refresh)

    p_show = sub.add_parser("show", help="打印额度摘要（默认只读缓存）")
    p_show.add_argument("--force", action="store_true", help="阻塞拉取网络（面板不会用）")
    p_show.set_defaults(func=cmd_show)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
