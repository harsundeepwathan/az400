# Clearance rules the checker applies

Every figure is millimetres, and every one is a default you can override per
layout with a `"clearances"` block. They are the middle of the range used by
domestic space-planning practice, not a building code — where a code applies
(accessible routes, means of escape, kitchen ventilation) it wins, and this
plugin does not know it.

Grid-based checks (circulation, door swing) rasterise the room at 50 mm, so a
result within about 50 mm of a limit means "go and measure it".

## Circulation

| Key | Default | What it is |
|---|---|---|
| `primary_walkway` | 900 | A route people actually walk: door to door, door to the seating. |
| `secondary_gap` | 750 | A squeeze-past between two pieces, used a few times a day. |
| `approach` | 600 | Getting from a walkway to a piece of furniture. |

The checker builds the set of floor that a 900 mm-wide envelope can reach from
the first door, then insists every other door is in that set. Anything it cannot
reach is reported. Accessories — nightstands, lamps, plants, stools, anything
under 0.25 m² — are exempt: they are reached from the piece they sit beside.

For a wheelchair user raise `primary_walkway` to 1000 and `approach` to 800, and
plan a 1500 mm turning circle in each room and a 1500 × 1500 mm clear space at
the bed and at any point where someone must turn round. The scripts do not check
turning circles.

## Doors and windows

- A door's swing is a quarter disc of radius equal to its width. Nothing that
  stands on the floor may be inside it. `"swing": "out"` moves the problem to the
  other side of the wall, which this plugin does not model.
- A piece taller than a window's sill, standing within 400 mm of that window,
  gets a warning: it will block light and probably the opening casement.
- Give a door leaf a wall to open against; a door that opens onto the room is
  worth 0.7 m² of lost floor.

## Seating

| Key | Default | Why |
|---|---|---|
| `sofa_to_table_min` | 300 | Below this there is nowhere to put your legs. |
| `sofa_to_table_max` | 450 | Above it you have to stand up to reach your cup. |
| `tv_distance_factor_min` | 1.5 × diagonal | Closer and you see pixels and turn your head. |
| `tv_distance_factor_max` | 2.5 × diagonal | Further and the picture stops being immersive. |

Conversation works up to about 2.5 m between facing seats; past 3 m people raise
their voices and stop talking to each other. Seating that faces a wall of glass
with nothing behind it feels exposed — put the backs to something solid.

## Beds

| Key | Default | Why |
|---|---|---|
| `bed_side` | 600 | Room to get in, and to change the sheets. |
| `bed_foot` | 700 | Walking past the foot without turning sideways. |

A double or larger wants 600 mm on **both** long sides; a single needs one. The
head end can be against the wall. Nightstands are expected beside a bed and are
not counted as blocking the bedside gap.

## Storage and worktops

| Key | Default | Why |
|---|---|---|
| `wardrobe_front` | 900 | Hinged door plus somebody standing in it. |
| `storage_front` | 750 | Drawers, shelves, a media unit. |
| `dining_pullout` | 900 | Chair pulled back far enough to stand up out of. |

Sliding wardrobe doors need only the `storage_front` 750; say so in the layout by
overriding the key rather than pretending the wardrobe is smaller.

Kitchen figures the scripts do not check, for when they come up: 1050 mm between
opposing runs for one cook, 1200 mm for two; 1000 mm of worktop beside the hob
and 400 mm on the other side; 300 mm of landing space beside the fridge and the
sink; 600 mm in front of an oven with a drop-down door, and never plan a corner
where two doors collide.

## Density

Furniture covering more than about 55% of the floor reads as crowded; under 20%
reads as unfurnished. Both are notes, not errors — a bedroom is meant to be full
and a hall is meant to be empty.
