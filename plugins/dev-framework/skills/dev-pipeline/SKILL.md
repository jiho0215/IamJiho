---
name: dev-pipeline
version: 1.3.0
description: |
  Autonomous 10-phase development pipeline with cross-session learning, phase gates, and multi-agent review.
  Use when: user says "/dev-pipeline", wants autonomous end-to-end ticket implementation,
  or wants a pipeline with JIRA integration, automated reviews, and mistake tracking.
  Also trigger when: user says "implement this ticket", "build this feature end to end",
  "take this JIRA ticket and run with it", "full pipeline", "autonomous implementation",
  "implement TICKET-123 autonomously", or any request for a structured multi-phase
  development workflow with automated code review and testing.
---

# Dev Pipeline

Autonomous 10-phase pipeline: JIRA fetch → codebase prime → plan → TDD → implement → review → test coverage → final review → mistake capture → human gate.

Single human gate at Phase 10. Everything else runs autonomously.

## Companion Skills (configurable via `config.json`)

All skill and agent references are resolved from `config.pipeline.skills.*` and `config.pipeline.agents.*`. If a key is missing, the fallback default is used. If the resolved skill is unavailable at runtime, the phase operates without skill-specific guidance.

Users can override any skill by setting the corresponding key in `~/.claude/autodev/config.json`. See `references/session-management.md` Config Defaults for the full list.

| Config Key | Default | Phase | Purpose |
|------------|---------|-------|---------|
| `skills.requirements` | `superpowers:brainstorming` | 1 | Requirements gathering through dialogue |
| `skills.exploration` | `feature-dev:code-explorer` | 2 | Deep codebase analysis, execution path tracing |
| `skills.architect` | `feature-dev:code-architect` | 3 | Feature architecture design from codebase patterns |
| `skills.consensus` | `dev-framework:multi-agent-consensus` | 3, 6, 8 | Multi-agent consensus loop |
| `skills.planning` | `superpowers:writing-plans` | 3 | Structured implementation plan |
| `skills.tdd` | `superpowers:test-driven-development` | 4, 7 | TDD methodology for test planning and coverage fill |
| `skills.testPlanning` | `dev-framework:test-planning` | 4 | Layered test plan generation |
| `skills.implementation` | `superpowers:subagent-driven-development` | 5 | Task execution with two-stage review (default) |
| `skills.implementationSequential` | `superpowers:executing-plans` | 5 | Sequential plan execution (alternative) |
| `skills.implementationParallel` | `superpowers:dispatching-parallel-agents` | 5 | Independent subtask parallelization (alternative) |
| `skills.requestReview` | `superpowers:requesting-code-review` | 6 | Structured review request to consensus agents |
| `skills.receiveReview` | `superpowers:receiving-code-review` | 6, 8 | Rigorous evaluation of review feedback |
| `skills.verification` | `superpowers:verification-before-completion` | 10 | Run verification commands before claiming done |
| `skills.finishing` | `superpowers:finishing-a-development-branch` | 10 | Structured commit/push/PR/discard options |
| `skills.debugging` | `superpowers:systematic-debugging` | Any failure | Root cause investigation before fix attempts |
| `agents.plan` | `[requirements-analyst, architect, test-strategist]` | 3 | Plan validation agents |
| `agents.review` | `[code-quality-reviewer, performance-reviewer, observability-reviewer]` | 6, 8 | Code review agents |

### Skill Resolution

When loading config in Pre-Pipeline step 2, resolve all skill/agent keys. For each key, read from config; if absent, use the fallback default from the table above. Store the resolved values so phases can reference them by config key.

Notation used in phases below: `{skills.X}` means the resolved value of `config.pipeline.skills.X`, and `{agents.X}` means the resolved value of `config.pipeline.agents.X`.

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
Read `~/.claude/autodev/config.json`.
- If `~/.claude/autodev/` directory doesn't exist: create it (`mkdir -p`).
- If `config.json` doesn't exist: **create it** with the full default schema (see below) and announce: "Created default config at ~/.claude/autodev/config.json — edit to customize skills, agents, and thresholds."
- If `config.json` exists but is malformed: rename to `config.json.bak`, create fresh default, warn: "config.json was malformed — backed up to config.json.bak and recreated with defaults."
- If `config.json` exists and is valid: read it. For any missing key, use the fallback default from `references/session-management.md` Config Defaults section.

