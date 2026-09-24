"""Public job aggregator APIs. Please respect their terms: RemoteOK asks for a link back."""
from __future__ import annotations

import re
from collections.abc import Iterator
from datetime import datetime, timezone
from urllib.parse import quote

from .. import http
from ..models import Job, WorkMode
from ..text import norm, strip_html
from ..workmode import classify
from .detect import detect_ats


def _job(source: str, ext_id: str, company: str, title: str, url: str, apply_url: str, loc: str,
         mode: WorkMode, desc: str, posted: datetime | None, salary: str = "", tags=None) -> Job:
    ats, slug, ats_id = detect_ats(apply_url or url)
    return Job(source=source, ats=ats or source, company=slug or norm(company).replace(" ", "-"),
               external_id=ats_id or ext_id, title=title.strip(), url=url, apply_url=apply_url or url,
               location=loc, work_mode=mode, description=desc, posted_at=posted, salary=salary, tags=tags or [])


def remotive(query: str) -> Iterator[Job]:
    data = http.get_json(f"https://remotive.com/api/remote-jobs?search={quote(query)}")
    for j in data.get("jobs", []):
        yield _job("remotive", str(j["id"]), j.get("company_name", ""), j.get("title", ""), j.get("url", ""),
                   j.get("url", ""), j.get("candidate_required_location") or "Remote", WorkMode.REMOTE,
                   strip_html(j.get("description")), _iso(j.get("publication_date")), j.get("salary", ""),
                   j.get("tags"))


def remoteok(keywords: list[str]) -> Iterator[Job]:
    data = http.get_json("https://remoteok.com/api")
    kws = [norm(k) for k in keywords]
    for j in data[1:]:  # element 0 is the legal notice
        text = norm(" ".join([j.get("position", ""), " ".join(j.get("tags") or [])]))
        if kws and not any(k in text for k in kws):
            continue
        sal = f"{j.get('salary_min')}-{j.get('salary_max')} USD" if j.get("salary_max") else ""
        yield _job("remoteok", str(j["id"]), j.get("company", ""), j.get("position", ""), j.get("url", ""),
                   j.get("apply_url") or j.get("url", ""), j.get("location") or "Remote", WorkMode.REMOTE,
                   strip_html(j.get("description")), _iso(j.get("date")), sal, j.get("tags"))


def arbeitnow(pages: int = 3) -> Iterator[Job]:
    url = "https://www.arbeitnow.com/api/job-board-api"
    for _ in range(pages):
        data = http.get_json(url)
        for j in data.get("data", []):
            desc = strip_html(j.get("description"))
            loc = j.get("location", "")
            mode = WorkMode.REMOTE if j.get("remote") else classify(loc, desc, j.get("title", ""))
            posted = datetime.fromtimestamp(j["created_at"], timezone.utc) if j.get("created_at") else None
            yield _job("arbeitnow", j["slug"], j.get("company_name", ""), j.get("title", ""), j.get("url", ""),
                       j.get("url", ""), loc, mode, desc, posted, tags=j.get("tags"))
        url = (data.get("links") or {}).get("next")
        if not url:
            break


def _iso(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        d = datetime.fromisoformat(re.sub(r"Z$", "+00:00", s))
        return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
    except ValueError:
        return None
