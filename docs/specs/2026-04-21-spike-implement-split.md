---
title: Spike + Implement — workflow split
date: 2026-04-21
status: proposed
author: Jiho Lee
supersedes: none
superseded_by: none
---

# Spike + Implement: workflow split

> Research Spike and Ticket Implementation are categorically different shapes of work.
> One skill cannot serve both without becoming either too heavy for small tickets or too light for large scope.

## 1. Context

The dev-framework plugin currently offers **one skill**: `/dev` (namespaced `/dev-framework:dev`). Its 7-phase pipeline covers Requirements → Research → Plan → Freeze → Test Planning → Implementation → Verification → Docs. It is rigorous, event-sourced (post-v3.0.0 Managed Agents pivot), and produces a single merged PR per invocation.

**The fundamental assumption is single-scope.** Every artifact — freeze doc, plan, tests, PR — assumes "one feature, one branch, one PR." The session folder is keyed by `{repo}--{branch}`. The freeze doc template covers one feature's §1–§9. The `progress-log.json` schema has `featureSlug`, `freezeDocPath`, `plannedFiles` — all singular.

**Real engineering work has two categorically different phases:**

1. **Research Spike** — a senior-engineer activity that takes a high-level goal (e.g., "build a payment processing system") and produces N tickets with dependencies, shared reference material, API contracts, rollout plans, and testing strategy spanning all tickets. Output: a plan doc plus a set of ticket ref docs. Duration: hours to days. Primary question: *what should be built and in what order?*

2. **Ticket Implementation** — an IC-dev activity that takes one well-defined ticket and produces a rigorously-tested, reviewed, merged PR. Output: code + tests + docs + PR. Duration: hours. Primary question: *how do I ship this one scope correctly?*

The current `/dev` skill is 95% aligned with **Ticket Implementation**. Its Phases 1–3 produce a single-feature freeze doc, not a multi-ticket decomposition. There is no `tickets[]`, no `blockedBy`, no shared-reference doc path, no cross-ticket integration verification. Retrofitting multi-ticket orchestration into `/dev` would require rewriting the event schema, progress log, freeze doc template, and several hooks. That is not a feature addition — it is a different shape of program.

This spec proposes that different shape.

## 2. Decision

**Split `/dev` into two skills within the existing `dev-framework` plugin:**

1. **`/spike`** (new) — Research Spike workflow. Input: epic ID + high-level goal. Output: `spike-plan.md` + N per-ticket ref docs + shared artifacts, committed to `<repo>/docs/plan/{epic-id}/`.

2. **`/implement`** (renamed from `/dev`) — Ticket Implementation workflow. Input: ticket ID (from a spike or ad-hoc). Output: merged PR.

Both skills write to **one epic-scoped event log** at `~/.claude/autodev/sessions/{repo}--epic-{epicId}/events.jsonl`. The plan docs under `docs/plan/` are git-versioned, human-readable, PR-reviewable artifacts whose auto-generated sections (status registries) are reducers over the event log.

The plugin itself does not change name. The command `/dev` is retired in favor of `/implement`; plugin version bumps to 4.0.0 to signal the breaking change.

## 3. Design

### 3.1 Skill boundary and naming

| Property | `/spike` | `/implement` |
|---|---|---|
| Namespaced form | `/dev-framework:spike` | `/dev-framework:implement` |
| User-level shortcut (optional) | `~/.claude/commands/spike.md` | `~/.claude/commands/implement.md` |
| Input | Epic ID + goal description | Ticket ID (spike-sourced or ad-hoc) |
| Output | Plan doc + ticket ref docs + shared artifacts | One merged PR |
| Primary artifacts | `docs/plan/{epic}/spike-plan.md`, `docs/plan/{epic}/{ticket}.md` | Freeze doc (retained from `/dev`), code, tests, PR |
| Session scope | Epic | Epic (shared with `/spike`) |
| Typical duration | Hours to days | Hours |
| User gates | One human signoff at end (no formal GATE for v1) | GATE 1 (freeze doc) + GATE 2 (final approval) — retained |
| Multi-agent consensus | Yes, on decomposition coherence + gap review | Yes, on implementation (existing Layer 1/Layer 2 reviews) |

**User-level shortcuts** remedy Claude Code's plugin-command namespacing: typing `/spike` bare routes to `/dev-framework:spike` via a one-line passthrough command file. This is an optional install step for users who want ergonomic bare invocation; the plugin itself ships only the namespaced commands.

