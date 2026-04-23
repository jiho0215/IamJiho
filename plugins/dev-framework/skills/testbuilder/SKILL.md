---
name: testbuilder
version: 1.0.0
description: "Use this skill aggressively whenever the user's request touches testing, test coverage, test organization, skip cleanup, mock/Docker decisions, TESTING.md, or CI test workflows — even if they don't say '/testbuilder' or use formal jargon. Standalone testing workflow that takes any repo state (TDD starter tests from /implement, legacy tests, manual tests, or nothing) and builds it into a formalized, complete test suite at 95%+ case coverage across unit, integration, and E2E tiers, organized under one TESTING.md per repo. Operates as a pure function of repo state; does NOT depend on /implement having run. Enforces skip-test hygiene (no empty shells, no false 'verified elsewhere' claims, tracking-issue-and-exit-criterion required), the mock-vs-docker dependency rule (3rd-party → mock; internal services → Docker; never invert), the blackbox-vs-whitebox boundary (E2E has no ProjectReference to source; compose uses image: tag only), and CI workflow hygiene (no orphan projects, no redundant runs, filters match traits). 6 phases: Assess → Gap Analysis → Design → Build → Document (TESTING.md) → Verify. Trigger on any of: '/testbuilder', 'build the full test suite', 'fill test coverage gaps', 'standardize testing docs', '95% case coverage', 'organize our tests', 'our tests are a mess', 'clean up the test suite', 'add tests for X', 'write more tests', 'coverage is low', 'audit our skips', 'flaky tests', 'why is this test skipped', 'should this be a mock or Docker', 'where do integration tests live', 'scaffold TESTING.md', 'testing is neglected', '테스트 더 써줘', '커버리지 올려줘', '테스트 정리해줘', 'TESTING.md 만들어줘'."
---

# `/testbuilder` — Standalone Testing Framework

Take whatever tests exist in a repo — or none at all — and build them into a documented suite organized by unit / integration / E2E, with one `TESTING.md` as the ledger. Target **95% case coverage**.

## Concepts

### What "case coverage" means

Not line coverage, not branch coverage. **Case coverage** = the fraction of behavioral scenarios that have a dedicated test: happy path, each error branch, each boundary, each auth variant, each null/empty input, each concurrency interleaving. A codebase can hit 100% line coverage with 30% case coverage — common trap. 95% is the target because the last 5% (obscure race conditions, hardware edge cases) has diminishing returns; below 95% there are usually real bugs hiding.

### Operating principle

Treat the repo's current state as input. Whatever tests exist when you start — TDD starter tests from `/implement`, legacy tests, manual tests, or nothing — are raw material. `/implement` does not need to have run. If it did, its tests are just more input for Phase 1.

When the caller supplies an epic ID, participate in the shared event log used by sibling skills `/spike` and `/implement` (the epic-scoped `<SESSION_DIR>/events.jsonl` they read on resume; `<SESSION_DIR>` is defined in Pre-Workflow step 3).

