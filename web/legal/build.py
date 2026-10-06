#!/usr/bin/env python3
"""Builds web/legal/{privacy,terms}.html from docs/legal/{privacy,terms}.md.

    python3 web/legal/build.py

Standard library only. Handles the Markdown subset the legal docs use:
headings, paragraphs, blockquotes, bullet and numbered lists, tables, bold,
links, inline code and horizontal rules. The "Implementation references"
checklist at the end of privacy.md is internal and is left out of the page.
"""
import html
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs/legal"
OUT = ROOT / "web/legal"

PAGES = {
    "privacy": ("Privacy Policy", "How Vector handles your data."),
    "terms": ("Terms of Service", "The terms for using Vector and Vector Pro."),
}
INTERNAL_HEADING = "## Implementation references"

CSS = """
:root {
  color-scheme: light dark;
  --bg: #FFFFFF; --text: #0A0A0A; --secondary: #5F5F64; --surface: #F5F5F7;
  --separator: #E3E3E8; --banner-bg: #FFF4E5; --banner-text: #7A4300; --banner-edge: #A65A00;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #000000; --text: #F5F5F7; --secondary: #A1A1A6; --surface: #141416;
    --separator: #2C2C2F; --banner-bg: #2A1E0C; --banner-text: #F2C27B; --banner-edge: #F2A93B;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0; background: var(--bg); color: var(--text);
  font: 17px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif;
}
main { max-width: 720px; margin: 0 auto; padding: 32px 16px 64px; }
.brand { font-size: 13px; font-weight: 600; letter-spacing: .6px; text-transform: uppercase; color: var(--secondary); margin: 0 0 8px; }
h1 { font-size: 34px; line-height: 1.15; letter-spacing: -.4px; margin: 0 0 24px; }
h2 { font-size: 22px; line-height: 1.25; margin: 40px 0 12px; }
h3 { font-size: 18px; margin: 28px 0 8px; }
p, ul, ol { margin: 0 0 16px; }
ul, ol { padding-left: 22px; }
li { margin: 4px 0; }
a { color: var(--text); text-decoration: underline; text-underline-offset: 2px; }
code { font: 15px ui-monospace, "SF Mono", Menlo, monospace; background: var(--surface); padding: 1px 5px; border-radius: 6px; }
hr { border: 0; border-top: 1px solid var(--separator); margin: 32px 0; }
.draft {
  background: var(--banner-bg); color: var(--banner-text); border-left: 4px solid var(--banner-edge);
  border-radius: 10px; padding: 12px 16px; margin: 0 0 28px; font-size: 15px;
}
.draft p:last-child { margin-bottom: 0; }
.table { overflow-x: auto; margin: 0 0 20px; border: 1px solid var(--separator); border-radius: 10px; }
table { border-collapse: collapse; width: 100%; font-size: 15px; }
th, td { text-align: left; vertical-align: top; padding: 10px 12px; border-bottom: 1px solid var(--separator); }
th { background: var(--surface); font-weight: 600; }
tr:last-child td { border-bottom: 0; }
footer { margin-top: 48px; padding-top: 16px; border-top: 1px solid var(--separator); color: var(--secondary); font-size: 14px; }
""".strip()


def inline(text: str) -> str:
    out = html.escape(text, quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"(?<!\*)\*(?!\s)(.+?)(?<!\s)\*(?!\*)", r"<em>\1</em>", out)
    out = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", lambda m: f'<a href="{m.group(2)}">{m.group(1)}</a>', out)
    return out


def table(rows: list[str]) -> str:
    cells = [[c.strip() for c in row.strip().strip("|").split("|")] for row in rows]
    head, body = cells[0], cells[2:]
    th = "".join(f"<th>{inline(c)}</th>" for c in head)
    trs = "".join("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row) + "</tr>" for row in body)
    return f'<div class="table"><table><thead><tr>{th}</tr></thead><tbody>{trs}</tbody></table></div>'


def convert(markdown: str) -> tuple[str, str]:
    """Returns (h1 text, body html)."""
    lines = markdown.split("\n")
    blocks: list[str] = []
    title = ""
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.startswith("> "):
            quote = []
            while i < len(lines) and lines[i].startswith(">"):
                quote.append(lines[i][1:].strip())
                i += 1
            blocks.append(f'<div class="draft" role="note"><p>{inline(" ".join(quote))}</p></div>')
            continue
        heading = re.match(r"^(#{1,3}) (.*)$", line)
        if heading:
            level = len(heading.group(1))
            if level == 1:
                title = heading.group(2)
                blocks.append(f"<h1>{inline(title)}</h1>")
            else:
                blocks.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
            i += 1
            continue
        if line.strip() == "---":
            blocks.append("<hr>")
            i += 1
            continue
        if line.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append(lines[i])
                i += 1
            blocks.append(table(rows))
            continue
        bullet = re.match(r"^(\s*)([-*]|\d+\.) ", line)
        if bullet:
            ordered = bullet.group(2)[0].isdigit()
            items: list[str] = []
            while i < len(lines) and re.match(r"^\s*([-*]|\d+\.) ", lines[i]):
                items.append(re.sub(r"^\s*([-*]|\d+\.) ", "", lines[i]))
                i += 1
            tag = "ol" if ordered else "ul"
            blocks.append(f"<{tag}>" + "".join(f"<li>{inline(item)}</li>" for item in items) + f"</{tag}>")
            continue
        para = []
        while i < len(lines) and lines[i].strip() and not re.match(r"^(#{1,3} |> |\||---$|\s*([-*]|\d+\.) )", lines[i]):
            para.append(lines[i].strip())
            i += 1
        blocks.append(f"<p>{inline(' '.join(para))}</p>")
    return title, "\n".join(blocks)


def page(slug: str, title: str, description: str, body: str) -> str:
    other = "terms" if slug == "privacy" else "privacy"
    other_title = PAGES[other][0]
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="{html.escape(description)}">
<meta name="robots" content="noindex">
<title>Vector {html.escape(title)}</title>
<style>
{CSS}
</style>
</head>
<body>
<main>
<p class="brand">Vector</p>
{body}
<footer><a href="{other}.html">{html.escape(other_title)}</a></footer>
</main>
</body>
</html>
"""


def main() -> None:
    for slug, (title, description) in PAGES.items():
        markdown = (DOCS / f"{slug}.md").read_text()
        markdown = markdown.split(INTERNAL_HEADING)[0].rstrip().removesuffix("---").rstrip() + "\n"
        _, body = convert(markdown)
        (OUT / f"{slug}.html").write_text(page(slug, title, description, body))


if __name__ == "__main__":
    main()
