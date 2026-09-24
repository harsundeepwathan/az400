"""SQLite tracker so every job is seen, scored and applied to at most once."""
from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from .models import Job, Status, WorkMode

SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    uid TEXT PRIMARY KEY, source TEXT, ats TEXT, company TEXT, external_id TEXT, title TEXT,
    url TEXT, apply_url TEXT, location TEXT, work_mode TEXT, description TEXT, posted_at TEXT,
    salary TEXT, tags TEXT, score REAL, reasons TEXT, status TEXT DEFAULT 'new', note TEXT,
    first_seen TEXT, updated_at TEXT, applied_at TEXT
);
CREATE INDEX IF NOT EXISTS jobs_status ON jobs(status);
CREATE TABLE IF NOT EXISTS applications (
    uid TEXT, at TEXT, outcome TEXT, answers TEXT, screenshot TEXT
);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class Store:
    def __init__(self, path: str | Path):
        self.db = sqlite3.connect(str(path))
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)

    def upsert(self, job: Job) -> bool:
        """Insert a new job; returns True if it was new. Existing rows keep their status."""
        cur = self.db.execute(
            """INSERT INTO jobs (uid, source, ats, company, external_id, title, url, apply_url, location,
                   work_mode, description, posted_at, salary, tags, status, first_seen, updated_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,'new',?,?)
               ON CONFLICT(uid) DO NOTHING""",
            (job.uid, job.source, job.ats, job.company, job.external_id, job.title, job.url, job.apply_url,
             job.location, job.work_mode.value, job.description,
             job.posted_at.isoformat() if job.posted_at else None, job.salary, json.dumps(job.tags), _now(), _now()),
        )
        self.db.commit()
        return cur.rowcount == 1

    def set_description(self, uid: str, desc: str) -> None:
        self.db.execute("UPDATE jobs SET description=? WHERE uid=?", (desc, uid))
        self.db.commit()

    def set_score(self, uid: str, score: float, reasons: list[str], status: Status) -> None:
        self.db.execute("UPDATE jobs SET score=?, reasons=?, status=?, updated_at=? WHERE uid=?",
                        (score, json.dumps(reasons), status.value, _now(), uid))
        self.db.commit()

    def set_status(self, uid: str, status: Status, note: str = "") -> None:
        applied = _now() if status == Status.APPLIED else None
        self.db.execute("UPDATE jobs SET status=?, note=?, updated_at=?, applied_at=COALESCE(?, applied_at) WHERE uid=?",
                        (status.value, note, _now(), applied, uid))
        self.db.commit()

    def log_application(self, uid: str, outcome: str, answers: dict, screenshot: str = "") -> None:
        self.db.execute("INSERT INTO applications VALUES (?,?,?,?,?)",
                        (uid, _now(), outcome, json.dumps(answers, default=str), screenshot))
        self.db.commit()

    def by_status(self, *statuses: Status, order: str = "score DESC") -> list[sqlite3.Row]:
        q = ",".join("?" * len(statuses))
        return list(self.db.execute(f"SELECT * FROM jobs WHERE status IN ({q}) ORDER BY {order}",
                                    [s.value for s in statuses]))

    def all(self) -> list[sqlite3.Row]:
        return list(self.db.execute("SELECT * FROM jobs ORDER BY COALESCE(score, -1) DESC"))

    def applied_today(self) -> int:
        today = datetime.now(timezone.utc).date().isoformat()
        return self.db.execute("SELECT COUNT(*) FROM jobs WHERE status='applied' AND applied_at >= ?",
                               (today,)).fetchone()[0]


def row_to_job(r: sqlite3.Row) -> Job:
    return Job(source=r["source"], ats=r["ats"], company=r["company"], external_id=r["external_id"],
               title=r["title"], url=r["url"], apply_url=r["apply_url"], location=r["location"] or "",
               work_mode=WorkMode(r["work_mode"]), description=r["description"] or "",
               posted_at=datetime.fromisoformat(r["posted_at"]) if r["posted_at"] else None,
               salary=r["salary"] or "", tags=json.loads(r["tags"] or "[]"))