Default config template to write (canonical source — `references/session-management.md` Config Defaults must match):
```json
{
  "pipeline": {
    "maxReviewIterations": 10,
    "consecutiveZerosToExit": 2,
    "testCoverageTarget": 90,
    "maxActivePatterns": 20,
    "chronicPromotionThreshold": 3,
    "cleanRunsForDemotion": 5,
    "maxRunsRetained": 10,
    "sessionHealthCheckpointPhases": 6,
    "skills": {
      "requirements": "superpowers:brainstorming",
      "exploration": "feature-dev:code-explorer",
      "architect": "feature-dev:code-architect",
      "consensus": "dev-framework:multi-agent-consensus",
      "planning": "superpowers:writing-plans",
      "tdd": "superpowers:test-driven-development",
      "testPlanning": "dev-framework:test-planning",
      "implementation": "superpowers:subagent-driven-development",
      "implementationSequential": "superpowers:executing-plans",
      "implementationParallel": "superpowers:dispatching-parallel-agents",
      "requestReview": "superpowers:requesting-code-review",
      "receiveReview": "superpowers:receiving-code-review",
      "verification": "superpowers:verification-before-completion",
      "finishing": "superpowers:finishing-a-development-branch",
      "debugging": "superpowers:systematic-debugging"
    },
    "agents": {
      "plan": ["requirements-analyst", "architect", "test-strategist"],
      "review": ["code-quality-reviewer", "performance-reviewer", "observability-reviewer"]
    }
  },
  "paths": {
    "sessionsDir": "~/.claude/autodev/sessions",
    "autodevRoot": "~/.claude/autodev",
    "patternsFile": "workflow_mistake_patterns.md"
  },
  "sessionFolderFormat": "{repo}--{branch}",
  "hooks": {
    "pushGuard": {
      "escapeFlags": ["--force", "-f"]
    },
    "testCapture": {
      "testCommand": "dotnet test"
    }
  },
  "sentinels": {
    "begin": "<!-- CHRONIC PATTERNS START -->",
    "end": "<!-- CHRONIC PATTERNS END -->"
  }
}
```

After loading/creating, resolve all `pipeline.skills.*` and `pipeline.agents.*` keys into variables for phase use (see Skill Resolution in the Companion Skills section).

### 3. Archive Old Runs
If `pipeline-issues.json` has > `maxRunsRetained` runs, move oldest to `pipeline-issues-archive.json`.

### 4. Clean Stale Sessions
Follow cleanup rules in `references/session-management.md`.

### 5. Initialize Session Files
- If `progress-log.json` doesn't exist: create with schemaVersion, ticket, repo, branch, runId, startedAt, configSnapshot, empty phases array.
- If `decision-log.json` doesn't exist: create with schemaVersion, ticket, repo, branch, empty decisions array.
- If `pipeline-issues.json` doesn't exist: create with schemaVersion, empty runs array. Append new run entry with runId.
- If resuming (`--from N`): read existing runId from progress-log.json (do not create new one).

### 5a. Verify Progress Map Exists
After initializing session files, run the progress map existence check:
```
bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh verify
```
This verifies `progress-log.json` was created, is valid JSON, and has `schemaVersion`. If it fails (exit 2), abort pipeline — session initialization is broken. This is distinct from the Phase 1 begin gate, which checks phase prerequisites.

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

## Phase 1: Requirements Gathering

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 1`

Invoke `{skills.requirements}` — gather requirements for TICKET_ID through dialogue:
1. If user provides a ticket URL or description, extract requirements, acceptance criteria, and constraints.
2. If user provides minimal context, ask clarifying questions one at a time.
3. Produce structured requirements document in the session folder.

**Output:** Requirements in session folder.
**Update:** progress-log.json (phase 1 complete).
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 1`
**Banner:** `--- Phase 1 Complete: Requirements Gathering ---`

