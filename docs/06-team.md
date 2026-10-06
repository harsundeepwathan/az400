# 6. The team (Claude Code subagents)

Vector ships with a team of 18 specialist subagents in `.claude/agents/`. They're adapted from [msitarzewski/agency-agents](https://github.com/msitarzewski/agency-agents) (MIT; source commit `8329468`, license in `.claude/agents/LICENSE-agency-agents`).

Each agent keeps its original role and personality. Two changes were made:
- each agent's `name` is a lowercase-hyphen ID, which Claude Code requires;
- each file ends with a **Vector project context** section: required reading, the stack, non-negotiable rules (no fabricated functionality, honest verification, the Ink design system) and what counts as evidence in this repo. The orchestrator also has a Vector-specific pipeline.

| Role | Agent | Owns |
|---|---|---|
| Lead | `agents-orchestrator` | Runs the spec → tasks → dev ↔ QA → release pipeline |
| Product | `product-manager` | Scope, priorities, success metrics |
| | `project-manager-senior` | Turns the roadmap into an exact task list |
| Design | `ux-architect` | Flows and information architecture |
| | `ui-designer` | Screens against `docs/02-design-system.md` |
| | `ui-finish-gate-reviewer` | Blocks generic or off-system UI before it ships |
| Engineering | `mobile-app-builder` | SwiftUI app, StoreKit, HealthKit, widgets, Watch |
| | `backend-architect` | `backend/api`, PostgreSQL schema and migrations |
| | `ai-engineer` | Meal-scan model, prompt and accuracy evaluation |
| | `privacy-engineer` | Data minimisation, deletion, privacy manifest |
| | `mobile-release-engineer` | Signing, TestFlight, App Store submission |
| Quality | `code-reviewer` | Correctness and maintainability of every diff |
| | `appsec-engineer` | Auth, tokens, threat model, dependency risk |
| | `api-tester` | Backend contract and load tests |
| | `accessibility-auditor` | VoiceOver, Dynamic Type, contrast |
| | `evidence-collector` | Per-task QA with real evidence |
| | `reality-checker` | Final go / no-go (defaults to NEEDS WORK) |
| Growth | `app-store-optimizer` | App Store listing, screenshots, keywords |

Left out on purpose: the payments engineer (built for Stripe and card processors; Vector uses StoreKit) and the web frontend agents.

## Using the team

In Claude Code, from this repository:

- Whole pipeline: *"Use the agents-orchestrator to run the Vector P1 backlog from docs/05-launch-audit.md."*
- One specialist: *"Have the mobile-app-builder fix the Xcode compile errors"*, *"Ask the reality-checker whether we're ready for TestFlight."*

Most P1 work (compiling the app, simulator tests, signing, TestFlight) needs a **Mac with Xcode**, an Apple developer account and an Anthropic API key. In a Linux cloud session the team can still work on `VectorCore` and `backend/api` and their tests, and is instructed to mark UI work as unverified rather than claim it builds.
