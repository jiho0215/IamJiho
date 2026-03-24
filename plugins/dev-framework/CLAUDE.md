# Dev Framework Plugin

Language-agnostic development framework with multi-agent consensus cycles.

## Core Philosophy

1. Move slow, do it right. Reduce revisits and refactoring.
2. Full rigor always. 3+ agents per step, discussion loops until zero issues.
3. Language-agnostic. Works with any tech stack.
4. Documentation as a first-class artifact.

## Plugin Structure

- `skills/dev.md` — Single `/dev` entry point with context-aware routing
- `agents/` — 6 specialized review agents
- `docs/methodology/` — Development cycle, decision making, testing, documentation
- `docs/standards/` — Result pattern, early exit, errors, observability, performance, code quality
- `docs/templates/` — ADR, feature spec, test plan, code review checklist

## Prerequisites

This plugin orchestrates the following superpowers skills. If any are unavailable, the corresponding phase will operate without skill-specific guidance:
- `superpowers:brainstorming` (Phase 2)
- `superpowers:writing-plans` (Phase 3)
- `superpowers:test-driven-development` (Phase 5)
- `superpowers:executing-plans` (Phase 5)
- `superpowers:verification-before-completion` (Phase 6)
- `superpowers:requesting-code-review` (Phase 6)
