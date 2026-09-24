"""Recognise which ATS hosts a URL, so aggregator jobs can still be auto-applied."""
from __future__ import annotations

import re

PATTERNS = [
    ("workable", re.compile(r"apply\.workable\.com/(?:j/)?([\w-]+)(?:/j/([A-Z0-9]+))?", re.I)),
    ("workable", re.compile(r"([\w-]+)\.workable\.com/(?:jobs|j)/(\w+)", re.I)),
    ("greenhouse", re.compile(r"(?:job-)?boards(?:\.eu)?\.greenhouse\.io/(?:embed/job_app\?for=)?([\w-]+)(?:/jobs/(\d+))?", re.I)),
    ("lever", re.compile(r"jobs(?:\.eu)?\.lever\.co/([\w.-]+)(?:/([0-9a-f-]{36}))?", re.I)),
    ("ashby", re.compile(r"jobs\.ashbyhq\.com/([\w.%-]+)(?:/([0-9a-f-]{36}))?", re.I)),
]


def detect_ats(url: str) -> tuple[str | None, str | None, str | None]:
    """Return (ats, company_slug, job_id) or (None, None, None)."""
    for ats, pat in PATTERNS:
        m = pat.search(url or "")
        if m:
            slug = m.group(1)
            if ats == "workable" and slug.lower() in ("api", "j"):
                continue
            return ats, slug.lower(), m.group(2)
    return None, None, None
