---
name: implement
version: 4.0.0
description: "Single-ticket Implementation workflow. Takes one well-defined ticket (spike-sourced or ad-hoc) and produces a rigorously-tested, reviewed, merged PR. Built on Managed Agents architecture (event log, stateless restart, phase YAML dispatcher, multi-brain fan-out). 7-phase pipeline (plus Phase 0 prereq check for spike-sourced tickets): Requirements \u2192 Research \u2192 Plan+Freeze \u2192 Test Planning \u2192 Implementation+Layer1 \u2192 Verification+Layer2 \u2192 Docs+PR. Multi-agent consensus reviews, freeze-doc-enforced research/execution boundary, two user approval gates (GATE 1 freeze, GATE 2 final). Use when the user wants to ship one ticket correctly. For multi-ticket research and decomposition, use /dev-framework:spike instead. Supports interactive (default) and autonomous (--autonomous TICKET) modes. Also trigger on: '/implement', 'ship this ticket', 'implement this feature', 'take this ticket and run with it', 'autonomous implementation', or any request for structured single-ticket development."
---

# `/implement` \u2014 Ticket Implementation Framework

You are orchestrating one rigorous, multi-agent development cycle for this user. This is the **only** workflow this plugin offers. Move slow, do it right. Reduce revisits and refactoring.

The plugin's purpose: AI leads development from initial requirement to deployment-ready change. The user answers questions, discusses, confirms at two gates, and completes. Every skill, protocol, and hook in this plugin exists to serve that single workflow.

## Invocation Modes

Parse `$ARGUMENTS`. Route to the first matching branch:

| Args match | Mode | Section |
|---|---|---|
| `--status` | Show session status and exit | see Status below |
| `--from N` (with TICKET or feature) | Resume at phase N | see Resume below |
| `--autonomous TICKET` or `-a TICKET` | Autonomous full cycle | Section B |
| `init` keyword, or no project files in cwd | Initialize project | Section A |
| `review` keyword | Standalone review | Section C |
| `test` keyword (or `coverage`) | Standalone test planning | Section D |
| `docs` keyword (or `documentation`) | Standalone docs maintenance | Section E |
| Feature description (any other non-empty) | Interactive full cycle | Section B |
| Empty args | Ask user which mode, then route | — |

## Pre-Workflow (runs for every mode)

Before entering any section, execute these steps in order:

1. **Ensure config** — `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/ensure-config.sh` (idempotent; creates `~/.claude/autodev/config.json` with defaults if absent). This is the single source of truth for the default config schema.
2. **Load session reference** — read `references/autonomous/session-management.md` into working context; you will need the session-folder algorithm and schemas.
3. **Resolve session folder** — follow the algorithm in `references/autonomous/session-management.md`. Result: `SESSION_DIR`.
4. **Chronic patterns** — already loaded by the SessionStart hook (`load-chronic-patterns.sh`). No action needed here unless resuming (see Resume handling).
5. **Emit `session.started`** — once mode/featureSlug/ticket are known (Section A/B/C/D/E entry), run:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh session.started \
     --actor orchestrator \
     --data "$(jq -cn --arg mode "$MODE" --arg fs "$FEATURE_SLUG" --arg t "$TICKET" \
       '{mode:$mode, featureSlug:$fs, ticket:$t} | with_entries(select(.value != ""))')"
   ```
   Use the empty-value filter so unset fields do not pollute the payload.
6. **Emit `config.snapshot.recorded` (M2.5+)** — capture effective config so view reducers can populate `progress-log.json.configSnapshot`:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh config.snapshot.recorded \
     --actor orchestrator \
     --data "$(jq -c '.pipeline | {maxReviewIterations, consecutiveZerosToExit, testCoverageTarget, modelProfile}' ~/.claude/autodev/config.json)"
   ```

The resolved `SESSION_DIR` path stays the same across invocations on the same repo+branch, so interactive and autonomous runs share state naturally.

## Companion References (read on demand)

Read these internal references into context when the current phase needs them. They are not external skills; invoke with your Read tool.

| Reference | When to read |
|---|---|
| `references/autonomous/session-management.md` | Always (Pre-Workflow step 2) |
| `references/autonomous/review-loop-protocol.md` | Phase 3 self-review, Phase 5 Layer 1 review, Phase 6 Layer 2 review |
| `references/autonomous/mistake-tracker-protocol.md` | Phase 7 mistake capture |
| `references/protocols/multi-agent-consensus.md` | Any phase that dispatches multiple review/plan agents |
| `references/protocols/project-docs.md` | Phase 7 docs update, Section A init, Section E |
| `references/protocols/test-planning.md` | Phase 4 |
| `references/methodology/DECISION_MAKING.md` | Issue validity judgement |
| `references/methodology/TESTING_STRATEGY.md` | Phase 4 |
| `references/methodology/DOCUMENTATION_STANDARDS.md` | Phase 7, Section E |
| `references/methodology/DEVELOPMENT_CYCLE.md` | Overview / refresher |
| `references/standards/*` | Phase 5 implementation, Phase 5/6 reviews |
| `references/templates/FREEZE_DOC_TEMPLATE.md` | Phase 3 assembly |
| `references/templates/ADR_TEMPLATE.md` | Phase 2 architecture |
| `references/templates/TEST_PLAN_TEMPLATE.md` | Phase 4 |
| `references/templates/FEATURE_SPEC_TEMPLATE.md` | Phase 1 |
| `references/templates/CODE_REVIEW_CHECKLIST.md` | Section C |

## Multi-Agent Consensus (the engine)

Every phase that runs parallel agents uses the protocol in `references/protocols/multi-agent-consensus.md`. Default parameters apply unless a phase overrides them:

- `agents: 3`
- `max_iterations: 10` (from `config.pipeline.maxReviewIterations`)
- `zero_threshold: 2` (from `config.pipeline.consecutiveZerosToExit`)

Never short-circuit the loop. Fixing issues without re-dispatching agents is NOT a zero-issue round (see the Critical Rule in the consensus protocol).

## Event Emissions (M1+)

Starting with M1 (Managed Agents Evolution), every orchestrator-level state transition dual-writes to `$SESSION_DIR/events.jsonl` via `emit-event.sh`. Hooks emit their own events independently. Full catalog and invariants: [`references/autonomous/events-schema.md`](./references/autonomous/events-schema.md).

**Emit command template:**

```
bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh <type> \
  --actor orchestrator \
  --data '<JSON object>'
```

**Orchestrator emit points** (each phase body below contains the exact command at the right location — this table is the summary):

