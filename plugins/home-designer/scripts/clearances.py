#!/usr/bin/env python3
"""Check a layout against ergonomic clearance and circulation rules.

    python3 clearances.py layout.json
    python3 clearances.py layout.json --json
    python3 clearances.py layout.json --strict     # warnings fail too

Exit status: 0 clean, 1 problems found, 2 the file could not be read.

Every distance is millimetres. Grid-based checks (circulation, door swing) use
a 50 mm raster, so treat results within ±50 mm of a limit as "measure it".
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from roomspec import (  # noqa: E402
    Grid, Item, Room, SpecError, load, point_in_polygon, point_polygon_distance,
    polygon_distance, polygons_overlap,
)

# Defaults in mm. Any of these can be overridden per layout via "clearances".
DEFAULTS = {
    "primary_walkway": 900,      # a route people use to cross the room
    "secondary_gap": 750,        # squeeze-past route between two pieces
    "approach": 600,             # getting to a piece from the circulation route
    "sofa_to_table_min": 300,
    "sofa_to_table_max": 450,
    "bed_side": 600,
    "bed_foot": 700,
    "wardrobe_front": 900,       # door swing + standing room
    "storage_front": 750,
    "dining_pullout": 900,       # chair pulled back from the table edge
    "tv_distance_factor_min": 1.5,
    "tv_distance_factor_max": 2.5,
    "against_wall": 120,         # gap at or below this counts as "against it"
}

SEATING = {"sofa", "armchair", "chair", "loveseat", "sectional", "bench"}
LOW_TABLES = {"coffee_table", "ottoman", "side_table"}
FRONTED = {"wardrobe": "wardrobe_front", "closet": "wardrobe_front",
           "dresser": "storage_front", "storage": "storage_front",
           "bookshelf": "storage_front", "media_unit": "storage_front",
           "cabinet": "storage_front", "appliance": "storage_front"}
FLAT = {"rug", "carpet", "runner"}
# small pieces that live against another piece and are reached from it
ACCESSORY = {"nightstand", "side_table", "lamp", "floor_lamp", "plant", "stool", "bin"}
BEDSIDE = {"nightstand", "side_table", "lamp", "floor_lamp"}
SCREENS = {"tv", "television", "screen", "projector_screen"}

RAY_STEP = 25.0
RAY_LIMIT = 2500.0


class Report:
    def __init__(self) -> None:
        self.findings: list[dict] = []

    def add(self, severity: str, rule: str, message: str, **extra) -> None:
        entry = {"severity": severity, "rule": rule, "message": message}
        entry.update(extra)
        self.findings.append(entry)

    def counts(self) -> dict:
        out = {"error": 0, "warning": 0, "note": 0}
        for finding in self.findings:
            out[finding["severity"]] = out.get(finding["severity"], 0) + 1
        return out


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def limits(room: Room) -> dict:
    values = dict(DEFAULTS)
    values.update(room.clearances or {})
    return values


def solid(room: Room) -> list[Item]:
    """Items that actually occupy floor space."""
    return [item for item in room.items
            if item.kind not in FLAT and not item.mounted]


def side_normals(item: Item) -> dict[str, tuple[float, float]]:
    a = math.radians(item.rotation)
    cos_a, sin_a = math.cos(a), math.sin(a)

    def rot(vx: float, vy: float) -> tuple[float, float]:
        return (vx * cos_a - vy * sin_a, vx * sin_a + vy * cos_a)

    return {"front": rot(0.0, -1.0), "back": rot(0.0, 1.0),
            "left": rot(-1.0, 0.0), "right": rot(1.0, 0.0)}


def side_edge(item: Item, side: str) -> tuple[tuple[float, float], tuple[float, float]]:
    corners = item.corners  # nw, ne, se, sw in the item's local frame, rotated
    mapping = {"front": (0, 1), "right": (1, 2), "back": (2, 3), "left": (3, 0)}
    i, j = mapping[side]
    return corners[i], corners[j]


def side_clearance(item: Item, side: str, room: Room, others: list[Item],
                   samples: int = 9, limit: float = RAY_LIMIT) -> float:
    """How far you can walk straight out from one side before hitting something."""
    (ax, ay), (bx, by) = side_edge(item, side)
    nx, ny = side_normals(item)[side]
    polys = [other.corners for other in others if other is not item]
    worst = limit
    for index in range(samples):
        t = (index + 0.5) / samples
        px, py = ax + (bx - ax) * t, ay + (by - ay) * t
        distance = limit
        steps = int(limit / RAY_STEP)
        for step in range(1, steps + 1):
            reach = step * RAY_STEP
            qx, qy = px + nx * reach, py + ny * reach
            if not (0.0 <= qx <= room.width and 0.0 <= qy <= room.depth):
                distance = reach - RAY_STEP
                break
            if any(point_in_polygon((qx, qy), poly) for poly in polys):
                distance = reach - RAY_STEP
                break
        worst = min(worst, distance)
    return worst


def wall_gaps(item: Item, room: Room) -> dict[str, float]:
    xs = [p[0] for p in item.corners]
    ys = [p[1] for p in item.corners]
    return {"west": min(xs), "east": room.width - max(xs),
            "north": min(ys), "south": room.depth - max(ys)}


def swing_polygon(opening, room: Room, segments: int = 12) -> list[tuple[float, float]]:
    """Quarter disc swept by a door leaf, as a polygon."""
    hinge = opening.hinge_point(room.width, room.depth)
    start, end = opening.endpoints(room.width, room.depth)
    other = end if opening.hinge == "start" else start
    length = opening.width
    along = ((other[0] - hinge[0]) / length, (other[1] - hinge[1]) / length)
    inward = opening.inward()
    sign = 1.0 if opening.swing == "in" else -1.0
    points = [hinge]
    for index in range(segments + 1):
        angle = (math.pi / 2) * index / segments
        dx = along[0] * math.cos(angle) + inward[0] * sign * math.sin(angle)
        dy = along[1] * math.cos(angle) + inward[1] * sign * math.sin(angle)
        points.append((hinge[0] + dx * length, hinge[1] + dy * length))
    return points


def polygon_area(points: list[tuple[float, float]]) -> float:
    total = 0.0
    for i, (x1, y1) in enumerate(points):
        x2, y2 = points[(i + 1) % len(points)]
        total += x1 * y2 - x2 * y1
    return abs(total) / 2.0


# --------------------------------------------------------------------------- #
# checks
# --------------------------------------------------------------------------- #
def check_bounds(room: Room, report: Report) -> None:
    for item in room.items:
        xs = [p[0] for p in item.corners]
        ys = [p[1] for p in item.corners]
        over = max(-min(xs), max(xs) - room.width, -min(ys), max(ys) - room.depth)
        if over > 1.0:
            report.add("error", "bounds",
                       f"{item.name} sticks {over:.0f} mm outside the room",
                       items=[item.name], measured=round(over, 1))


def check_overlaps(room: Room, report: Report) -> None:
    items = solid(room)
    for i, first in enumerate(items):
        for second in items[i + 1:]:
            if polygons_overlap(first.corners, second.corners, tolerance=1.0):
                report.add("error", "overlap",
                           f"{first.name} and {second.name} occupy the same floor",
                           items=[first.name, second.name])


def check_door_swings(room: Room, report: Report) -> None:
    for opening in room.openings:
        if opening.kind != "door" or opening.swing not in ("in", "out"):
            continue
        if opening.swing == "out":
            continue  # nothing inside the room to hit
        arc = swing_polygon(opening, room)
        label = opening.name or f"{opening.wall} door"
        for item in solid(room):
            if polygons_overlap(arc, item.corners, tolerance=10.0):
                report.add("error", "door-swing",
                           f"{item.name} is inside the swing of the {label}",
                           items=[item.name], opening=label)


def check_window_blocking(room: Room, report: Report) -> None:
    for opening in room.openings:
        if opening.kind != "window":
            continue
        start, end = opening.endpoints(room.width, room.depth)
        inward = opening.inward()
        depth = 400.0
        zone = [start, end,
                (end[0] + inward[0] * depth, end[1] + inward[1] * depth),
                (start[0] + inward[0] * depth, start[1] + inward[1] * depth)]
        label = opening.name or f"{opening.wall} window"
        for item in solid(room):
            if item.height is None:
                continue
            if item.height <= opening.sill + 50:
                continue
            if polygons_overlap(zone, item.corners, tolerance=10.0):
                report.add("warning", "window",
                           f"{item.name} ({item.height:.0f} mm tall) stands in front of the "
                           f"{label} (sill at {opening.sill:.0f} mm)",
                           items=[item.name], opening=label)


def check_circulation(room: Room, report: Report, values: dict) -> dict:
    grid = Grid(room, cell=50.0, obstacles=solid(room))
    clearance = grid.clearance_map()
    primary = float(values["primary_walkway"])
    doors = [o for o in room.openings if o.kind in ("door", "opening")]

    starts: list[tuple[tuple[int, int], str]] = []
    for opening in doors:
        start, end = opening.endpoints(room.width, room.depth)
        inward = opening.inward()
        mid = ((start[0] + end[0]) / 2.0, (start[1] + end[1]) / 2.0)
        step = primary / 2.0 + 60.0
        cell = grid.index(mid[0] + inward[0] * step, mid[1] + inward[1] * step)
        starts.append((cell, opening.name or f"{opening.wall} {opening.kind}"))

    stats = {"reachable_m2": 0.0, "doors": len(doors)}
    if not starts:
        report.add("note", "circulation",
                   "no doors in the layout, so circulation was not checked")
        return stats

    (first_cell, first_label) = starts[0]
    if clearance[first_cell[1]][first_cell[0]] < primary / 2.0:
        report.add("error", "circulation",
                   f"there is not {primary:.0f} mm of clear floor just inside the "
                   f"{first_label}", opening=first_label, required=primary)
        return stats

    seen = grid.reachable([first_cell], primary, clearance)
    reachable_cells = sum(row.count(True) for row in seen)
    stats["reachable_m2"] = reachable_cells * grid.cell ** 2 / 1_000_000.0

    for cell, label in starts[1:]:
        if not seen[cell[1]][cell[0]]:
            report.add("error", "circulation",
                       f"you cannot get from the {first_label} to the {label} without "
                       f"squeezing below {primary:.0f} mm",
                       opening=label, required=primary)

    approach = float(values["approach"])
    for item in solid(room):
        if item.kind in ACCESSORY or item.footprint_mm2 < 250_000:
            continue  # reached from the piece it sits beside, not from a walkway
        if _reachable_within(item, grid, seen, approach):
            continue
        report.add("warning", "access",
                   f"{item.name} is more than {approach:.0f} mm from any "
                   f"{primary:.0f} mm walkway",
                   items=[item.name], required=approach)
    return stats


def _reachable_within(item: Item, grid: Grid, seen: list[list[bool]], approach: float) -> bool:
    xs = [p[0] for p in item.corners]
    ys = [p[1] for p in item.corners]
    x0, y0 = grid.index(min(xs) - approach, min(ys) - approach)
    x1, y1 = grid.index(max(xs) + approach, max(ys) + approach)
    poly = item.corners
    for iy in range(y0, y1 + 1):
        for ix in range(x0, x1 + 1):
            if not seen[iy][ix]:
                continue
            cx, cy = grid.centre(ix, iy)
            if point_polygon_distance((cx, cy), poly) <= approach:
                return True
    return False


def check_seating(room: Room, report: Report, values: dict) -> None:
    seats = [i for i in room.items if i.kind in SEATING]
    tables = [i for i in room.items if i.kind in LOW_TABLES]
    low, high = float(values["sofa_to_table_min"]), float(values["sofa_to_table_max"])
    for table in tables:
        if not seats:
            continue
        nearest = min(seats, key=lambda s: polygon_distance(s.corners, table.corners))
        gap = polygon_distance(nearest.corners, table.corners)
        if gap > 1200:
            continue  # not part of this seating group
        if gap < low:
            report.add("warning", "reach",
                       f"{gap:.0f} mm between {nearest.name} and {table.name}; "
                       f"below {low:.0f} mm there is nowhere to put your legs",
                       items=[nearest.name, table.name], measured=round(gap), required=low)
        elif gap > high:
            report.add("note", "reach",
                       f"{gap:.0f} mm between {nearest.name} and {table.name}; "
                       f"over {high:.0f} mm you have to stand up to reach it",
                       items=[nearest.name, table.name], measured=round(gap), required=high)


def check_screens(room: Room, report: Report, values: dict) -> None:
    seats = [i for i in room.items if i.kind in SEATING]
    for screen in [i for i in room.items if i.kind in SCREENS]:
        if not seats or not screen.diagonal:
            if screen.diagonal is None and screen.kind in SCREENS:
                report.add("note", "viewing",
                           f"add a \"diagonal\" to {screen.name} to check viewing distance",
                           items=[screen.name])
            continue
        nearest = min(seats, key=lambda s: polygon_distance(s.corners, screen.corners))
        gap = polygon_distance(nearest.corners, screen.corners)
        low = screen.diagonal * float(values["tv_distance_factor_min"])
        high = screen.diagonal * float(values["tv_distance_factor_max"])
        if gap < low:
            report.add("warning", "viewing",
                       f"{nearest.name} sits {gap:.0f} mm from {screen.name}; a "
                       f"{screen.diagonal:.0f} mm screen wants at least {low:.0f} mm",
                       items=[nearest.name, screen.name], measured=round(gap), required=round(low))
        elif gap > high:
            report.add("note", "viewing",
                       f"{nearest.name} sits {gap:.0f} mm from {screen.name}; over "
                       f"{high:.0f} mm the picture starts to feel small",
                       items=[nearest.name, screen.name], measured=round(gap), required=round(high))


def check_beds(room: Room, report: Report, values: dict) -> None:
    others = solid(room)
    side_min = float(values["bed_side"])
    foot_min = float(values["bed_foot"])
    against = float(values["against_wall"])
    for bed in [i for i in room.items if i.kind == "bed"]:
        # a nightstand belongs beside a bed; it is not what blocks the bedside gap
        beside = [o for o in others if o.kind not in BEDSIDE]
        gaps = {side: side_clearance(bed, side, room, beside) for side in
                ("front", "back", "left", "right")}
        # a bed's head is its "back"; you get in from the sides and the foot
        sides = [gaps["left"], gaps["right"]]
        free_sides = [g for g in sides if g >= side_min]
        double = bed.w >= 1300
        if double and len(free_sides) < 2:
            tight = min(sides)
            report.add("warning", "bed",
                       f"{bed.name} is a double but only has {tight:.0f} mm on one side; "
                       f"allow {side_min:.0f} mm to both sides so nobody climbs over",
                       items=[bed.name], measured=round(tight), required=side_min)
        elif not double and not free_sides:
            report.add("warning", "bed",
                       f"{bed.name} has under {side_min:.0f} mm on both sides",
                       items=[bed.name], measured=round(min(sides)), required=side_min)
        if gaps["front"] < foot_min and gaps["front"] > against:
            report.add("note", "bed",
                       f"{gaps['front']:.0f} mm at the foot of {bed.name}; "
                       f"{foot_min:.0f} mm walks past comfortably",
                       items=[bed.name], measured=round(gaps["front"]), required=foot_min)


def check_fronts(room: Room, report: Report, values: dict) -> None:
    others = solid(room)
    for item in solid(room):
        key = FRONTED.get(item.kind)
        if not key:
            continue
        required = float(values[key])
        gap = side_clearance(item, "front", room, others)
        if gap < required:
            report.add("warning", "front-clearance",
                       f"{gap:.0f} mm in front of {item.name}; it needs {required:.0f} mm "
                       f"to open and stand at",
                       items=[item.name], measured=round(gap), required=required)


def check_dining(room: Room, report: Report, values: dict) -> None:
    others = solid(room)
    required = float(values["dining_pullout"])
    for table in [i for i in room.items if i.kind in ("dining_table", "desk")]:
        seat_kinds = {"chair", "bench", "stool"}
        seats = [i for i in room.items if i.kind in seat_kinds
                 and polygon_distance(i.corners, table.corners) < 900]
        ignore = set(id(s) for s in seats)
        neighbours = [o for o in others if id(o) not in ignore]
        tight = {side: side_clearance(table, side, room, neighbours)
                 for side in ("front", "back", "left", "right")}
        blocked = {side: gap for side, gap in tight.items() if gap < required}
        if len(blocked) == 4:
            worst = min(blocked.values())
            report.add("warning", "dining",
                       f"{table.name} has under {required:.0f} mm on every side "
                       f"(tightest {worst:.0f} mm); chairs cannot be pulled out",
                       items=[table.name], measured=round(worst), required=required)
        elif blocked:
            sides = ", ".join(sorted(blocked))
            report.add("note", "dining",
                       f"{table.name} is tight on its {sides} side(s); those seats will be "
                       f"hard to get into",
                       items=[table.name], required=required)


def summarise(room: Room, stats: dict) -> dict:
    footprint = sum(i.footprint_mm2 for i in solid(room)) / 1_000_000.0
    return {
        "room": room.name,
        "area_m2": round(room.area_m2, 2),
        "furniture_m2": round(footprint, 2),
        "furniture_ratio": round(footprint / room.area_m2, 3) if room.area_m2 else 0.0,
        "walkway_m2": round(stats.get("reachable_m2", 0.0), 2),
        "items": len(room.items),
        "openings": len(room.openings),
    }


def analyse(room: Room) -> tuple[Report, dict]:
    report = Report()
    values = limits(room)
    check_bounds(room, report)
    check_overlaps(room, report)
    check_door_swings(room, report)
    check_window_blocking(room, report)
    stats = check_circulation(room, report, values)
    check_seating(room, report, values)
    check_screens(room, report, values)
    check_beds(room, report, values)
    check_fronts(room, report, values)
    check_dining(room, report, values)
    summary = summarise(room, stats)
    ratio = summary["furniture_ratio"]
    if ratio > 0.55:
        report.add("note", "density",
                   f"furniture covers {ratio * 100:.0f}% of the floor; over ~50% a room "
                   f"reads as crowded")
    elif ratio and ratio < 0.20:
        report.add("note", "density",
                   f"furniture covers only {ratio * 100:.0f}% of the floor; the room may "
                   f"feel unfurnished")
    return report, summary


ICONS = {"error": "✗", "warning": "!", "note": "·"}


def format_text(report: Report, summary: dict) -> str:
    lines = [f"{summary['room']} — {summary['area_m2']:.1f} m², {summary['items']} items",
             f"  furniture {summary['furniture_m2']:.1f} m² "
             f"({summary['furniture_ratio'] * 100:.0f}% of floor) · "
             f"walkway network {summary['walkway_m2']:.1f} m²", ""]
    if not report.findings:
        lines.append("✓ no clearance problems found")
        return "\n".join(lines)
    order = {"error": 0, "warning": 1, "note": 2}
    for finding in sorted(report.findings, key=lambda f: order.get(f["severity"], 3)):
        lines.append(f"{ICONS.get(finding['severity'], '-')} [{finding['rule']}] "
                     f"{finding['message']}")
    counts = report.counts()
    lines += ["", f"{counts['error']} error(s), {counts['warning']} warning(s), "
                  f"{counts['note']} note(s)"]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Check a layout for clearance problems.")
    parser.add_argument("layout", help="path to the layout JSON file")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--strict", action="store_true", help="warnings fail as well as errors")
    args = parser.parse_args(argv)

    try:
        room = load(args.layout)
    except (SpecError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    report, summary = analyse(room)
    if args.json:
        print(json.dumps({"summary": summary, "findings": report.findings,
                          "limits": limits(room)}, indent=2))
    else:
        print(format_text(report, summary))

    counts = report.counts()
    if counts["error"] or (args.strict and counts["warning"]):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
