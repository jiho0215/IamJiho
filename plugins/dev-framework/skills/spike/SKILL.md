---
name: spike
version: 1.0.0
description: "Multi-ticket Research Spike workflow. Takes a high-level epic goal and produces a master spike plan plus N per-ticket ref docs with dependency classification, rollout plan, observability plan, API contracts, and migration chain — all committed under docs/plan/{epic}/ for PR review. Built on Managed Agents architecture with an epic-scoped event log shared with /implement. 5 phases: Requirements → System Design → Ticket Decomposition → Cross-Ticket Gap Review → Retro (async, runs after all tickets merged). Use when the user wants to decompose a non-trivial feature into multiple tickets before implementation begins, or when the input is 'build X' at a scale larger than a single PR. For single-ticket implementation, use /dev-framework:implement instead. Also trigger on: '/spike', 'plan this epic', 'decompose this feature', 'research spike', 'break this down into tickets', 'multi-ticket plan', or any request for cross-ticket architecture work."
---

# `/spike` — Research Spike Framework

You are orchestrating one rigorous research spike for this user. The spike takes a high-level goal and produces a plan doc plus a decomposed set of ticket ref docs that `/implement` can consume one at a time. Move slow, do it right. The spike is where architectural coherence is earned; skipping this work shows up later as rework across ticket boundaries.

`/spike` is the **complement** to `/implement`. They share one epic-scoped event log so `wake()` returns full cross-ticket state in a single call. Plan docs live in-repo under `docs/plan/{epic}/` — they are first-class engineering artifacts, PR-reviewable and version-controlled.

## Invocation Modes

Parse `$ARGUMENTS`. Route to the first matching branch:

| Args match | Mode | Section |
|---|---|---|
| `--retro EPIC-ID` | Async post-merge retro | Section R |
| `--status EPIC-ID` | Show spike status and exit | see Status below |
| `--from N EPIC-ID` | Resume at phase N | see Resume below |
| Non-empty description | New research spike (full 5-phase flow) | Section S |
| Empty args | Ask user for the epic goal, then route to Section S | — |

## Pre-Workflow (runs for every mode)

Before entering any section, execute these steps in order:

1. **Ensure config** — `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/ensure-config.sh` (idempotent; creates `~/.claude/autodev/config.json` with defaults if absent). Single source of truth for the default config schema.
2. **Resolve epic ID**:
   - New spike (Section S): ask user for the epic ID / slug. Sanitize: lowercase, replace spaces with dashes, strip special chars. Example: `"Payments V2"` → `payments-v2`.
   - Retro / status / resume: read `EPIC-ID` from `$ARGUMENTS`.
3. **Resolve epic session folder** — `SESSION_DIR = ~/.claude/autodev/sessions/{repo}--epic-{epicId}/`. The repo segment uses the same sanitization algorithm as `session-management.md` in `/implement`'s references. The epic segment uses the sanitized epic ID from step 2.
   - Create `SESSION_DIR` if absent (`mkdir -p`). An existing folder means another skill has already touched this epic — that's fine; `/spike` and `/implement` share the folder by design.
4. **Docs folder scaffolding** — ensure `<repo>/docs/plan/` exists (`mkdir -p docs/plan`). If this is the first plan folder ever, append a one-line entry to `<repo>/docs/README.md` (or create it) pointing to `docs/plan/` for discoverability. Non-fatal if repo has no `docs/` root — `/spike` creates it.
5. **Emit `session.started`** — once mode + epicId are known:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh session.started \
     --actor orchestrator \
     --data "$(jq -cn --arg mode "$MODE" --arg epicId "$EPIC_ID" \
       '{mode:$mode, epicId:$epicId, skill:"spike"}')"
   ```
   Use `mode = "spike"`, `"spike-retro"`, `"spike-resume"`, or `"spike-status"` to match the invocation branch.
6. **Emit `config.snapshot.recorded`** — capture effective config so reducers can populate `progress-log.json.configSnapshot`:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh config.snapshot.recorded \
     --actor orchestrator \
     --data "$(jq -c '.pipeline | {maxReviewIterations, consecutiveZerosToExit, modelProfile}' ~/.claude/autodev/config.json)"
   ```

The resolved `SESSION_DIR` is stable across all invocations for this epic. Multiple `/spike` and `/implement` calls append to the same `events.jsonl`.

