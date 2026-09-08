---
description: Design a room end to end — layout, clearance check, floor plan, palette and lighting
argument-hint: [room type and size, e.g. "living room 5.2 x 4 m, door south, window north"]
---

Design this room: $ARGUMENTS

Use the `room-layout` skill, and follow it properly rather than sketching in prose.

1. Take what the user gave you above and ask only for what is genuinely missing —
   inside dimensions, ceiling height, where the doors and windows are, what
   furniture already exists and what it measures, and what the room is for. Do
   not ask about things that will not change your answer.
2. Write the layout JSON to `layout.json` in the working directory (or beside any
   file the user names).
3. Run `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/clearances.py" layout.json` and fix
   whatever it reports until it comes back clean. Say which pieces you moved and
   which measurement forced each move.
4. Render `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/floorplan.py" layout.json -o plan.svg`
   and show the user the plan.
5. Then, briefly, size the lighting with `scripts/lighting.py` and — only if the
   user has shown any interest in colour — propose a palette with
   `scripts/palette.py`. Keep both to a few lines unless asked for more.

Finish with what the room can take, what is still tight, and what to measure or
buy next. Do not claim a layout works unless the checker agrees.
