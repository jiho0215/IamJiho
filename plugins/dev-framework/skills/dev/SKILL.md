---
name: dev
version: 1.0.0
description: "This skill should be used when the user wants to build a feature, initialize a project, review code quality, plan a testing strategy, or maintain documentation using a rigorous multi-agent workflow. It orchestrates 3+ specialized agents per phase with consensus cycles to ensure thorough requirements, architecture, implementation, and verification. Use for any non-trivial development task that benefits from structured quality practices."
---

# Development Framework — `/dev`

You are orchestrating a rigorous, multi-agent development cycle. Every decision matters. Move slow, do it right. Reduce revisits and refactoring.

Read the referenced documentation files from this skill's `references/` directory when you need detailed guidance on any standard or methodology.

## Companion Skills

This skill depends on two companion skills. Invoke them as described below:

- **`dev-framework:project-docs`** — Ensures every repository has a proper `docs/` structure before work begins. Invoke at the start of every workflow (Sections A-E). If the docs structure is missing, this skill scaffolds it.
- **`dev-framework:multi-agent-consensus`** — The reusable consensus protocol engine. Every phase that says "run the consensus protocol" should invoke this skill with the appropriate parameters (agents, max_iterations, zero_threshold, task_type, agents_list, context). See that skill's SKILL.md for the full parameter spec.

## Workflow Routing

Detect the appropriate workflow from context. If ambiguous, ask the user.

1. **No project files** (empty dir, no src/package.json/.csproj/go.mod/etc.) → **Init Workflow** (Section A)
2. **User provides a feature/task description** → **Full Cycle Workflow** (Section B)
3. **User says "review"** → **Review Workflow** (Section C)
4. **User says "test" or "coverage"** → **Test Workflow** (Section D)
5. **User says "docs" or "documentation"** → **Documentation Workflow** (Section E)
6. **Ambiguous** → Ask the user which workflow they need

---

## Section A: Init Workflow

For new or uninitialized projects.

1. **Invoke `dev-framework:project-docs`** to verify/scaffold the `docs/` directory structure
2. Ask the user for: project name, language/framework, test runner, linter, performance budgets (or accept defaults from `references/standards/PERFORMANCE.md`), and existing conventions
3. Explore the project directory for existing files to auto-detect language/framework
4. Create additional directory structure: `tests/` (or framework equivalent), `src/` (or equivalent)
5. Create CLAUDE.md with project-specific configuration referencing the generic standards from `references/standards/`
6. Create ADR-001: Project Setup (use template from `references/templates/ADR_TEMPLATE.md`)
7. Set up test configuration for the detected test runner
8. Map generic standards to concrete implementations:
   - **Result pattern:** Generate a language-specific Result type. Read `references/standards/RESULT_PATTERN.md` for the pattern.
   - **Test types:** Map Unit/Integration/Smoke/E2E to the project's testing tools
   - **Observability:** Map to the project's logging/tracing libraries
   - Delegate to language-specific Claude skills if available, or use detected framework conventions
9. **Validate scaffolded output.** Invoke `dev-framework:multi-agent-consensus` with:
   - `task_type: validate`
   - `agents_list: [code-quality-reviewer, architect, requirements-analyst]`
   - `context: "Validate all scaffolded files against the actual codebase. Ensure documented state (provider trees, file paths, API endpoints, type shapes, storage mechanisms) matches reality. Flag any aspirational documentation that contradicts the current code."`
   - This step catches the most dangerous class of documentation bugs: docs that describe a target architecture as if it were already implemented.
10. Confirm initialization is complete. Present a summary of what was created and tell the user: "Type `/dev [feature description]` to begin the full development cycle for your first feature."

---

## Section B: Full Development Cycle

**Prerequisite**: Invoke `dev-framework:project-docs` to verify the project's `docs/` structure exists before starting.

The primary workflow. 7 phases. Phases 1-3 are interactive (heavy user communication). Phase 3 ends with a user gate. Phases 4-7 are autonomous after user confirmation.

### Multi-Agent Consensus Protocol

Every phase uses the `dev-framework:multi-agent-consensus` skill. Invoke it with the appropriate `task_type`, `agents_list`, and `context` for each phase. Default configuration: `agents: 3`, `max_iterations: 10`, `zero_threshold: 2`. Individual phases may override these defaults (e.g., `max_iterations: 5` for time-boxed phases). Read `references/methodology/DECISION_MAKING.md` for issue validity criteria and ADR lifecycle rules.

### Decision Logging

After each consensus round that produces a significant decision, the **dev skill (orchestrator)** is responsible for invoking `dev-framework:project-docs` to append the decision to the project's `docs/decisions.md`. The multi-agent-consensus skill produces a "Decisions Made" section in its output — use that as the source.

---

### Phase 1: REQUIREMENTS (Interactive)

Gather as much information as possible from the user. Ask clarifying questions one at a time. Understand the full scope before proceeding.

After gathering requirements, run the consensus protocol with these agents:
- `requirements-analyst` — user/business perspective
- `architect` — system design perspective
- `test-strategist` — testing/quality perspective

Each agent independently analyzes the requirements from their perspective. Then run the discussion round and resolution loop.

Output: A validated requirements document with zero unresolved issues. Write to `docs/specs/[feature]-requirements.md`.

### Phase 2: ARCHITECTURE (Interactive)

Run the consensus protocol with the same 3 agents on architecture design.

Invoke the `superpowers:brainstorming` skill for design exploration. If unavailable, enumerate 2-3 design alternatives inline with trade-offs. This handles proposing 2-3 approaches, evaluating trade-offs, and selecting the best architecture.

Produce Architecture Decision Records using the template at `references/templates/ADR_TEMPLATE.md`. Read `references/methodology/DECISION_MAKING.md` for ADR lifecycle rules.

