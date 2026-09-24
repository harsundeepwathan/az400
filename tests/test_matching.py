from pathlib import Path

from jobhunter.matcher import keyword_score
from jobhunter.models import Job, WorkMode
from jobhunter.resume import find_skills, parse_resume

FIX = Path(__file__).parent / "fixtures"
SEARCH = {"titles": ["DevOps Engineer", "Site Reliability Engineer"], "keywords": [], "exclude_keywords": ["clearance required"]}


def mk(title, desc):
    return Job(source="t", ats="t", company="c", external_id="1", title=title, url="", description=desc, work_mode=WorkMode.REMOTE)


def test_resume_parse():
    r = parse_resume(FIX / "resume.txt")
    assert {"python", "terraform", "kubernetes", "azure devops", "github actions"} <= r.skills
    assert "c" not in r.skills  # single-letter skills must not match random letters
    assert r.years_experience == 6


def test_skill_boundaries():
    assert "go" not in find_skills("we are going to google it")
    assert "c++" in find_skills("Strong C++ and C# skills")
    assert "c#" in find_skills("Strong C++ and C# skills")


def test_scores_rank_relevant_jobs_higher():
    r = parse_resume(FIX / "resume.txt")
    good, _ = keyword_score(mk("Senior DevOps Engineer", "Terraform, Kubernetes, Azure, Python, CI/CD, Prometheus"), r, SEARCH)
    bad, _ = keyword_score(mk("Account Executive", "Salesforce, quota, hubspot, cold calling"), r, SEARCH)
    assert good >= 70 > 30 >= bad


def test_exclude_keywords():
    r = parse_resume(FIX / "resume.txt")
    score, reasons = keyword_score(mk("DevOps Engineer", "Top secret clearance required."), r, SEARCH)
    assert score == 0 and "excluded" in reasons[0]
