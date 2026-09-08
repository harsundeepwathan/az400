#!/usr/bin/env python3
"""Build a room colour scheme from one base colour and print or draw it.

    python3 palette.py "#3E5C50" --scheme analogous --name "Living room"
    python3 palette.py "#3E5C50" -o palette.svg
    python3 palette.py "#3E5C50" --json

Every swatch carries an LRV (light reflectance value, 0-100) because that, more
than hue, decides how bright a room feels: walls under about LRV 50 eat
daylight, and a ceiling wants to be the lightest surface in the room.
"""

from __future__ import annotations

import argparse
import colorsys
import json
import sys
from xml.sax.saxutils import escape

# Hue offsets in degrees from the base, indexed by the role's hue slot below.
# Slot 0 is always the base hue: walls and ceiling stay on it, and the scheme
# decides how far the supporting colour, the accent and the anchor travel.
SCHEMES = {
    "monochrome": [0, 0, 0, 0],
    "analogous": [0, -25, 25, -12],
    "complementary": [0, 0, 180, 172],
    "split-complementary": [0, -18, 150, 210],
    "triadic": [0, 0, 120, 240],
    "neutral": [0, 6, -8, 3],
}

# role: (share of the room, hue index, saturation multiplier, target LRV)
ROLES = [
    ("ceiling", "Ceiling & trim", 0.0, 0, 0.10, 88),
    ("dominant", "Walls (60%)", 0.60, 0, 0.30, 68),
    ("secondary", "Upholstery & cabinetry (30%)", 0.30, 1, 0.55, 38),
    ("accent", "Accent (10%)", 0.10, 2, 1.35, 32),
    ("anchor", "Anchor / contrast", 0.0, 3, 0.45, 12),
]


def hex_to_rgb(value: str) -> tuple[float, float, float]:
    text = value.strip().lstrip("#")
    if len(text) == 3:
        text = "".join(ch * 2 for ch in text)
    if len(text) != 6 or any(ch not in "0123456789abcdefABCDEF" for ch in text):
        raise ValueError(f"{value!r} is not a hex colour like #3E5C50")
    return tuple(int(text[i:i + 2], 16) / 255.0 for i in (0, 2, 4))  # type: ignore[return-value]


def rgb_to_hex(rgb: tuple[float, float, float]) -> str:
    return "#" + "".join(f"{max(0, min(255, round(channel * 255))):02X}" for channel in rgb)


