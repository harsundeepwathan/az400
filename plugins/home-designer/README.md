# Home Designer

A Claude Code plugin for planning rooms. It turns a room's real dimensions and a
wish list into a layout you can check: scaled floor plans, clearance and
circulation validation, colour palettes with light-reflectance figures, and a
layered lighting plan.

The point is that the answers are measured rather than asserted. A walkway is
900 mm wide or it is not, and the checker will tell you which.

## Install

From this repository's marketplace:

```
/plugin marketplace add harsundeepwathan/az400
/plugin install home-designer@az400-plugins
```

Or point Claude Code at a local checkout: `/plugin marketplace add ./` from the
repository root.

## What you get

**Skills** — invoked by name, or picked up automatically when the conversation
turns to a room:

| Skill | Covers |
|---|---|
| `room-layout` | Measuring, writing a layout file, checking it, drawing the plan |
| `color-palette` | Building a scheme around what stays, and reading LRV |
| `lighting-plan` | Lumens, layers, colour temperature, placement |
| `feature-wall` | MDF TV walls: elevation, cut list, materials, build sequence |

**Commands**

| Command | Does |
|---|---|
| `/design-room` | The whole loop: layout, check, plan, lighting, palette |
| `/check-layout` | Runs the clearance checks and explains the findings |
| `/render-floorplan` | Draws an SVG plan from a layout file |
| `/feature-wall` | Designs an MDF TV feature wall and cuts the list for it |

**Agent** — `interior-critic` reviews a finished layout and reports what will
annoy someone living in it.

## The scripts

They are plain Python 3.11 with nothing but the standard library, and they work
on their own if you would rather not go through Claude.

```bash
cd plugins/home-designer

python3 scripts/clearances.py examples/living-room.json          # check a layout
python3 scripts/clearances.py examples/bedroom.json --json       # structured output
python3 scripts/floorplan.py examples/living-room.json -o plan.svg --grid
python3 scripts/floorplan.py examples/bedroom.json -o plan.svg --scale 50
python3 scripts/palette.py "#3E5C50" --scheme analogous -o palette.svg
python3 scripts/lighting.py --layout examples/living-room.json --type living
python3 scripts/featurewall.py --width 3600 --tv 65 -o wall.svg
python3 scripts/featurewall.py --style shaker --width 4200 --tv 75 --json
python3 scripts/featurewall.py --width 3500 --board-height 2400 \
  --bought-console "IKEA BESTÅ" --console-width 2400 --module-width 600 -o wall.svg
python3 scripts/featurewall.py --style flush --width 3500 --batten 75 -o wall.svg
```

`clearances.py` exits 0 when clean, 1 when it finds problems, 2 when the file
will not load, so it drops straight into a pre-commit hook or CI.

## The layout file

One rectangular room per file. Lengths in whatever `units` says; `x` grows east,
`y` grows south, and a piece's `x`/`y` is the **centre** of its footprint.
Rotation is clockwise, and at 0 a piece faces north.

```json
{
  "name": "Living room",
  "units": "mm",
  "room": { "width": 5200, "depth": 4000, "height": 2600 },
  "openings": [
    { "type": "door", "wall": "south", "offset": 400, "width": 900, "hinge": "start", "swing": "in" },
    { "type": "window", "wall": "north", "offset": 1400, "width": 2000, "sill": 900 }
  ],
  "furniture": [
    { "name": "Sofa", "type": "sofa", "x": 4600, "y": 2100, "width": 2200, "depth": 900, "rotation": 270 },
    { "name": "Coffee table", "type": "coffee_table", "x": 3200, "y": 2000, "width": 1200, "depth": 700 }
  ]
}
```

Full field list: `schema/layout.schema.json`. Worked examples: `examples/`.

## What it checks

Errors (the layout does not work): furniture outside the room, two pieces in the
same place, anything standing in a door swing, and no 900 mm route between the
doors.

Warnings (it works but it is uncomfortable): a piece more than 600 mm from any
walkway, a sofa and table too far apart to reach or too close to sit at, a screen
at the wrong viewing distance, a double bed with one side against a wall, a
wardrobe that cannot open, a dining table nobody can pull a chair out from, a
tall piece across a window.

The rules, their default figures and the reasoning are in
`skills/room-layout/references/clearances.md`, and every one can be overridden
per layout with a `"clearances"` block — for a wheelchair user, for instance.

## Limits worth knowing

- `featurewall.py` draws one flat wall in elevation. `--bought-console` schedules a
  shop-bought unit instead of cutting it, `--board-height` stops the boards below the
  ceiling so every piece fits a 2440 mm sheet, and `--bay-width` sizes the flat bay
  behind the screen. A chimney breast, a return
  or a sloped ceiling is yours to work around, and the sheet count is an estimate
  with waste in it, not a cutting optimisation.
- Rectangular rooms only. An L-shaped room has to be split into two files or
  approximated with a fixed "piece" filling the missing corner.
- Circulation and door-swing checks rasterise at 50 mm, so anything within about
  50 mm of a limit needs a tape measure.
- It plans in two dimensions. Sloped ceilings, split levels, and what happens
  above 2 m are yours to think about.
- The lighting figures are design estimates, not photometric calculations, and
  none of this knows your building regulations.

## Tests

```bash
cd plugins/home-designer && python3 -m unittest discover -s tests
```
