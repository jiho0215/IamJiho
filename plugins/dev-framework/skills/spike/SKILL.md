---
name: spike
version: 2.0.0
description: "Multi-ticket Research Spike workflow with lean YAGNI defaults. Takes a high-level epic goal and produces a master spike plan plus N per-ticket ref docs — focused on MVP scope by default with explicit prune step + severity-gated review consensus. Phase 0 gate redirects single-PR work to /implement. Phase 1 NFR is triaged (not forced-asked). Phase 2 ends with an inline scope-prune step that defers forward-compat / nice-to-have / 'while-we-here' items. Phase 4 multi-agent consensus exits on zero Critical+Major findings (Minor/Nit go to review-backlog.md without blocking). Power-user escape hatch: framework defaults lean but users can manually expand spike-plan.md sections for genuine enterprise contexts (HIPAA, high-scale, etc.). 5 phases: Requirements → System Design (with inline prune) → Ticket Decomposition → Cross-Ticket Gap Review → Retro. Use when the user wants to decompose a genuinely multi-PR feature; for single-PR work, Phase 0 redirects to /dev-framework:implement. Also trigger on: '/spike', 'plan this epic', 'decompose this feature', 'research spike', 'break this down into tickets', 'multi-ticket plan'."
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
| `references/autonomous/mistake-tracker-protocol.md` (design variant) | Phase 5 retro |

The /implement reference tree is shared by design — these are internal protocols, not user-facing skills, and `/spike` reuses them where semantics match.

## Multi-Agent Consensus (lean defaults — v2.0)

Phases 1, 2, and 4 run multi-agent consensus via `../implement/references/protocols/multi-agent-consensus.md`. **Lean defaults apply** unless a phase overrides them:

- `agents`: Phase 1 = 1 (user is human consensus), Phase 2 = 1 (architect deep-dive), Phase 4 = 2 (cross-ticket dependency multi-perspective)
- `max_iterations: 10` (hard cap — infinite-loop guard)
- `exit_on: zero_blocking` (severity-gated — only Critical + Major findings block exit; Minor + Nit findings append to `docs/plan/{epic}/review-backlog.md` without gating convergence)

