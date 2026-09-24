"""Fill and (optionally) submit application forms with a real browser (Playwright).

Modes (profile.yaml -> apply.mode):
  review  - fill everything, then hand over: in a visible browser you check the form and click Submit
            yourself (the tool detects the confirmation and records it). Headless review = dry run.
  submit  - fully automatic when every required field was answered confidently. Anything uncertain
            (unknown required question, low-confidence answer, CAPTCHA) falls back to review.

CAPTCHAs are never bypassed: in a visible browser you solve them; headless runs mark the job for review.
"""
from __future__ import annotations

import logging
import os
import re
import time
from dataclasses import asdict
from pathlib import Path

from ..models import Job, Status
from .fields import Answer, Field, best_option, resolve

log = logging.getLogger(__name__)

EXTRACT_JS = (Path(__file__).parent / "extract.js").read_text()

SUCCESS = re.compile(
    r"thank(?:s| you)[^.]{0,40}(?:appl|interest|submitting)|application (?:has been |was )?(?:submitted|received|sent|complete)"
    r"|we(?:'ve| have) received your application|successfully (?:applied|submitted)", re.I)
SUCCESS_URL = re.compile(r"confirmation|thank|success|submitted|applied", re.I)

COOKIE_BUTTONS = ["Accept all", "Accept All", "Accept", "Allow all", "I agree", "Got it", "Accept cookies"]
SUBMIT_SELECTORS = [
    "button[data-ui='apply-button']", "button[type=submit]", "input[type=submit]", "#submit_app",
    "button:has-text('Submit application')", "button:has-text('Submit Application')",
    "button:has-text('Submit')", "button:has-text('Apply')",
]
# Per-ATS: how to reach the form from the job page.
OPEN_FORM = {
    "workable": ["a:has-text('Apply for this job')", "button:has-text('Apply for this job')", "[data-ui='overview-apply-now']"],
    "greenhouse": ["button:has-text('Apply')", "a:has-text('Apply for this job')"],
    "lever": ["a:has-text('Apply for this job')"],
    "ashby": ["a:has-text('Application')", "button:has-text('Apply for this Job')"],
}


class Result:
    def __init__(self, status: Status, note: str = "", answers: dict | None = None, screenshot: str = ""):
        self.status, self.note, self.answers, self.screenshot = status, note, answers or {}, screenshot


