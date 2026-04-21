---
title: Managed Agents Evolution — dev-framework architectural pivot
date: 2026-04-20
status: accepted
author: Jiho Lee
supersedes: none
superseded_by: none
---

# Managed Agents Evolution

> "Harnesses encode assumptions about what Claude can't do on its own."
> — Anthropic, *Managed Agents* (engineering blog, 2026)

## 1. Context

The dev-framework plugin is a rigorous, multi-agent development workflow whose behavior lives primarily in **prose** — `SKILL.md` is a 579-line procedural specification that Claude executes turn-by-turn. State is distributed across several JSON and JSONL files in a per-branch session folder. Hooks enforce physical boundaries (freeze gate, push guard, phase gate).

This design served us well through v1.0 and v2.0, but Anthropic's Managed Agents work reveals a structural ceiling:

1. **Brain-state coupling**: Workflow state lives in Claude's working memory mid-phase. A session crash forces phase-level restart (not event-level).
2. **Scattered state**: `progress-log.json`, `decision-log.json`, `pipeline-issues.json`, and various JSONLs hold *snapshots*, not an event sequence. Retrospective audit is hard ("when exactly did we first hit the iteration cap?").
3. **Hardcoded model assumptions**: `maxReviewIterations: 10`, `consecutiveZerosToExit: 2`, `agents: 3`, "one question at a time" all assume the model cannot self-pace. As models improve, these become dead weight — the same trajectory Anthropic observed with Sonnet 4.5 context anxiety.
4. **Upfront reference loading**: 13 reference files loaded at phase start regardless of need.
5. **Non-standardized dispatch**: Task/Skill/Bash/self-execute each have different calling conventions. Failure classification requires human inspection.

Managed Agents solves the analogous problem by **decoupling Brain (Claude + harness), Hands (execution environments), and Session (durable event log)**, linked by four minimal interfaces: `execute(name, input) → string`, `wake(sessionId)`, `getSession(id)`, `emitEvent(id, event)`.

We adopt the same pivot, adapted to a Claude Code plugin runtime.

## 2. Decision

**Elevate the session to an append-only event log, with all current state files becoming derived projections. Reduce `SKILL.md` from procedural prose to a stateless dispatcher that reads phase specs (YAML data) and emits events via a uniform `execute()` primitive.**

This single pivot is the enabler for seven downstream improvements:

