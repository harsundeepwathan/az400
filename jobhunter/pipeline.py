"""discover -> search -> score -> apply, each step idempotent over the SQLite store."""
from __future__ import annotations

import json
import logging
from pathlib import Path

from .apply.browser import Applier
from .llm import get_llm
from .matcher import keyword_score, too_old
from .models import Status, WorkMode
from .resume import parse_resume
from .sources import collect
from .sources import workable as workable_src
from .sources.discovery import discover, load_discovered
from .store import Store, row_to_job
from .workmode import location_ok

log = logging.getLogger(__name__)


class Pipeline:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.store = Store(Path(cfg["data_dir"]) / "jobs.db")
        self._resume = None
        self._llm = False

    @property
    def resume(self):
        if self._resume is None:
            s = self.cfg["search"]
            self._resume = parse_resume(self.cfg["resume_path"], s.get("keywords"), s.get("titles"))
            log.info("resume: %d skills, ~%s yrs: %s", len(self._resume.skills), self._resume.years_experience,
                     ", ".join(sorted(self._resume.skills)[:25]))
        return self._resume

    @property
    def llm(self):
        if self._llm is False:
            self._llm = get_llm(self.cfg)
        return self._llm

    def discover(self) -> None:
        discover(self.cfg)

    def search(self) -> int:
        load_discovered(self.cfg)
        new = 0
        for job in collect(self.cfg):
            new += self.store.upsert(job)
        log.info("search: %d new jobs", new)
        return new

    def score(self) -> int:
        s = self.cfg["search"]
        rows = self.store.by_status(Status.NEW, order="first_seen")
        passed = []
        for r in rows:
            job = row_to_job(r)
            ok, why = location_ok(job, s)
            if not ok or too_old(job, s.get("max_age_days")):
                self.store.set_score(job.uid, 0, [why if not ok else "posting too old"], Status.SKIPPED)
                continue
            if job.ats == "workable" and not job.description:
                job.description = workable_src.fetch_description(job)
                self.store.set_description(job.uid, job.description)
            score, reasons = keyword_score(job, self.resume, s)
            passed.append((score, reasons, job))

        # Claude re-scores the most promising candidates (keyword score is a cheap pre-filter).
        passed.sort(key=lambda x: -x[0])
        min_score = float(s.get("min_score", 55))
        top_n = int(self.cfg["llm"].get("rescore_top", 40)) if self.llm else 0
        matched = 0
        for i, (score, reasons, job) in enumerate(passed):
            if i < top_n and score >= min_score * 0.6:
                fit = self.llm.score(self.resume.text, self.cfg, job)
                if fit:
                    score = 0.3 * score + 0.7 * fit.score
                    reasons = [f"claude {fit.score}: " + "; ".join(fit.reasons)] + (
                        ["missing: " + ", ".join(fit.missing)] if fit.missing else []) + reasons
                    if job.work_mode == WorkMode.UNKNOWN and fit.work_mode != "unknown":
                        job.work_mode = WorkMode(fit.work_mode)
                        ok, why = location_ok(job, s)
                        if not ok:
                            self.store.set_score(job.uid, score, [why] + reasons, Status.SKIPPED)
                            continue
            status = Status.MATCHED if score >= min_score else Status.SKIPPED
            matched += status == Status.MATCHED
            self.store.set_score(job.uid, round(score, 1), reasons, status)
        log.info("score: %d scored, %d matched (>= %s)", len(rows), matched, min_score)
        return matched

    def apply(self, limit: int | None = None, uid: str | None = None) -> dict[str, int]:
        a = self.cfg["apply"]
        if not a.get("enabled") and not uid:
            log.info("apply disabled in profile.yaml")
            return {}
        supported = set(a.get("ats") or [])
        budget = max(0, int(a.get("daily_limit", 15)) - self.store.applied_today())
        if limit is not None:
            budget = min(budget, limit)
        rows = [r for r in self.store.by_status(Status.MATCHED) if not uid or r["uid"] == uid]
        if uid and not rows:
            rows = [r for r in self.store.all() if r["uid"] == uid]
        todo = []
        for r in rows:
            if r["ats"] not in supported:
                self.store.set_status(r["uid"], Status.MANUAL, f"{r['ats']} not automated - apply at {r['apply_url']}")
            else:
                todo.append(r)
        todo = todo[:budget]
        counts: dict[str, int] = {}
        if not todo:
            log.info("apply: nothing to do (daily budget left: %d)", budget)
            return counts
        with Applier(self.cfg, self.resume.text, self.llm) as ap:
            for r in todo:
                job = row_to_job(r)
                log.info("applying: %s @ %s (%s, score %s)", job.title, job.company, job.work_mode.value, r["score"])
                res = ap.apply(job)
                self.store.set_status(job.uid, res.status, res.note)
                self.store.log_application(job.uid, res.status.value, res.answers, res.screenshot)
                counts[res.status.value] = counts.get(res.status.value, 0) + 1
                log.info("  -> %s %s", res.status.value, res.note)
        return counts

    def run(self, do_apply: bool = True) -> None:
        if self.cfg["discovery"].get("enabled"):
            self.discover()
        self.search()
        self.score()
        if do_apply:
            self.apply()

    def export(self) -> list[dict]:
        out = []
        for r in self.store.all():
            d = dict(r)
            d.pop("description", None)
            d["reasons"] = json.loads(d["reasons"] or "[]")
            out.append(d)
        return out