## Phase 2: Codebase Exploration

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 2`

Invoke `{skills.exploration}` — deeply analyze the existing codebase:
1. Trace execution paths related to the feature area.
2. Map architecture layers, patterns, and abstractions.
3. Document dependencies and integration points.
4. Identify conventions the new code must follow.

**Output:** Codebase context loaded into session.
**Update:** progress-log.json.
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 2`
**Banner:** `--- Phase 2 Complete: Codebase Exploration ---`

## Phase 3: Plan & Review

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 3`

**Load now:** Read `references/review-loop-protocol.md` into context.

1. Invoke `{skills.architect}` — design feature architecture based on Phase 2 findings. Analyze patterns, propose component design, data flows, and integration blueprint.
2. Invoke `{skills.consensus}` with `task_type: plan`, `agents_list: {agents.plan}` — validate the design with the configured plan agents.
3. Invoke `{skills.planning}` — generate structured implementation plan with bite-sized tasks.
4. Inject CHRONIC_PATTERNS as a prevention checklist in the plan.
5. **Self-review loop:** Follow `review-loop-protocol.md`. Run in self-review mode.
6. Log plan decisions to decision-log.json (category: "plan").
7. Persist issues to pipeline-issues.json.

**Update:** progress-log.json with review metrics (iterations, issues found/fixed).
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 3`
**Banner:** `--- Phase 3 Complete: Plan & Review --- Iterations: {N} | Issues fixed: {M} ---`

## Phase 4: TDD Plan

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 4`

1. Invoke `{skills.tdd}` — establish TDD methodology for the feature.
2. Invoke `{skills.testPlanning}` skill with context from Phases 1-3 (ticket requirements, codebase architecture, implementation plan).

The test-planning skill generates a layered test plan with:
- Layer 0 (data pipeline), Layer 1 (cross-validation), Layer 2 (per-feature by event type)
- Seed/mock profiles, dependency chains, execution order
- Task execution cycle with review loop per test group

**Output:** `{SESSION_DIR}/tdd-plan.md`
**Update:** progress-log.json.
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 4`
**Banner:** `--- Phase 4 Complete: TDD Plan ---`

## Phase 5: Implementation

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 5`

Execute the Phase 3 plan using the most appropriate approach:

- **Default:** Invoke `{skills.implementation}` — dispatch fresh subagent per task from the plan, with two-stage review (spec compliance → code quality) per task.
- **Sequential alternative:** Invoke `{skills.implementationSequential}` — if tasks have strong sequential dependencies.
- **Parallel alternative:** Invoke `{skills.implementationParallel}` — if multiple independent subtasks can run concurrently without shared state.

Reference `{SESSION_DIR}/tdd-plan.md` for test strategy during implementation. Follow TDD: write failing test first, then implement.

**On any bug or unexpected failure during implementation:** Invoke `{skills.debugging}` — investigate root cause before attempting fixes. Do not guess.

**Update:** progress-log.json.
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 5`
**Banner:** `--- Phase 5 Complete: Implementation ---`

## Phase 6: Post-Implementation Review

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 6`

1. Invoke `{skills.requestReview}` — prepare structured review request with what was implemented, the plan/requirements, and the diff range.

2. Invoke `{skills.consensus}` via the Skill tool with:
   ```
   task_type: validate
   agents_list: {agents.review}
   max_iterations: {config.pipeline.maxReviewIterations}
   zero_threshold: {config.pipeline.consecutiveZerosToExit}
   ```

3. Invoke `{skills.receiveReview}` — evaluate feedback rigorously. Verify each finding against the codebase before implementing. No performative agreement. Reasoned pushback on invalid findings.

4. After consensus completes:
   - Collect all issues found and fixes applied.
   - Log fix decisions to `{SESSION_DIR}/phase-6-decisions.jsonl`, then merge into decision-log.json.
   - Persist issues to pipeline-issues.json (append to current run by runId).

**Update:** progress-log.json with review metrics.
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 6`
**Banner:** `--- Phase 6 Complete: Post-Impl Review --- Rounds: {N} | Issues fixed: {M} ---`

