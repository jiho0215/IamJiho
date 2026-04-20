---
name: dev
version: 2.0.0
description: "AI-led, end-to-end development workflow with multi-agent consensus reviews, freeze-doc-enforced research/execution boundary, and two user approval gates. Use when the user wants to build a feature, fix a bug via research-plan-execute, initialize a project, review code, plan tests, or maintain docs. Supports interactive (default) and autonomous (--autonomous TICKET) modes under one command. Also trigger on: '/dev', 'implement this feature', 'build end-to-end', 'research and plan', 'take this ticket and run with it', 'autonomous implementation', or any request for structured multi-phase development."
---

# `/dev` — Unified Development Framework

You are orchestrating one rigorous, multi-agent development cycle for this user. This is the **only** workflow this plugin offers. Move slow, do it right. Reduce revisits and refactoring.

The plugin's purpose: AI leads development from initial requirement to deployment-ready change. The user answers questions, discusses, confirms at two gates, and completes. Every skill, protocol, and hook in this plugin exists to serve that single workflow.

## Invocation Modes

Parse `$ARGUMENTS`. Route to the first matching branch:

| Args match | Mode | Section |
|---|---|---|
| `--status` | Show session status and exit | see Status below |
| `--from N` (with TICKET or feature) | Resume at phase N | see Resume below |
| `--autonomous TICKET` or `-a TICKET` | Autonomous full cycle | Section B |
| `init` keyword, or no project files in cwd | Initialize project | Section A |
| `review` keyword | Standalone review | Section C |
| `test` keyword (or `coverage`) | Standalone test planning | Section D |
| `docs` keyword (or `documentation`) | Standalone docs maintenance | Section E |
| Feature description (any other non-empty) | Interactive full cycle | Section B |
| Empty args | Ask user which mode, then route | — |

## Pre-Workflow (runs for every mode)

Before entering any section, execute these steps in order:

1. **Ensure config** — `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/ensure-config.sh` (idempotent; creates `~/.claude/autodev/config.json` with defaults if absent). This is the single source of truth for the default config schema.
2. **Load session reference** — read `references/autonomous/session-management.md` into working context; you will need the session-folder algorithm and schemas.
3. **Resolve session folder** — follow the algorithm in `references/autonomous/session-management.md`. Result: `SESSION_DIR`.
4. **Chronic patterns** — already loaded by the SessionStart hook (`load-chronic-patterns.sh`). No action needed here unless resuming (see Resume handling).

The resolved `SESSION_DIR` path stays the same across invocations on the same repo+branch, so interactive and autonomous runs share state naturally.

## Companion References (read on demand)

Read these internal references into context when the current phase needs them. They are not external skills; invoke with your Read tool.

| Reference | When to read |
|---|---|
| `references/autonomous/session-management.md` | Always (Pre-Workflow step 2) |
| `references/autonomous/review-loop-protocol.md` | Phase 3 self-review, Phase 5 Layer 1 review, Phase 6 Layer 2 review |
| `references/autonomous/mistake-tracker-protocol.md` | Phase 7 mistake capture |
| `references/protocols/multi-agent-consensus.md` | Any phase that dispatches multiple review/plan agents |
| `references/protocols/project-docs.md` | Phase 7 docs update, Section A init, Section E |
| `references/protocols/test-planning.md` | Phase 4 |
| `references/methodology/DECISION_MAKING.md` | Issue validity judgement |
| `references/methodology/TESTING_STRATEGY.md` | Phase 4 |
| `references/methodology/DOCUMENTATION_STANDARDS.md` | Phase 7, Section E |
| `references/methodology/DEVELOPMENT_CYCLE.md` | Overview / refresher |
| `references/standards/*` | Phase 5 implementation, Phase 5/6 reviews |
| `references/templates/FREEZE_DOC_TEMPLATE.md` | Phase 3 assembly |
| `references/templates/ADR_TEMPLATE.md` | Phase 2 architecture |
| `references/templates/TEST_PLAN_TEMPLATE.md` | Phase 4 |
| `references/templates/FEATURE_SPEC_TEMPLATE.md` | Phase 1 |
| `references/templates/CODE_REVIEW_CHECKLIST.md` | Section C |

## Multi-Agent Consensus (the engine)

Every phase that runs parallel agents uses the protocol in `references/protocols/multi-agent-consensus.md`. Default parameters apply unless a phase overrides them:

- `agents: 3`
- `max_iterations: 10` (from `config.pipeline.maxReviewIterations`)
- `zero_threshold: 2` (from `config.pipeline.consecutiveZerosToExit`)

Never short-circuit the loop. Fixing issues without re-dispatching agents is NOT a zero-issue round (see the Critical Rule in the consensus protocol).

