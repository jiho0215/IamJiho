# CI Organization Protocol

Phase 6 of `/testbuilder`. Ensures that the tests built in Phase 4 are actually run by CI, without orphaned projects or redundant runs. Inspired by real audit findings (orphan `Buckit.Plaid.IntegrationTests` filtered out of one job but never run by any other, redundant advisor-ci runs of the same unit projects already covered by test.yml).

## Audit checklist

For each CI workflow file under `.github/workflows/` (or the equivalent for GitLab / Jenkins / Circle):

### 1. Orphan detection

For every test project in the repo, there MUST exist at least one CI job whose filter-after-enumeration includes it. Algorithm:

```
for project in <all test projects>:
    matched = false
    for job in <all CI jobs>:
        if project matches job.filter AND project is in job.scope:
            matched = true
            break
    if not matched:
        flag project as ORPHAN
```

A project explicitly filtered OUT of a job (e.g., `FullyQualifiedName!~Buckit.Plaid.IntegrationTests`) must be explicitly run by ANOTHER job. Otherwise it's an orphan — the tests exist, compile, maybe even pass locally, but never run in CI.

**Fix**: either add a CI job that runs the orphaned project, or delete the project if it's dead.

### 2. Redundancy detection

For every test project, count how many CI jobs run it. If a project runs in multiple jobs, the redundancy must be intentional:

| Intentional redundancy | Not intentional |
|---|---|
| Unit job (fast feedback) + coverage job (slow, full) | Two jobs running the same tests with slightly different filters by accident |
| Full run on main, fast subset on PR | Path-filtered workflow duplicating main workflow's coverage |
| Smoke subset before full run (gate) | Forgotten migration leftover |

**Fix**: consolidate or annotate with a comment explaining why the duplication exists.

### 3. Filter correctness

For each job's test filter, parse and verify:

- **Trait filters match trait reality** — if the filter is `Category=Unit`, every test with `[Trait("Category", "Unit")]` is included AND no test without that trait matches. Phase 4 enforces trait consistency; this step verifies.
- **FQN exclusion is defensive, not primary** — prefer `Category=Unit` over `FullyQualifiedName!~Integration`. FQN filters break silently when names change.
- **Every test project the filter CLAIMS to run is actually in the scope** — `dotnet test <project>.csproj` runs a specific project; `dotnet test` at solution root runs all. Be explicit about which.

### 4. Comment-documented intent

Every non-trivial filter or exclusion MUST have a comment explaining why. Example from a real repo:

```yaml
# Buckit.BuckitApi.IntegrationTests (the `E2EApi` goldens) lives in the
# buckit-e2e repo now and never runs in CI. Buckit.IntegrationTests and
# Buckit.Plaid.IntegrationTests are whitebox and stay here.
run: dotnet test --filter "Category!=Integration&..."
```

Without the comment, future maintainers cannot tell whether the exclusion is current or stale.

### 5. CI-vs-local parity

Tests pass locally ≠ tests pass in CI. Sources of drift:

- **Docker services** — local developer has a long-running compose up; CI brings services up fresh each run. Flakes appear in CI first.
- **Timezone** — local machine is `America/New_York`; CI runner is UTC. DateTime tests flake.
- **Culture** — local `en-US`; CI `en_US.UTF-8`. Number/date parsing differs.
- **File system** — local case-insensitive (macOS/Windows); CI case-sensitive (Linux). File path tests flake.

Phase 6 verification must either:

- Bring up services identically to CI (use the same compose file)
- OR explicitly document the drift in Known Gaps

## New-project wiring procedure

When Phase 4 (Build) creates a new test project:

1. **Add to solution** (if using one: `dotnet sln add`, `pnpm workspace`, etc.).
2. **Add `[Trait]` consistent with the new tier**.
3. **Add to the appropriate CI job**:
   - Unit tier project → existing unit job's scope (usually solution-wide with a `Category=Unit` filter — no workflow change needed if trait is set).
   - Integration tier project → integration job. May require explicit `<project>.csproj` path in the job step.
   - E2E tier project → E2E workflow (often in a sibling repo).
4. **Remove stale exclusions** — if a FQN exclusion existed to work around the now-nonexistent project, delete it.
5. **Run the workflow on a PR** before merging to main. CI-vs-local parity test.

## Branch protection expectations

The CI jobs that RUN tests should gate main merge. The CI jobs that only REPORT (coverage, lint-only, docs) may or may not gate. Phase 6 verification reports the current branch protection state in the summary; changing it is a repo-admin action outside the skill's scope.

## Common CI anti-patterns (flag in Phase 6)

| Anti-pattern | Why it's bad |
|---|---|
| `continue-on-error: true` on the test step | Silent failures; coverage rots |
| Filter uses FQN substring but the substring is fragile (`!~Integration` catches projects named `IntegrationHelpers` unintentionally) | False exclusions |
| Multiple workflows path-filter the same source tree with overlapping scopes | Duplicate runs, duplicate flakes, no coverage gain |
| `needs:` dependency chains that lose test signal on skip (upstream fails silently → downstream skips → green check) | False green |
| Coverage threshold missing OR set to a low floor that never fails | Coverage target is aspirational, not enforced |
| Secrets required for a test tier that's supposed to be mock-based | Mock-vs-Docker policy violation; tests hit real 3rd-party |

## Output of Phase 6

Phase 6 emits `phase.completed` with a summary event containing:

```json
{
  "phase": 6,
  "lineCoverage": 0.92,
  "branchCoverage": 0.88,
  "caseCoverage": 0.96,
  "testCounts": {"unit": 2584, "integration": 189, "e2e": 47},
  "skipCount": 4,
  "knownGapsCount": 4,
  "ciWorkflowsAudited": ["test.yml", "advisor-ci.yml"],
  "orphansFound": 0,
  "redundanciesFound": 1,
  "orphansFixed": 0,
  "redundanciesAnnotated": 1
}
```
