"""Claude-powered steps: fit scoring, answering application questions, cover letters.

Everything here is optional - with no Anthropic credentials the pipeline falls back to
keyword scoring and your pre-written answers, and unanswerable questions go to review.
"""
from __future__ import annotations

import json
import logging
import os
from typing import Literal

from pydantic import BaseModel, Field

from .models import Job

log = logging.getLogger(__name__)

SYSTEM = """You help one job seeker apply to jobs. You act strictly on their behalf and only with facts
from their resume and profile. Never invent experience, credentials, employers, degrees, dates,
clearances, or legal/work-authorization status. If the resume and profile do not support an answer,
say so by marking it not confident rather than guessing."""


class JobFit(BaseModel):
    score: int = Field(description="0-100 fit of the candidate for this job")
    reasons: list[str] = Field(description="2-4 short reasons for the score")
    missing: list[str] = Field(description="hard requirements the candidate appears to lack")
    work_mode: Literal["remote", "hybrid", "onsite", "unknown"]


class FieldAnswer(BaseModel):
    id: str
    answer: str = Field(description="exact text to enter, or for choice fields the exact option label(s), "
                                    "comma-separated for multi-select")
    confident: bool = Field(description="true only if the answer is directly supported by the resume/profile")


class FieldAnswers(BaseModel):
    answers: list[FieldAnswer]


class CoverLetter(BaseModel):
    text: str


class LLM:
    def __init__(self, cfg: dict):
        import anthropic

        self.model = cfg["llm"].get("model", "claude-opus-5")
        self.client = anthropic.Anthropic()

    def _parse(self, prompt: str, schema: type[BaseModel], effort: str = "medium", max_tokens: int = 16000):
        import anthropic

        try:
            resp = self.client.beta.messages.parse(
                model=self.model,
                max_tokens=max_tokens,
                system=SYSTEM,
                thinking={"type": "adaptive"},
                output_config={"effort": effort},
                # If a request is declined, the API retries it on a suitable fallback model.
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
                messages=[{"role": "user", "content": prompt}],
                output_format=schema,
            )
        except anthropic.RateLimitError as e:
            log.warning("Claude rate limited: %s", e)
            return None
        except anthropic.APIStatusError as e:
            log.warning("Claude API error %s: %s", e.status_code, e.message)
            return None
        except anthropic.APIConnectionError as e:
            log.warning("Claude connection error: %s", e)
            return None
        if resp.stop_reason in ("refusal", "max_tokens"):
            log.warning("Claude stopped with %s", resp.stop_reason)
            return None
        return resp.parsed_output

    def score(self, resume_text: str, cfg: dict, job: Job) -> JobFit | None:
        prefs = {k: cfg["search"].get(k) for k in ("titles", "work_modes", "locations", "remote_regions", "exclude_keywords")}
        prompt = f"""Rate how well this candidate fits this job (0-100). Weigh hard requirements (years,
must-have skills, location/work-authorization constraints) most. Also classify the job's work mode.

<preferences>{json.dumps(prefs)}</preferences>
<resume>{resume_text[:30000]}</resume>
<job company="{job.company}" title="{job.title}" location="{job.location}">
{job.description[:20000]}
</job>"""
        return self._parse(prompt, JobFit, effort="low")

    def answer_fields(self, resume_text: str, cfg: dict, job: Job, fields: list[dict]) -> dict[str, FieldAnswer]:
        profile = {"personal": cfg.get("personal", {}), "answers": cfg.get("answers", {})}
        prompt = f"""Fill in these job application fields for the candidate.

Rules:
- For select/radio/checkbox fields, answer with option label(s) copied exactly from "options".
- Use the profile "answers" for work authorization, sponsorship, salary, notice period, relocation and
  demographic questions. For voluntary demographic (EEO) questions with no stated answer, pick the
  "decline to self-identify"-style option.
- For free-text questions (e.g. "why do you want to work here"), write a concise, specific, truthful
  answer (<= 120 words) grounded in the resume and the job description; mark it confident.
- If a question asks for a fact not in the resume/profile, give your best non-committal answer and set
  confident=false so a human reviews it.

<profile>{json.dumps(profile, default=str)}</profile>
<resume>{resume_text[:30000]}</resume>
<job company="{job.company}" title="{job.title}">{job.description[:12000]}</job>
<fields>{json.dumps(fields)}</fields>"""
        out = self._parse(prompt, FieldAnswers, effort="medium")
        return {a.id: a for a in out.answers} if out else {}

    def cover_letter(self, resume_text: str, cfg: dict, job: Job) -> str:
        name = " ".join(filter(None, [cfg["personal"].get("first_name"), cfg["personal"].get("last_name")]))
        prompt = f"""Write a short cover letter (180-250 words, plain text, no placeholders) from {name}
for this job. Specific to the role, truthful to the resume, no clichés.
<resume>{resume_text[:30000]}</resume>
<job company="{job.company}" title="{job.title}">{job.description[:12000]}</job>"""
        out = self._parse(prompt, CoverLetter, effort="medium")
        return out.text if out else ""


def get_llm(cfg: dict) -> LLM | None:
    if not cfg["llm"].get("enabled"):
        return None
    if not (os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN")
            or os.environ.get("ANTHROPIC_PROFILE") or os.path.isdir(os.path.expanduser("~/.config/anthropic"))):
        log.info("No Anthropic credentials found; running without Claude (keyword scoring only)")
        return None
    try:
        return LLM(cfg)
    except Exception as e:  # noqa: BLE001
        log.warning("Claude unavailable: %s", e)
        return None
