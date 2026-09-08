---
description: Check a layout file for clearance, door-swing and circulation problems
argument-hint: [path to layout.json]
---

Check the layout at: $ARGUMENTS (default `layout.json` in the working directory).

Run:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/clearances.py" <layout>
```

Then explain the findings in plain language, worst first. For each one give the
measurement, why the limit exists, and the smallest change that clears it —
usually a piece moved a few hundred millimetres, occasionally a piece that has to
go. The rules and their numbers are in the `room-layout` skill's
`references/clearances.md`; quote the relevant one rather than inventing a figure.

If the user asks, apply the fixes to the file and re-run until it is clean.
