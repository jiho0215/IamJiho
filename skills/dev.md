---
name: dev
description: >
  Single entry point for the rigorous multi-agent development framework. Use this skill whenever
  starting new feature development, initializing a project, reviewing code quality, designing
  testing strategy, or updating documentation. Trigger when user says /dev, mentions "development cycle",
  "init project", "code review", "testing strategy", "update docs", or describes any software development
  task that should follow structured quality practices. This skill orchestrates a 7-phase development
  cycle with 3+ parallel agents per phase, enforcing 90%+ branch coverage, Result pattern, early exit,
  observability, and performance standards. Even for seemingly simple tasks, invoke this skill — it
  ensures nothing is missed and quality remains consistent.
---

# Development Framework — `/dev`

You are orchestrating a rigorous, multi-agent development cycle. Every decision matters. Move slow, do it right. Reduce revisits and refactoring.

Read the referenced documentation files from the plugin's `docs/` directory when you need detailed guidance on any standard or methodology. The plugin root is `${CLAUDE_PLUGIN_ROOT}`.

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

1. Ask the user for: project name, language/framework, test runner, linter, existing conventions
2. Explore the project directory for existing files to auto-detect language/framework
3. Create directory structure: `docs/`, `docs/adr/`, `tests/` (or framework equivalent), `src/` (or equivalent)
4. Create CLAUDE.md with project-specific configuration referencing the generic standards from `${CLAUDE_PLUGIN_ROOT}/docs/standards/`
5. Create ADR-001: Project Setup (use template from `${CLAUDE_PLUGIN_ROOT}/docs/templates/ADR_TEMPLATE.md`)
6. Set up test configuration for the detected test runner
7. Map generic standards to concrete implementations:
   - **Result pattern:** Generate a language-specific Result type. Read `${CLAUDE_PLUGIN_ROOT}/docs/standards/RESULT_PATTERN.md` for the pattern.
   - **Test types:** Map Unit/Integration/Smoke/E2E to the project's testing tools
   - **Observability:** Map to the project's logging/tracing libraries
   - Delegate to language-specific Claude skills if available, or use detected framework conventions

---

## Section B: Full Development Cycle

The primary workflow. 7 phases. Phases 1-3 are interactive (heavy user communication). Phase 3 ends with a user gate. Phases 4-7 are autonomous after user confirmation.

### Multi-Agent Consensus Protocol

Every phase uses this protocol. Read `${CLAUDE_PLUGIN_ROOT}/docs/methodology/DECISION_MAKING.md` for full details.

**Step 1 — Independent Analysis:**
Dispatch 3+ agents in parallel using the Agent tool (one message, multiple Agent tool calls). Each agent runs as an isolated subprocess — no agent sees another's output.

**Step 2 — Discussion Round:**
Collect all agent outputs. Combine findings, identify conflicts, gaps, and issues. Tag each issue with severity and the agent that raised it.

**Step 3 — Issue Resolution Loop (max 5 iterations):**
For each valid issue: dispatch agents in parallel to propose solutions with reasoning. Evaluate proposals, select best by reasoning quality, apply solution. A valid issue causes incorrect behavior, violates a requirement, breaks a coding standard, or creates technical debt. Invalid issues are cosmetic preference, already addressed, out of scope, or duplicates.

If zero valid issues remain → proceed to Step 4.
If 5 iterations reached without convergence → escalate to user with full context.

**Step 4 — Final Confirmation Round:**
Dispatch all agents in parallel for one final review. Each confirms zero valid issues. If ANY agent finds a new issue → back to Step 3 (counts toward iteration limit). Only proceed when ALL agents confirm zero issues.

---

### Phase 1: REQUIREMENTS (Interactive)

Gather as much information as possible from the user. Ask clarifying questions one at a time. Understand the full scope before proceeding.

After gathering requirements, run the consensus protocol with these agents:
- `requirements-analyst` — user/business perspective
- `architect` — system design perspective
- `test-strategist` — testing/quality perspective

Each agent independently analyzes the requirements from their perspective. Then run the discussion round and resolution loop.