## Companion References (read on demand)

Read these internal references into context when the current phase needs them. They are not external skills; invoke with your Read tool.

| Reference | When to read |
|---|---|
| `references/templates/SPIKE_PLAN_TEMPLATE.md` | Phase 2 skeleton assembly |
| `references/templates/TICKET_REF_TEMPLATE.md` | Phase 3 per-ticket instantiation |
| `../implement/references/protocols/multi-agent-consensus.md` | Any phase that dispatches multiple review/plan agents |
| `../implement/references/methodology/DECISION_MAKING.md` | Recording architectural decisions in Phase 2 |
| `../implement/references/templates/ADR_TEMPLATE.md` | Phase 2 ADR production for cross-ticket decisions |
| `../implement/references/templates/FEATURE_SPEC_TEMPLATE.md` | Phase 1 requirements-section shape |
| `../implement/references/autonomous/session-management.md` | Session folder resolution helpers |
| `../implement/references/autonomous/events-schema.md` | Event type catalog and validation rules |
| `references/autonomous/mistake-tracker-protocol.md` (design variant) | Phase 5 retro (fallback to `../implement/references/autonomous/mistake-tracker-protocol.md` until design variant lands in Phase 5 of the implementation plan) |

The /implement reference tree is shared by design — these are internal protocols, not user-facing skills, and `/spike` reuses them where semantics match.

## Multi-Agent Consensus

Phases 1, 2, and 4 run multi-agent consensus via `../implement/references/protocols/multi-agent-consensus.md`. Defaults apply unless a phase overrides them:

- `agents: 3` (from `config.pipeline.agents.plan` or `config.pipeline.agents.review`)
- `max_iterations: 10` (from `config.pipeline.maxReviewIterations`)
- `zero_threshold: 2` (from `config.pipeline.consecutiveZerosToExit`)

Never short-circuit. Fixing issues without re-dispatching agents is NOT a zero-issue round.

## Event Emissions

Every orchestrator-level state transition in `/spike` dual-writes to `$SESSION_DIR/events.jsonl` via `emit-event.sh`. Events are shared with `/implement` on this epic.

**Emit command template:**

```
bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh <type> \
  --actor orchestrator \
  --data '<JSON object>'
```

**/spike-specific emit points** (full catalog in `../implement/references/autonomous/events-schema.md`):

| Point | Type | Data shape |
|---|---|---|
| Pre-Workflow complete | `session.started` | `{mode, epicId, skill:"spike"}` |
| Phase 1 begin | `spike.phase.1.started` | `{epicId, phase:1}` |
| Phase 1 end | `spike.phase.1.completed` | `{epicId, phase:1, metrics?}` |
| Phase 2 begin/end | `spike.phase.2.started` / `.completed` | same |
| Phase 3 begin | `spike.phase.3.started` | `{epicId, phase:3}` |
| Each ticket decomposed | `ticket.decomposed` | `{epicId, ticketId, title, implBlockedBy, deployBlockedBy}` |
| Phase 3 end | `spike.tickets.decomposed`, then `spike.phase.3.completed` | `{epicId, tickets:[...]}`, `{epicId, phase:3}` |
| Phase 4 begin | `spike.phase.4.started` | same |
| Phase 4 human signoff (approved) | `spike.gate.approved` | `{epicId, approvedBy}` |
| Phase 4 human signoff (rejected) | `spike.gate.rejected` | `{epicId, returnToPhase, reason}` |
| Phase 4 end | `spike.phase.4.completed` | same |
| Phase 5 begin | `spike.phase.5.started` | same |
| Phase 5 end | `spike.retro.completed` + `spike.phase.5.completed` | `{epicId, patternsPromoted, patternsDemoted}` |
| All tickets merged | `spike.integration.verified` | `{epicId, ticketCount}` — emitted by the integration verifier, not by /spike itself |
| Bi-dir events from /implement | `ticket.started`, `ticket.discovery`, `ticket.merged` | — read but not emitted here |

Emits are best-effort (exit 0 on missing session). Never abort a phase on emit failure.

---

## Section S: Research Spike (new, full 5-phase flow)

Runs sequentially through Phases 1-4. Phase 5 runs asynchronously later, triggered by `/spike --retro EPIC-ID` once all tickets reach `merged` status.

