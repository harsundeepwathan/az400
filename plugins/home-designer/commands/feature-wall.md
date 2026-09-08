---
description: Design an MDF TV feature wall — elevation, cut list and build sequence
argument-hint: [wall width x height, TV size, e.g. "3.6 x 2.4 m, 65 inch, slatted"]
---

Design an MDF TV feature wall: $ARGUMENTS

Use the `feature-wall` skill. Take the dimensions from the request above and ask
only for what is genuinely missing — measured wall width and ceiling height,
screen size, and what is already on that wall (chimney breast, sockets,
radiator, whether it is stud or masonry).

Run the generator, show the elevation and the cut list, and keep the commentary
to the decisions that are actually the user's:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/featurewall.py" --width <mm> --height <mm> --tv <inches> -o wall.svg
```

Add `--style shaker` for planted panelling instead of slats. If the user has not
said, use the slat style and say why in one line.
