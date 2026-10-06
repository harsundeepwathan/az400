#!/usr/bin/env python3
"""Renders the Vector app icon from the SVG sources in this folder.

    pip install cairosvg   # needs the system libcairo
    python3 design/icon/render.py

Writes the three 1024 px PNGs into the AppIcon asset catalog and preview PNGs
(180 px and 58 px, i.e. 60 pt @3x and 29 pt @2x) into design/icon/previews.
ImageMagick (`convert`) flattens the light icon (iOS rejects transparency
there) and makes the previews. cairosvg does the SVG rasterising because the
ImageMagick build here has no SVG coder (it would delegate to rsvg-convert).
"""
import pathlib
import subprocess

import cairosvg

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ICONSET = ROOT / "App/Vector/Resources/Assets.xcassets/AppIcon.appiconset"
PREVIEWS = HERE / "previews"

VARIANTS = {
    # name: (svg source, PNG in the icon set)
    "light": ("vector-icon.svg", "AppIcon.png"),
    "dark": ("vector-icon-dark.svg", "AppIcon-Dark.png"),
    "tinted": ("vector-icon-tinted.svg", "AppIcon-Tinted.png"),
}
# What iOS shows behind transparent dark/tinted icons is system-defined; these
# stand-ins are only for previewing (near-black, and a sample blue tint).
PREVIEW_BACKDROP = {"light": None, "dark": "#141416", "tinted": "#0B1A33"}
TINT = "#4D8BFF"


def magick(*args: str) -> None:
    subprocess.run(["convert", *args], check=True)


def main() -> None:
    PREVIEWS.mkdir(exist_ok=True)
    for name, (svg, png) in VARIANTS.items():
        target = ICONSET / png
        cairosvg.svg2png(url=str(HERE / svg), write_to=str(target), output_width=1024, output_height=1024)
        if name == "light":
            # Opaque, no alpha channel: App Store Connect rejects transparent icons.
            magick(str(target), "-background", "#FFFFFF", "-alpha", "remove", "-alpha", "off",
                   "-type", "TrueColor", f"PNG24:{target}")

        # Preview source: what the home screen roughly shows for this appearance.
        flat = PREVIEWS / f"{name}-1024.png"
        if name == "light":
            magick(str(target), str(flat))
        elif name == "dark":
            magick("-size", "1024x1024", f"xc:{PREVIEW_BACKDROP[name]}", str(target), "-composite", str(flat))
        else:
            # Luminance becomes tint strength: colour the white mark with a sample tint.
            magick(str(target), "-fill", TINT, "-colorize", "100", "-background", PREVIEW_BACKDROP[name],
                   "-alpha", "remove", "-alpha", "off", str(flat))
        for size in (180, 58):
            out = PREVIEWS / f"{name}-{size}.png"
            # Approximate the iOS corner mask (continuous corners are a little softer).
            radius = round(size * 0.2237)
            magick(str(flat), "-resize", f"{size}x{size}", "-alpha", "set",
                   "(", "-size", f"{size}x{size}", "xc:none", "-fill", "white",
                   "-draw", f"roundrectangle 0,0 {size - 1},{size - 1} {radius},{radius}", ")",
                   "-compose", "DstIn", "-composite", str(out))
        flat.unlink()

    # One contact sheet with every preview, on a mid-grey "wallpaper".
    sheet = PREVIEWS / "contact-sheet.png"
    tiles = [str(PREVIEWS / f"{n}-{s}.png") for s in (180, 58) for n in VARIANTS]
    magick("-background", "#8E8E93", *tiles, "-bordercolor", "#8E8E93", "-border", "12",
           "-gravity", "center", "+append", "-border", "12", str(sheet))


if __name__ == "__main__":
    main()
