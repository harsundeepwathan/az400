"""Room specification loading, geometry and occupancy helpers.

Shared by floorplan.py (drawing) and clearances.py (checking) so both read a
layout exactly the same way.

Conventions
-----------
* All internal lengths are millimetres.
* Origin is the inside top-left corner of the room. ``x`` grows east (right),
  ``y`` grows south (down). A plan is therefore drawn "north up".
* ``x``/``y`` of an item is the CENTRE of its footprint, and ``rotation`` is
  degrees clockwise about that centre. Centre coordinates keep rotation
  unambiguous.
* An item may be ``mounted`` (wall-hung): it is drawn, but it does not occupy
  floor space, so it is skipped by the overlap, obstacle and clearance checks.
* Walls are named ``north`` (y=0), ``south`` (y=depth), ``west`` (x=0) and
  ``east`` (x=width). An opening's ``offset`` is measured from the west end of
  a north/south wall, or from the north end of an east/west wall.
"""

from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass, field
from typing import Iterable, Sequence

UNIT_TO_MM = {"mm": 1.0, "cm": 10.0, "m": 1000.0, "in": 25.4, "ft": 304.8}
WALLS = ("north", "east", "south", "west")


class SpecError(ValueError):
    """Raised when a layout file is malformed."""


Point = tuple[float, float]


# --------------------------------------------------------------------------- #
# geometry
# --------------------------------------------------------------------------- #
def rect_corners(cx: float, cy: float, w: float, d: float, rotation: float = 0.0) -> list[Point]:
    """Corners of a rectangle centred on (cx, cy), rotated clockwise."""
    a = math.radians(rotation)
    cos_a, sin_a = math.cos(a), math.sin(a)
    hw, hd = w / 2.0, d / 2.0
    out = []
    for ox, oy in ((-hw, -hd), (hw, -hd), (hw, hd), (-hw, hd)):
        # clockwise rotation in a y-down coordinate system
        out.append((cx + ox * cos_a - oy * sin_a, cy + ox * sin_a + oy * cos_a))
    return out


def _axes(poly: Sequence[Point]) -> list[Point]:
    axes = []
    for i, (x1, y1) in enumerate(poly):
        x2, y2 = poly[(i + 1) % len(poly)]
        ex, ey = x2 - x1, y2 - y1
        length = math.hypot(ex, ey)
        if length > 1e-9:
            axes.append((-ey / length, ex / length))
    return axes


def _project(poly: Sequence[Point], axis: Point) -> tuple[float, float]:
    dots = [px * axis[0] + py * axis[1] for px, py in poly]
    return min(dots), max(dots)


def polygons_overlap(a: Sequence[Point], b: Sequence[Point], tolerance: float = 1.0) -> bool:
    """Separating-axis test for two convex polygons.

    ``tolerance`` (mm) lets footprints touch without counting as an overlap.
    """
    for axis in _axes(a) + _axes(b):
        a_min, a_max = _project(a, axis)
        b_min, b_max = _project(b, axis)
        if a_max - tolerance <= b_min or b_max - tolerance <= a_min:
            return False
    return True


def _point_segment_distance(p: Point, a: Point, b: Point) -> float:
    px, py = p
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    denom = dx * dx + dy * dy
    if denom < 1e-12:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / denom))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def _segments_intersect(p1: Point, p2: Point, p3: Point, p4: Point) -> bool:
    def cross(o: Point, a: Point, b: Point) -> float:
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    d1, d2 = cross(p3, p4, p1), cross(p3, p4, p2)
    d3, d4 = cross(p1, p2, p3), cross(p1, p2, p4)
    return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0))


def polygon_distance(a: Sequence[Point], b: Sequence[Point]) -> float:
    """Smallest gap between two convex polygons; 0.0 if they touch or overlap."""
    edges_a = [(a[i], a[(i + 1) % len(a)]) for i in range(len(a))]
    edges_b = [(b[i], b[(i + 1) % len(b)]) for i in range(len(b))]
    for s1, e1 in edges_a:
        for s2, e2 in edges_b:
            if _segments_intersect(s1, e1, s2, e2):
                return 0.0
    if polygons_overlap(a, b, tolerance=0.0):
        return 0.0
    best = math.inf
    for poly1, poly2 in ((a, b), (b, a)):
        edges = [(poly2[i], poly2[(i + 1) % len(poly2)]) for i in range(len(poly2))]
        for point in poly1:
            for seg_a, seg_b in edges:
                best = min(best, _point_segment_distance(point, seg_a, seg_b))
    return best


