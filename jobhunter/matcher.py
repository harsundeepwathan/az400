"""Score jobs against the resume and the user's preferences."""
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone

from .models import Job
from .resume import Resume, find_skills, skill_pattern
from .text import norm

SENIORITY = {
    "intern": 0, "junior": 1, "associate": 1, "mid": 2, "senior": 4, "sr": 4, "staff": 6, "lead": 6,
    "principal": 8, "director": 10, "head of": 10, "vp": 12,
}


def _title_score(title: str, targets: list[str]) -> float:
    t = norm(title)
    best = 0.0
    for target in targets:
        words = [w for w in re.split(r"\W+", norm(target)) if w and w not in SENIORITY]
        if not words:
            continue
        if norm(target) in t:
            return 1.0
        hit = sum(1 for w in words if re.search(rf"\b{re.escape(w)}", t)) / len(words)
        best = max(best, hit)
    return best


def _seniority_penalty(title: str, years: int | None) -> tuple[float, str]:
    if years is None:
        return 0, ""
    t = norm(title)
    needed = max((v for k, v in SENIORITY.items() if re.search(rf"\b{k}\b", t)), default=None)
    if needed is None or years >= needed:
        return 0, ""
    gap = needed - years
    return min(25, gap * 6), f"seniority '{title}' likely needs ~{needed}+ yrs"


def keyword_score(job: Job, resume: Resume, search: dict) -> tuple[float, list[str]]:
    reasons: list[str] = []
    text = norm(f"{job.title}\n{job.description}")

    for bad in search.get("exclude_keywords") or []:
        if skill_pattern(norm(bad)).search(text):
            return 0, [f"excluded keyword '{bad}'"]

    title = _title_score(job.title, search.get("titles") or [])
    job_skills = find_skills(text, search.get("keywords"))
    matched = job_skills & resume.skills
    if job_skills:
        # Diminishing returns: 8 overlapping skills already counts as a strong match.
        skill = min(1.0, 0.6 * len(matched) / len(job_skills) + 0.4 * min(len(matched), 8) / 8)
    else:
        skill = 0.3  # thin description - rely on the title
    penalty, why = _seniority_penalty(job.title, resume.years_experience)

    score = 55 * title + 45 * skill - penalty
    if title >= 0.99:
        reasons.append("title matches target")
    elif title > 0:
        reasons.append(f"title partially matches ({title:.0%})")
    if matched:
        reasons.append("skills: " + ", ".join(sorted(matched)[:8]))
    if missing := sorted(job_skills - resume.skills)[:6]:
        reasons.append("not on resume: " + ", ".join(missing))
    if why:
        reasons.append(why)
    return max(0.0, min(100.0, score)), reasons


def too_old(job: Job, max_age_days: int | None) -> bool:
    if not max_age_days or not job.posted_at:
        return False
    posted = job.posted_at if job.posted_at.tzinfo else job.posted_at.replace(tzinfo=timezone.utc)
    return datetime.now(timezone.utc) - posted > timedelta(days=max_age_days)
