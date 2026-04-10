---
name: dev-pipeline
version: 1.2.0
description: |
  Autonomous 10-phase development pipeline with cross-session learning.
  Use when: user says "/dev-pipeline", wants autonomous end-to-end ticket implementation,
  or wants a pipeline with JIRA integration, automated reviews, and mistake tracking.
---

# Dev Pipeline

Autonomous 10-phase pipeline: JIRA fetch → codebase prime → plan → TDD → implement → review → test coverage → final review → mistake capture → human gate.

Single human gate at Phase 10. Everything else runs autonomously.

## Companion Skills (invoked automatically per phase)

These superpowers skills are invoked at specific phases. If unavailable, the phase operates without skill-specific guidance.

| Skill | Phase | Purpose |
|-------|-------|---------|
| `superpowers:brainstorming` | 3 | Design exploration before plan creation |
| `superpowers:writing-plans` | 3 | Structured implementation plan |
| `superpowers:test-driven-development` | 4, 7 | TDD methodology for test planning and coverage fill |
| `superpowers:executing-plans` | 5 | Execute plan with review checkpoints |
| `superpowers:subagent-driven-development` | 5 | Parallel task execution with two-stage review |
| `superpowers:dispatching-parallel-agents` | 5 | Independent subtask parallelization |
| `superpowers:requesting-code-review` | 6 | Structured review request to consensus agents |
| `superpowers:receiving-code-review` | 6, 8 | Rigorous evaluation of review feedback |
| `superpowers:verification-before-completion` | 10 | Run verification commands before claiming done |
| `superpowers:finishing-a-development-branch` | 10 | Structured commit/push/PR/discard options |
| `superpowers:systematic-debugging` | Any failure | Root cause investigation before fix attempts |

## Arguments

Parse from `$ARGUMENTS`:
- `TICKET_ID` — required (e.g., `CAOS-1234`)
- `--from N` — resume from Phase N
- `--status` — show current pipeline status and exit

## --status Command

If `--status` requested:
1. Resolve session folder (see `references/session-management.md`)
2. Read `{SESSION_DIR}/progress-log.json`
3. Read `{SESSION_DIR}/decision-log.json`
4. Output summary: status, current phase, phase table with timing/metrics, last 5 decisions, config snapshot
5. **Exit — do not run pipeline.**

---

## Pre-Pipeline

Run these steps before Phase 1. **Skip steps 3-4 if `--from N` is set.**

### 0. Load References
Read these files into context now (used throughout the pipeline):
- `references/session-management.md` — session folders, schemas, resume protocol
- Do NOT read review-loop-protocol.md or mistake-tracker-protocol.md yet (loaded on-demand at Phase 3 and Phase 9)

### 1. Resolve Session Folder
Follow the algorithm in `references/session-management.md`. Result: `SESSION_DIR`.

### 2. Load Config
Read `~/.claude/autodev/config.json`. If missing or malformed, use fallback defaults (see `references/session-management.md` Config Defaults section) and warn.

### 3. Archive Old Runs
If `pipeline-issues.json` has > `maxRunsRetained` runs, move oldest to `pipeline-issues-archive.json`.

### 4. Clean Stale Sessions
Follow cleanup rules in `references/session-management.md`.

### 5. Initialize Session Files
- If `progress-log.json` doesn't exist: create with schemaVersion, ticket, repo, branch, runId, startedAt, configSnapshot, empty phases array.
- If `decision-log.json` doesn't exist: create with schemaVersion, ticket, repo, branch, empty decisions array.
- If `pipeline-issues.json` doesn't exist: create with schemaVersion, empty runs array. Append new run entry with runId.
- If resuming (`--from N`): read existing runId from progress-log.json (do not create new one).

### 6. Load Chronic Patterns
The SessionStart hook provides chronic patterns to ALL sessions (including non-pipeline work). Here, load them explicitly for pipeline use — this is intentionally not deduplicated because the hook covers broad sessions while this step guarantees patterns are available for Phase 3 injection and Phase 8 pre-check.
1. Find `workflow_mistake_patterns.md` in project memory
2. If missing: CHRONIC_PATTERNS = [], log warning, continue
3. Parse "## Chronic Patterns" table rows matching '| P[0-9]'
4. Extract: id, pattern, category, frequency, prevention_strategy
5. Announce: "Loaded {N} chronic patterns for proactive prevention"

### 7. Resume Handling (if --from N)
Follow resume protocol in `references/session-management.md`. Detect mid-phase crashes, merge stale JSONL, announce caveat.

---

