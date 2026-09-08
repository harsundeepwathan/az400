# az400

Sandbox repository. Alongside the AZ-400 exercise files it hosts a Claude Code
plugin marketplace.

## Plugins

| Plugin | What it does |
|---|---|
| [`home-designer`](plugins/home-designer) | Plan rooms: layout files, clearance and circulation checks, scaled SVG floor plans, colour palettes and lighting plans. |

Install from this repository:

```
/plugin marketplace add harsundeepwathan/az400
/plugin install home-designer@az400-plugins
```

The marketplace manifest is `.claude-plugin/marketplace.json`; each plugin lives
under `plugins/`.
