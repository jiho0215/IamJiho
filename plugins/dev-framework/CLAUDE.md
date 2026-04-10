# Dev Framework Plugin

Language-agnostic development framework with multi-agent consensus cycles.

## Core Philosophy

1. Move slow, do it right. Reduce revisits and refactoring.
2. Full rigor always. 3+ agents per step, discussion loops until zero issues.
3. Language-agnostic. Works with any tech stack.
4. Documentation as a first-class artifact.

## Plugin Structure

### /dev — Interactive Development (existing)
- `commands/dev.md` — `/dev` command entry point
- `skills/dev/SKILL.md` — Core skill with context-aware workflow routing (7 phases)
- `skills/dev/references/` — Bundled reference documentation (methodology, standards, templates)

### /dev-pipeline — Autonomous Pipeline (new)
- `commands/dev-pipeline.md` — `/dev-pipeline TICKET [--from N] [--status]`
- `skills/dev-pipeline/SKILL.md` — 10-phase autonomous pipeline with single human gate
- `skills/dev-pipeline/references/` — Review loop, mistake tracker, session management protocols
- `hooks/` — Bundled harness enforcement (auto-registered)

### Shared
- `agents/` — 6 specialized review agents (used by both /dev and /dev-pipeline)
- `skills/multi-agent-consensus/SKILL.md` — Reusable consensus loop (used by both)

## /dev-pipeline — How It Differs from /dev

| Aspect | /dev | /dev-pipeline |
|--------|------|---------------|
| Human gates | Multiple (Phase 3 approval) | One (Phase 10 only) |
| Review mechanism | Internal agents via consensus | Same agents via consensus |
| Learning | None | Cross-session mistake tracking |
| JIRA integration | None | Phase 1 fetches ticket |
| Decision logging | docs/decisions.md | Session folder decision-log.json |
| Push protection | None | Hook blocks unreviewed pushes |

## Prerequisites

### /dev prerequisites
Superpowers skills (optional — phases degrade gracefully if unavailable):
- `superpowers:brainstorming` (Phase 2)
- `superpowers:writing-plans` (Phase 3)
- `superpowers:test-driven-development` (Phase 5)
- `superpowers:executing-plans` (Phase 5)
- `superpowers:verification-before-completion` (Phase 6)
- `superpowers:requesting-code-review` (Phase 6)

### /dev-pipeline prerequisites
External configuration (auto-created on first run with defaults if absent):
- `~/.claude/autodev/config.json` — pipeline configuration (single source of truth for thresholds, paths, and skill/agent mappings)

All default skills are Anthropic official — zero external dependencies. Each skill is configurable via `config.pipeline.skills.*` and agents via `config.pipeline.agents.*`. Override any mapping in config.json to swap in custom skills.

Default skill mappings (see `references/session-management.md` for full config schema):

| Config Key | Default | Phase |
|------------|---------|-------|
| `skills.requirements` | `superpowers:brainstorming` | 1 |
| `skills.exploration` | `feature-dev:code-explorer` | 2 |
| `skills.architect` | `feature-dev:code-architect` | 3 |
| `skills.consensus` | `dev-framework:multi-agent-consensus` | 3, 6, 8 |
| `skills.planning` | `superpowers:writing-plans` | 3 |
| `skills.tdd` | `superpowers:test-driven-development` | 4, 7 |
| `skills.testPlanning` | `dev-framework:test-planning` | 4 |
| `skills.implementation` | `superpowers:subagent-driven-development` | 5 |
| `skills.implementationSequential` | `superpowers:executing-plans` | 5 |
| `skills.implementationParallel` | `superpowers:dispatching-parallel-agents` | 5 |
| `skills.requestReview` | `superpowers:requesting-code-review` | 6 |
| `skills.receiveReview` | `superpowers:receiving-code-review` | 6, 8 |
| `skills.verification` | `superpowers:verification-before-completion` | 10 |
| `skills.finishing` | `superpowers:finishing-a-development-branch` | 10 |
| `skills.debugging` | `superpowers:systematic-debugging` | Any failure |
| `agents.plan` | `[requirements-analyst, architect, test-strategist]` | 3 |
| `agents.review` | `[code-quality-reviewer, performance-reviewer, observability-reviewer]` | 6, 8 |

### Bundled Hooks (auto-registered, no setup needed)

| Hook | Event | What It Does |
|------|-------|-------------|
| Chronic pattern loader | SessionStart | Reads patterns file, outputs to session context |
| Push guard | PreToolUse (git push) | Blocks push if pipeline started but not completed for branch |
| Test failure capture | PostToolUse (dotnet test) | Logs failed test runs to session folder |
| **Phase gate** | **Called by SKILL.md** | **Validates progress map at phase boundaries (begin/end). Blocks on failure (exit 2)** |
| **Progress validator** | **PostToolUse (phase-gate.sh)** | **Independent post-gate validation of progress-log.json consistency** |
| State preservation | PreCompact | Serializes pipeline state before context truncation |
| Session cleanup | SessionEnd | Cleans temp files, marks interrupted pipelines |
