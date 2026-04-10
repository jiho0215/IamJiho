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
External configuration (must be set up before first use):
- `~/.claude/autodev/config.json` — pipeline configuration (single source of truth for thresholds, paths, phase skills)

All skills are Anthropic official — zero external dependencies:
- `superpowers:brainstorming` (Phase 1 — requirements gathering)
- `feature-dev:code-explorer` (Phase 2 — codebase analysis)
- `feature-dev:code-architect` (Phase 3 — architecture design)
- `superpowers:writing-plans` (Phase 3 — structured plan)
- `superpowers:test-driven-development` (Phase 4, 7 — TDD methodology)
- `superpowers:subagent-driven-development` (Phase 5 — task execution with two-stage review)
- `superpowers:executing-plans` (Phase 5 — sequential alternative)
- `superpowers:dispatching-parallel-agents` (Phase 5 — parallel alternative)
- `superpowers:requesting-code-review` (Phase 6 — structured review request)
- `superpowers:receiving-code-review` (Phase 6, 8 — rigorous feedback evaluation)
- `superpowers:verification-before-completion` (Phase 10 — evidence before claims)
- `superpowers:finishing-a-development-branch` (Phase 10 — commit/push/PR options)
- `superpowers:systematic-debugging` (any failure — root cause investigation)

### Bundled Hooks (auto-registered, no setup needed)

| Hook | Event | What It Does |
|------|-------|-------------|
| Chronic pattern loader | SessionStart | Reads patterns file, outputs to session context |
| Push guard | PreToolUse (git push) | Blocks push if pipeline started but not completed for branch |
| Test failure capture | PostToolUse (dotnet test) | Logs failed test runs to session folder |
| State preservation | PreCompact | Serializes pipeline state before context truncation |
| Session cleanup | SessionEnd | Cleans temp files, marks interrupted pipelines |
