from __future__ import annotations

import html
import re

_TAG = re.compile(r"<[^>]+>")
_WS = re.compile(r"[ \t\r\f\v]+")


def strip_html(s: str | None) -> str:
    if not s:
        return ""
    s = html.unescape(s)  # Greenhouse double-encodes its HTML
    s = re.sub(r"<(br|/p|/li|/h\d|/div)[^>]*>", "\n", s, flags=re.I)
    s = html.unescape(_TAG.sub(" ", s))
    s = _WS.sub(" ", s)
    return re.sub(r"\n\s*\n+", "\n\n", s).strip()


def norm(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").lower()).strip()
