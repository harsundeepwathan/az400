#!/usr/bin/env python3
"""Render a layout JSON file as a scaled SVG floor plan.

    python3 floorplan.py layout.json -o plan.svg
    python3 floorplan.py layout.json --scale 50 --grid   # true 1:50 at 96dpi

Writes SVG to ``-o``/``--out``, or to stdout when neither is given.
"""

from __future__ import annotations

import argparse
import math
import os
import sys
from xml.sax.saxutils import escape

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from roomspec import Item, Opening, Room, SpecError, load  # noqa: E402

WALL_THICKNESS = 100.0  # mm, drawn outside the room's inside face
PX_PER_MM = 96.0 / 25.4  # CSS pixels per millimetre at 1:1

PALETTE = {
    "sofa": "#b9c7d6",
    "armchair": "#c7d2dd",
    "chair": "#d7dee6",
    "coffee_table": "#e0d3bd",
    "side_table": "#e6dcc9",
    "dining_table": "#dcc9a8",
    "desk": "#dcc9a8",
    "bed": "#cfd8cd",
    "nightstand": "#dde3da",
    "wardrobe": "#c9c3ba",
    "storage": "#cfc9c0",
    "bookshelf": "#cfc9c0",
    "rug": "#f0e9dd",
    "tv": "#5a6570",
    "media_unit": "#c9c3ba",
    "appliance": "#d5d8db",
    "counter": "#d5d8db",
    "fireplace": "#b8a99a",
    "plant": "#c3d6bd",
}
DEFAULT_FILL = "#d8dade"
RUG_KINDS = {"rug", "carpet"}


def fill_for(item: Item) -> str:
    return item.color or PALETTE.get(item.kind, DEFAULT_FILL)


def fmt_mm(value: float) -> str:
    """1850 -> '1850', 1850.4 -> '1850'; metres for anything over 1 m."""
    return f"{value:.0f}"


def fmt_m(value: float) -> str:
    return f"{value / 1000.0:.2f} m"


class Canvas:
    """Millimetre-space drawing that emits SVG user units."""

    def __init__(self, room: Room, px_per_mm: float, margin: float):
        self.room = room
        self.k = px_per_mm
        self.margin = margin
        self.parts: list[str] = []

    def px(self, mm: float) -> float:
        return mm * self.k

    def pt(self, x: float, y: float) -> tuple[float, float]:
        return (self.margin + x * self.k, self.margin + y * self.k)

    def add(self, markup: str) -> None:
        self.parts.append(markup)

    def line(self, x1, y1, x2, y2, cls="thin"):
        (px1, py1), (px2, py2) = self.pt(x1, y1), self.pt(x2, y2)
        self.add(f'<line class="{cls}" x1="{px1:.2f}" y1="{py1:.2f}" '
                 f'x2="{px2:.2f}" y2="{py2:.2f}"/>')

    def polygon(self, points, cls="", style=""):
        coords = " ".join(f"{px:.2f},{py:.2f}" for px, py in (self.pt(x, y) for x, y in points))
        cls_attr = f' class="{cls}"' if cls else ""
        style_attr = f' style="{style}"' if style else ""
        self.add(f"<polygon{cls_attr}{style_attr} points=\"{coords}\"/>")

    def text(self, x, y, content, cls="label", anchor="middle", dy=0.0, size=None):
        px, py = self.pt(x, y)
        size_attr = f' font-size="{size}"' if size else ""
        self.add(f'<text class="{cls}" x="{px:.2f}" y="{py + dy:.2f}" '
                 f'text-anchor="{anchor}"{size_attr}>{escape(content)}</text>')


def draw_walls(canvas: Canvas) -> None:
    """Walls as a filled ring: outer rectangle with the room punched out."""
    room = canvas.room
    t = WALL_THICKNESS
    outer = [(-t, -t), (room.width + t, -t), (room.width + t, room.depth + t), (-t, room.depth + t)]

    def path_for(points):
        moves = [f"{px:.2f} {py:.2f}" for px, py in (canvas.pt(x, y) for x, y in points)]
        return "M " + " L ".join(moves) + " Z"

    canvas.add(f'<path class="wall" fill-rule="evenodd" '
               f'd="{path_for(outer)} {path_for(room.polygon)}"/>')


def _wall_axis(opening: Opening, room: Room):
    """Return (start_point, direction_along_wall, inward_normal)."""
    start, end = opening.endpoints(room.width, room.depth)
    length = math.hypot(end[0] - start[0], end[1] - start[1])
    along = ((end[0] - start[0]) / length, (end[1] - start[1]) / length)
    return start, along, opening.inward()


