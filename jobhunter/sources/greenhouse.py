from __future__ import annotations

from collections.abc import Iterator
from datetime import datetime

from .. import http
from ..models import Job
from ..text import strip_html
from ..workmode import classify

API = "https://boards-api.greenhouse.io/v1/boards/{slug}/jobs?content=true"


def parse(slug: str, data: dict) -> Iterator[Job]:
    for j in data.get("jobs", []):
        loc = (j.get("location") or {}).get("name", "")
        desc = strip_html(j.get("content"))
        url = j.get("absolute_url", "")
        # Some boards put only "Hybrid"/"Remote" in location; the cities live in offices/metadata.
        geo = [o.get("location") or o.get("name", "") for o in j.get("offices") or []]
        for m in j.get("metadata") or []:
            if "location" in (m.get("name") or "").lower() and m.get("value"):
                geo += m["value"] if isinstance(m["value"], list) else [str(m["value"])]
        extra = "; ".join(g for g in dict.fromkeys(geo) if g and g.lower() not in loc.lower())
        full_loc = " - ".join(x for x in [loc, extra] if x)
        yield Job(
            source="greenhouse", ats="greenhouse", company=slug, external_id=str(j["id"]),
            title=j.get("title", "").strip(), url=url, apply_url=url,
            location=full_loc, work_mode=classify(full_loc, desc, j.get("title", "")),
            description=desc, posted_at=_dt(j.get("first_published") or j.get("updated_at")),
        )


def fetch(slug: str) -> Iterator[Job]:
    return parse(slug, http.get_json(API.format(slug=slug)))


def _dt(s: str | None) -> datetime | None:
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None
    except ValueError:
        return None
