# Development Framework Plugin — Design Specification

**Date:** 2026-03-23
**Status:** Approved — Implementation Pending
**Author:** Collaborative (human + Claude)

---

## 1. Problem Statement

Building software with high quality, strong documentation, and uniform patterns requires discipline that is hard to maintain across projects. Each new project risks inconsistency, missing tests, poor observability, and architectural drift.

We need a **language-agnostic development framework** implemented as a Claude Code plugin that:
- Enforces a rigorous multi-agent development cycle
- Ensures 90%+ branch coverage with mandatory test types
- Maintains uniform coding standards (Result pattern, early exit, small files)
- Produces and maintains documentation alongside code
- Integrates with existing Claude Code superpowers skills

## 2. Core Philosophy

1. **Move slow, do it right.** Reduce revisits and refactoring.
2. **Full rigor always.** 3+ agents per step, discussion loops until zero issues. No exceptions regardless of task size.
3. **Language-agnostic.** Delegates language-specific concerns to appropriate Claude skills/plugins at runtime.
4. **Orchestrator pattern.** Wraps existing superpowers skills with development culture, doesn't replace them.
5. **Documentation as a first-class artifact.** Every decision documented. Every pattern explained.

## 3. Plugin Architecture

### 3.1 Location

Standalone git repo: cloned from `https://github.com/jiho0215/IamJiho.git`.
The **repository root** is the plugin root — `plugin.json` lives at the top level of the repo, not in a subdirectory.
Referenced in global Claude settings (`~/.claude/settings.json` → `"plugins"` array) for universal availability across all projects.

### 3.2 Plugin Manifest (`plugin.json`)

```json
{
  "name": "dev-framework",
  "version": "1.0.0",
  "description": "Language-agnostic development framework with multi-agent consensus cycle",
  "skills": [
    "skills/dev.md"
  ],
  "agents": [
    "agents/requirements-analyst.md",
    "agents/architect.md",
    "agents/test-strategist.md",
    "agents/code-quality-reviewer.md",
    "agents/observability-reviewer.md",
    "agents/performance-reviewer.md"
  ]
}
```

Skills are markdown files with YAML frontmatter defining `name`, `description`, and trigger conditions. Agents are markdown files with YAML frontmatter defining `name`, `description`, `model`, and `tools`. Claude Code auto-discovers these from the paths listed in `plugin.json`.

### 3.3 Directory Structure

```
<repo-root>/                             # This IS the plugin root
├── plugin.json                          # Plugin manifest (see 3.2)
├── CLAUDE.md                            # Self-documentation for the plugin itself
│
├── skills/
│   └── dev.md                           # Single entry point — routes to all workflows
│
├── agents/
│   ├── requirements-analyst.md          # Analyzes from user/business perspective
│   ├── architect.md                     # Analyzes from system design perspective
│   ├── test-strategist.md               # Analyzes from testing/quality perspective
│   ├── code-quality-reviewer.md         # Reviews code against standards
│   ├── observability-reviewer.md        # Reviews telemetry/logging/tracing
│   └── performance-reviewer.md          # Reviews performance characteristics
│
├── docs/
│   ├── methodology/
│   │   ├── DEVELOPMENT_CYCLE.md         # The full multi-agent cycle (detailed)
│   │   ├── DECISION_MAKING.md           # How decisions are made (agent consensus)
│   │   ├── TESTING_STRATEGY.md          # Test types, coverage requirements
│   │   └── DOCUMENTATION_STANDARDS.md   # How docs are maintained
│   │
│   ├── standards/
│   │   ├── RESULT_PATTERN.md            # Uniform Result<T> pattern (pseudocode)
│   │   ├── EARLY_EXIT.md               # Early exit / guard clause patterns
│   │   ├── ERROR_HANDLING.md            # Error handling philosophy
│   │   ├── OBSERVABILITY.md             # Telemetry, logging, tracing standards
│   │   ├── PERFORMANCE.md              # Performance principles & budgets
│   │   └── CODE_QUALITY.md              # File size limits, naming, structure
│   │
│   └── templates/
│       ├── ADR_TEMPLATE.md              # Architecture Decision Record template
│       ├── FEATURE_SPEC_TEMPLATE.md     # Feature specification template
│       ├── TEST_PLAN_TEMPLATE.md        # Test plan document template
│       └── CODE_REVIEW_CHECKLIST.md     # Review checklist template
│
└── hooks/
    └── (reserved for future enforcement hooks)
```

