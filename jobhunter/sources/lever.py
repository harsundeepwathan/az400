from __future__ import annotations

from collections.abc import Iterator
from datetime import datetime, timezone

from .. import http
from ..models import Job, WorkMode
from ..workmode import classify, from_label

API = "https://api.lever.co/v0/postings/{slug}?mode=json"


def parse(slug: str, data: list) -> Iterator[Job]:
    for j in data:
        cats = j.get("categories") or {}
        loc = cats.get("location") or ", ".join(cats.get("allLocations") or [])
        desc = "\n".join(filter(None, [j.get("descriptionPlain"), *(
            f"{li.get('text', '')}\n{li.get('content', '')}" for li in j.get("lists") or []), j.get("additionalPlain")]))
        mode = from_label(j.get("workplaceType"))
        if mode == WorkMode.UNKNOWN:
            mode = classify(loc, desc, j.get("text", ""))
        created = j.get("createdAt")
        yield Job(
            source="lever", ats="lever", company=slug, external_id=j["id"], title=j.get("text", "").strip(),
            url=j.get("hostedUrl", ""), apply_url=j.get("applyUrl") or (j.get("hostedUrl", "") + "/apply"),
            location=loc, work_mode=mode, description=desc,
            posted_at=datetime.fromtimestamp(created / 1000, timezone.utc) if created else None,
            salary=_salary(j.get("salaryRange")), tags=[t for t in [cats.get("team"), cats.get("commitment")] if t],
        )


def fetch(slug: str) -> Iterator[Job]:
    return parse(slug, http.get_json(API.format(slug=slug)))


def _salary(r: dict | None) -> str:
    if not r:
        return ""
    return f"{r.get('min', '')}-{r.get('max', '')} {r.get('currency', '')} / {r.get('interval', '')}".strip()