| Point | Type | Data shape |
|---|---|---|
| Pre-Workflow complete | `session.started` | `{mode, featureSlug?, ticket?}` |
| Pre-Workflow (M2.5+) | `config.snapshot.recorded` | `{maxReviewIterations, consecutiveZerosToExit, testCoverageTarget, modelProfile}` |
| Phase 3 plan set (M2.5+) | `plan.files.set` | `{phase:3, plannedFiles:[...]}` |
| Phase 7 chronic promote/demote (M2.5+) | `patterns.promoted` / `patterns.demoted` | `{id, pattern, frequency?, reason?}` |
| Each Phase N begin (after begin gate) | `phase.started` | `{phase:N}` |
| Each Phase N end (before end gate) | `phase.completed` | `{phase:N, metrics?}` |
| GATE 1 approval | `gate.approved` | `{gate:1, approvalMode, approvedBy}` |
| GATE 1 rejection | `gate.rejected` | `{gate:1, reason, returnToPhase}` |
| GATE 2 approval | `gate.approved` | `{gate:2, approvalMode, approvedBy}` |
| GATE 2 rejection | `gate.rejected` | `{gate:2, reason, returnToPhase}` |
| Bypass requested | `bypass.created` | `{feature, reason, userMessage}` |
| Session completes (GATE 2 approved) | `session.completed` | `{totalMinutes}` |
| Phase fails | `phase.failed` | `{phase:N, error}` |
| `--from N` resume entry | `session.resumed` | `{fromPhase:N}` |
| Consensus iteration start | `consensus.iteration.started` | `{phase:N, iteration}` |
| Consensus converges | `consensus.converged` | `{phase:N, iterations, issuesFixed}` |
| Consensus forced stop (iteration cap) | `consensus.forced_stop` | `{phase:N, iterations, remainingIssues}` |
| Phase 0 prereq pass (spike-sourced, v4.0+) | `ticket.started` | `{epicId, ticketId, branch}` |
| Phase 5/6 ref-doc error found (v4.0+) | `ticket.discovery` | `{epicId, ticketId, section, correction}` |
| Phase 7 GATE 2 approval (spike-sourced, v4.0+) | `ticket.merged` | `{epicId, ticketId, prUrl?}` |

Emits are best-effort (exit 0 on no session). Never abort a phase on emit failure.

---

## Section A: Init Workflow

For new or uninitialized projects. **Apply the session collision guard from Section C before proceeding** — initializing a project while a full-cycle session is active would overwrite `docs/` scaffolding and session state.

1. Read `references/protocols/project-docs.md`. Verify/scaffold `docs/` structure (`adr/`, `specs/`, `test-plans/`, `decisions.md`).
2. Ask the user for: project name, language/framework, test runner, linter, performance budgets (or accept defaults from `references/standards/PERFORMANCE.md`), existing conventions.
3. Explore the project directory for existing files to auto-detect language/framework.
4. Create directory structure: `tests/` (or framework equivalent), `src/` (or equivalent).
5. Create CLAUDE.md with project-specific configuration referencing the generic standards from `references/standards/`.
6. Create ADR-001 (Project Setup) using `references/templates/ADR_TEMPLATE.md`.
7. Set up test configuration for the detected test runner.
8. Map generic standards to concrete implementations:
   - **Result pattern** — generate a language-specific Result type (read `references/standards/RESULT_PATTERN.md`).
   - **Test types** — map Unit/Integration/Smoke/E2E to the project's testing tools.
   - **Observability** — map to the project's logging/tracing libraries.
9. **Validate scaffolded output.** Read `references/protocols/multi-agent-consensus.md` and run the protocol with:
   - `task_type: validate`
   - `agents_list: [code-quality-reviewer, architect, requirements-analyst]`
   - Context: "Validate all scaffolded files against the actual codebase. Flag any aspirational documentation that contradicts the current code."
10. Confirm initialization complete. Tell the user: "Type `/implement [feature description]` to begin the full development cycle for your first feature."

---

## Section B: Full Development Cycle

**Prerequisite:** Pre-Workflow steps must have run. Read `references/protocols/project-docs.md` and verify `docs/` structure exists before Phase 1 (scaffold if missing).

**Phase 0 fork.** Before entering Phase 1, run the Phase 0 prereq check (see "Phase 0 — Prereq Check" below). If a spike ref doc is found at `docs/plan/*/{ticket}.md`, Phase 0 validates blockers, pre-seeds the freeze doc, and emits `ticket.started`. If no ref doc, Phase 0 is a no-op — set `epicId = "ad-hoc-<sanitized-branch>"` and proceed to Phase 1 with the existing flow.

### Mode Difference (Interactive vs Autonomous)

| Aspect | Interactive (default) | Autonomous (`--autonomous TICKET`) |
|---|---|---|
| Initial input | Feature description from user | JIRA ticket fetched/described |
| Phase 1-3 dialogue | User answers questions synchronously | LLM synthesizes best-guess answers, logs decisions to decision-log |
| GATE 1 (Phase 3 end) | User approves freeze doc | Freeze doc auto-APPROVED with `approvalMode: autonomous` audit |
| GATE 2 (Phase 7 end) | User approves final state | **Always user-interactive** (push is too consequential to automate) |
| freeze-gate hook | Active | Active |
| push-guard hook | Active | Active |

The phase structure and review loops are identical across modes. Only user interaction points differ.

### Session Initialization (both modes)

Before Phase 1:

1. Create `SESSION_DIR/progress-log.json` with:
   - `schemaVersion: 1`
   - `ticket` (autonomous) or `featureSlug` (interactive; derived from description)
   - `repo`, `branch`
   - `runId` (per `references/autonomous/session-management.md`)
   - `mode: "full-cycle"`
   - `approvalMode: "interactive" | "autonomous"`
   - `freezeDocPath: "docs/specs/[feature-slug]-freeze.md"` (set at Phase 3 completion; null initially)
   - `plannedFiles: []` (populated at Phase 3 completion)
   - `startedAt: <ISO-8601 UTC>`
   - `status: "in-progress"`
   - `configSnapshot: { maxReviewIterations, consecutiveZerosToExit, testCoverageTarget }`
   - `phases: []`
2. Create `SESSION_DIR/decision-log.json` (empty `decisions: []`).
3. Create `SESSION_DIR/pipeline-issues.json` (empty `runs: []`, append current runId).
4. Run `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh verify` — aborts if progress-log.json is broken.

### Decision Logging

After each consensus round or user decision, append to `SESSION_DIR/phase-{N}-decisions.jsonl` (one JSON object per line). At end of each phase, merge JSONL into `decision-log.json` and delete the JSONL. Also call `project-docs` (read the protocol reference) to append significant decisions to `docs/decisions.md`.

### Dispatcher Preamble (per phase, M3+)

Before running any phase body below, read `phases/phase-${N}.yaml` (M3+) and act on its metadata:

