#!/usr/bin/env python3
"""Design an MDF TV feature wall: elevation drawing, cut list and build notes.

    python3 featurewall.py --width 3600 --height 2400 --tv 65
    python3 featurewall.py --width 4200 --style shaker -o wall.svg
    python3 featurewall.py --width 3600 --tv 75 --json

Two styles:

  slat    vertical MDF battens on a backing panel, with a flat inset behind the
          TV so cables and the bracket have somewhere to go
  shaker  a grid of MDF mouldings planted straight onto the plastered wall,
          with the TV bay left as one larger opening

Sizes are millimetres. Sheet material is assumed to be 2440 x 1220 MDF.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from xml.sax.saxutils import escape

SHEET_LONG, SHEET_SHORT = 2440.0, 1220.0
KERF = 3.0
ASPECT_W, ASPECT_H = 0.87157, 0.49026  # 16:9 screen from its diagonal


class Spec:
    """Every dimension the drawing and the cut list are derived from."""

    def __init__(self, width=3600.0, height=2400.0, tv_inches=65.0, style="slat",
                 slat_width=60.0, slat_gap=40.0, thickness=18.0, batten=25.0,
                 console=True, console_width=2000.0, console_height=280.0,
                 console_depth=400.0, console_base=250.0, tv_gap=200.0,
                 skirting=0.0, name="TV feature wall"):
        if width <= 0 or height <= 0:
            raise ValueError("wall width and height must be positive")
        if style not in ("slat", "shaker"):
            raise ValueError("style must be 'slat' or 'shaker'")
        if slat_width <= 0 or slat_gap < 0:
            raise ValueError("slat width must be positive and the gap cannot be negative")
        self.name = name
        self.width = float(width)
        self.height = float(height)
        self.style = style
        self.thickness = float(thickness)
        self.batten = float(batten)
        self.slat_width = float(slat_width)
        self.slat_gap = float(slat_gap)
        self.skirting = float(skirting)

        self.tv_inches = float(tv_inches)
        diagonal = self.tv_inches * 25.4
        self.tv_w = diagonal * ASPECT_W
        self.tv_h = diagonal * ASPECT_H

        self.console = bool(console)
        self.console_w = min(float(console_width), self.width - 200.0)
        self.console_h = float(console_height)
        self.console_d = float(console_depth)
        self.console_base = float(console_base)
        self.console_top = self.console_base + self.console_h if self.console else self.skirting

        # Screen centre: seated eye level if it clears the console, otherwise as
        # low as the console lets it sit.
        preferred = 1150.0
        floor = self.console_top + float(tv_gap) + self.tv_h / 2.0
        self.tv_centre_y = max(preferred, floor)
        self.tv_top = self.tv_centre_y + self.tv_h / 2.0
        self.tv_bottom = self.tv_centre_y - self.tv_h / 2.0
        if self.tv_top > self.height - 150.0:
            raise ValueError(f"a {self.tv_inches:.0f} inch screen will not fit under a "
                             f"{self.height:.0f} mm ceiling at a sensible height")

        # The flat inset the TV hangs on: screen plus a margin, snapped to the
        # slat pitch so the panel lands between battens rather than through one.
        margin = 150.0
        self.inset_w = self.tv_w + margin * 2
        if self.style == "slat":
            self.inset_w = self.snap_to_pitch(self.inset_w)
        self.inset_x = (self.width - self.inset_w) / 2.0
        # the bay stops clear of the console rather than running behind it
        self.inset_y = max(self.tv_bottom - margin, self.console_top + 60.0)
        self.inset_top = min(self.tv_top + margin, self.height - 60.0)
        self.inset_h = self.inset_top - self.inset_y
        if self.inset_h < self.tv_h + 60.0:
            raise ValueError("not enough height between the console and the ceiling for "
                             "this screen; lower the console or use a smaller screen")

    # ------------------------------------------------------------------ #
    @property
    def pitch(self) -> float:
        return self.slat_width + self.slat_gap

    @property
    def build_out(self) -> float:
        return self.thickness + (self.batten if self.style == "slat" else 0.0)

    def batten_count(self, centres: float = 600.0) -> int:
        return int(math.ceil(self.width / centres)) + 1

    def snap_to_pitch(self, value: float) -> float:
        return math.ceil(value / self.pitch) * self.pitch - self.slat_gap

    def slat_columns(self) -> list[dict]:
        """Every batten across the wall, and where the TV inset interrupts it."""
        count = max(1, int(round((self.width + self.slat_gap) / self.pitch)))
        span = count * self.pitch - self.slat_gap
        start = (self.width - span) / 2.0
        columns = []
        for index in range(count):
            x = start + index * self.pitch
            interrupted = (self.style == "slat"
                           and x + self.slat_width > self.inset_x
                           and x < self.inset_x + self.inset_w)
            columns.append({"x": x, "interrupted": interrupted})
        return columns

    def shaker_grid(self) -> dict:
        """Rail and stile positions for the panelled style.

        Bays are even across the wall, and any stile that would run through the
        TV bay is dropped so the screen sits in one clear opening.
        """
        rail_w = 70.0
        top_rail = min(self.height - 300.0, 2100.0)
        bays = max(2, int(round(self.width / 900.0)))
        step = (self.width - rail_w) / bays
        stiles = [i * step for i in range(bays + 1)]
        kept = [x for x in stiles
                if x + rail_w <= self.inset_x - 20 or x >= self.inset_x + self.inset_w + 20]
        return {"rail_w": rail_w, "top_rail": top_rail, "bays": bays, "stiles": kept,
                "bottom_rail": self.skirting, "dropped": len(stiles) - len(kept)}


# ---------------------------------------------------------------------- #
# cut list
# ---------------------------------------------------------------------- #
def cut_list(spec: Spec) -> list[dict]:
    items: list[dict] = []

    def add(part, qty, length, width, thickness, note=""):
        if qty <= 0:
            return
        length, width = max(length, width), min(length, width)
        items.append({"part": part, "qty": int(qty), "length": round(length),
                      "width": round(width), "thickness": round(thickness), "note": note})

    if spec.style == "slat":
        backing_h = spec.height - spec.skirting
        add("Backing panel", math.ceil(spec.width / SHEET_SHORT), backing_h, SHEET_SHORT,
            spec.thickness, "cut the last one to width; butt joints land on a batten")
        add("Wall batten (vertical)", spec.batten_count(), backing_h, 50, spec.batten,
            "softwood, plugged and screwed to the wall at 600 mm centres")

        columns = spec.slat_columns()
        full = [c for c in columns if not c["interrupted"]]
        cut = [c for c in columns if c["interrupted"]]
        add("Slat, full height", len(full), backing_h - spec.skirting, spec.slat_width,
            spec.thickness, "ripped from sheet, long edges eased with 120 grit")
        add("Slat, above TV inset", len(cut), spec.height - spec.inset_top, spec.slat_width,
            spec.thickness, "over the inset")
        add("Slat, below TV inset", len(cut), spec.inset_y - spec.skirting, spec.slat_width,
            spec.thickness, "under the inset")
        add("TV inset panel", 1, spec.inset_h, spec.inset_w, spec.thickness,
            "sits proud of the backing by the batten depth, flush with the slat faces")
        add("Inset return", 2, spec.inset_h, spec.build_out, spec.thickness, "sides of the bay")
        add("Inset return", 2, spec.inset_w, spec.build_out, spec.thickness,
            "head and sill of the bay")
    else:
        grid = spec.shaker_grid()
        add("Stile (vertical)", len(grid["stiles"]), grid["top_rail"] - spec.skirting,
            grid["rail_w"], spec.thickness,
            f"{grid['bays']} even bays, {grid['dropped']} stiles omitted at the TV bay")
        add("Rail (horizontal)", 2, spec.width, grid["rail_w"], spec.thickness,
            "top rail and bottom rail, running the full width behind the stiles")
        add("TV bay lining", 4, max(spec.inset_w, spec.inset_h), 40, spec.thickness,
            "frames the opening the TV hangs in")

    if spec.console:
        add("Console top / bottom", 2, spec.console_w, spec.console_d, spec.thickness)
        add("Console end", 2, spec.console_d, spec.console_h - 2 * spec.thickness,
            spec.thickness)
        add("Console divider", 1, spec.console_d, spec.console_h - 2 * spec.thickness,
            spec.thickness, "stiffens the span and splits the shelf")
        add("Console back", 1, spec.console_w - 2 * spec.thickness,
            spec.console_h - 2 * spec.thickness, spec.thickness,
            "drill a 60 mm cable grommet before assembly")
        add("Console door / drawer front", 2, spec.console_w / 2 - 3, spec.console_h - 6,
            spec.thickness, "3 mm shadow gap all round")
        add("French cleat", 2, spec.console_w - 100, 120, spec.thickness,
            "45 degrees on the table saw; one half on the wall, one on the carcass")

    return items


def sheets_needed(spec: Spec, items: list[dict]) -> dict:
    """Rough sheet count: rips for long thin parts, area for panels."""
    rip_length = 0.0
    panel_area = 0.0
    over_length = []
    for item in items:
        if item["thickness"] != round(spec.thickness):
            continue  # battens and cleats come out of other stock
        if item["length"] > SHEET_LONG:
            over_length.append(item["part"])
        if item["width"] <= 300:
            per_sheet = max(1, int(SHEET_SHORT // (item["width"] + KERF)))
            rip_length += item["qty"] * item["length"] / per_sheet
        else:
            panel_area += item["qty"] * item["length"] * item["width"]
    sheets = rip_length / SHEET_LONG + panel_area / (SHEET_LONG * SHEET_SHORT)
    return {"sheets": math.ceil(sheets + 0.4), "raw": round(sheets, 2),
            "over_length": sorted(set(over_length))}


def materials(spec: Spec, items: list[dict]) -> list[str]:
    sheet = sheets_needed(spec, items)
    slat_pieces = sum(item["qty"] for item in items if item["part"].startswith("Slat"))
    lines = [f"{sheet['sheets']} × 2440 × 1220 × {spec.thickness:.0f} mm MDF "
             f"(≈{sheet['raw']} sheets of material, rounded up for waste and mistakes)"]
    if spec.style == "slat":
        lines.append(f"{len(spec.slat_columns())} slat lines at {spec.slat_width:.0f} mm wide "
                     f"and {spec.slat_gap:.0f} mm apart ({spec.pitch:.0f} mm pitch), "
                     f"{slat_pieces} pieces once the inset breaks them")
        lines.append(f"{spec.batten_count()} × 50 × {spec.batten:.0f} mm softwood battens "
                     f"at 600 mm centres, plus wall plugs and 60 mm screws")
    lines += [
        "Grab adhesive (MDF to backing), 18 g pin nails, 12 × 40 mm screws for the cleat",
        "MDF primer (two coats, sanded between) and eggshell or satin topcoat",
        "Caulk for the wall junctions, filler for the pin holes",
    ]
    if spec.console:
        lines.append("Push-to-open hinges or runners, and a 60 mm cable grommet")
    lines.append("2 m of 24 V LED strip + driver if you want the shadow-gap glow")
    if sheet["over_length"]:
        lines.append("NOTE: " + ", ".join(sheet["over_length"]) +
                     " exceeds a 2440 mm sheet — join over a batten or buy 3050 mm boards")
    return lines


def build_notes(spec: Spec) -> list[str]:
    steps = [
        "Find the studs and the services. Scan the wall before you drill: a TV bracket "
        "wants a stud or a proper cavity fixing, and the cable route has to miss both.",
        f"Set the bracket height first. The screen centre lands at "
        f"{spec.tv_centre_y:.0f} mm, which is eye level for someone sitting on a sofa. "
        f"Sit down and check it before anything is fixed.",
    ]
    if spec.style == "slat":
        steps += [
            f"Batten the wall vertically at roughly 600 mm centres, packed plumb — the "
            f"finished face is only as flat as the battens. Total build-out is "
            f"{spec.build_out:.0f} mm.",
            "Fix the backing panel to the battens, joints landing on a batten, and paint it "
            "the same colour as the slats before the slats go on. You will never reach "
            "between them afterwards.",
            f"Rip the slats {spec.slat_width:.0f} mm wide from full sheets, all in one "
            f"session so the width is identical. Ease the arrises with 120 grit.",
            f"Fit the TV inset panel first, then work the slats out from it towards both "
            f"ends. Use a {spec.slat_gap:.0f} mm offcut as a spacer, and check plumb every "
            f"fourth slat rather than trusting the spacer.",
            "Leave the end gap to the corner even, not whatever is left — take the "
            "difference off both end slats.",
        ]
    else:
        steps += [
            "Mark the grid on the wall in pencil and live with it for a day before you cut "
            "anything. Bay widths that differ by 10 mm are visible from across the room.",
            "Plant the stiles first, then scribe the rails between them. Glue and pin into "
            "solid plaster; use grab adhesive on dot-and-dab and pin only where you can "
            "find something to pin to.",
            "Mitre nothing. Butt joints filled and sanded read as one piece once painted.",
        ]
    steps += [
        "Bring the cables through before you close anything up: two HDMI, one power, one "
        "spare, in a 50 mm conduit from behind the screen down to the console.",
        "Fill, caulk the wall junctions, prime the cut MDF edges twice — they drink paint — "
        "and sand between coats. Spray or roll with a fine foam roller, never a brush.",
    ]
    if spec.console:
        steps.append(
            f"Hang the console on a French cleat at {spec.console_base:.0f} mm above the "
            f"floor. The gap under it is what makes it look floating; an LED strip in that "
            f"gap, and behind the TV inset, is the cheapest upgrade on the wall.")
    steps.append("Paint the wall darker than you think. A feature wall in an off-white reads "
                 "as texture; in a deep tone it reads as architecture.")
    return steps


# ---------------------------------------------------------------------- #
# drawing
# ---------------------------------------------------------------------- #
STYLE = """
  .sheet{fill:#fbfaf7}
  .wall{fill:#e9e6df;stroke:#2f3337;stroke-width:1.2}
  .backing{fill:#3a4046}
  .slat{fill:#6f5b45;stroke:#5b4a37;stroke-width:.5}
  .inset{fill:#2b3036;stroke:#20242a;stroke-width:1}
  .moulding{fill:#dfe3e6;stroke:#9aa4ad;stroke-width:.8}
  .tv{fill:#15181b;stroke:#000;stroke-width:1}
  .screen{fill:#1d2126}
  .console{fill:#514132;stroke:#3b2f24;stroke-width:1}
  .consoleline{stroke:#4a3b2c;stroke-width:.8}
  .glow{fill:#f7d9a2;opacity:.65;filter:url(#soft)}
  .floor{stroke:#2f3337;stroke-width:1.4}
  .dim{stroke:#8c949b;stroke-width:.9}
  .dimlabel{fill:#5c646c;font-size:11px}
  .note{fill:#5c646c;font-size:11px}
  .title{fill:#2f3337;font-size:19px;font-weight:700}
  .sub{fill:#5c646c;font-size:12px}
  .key{fill:#2f3337;font-size:11px;font-weight:600}
  .sectionfill{fill:#d8d4cc;stroke:#2f3337;stroke-width:.8}
  .sectionmdf{fill:#6f5b45;stroke:#4a3b2c;stroke-width:.8}
  .sectionbatten{fill:#c9b79a;stroke:#8c7a5e;stroke-width:.8}
  text{font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;dominant-baseline:auto}
"""


def glow_rect(px, k: float, spec: Spec) -> str:
    """The wash of LED light escaping around the inset bay."""
    gx, gy = px(spec.inset_x - 45, spec.inset_top + 45)
    return (f'<rect class="glow" x="{gx:.1f}" y="{gy:.1f}" '
            f'width="{(spec.inset_w + 90) * k:.1f}" '
            f'height="{(spec.inset_h + 90) * k:.1f}" rx="8"/>')


def render(spec: Spec, target_width: float = 1240.0) -> str:
    margin = 96.0
    detail_w = 300.0
    usable = target_width - 2 * margin - detail_w
    k = usable / spec.width
    plan_h = spec.height * k
    width_px = target_width
    height_px = max(margin * 2 + plan_h + 86.0, margin + 640.0)

    def px(x: float, y: float) -> tuple[float, float]:
        """Elevation coordinates: x from the left of the wall, y up from the floor."""
        return (margin + x * k, margin + (spec.height - y) * k)

    out = [f'<rect class="sheet" x="0" y="0" width="{width_px:.1f}" height="{height_px:.1f}"/>']
    x0, y0 = px(0, spec.height)
    out.append(f'<rect class="wall" x="{x0:.1f}" y="{y0:.1f}" '
               f'width="{spec.width * k:.1f}" height="{plan_h:.1f}"/>')

    if spec.style == "slat":
        out.append(f'<rect class="backing" x="{x0:.1f}" y="{y0:.1f}" '
                   f'width="{spec.width * k:.1f}" height="{plan_h:.1f}"/>')
        for column in spec.slat_columns():
            sx = column["x"]
            if not column["interrupted"]:
                bx, by = px(sx, spec.height)
                out.append(f'<rect class="slat" x="{bx:.1f}" y="{by:.1f}" '
                           f'width="{spec.slat_width * k:.1f}" height="{plan_h:.1f}"/>')
                continue
            for bottom, top in ((spec.inset_top, spec.height), (0.0, spec.inset_y)):
                if top - bottom <= 1:
                    continue
                bx, by = px(sx, top)
                out.append(f'<rect class="slat" x="{bx:.1f}" y="{by:.1f}" '
                           f'width="{spec.slat_width * k:.1f}" '
                           f'height="{(top - bottom) * k:.1f}"/>')
        out.append(glow_rect(px, k, spec))
        ix, iy = px(spec.inset_x, spec.inset_top)
        out.append(f'<rect class="inset" x="{ix:.1f}" y="{iy:.1f}" '
                   f'width="{spec.inset_w * k:.1f}" height="{spec.inset_h * k:.1f}" rx="2"/>')
    else:
        grid = spec.shaker_grid()
        rail = grid["rail_w"]
        base = grid["bottom_rail"]
        for sx in grid["stiles"]:
            bx, by = px(sx, grid["top_rail"])
            out.append(f'<rect class="moulding" x="{bx:.1f}" y="{by:.1f}" '
                       f'width="{rail * k:.1f}" '
                       f'height="{(grid["top_rail"] - base) * k:.1f}"/>')
        for ry in (grid["top_rail"], base + rail):
            bx, by = px(0, ry)
            out.append(f'<rect class="moulding" x="{bx:.1f}" y="{by:.1f}" '
                       f'width="{spec.width * k:.1f}" height="{rail * k:.1f}"/>')
        out.append(glow_rect(px, k, spec))
        ix, iy = px(spec.inset_x, spec.inset_top)
        out.append(f'<rect class="inset" x="{ix:.1f}" y="{iy:.1f}" '
                   f'width="{spec.inset_w * k:.1f}" height="{spec.inset_h * k:.1f}" rx="2"/>')

    # television
    tx, ty = px((spec.width - spec.tv_w) / 2.0, spec.tv_top)
    out.append(f'<rect class="tv" x="{tx:.1f}" y="{ty:.1f}" width="{spec.tv_w * k:.1f}" '
               f'height="{spec.tv_h * k:.1f}" rx="3"/>')
    out.append(f'<rect class="screen" x="{tx + 3:.1f}" y="{ty + 3:.1f}" '
               f'width="{spec.tv_w * k - 6:.1f}" height="{spec.tv_h * k - 6:.1f}" rx="2"/>')

    # console
    if spec.console:
        cx, cy = px((spec.width - spec.console_w) / 2.0, spec.console_top)
        out.append(f'<rect class="glow" x="{cx + 6:.1f}" y="{cy + spec.console_h * k:.1f}" '
                   f'width="{spec.console_w * k - 12:.1f}" '
                   f'height="{min(14.0, spec.console_base * k * 0.6):.1f}"/>')
        out.append(f'<rect class="console" x="{cx:.1f}" y="{cy:.1f}" '
                   f'width="{spec.console_w * k:.1f}" height="{spec.console_h * k:.1f}" rx="2"/>')
        mid = cx + spec.console_w * k / 2.0
        out.append(f'<line class="consoleline" x1="{mid:.1f}" y1="{cy:.1f}" x2="{mid:.1f}" '
                   f'y2="{cy + spec.console_h * k:.1f}"/>')

    fx0, fy0 = px(-120, 0)
    fx1, _ = px(spec.width + 120, 0)
    out.append(f'<line class="floor" x1="{fx0:.1f}" y1="{fy0:.1f}" x2="{fx1:.1f}" '
               f'y2="{fy0:.1f}"/>')

    # dimensions
    def hdim(x_from, x_to, y, label, above=True):
        (ax, ay), (bx, _) = px(x_from, y), px(x_to, y)
        out.append(f'<line class="dim" x1="{ax:.1f}" y1="{ay:.1f}" x2="{bx:.1f}" y2="{ay:.1f}"/>')
        for edge in (ax, bx):
            out.append(f'<line class="dim" x1="{edge:.1f}" y1="{ay - 5:.1f}" '
                       f'x2="{edge:.1f}" y2="{ay + 5:.1f}"/>')
        out.append(f'<text class="dimlabel" x="{(ax + bx) / 2:.1f}" '
                   f'y="{ay + (-7 if above else 15):.1f}" text-anchor="middle">{label}</text>')

    def vdim(y_from, y_to, x, label):
        (ax, ay), (_, by) = px(x, y_from), px(x, y_to)
        out.append(f'<line class="dim" x1="{ax:.1f}" y1="{ay:.1f}" x2="{ax:.1f}" y2="{by:.1f}"/>')
        for edge in (ay, by):
            out.append(f'<line class="dim" x1="{ax - 5:.1f}" y1="{edge:.1f}" '
                       f'x2="{ax + 5:.1f}" y2="{edge:.1f}"/>')
        out.append(f'<text class="dimlabel" x="{ax - 8:.1f}" y="{(ay + by) / 2:.1f}" '
                   f'text-anchor="middle" transform="rotate(-90 {ax - 8:.1f} '
                   f'{(ay + by) / 2:.1f})">{label}</text>')

    hdim(0, spec.width, spec.height + 190, f"{spec.width:.0f}")
    hdim(spec.inset_x, spec.inset_x + spec.inset_w, spec.height + 70,
         f"inset {spec.inset_w:.0f}")
    vdim(0, spec.height, -190, f"{spec.height:.0f}")
    vdim(0, spec.tv_centre_y, -70, f"screen centre {spec.tv_centre_y:.0f}")
    if spec.console:
        vdim(0, spec.console_base, spec.width + 110, f"{spec.console_base:.0f}")

    # section detail and key, laid out as a column so nothing collides
    sx = margin + spec.width * k + 130.0
    sy = margin + 30.0
    scale = 0.42
    if spec.style == "slat":
        layers = [("Existing plaster", 120.0, "sectionfill"),
                  (f"Batten {spec.batten:.0f} mm", spec.batten, "sectionbatten"),
                  (f"Backing MDF {spec.thickness:.0f} mm", spec.thickness, "sectionmdf"),
                  (f"Slat {spec.slat_width:.0f} × {spec.thickness:.0f} mm", spec.thickness,
                   "sectionmdf")]
    else:
        layers = [("Existing plaster", 120.0, "sectionfill"),
                  (f"Moulding {spec.thickness:.0f} mm", spec.thickness, "sectionmdf")]

    out.append(f'<text class="key" x="{sx:.1f}" y="{sy:.1f}">Section through the wall</text>')
    out.append(f'<text class="note" x="{sx:.1f}" y="{sy + 16:.1f}">plan view, not to scale</text>')
    band_top = sy + 32.0
    cursor = 0.0
    for label, depth, cls in layers:
        drawn = max(7.0, depth * scale * 2.4)
        band_h = 132.0 if label.startswith("Existing") else 96.0
        out.append(f'<rect class="{cls}" x="{sx + cursor:.1f}" y="{band_top:.1f}" '
                   f'width="{drawn:.1f}" height="{band_h:.1f}"/>')
        cursor += drawn
    out.append(f'<text class="note" x="{sx:.1f}" y="{band_top + 152:.1f}">'
               f'← room side is to the right</text>')

    legend_y = band_top + 178.0
    for index, (label, _, cls) in enumerate(layers):
        row = legend_y + index * 19.0
        out.append(f'<rect class="{cls}" x="{sx:.1f}" y="{row - 9:.1f}" width="12" height="12"/>')
        out.append(f'<text class="note" x="{sx + 19:.1f}" y="{row:.1f}">{escape(label)}</text>')
    out.append(f'<text class="key" x="{sx:.1f}" y="{legend_y + len(layers) * 19 + 12:.1f}">'
               f'Total build-out {spec.build_out:.0f} mm</text>')

    key_y = legend_y + len(layers) * 19 + 48.0
    out.append(f'<text class="key" x="{sx:.1f}" y="{key_y:.1f}">Key dimensions</text>')
    keys = [f"Screen {spec.tv_inches:.0f}\" — {spec.tv_w:.0f} × {spec.tv_h:.0f}",
            f"Screen centre {spec.tv_centre_y:.0f} above floor",
            f"Inset bay {spec.inset_w:.0f} × {spec.inset_h:.0f}"]
    if spec.style == "slat":
        keys.append(f"{len(spec.slat_columns())} slats at {spec.pitch:.0f} mm pitch")
    if spec.console:
        keys.append(f"Console {spec.console_w:.0f} × {spec.console_h:.0f} × "
                    f"{spec.console_d:.0f} deep")
        keys.append(f"Floating {spec.console_base:.0f} above the floor")
    for index, line in enumerate(keys):
        out.append(f'<text class="note" x="{sx:.1f}" y="{key_y + 20 + index * 17:.1f}">'
                   f'{escape(line)}</text>')

    out.append(f'<text class="title" x="{margin:.1f}" y="{height_px - 46:.1f}">'
               f'{escape(spec.name)}</text>')
    subtitle = (f"{spec.style} style · {spec.width:.0f} × {spec.height:.0f} mm wall · "
                f"{spec.thickness:.0f} mm MDF · elevation, dimensions in mm")
    out.append(f'<text class="sub" x="{margin:.1f}" y="{height_px - 26:.1f}">'
               f'{escape(subtitle)}</text>')

    body = "\n  ".join(out)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width_px:.0f}" '
            f'height="{height_px:.0f}" viewBox="0 0 {width_px:.1f} {height_px:.1f}" '
            f'role="img" aria-label="{escape(spec.name)} elevation">\n'
            f"  <style>{STYLE}  </style>\n"
            f'  <defs><filter id="soft" x="-25%" y="-25%" width="150%" height="150%">'
            f'<feGaussianBlur stdDeviation="7"/></filter></defs>\n'
            f"  {body}\n</svg>\n")


# ---------------------------------------------------------------------- #
def format_text(spec: Spec, items: list[dict]) -> str:
    lines = [f"{spec.name} — {spec.style} style",
             f"  wall {spec.width:.0f} × {spec.height:.0f} mm, "
             f"{spec.thickness:.0f} mm MDF, build-out {spec.build_out:.0f} mm",
             f"  screen {spec.tv_inches:.0f}\" ({spec.tv_w:.0f} × {spec.tv_h:.0f}), "
             f"centre {spec.tv_centre_y:.0f} above the floor", "", "CUT LIST"]
    lines.append(f"  {'part':<28}{'qty':>4}{'length':>9}{'width':>8}{'thk':>6}")
    for item in items:
        lines.append(f"  {item['part']:<28}{item['qty']:>4}{item['length']:>9}"
                     f"{item['width']:>8}{item['thickness']:>6}"
                     + (f"   {item['note']}" if item["note"] else ""))
    lines += ["", "MATERIALS"]
    lines += [f"  · {line}" for line in materials(spec, items)]
    lines += ["", "BUILD"]
    for index, step in enumerate(build_notes(spec), 1):
        lines.append(f"  {index}. {step}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Design an MDF TV feature wall.")
    parser.add_argument("--width", type=float, default=3600.0, help="wall width in mm")
    parser.add_argument("--height", type=float, default=2400.0, help="floor to ceiling in mm")
    parser.add_argument("--tv", type=float, default=65.0, dest="tv_inches",
                        help="screen size in inches")
    parser.add_argument("--style", default="slat", choices=("slat", "shaker"))
    parser.add_argument("--slat-width", type=float, default=60.0)
    parser.add_argument("--slat-gap", type=float, default=40.0)
    parser.add_argument("--thickness", type=float, default=18.0, help="MDF thickness")
    parser.add_argument("--batten", type=float, default=25.0, help="wall batten depth")
    parser.add_argument("--no-console", action="store_true", help="leave out the media unit")
    parser.add_argument("--console-width", type=float, default=2000.0)
    parser.add_argument("--console-height", type=float, default=280.0)
    parser.add_argument("--console-base", type=float, default=250.0,
                        help="height of the underside above the floor")
    parser.add_argument("--name", default="TV feature wall")
    parser.add_argument("-o", "--out", help="write the elevation SVG here")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args(argv)

    try:
        spec = Spec(width=args.width, height=args.height, tv_inches=args.tv_inches,
                    style=args.style, slat_width=args.slat_width, slat_gap=args.slat_gap,
                    thickness=args.thickness, batten=args.batten,
                    console=not args.no_console, console_width=args.console_width,
                    console_height=args.console_height,
                    console_base=args.console_base,
                    name=args.name)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    items = cut_list(spec)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(render(spec))

    if args.json:
        print(json.dumps({
            "wall": {"width": spec.width, "height": spec.height, "style": spec.style,
                     "thickness": spec.thickness, "build_out": spec.build_out},
            "tv": {"inches": spec.tv_inches, "width": round(spec.tv_w),
                   "height": round(spec.tv_h), "centre_height": round(spec.tv_centre_y)},
            "inset": {"width": round(spec.inset_w), "height": round(spec.inset_h)},
            "cut_list": items, "materials": materials(spec, items),
            "build": build_notes(spec)}, indent=2))
    else:
        print(format_text(spec, items))
        if args.out:
            print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
