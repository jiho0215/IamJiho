# Dev Framework Plugin

This is a Claude Code plugin that provides a language-agnostic development framework with multi-agent consensus cycles.

## Quick Start

Type `/dev` to start. The skill auto-detects the appropriate workflow:
- Empty project → Project initialization
- Feature description → Full 7-phase development cycle
- "review" → Standalone quality review
- "test" → Testing strategy analysis
- "docs" → Documentation maintenance

## Core Philosophy

1. Move slow, do it right. Reduce revisits and refactoring.
2. Full rigor always. 3+ agents per step, discussion loops until zero issues.
3. Language-agnostic. Works with any tech stack.
4. Documentation as a first-class artifact.

## Plugin Structure

- `skills/dev.md` — Single entry point skill
- `agents/` — 6 specialized agents (requirements, architect, test, quality, observability, performance)
- `docs/methodology/` — Development cycle, decision making, testing strategy, documentation standards
- `docs/standards/` — Result pattern, early exit, error handling, observability, performance, code quality
- `docs/templates/` — ADR, feature spec, test plan, code review checklist

## Standards Enforced

- Result<T> uniform responses for all fallible operations
- Early exit / guard clause patterns
- 90%+ branch coverage with 4 mandatory test types (unit, integration, smoke, E2E)
- Files < 200 lines, functions < 30 lines
- Structured logging with correlation IDs
- Performance budgets defined and enforced

## Integration

This plugin orchestrates existing superpowers skills:
- `superpowers:brainstorming` for design exploration
- `superpowers:writing-plans` for plan creation
- `superpowers:test-driven-development` for TDD
- `superpowers:executing-plans` for implementation
- `superpowers:verification-before-completion` for pre-completion checks
- `superpowers:requesting-code-review` for code review
