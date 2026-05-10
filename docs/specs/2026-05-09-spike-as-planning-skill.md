---
title: "Spike as the planning skill for all ticket levels — Research agent + clean planning/execution split"
date: 2026-05-09
status: design-approved
target: dev-framework plugin v4.2.0 → v5.0.0
related:
  - replaces (partial): docs/specs/2026-04-27-spike-lean-redesign.md (v2.0 of /spike)
  - replaces (partial): docs/specs/2026-04-21-spike-implement-split.md
  - foundation: docs/specs/2026-04-20-managed-agents-evolution.md (M1-M4 primitives)
---

# Spike as the planning skill for all ticket levels

## §0 Background — what motivated this

The current model (post-v2.0 lean redesign) treats `/spike` as a **multi-ticket-only** workflow. Phase 0 redirects single-PR work to `/implement`. `/implement` is a 7-phase orchestrator that does requirements, research, planning, freeze-doc, test plan, code, verify, and finalize — i.e., it owns both planning and execution.

**Friction observed:**
- Mental model is split across "epic plan vs single-ticket plan" with different artifacts and agents.
- `/implement` Phase 1-3 effectively duplicates spike's requirements + design + plan steps for the single-ticket case. Two skills both "plan" — confusing.
- No first-class concept of a Research ticket: investigation work that doesn't produce code (API exploration, schema decisions, doc-vs-reality verification) is awkwardly stuffed into Phase 2 of `/implement` or hand-rolled outside the framework.
- Cross-ticket Research dependencies (Story B's plan blocks on Research A's findings) have no formal model — user has to manually orchestrate.

**Goal of this redesign**: make `/spike` the **single planning skill** for any ticket level (Epic / Research / Story), and make `/implement` the **pure execution skill** for Story tickets. Add a first-class **Research agent** dispatched within spike for any kind of investigation work.

## §1 Goals / non-goals

**Goals:**
- One mental model: spike = ALL planning + user check-in; implement = pure execution.
- Three ticket levels handled by spike with shared phase building blocks: Epic, Research, Story.
- Research agent that handles any investigation (not just API): external docs, internal codebase, empirical testing, user collaboration, behavioral observation.
- Doc-vs-reality cross-validation built into Research agent output (every finding tagged with confidence; load-bearing doc-only items flagged for empirical verification).
- Eager Epic decomposition: Epic-spike fully specs all child tickets in one run.
- Research agent dispatched as a first-class managed sub-brain (fan-out, durable, resumable).
- Freeze doc as the formal contract artifact between spike and implement; spike owns its creation and the GATE 1 approval.
- Reduce `/implement` from 7 phases to 3 (Execute / Verify / Finalize).

