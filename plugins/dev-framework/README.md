# Dev Framework Plugin

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

### Phase 2: Architecture (Interactive)

**Goal**: Design architecture with trade-off analysis and ADRs.

Runs the same 3 agents on architecture design. Integrates with `superpowers:brainstorming` for design exploration when available, or enumerates 2-3 alternatives inline.

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

The full development cycle integrates with these superpowers skills when available. If any are unavailable, the corresponding phase operates with inline alternatives:

- `superpowers:brainstorming` (Phase 2 -- design exploration)
- `superpowers:writing-plans` (Phase 3 -- structured plan creation)
- `superpowers:test-driven-development` (Phase 5 -- TDD workflow)
- `superpowers:executing-plans` (Phase 5 -- plan execution)
- `superpowers:verification-before-completion` (Phase 6 -- acceptance criteria verification)
- `superpowers:requesting-code-review` (Phase 6 -- code review)

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

**Issue**: Agents cannot reach agreement within 5 iterations.

**Solution**: Unresolved issues are escalated to you automatically. Review the competing perspectives, make a decision, and the workflow continues. This is by design -- some decisions require human judgment.

### Standards feel too strict

**Issue**: The 90% coverage target or file size limits are too aggressive for your project.

**Solution**: The standards in `references/` are defaults. During the Init workflow, you can customize performance budgets, coverage targets, and other thresholds for your project. These get encoded in your project's CLAUDE.md.

## Requirements

- Claude Code installed
- Git repository (for version control and code review workflows)
- Project with existing codebase (for full cycle, review, test, and docs workflows) or empty directory (for init workflow)

## Version

1.0.0

## Author

Jiho Lee (ianjiholee@gmail.com)
