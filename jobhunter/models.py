from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class WorkMode(str, Enum):
    REMOTE = "remote"
    HYBRID = "hybrid"
    ONSITE = "onsite"
    UNKNOWN = "unknown"


class Status(str, Enum):
    NEW = "new"                    # discovered, not yet scored
    SKIPPED = "skipped"            # filtered out (score/work mode/location)
    MATCHED = "matched"            # passed filters, waiting to be applied to
    APPLIED = "applied"            # submitted successfully
    NEEDS_REVIEW = "needs_review"  # form filled but a human must finish (captcha, unknown answer...)
    MANUAL = "manual"              # ATS not supported for automation - apply by hand
    FAILED = "failed"


@dataclass
class Job:
    source: str            # which feed found it (greenhouse, lever, remotive, ...)
    ats: str               # which applicant tracking system hosts the form
    company: str
    external_id: str
    title: str
    url: str
    apply_url: str = ""
    location: str = ""
    work_mode: WorkMode = WorkMode.UNKNOWN
    description: str = ""
    posted_at: datetime | None = None
    salary: str = ""
    tags: list[str] = field(default_factory=list)

    @property
    def uid(self) -> str:
        return f"{self.ats}:{self.company}:{self.external_id}".lower()