**Non-goals:**
- Auto-migration of v4 in-flight sessions.
- Cross-epic dependencies (one epic blocking on another).
- Multi-repo spike (single epic spanning multiple repos).
- "Re-spike" workflow (rewriting a finalized freeze doc — freeze doc is immutable by design).
- `/spike --autonomous` mode (spike's value is user check-in; autonomous spike is contradiction).
- Research-only epic P7 retro mechanics (no merge event ever; defer).

## §2 Mental model

**Core split:**

```
Spike      = ALL planning + user check-in   (Epic, Research, Story)
Implement  = PURE execution                  (Story only)
```

**Ticket levels and lifecycles:**

| Level | Spike output | Goes to /implement? | Final artifact |
|---|---|---|---|
| Epic | spike-plan + N child specs (eager decomposition) | No | `docs/plan/{epic}/spike-plan.md` + N child docs |
| Research | research findings + ADRs + schemas | No | `docs/plan/{epic-or-slug}/research-{ticket-or-slug}.md` + schemas + ADRs (committed; no separate PR required) — see §4/§5 for path-by-mode |
| Story | freeze doc (interface, edge cases, test plan) | Yes | freeze doc → /implement → code PR |

**Entry points:**

| Invocation | Mode |
|---|---|
| `/spike <epic-description>` | Epic mode |
| `/spike research <topic>` | Standalone Research mode |
| `/spike story <ticket>` | Standalone Story mode |
| `/implement <freeze-doc-path>` | Execution (Story only) |

**Global guardrails (injected into every agent system prompt):**
SOLID / DRY / YAGNI; small-start + edge case coverage; Open/Closed (interfaces for extensibility); follow existing repo style; concise ADRs and docs; minimal inline comments.

## §3 Phase structure

**Shared building blocks:**

| Block | Purpose | Primary agent(s) |
|---|---|---|
| P1. Scope | Requirements clarification at the level | requirements-analyst |
| P2. Investigate | Architecture/research; dispatches Research agent for blocking investigation deps | architect + research-investigator (as needed) |
| P3. Decompose | Build DAG of children + dependency edges | architect |
| P4. Spec | Produce final artifact: freeze doc / research doc / multi-ticket plan; includes test plan via test-strategist | architect + test-strategist |
| P5. Review | Multi-agent consensus (gaps, completeness, edge cases) | code-quality + observability + performance + test-strategist |
| P6. Approve | User signoff (GATE 1) | user (interactive) |
| P7. Retro | (async) all-children-merged pattern extraction | code-quality-reviewer |

**Mode → Phase sequence:**

| Mode | Sequence | Notes |
|---|---|---|
| Epic | P1 → P2 → P3 → P4(per child) → P5 → P6 → P7(async) | Decompose included; P4 iterates per child; P5 = cross-ticket gap consensus |
| Story | P1 → P2 → P4 → P5 → P6 → P7(async) | Skip Decompose; P2 may dispatch Research agent if blocking; P5 = single-artifact gap consensus on the freeze doc |
| Research | P1 → P2(agent-driven) → P4(synthesize) → P6 → P7(async) | Skip Decompose; skip P5 (single artifact, no cross-ticket gaps) |

**Epic-mode Research dispatch flow inside P2/P3/P4:**

```
P3 Decompose
  ├── identify Research children: [R1, R2]
  ├── identify Story children: [S1, S2, S3]
  └── DAG: R1 → S1, S2;  R2 → S3

P2 (re-entered, per Research child)
  ├── dispatch Research agent for R1 (fan-out sub-session)
  │     └── agent runs (any combination of doc-search, codebase-explore, empirical-test, user-collab)
  │     └── emits research.completed (parent reducer derives ticket.research.completed)
  └── dispatch Research agent for R2 (parallel possible)

P4 Spec (per child) — each Story spec uses its blocking Research output
  ├── spec S1 (uses R1 output)
  ├── spec S2 (uses R1 output)
  └── spec S3 (uses R2 output)

P5 Review → P6 Approve (whole plan: epic + N children) → /implement starts per-Story.
```

**`/implement` reduces from 7 phases to 3:**

| New phase | Old phase | Purpose |
|---|---|---|
| E1. Execute | Phase 5 (Implementation + L1 review) | TDD code + multi-agent layer 1 review |
| E2. Verify | Phase 6 (Verification + L2 review) | coverage fill + layer 2 review |
| E3. Finalize | Phase 7 (Docs + GATE 2) | docs + mistake capture + GATE 2 + PR |

## §4 Research agent

File: `plugins/dev-framework/agents/research-investigator.md` (single agent, strategy-toolbelt model).

**Frontmatter sketch:**
```yaml
name: research-investigator
description: |
  Specialized agent for resolving Research ticket dependencies during spike.
  Universal scope: external docs, internal codebase, empirical testing, user
  collaboration, behavioral observation. Outputs research-{ticket}.md plus
  ADRs and schema files; emits research.completed.
tools: WebFetch, WebSearch, Read, Write, Grep, Glob, Bash, AskUserQuestion, NotebookRead
```

**Strategy toolbelt (agent picks dynamically):**

| Strategy | Use for |
|---|---|
| External docs | API spec, framework docs, RFCs, library behaviors |
| Internal explore | existing patterns, ADRs, schemas in this repo |
| Empirical test | actual execution: curl, scripts, db queries, benchmarks |
| User collab | domain knowledge, business rules, ambiguous requirements |
| Behavioral observation | logs, traces, prod data |

**Doc ≠ Reality protocol.** Every finding gets a confidence tag:

| Tag | Meaning | Handling |
|---|---|---|
| `verified-empirically` | Actually tested | Commit as-is |
| `doc-only` | Found in official doc, not tested | If load-bearing for ≥1 Story spec, flag with verification recipe |
| `inferred-from-code` | Derived from code/context | Recommend separate verification |
| `user-confirmed` | Domain expert/user confirmed | Commit as-is |

**Dispatch via fan-out (not Task tool) for durability:**

```
Spike detects Research dep
  ├── Epic mode: in P3 Decompose (Research is a separate child ticket)
  └── Story mode: in P2 Investigate (Research is inline within the Story)
  ↓
fan-out.sh --name research-{slug} --share-events
  ↓
research-investigator agent runs in child session (events.jsonl shared)
  ↓
research.completed event → parent reducer derives ticket.research.completed
  ↓
parent spike resumes (Epic: P4 Spec for unblocked Stories; Story: continues P2/P4)
```

**Output file location by mode:**

| Mode | Research output path |
|---|---|
| Epic (Research child ticket) | `docs/plan/{epic}/research-{ticket-id}.md` |
| Story (inline research within Story-mode spike) | `docs/plan/{story-ticket-id}/research-{question-slug}.md` (sidecar) |
| Standalone Research | `docs/plan/{ticket-id}/research-{ticket-id}.md` |

In Story mode, the Research findings are also **summarized into the freeze doc §2-§4 Architecture**; the sidecar holds full detail and verification backlog.

**Why fan-out, not sub-task:**
- Durability: long interactive runs survive crashes.
- Event-log integration: `wake()` returns parent + research state in one view.
- Parallelism: independent Research children dispatch concurrently.
- Resumability: `/spike --from N` re-dispatches incomplete Research.

**Input contract (parent → agent):**
```json
{
  "ticketId": "research-stripe-webhooks",
  "epicId": "payments-v2",
  "question": "Stripe webhook event schema + behaviors needed for refund handler",
  "blockedStoryTickets": ["pay-handler-001", "pay-recon-002"],
  "requiredOutput": {
    "schemas": ["TS event payload type"],
    "behaviors": ["retry policy", "signature verification"],
    "edgeCases": ["partial refund", "out-of-order events"]
  },
  "interactionAllowed": true,
  "globalGuardrails": "SOLID, DRY, YAGNI, ..."
}
```

**Output contract — research doc** (path varies by mode; see "Output file location by mode" table above):

| Section | Content |
|---|---|
| §1 Question | Parent-supplied question + scope |
| §2 Methodology | Strategies used + counts (e.g., "external-docs: 3 URLs; codebase-explore: 12 files; empirical-test: 5 calls") |
| §3 Findings | Key facts with confidence tag + source citation |
| §4 Schemas/Types | Extracted (TS/JSON/OpenAPI; also committed as separate files) |
| §5 Edge Cases Observed | Behaviors not in docs but found |
| §6 Open Questions | Unresolved items (parent escalates to user if blocking) |
| §7 Decision Impact | Which Story specs are affected and how |
| §8 References | URLs (with doc version), payload samples (secrets masked) |
| §9 Verification Backlog | doc-only/inferred items load-bearing for ≥1 Story; each item has a verification recipe |

**Plus committed artifacts (separate files; `{epic-or-slug}` matches the research doc's parent folder):**
- `docs/adr/adr-{n}-{slug}.md` (architectural decisions surfaced by research)
- `docs/plan/{epic-or-slug}/schemas/{ticket-or-slug}.{ts,json,yaml}` (extracted schemas)
- `docs/plan/{epic-or-slug}/samples/{ticket-or-slug}-{request,response}.json` (empirical samples; secrets masked)

**Hard constraints (system prompt):**

1. **Secrets handling.** Secrets (API keys, tokens, passwords, cookies) MUST be masked as `<REDACTED-{kind}>` before any write. `.env` is read only after `.gitignore` confirms exclusion; values are never logged or committed.

2. **Bash scope — read-only investigation only.** Allowed: GET/HEAD HTTP, `cat`/`ls`/`grep`/`find` reads, idempotent queries (`SELECT`, dry-run subcommands). **Forbidden without explicit per-call user confirmation**: any write (`rm`, `mv`, `cp` to existing path), any state-mutating HTTP (POST/PUT/PATCH/DELETE), any DB mutation (`INSERT`/`UPDATE`/`DELETE`), any process control (`kill`, `systemctl`), any file creation outside `docs/plan/{epic-or-slug}/` and `docs/adr/`. Production endpoints require user-confirm-each-call regardless of method. This guards against prompt-injection via fetched web content steering the agent into destructive ops.

3. **Dispatch crash recovery.** On parent spike resume (`/spike --from N` or stateless wake), if `research.dispatched` exists for ticket X without a matching `research.completed`, parent re-dispatches a fresh Research agent for X. Re-dispatch is idempotent: the agent reads any prior partial output from child SESSION_DIR if present, else starts fresh. Parent emits `research.redispatched` event for audit.

## §5 Spike → Implement contract

**Disk layout (uniform across modes):**

```
docs/plan/{epic-or-slug}/
├── spike-plan.md                     # Epic mode only — overview, DAG, child links
├── freeze-{ticket}.md                # per Story child (or standalone Story)
├── research-{ticket-or-slug}.md      # per Research child, standalone Research, OR inline-research sidecar in Story mode
├── schemas/                          # extracted/decided schemas
├── samples/                          # API empirical payloads (secrets masked)
└── review-backlog.md                 # Minor/Nit findings from P5

docs/adr/
└── adr-{n}-{slug}.md                 # cross-ticket architectural decisions
```

`{epic-or-slug}` = epic ID for Epic mode, ticket ID for standalone Story/Research mode.

`{ticket-or-slug}` for research-*.md = ticket ID when Research is a separate ticket (Epic-child or standalone), OR a descriptive slug when inline within a Story-mode spike (e.g., `research-stripe-signature.md`).

**Freeze doc (spike-owned; /implement read-only):**

| Section | Content | Filled by |
|---|---|---|
| Header | `status: APPROVED`, approvedAt, approvedBy, approvalMode, **approvedHash** (sha256 of canonical body content at approval time) | Spike P6 (GATE 1) |
| §1 Requirements | acceptance criteria, success metrics | Spike P1 |
| §2-§4 Architecture | component design, data flow, NFR | Spike P2 |
| §5 Edge Cases | explicit list (must be test-covered) | Spike P4 |
| §6 Test Plan | unit + integration + e2e scenarios, coverage targets | Spike P4 (test-strategist) |
| §7 Interface Contracts | exported APIs, types, error modes | Spike P4 |
| §8 ADR References | adr-N links + decision summaries | Spike P2 |
| §9 Non-Frozen Allow List | zones where /implement may ask user (observability config, etc.) | Spike P4 |
| §10 Verification Backlog | imported from Research §9 | Spike P3-P4 |
| **§11 Prerequisites** | other Story ticket-ids that must be merged before this Story starts (extracted from Epic-mode DAG; empty for standalone Story) | Spike P3 (Epic) / empty (Story-mode) |
| `bypassHistory` | freeze-gate bypass log | /implement E3 (merged at GATE 2) |

**Immutability enforcement.** The freeze doc is immutable after GATE 1. `approvedHash` is computed over the canonical body (everything except the header `bypassHistory` field, which legitimately mutates during /implement). At /implement startup, the hash is recomputed and compared. Mismatch → abort with: `"freeze doc body modified after approval (hash mismatch). Re-run /spike to re-approve, or revoke and start a new ticket."` This makes the contract enforceable, not just documented.

**Verification-failure recovery path.** If user runs a `§10 Verification Backlog` recipe and reality differs from the freeze doc's assumption: freeze doc is immutable, so user has two paths:
- **(a) Re-spike**: `/spike --revisit {epic-or-slug} --reason verification-failure`. Spike re-enters at P2 (Investigate) with prior research as input + new empirical findings. Produces new freeze doc(s) with new `approvedHash`.
- **(b) Revoke and replace**: user manually moves the old freeze doc to `freeze-{ticket}.revoked.md`, opens a new ticket, runs `/spike story <new-ticket>`.

Manual edits to a hash-locked freeze doc are blocked at /implement startup (hash mismatch); freeze-gate hook also denies src/** edits when hash doesn't match. No silent corruption path.

**Two gates, two owners:**

| Gate | Phase | Owner | Marker | Effect |
|---|---|---|---|---|
| GATE 1 | End of Spike P6 | Spike | Story mode/Epic-Story-child: freeze doc `status: APPROVED`. Research mode/Epic-Research-child: research doc `status: APPROVED`. | freeze-gate hook unlocks src/** edits (Story only; Research has no /implement) |
| GATE 2 | End of /implement E3 | /implement | `pipeline-complete.md` in session folder | push-guard hook unlocks `git push` |

Research-mode P6 only sets the research doc status (no src/** unlock needed since no /implement follows).

**Hooks (minor behavior delta on freeze-gate; others unchanged):**

| Hook | Behavior |
|---|---|
| `freeze-gate.sh` | Blocks src/** Edit/Write unless **active** freeze doc is APPROVED. Active doc resolved via `active-freeze-doc.txt` pointer in SESSION_DIR (written by /implement at startup). See §7 for the pointer mechanism. |
| `push-guard.sh` | Blocks `git push` until pipeline-complete.md exists. /implement still creates it. |
| `phase-gate.sh` | Validates progress-log at phase boundaries. Reads new YAML paths (spike/, implement/). |

**`/implement` invocation:**

```bash
# v5.x
/implement docs/plan/payments-v2/freeze-pay-handler-001.md
```

**/implement startup checks (in order):**

1. **Parse freeze doc** at given path; fail if file missing or unparseable.
2. **Verify `status == APPROVED`**; fail loudly otherwise.
3. **Verify `approvedHash`** matches sha256 of current canonical body; fail with hash-mismatch error if modified post-approval.
4. **Verify §11 Prerequisites all merged**: for each prerequisite ticket-id, check that `ticket.merged` event exists in events.jsonl OR git log shows the merge commit. If any prerequisite unmerged → abort with `"Prerequisites not satisfied: [...]. Merge prerequisites first or run /implement on them in order."`
5. **Resolve SESSION_DIR** (epic-scoped event log; shared with `/spike`).
6. **Write `active-freeze-doc.txt`** pointer in SESSION_DIR (so freeze-gate hook knows which doc is active for this run).
7. **Begin Phase E1 Execute.**

**Backwards compat for freeze doc format:** v4 freeze docs are readable by v5 `/implement` (v5 schema is a superset; new optional sections like §10 default to empty).

## §6 Migration

**Plugin version: v4.2.0 → v5.0.0** (breaking — `/implement` invocation signature changes).

**Files to add:**

| File | Purpose |
|---|---|
| `agents/research-investigator.md` | New universal Research agent |
| `skills/spike/references/templates/RESEARCH_DOC_TEMPLATE.md` | research-{ticket}.md template |
| `skills/spike/references/templates/FREEZE_DOC_TEMPLATE.md` | (moved from implement; spike now owns) |
| `skills/spike/references/protocols/research-dispatch.md` | Spike → Research agent fan-out protocol |
| `skills/spike/references/guardrails.md` | Inline-injected global guardrails |
| `phases/spike/p1-scope.yaml … p7-retro.yaml` | New spike phase YAML |
| `phases/implement/e1-execute.yaml … e3-finalize.yaml` | Renamed from phase-5/6/7 |

**Files to rewrite (major):**

| File | Change |
|---|---|
| `skills/spike/SKILL.md` | Phase 0 removed. Mode routing (epic/story/research). Research dispatch. P1-P7. |
| `skills/implement/SKILL.md` | Phase 1-4 removed. E1-E3 only. Freeze-doc-path required at invocation. |
| `commands/spike.md` | Mode parsing |
| `commands/implement.md` | Validate freeze-doc-path arg |
| `plugins/dev-framework/CLAUDE.md` | Workflows table, phase tables, version |

**Files to remove or relocate:**

| File | Disposition |
|---|---|
| `phases/phase-1.yaml` (Requirements) | Content → `phases/spike/p1-scope.yaml` |
| `phases/phase-2.yaml` (Research) | Content → `phases/spike/p2-investigate.yaml` |
| `phases/phase-3.yaml` (Plan + Freeze) | Content → `phases/spike/p4-spec.yaml` (Epic adds p3-decompose.yaml separately) |
| `phases/phase-4.yaml` (Test Planning) | Content folded into `phases/spike/p4-spec.yaml` (test-strategist invocation) |
| `phases/phase-5.yaml` (Implementation + L1) | Renamed → `phases/implement/e1-execute.yaml` |
| `phases/phase-6.yaml` (Verification + L2) | Renamed → `phases/implement/e2-verify.yaml` |
| `phases/phase-7.yaml` (Docs + GATE 2) | Renamed → `phases/implement/e3-finalize.yaml` |
| `skills/implement/references/templates/FREEZE_DOC_TEMPLATE.md` | Moved to spike |
| `skills/implement/references/templates/FEATURE_SPEC_TEMPLATE.md` | Absorbed by spike P1 |
| `skills/implement/references/methodology/DECISION_MAKING.md` | Shared by spike (move or symlink) |
| `skills/implement/references/protocols/test-planning.md` | Used by spike P4 |

Spike P5 (Review), P6 (Approve), P7 (Retro) are new; no old phase YAML maps to them. Their content draws from existing multi-agent-consensus protocol (P5), human-signoff pattern (P6 — currently inline in spike SKILL.md), and design-mistake-tracker protocol (P7 — currently `skills/spike/references/autonomous/mistake-tracker-protocol.md`).

**Agent ownership:**

| Agent | Old owner | New owner |
|---|---|---|
| requirements-analyst | implement Phase 1 | spike P1 |
| architect | implement Phase 2 | spike P2 |
| test-strategist | implement Phase 4 | spike P4 |
| code-quality-reviewer | implement P5/P6 review | implement E1/E2 review (unchanged) |
| observability-reviewer | unchanged | unchanged |
| performance-reviewer | unchanged | unchanged |
| **research-investigator** (new) | — | spike P2 (dispatched as needed) |

**New event types:**

| Event | Emit point |
|---|---|
| `spike.mode.detected` | Pre-Workflow after mode resolves |
| `research.dispatched` | Parent fan-outs Research agent |
| `research.findings.captured` | Agent intermediate (long runs) |
| `research.completed` | Agent end |
| `research.redispatched` | Parent re-dispatches Research agent on resume after detected crash |
| `ticket.research.completed` | Parent reducer (unblocks Stories) |
| `freeze.doc.approved` | Spike P6 GATE 1 (Story mode / Epic-Story-child) |
| `research.doc.approved` | Spike P6 GATE 1 (Research mode / Epic-Research-child) |

**In-flight session policy:** v4 → v5 upgrade replaces plugin files; in-flight v4 pipelines that depend on removed scripts/templates will break. **Recommendation: finish or abandon all in-flight v4 pipelines before upgrading.** Framework provides no compat-layer for v4 phase YAMLs (phase-1..4) post-upgrade. SESSION_DIR contents (events.jsonl, views/) remain readable but cannot be resumed under v5 if their phase falls in the removed range.

## §7 Open questions (defer to writing-plans)

| Q | Provisional answer |
|---|---|
| Standalone Story spike SESSION_DIR key | `epic-{ticket-id}` or `standalone-{ticket-id}` — pick one in writing-plans |
| Concurrent Research agents writing to events.jsonl | Existing seq-counter mkdir-lock is atomic; verify under stress |
| Does `AskUserQuestion` reach parent UI from a fan-out child session | Verify; if not, child escalates via user-message |
| Spike P7 retro trigger by mode | Epic: when all Story children merged (existing pattern). Standalone Story: when that single ticket merges. Standalone Research / Research-only epic: no merge event ever — P7 deferred entirely. |
| `review-backlog.md` path under standalone modes | `docs/plan/{ticket-id}/review-backlog.md` (uniform) |
| Mistake-tracker scope for Research agent patterns | Track under `patterns/research/` namespace |
| TDD test scaffold ownership | Spike P4 writes test plan; implement E1 writes the actual test code (TDD red phase) |
| Active freeze doc disambiguation for freeze-gate hook | Epic with N Story freeze docs → which is active during a given /implement run? Provisional: /implement writes `active-freeze-doc.txt` pointer in session folder at startup; hook reads pointer instead of scanning. Verify hook logic delta |
| /implement session model under Epic-mode parent | Option A: /implement uses parent epic SESSION_DIR (single shared events.jsonl). Option B: spawns child session per Story (events bubble up). A is simpler; B is more MA-aligned. Pick in writing-plans |

## §8 Risks

| Risk | Mitigation |
|---|---|
| 7-phase spike contradicts v2.0 lean intent | Phase count by mode: Epic = 6 sync + 1 async (full path with P3 Decompose + P5 Review); Story = 5 sync + 1 async (skips P3); Research = 4 sync + 1 async (skips P3 and P5). Only Epic walks the full path; Story and Research are leaner. |
| Standalone Story spike feels like ceremony for trivial PRs | Trivial cases produce a near-empty freeze doc; framework does not force depth |
| Global guardrails inject bloats Research agent prompt | Reference-by-link (`See: skills/spike/references/guardrails.md`) instead of inline |
| Doc-only confidence tagging is subjective | Rubric in system prompt: `verified-empirically` requires the agent itself ran the call/script |
| This refactor's own scope is large | Use v4.2 framework as a multi-ticket spike to land v5.0 (eat-own-dogfood) |

## §9 Next steps

1. User reviews this spec.
2. `superpowers:writing-plans` → produces implementation plan.
3. (Optional) Run that plan as the first epic processed under the new spike v3 (boot-strap cycle).
