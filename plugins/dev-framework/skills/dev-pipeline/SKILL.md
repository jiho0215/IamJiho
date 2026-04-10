---
name: dev-pipeline
version: 1.1.0
description: |
  Autonomous 10-phase development pipeline with cross-session learning.
  Use when: user says "/dev-pipeline", wants autonomous end-to-end ticket implementation,
  or wants a pipeline with JIRA integration, automated reviews, and mistake tracking.
---

# Dev Pipeline

Autonomous 10-phase pipeline: JIRA fetch → codebase prime → plan → TDD → implement → review → test coverage → final review → mistake capture → human gate.

Single human gate at Phase 10. Everything else runs autonomously.

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

1. Invoke `config.phases["3"].skill` (default: `/essentials-analyze`) for design analysis.
2. Generate implementation plan.
3. Inject CHRONIC_PATTERNS as a prevention checklist in the plan.
4. **Self-review loop:** Follow `review-loop-protocol.md`. Run in self-review mode.
5. Log plan decisions to decision-log.json (category: "plan").
6. Persist issues to pipeline-issues.json.

**Update:** progress-log.json with review metrics (iterations, issues found/fixed).
**Banner:** `--- Phase 3 Complete: Plan & Review --- Iterations: {N} | Issues fixed: {M} ---`

## Phase 4: TDD Plan

Invoke `dev-framework:test-planning` skill with context from Phases 1-3 (ticket requirements, codebase architecture, implementation plan).

The test-planning skill generates a layered test plan with:
- Layer 0 (data pipeline), Layer 1 (cross-validation), Layer 2 (per-feature by event type)
- Seed/mock profiles, dependency chains, execution order
- Task execution cycle with review loop per test group

**Output:** `{SESSION_DIR}/tdd-plan.md`
**Update:** progress-log.json.
**Banner:** `--- Phase 4 Complete: TDD Plan ---`

## Phase 5: Implementation

Invoke `config.phases["5"].skill` (default: `/essentials-execute`).

Reference `{SESSION_DIR}/tdd-plan.md` for test strategy during implementation.

**Update:** progress-log.json.
**Banner:** `--- Phase 5 Complete: Implementation ---`

## Phase 6: Post-Implementation Review

**Uses existing plugin infrastructure:**

Invoke `dev-framework:multi-agent-consensus` via the Skill tool with:
```
task_type: validate
agents_list: code-quality-reviewer, performance-reviewer, observability-reviewer
context: "Review the code changes for ticket {TICKET_ID}. Self-fix enabled."
max_iterations: {config.pipeline.maxReviewIterations}
zero_threshold: {config.pipeline.consecutiveZerosToExit}
```

After consensus completes:
1. Collect all issues found and fixes applied.
2. Log fix decisions to `{SESSION_DIR}/phase-6-decisions.jsonl`, then merge into decision-log.json.
3. Persist issues to pipeline-issues.json (append to current run by runId).

**Update:** progress-log.json with review metrics.
**Banner:** `--- Phase 6 Complete: Post-Impl Review --- Rounds: {N} | Issues fixed: {M} ---`

## Phase 7: Test Coverage Fill

1. Run all tests. Measure current coverage.
2. Compare against `config.pipeline.testCoverageTarget`%.
3. If below target: write additional tests targeting uncovered branches.
4. Re-run all tests. Verify green.

**Update:** progress-log.json.
**Banner:** `--- Phase 7 Complete: Test Coverage --- Coverage: {N}% ---`

## Phase 8: Final Review

1. **Pre-check:** Scan code for chronic pattern violations. If found, fix them first (quick pass, log as decisions).
2. **Review:** Invoke `dev-framework:multi-agent-consensus` (same config as Phase 6).
3. After consensus: collect issues, log decisions, persist issues.

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

Present comprehensive summary including: files modified, tests added, review iterations + issues fixed per phase, test coverage %, chronic patterns prevented, duration, decision count (link to decision-log.md), mistake tracker updates, and `git diff --stat` output.

**User Options:**
1. **Commit + Push** — Stage, commit, push, write pipeline-complete.md marker
2. **Commit only** — Commit without pushing, write marker
3. **Done** — Leave in working tree, user handles manually

On commit (option 1 or 2): write `pipeline-complete.md` to session folder with **original** (unsanitized) branch name. This authorizes git push via the push-guard hook.

Generate final `decision-log.md` and `progress-log.md`.

---

## Phase Failure Protocol

When any phase fails:

1. Update progress-log.json: phase status = "failed"
2. Persist any accumulated issues to pipeline-issues.json
3. Log failure as decision (category: "skip")
4. Announce:
   ```
   --- Phase {N} FAILED: {phase name} ---
   Error: {description}
   Session: {SESSION_DIR}
   Resume: /dev-pipeline {TICKET} --from {N}
   ```
5. Offer: [1] Retry this phase [2] Skip to next [3] Abort pipeline

**Graceful degradation:** If config.json missing → use fallbacks. If patterns file missing → empty list. The pipeline must never fail to start.

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