## Phase 7: Test Coverage Fill

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 7`

1. Invoke `{skills.tdd}` — use TDD methodology for writing additional tests.
2. Run all tests. Measure current coverage.
3. Compare against `config.pipeline.testCoverageTarget`%.
4. If below target: write additional tests targeting uncovered branches (RED-GREEN-REFACTOR cycle).
5. Re-run all tests. Verify green.

**Update:** progress-log.json.
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 7`
**Banner:** `--- Phase 7 Complete: Test Coverage --- Coverage: {N}% ---`

## Phase 8: Final Review

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 8`

1. **Pre-check:** Scan code for chronic pattern violations. If found, fix them first (quick pass, log as decisions).

2. **Review:** Invoke `{skills.consensus}` with `task_type: validate`, `agents_list: {agents.review}`, same `max_iterations` and `zero_threshold` as Phase 6.

3. Invoke `{skills.receiveReview}` — evaluate final review findings with same rigor as Phase 6.

4. After consensus: collect issues, log decisions, persist issues.

**Update:** progress-log.json.
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 8`
**Banner:** `--- Phase 8 Complete: Final Review --- Rounds: {N} | Issues fixed: {M} ---`

## Phase 9: Mistake Capture

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 9`

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
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 9`
**Banner:** `--- Phase 9 Complete: Mistake Capture --- New patterns: {N} | Promoted: {M} ---`

## Phase 10: Human Gate

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 10`

1. Invoke `{skills.verification}` — run full test suite, verify build, confirm all claims with evidence before presenting summary.

2. Present comprehensive summary including: files modified, tests added, review iterations + issues fixed per phase, test coverage %, chronic patterns prevented, duration, decision count (link to decision-log.md), mistake tracker updates, and `git diff --stat` output.

3. Invoke `{skills.finishing}` — present structured options:
   - **[1] Commit + Push** — Stage, commit, push, write pipeline-complete.md marker
   - **[2] Commit only** — Commit without pushing, write marker
   - **[3] Done** — Leave in working tree, user handles manually

4. On commit (option 1 or 2): write `pipeline-complete.md` to session folder with **original** (unsanitized) branch name. This authorizes git push via the push-guard hook.

5. Generate final `decision-log.md` and `progress-log.md`.

**Update:** progress-log.json (phase 10 complete, pipeline status = "completed", completedAt = now).
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 10`

---

## Phase Failure Protocol

When any phase fails:

1. Invoke `{skills.debugging}` — investigate root cause before attempting fixes. Gather evidence, form hypothesis, test minimally.
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

**Graceful degradation:** If config.json missing → create with defaults (Pre-Pipeline step 2). If patterns file missing → empty list. If any configured skill unavailable → phase operates without it. The pipeline must never fail to start.

## Gate Failure Protocol

When a phase gate blocks (exit 2), it's a prerequisite violation — not a phase failure. Do NOT invoke `{skills.debugging}` (there's no bug to debug).

1. Read the gate error message — it explains exactly what's wrong.
2. Announce:
   ```
   --- Phase {N} GATE BLOCKED: {gate error summary} ---
   Session: {SESSION_DIR}
   ```
3. Offer based on gate type:
   - **Begin gate (missing progress):** [1] Run Pre-Pipeline to initialize [2] Use `--from N` to resume [3] Abort
   - **Begin gate (previous phase incomplete):** [1] Complete Phase {N-1} first [2] Use `--from N` to skip [3] Abort
   - **End gate (progress not updated):** [1] Update progress-log.json and retry end gate [2] Abort
   - **Verify gate (session broken):** [1] Delete session folder and restart [2] Abort

---

## Cross-Cutting Concerns

### Phase Gates (Mandatory)
Every phase is bookended by gate calls that enforce progress map integrity:
- **Begin gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin N` — validates progress-log.json exists, previous phase completed, pipeline not already finished.
- **End gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end N` — validates current phase status is "completed", completedAt is set, and progress-log.json is consistent.
- **PostToolUse hook:** After each gate call, `phase-progress-validator.sh` runs automatically (registered in hooks.json) to independently validate progress map consistency.
- **Blocking behavior:** Gate scripts exit 2 on validation failure, halting the pipeline. The validator hook emits warnings but does not block (exit 0).
- **Execution order:** Begin gate BEFORE any phase work. Update progress-log.json DURING the phase. End gate AFTER the update, BEFORE the banner.

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
