# Review Loop Protocol

Reusable iterative review protocol used throughout the `/implement` full-cycle workflow and the `/spike` Phase 4 cross-ticket gap review.

## Modes

| Phase | Mode | What's Reviewed |
|-------|------|-----------------|
| 3 (self-review) | Self-review | Implementation plan document |
| 5 (Layer 1) | multi-agent-consensus | Implemented code (post-implementation) |
| 6 (Layer 2) | multi-agent-consensus | Implemented code (final, after test coverage fill) |

## Algorithm

```
MAX_ITERATIONS = config.pipeline.maxReviewIterations    # default: 10
EARLY_EXIT = config.pipeline.consecutiveZerosToExit      # default: 2

iteration = 0
consecutive_zeros = 0
issue_log = []

LOAD chronic patterns (use already-loaded CHRONIC_PATTERNS from Pre-Workflow)
ADD chronic patterns to REVIEW_FOCUS criteria

WHILE iteration < MAX_ITERATIONS:
    iteration++
    ANNOUNCE: "--- Review iteration {iteration}/{MAX_ITERATIONS} ---"
    EMIT: bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh consensus.iteration.started \
          --actor orchestrator \
          --data "$(jq -cn --argjson p $PHASE --argjson i $iteration '{phase:$p, iteration:$i}')"

    IF REVIEW_MODE == "multi-agent-consensus":
        READ references/protocols/multi-agent-consensus.md and run the protocol with:
          task_type: validate
          agents_list: [code-quality-reviewer, performance-reviewer, observability-reviewer]
          max_iterations: 1  (single consensus round per review iteration)
          zero_threshold: 1
        issues = validated findings from consensus
    ELSE IF REVIEW_MODE == "self":
        FOR EACH criterion in REVIEW_FOCUS:
            Examine the artifact against this criterion
            Record any valid issues found
        issues = all valid issues collected

    ANNOUNCE: "Iteration {iteration}: {len(issues)} valid issues found"

    FOR EACH issue in issues:
        APPEND to issue_log: { iteration, description, category, chronicPatternMatch }

    IF len(issues) == 0:
        consecutive_zeros++
        ANNOUNCE: "Clean round ({consecutive_zeros}/{EARLY_EXIT})"
        IF consecutive_zeros >= EARLY_EXIT:
            ANNOUNCE: "Exit: clean after {EARLY_EXIT} consecutive zeros"
            EMIT: bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh consensus.converged \
                  --actor orchestrator \
                  --data "$(jq -cn --argjson p $PHASE --argjson it $iteration --argjson f $TOTAL_FIXED \
                           '{phase:$p, iterations:$it, issuesFixed:$f}')"
            BREAK
    ELSE:
        consecutive_zeros = 0
        Fix all issues
        APPEND fix decisions to {SESSION_DIR}/phase-{N}-decisions.jsonl

IF iteration >= MAX_ITERATIONS:
    ANNOUNCE: "Exit: max iterations reached"
    EMIT: bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh consensus.forced_stop \
          --actor orchestrator \
          --data "$(jq -cn --argjson p $PHASE --argjson it $iteration --argjson r $REMAINING \
                   '{phase:$p, iterations:$it, remainingIssues:$r}')"

# --- Batch merge at phase end ---
MERGE {SESSION_DIR}/phase-{N}-decisions.jsonl into decision-log.json
PERSIST issue_log to pipeline-issues.json (read→modify→write by runId)
UPDATE progress-log.json with phase metrics
REGENERATE decision-log.md and progress-log.md
DELETE {SESSION_DIR}/phase-{N}-decisions.jsonl
RETURN issue_log
```

## Issue Categories (from config.issueCategories)

| Category | Covers |
|----------|--------|
| `style` | Return types, naming, signatures, formatting |
| `logic` | Null checks, conditions, branching, race conditions |
| `security` | Auth, credentials, injection, OWASP |
| `performance` | N+1 queries, allocation, caching, complexity |
| `docs` | XML docs, comments, API documentation |
| `testing` | Coverage gaps, edge cases, fragile tests |
| `wiring` | DI registration, service lifetime, middleware, config |
| `architecture` | Layer violations, coupling, responsibility |

## What Counts as Valid

**Valid:** Functional incorrectness, deviation from documented codebase conventions, missing requirements, security vulnerabilities, missing DI wiring, missing public API documentation.

**NOT valid:** Style preferences not established in the codebase, hypothetical future requirements, issues already fixed in a prior iteration, trivial formatting, "nice to have" suggestions, disagreements with established patterns.

## Anti-Patterns

1. **Rubber-stamping** — Zero issues on iteration 1 is suspicious for plan reviews. In the Phase 3 self-review step, if iteration 1 returns zero issues on a new plan, re-review with explicit focus on each criterion. Do not early-exit on iteration 1.
2. **Flip-flopping** — Fix A introduces B, fix B re-introduces A. Resolve holistically.
3. **Category gaming** — Don't downplay `logic` as `style`.
4. **Scope creep** — Don't add features during fix iterations.
5. **Phantom fixes** — Verify the artifact actually changed.

## Temp Decision File Schema (phase-{N}-decisions.jsonl)

One JSON object per line, same fields as decision-log.json entries:

```jsonl
{"id":"D003","timestamp":"2026-04-09T10:42:00Z","phase":6,"category":"review-fix","decision":"Added Result<T> return type","reason":"Chronic pattern P3","alternatives":[],"confidence":"high","references":["src/Services/EmployeeService.cs"],"chronicPatternMatch":"P3"}
```

- **id:** Auto-incremented from last id in decision-log.json (read once at phase start). Start from D001 if decision-log.json doesn't exist.
- **Format:** Strictly one JSON object per line.
- **Resume cleanup:** On `--from N`, if phase-{N}-decisions.jsonl exists from a prior crash, merge it first.