1. **Lazy-load refs:** For each entry in `requiredRefs[]`, read that file with the Read tool. Do not eager-load the entire Companion References table — phase YAMLs declare what's actually needed. This replaces the upfront reference table scan.
2. **Emit entry events:** Execute each emit in `emits.entry[]` via `emit-event.sh`.
3. **Run begin gates:** Run each script listed in `gates.begin[]` via `execute.sh hook`.
4. **Consult the narrative + checklist (M3b+):** Two sources, read together:
   - Phase YAML `instructions.*` — a machine-actionable checklist of steps (entry/main/exit + phase-specific keys). Use this as the step order.
   - Phase body below (anchored by `skillMdSection`) — the prose narrative explaining **why** each step matters, dialogue templates, and examples.
   YAML answers "what to do now"; SKILL.md answers "why and how to think about it."
5. **Invoke** per `invokes[]`:
   - `kind: hook` — `execute.sh hook <name>` runs to completion synchronously.
   - `kind: protocol` — `execute.sh protocol <name>` emits load event; you must Read the reference file separately.
   - `kind: skill` — `execute.sh skill <name>` emits started event and returns a dispatch payload; invoke the actual Skill tool, then call `execute.sh --complete skill <name> --output ...`.
   - `kind: agent` — same pattern as skill, but via the Task tool.
6. **Verify produces:** Before running end gates, verify each `produces[]` entry's artifact/section/marker exists.
7. **Run end gates** and **emit exit events** when the phase body concludes.

Full semantics: [`references/autonomous/dispatcher-spec.md`](./references/autonomous/dispatcher-spec.md). Phase YAML schema: [`../../phases/README.md`](../../phases/README.md).

If a phase YAML is missing (pre-M3 repos), fall back to this file's procedural prose as the single source of truth.

### Freeze Doc Draft

Start writing `docs/specs/[feature-slug]-freeze.md` during Phase 1. Open in DRAFT status. Each phase populates its assigned categories:
- **Phase 1** → §1 Business Logic, §5 Error Model, §6 Acceptance Criteria.
- **Phase 2** → §2 API Contracts, §3 3rd Party, §4 Data, §7 Security, §8 Performance.
- **Phase 3** → §9 Non-Frozen Questions (from config), final cross-category validation, bump status to `PENDING_APPROVAL`.

Use the template in `references/templates/FREEZE_DOC_TEMPLATE.md`. Category names and allow-list entries come from `config.pipeline.freezeDoc.categories` and `config.pipeline.freezeDoc.nonFrozenAllowList`.

**Custom category rendering:** after rendering the 8 required sections, iterate over any entries in `config.pipeline.freezeDoc.categories` that are not in the default 8. For each custom entry `X`, read the section template from `{config.pipeline.freezeDoc.customCategoryTemplatesDir}/{X}.md` and append it as an additional `§` section (numbered 10+). Also append the entry to the freeze doc frontmatter `customCategories` array. If the template file is missing, log a warning and fall back to a stub section `## § NN. {X} (TEMPLATE MISSING)` so the omission is visible during GATE 1.

### Phase 0 — Prereq Check (spike-sourced only)

Phase 0 runs **before** Phase 1 for spike-sourced tickets. It is diagnostic: no artifacts are produced, but the ref-doc context becomes available to downstream phases and the event log records that this ticket's implementation has started.

