## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

## Screenshots (owner's standing request)

Always show screenshots. After any change to the app's UI:
- Push, then let the `Screenshots` workflow (.github/workflows/screenshots.yml) finish. It runs the app in the iPhone simulator and publishes light and dark PNGs to the `screenshots` branch. Don't push again while it runs, because a new push cancels it.
- `git fetch origin screenshots`, look at the images, and send the relevant ones to the user (SendUserFile, display: render), flagging anything that looks wrong.
- When a screen isn't covered yet, add it to App/VectorUITests/ScreenshotTests.swift.
- Before the run finishes, mock-ups may be shown, but they must be labelled as mock-ups.
