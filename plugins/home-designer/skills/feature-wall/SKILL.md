---
name: feature-wall
description: Design a TV feature wall or media wall in MDF — slatted or panelled — and produce a scaled elevation, a cut list, a materials list and a build sequence. Use when someone asks for a TV wall, media wall, slat wall, fluted wall, panelled or shaker wall, a floating console, or asks how to build one out of MDF, how much MDF it takes, or at what height to hang the television.
---

# MDF feature wall

`$PLUGIN` is `${CLAUDE_PLUGIN_ROOT}`.

## Ask four things

Everything else has a sensible default, but these change the drawing:

1. **Wall width and floor-to-ceiling height**, measured — not the room's nominal
   size. Check the width at the top and at the bottom; old walls taper.
2. **Screen size in inches**, and whether it is staying or being replaced.
3. **What is in or on that wall already** — a chimney breast, sockets, a radiator,
   a boiler, the consumer unit, a stud partition or solid masonry behind the
   plaster.
4. **Where the seating is.** Sitting closer than about 1.5 × the screen diagonal
   is uncomfortable; the `room-layout` skill checks that properly.

## Draw it

```bash
python3 "$PLUGIN/scripts/featurewall.py" --width 3600 --height 2400 --tv 65 -o wall.svg
python3 "$PLUGIN/scripts/featurewall.py" --style shaker --width 4200 -o wall.svg
python3 "$PLUGIN/scripts/featurewall.py" --width 3600 --tv 75 --json
```

Useful switches: `--slat-width` / `--slat-gap` (default 60 and 40, a 100 mm
pitch), `--thickness` (18 mm MDF), `--batten` (25 mm), `--console-width`,
`--console-height`, `--console-depth`, `--console-base`, `--no-console`, `--name`.

For a shop-bought unit — an IKEA BESTÅ run, say — add `--bought-console "IKEA BESTÅ"`
and `--module-width 600`: the bench is drawn at its real module divisions and
scheduled as a bought item, and its carcass drops out of the cut list. Use
`--bay-width` to size the flat bay behind the screen against the bench, and
`--board-height` to stop the boards below the ceiling — a 2440 mm sheet will not
reach a 2850 mm ceiling, and a painted reveal above reads better than a joint.

**Hanging a bought unit is the part that goes wrong.** A loaded 2.4 m run is heavy,
and it cannot be fixed to the board face. A continuous timber noggin goes on the
structural wall at the suspension-rail line *before* the boards, fixed at 400 mm
centres into studs or masonry; the boards go over it; the rail is screwed through
with screws long enough to clear the build-out. Say this every time.

Output is a dimensioned elevation, a section through the build-up, a cut list, a
materials list with a sheet count, and a build sequence. Show the user the
elevation and the cut list; keep the prose short.

## The three styles

**Slat** — vertical MDF battens on a painted backing panel, with a flat inset bay
where the TV hangs. Forgiving of a wavy wall, hides the cable run, and the ribs
give the wall depth under raking light. Total build-out is the batten plus two
thicknesses, about 43 mm with the defaults, so check what that does to a door
architrave or a window reveal on the same wall.

**Shaker** — mouldings planted straight onto the plaster in even bays, with the
screen in one wide central opening. Cheaper, only 18 mm proud, and it suits an
older room. It needs a flat, sound wall: on dot-and-dab you are gluing to
plasterboard that is itself glued on.

**Flush** — the minimal one. A seamless boarded face on 75 mm battens, held
15 mm clear of the floor and the head on a recessed ground so shadow gaps
replace skirting and scotia, with the screen recessed into a lined niche. Fewer
sheets than the slat wall and far more labour: battens at 400 mm centres packed
dead flat, joints filled in three passes, and a sprayed finish, because a flat
plane in raking light shows everything a slat wall would have hidden. Do not
recommend it as a first sheet-goods project.

## Numbers that matter

- **Screen centre 1050–1250 mm above the floor.** The script puts it at 1150 mm
  unless the console forces it higher. Sit on the actual sofa and check before
  anything is fixed — a wall-mounted TV that is 100 mm too high is a permanent
  irritation.
- **Console floating 250 mm off the floor**, 250–300 mm tall, 400 mm deep. The
  gap underneath is what makes it read as floating, and it is where the LED strip
  goes.
- **150–250 mm between the console top and the bottom of the screen.**
- **Bay margin 150 mm** around the screen, so the bezel is not fighting the edge.
- **Recess depth 93 mm** if the screen is to sit back in the plane rather than on
  it — that is a 75 mm batten plus an 18 mm board, and it is the single detail
  that separates a minimal wall from a plain one.
- **50 mm conduit** from behind the screen down to the console: two HDMI, one
  power, one spare. Do this before anything closes up.
- MDF: 18 mm for slats and panels, 25 mm only if the shelf spans over 900 mm
  unsupported. A 2440 × 1220 sheet yields 19 rips at 60 mm wide.

## Building it

- MDF is heavy and the dust is nasty. Cut outside or on extraction, wear a proper
  mask, and get a second pair of hands for full sheets.
- Rip every slat in one session off one fence setting, or the pitch will drift
  visibly across the wall.
- Prime the cut edges twice — they drink paint — sand between coats, and finish
  with a fine foam roller or a sprayer. A brush leaves tramlines on flat MDF.
- Paint the backing before the slats go on. You will never reach between them.
- Fix into studs or use proper cavity anchors for the bracket. A 65-inch screen
  on a cantilever arm pulls hard; MDF alone will not hold it, so the bracket goes
  through to the structure, never into the slat wall.
- Keep the end gap to each corner equal by taking the difference off both end
  slats, rather than letting the last gap be whatever is left over.
- Do not box in a boiler, a meter, a stopcock or a socket you still need. Leave
  an access panel or move them properly first.

## Finish the job

Give the user: the elevation, the cut list they can hand to a merchant, the sheet
count, and the three or four decisions that are theirs — colour, whether the LED
strip goes in, whether the console has doors or drawers, and whether the wall
goes corner to corner or stops short of the return.
