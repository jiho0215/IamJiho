---
name: spike
version: 3.0.0
description: |
  Universal planning skill across all ticket levels: Epic (multi-ticket decomposition),
  Story (single-ticket freeze doc), and Research (investigation that doesn't ship code).
  Dispatches the research-investigator agent for any blocking investigation — external
  docs, internal codebase, empirical testing, user collaboration, behavioral observation.
  Owns freeze-doc creation and the GATE 1 approval handshake that unlocks /implement.
  Operates in seven shared phase building blocks (P1 Scope → P2 Investigate → P3 Decompose →
  P4 Spec → P5 Review → P6 Approve → P7 Retro), with each mode skipping the phases that
  don't apply (Story skips P3; Research skips P3 and P5). Supports `/spike --revisit`
  for verification-failure recovery against an immutable approved freeze doc.

  Use whenever the user wants to plan engineering work at any size; /implement is the
  pure-execution complement that consumes the freeze doc spike produces. Trigger on:
  '/spike', 'plan this', 'plan this epic', 'decompose this feature', 'break this into
  tickets', 'research spike', 'investigate', 'spec this story', 'I need to research X',
  'freeze doc', 're-spike', '--revisit', 'verification failed re-plan'.
---

# `/spike` — Universal Planning Skill (v3)

You are orchestrating one rigorous planning run for this user. `/spike` is the **single planning skill** for any ticket level — Epic, Story, or Research. It produces the artifacts (`spike-plan.md`, `freeze-{ticket}.md`, `research-{ticket-or-slug}.md`) that `/implement` (Story execution) or downstream readers (Research consumers) act on. Move slow, do it right; spike is where architectural coherence is earned.

`/spike` is the **complement** to `/implement`. Spike owns ALL planning plus the user check-in (GATE 1). `/implement` is pure execution against an APPROVED freeze doc. They share one epic-scoped event log so `wake()` returns full cross-ticket and cross-skill state in a single call. Plan/freeze/research docs live in-repo under `docs/plan/{epic-or-slug}/` — they are first-class engineering artifacts, PR-reviewable and version-controlled.

## Invocation Modes

Parse `$ARGUMENTS`. Route to the first matching branch:

| Args match | Mode | Section |
|---|---|---|
| `--retro EPIC-OR-SLUG` | Async post-merge retro | Section R |
| `--status EPIC-OR-SLUG` | Show spike status and exit | see Status below |
| `--from N EPIC-OR-SLUG` | Resume at phase N | see Resume below |
| `--revisit EPIC-OR-SLUG --reason <reason>` | Re-spike for verification-failure recovery | Section `--revisit` |
| `research <topic>` | Standalone Research mode | Section S (mode=research) |
| `story <ticket-id>` | Standalone Story mode | Section S (mode=story) |
| Non-empty description (no keyword prefix) | Epic mode (default; multi-ticket decomposition) | Section S (mode=epic) |
| Empty args | Ask user for the epic goal, then route to Section S | — |

There is **no scope-or-implement gate**. Modes are explicit at invocation. Single-PR work uses `/spike story <ticket-id>`; multi-PR work uses the bare-description Epic form; investigation-only work uses `/spike research <topic>`.

## Pre-Workflow (runs for every mode)

Before entering any section, execute these steps in order:

1. **Ensure config** — `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/ensure-config.sh` (idempotent; creates `~/.claude/autodev/config.json` with defaults if absent). Single source of truth for the default config schema.
2. **Resolve identifier**:
   - Epic mode: ask user for the epic ID / slug. Sanitize: lowercase, replace spaces with dashes, strip special chars. Example: `"Payments V2"` → `payments-v2`. The identifier becomes the `{epic-or-slug}` directory segment.
   - Story mode: `{epic-or-slug}` = the supplied ticket ID (sanitized).
   - Research mode: `{epic-or-slug}` = the supplied topic slug, or the user-provided ticket ID if any.
   - Retro / status / resume / revisit: read `EPIC-OR-SLUG` from `$ARGUMENTS`.
3. **Resolve session folder** — `SESSION_DIR = ~/.claude/autodev/sessions/{repo}--epic-{epicOrSlug}/`. The repo segment uses the same sanitization algorithm as `../implement/references/autonomous/session-management.md`. For standalone Story/Research the prefix is still `epic-` (uniform sessions across modes; see spec §7).
   - Create `SESSION_DIR` if absent (`mkdir -p`). An existing folder means another skill has already touched this work — that's fine; `/spike` and `/implement` share the folder by design.
4. **Docs folder scaffolding** — ensure `<repo>/docs/plan/{epicOrSlug}/` exists (`mkdir -p`). If this is the first plan folder ever in the repo, append a one-line entry to `<repo>/docs/README.md` (or create it) pointing to `docs/plan/` for discoverability.
5. **Emit `spike.mode.detected`** — once `MODE` resolves:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh spike.mode.detected \
     --actor orchestrator \
     --data "$(jq -cn --arg mode "$MODE" --arg epicOrSlug "$EPIC_OR_SLUG" \
       '{mode:$mode, epicOrSlug:$epicOrSlug}')"
   ```
6. **Emit `session.started`**:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh session.started \
     --actor orchestrator \
     --data "$(jq -cn --arg mode "spike-$MODE" --arg epicOrSlug "$EPIC_OR_SLUG" \
       '{mode:$mode, epicId:$epicOrSlug, skill:"spike"}')"
   ```
   Use `mode = "spike-epic"`, `"spike-story"`, `"spike-research"`, `"spike-retro"`, `"spike-resume"`, `"spike-status"`, or `"spike-revisit"` to match the invocation branch.
7. **Emit `config.snapshot.recorded`** — capture effective config so reducers can populate `progress-log.json.configSnapshot`:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh config.snapshot.recorded \
     --actor orchestrator \
     --data "$(jq -c '.pipeline | {maxReviewIterations, consecutiveZerosToExit, modelProfile}' ~/.claude/autodev/config.json)"
   ```

The resolved `SESSION_DIR` is stable across all invocations for this epic-or-slug. Multiple `/spike` and `/implement` calls append to the same `events.jsonl`.

## Companion References (read on demand)

Read these internal references into context when the current phase needs them. They are not external skills; invoke with your Read tool.

| Reference | When to read |
|---|---|
| `references/templates/SPIKE_PLAN_TEMPLATE.md` | Epic mode P4 — spike-plan.md skeleton |
| `references/templates/FREEZE_DOC_TEMPLATE.md` | P4 — Story freeze docs (Epic-child or standalone) |
| `references/templates/RESEARCH_DOC_TEMPLATE.md` | P4 — Research output doc (Epic-child or standalone) |
| `references/templates/TICKET_REF_TEMPLATE.md` | Epic mode P3 — per-child ref docs (Story children point at their freeze doc) |
| `references/templates/REVIEW_BACKLOG_TEMPLATE.md` | P5 — Minor / Nit backlog file |
| `references/protocols/research-dispatch.md` | P2 — dispatching research-investigator agent (Epic P3 → P2 re-entry, or Story P2 inline) |
| `references/guardrails.md` | Inject into every agent system prompt (SOLID / DRY / YAGNI / read-only investigation / secrets handling) |
| `references/autonomous/mistake-tracker-protocol.md` | P7 retro — design-pattern extraction |
| `../implement/references/protocols/multi-agent-consensus.md` | P5 — multi-agent consensus loop and severity rubric |
| `../implement/references/methodology/DECISION_MAKING.md` | Any phase that records an ADR |
| `../implement/references/templates/ADR_TEMPLATE.md` | P2 ADR production for cross-ticket architectural decisions |
| `../implement/references/autonomous/session-management.md` | Session folder + repo sanitization helpers |
| `../implement/references/autonomous/events-schema.md` | Event type catalog and validation rules |

The /implement reference tree is shared by design — these are internal protocols, not user-facing skills, and `/spike` reuses them where semantics match. The Research agent (`agents/research-investigator.md`) also reads `references/guardrails.md` first thing.

## Multi-Agent Consensus (lean defaults — carryover from v2.0)

P5 (and any phase that explicitly dispatches multiple review agents) runs multi-agent consensus via `../implement/references/protocols/multi-agent-consensus.md`. **Lean defaults apply** unless overridden:

- `agents`: P5 = 2 reviewers by default (cross-ticket gap perspective in Epic mode; single-artifact perspective in Story mode); other phases dispatch a single primary agent.
- `max_iterations: 10` (hard cap — infinite-loop guard).
- `exit_on: zero_blocking` (severity-gated — only Critical + Major findings block exit; Minor + Nit findings append to `docs/plan/{epic-or-slug}/review-backlog.md` without gating convergence).

**Severity rubric** (concrete language so reviewers don't inflate):

| Severity | Definition |
|---|---|
| **Critical** | Ship 시 data corruption / security breach / production outage 가능 |
| **Major** | Oncall이 incident 디버그 불가 / documented contract 깨짐 / concurrency bug |
| **Minor** | System 동작. 개선 기회 (test coverage gap, naming, completeness) |
| **Nit** | Style / 문서 / 부가 thoroughness |

The protocol treats `Critical` and `Major` as blocking; `Minor` and `Nit` as backlog. The reviewer agent's task instruction MUST include this rubric — without it, severity inflation defeats the gate. Never short-circuit. Fixing issues without re-dispatching agents is NOT a zero-issue round.

## Event Emissions

Every orchestrator-level state transition in `/spike` dual-writes to `$SESSION_DIR/events.jsonl` via `emit-event.sh`. Events are shared with `/implement` (and any concurrent fan-out children) on this epic-or-slug.

**Emit command template:**

```bash
bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh <type> \
  --actor orchestrator \
  --data '<JSON object>'
```

**/spike-specific emit points** (full catalog in `../implement/references/autonomous/events-schema.md`):

| Point | Type | Actor | Data shape |
|---|---|---|---|
| Pre-Workflow mode resolved | `spike.mode.detected` | orchestrator | `{mode, epicOrSlug}` |
| Pre-Workflow complete | `session.started` | orchestrator | `{mode, epicId, skill:"spike"}` |
| Pre-Workflow config | `config.snapshot.recorded` | orchestrator | `{maxReviewIterations, consecutiveZerosToExit, modelProfile}` |
| P1 begin / end | `spike.phase.1.started` / `.completed` | orchestrator | `{epicOrSlug, phase:1, mode}` |
| P2 begin / end | `spike.phase.2.started` / `.completed` | orchestrator | same |
| Each research dispatch | `research.dispatched` | orchestrator | `{epicOrSlug, ticketIdOrSlug, question, blockedStoryTickets}` |
| Research crash recovery | `research.redispatched` | orchestrator | `{epicOrSlug, ticketIdOrSlug, attempt}` |
| Research intermediate (long runs) | `research.findings.captured` | research-investigator | `{epicOrSlug, ticketIdOrSlug, partialFindings}` |
| Research agent end | `research.completed` | research-investigator | `{epicOrSlug, ticketIdOrSlug, outputDocPath, schemas, samples}` |
| Reducer-derived unblock | `ticket.research.completed` | reducer | `{epicOrSlug, ticketIdOrSlug, unblocks:[storyTicketIds]}` |
| P3 begin / end (Epic only) | `spike.phase.3.started` / `.completed` | orchestrator | `{epicOrSlug, phase:3}` |
| Each child decomposed | `ticket.decomposed` | orchestrator | `{epicOrSlug, ticketId, title, kind:"story"|"research", implBlockedBy, deployBlockedBy}` |
| Full DAG built | `spike.tickets.decomposed` | orchestrator | `{epicOrSlug, tickets:[...]}` |
| Scope prune (P4) | `spike.scope.pruned` | orchestrator | `{epicOrSlug, deferredCount, items:[...]}` |
| P4 begin / end | `spike.phase.4.started` / `.completed` | orchestrator | same |
| P5 begin / end | `spike.phase.5.started` / `.completed` | orchestrator | same |
| P6 begin | `spike.phase.6.started` | orchestrator | same |
| P6 freeze doc approved | `freeze.doc.approved` | orchestrator | `{epicOrSlug, ticketId, freezeDocPath, approvedHash, approvedBy}` |
| P6 research doc approved | `research.doc.approved` | orchestrator | `{epicOrSlug, ticketIdOrSlug, researchDocPath, approvedBy}` |
| P6 user signoff approved | `spike.gate.approved` | orchestrator | `{epicOrSlug, approvedBy}` |
| P6 user signoff rejected | `spike.gate.rejected` | orchestrator | `{epicOrSlug, returnToPhase, reason}` |
| P6 end | `spike.phase.6.completed` | orchestrator | same |
| Revisit started | `spike.revisit.started` | orchestrator | `{epicOrSlug, reason, revokedFreezeDocs:[...]}` |
| Revisit completed | `spike.revisit.completed` | orchestrator | `{epicOrSlug, newFreezeDocs:[...]}` |
| P7 begin (async) | `spike.phase.7.started` | orchestrator | `{epicOrSlug, phase:7}` |
| P7 retro end | `spike.retro.completed` + `spike.phase.7.completed` | orchestrator | `{epicOrSlug, patternsPromoted, patternsDemoted}` |
| All children merged | `spike.integration.verified` | integrator | `{epicOrSlug, ticketCount}` — emitted by integration verifier, not by /spike itself |
| Bi-dir events from /implement | `ticket.started`, `ticket.discovery`, `ticket.merged` | implement | — read but not emitted here |

Emits are best-effort (exit 0 on missing session). Never abort a phase on emit failure.

## Mode → Phase Sequence

| Mode | Sequence | Notes |
|---|---|---|
| Epic | P1 → P2 → P3 → P4 (per child) → P5 → P6 → P7 (async) | Decompose included; P4 iterates per child (one freeze doc per Story child, one research doc per Research child, plus the umbrella spike-plan.md); P5 = cross-ticket gap consensus. |
| Story | P1 → P2 → P4 → P5 → P6 → P7 (async) | Skip Decompose. P2 may dispatch the research-investigator agent for blocking inline questions. P5 = single-artifact gap consensus on the freeze doc. |
| Research | P1 → P2 (agent-driven) → P4 (synthesize) → P6 → P7 (async) | Skip Decompose; skip P5 (single artifact, no cross-ticket gaps). P2 is essentially the agent run; P4 synthesizes its findings into the final `research-{ticket-or-slug}.md`. |

Only Epic walks the full path. Story and Research are leaner by skipping the phases that don't apply (spec §3, §8).

---

## Section S: Spike Run (P1–P6)

Runs sequentially through P1 through P6 per the mode's sequence above. P7 runs asynchronously later, triggered by `spike.integration.verified` (or by `/spike --retro` on demand once all children are merged); Research-only flows skip P7 entirely (no merge event ever — spec §7).

### Dispatcher Preamble (per phase)

Before running any phase body below, read `phases/spike/p${N}-${name}.yaml` and act on its metadata:

1. **Lazy-load refs:** for each entry in `requiredRefs[]`, read that file with the Read tool.
2. **Emit entry events:** execute each emit in `emits.entry[]` via `emit-event.sh`.
3. **Run begin gates:** run each script listed in `gates.begin[]`.
4. **Consult narrative + checklist:** phase YAML `instructions.*` is the action checklist; the prose below explains the why and how-to-think.
5. **Invoke** per `invokes[]`:
   - `kind: agent` → invoke via Task tool (or `fan-out.sh` for `research-investigator`, per `references/protocols/research-dispatch.md`).
   - `kind: skill` → `execute.sh skill <name>`; invoke the actual Skill tool, then call `execute.sh --complete skill <name>`.
   - `kind: protocol` → read the reference file and apply.
   - `kind: hook` → `execute.sh hook <name>` runs to completion.
6. **Verify produces:** before end gates, verify each `produces[]` artifact or section exists.
7. **Run end gates** and **emit exit events** when the phase body concludes.

If a spike-phase YAML is missing, fall back to this file's phase prose as the single source of truth.

### P1 Scope

**Purpose:** clarify requirements at the appropriate level (Epic / Story / Research). Single primary agent: `config.pipeline.skills.requirements` (default `requirements-analyst`).

**Gate:** `phase-gate.sh begin 1`
**Emit:** `spike.phase.1.started`.

Dialogue-gather requirements through the mode's lens:

- **Epic mode** — gather epic goal (one paragraph), success criteria (bullet list, testable at epic scope), NFR triage (single multi-select; only ask follow-up NFR for applicable categories — see v2.0 rubric in §1 below), rollout / rollback strategy. Output: `spike-plan.md` §0–§1 sketch (in-memory draft until P4).
- **Story mode** — gather ticket-level acceptance criteria, edge cases the user already knows about, and any cross-ticket constraints. Output: in-memory requirements summary that becomes freeze doc §1 in P4.
- **Research mode** — gather the research question, scope (which Story decisions hinge on it), required output shape (schemas / behaviors / edge cases), interaction allowance. Output: in-memory question scope that becomes the research doc's §1 in P4 and the agent's input contract in P2.

**NFR triage (Epic / Story, carryover from v2.0).** Single triage question first; only ask follow-up NFR for applicable categories (`user-facing API`, `PII`, `user-visible UI`, `auth/authz`, `none-of-the-above`). For each checked box, ask the original question with a default fallback. For unchecked boxes, do NOT ask. If all unchecked, omit the NFR sub-section entirely (no "N/A" placeholder).

**Update:** `progress-log.json` (append phase entry).
**Emit:** `spike.phase.1.completed`.
**Gate:** `phase-gate.sh end 1`.
**Banner:** `--- Spike P1 Complete: Scope ({mode}) ---`

### P2 Investigate

**Purpose:** architecture and research. The `architect` agent produces the design sketch. **For each blocking investigation, the orchestrator dispatches the `research-investigator` agent per `references/protocols/research-dispatch.md`.** This is the only place in `/spike` that fans out to a long-running agent.

**Gate:** `phase-gate.sh begin 2`
**Emit:** `spike.phase.2.started`.

1. **Architecture sketch (Epic / Story).** Invoke the architect agent (`config.pipeline.skills.architect`, default `feature-dev:code-architect`). Produce component design (mermaid where useful), data flow, NFR enforcement points. Create ADR(s) under `<repo>/docs/adr/` for cross-ticket architectural decisions using `../implement/references/templates/ADR_TEMPLATE.md` and `../implement/references/methodology/DECISION_MAKING.md`.

2. **Research dispatch.** Triggers differ by mode:
   - **Epic mode**: research children are surfaced during P3 Decompose; P2 is re-entered per Research child to dispatch the agent. The orchestrator iterates `research children` from the DAG and fans out `research-investigator` for each one (parallel allowed when no shared dependency).
   - **Story mode**: research is inline within the Story spike. P2 determines whether a blocking question needs the agent; if yes, dispatch directly. The output sidecar lives at `docs/plan/{epicOrSlug}/research-{question-slug}.md` and its findings are also summarized into freeze doc §2–§4.
   - **Research mode**: P2 IS the agent run. Dispatch the agent with the P1-gathered question scope; the agent's output becomes the P4 input.

   Each dispatch follows `references/protocols/research-dispatch.md`:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/fan-out.sh \
     --name "research-${TICKET_OR_SLUG}" \
     --share-events
   ```
   Emit `research.dispatched`. The child agent runs in its own SESSION_DIR sharing `events.jsonl` with the parent; on completion it emits `research.completed`, which the parent reducer turns into `ticket.research.completed` to unblock the relevant Story tickets in P4.

3. **Crash recovery.** On resume (`/spike --from 2` or stateless wake), if `research.dispatched` exists for ticket X without a matching `research.completed`, parent re-dispatches a fresh agent for X and emits `research.redispatched`. Re-dispatch is idempotent (the agent reads any prior partial output from child SESSION_DIR if present).

**Update:** `progress-log.json` (append phase entry; record each dispatched/completed research).
**Emit:** `spike.phase.2.completed`.
**Gate:** `phase-gate.sh end 2`.
**Banner:** `--- Spike P2 Complete: Investigate (researchCount: ${n}) ---`

### P3 Decompose (Epic mode only)

**Purpose:** build the DAG of children — Story children and Research children with dependency edges. Skipped in Story and Research modes.

**Gate:** `phase-gate.sh begin 3` (Epic only)
**Emit:** `spike.phase.3.started` (Epic only)

Decompose one child at a time. The one-at-a-time loop is deliberate: it forces the user to reason about each child in the context of what came before, which is when blocker classification is done correctly.

**Per-iteration:**

1. **Propose** a child (Story or Research). Title + 2–3-sentence scope summary derived from P2's architecture sketch. Mark `kind: story` or `kind: research`.

2. **Size sanity (carryover from v2.0; soft guidance, no hard threshold).** For Story children, ask "예상 LOC?" — if estimate ≥800 LOC, prompt to consider splitting. Framework records justification in `decision-log.json` but does NOT block.

3. **Forward-compat check (carryover from v2.0).** If user describes scope that includes "and we'll need X for PR3" or "register Y now so future PR can…", prompt: can THIS child ship without it? If yes → automatic deferred. If no → MVP, justification recorded in `decision-log.json`.

4. **Ticket ID.** Ask for tracker ID (JIRA `PAY-123`, Linear `ENG-456`, GitHub `#47`) or a slug. Sanitize.

5. **Collision check.** If `<repo>/docs/plan/${epicOrSlug}/<id>.md` exists, prompt: overwrite, suffix, or pick a new ID.

6. **Blocker classification.**
   - `implBlockedBy`: `[{ticketId, kind: hard|soft, reason}, ...]`. Hard = cannot start until target merged. Soft = can start, will pay copy-paste / rework cost.
   - `deployBlockedBy`: `[{ticketId, kind: hard, reason}, ...]`. Soft deploy blockers are rare; usually indicate conflating deploy with implementation.
   - For Story children that depend on a Research child's output, record `research-{ticket}` in `implBlockedBy` with `kind: hard`.

7. **Instantiate ticket ref** from `references/templates/TICKET_REF_TEMPLATE.md`. Story children link to their forthcoming freeze doc; Research children link to their forthcoming research doc.

8. **Emit `ticket.decomposed`** with `{epicOrSlug, ticketId, title, kind, implBlockedBy, deployBlockedBy}`.

9. **Continue loop** until user says no more children.

**Exit loop:**

- Verify the DAG is **acyclic** (DFS over `implBlockedBy` across all decomposed children). On cycle, surface the cycle path and loop back.
- Emit `spike.tickets.decomposed` with the full children array.
- Update `progress-log.json.ticketCount`.

**Emit:** `spike.phase.3.completed`.
**Gate:** `phase-gate.sh end 3`.
**Banner:** `--- Spike P3 Complete: Decompose ({ticketCount} children: ${storyCount} story / ${researchCount} research) ---`

### P4 Spec

**Purpose:** produce final artifacts. Output depends on mode:

| Mode | P4 output |
|---|---|
| Epic | `spike-plan.md` (overview + DAG + child links) + one `freeze-{ticket}.md` per Story child + one `research-{ticket}.md` per Research child |
| Story | One `freeze-{ticket}.md` for the standalone Story |
| Research | One `research-{ticket-or-slug}.md` for the standalone Research |

**Gate:** `phase-gate.sh begin 4`
**Emit:** `spike.phase.4.started`.

**Epic mode (one pass per child, in DAG topological order so Research outputs are consumed by Story specs that depend on them):**

1. **Instantiate `spike-plan.md`** from `references/templates/SPIKE_PLAN_TEMPLATE.md`. Populate frontmatter (`epicId`, `status: planning`, `createdAt`); fill §1 Requirements from P1 draft; §2 Architecture + NFR from P2; §3 Rollout / rollback; §4 Observability; §5 API contracts; §6 Data migration chain; §7 child registry (rendered from `ticket.decomposed` events).

2. **Per Story child** — instantiate `freeze-{ticket}.md` from `references/templates/FREEZE_DOC_TEMPLATE.md`. Populate §1 Requirements, §2–§4 Architecture (importing Research findings via `ticket.research.completed` unblock signal), §5 Edge Cases, §7 Interface Contracts, §8 ADR References, §9 Non-Frozen Allow List, §10 Verification Backlog (imported from blocking Research §9), §11 Prerequisites (from DAG `implBlockedBy`). **Invoke `test-strategist` agent** (`config.pipeline.skills.testStrategist`) to populate §6 Test Plan — unit + integration + e2e scenarios with coverage targets. Status remains DRAFT (header `status: DRAFT`, `approvedHash: null`) until P6.

3. **Per Research child** — instantiate `research-{ticket}.md` from `references/templates/RESEARCH_DOC_TEMPLATE.md` using the agent's output from P2. Status DRAFT until P6.

**Story mode:** one freeze doc, as in step 2 above. The Story's own P2-dispatched inline research (if any) is summarized into §2–§4 with the sidecar at `docs/plan/{epicOrSlug}/research-{question-slug}.md`.

**Research mode:** synthesize the P2 agent output into `research-{ticket-or-slug}.md`. No freeze doc; this artifact never feeds `/implement`.

**Inline scope prune (carryover from v2.0).** Single-agent task at the end of P4 (Epic and Story modes):

```
Agent task: Read artifact(s) just produced. List items NOT required for first ship to be useful.
Classify each:
  - forward-compat: preparing for future PR; current ships without it
  - nice-to-have: improvement opportunity, not correctness
  - while-we-here: unrelated cleanup that snuck in
  - future-need: speculative requirement without current evidence
For each item, propose: keep / move to deferred / remove entirely.
```

Present output to user. Approved deferred items fold into `spike-plan.md §10 Deferred items` (Epic) or freeze doc `§5 Edge Cases` "Deferred" sub-section (Story). Emit `spike.scope.pruned` with `{epicOrSlug, deferredCount, items: [{type, summary}, ...]}`.

**Update:** `progress-log.json` — set `planDocPath`, `freezeDocPaths`, `researchDocPaths`.
**Emit:** `spike.phase.4.completed`.
**Gate:** `phase-gate.sh end 4`.
**Banner:** `--- Spike P4 Complete: Spec (deferred ${deferredCount}) ---`

### P5 Review

**Purpose:** multi-agent consensus over the P4 artifacts. Skipped in Research mode (single artifact, no cross-ticket gaps to find).

**Gate:** `phase-gate.sh begin 5`
**Emit:** `spike.phase.5.started`.

Run multi-agent consensus per `../implement/references/protocols/multi-agent-consensus.md`:

- `task_type: review`
- `agents_list`: 2 reviewers by default (`code-quality-reviewer`, `observability-reviewer`; `performance-reviewer` and `test-strategist` added in Epic mode when relevant per `config.pipeline.agents.review`).
- `exit_on: zero_blocking` (severity-gated — Critical + Major block exit; Minor + Nit append to `docs/plan/{epicOrSlug}/review-backlog.md` without gating).
- Max 10 iterations.

**Review context (equally weight ADD and REMOVE concerns):**

- **Coverage check (additive)** — Epic: does the child set fully cover epic §1 requirements? Story: does the freeze doc cover all acceptance criteria from P1? Flag uncovered as Critical or Major.
- **Pruning check (subtractive)** — anything forward-compat / nice-to-have / "while we're here" that should be deferred? Forward-compat = Major if expensive to undo later, else Minor; "while we're here" = Minor; "in case of…" = Minor or Nit.
- **Dependency check (Epic only)** — DAG acyclic and minimally coupled? Hard blockers actually hard, or "might want" that should be soft?
- **Deploy order (Epic only)** — is `deployBlockedBy` order actually deployable end-to-end?
- **Cross-ticket testing (Epic only)** — are there integration tests in spike-plan §8 spanning children where needed?
- **Severity classification mandatory** — every finding tagged Critical / Major / Minor / Nit per the rubric.

For each blocking issue returned, classify and act:

- **Missing child** — re-enter P3 Decompose loop for that one child, then return.
- **Misclassified blocker** — update the child's ticket ref and re-emit `ticket.decomposed` (supersedes prior event at reducer level).
- **Freeze-doc / research-doc gap** — re-enter P4 for that artifact only.
- **Dismissible** — record rationale in `decision-log.json` category `spike-dismissed-issue`.

**Update:** `progress-log.json`.
**Emit:** `spike.phase.5.completed`.
**Gate:** `phase-gate.sh end 5`.
**Banner:** `--- Spike P5 Complete: Review (blocking: 0 / backlog: ${minorCount}) ---`

### P6 Approve (GATE 1)

**Purpose:** user signoff. This is GATE 1 — the freeze-doc immutability contract is sealed here. Always interactive; there is no autonomous spike (spec §1 non-goals).

**Gate:** `phase-gate.sh begin 6`
**Emit:** `spike.phase.6.started`.

Present to user (concise summary):

- Mode + artifacts produced (paths to spike-plan.md, freeze docs, research docs).
- Child count and DAG (Epic) or single-artifact summary (Story / Research).
- Deferred items + review backlog count.
- Unresolved blocking issues (should be zero — P5 must have exited zero-blocking).

Ask: "Approve and seal?" per artifact — y/n.

**Per artifact on approval:**

1. **Compute `approvedHash`** — sha256 of the canonical body (everything except the header `bypassHistory` field):
   ```bash
   APPROVED_HASH=$(bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/freeze-doc-hash.sh compute <path>)
   ```
   This applies to freeze docs (required by `/implement` startup verification) and to research docs (for parity / future hash-locked consumers). The spike-plan.md is not hash-locked; it's a navigation doc, not a contract.

2. **Update artifact frontmatter** —
   ```yaml
   status: APPROVED
   approvedAt: <ISO-8601 UTC>
   approvedBy: <user-identifier>
   approvalMode: interactive
   approvedHash: <sha256>
   ```

3. **Emit per-artifact approval event** —
   - Story freeze doc → `freeze.doc.approved` with `{epicOrSlug, ticketId, freezeDocPath, approvedHash, approvedBy}`.
   - Research doc → `research.doc.approved` with `{epicOrSlug, ticketIdOrSlug, researchDocPath, approvedBy}`.

4. **On any artifact rejection** — ask which phase to return to (1–5), emit `spike.gate.rejected` with `{epicOrSlug, returnToPhase, reason}`, and loop back. Do NOT compute hashes for the rejected artifact; status stays DRAFT.

After all artifacts are approved, emit `spike.gate.approved` with `{epicOrSlug, approvedBy}`. From this point the freeze-gate hook will unlock `src/**` edits for `/implement` runs invoked against the approved freeze doc paths.

**Update:** `progress-log.json` (mark all artifacts APPROVED).
**Emit:** `spike.phase.6.completed`.
**Gate:** `phase-gate.sh end 6`.
**Banner:** `--- Spike P6 Complete: Approve — signoff: {approvedBy} | approved artifacts: ${count} ---`

After P6, `/spike` is done for this invocation. Story freeze docs are now consumable by `/implement <freeze-doc-path>`; Research docs are consumable as documentation / context by future tickets. P7 runs asynchronously.

---

## Section R: Retro (P7, async — `/spike --retro EPIC-OR-SLUG`)

Triggered by `spike.integration.verified` (Epic: all-children-merged; standalone Story: that single ticket merges). **Skipped for Research-only flows entirely** — no merge event ever (spec §7).

1. **Verify prerequisite.** Query `views/ticket-statuses.json` (or fold over `events.jsonl` for `ticket.merged` events). If any child is still unmerged, exit with: `"retro not ready — N children unmerged: [list]"`.
2. **Read** `references/autonomous/mistake-tracker-protocol.md` into context. The code variant at `../implement/references/autonomous/mistake-tracker-protocol.md` is structurally similar but targets a different taxonomy and store; do not conflate them.
3. **Emit** `spike.phase.7.started`.
4. **Aggregate signals.**
   - `ticket.discovery` events across the epic — raw signals of design mistakes (places the spike plan was wrong, where `/implement` had to work around it).
   - `spike.phase.*.completed` metrics: consensus iteration counts, gate rejection / return-to-phase counts, total spike duration.
   - Cross-reference prior epics' chronic patterns in `~/.claude/autodev/chronic-design-patterns.json`.
5. **Update chronic-design-patterns store.** Match discoveries against existing patterns (increment frequency on match, create new on novel signal). Promote at frequency ≥ `config.pipeline.chronicPromotionThreshold` (default 3). Enforce cap `config.pipeline.maxActivePatterns` (default 20) with LRU eviction. Demote patterns clean for ≥ `config.pipeline.cleanRunsForDemotion` runs (default 5). Research-agent-pattern discoveries are tracked under `patterns/research/` namespace (spec §7).
6. **Sync CLAUDE.md chronic-design-patterns section** between sentinel markers (atomic write with backup).
7. **Emit** `spike.retro.completed` + `spike.phase.7.completed` with `{epicOrSlug, patternsPromoted, patternsDemoted}`.
8. **Run** `phase-gate.sh end 7`.

**Banner:** `--- Spike P7 Complete: Retro — promoted: ${promoted} | demoted: ${demoted} ---`

---

## Section --revisit: Verification-Failure Recovery

When the user has approved a freeze doc, started `/implement`, and discovered via the §10 Verification Backlog that an assumption was wrong, the freeze doc is **immutable** (hash-locked). The recovery path is `/spike --revisit EPIC-OR-SLUG --reason <reason>`.

**Behavior:**

1. **Verify epic-or-slug exists** in `docs/plan/`. Fail if not found.
2. **Revoke existing freeze docs.** Rename each `freeze-{ticket}.md` (or `freeze-{epicOrSlug}.md` for standalone Story) to `freeze-{ticket}.revoked.md`. Research docs are NOT revoked — their findings are still input.
3. **Emit `spike.revisit.started`** with `{epicOrSlug, reason, revokedFreezeDocs: [...]}`. (New event in v5; documented in `events-schema.md`.)
4. **Re-enter at P2 Investigate** with prior research findings + the user-supplied new empirical findings as input. The architect agent is informed of which assumption was wrong (passed via `reason`) and produces an updated design.
5. **Continue through P4 (new freeze doc(s)) → P5 → P6**. Each new freeze doc gets a fresh `approvedHash` at P6. The revoked sibling file is preserved on disk for audit (it captures the prior approval moment).
6. **Emit `spike.revisit.completed`** with `{epicOrSlug, newFreezeDocs: [...]}`.

Manual edits to a hash-locked freeze doc are blocked at `/implement` startup (hash mismatch); freeze-gate hook also denies `src/**` edits when hash doesn't match. There is no silent corruption path — verification-failure either drives `--revisit` or the user opens a brand-new ticket via Section S.

**Why immutable + revisit, not in-place edit:** the freeze doc is a contract. If reality contradicts it, the contract is renegotiated (new doc, new hash, new approval moment) rather than mutated. This preserves the audit trail and forces explicit user check-in on changed assumptions.

---

## Status (`/spike --status EPIC-OR-SLUG`)

Show session state without running any phase:

1. Resolve `SESSION_DIR` for the epic-or-slug.
2. Run `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/wake.sh` to get `{sessionDir, lastSeq, currentPhase, status, pendingAction, minimumContext}`.
3. Print:
   - Epic-or-slug, mode (epic / story / research), plan / freeze / research doc paths, status (planning / in-progress / approved / all-children-merged / done).
   - For Epic: child table with ID, kind, title, status, impl-blockers, deploy-blockers (derived from `ticket-statuses.json` or events).
   - Current phase + iteration if in-progress.
   - Pending action per `wake.sh` output.
4. Exit.

## Resume (`/spike --from N EPIC-OR-SLUG`)

Resume a previously-interrupted spike at phase N.

1. Resolve `SESSION_DIR`. Verify `progress-log.json` exists and `mode` matches `spike-*`.
2. Emit `session.resumed` with `{epicOrSlug, fromPhase: N}`.
3. Load prior-phase state from `progress-log.json.phases[]`.
4. If resuming at P2 and `research.dispatched` exists without matching `research.completed`, re-dispatch per the crash-recovery rule (emit `research.redispatched`).
5. Jump to phase N's dispatcher preamble and continue through the remaining phases per the mode's sequence.

Resume is safest at phase boundaries. Mid-phase interruption can resume, but the user should expect some Phase-N work to be redone — the event log surfaces which iteration was last `spike.phase.N.iteration.M.started` so the orchestrator can skip forward.

---

## Power-user escape hatch (carryover from v2.0)

Framework defaults are **lean by design** (YAGNI; see `references/guardrails.md`). For genuine enterprise contexts where lean defaults are insufficient, **users can manually expand** `spike-plan.md`, freeze docs, and research docs without framework intervention. The framework does not prompt for these and does not require them.

**When this matters** (concrete examples — none are framework-prompted):

- HIPAA / PCI / regulated data context → user manually adds detailed threat model in §1 NFR.
- High-traffic system (1000+ RPS) → user adds SLO / SLI burn-rate alerts in §4 Observability.
- External API consumers → user adds backwards-compatibility policy + deprecation timeline in §5 API contracts.
- Multi-team coordination → user adds RACI / ownership matrix anywhere appropriate.

**How:** all artifacts are markdown files. User edits directly with any editor. `/spike --status` re-reads, and `/implement` consumes freeze docs as-is — BUT manual edits MUST happen before P6 approval (hash is computed at P6 and locked). Post-approval edits are blocked by hash mismatch; use `--revisit` instead.

If a class of escape-hatch usage becomes consistent across runs, that's evidence to promote it from "user manually adds" to "framework generates" in v3.1.

## Explicitly NOT Added (see spec §1 non-goals)

- **Auto-migration of v4 in-flight sessions.** Finish or abandon v4 work before upgrading.
- **Cross-epic dependencies** (one epic blocking on another).
- **Multi-repo spike** (single epic spanning multiple repos).
- **`/spike --autonomous` mode.** Spike's value is user check-in; autonomous spike is a contradiction. (Research-agent execution within P2 is dispatched async, but the parent spike is interactive.)
- **Research-only epic P7 retro mechanics.** No merge event ever; P7 deferred for those flows.
- **Tracker integration** (`gh issue create`, JIRA API, Linear API). `/spike` records user-supplied IDs only; keeps the skill stack-agnostic.

## Performance Budgets (advisory)

| Phase | Budget | Notes |
|---|---|---|
| P1 Scope | 5 min | Multi-feature Q&A in Epic mode; tighter in Story / Research. |
| P2 Investigate | 15 min (Story / Research) — varies for Epic | Architecture work + research agent dispatch latency. Research agents may run minutes to tens of minutes. |
| P3 Decompose | 10 min | Epic only; one-at-a-time loop scales with child count. |
| P4 Spec | 10 min | Per artifact; Epic-mode multiplies by child count. |
| P5 Review | 10 min | Multi-agent consensus + iteration. |
| P6 Approve | 5 min | User read + signoff per artifact. |
| P7 Retro | 5 min | Async; runs only when all children merged. |

Budgets are advisory, not gate-enforced.