### Session Initialization

Before Phase 1:

1. Initialize / update `SESSION_DIR/progress-log.json`:
   - `schemaVersion: 1`
   - `epicId: <sanitized>`
   - `mode: "spike"`
   - `repo`, `branch` (current; note that `/spike` is typically run on a dedicated spike branch or main)
   - `runId` (per `../implement/references/autonomous/session-management.md`)
   - `planDocPath: null` (set at Phase 2 completion: `docs/plan/${epicId}/spike-plan.md`)
   - `ticketCount: 0` (incremented during Phase 3)
   - `startedAt: <ISO-8601 UTC>`
   - `status: "in-progress"`
   - `configSnapshot: { maxReviewIterations, consecutiveZerosToExit, modelProfile }`
   - `phases: []`
2. Create `SESSION_DIR/decision-log.json` if absent (`{ decisions: [] }`).
3. Run `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh verify` — aborts if `progress-log.json` is malformed.

### Dispatcher Preamble (per phase)

Before running any phase body below, read `phases/spike-phase-${N}.yaml` and act on its metadata:

1. **Lazy-load refs:** for each entry in `requiredRefs[]`, read that file with the Read tool.
2. **Emit entry events:** execute each emit in `emits.entry[]` via `emit-event.sh`.
3. **Run begin gates:** run each script listed in `gates.begin[]`.
4. **Consult narrative + checklist:** phase YAML `instructions.*` is the action checklist; the prose below anchored by `skillMdSection` explains the why and how-to-think.
5. **Invoke** per `invokes[]`:
   - `kind: skill` → `execute.sh skill <name>` emits started event, returns dispatch payload; invoke the actual Skill tool, then call `execute.sh --complete skill <name> --output ...`.
   - `kind: protocol` → read the reference file and apply.
   - `kind: hook` → `execute.sh hook <name>` runs to completion.
6. **Verify produces:** before end gates, verify each `produces[]` artifact or section exists.
7. **Run end gates** and **emit exit events** when the phase body concludes.

If a spike-phase YAML is missing, fall back to this file's phase prose as the single source of truth.

