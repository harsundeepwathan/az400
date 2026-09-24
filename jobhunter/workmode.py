"""Classify a posting as remote / hybrid / onsite and check it against the user's preferences."""
from __future__ import annotations

import re

from .models import Job, WorkMode
from .text import norm

_EXPLICIT = {
    "remote": WorkMode.REMOTE, "fully remote": WorkMode.REMOTE, "telecommute": WorkMode.REMOTE,
    "hybrid": WorkMode.HYBRID,
    "onsite": WorkMode.ONSITE, "on-site": WorkMode.ONSITE, "on_site": WorkMode.ONSITE,
    "on site": WorkMode.ONSITE, "office": WorkMode.ONSITE, "in office": WorkMode.ONSITE,
    "in_office": WorkMode.ONSITE, "in-person": WorkMode.ONSITE,
}

_HYBRID = re.compile(r"\bhybrid\b|\b\d\s*(?:days?|x)\s*(?:per|a|/)\s*week in (?:the )?office|\bflexible (?:office|work) (?:model|arrangement)")
_REMOTE = re.compile(r"\b(?:fully |100% |remote[- ]first|work from home|wfh|remote)\b")
_ONSITE = re.compile(r"\bon[- ]?site\b|\bin[- ]office\b|\bin[- ]person\b|\boffice[- ]based\b")


def from_label(label: str | None) -> WorkMode:
    """Map an ATS-provided workplace field (e.g. Ashby 'OnSite', Workable 'on_site')."""
    if not label:
        return WorkMode.UNKNOWN
    return _EXPLICIT.get(norm(label), WorkMode.UNKNOWN)


def classify(location: str, description: str = "", title: str = "") -> WorkMode:
    """Heuristic classification when the ATS gives no structured field.

    Location wins over description: "Remote - US" in the location is decisive, while a
    description that merely mentions "remote" (e.g. "remote-friendly team") is weaker.
    """
    if norm(location) in ("distributed", "anywhere", "worldwide"):
        return WorkMode.REMOTE
    loc = norm(location) + " " + norm(title)
    if _HYBRID.search(loc):
        return WorkMode.HYBRID
    if _REMOTE.search(loc):
        return WorkMode.REMOTE
    if _ONSITE.search(loc):
        return WorkMode.ONSITE
    desc = norm(description)[:6000]
    if _HYBRID.search(desc):
        return WorkMode.HYBRID
    if re.search(r"\b(?:fully remote|100% remote|remote position|remote role|work from anywhere)\b", desc):
        return WorkMode.REMOTE
    if _ONSITE.search(desc):
        return WorkMode.ONSITE
    return WorkMode.ONSITE if location.strip() else WorkMode.UNKNOWN


def location_ok(job: Job, search: dict) -> tuple[bool, str]:
    """Does this job fit the user's work-mode and location preferences?"""
    wanted = {WorkMode(m) for m in search.get("work_modes", [])}
    mode = job.work_mode
    if mode == WorkMode.UNKNOWN:
        if not search.get("include_unknown_work_mode", True):
            return False, "work mode unknown"
    elif mode not in wanted:
        return False, f"{mode.value} not wanted"

    loc = norm(job.location)
    if mode == WorkMode.REMOTE:
        regions = [norm(r) for r in search.get("remote_regions", [])]
        # A remote role with no stated restriction is fine; otherwise it must mention one of the regions.
        if not loc or loc in ("remote", "anywhere") or not regions:
            return True, "remote"
        if any(r in loc for r in regions):
            return True, "remote (region match)"
        # "Remote - Canada" when the user lists "Canada" as an on-site location is also fine.
        if any(norm(p) in loc for p in search.get("locations", [])):
            return True, "remote (location match)"
        return False, f"remote region '{job.location}' not in remote_regions"

    places = [norm(p) for p in search.get("locations", [])]
    if not places:
        return True, "no location filter"
    if any(p in loc for p in places):
        return True, "location match"
    if not loc:
        return mode == WorkMode.UNKNOWN, "no location given"
    return False, f"location '{job.location}' not in preferred locations"