Output: A validated requirements document with zero unresolved issues.

### Phase 2: ARCHITECTURE (Interactive)

Run the consensus protocol with the same 3 agents on architecture design.

Invoke the `superpowers:brainstorming` skill for design exploration. This handles proposing 2-3 approaches, evaluating trade-offs, and selecting the best architecture.

Produce Architecture Decision Records using the template at `${CLAUDE_PLUGIN_ROOT}/docs/templates/ADR_TEMPLATE.md`. Read `${CLAUDE_PLUGIN_ROOT}/docs/methodology/DECISION_MAKING.md` for ADR lifecycle rules.

Output: ADR documents and architecture design with zero unresolved issues.

### Phase 3: PLANNING (Interactive → User Gate)

3 agents independently review the implementation plan.

Invoke the `superpowers:writing-plans` skill for structured plan creation.

Run the consensus protocol on the plan. After the final confirmation round:

**USER REVIEW & CONFIRMATION GATE**
Present the final plan to the user. Include:
- Requirements summary from Phase 1
- Architecture decisions from Phase 2
- Implementation plan with step-by-step breakdown
- Testing approach overview

Do NOT proceed until the user explicitly approves. If the user requests changes, incorporate them and re-run the consensus protocol.

### Phase 4: TESTING STRATEGY (Autonomous)

Run the consensus protocol with 3 agents to design the test approach.

Read `${CLAUDE_PLUGIN_ROOT}/docs/methodology/TESTING_STRATEGY.md` for requirements.

Requirements:
- Map tests to requirements (traceability matrix)
- Define all 4 test types: Unit, Integration, Smoke, E2E
- Coverage target: >= 90% branch coverage
- Produce a test plan document using `${CLAUDE_PLUGIN_ROOT}/docs/templates/TEST_PLAN_TEMPLATE.md`

### Phase 5: IMPLEMENTATION (Autonomous)

Invoke the `superpowers:test-driven-development` skill — write tests first, then implementation.

Invoke the `superpowers:executing-plans` skill to execute the plan from Phase 3.

After implementation, run the consensus protocol with these review agents:
- `code-quality-reviewer` — standards compliance (read `${CLAUDE_PLUGIN_ROOT}/docs/standards/` files)
- `observability-reviewer` — telemetry, logging, tracing
- `performance-reviewer` — performance characteristics

### Phase 6: VERIFICATION & CODE REVIEW (Autonomous)

1. Run ALL tests (unit, integration, smoke, E2E)
2. Verify test coverage >= 90% branch coverage
3. Invoke the `superpowers:verification-before-completion` skill
4. Invoke the `superpowers:requesting-code-review` skill

Run the consensus protocol with 3 agents verifying against:
- Original requirements from Phase 1
- Architecture decisions from Phase 2
- Implementation plan from Phase 3
- All coding standards: Result pattern, early exit, observability, performance, file size limits

Read these standards from `${CLAUDE_PLUGIN_ROOT}/docs/standards/`:
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
3. Each agent reads the relevant standards from `${CLAUDE_PLUGIN_ROOT}/docs/standards/`
4. Produce a review report with findings, severity, and recommended fixes

---

## Section D: Test Workflow

Standalone testing strategy analysis.

1. Analyze the codebase for test coverage gaps
2. Read `${CLAUDE_PLUGIN_ROOT}/docs/methodology/TESTING_STRATEGY.md`
3. Design or update the test plan ensuring all 4 test types are represented
4. Verify branch coverage target (>= 90%)
5. Run the consensus protocol with `test-strategist`, `architect`, and `requirements-analyst`

---

## Section E: Documentation Workflow

Standalone documentation maintenance.

1. Read `${CLAUDE_PLUGIN_ROOT}/docs/methodology/DOCUMENTATION_STANDARDS.md`
2. Scan for undocumented decisions, features, or changes
3. Update ADRs, specs, test plans
4. Ensure the project's `docs/` directory is current
5. Verify all ADRs follow the template at `${CLAUDE_PLUGIN_ROOT}/docs/templates/ADR_TEMPLATE.md`
