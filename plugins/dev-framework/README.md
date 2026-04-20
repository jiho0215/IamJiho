# Dev Framework Plugin

> **⚠️ Notice — README is pending update to v2.0.0 (consolidated workflow).**
>
> As of v2.0.0, this plugin has been restructured: `/dev-pipeline` is removed and `/dev` is the single command (with `--autonomous TICKET` for the former pipeline behavior). The workflow has 7 phases (not 10) with two user gates (freeze doc approval at Phase 3, final approval at Phase 7). Review iterations default to 10 (not 5) with 2 consecutive zero-issue rounds for early exit. See **[CLAUDE.md](./CLAUDE.md)** for the current plugin structure and [skills/dev/SKILL.md](./skills/dev/SKILL.md) for the authoritative workflow definition. The content below is v1.0.0 and is being rewritten.

---

A language-agnostic development framework with multi-agent consensus cycles for Claude Code. Every phase dispatches 3+ specialized agents in parallel, runs consensus discussion rounds, and resolves issues until zero remain.

## Overview

The Dev Framework Plugin provides a rigorous, structured approach to software development. Instead of jumping straight into code, it guides you through requirements gathering, architecture design, planning, testing strategy, implementation, verification, and documentation -- with multi-agent consensus at every step.

## Philosophy

Building quality software requires more than writing code. You need to:
- **Understand requirements thoroughly** before designing
- **Design architecture deliberately** before implementing
- **Get user approval** before committing to a plan
- **Enforce quality standards** with multiple independent reviewers
- **Document decisions** as first-class artifacts

This plugin embeds these practices into a structured workflow with 3+ agents per phase ensuring no single perspective dominates.

## Installation

Add to your global Claude settings:

```json
// ~/.claude/settings.json
{
  "plugins": ["path/to/dev-framework"]
}
```

Or add to a project-specific configuration:

```json
// .claude/settings.json (in project root)
{
  "plugins": ["path/to/dev-framework"]
}
```

## Command: `/dev`

Launches the development framework workflow. The skill auto-detects which workflow to run based on context.

**Usage:**

```bash
/dev Add user authentication with OAuth
```

Or for other workflows:

```bash
/dev review
/dev test
/dev docs
/dev
```

When run without arguments or a feature description, the skill examines the project state and asks which workflow you need.

## Workflow Overview

The `/dev` command routes to one of five workflows based on context:

| Context | Workflow | Description |
|---------|----------|-------------|
| Empty project directory | Init | Scaffolds project structure, CLAUDE.md, ADR-001 |
| Feature/task description | Full Cycle | 7-phase development with consensus at every step |
| "review" keyword | Review | Standalone code quality review with 3 agents |
| "test" keyword | Test | Testing strategy analysis and gap identification |
| "docs" keyword | Documentation | Documentation maintenance and ADR updates |

## The 7-Phase Development Cycle

The full development cycle is the primary workflow, triggered when you describe a feature or task.

### Phase 1: Requirements (Interactive)

**Goal**: Gather and validate requirements with multi-agent consensus.

Asks clarifying questions one at a time, then dispatches `requirements-analyst`, `architect`, and `test-strategist` agents to independently analyze the requirements. Agents discuss and resolve issues until zero remain.

**Output**: Validated requirements document written to `docs/specs/[feature]-requirements.md`.

### Phase 2: Research — Codebase + Architecture (Interactive)

**Goal**: Design architecture with trade-off analysis and ADRs.

Runs 3 agents on codebase exploration and architecture design. Invokes `feature-dev:code-explorer` to trace execution paths, map architecture layers, and identify existing conventions, then `feature-dev:code-architect` to design the feature architecture based on exploration findings. Populates freeze doc §2 (API Contracts), §3 (3rd Party), §4 (Data), §7 (Security), §8 (Performance).

**Output**: Architecture Decision Records written to `docs/adr/ADR-NNN-[title].md`.

### Phase 3: Planning (Interactive, User Gate)

**Goal**: Create implementation plan and get explicit user approval.

3 agents review the plan. Integrates with `superpowers:writing-plans` when available.

**User approval required**: Presents the complete plan (requirements, architecture, implementation steps, testing approach) and waits for explicit confirmation before proceeding.

### Phase 4: Testing Strategy (Autonomous)

**Goal**: Design comprehensive test approach.

Dispatches `test-strategist`, `architect`, and `requirements-analyst` in parallel. Produces a test plan covering Unit, Integration, Smoke, and E2E tests with >= 90% branch coverage target.

### Phase 5: Implementation (Autonomous)

**Goal**: Build the feature following TDD practices.

Integrates with `superpowers:test-driven-development` and `superpowers:executing-plans` when available. After implementation, runs consensus review with `code-quality-reviewer`, `observability-reviewer`, and `performance-reviewer`.

### Phase 6: Verification & Code Review (Autonomous)

**Goal**: Run all tests, verify standards compliance, and conduct code review.

Runs all test types, verifies coverage, and dispatches 3 agents to verify against requirements, architecture decisions, and all coding standards (Result pattern, early exit, observability, performance, file size limits).

### Phase 7: Documentation (Autonomous)

**Goal**: Update all project documentation.

Updates ADRs, feature specs, and test documentation. Only documents what was built -- does not introduce new features or refactor code.

