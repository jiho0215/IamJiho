# Events Schema

Append-only event log at `$SESSION_DIR/events.jsonl`. Each line is one event.

Introduced in **M1 (Managed Agents Evolution)**. See [docs/specs/2026-04-20-managed-agents-evolution.md](../../../../../../docs/specs/2026-04-20-managed-agents-evolution.md) for motivation.

## Event envelope

Every event has:

| Field | Type | Description |
|---|---|---|
| `seq` | int | Monotonically increasing per session. Assigned atomically by `emit-event.sh`. |
| `at` | string | ISO-8601 UTC timestamp (e.g. `2026-04-20T10:30:00Z`). |
| `runId` | string | Pipeline run identifier. Empty string if emitted before progress-log.json exists. |
| `actor` | string | Who emitted. Examples: `orchestrator`, `agent:code-quality-reviewer`, `hook:freeze-gate`, `skill:superpowers:brainstorming`, `user`. |
| `type` | string | Dot-separated event type. See catalog below. |
| `data` | object | Type-specific payload. Always an object, may be `{}`. |

## Type catalog

### `phase.*` — phase lifecycle

| Type | Data | Emitted by |
|---|---|---|
| `phase.started` | `{phase: int}` | SKILL.md at Begin gate pass |
| `phase.completed` | `{phase: int, metrics?: object}` | SKILL.md at End gate pass |
| `phase.failed` | `{phase: int, error: string}` | SKILL.md in Phase Failure Protocol |
| `phase.skipped` | `{phase: int, reason: string}` | SKILL.md when Skip-to-next chosen |

### `gate.*` — gate events

| Type | Data | Emitted by |
|---|---|---|
| `gate.passed` | `{gate: "phase\|freeze\|push", detail?: object}` | phase-gate.sh, freeze-gate.sh, push-guard.sh |
| `gate.blocked` | `{gate: "phase\|freeze\|push", reason: string, detail?: object}` | same hooks |
| `gate.approved` | `{gate: 1\|2, approvalMode: "interactive\|autonomous", approvedBy: string}` | SKILL.md at GATE 1 or GATE 2 |
| `gate.rejected` | `{gate: 1\|2, reason: string, returnToPhase?: int}` | SKILL.md at GATE 1/GATE 2 rejection |

### `consensus.*` — multi-agent consensus

| Type | Data | Emitted by |
|---|---|---|
| `consensus.started` | `{phase: int, taskType: string, agents: string[]}` | SKILL.md entering consensus |
| `consensus.iteration.started` | `{phase: int, iteration: int}` | review-loop emitted by SKILL.md |
| `consensus.agent.dispatched` | `{phase: int, iteration: int, agent: string}` | SKILL.md |
| `consensus.issues.found` | `{phase: int, iteration: int, agent: string, issues: object[]}` | SKILL.md (post-agent) |
| `consensus.fix.applied` | `{phase: int, iteration: int, issueId: string, file?: string}` | SKILL.md |
| `consensus.converged` | `{phase: int, iterations: int, issuesFixed: int}` | SKILL.md |
| `consensus.forced_stop` | `{phase: int, iterations: int, remainingIssues: int}` | SKILL.md at iteration cap |

### `bypass.*` — freeze-gate bypass lifecycle

| Type | Data | Emitted by |
|---|---|---|
| `bypass.created` | `{feature: string, reason: string, userMessage: string}` | SKILL.md on bypass request |
| `bypass.preserved` | `{at: string, runId: string, preservedAt: string}` | sessionend.sh |
| `bypass.archived` | `{count: int}` | SKILL.md at GATE 2 (freeze doc bypassHistory merge) |

### `tool.call.*` — dispatched tool invocations (M3+)

Emitted by `execute.sh` wrapper (introduced in M3). Not emitted in M1.

| Type | Data |
|---|---|
| `tool.call.started` | `{kind: string, name: string, inputHash: string}` |
| `tool.call.completed` | `{kind: string, name: string, durationMs: int, outputSummary?: string}` |
| `tool.call.failed` | `{kind: string, name: string, failureSource: string, error: string}` |

### `reference.*` — lazy reference loading (M3+)

Emitted when dispatcher loads a reference file. Not emitted in M1.

| Type | Data |
|---|---|
| `reference.loaded` | `{path: string, phase: int}` |

### `artifact.*` — file changes (M2+)

Optional post-tool-use hook. Not emitted in M1.

### `session.*` — session lifecycle

| Type | Data | Emitted by |
|---|---|---|
| `session.started` | `{mode: string, featureSlug?: string, ticket?: string}` | SKILL.md Pre-Workflow |
| `session.interrupted` | `{interruptedAt: string, currentPhase: int}` | sessionend.sh |
| `session.resumed` | `{fromPhase: int, fromSeq: int}` | SKILL.md --from handler |
| `session.precompact` | `{reason: string}` | precompact.sh |
| `session.completed` | `{totalMinutes: number}` | SKILL.md at GATE 2 |

### `decision.*` — user or orchestrator decisions

Alongside the existing decision-log.json (dual-write in M1).

| Type | Data |
|---|---|
| `decision.recorded` | `{id: string, phase: int, category: string, decision: string, reason: string, confidence: string}` |

### `config.*` — configuration snapshot (M2.5+)

| Type | Data | Emitted by |
|---|---|---|
| `config.snapshot.recorded` | `{maxReviewIterations, consecutiveZerosToExit, testCoverageTarget, modelProfile, skills?: object, agents?: object}` | SKILL.md Pre-Workflow (after ensure-config) |

