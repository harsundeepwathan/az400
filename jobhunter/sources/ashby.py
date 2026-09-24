from __future__ import annotations

from collections.abc import Iterator
from datetime import datetime

from .. import http
from ..models import Job, WorkMode
from ..workmode import classify, from_label

API = "https://api.ashbyhq.com/posting-api/job-board/{slug}?includeCompensation=true"


def parse(slug: str, data: dict) -> Iterator[Job]:
    for j in data.get("jobs", []):
        if j.get("isListed") is False:
            continue
        locs = [j.get("location", "")] + [s.get("location", "") for s in j.get("secondaryLocations") or []]
        loc = "; ".join(x for x in locs if x)
        desc = j.get("descriptionPlain") or ""
        mode = from_label(j.get("workplaceType"))
        if mode == WorkMode.UNKNOWN:
            mode = WorkMode.REMOTE if j.get("isRemote") else classify(loc, desc, j.get("title", ""))
        url = j.get("jobUrl", "")
        yield Job(
            source="ashby", ats="ashby", company=slug, external_id=j["id"], title=j.get("title", "").strip(),
            url=url, apply_url=j.get("applyUrl") or f"{url}/application", location=loc, work_mode=mode,
            description=desc, posted_at=_dt(j.get("publishedAt")),
            salary=((j.get("compensation") or {}).get("compensationTierSummary") or ""),
        )


def fetch(slug: str) -> Iterator[Job]:
    return parse(slug, http.get_json(API.format(slug=slug)))


def _dt(s: str | None) -> datetime | None:
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None
    except ValueError:
        return None