**Severity rubric** (concrete language so reviewers don't inflate):

| Severity | Definition |
|---|---|
| **Critical** | Ship 시 data corruption / security breach / production outage 가능 |
| **Major** | Oncall이 incident 디버그 불가 / documented contract 깨짐 / concurrency bug |
| **Minor** | System 동작. 개선 기회 (test coverage gap, naming, completeness) |
| **Nit** | Style / 문서 / 부가 thoroughness |

The protocol treats `Critical` and `Major` as blocking; `Minor` and `Nit` as backlog. The reviewer agent's task instruction MUST include this rubric — without it, severity inflation defeats the gate.

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

Runs sequentially through Phase 0 (gate) + Phases 1-4. Phase 5 runs asynchronously later, triggered by `/spike --retro EPIC-ID` once all tickets reach `merged` status.

### Phase 0 — Scope-or-implement gate (v2.0 NEW)

Before Session Initialization, run a 2-question gate to redirect single-PR work away from spike's multi-ticket overhead:

**Q1**: "Could this epic ship as a single PR (~500 LOC, ~1주일 작업)?"
- **Yes** → exit with: `"This is single-PR scope. Use /dev-framework:implement <ticket> instead — spike adds overhead for single-ticket work without benefit."` Emit `spike.aborted` with `{epicId, reason: "single-pr-scope"}` and stop.
- **No** → continue to Q2.

**Q2**: "How many PRs do you anticipate for this epic?"
- **1** → same as Q1=yes; redirect to /implement.
- **2-4** → continue to Section S Session Initialization.
- **5+** → flag scope warning: `"5+ PR scope is unusual. Confirm this is one cohesive epic (not multiple independent epics) or split into sub-epics now."` User confirms or splits before continuing.

**Why**: PR1 retro identified that spike's ceremony (5 phases, multi-agent consensus, plan doc, ticket refs) inflates single-PR work. The gate is cheap (2 questions) and prevents wrong-tool-for-the-job misuse.

**Implementation note**: Phase 0 runs after Pre-Workflow's epic ID resolution but BEFORE Session Initialization. If Q1 redirects, no SESSION_DIR state is created. If Q2=5+ and user splits, the resulting smaller epic restarts at Phase 0 with the new (smaller) scope.

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
3. **Non-functional requirements (triaged — v2.0)** — single triage question first; only ask follow-up NFR for applicable categories:

   ```
   "이 epic이 다음 중 어떤 거에 해당해? (해당되는 것 모두 선택)
   [ ] 새 user-facing 엔드포인트 / API → SLA 질문
   [ ] PII / 사용자 데이터 처리 → privacy / compliance 질문
   [ ] 새 user-visible UI → accessibility 질문
   [ ] 인증 / 권한 변경 → security threat model 질문
   [ ] 위 어느 것도 아님 → NFR sub-section 전체 omit"
   ```

   For each checked box, ask the original question with a default fallback (SLA target, threat-model depth, WCAG tier, etc.). For unchecked boxes, do NOT ask — they're explicitly out of scope.

   **If all unchecked**: §1 of `spike-plan.md` keeps goal + success criteria but **omits the NFR sub-section entirely** (no "N/A" placeholder — full omission). Power-user escape hatch: user can manually add NFR detail to the file later if context surfaces a need.

   **Why triaged**: PR1 retro showed forced-asking NFR for irrelevant categories (a transaction-categorization feature got asked about SLA / privacy / accessibility) committed those concerns to spec where they bloated subsequent phases. Triage lets the user honestly say "not applicable" without ceremony.
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
   - `agents_list: 1 architect agent` (lean default — see Multi-Agent Consensus section)
   - `exit_on: zero_blocking` (severity-gated)
   - Context: "Validate epic architecture coherence. Equally weight: (a) what's MISSING (component boundaries, data flow gaps, contract mismatches) AND (b) what should be REMOVED (forward-compat baked in, 'while we're here' cleanup, speculative future-proofing without evidence)."

10. **Inline scope prune (v2.0 NEW — replaces separate Phase 2.5)** — single-agent task at end of Phase 2:

    ```
    Agent task: Read spike-plan.md §2-§6. List items NOT required for first ship to be useful.
    Classify each:
      - forward-compat: preparing for future PR; current epic ships without it
      - nice-to-have: improvement opportunity, not correctness
      - while-we-here: unrelated cleanup that snuck in
      - future-need: speculative requirement without current evidence
    For each item, propose: keep in MVP / move to deferred / remove entirely.
    ```

    Present output to user. User reviews and overrides classifications. Approved deferred items are folded INTO `spike-plan.md` §10 (NEW — `## §10 Deferred items`) with format:

    ```markdown
    ## §10 Deferred items

    These items were considered during Phase 2 but deferred to follow-up epics or to
    /implement Phase 4 backlog. Revisit when [trigger condition specified per item].

    - **<item>** — Type: <forward-compat | nice-to-have | while-we-here | future-need>
      - Why deferred: <1-2 sentence rationale>
      - When to revisit: <specific trigger or "next epic" or "post-MVP retro">
    ```

    **Why inline (not separate Phase 2.5)**: avoids new yaml file + new banner + new emit ceremony. The prune is a sub-step of Phase 2's exit, not a separate orchestration phase. If experience shows it warrants its own phase, v2.1 promotes it.

    **Emit**: `spike.scope.pruned` with `{epicId, deferredCount, items: [{type, summary}]}`.

**Update:** `progress-log.json` — set `planDocPath: "docs/plan/${epicId}/spike-plan.md"`.
**Emit:** `spike.phase.2.completed`.
**Gate:** `phase-gate.sh end 2`.
**Banner:** `--- Spike Phase 2 Complete: System Design (deferred ${deferredCount} items) ---`

### Phase 3 — Ticket Decomposition

**Gate:** `phase-gate.sh begin 3`
**Emit:** `spike.phase.3.started`.

Decompose one ticket at a time. The one-at-a-time loop is deliberate: it forces the user to reason about each ticket in the context of what came before, which is when blocker classification is done correctly.

**Per-iteration:**

1. **Propose** — draft a ticket title and a 2-3-sentence scope summary derived from the spike-plan §2-§6 content. Example: "`pay-123` — Payment API endpoint. Scope: POST /payments handler, auth, persistence, basic validation. Implements contract §5 lines 12-40; owns migration step 2."

   **Size sanity (v2.0 — soft guidance, no hard threshold)**: ask user "예상 LOC?" — if estimate ≥800 LOC, prompt "consider splitting? a single ticket >800 LOC tends to push reviewable PRs into multi-day cycles". User can justify and proceed; framework records the justification in `decision-log.json` but does NOT block. Hard thresholds defer to v2.1 once we have data on what actually works in practice.

   **Forward-compat check (v2.0 NEW)**: when user describes scope including "and we'll need X for PR3" or "register Y now so future PR can...", framework prompts:
   ```
   "Item '<X>' sounds like forward-compat. Can THIS PR ship without it?
    - Yes → automatic deferred (added to ticket §3/§4/§5 'Deferred' sub-section, NOT MVP)
    - No → MVP. Justify why blocking (recorded in decision-log.json)."
   ```

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
   - `agents_list: 2 reviewers` (lean default — see Multi-Agent Consensus section)
   - `exit_on: zero_blocking` (severity-gated — see rubric in Multi-Agent Consensus section)
   - Context (gap review — equally weight ADD and REMOVE concerns per v2.0):
     - **Coverage check (additive)**: "Does the ticket set fully cover epic §1 requirements? Flag uncovered requirements as Critical or Major."
     - **Pruning check (subtractive — v2.0 NEW)**: "Is anything in the ticket set forward-compat / nice-to-have / 'while-we-here' that should be deferred? Flag with severity:
       - Forward-compat (next-PR setup baked in current PR): Major if it's expensive to undo later, else Minor
       - 'While we're here' (unrelated cleanup): Minor
       - 'In case of...' (speculative future-proofing): Minor or Nit"
     - **Dependency check**: "Is the dependency graph acyclic and minimally coupled? Hard blockers actually hard, or 'might want' that should be soft?"
     - **Deploy order**: "Is the `deployBlockedBy` order actually deployable end-to-end?"
     - **Cross-ticket testing**: "Are there integration tests in §8 that span tickets where needed?"
     - **Severity classification mandatory**: every finding tagged Critical / Major / Minor / Nit per the rubric in Multi-Agent Consensus section.
   - Iterate until `exit_on: zero_blocking` (zero Critical + zero Major). Minor + Nit findings append to `docs/plan/{epicId}/review-backlog.md` (NEW artifact, see template) without blocking exit. Hard cap 10 iterations.
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
2. **Read the mistake-tracker-protocol (design variant)** from `references/autonomous/mistake-tracker-protocol.md` into context. The code variant at `../implement/references/autonomous/mistake-tracker-protocol.md` is structurally similar but targets a different taxonomy and store; do not conflate them.
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

## Power-user escape hatch (v2.0)

Framework defaults are **lean by design** (YAGNI — see `docs/specs/2026-04-27-spike-lean-redesign.md`). For genuine enterprise contexts where lean defaults are insufficient, **users can manually expand** `spike-plan.md` and ticket ref docs without framework intervention. The framework does not prompt for these and does not require them, but does NOT block them either.

**When this matters** (concrete examples — none of these are framework-prompted):

- HIPAA / PCI / regulated data context → user manually adds detailed threat model in §1 NFR
- High-traffic system (1000+ RPS) → user adds SLO / SLI burn rate alerts in §4 Observability
- External API consumers → user adds backwards-compatibility policy + deprecation timeline in §5 API contracts
- Multi-team coordination → user adds RACI / ownership matrix anywhere appropriate

**How**: `spike-plan.md` is a markdown file. User edits directly with any editor. Framework re-reads on `/spike --status` and `/implement` consumes ticket refs as-is. No special mechanism, flag, or mode needed.

**Cost awareness**: thoroughness has nontrivial cost (review cycles, maintenance burden, cognitive load). Framework defaults to lean because most epics don't need it; users who genuinely need more are responsible for the ROI judgment. The framework makes the trade-off explicit by NOT generating these sections by default — the absence is a feature, not a gap.

If a class of escape-hatch usage becomes consistent across epics, that's evidence to promote it from "user manually adds" to "framework generates" in v2.1.

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