Output: ADR documents and architecture design with zero unresolved issues. Write ADRs to `docs/adr/ADR-NNN-[title].md`.

### Phase 3: PLANNING (Interactive → User Gate)

Invoke the `superpowers:writing-plans` skill for structured plan creation. If unavailable, create the plan inline with step-by-step breakdown.

Run the consensus protocol with these agents:
- `requirements-analyst` — validates plan covers all requirements
- `architect` — validates plan aligns with architecture decisions
- `test-strategist` — validates plan includes testability considerations

After the final confirmation round:

**USER REVIEW & CONFIRMATION GATE**
Present the final plan to the user. Include:
- Requirements summary from Phase 1
- Architecture decisions from Phase 2
- Implementation plan with step-by-step breakdown
- Preliminary testing approach (high-level sketch — Phase 4 will elaborate into a full test plan)

Do NOT proceed until the user explicitly approves. If the user requests changes, incorporate them and re-run the consensus protocol. If the user rejects the plan entirely and indicates the requirements were misunderstood, return to Phase 1 and re-gather requirements.

### Phase 4: TESTING STRATEGY (Autonomous)

Dispatch 3 agents in parallel:
- `test-strategist`: Test types, coverage targets, risk areas
- `architect`: Testability of the architecture, component boundaries
- `requirements-analyst`: Traceability to requirements, acceptance criteria coverage

Run the consensus protocol (max 5 iterations — see DECISION_MAKING.md; escalate if unresolved).

Read `references/methodology/TESTING_STRATEGY.md` for requirements.

Requirements:
- Map tests to requirements (traceability matrix)
- Define all 4 test types: Unit, Integration, Smoke, E2E
- Coverage target: >= 90% branch coverage
- Produce a test plan document using `references/templates/TEST_PLAN_TEMPLATE.md`

### Phase 5: IMPLEMENTATION (Autonomous)

Invoke the `superpowers:test-driven-development` skill — write tests first, then implementation. If unavailable, follow TDD manually: write a failing test, implement minimum code to pass, refactor.

Invoke the `superpowers:executing-plans` skill to execute the plan from Phase 3. If unavailable, follow the plan steps sequentially.

After implementation, you **MUST** invoke `dev-framework:multi-agent-consensus` with `task_type: validate` (max 5 iterations — see DECISION_MAKING.md; escalate if unresolved) with these review agents:
- `code-quality-reviewer` — standards compliance (read `references/standards/` files)
- `observability-reviewer` — telemetry, logging, tracing
- `performance-reviewer` — performance characteristics

**Do NOT substitute a manual single-agent review for the consensus protocol.** The iteration loop is what catches issues that a single pass misses. A single reviewer finding issues, followed by fixes without re-validation, is NOT convergence.

### Phase 6: VERIFICATION & CODE REVIEW (Autonomous)

1. Run ALL tests (unit, integration, smoke, E2E)
2. Verify test coverage >= 90% branch coverage
3. Invoke the `superpowers:verification-before-completion` skill. If unavailable, manually verify all acceptance criteria from Phase 1.
4. Invoke the `superpowers:requesting-code-review` skill. If unavailable, use the `references/templates/CODE_REVIEW_CHECKLIST.md` template to conduct review inline.

Run the consensus protocol with these agents:
- `code-quality-reviewer` — standards compliance
- `observability-reviewer` — telemetry and logging completeness
- `performance-reviewer` — performance budget adherence

Verify against:
- Original requirements from Phase 1
- Architecture decisions from Phase 2
- Implementation plan from Phase 3
- All coding standards: Result pattern, early exit, observability, performance, file size limits

Read these standards from `references/standards/`:
- `RESULT_PATTERN.md` — uniform Result<T> responses
- `EARLY_EXIT.md` — guard clause patterns
- `ERROR_HANDLING.md` — error categorization
- `OBSERVABILITY.md` — telemetry requirements
- `PERFORMANCE.md` — performance budgets
- `CODE_QUALITY.md` — file size, naming, structure

If the resolution loop does not converge within 5 iterations, escalate remaining issues to the user.

### Phase 7: DOCUMENTATION (Autonomous)

- Update/create ADRs for any decisions made during implementation that deviated from Phase 2
- Update feature specs to reflect final implementation
- Update test documentation with actual coverage numbers and test inventory
- Ensure the project's `docs/` directory is current and complete

**Scope boundary:** Phase 7 only documents what was built. It does not introduce new features, refactor code, or change behavior. If documentation reveals an implementation gap, log it as a follow-up task.

---

## Section C: Review Workflow

Standalone quality review, independent of the full cycle.

1. Dispatch 3 review agents in parallel:
   - `code-quality-reviewer`
   - `observability-reviewer`
   - `performance-reviewer`
2. Run the consensus protocol (discussion round → resolution loop → final confirmation)
3. Each agent reads the relevant standards from `references/standards/`
4. Produce a review report using `references/templates/CODE_REVIEW_CHECKLIST.md` as the output template, with findings, severity, and recommended fixes

---

## Section D: Test Workflow

Standalone testing strategy analysis.

1. Analyze the codebase for test coverage gaps
2. Read `references/methodology/TESTING_STRATEGY.md`
3. Design or update the test plan ensuring all 4 test types are represented
4. Verify branch coverage target (>= 90%)
5. Run the consensus protocol with `test-strategist`, `architect`, and `requirements-analyst`

---

## Section E: Documentation Workflow

Standalone documentation maintenance.

1. Read `references/methodology/DOCUMENTATION_STANDARDS.md`
2. Scan for undocumented decisions, features, or changes
3. Update ADRs, specs, test plans
4. Ensure the project's `docs/` directory is current
5. Verify all ADRs follow the template at `references/templates/ADR_TEMPLATE.md`