### Phase 1 — Requirements Review

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 1`
**Emit:** `spike.phase.1.started` with `{epicId, phase:1}`.

Dialogue-gather epic-level requirements:

1. **Epic goal** — one paragraph capturing the outcome the user wants. Prompt: "In one or two sentences, what is the epic supposed to accomplish when done?"
2. **Success criteria** — bullet list, each testable at epic scope. "How will you know the epic is complete — what observable change or metric?"
3. **Non-functional requirements** — ask explicitly about each of: SLA, security threat model, privacy / compliance (PII, residency, retention), accessibility (WCAG tier or N/A). Do not let the user skip any — ask one at a time with a default fallback they can accept or refine.
4. **Rollout / rollback** — feature flags (owner, scope), canary stages (percent, dwell time, success gates), migration reversibility. If any schema migration is irreversible, flag it now.

**Autonomous mode:** the user-supplied description is the ticket content. Extract requirements; log assumptions to `decision-log.json` category `spike-autonomous-inference`.

After gathering, run multi-agent consensus:
- `task_type: validate`
- `agents_list: config.pipeline.agents.plan`
- Context: "Validate epic-level requirements completeness across all features, NFR coverage, and rollout/rollback strategy. Focus on gaps, ambiguities, and missing cross-feature concerns."

Persist the Phase 1 result as a working draft (in-memory or `SESSION_DIR/spike-phase-1-draft.md`). The spike-plan.md file is created in Phase 2.

**Update:** `progress-log.json` (append phase entry with status `completed`, `completedAt`, metrics).
**Emit:** `spike.phase.1.completed`.
**Gate:** `phase-gate.sh end 1`.
**Banner:** `--- Spike Phase 1 Complete: Requirements Review ---`

### Phase 2 — System Design

**Gate:** `phase-gate.sh begin 2`
**Emit:** `spike.phase.2.started`.

1. **Create plan folder**: `mkdir -p <repo>/docs/plan/${epicId}/`. If `spike-plan.md` already exists there, prompt the user: overwrite, pick a new epicId, or abort.
2. **Instantiate `spike-plan.md`** from `references/templates/SPIKE_PLAN_TEMPLATE.md`. Populate frontmatter: `epicId`, `status: planning`, `createdAt`.
3. **Write §1 Requirements** from the Phase 1 draft.
4. **§2 Architecture + NFR** — invoke the skill named by `config.pipeline.skills.architect` (default `feature-dev:code-architect`). Produce component diagram (mermaid), data flow, NFR enforcement points. Create ADR(s) under `<repo>/docs/adr/` for cross-ticket architectural decisions using `../implement/references/templates/ADR_TEMPLATE.md`. Cross-ticket scope includes: new services, shared abstractions, data-model splits, API versioning policy.
5. **§3 Rollout / rollback plan** — expand Phase 1 notes into concrete stages: flag name + owner, canary percent + dwell + success gate per stage, rollback procedure (code revert, flag flip, data rollback), post-launch cleanup plan and target date.
6. **§4 Observability plan** — epic-scope metrics (counters, gauges, histograms with units), logs (structured schemas with field inventories), traces (span naming + attributes), dashboards (one per service/flow), alerts (burn-rate thresholds with runbook links).
7. **§5 API contracts** — inline small surfaces; for significant surfaces, create `<repo>/docs/plan/${epicId}/shared/api-contracts.openapi.yaml` (or `.proto`, `.graphql` as appropriate). Record version, breaking-change policy, and deprecation timeline for any modified endpoints.
8. **§6 Data migration chain** — ordered migration steps across tickets: schema change, owning ticket ID placeholder, reversibility, backfill plan. For long chains, externalize to `<repo>/docs/plan/${epicId}/shared/migrations.md`.
9. Run multi-agent consensus:
   - `task_type: validate`
   - `agents_list: config.pipeline.agents.plan`
   - Context: "Validate epic architecture coherence. Component boundaries clean? Data flow consistent with requirements? Rollout/rollback actually reversible? Observability complete? API contracts match the data model? Migration chain ordered and non-conflicting?"

**Update:** `progress-log.json` — set `planDocPath: "docs/plan/${epicId}/spike-plan.md"`.
**Emit:** `spike.phase.2.completed`.
**Gate:** `phase-gate.sh end 2`.
**Banner:** `--- Spike Phase 2 Complete: System Design ---`

### Phase 3 — Ticket Decomposition

**Gate:** `phase-gate.sh begin 3`
**Emit:** `spike.phase.3.started`.

Decompose one ticket at a time. The one-at-a-time loop is deliberate: it forces the user to reason about each ticket in the context of what came before, which is when blocker classification is done correctly.

**Per-iteration:**

1. **Propose** — draft a ticket title and a 2-3-sentence scope summary derived from the spike-plan §2-§6 content. Example: "`pay-123` — Payment API endpoint. Scope: POST /payments handler, auth, persistence, basic validation. Implements contract §5 lines 12-40; owns migration step 2."
2. **User dialogue** — ask user to accept, modify, or reject. On reject, propose a different slice.
3. **Ticket ID** — ask user for an ID. Prefer their tracker ID (JIRA `PAY-123`, Linear `ENG-456`, GitHub `#47`). If no tracker, ask for a slug. Sanitize to lowercase/dashes.
4. **Collision check** — if `<repo>/docs/plan/${epicId}/<id>.md` exists, prompt: overwrite, suffix (`-2`, `-3`), or pick a new ID.
5. **Instantiate ref doc** from `references/templates/TICKET_REF_TEMPLATE.md`. Populate:
   - Frontmatter: `epicId`, `ticketId`, `status: planned`, `createdAt`, empty `implBlockedBy` / `deployBlockedBy` arrays.
   - §2 role-in-big-picture: extract 1-2 paragraphs from spike-plan §2 relevant to this ticket.
   - §3 API slice: extract the relevant endpoints from spike-plan §5.
   - §4 Relevant migrations: the migration-chain entries from §6 this ticket owns.
   - §5 Relevant observability hooks: the metrics/logs/traces/alerts this ticket will emit.
6. **Blocker classification** — ask user for each blocker of this ticket:
   - `implBlockedBy`: list of `{ticketId, kind: hard|soft, reason}`. `hard` means cannot start this ticket until target is merged. `soft` means can start, but will pay some copy-paste / rework cost.
   - `deployBlockedBy`: list of `{ticketId, kind: hard, reason}`. Deploy blockers are virtually always hard — if B's deploy requires A's deploy, it's hard. Soft deploy blockers are rare and usually indicate the author is conflating deploy with implementation.