class Applier:
    def __init__(self, cfg: dict, resume_text: str, llm=None):
        self.cfg, self.acfg = cfg, cfg["apply"]
        self.resume_text, self.llm = resume_text, llm
        self.out_dir = Path(cfg["data_dir"]) / "applications"
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self._pw = self._browser = None
        self._baseline: set[str] = set()

    def __enter__(self):
        from playwright.sync_api import sync_playwright

        self._pw = sync_playwright().start()
        profile_dir = Path(self.cfg["data_dir"]) / "browser-profile"
        # A persistent profile keeps cookies (e.g. a Workable candidate login) between runs.
        # Use an existing Chrome/Chromium instead of Playwright's download when configured.
        exe = self.acfg.get("browser_executable") or os.environ.get("JOBHUNTER_BROWSER")
        self._browser = self._pw.chromium.launch_persistent_context(
            str(profile_dir), headless=bool(self.acfg.get("headless")), viewport={"width": 1280, "height": 900},
            accept_downloads=False, **({"executable_path": exe} if exe else {}),
        )
        return self

    def __exit__(self, *exc):
        if self._browser:
            self._browser.close()
        if self._pw:
            self._pw.stop()

    # ------------------------------------------------------------------ main flow
    def apply(self, job: Job) -> Result:
        page = self._browser.new_page()
        tag = re.sub(r"[^\w-]+", "_", job.uid)[:80]
        try:
            page.goto(job.apply_url or job.url, wait_until="domcontentloaded", timeout=45000)
            page.wait_for_timeout(2500)
            self._dismiss_cookies(page)
            self._open_form(page, job.ats)
            self._baseline = self._success_texts(page)

            cover_text, cover_path = self._cover_letter(job, tag)
            fields = self._extract(page)
            if not fields:
                return Result(Status.NEEDS_REVIEW, "no form fields found", screenshot=self._shot(page, tag))

            # Upload files first: Workable/Lever parse the resume and pre-fill fields.
            answers: dict[str, Answer] = {}
            files = [f for f in fields if f.kind == "file"]
            for f in files:
                a = resolve(f, self.cfg, self.cfg["resume_path"], cover_path, cover_text)
                if a and a.value:
                    self._fill(page, f, a)
                    answers[f.id] = a
            if files:
                page.wait_for_timeout(4000)
                fields = self._extract(page)

            unresolved = []
            for f in fields:
                if f.kind == "file":
                    continue
                if f.kind == "combobox" and not f.options:
                    f.options = self._combobox_options(page, f)
                a = resolve(f, self.cfg, self.cfg["resume_path"], cover_path, cover_text)
                if a is None:
                    unresolved.append(f)
                else:
                    answers[f.id] = a

            if unresolved and self.llm:
                need = [f for f in unresolved if f.required or f.kind in ("textarea", "select", "radio", "combobox")]
                llm_ans = self.llm.answer_fields(self.resume_text, self.cfg, job, [asdict(f) for f in need]) if need else {}
                for f in list(unresolved):
                    la = llm_ans.get(f.id)
                    if la and la.answer:
                        value: str | list[str] = la.answer
                        if f.kind in ("select", "radio", "combobox") and f.options:
                            value = best_option(f.options, la.answer) or la.answer
                        elif f.kind == "checkbox":
                            value = [o for v in la.answer.split(",") if (o := best_option(f.options, v.strip()))]
                        answers[f.id] = Answer(value, "llm", la.confident)
                        unresolved.remove(f)

            by_id = {f.id: f for f in fields}
            for fid, a in answers.items():
                if fid in by_id:
                    self._fill(page, by_id[fid], a)

            record = {by_id[fid].label if fid in by_id else fid: {"value": a.value, "source": a.source, "confident": a.confident}
                      for fid, a in answers.items()}
            missing_required = [f.label or f.name for f in unresolved if f.required]
            missing_required += [x for x in self._invalid_fields(page) if x not in missing_required]
            unsure = [by_id[fid].label for fid, a in answers.items() if not a.confident and fid in by_id]

            shot = self._shot(page, tag)
            auto = self.acfg.get("mode") == "submit" and not missing_required and not unsure
            if auto:
                return self._submit(page, tag, record)
            reason = "; ".join(filter(None, [
                missing_required and f"required fields needing you: {missing_required[:5]}",
                unsure and f"answers to double-check: {unsure[:5]}",
                self.acfg.get("mode") != "submit" and "review mode",
            ]))
            return self._hand_over(page, tag, record, reason, shot)
        except Exception as e:  # noqa: BLE001
            log.exception("apply failed for %s", job.uid)
            return Result(Status.FAILED, f"{type(e).__name__}: {e}", screenshot=self._shot(page, tag))
        finally:
            page.close()

    # ------------------------------------------------------------------ steps
    def _submit(self, page, tag: str, record: dict) -> Result:
        btn = self._find_submit(page)
        if not btn:
            return self._hand_over(page, tag, record, "submit button not found", self._shot(page, tag))
        btn.click()
        if self._wait_success(page, 20):
            return Result(Status.APPLIED, "submitted automatically", record, self._shot(page, tag + "_done"))
        if self._captcha_visible(page):
            return self._hand_over(page, tag, record, "CAPTCHA shown - please solve it", self._shot(page, tag))
        errors = self._invalid_fields(page)
        return self._hand_over(page, tag, record, f"not confirmed after submit; invalid: {errors[:5]}",
                               self._shot(page, tag))

    def _hand_over(self, page, tag: str, record: dict, reason: str, shot: str) -> Result:
        """Give the human the filled form. In a visible browser, wait for them to submit."""
        if self.acfg.get("headless"):
            return Result(Status.NEEDS_REVIEW, reason, record, shot)
        log.warning(">>> Please review the application in the browser window: %s", reason)
        log.warning(">>> Fix anything needed and click Submit (waiting up to %ss; close the tab to skip).",
                    self.acfg.get("human_timeout_sec", 600))
        page.evaluate("""r => { const d = document.createElement('div');
            d.textContent = 'jobhunter: ' + r + ' - review, then click Submit yourself.';
            d.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#fde68a;color:#111;'
              + 'padding:8px 12px;font:14px sans-serif;border-bottom:2px solid #b45309';
            document.body.appendChild(d); }""", reason)
        if self._wait_success(page, int(self.acfg.get("human_timeout_sec", 600))):
            return Result(Status.APPLIED, f"submitted after human review ({reason})", record,
                          self._shot(page, tag + "_done"))
        return Result(Status.NEEDS_REVIEW, reason, record, shot)

    def _success_texts(self, page) -> set[str]:
        try:
            return {m.group(0).lower() for m in SUCCESS.finditer(page.inner_text("body"))}
        except Exception:  # noqa: BLE001 - navigation in progress
            return set()

    def _wait_success(self, page, seconds: int) -> bool:
        """Wait for a confirmation that wasn't on the page before submitting.

        Job descriptions often say "thank you for your interest", so only *new* matches count.
        """
        baseline = self._baseline
        start_url = page.url
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                if page.is_closed():
                    return False
                now = self._success_texts(page)
                if now - baseline:
                    return True
                if page.url != start_url and SUCCESS_URL.search(page.url) and not self._find_submit(page):
                    return True
            except Exception:  # noqa: BLE001 - navigation in progress
                pass
            time.sleep(1.5)
        return False

    def _captcha_visible(self, page) -> bool:
        for fr in page.query_selector_all("iframe[src*='hcaptcha'], iframe[src*='recaptcha'], iframe[src*='turnstile']"):
            box = fr.bounding_box()
            if box and box["width"] > 60 and box["height"] > 60:
                return True
        return False

    def _dismiss_cookies(self, page) -> None:
        for label in COOKIE_BUTTONS:
            btn = page.get_by_role("button", name=label, exact=True)
            if btn.count() and btn.first.is_visible():
                btn.first.click()
                page.wait_for_timeout(500)
                return

    def _open_form(self, page, ats: str) -> None:
        if page.query_selector("input[type=file]") and page.query_selector("input[type=email], input[name*=email i]"):
            return
        for sel in OPEN_FORM.get(ats, []) + ["a:has-text('Apply')", "button:has-text('Apply now')"]:
            el = page.query_selector(sel)
            # Never click something that would submit a form - we only want to *open* the form.
            if el and el.is_visible() and not el.evaluate("e => !!e.closest('form') && (e.type || '').toLowerCase() === 'submit'"):
                el.click()
                page.wait_for_timeout(2500)
                self._dismiss_cookies(page)
                return

    def _extract(self, page) -> list[Field]:
        return [Field(**f) for f in page.evaluate(EXTRACT_JS)]

    def _combobox_options(self, page, f: Field) -> list[str]:
        el = page.locator(f"[data-jh-id='{f.id}']")
        try:
            el.click()
            page.wait_for_timeout(600)
            opts = [o.strip() for o in page.locator("[role=option]").all_inner_texts() if o.strip()][:60]
            el.press("Escape")
            return opts
        except Exception:  # noqa: BLE001
            return []

    def _fill(self, page, f: Field, a: Answer) -> None:
        loc = page.locator(f"[data-jh-id='{f.id}']")
        v = a.value
        try:
            if f.kind == "file":
                loc.first.set_input_files(str(v))
            elif f.kind == "select":
                vals = v if isinstance(v, list) else [v]
                loc.first.select_option(label=vals if f.multiple else vals[0])
            elif f.kind == "radio":
                idx = f.options.index(v) if v in f.options else None
                if idx is not None:
                    self._check(page, page.locator(f"[data-jh-id='{f.id}'][data-jh-opt='{idx}']"))
            elif f.kind == "checkbox":
                if isinstance(v, bool):
                    target = loc.first
                    if v and not target.is_checked():
                        self._check(page, target)
                else:
                    for opt in (v if isinstance(v, list) else [v]):
                        if opt in f.options:
                            self._check(page, page.locator(f"[data-jh-id='{f.id}'][data-jh-opt='{f.options.index(opt)}']"))
            elif f.kind == "combobox":
                loc.first.click()
                loc.first.fill(str(v))
                page.wait_for_timeout(700)
                opt = page.locator("[role=option]").filter(has_text=str(v)).first
                if opt.count():
                    opt.click()
                else:
                    loc.first.press("Enter")
            else:
                loc.first.fill(str(v))
        except Exception as e:  # noqa: BLE001
            log.info("could not fill %r: %s", f.label, e)
            a.confident = False

    @staticmethod
    def _check(page, loc) -> None:
        try:
            loc.check(timeout=3000)
        except Exception:  # noqa: BLE001 - styled inputs hide the real checkbox; click its label
            loc.check(force=True, timeout=3000)

    def _invalid_fields(self, page) -> list[str]:
        return page.evaluate("""() => Array.from(document.querySelectorAll('input:invalid, select:invalid, textarea:invalid, [aria-invalid="true"]'))
            .filter(el => el.type !== 'hidden').map(el => (el.labels && el.labels[0] && el.labels[0].innerText)
              || el.getAttribute('aria-label') || el.name || el.id).map(s => (s || '').trim()).filter(Boolean)""")

    def _find_submit(self, page):
        for sel in SUBMIT_SELECTORS:
            els = [e for e in page.query_selector_all(sel) if e.is_visible()]
            if els:
                return els[-1]
        return None

    def _cover_letter(self, job: Job, tag: str) -> tuple[str, str | None]:
        if not self.acfg.get("cover_letter"):
            return "", None
        text = ""
        tmpl = self.cfg.get("cover_letter_template")
        if self.llm:
            text = self.llm.cover_letter(self.resume_text, self.cfg, job)
        if not text and tmpl:
            text = tmpl.format(company=job.company, title=job.title, **self.cfg.get("personal", {}))
        if not text:
            return "", None
        import docx

        path = self.out_dir / f"{tag}_cover_letter.docx"
        doc = docx.Document()
        for para in text.split("\n\n"):
            doc.add_paragraph(para.strip())
        doc.save(str(path))
        return text, str(path)

    def _shot(self, page, tag: str) -> str:
        if not self.acfg.get("screenshots", True):
            return ""
        path = self.out_dir / f"{tag}.png"
        try:
            page.screenshot(path=str(path), full_page=True)
            return str(path)
        except Exception:  # noqa: BLE001
            return ""