def draw_openings(canvas: Canvas) -> None:
    room = canvas.room
    t = WALL_THICKNESS
    for opening in room.openings:
        start, along, inward = _wall_axis(opening, room)
        end = (start[0] + along[0] * opening.width, start[1] + along[1] * opening.width)
        # knock the opening out of the wall
        gap = [
            (start[0] - inward[0] * t, start[1] - inward[1] * t),
            (end[0] - inward[0] * t, end[1] - inward[1] * t),
            (end[0] + inward[0] * 2, end[1] + inward[1] * 2),
            (start[0] + inward[0] * 2, start[1] + inward[1] * 2),
        ]
        canvas.polygon(gap, cls="gap")

        if opening.kind == "window":
            for factor in (-0.66, -0.33):
                offset = (inward[0] * t * factor, inward[1] * t * factor)
                canvas.line(start[0] + offset[0], start[1] + offset[1],
                            end[0] + offset[0], end[1] + offset[1], cls="window")
            continue

        canvas.line(start[0], start[1], end[0], end[1], cls="threshold")
        if opening.kind == "opening" or opening.swing == "none":
            continue

        hinge = start if opening.hinge == "start" else end
        direction = 1.0 if opening.hinge == "start" else -1.0
        sign = 1.0 if opening.swing == "in" else -1.0
        leaf = (hinge[0] + inward[0] * opening.width * sign,
                hinge[1] + inward[1] * opening.width * sign)
        arc_end = (hinge[0] + along[0] * opening.width * direction,
                   hinge[1] + along[1] * opening.width * direction)
        canvas.line(hinge[0], hinge[1], leaf[0], leaf[1], cls="leaf")
        (lx, ly) = canvas.pt(*leaf)
        (ax, ay) = canvas.pt(*arc_end)
        radius = canvas.px(opening.width)
        cross = (leaf[0] - hinge[0]) * (arc_end[1] - hinge[1]) - \
                (leaf[1] - hinge[1]) * (arc_end[0] - hinge[0])
        sweep = 1 if cross > 0 else 0
        canvas.add(f'<path class="swing" d="M {lx:.2f} {ly:.2f} '
                   f'A {radius:.2f} {radius:.2f} 0 0 {sweep} {ax:.2f} {ay:.2f}"/>')


def draw_items(canvas: Canvas) -> None:
    for item in sorted(canvas.room.items, key=lambda i: (i.kind not in RUG_KINDS, -i.footprint_mm2)):
        corners = item.corners
        if item.kind in RUG_KINDS:
            canvas.polygon(corners, cls="rug", style=f"fill:{fill_for(item)}")
        elif item.mounted:
            canvas.polygon(corners, cls="mounted", style=f"fill:{fill_for(item)}")
        else:
            canvas.polygon(corners, cls="item", style=f"fill:{fill_for(item)}")
        label_size = max(9.0, min(13.0, canvas.px(min(item.w, item.d)) / 6.0))
        if canvas.px(min(item.w, item.d)) < 26:
            continue
        canvas.text(item.x, item.y, item.name, cls="item-label", dy=-1, size=f"{label_size:.1f}")
        if canvas.px(min(item.w, item.d)) >= 46:
            canvas.text(item.x, item.y, f"{fmt_mm(item.w)}×{fmt_mm(item.d)}",
                        cls="item-dim", dy=label_size + 1, size=f"{label_size * 0.82:.1f}")


def draw_dimensions(canvas: Canvas) -> None:
    room = canvas.room
    off = 320.0
    canvas.line(0, -off, room.width, -off, cls="dim")
    canvas.line(0, -off - 60, 0, -off + 60, cls="dim")
    canvas.line(room.width, -off - 60, room.width, -off + 60, cls="dim")
    canvas.text(room.width / 2, -off, fmt_m(room.width), cls="dim-label", dy=-6)

    canvas.line(-off, 0, -off, room.depth, cls="dim")
    canvas.line(-off - 60, 0, -off + 60, 0, cls="dim")
    canvas.line(-off - 60, room.depth, -off + 60, room.depth, cls="dim")
    px, py = canvas.pt(-off, room.depth / 2)
    canvas.add(f'<text class="dim-label" x="{px - 6:.2f}" y="{py:.2f}" text-anchor="middle" '
               f'transform="rotate(-90 {px - 6:.2f} {py:.2f})">{fmt_m(room.depth)}</text>')


def draw_grid(canvas: Canvas, step: float = 500.0) -> None:
    room = canvas.room
    x = step
    while x < room.width:
        canvas.line(x, 0, x, room.depth, cls="grid")
        x += step
    y = step
    while y < room.depth:
        canvas.line(0, y, room.width, y, cls="grid")
        y += step


def draw_north(canvas: Canvas) -> None:
    room = canvas.room
    cx, cy = room.width + 520, 220
    px, py = canvas.pt(cx, cy)
    canvas.add(
        f'<g class="north" transform="translate({px:.2f} {py:.2f})">'
        f'<circle r="26" class="north-ring"/>'
        f'<path class="north-arrow" d="M 0 -19 L 8 12 L 0 5 L -8 12 Z"/>'
        f'<text class="north-label" y="-30" text-anchor="middle">N</text></g>'
    )