7. **Write the doc** to `<repo>/docs/plan/${epicId}/<ticketId>.md`.
8. **Emit `ticket.decomposed`** with `{epicId, ticketId, title, implBlockedBy, deployBlockedBy}`.
9. **Sanity check (interactive)** — run short-form multi-agent consensus (1 iteration, no loop) asking: is this ticket cohesive, appropriately sized, and with accurate blocker classification versus tickets decomposed so far? Skip in autonomous mode — Phase 4 does the deep review.
10. **Continue loop** — ask user: "Add another ticket?" until they say no.

**Exit loop:**

- Verify the dependency graph is **acyclic** (DFS over `implBlockedBy` across all decomposed tickets). On cycle, surface the cycle path to the user and loop back to allow blocker reclassification.
- Emit `spike.tickets.decomposed` with the full tickets array.
- Update `progress-log.json.ticketCount`.
- Run the spike-plan registry reducer (`reduce-spike-plan.sh`) to populate §7 in `spike-plan.md`. If the reducer does not yet exist (lands in Phase 4 of this implementation plan), write a stub marker so Phase 4 gap review has something to work against.

**Emit:** `spike.phase.3.completed`.
**Gate:** `phase-gate.sh end 3`.
**Banner:** `--- Spike Phase 3 Complete: Ticket Decomposition (${ticketCount} tickets) ---`

### Phase 4 — Cross-Ticket Gap Review → Human Signoff

**Gate:** `phase-gate.sh begin 4`
**Emit:** `spike.phase.4.started`.

1. Regenerate spike-plan §7 registry from the event log (`reduce-spike-plan.sh`; stub until Phase 4 implementation).
2. Write **§8 Testing Strategy** — cross-ticket integration tests, end-to-end flow tests, contract tests for the API surface, load/stress test plan if NFR demands it. Ticket-local unit tests are the responsibility of `/implement` Phase 4.
3. Run multi-agent consensus:
   - `task_type: review`
   - `agents_list: config.pipeline.agents.review`
   - Context (gap review):
     - "Does the ticket set fully cover epic §1 requirements? Flag uncovered requirements."
     - "Is the dependency graph acyclic and minimally coupled? Flag unnecessary hard blockers."
     - "Is the `deployBlockedBy` order actually deployable end-to-end?"
     - "Are there integration tests in §8 that span tickets where needed?"
     - "Are blocker classifications accurate? Flag any `soft` that should be `hard`."
   - Iterate until convergence (global cap / consecutive-zero rules).
4. For each issue returned, classify and act:
   - **Missing ticket** — re-enter Phase 3 loop for that one ticket, then return.
   - **Misclassified blocker** — update the target ticket's ref doc and re-emit `ticket.decomposed` (supersedes prior event at the reducer level).
   - **Dismissible** — record rationale in `decision-log.json` category `spike-dismissed-issue`.

**Human signoff:**

Present to user (concise summary):
- Ticket count and dependency graph (ASCII or mermaid).
- Deploy order derived from `deployBlockedBy`.
- Unresolved issues from consensus (should be zero or explicitly dismissed).
- Links to `spike-plan.md` and each `<ticketId>.md`.

Ask: "Spike ready to proceed to `/implement`?" — y/n.

**On yes (interactive) or autonomous auto-sign:** emit `spike.gate.approved` with `{epicId, approvedBy}`. Update `spike-plan.md` frontmatter `status: in-progress`.

**On no:** ask which phase to return to (1-3), emit `spike.gate.rejected` with `{epicId, returnToPhase, reason}`, and loop back.

**Emit:** `spike.phase.4.completed`.
**Gate:** `phase-gate.sh end 4`.
**Banner:** `--- Spike Phase 4 Complete: Gap Review — signoff: {approvedBy} | tickets ready: ${ticketCount} ---`

After Phase 4, `/spike` is done for this invocation. Tickets are now available for `/implement` to consume. Phase 5 runs asynchronously later.

---

## Section R: Retro (async — `/spike --retro EPIC-ID`)

Runs after all tickets of the epic reach `merged` status. Triggered explicitly, or auto-proposed when the user invokes `/spike EPIC-ID` on an epic whose tickets are all merged.

