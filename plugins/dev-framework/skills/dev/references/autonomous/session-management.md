# Session Management

Per-repo-branch session folders for pipeline state, decisions, and progress tracking.

## Session Folder Location

`config.paths.sessionsDir` → default: `~/.claude/autodev/sessions/`

Each session: `{sessionsDir}/{repo}--{branch}/`

## Session Folder Contents

| File | Purpose |
|------|---------|
| `decision-log.json` + `.md` | Every decision with reasons (auto-generated MD) |
| `progress-log.json` + `.md` | Phase timing, metrics, status |
| `pipeline-issues.json` | Review findings per phase |
| `tdd-plan.md` | Phase 4 output: test strategy |
| `pipeline-complete.md` | Push guard marker (written at Phase 7 GATE 2 approval) |
| `bypass.json` | Ticket-scoped freeze-gate override (active until Phase 7 completion or session end) |
| `bypass-audit.jsonl` | Durable bypass audit trail (written by sessionend hook when GATE 2 did not run) |
| `test-failures.log` | Test failure audit trail (written by hook) |
| `phase-{N}-decisions.jsonl` | Temp file during review iterations (deleted at phase end) |

## Folder Resolution Algorithm

```
1. Read config.json → paths.sessionsDir
2. Get repo name:
   a. Try: basename of `git remote get-url origin` (strip .git)
   b. Fallback: basename of `git rev-parse --show-toplevel` (worktree-safe)
   c. Last resort: basename of current working directory
3. Get branch:
   a. Try: `git symbolic-ref --short HEAD`
   b. If detached HEAD: use short commit hash
4. Sanitize branch name:
   - Replace all of / \ : * ? " < > | @ with '-'
   - Remove trailing dots
   - Truncate to 64 chars
5. Apply config.sessionFolderFormat: replace {repo} and {branch}
6. SESSION_DIR = {sessionsDir}/{formatted name}/
7. mkdir -p "$SESSION_DIR" || fallback to /tmp/autodev-sessions/
```

### Reference Implementations

```bash
sanitize_branch() {
  echo "$1" | sed 's|[/\\:*?"<>|@]|-|g' | sed 's|\.\.*$||' | cut -c1-64
}

get_repo_name() {
  local url
  url=$(git remote get-url origin 2>/dev/null) && { basename "$url" .git; return; }
  local toplevel
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) && { basename "$toplevel"; return; }
  basename "$(pwd)"
}
```

## Session Cleanup

On pipeline start (**skipped during `--from N` resume**):

1. List all session folders in config.paths.sessionsDir
2. For each folder, check progress-log.json:
   - If `completedAt` is set and > 90 days ago: delete (stale completed)
   - If `completedAt` is null AND `startedAt` > 90 days ago: delete (abandoned)
   - Otherwise: keep
3. Log: "Cleaned up {N} stale session folders"

This is advisory — if cleanup fails, the pipeline continues.

## Resume Protocol (--from N)

1. Resolve session folder (same repo + branch)
2. Read `progress-log.json` — verify ticket, show completed phases
3. **Mid-phase crash detection:** If last phase status is `"in-progress"`:
   ```
   WARNING: Phase {N} was interrupted mid-execution.
   Code may be in an inconsistent state.
   Options: [1] Continue  [2] Reset and restart  [3] Abort
   ```
4. **Stale JSONL cleanup:** If `phase-{N}-decisions.jsonl` exists from prior crash, merge it first
5. Read `pipeline-issues.json` — restore issue logs
6. Read `decision-log.json` — restore decision context
7. Load config + chronic patterns
8. Announce caveat: "Resuming from Phase {N}. Phases 1-{N-1} artifacts assumed valid."
9. Continue from Phase N

**Resume append caveat:** Append to existing run's phases array by runId. Do not create duplicate run entry.

**Phase 7 GATE 2 idempotency:** the GATE 2 archival sequence (merge bypass records into freeze doc `bypassHistory`, delete `bypass.json`, write `pipeline-complete.md`, finalize `progress-log.json`) is idempotent — dedup by `at` and filter by `runId` protect against double-writes. On `--from 7` after a mid-archival failure, re-run the full sequence; already-written records are skipped by dedup and the sequence reaches a consistent terminal state.

## JSON Schemas (Inline)

### decision-log.json
```json
{
  "schemaVersion": 1,
  "ticket": "CAOS-1234",
  "repo": "my-api",
  "branch": "feature/auth-flow",
  "decisions": [
    {
      "id": "D001",
      "timestamp": "2026-04-09T10:35:00Z",
      "phase": 3,
      "category": "plan|review-fix|pattern|skip|override|resume|autonomous-inference|gate-1|gate-2|bypass",
      "decision": "Short description",
      "reason": "Why this choice",
      "alternatives": [],
      "confidence": "high|medium|low",
      "references": [],
      "chronicPatternMatch": null
    }
  ]
}
```

