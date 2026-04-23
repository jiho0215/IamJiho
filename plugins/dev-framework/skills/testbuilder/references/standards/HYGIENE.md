# Test Hygiene

Rules that govern what a test is allowed to look like. Enforced in Phase 4 (Build) and Phase 5 (Document). Violations block Phase 6 (Verify) from declaring victory.

## 1. No empty test shells

A test function that contains only comments, `TODO`, or is empty under a `[Skip]` attribute is **not a test**. It is a false signal in the test count.

**Forbidden**:
```csharp
[Fact(Skip = "DateTime comparison issue with InMemory DB - boundary testing requires real DB")]
public async Task SendFriendRequest_Exactly48HoursAfterReject_Succeeds()
{
    // This test requires real DB for accurate DateTime comparison
    // In-Memory DB doesn't handle DateTime.UtcNow.AddHours(-48) correctly
}
```

The body is empty. The skip reason points nowhere. This inflates the test count and creates false coverage confidence.

**Required**: either delete it, or write arrange + act + assert (even if the tier has to change — see Phase 4 escalation rule).

## 2. Skip is a last resort with a contract

A `[Skip]` / `xit` / `@unittest.skip` / `t.Skip()` attribute is allowed ONLY when ALL of the following hold:

1. **Tracking link** — issue URL or ID. No "TODO" without a ticket. Example: `Skip = "Tracked: GH-1234"`.
2. **Exit criterion** — a specific, observable condition under which the skip is removed. Example: `"Unblocked when PR #1234 ships the HookedToolExecutor fix"`.
3. **Truthful message** — any claim in the skip message must be verifiable. If it says "covered in integration tests", a grep across the integration suite MUST find a test for the same behavior. If no such test exists, the claim is a lie and the skip is invalid.
4. **Not stale** — the skip was last touched within the last 90 days OR has an explicit SLA extension recorded in `TESTING.md` Known Gaps.

**Forbidden skip patterns**:

| Pattern | Why it fails |
|---|---|
| `Skip = "TODO: fix this"` | No tracking, no exit criterion. |
| `Skip = "verified in integration tests"` (when no such integration test exists) | False claim. Coverage lie. |
| `Skip = "flaky"` with no tracking link | No SLA, no owner, no plan. |
| `Skip = "requires actual database"` with no tier escalation | The test should live in the integration tier, not be skipped at the unit tier. |

## 3. Skip message truthfulness (grep test)

Phase 5 runs a grep audit over every surviving `[Skip]`. For each skip whose message claims coverage elsewhere ("verified in X", "covered by Y", "tested in Z"), run:

```
grep -rn "<claimed test name or behavior>" <claimed location>
```

Zero matches → the claim is false → the skip is invalid. Either write the claimed test, or rewrite the skip message to drop the false claim.

## 4. Tier escalation before skip

If a test CAN be meaningfully written in a higher tier, escalate instead of skip:

| Skipped at | Escalation |
|---|---|
| Unit tier (InMemory DB semantics differ, real locking needed, timing-dependent) | Write as integration test with Docker-backed real DB |
| Integration tier (cross-service flow, real external contract) | Write as E2E test |
| E2E tier (flake from external instability) | Mock the unstable external with a fixture-recorded fake; escalate integration, don't delete E2E — but keep the E2E gated to non-blocking job |

Escalation is the default. Skip is the exception.

## 5. No disabled tests via `.only` or `.skip` leaks

Test framework focus/skip helpers used during local debugging MUST NOT be committed:

- Jest: `describe.only`, `it.only`, `xdescribe`, `xit` (use `it.skip` with contract if needed)
- Playwright: `test.only`
- Vitest: `.only`, `.skip.if(true)` without condition
- Go: `t.Skip()` without message
- Python: `@unittest.skip("")` with empty reason

Phase 4 scans the diff for these and fails the build step if found.

## 6. Known Gaps ledger

Every surviving `[Skip]`, every entry in `<SESSION_DIR>/untestable.json`, and every unresolved entry in `<SESSION_DIR>/escalations.json` whose built test lives at a tier above the case's original tier (so readers know the case was tier-retargeted rather than tested in place) MUST appear in `TESTING.md` Known Gaps. Ledger format per entry:

```markdown
### GAP-ID — short title

- **Tier**: unit | integration | e2e
- **Why**: one-sentence reason
- **Tracking**: <issue URL>
- **Exit criterion**: when is this resolved?
- **Last reviewed**: YYYY-MM-DD
```

If it's not in the ledger, Phase 5 consensus flags it.

## 7. No false coverage inflation

The following patterns are forbidden because they increase the test count without increasing meaningful coverage:

- Tests that only assert the constructor didn't throw
- Tests that re-verify the mocked dependency's mocked return value
- Snapshot tests with no manual review discipline (snapshot regenerated on every run)
- Duplicate tests across tiers without a reason (e.g., same assertion in unit and integration when integration is the only place it's meaningful)

Phase 4 reviewers flag these during the build. Phase 5 consensus rechecks.

## 8. Deterministic or explicitly quarantined

Every test MUST be:

- **Deterministic** — same input → same result, every run, on every platform the CI targets.
- OR **explicitly quarantined** — moved to a separate job or filter with a tracking link and an SLA.

Flake mitigation (retry, sleep, jitter) without a tracking entry is forbidden. Retries mask regressions.