1. **Verify prerequisite** — query `ticket-statuses.json` (or fold over `events.jsonl` for `ticket.merged` events by `ticketId`). If any ticket is still `in-impl` or `planned`, exit with: `"retro not ready — N tickets unmerged: [list]"`.
2. **Read the mistake-tracker-protocol (design variant)** from `references/autonomous/mistake-tracker-protocol.md`. Falls back to `../implement/references/autonomous/mistake-tracker-protocol.md` (code variant) while the design variant is pending. Both have the same shape; only the pattern taxonomy and store path differ.
3. **Emit `spike.phase.5.started`**.
4. **Aggregate signals:**
   - `ticket.discovery` events across the epic — raw signals of design mistakes (places where the spike plan was wrong, and `/implement` had to work around it).
   - `spike.phase.*.completed` metrics: consensus iteration counts, rejection/return-to-phase counts, total spike duration.
   - Cross-reference against prior epics' chronic patterns in `~/.claude/autodev/chronic-design-patterns.json`.
5. **Update the chronic-design-patterns store** — match discoveries against existing patterns (increment frequency on match, create new pattern on novel signal). Promote at frequency ≥ `config.pipeline.chronicPromotionThreshold` (default 3). Enforce cap `config.pipeline.maxActivePatterns` (default 20) with LRU eviction. Demote patterns clean for ≥ `config.pipeline.cleanRunsForDemotion` runs (default 5).
6. **Sync CLAUDE.md chronic-design-patterns section** between sentinel markers (atomic write with backup, per the existing code-pattern implementation in `/implement` Phase 7).
7. **Emit** `spike.retro.completed` with `{epicId, patternsPromoted, patternsDemoted}` and `spike.phase.5.completed`.
8. **Run phase-gate.sh end 5.**

**Banner:** `--- Spike Phase 5 Complete: Retro — promoted: ${promoted} | demoted: ${demoted} ---`

---

## Status (`/spike --status EPIC-ID`)

Show session state without running any phase:

1. Resolve `SESSION_DIR` for this epic.
2. Run `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/wake.sh` to get `{sessionDir, lastSeq, currentPhase, status, pendingAction, minimumContext}`.
3. Print:
   - Epic ID, plan doc path, status (planning / in-progress / all-tickets-integrated / done).
   - Ticket table: ID, title, status, impl-blockers, deploy-blockers (derived from `ticket-statuses.json` or events).
   - Current phase + iteration if in-progress.
   - Pending action per `wake.sh` output.
4. Exit.

## Resume (`/spike --from N EPIC-ID`)

Resume a previously-interrupted spike at phase N.

1. Resolve `SESSION_DIR` for the epic. Verify `progress-log.json` exists and `mode: "spike"`.
2. Emit `session.resumed` with `{epicId, fromPhase:N}`.
3. Load prior-phase state from `progress-log.json.phases[]`.
4. Jump to Phase N's dispatcher preamble and continue through the remaining phases.

Resume is safest at phase boundaries (between completed phases). Mid-phase interruption can be resumed but the user should expect some Phase-N work to be redone — the event log surfaces which iteration was last `spike.phase.N.iteration.M.started` so the orchestrator can skip forward.

---

## Explicitly NOT Added (see design spec §9)

- **Tracker integration** (`gh issue create`, JIRA API, Linear API) — `/spike` records user-supplied IDs only; keeps the skill stack-agnostic.
- **Formal GATE scaffolding** for end-of-phase — human review is natural and informal. No freeze doc.
- **Ticket sizing / estimation** — time/effort is out of scope; the user pushed back explicitly on this in the design session.
- **Parallel implementation coordination** — one ticket at a time; cross-ticket coordination is `/implement`'s responsibility via the shared epic session.
- **Pre-spike intake / triage** — product-management concerns, not engineering workflow.

## Performance Budgets (advisory)

| Phase | Budget | Notes |
|---|---|---|
| 1 Requirements | 5 min | Multi-feature Q&A |
| 2 System design | 15 min | Architecture across epic; heavy research |
| 3 Decomposition | 10 min | One-at-a-time loop; depends on ticket count |
| 4 Gap review | 10 min | Multi-agent consensus + signoff |
| 5 Retro | 5 min | Async, runs only when all tickets merged |

Budgets are advisory, not gate-enforced.