def draw_titleblock(canvas: Canvas, scale_denominator: float | None, width_px: float,
                    height_px: float) -> None:
    room = canvas.room
    y = height_px - canvas.margin * 0.45
    canvas.add(f'<text class="title" x="{canvas.margin:.2f}" y="{y - 20:.2f}">'
               f"{escape(room.name)}</text>")
    bits = [f"{fmt_m(room.width)} × {fmt_m(room.depth)}",
            f"{room.area_m2:.1f} m²",
            f"ceiling {fmt_m(room.height)}",
            f"{len(room.items)} items"]
    canvas.add(f'<text class="subtitle" x="{canvas.margin:.2f}" y="{y:.2f}">'
               f"{escape(' · '.join(bits))}</text>")

    bar_mm = 1000.0
    bar_px = canvas.px(bar_mm)
    bx = width_px - canvas.margin - bar_px
    by = y - 12
    canvas.add(f'<g class="scalebar"><rect x="{bx:.2f}" y="{by:.2f}" width="{bar_px / 2:.2f}" '
               f'height="7" class="bar-dark"/>'
               f'<rect x="{bx + bar_px / 2:.2f}" y="{by:.2f}" width="{bar_px / 2:.2f}" '
               f'height="7" class="bar-light"/>'
               f'<text class="scale-label" x="{bx + bar_px:.2f}" y="{by + 22:.2f}" '
               f'text-anchor="end">1 m'
               + (f" · 1:{scale_denominator:.0f}" if scale_denominator else "")
               + "</text></g>")


STYLE = """
  .sheet { fill: #fbfaf7; }
  .wall { fill: #2f3337; }
  .gap { fill: #fbfaf7; stroke: none; }
  .threshold { stroke: #2f3337; stroke-width: 1.2; }
  .window { stroke: #4c565f; stroke-width: 1.4; }
  .leaf { stroke: #4c565f; stroke-width: 1.4; }
  .swing { fill: none; stroke: #9aa4ad; stroke-width: 1; stroke-dasharray: 4 3; }
  .item { stroke: #5c646c; stroke-width: 1; }
  .mounted { stroke: #2f3337; stroke-width: 1; stroke-dasharray: 3 2; }
  .rug { stroke: #cbbfa8; stroke-width: 1; stroke-dasharray: 6 4; }
  .grid { stroke: #e4e0d6; stroke-width: 0.6; }
  .dim { stroke: #8c949b; stroke-width: 0.9; }
  .dim-label { fill: #5c646c; font-size: 12px; }
  .item-label { fill: #2f3337; font-weight: 600; }
  .item-dim { fill: #5c646c; }
  .title { fill: #2f3337; font-size: 20px; font-weight: 700; }
  .subtitle { fill: #5c646c; font-size: 12px; }
  .scale-label { fill: #5c646c; font-size: 11px; }
  .bar-dark { fill: #2f3337; }
  .bar-light { fill: #fbfaf7; stroke: #2f3337; stroke-width: 1; }
  .north-ring { fill: none; stroke: #8c949b; stroke-width: 1; }
  .north-arrow { fill: #2f3337; }
  .north-label { fill: #5c646c; font-size: 11px; font-weight: 700; }
  text { font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; dominant-baseline: middle; }
  .title, .subtitle, .scale-label { dominant-baseline: auto; }
"""


def render(room: Room, target_width: float = 1100.0, scale_denominator: float | None = None,
           grid: bool = False) -> str:
    if scale_denominator:
        px_per_mm = PX_PER_MM / scale_denominator
        margin = 90.0
    else:
        margin = 90.0
        usable = max(200.0, target_width - 2 * margin - 140.0)
        px_per_mm = usable / room.width
    canvas = Canvas(room, px_per_mm, margin)

    width_px = margin * 2 + canvas.px(room.width) + 140.0
    height_px = margin * 2 + canvas.px(room.depth) + 70.0

    canvas.add(f'<rect class="sheet" x="0" y="0" width="{width_px:.2f}" height="{height_px:.2f}"/>')
    if grid:
        draw_grid(canvas)
    draw_walls(canvas)
    draw_openings(canvas)
    draw_items(canvas)
    draw_dimensions(canvas)
    draw_north(canvas)
    draw_titleblock(canvas, scale_denominator, width_px, height_px)

    body = "\n  ".join(canvas.parts)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width_px:.0f}" '
        f'height="{height_px:.0f}" viewBox="0 0 {width_px:.2f} {height_px:.2f}" '
        f'role="img" aria-label="{escape(room.name)} floor plan">\n'
        f"  <style>{STYLE}  </style>\n  {body}\n</svg>\n"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Render a layout JSON file as an SVG floor plan.")
    parser.add_argument("layout", help="path to the layout JSON file")
    parser.add_argument("-o", "--out", help="output SVG path (default: stdout)")
    parser.add_argument("--width", type=float, default=1100.0,
                        help="target image width in pixels (default 1100)")
    parser.add_argument("--scale", type=float, default=None,
                        help="draw at a true scale, e.g. 50 for 1:50 at 96 dpi")
    parser.add_argument("--grid", action="store_true", help="draw a 500 mm reference grid")
    args = parser.parse_args(argv)

    try:
        room = load(args.layout)
    except (SpecError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    svg = render(room, target_width=args.width, scale_denominator=args.scale, grid=args.grid)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(svg)
        print(f"wrote {args.out} ({room.name}, {room.area_m2:.1f} m², {len(room.items)} items)")
    else:
        sys.stdout.write(svg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