## Phase 1: JIRA Fetch

Invoke `config.phases["1"].skill` (default: `/essentials-jira`) via the Skill tool with the TICKET_ID.

**Output:** Ticket requirements in session folder.
**Update:** progress-log.json (phase 1 complete).
**Banner:** `--- Phase 1 Complete: JIRA Fetch ---`

## Phase 2: Codebase Prime

Invoke `config.phases["2"].skill` (default: `/essentials-prime`).

**Output:** Codebase context loaded.
**Update:** progress-log.json.
**Banner:** `--- Phase 2 Complete: Codebase Prime ---`

## Phase 3: Plan & Review

**Load now:** Read `references/review-loop-protocol.md` into context.

1. Invoke `superpowers:brainstorming` — explore design approaches, propose 2-3 alternatives, settle on recommended approach.
2. Invoke `config.phases["3"].skill` (default: `/essentials-analyze`) for design analysis.
3. Invoke `superpowers:writing-plans` — generate structured implementation plan with bite-sized tasks.
4. Inject CHRONIC_PATTERNS as a prevention checklist in the plan.
5. **Self-review loop:** Follow `review-loop-protocol.md`. Run in self-review mode.
6. Log plan decisions to decision-log.json (category: "plan").
7. Persist issues to pipeline-issues.json.

**Update:** progress-log.json with review metrics (iterations, issues found/fixed).
**Banner:** `--- Phase 3 Complete: Plan & Review --- Iterations: {N} | Issues fixed: {M} ---`

## Phase 4: TDD Plan

1. Invoke `superpowers:test-driven-development` — establish TDD methodology for the feature.
2. Invoke `dev-framework:test-planning` skill with context from Phases 1-3 (ticket requirements, codebase architecture, implementation plan).

The test-planning skill generates a layered test plan with:
- Layer 0 (data pipeline), Layer 1 (cross-validation), Layer 2 (per-feature by event type)
- Seed/mock profiles, dependency chains, execution order
- Task execution cycle with review loop per test group

**Output:** `{SESSION_DIR}/tdd-plan.md`
**Update:** progress-log.json.
**Banner:** `--- Phase 4 Complete: TDD Plan ---`

## Phase 5: Implementation

Invoke `config.phases["5"].skill` (default: `/essentials-execute`).

**Companion skills (invoke as appropriate for the task):**
- `superpowers:executing-plans` — if implementing sequentially from the Phase 3 plan.
- `superpowers:subagent-driven-development` — if plan has independent tasks suitable for parallel subagent dispatch with two-stage review (spec compliance → code quality).
- `superpowers:dispatching-parallel-agents` — if multiple independent subtasks can run concurrently.

Reference `{SESSION_DIR}/tdd-plan.md` for test strategy during implementation. Follow TDD: write failing test first, then implement.

**On any bug or unexpected failure during implementation:** Invoke `superpowers:systematic-debugging` — investigate root cause before attempting fixes. Do not guess.

**Update:** progress-log.json.
**Banner:** `--- Phase 5 Complete: Implementation ---`

## Phase 6: Post-Implementation Review

1. Invoke `superpowers:requesting-code-review` — prepare structured review request with what was implemented, the plan/requirements, and the diff range.

2. Invoke `dev-framework:multi-agent-consensus` via the Skill tool with:
   ```
   task_type: validate
   agents_list: code-quality-reviewer, performance-reviewer, observability-reviewer
   max_iterations: {config.pipeline.maxReviewIterations}
   zero_threshold: {config.pipeline.consecutiveZerosToExit}
   ```

3. Invoke `superpowers:receiving-code-review` — evaluate feedback rigorously. Verify each finding against the codebase before implementing. No performative agreement. Reasoned pushback on invalid findings.

4. After consensus completes:
   - Collect all issues found and fixes applied.
   - Log fix decisions to `{SESSION_DIR}/phase-6-decisions.jsonl`, then merge into decision-log.json.
   - Persist issues to pipeline-issues.json (append to current run by runId).

**Update:** progress-log.json with review metrics.
**Banner:** `--- Phase 6 Complete: Post-Impl Review --- Rounds: {N} | Issues fixed: {M} ---`

## Phase 7: Test Coverage Fill

1. Invoke `superpowers:test-driven-development` — use TDD methodology for writing additional tests.
2. Run all tests. Measure current coverage.
3. Compare against `config.pipeline.testCoverageTarget`%.
4. If below target: write additional tests targeting uncovered branches (RED-GREEN-REFACTOR cycle).
5. Re-run all tests. Verify green.

