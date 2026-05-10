---
name: implement
version: 2.0.0
description: |
  Pure execution skill. Takes an APPROVED freeze doc produced by /spike and runs three
  execution phases — E1 Execute → E2 Verify → E3 Finalize — to produce a reviewed,
  rigorously-tested PR. No planning, no requirements gathering: every design decision
  is read-only from the freeze doc (hash-locked) and src/** edits remain gated until
  startup verifies status APPROVED, approvedHash matches, and §11 Prerequisites are
  merged. TDD throughout; multi-agent consensus review at E1 and E2 (10 max iterations,
  2 consecutive zeros to exit). Single user gate (GATE 2 at end of E3) is always
  interactive. Operates against the same epic-scoped event log as /spike, so wake()
  returns cross-skill state in one call.

  Use whenever a freeze doc is ready to ship. If you don't have a freeze-doc-path,
  run /spike story <ticket> (or /spike <epic>) first. Trigger on: '/implement',
  '/implement <freeze-doc-path>', 'execute this ticket', 'run the freeze doc',
  'ship this freeze doc', 'implement this story', 'take this freeze doc and ship it',
  '/implement --from N <freeze-doc-path>', '/implement --status <freeze-doc-path>'.
---

# `/implement` — Pure Execution Skill (v2)

You are orchestrating one rigorous execution run against an **already-approved** freeze doc. `/implement` does no planning. Requirements, research, architecture, test plan, and edge-case list all live in the freeze doc — produced upstream by `/spike` and locked at GATE 1 with a sha256 over the canonical body. Your job is to make the code, tests, docs, and PR match the freeze doc, and to surface drift loudly if reality contradicts what the doc assumed.

There is one user gate: **GATE 2** at the end of E3. GATE 1 already happened in spike; you are downstream of that approval. Move slow, fix root causes, and never edit the freeze doc body — if you must, halt and tell the user to re-spike via `/spike --revisit`.

## Invocation

Parse `$ARGUMENTS`. Route to the first matching branch:

| Args match | Mode |
|---|---|
| `--status <freeze-doc-path>` | Show session status against the freeze doc and exit (see `--status` Handler) |
| `--from N <freeze-doc-path>` | Resume at phase E1/E2/E3 (N=1,2,3); see Resume Handler |
| `<freeze-doc-path>` (a single non-flag arg) | Start E1 against the given freeze doc |
| Empty or no path | **Error:** `"freeze-doc-path required. Run /spike <ticket> first to produce one."` Exit without entering Pre-Workflow. |

The freeze-doc-path is REQUIRED in every non-error branch. There is no longer a `--autonomous` mode, no `init`/`review`/`test`/`docs` standalone modes, and no ad-hoc-ticket fallback — these were planning-time concerns that now live in `/spike` (`/spike story` for ad-hoc; spike provides its own status/resume).

## Pre-Workflow / 7-Step Startup

Before entering E1, execute these steps **in order**. Each step's failure mode is concrete and halts the workflow with the message shown — do not proceed past a failed step.

1. **Parse freeze doc.** Read the file at `<freeze-doc-path>`. Parse YAML frontmatter and `## §N` section headers. On `ENOENT` or unparseable frontmatter, halt with: `"Freeze doc not found or unparseable: <path>. Run /spike story <ticket> first, or pass the correct path."`

2. **Verify `status == APPROVED`.** Read the frontmatter `status` field. If absent, `DRAFT`, `PENDING_APPROVAL`, `SUPERSEDED`, or anything other than `APPROVED`, halt with: `"Freeze doc status is <status>, expected APPROVED. Re-run /spike to land GATE 1 approval."`

3. **Verify `approvedHash` matches canonical body.** Run:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/freeze-doc-hash.sh verify "<freeze-doc-path>"
   ```
   On non-zero exit, halt with: `"Freeze doc body modified after approval (hash mismatch). The contract is broken. Re-run /spike to re-approve (a new approvedHash will be issued), or revoke this freeze doc and start a new ticket."` Do not attempt to silently fix the hash — the immutability is the whole point.

4. **Verify §11 Prerequisites all merged.** With `SESSION_DIR` exported (computed in step 5; if step 5 hasn't run yet, compute it ahead of time here — the resolution algorithm is deterministic), run:
   ```bash
   SESSION_DIR="$SESSION_DIR" bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/freeze-doc-prereqs.sh "<freeze-doc-path>"
   ```
   The script extracts each `- \`<ticket-id>\` --` row under `## §11 Prerequisites` and confirms each via either a `ticket.merged` event in `events.jsonl` or a matching merge commit reachable from `HEAD`. On non-zero exit, halt with: `"Prerequisites not satisfied: <list from stderr>. Merge prerequisites first, or run /implement on them in dependency order."`

5. **Resolve SESSION_DIR.** Use the standard epic-scoped session-folder algorithm: `SESSION_DIR = ~/.claude/autodev/sessions/{repo}--epic-{epicOrSlug}/`, where `{epicOrSlug}` is read from the freeze doc frontmatter (`epicId` for Epic-child Stories, the ticket id for standalone Stories — both forms produce the same session prefix). This is the **same** session folder `/spike` writes to; you append to its `events.jsonl`. The full algorithm is in `references/autonomous/session-management.md` (read on demand).

6. **Write `active-freeze-doc.txt` pointer.** Write the absolute freeze-doc-path on a single line to `${SESSION_DIR}/active-freeze-doc.txt`. This is the disambiguation pointer that `freeze-gate.sh` reads: it tells the hook which doc is "active" for this `/implement` run, so src/** edits are evaluated against the right doc when an epic contains multiple Story freeze docs. Without this pointer, freeze-gate falls back to a scan, which is ambiguous. On write failure (permission, disk), halt with: `"Cannot write active-freeze-doc.txt at <path>: <error>. Aborting before src/** edits unlock."`

7. **Begin Phase E1 Execute.** Emit `session.started` (with `mode: "implement"`, `freezeDocPath`, `epicId`, `ticketId`) and `config.snapshot.recorded`, then call the E1 begin gate (`phase-gate.sh begin 5`, retaining the legacy phase number for gate compatibility) and proceed to the E1 body.

The session folder is shared with `/spike` — `wake()` returns both skills' state. Hooks (`freeze-gate.sh`, `push-guard.sh`, `phase-gate.sh`) remain active throughout. Emits are best-effort (exit 0 on no session); never abort a phase on emit failure.

## Companion References (read on demand)

Read these references into context when the phase needs them. They are not external skills — invoke via the Read tool.

| Reference | When to read |
|---|---|
| `../spike/references/templates/FREEZE_DOC_TEMPLATE.md` | Always (to interpret the freeze doc you are executing) |
| `references/protocols/multi-agent-consensus.md` | E1 Layer 1 review, E2 Layer 2 review |
| `references/methodology/DECISION_MAKING.md` | Issue validity judgement during reviews; Zone 3 ambiguous-question handling |
| `references/standards/CODE_QUALITY.md` | E1 implementation |
| `references/standards/EARLY_EXIT.md` | E1 implementation |
| `references/standards/ERROR_HANDLING.md` | E1 implementation |
| `references/standards/OBSERVABILITY.md` | E1 implementation, E1/E2 reviews |
| `references/standards/PERFORMANCE.md` | E1 implementation, E1/E2 reviews |
| `references/standards/RESULT_PATTERN.md` | E1 implementation |
| `references/templates/CODE_REVIEW_CHECKLIST.md` | E1 review reports |
| `references/templates/TEST_PLAN_TEMPLATE.md` | Reference shape only — test plan is consumed from freeze doc §6 |
| `references/methodology/TESTING_STRATEGY.md` | E1 TDD red phase; E2 coverage fill |
| `references/methodology/DOCUMENTATION_STANDARDS.md` | E3 docs updates |
| `references/methodology/DEVELOPMENT_CYCLE.md` | Overview / refresher |
| `references/protocols/project-docs.md` | E3 docs updates |
| `references/autonomous/session-management.md` | Step 5 (SESSION_DIR algorithm), Resume Handler |
| `references/autonomous/events-schema.md` | Event catalog and invariants |
| `references/autonomous/review-loop-protocol.md` | E1 Layer 1 review, E2 Layer 2 review |
| `references/autonomous/mistake-tracker-protocol.md` | E3 retro / mistake capture |
| `references/autonomous/dispatcher-spec.md` | Phase YAML dispatcher semantics (M3+) |

`FREEZE_DOC_TEMPLATE.md` lives under `skills/spike/` in v5 because spike owns the contract. The relative path above resolves correctly when `/implement` is invoked from any worktree of this plugin.

## Multi-Agent Consensus (the engine)

Every phase that runs parallel review agents uses the protocol in `references/protocols/multi-agent-consensus.md`. Default parameters apply unless a phase overrides them:

- `agents: 3`
- `max_iterations: 10` (from `config.pipeline.maxReviewIterations`)
- `zero_threshold: 2` (from `config.pipeline.consecutiveZerosToExit`)
- Severity rubric and convergence rules are unchanged from v4 — Critical and Major findings block convergence; Minor and Nit findings go to the review backlog without blocking.

Never short-circuit the loop. Fixing issues without re-dispatching agents is NOT a zero-issue round (see the Critical Rule in the consensus protocol).

## Event Emissions

Every orchestrator state transition dual-writes to `${SESSION_DIR}/events.jsonl` via `emit-event.sh`. Hooks emit independently. Full catalog: [`references/autonomous/events-schema.md`](./references/autonomous/events-schema.md).

**Emit command template:**

```bash
bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh <type> \
  --actor orchestrator \
  --data '<JSON object>'
```

**Orchestrator emit points** (each phase body below contains the exact command at the right location — this table is the summary):

| Point | Type | Data shape |
|---|---|---|
| Pre-Workflow step 7 | `session.started` | `{mode:"implement", freezeDocPath, epicId, ticketId}` |
| Pre-Workflow step 7 | `config.snapshot.recorded` | `{maxReviewIterations, consecutiveZerosToExit, testCoverageTarget, modelProfile}` |
| `--from N` resume entry | `session.resumed` | `{fromPhase:N}` |
| E1 begin (after begin gate) | `implement.phase.E1.started` + `phase.started` | `{phase:5}` (legacy phase number for reducer compat) |
| E1 end (before end gate) | `implement.phase.E1.completed` + `phase.completed` | `{phase:5, metrics:{rounds, issuesFixed}}` |
| E2 begin | `implement.phase.E2.started` + `phase.started` | `{phase:6}` |
| E2 end | `implement.phase.E2.completed` + `phase.completed` | `{phase:6, metrics:{coverage, rounds, issuesFixed}}` |
| E3 begin | `implement.phase.E3.started` + `phase.started` | `{phase:7}` |
| E3 end | `implement.phase.E3.completed` + `phase.completed` | `{phase:7}` |
| GATE 2 approval | `gate.approved` | `{gate:2, approvalMode, approvedBy}` |
| GATE 2 rejection | `gate.rejected` | `{gate:2, reason, returnToPhase}` |
| Bypass requested | `gate.bypass.created` (alias `bypass.created`) | `{feature, reason, userMessage}` |
| Bypass expired (post-archival) | `bypass.expired` | `{feature, at}` |
| Consensus iteration start | `consensus.iteration.started` | `{phase, iteration}` |
| Consensus converges | `consensus.converged` | `{phase, iterations, issuesFixed}` |
| Consensus forced stop (cap hit) | `consensus.forced_stop` | `{phase, iterations, remainingIssues}` |
| Pipeline complete (GATE 2 approved) | `pipeline.complete` + `session.completed` | `{totalMinutes}` |
| Phase fails | `phase.failed` | `{phase, error}` |
| Spike-plan correction found | `ticket.discovery` | `{epicId, ticketId, section, correction}` |
| GATE 2 approve emits ticket.merged (Epic-child only) | `ticket.merged` | `{epicId, ticketId, prUrl?}` |

The `implement.phase.E*.*` events are v5-native; the parallel `phase.started`/`phase.completed` events (with legacy phase numbers 5/6/7) are emitted alongside so existing reducers (`reduce-progress-log.sh`, `reduce-pipeline-issues.sh`) continue to work without schema migration.

---

## Phase E1 — Execute

**Begin gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 5`
**Emit:** `implement.phase.E1.started` and `phase.started --data '{"phase":5}'`

The freeze doc is your contract. §1-§9 are immutable truth source; treat them as read-only law. §10 Verification Backlog is informational (E2 may empirically falsify items). §11 Prerequisites was already verified at startup. `bypassHistory` is the only field you may eventually mutate, and only at E3 (GATE 2 sole writer).

**Execution rules (apply throughout E1, E2, E3):**

- **Frozen body change requested?** Halt with: `"Implementation would change freeze doc §<N>. Freeze doc is hash-locked; re-spike via /spike --revisit <epic-or-slug> --reason <reason>."` Do not edit the body.
- **Zone-3 ambiguous question** (technical detail not covered by freeze doc §1-§8): follow the 4-tier rule from freeze doc §9 Non-Frozen Allow List —
  1. **Existing code** sets a precedent → follow silently; ask only on deviation.
  2. **Reference repository** sets a precedent → same.
  3. **Initial implementation** (no precedent) → ask the user liberally.
  4. **Otherwise** → self-decide via `references/standards/*` and `references/methodology/DECISION_MAKING.md`.
- **Zone 2** (Non-Frozen list in freeze doc §9) → may ask user.
- **Zone 4** (pure technical: naming, extraction, internal boundaries) → self-decide.
- Use the "Ask with Suggestion" format from freeze doc §9 when asking.

**Implementation:**

1. Invoke `config.pipeline.skills.implementation` (default `superpowers:subagent-driven-development`). Alternative skills:
   - Sequential plan execution: `config.pipeline.skills.implementationSequential`.
   - Parallel independent subtasks: `config.pipeline.skills.implementationParallel`.
   Choose based on §6 Test Plan shape and §7 Interface Contracts.
2. **TDD per freeze doc §6 and §7.** Write the failing test first (consumed from §6 Test Plan; scaffold structure with `TEST_PLAN_TEMPLATE.md` for reference only — the plan content is already in §6). Implement to pass. Refactor. Each acceptance criterion in §1 must map to at least one test.
3. **Interface contracts (§7) are exact.** Exported signatures, types, and error modes must match §7 byte-for-byte. Deviations halt the workflow per the "frozen body change" rule above.
4. On any bug or unexpected failure, invoke `config.pipeline.skills.debugging` (default `superpowers:systematic-debugging`) before guessing fixes. Root cause first.
5. **Ticket discovery during E1/E2.** If you find an error in the **parent ticket ref doc or spike plan** (not in the freeze doc itself — the freeze doc is immutable), emit a `ticket.discovery` event for the spike retro to pick up:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh ticket.discovery \
     --actor orchestrator \
     --data "$(jq -cn --arg e "$epicId" --arg t "$TICKET" --arg s "$SECTION" --arg c "$CORRECTION" \
       '{epicId:$e, ticketId:$t, section:$s, correction:$c}')"
   ```

> **Agent-dispatched edits & freeze-gate:** when implementation runs via the Agent tool, `Edit`/`Write` calls fire `freeze-gate.sh` inside the sub-agent sandbox. Hook exit-2 blocks surface as generic "tool call failed" to the orchestrator. If an Agent reports an edit failure in `src/**`, inspect `SESSION_DIR/bypass.json`, `active-freeze-doc.txt`, and the freeze doc status before assuming a code error.

**Layer 1 Review (mandatory):**

Read `references/autonomous/review-loop-protocol.md`. Run the protocol over the implemented code:

1. Invoke `config.pipeline.skills.requestReview` (default `superpowers:requesting-code-review`) to prepare the review request.
2. Run consensus protocol (`references/protocols/multi-agent-consensus.md`):
   - `task_type: validate`
   - `agents_list: config.pipeline.agents.review` (default `[code-quality-reviewer, performance-reviewer, observability-reviewer]`)
   - `max_iterations: config.pipeline.maxReviewIterations` (default 10)
   - `zero_threshold: config.pipeline.consecutiveZerosToExit` (default 2)
3. Invoke `config.pipeline.skills.receiveReview` (default `superpowers:receiving-code-review`) — evaluate findings rigorously, no performative agreement, reasoned pushback on invalid findings (per `references/methodology/DECISION_MAKING.md`).
4. Fix valid Critical/Major issues; re-dispatch for verification. Minor/Nit go to `docs/plan/{epic-or-slug}/review-backlog.md` without blocking.
5. If not converged within `max_iterations`, escalate remaining issues to the user.

**Update:** `progress-log.json` with review metrics (rounds, issuesFixed).
**Emit:** `implement.phase.E1.completed` and `phase.completed --data '{"phase":5, metrics:{...}}'`
**End gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 5`
**Banner:** `--- E1 Execute Complete --- Rounds: {N} | Issues fixed: {M} ---`

## Phase E2 — Verify

**Begin gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 6`
**Emit:** `implement.phase.E2.started` and `phase.started --data '{"phase":6}'`

1. Run all tests (unit, integration, smoke, E2E). All must pass.
2. Measure branch coverage. Compare against `config.pipeline.testCoverageTarget` (default 90).
3. If below target: use `config.pipeline.skills.tdd` to write additional tests targeting uncovered branches (RED-GREEN-REFACTOR). Re-run all tests, verify green.
4. Invoke `config.pipeline.skills.verification` (default `superpowers:verification-before-completion`) — confirm each §1 acceptance criterion with concrete evidence before continuing. Evidence > assertion.
5. **Verification Backlog (§10) empirical check.** For each item in freeze doc §10 with confidence `doc-only` or `inferred-from-code`, run its verification recipe. If any recipe reveals reality differs from the freeze doc's assumption:
   - **Halt.** Do NOT silently fix or update the freeze doc body (it is hash-locked).
   - Print: `"Verification failed: §10 item "<item>" recipe revealed reality differs from the freeze doc assumption: <observed>. The freeze doc body is immutable. Recommend: /spike --revisit <epic-or-slug> --reason verification-failure to re-plan, or revoke and start a new ticket."`
   - Emit `phase.failed --data '{"phase":6, "error":"verification-failure: §10 <item>"}'`.
   - Exit. The user re-spikes; on the new freeze doc, `/implement` runs again.

6. **Layer 2 Review** (same mechanics as Layer 1):
   - Read `references/autonomous/review-loop-protocol.md`.
   - Run consensus protocol with `agents.review`, `max_iterations: config.pipeline.maxReviewIterations`, `zero_threshold: config.pipeline.consecutiveZerosToExit`.
   - Context: final validation — integration-level consistency, test-to-§1-acceptance traceability, §8 performance budget adherence, standards compliance against §2-§7.
   - Invoke `config.pipeline.skills.receiveReview` to evaluate rigorously.
7. Fix valid issues, re-validate. If not converged within `max_iterations`, escalate to user.

Log decisions, persist issues to `pipeline-issues.json`, merge `phase-6-decisions.jsonl`, update markdown.

**Update:** `progress-log.json` with review metrics (coverage, rounds, issuesFixed).
**Emit:** `implement.phase.E2.completed` and `phase.completed --data '{"phase":6, metrics:{coverage, rounds, issuesFixed}}'`
**End gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 6`
**Banner:** `--- E2 Verify Complete --- Coverage: {N}% | Rounds: {M} | Issues fixed: {K} ---`

## Phase E3 — Finalize

**Begin gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 7`
**Emit:** `implement.phase.E3.started` and `phase.started --data '{"phase":7}'`

**Documentation:**

1. Read `references/protocols/project-docs.md`.
2. Update/create ADRs for any E1/E2 decisions that deviated from freeze doc §2-§4 architecture (supersede the prior ADR per the ADR lifecycle in `references/methodology/DECISION_MAKING.md`). Deviations rare in v5 — most architecture is locked in the freeze doc.
3. Update `docs/test-plans/[ticket-or-slug]-test-plan.md` with actual coverage numbers and test inventory (the test plan as-built; the freeze doc §6 is the test plan as-designed).
4. Append the freeze doc as a permanent record; do not delete or modify the body.
5. Scope boundary: E3 only **documents** what was built. It does not introduce features, refactor code, or change behavior. Implementation gaps become follow-up tickets.

**Mistake Capture:**

6. Read `references/autonomous/mistake-tracker-protocol.md`.
7. Follow the protocol:
   - Check idempotency via Run Log; skip if this `runId` already aggregated.
   - Aggregate E1 + E2 code issues.
   - Match against existing patterns; increment frequency or create new patterns.
   - Promote at frequency ≥ `config.pipeline.chronicPromotionThreshold` (default 3) — write prevention strategy.
   - Enforce hard cap `config.pipeline.maxActivePatterns` (default 20).
   - Sync `CLAUDE.md` chronic patterns between sentinel markers (atomic write with backup).
   - Append `runId` to Run Log.
   - Log pattern promotions/demotions to `decision-log.json` category `pattern`.

**GATE 2 — Final Approval** (always user-interactive):

If any `ticket.discovery` events were emitted during E1/E2, query and print them before the approval summary:

```
━━━ Spike Plan Corrections Discovered ━━━
The following ref-doc / spike-plan errors were found during implementation:
  - [{section}] {correction}
  ...
These events are logged and will be addressed by /spike --retro <epic-or-slug> after this ticket merges.
```

Discoveries do NOT block GATE 2; they are informational.

Present:

```
Ticket: [ticket-id] — Final Approval
────────────────────────────────────────────────────────
Freeze doc:   {path}  (approvedHash verified: yes)
Tests:        {passed}/{total} passed
Coverage:     {N}% branch (target: {target}%)
Code Review:
  Layer 1 (E1): {agents} agents, {rounds} rounds, {issues} issues fixed
  Layer 2 (E2): {agents} agents, {rounds} rounds, {issues} issues fixed
  Remaining:    {N} issues (must be 0 to approve [1] or [3])
Standards:    {pass/fail summary}
Docs updated: {list}
Files changed: {N} ({src}/{tests})
Frozen body intact: yes (hash recheck OK)
Prerequisites:    {N}/{N} merged
Bypasses used: {N}
Chronic patterns prevented: {N}
Duration: {minutes}
────────────────────────────────────────────────────────
Options:
  [1] Approve → archive session, allow push
  [2] Reject → list issues to fix (returns to E1 or E2 per user choice)
  [3] Approve + commit + push (invokes the finishing skill)
```

On approval (option 1 or 3), execute this sequence in order. **If any step fails, halt and report the specific error to the user — do NOT proceed to later steps.** The archival + cleanup sequence is idempotent (dedup by `at`, filter by `runId`), so a resumed E3 safely re-runs any completed portion.

1. **Bypass archival — GATE 2 is the sole writer of freeze doc `bypassHistory`.** Collect bypass records from both sources, normalizing each to the `bypassHistory` entry schema `{at, reason, feature, userMessage, runId, preservedAt?}`:
   - `bypass.json` (current live bypass, if any): use `bypass.json.createdAt` as `at`; inject `runId` from `progress-log.json`; `preservedAt` is absent.
   - `bypass-audit.jsonl` (preserved by `sessionend.sh` on prior crash within this run): already uses `at` and carries `runId` + `preservedAt`.
   Filter `bypass-audit.jsonl` entries by `runId` matching current; dedup by `at` against existing `bypassHistory`. Merge into freeze doc frontmatter `bypassHistory` — this is the **only** legitimate post-approval mutation of the freeze doc.

2. **Bypass cleanup:** after archival succeeds, delete `SESSION_DIR/bypass.json`. Do not delete `bypass-audit.jsonl` (cross-run audit). Emit `bypass.expired` for each archived bypass.

3. **Write completion marker:** write `SESSION_DIR/pipeline-complete.md`:
   ```
   Pipeline completed for branch: {original unsanitized branch name}
   Date: {ISO UTC}
   Ticket: {ticket-id}
   Freeze doc: {freeze-doc-path}
   ```
   This marker authorizes `push-guard.sh` to allow `git push` on this branch. It is written **after** archival and cleanup so the marker only exists in a fully-consistent state.

4. **Finalize progress log:** set `progress-log.json` `status: "completed"`, `completedAt: <ISO UTC>`, summary totals.

5. **On option 3:** invoke `config.pipeline.skills.finishing` (default `superpowers:finishing-a-development-branch`) — stage, commit, push, **open the PR**. PR description should link the freeze doc, list acceptance criteria with checkmarks, summarize Layer 1/2 review rounds, and reference any `ticket.discovery` events for the spike retro.

6. **Emit GATE 2, pipeline complete, ticket merge (Epic-child only):**
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh gate.approved \
     --actor orchestrator \
     --data "$(jq -cn --arg by "$APPROVED_BY" '{gate:2, approvalMode:"interactive", approvedBy:$by}')"

   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh pipeline.complete \
     --actor orchestrator \
     --data "$(jq -cn --argjson m "$TOTAL_MINUTES" '{totalMinutes:$m}')"

   if [[ "$epicId" != ad-hoc-* && -n "$epicId" ]]; then
     bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh ticket.merged \
       --actor orchestrator \
       --data "$(jq -cn --arg e "$epicId" --arg t "$TICKET" --arg p "${PR_URL:-}" \
         '{epicId:$e, ticketId:$t, prUrl:$p} | with_entries(select(.value != ""))')"
   fi

   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh session.completed \
     --actor orchestrator \
     --data "$(jq -cn --argjson m "$TOTAL_MINUTES" '{totalMinutes:$m}')"
   ```

On rejection (option 2):

- User indicates which phase (E1 or E2) to return to; set `progress-log.json` `status: "in-progress"`, reset `currentPhase` accordingly.
- **Emit:** `gate.rejected --data '{"gate":2, "reason": "...", "returnToPhase": N}'`.
- Re-enter that phase.

**Update:** `progress-log.json`.
**Emit:** `implement.phase.E3.completed` and `phase.completed --data '{"phase":7}'`
**End gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 7`
**Banner:** `--- E3 Finalize Complete --- GATE 2: approved | Total: {minutes}min ---`

---

## `--status` Handler

1. Parse `<freeze-doc-path>` and resolve `SESSION_DIR` via the same algorithm as Pre-Workflow step 5.
2. Read `progress-log.json`, `decision-log.json`, the freeze doc (status + approvedHash recheck), `active-freeze-doc.txt`, `bypass.json`, `bypass-audit.jsonl`, `pipeline-complete.md`.
3. Print:
   - Ticket / freeze doc path / freeze doc status / approvedHash verify result.
   - Mode (`implement`), current phase (E1 / E2 / E3), session status (in-progress / completed / interrupted / failed).
   - Per-phase timing and review metrics.
   - Last 5 decisions.
   - Config snapshot.
   - Bypass state (active y/n; audit count; pending-merge count).
   - Push-guard state (`pipeline-complete.md` present y/n; blocking reason if no).
   - SESSION_DIR absolute path.
   - freeze-gate state: edits allowed y/n (based on freeze doc status + active-freeze-doc.txt + hash recheck).
4. Exit — do not run the workflow.

## `--from N` Resume Handler

1. Validate N ∈ {1, 2, 3}.
2. Run the full Pre-Workflow / 7-Step Startup against `<freeze-doc-path>` — hash and prereqs must still verify on resume. Any startup failure halts as it would on a fresh run.
3. Read `progress-log.json`, verify the freeze-doc path matches.
4. Follow the resume protocol in `references/autonomous/session-management.md`: detect mid-phase crash (last phase status `in-progress`), merge stale `phase-{N}-decisions.jsonl`, announce: `"Resuming from E{N}. Earlier phases assumed complete."`
5. **Emit:** `session.resumed --data '{"fromPhase": N}'`.
6. Run the phase begin gate (`phase-gate.sh begin <legacy-N>`, where N=1→5, 2→6, 3→7), then continue at E{N}.

---

## Phase Failure Protocol

When a phase fails (not a verification-backlog halt; a runtime/test/agent failure):

1. Invoke `config.pipeline.skills.debugging` (default `superpowers:systematic-debugging`). Gather evidence, form hypothesis, test minimally. No guessing.
2. Update `progress-log.json`: phase status `failed`.
3. Persist issues to `pipeline-issues.json`.
4. Log failure as decision (category: `skip`).
5. **Emit:** `phase.failed --data '{"phase": N, "error": "..."}'`.
6. Announce:
   ```
   --- E{N} FAILED ---
   Error: {description}
   Session: {SESSION_DIR}
   Resume: /implement --from {N} <freeze-doc-path>
   ```
7. Offer: `[1] Retry this phase` `[2] Skip to next` `[3] Abort workflow`.

## Gate Failure Protocol

When `phase-gate.sh` exits 2 (begin or end gate blocked), it is a prerequisite violation, not a bug. Do **not** invoke the debugging skill.

1. Read the gate error message — it explains exactly what is wrong.
2. Announce `--- E{N} GATE BLOCKED: {summary} ---` with SESSION_DIR.
3. Offer:
   - Begin gate (missing progress): `[1] Run Pre-Workflow` `[2] Use --from N` `[3] Abort`.
   - Begin gate (previous phase incomplete): `[1] Complete E{N-1}` `[2] Use --from N to skip` `[3] Abort`.
   - End gate (progress not updated): `[1] Update progress-log.json and retry` `[2] Abort`.

## Bypass Protocol (freeze-gate override)

If the user explicitly asks to bypass the freeze gate (trigger phrases: "bypass freeze", "freeze 무시하고 진행", "freeze 우회", or explicit sentence with clear intent):

1. Write `SESSION_DIR/bypass.json`:
   ```json
   {
     "createdAt": "<ISO UTC>-<4 hex chars>",
     "reason": "<extracted from user message>",
     "feature": "<ticket-or-slug>",
     "scope": "ticket",
     "userMessage": "<verbatim user request>"
   }
   ```
   The 4-hex suffix makes `createdAt` a unique event identifier even when multiple bypasses occur within the same second. All downstream consumers (`sessionend.sh` dedup, GATE 2 dedup, freeze doc `bypassHistory.at`) use this as the join key.
2. Announce the bypass clearly, including the reason.
3. Log a decision to `decision-log.json` category `bypass` with full fields.
4. **Emit:** `gate.bypass.created --data '{"feature": "...", "reason": "...", "userMessage": "..."}'`.
5. Continue work. E3 GATE 2 is the **sole** writer of freeze doc `bypassHistory` — do not write to it elsewhere.

The `freeze-gate.sh` hook reads `bypass.json` (and `active-freeze-doc.txt`) and respects it. Do not silence the hook by any other means.

---

## Cross-Cutting Concerns

### Phase Gates (Mandatory)

Every phase is bookended by `phase-gate.sh begin <legacy-N>` and `phase-gate.sh end <legacy-N>` (N=5 for E1, 6 for E2, 7 for E3). The `phase-progress-validator.sh` PostToolUse hook runs after each gate as an independent consistency check (warning-only).

### Decision Logging

Per-iteration: append to `SESSION_DIR/phase-{N}-decisions.jsonl`. At phase end: merge JSONL into `decision-log.json`, delete JSONL. Append significant decisions to `docs/decisions.md` via the `project-docs` protocol.

### Markdown Regeneration

At phase end (not per-iteration): regenerate `decision-log.md` and `progress-log.md` from JSON. On failure, warn but do not fail the phase. JSON is the source of truth.

### Performance Budgets (advisory)

| Phase | Budget | Notes |
|---|---|---|
| E1 | 15 min | Varies by complexity; Layer 1 review included |
| E2 | 10 min | Verification + coverage fill + Layer 2 review |
| E3 | 5 min | Docs + mistake capture + GATE 2 |

Budgets calibrate "something is wrong" intuition; they are not enforced by gate hooks.

---

## Migration Note (v4 → v5)

v4 `/implement` was a 7-phase orchestrator that did Requirements → Research → Plan+Freeze → Test Planning → Implementation → Verification → Docs+PR, owning both planning and execution end-to-end. In v5, the first four phases moved into `/spike` (P1 Scope → P2 Investigate → P3 Decompose → P4 Spec). `/implement` v2.0.0 executes **only** the spec-frozen plan and reduces to E1 Execute → E2 Verify → E3 Finalize, with a single user gate (GATE 2). The freeze doc — now spike-owned — is the formal contract between the two skills, hash-locked at GATE 1 and verified on every `/implement` startup.

In-flight v4 pipelines that already crossed into the planning phases on v4 cannot be resumed under v5. Finish or abandon them on v4.2 before upgrading; v5 provides no compat layer for the removed planning-side dispatcher metadata.
