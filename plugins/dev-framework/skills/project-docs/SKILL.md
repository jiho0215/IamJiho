---
name: project-docs
version: 1.0.0
description: "Enforce and maintain a project documentation structure in every repository. Use this skill whenever the dev-framework interacts with a repository — before ANY implementation work, verify docs/ exists with adr/, specs/, test-plans/, and a decisions log. If missing, scaffold it. Also use when the user says 'update docs', 'document this decision', 'add ADR', or any documentation-related request. This is a prerequisite skill that other dev-framework skills depend on."
---

# Project Documentation Structure — `project-docs`

Every repository the dev-framework touches requires a documentation home. This skill ensures that home exists, is well-organized, and stays current. Documentation is a first-class artifact — not an afterthought.

## Why This Matters

Without a consistent doc structure, decisions get lost, context evaporates between sessions, and future developers (or future Claude sessions) waste time re-discovering what was already decided. This skill prevents that by enforcing a standard structure and providing clear guidance on what goes where.

## Priority Hierarchy

When documenting decisions, always respect this priority order:
1. **User's explicit decisions** — highest priority, never overridden
2. **Team/project conventions** — from CLAUDE.md or existing patterns
3. **Dev-framework defaults** — from plugin references (lowest priority)

If a user decision contradicts a framework default, document the user's choice and the reasoning. Never silently override user preferences.

## Required Directory Structure

Every project must have this structure. Verify it exists before any dev-framework workflow begins. If missing, create it.

```
project-root/
├── docs/
│   ├── adr/                    # Architecture Decision Records
│   │   └── ADR-001-*.md        # At minimum: project setup ADR
│   ├── specs/                  # Feature specifications
│   ├── test-plans/             # Test strategy documents
│   └── decisions.md            # Running decision log (quick-capture)
```

## Verification Steps

Run these checks at the start of any dev-framework workflow:

1. Check if `docs/` directory exists at project root
2. Check for `docs/adr/`, `docs/specs/`, `docs/test-plans/` subdirectories
3. Check for `docs/decisions.md`
4. If anything is missing, scaffold it with sensible defaults

## Scaffolding

When creating missing structure:

### docs/decisions.md (Quick Decision Log)

This is a lightweight, append-only log for capturing decisions as they happen. Not every decision needs a full ADR — small choices go here, significant ones get promoted to ADRs.

```markdown
# Decision Log

Append decisions as they are made. Format: date, context, decision, reasoning.
User decisions always take highest priority over framework defaults.

---

## [YYYY-MM-DD] Project initialized with dev-framework
- **Context**: First use of dev-framework on this project
- **Decision**: Adopted dev-framework standards as baseline
- **Reasoning**: Provides consistent quality practices
- **Priority**: Framework default (can be overridden by user)
```

### docs/adr/ (Architecture Decision Records)

Create ADR-001 for project setup if no ADRs exist. Use the ADR template from the dev skill's references.

### docs/specs/ and docs/test-plans/

Create empty directories. These get populated during the full development cycle (Phases 1 and 4).

## When to Update Documentation

- **Before implementation**: Verify structure exists (this skill)
- **During Phase 1 (Requirements)**: Write to `docs/specs/`
- **During Phase 2 (Architecture)**: Write to `docs/adr/`
- **During Phase 4 (Testing Strategy)**: Write to `docs/test-plans/`
- **During Phase 7 (Documentation)**: Update all of the above
- **Any time a decision is made**: Append to `docs/decisions.md`
- **User requests a change**: Log it in `docs/decisions.md` with "User decision" priority

## Decision Capture Format

When any decision is made (by user, by consensus protocol, or by framework default), append to `docs/decisions.md`:

```markdown
## [YYYY-MM-DD] [Brief title]
- **Context**: What prompted this decision
- **Decision**: What was decided
- **Reasoning**: Why this choice was made
- **Priority**: User decision | Team convention | Framework default
- **Source**: User / Consensus (Phase N) / Framework init
```

## Integration with Other Skills

This skill is invoked automatically by the `dev` skill at the start of every workflow. Other skills can also invoke it directly when they need to verify or update documentation.

When the `multi-agent-consensus` skill resolves an issue, the resolution should be logged in `docs/decisions.md` if it represents a meaningful project decision.