## 4. Skill Invocation Mechanism

Skills invoke other skills by including an instruction in their markdown body such as:
`"Invoke the superpowers:brainstorming skill before proceeding with architecture design."`

When Claude reads this instruction in the skill body, it uses the `Skill` tool to load and execute the referenced skill. This is the same mechanism that superpowers skills use to chain into each other (e.g., `brainstorming` → `writing-plans` → `executing-plans`).

Agent dispatch uses the `Agent` tool with parallel invocations. Skills instruct Claude to dispatch multiple agents in a single message using multiple `Agent` tool calls. Each agent runs as an independent subprocess with its own context — achieving natural isolation (no agent sees another's output until the orchestrating skill combines their results).

## 5. Skill Definition — `/dev`

### 5.1 Single Entry Point

`/dev` is the only skill the user needs to know. It auto-detects the appropriate workflow based on project context, or asks the user if ambiguous.

**Context detection logic:**
1. **No project files detected** (empty directory or no src/package.json/.csproj/etc.) → Route to **Init** workflow
2. **User provides a feature/task description** → Route to **Full Cycle** workflow
3. **User says "review"** → Route to **Review** workflow
4. **User says "test" or "coverage"** → Route to **Test** workflow
5. **User says "docs" or "documentation"** → Route to **Documentation** workflow
6. **Ambiguous** → Ask the user which workflow they need

### 5.2 Workflow: Full Development Cycle

The primary workflow. Orchestrates the entire development cycle for any feature or task.

**Interaction Model:**
- **Phases 1-3 (Interactive):** Heavy communication with the user. Gather requirements, explore architecture, create plans. User is actively involved.
- **User Gate after Phase 3:** Present final plan for user review and explicit confirmation.
- **Phases 4-7 (Autonomous):** After user confirms the plan, execute implementation, testing, verification, and documentation autonomously.

**Phase 1: REQUIREMENTS (Interactive)**
- Gather as much information as possible from the user
- Ask clarifying questions one at a time
- Dispatch 3 agents independently:
  - `requirements-analyst`: User/business perspective
  - `architect`: System design perspective
  - `test-strategist`: Testing/quality perspective
- Combine findings into a discussion round
- Identify issues, validate issues
- Resolution loop: agents discuss and resolve each issue (max 5 iterations)
- Repeat until zero valid issues across all agents
- Final confirmation round: all 3 agents independently verify zero valid issues

**Phase 2: ARCHITECTURE (Interactive)**
- Same 3-agent parallel analysis pattern
- Invoke `superpowers:brainstorming` for design exploration
- Produce Architecture Decision Records (ADRs)
- Discussion/resolution loop until zero issues (max 5 iterations)
- Final confirmation round

**Phase 3: PLANNING (Interactive → User Gate)**
- 3 agents independently create/review the implementation plan
- Invoke `superpowers:writing-plans` for structured plan creation
- Discussion/resolution loop until zero issues (max 5 iterations)
- Final confirmation round
- **USER REVIEW & CONFIRMATION GATE**: Present final plan to user. Do NOT proceed until explicit user approval.

**Phase 4: TESTING STRATEGY (Autonomous)**
- 3 agents design the test approach
- Map tests to requirements (traceability)
- Define test types: Unit, Integration, Smoke, E2E
- Coverage target: >= 90% branch coverage
- Produce test plan document
- Discussion/resolution loop until zero issues (max 5 iterations)

**Phase 5: IMPLEMENTATION (Autonomous)**
- Invoke `superpowers:test-driven-development`
- Invoke `superpowers:executing-plans`
- 3 agents review implementation independently:
  - `code-quality-reviewer`: Standards compliance
  - `observability-reviewer`: Telemetry/logging
  - `performance-reviewer`: Performance characteristics
- Discussion/resolution loop until zero issues (max 5 iterations)

**Phase 6: VERIFICATION & CODE REVIEW (Autonomous)**
- Run ALL tests (unit, integration, smoke, E2E)
- Verify test coverage >= 90% **branch coverage** (branch coverage is the required metric — it measures whether both true/false paths of every conditional are exercised, which is the most meaningful measure of test thoroughness)
- Invoke `superpowers:verification-before-completion`
- Invoke `superpowers:requesting-code-review` (code review is a verification activity)
- 3 agents verify against:
  - Original requirements from Phase 1
  - Architecture decisions from Phase 2
  - Implementation plan from Phase 3
  - All coding standards (Result pattern, early exit, observability, performance, file size)
- Resolution loop until zero issues (max 5 iterations, escalate to user if non-convergent)
- Final confirmation round from all agents

**Phase 7: DOCUMENTATION (Autonomous)**
- Update/create ADRs for any decisions made during implementation that deviated from Phase 2 design
- Update feature specs to reflect final implementation
- Update test documentation with actual coverage numbers and test inventory
- Ensure docs directory is current and complete
- **Scope boundary:** Phase 7 only documents what was built. It does not introduce new features, refactor code, or change behavior. If documentation review reveals a gap in implementation, it is logged as a follow-up task, not fixed in Phase 7.

### 5.3 Workflow: Project Initialization

Triggered when `/dev` detects an empty or uninitialized project. Sets up a new project with the framework's standards baked in.
- Asks the user for: project name, language/framework, test runner, linter, and any existing conventions
- Explores the project directory for existing files (package.json, .csproj, go.mod, etc.) to auto-detect language/framework if already initialized
- Creates directory structure (docs/, tests/, src/ or equivalent for the detected framework)
- Creates CLAUDE.md with project-specific configuration referencing the generic standards
- Creates initial ADR (ADR-001: Project Setup) documenting the technology choices
- Sets up test configuration for the detected test runner
- Maps generic standards to concrete implementations:
  - **Result pattern:** Generates a language-specific Result type (e.g., TypeScript discriminated union, C# record, Go error tuple)
  - **Test types:** Maps Unit/Integration/Smoke/E2E to the project's testing tools
  - **Observability:** Maps to the project's logging/tracing libraries
  - This mapping is done by delegating to language-specific Claude skills if available, or by using the detected framework's conventions

### 5.4 Workflow: Quality Review

Triggered when user says "review" or requests code quality analysis. Can be invoked independently outside the full cycle.
- Dispatches 3 review agents (code-quality, observability, performance)
- Discussion/resolution loop (max 5 iterations)
- Produces review report

### 5.5 Workflow: Testing Strategy

Triggered when user says "test" or "coverage". Can be invoked independently to design or review a testing strategy.
- Analyzes codebase for test coverage gaps
- Designs test plan per the TESTING_STRATEGY methodology
- Ensures all 4 test types are represented

### 5.6 Workflow: Documentation Maintenance

Triggered when user says "docs" or "documentation". Can be invoked independently to update documentation.
- Scans for undocumented decisions, features, or changes
- Updates ADRs, specs, test plans
- Ensures docs/ is current

## 6. Agent Definitions

### 6.1 Multi-Agent Consensus Protocol

Every phase follows this protocol.

**Isolation mechanism:** Each agent is dispatched via the `Agent` tool as a separate subprocess. Multiple agents are dispatched in a single message (parallel `Agent` tool calls), which means they execute concurrently with independent contexts. No agent can see another agent's output. The orchestrating skill (running in the main session) collects all agent outputs and combines them for the discussion round.

**Issue validity:** An issue is "valid" if it identifies a concrete problem that would cause incorrect behavior, violate a stated requirement, break a coding standard, or create technical debt. An issue is "invalid" if it is cosmetic preference, already addressed by existing design decisions, out of scope for the current task, or a duplicate of another issue. The orchestrating skill makes this determination by reasoning about each issue against the requirements and standards.

**Termination guarantee:** The resolution loop has a **maximum of 5 iterations**. If the loop does not converge to zero issues within 5 iterations, the remaining issues are escalated to the user with full context (what was tried, why it didn't converge). The user decides whether to accept the current state, provide guidance, or extend the loop.

```
1. INDEPENDENT ANALYSIS
   - Dispatch 3+ agents in parallel via Agent tool (concurrent, isolated)
   - Each agent produces findings from their perspective
   - No agent sees another agent's output (enforced by subprocess isolation)

2. DISCUSSION ROUND
   - Orchestrator collects all agent outputs
   - Combines findings, identifies conflicts, gaps, and issues
   - Each issue is tagged with severity and the agent that raised it

3. ISSUE RESOLUTION LOOP (max 5 iterations)
   - For each valid issue:
     a. Dispatch agents in parallel to propose solutions with reasoning
     b. Orchestrator evaluates proposals and selects best by reasoning quality
     c. Apply selected solution
   - If zero valid issues remain → proceed to step 4
   - If iteration limit (5) reached → escalate to user

4. FINAL CONFIRMATION ROUND
   - Dispatch all agents in parallel for one final review
   - Each confirms zero valid issues from their perspective
   - If ANY agent finds a new issue → back to step 3 (counts toward iteration limit)
   - Only proceed when ALL agents confirm zero issues
```

### 6.2 Agent Specifications

**requirements-analyst**
- Perspective: User/business needs
- Focuses on: Use cases, edge cases, user stories, acceptance criteria
- Checks: Completeness, clarity, testability of requirements

**architect**
- Perspective: System design and structure
- Focuses on: Component boundaries, data flow, dependencies, patterns
- Checks: Scalability, maintainability, consistency with existing architecture

**test-strategist**
- Perspective: Quality and verification
- Focuses on: Test coverage, test types, risk areas, edge cases
- Checks: Testability, coverage targets, test plan completeness

**code-quality-reviewer**
- Perspective: Code standards compliance
- Focuses on: Result pattern, early exit, file size, naming, structure
- Checks: All standards from docs/standards/

**observability-reviewer**
- Perspective: Operational visibility
- Focuses on: Logging, tracing, metrics, error reporting, correlation IDs
- Checks: Telemetry completeness, log quality, trace coverage

**performance-reviewer**
- Perspective: Runtime efficiency
- Focuses on: Time complexity, memory usage, network calls, bundle size
- Checks: Performance budgets, unnecessary work, optimization opportunities

## 7. Standards (Language-Agnostic)

### 7.1 Result Pattern
All operations that can fail return a uniform Result type containing either a success value or a structured error. No exceptions for flow control. See `docs/standards/RESULT_PATTERN.md`.

### 7.2 Early Exit
Functions validate preconditions first and return/throw immediately on failure. Happy path is never nested inside conditionals. See `docs/standards/EARLY_EXIT.md`.

### 7.3 Error Handling
Errors are categorized (user error, system error, external error). Each category has defined handling behavior. Error context preserved through the call chain. See `docs/standards/ERROR_HANDLING.md`.

### 7.4 Observability
Every operation must be traceable. Structured logging with correlation IDs. Metrics for key operations. Health checks. See `docs/standards/OBSERVABILITY.md`.

### 7.5 Performance
Define performance budgets per project. Measure before optimizing. No premature optimization, but no lazy algorithms either. See `docs/standards/PERFORMANCE.md`.

### 7.6 Code Quality
- Files: Max 200 lines (prefer smaller)
- Functions: Max 30 lines (prefer smaller)
- One responsibility per file/function
- Descriptive naming (no abbreviations)
- Test coverage: >= 90% **branch coverage** (the required metric across all projects)
- All 4 test types mandatory (definitions below). During `/dev-init`, the meaning of each type is mapped to the project's context:
  - **Unit tests:** Test a single function/module in isolation. External dependencies are mocked.
  - **Integration tests:** Test multiple modules working together. May use real databases or services.
  - **Smoke tests:** Minimal tests that verify the system starts, critical paths respond, and basic operations succeed. Run first in CI.
  - **E2E tests:** Test complete user workflows through the actual interface (UI, CLI, API). For libraries without a deployment target, E2E tests exercise the public API surface with real inputs/outputs.
See `docs/standards/CODE_QUALITY.md`.

## 8. Documentation Standards

### 8.1 Decision Documentation
Every architectural or design decision gets an ADR (Architecture Decision Record). ADRs are immutable once their status is set to "Accepted" (which happens after the Phase 2 final confirmation round, or after the user gate in Phase 3 for planning decisions). New decisions supersede old ones by referencing the superseded ADR's ID in a `supersedes: ADR-NNN` field in the new ADR's frontmatter. The superseded ADR's status changes to "Superseded by ADR-NNN". See `docs/templates/ADR_TEMPLATE.md` for required fields.

### 8.2 Directory Separation
Documentation lives in `docs/` adjacent to but separate from source code. Documentation is maintained as part of the development cycle, not as an afterthought.

### 8.3 Templates
All documentation follows templates defined in `docs/templates/`. Templates ensure consistency across projects and features.

## 9. Integration Points

| Superpowers Skill | When Invoked | Purpose |
|---|---|---|
| `superpowers:brainstorming` | Phase 2 (Architecture) | Design exploration |
| `superpowers:writing-plans` | Phase 3 (Planning) | Structured plan creation |
| `superpowers:test-driven-development` | Phase 5 (Implementation) | TDD workflow |
| `superpowers:executing-plans` | Phase 5 (Implementation) | Plan execution |
| `superpowers:verification-before-completion` | Phase 6 (Verification) | Pre-completion checks |
| `superpowers:requesting-code-review` | Phase 6 (Verification) | Final code review |
| `superpowers:dispatching-parallel-agents` | All phases | Parallel agent dispatch |
| `superpowers:systematic-debugging` | As needed | Bug investigation |

## 10. Success Criteria

- Plugin installs and is discoverable globally
- `/dev` is the single entry point that routes to all workflows
- `/dev` orchestrates the full 7-phase workflow for feature development
- The skill can invoke superpowers skills
- Agents produce independent, reasoned analysis
- Discussion/resolution loops converge to zero issues (within 5 iterations)
- Standards are enforced during review phases
- Documentation is produced alongside code
- Test branch coverage meets 90% threshold
- All 4 test types are implemented per feature

## 11. Decisions Made

| Decision | Choice | Reasoning |
|---|---|---|
| Framework format | Claude Code Plugin | Integrates with existing skill ecosystem |
| Location | Standalone git repo | Version controlled, shareable |
| Language specificity | Fully generic | Reusable across any stack |
| Agent rigor | Full rigor always | Move slow, do it right |
| Interaction model | Interactive phases 1-3, autonomous 4-7 | User controls decisions, AI executes |
| Superpowers integration | Orchestrator pattern | Don't reinvent, wrap and enhance |
| Coverage metric | Branch coverage | Most meaningful measure of test thoroughness |
| Loop termination | Max 5 iterations + escalation | Prevents infinite loops while maintaining rigor |
| Code review placement | Phase 6 (Verification) | Code review is a verification activity, not documentation |
