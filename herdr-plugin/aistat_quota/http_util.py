"""Minimal urllib helpers (stdlib only). Never log Authorization headers."""

from __future__ import annotations

import json
import ssl
import urllib.error
import urllib.request
from typing import Any, Optional


class HTTPError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status
        self.message = message


def request_json(
    method: str,
    url: str,
    *,
    headers: Optional[dict[str, str]] = None,
    body: Optional[dict[str, Any] | list[Any] | bytes] = None,
    timeout: float = 30.0,
) -> Any:
    data: Optional[bytes]
    if body is None:
        data = None
    elif isinstance(body, bytes):
        data = body
    else:
        data = json.dumps(body).encode("utf-8")

    req_headers = dict(headers or {})
    if data is not None and "Content-Type" not in req_headers:
        req_headers["Content-Type"] = "application/json"
    if "Accept" not in req_headers:
        req_headers["Accept"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=req_headers, method=method.upper())
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            raw = resp.read()
            status = getattr(resp, "status", None) or resp.getcode()
            if status is not None and not (200 <= int(status) < 300):
                snippet = raw[:240].decode("utf-8", errors="replace").strip()
                raise HTTPError(int(status), snippet or "unknown error")
            if not raw:
                if method.upper() == "PATCH":
                    return {}
                raise HTTPError(-1, "空响应")
            return json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as e:
        snippet = ""
        try:
            snippet = e.read()[:240].decode("utf-8", errors="replace").strip()
        except Exception:
            pass
        raise HTTPError(e.code, snippet or e.reason or "unknown error") from None
    except urllib.error.URLError as e:
        raise HTTPError(-1, str(e.reason or e)) from None
    except json.JSONDecodeError as e:
        raise HTTPError(-1, f"解析失败: {e}") from None
