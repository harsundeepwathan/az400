---
description: Render a layout file as a scaled SVG floor plan
argument-hint: [path to layout.json] [--scale 50] [--grid]
---

Render a floor plan from: $ARGUMENTS (default `layout.json`).

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/floorplan.py" <layout> -o plan.svg
```

Add `--scale 50` for a true 1:50 drawing that prints to scale, or `--grid` for a
500 mm reference grid. Show the user the result.

If the file does not load, the error names the field — fix it against
`${CLAUDE_PLUGIN_ROOT}/schema/layout.schema.json` and try again. If the user has
no layout file yet, use the `room-layout` skill to build one first.
