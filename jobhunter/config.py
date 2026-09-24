from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import yaml

DEFAULTS: dict[str, Any] = {
    "resume_path": "resume.pdf",
    "data_dir": "data",
    "personal": {},
    "search": {
        "titles": [],
        "keywords": [],
        "exclude_keywords": [],
        "work_modes": ["remote", "hybrid", "onsite"],
        "locations": [],
        "remote_regions": ["worldwide", "anywhere", "global"],
        "include_unknown_work_mode": True,
        "min_score": 55,
        "max_age_days": 30,
    },
    "sources": {
        "greenhouse": True, "lever": True, "ashby": True, "workable": True,
        "remotive": True, "remoteok": True, "arbeitnow": True, "adzuna": False,
    },
    "companies": {"greenhouse": [], "lever": [], "ashby": [], "workable": []},
    "discovery": {"enabled": False, "max_queries": 20},
    "apply": {
        "enabled": True,
        "mode": "review",           # review: fill + wait for you to click submit; submit: fully automatic
        "daily_limit": 15,
        "ats": ["workable", "greenhouse", "lever", "ashby"],
        "headless": False,
        "human_timeout_sec": 600,
        "cover_letter": True,
        "screenshots": True,
    },
    "answers": {},
    "llm": {"enabled": True, "model": "claude-opus-5", "rescore_top": 40},
}


def _merge(base: dict, override: dict) -> dict:
    out = dict(base)
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


def load_config(path: str | os.PathLike = "config/profile.yaml") -> dict[str, Any]:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(
            f"{p} not found. Copy config/profile.example.yaml to {p} and fill it in."
        )
    raw = yaml.safe_load(p.read_text()) or {}
    cfg = _merge(DEFAULTS, raw)
    # A separate companies file keeps the (long) seed list out of the profile.
    companies_file = p.parent / "companies.yaml"
    if companies_file.exists():
        extra = yaml.safe_load(companies_file.read_text()) or {}
        for ats, slugs in extra.items():
            cfg["companies"].setdefault(ats, [])
            cfg["companies"][ats] = sorted(set(cfg["companies"][ats]) | set(slugs or []))
    base = p.parent.parent if p.parent.name == "config" else p.parent
    cfg["_base_dir"] = str(base.resolve())
    for key in ("resume_path", "data_dir"):
        if not Path(cfg[key]).is_absolute():
            cfg[key] = str((base / cfg[key]).resolve())
    Path(cfg["data_dir"]).mkdir(parents=True, exist_ok=True)
    return cfg
