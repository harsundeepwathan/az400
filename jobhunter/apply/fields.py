"""Decide what to type into each application form field.

Pure logic (no browser) so it is unit-testable. Resolution order per field:
  1. the candidate's own data (name, email, phone, links, resume file, cover letter)
  2. profile `answers` - explicit answers the user wrote for common screening questions
  3. voluntary EEO/demographic questions -> "decline to answer" option unless the user set one
  4. consent / privacy / terms checkboxes -> tick
  5. Claude (if configured), with a confidence flag
  6. unresolved -> if required, the application goes to human review
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from ..text import norm


@dataclass
class Field:
    id: str                 # data-jh-id we stamped on the element
    kind: str               # text | email | tel | url | number | textarea | select | radio | checkbox | file | combobox | date
    label: str
    name: str = ""
    required: bool = False
    options: list[str] = field(default_factory=list)
    multiple: bool = False

    @property
    def key(self) -> str:
        return norm(f"{self.label} {self.name}")


@dataclass
class Answer:
    value: str | list[str] | bool
    source: str             # profile | answers | eeo | consent | llm | default
    confident: bool = True


DECLINE = re.compile(r"decline|prefer not|don.?t wish|do not wish|not to (?:say|answer|disclose)|rather not|choose not", re.I)
EEO = re.compile(r"\b(gender|sex\b|pronoun|race|ethnic|hispanic|latin|veteran|disabilit|sexual orientation|transgender|lgbt)", re.I)
CONSENT = re.compile(r"\b(i agree|agree to|consent|privacy (?:policy|notice)|terms|acknowledge|i confirm|i certify|gdpr|data processing|accept)", re.I)

# (regex on label/name, personal key or callable) - first match wins, order matters
PERSONAL_RULES: list[tuple[str, str]] = [
    (r"\bpreferred (?:first )?name\b", "preferred_name"),
    (r"\bfirst[ _-]?name\b|\bgiven name\b|^firstname", "first_name"),
    (r"\blast[ _-]?name\b|\bsurname\b|\bfamily name\b|^lastname", "last_name"),
    (r"^(?:full |legal |your )?name\W*$|\bfull name\b|\blegal name\b", "full_name"),
    (r"e-?mail", "email"),
    (r"phone|mobile|telephone", "phone"),
    (r"linkedin", "linkedin"),
    (r"github", "github"),
    (r"portfolio|personal (?:site|website)|^website|other website|\bblog\b", "website"),
    (r"current (?:company|employer)|^company\b|\borg\b", "current_company"),
    (r"current (?:job )?title|current role|job title", "current_title"),
    (r"^(?:current )?(?:location|city)\b|where are you (?:located|based)|city of residence|^address", "location"),
    (r"\bcountry\b", "country"),
    (r"zip|postal", "postal_code"),
    (r"\bstate\b|province", "state"),
    (r"^headline", "headline"),
    (r"summary|about (?:you|yourself)", "summary"),
]

# Common screening questions -> key in profile `answers`
ANSWER_RULES: list[tuple[str, str]] = [
    (r"sponsor", "require_sponsorship"),
    (r"(?:legally )?(?:authori[sz]ed|eligible|permit(?:ted)?|right) to work|work authori[sz]ation|work permit", "work_authorization"),
    (r"salary|compensation|pay expectation|expected (?:pay|ctc)|desired pay", "salary_expectation"),
    (r"notice period|start date|when can you start|earliest (?:start|availability)|available to start", "notice_period"),
    (r"relocat", "willing_to_relocate"),
    (r"years of (?:professional |relevant |work )?experience|how many years", "years_experience"),
    (r"hybrid|in[- ]office|on[- ]?site|commute|come (?:in)?to the office", "onsite_ok"),
    (r"how (?:did )?you (?:hear|heard|find|found|learn)|hear about (?:this|us|the)|referr?al source|where did you (?:hear|find)", "how_heard"),
    (r"referred by|employee referral|who referred", "referred_by"),
    (r"security clearance|clearance", "security_clearance"),
    (r"background check", "background_check_ok"),
    (r"(?:18|eighteen) years|age of majority|at least 18", "over_18"),
    (r"visa (?:status|type)|immigration status|citizenship", "visa_status"),
    (r"previously (?:worked|employed|applied)|former employee|worked (?:here|for us) before", "worked_here_before"),
    (r"languages? (?:do you )?speak|language skill|fluent in|proficien(?:t|cy) in english|english level", "languages"),
    (r"pronouns", "pronouns"),
    (r"time ?zone", "timezone"),
    (r"degree|highest (?:level of )?education|education level", "education"),
    (r"\bgpa\b", "gpa"),
]


def personal_values(cfg: dict) -> dict[str, str]:
    p = dict(cfg.get("personal") or {})
    p.setdefault("full_name", " ".join(filter(None, [p.get("first_name"), p.get("last_name")])))
    p.setdefault("preferred_name", p.get("first_name", ""))
    return {k: str(v) for k, v in p.items() if v not in (None, "")}


def best_option(options: list[str], wanted: str) -> str | None:
    """Pick the option that best matches a free-text answer ("Yes", "No", "Decline"...)."""
    if not options:
        return None
    w = norm(str(wanted))
    opts = [(o, norm(o)) for o in options if norm(o) not in ("", "select", "select...", "please select", "--")]
    for o, n in opts:
        if n == w:
            return o
    if w in ("yes", "true", "y"):
        return next((o for o, n in opts if re.match(r"^yes\b", n)), None)
    if w in ("no", "false", "n"):
        return next((o for o, n in opts if re.match(r"^no\b", n)), None)
    if DECLINE.search(w):
        return next((o for o, n in opts if DECLINE.search(n)), None)
    for o, n in opts:
        if w and (w in n or n in w):
            return o
    # numeric answers against ranges like "3-5 years"
    if re.fullmatch(r"\d+(?:\.\d+)?", w):
        x = float(w)
        for o, n in opts:
            nums = [float(v) for v in re.findall(r"\d+(?:\.\d+)?", n)]
            if len(nums) == 2 and nums[0] <= x <= nums[1]:
                return o
            if len(nums) == 1 and ("+" in n or "more" in n or "over" in n) and x >= nums[0]:
                return o
            if len(nums) == 1 and ("less" in n or "under" in n or "<" in n) and x < nums[0]:
                return o
    return None


def _fmt(v) -> str:
    if isinstance(v, bool):
        return "Yes" if v else "No"
    return str(v)


def resolve(f: Field, cfg: dict, resume_path: str, cover_letter_path: str | None, cover_letter: str) -> Answer | None:
    k = f.key
    answers = cfg.get("answers") or {}

    if f.kind == "file":
        if re.search(r"cover", k):
            return Answer(cover_letter_path, "profile") if cover_letter_path else None
        if re.search(r"resume|cv|curriculum", k) or f.required:
            return Answer(resume_path, "profile")
        return None

    if re.search(r"cover letter|coverletter|motivation letter", k) and f.kind == "textarea":
        return Answer(cover_letter, "profile") if cover_letter else None

    # User-defined answers first: they are the most specific instruction.
    for rule in answers.get("custom") or []:
        if re.search(rule["match"], k, re.I):
            return _choice(f, rule["answer"], "answers")

    if EEO.search(k) and f.kind in ("select", "radio", "checkbox", "combobox"):
        eeo = answers.get("eeo") or {}
        wanted = eeo.get(_eeo_key(k)) if isinstance(eeo, dict) else None
        if wanted:
            return _choice(f, wanted, "eeo")
        opt = next((o for o in f.options if DECLINE.search(o)), None)
        return Answer([opt] if f.multiple else opt, "eeo") if opt else None

    if f.kind == "checkbox" and CONSENT.search(k) and len(f.options) <= 1:
        # Tick required consents (privacy policy, terms). Optional ones (marketing, talent pool) only if opted in.
        return Answer(bool(f.required or answers.get("optional_consents")), "consent")

    if f.kind not in ("select", "radio", "checkbox", "combobox"):
        pv = personal_values(cfg)
        for pat, key in PERSONAL_RULES:
            if re.search(pat, k) and key in pv:
                return Answer(pv[key], "profile")

    for pat, key in ANSWER_RULES:
        # "Years of experience with Kubernetes" is skill-specific - not the same as total years.
        if key == "years_experience" and re.search(r"(?:experience|years) (?:with|in|using|of working with) \w", k):
            continue
        if re.search(pat, k) and answers.get(key) not in (None, ""):
            return _choice(f, _fmt(answers[key]), "answers")

    return None


def _choice(f: Field, value, source: str) -> Answer | None:
    if f.kind in ("select", "radio", "combobox") and f.options:
        opt = best_option(f.options, _fmt(value))
        return Answer(opt, source) if opt else Answer(_fmt(value), source, confident=False)
    if f.kind == "checkbox":
        if f.options and len(f.options) > 1:
            vals = value if isinstance(value, list) else [v.strip() for v in _fmt(value).split(",")]
            picked = [o for v in vals if (o := best_option(f.options, v))]
            return Answer(picked, source, confident=bool(picked))
        return Answer(norm(_fmt(value)) in ("yes", "true", "1", "y"), source)
    return Answer(_fmt(value), source)


def _eeo_key(k: str) -> str:
    for key, pat in [("gender", r"gender|sex\b|pronoun|transgender"), ("race", r"race|ethnic|hispanic|latin"),
                     ("veteran", r"veteran"), ("disability", r"disabilit"), ("sexual_orientation", r"orientation|lgbt")]:
        if re.search(pat, k):
            return key
    return ""