### 3.2 Plan doc convention (in-repo)

All plan helper docs live under the consuming repo's `docs/plan/` directory:

```
<repo>/
└── docs/
    └── plan/
        └── {epic-id-or-slug}/              ← from user at /spike entry
            ├── spike-plan.md               ← master plan (§1–§8, §7 auto-regenerated)
            ├── {ticket-1-id-or-slug}.md    ← per-ticket ref doc
            ├── {ticket-2-id-or-slug}.md
            ├── {ticket-3-id-or-slug}.md
            └── shared/                     ← optional: shared artifacts
                ├── api-contracts.openapi.yaml
                └── migrations.md
```

**Naming rules:**
- **Epic folder name:** collected from user at `/spike` entry; required field. Sanitized (lowercase, dashes replace spaces, strip special chars). Example: user provides `"Payments V2"` → folder is `payments-v2`. Collision with existing folder → prompt the user to suffix or overwrite.
- **Ticket file name:** collected from user during Phase 3 decomposition, one ticket at a time. If the user has a tracker ID (e.g., `PAY-123`), it is used verbatim (sanitized). If no ID exists, the user supplies a slug. Collision within the epic folder → same prompt.
- **No tracker integration.** `/spike` does not call `gh issue create`, JIRA API, or any tracker CLI. It records user-supplied IDs only. This is explicitly out of scope; see §9.

**Frontmatter schema (every plan doc):**

```yaml
---
epicId: payments-v2         # matches folder name; absent on ad-hoc /implement
ticketId: pay-123           # absent on spike-plan.md
status: planned | in-impl | merged
implBlockedBy: [pay-120]    # ticket IDs this one cannot be implemented before
deployBlockedBy: [pay-120, pay-121]  # ticket IDs this one cannot be deployed before
createdAt: 2026-04-21T10:00:00Z
---
```

### 3.3 Blocker classification

Dependencies between tickets are classified at spike time (when the author has the big-picture view) and enforced at implementation time:

```yaml
implBlockedBy:
  - ticketId: pay-120
    kind: hard
    reason: "pay-120 defines the Payment type that pay-123 imports"
  - ticketId: pay-121
    kind: soft
    reason: "pay-121 extracts a shared auth helper; pay-123 can copy-paste until it lands"

deployBlockedBy:
  - ticketId: pay-120
    kind: hard
    reason: "pay-120 adds payments.status column; pay-123's queries fail without it"
```

**Two dimensions of blocking, because they diverge in practice:**