---

## Section A: Init Workflow

For new or uninitialized projects. **Apply the session collision guard from Section C before proceeding** — initializing a project while a full-cycle session is active would overwrite `docs/` scaffolding and session state.

1. Read `references/protocols/project-docs.md`. Verify/scaffold `docs/` structure (`adr/`, `specs/`, `test-plans/`, `decisions.md`).
2. Ask the user for: project name, language/framework, test runner, linter, performance budgets (or accept defaults from `references/standards/PERFORMANCE.md`), existing conventions.
3. Explore the project directory for existing files to auto-detect language/framework.
4. Create directory structure: `tests/` (or framework equivalent), `src/` (or equivalent).
5. Create CLAUDE.md with project-specific configuration referencing the generic standards from `references/standards/`.
6. Create ADR-001 (Project Setup) using `references/templates/ADR_TEMPLATE.md`.
7. Set up test configuration for the detected test runner.
8. Map generic standards to concrete implementations:
   - **Result pattern** — generate a language-specific Result type (read `references/standards/RESULT_PATTERN.md`).
   - **Test types** — map Unit/Integration/Smoke/E2E to the project's testing tools.
   - **Observability** — map to the project's logging/tracing libraries.
9. **Validate scaffolded output.** Read `references/protocols/multi-agent-consensus.md` and run the protocol with:
   - `task_type: validate`
   - `agents_list: [code-quality-reviewer, architect, requirements-analyst]`
   - Context: "Validate all scaffolded files against the actual codebase. Flag any aspirational documentation that contradicts the current code."
10. Confirm initialization complete. Tell the user: "Type `/dev [feature description]` to begin the full development cycle for your first feature."

---

## Section B: Full Development Cycle

**Prerequisite:** Pre-Workflow steps must have run. Read `references/protocols/project-docs.md` and verify `docs/` structure exists before Phase 1 (scaffold if missing).

### Mode Difference (Interactive vs Autonomous)

| Aspect | Interactive (default) | Autonomous (`--autonomous TICKET`) |
|---|---|---|
| Initial input | Feature description from user | JIRA ticket fetched/described |
| Phase 1-3 dialogue | User answers questions synchronously | LLM synthesizes best-guess answers, logs decisions to decision-log |
| GATE 1 (Phase 3 end) | User approves freeze doc | Freeze doc auto-APPROVED with `approvalMode: autonomous` audit |
| GATE 2 (Phase 7 end) | User approves final state | **Always user-interactive** (push is too consequential to automate) |
| freeze-gate hook | Active | Active |
| push-guard hook | Active | Active |

The phase structure and review loops are identical across modes. Only user interaction points differ.

### Session Initialization (both modes)

Before Phase 1:

1. Create `SESSION_DIR/progress-log.json` with:
   - `schemaVersion: 1`
   - `ticket` (autonomous) or `featureSlug` (interactive; derived from description)
   - `repo`, `branch`
   - `runId` (per `references/autonomous/session-management.md`)
   - `mode: "full-cycle"`
   - `approvalMode: "interactive" | "autonomous"`
   - `freezeDocPath: "docs/specs/[feature-slug]-freeze.md"` (set at Phase 3 completion; null initially)
   - `plannedFiles: []` (populated at Phase 3 completion)
   - `startedAt: <ISO-8601 UTC>`
   - `status: "in-progress"`
   - `configSnapshot: { maxReviewIterations, consecutiveZerosToExit, testCoverageTarget }`
   - `phases: []`
2. Create `SESSION_DIR/decision-log.json` (empty `decisions: []`).
3. Create `SESSION_DIR/pipeline-issues.json` (empty `runs: []`, append current runId).
4. Run `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh verify` — aborts if progress-log.json is broken.

### Decision Logging

After each consensus round or user decision, append to `SESSION_DIR/phase-{N}-decisions.jsonl` (one JSON object per line). At end of each phase, merge JSONL into `decision-log.json` and delete the JSONL. Also call `project-docs` (read the protocol reference) to append significant decisions to `docs/decisions.md`.

### Freeze Doc Draft

Start writing `docs/specs/[feature-slug]-freeze.md` during Phase 1. Open in DRAFT status. Each phase populates its assigned categories:
- **Phase 1** → §1 Business Logic, §5 Error Model, §6 Acceptance Criteria.
- **Phase 2** → §2 API Contracts, §3 3rd Party, §4 Data, §7 Security, §8 Performance.
- **Phase 3** → §9 Non-Frozen Questions (from config), final cross-category validation, bump status to `PENDING_APPROVAL`.