**Detect spike-sourced vs ad-hoc.** Resolve `TICKET` from invocation mode (autonomous: from `--autonomous TICKET`; interactive: if `$ARGUMENTS` is a bare ID rather than a free-form description). Search for a ticket ref doc:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
TICKET_REF=$(find "$REPO_ROOT/docs/plan" -maxdepth 2 -name "${TICKET}.md" 2>/dev/null | head -1)
```

- **Found** → spike-sourced, run Phase 0 body below.
- **Not found** → ad-hoc; set `epicId = "ad-hoc-<sanitized-branch>"`, skip Phase 0 body, proceed to Phase 1 with the existing flow.

**Phase 0 body (spike-sourced).**

1. **Resolve epic context.** Derive `epicId` from the ref-doc parent folder: `epicId=$(basename "$(dirname "$TICKET_REF")")`. Resolve the plan folder: `PLAN_DIR="$REPO_ROOT/docs/plan/$epicId"`. Verify `$PLAN_DIR/spike-plan.md` exists; if missing, halt with: "Ticket ref doc found at `$TICKET_REF` but `$PLAN_DIR/spike-plan.md` is missing — the epic's spike plan must accompany ticket refs."
2. **Read artifacts.** Read the full ticket ref doc into context. Read `$PLAN_DIR/spike-plan.md` §2 (architecture summary) and §7 (ticket registry) for cross-ticket blocker status.
3. **Validate `implBlockedBy`.** Parse ticket ref doc frontmatter `implBlockedBy` (array of `{ticketId, kind, reason}`). For each entry, resolve the target ticket's current status by scanning `events.jsonl` (`ticket.merged` for target ticketId implies `merged`; else check spike-plan §7 row which is the reducer-maintained view):
   - `kind: hard` AND target status ≠ `merged` → **Hard block.** Exit the workflow with a message listing every unmet hard blocker, its reason, and current target status. Emit `phase.failed --data '{"phase":0,"error":"hard blocker(s) unmet"}'`. Do **not** emit `ticket.started`.
   - `kind: soft` AND target status ≠ `merged` → **Warn.** Print "⚠️  soft blocker [{ticketId}] not yet merged — reason: {reason}. Proceeding, but reviewer should confirm this is intentional at GATE 1." Continue.
   - Blocker merged → silent pass.
4. **Print three sections to the user** (always, even on proceed):
   ```
   ━━━ Big Picture ━━━
   {spike-plan §2 architecture summary, verbatim or condensed}

   ━━━ This Ticket's Role ━━━
   {ticket ref doc §2 "Scope" / role-in-epic prose}

   ━━━ Prereq Check ━━━
   {either:}
     ✅ Proceeding. All hard blockers merged. Soft warnings (if any) listed above.
   {or (on hard block, as terminal output):}
     🛑 Blocked. Cannot proceed until the following tickets merge:
        - [{blockerId}] {reason}
        ...
     Re-run /implement after the blocking ticket(s) are merged.
   ```
5. **Pre-populate freeze doc §1–§5 from the ticket ref doc.** Spike-sourced tickets inherit most decisions from the parent spike. Read the ticket ref doc sections and seed the freeze doc at `docs/specs/{feature-slug}-freeze.md` with:
   - §1 Business Logic ← ticket ref doc §2 (Scope) + §3 (Behavior)
   - §2 API Contracts ← ticket ref doc §4 (Contracts inherited from spike)
   - §3 3rd Party ← ticket ref doc §4 (external deps subset)
   - §4 Data ← ticket ref doc §4 (schema/migration references)
   - §5 Error Model ← ticket ref doc §5 (error taxonomy)

   Leave §6–§9 for Phase 1–3 to populate normally. Mark each pre-populated section header with an inline `<!-- seeded from spike plan, refine during Phase 1-3 -->` comment so GATE 1 reviewers know to verify. The human review at GATE 1 still binds — pre-population only reduces typing, not accountability.
6. **Emit `ticket.started`.**
   ```bash
   BRANCH=$(git rev-parse --abbrev-ref HEAD)
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh ticket.started \
     --actor orchestrator \
     --data "$(jq -cn --arg e "$epicId" --arg t "$TICKET" --arg b "$BRANCH" \
       '{epicId:$e, ticketId:$t, branch:$b}')"
   ```
   The `reduce-spike-plan.sh` reducer will flip the ticket's §7 row status to `in-impl` on the next `regenerate-views.sh` pass; `reduce-ticket-doc.sh` updates the ticket doc frontmatter `.status` accordingly.
7. **Banner:** `--- Phase 0 Complete: Prereq Check --- Epic: {epicId} | Ticket: {ticketId} | Blockers: {all clear | N soft warnings} ---`

**No gate hooks for Phase 0** — it is a diagnostic phase, not gated by `phase-gate.sh` (which validates the progress-log schema for phases 1-7 only). The hard-block exit path above is the only failure mode.

**Modified Phase 1-3 when spike-sourced.** Requirements → Research → Plan phases still execute their consensus loops and self-review, but the freeze doc's §1-§5 arrive pre-seeded (step 5 above). Treat the seeded content as a **strong prior**, not frozen truth: if consensus finds a gap, update the section and emit a `ticket.discovery` event (see below). If no gaps, the phases fast-forward. Ad-hoc tickets (no ref doc) run full Phase 1-3 from scratch as before.

### Phase 1 — Requirements

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 1`
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.started --actor orchestrator --data '{"phase":1}'`

Mode-sensitive:
- **Interactive:** gather requirements via one-at-a-time questions. Use clarifying dialogue until scope is understood. Invoke the skill named by `config.pipeline.skills.requirements` (default `superpowers:brainstorming`) via the Skill tool.
- **Autonomous:** read the ticket content. Extract requirements, acceptance criteria, and constraints. Log any assumptions to `decision-log.json` category `autonomous-inference`.

After gathering (both modes), run the consensus protocol (`references/protocols/multi-agent-consensus.md`):
- `task_type: validate`
- `agents_list: config.pipeline.agents.plan` (default `[requirements-analyst, architect, test-strategist]`)
- Context: "Validate that requirements are complete, unambiguous, and testable."

Produce/update `docs/specs/[feature-slug]-requirements.md`. Populate freeze doc §1, §5, §6.

**Update:** `progress-log.json` (append phase entry with status `completed`, `completedAt`, metrics).
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.completed --actor orchestrator --data '{"phase":1}'`
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 1`
**Banner:** `--- Phase 1 Complete: Requirements ---`

### Phase 2 — Research (Codebase + Architecture)

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 2`
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.started --actor orchestrator --data '{"phase":2}'`

1. Invoke the skill named by `config.pipeline.skills.exploration` (default `feature-dev:code-explorer`). Trace execution paths related to the feature area, map architecture layers, document dependencies and integration points, identify conventions the new code must follow.
2. Invoke the skill named by `config.pipeline.skills.architect` (default `feature-dev:code-architect`). Design the feature architecture based on exploration findings.
3. Run the consensus protocol (`references/protocols/multi-agent-consensus.md`):
   - `task_type: plan`
   - `agents_list: config.pipeline.agents.plan`
   - Context: "Validate architecture design against requirements and existing codebase conventions."
4. Produce ADR(s) using `references/templates/ADR_TEMPLATE.md`. Write to `docs/adr/ADR-NNN-[title].md`.
5. **Populate freeze doc §2–§4, §7, §8:**
   - **§2 API Contracts:** observed conventions → "Conventions Followed"; new endpoints with concrete schemas; any deviation from existing patterns goes in "Proposed Deviations" with rationale.
   - **§3 3rd Party:** every external API — payload shape, rate limit, retry policy, cache TTL, secret storage.
   - **§4 Data & Database:** schema changes (DDL), enums with values/defaults, forward and rollback migration, backfill plan.
   - **§7 Security/Auth:** authZ model, sensitive data rules, identified threats and mitigations.
   - **§8 Performance:** measurable budgets (p95/p99 latency, throughput, query count, memory).

**Update:** progress-log.json.
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.completed --actor orchestrator --data '{"phase":2}'`
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 2`
**Banner:** `--- Phase 2 Complete: Research ---`

### Phase 3 — Plan + Freeze Doc Assembly → GATE 1

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 3`
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.started --actor orchestrator --data '{"phase":3}'`

1. Read `references/autonomous/review-loop-protocol.md` into context.
2. Invoke the skill named by `config.pipeline.skills.planning` (default `superpowers:writing-plans`). Generate a structured implementation plan with bite-sized tasks.
3. Populate freeze doc §9 from `config.pipeline.freezeDoc.nonFrozenAllowList`.
4. Run consensus protocol:
   - `task_type: plan`
   - `agents_list: config.pipeline.agents.plan`
   - Context: "Verify that the plan covers all acceptance criteria, aligns with frozen architecture, and is testable."
5. **Self-review loop** (per review-loop-protocol.md) — run in self-review mode over the plan and freeze doc. Fix any issues. Inject chronic patterns as prevention checklist.
6. Populate `progress-log.json`:
   - `freezeDocPath: "docs/specs/[feature-slug]-freeze.md"`
   - `plannedFiles: [...]` (from the plan)
   - `featureSlug: "[feature-slug]"`
7. **Emit `plan.files.set` (M2.5+)** — records the planned files into the event log so view reducers can populate `progress-log.json.plannedFiles`:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh plan.files.set \
     --actor orchestrator \
     --data "$(jq -cn --argjson files "$PLANNED_FILES_JSON" '{phase:3, plannedFiles:$files}')"
   ```
   where `$PLANNED_FILES_JSON` is the JSON array of planned file paths from the implementation plan.
8. Bump freeze doc `status: PENDING_APPROVAL`, record `createdAt` in frontmatter.

**GATE 1 — Freeze Doc Approval** (mode-sensitive):

**Interactive mode:**
Present the complete freeze doc to the user with a category-by-category summary. Prompt for one of:
- `[1] Approve all` — proceed.
- `[2] Reject category X` — reopen that category (return to Phase 1 for §1/§5/§6 or Phase 2 for §2/§3/§4/§7/§8) and re-run the relevant review loops on return.
- `[3] Inline edit` — modify specific items, then present again.

On approval:
- Set freeze doc frontmatter: `status: APPROVED`, `approvedAt: <ISO UTC>`, `approvedBy: <user email or identifier>`, `approvalMode: interactive`.
- Append decision to `decision-log.json` category `gate-1`.
- **Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh gate.approved --actor orchestrator --data "$(jq -cn --arg am interactive --arg by "$APPROVED_BY" '{gate:1, approvalMode:$am, approvedBy:$by}')"`

On rejection (category X reopened):
- **Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh gate.rejected --actor orchestrator --data "$(jq -cn --arg reason "$REASON" --argjson rp "$RETURN_PHASE" '{gate:1, reason:$reason, returnToPhase:$rp}')"`

