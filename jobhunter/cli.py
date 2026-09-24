"""Command line: python -m jobhunter <command>"""
from __future__ import annotations

import argparse
import logging
import shutil
import sys
from pathlib import Path

from .config import load_config
from .models import Status
from .pipeline import Pipeline
from .report import write_report


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="jobhunter", description="Find jobs that fit your resume and apply to them.")
    ap.add_argument("-c", "--config", default="config/profile.yaml")
    ap.add_argument("-v", "--verbose", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init", help="create config/profile.yaml from the example")
    sub.add_parser("discover", help="search the web for company job boards hiring for your titles")
    sub.add_parser("search", help="pull jobs from all enabled sources")
    sub.add_parser("score", help="score new jobs against your resume and preferences")
    p_apply = sub.add_parser("apply", help="apply to matched jobs")
    p_apply.add_argument("--limit", type=int)
    p_apply.add_argument("--job", help="apply to one job uid (see `list`)")
    p_apply.add_argument("--submit", action="store_true", help="override mode=submit for this run")
    p_apply.add_argument("--headless", action="store_true")
    p_run = sub.add_parser("run", help="discover (if enabled) + search + score + apply")
    p_run.add_argument("--no-apply", action="store_true")
    p_list = sub.add_parser("list", help="show jobs by status")
    p_list.add_argument("--status", default="matched", choices=[s.value for s in Status] + ["all"])
    p_list.add_argument("-n", type=int, default=30)
    p_rep = sub.add_parser("report", help="write data/report.html")
    p_rep.add_argument("-o", "--out")
    p_mark = sub.add_parser("mark", help="manually set a job's status (e.g. after applying by hand)")
    p_mark.add_argument("uid")
    p_mark.add_argument("status", choices=[s.value for s in Status])
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    logging.getLogger("httpx").setLevel(logging.WARNING)

    if args.cmd == "init":
        dst = Path(args.config)
        if dst.exists():
            print(f"{dst} already exists")
            return 1
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(Path(__file__).parent.parent / "config" / "profile.example.yaml", dst)
        print(f"Created {dst}. Fill in your details and point resume_path at your resume.")
        return 0

    cfg = load_config(args.config)
    if getattr(args, "submit", False):
        cfg["apply"]["mode"] = "submit"
    if getattr(args, "headless", False):
        cfg["apply"]["headless"] = True
    p = Pipeline(cfg)

    if args.cmd == "discover":
        p.discover()
    elif args.cmd == "search":
        p.search()
    elif args.cmd == "score":
        p.score()
    elif args.cmd == "apply":
        print(p.apply(limit=args.limit, uid=args.job))
    elif args.cmd == "run":
        p.run(do_apply=not args.no_apply)
        print(f"report: {write_report(p.export(), Path(cfg['data_dir']) / 'report.html')}")
    elif args.cmd == "list":
        rows = p.store.all() if args.status == "all" else p.store.by_status(Status(args.status))
        for r in rows[: args.n]:
            print(f"{(r['score'] or 0):5.1f}  {r['status']:<12} {r['work_mode']:<7} {r['title'][:50]:<50} "
                  f"{r['company'][:20]:<20} {r['uid']}")
    elif args.cmd == "report":
        print(write_report(p.export(), args.out or Path(cfg["data_dir"]) / "report.html"))
    elif args.cmd == "mark":
        p.store.set_status(args.uid, Status(args.status), "set manually")
    return 0


if __name__ == "__main__":
    sys.exit(main())
