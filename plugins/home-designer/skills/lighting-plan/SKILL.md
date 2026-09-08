---
name: lighting-plan
description: Plan a room's lighting — how many lumens it needs, split into ambient, task and accent layers, with colour temperature, circuits and fixture counts. Use when someone asks how many downlights or lamps a room needs, why a room feels gloomy or harsh, what bulbs or colour temperature to buy, or wants a lighting scheme or lighting plan.
---

# Lighting plan

`$PLUGIN` is `${CLAUDE_PLUGIN_ROOT}`.

## Size it

```bash
python3 "$PLUGIN/scripts/lighting.py" --area 20.8 --type living --walls light
python3 "$PLUGIN/scripts/lighting.py" --layout layout.json --type living
python3 "$PLUGIN/scripts/lighting.py" --area 12 --type office --task --json
```

Room types: `living`, `bedroom`, `kitchen`, `dining`, `bathroom`, `office`,
`hallway`, `utility`. `--walls light|mid|dark` sets how much of the output comes
back off the surfaces — dark walls swallow roughly a third more light than pale
ones, which is the single biggest reason a "correctly sized" scheme disappoints.

The number is a design estimate: target illuminance × floor area, divided by a
utilisation factor and a maintenance factor. It gets you to the right order of
fixtures. It is not a photometric calculation and it does not replace one where a
regulation or a workplace standard applies.

## Then layer it

A single bright ceiling fitting is the most common lighting mistake there is. The
script splits the total three ways:

- **Ambient (55%)** — the wash that lets you cross the room. Pendant, semi-flush,
  perimeter downlights, or light bounced off the ceiling. One dimmer.
- **Task (30%)** — aimed at where you read, cook, work or do your face. Switched
  separately, and positioned so the light comes between your head and the work,
  never over your shoulder.
- **Accent (15%)** — art, shelves, a plant, a wall wash. This is the layer that
  stops a room looking flat, and the first one people leave out.

Three separate sources per room is the floor, not the target. Put them on
different switches so the room has an evening setting and a working setting.

## Choosing lamps

- **Colour temperature.** 2700 K in living rooms and bedrooms, 3000 K in kitchens
  and bathrooms, 3500–4000 K where you work or do laundry. Never mix
  temperatures within one room; matching across a floor is worth the effort too.
- **CRI 90+** anywhere colour matters — where people dress, cook, or look at art.
  Cheap 80 CRI lamps make food and skin look grey.
- **Dim-to-warm** for evening rooms: it drops towards 2200 K as it dims, the way
  a filament does.
- Check the **lumens**, not the watts, and check the beam angle on anything
  directional: 24° for accenting an object, 60° for general downlighting.
- Glare is the enemy. Recess the source, shade it, or bounce it. If you can see
  the bulb from a seat, it is in the wrong place.

## Placing it

- Downlights: 1200–1500 mm apart, and set them 700–900 mm off the wall so they
  wash it rather than scallop the ceiling above the skirting. A grid centred on
  the room usually lights the middle of the floor and nothing anyone uses.
- Kitchen: light the worktop from in front of the person, not the ceiling behind
  them, or they work in their own shadow. Under-cabinet strips are the fix.
- Dining: one pendant centred on the table, hung 750–900 mm above it, on a dimmer.
- Bed: a reading light each, switched at the bed, with the light coming over the
  shoulder onto the page.
- Bathroom: light beside the mirror at face height, not above it. Respect the IP
  zones and get an electrician to sign it off.
- Hallways and stairs: two-way switching, and enough light on the stair nosings
  that every step reads as a separate edge.

## Report it

Give the total, the three layer figures, a plausible fixture count for each, the
colour temperature and CRI, and how many switched circuits. Then name the one
change that would matter most in that particular room.