Use the template in `references/templates/FREEZE_DOC_TEMPLATE.md`. Category names and allow-list entries come from `config.pipeline.freezeDoc.categories` and `config.pipeline.freezeDoc.nonFrozenAllowList`.

**Custom category rendering:** after rendering the 8 required sections, iterate over any entries in `config.pipeline.freezeDoc.categories` that are not in the default 8. For each custom entry `X`, read the section template from `{config.pipeline.freezeDoc.customCategoryTemplatesDir}/{X}.md` and append it as an additional `§` section (numbered 10+). Also append the entry to the freeze doc frontmatter `customCategories` array. If the template file is missing, log a warning and fall back to a stub section `## § NN. {X} (TEMPLATE MISSING)` so the omission is visible during GATE 1.

### Phase 1 — Requirements

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 1`

Mode-sensitive:
- **Interactive:** gather requirements via one-at-a-time questions. Use clarifying dialogue until scope is understood. Invoke the skill named by `config.pipeline.skills.requirements` (default `superpowers:brainstorming`) via the Skill tool.
- **Autonomous:** read the ticket content. Extract requirements, acceptance criteria, and constraints. Log any assumptions to `decision-log.json` category `autonomous-inference`.

After gathering (both modes), run the consensus protocol (`references/protocols/multi-agent-consensus.md`):
- `task_type: validate`
- `agents_list: config.pipeline.agents.plan` (default `[requirements-analyst, architect, test-strategist]`)
- Context: "Validate that requirements are complete, unambiguous, and testable."

Produce/update `docs/specs/[feature-slug]-requirements.md`. Populate freeze doc §1, §5, §6.

**Update:** `progress-log.json` (append phase entry with status `completed`, `completedAt`, metrics).
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 1`
**Banner:** `--- Phase 1 Complete: Requirements ---`

### Phase 2 — Research (Codebase + Architecture)

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 2`

1. Invoke the skill named by `config.pipeline.skills.exploration` (default `feature-dev:code-explorer`). Trace execution paths related to the feature area, map architecture layers, document dependencies and integration points, identify conventions the new code must follow.
2. Invoke the skill named by `config.pipeline.skills.architect` (default `feature-dev:code-architect`). Design the feature architecture based on exploration findings.
3. Run the consensus protocol (`references/protocols/multi-agent-consensus.md`):
   - `task_type: plan`
   - `agents_list: config.pipeline.agents.plan`
   - Context: "Validate architecture design against requirements and existing codebase conventions."
4. Produce ADR(s) using `references/templates/ADR_TEMPLATE.md`. Write to `docs/adr/ADR-NNN-[title].md`.
5. **Populate freeze doc §2–§4, §7, §8:**
   - **§2 API Contracts:** observed conventions → "Conventions Followed"; new endpoints with concrete schemas; any deviation from existing patterns goes in "Proposed Deviations" with rationale.
   - **§3 3rd Party:** every external API — payload shape, rate limit, retry policy, cache TTL, secret storage.
   - **§4 Data & Database:** schema changes (DDL), enums with values/defaults, forward and rollback migration, backfill plan.
   - **§7 Security/Auth:** authZ model, sensitive data rules, identified threats and mitigations.
   - **§8 Performance:** measurable budgets (p95/p99 latency, throughput, query count, memory).

**Update:** progress-log.json.
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 2`
**Banner:** `--- Phase 2 Complete: Research ---`

### Phase 3 — Plan + Freeze Doc Assembly → GATE 1

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 3`

1. Read `references/autonomous/review-loop-protocol.md` into context.
2. Invoke the skill named by `config.pipeline.skills.planning` (default `superpowers:writing-plans`). Generate a structured implementation plan with bite-sized tasks.
3. Populate freeze doc §9 from `config.pipeline.freezeDoc.nonFrozenAllowList`.
4. Run consensus protocol:
   - `task_type: plan`
   - `agents_list: config.pipeline.agents.plan`
   - Context: "Verify that the plan covers all acceptance criteria, aligns with frozen architecture, and is testable."
5. **Self-review loop** (per review-loop-protocol.md) — run in self-review mode over the plan and freeze doc. Fix any issues. Inject chronic patterns as prevention checklist.
6. Populate `progress-log.json`:
   - `freezeDocPath: "docs/specs/[feature-slug]-freeze.md"`
   - `plannedFiles: [...]` (from the plan)
   - `featureSlug: "[feature-slug]"`
7. Bump freeze doc `status: PENDING_APPROVAL`, record `createdAt` in frontmatter.

**GATE 1 — Freeze Doc Approval** (mode-sensitive):

**Interactive mode:**
Present the complete freeze doc to the user with a category-by-category summary. Prompt for one of:
- `[1] Approve all` — proceed.
- `[2] Reject category X` — reopen that category (return to Phase 1 for §1/§5/§6 or Phase 2 for §2/§3/§4/§7/§8) and re-run the relevant review loops on return.
- `[3] Inline edit` — modify specific items, then present again.

On approval:
- Set freeze doc frontmatter: `status: APPROVED`, `approvedAt: <ISO UTC>`, `approvedBy: <user email or identifier>`, `approvalMode: interactive`.
- Append decision to `decision-log.json` category `gate-1`.

**Autonomous mode:**
- Set freeze doc frontmatter: `status: APPROVED`, `approvedAt: <ISO UTC>`, `approvedBy: "autonomous"`, `approvalMode: autonomous`.
- Append audit decision to `decision-log.json` explaining the autonomous approval and listing any uncertainty flagged during Phase 1-3.
- Continue to Phase 4.

**Update:** progress-log.json (phase 3 complete with review metrics — iterations, issues fixed, final issue count).
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 3`
**Banner:** `--- Phase 3 Complete: Plan + Freeze Doc --- GATE 1: {mode}-approved | Iterations: {N} | Issues fixed: {M} ---`