Captures the effective config at session start so event-log retrospection can compare quality across config profiles without needing to fetch config.json separately.

### `plan.*` — plan artifacts (M2.5+)

| Type | Data | Emitted by |
|---|---|---|
| `plan.files.set` | `{phase: int, plannedFiles: string[]}` | SKILL.md Phase 3 completion |

Records which files the implementation plan intends to touch. Populates `views/progress-log.json.plannedFiles` for full parity with the procedural write.

### `patterns.*` — chronic pattern lifecycle (M2.5+)

| Type | Data | Emitted by |
|---|---|---|
| `patterns.loaded` | `{count: int, file: string, chronicPatterns: string[]}` | `load-chronic-patterns.sh` SessionStart hook |
| `patterns.promoted` | `{id: string, pattern: string, frequency: int}` | SKILL.md Phase 7 mistake capture |
| `patterns.demoted` | `{id: string, pattern: string, reason: string}` | SKILL.md Phase 7 mistake capture |

### `spike.*` — /spike phase and retro lifecycle (v4.0+)

Session folder for `/spike` is epic-scoped: `{repo}--epic-{epicId}/`. `session.started` from `/spike` carries `epicId` instead of (or in addition to) `featureSlug`/`ticket`.

| Type | Data | Emitted by |
|---|---|---|
| `spike.started` | `{epicId: string, goal: string}` | `/spike` SKILL.md Pre-Workflow |
| `spike.phase.N.started` | `{epicId: string, phase: 1\|2\|3\|4\|5}` | `/spike` SKILL.md at Begin gate pass |
| `spike.phase.N.completed` | `{epicId: string, phase: int, metrics?: object}` | `/spike` SKILL.md at End gate pass |
| `spike.tickets.decomposed` | `{epicId: string, tickets: [{ticketId, title}]}` | `/spike` Phase 3 end |
| `spike.gate.approved` | `{epicId: string, approvedBy: string}` | `/spike` Phase 4 human signoff |
| `spike.gate.rejected` | `{epicId: string, returnToPhase: int, reason: string}` | `/spike` Phase 4 rejection |
| `spike.integration.verified` | `{epicId: string, ticketCount: int}` | cross-ticket integration verifier (after all tickets merged) |
| `spike.retro.completed` | `{epicId: string, patternsPromoted: int, patternsDemoted: int}` | `/spike` Phase 5 retro end |

### `ticket.*` — ticket decomposition and lifecycle (v4.0+)

Emitted by both `/spike` (decomposition) and `/implement` (impl progress). All carry `epicId` + `ticketId` so reducers can key state by either dimension.

| Type | Data | Emitted by |
|---|---|---|
| `ticket.decomposed` | `{epicId, ticketId, title, implBlockedBy: [{ticketId, kind, reason}], deployBlockedBy: [{ticketId, kind, reason}]}` | `/spike` Phase 3 per-iteration |
| `ticket.started` | `{epicId, ticketId, branch: string}` | `/implement` Phase 0 success |
| `ticket.discovery` | `{epicId, ticketId, section: string, correction: string}` | `/implement` on spike-plan / ref-doc error discovery |
| `ticket.merged` | `{epicId, ticketId, prUrl?: string}` | `/implement` Phase 7 GATE 2 approval option [1] or [3] |

**Re-emit semantics for `ticket.decomposed`:** if the same `ticketId` is decomposed a second time (e.g., Phase 4 gap-review correction reclassifies a blocker), the later event supersedes the earlier one in the reducer's view. Events themselves are still append-only; the reducer picks the latest.

**Cross-skill reducer consumers:**
- `reduce-spike-plan.sh` — reads `ticket.decomposed`, `ticket.started`, `ticket.merged` to regenerate `docs/plan/{epicId}/spike-plan.md` §7 registry.
- `reduce-ticket-doc.sh` — reads per-ticket phase/consensus/gate events to regenerate `docs/plan/{epicId}/{ticketId}.md` §6 impl log + frontmatter `.status`.

## Invariants

1. **Monotonic seq.** Within a session, `seq` strictly increases. Concurrent writes serialized by mkdir lock on `.seq.lock`.
2. **Append-only.** Never rewrite `events.jsonl`. Regenerated views live in `$SESSION_DIR/views/` (M2+).
3. **No PII in `data`.** Never include credentials, tokens, or full secret payloads.
4. **Stability.** Once deployed, an event type's schema may only extend (add optional fields). Breaking changes require a new type name.

## Query examples

```bash
# All phase transitions for current session
bash hooks/scripts/get-events.sh --type 'phase.*'

# Where did we block freeze-gate?
bash hooks/scripts/get-events.sh --type gate.blocked --format summary

# Consensus performance in Phase 5
bash hooks/scripts/get-events.sh --type consensus.iteration.started --phase 5 --format count

# Events since last known seq (for wake() in M2+)
bash hooks/scripts/get-events.sh --since-seq 42
```

## Emit examples

```bash
# Simple phase transition
bash hooks/scripts/emit-event.sh phase.started \
  --actor orchestrator \
  --data '{"phase":1}'

# Gate block with detail
bash hooks/scripts/emit-event.sh gate.blocked \
  --actor "hook:freeze-gate" \
  --data "$(jq -cn --arg reason "branch mismatch" --arg path "src/auth.ts" \
    '{gate:"freeze",reason:$reason,path:$path}')"

# With explicit runId override (rare; normally auto-pulled from progress-log)
bash hooks/scripts/emit-event.sh session.started \
  --actor orchestrator \
  --run-id "run-2026-04-20T10-30-00-abcd" \
  --data '{"mode":"full-cycle"}'
```
