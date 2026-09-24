"""Scan the web for companies hiring for your titles on auto-appliable ATS boards.

Runs searches like  site:apply.workable.com "DevOps Engineer" hybrid  through a search API
and harvests the company slugs from result URLs. Discovered slugs are saved to
data/discovered_companies.yaml and fed into the board sources on every run.

Supported search APIs (set one): SERPAPI_KEY, BRAVE_API_KEY, or GOOGLE_CSE_KEY + GOOGLE_CSE_ID.
"""
from __future__ import annotations

import logging
import os
from pathlib import Path
from urllib.parse import urlencode

import yaml

from .. import http
from .detect import detect_ats

log = logging.getLogger(__name__)

SITES = {
    "workable": "apply.workable.com",
    "greenhouse": "job-boards.greenhouse.io",
    "lever": "jobs.lever.co",
    "ashby": "jobs.ashbyhq.com",
}


def _search(q: str) -> list[str]:
    if key := os.environ.get("SERPAPI_KEY"):
        d = http.get_json("https://serpapi.com/search.json?" + urlencode({"q": q, "api_key": key, "num": 50}))
        return [r.get("link", "") for r in d.get("organic_results", [])]
    if key := os.environ.get("BRAVE_API_KEY"):
        d = http.get_json("https://api.search.brave.com/res/v1/web/search?" + urlencode({"q": q, "count": 20}),
                          headers={"X-Subscription-Token": key, "Accept": "application/json"})
        return [r.get("url", "") for r in (d.get("web") or {}).get("results", [])]
    if (key := os.environ.get("GOOGLE_CSE_KEY")) and (cx := os.environ.get("GOOGLE_CSE_ID")):
        d = http.get_json("https://www.googleapis.com/customsearch/v1?" + urlencode({"q": q, "key": key, "cx": cx}))
        return [r.get("link", "") for r in d.get("items", [])]
    raise RuntimeError("no search API key set (SERPAPI_KEY, BRAVE_API_KEY or GOOGLE_CSE_KEY+GOOGLE_CSE_ID)")


def queries(cfg: dict) -> list[str]:
    s = cfg["search"]
    titles = s.get("titles") or s.get("keywords") or []
    modes = s.get("work_modes") or []
    places = s.get("locations") or []
    out = []
    for ats in cfg["apply"].get("ats", SITES):
        site = SITES.get(ats)
        if not site:
            continue
        for t in titles:
            out.append(f'site:{site} "{t}"' + (" remote" if modes == ["remote"] else ""))
            for p in places[:2]:
                if set(modes) & {"hybrid", "onsite"}:
                    out.append(f'site:{site} "{t}" "{p}"')
    return out[: int(cfg["discovery"].get("max_queries", 20))]


def discover(cfg: dict) -> dict[str, list[str]]:
    path = Path(cfg["data_dir"]) / "discovered_companies.yaml"
    found: dict[str, set[str]] = {k: set(v or []) for k, v in (yaml.safe_load(path.read_text()) if path.exists() else {}).items()}
    for q in queries(cfg):
        try:
            urls = _search(q)
        except Exception as e:  # noqa: BLE001
            log.warning("discovery query failed (%s): %s", q, e)
            if "no search API key" in str(e):
                break
            continue
        for u in urls:
            ats, slug, _ = detect_ats(u)
            if ats and slug:
                found.setdefault(ats, set()).add(slug)
    result = {k: sorted(v) for k, v in found.items()}
    path.write_text(yaml.safe_dump(result))
    log.info("discovery: %s", {k: len(v) for k, v in result.items()})
    return result


def load_discovered(cfg: dict) -> None:
    """Merge previously discovered slugs into cfg['companies']."""
    path = Path(cfg["data_dir"]) / "discovered_companies.yaml"
    if not path.exists():
        return
    for ats, slugs in (yaml.safe_load(path.read_text()) or {}).items():
        cfg["companies"][ats] = sorted(set(cfg["companies"].get(ats, [])) | set(slugs or []))
