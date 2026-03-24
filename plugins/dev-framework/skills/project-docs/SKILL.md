---
name: project-docs
version: 1.0.0
description: "Enforce, maintain, and refactor project documentation in every repository. Use this skill whenever the dev-framework interacts with a repository — before ANY implementation work, verify docs/ exists with adr/, specs/, test-plans/, and a decisions log. If missing, scaffold it. Also analyzes existing docs for staleness, redundancy, bloat, and accuracy drift, then refactors to keep documentation concise, small, and organized. Use when the user says 'update docs', 'clean up docs', 'refactor docs', 'document this decision', 'add ADR', or any documentation-related request. This is a prerequisite skill that other dev-framework skills depend on."
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

## Documentation Hygiene — Analyze & Refactor

Every time this skill runs, it should also scan existing docs for opportunities to improve clarity, reduce size, and maintain accuracy. Documentation that grows unchecked becomes noise — concise docs are more valuable than comprehensive ones.

### When to Refactor

Perform a hygiene pass:
- At the start of every dev-framework workflow (alongside verification)
- After Phase 7 (Documentation) completes
- When the user explicitly asks to clean up docs
- When `docs/decisions.md` exceeds ~50 entries (promote patterns to ADRs, archive resolved items)

### What to Look For

1. **Stale content**: Decisions that were superseded but not marked. Specs that describe features differently than the current implementation. Test plans referencing deleted tests.
2. **Redundancy**: The same decision captured in both `decisions.md` AND an ADR — keep the ADR, remove the duplicate from decisions.md with a pointer. Multiple specs covering overlapping scope — merge them.
3. **Bloat**: Files exceeding ~200 lines — split into focused documents. Decision log with resolved/obsolete entries — archive them to `docs/adr/` or remove with a summary note.
4. **Accuracy drift**: Doc content that contradicts the actual codebase. Out-of-date architecture diagrams. Coverage numbers or test counts that no longer match reality.
5. **Organization**: Files in the wrong directory (a decision in specs/, a spec in adr/). Inconsistent naming conventions. Missing cross-references between related docs.

### How to Refactor

Follow these principles:

- **Concise over comprehensive**: A 20-line doc that captures the essential decision is better than a 200-line doc that buries it in context. Remove boilerplate, hedging language, and obvious statements.
- **One concern per file**: If a spec covers two features, split it. If an ADR addresses three decisions, break it into three ADRs.
- **Archive, don't delete**: Move obsolete content to a `docs/archive/` directory (create if needed) rather than deleting. Add a one-line note explaining why it was archived.
- **Preserve user decisions**: When refactoring, never remove or alter user decisions. They are immutable. If a user decision appears stale, flag it for the user to confirm before touching it.
- **Update cross-references**: After any refactor (rename, split, merge, archive), verify that all documents referencing the changed file are updated.

### Refactor Output

After a hygiene pass, briefly report what changed:

```markdown
### Doc Hygiene Report
- **Archived**: [list of files moved to docs/archive/ with reason]
- **Merged**: [list of files combined with reason]
- **Split**: [list of files broken apart with reason]
- **Updated**: [list of files with stale content corrected]
- **No changes needed**: [if everything is clean]
```

## Integration with Other Skills

This skill is invoked automatically by the `dev` skill at the start of every workflow. Other skills can also invoke it directly when they need to verify or update documentation.

When the `multi-agent-consensus` skill resolves an issue, the resolution should be logged in `docs/decisions.md` if it represents a meaningful project decision.