After this point, **the freeze-gate hook is active**: any attempt to edit `src/`, `lib/`, or `app/` files (excluding tests) will be blocked unless the freeze doc is `APPROVED` and the current branch matches the session.

### Phase 4 — Test Planning

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 4`

1. Invoke the skill named by `config.pipeline.skills.tdd` (default `superpowers:test-driven-development`) to establish TDD methodology.
2. Read `references/protocols/test-planning.md` into context. Apply it using inputs from Phase 1-3 artifacts in `SESSION_DIR`.
3. Read `references/methodology/TESTING_STRATEGY.md` for coverage requirements.
4. Produce layered test plan (Layer 0 data pipeline, Layer 1 cross-validation, Layer 2 per-feature by event type) using `references/templates/TEST_PLAN_TEMPLATE.md` and the layout in the test-planning protocol.
5. Coverage target: `config.pipeline.testCoverageTarget` (default 90) percent branch coverage.
6. Map tests to acceptance criteria (traceability matrix).
7. Write to `SESSION_DIR/tdd-plan.md` and `docs/test-plans/[feature-slug]-test-plan.md`.

**Update:** progress-log.json.
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 4`
**Banner:** `--- Phase 4 Complete: Test Planning ---`

### Phase 5 — Implementation + Layer 1 Review

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 5`

**Execution rules (ALL of Phase 4-7):**
- Freeze doc §1-§8 are immutable truth source. Any question that would change them triggers **workflow halt** and a "freeze doc update needed" message to the user.
- Zone 2 (Non-Frozen list, freeze doc §9) questions may be asked to the user.
- Zone 3 (Ambiguous) questions follow the 4-tier rule in freeze doc §9: existing code → follow silently (ask on deviation); reference repo → same; initial implementation → ask liberally; otherwise → self-decide via standards.
- Zone 4 (pure technical: naming, extraction, internal boundaries) → self-decide without asking.
- Use the "Ask with Suggestion" format (freeze doc §9) when asking.

**Implementation:**
1. Invoke the default implementation skill: `config.pipeline.skills.implementation` (default `superpowers:subagent-driven-development`). Alternative skills:
   - Sequential plan execution: `config.pipeline.skills.implementationSequential`.
   - Parallel independent subtasks: `config.pipeline.skills.implementationParallel`.
   Choose based on plan structure.
2. Reference `SESSION_DIR/tdd-plan.md` for test strategy. Follow TDD: write failing test → implement minimum to pass → refactor.
3. On any bug or unexpected failure, invoke `config.pipeline.skills.debugging` (default `superpowers:systematic-debugging`) before attempting fixes. Root cause first.

> **Observability note — Agent-dispatched edits:** when implementation runs via the Agent tool (subagent-driven or parallel-agent modes), `Edit`/`Write` tool calls made by sub-agents fire `freeze-gate.sh` inside the sub-agent's sandboxed context. The hook's exit-2 block messages surface back only as a generic "tool call failed" signal to the orchestrator, not as a structured gate diagnostic. If an Agent tool reports an edit failure in `src/**`, inspect `SESSION_DIR/bypass.json` and the freeze doc status directly (or run `/dev --status`) before assuming a code error — the failure may be a legitimate gate block.

**Layer 1 Review (mandatory):**

Read `references/autonomous/review-loop-protocol.md`. Run the protocol over the implemented code:

1. Invoke `config.pipeline.skills.requestReview` (default `superpowers:requesting-code-review`) to prepare the review request.
2. Run consensus protocol (`references/protocols/multi-agent-consensus.md`):
   - `task_type: validate`
   - `agents_list: config.pipeline.agents.review` (default `[code-quality-reviewer, performance-reviewer, observability-reviewer]`)
   - `max_iterations: config.pipeline.maxReviewIterations` (default 10)
   - `zero_threshold: config.pipeline.consecutiveZerosToExit` (default 2)
3. Invoke `config.pipeline.skills.receiveReview` (default `superpowers:receiving-code-review`) — evaluate findings rigorously; no performative agreement; reasoned pushback on invalid findings (per `references/methodology/DECISION_MAKING.md`).
4. Fix valid issues, re-dispatch for verification. Do NOT declare convergence without re-validation (see Critical Rule in consensus protocol).
5. If not converged within `max_iterations`, escalate remaining issues to the user.

Log decisions, persist issues to `pipeline-issues.json`, merge `phase-5-decisions.jsonl`, update markdown.

**Update:** progress-log.json with review metrics.
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 5`
**Banner:** `--- Phase 5 Complete: Implementation --- Rounds: {N} | Issues fixed: {M} ---`

### Phase 6 — Verification + Coverage Fill + Layer 2 Review

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 6`

1. Run all tests (unit, integration, smoke, E2E). All must pass.
2. Measure branch coverage. Compare against `config.pipeline.testCoverageTarget`.
3. If below target: use `config.pipeline.skills.tdd` to write additional tests targeting uncovered branches (RED-GREEN-REFACTOR cycle). Re-run all tests, verify green.
4. Invoke `config.pipeline.skills.verification` (default `superpowers:verification-before-completion`) — confirm each acceptance criterion with evidence before continuing.
5. **Layer 2 Review** (same mechanics as Layer 1):
   - Read `references/autonomous/review-loop-protocol.md`.
   - Run consensus protocol with `agents.review`, `max_iterations: config.pipeline.maxReviewIterations` (default 10), `zero_threshold: config.pipeline.consecutiveZerosToExit` (default 2).
   - Context: final validation — integration-level consistency, test-to-requirement traceability, performance budget adherence, standards compliance.
   - Invoke `config.pipeline.skills.receiveReview` to evaluate rigorously.
6. Fix valid issues, re-validate. If not converged, escalate to user.
7. Verify frozen-category integrity: scan code + tests for any decision that drifted from freeze doc §1-§8. If drift detected, halt and offer [1] update freeze doc via supersede, [2] revert to freeze doc, [3] bypass.

Log decisions, persist issues, merge JSONL, update markdown.

**Update:** progress-log.json with review metrics.
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 6`
**Banner:** `--- Phase 6 Complete: Verification --- Coverage: {N}% | Rounds: {M} | Issues fixed: {K} ---`

### Phase 7 — Documentation + Mistake Capture → GATE 2

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 7`

**Documentation:**
1. Read `references/protocols/project-docs.md`.
2. Update/create ADRs for any Phase 5-6 decisions that deviated from Phase 2 (supersede the prior ADR per the ADR lifecycle in `references/methodology/DECISION_MAKING.md`).
3. Update `docs/specs/[feature-slug]-requirements.md` to reflect final implementation.
4. Update `docs/test-plans/[feature-slug]-test-plan.md` with actual coverage numbers and test inventory.
5. Append freeze doc as a permanent record; do not delete.
6. Scope boundary: Phase 7 only **documents** what was built. It does not introduce features, refactor code, or change behavior. Implementation gaps become follow-up tasks.

**Mistake Capture:**
7. Read `references/autonomous/mistake-tracker-protocol.md`.
8. Follow the protocol:
   - Check idempotency via Run Log; if runId already aggregated, skip.
   - Aggregate Phase 5 + Phase 6 code issues (not Phase 3 design issues).
   - Match against existing patterns; increment frequency or create new patterns.
   - Promote at frequency ≥ `config.pipeline.chronicPromotionThreshold` (default 3) — write prevention strategy.
   - Enforce hard cap `config.pipeline.maxActivePatterns` (default 20).
   - Sync CLAUDE.md chronic patterns between sentinel markers (atomic write with backup).
   - Append runId to Run Log.
   - Log pattern promotions/demotions to `decision-log.json` category `pattern`.

**GATE 2 — Final Approval** (always user-interactive, both modes):

Present:

```
Feature: [feature-slug] — Final Approval
────────────────────────────────────────────────────────
Tests:        {passed}/{total} passed
Coverage:     {N}% branch (target: {target}%)
Code Review:
  Layer 1 (Phase 5): {agents} agents, {rounds} rounds, {issues} issues fixed
  Layer 2 (Phase 6): {agents} agents, {rounds} rounds, {issues} issues fixed
  Remaining:    {N} issues (must be 0 to approve [1] or [3])
Standards:    {pass/fail summary}
Docs updated: {list}
Files changed: {N} ({src}/{tests})
Frozen decisions honored: {N}/{N}
Bypasses used: {N}
Chronic patterns prevented: {N}
Duration: {minutes}
────────────────────────────────────────────────────────
Options:
  [1] Approve → archive session, allow push
  [2] Reject → list issues to fix (returns to Phase 5 or 6 per user choice)
  [3] Approve + commit + push
```

On approval (option 1 or 3), execute this sequence in order. **If any step fails, halt and report the specific error to the user — do NOT proceed to later steps. Log the failure to `decision-log.json` category `gate-2` with `failed: true` and the error details so the session is resumable via `--from 7`.** The entire archival + cleanup sequence is idempotent (dedup by `at` and filter by `runId`), so a resumed Phase 7 safely re-runs any completed portion.

1. **Bypass archival — GATE 2 is the sole writer of freeze doc `bypassHistory`.** Collect bypass records from both sources, normalizing each to the `bypassHistory` entry schema `{ at, reason, feature, userMessage, runId, preservedAt? }`:
   - `bypass.json` (current live bypass, if any). **Field mapping:** use `bypass.json.createdAt` as the `at` value; inject `runId` from `progress-log.json` (bypass.json does not carry runId); `preservedAt` is absent (this is the direct-from-bypass path, not the crash-preservation path).
   - `bypass-audit.jsonl` (preserved by `sessionend.sh` on prior crash/interrupt within this run). These already use `at` and carry `runId` and `preservedAt` written by sessionend.
   For each normalized record, dedup by `at` against existing `bypassHistory` entries. Filter `bypass-audit.jsonl` entries by `runId` matching the current `runId` in `progress-log.json` before merging — entries from prior runs on the same branch must not be imported. **If the freeze doc is unwritable (read-only, lock contention, missing parent directory), halt per the failure rule above.**

2. **Bypass cleanup:** after archival succeeds, delete `SESSION_DIR/bypass.json`. Do not delete `bypass-audit.jsonl` — it is preserved for cross-run audit. The bypass lifecycle ends here.

3. **Write completion marker:** write `SESSION_DIR/pipeline-complete.md` containing exactly:
   ```
   Pipeline completed for branch: {original unsanitized branch name}
   Date: {ISO UTC}
   Feature: {feature-slug}
   ```
   This marker authorizes `push-guard.sh` to allow `git push` on this branch. It is written **after** archival and cleanup so the marker only exists in a fully-consistent state.

4. **Finalize progress log:** set `progress-log.json` `status: "completed"`, `completedAt: <ISO UTC>`, final `currentPhase: 7`, and summary totals.

5. **On option 3:** invoke `config.pipeline.skills.finishing` (default `superpowers:finishing-a-development-branch`) — stage, commit, push.

On rejection (option 2):
- User indicates which phase to return to; set `progress-log.json` `status: "in-progress"`, reset `currentPhase` accordingly.
- Re-enter that phase.

**Update:** progress-log.json.
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 7`
**Banner:** `--- Phase 7 Complete: Documentation + Capture --- GATE 2: approved | Total: {minutes}min | Decisions: {N} ---`

---

## Section C: Standalone Review

Runs without a full cycle. Use when the user says `review`.

**Session collision guard (applies to Sections A, C, D, E):** Before creating or writing any session state, if `SESSION_DIR/progress-log.json` already exists, read it. If its `mode` is `full-cycle` and `status` is `in-progress`, `interrupted`, or `failed`, **halt** and present the user with:
```
⚠️  A full-cycle /dev session exists on this branch ({featureSlug}, Phase {N}, status={status}).
Running standalone '{init|review|test|docs}' here will overwrite the full-cycle session state,
making it unresumable. If status is 'failed' or 'interrupted', resume via /dev --from {N} instead.
  [1] Abort this standalone run
  [2] Overwrite and proceed (full-cycle state will be lost)
  [3] Switch branch before continuing
```
Do not proceed without explicit confirmation.

1. Read `references/protocols/multi-agent-consensus.md` and `references/methodology/DECISION_MAKING.md`.
2. Create `SESSION_DIR/progress-log.json` with `mode: "review"` so the freeze-gate hook knows this is not a full cycle.
3. Run consensus protocol:
   - `task_type: validate`
   - `agents_list: config.pipeline.agents.review`
   - `max_iterations: config.pipeline.maxReviewIterations` (default 10)
   - `zero_threshold: config.pipeline.consecutiveZerosToExit` (default 2)
4. Each agent reads the relevant standards from `references/standards/`.
5. Produce a review report using `references/templates/CODE_REVIEW_CHECKLIST.md`, with findings, severity, and recommended fixes.
6. Set `progress-log.json` `status: "completed"`, `completedAt: <ISO UTC>`.

---

## Section D: Standalone Test Planning

Use when the user says `test` or `coverage`. Apply the session collision guard from Section C before proceeding.

1. Create `SESSION_DIR/progress-log.json` with `mode: "test"`.
2. Read `references/methodology/TESTING_STRATEGY.md` and `references/protocols/test-planning.md`.
3. Analyze the codebase for test coverage gaps.
4. Design or update the test plan ensuring all 4 test types are represented.
5. Verify branch coverage target (`config.pipeline.testCoverageTarget`, default 90%).
6. Run consensus protocol with `agents.plan`.
7. Produce `docs/test-plans/[feature-or-scope]-test-plan.md` using `references/templates/TEST_PLAN_TEMPLATE.md`.
8. Mark session completed.

---

## Section E: Standalone Documentation

Use when the user says `docs` or `documentation`. Apply the session collision guard from Section C before proceeding.

1. Create `SESSION_DIR/progress-log.json` with `mode: "docs"`.
2. Read `references/methodology/DOCUMENTATION_STANDARDS.md` and `references/protocols/project-docs.md`.
3. Run the doc hygiene analysis per `project-docs.md` (stale/redundancy/bloat/accuracy/organization).
4. Update ADRs, specs, test plans. Ensure `docs/` is current.
5. Verify all ADRs follow `references/templates/ADR_TEMPLATE.md`.
6. Mark session completed.

---

## `--status` Handler

1. Resolve `SESSION_DIR`.
2. Read `progress-log.json`, `decision-log.json`. Also read the freeze doc (if `freezeDocPath` is set) and check for `bypass.json` and `pipeline-complete.md`.
3. Output a comprehensive summary for quick diagnosis:
   - Ticket/feature, mode, status, current phase.
   - **If status is `interrupted`:** highlight `interruptedAt` timestamp prominently and include an actionable note: "Session ended mid-run. Use `/dev --from {currentPhase}` to resume. Phase {currentPhase} may be partially complete — review `phase-{N}-decisions.jsonl` if present."
   - Per-phase timing, metrics, decisions count.
   - Last 5 decisions.
   - Config snapshot.
   - **Freeze doc:** path + `status` field (DRAFT / PENDING_APPROVAL / APPROVED / SUPERSEDED) + approvedAt/approvedBy + `approvalMode`.
   - **Bypass:** active yes/no; if yes, show `feature`, `reason`, `createdAt`, `userMessage` from `bypass.json`. Also show count of entries in `bypass-audit.jsonl` and the count in freeze doc `bypassHistory` (if freeze doc exists). If `bypass-audit.jsonl count > bypassHistory count`, annotate with "(N pending merge at GATE 2)" so the operator can distinguish archived vs pending records.
   - **Push-guard state:** `pipeline-complete.md` present yes/no; if no, explain blocking reason (GATE 2 pending vs mid-pipeline vs interrupted).
   - **Session folder:** absolute path so the operator can inspect raw artifacts directly.
   - **freeze-gate state:** whether src/** edits are currently allowed (based on freeze doc status + branch + mode).
4. Exit — do not run the workflow.

## `--from N` Resume

1. Resolve `SESSION_DIR`. Verify it exists.
2. Read `progress-log.json`. Verify the feature/ticket matches.
3. Follow the resume protocol in `references/autonomous/session-management.md`:
   - Detect mid-phase crash (last phase status `in-progress`).
   - Merge any stale `phase-{N}-decisions.jsonl`.
   - Announce caveat: "Resuming from Phase {N}. Phases 1-{N-1} artifacts assumed valid."
4. If the session was interactive and the user is re-entering at Phase 4+ without the freeze doc in APPROVED state → halt and advise completing Phase 3.
5. Run the phase begin gate, then continue at Phase N.

---

## Phase Failure Protocol

When a phase fails:

1. Invoke `config.pipeline.skills.debugging` (default `superpowers:systematic-debugging`). Gather evidence, form hypothesis, test minimally. No guessing.
2. Update `progress-log.json`: phase status `failed`.
3. Persist accumulated issues to `pipeline-issues.json`.
4. Log failure as decision (category: `skip`).
5. Announce:
   ```
   --- Phase {N} FAILED: {phase name} ---
   Error: {description}
   Session: {SESSION_DIR}
   Resume: /dev --from {N} [--autonomous TICKET]
   ```
6. Offer: `[1] Retry this phase` `[2] Skip to next` `[3] Abort workflow`.

**Graceful degradation:** missing config → `ensure-config.sh` creates it (Pre-Workflow step 1). Missing chronic patterns file → empty list. Unavailable configured skill → phase operates without it. The workflow must never fail to start.

## Gate Failure Protocol

When a phase gate blocks (`phase-gate.sh` exit 2), it's a prerequisite violation, not a bug. Do **not** invoke the debugging skill.

1. Read the gate error message — it explains exactly what is wrong.
2. Announce:
   ```
   --- Phase {N} GATE BLOCKED: {gate error summary} ---
   Session: {SESSION_DIR}
   ```
3. Offer, based on gate type:
   - Begin gate (missing progress): `[1] Run Pre-Workflow` `[2] Use --from N` `[3] Abort`.
   - Begin gate (previous phase incomplete): `[1] Complete Phase N-1` `[2] Use --from N to skip` `[3] Abort`.
   - End gate (progress not updated): `[1] Update progress-log.json and retry` `[2] Abort`.
   - Verify gate (session broken): `[1] Delete session folder and restart` `[2] Abort`.

## Bypass Protocol (freeze-gate override)

If the user explicitly asks to bypass the freeze gate (trigger phrases: "bypass freeze", "freeze 무시하고 진행", "freeze 우회", or an explicit sentence with clear intent):

1. Write `SESSION_DIR/bypass.json`:
   ```json
   {
     "createdAt": "<ISO UTC>-<4 hex chars>",
     "reason": "<extracted from user message>",
     "feature": "<progress-log.featureSlug>",
     "scope": "ticket",
     "userMessage": "<verbatim user request>"
   }
   ```
   The 4-hex-char suffix makes `createdAt` a unique event identifier even when multiple bypasses occur within the same second (e.g., `2026-04-19T14:30:00Z-a3f2`). All downstream consumers (`sessionend.sh` dedup, GATE 2 dedup, freeze doc `bypassHistory.at`) use this as the join key; collisions would silently drop audit events.
2. Announce the bypass clearly, including the reason.
3. Log a decision to `decision-log.json` category `bypass` with full fields (reason, feature, at, userMessage, runId) — so the bypass event can be correlated to its run from the decision log alone.
4. Continue work. The bypass remains active for this ticket; Phase 7 GATE 2 is the **sole** writer of freeze doc `bypassHistory` — it merges `bypass.json` + any `bypass-audit.jsonl` entries into `bypassHistory` with dedup. Do not write to `bypassHistory` here (double-write would corrupt the audit trail).

The `freeze-gate.sh` hook reads `bypass.json` and respects it. Do not attempt to silence the hook by any other means.

---

## Cross-Cutting Concerns

### Phase Gates (Mandatory)

Every phase in Section B is bookended by gate calls that enforce progress-map integrity:

- **Begin gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin N` — validates progress-log.json exists, previous phase completed, workflow not already finished.
- **End gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end N` — validates current phase status is `completed`, `completedAt` is set, and progress-log.json is consistent.
- **PostToolUse hook:** after each gate call, `phase-progress-validator.sh` runs automatically (registered in `hooks.json`) to independently validate progress-map consistency.
- **Blocking behavior:** gate scripts exit 2 on validation failure, halting the workflow. The validator hook emits warnings only (exit 0).
- **Execution order:** begin gate BEFORE any phase work. Update progress-log.json DURING the phase. End gate AFTER the update, BEFORE the banner.

### Progress Banners

One-line banner at each phase transition. Include key metrics when available.

### Decision Logging

Per-iteration: append to `SESSION_DIR/phase-{N}-decisions.jsonl` (one JSON line per decision).
At phase end: merge JSONL into `decision-log.json`, delete the JSONL.

### Progress Updates

At phase end: update `progress-log.json` with phase timing, metrics, and decision references.

### Markdown Regeneration

At phase end (not per-iteration): regenerate `decision-log.md` and `progress-log.md` from the JSON source. On generation failure, warn but do not fail the phase. JSON is the source of truth.

### Performance Budgets (config.phases defaults)

| Phase | Budget | Notes |
|-------|--------|-------|
| 1 | 0.5 min | Single API call or short dialogue |
| 2 | 2 min | Codebase scan + architecture design |
| 3 | 10 min | Plan + freeze doc + self-review loop |
| 4 | 2 min | Planning only |
| 5 | 15 min | Varies by complexity; Layer 1 review included |
| 6 | 10 min | Verification + coverage fill + Layer 2 review |
| 7 | 5 min | Docs + mistake capture + GATE 2 |

Budgets are advisory, not enforced by the gate hooks. They calibrate "something is wrong" intuition.