| Scenario | implBlockedBy | deployBlockedBy |
|---|---|---|
| Type dependency (ticket B imports types from ticket A) | `hard` | `hard` (together) |
| Schema precondition (B queries column added by A) | `none` (B can be written against mocked schema) | `hard` (B's deployment breaks without A deployed first) |
| Shared helper refactor (nice-to-have) | `soft` | `none` |

**Enforcement rule at `/implement` Phase 0:**

| Classification | Target ticket status | Behavior |
|---|---|---|
| `hard` | unmerged | **Hard block** — exit with message listing unmet blockers and reasons |
| `soft` | unmerged | **Warn + proceed** — user takes responsibility |
| any | merged | Pass |

Soft classification exists because not every dependency is a correctness requirement. Forcing everything through a hard gate creates false coupling; allowing everything through a warning erodes gates. The user decides at spike time which is which.

### 3.4 Epic-scoped session folder (Managed Agents alignment)

Session state moves from branch-scoped to epic-scoped:

```
~/.claude/autodev/sessions/
└── {repo}--epic-{epicId}/              ← keyed by epic, not branch
    ├── events.jsonl                    ← shared between /spike and all /implement runs
    ├── .seq                            ← atomic counter (existing)
    ├── views/                          ← reducer output (existing M2 pattern)
    │   ├── spike-registry.json         ← feeds spike-plan.md §7
    │   ├── ticket-statuses.json        ← feeds ticket-doc frontmatter.status
    │   ├── progress-log.json           ← extended schema
    │   ├── decision-log.json           ← existing
    │   └── pipeline-issues.json        ← existing, but now per-ticket
    ├── bypass.json                     ← unchanged
    └── bypass-audit.jsonl              ← unchanged
```

**Rationale — Managed Agents invariant #7 ("many brains can share many hands"):**

`/spike` and `/implement` are two brain invocations. In MA terms, they are not two separate sessions — they are two brains operating against **one shared session log scoped to the epic**. `wake.sh` on the epic session returns the full cross-ticket state in a single call:

> "T1 merged at seq 142. T2 in-impl, Phase 5 iteration 2 at seq 287. T3 planned, blocked by T2."

This is not achievable with per-branch sessions linked by a `spikeId` field (my earlier discarded option). Per-branch sessions would require join-at-query-time to reconstruct epic state, violating MA's principle that `wake()` should return a complete picture from a single session.

**Ad-hoc `/implement` fallback:** if `/implement` is invoked without an epic context (no spike, no ticket ref doc in any `docs/plan/*/`), it synthesizes `epicId = ad-hoc-{sanitized-branch}` and proceeds. This preserves the single-feature workflow for users who don't want a spike for small changes.

### 3.5 Bi-directional references (plan ↔ tickets)

The plan doc knows its tickets. Each ticket knows its plan. Updates flow through the event log; reducers regenerate the "join" sections in both directions.

**`spike-plan.md` structure:**

```markdown
---
epicId: payments-v2
status: in-progress
createdAt: 2026-04-21T10:00:00Z
---

# Payments V2 — Spike Plan

## §1 Requirements (human-authored)
...

## §2 Architecture + NFR (human-authored)
...

## §3 Rollout / rollback plan (human-authored)
...

## §4 Observability plan (human-authored)
...

## §5 API contracts (human-authored; links to shared/api-contracts.openapi.yaml)
...

## §6 Data migration chain (human-authored; links to shared/migrations.md)
...

## §7 Tickets

<!-- BEGIN AUTO-GENERATED REGISTRY -->
| ID | Title | Status | impl-blockedBy | deploy-blockedBy | Ref |
|----|-------|--------|----------------|------------------|-----|
| pay-120 | Add payments schema | merged | [] | [] | [pay-120.md](pay-120.md) |
| pay-123 | Payment API | in-impl | [pay-120] | [pay-120, pay-121] | [pay-123.md](pay-123.md) |
| pay-125 | Payment reconciliation | planned | [pay-123] | [pay-123] | [pay-125.md](pay-125.md) |
<!-- END AUTO-GENERATED REGISTRY -->

## §8 Testing strategy (human-authored)
...
```

**Per-ticket ref doc (`pay-123.md`) structure:**

```markdown
---
epicId: payments-v2
ticketId: pay-123
status: in-impl
implBlockedBy:
  - ticketId: pay-120
    kind: hard
    reason: "pay-120 defines Payment type"
deployBlockedBy:
  - ticketId: pay-120
    kind: hard
    reason: "schema precondition"
  - ticketId: pay-121
    kind: hard
    reason: "index migration"
---

# pay-123 — Payment API

## §1 Back-reference
Part of epic [payments-v2](spike-plan.md). See spike-plan §7 for sibling tickets and status.

## §2 This ticket's role in the big picture (extracted from spike-plan §2)
...

## §3 Relevant API contract slice (extracted from spike-plan §5)
...

## §4 Relevant migrations (extracted from spike-plan §6)
...

## §5 Relevant observability hooks (extracted from spike-plan §4)
...

## §6 Implementation notes

<!-- BEGIN AUTO-GENERATED IMPL LOG -->
- seq 287: Phase 5 started
- seq 301: Consensus iteration 1 — 4 issues found, 3 fixed
- ...
<!-- END AUTO-GENERATED IMPL LOG -->

## §7 Discoveries / reference-doc corrections needed
(populated by /implement when it finds spike-plan facts are wrong)
- 2026-04-23: pay-123 discovered that the third-party API returns arrays under `data[]`, not objects as §3 of spike-plan stated. Proposed correction emitted as `ticket.discovery` event; user should update spike-plan.md §5.
```

**Bi-directional update mechanism:**

| Event | Emitted by | Reducer effect |
|---|---|---|
| `ticket.started` | `/implement` on Phase 0 success | `spike-plan.md` §7 row → status `in-impl`; ticket-doc frontmatter `.status` → `in-impl` |
| `ticket.discovery` | `/implement` on ref-doc error | Ticket doc §7 appended; spike emits a "stale reference" flag for spike retro |
| `ticket.merged` | `/implement` Phase 7 GATE 2 option [3] | `spike-plan.md` §7 row → `merged`; cross-ticket integration verifier wakes if all deps now green |
| `spike.integration.verified` | Cross-ticket test runner | `spike-plan.md` status → `all-tickets-integrated` |

Both docs are views over the event log (matches existing M2 architecture). Between-sentinel content is never written by hand; outside-sentinel content is never written by tooling. This is a strict **one-writer rule per section**, enforcing no two-writer hazards.

### 3.6 `/spike` phase structure

`/spike` has 4 active phases ending in human signoff. A 5th phase (retro) runs asynchronously when all spike tickets are merged.

**Phase 1 — Requirements review.** Multi-feature scope. User is asked for the epic goal, success criteria across the epic, non-functional requirements (2a: SLA, security threat model, privacy/compliance, accessibility), and the rollout/rollback strategy (2b: feature flags, canary, migration reversibility). Multi-agent consensus on completeness.

**Phase 2 — System design.** Produces spike-plan.md §2 (architecture across the epic), §3 (rollout), §4 (observability plan: metrics, logs, traces, dashboards, alerts at spike level), §5 (API contracts as artifacts in `shared/`), and §6 (data migration chain). Multi-agent consensus on design coherence. Creates the `docs/plan/{epic}/` folder, writes `spike-plan.md` skeleton and `shared/` stubs.

**Phase 3 — Ticket decomposition.** One-at-a-time interactive: propose a ticket, ask for ID/slug, write its ref doc, confirm `implBlockedBy` and `deployBlockedBy`. Each ticket ref doc inherits relevant slices of spike-plan §2, §4, §5, §6 to avoid duplication pain later. Emits `spike.tickets.decomposed` event when all tickets are defined.

**Phase 4 — Cross-ticket gap review.** Multi-agent consensus on the decomposition: does the ticket set fully cover the requirements? Are there integration tests that span tickets? Is the dependency graph acyclic? Is the deployment order deployable? Produces spike-plan §7 (auto-generated from events) and §8 (testing strategy). Ends with human signoff — no formal GATE scaffolding, just a "ready to proceed" confirmation from the user, matching their directive that signoff is natural human review.

**Phase 5 — Retro (async).** Runs only after all tickets of the epic reach `merged` status. Triggered explicitly via `/spike --retro EPIC-ID` or automatically proposed when the user re-invokes `/spike EPIC-ID` and all tickets are merged. Aggregates `ticket.discovery` events, identifies recurring design mistakes, writes to `~/.claude/autodev/chronic-design-patterns.json`.

### 3.7 `/implement` phase structure (changes from current `/dev`)

`/implement` retains the existing 7 phases of `/dev` with additions. Reference: [plugins/dev-framework/skills/dev/SKILL.md](../../plugins/dev-framework/skills/dev/SKILL.md).

**New Phase 0 — Prereq check.**
- Read the ticket's ref doc from `docs/plan/{epic}/{ticket}.md`
- Read `spike-plan.md` §2 (architecture summary) for big-picture context
- For each `implBlockedBy` entry:
  - Kind `hard` + target status not `merged` → exit with listed blockers and reasons
  - Kind `soft` + target status not `merged` → warn the user with reason, proceed
- Print three sections to the user:
  1. **Big picture** — spike-plan §2 summary
  2. **This ticket's role** — ticket doc §2
  3. **Proceeding** or **Blocked**
- Emit `ticket.started` on success (reducer flips spike-plan §7 row and ticket doc frontmatter)

**Modified Phase 1-3 when spike-sourced.** When the ticket ref doc exists, the existing Requirements → Research → Plan phases fast-forward: the freeze doc's §1-§8 sections can pre-populate from the ticket ref doc (which inherited them from spike-plan.md). Human review still occurs at GATE 1; the difference is that most sections arrive pre-filled rather than gathered from scratch. Ad-hoc `/implement` (no ref doc) runs full Phase 1-3 as today.

**New sub-step in Phase 5 — Static checks (3a).** After Layer 1 review converges, run linter, type check, dependency security scan, and license check before declaring the phase complete. This is a mechanical pass, not a consensus phase. Existing hook infrastructure (PostToolUse) can drive this.

**Phase 6 — unchanged.** Verification + coverage fill + Layer 2 review.

**Extended Phase 7 — PR + bi-dir plan update + optional DB rollback.**
- Existing GATE 2 flow retained (options [1] approve, [2] reject, [3] approve + commit + push)
- On approval (option [1] or [3]), emit `ticket.merged` (reducer flips spike-plan §7 row to `merged`)
- If the ticket's deploy changes affected schema (detected by a file heuristic like `migrations/` edits), produce a **rollback script companion** alongside the PR — this is the "step 7: rollback for schema changes" the user approved. The script is a reversal of the migration steps, committed to the same PR.
- If any `ticket.discovery` events were emitted during Phase 5-6, summarize them to the user before GATE 2 so they know the spike plan needs corrections

**Retro (existing Phase 7 mistake capture, unchanged).** Continues to capture chronic code patterns to `chronic-patterns.json`. Added benefit: `ticket.discovery` events emitted during implementation now feed into the spike-level retro as well (cross-pollination).

**Explicitly retained from `/dev`:** multi-agent consensus engine, freeze doc template, GATE 1/GATE 2 mechanics, bypass protocol, freeze-gate hook, push-guard hook, phase-gate hook, event log, view reducers, wake.sh, replay.sh, chronic patterns, modelProfile config.

**Explicitly NOT added (see §9 for rationale):**
- Breaking-change detection (belongs to external review plugin)
- PR review response loop (belongs to external review plugin)
- Deploy + smoke + monitoring (out of scope for this plugin)
- Ticket sizing / estimation
- Parallel implementation coordination (single-ticket focus preserved)

### 3.8 Retro-per-skill (chronic patterns split)

| Retro type | Stored in | Loaded at SessionStart by | Populated by |
|---|---|---|---|
| Code patterns (existing) | `~/.claude/autodev/chronic-patterns.json` | `/implement` (existing hook) | `/implement` Phase 7 mistake capture |
| Design patterns (new) | `~/.claude/autodev/chronic-design-patterns.json` | `/spike` (extend existing hook) | `/spike` Phase 5 retro |
| Cross-pollination | Event stream (no separate store) | Both skills read via reducers | `ticket.discovery` events emitted by `/implement`, consumed by `/spike` retro |

The existing [load-chronic-patterns.sh](../../plugins/dev-framework/hooks/scripts/load-chronic-patterns.sh) extends to load both files conditionally based on invoking skill. The existing [mistake-tracker-protocol.md](../../plugins/dev-framework/skills/dev/references/autonomous/mistake-tracker-protocol.md) forks into two parallel protocols: one for code (unchanged), one for design.

## 4. Event vocabulary

Extending the existing [events-schema.md](../../plugins/dev-framework/skills/dev/references/autonomous/events-schema.md). All new event types carry `epicId` at minimum; ticket-scoped events also carry `ticketId`.

| Event type | Emitted by | Consumers | Data fields |
|---|---|---|---|
| `spike.started` | `/spike` entry | wake.sh pendingAction resolver | `{epicId, goal}` |
| `spike.phase.N.started` | `/spike` phase N begin | progress view | `{epicId, phase}` |
| `spike.phase.N.completed` | `/spike` phase N end | spike retro, progress view | `{epicId, phase, metrics?}` |
| `spike.tickets.decomposed` | `/spike` Phase 3 end | spike-registry reducer | `{epicId, tickets: [{ticketId, title}]}` |
| `spike.gate.approved` | `/spike` Phase 4 end (human signoff) | unlocks `/implement` on this epic | `{epicId, approvedBy}` |
| `spike.integration.verified` | Cross-ticket verifier | spike completion check | `{epicId, ticketCount}` |
| `spike.retro.completed` | `/spike` Phase 5 end | chronic-design-patterns store | `{epicId, patternsPromoted, patternsDemoted}` |
| `ticket.started` | `/implement` Phase 0 success | spike-registry (→ status: in-impl), ticket-doc reducer | `{epicId, ticketId, branch}` |
| `ticket.discovery` | `/implement` on ref-doc error | spike retro; proposes spike-plan edit | `{epicId, ticketId, section, correction}` |
| `ticket.merged` | `/implement` Phase 7 approval [1] or [3] | spike-registry; integration verifier wake | `{epicId, ticketId, prUrl?}` |

All events use the existing atomic-seq append protocol via [emit-event.sh](../../plugins/dev-framework/hooks/scripts/emit-event.sh). No changes to primitives required.

## 5. Managed Agents alignment audit

Mapping each design decision in §3 to the invariants of Anthropic's Managed Agents pattern (anthropic.com/engineering/managed-agents):

| MA invariant | Design element | Verdict |
|---|---|---|
| Brain / Hands / Session decomposition | Brain = Claude+orchestrator per skill; Hands = hooks, reducers, execute.sh; Session = shared `events.jsonl` | ✅ Matches |
| Append-only session | All new events (`spike.*`, `ticket.*`) extend `events.jsonl`; plan-doc §7 is a regenerated view, not a mutated source | ✅ Matches |
| Stateless harness / `wake()` | [wake.sh](../../plugins/dev-framework/hooks/scripts/wake.sh) extended with new `pendingAction` values: `spike.phase.N.*`, `spike.gate.pending`, `ticket.T.impl.phase.N.*`, `spike.retro.ready` | ⚠️ Extension required; no architectural change |
| Context lives outside Claude's context window | Plan docs in `<repo>/docs/plan/` + event log views both durable and programmatically accessed. Plan docs are **better** than session-local state because they are also shareable with humans via PR review | ✅ Matches + improvement |
| Interface stability over implementation | `/spike` declares phases in `phases/spike-phase-N.yaml`; `/implement` continues using existing phase YAMLs. Dispatcher semantics (execute.sh) unchanged | ✅ Matches |
| Hands independent of brain | `execute.sh`, reducers, emit-event, phase-gate, freeze-gate, push-guard all work for both skills without modification | ✅ Matches |
| Many brains share many hands | `/spike` and `/implement` write to one epic-scoped `events.jsonl`. `wake()` returns cross-ticket state in a single call | ✅ Matches — this was the key design shift away from branch-scoped sessions |

**Explicit non-change:** the four core primitives (`emit-event.sh`, `get-events.sh`, `wake.sh`, `execute.sh`) are not modified. New functionality extends the **event vocabulary** and adds **new reducers**, but does not introduce new primitive shapes. This preserves the MA invariant that primitives are stable interfaces.

## 6. Migration from `/dev`

**Version bump:** plugin moves from v3.0.x → **v4.0.0**. The major bump signals a breaking change: the `/dev` command is retired.

**Transition files (one-version tombstone):**

1. Keep [plugins/dev-framework/commands/dev.md](../../plugins/dev-framework/commands/dev.md) for v4.0.0 only, with content replaced by:

   ```markdown
   ---
   description: Renamed to /dev-framework:implement as of v4.0.0. See also the new /dev-framework:spike for multi-ticket research.
   ---
   Inform the user that `/dev-framework:dev` has been renamed to `/dev-framework:implement`. Do not invoke any skill; point them to `/dev-framework:implement` for single-ticket work and `/dev-framework:spike` for multi-ticket research. Return without taking further action.
   ```

   This command is removed entirely in v4.1.0.

2. Existing session folders keyed by `{repo}--{branch}`: no user has long-lived sessions in production yet (plugin is young), so **no automated migration script ships**. If any user reports an in-flight session, manual migration is documented in the v4.0.0 release notes.

**Rename mechanics:**

- `plugins/dev-framework/commands/dev.md` → `plugins/dev-framework/commands/implement.md` (content updated to invoke the renamed skill)
- `plugins/dev-framework/skills/dev/` → `plugins/dev-framework/skills/implement/`
- `SKILL.md` frontmatter `name: dev` → `name: implement`
- Sweep `plugins/dev-framework/README.md`, `plugins/dev-framework/CLAUDE.md`, all `references/**/*.md`, all `phases/*.yaml` for `/dev` references → `/implement` where the reference is to the command; keep the generic word "dev" / "development" where it refers to the category of work
- Update [plugin.json](../../plugins/dev-framework/.claude-plugin/plugin.json) description, version
- Tests under `plugins/dev-framework/tests/` may reference the skill name; audit and update

**New files to create:**

- `plugins/dev-framework/commands/spike.md`
- `plugins/dev-framework/skills/spike/SKILL.md`
- `plugins/dev-framework/skills/spike/references/` — relevant protocol, template, standards subtrees (can reuse existing references where semantics match)
- `plugins/dev-framework/phases/spike-phase-1.yaml` through `spike-phase-5.yaml`
- `plugins/dev-framework/hooks/scripts/reduce-spike-plan.sh` (reducer for `spike-plan.md` §7)
- `plugins/dev-framework/hooks/scripts/reduce-ticket-doc.sh` (reducer for ticket doc §6 and frontmatter status)
- Templates: `plugins/dev-framework/skills/spike/references/templates/SPIKE_PLAN_TEMPLATE.md`, `TICKET_REF_TEMPLATE.md`

## 7. Implementation phases

Ordered by dependency; each phase should land as its own PR.

| # | Phase | Deliverables | Depends on |
|---|---|---|---|
| 1 | **Design spec** (this doc) | `docs/specs/2026-04-21-spike-implement-split.md`; user review | — |
| 2 | **Rename `/dev` → `/implement`** | File renames, reference sweep, v4.0.0 bump, tombstone `dev.md` command | 1 |
| 3 | **`/spike` skill v1** | SKILL.md, 5 phase YAMLs, plan-doc templates, user-level shortcut file | 1 (design spec locked) |
| 4 | **Plan folder reducer + bi-dir events + Phase 0 prereq** | `reduce-spike-plan.sh`, `reduce-ticket-doc.sh`, new event type handlers, Phase 0 wiring in `/implement` | 2, 3 |
| 5 | **Retro-per-skill** | Extend [load-chronic-patterns.sh](../../plugins/dev-framework/hooks/scripts/load-chronic-patterns.sh); create `chronic-design-patterns.json` store; fork mistake-tracker-protocol into design + code variants | 4 |
| 6 | **Dog-food test** | Run `/spike` on a small toy epic; consume tickets via `/implement`; verify bi-dir updates, integration verification, retro capture | 5 |

Phases 2 and 3 are independent and can be developed in parallel worktrees. Phase 4 unifies them.

## 8. Performance budgets

Preserving the advisory-budget discipline of the existing pipeline:

| Skill | Phase | Budget | Notes |
|---|---|---|---|
| `/spike` | 1 Requirements | 5 min | Multi-feature Q&A |
| `/spike` | 2 System design | 15 min | Architecture across epic; heavy research |
| `/spike` | 3 Decomposition | 10 min | One-at-a-time ticket creation |
| `/spike` | 4 Gap review | 10 min | Multi-agent consensus on decomposition |
| `/spike` | 5 Retro | 5 min | Async, runs only when all tickets merged |
| `/implement` | 0 Prereq check | 0.5 min | Mostly file reads and comparisons |
| `/implement` | 1-7 | unchanged | See existing [SKILL.md](../../plugins/dev-framework/skills/dev/SKILL.md) §"Performance Budgets" |

Budgets are advisory, not gate-enforced.

## 9. Non-goals and deferred work

Explicitly out of scope for this spec — not because they're unimportant, but because their scope warrants separate design.

| # | Item | Rationale | Deferred to |
|---|---|---|---|
| 1 | Ticket management (JIRA, Linear, GitHub Issues CLI integration) | Keeps `/spike` stack-agnostic; tracker choice varies per team | Future `/spike --create-tickets=<tracker>` mode |
| 2 | PR review response loop (responding to human PR comments) | Owned by a separate review-focused plugin | That plugin |
| 3 | Breaking-change detection on APIs | Same — review-plugin territory | That plugin |
| 4 | Deploy + smoke + monitoring + rollback decision | Deployment tooling varies wildly per stack; needs its own config surface | Future `/deploy` skill |
| 5 | Feasibility pre-check sub-mode (20-min "can this even work?" variant of `/spike`) | Nice-to-have; adds UX complexity without structural value for v1 | Future `/spike --quick` mode |
| 6 | Parallel implementation coordination across tickets | Hard problem (merge conflicts, dep-ordering under concurrency); user deferred via "we use branches/worktrees" response | Future, likely requires its own spec |
| 7 | Cost / capacity planning in spike | Highly stack-dependent | Future |
| 8 | Ticket sizing / estimation | User directly declined: "time and effort doesn't matter, only domain matters" | Not planned |
| 9 | Formal GATE scaffolding for `/spike` end-of-phase | User directly declined: "natural thing for human to review the result and signoff. so no need an extra step" | Not planned — human review stays informal |
| 10 | Pre-spike intake / triage / stakeholder alignment | Product-management concerns, not engineering workflow | Not planned — out of scope for engineering plugin |

## 10. Open questions

None at spec-authoring time. All design questions raised during the 2026-04-21 design session were resolved by user direction. Any new questions that emerge during implementation will be appended below with resolution notes.

---

**End of spec. Implementation proceeds per §7 after user approval of this document.**