def point_in_polygon(p: Point, poly: Sequence[Point]) -> bool:
    x, y = p
    inside = False
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        if (y1 > y) != (y2 > y):
            x_at = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            if x_at > x:
                inside = not inside
    return inside


def point_polygon_distance(p: Point, poly: Sequence[Point]) -> float:
    """Distance from a point to a polygon; 0.0 if the point is inside."""
    if point_in_polygon(p, poly):
        return 0.0
    return min(
        _point_segment_distance(p, poly[i], poly[(i + 1) % len(poly)])
        for i in range(len(poly))
    )


# --------------------------------------------------------------------------- #
# model
# --------------------------------------------------------------------------- #
@dataclass
class Item:
    name: str
    kind: str
    x: float
    y: float
    w: float
    d: float
    rotation: float = 0.0
    height: float | None = None
    fixed: bool = False
    mounted: bool = False  # hung on the wall, so not an obstacle on the floor
    color: str | None = None
    diagonal: float | None = None  # screens, in mm
    notes: str = ""

    @property
    def corners(self) -> list[Point]:
        return rect_corners(self.x, self.y, self.w, self.d, self.rotation)

    @property
    def footprint_mm2(self) -> float:
        return self.w * self.d


@dataclass
class Opening:
    kind: str  # "door", "window", "opening"
    wall: str
    offset: float  # from the west/north end of that wall
    width: float
    hinge: str = "start"  # "start" | "end" -- which end of the opening pivots
    swing: str = "in"  # "in" | "out" | "none"
    sill: float = 0.0  # windows only
    head: float | None = None
    name: str = ""

    def endpoints(self, room_w: float, room_d: float) -> tuple[Point, Point]:
        if self.wall == "north":
            return (self.offset, 0.0), (self.offset + self.width, 0.0)
        if self.wall == "south":
            return (self.offset, room_d), (self.offset + self.width, room_d)
        if self.wall == "west":
            return (0.0, self.offset), (0.0, self.offset + self.width)
        if self.wall == "east":
            return (room_w, self.offset), (room_w, self.offset + self.width)
        raise SpecError(f"unknown wall {self.wall!r}")

    def inward(self) -> Point:
        return {"north": (0.0, 1.0), "south": (0.0, -1.0),
                "west": (1.0, 0.0), "east": (-1.0, 0.0)}[self.wall]

    def hinge_point(self, room_w: float, room_d: float) -> Point:
        start, end = self.endpoints(room_w, room_d)
        return start if self.hinge == "start" else end


@dataclass
class Room:
    name: str
    width: float
    depth: float
    height: float = 2400.0
    openings: list[Opening] = field(default_factory=list)
    items: list[Item] = field(default_factory=list)
    source: str = ""
    clearances: dict = field(default_factory=dict)

    @property
    def area_m2(self) -> float:
        return self.width * self.depth / 1_000_000.0

    @property
    def polygon(self) -> list[Point]:
        return [(0.0, 0.0), (self.width, 0.0), (self.width, self.depth), (0.0, self.depth)]

    def doors(self) -> list[Opening]:
        return [o for o in self.openings if o.kind in ("door", "opening")]