## Agents

The plugin includes 6 specialized agents, each bringing a distinct perspective to the consensus protocol:

### `requirements-analyst`

Analyzes features from the user and business perspective: use cases, edge cases, user stories, and acceptance criteria. Ensures requirements are complete and testable.

### `architect`

Evaluates system design, component boundaries, data flow, dependencies, and architectural patterns. Reviews whether changes fit existing architecture.

### `test-strategist`

Designs and evaluates testing strategies: coverage targets, test type distribution, risk areas, and edge cases. Plans comprehensive test suites across all 4 test types.

### `code-quality-reviewer`

Reviews code for compliance with project coding standards: Result pattern, early exit, file size limits, naming conventions, and single responsibility.

### `observability-reviewer`

Reviews code for production readiness: structured logging, tracing, metrics, error reporting, and correlation IDs.

### `performance-reviewer`

Reviews code for performance characteristics: time complexity, memory usage, network call efficiency, and bundle size.

## What It Enforces

The framework enforces these standards through its reference documentation and agent reviews:

- **Result\<T\> pattern**: Uniform responses for all fallible operations
- **Early exit / guard clauses**: Clean control flow patterns
- **90%+ branch coverage**: Unit, integration, smoke, and E2E tests mandatory
- **File size limits**: Files < 200 lines, functions < 30 lines
- **Structured logging**: Correlation IDs, contextual metadata
- **Performance budgets**: Measurable performance targets

## Usage Examples

### Initialize a new project:

```
/dev
```

When run in an empty directory, scaffolds the project with directory structure, CLAUDE.md, ADR-001, test configuration, and language-specific Result types.

### Build a new feature:

```
/dev Add rate limiting to API endpoints
```

Walks through all 7 phases with multi-agent consensus at each step.

### Review existing code:

```
/dev review
```

Dispatches 3 review agents (code quality, observability, performance) for a standalone quality review.

### Analyze test coverage:

```
/dev test
```

Analyzes the codebase for test coverage gaps and designs or updates the test plan.

### Update documentation:

```
/dev docs
```

Scans for undocumented decisions, updates ADRs, specs, and test plans.

## Prerequisites

The full development cycle integrates with a set of external skills that the pipeline invokes through config keys. All are optional — if any is unavailable, the corresponding phase operates with inline alternatives (graceful degradation).

The authoritative list with config keys and defaults is in **[CLAUDE.md — Prerequisites](./CLAUDE.md)** (the `Prerequisites` section maps each `pipeline.skills.*` key to its default skill). Summary of phases that integrate external skills:

- Phase 1 (Requirements): `pipeline.skills.requirements`
- Phase 2 (Research): `pipeline.skills.exploration`, `pipeline.skills.architect`
- Phase 3 (Plan + Freeze Doc): `pipeline.skills.planning`
- Phase 4 (Test Planning): `pipeline.skills.tdd`
- Phase 5 (Implementation + Layer 1 Review): `pipeline.skills.implementation` (or `implementationSequential`/`implementationParallel`), `pipeline.skills.requestReview`, `pipeline.skills.receiveReview`
- Phase 6 (Verification + Layer 2 Review): `pipeline.skills.verification`, same review skills as Phase 5
- Phase 7 (Documentation + Mistake Capture → GATE 2): `pipeline.skills.finishing`
- Any phase failure: `pipeline.skills.debugging`

Override any mapping in `~/.claude/autodev/config.json`.

## Troubleshooting

### Agents take too long

**Issue**: Consensus rounds with multiple agents are slow on large codebases.

**Solution**: This is expected behavior. Agents run in parallel when possible, and the thoroughness of multi-agent consensus prevents costly rework later. For simpler tasks that do not need the full framework, skip `/dev` and work directly.

### Too many clarifying questions in Phase 1

**Issue**: The requirements phase asks too many questions.

**Solution**: Provide more detail in your initial feature description. Include constraints, scope boundaries, and known requirements upfront. The more context you give, the fewer questions the agents need to ask.

### User gate in Phase 3 feels excessive

**Issue**: The plan approval step slows things down.

**Solution**: The user gate exists to prevent wasted implementation effort. Review the plan carefully -- it is much cheaper to change direction at Phase 3 than at Phase 6. If you trust the plan, approve it and Phases 4-7 run autonomously.

### Consensus loop does not converge

**Issue**: Agents cannot reach agreement within the review iteration cap (v2.0.0 default: 10 iterations with early exit on 2 consecutive zero-issue rounds).

**Solution**: Unresolved issues are escalated to you automatically. Review the competing perspectives, make a decision, and the workflow continues. This is by design -- some decisions require human judgment.

### Standards feel too strict

**Issue**: The 90% coverage target or file size limits are too aggressive for your project.

**Solution**: The standards in `references/` are defaults. During the Init workflow, you can customize performance budgets, coverage targets, and other thresholds for your project. These get encoded in your project's CLAUDE.md.

## Requirements

- Claude Code installed
- Git repository (for version control and code review workflows)
- Project with existing codebase (for full cycle, review, test, and docs workflows) or empty directory (for init workflow)

## Version

2.0.0

## Author

Jiho Lee (ianjiholee@gmail.com)