### progress-log.json
```json
{
  "schemaVersion": 1,
  "mode": "full-cycle",
  "ticket": "CAOS-1234",
  "featureSlug": "auth-flow",
  "freezeDocPath": "docs/specs/auth-flow-freeze.md",
  "plannedFiles": ["src/auth/login.ts", "src/auth/session.ts"],
  "approvalMode": "interactive",
  "repo": "my-api",
  "branch": "feature/auth-flow",
  "runId": "run-2026-04-09T10-30-00-a3f2",
  "startedAt": "2026-04-09T10:30:00Z",
  "completedAt": null,
  "interruptedAt": null,
  "status": "in-progress|completed|failed|interrupted",
  "currentPhase": 5,
  "chronicPatternsLoaded": 3,
  "configSnapshot": {
    "maxReviewIterations": 10,
    "consecutiveZerosToExit": 2,
    "testCoverageTarget": 90
  },
  "phases": [
    {
      "phase": 1,
      "name": "Requirements",
      "startedAt": "...",
      "completedAt": "...",
      "durationSeconds": 25,
      "budgetSeconds": 30,
      "status": "completed|failed|skipped|in-progress",
      "metrics": {},
      "decisions": [],
      "notes": ""
    }
  ],
  "summary": {
    "totalDurationMinutes": null,
    "totalIssuesFound": 0,
    "totalIssuesFixed": 0,
    "chronicPatternsPrevented": 0,
    "newPatternsAdded": 0,
    "patternsPromoted": 0,
    "avgReviewIterations": null
  }
}
```

**Field notes:**
- `mode` — `"full-cycle"`, `"review"`, `"test"`, `"docs"`, or `"init"`. Hooks (`freeze-gate`, `push-guard`) use this to decide when to enforce gates.
- `featureSlug` — stable identifier used across artifacts; always set at Phase 1 (autonomous uses it alongside `ticket`).
- `freezeDocPath` — relative path from repo root to the feature's freeze doc; set at Phase 3 completion.
- `plannedFiles` — files the plan expects to modify; populated at Phase 3 completion.
- `approvalMode` — `"interactive"` or `"autonomous"`; records how GATE 1 was satisfied.
- `interruptedAt` — ISO-8601 UTC timestamp set by `sessionend.sh` when it marks a session's status as `interrupted` (session ended mid-run without completing Phase 7). Null while the session is still active.

### pipeline-complete.md (Phase 7 GATE 2 marker)
```
Pipeline completed for branch: {original git branch name, NOT sanitized}
Date: {ISO UTC}
Feature: {feature-slug}
```

Only the first line is consumed by `push-guard.sh` (exact-match grep). Subsequent lines are for human/audit reading. For autonomous runs the `Feature:` line may additionally include `Ticket: {ticket}` as a second identifier.

### runId Format
`run-{ISO date}T{HH-MM-SS}-{4 hex}` — timestamp + random hex suffix. Generated once at pipeline start, stored in progress-log.json, reused on resume.

### Markdown Generation
- **Generated by:** SKILL.md orchestrator (not hooks)
- **When:** At phase completion, not per-iteration
- **On failure:** Log warning, don't fail phase. JSON is source of truth.

## Config Defaults

If `~/.claude/autodev/config.json` is missing or a key is absent, use these fallbacks:

| Key | Fallback |
|-----|----------|
| `pipeline.maxReviewIterations` | 10 |
| `pipeline.consecutiveZerosToExit` | 2 |
| `pipeline.testCoverageTarget` | 90 |
| `pipeline.maxActivePatterns` | 20 |
| `pipeline.chronicPromotionThreshold` | 3 |
| `pipeline.cleanRunsForDemotion` | 5 |
| `pipeline.maxRunsRetained` | 10 |
| `pipeline.sessionHealthCheckpointPhases` | 6 |
| `paths.sessionsDir` | `~/.claude/autodev/sessions` |
| `paths.autodevRoot` | `~/.claude/autodev` |
| `sessionFolderFormat` | `{repo}--{branch}` |
| `pipeline.skills.requirements` | `superpowers:brainstorming` |
| `pipeline.skills.exploration` | `feature-dev:code-explorer` |
| `pipeline.skills.architect` | `feature-dev:code-architect` |
| `pipeline.skills.planning` | `superpowers:writing-plans` |
| `pipeline.skills.tdd` | `superpowers:test-driven-development` |
| `pipeline.skills.implementation` | `superpowers:subagent-driven-development` |
| `pipeline.skills.implementationSequential` | `superpowers:executing-plans` |
| `pipeline.skills.implementationParallel` | `superpowers:dispatching-parallel-agents` |
| `pipeline.skills.requestReview` | `superpowers:requesting-code-review` |
| `pipeline.skills.receiveReview` | `superpowers:receiving-code-review` |
| `pipeline.skills.verification` | `superpowers:verification-before-completion` |
| `pipeline.skills.finishing` | `superpowers:finishing-a-development-branch` |
| `pipeline.skills.debugging` | `superpowers:systematic-debugging` |
| `pipeline.agents.plan` | `["requirements-analyst", "architect", "test-strategist"]` |
| `pipeline.agents.review` | `["code-quality-reviewer", "performance-reviewer", "observability-reviewer"]` |
| `pipeline.freezeDoc.categories` | `["business-logic", "api-contracts", "third-party", "data", "error-model", "acceptance-criteria", "security", "performance"]` |
| `pipeline.freezeDoc.nonFrozenAllowList` | `["observability", "railroad-composition", "pure-function-composition"]` |

Note: `pipeline.skills.consensus` and `pipeline.skills.testPlanning` keys from prior versions are removed — multi-agent consensus and test planning are now internal protocols (see `protocols/`), not configurable external skills.
