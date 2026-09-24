"""Static HTML dashboard of the tracker (data/report.html)."""
from __future__ import annotations

import html
import json
from datetime import datetime, timezone
from pathlib import Path

STATUS_ORDER = ["matched", "needs_review", "applied", "manual", "failed", "new", "skipped"]


def write_report(rows: list[dict], path: str | Path) -> Path:
    rows = sorted(rows, key=lambda r: (STATUS_ORDER.index(r["status"]) if r["status"] in STATUS_ORDER else 99,
                                       -(r["score"] or 0)))
    counts: dict[str, int] = {}
    for r in rows:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    tiles = "".join(f'<div class="tile"><b>{counts.get(s, 0)}</b><span>{s.replace("_", " ")}</span></div>'
                    for s in STATUS_ORDER)
    body = []
    for r in rows:
        if r["status"] == "skipped" and (r["score"] or 0) < 20:
            continue
        e = lambda k: html.escape(str(r.get(k) or ""))  # noqa: E731
        reasons = html.escape(" · ".join(r.get("reasons") or []))
        body.append(
            f'<tr data-status="{e("status")}" data-mode="{e("work_mode")}"><td><span class="pill {e("status")}">'
            f'{e("status").replace("_", " ")}</span></td><td class="num">{r["score"] or ""}</td>'
            f'<td><a href="{e("url")}" target="_blank" rel="noopener">{e("title")}</a><div class="sub">{reasons}</div></td>'
            f'<td>{e("company")}</td><td>{e("work_mode")}</td><td>{e("location")}</td><td>{e("ats")}</td>'
            f'<td class="sub">{e("note")}</td></tr>')
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    doc = TEMPLATE.replace("{{tiles}}", tiles).replace("{{rows}}", "\n".join(body)).replace("{{generated}}", generated)
    p = Path(path)
    p.write_text(doc)
    (p.with_suffix(".json")).write_text(json.dumps(rows, indent=1, default=str))
    return p


TEMPLATE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Job Hunt Tracker</title>
<style>
:root{--bg:#fafaf9;--fg:#1c1917;--mut:#78716c;--line:#e7e5e4;--card:#fff;--acc:#2563eb}
@media (prefers-color-scheme:dark){:root{--bg:#1c1917;--fg:#f5f5f4;--mut:#a8a29e;--line:#44403c;--card:#292524;--acc:#60a5fa}}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,sans-serif;padding:16px}
h1{font-size:20px;margin:0 0 4px}.sub{color:var(--mut);font-size:12px}
.tiles{display:flex;flex-wrap:wrap;gap:8px;margin:16px 0}.tile{background:var(--card);border:1px solid var(--line);
border-radius:8px;padding:8px 14px;min-width:84px}.tile b{display:block;font-size:20px}.tile span{color:var(--mut);font-size:12px}
.filters{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:8px}select,input{background:var(--card);color:var(--fg);
border:1px solid var(--line);border-radius:6px;padding:6px}
.wrap{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:8px}
table{border-collapse:collapse;width:100%;min-width:760px}td,th{padding:8px;border-bottom:1px solid var(--line);
text-align:left;vertical-align:top}th{font-size:12px;color:var(--mut)}.num{font-variant-numeric:tabular-nums}
a{color:var(--acc);text-decoration:none}.pill{border-radius:99px;padding:2px 8px;font-size:12px;border:1px solid var(--line);white-space:nowrap}
.applied{background:#16a34a22}.needs_review{background:#f59e0b33}.matched{background:#2563eb22}.failed{background:#dc262622}
</style></head><body>
<h1>Job Hunt Tracker</h1><div class="sub">Generated {{generated}}</div>
<div class="tiles">{{tiles}}</div>
<div class="filters"><select id="st"><option value="">All statuses</option><option>matched</option><option>needs_review</option>
<option>applied</option><option>manual</option><option>failed</option><option>skipped</option></select>
<select id="md"><option value="">All work modes</option><option>remote</option><option>hybrid</option><option>onsite</option>
<option>unknown</option></select><input id="q" placeholder="Filter text"></div>
<div class="wrap"><table><thead><tr><th>Status</th><th>Score</th><th>Job</th><th>Company</th><th>Mode</th><th>Location</th>
<th>ATS</th><th>Note</th></tr></thead><tbody>{{rows}}</tbody></table></div>
<script>
const f=()=>{const s=st.value,m=md.value,q=document.getElementById('q').value.toLowerCase();
document.querySelectorAll('tbody tr').forEach(r=>{r.style.display=(!s||r.dataset.status===s)&&(!m||r.dataset.mode===m)
&&(!q||r.innerText.toLowerCase().includes(q))?'':'none'})};[st,md,document.getElementById('q')].forEach(e=>e.oninput=f);
</script></body></html>"""
