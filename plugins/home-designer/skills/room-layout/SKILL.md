---
name: room-layout
description: Work out where furniture goes in a room and check it before anything is bought or moved — build a layout from the room's real dimensions, validate walkways, door swings and ergonomic clearances, and render a scaled SVG floor plan. Use when someone asks where to put a sofa, bed or desk, whether a piece will fit, how to arrange or rearrange a room, or asks for a floor plan or furniture plan.
---

# Room layout

Design a room by writing a layout file, checking it with the scripts, and showing
a plan. The point of the file is that the checks are arithmetic rather than
opinion: a walkway is 900 mm wide or it is not.

`$PLUGIN` below is `${CLAUDE_PLUGIN_ROOT}` — the directory this skill lives in.

## 1. Get the dimensions

Ask for whatever is missing; guessing a room's size wastes the whole exercise.

- inside width and depth, and ceiling height
- every door: which wall, how far along, how wide, which side it hinges on, which
  way it swings
- every window: wall, position, width, sill height
- anything immovable: radiators, boiler, chimney breast, sockets that matter
- what the room is for, who uses it, and what furniture already exists (with its
  real sizes — measure, don't assume)

If they have measurements in feet and inches, put `"units": "ft"` or `"in"` in
the file rather than converting by hand.

## 2. Write the layout file

JSON, validated by `$PLUGIN/schema/layout.schema.json`. Working examples:
`$PLUGIN/examples/living-room.json` and `$PLUGIN/examples/bedroom.json`.

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
    { "name": "Sofa", "type": "sofa", "x": 4600, "y": 2100, "width": 2200, "depth": 900, "rotation": 270 }
  ]
}
```

Conventions that trip people up:

- `x` grows east, `y` grows south. North is up the plan.
- `x`/`y` are the **centre** of a piece, not a corner.
- `rotation` is degrees clockwise. At 0 a piece **faces north** (its front is the
  side with the lower `y`). A sofa against the east wall facing west is 270.
- `offset` for an opening is measured from the west end of a north/south wall, or
  the north end of an east/west wall.
- `mounted: true` for anything hung on a wall (a TV, a floating shelf) so it is
  drawn but not treated as floor space.
- rugs (`"type": "rug"`) are drawn under everything and never block anything.

## 3. Check it

```bash
python3 "$PLUGIN/scripts/clearances.py" layout.json
python3 "$PLUGIN/scripts/clearances.py" layout.json --json    # for further work
```

Exit status is 0 when clean, 1 when there are errors, 2 when the file will not
load. Errors are things that do not work at all — a piece outside the room, two
pieces in the same place, a blocked door, no 900 mm route between the doors.
Warnings are things that work but are uncomfortable. Notes are worth a sentence
to the user and no more.

Fix and re-run until it is clean, then say what you moved and why. The rules and
their numbers are in `references/clearances.md`; typical furniture sizes, for
when someone has not measured yet, are in `references/furniture-sizes.md`.

Per-room overrides go in the layout itself when a client has a reason — a
wheelchair user needs `{"clearances": {"primary_walkway": 1000, "approach": 800}}`
and a turning circle of 1500 mm that these scripts do not check for you.

## 4. Draw it

```bash
python3 "$PLUGIN/scripts/floorplan.py" layout.json -o plan.svg
python3 "$PLUGIN/scripts/floorplan.py" layout.json -o plan.svg --scale 50 --grid
```

Plain SVG: walls, door swings, windows, labelled furniture with sizes,
dimensions, a north point and a scale bar. `--scale 50` draws true 1:50 at 96 dpi
so it prints to scale; without it the plan is fitted to `--width` pixels.

Show the plan to the user. If the conversation supports artifacts and they want
to keep or share it, publishing the SVG inside a small HTML page is a good
finish; otherwise send the file.

## 5. Say what you did

Report in this order: what the room can take, what you moved and the measurement
that forced it, what is still tight, and what you would buy or measure next. Give
distances in the units the user used. Never claim a layout "works" without having
run the checker over it.

## Working method

- Start from what cannot move: doors and their swings, windows, radiators,
  the aspect people look at, and where the TV or bed must go.
- Place the biggest piece first, on the longest uninterrupted wall, then build the
  circulation route around it, then fill in.
- One clear route through the room beats several tight ones. Do not run the route
  between the seating and what the seating faces.
- Float furniture off the walls when the room is big enough; push it back when
  the check says the walkway is losing.
- Leave a piece out rather than shrink a walkway to fit it in.
