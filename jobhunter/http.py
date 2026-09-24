from __future__ import annotations

import logging
import time
from typing import Any

import httpx

log = logging.getLogger(__name__)

USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) jobhunter/0.1 (+personal job search)"

_client: httpx.Client | None = None


def client() -> httpx.Client:
    global _client
    if _client is None:
        _client = httpx.Client(
            timeout=30, follow_redirects=True, headers={"User-Agent": USER_AGENT}
        )
    return _client


def request_json(method: str, url: str, retries: int = 3, **kw: Any) -> Any:
    """GET/POST returning parsed JSON, with polite backoff on 429/5xx."""
    delay = 2.0
    for attempt in range(retries):
        try:
            r = client().request(method, url, **kw)
            if r.status_code in (429, 500, 502, 503, 504) and attempt < retries - 1:
                wait = float(r.headers.get("retry-after") or delay)
                log.info("%s %s -> %s, retrying in %.0fs", method, url, r.status_code, wait)
                time.sleep(min(wait, 60))
                delay *= 2
                continue
            r.raise_for_status()
            return r.json()
        except (httpx.TransportError, ValueError) as e:
            if attempt == retries - 1:
                raise
            log.info("%s %s failed (%s), retrying", method, url, e)
            time.sleep(delay)
            delay *= 2
    raise RuntimeError("unreachable")


def get_json(url: str, **kw: Any) -> Any:
    return request_json("GET", url, **kw)


def post_json(url: str, payload: Any, **kw: Any) -> Any:
    return request_json("POST", url, json=payload, **kw)
