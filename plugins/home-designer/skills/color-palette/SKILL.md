---
name: color-palette
description: Build a colour scheme for a room or a whole home — pick a dominant, supporting and accent colour from one starting point, check each against light reflectance, and produce swatches with hex values you can take to a paint shop. Use when someone asks what colour to paint a room, wants a palette or colour scheme, asks whether two colours work together, or wants to know how a colour will behave in their light.
---

# Colour palette

`$PLUGIN` is `${CLAUDE_PLUGIN_ROOT}`.

## Start from the room, not from a colour

Ask, before proposing anything:

- Which way do the windows face? North light is cool and steady and kills weak
  greens; south light is warm and forgiving; east is bright early; west goes
  orange in the evening. How much daylight does the room get at all?
- What already stays — floor, worktop, sofa, a rug, a wooden door? A palette is
  built around the things that are not being replaced.
- What is the room for, and what should it feel like when you walk in?
- What can be repainted later and what cannot? A wall is cheap to change; tiles,
  a kitchen carcass and a sofa are not.

## Build it

```bash
python3 "$PLUGIN/scripts/palette.py" "#3E5C50" --scheme analogous --name "Living room"
python3 "$PLUGIN/scripts/palette.py" "#3E5C50" -o palette.svg    # swatch sheet
python3 "$PLUGIN/scripts/palette.py" "#3E5C50" --json            # structured
```

Schemes: `monochrome`, `analogous`, `complementary`, `split-complementary`,
`triadic`, `neutral`. Walls and ceiling always stay on the base hue; the scheme
decides how far the supporting colour, the accent and the anchor travel from it.

The output is five colours with a role each: ceiling and trim, walls (60%),
upholstery and cabinetry (30%), accent (10%), and a dark anchor for the pieces
that need to hold the room down. Take the hex values to a paint merchant and ask
them to match, or use them to shortlist real paint names.

## Read the LRV

Every swatch carries its light reflectance value, 0–100. It matters more than the
hue for how a room feels:

- **Above 70** — bounces light, keeps a small or north-facing room usable.
- **50–70** — colour you can see that still gives light back. Most walls.
- **25–50** — you will feel it. Fine in a room with good daylight or one meant to
  be cosy, and plan more lumens.
- **Below 25** — a decision, not a default. Take the colour over the ceiling and
  woodwork too, or the room looks like a mistake with a white lid.

The ceiling should be the lightest surface in the room. A ceiling painted the
wall colour at 80% strength looks deliberate; brilliant white against a deep wall
often does not.

## Rules that keep a scheme honest

- 60 / 30 / 10: one colour on the big surfaces, one on the large soft pieces, one
  accent. The accent has to appear at least three times around the room or it
  reads as an accident.
- Repeat every colour somewhere else in the room. Nothing appears once.
- Keep undertones together. Greige with a pink undertone next to greige with a
  green undertone looks dirty, and neither is at fault.
- Whites have undertones too. Pick the white after the wall colour, not before.
- Adjacent rooms share at least the trim colour, so a home reads as one place.
- Test properly: paint A4 sample boards, not the wall, and move them around the
  room across a day. Look at them under the evening lamps too — a warm dimmed
  bulb takes the blue out of everything.

## Say it plainly

Give the user the role, the hex, the LRV and where it goes, then the two or three
sentences of reasoning that made you choose it. If they asked about a colour they
already own, say what it will do in their light rather than whether you like it.
