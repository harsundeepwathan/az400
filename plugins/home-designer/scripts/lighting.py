#!/usr/bin/env python3
"""Size the lighting for a room and split it into layers.

    python3 lighting.py --area 20.8 --type living
    python3 lighting.py --layout examples/living-room.json --type living
    python3 lighting.py --area 12 --type bedroom --json

The lumen figure is a design estimate, not a photometric calculation: it takes
the target illuminance for the room's use, multiplies by floor area, and divides
by a utilisation factor (how much of a lamp's output reaches the working plane)
and a maintenance factor (dirt and lamp ageing). Reflective, light rooms land at
the optimistic end; dark walls and a high ceiling at the other.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# target illuminance (lux) on the working plane, and the CCT people expect
ROOM_TYPES = {
    "living":   {"ambient": 150, "task": 300, "cct": "2700 K", "cri": 90},
    "bedroom":  {"ambient": 100, "task": 300, "cct": "2700 K", "cri": 90},
    "kitchen":  {"ambient": 300, "task": 500, "cct": "3000 K", "cri": 90},
    "dining":   {"ambient": 150, "task": 300, "cct": "2700 K", "cri": 90},
    "bathroom": {"ambient": 200, "task": 500, "cct": "3000 K", "cri": 90},
    "office":   {"ambient": 300, "task": 500, "cct": "3500 K", "cri": 90},
    "hallway":  {"ambient": 100, "task": 150, "cct": "2700 K", "cri": 80},
    "utility":  {"ambient": 200, "task": 400, "cct": "4000 K", "cri": 80},
}

# how much of the emitted light reaches the working plane, by wall lightness
UTILISATION = {"light": 0.55, "mid": 0.45, "dark": 0.35}
MAINTENANCE = 0.8

LAYERS = (
    ("ambient", 0.55, "Overall wash — pendant, semi-flush or perimeter downlights on one dimmer"),
    ("task", 0.30, "Where you read, cook, work or make up — aimed, switched separately"),
    ("accent", 0.15, "Art, shelves, plants — the layer that stops a room looking flat"),
)

FIXTURE_LUMENS = {"pendant": 800, "downlight": 650, "table lamp": 400,
                  "floor lamp": 700, "strip (per m)": 500}


def plan(area_m2: float, room_type: str, walls: str = "mid",
         ceiling_m: float = 2.4, mode: str = "ambient") -> dict:
    if room_type not in ROOM_TYPES:
        raise ValueError(f"unknown room type {room_type!r}; "
                         f"try {', '.join(sorted(ROOM_TYPES))}")
    if walls not in UTILISATION:
        raise ValueError(f"walls must be one of {', '.join(sorted(UTILISATION))}")
    profile = ROOM_TYPES[room_type]
    lux = profile[mode] if mode in ("ambient", "task") else profile["ambient"]
    utilisation = UTILISATION[walls]
    if ceiling_m > 2.7:  # light spreads further from the plane, so less arrives
        utilisation *= 0.9
    total = area_m2 * lux / (utilisation * MAINTENANCE)

    layers = []
    for name, share, note in LAYERS:
        lumens = total * share
        layers.append({"layer": name, "share": share, "lumens": int(round(lumens / 50) * 50),
                       "note": note})
    return {
        "room_type": room_type,
        "area_m2": round(area_m2, 2),
        "target_lux": lux,
        "walls": walls,
        "utilisation": round(utilisation, 2),
        "maintenance": MAINTENANCE,
        "total_lumens": int(round(total / 50) * 50),
        "lumens_per_m2": int(round(total / area_m2)) if area_m2 else 0,
        "cct": profile["cct"],
        "min_cri": profile["cri"],
        "layers": layers,
        "circuits": max(2, min(4, 2 + int(area_m2 // 15))),
    }


def fixture_options(lumens: int) -> list[str]:
    out = []
    for name, output in FIXTURE_LUMENS.items():
        count = max(1, round(lumens / output))
        out.append(f"{count} × {name} at ~{output} lm")
    return out


def format_text(result: dict) -> str:
    lines = [
        f"{result['room_type'].title()} — {result['area_m2']:.1f} m², "
        f"target {result['target_lux']} lux, {result['walls']} walls",
        f"  {result['total_lumens']} lm total "
        f"({result['lumens_per_m2']} lm/m², utilisation {result['utilisation']}, "
        f"maintenance {result['maintenance']})",
        f"  {result['cct']} colour temperature, CRI {result['min_cri']}+, "
        f"{result['circuits']} switched circuits, all dimmable",
        "",
    ]
    for layer in result["layers"]:
        lines.append(f"  {layer['layer']:<8} {layer['lumens']:>6} lm  ({layer['share'] * 100:.0f}%)"
                     f"  {layer['note']}")
    ambient = next(layer for layer in result["layers"] if layer["layer"] == "ambient")
    lines += ["", "  ambient could be: " + " · ".join(fixture_options(ambient["lumens"])), "",
              "  Rules of thumb: at least three separate light sources per room; nothing on a "
              "single ceiling switch;",
              "  warm dimming for evening rooms; put task light between your head and the work, "
              "never behind you."]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Size and layer a room's lighting.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--area", type=float, help="floor area in m²")
    source.add_argument("--layout", help="layout JSON file to take the area from")
    parser.add_argument("--type", dest="room_type", default="living",
                        choices=sorted(ROOM_TYPES), help="what the room is used for")
    parser.add_argument("--walls", default="mid", choices=sorted(UTILISATION),
                        help="how light the surfaces are (light/mid/dark)")
    parser.add_argument("--ceiling", type=float, default=2.4, help="ceiling height in metres")
    parser.add_argument("--task", action="store_true",
                        help="size for the task illuminance instead of ambient")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args(argv)

    area = args.area
    ceiling = args.ceiling
    if args.layout:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from roomspec import SpecError, load  # noqa: PLC0415
        try:
            room = load(args.layout)
        except (SpecError, OSError) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        area = room.area_m2
        ceiling = room.height / 1000.0

    try:
        result = plan(area, args.room_type, args.walls, ceiling,
                      "task" if args.task else "ambient")
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    print(json.dumps(result, indent=2) if args.json else format_text(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
