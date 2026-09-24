"""Adzuna aggregates most major boards across ~20 countries, including hybrid/onsite roles.

Needs a free API key (developer.adzuna.com): set ADZUNA_APP_ID / ADZUNA_APP_KEY.
"""
from __future__ import annotations

import os
from collections.abc import Iterator
from urllib.parse import urlencode

from .. import http
from ..models import Job
from ..text import strip_html
from ..workmode import classify
from .aggregators import _iso, _job


def fetch(query: str, where: str, opts: dict) -> Iterator[Job]:
    app_id, app_key = os.environ.get("ADZUNA_APP_ID"), os.environ.get("ADZUNA_APP_KEY")
    if not (app_id and app_key):
        raise RuntimeError("ADZUNA_APP_ID / ADZUNA_APP_KEY not set")
    country = opts.get("country", "us")
    for page in range(1, int(opts.get("pages", 2)) + 1):
        params = {"app_id": app_id, "app_key": app_key, "what": query, "results_per_page": 50,
                  "max_days_old": opts.get("max_days_old", 30), "content-type": "application/json"}
        if where:
            params["where"] = where
        data = http.get_json(f"https://api.adzuna.com/v1/api/jobs/{country}/search/{page}?{urlencode(params)}")
        for j in data.get("results", []):
            loc = (j.get("location") or {}).get("display_name", "")
            desc = strip_html(j.get("description"))
            sal = f"{j.get('salary_min', '')}-{j.get('salary_max', '')}" if j.get("salary_max") else ""
            yield _job("adzuna", str(j["id"]), (j.get("company") or {}).get("display_name", ""), j.get("title", ""),
                       j.get("redirect_url", ""), j.get("redirect_url", ""), loc,
                       classify(loc, desc, j.get("title", "")), desc, _iso(j.get("created")), sal)
        if len(data.get("results", [])) < 50:
            break
