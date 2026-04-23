# Coverage Gap Analysis Protocol

Phase 2 of `/testbuilder`. Computes the gap between the current state (from Phase 1 `assess.json`) and the 95% case coverage target. Runs under multi-agent consensus.

## Two coverage dimensions

| Dimension | What it measures | Tool | Target |
|---|---|---|---|
| **Code coverage** (line + branch) | Which lines / branches executed during tests | `coverlet`, `c8`, `coverage.py`, `go test -cover`, `jacoco` | ≥ 90% line, ≥ 90% branch |
| **Case coverage** | Which behavioral scenarios have a dedicated test | Human/agent-enumerated from public API + requirements | ≥ **95%** |

Code coverage catches unexercised lines. Case coverage catches unexercised **scenarios** — error branches, boundary values, auth variants, empty/null inputs, concurrency interleavings. 100% line coverage with 30% case coverage is a trap (seen repeatedly in real codebases).

Testbuilder targets both. Case coverage is the stricter and more valuable metric.

## Enumerating cases

For each public entry point in scope (controller action, exported function, event handler, CLI command), list the cases that would need a test:

### Default case checklist per entry point

1. **Happy path** — valid input → expected success output
2. **Error branches** — one per distinct error case in the code (auth fail, not-found, conflict, validation fail, upstream fail)
3. **Boundary values** — empty input, max-length input, zero, negative, exactly-N (where N is a documented limit)
4. **Null / missing fields** — each optional field null, each required field missing
5. **Auth variants** — anonymous, wrong role, correct role, elevated role
6. **Concurrency** (if the endpoint mutates shared state) — two concurrent calls, interleaved reads/writes, race conditions
7. **Idempotency** (if declared) — same request twice, same result
8. **Ordering** (if list) — default order, reverse, pagination boundary, empty result set
9. **Currency / units** (if money) — zero, negative, minimum step (1 cent), currency mismatch
10. **Time** (if time-sensitive) — past, future, now, timezone variant, DST boundary

Not every case applies to every endpoint — use judgment. Typical non-trivial endpoint: 8–15 cases. Typical CRUD endpoint: 6–10 cases.

### Requirements → cases traceability

If the scope came from an `/implement` ticket or `/spike` ticket-ref doc, every requirement (REQ-*) in that doc must map to at least one case — this is the traceability contract from the upstream skill. Cases without a requirement source are still allowed (discovered during design) but flagged for review. In ad-hoc mode (legacy module, no upstream skill), there are no REQ-IDs to trace — proceed without the traceability pass.

## Input: `assess.json`

```json
{
  "scope": "...",
  "scopeFiles": ["Path/To/Service.cs", "..."],
  "existingTests": {
    "unit": [{"file": "...", "method": "...", "trait": "Unit"}],
    "integration": [...],
    "e2e": [...]
  },
  "lineCoverage": {"Path/To/Service.cs": 0.72, ...},
  "branchCoverage": {"Path/To/Service.cs": 0.65, ...},
  "cases": [
    {
      "id": "CASE-001",
      "entryPoint": "SpaceService.CreateSpaceAsync",
      "description": "Valid input → space created with owner assigned",
      "tierHint": "unit",
      "covered": true,
      "byTest": "SpaceServiceTests.CreateSpace_ValidInput_ReturnsSpace"
    },
    {
      "id": "CASE-002",
      "entryPoint": "SpaceService.CreateSpaceAsync",
      "description": "Duplicate name for same user → ConflictException",
      "tierHint": "unit",
      "covered": false,
      "byTest": null
    },
    ...
  ]
}
```

## Output: `gap-analysis.json`

```json
{
  "missingCases": [
    {
      "caseId": "CASE-002",
      "entryPoint": "SpaceService.CreateSpaceAsync",
      "description": "Duplicate name for same user → ConflictException",
      "tier": "unit",
      "priority": "high",
      "proposedTestCount": 1,
      "rationale": "Error branch with distinct status code; no existing test covers"
    },
    ...
  ],
  "coverageTargets": {
    "line": 0.90,
    "branch": 0.90,
    "case": 0.95
  },
  "summary": {
    "currentCaseCoverage": 0.52,
    "missingCount": 47,
    "byPriority": {"critical": 3, "high": 18, "medium": 20, "low": 6},
    "byTier": {"unit": 31, "integration": 12, "e2e": 4}
  }
}
```

## Multi-agent consensus

Dispatch 3 review agents. Each independently reads `assess.json` and produces its own `gap-analysis.json`. Compare:

- **High agreement** (≥ 80% overlap of caseIds + same tier + same priority) — merge with OR-union, tie-break priority to the higher rating.
- **Low agreement** — re-dispatch a reconcile round with each agent seeing the others' proposals. Keep iterating until 2 consecutive zero-issue rounds OR `maxReviewIterations` hit.

Agent prompts emphasize:

- Every public entry point covered by the case checklist above
- Tier hints consistent with BLACKBOX_BOUNDARY rules
- Priority consistent with impact (security, money, data integrity → critical)
- No duplicate cases; if two cases are semantically the same, merge

## Priority guidance

| Priority | Examples |
|---|---|
| **critical** | auth bypass, money calculation error, data corruption, PII leak, deadlock |
| **high** | primary user path failure, cross-user data access bug, required validation bypass |
| **medium** | edge case of a non-primary path, error message clarity, optional field handling |
| **low** | cosmetic, rare-but-valid edge case, backward-compat detail |

Phase 4 (Build) works priorities top-down. If time-boxed, `low` tail can be deferred to a follow-up with `untestable.json` or Known Gaps entries.

## Counting case coverage

```
case coverage = (cases where covered == true) / (cases total)
```

**Loop-back filter**: when Phase 6 loops back into Phase 2 with a residual gap, subtract every caseId already recorded in `<SESSION_DIR>/untestable.json` from the proposal list before emitting `gap-analysis.json`. Those cases have already been declared unreachable in this run; re-proposing them would create phantom gaps the second pass cannot close.

Cases marked `untestable` with a Known Gaps entry count as "deliberately excluded" and are removed from both numerator and denominator — but only up to 5% of total cases (the 95% target assumes up to 5% deliberate exclusion). More than that → the target is not met and the residual feeds Phase 6's loop-back decision (Phase 6 owns the "at most one loop-back per run" budget; Phase 2 does not re-enter itself directly from this file).

**Separate from the arithmetic**: every untestable case gets a Known Gaps entry in TESTING.md regardless of the 5% cap. The cap only governs denominator math for the 95% target; the documentation obligation is absolute.

## Common missed case categories (reviewer checklist)

Agents should specifically sweep for:

- **Permission scenarios** — if an endpoint has an authorization check, every role variant is a case.
- **Pagination edges** — empty list, single item, page-size boundary, invalid cursor.
- **Retry paths** — if retry logic exists, at least one test per retry count (0, max-1, max, max+1).
- **Webhook / async handlers** — duplicate delivery, out-of-order, poisoned message.
- **File uploads** — empty file, oversized file, wrong MIME, UTF-8 name with emoji, name with `../` traversal attempt.
- **Enum exhaustiveness** — every enum value handled (or explicitly rejected).

Agents that miss these categories score lower in consensus scoring.
