"""Job feeds. Each source yields `Job`s from a public, documented endpoint.

Company-hosted ATS boards (Greenhouse, Lever, Ashby, Workable) are where auto-apply works,
so they're the core. Aggregators (Remotive, RemoteOK, Arbeitnow, Adzuna) widen the net;
their jobs are applied to automatically only when the apply link resolves to a supported ATS.
"""
from __future__ import annotations

import logging
from collections.abc import Iterable, Iterator

from ..models import Job
from . import adzuna, aggregators, ashby, greenhouse, lever, workable

log = logging.getLogger(__name__)

BOARD_SOURCES = {
    "greenhouse": greenhouse.fetch,
    "lever": lever.fetch,
    "ashby": ashby.fetch,
    "workable": workable.fetch,
}


def collect(cfg: dict) -> Iterator[Job]:
    enabled = cfg["sources"]
    search = cfg["search"]
    queries = list(search.get("titles") or []) or list(search.get("keywords") or [])[:3]

    for ats, fetch in BOARD_SOURCES.items():
        if not enabled.get(ats):
            continue
        for slug in cfg["companies"].get(ats, []):
            yield from _safe(f"{ats}:{slug}", fetch(slug))

    if enabled.get("remotive"):
        for q in queries or [""]:
            yield from _safe(f"remotive:{q}", aggregators.remotive(q))
    if enabled.get("remoteok"):
        yield from _safe("remoteok", aggregators.remoteok(search.get("keywords") or []))
    if enabled.get("arbeitnow"):
        yield from _safe("arbeitnow", aggregators.arbeitnow())
    if enabled.get("adzuna"):
        for q in queries:
            for where in search.get("locations") or [""]:
                yield from _safe(f"adzuna:{q}:{where}", adzuna.fetch(q, where, cfg.get("adzuna", {})))


def _safe(label: str, it: Iterable[Job]) -> Iterator[Job]:
    """One broken board must not kill the whole run."""
    n = 0
    try:
        for job in it:
            n += 1
            yield job
    except Exception as e:  # noqa: BLE001 - network/API shape errors are logged and skipped
        log.warning("source %s failed: %s", label, e)
    log.info("source %s: %d jobs", label, n)