def relative_luminance(rgb: tuple[float, float, float]) -> float:
    def channel(value: float) -> float:
        return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4
    r, g, b = (channel(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def lrv(rgb: tuple[float, float, float]) -> float:
    """Light reflectance value as the paint trade quotes it, 0-100."""
    return relative_luminance(rgb) * 100.0


def contrast_ratio(a: tuple[float, float, float], b: tuple[float, float, float]) -> float:
    la, lb = relative_luminance(a), relative_luminance(b)
    lighter, darker = max(la, lb), min(la, lb)
    return (lighter + 0.05) / (darker + 0.05)


def with_lrv(hue: float, saturation: float, target_lrv: float) -> tuple[float, float, float]:
    """Pick the lightness that lands closest to a target LRV for this hue."""
    best, best_error = None, None
    low, high = 0.0, 1.0
    for _ in range(40):
        mid = (low + high) / 2.0
        rgb = colorsys.hls_to_rgb(hue, mid, saturation)
        value = lrv(rgb)
        error = abs(value - target_lrv)
        if best_error is None or error < best_error:
            best, best_error = rgb, error
        if value < target_lrv:
            low = mid
        else:
            high = mid
    return best  # type: ignore[return-value]


def build(base_hex: str, scheme: str = "analogous", warmth: float = 0.0) -> list[dict]:
    if scheme not in SCHEMES:
        raise ValueError(f"unknown scheme {scheme!r}; try {', '.join(sorted(SCHEMES))}")
    base_rgb = hex_to_rgb(base_hex)
    hue, _, saturation = colorsys.rgb_to_hls(*base_rgb)
    saturation = max(0.08, min(0.9, saturation))
    offsets = SCHEMES[scheme]

    swatches = []
    for key, label, share, hue_index, sat_mul, target in ROLES:
        shifted = (hue + offsets[hue_index] / 360.0 + warmth / 360.0) % 1.0
        rgb = with_lrv(shifted, max(0.02, min(0.95, saturation * sat_mul)), target)
        white_contrast = contrast_ratio(rgb, (1.0, 1.0, 1.0))
        black_contrast = contrast_ratio(rgb, (0.0, 0.0, 0.0))
        swatches.append({
            "role": key,
            "label": label,
            "share": share,
            "hex": rgb_to_hex(rgb),
            "lrv": round(lrv(rgb), 1),
            "contrast_on_white": round(white_contrast, 2),
            "contrast_on_black": round(black_contrast, 2),
            "readable_text": "#FFFFFF" if white_contrast >= black_contrast else "#111111",
        })
    return swatches


def advice(swatches: list[dict]) -> list[str]:
    by_role = {s["role"]: s for s in swatches}
    notes = []
    walls = by_role["dominant"]
    ceiling = by_role["ceiling"]
    if walls["lrv"] < 45:
        notes.append(f"Walls at LRV {walls['lrv']:.0f} will absorb a lot of daylight — good for a "
                     f"snug room, but plan on more lumens and keep the ceiling much lighter.")
    if ceiling["lrv"] - walls["lrv"] < 10:
        notes.append("Lift the ceiling colour: it should be the lightest surface so the room does "
                     "not feel low.")
    accent = by_role["accent"]
    if accent["contrast_on_white"] < 3.0 and accent["contrast_on_black"] < 3.0:
        notes.append("The accent is mid-toned against everything; use it on shape (a chair, a "
                     "frame) rather than on lettering or fine detail.")
    notes.append("Hold the 60/30/10 split: one dominant surface colour, one supporting colour on "
                 "the big soft pieces, one accent repeated at least three times around the room.")
    notes.append("Check every colour on a sample board in the actual room, in daylight and under "
                 "the evening lamps, before buying paint.")
    return notes


def render_svg(swatches: list[dict], title: str) -> str:
    swatch_w, swatch_h, gap, pad = 200, 240, 16, 40
    width = pad * 2 + len(swatches) * swatch_w + (len(swatches) - 1) * gap
    height = pad * 2 + swatch_h + 80
    parts = [f'<rect x="0" y="0" width="{width}" height="{height}" fill="#fbfaf7"/>',
             f'<text class="h" x="{pad}" y="{pad + 6}">{escape(title)}</text>']
    for index, swatch in enumerate(swatches):
        x = pad + index * (swatch_w + gap)
        y = pad + 34
        parts.append(f'<rect x="{x}" y="{y}" width="{swatch_w}" height="{swatch_h}" '
                     f'fill="{swatch["hex"]}" rx="6"/>')
        parts.append(f'<text class="chip" x="{x + 14}" y="{y + swatch_h - 44}" '
                     f'fill="{swatch["readable_text"]}">{swatch["hex"]}</text>')
        parts.append(f'<text class="chip small" x="{x + 14}" y="{y + swatch_h - 22}" '
                     f'fill="{swatch["readable_text"]}">LRV {swatch["lrv"]:.0f}</text>')
        parts.append(f'<text class="cap" x="{x}" y="{y + swatch_h + 24}">'
                     f'{escape(swatch["label"])}</text>')
    style = ("text{font-family:'Helvetica Neue',Helvetica,Arial,sans-serif}"
             ".h{font-size:20px;font-weight:700;fill:#2f3337}"
             ".chip{font-size:16px;font-weight:600}"
             ".small{font-size:13px;font-weight:400;opacity:.85}"
             ".cap{font-size:12px;fill:#5c646c}")
    body = "\n  ".join(parts)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}" role="img" aria-label="{escape(title)} palette">\n'
            f"  <style>{style}</style>\n  {body}\n</svg>\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build a room colour scheme from a base colour.")
    parser.add_argument("base", help="base colour as hex, e.g. #3E5C50")
    parser.add_argument("--scheme", default="analogous", choices=sorted(SCHEMES))
    parser.add_argument("--name", default="Palette", help="title for the sheet")
    parser.add_argument("--warmth", type=float, default=0.0,
                        help="degrees to nudge every hue; negative is warmer on most bases")
    parser.add_argument("-o", "--out", help="write an SVG swatch sheet here")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args(argv)

    try:
        swatches = build(args.base, args.scheme, args.warmth)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    notes = advice(swatches)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(render_svg(swatches, f"{args.name} — {args.scheme}"))

    if args.json:
        print(json.dumps({"base": args.base, "scheme": args.scheme,
                          "swatches": swatches, "notes": notes}, indent=2))
        return 0

    print(f"{args.name} — {args.scheme} from {args.base}\n")
    for swatch in swatches:
        share = f"{swatch['share'] * 100:.0f}%" if swatch["share"] else "—"
        print(f"  {swatch['hex']}  LRV {swatch['lrv']:>4.0f}  {share:>4}  {swatch['label']}")
    print()
    for note in notes:
        print(f"  · {note}")
    if args.out:
        print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
