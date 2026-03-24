# Dev Framework

A Claude Code plugin providing a language-agnostic development framework with multi-agent consensus cycles.

## Usage

Type `/dev` in any project. The skill auto-detects the appropriate workflow:

- **Empty project** → Project initialization (scaffolding, CLAUDE.md, ADR-001)
- **Feature description** → Full 7-phase development cycle with 3+ agents per phase
- **"review"** → Standalone code quality review
- **"test"** → Testing strategy analysis
- **"docs"** → Documentation maintenance

## What It Enforces

- Result<T> uniform responses for all fallible operations
- Early exit / guard clause patterns
- 90%+ branch coverage (unit, integration, smoke, E2E tests mandatory)
- Files < 200 lines, functions < 30 lines
- Structured logging with correlation IDs
- Performance budgets

## Prerequisites

The full development cycle integrates with these superpowers skills (Phases 2, 3, 5, 6). If unavailable, those phases operate without skill-specific guidance:

- `superpowers:brainstorming`
- `superpowers:writing-plans`
- `superpowers:test-driven-development`
- `superpowers:executing-plans`
- `superpowers:verification-before-completion`
- `superpowers:requesting-code-review`

## Installation

Add to your global Claude settings:

```json
// ~/.claude/settings.json
{
  "plugins": ["path/to/dev-framework"]
}
```

## Development Cycle (7 Phases)

| Phase | Mode | Description |
|-------|------|-------------|
| 1. Requirements | Interactive | Gather and validate with user |
| 2. Architecture | Interactive | Design structure, produce ADRs |
| 3. Planning | Interactive → Gate | Create plan, get user approval |
| 4. Testing Strategy | Autonomous | Design test approach |
| 5. Implementation | Autonomous | TDD following the plan |
| 6. Verification | Autonomous | Run tests, verify standards, code review |
| 7. Documentation | Autonomous | Update docs and ADRs |

Each phase dispatches 3+ agents in parallel, runs consensus discussion, and resolves issues until zero remain.
