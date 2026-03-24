# Dev Framework Plugin

Language-agnostic development framework with multi-agent consensus cycles.

## Core Philosophy

1. Move slow, do it right. Reduce revisits and refactoring.
2. Full rigor always. 3+ agents per step, discussion loops until zero issues.
3. Language-agnostic. Works with any tech stack.
4. Documentation as a first-class artifact.

## Plugin Structure

- `commands/dev.md` — `/dev` command entry point that delegates to the skill
- `skills/dev/SKILL.md` — Core skill with context-aware workflow routing
- `skills/dev/references/` — Bundled reference documentation (methodology, standards, templates)
- `agents/` — 6 specialized review agents

## Prerequisites

This plugin orchestrates the following superpowers skills. If any are unavailable, the corresponding phase will operate without skill-specific guidance:
- `superpowers:brainstorming` (Phase 2)
- `superpowers:writing-plans` (Phase 3)
- `superpowers:test-driven-development` (Phase 5)
- `superpowers:executing-plans` (Phase 5)
- `superpowers:verification-before-completion` (Phase 6)
- `superpowers:requesting-code-review` (Phase 6)