- Stateless harness (Claude's turn-boundary context is reconstructable from events)
- Cattle-not-pets sessions (delete session folder → replay events to rebuild state)
- Replay/rewind at event granularity (not phase granularity)
- Lazy provisioning (references loaded per-phase via YAML declaration)
- Standardized tool dispatch (single `execute()` wrapper auto-emits events)
- Multi-brain scaling (parallel phases in worktrees fan-in to shared event log)
- Dead-weight audit (event log becomes query surface for retrospective analysis)

## 3. Design

### 3.1 Core primitive — `events.jsonl`

A single append-only JSON-lines file per session, located at `$SESSION_DIR/events.jsonl`.

Event schema:

```jsonl
{"seq":1,"at":"2026-04-20T10:30:00Z","runId":"run-...","actor":"orchestrator","type":"phase.started","data":{"phase":1}}
{"seq":2,"at":"2026-04-20T10:30:02Z","runId":"run-...","actor":"agent:architect","type":"consensus.issue.found","data":{"phase":5,"iteration":2,"severity":"HIGH","description":"..."}}
```

Required fields: `seq` (monotonically increasing integer), `at` (ISO-8601 UTC), `runId`, `actor`, `type`, `data`.

**Event type naming**: dot-separated, hierarchical. `<domain>.<subject>.<verb>` or `<domain>.<verb>`. Domains:
- `phase.*` — phase lifecycle (started, completed, failed)
- `gate.*` — freeze/push/phase gate events (blocked, passed, approved, rejected)
- `consensus.*` — multi-agent consensus iterations
- `bypass.*` — freeze-gate bypass lifecycle
- `tool.call.*` — dispatched tool invocations (via `execute()`)
- `reference.*` — lazy reference loading
- `artifact.*` — file modifications visible to the orchestrator
- `session.*` — session lifecycle (started, interrupted, resumed, completed)
- `decision.*` — user or orchestrator decisions

### 3.2 Three shell primitives

| Script | Purpose |
|---|---|
| `emit-event.sh <type> [--data JSON] [--actor ACTOR]` | Append one event with atomic seq assignment |
| `get-events.sh [--type ...] [--since-seq N] [--format json\|summary\|count]` | Query events (jq-backed filter) |
| `wake.sh` | Return `{currentPhase, lastSeq, nextAction, minimumContext}` for stateless restart |

These three plus an optional `replay.sh` and `fork.sh` (rewind/branch) give us the Managed Agents interface surface adapted to a local filesystem.

### 3.3 Views as projections

Existing state files (`progress-log.json`, `decision-log.json`, `pipeline-issues.json`) become **derived views** regenerated from `events.jsonl` by reducer scripts. During M1-M2 they are dual-written (event log + existing writes) for safety; M3 switches reads to views-regenerated-from-events.

```
SESSION_DIR/
├── events.jsonl            source of truth
├── .seq                    atomic counter for last emitted seq
├── views/                  regenerable from events.jsonl
│   ├── progress-log.json
│   ├── decision-log.json
│   └── pipeline-issues.json
├── snapshots/              periodic dumps for fast wake() (optional, M2+)
└── artifacts/              freeze-doc, tdd-plan, etc. (non-event outputs)
```

### 3.4 Phase specs as data

`SKILL.md` Sections B (7-phase full cycle) become YAML declarations in `phases/phase-1.yaml`...`phase-7.yaml`:

```yaml
phase: 5
name: "Implementation + Layer 1 Review"
preconditions:
  - event: gate.approved
    filter: {gate: 1}
requiredRefs:
  - standards/RESULT_PATTERN.md
  - autonomous/review-loop-protocol.md
  - protocols/multi-agent-consensus.md
dispatchChain:
  - type: skill
    name: "${config.pipeline.skills.implementation}"
  - type: protocol
    name: review-loop-protocol
postconditions:
  - event: consensus.converged
budget: { seconds: 900 }
```

The dispatcher reads the YAML, loads only the declared references (lazy), executes the `dispatchChain` via `execute()`, and emits events at each step.

### 3.5 Stateless dispatcher loop

New `SKILL.md` (target ~100 lines):

```
1. wake.sh → {currentPhase, nextAction}
2. read phases/phase-${currentPhase}.yaml
3. load only requiredRefs
4. for step in dispatchChain: execute(step.type, step.name, step.input)
5. emit step.completed after each
6. emit phase.completed when dispatchChain drains
7. exit → next invocation wakes at next phase
```

Claude's working memory holds only the current phase's slice. Cross-turn continuity lives in `events.jsonl`.

### 3.6 Uniform tool dispatch

```bash
bash execute.sh <kind> <name> --input '{...}'
# kind ∈ {agent, skill, protocol, hook, tool}
```

Emits `tool.call.started`, `tool.call.completed` (or `.failed`) events automatically. Failure classification via `failureSource` field in event data: `hook|skill-not-found|agent-error|timeout|tool-error`.

### 3.7 Model-profile config

```jsonc
{
  "pipeline": {
    "modelProfile": "balanced",  // "conservative" | "balanced" | "trust-model"
    "maxReviewIterations": 10,   // null → model declares convergence
    "agents": { "review": 3 }    // "auto" → 1 for frontier, 3 otherwise
  }
}
```

A/B validation via cross-run event log queries.

### 3.8 Multi-brain via worktrees

Phase YAMLs may declare `dependencies: [phase-N]` and `parallel: true`. The orchestrator provisions a git worktree per independent phase and spawns a Claude instance (via Task tool) in each. Shared `events.jsonl` coordinates via mkdir-based lock.

## 4. Scorecard — current vs. target

| Principle | Current | Target | Mechanism |
|---|---|---|---|
| Durable external state | 7 | **9** | events.jsonl + snapshots |
| Stateless harness | 2 | **8** | wake() + dispatcher loop |
| Cattle-not-pets | 5 | **8** | events-based restore |
| Lazy provisioning | 3 | **8** | phase YAML requiredRefs |
| Standard tool interface | 4 | **9** | execute() wrapper |
| Replay / rewind | 3 | **9** | event-seq replay + fork |
| Multi-brain scaling | 1 | **8** | worktree + intra-phase agents |
| Dead-weight audit | 4 | **9** | event query + modelProfile |
| **Total** | **29 / 80** | **68 / 80** | |

## 5. Consequences

### 5.1 Positive

- Event-level crash recovery replaces phase-level restart
- Harness self-observability enables data-driven parameter tuning (no more guessing at `maxReviewIterations`)
- Future model capabilities absorbed via config profile (no prompt surgery)
- Phase boundaries become testable in isolation (phase YAML + dispatcher)
- Debugging opacity reduced: every failure has a structured event

### 5.2 Negative / risks

- **Prose → data migration risk**: `SKILL.md` currently encodes domain knowledge in natural language; extracting to YAML may lose nuance. Mitigation: per-phase parallel-run validation before switching reads.
- **Concurrency complexity**: multi-brain fan-in requires robust locking. Mitigation: mkdir-based locks are NTFS-safe and well-understood.
- **jq dependency hardened**: event log queries require jq. Already implicit but becomes load-bearing.
- **Event schema evolution**: changing event types breaks historical queries. Mitigation: append-only schema with `data.version` field when needed; never rename types, only deprecate + add new.

### 5.3 Backward compatibility

M1 and M2 are strictly additive — all existing behavior preserved, events written alongside current state. M3 switches reads but retains state files as views for inspection. M4 is opt-in (disabled by default).

## 6. Migration roadmap

| Milestone | Goal | Risk | Estimated effort |
|---|---|---|---|
| **M1 — Event Log Dual-Write** | Add `events.jsonl` + emit/get primitives; wire emit into existing hooks and phase transitions. Existing files untouched. | Very low | 1-2 days |
| **M2 — Views as Projections** | Build view reducers; introduce `wake.sh`; verify byte-equality between regenerated views and existing state files across representative runs. | Low | 3-5 days |
| **M3 — Phase YAML + Dispatcher** | Extract phases to YAML; rewrite SKILL.md as dispatcher; introduce `execute()` wrapper; expose `modelProfile` config (no-op default). | Moderate | 1-2 weeks |
| **M4 — Multi-brain orchestration** | Worktree fan-out for independent phases; concurrency verification. Opt-in via `parallel: true` in phase YAML. | High (concurrency) | 1 week |

### 6.1 Migration safety — Parallel Change

All milestones follow **Expand-Contract**:

1. **Expand**: add new path (event emit, view regeneration, dispatcher loop) alongside existing path
2. **Validate**: run both in parallel; byte-diff outputs or event-equivalence checks
3. **Contract**: switch reads to new path; existing path becomes deprecated (but retained) for one more version
4. **Remove**: delete deprecated path after a clean cycle

This matches production DB migration discipline. The harness is production software.

## 7. Success metrics

We declare each milestone successful when:

**M1**: Every current state transition (phase start/end, gate pass/block, bypass create, session interrupt) also appears as an event in `events.jsonl`. `get-events.sh --type 'phase.*'` returns a coherent phase history for any completed run.

**M2**: For any test run, views regenerated from `events.jsonl` are byte-equal to the file that was originally written. `wake.sh` correctly identifies the next action for a deliberately-interrupted session.

**M3**: SKILL.md ≤ 150 lines. All phase bodies live in YAML. A test feature cycle completes end-to-end with identical external outputs (freeze doc, ADR, test plan, implementation diff) to pre-M3 runs.

**M4**: Two independent phases (e.g., parallel verification paths) complete concurrently in distinct worktrees with no event-log corruption across 10 stress runs.

## 8. Open questions

1. **Snapshot cadence** (M2): at what seq intervals to dump? Every phase end? Every 50 events? Deferred to M2 design.
2. **Event schema versioning** (M3+): do we need a `schemaVersion` field in events? Adopt opportunistically — `data.v: 2` when an event type's shape changes.
3. **Multi-brain merge semantics** (M4): if two parallel brains emit contradictory events (e.g., both claim `phase.completed` for the same phase), how to reconcile? Proposal: shared events.jsonl with mkdir lock → seq is totally ordered → contradictions become auditable, not silent.
4. **Chronic pattern sync**: mistake-tracker CLAUDE.md sync runs at Phase 7. Does this become an event (`pattern.promoted`)? Likely yes; integrate in M1.

## 9. References

- Anthropic, *Managed Agents* — https://www.anthropic.com/engineering/managed-agents
- `plugins/dev-framework/CLAUDE.md` — current plugin structure
- `plugins/dev-framework/skills/dev/SKILL.md` — current procedural spec
- `docs/specs/2026-04-19-dev-freeze-doc-design.md` — freeze doc design (related prior work)
- Fowler, *Parallel Change* — migration pattern