Without an epic ID, run in ad-hoc mode against a legacy module — a first-class use case. Ad-hoc mode skips event-log plumbing (Pre-Workflow's `session.started` and `config.snapshot.recorded` emissions — steps 6–7) and uses single-agent review instead of multi-agent consensus in Phases 2 and 5. The 6-phase workflow, the 95% case-coverage target, and standards enforcement all still apply — only the cross-skill coordination degrades.

## Invocation Modes

Parse `$ARGUMENTS`. Route to the first matching branch:

| Args match | Mode | Section |
|---|---|---|
| `--init` | Scaffold TESTING.md + CI skeleton for a new/legacy repo | Section I |
| `--audit` (with EPIC-ID or module) | Report gaps only, no writes | Section A |
| `--status` | Show testbuilder status and exit | see Status below |
| `--from N` | Resume at phase N | see Resume below |
| Ticket ID, epic ID, or module path | Full 6-phase build (default) | Section B |
| Empty args | Ask user for target scope, then route to Section B | — |

## Pre-Workflow (runs for every mode)

Before entering any section, execute these steps in order:

1. **Ensure config** — `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/ensure-config.sh`. Creates `~/.claude/autodev/config.json` with defaults if absent.
2. **Resolve scope**:
   - `--init`: the target is the repo root. No ticket/epic required.
   - Full build or `--audit`: read epic ID / ticket ID / module path from `$ARGUMENTS`. If only a module path, synthesize a scope slug from it (e.g., `BuckitApi/Services/Advisor` → `advisor`).
3. **Resolve epic session folder** — `SESSION_DIR = ~/.claude/autodev/sessions/{repo}--epic-{epicId}/`. Sanitize `{repo}` and `{epicId}` by replacing any character not in `[A-Za-z0-9._-]` with `-` and collapsing runs of `-` (so `buckit/api` → `buckit-api`, `EPIC#42` → `EPIC-42`). For `--init` or ad-hoc module scope, use `{repo}--testbuilder-{scopeSlug}` with the same sanitization.
4. **Locate TESTING.md** — the repo's testing source of truth:
   - Look for `<repo>/TESTING.md` first (root-level).
   - If absent, check `<repo>/docs/TESTING.md`.
   - If still absent, **Section I (init)** is a prerequisite. Before routing there, persist `<SESSION_DIR>/pending-mode.json` with `{originalMode, originalArgs}`. Section I's final step re-dispatches back to the caller's mode using this file — without it, Section I would exit silently, leaving the user's original intent unfulfilled.
   - **Audit mode exception (`--audit`)**: do NOT route to Section I — audit is read-only and must not create files outside `<SESSION_DIR>/`. Instead, report `"TESTING.md missing"` as the first audit finding and continue Section A.
5. **Bind `$MODE` and `$SCOPE`** — set `MODE` to the routed mode name from the Invocation Modes table (`"testbuilder"`, `"testbuilder-init"`, `"testbuilder-audit"`, `"testbuilder-resume"`, or `"testbuilder-status"`) and `SCOPE` to the resolved scope from step 2 (epic ID, ticket ID, or scope slug). The next two steps reference these.
6. **Emit `session.started`** — but skip this emission if `<SESSION_DIR>/pending-mode.json` exists on entry (meaning Section I is re-dispatching back to the caller's mode; the original call already emitted `session.started`, and a second emission would double-count the run in event-log consumers):
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh session.started \
     --actor orchestrator \
     --data "$(jq -cn --arg mode "$MODE" --arg scope "$SCOPE" \
       '{mode:$mode, scope:$scope, skill:"testbuilder"}')"
   ```
7. **Emit `config.snapshot.recorded`** — capture coverage targets from config:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh config.snapshot.recorded \
     --actor orchestrator \
     --data "$(jq -c '.pipeline | {testCoverageTarget, caseCoverageTarget, modelProfile}' ~/.claude/autodev/config.json)"
   ```

## Companion References (read on demand)

| Reference | When to read |
|---|---|
| `references/standards/HYGIENE.md` | Phase 4 (Build) and Phase 5 (Document) — skip policy, empty-shell ban, truth check |
| `references/standards/DEPENDENCY_POLICY.md` | Phase 3 (Design) — mock vs Docker decision per dependency |
| `references/standards/BLACKBOX_BOUNDARY.md` | Phase 3 (Design) — where each test tier physically lives |
| `references/protocols/coverage-gap-analysis.md` | Phase 2 (Gap Analysis) — how to compute the 50%→95% diff |
| `references/protocols/ci-organization.md` | Phase 4 (new project wiring) and Phase 6 (Verify) — CI workflow hygiene |
| `references/templates/TESTING_MD_TEMPLATE.md` | Section I (init) — TESTING.md skeleton |
| `../implement/references/methodology/TESTING_STRATEGY.md` | Phase 1 — optional: 4-tier strategy detail, if `/implement` is installed |
| `../implement/references/protocols/multi-agent-consensus.md` | Phase 2 and Phase 5 — multi-agent gap + doc-consistency reviews, if `/implement` is installed |
| `../implement/references/autonomous/events-schema.md` | Event type catalog, if `/implement` is installed |

Paths starting with `../implement/` are relative to this SKILL.md's directory and resolve only when the sibling `/implement` skill is installed in the same plugin (common case in the dev-framework plugin). When `/implement` is not installed (standalone testbuilder use), these references are optional. Session-dir sanitization is inlined above (Pre-Workflow step 3). Multi-agent consensus falls back to a single review agent per phase; event emission is a no-op if the hook scripts are absent. The core workflow — 6 phases, enforcement of the standards files in `references/standards/` — is self-contained in this skill.

## Multi-Agent Consensus

Phases 2 and 5 run multi-agent consensus when an epic ID is supplied AND `/implement` is installed (so the consensus protocol reference is resolvable):

- `agents: 3`
- `max_iterations: 10` (from `config.pipeline.maxReviewIterations`)
- `zero_threshold: 2` (from `config.pipeline.consecutiveZerosToExit`)
- Full protocol: `../implement/references/protocols/multi-agent-consensus.md`

**Standalone fallback** (no epic ID, or `/implement` not installed): run a single review agent per phase instead. The agent reads the phase's input artifact (`assess.json` for Phase 2, updated `TESTING.md` + `design.json` + `untestable.json` for Phase 5), produces a flat list of issues, and you fix them in one pass. No iteration loop. The exit criterion becomes "reviewer reports zero issues on the fixed state." This is weaker than full consensus but reliable enough for ad-hoc use.

**In full consensus mode**, never short-circuit by applying fixes and declaring the round "zero-issue" without re-dispatching. The reason: an un-reviewed fix can introduce new issues the prior round wasn't looking for. Only the agents, looking at the latest state, can attest to zero. (Standalone fallback has no multi-round loop, so this rule does not apply — but its single review must still see the final fixed state before exit.)

The event log for the current scope is at `<SESSION_DIR>/events.jsonl`; every read in this skill that references "events" means that file.

---

## Section B — Full 6-Phase Build (Default)

The full workflow. Run phases sequentially. The orchestrator wraps each phase body in `phase.started` / `phase.completed` events (emission is a no-op if hook scripts are absent — phase bodies themselves do not need to emit).

### Phase 1 — Assess

**Goal**: capture current state. What code exists in scope? What tests already exist? What does coverage look like today?

1. **Enumerate scope** — list source files in scope (module path, or all files touched by the epic's tickets per progress-log). Output: `scopeFiles[]`.
2. **Enumerate existing tests** — find test files that reference `scopeFiles[]`. Classify each as unit / integration / E2E per [BLACKBOX_BOUNDARY.md](references/standards/BLACKBOX_BOUNDARY.md) rules.
3. **Run coverage** — use the repo's coverage tool (`coverlet`, `c8`, `coverage.py`, `go test -cover`, `jacoco`). Capture per-file line + branch coverage.
4. **Enumerate cases** — for each public function/endpoint in scope, list the cases needed for **case coverage** (happy path, each error branch, each boundary, each auth variant, each null/empty input, each concurrency interleaving if applicable). This is the **case coverage denominator**.
5. **Record current state** — write `<SESSION_DIR>/assess.json` with `{scopeFiles, existingTests[tier], lineCoverage, branchCoverage, cases: [{id, description, covered: bool, byTest: null | testPath}]}`.

**Exit criterion**: `assess.json` exists and enumerates every public surface in scope.

### Phase 2 — Gap Analysis (multi-agent consensus when available)

**Goal**: identify the gap between current state and 95% case coverage. In full consensus mode, dispatch 3 review agents; each proposes a **gap list** independently, then consensus round reconciles. In standalone fallback mode (see Multi-Agent Consensus section above), run a single review agent whose gap list is the Phase 2 output — no iteration loop.

Follow [coverage-gap-analysis.md](references/protocols/coverage-gap-analysis.md).

Each agent reads `assess.json` and produces:

- **Missing cases** — cases in `cases[]` where `covered == false`
- **Tier assignment** — which tier (unit / integration / E2E) each missing case belongs to per BLACKBOX_BOUNDARY
- **Priority** — `critical` (security, money, data integrity), `high` (primary user path), `medium`, `low`
- **Proposed test count** — rough estimate

**Consensus exit**: 2 consecutive zero-disagreement rounds — the identity tuple `(caseId, tier, priority)` matches across all agents' gap lists — OR `maxReviewIterations` hit. Phase 2 agents produce *proposals* (a gap list), so the exit measures agent convergence on the proposed list — not the correctness of any downstream tests, which get their own review gates later.

**Output**: `<SESSION_DIR>/gap-analysis.json`. If iteration cap hit without 2-zero, log warning but proceed — the `low` priority tail is acceptable residual.

### Phase 3 — Design

**Goal**: for each gap in `gap-analysis.json`, decide dependency strategy and physical location.

For each missing case:

1. **Dependency strategy** — classify each dep as 3rd-party (→ mock) or internal (→ Docker), per [DEPENDENCY_POLICY.md](references/standards/DEPENDENCY_POLICY.md). Never invert. The full rule, rationale, and boundary-case answers live in that reference — open it when a dep is ambiguous.
2. **Tier placement** — pick unit / integration / E2E per [BLACKBOX_BOUNDARY.md](references/standards/BLACKBOX_BOUNDARY.md). That reference owns the definitions and the blackbox invariants (no `ProjectReference` from E2E, compose uses `image:` tag). Open it when tier placement is unclear.
3. **Test file assignment** — decide whether each case adds to an existing test file or creates a new one. Prefer adding to existing files when the subject matches; create new files only when classification changes.
4. **Trait assignment** — every test gets `[Trait("Category", "Unit|Integration|E2E")]` (or the repo's equivalent). CI filters depend on these traits being consistent.

**Output**: `<SESSION_DIR>/design.json` with `[{caseId, tier, file, method, deps: [{name, strategy: mock|docker}], trait}]`.

### Phase 4 — Build

**Goal**: write the tests per `design.json`. Enforce [HYGIENE.md](references/standards/HYGIENE.md) at write time.

For each design entry:

1. Write the test using the AAA pattern (arrange → act → assert). Empty shells inflate the test count without adding coverage — see [HYGIENE.md §1](references/standards/HYGIENE.md).
2. Apply repo convention for naming (verb-first, describes behavior, not implementation).
3. Apply the trait from design.
4. **If Phase 4 creates a new test project** (not just a new file in an existing project), follow the new-project wiring procedure in [ci-organization.md](references/protocols/ci-organization.md) immediately — otherwise the project becomes an orphan (no CI filter references it) and Phase 6's orphan check will fail.
Steps 5 and 6 below handle two distinct "can't test it here" scenarios that readers often confuse: step 5 = the case is *untestable at this tier* (escalate or record as Known Gap); step 6 = the case *is* testable and the test body exists, but execution must be suspended (valid `[Skip]` with contract). Keep them separate.

5. If a test cannot be meaningfully written in this tier (e.g., requires concurrency the in-memory DB can't model), **do not create a `[Skip]` shell for the untestable case**. Instead:
   - **Escalate the case to the next tier up** (unit → integration; integration → E2E). Append the escalated case to `<SESSION_DIR>/escalations.json` with `{caseId, fromTier, toTier, reason, newFile, newTrait}`. Do NOT mutate `design.json` in place — Phase 3 owns that artifact, and in-place mutation makes resume-from-Phase-4 read a corrupted input. The escalation file is a sidecar the later steps honor.
   - **Re-entry**: escalated cases go back into Phase 4's pending queue at the head of their new tier's pass. If the new tier's pass has already completed in this run, open a supplementary pass over just the escalated cases before declaring Phase 4 done. Exit criterion only counts cases that have been *built* (or recorded as untestable), not merely retiered.
   - If the case is untestable at every tier (including E2E), record in `<SESSION_DIR>/untestable.json` with reason. All writes to `untestable.json` (this step and the environment-failure diagnosis below) are **append-only with de-dup by `caseId`** — never overwrite. These go into TESTING.md Known Gaps in Phase 5.
6. **Separate case — disabling an existing test that can be written:** if you *can* write the test but it must be disabled (known flake awaiting quarantine, known-upstream-issue, pending fix), then `[Skip]` is appropriate. This is distinct from step 5 (case is untestable here) — here the test body exists, only its execution is suspended. Apply the skip contract in [HYGIENE.md §2](references/standards/HYGIENE.md). Every claim in a skip message (e.g., "covered by integration test X") must resolve to an actual test — verify with `grep` before committing.

After each test file write: run it locally (fast tier only — unit tests; Docker-dependent tiers run in Phase 6).

**On failure, diagnose before retrying — do NOT blindly mutate the test until it passes.** Classify the failure:

| Diagnosis | Signal | Action |
|---|---|---|
| **Source bug** | Test encodes a correct requirement; assertion fails because the code under test is wrong | Fix the source code. The test stays as-is. Append a JSONL record `{caseId, file, description}` to `<SESSION_DIR>/bugs-found.log` (the `.log` extension is conventional — the file is strict JSONL, one object per line). Additionally emit a `bug.found` event with the same payload if the hook scripts are available. |
| **Test bug** | Test's arrange/act/assert doesn't match the behavior being specified (wrong fixture, wrong assertion, typo) | Fix the test. Source is untouched. |
| **Environment failure** | Test imports fail, fixture unavailable, flaky dependency, missing config | Fix the harness (fixture, setup, config). Do NOT add retry logic to hide flakiness. If the dependency is not mockable in this tier, escalate the case to the next tier (unit → integration → E2E) and record in `untestable.json` if still not reachable. |
| **Requirement mismatch** | The case in `gap-analysis.json` is mis-specified (e.g., wrong expected behavior) | Park the case: append to `<SESSION_DIR>/mis-specified.json` with the corrected requirement, continue with other entries. Re-run policy below the table. |

**Mis-specification re-run policy**: at phase end, if `mis-specified.json` is non-empty, re-run Phase 2 **then Phase 3** before resuming Phase 4. Phase 2 alone isn't enough — its output (`gap-analysis.json`) feeds Phase 3, so changed cases invalidate `design.json`'s tier/dep/file assignments. Budget: **one** Phase 2+3 re-run per Phase 4 pass. If mis-specs re-appear after the re-run, abort to the caller with `mis-specified.json` as the deliverable — the requirements themselves need human review. Consensus remains the only authority that can retire a case (the "Never short-circuit" rule).

Never "fix" a failing test by weakening the assertion to match current (wrong) behavior. If the test is right and the code is wrong, that's a bug find — one of the most valuable things testbuilder produces.

Test must pass before moving to the next design entry — but "pass" means the diagnosis above has been applied, not that the test has been bent until green.

**Exit criterion**: every gap-analysis entry is either (a) a passing test (in its original tier or after successful escalation + build), or (b) in `untestable.json`. Entries only in `escalations.json` without a built test at the new tier do NOT satisfy exit — the supplementary pass must run. `mis-specified.json` must be empty at phase end (its contents get absorbed into the re-run gap-analysis); if the one-shot re-run budget was consumed and entries remain, Phase 4 aborts to the caller with `mis-specified.json` as the deliverable rather than declaring exit.

### Phase 5 — Document (update TESTING.md) (multi-agent consensus when available)

**Goal**: update the single `TESTING.md` so it reflects current reality. This is the repo's testing ledger.

**Review mode**: in full consensus mode, dispatch 3 doc-review agents (step 3 below). In standalone fallback mode (see Multi-Agent Consensus section), run a single doc-review agent over the same inputs; fix its findings in one pass; done.

1. Load the current `TESTING.md` (created in Section I if absent).
2. **Build the surviving-skip inventory** by running the bundled audit script:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/skills/testbuilder/scripts/skip-truth-audit.sh \
     --repo <repo-root> --out <SESSION_DIR>/skip-audit.json
   ```
   The script walks the test tree for `[Skip]`, `xit`/`xdescribe`, `@Disabled`, `@pytest.mark.skip`, and Go `t.Skip(...)`, extracts each skip's message, and for any message that claims coverage elsewhere ("covered in X", "verified by Y", "tested in Z") greps for the claim target and records whether it resolves. The output JSON has a `summary` (total / verified / unverified / noClaim / noTracking counts) and a `skips[]` list with the raw evidence per skip. Use this inventory directly for the Known Gaps section below, and let the `unverified` bucket flag false-claim skips for Phase 4 follow-up (either write the claimed test or rewrite the message to drop the claim). Running the script beats re-deriving the loop each time — the grep pattern set and framework regex list are subtle enough to be worth keeping in one place.
3. Update sections per [TESTING_MD_TEMPLATE.md](references/templates/TESTING_MD_TEMPLATE.md):
   - **Overview**: keep; update if new projects/folders introduced.
   - **Running locally**: update commands if Phase 6 added CI variants.
   - **CI**: reflect any new workflow or filter change from Phase 6.
   - **Writing new tests**: unchanged unless convention evolved.
   - **Known Gaps** (critical section): list every entry from `untestable.json`, every unresolved entry from `escalations.json` whose built test lives at a tier above the original (so readers know the case was tier-retargeted), and every surviving `[Skip]` from step 2. Each entry MUST include tier, reason, tracking link, exit criterion.
   - **Coverage table**: update per-module coverage numbers from Phase 6 results.
4. **In full consensus mode**, dispatch 3 doc-review agents. Each reads the updated TESTING.md against `design.json` + `untestable.json` + the skip inventory and flags:
   - False claims ("verified in X" when X doesn't exist)
   - Stale entries (referencing deleted tests)
   - Missing entries (tests built in Phase 4 but not documented)
   - Skip entries missing the required fields

**Consensus exit**: 2 consecutive zero-disagreement rounds (same definition as Phase 2 — a round where reviewing agents report no new findings on the current state).

**Output**: updated `TESTING.md` committed as part of the PR.

### Phase 6 — Verify

**Goal**: prove every tier runs green and coverage targets are met.

1. **Unit tier**: run all unit tests with the repo's CI filter. Must pass.
2. **Integration tier**: bring up Docker compose (per DEPENDENCY_POLICY). Run integration tests. Must pass.
3. **E2E tier**: bring up full stack. Run E2E suite. Must pass.
4. **Coverage measurement**: re-run coverage. Compare to Phase 1 baseline:
   - Line coverage target: the repo's config value (`testCoverageTarget`, default 90%)
   - Case coverage target: the repo's config value (`caseCoverageTarget`, default 95% — the testbuilder standard; lower it only with a documented rationale since below 95% there are usually real bugs hiding)
   - If either missed, loop back to Phase 2 and run Phases **2→3→4→5→6** again on the residual gap — not just Phase 2. New tests require new Phase 3 design, Phase 4 build, and Phase 5 documentation before Phase 6 can measure honestly. **At most one loop-back per testbuilder run**: before entering the loop-back, touch `<SESSION_DIR>/loopback.consumed` as a sentinel file. On any subsequent entry to Phase 6 (including after `--from N` resume), check this file — if present, loop-back is no longer available, and a missed target goes straight to the Known Gap documentation path below. This persists the budget across aborts and resumes so the one-loop-back cap holds no matter how the run is interrupted.
   - If the second Phase 6 coverage check still misses, document the remaining delta as a Known Gap entry in TESTING.md and accept the run — some residual cases are genuinely unreachable (physical hardware, third-party outage simulation, etc.) and bounded retries keep the skill from ping-ponging.
   - "One loop-back per run" refers to a Section B full build invocation (and any `--from N` resume continuing that build). Section A audit runs are independent — audits do not execute Phase 6 and do not consume the budget.
   - **On loop-back, the mis-specification re-run budget (Phase 4 table) resets**: the budget is per Phase 4 pass, and Phase 6 loop-back triggers a new pass through Phases 2→3→4, so a fresh mis-spec re-run is allowed.
   - **Phase 2 on loop-back must subtract existing `untestable.json` caseIds** from its proposal list (they've already been declared unreachable) so the loop doesn't re-propose them as phantom gaps.
5. **CI wiring** — run the bundled auditor:
   ```
   python3 ${CLAUDE_PLUGIN_ROOT}/skills/testbuilder/scripts/ci-audit.py \
     --repo <repo-root> --out <SESSION_DIR>/ci-audit.json
   ```
   The script parses `.github/workflows/*.yml`, enumerates test projects (heuristics for `.csproj`/`package.json`/`pytest`/`go.mod`; override with `--test-globs` if the repo uses something custom), and emits a JSON report with `orphans[]`, `redundancies[]`, and `filterWarnings[]`. Follow up per [ci-organization.md](references/protocols/ci-organization.md):
   - Fix every orphan (add a CI job that runs it, or delete the project if dead)
   - Annotate every redundancy with an intent comment, or consolidate
   - Resolve every filter warning (replace fragile `FullyQualifiedName!~` with trait filters; add comments to undocumented filters)
   - Spot-check that filter syntax matches actual test traits (the script flags fragile patterns; trait↔filter alignment still needs a human eye when traits were renamed mid-run)

**Exit criterion**: all tiers pass locally, all tiers either already run in CI or now wired to do so, coverage targets met.

**Emit `phase.completed` for phase 6 with summary** — line coverage %, case coverage %, test counts per tier, skip count, known-gaps count.

---

## Section I — Init (repo scaffolding)

**Goal**: create the testing ledger in a repo that lacks one.

1. Verify no `TESTING.md` exists at root or `docs/`.
2. Copy [TESTING_MD_TEMPLATE.md](references/templates/TESTING_MD_TEMPLATE.md) to `<repo>/TESTING.md`.
3. Populate the **Overview** section by scanning the repo:
   - Detect stack (package.json, *.csproj, pyproject.toml, go.mod).
   - Detect existing test projects/folders.
   - Infer tier assignment per [BLACKBOX_BOUNDARY.md](references/standards/BLACKBOX_BOUNDARY.md).
4. Populate the **Running locally** section with the repo's real commands (detected from existing scripts, Makefiles, or tool conventions).
5. Populate the **CI** section from existing workflows under `.github/workflows/` (or note "local-only" if intentional).
6. Leave **Known Gaps** empty with a pointer to /testbuilder for future updates.
7. Commit as a standalone PR titled `chore(testing): scaffold TESTING.md ledger`.

**Resume the caller's original mode** — read `<SESSION_DIR>/pending-mode.json`, delete the file, and re-dispatch on its `originalMode` + `originalArgs`. If the file is absent (Section I was invoked directly via `--init`), stop here.

---

## Section A — Audit (report only, no writes)

**Goal**: run Phases 1, 2, and 5's review pass against the current state without modifying source code or `TESTING.md`.

Audit does **not** go through the orchestrator phase-event wrapper. If `--status` is run after an audit, it should see an audit run, not a stale real-build phase; each step below emits its own `phase.started`/`phase.completed` event with `{audit: true}` in the data payload so Status can distinguish audit runs.

1. Phase 1 (Assess) — read-only inspection of source. Writes `<SESSION_DIR>/assess.json` for the audit's own reasoning.
2. Phase 2 (Gap Analysis) — single agent (not consensus; audit is a fast inspection). Writes `<SESSION_DIR>/gap-analysis.json`.
3. Phase 5 review pass — check `TESTING.md` for false claims, stale entries, missing entries, skip hygiene violations.
4. **Write `<SESSION_DIR>/audit.json`** — persist structured findings for later diffing across runs. Schema:
   ```json
   {
     "timestamp": "ISO-8601",
     "scope": "...",
     "testingMdPresent": true,
     "coverageGaps": [{ "caseId": "...", "entryPoint": "...", "tier": "...", "priority": "..." }],
     "hygieneViolations": [{ "file": "...", "test": "...", "rule": "...", "detail": "..." }],
     "docInconsistencies": [{ "section": "...", "kind": "false-claim|stale|missing|skip-fields-missing", "detail": "..." }]
   }
   ```
   If TESTING.md is absent (audit-mode exception from Pre-Workflow step 4), set `testingMdPresent: false` and emit a synthetic doc inconsistency `{section: "root", kind: "missing", detail: "TESTING.md not present — run /testbuilder --init"}`; other sections still populate from source inspection.

**Output**: a markdown report to stdout with three sections — coverage gaps, hygiene violations, doc inconsistencies. Audit mode writes only to `<SESSION_DIR>/` (assess.json, gap-analysis.json, audit.json) — source code and `TESTING.md` are never touched.

---

## Status

On `--status`: read the most recent events from `<SESSION_DIR>/events.jsonl`. Print:

- Current phase
- Coverage baseline (Phase 1 result if reached)
- Gap count (Phase 2 result if reached)
- Designed tests / built tests / verified tests counts
- Outstanding issues from the last consensus round

---

## Resume

On `--from N` (N ∈ 2..6; `--from 1` is a no-op — just run normally): emit `phase.skipped` events for phases 1..N-1 if their outputs exist in `<SESSION_DIR>`, then enter phase N. Refuse to skip a phase whose input artifact is missing.

Phase input map (what each phase needs to resume from):

| Phase | Required input artifacts |
|---|---|
| 2 (Gap Analysis) | `assess.json` |
| 3 (Design) | `gap-analysis.json` |
| 4 (Build) | `design.json` (read-only) — see note below on sidecar merge |
| 5 (Document) | `design.json`, `untestable.json` + `escalations.json` (both may be empty), plus a fresh scan of the test tree for surviving `[Skip]` attributes (re-derived from source — step 2 in Phase 5) |
| 6 (Verify) | built tests on disk (no JSON artifact needed) |

**Phase 4 sidecar merge note**: when resuming into Phase 4, if `escalations.json` or `mis-specified.json` exist from a prior partial run, merge their unbuilt entries into the pending queue before starting — otherwise escalated or parked cases from the interrupted run would be silently dropped.

**Resume-into-Phase-5 precondition**: Phase 5 assumes `mis-specified.json` is empty (Phase 4's exit criterion). If a Resume targets Phase 5 directly and finds a non-empty `mis-specified.json` (from an aborted Phase 4), refuse — emit a `resume.blocked` event and tell the caller to `--from 4` instead so the parked cases get addressed.

---

## Relationship to `/implement`

**Independent.** No dispatch, no handoff contract, no shared-standards coupling. `/implement` may run first and leave TDD starter tests; it may never run at all. Either way, `/testbuilder` treats whatever exists in the repo as Phase 1 raw material.

`/testbuilder` owns, unconditionally:

- The `TESTING.md` ledger (one per repo)
- Tier organization and trait consistency
- Dependency policy enforcement (mock vs Docker)
- Blackbox/whitebox boundary enforcement
- CI wiring hygiene
- Case-coverage gap fill to 95%
- Skip discipline

Phase 5 (Document) has absolute authority: any existing test that violates [HYGIENE.md](references/standards/HYGIENE.md), [DEPENDENCY_POLICY.md](references/standards/DEPENDENCY_POLICY.md), or [BLACKBOX_BOUNDARY.md](references/standards/BLACKBOX_BOUNDARY.md) is rewritten or removed — regardless of who wrote it.

If an epic ID is supplied, `/testbuilder` joins the shared event log so sibling skills can see testbuilder progress when they resume from checkpoint. Otherwise it runs in its own session folder (`{repo}--testbuilder-{scopeSlug}`).
