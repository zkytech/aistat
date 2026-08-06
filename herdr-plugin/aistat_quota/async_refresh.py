"""Fire-and-forget refresh: spawn a detached process, never wait for network."""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

from .config import aistat_support_dir, cache_path


def _state_dir() -> Path:
    state = os.environ.get("HERDR_PLUGIN_STATE_DIR", "").strip()
    if state:
        return Path(state)
    # Same fallback as cache when not under Herdr.
    return aistat_support_dir()


def lock_path() -> Path:
    return _state_dir() / "refresh.lock"


def log_path() -> Path:
    return _state_dir() / "refresh.log"


def is_refresh_running(stale_seconds: float = 600.0) -> bool:
    """True if a previous fire-and-forget refresh still holds the lock."""
    path = lock_path()
    if not path.is_file():
        return False
    try:
        raw = path.read_text(encoding="utf-8").strip()
        pid_s, started_s = (raw.split() + ["0", "0"])[:2]
        pid = int(pid_s)
        started = float(started_s)
    except (OSError, ValueError):
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        return False

    # Stale lock
    if time.time() - started > stale_seconds:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        return False

    if pid <= 0:
        return True
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        return False


def plugin_root() -> Path:
    return Path(__file__).resolve().parent.parent


def spawn_refresh_async() -> tuple[bool, str]:
    """
    Start `python3 -m aistat_quota refresh` in a fully detached process.

    Returns (started, message). Never waits for network I/O.
    """
    if is_refresh_running():
        return False, "后台刷新已在进行，下次打开面板会看到结果"

    root = plugin_root()
    state = _state_dir()
    try:
        state.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass

    # Soft lock before spawn (refresh command also writes a proper lock with its pid).
    try:
        lock_path().write_text(f"0 {time.time():.3f}\n", encoding="utf-8")
    except OSError:
        pass

    log = log_path()
    try:
        log_f = open(log, "a", encoding="utf-8")  # noqa: SIM115 — kept open for child
    except OSError:
        log_f = subprocess.DEVNULL

    env = os.environ.copy()
    # Preserve Herdr plugin dirs so cache lands in the same place as the panel.
    env.setdefault("PYTHONUNBUFFERED", "1")

    try:
        # Write a header so refresh.log is inspectable without secrets.
        if log_f is not subprocess.DEVNULL:
            log_f.write(f"\n--- spawn {time.strftime('%Y-%m-%d %H:%M:%S')} cache={cache_path()}\n")
            log_f.flush()

        subprocess.Popen(
            [sys.executable, "-m", "aistat_quota", "refresh", "--background"],
            cwd=str(root),
            stdin=subprocess.DEVNULL,
            stdout=log_f,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            env=env,
            close_fds=True,
        )
    except OSError as e:
        try:
            lock_path().unlink(missing_ok=True)
        except OSError:
            pass
        if log_f is not subprocess.DEVNULL:
            try:
                log_f.close()
            except OSError:
                pass
        return False, f"无法启动后台刷新: {e}"

    if log_f is not subprocess.DEVNULL:
        try:
            log_f.close()
        except OSError:
            pass

    return True, "已触发后台刷新，下次打开面板加载新数据"
