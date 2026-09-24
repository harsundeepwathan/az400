"""End-to-end: fill and submit a local Workable-style form with the real browser."""
import os
import shutil
from pathlib import Path

import pytest

from jobhunter.models import Job, Status

FIX = Path(__file__).parent / "fixtures"


def _chromium_available():
    # Pre-installed Chromium whose version differs from the pip playwright's expected build.
    if not os.environ.get("JOBHUNTER_BROWSER") and os.path.exists("/opt/pw-browsers/chromium"):
        os.environ["JOBHUNTER_BROWSER"] = "/opt/pw-browsers/chromium"
    try:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as p:
            p.chromium.launch(executable_path=os.environ.get("JOBHUNTER_BROWSER")).close()
        return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(not _chromium_available(), reason="Playwright Chromium not installed")


def cfg(tmp_path, mode):
    resume = tmp_path / "resume.txt"
    shutil.copy(FIX / "resume.txt", resume)
    return {
        "data_dir": str(tmp_path), "resume_path": str(resume),
        "personal": {"first_name": "Jane", "last_name": "Doe", "email": "jane@example.com", "phone": "555",
                     "linkedin": "https://linkedin.com/in/jane"},
        "answers": {"work_authorization": "Yes", "require_sponsorship": "No", "years_experience": 6, "eeo": {},
                    "custom": [{"match": "why do you want", "answer": "I love platform work."}]},
        "apply": {"mode": mode, "headless": True, "cover_letter": False, "screenshots": True, "human_timeout_sec": 5},
    }


def job():
    url = (FIX / "workable_form.html").as_uri()
    return Job(source="workable", ats="workable", company="acme", external_id="X", title="DevOps", url=url, apply_url=url)


def test_submit_mode_applies(tmp_path):
    from jobhunter.apply.browser import Applier

    with Applier(cfg(tmp_path, "submit"), "resume") as ap:
        res = ap.apply(job())
    assert res.status == Status.APPLIED, res.note
    vals = {k: v["value"] for k, v in res.answers.items()}
    assert vals["First name *"] == "Jane"
    assert "Decline to self-identify" in vals.values()
    assert any("sponsorship" in k and v == "No" for k, v in vals.items())


def test_review_mode_headless_is_dry_run(tmp_path):
    from jobhunter.apply.browser import Applier

    with Applier(cfg(tmp_path, "review"), "resume") as ap:
        res = ap.apply(job())
    assert res.status == Status.NEEDS_REVIEW
    assert os.path.exists(res.screenshot)


def test_unknown_required_question_blocks_auto_submit(tmp_path):
    from jobhunter.apply.browser import Applier

    c = cfg(tmp_path, "submit")
    c["answers"]["custom"] = []  # nobody can answer "why do you want to join" without Claude
    with Applier(c, "resume") as ap:
        res = ap.apply(job())
    assert res.status == Status.NEEDS_REVIEW and "Why do you want" in res.note
