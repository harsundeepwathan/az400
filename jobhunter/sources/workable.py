"""Workable career sites (apply.workable.com/<account>).

Uses the same JSON endpoints the public careers page calls. The v3 endpoint gives a
structured `workplace` field (remote / hybrid / on_site); the older widget endpoint is a
fallback for accounts where v3 is unavailable.
"""
from __future__ import annotations

from collections.abc import Iterator
from datetime import datetime

from .. import http
from ..models import Job, WorkMode
from ..text import strip_html
from ..workmode import classify, from_label

V3 = "https://apply.workable.com/api/v3/accounts/{slug}/jobs"
V2_JOB = "https://apply.workable.com/api/v2/accounts/{slug}/jobs/{code}"
WIDGET = "https://apply.workable.com/api/v1/widget/accounts/{slug}?details=true"
APPLY = "https://apply.workable.com/{slug}/j/{code}/apply/"


def _loc(j: dict) -> str:
    loc = j.get("location") or {}
    if isinstance(loc, dict):
        return ", ".join(x for x in [loc.get("city"), loc.get("region"), loc.get("country")] if x)
    return ", ".join(x for x in [j.get("city"), j.get("state"), j.get("country")] if x) or str(loc or "")


def parse_v3(slug: str, results: list[dict]) -> Iterator[Job]:
    for j in results:
        code = j["shortcode"]
        loc = _loc(j)
        mode = from_label(j.get("workplace"))
        if mode == WorkMode.UNKNOWN:
            mode = WorkMode.REMOTE if j.get("remote") else classify(loc, "", j.get("title", ""))
        yield Job(
            source="workable", ats="workable", company=slug, external_id=code, title=j.get("title", "").strip(),
            url=f"https://apply.workable.com/{slug}/j/{code}/", apply_url=APPLY.format(slug=slug, code=code),
            location=loc, work_mode=mode, posted_at=_dt(j.get("published")),
            tags=[t for t in [j.get("department") and str(j.get("department")), j.get("type")] if t],
        )


def parse_widget(slug: str, data: dict) -> Iterator[Job]:
    for j in data.get("jobs", []):
        code = j.get("shortcode") or j.get("url", "").rstrip("/").split("/")[-1]
        loc = _loc(j)
        desc = strip_html(j.get("description"))
        mode = WorkMode.REMOTE if j.get("telecommuting") else classify(loc, desc, j.get("title", ""))
        yield Job(
            source="workable", ats="workable", company=slug, external_id=code, title=j.get("title", "").strip(),
            url=j.get("url") or f"https://apply.workable.com/{slug}/j/{code}/",
            apply_url=APPLY.format(slug=slug, code=code), location=loc, work_mode=mode,
            description=desc, posted_at=_dt(j.get("published_on") or j.get("created_at")),
        )


def fetch(slug: str) -> Iterator[Job]:
    try:
        results, token = [], None
        for _ in range(20):  # pagination guard
            body = {"query": "", "location": [], "department": [], "worktype": [], "remote": []}
            if token:
                body["token"] = token
            data = http.post_json(V3.format(slug=slug), body)
            results += data.get("results", [])
            token = data.get("nextPage")
            if not token:
                break
        yield from parse_v3(slug, results)
    except Exception:  # noqa: BLE001 - fall back to the legacy widget API
        yield from parse_widget(slug, http.get_json(WIDGET.format(slug=slug)))


def fetch_description(job: Job) -> str:
    """v3 listings have no description; fetch it lazily only for jobs worth scoring."""
    try:
        d = http.get_json(V2_JOB.format(slug=job.company, code=job.external_id))
    except Exception:  # noqa: BLE001
        return ""
    return "\n".join(strip_html(d.get(k)) for k in ("description", "requirements", "benefits") if d.get(k))


def _dt(s: str | None) -> datetime | None:
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None
    except ValueError:
        return None