**Update:** progress-log.json.
**Banner:** `--- Phase 7 Complete: Test Coverage --- Coverage: {N}% ---`

## Phase 8: Final Review

1. **Pre-check:** Scan code for chronic pattern violations. If found, fix them first (quick pass, log as decisions).

2. **Review:** Invoke `dev-framework:multi-agent-consensus` (same config as Phase 6).

3. Invoke `superpowers:receiving-code-review` — evaluate final review findings with same rigor as Phase 6.

4. After consensus: collect issues, log decisions, persist issues.

**Update:** progress-log.json.
**Banner:** `--- Phase 8 Complete: Final Review --- Rounds: {N} | Issues fixed: {M} ---`

## Phase 9: Mistake Capture

**Load now:** Read `references/mistake-tracker-protocol.md` into context. Follow it:

1. **Idempotency:** Check Run Log — if current runId already aggregated, skip.
2. **Aggregate:** Read pipeline-issues.json, collect Phase 6 + 8 issues only.
3. **Match:** For each issue, match against existing patterns (LLM-driven).
4. **Update:** Increment frequency for matches, create new patterns for novel issues.
5. **Promote:** frequency >= `config.pipeline.chronicPromotionThreshold` → Chronic + prevention strategy.
6. **Hard cap:** Enforce `config.pipeline.maxActivePatterns` limit.
7. **Sync CLAUDE.md:** Write chronic patterns between sentinel markers.
8. **Log:** Decision-log entries for promotions/demotions (category: "pattern").
9. **Run Log:** Append runId to Run Log table.

**Update:** progress-log.json.
**Banner:** `--- Phase 9 Complete: Mistake Capture --- New patterns: {N} | Promoted: {M} ---`

## Phase 10: Human Gate

1. Invoke `superpowers:verification-before-completion` — run full test suite, verify build, confirm all claims with evidence before presenting summary.

2. Present comprehensive summary including: files modified, tests added, review iterations + issues fixed per phase, test coverage %, chronic patterns prevented, duration, decision count (link to decision-log.md), mistake tracker updates, and `git diff --stat` output.

3. Invoke `superpowers:finishing-a-development-branch` — present structured options:
   - **[1] Commit + Push** — Stage, commit, push, write pipeline-complete.md marker
   - **[2] Commit only** — Commit without pushing, write marker
   - **[3] Done** — Leave in working tree, user handles manually

4. On commit (option 1 or 2): write `pipeline-complete.md` to session folder with **original** (unsanitized) branch name. This authorizes git push via the push-guard hook.

5. Generate final `decision-log.md` and `progress-log.md`.

---

## Phase Failure Protocol

When any phase fails:

1. Invoke `superpowers:systematic-debugging` — investigate root cause before attempting fixes. Gather evidence, form hypothesis, test minimally.
2. Update progress-log.json: phase status = "failed"
3. Persist any accumulated issues to pipeline-issues.json
4. Log failure as decision (category: "skip")
5. Announce:
   ```
   --- Phase {N} FAILED: {phase name} ---
   Error: {description}
   Session: {SESSION_DIR}
   Resume: /dev-pipeline {TICKET} --from {N}
   ```
6. Offer: [1] Retry this phase [2] Skip to next [3] Abort pipeline

**Graceful degradation:** If config.json missing → use fallbacks. If patterns file missing → empty list. If any superpowers skill unavailable → phase operates without it. The pipeline must never fail to start.

---

## Cross-Cutting Concerns

### Progress Banners
One-line banner at each phase transition. Include key metrics when available.

### Decision Logging
Per-iteration: append to `phase-{N}-decisions.jsonl` (one JSON line per decision).
At phase end: merge JSONL into `decision-log.json`, delete temp file.

### Progress Updates
At phase end: update `progress-log.json` with phase timing, metrics, and decision references.

### Markdown Regeneration
At phase end (not per-iteration): regenerate `decision-log.md` and `progress-log.md` from JSON source. If generation fails, warn but don't fail the phase.

### Performance Budgets (from config.phases)

| Phase | Budget | Notes |
|-------|--------|-------|
| 1 | 0.5 min | Single API call |
| 2 | 2 min | Codebase scan |
| 3 | 10 min | Self-review loop |
| 4 | 2 min | Planning only |
| 5 | 15 min | Varies by complexity |
| 6 | 10 min | 3 agents per round |
| 7 | 5 min | Gap fill + test run |
| 8 | 10 min | Should be faster |
| 9 | 1 min | File I/O only |
| 10 | User-paced | No timeout |