**Autonomous mode:**
- Set freeze doc frontmatter: `status: APPROVED`, `approvedAt: <ISO UTC>`, `approvedBy: "autonomous"`, `approvalMode: autonomous`.
- Append audit decision to `decision-log.json` explaining the autonomous approval and listing any uncertainty flagged during Phase 1-3.
- **Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh gate.approved --actor orchestrator --data '{"gate":1,"approvalMode":"autonomous","approvedBy":"autonomous"}'`
- Continue to Phase 4.

**Update:** progress-log.json (phase 3 complete with review metrics — iterations, issues fixed, final issue count).
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.completed --actor orchestrator --data '{"phase":3}'`
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 3`
**Banner:** `--- Phase 3 Complete: Plan + Freeze Doc --- GATE 1: {mode}-approved | Iterations: {N} | Issues fixed: {M} ---`

After this point, **the freeze-gate hook is active**: any attempt to edit `src/`, `lib/`, or `app/` files (excluding tests) will be blocked unless the freeze doc is `APPROVED` and the current branch matches the session.

### Phase 4 — Test Planning

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 4`
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.started --actor orchestrator --data '{"phase":4}'`

1. Invoke the skill named by `config.pipeline.skills.tdd` (default `superpowers:test-driven-development`) to establish TDD methodology.
2. Read `references/protocols/test-planning.md` into context. Apply it using inputs from Phase 1-3 artifacts in `SESSION_DIR`.
3. Read `references/methodology/TESTING_STRATEGY.md` for coverage requirements.
4. Produce layered test plan (Layer 0 data pipeline, Layer 1 cross-validation, Layer 2 per-feature by event type) using `references/templates/TEST_PLAN_TEMPLATE.md` and the layout in the test-planning protocol.
5. Coverage target: `config.pipeline.testCoverageTarget` (default 90) percent branch coverage.
6. Map tests to acceptance criteria (traceability matrix).
7. Write to `SESSION_DIR/tdd-plan.md` and `docs/test-plans/[feature-slug]-test-plan.md`.

**Update:** progress-log.json.
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.completed --actor orchestrator --data '{"phase":4}'`
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 4`
**Banner:** `--- Phase 4 Complete: Test Planning ---`

### Phase 5 — Implementation + Layer 1 Review

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 5`
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.started --actor orchestrator --data '{"phase":5}'`

**Execution rules (ALL of Phase 4-7):**
- Freeze doc §1-§8 are immutable truth source. Any question that would change them triggers **workflow halt** and a "freeze doc update needed" message to the user.
- Zone 2 (Non-Frozen list, freeze doc §9) questions may be asked to the user.
- Zone 3 (Ambiguous) questions follow the 4-tier rule in freeze doc §9: existing code → follow silently (ask on deviation); reference repo → same; initial implementation → ask liberally; otherwise → self-decide via standards.
- Zone 4 (pure technical: naming, extraction, internal boundaries) → self-decide without asking.
- Use the "Ask with Suggestion" format (freeze doc §9) when asking.
- **Ticket discovery.** If during Phase 5 or 6 you find an error in the **parent ticket ref doc or spike plan** (not the freeze doc) — e.g., a contract declared in `spike-plan.md` §3 is wrong, a blocker was missed, a data-migration step was omitted — emit a `ticket.discovery` event. The event is consumed by `/spike` Phase 5 (retro) to propose corrections. Do NOT edit the spike plan mid-implementation; the spike owns its plan. Emit command:
  ```bash
  bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh ticket.discovery \
    --actor orchestrator \
    --data "$(jq -cn --arg e "$epicId" --arg t "$TICKET" --arg s "$SECTION" --arg c "$CORRECTION" \
      '{epicId:$e, ticketId:$t, section:$s, correction:$c}')"
  ```
  where `$SECTION` is a spike-plan or ref-doc section reference (e.g., `"spike-plan §3"`) and `$CORRECTION` is a one-sentence description of what should be changed. Phase 7 GATE 2 summarizes all discoveries before final approval so the user knows the spike plan needs follow-up.

**Implementation:**
1. Invoke the default implementation skill: `config.pipeline.skills.implementation` (default `superpowers:subagent-driven-development`). Alternative skills:
   - Sequential plan execution: `config.pipeline.skills.implementationSequential`.
   - Parallel independent subtasks: `config.pipeline.skills.implementationParallel`.
   Choose based on plan structure.
2. Reference `SESSION_DIR/tdd-plan.md` for test strategy. Follow TDD: write failing test → implement minimum to pass → refactor.
3. On any bug or unexpected failure, invoke `config.pipeline.skills.debugging` (default `superpowers:systematic-debugging`) before attempting fixes. Root cause first.

> **Observability note — Agent-dispatched edits:** when implementation runs via the Agent tool (subagent-driven or parallel-agent modes), `Edit`/`Write` tool calls made by sub-agents fire `freeze-gate.sh` inside the sub-agent's sandboxed context. The hook's exit-2 block messages surface back only as a generic "tool call failed" signal to the orchestrator, not as a structured gate diagnostic. If an Agent tool reports an edit failure in `src/**`, inspect `SESSION_DIR/bypass.json` and the freeze doc status directly (or run `/implement --status`) before assuming a code error — the failure may be a legitimate gate block.

**Layer 1 Review (mandatory):**

Read `references/autonomous/review-loop-protocol.md`. Run the protocol over the implemented code:

1. Invoke `config.pipeline.skills.requestReview` (default `superpowers:requesting-code-review`) to prepare the review request.
2. Run consensus protocol (`references/protocols/multi-agent-consensus.md`):
   - `task_type: validate`
   - `agents_list: config.pipeline.agents.review` (default `[code-quality-reviewer, performance-reviewer, observability-reviewer]`)
   - `max_iterations: config.pipeline.maxReviewIterations` (default 10)
   - `zero_threshold: config.pipeline.consecutiveZerosToExit` (default 2)
3. Invoke `config.pipeline.skills.receiveReview` (default `superpowers:receiving-code-review`) — evaluate findings rigorously; no performative agreement; reasoned pushback on invalid findings (per `references/methodology/DECISION_MAKING.md`).
4. Fix valid issues, re-dispatch for verification. Do NOT declare convergence without re-validation (see Critical Rule in consensus protocol).
5. If not converged within `max_iterations`, escalate remaining issues to the user.

Log decisions, persist issues to `pipeline-issues.json`, merge `phase-5-decisions.jsonl`, update markdown.

**Update:** progress-log.json with review metrics.
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.completed --actor orchestrator --data "$(jq -cn --argjson r "$ROUNDS" --argjson f "$FIXED" '{phase:5, metrics:{rounds:$r, issuesFixed:$f}}')"`
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 5`
**Banner:** `--- Phase 5 Complete: Implementation --- Rounds: {N} | Issues fixed: {M} ---`

### Phase 6 — Verification + Coverage Fill + Layer 2 Review

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 6`
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.started --actor orchestrator --data '{"phase":6}'`

1. Run all tests (unit, integration, smoke, E2E). All must pass.
2. Measure branch coverage. Compare against `config.pipeline.testCoverageTarget`.
3. If below target: use `config.pipeline.skills.tdd` to write additional tests targeting uncovered branches (RED-GREEN-REFACTOR cycle). Re-run all tests, verify green.
4. Invoke `config.pipeline.skills.verification` (default `superpowers:verification-before-completion`) — confirm each acceptance criterion with evidence before continuing.
5. **Layer 2 Review** (same mechanics as Layer 1):
   - Read `references/autonomous/review-loop-protocol.md`.
   - Run consensus protocol with `agents.review`, `max_iterations: config.pipeline.maxReviewIterations` (default 10), `zero_threshold: config.pipeline.consecutiveZerosToExit` (default 2).
   - Context: final validation — integration-level consistency, test-to-requirement traceability, performance budget adherence, standards compliance.
   - Invoke `config.pipeline.skills.receiveReview` to evaluate rigorously.
6. Fix valid issues, re-validate. If not converged, escalate to user.
7. Verify frozen-category integrity: scan code + tests for any decision that drifted from freeze doc §1-§8. If drift detected, halt and offer [1] update freeze doc via supersede, [2] revert to freeze doc, [3] bypass.

Log decisions, persist issues, merge JSONL, update markdown.

**Update:** progress-log.json with review metrics.
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.completed --actor orchestrator --data "$(jq -cn --argjson c "$COVERAGE" --argjson r "$ROUNDS" --argjson f "$FIXED" '{phase:6, metrics:{coverage:$c, rounds:$r, issuesFixed:$f}}')"`
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 6`
**Banner:** `--- Phase 6 Complete: Verification --- Coverage: {N}% | Rounds: {M} | Issues fixed: {K} ---`

### Phase 7 — Documentation + Mistake Capture → GATE 2

**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin 7`
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.started --actor orchestrator --data '{"phase":7}'`

**Documentation:**
1. Read `references/protocols/project-docs.md`.
2. Update/create ADRs for any Phase 5-6 decisions that deviated from Phase 2 (supersede the prior ADR per the ADR lifecycle in `references/methodology/DECISION_MAKING.md`).
3. Update `docs/specs/[feature-slug]-requirements.md` to reflect final implementation.
4. Update `docs/test-plans/[feature-slug]-test-plan.md` with actual coverage numbers and test inventory.
5. Append freeze doc as a permanent record; do not delete.
6. Scope boundary: Phase 7 only **documents** what was built. It does not introduce features, refactor code, or change behavior. Implementation gaps become follow-up tasks.

**Mistake Capture:**
7. Read `references/autonomous/mistake-tracker-protocol.md`.
8. Follow the protocol:
   - Check idempotency via Run Log; if runId already aggregated, skip.
   - Aggregate Phase 5 + Phase 6 code issues (not Phase 3 design issues).
   - Match against existing patterns; increment frequency or create new patterns.
   - Promote at frequency ≥ `config.pipeline.chronicPromotionThreshold` (default 3) — write prevention strategy.
   - Enforce hard cap `config.pipeline.maxActivePatterns` (default 20).
   - Sync CLAUDE.md chronic patterns between sentinel markers (atomic write with backup).
   - Append runId to Run Log.
   - Log pattern promotions/demotions to `decision-log.json` category `pattern`.

**GATE 2 — Final Approval** (always user-interactive, both modes):

**If spike-sourced:** before presenting the approval summary, query `events.jsonl` for any `ticket.discovery` events emitted during this run and, if any exist, print:
```
━━━ Spike Plan Corrections Discovered ━━━
The following ref-doc / spike-plan errors were found during implementation:
  - [{section}] {correction}
  ...
These events are logged and will be addressed by /spike --retro EPIC-ID after this ticket merges.
```
Discovery events do NOT block GATE 2. They are informational only; the spike's retro phase is the correct channel for plan edits.

Present:

```
Feature: [feature-slug] — Final Approval
────────────────────────────────────────────────────────
Tests:        {passed}/{total} passed
Coverage:     {N}% branch (target: {target}%)
Code Review:
  Layer 1 (Phase 5): {agents} agents, {rounds} rounds, {issues} issues fixed
  Layer 2 (Phase 6): {agents} agents, {rounds} rounds, {issues} issues fixed
  Remaining:    {N} issues (must be 0 to approve [1] or [3])
Standards:    {pass/fail summary}
Docs updated: {list}
Files changed: {N} ({src}/{tests})
Frozen decisions honored: {N}/{N}
Bypasses used: {N}
Chronic patterns prevented: {N}
Duration: {minutes}
────────────────────────────────────────────────────────
Options:
  [1] Approve → archive session, allow push
  [2] Reject → list issues to fix (returns to Phase 5 or 6 per user choice)
  [3] Approve + commit + push
```

On approval (option 1 or 3), execute this sequence in order. **If any step fails, halt and report the specific error to the user — do NOT proceed to later steps. Log the failure to `decision-log.json` category `gate-2` with `failed: true` and the error details so the session is resumable via `--from 7`.** The entire archival + cleanup sequence is idempotent (dedup by `at` and filter by `runId`), so a resumed Phase 7 safely re-runs any completed portion.

**Note on `ticket.merged` emission** (step 6 below, after `gate.approved`): emitted once per GATE 2 approval. Consumed by `reduce-spike-plan.sh` to flip the ticket's §7 row to `merged`, and by any `/spike --retro EPIC-ID` auto-trigger logic checking whether all tickets of an epic are merged. Emit for both options [1] (approve) and [3] (approve + push); the event is independent of whether the PR is actually pushed in this run — a human may push later.

1. **Bypass archival — GATE 2 is the sole writer of freeze doc `bypassHistory`.** Collect bypass records from both sources, normalizing each to the `bypassHistory` entry schema `{ at, reason, feature, userMessage, runId, preservedAt? }`:
   - `bypass.json` (current live bypass, if any). **Field mapping:** use `bypass.json.createdAt` as the `at` value; inject `runId` from `progress-log.json` (bypass.json does not carry runId); `preservedAt` is absent (this is the direct-from-bypass path, not the crash-preservation path).
   - `bypass-audit.jsonl` (preserved by `sessionend.sh` on prior crash/interrupt within this run). These already use `at` and carry `runId` and `preservedAt` written by sessionend.
   For each normalized record, dedup by `at` against existing `bypassHistory` entries. Filter `bypass-audit.jsonl` entries by `runId` matching the current `runId` in `progress-log.json` before merging — entries from prior runs on the same branch must not be imported. **If the freeze doc is unwritable (read-only, lock contention, missing parent directory), halt per the failure rule above.**

2. **Bypass cleanup:** after archival succeeds, delete `SESSION_DIR/bypass.json`. Do not delete `bypass-audit.jsonl` — it is preserved for cross-run audit. The bypass lifecycle ends here.

3. **Write completion marker:** write `SESSION_DIR/pipeline-complete.md` containing exactly:
   ```
   Pipeline completed for branch: {original unsanitized branch name}
   Date: {ISO UTC}
   Feature: {feature-slug}
   ```
   This marker authorizes `push-guard.sh` to allow `git push` on this branch. It is written **after** archival and cleanup so the marker only exists in a fully-consistent state.

4. **Finalize progress log:** set `progress-log.json` `status: "completed"`, `completedAt: <ISO UTC>`, final `currentPhase: 7`, and summary totals.

5. **On option 3:** invoke `config.pipeline.skills.finishing` (default `superpowers:finishing-a-development-branch`) — stage, commit, push.

6. **Emit GATE 2 approval, ticket merge (spike-sourced only), and session completion events:**
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh gate.approved \
     --actor orchestrator \
     --data "$(jq -cn --arg am "$APPROVAL_MODE" --arg by "$APPROVED_BY" \
       '{gate:2, approvalMode:$am, approvedBy:$by}')"

   # ticket.merged — only when Phase 0 found a spike ref doc (epicId != "ad-hoc-*").
   # Option [3] may include $PR_URL from the finishing skill; option [1] emits without prUrl.
   if [[ "$epicId" != ad-hoc-* ]]; then
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
- User indicates which phase to return to; set `progress-log.json` `status: "in-progress"`, reset `currentPhase` accordingly.
- **Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh gate.rejected --actor orchestrator --data "$(jq -cn --arg reason "$REASON" --argjson rp "$RETURN_PHASE" '{gate:2, reason:$reason, returnToPhase:$rp}')"`
- Re-enter that phase.

**Update:** progress-log.json.
**Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.completed --actor orchestrator --data '{"phase":7}'`
**Gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end 7`
**Banner:** `--- Phase 7 Complete: Documentation + Capture --- GATE 2: approved | Total: {minutes}min | Decisions: {N} ---`

---

## Section C: Standalone Review

Runs without a full cycle. Use when the user says `review`.

**Session collision guard (applies to Sections A, C, D, E):** Before creating or writing any session state, if `SESSION_DIR/progress-log.json` already exists, read it. If its `mode` is `full-cycle` and `status` is `in-progress`, `interrupted`, or `failed`, **halt** and present the user with:
```
⚠️  A full-cycle /implement session exists on this branch ({featureSlug}, Phase {N}, status={status}).
Running standalone '{init|review|test|docs}' here will overwrite the full-cycle session state,
making it unresumable. If status is 'failed' or 'interrupted', resume via /implement --from {N} instead.
  [1] Abort this standalone run
  [2] Overwrite and proceed (full-cycle state will be lost)
  [3] Switch branch before continuing
```
Do not proceed without explicit confirmation.

1. Read `references/protocols/multi-agent-consensus.md` and `references/methodology/DECISION_MAKING.md`.
2. Create `SESSION_DIR/progress-log.json` with `mode: "review"` so the freeze-gate hook knows this is not a full cycle.
3. Run consensus protocol:
   - `task_type: validate`
   - `agents_list: config.pipeline.agents.review`
   - `max_iterations: config.pipeline.maxReviewIterations` (default 10)
   - `zero_threshold: config.pipeline.consecutiveZerosToExit` (default 2)
4. Each agent reads the relevant standards from `references/standards/`.
5. Produce a review report using `references/templates/CODE_REVIEW_CHECKLIST.md`, with findings, severity, and recommended fixes.
6. Set `progress-log.json` `status: "completed"`, `completedAt: <ISO UTC>`.

---

## Section D: Standalone Test Planning

Use when the user says `test` or `coverage`. Apply the session collision guard from Section C before proceeding.

1. Create `SESSION_DIR/progress-log.json` with `mode: "test"`.
2. Read `references/methodology/TESTING_STRATEGY.md` and `references/protocols/test-planning.md`.
3. Analyze the codebase for test coverage gaps.
4. Design or update the test plan ensuring all 4 test types are represented.
5. Verify branch coverage target (`config.pipeline.testCoverageTarget`, default 90%).
6. Run consensus protocol with `agents.plan`.
7. Produce `docs/test-plans/[feature-or-scope]-test-plan.md` using `references/templates/TEST_PLAN_TEMPLATE.md`.
8. Mark session completed.

---

## Section E: Standalone Documentation

Use when the user says `docs` or `documentation`. Apply the session collision guard from Section C before proceeding.

1. Create `SESSION_DIR/progress-log.json` with `mode: "docs"`.
2. Read `references/methodology/DOCUMENTATION_STANDARDS.md` and `references/protocols/project-docs.md`.
3. Run the doc hygiene analysis per `project-docs.md` (stale/redundancy/bloat/accuracy/organization).
4. Update ADRs, specs, test plans. Ensure `docs/` is current.
5. Verify all ADRs follow `references/templates/ADR_TEMPLATE.md`.
6. Mark session completed.

---

## `--status` Handler

1. Resolve `SESSION_DIR`.
2. Read `progress-log.json`, `decision-log.json`. Also read the freeze doc (if `freezeDocPath` is set) and check for `bypass.json` and `pipeline-complete.md`.
3. Output a comprehensive summary for quick diagnosis:
   - Ticket/feature, mode, status, current phase.
   - **If status is `interrupted`:** highlight `interruptedAt` timestamp prominently and include an actionable note: "Session ended mid-run. Use `/implement --from {currentPhase}` to resume. Phase {currentPhase} may be partially complete — review `phase-{N}-decisions.jsonl` if present."
   - Per-phase timing, metrics, decisions count.
   - Last 5 decisions.
   - Config snapshot.
   - **Freeze doc:** path + `status` field (DRAFT / PENDING_APPROVAL / APPROVED / SUPERSEDED) + approvedAt/approvedBy + `approvalMode`.
   - **Bypass:** active yes/no; if yes, show `feature`, `reason`, `createdAt`, `userMessage` from `bypass.json`. Also show count of entries in `bypass-audit.jsonl` and the count in freeze doc `bypassHistory` (if freeze doc exists). If `bypass-audit.jsonl count > bypassHistory count`, annotate with "(N pending merge at GATE 2)" so the operator can distinguish archived vs pending records.
   - **Push-guard state:** `pipeline-complete.md` present yes/no; if no, explain blocking reason (GATE 2 pending vs mid-pipeline vs interrupted).
   - **Session folder:** absolute path so the operator can inspect raw artifacts directly.
   - **freeze-gate state:** whether src/** edits are currently allowed (based on freeze doc status + branch + mode).
4. Exit — do not run the workflow.

## `--from N` Resume

1. Resolve `SESSION_DIR`. Verify it exists.
2. Read `progress-log.json`. Verify the feature/ticket matches.
3. Follow the resume protocol in `references/autonomous/session-management.md`:
   - Detect mid-phase crash (last phase status `in-progress`).
   - Merge any stale `phase-{N}-decisions.jsonl`.
   - Announce caveat: "Resuming from Phase {N}. Phases 1-{N-1} artifacts assumed valid."
4. If the session was interactive and the user is re-entering at Phase 4+ without the freeze doc in APPROVED state → halt and advise completing Phase 3.
5. **Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh session.resumed --actor orchestrator --data "$(jq -cn --argjson p "$PHASE" '{fromPhase:$p}')"`
6. Run the phase begin gate, then continue at Phase N.

---

## Phase Failure Protocol

When a phase fails:

1. Invoke `config.pipeline.skills.debugging` (default `superpowers:systematic-debugging`). Gather evidence, form hypothesis, test minimally. No guessing.
2. Update `progress-log.json`: phase status `failed`.
3. Persist accumulated issues to `pipeline-issues.json`.
4. Log failure as decision (category: `skip`).
5. **Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh phase.failed --actor orchestrator --data "$(jq -cn --argjson p "$PHASE" --arg err "$ERROR" '{phase:$p, error:$err}')"`
6. Announce:
   ```
   --- Phase {N} FAILED: {phase name} ---
   Error: {description}
   Session: {SESSION_DIR}
   Resume: /implement --from {N} [--autonomous TICKET]
   ```
7. Offer: `[1] Retry this phase` `[2] Skip to next` `[3] Abort workflow`.

**Graceful degradation:** missing config → `ensure-config.sh` creates it (Pre-Workflow step 1). Missing chronic patterns file → empty list. Unavailable configured skill → phase operates without it. The workflow must never fail to start.

## Gate Failure Protocol

When a phase gate blocks (`phase-gate.sh` exit 2), it's a prerequisite violation, not a bug. Do **not** invoke the debugging skill.

1. Read the gate error message — it explains exactly what is wrong.
2. Announce:
   ```
   --- Phase {N} GATE BLOCKED: {gate error summary} ---
   Session: {SESSION_DIR}
   ```
3. Offer, based on gate type:
   - Begin gate (missing progress): `[1] Run Pre-Workflow` `[2] Use --from N` `[3] Abort`.
   - Begin gate (previous phase incomplete): `[1] Complete Phase N-1` `[2] Use --from N to skip` `[3] Abort`.
   - End gate (progress not updated): `[1] Update progress-log.json and retry` `[2] Abort`.
   - Verify gate (session broken): `[1] Delete session folder and restart` `[2] Abort`.

## Bypass Protocol (freeze-gate override)

If the user explicitly asks to bypass the freeze gate (trigger phrases: "bypass freeze", "freeze 무시하고 진행", "freeze 우회", or an explicit sentence with clear intent):

1. Write `SESSION_DIR/bypass.json`:
   ```json
   {
     "createdAt": "<ISO UTC>-<4 hex chars>",
     "reason": "<extracted from user message>",
     "feature": "<progress-log.featureSlug>",
     "scope": "ticket",
     "userMessage": "<verbatim user request>"
   }
   ```
   The 4-hex-char suffix makes `createdAt` a unique event identifier even when multiple bypasses occur within the same second (e.g., `2026-04-19T14:30:00Z-a3f2`). All downstream consumers (`sessionend.sh` dedup, GATE 2 dedup, freeze doc `bypassHistory.at`) use this as the join key; collisions would silently drop audit events.
2. Announce the bypass clearly, including the reason.
3. Log a decision to `decision-log.json` category `bypass` with full fields (reason, feature, at, userMessage, runId) — so the bypass event can be correlated to its run from the decision log alone.
4. **Emit:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/emit-event.sh bypass.created --actor orchestrator --data "$(jq -cn --arg f "$FEATURE" --arg r "$REASON" --arg m "$USER_MESSAGE" '{feature:$f, reason:$r, userMessage:$m}')"`
5. Continue work. The bypass remains active for this ticket; Phase 7 GATE 2 is the **sole** writer of freeze doc `bypassHistory` — it merges `bypass.json` + any `bypass-audit.jsonl` entries into `bypassHistory` with dedup. Do not write to `bypassHistory` here (double-write would corrupt the audit trail).

The `freeze-gate.sh` hook reads `bypass.json` and respects it. Do not attempt to silence the hook by any other means.

---

## Cross-Cutting Concerns

### Phase Gates (Mandatory)

Every phase in Section B is bookended by gate calls that enforce progress-map integrity:

- **Begin gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh begin N` — validates progress-log.json exists, previous phase completed, workflow not already finished.
- **End gate:** `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/phase-gate.sh end N` — validates current phase status is `completed`, `completedAt` is set, and progress-log.json is consistent.
- **PostToolUse hook:** after each gate call, `phase-progress-validator.sh` runs automatically (registered in `hooks.json`) to independently validate progress-map consistency.
- **Blocking behavior:** gate scripts exit 2 on validation failure, halting the workflow. The validator hook emits warnings only (exit 0).
- **Execution order:** begin gate BEFORE any phase work. Update progress-log.json DURING the phase. End gate AFTER the update, BEFORE the banner.

### Progress Banners

One-line banner at each phase transition. Include key metrics when available.

### Decision Logging

Per-iteration: append to `SESSION_DIR/phase-{N}-decisions.jsonl` (one JSON line per decision).
At phase end: merge JSONL into `decision-log.json`, delete the JSONL.

### Progress Updates

At phase end: update `progress-log.json` with phase timing, metrics, and decision references.

### Markdown Regeneration

At phase end (not per-iteration): regenerate `decision-log.md` and `progress-log.md` from the JSON source. On generation failure, warn but do not fail the phase. JSON is the source of truth.

### Performance Budgets (config.phases defaults)

| Phase | Budget | Notes |
|-------|--------|-------|
| 1 | 0.5 min | Single API call or short dialogue |
| 2 | 2 min | Codebase scan + architecture design |
| 3 | 10 min | Plan + freeze doc + self-review loop |
| 4 | 2 min | Planning only |
| 5 | 15 min | Varies by complexity; Layer 1 review included |
| 6 | 10 min | Verification + coverage fill + Layer 2 review |
| 7 | 5 min | Docs + mistake capture + GATE 2 |

Budgets are advisory, not enforced by the gate hooks. They calibrate "something is wrong" intuition.