# --------------------------------------------------------------------------- #
# loading
# --------------------------------------------------------------------------- #
def _num(value, label: str, factor: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SpecError(f"{label} must be a number, got {value!r}")
    return float(value) * factor


def load(path: str) -> Room:
    """Read a layout JSON file and return a validated :class:`Room`."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except json.JSONDecodeError as exc:
        raise SpecError(f"{path}: invalid JSON ({exc})") from exc
    room = from_dict(data)
    room.source = os.path.abspath(path)
    return room


def from_dict(data: dict) -> Room:
    if not isinstance(data, dict):
        raise SpecError("layout must be a JSON object")
    units = data.get("units", "mm")
    if units not in UNIT_TO_MM:
        raise SpecError(f"unknown units {units!r}; use one of {sorted(UNIT_TO_MM)}")
    factor = UNIT_TO_MM[units]

    room_data = data.get("room")
    if not isinstance(room_data, dict):
        raise SpecError("layout needs a 'room' object with 'width' and 'depth'")
    width = _num(room_data.get("width"), "room.width", factor)
    depth = _num(room_data.get("depth"), "room.depth", factor)
    if width <= 0 or depth <= 0:
        raise SpecError("room width and depth must be positive")
    height = _num(room_data.get("height", 2400.0 / factor), "room.height", factor)

    room = Room(
        name=str(data.get("name") or room_data.get("name") or "Room"),
        width=width,
        depth=depth,
        height=height,
        clearances={k: float(v) * factor for k, v in (data.get("clearances") or {}).items()},
    )

    for index, raw in enumerate(data.get("openings") or []):
        room.openings.append(_opening(raw, index, factor, room))
    for index, raw in enumerate(data.get("furniture") or []):
        room.items.append(_item(raw, index, factor))
    return room


def _opening(raw: dict, index: int, factor: float, room: Room) -> Opening:
    label = f"openings[{index}]"
    if not isinstance(raw, dict):
        raise SpecError(f"{label} must be an object")
    wall = str(raw.get("wall", "")).lower()
    if wall not in WALLS:
        raise SpecError(f"{label}.wall must be one of {list(WALLS)}")
    kind = str(raw.get("type", "door")).lower()
    if kind not in ("door", "window", "opening"):
        raise SpecError(f"{label}.type must be door, window or opening")
    opening = Opening(
        kind=kind,
        wall=wall,
        offset=_num(raw.get("offset", 0), f"{label}.offset", factor),
        width=_num(raw.get("width", 900), f"{label}.width", factor),
        hinge=str(raw.get("hinge", "start")).lower(),
        swing=str(raw.get("swing", "in" if kind == "door" else "none")).lower(),
        sill=_num(raw.get("sill", 0), f"{label}.sill", factor),
        head=_num(raw["head"], f"{label}.head", factor) if "head" in raw else None,
        name=str(raw.get("name", "")),
    )
    if opening.hinge not in ("start", "end"):
        raise SpecError(f"{label}.hinge must be 'start' or 'end'")
    if opening.swing not in ("in", "out", "none"):
        raise SpecError(f"{label}.swing must be 'in', 'out' or 'none'")
    span = room.width if wall in ("north", "south") else room.depth
    if opening.width <= 0:
        raise SpecError(f"{label}.width must be positive")
    if opening.offset < -1e-6 or opening.offset + opening.width > span + 1e-6:
        raise SpecError(
            f"{label} runs off the {wall} wall "
            f"({opening.offset:.0f}+{opening.width:.0f}mm > {span:.0f}mm)"
        )
    return opening


def _item(raw: dict, index: int, factor: float) -> Item:
    label = f"furniture[{index}]"
    if not isinstance(raw, dict):
        raise SpecError(f"{label} must be an object")
    for key in ("x", "y"):
        if key not in raw:
            raise SpecError(f"{label} needs '{key}' (centre of the footprint)")
    width = _num(raw.get("width", raw.get("w")), f"{label}.width", factor)
    depth = _num(raw.get("depth", raw.get("d")), f"{label}.depth", factor)
    if width <= 0 or depth <= 0:
        raise SpecError(f"{label} width and depth must be positive")
    return Item(
        name=str(raw.get("name") or raw.get("type") or f"item {index + 1}"),
        kind=str(raw.get("type", "furniture")).lower().replace("-", "_").replace(" ", "_"),
        x=_num(raw["x"], f"{label}.x", factor),
        y=_num(raw["y"], f"{label}.y", factor),
        w=width,
        d=depth,
        rotation=float(raw.get("rotation", 0) or 0),
        height=_num(raw["height"], f"{label}.height", factor) if "height" in raw else None,
        fixed=bool(raw.get("fixed", False)),
        mounted=bool(raw.get("mounted", False)),
        color=raw.get("color"),
        diagonal=_num(raw["diagonal"], f"{label}.diagonal", factor) if "diagonal" in raw else None,
        notes=str(raw.get("notes", "")),
    )


# --------------------------------------------------------------------------- #
# occupancy grid
# --------------------------------------------------------------------------- #
class Grid:
    """Boolean occupancy raster over the room, used for circulation checks."""

    def __init__(self, room: Room, cell: float = 50.0, obstacles: Iterable[Item] | None = None):
        self.cell = float(cell)
        self.room = room
        self.nx = max(1, int(math.ceil(room.width / self.cell)))
        self.ny = max(1, int(math.ceil(room.depth / self.cell)))
        self.blocked = [[False] * self.nx for _ in range(self.ny)]
        items = room.items if obstacles is None else list(obstacles)
        for item in items:
            self._stamp(item.corners)

    def centre(self, ix: int, iy: int) -> Point:
        return ((ix + 0.5) * self.cell, (iy + 0.5) * self.cell)

    def index(self, x: float, y: float) -> tuple[int, int]:
        return (
            min(self.nx - 1, max(0, int(x // self.cell))),
            min(self.ny - 1, max(0, int(y // self.cell))),
        )

    def _stamp(self, poly: Sequence[Point]) -> None:
        xs = [p[0] for p in poly]
        ys = [p[1] for p in poly]
        x0, _ = self.index(min(xs), 0)
        x1, _ = self.index(max(xs), 0)
        _, y0 = self.index(0, min(ys))
        _, y1 = self.index(0, max(ys))
        for iy in range(y0, y1 + 1):
            for ix in range(x0, x1 + 1):
                if not self.blocked[iy][ix] and point_in_polygon(self.centre(ix, iy), poly):
                    self.blocked[iy][ix] = True

    def clearance_map(self) -> list[list[float]]:
        """Chebyshev distance (mm) from every free cell to the nearest blocked
        cell or wall, via the usual two-pass transform."""
        big = float(self.nx + self.ny + 2)
        dist = [
            [0.0 if self.blocked[iy][ix] else big for ix in range(self.nx)]
            for iy in range(self.ny)
        ]
        for iy in range(self.ny):
            for ix in range(self.nx):
                if dist[iy][ix] == 0.0:
                    continue
                best = min(iy + 1.0, ix + 1.0)  # walls behave like blocked cells
                for dy, dx in ((-1, -1), (-1, 0), (-1, 1), (0, -1)):
                    ny_, nx_ = iy + dy, ix + dx
                    if 0 <= ny_ < self.ny and 0 <= nx_ < self.nx:
                        best = min(best, dist[ny_][nx_] + 1.0)
                dist[iy][ix] = best
        for iy in range(self.ny - 1, -1, -1):
            for ix in range(self.nx - 1, -1, -1):
                if dist[iy][ix] == 0.0:
                    continue
                best = min(dist[iy][ix], float(self.ny - iy), float(self.nx - ix))
                for dy, dx in ((1, 1), (1, 0), (1, -1), (0, 1)):
                    ny_, nx_ = iy + dy, ix + dx
                    if 0 <= ny_ < self.ny and 0 <= nx_ < self.nx:
                        best = min(best, dist[ny_][nx_] + 1.0)
                dist[iy][ix] = best
        return [[value * self.cell for value in row] for row in dist]

    def reachable(self, starts: Iterable[tuple[int, int]], min_clearance: float,
                  clearance: list[list[float]] | None = None) -> list[list[bool]]:
        """Cells reachable from ``starts`` while keeping ``min_clearance`` mm of
        free width on every side (a square-footprint erosion)."""
        clearance = clearance or self.clearance_map()
        half = min_clearance / 2.0
        seen = [[False] * self.nx for _ in range(self.ny)]
        queue: list[tuple[int, int]] = []
        for ix, iy in starts:
            if 0 <= ix < self.nx and 0 <= iy < self.ny and not seen[iy][ix] \
                    and clearance[iy][ix] >= half:
                seen[iy][ix] = True
                queue.append((ix, iy))
        while queue:
            ix, iy = queue.pop()
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx_, ny_ = ix + dx, iy + dy
                if 0 <= nx_ < self.nx and 0 <= ny_ < self.ny and not seen[ny_][nx_] \
                        and clearance[ny_][nx_] >= half:
                    seen[ny_][nx_] = True
                    queue.append((nx_, ny_))
        return seen
