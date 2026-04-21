# Dev Framework Plugin

**v4.0.0** \u2014 AI-led, end-to-end development framework built on **Managed Agents** architecture. Two skills for the two shapes of engineering work: `/spike` (multi-ticket research and decomposition) and `/implement` (single-ticket rigorous execution). Both share one epic-scoped event log. Seq-level replay, stateless restart, multi-brain fan-out.

> **v3 \u2192 v4 breaking change.** The `/dev` command is retired in favor of `/implement` (single-ticket) and `/spike` (multi-ticket research). A one-version tombstone at `/dev` informs users of the rename. See [docs/specs/2026-04-21-spike-implement-split.md](../../docs/specs/2026-04-21-spike-implement-split.md) for design rationale.

## At a glance

```
/spike [epic description]                   Research spike \u2014 decompose into N tickets
/spike --retro EPIC-ID                      Post-merge design-pattern retro

/implement [ticket-or-feature]              Single-ticket implementation (interactive)
/implement --autonomous TICKET-123          Single-ticket implementation (autonomous)
/implement --from N                         Resume at phase N
/implement --status                         Show session status
/implement init | review | test | docs      Standalone workflows
```

`/implement` full cycle: **7 phases (plus Phase 0 prereq check for spike-sourced tickets), 2 user gates, multi-agent consensus at every step.**

```
0. Prereq check           (spike-sourced only; reads ticket ref doc, enforces hard blockers)
1. Requirements           (populates freeze doc \u00a71, \u00a75, \u00a76)
2. Research               (populates freeze doc \u00a72-\u00a74, \u00a77, \u00a78)
3. Plan + Freeze Doc   \u2192  \ud83d\udeaa GATE 1
[freeze-gate hook ACTIVE \u2014 src/** edits blocked unless freeze doc APPROVED]
4. Test Planning
5. Implementation + Layer 1 Review  (multi-agent consensus, 10 max / 2 zero)
6. Verification + Layer 2 Review
7. Documentation + PR + bi-dir plan update + Mistake Capture \u2192  \ud83d\udeaa GATE 2
[push-guard hook \u2014 blocks git push until GATE 2 approved]
```

`/spike` 5-phase workflow:

```
1. Requirements review      (multi-feature; NFR + rollout/rollback)
2. System design            (epic architecture + observability + API contracts + migration chain)
3. Ticket decomposition     (one-at-a-time; hard/soft impl and deploy blockers)
4. Cross-ticket gap review  (multi-agent consensus) \u2192 human signoff
5. Retro (async)            (fires when all spike tickets reach merged)
```

## Why this plugin

Building quality software requires more than writing code:

- **Understand requirements** before designing (Phase 1)
- **Design architecture deliberately** before implementing (Phase 2)
- **Get user approval** before committing to a plan (GATE 1)
- **Enforce quality with multiple independent reviewers** (Phases 5-6 consensus loops)
- **Document decisions** as first-class artifacts (freeze doc, ADRs, event log)
- **Learn from mistakes across runs** (chronic-pattern tracker)

Every phase runs 3+ specialized agents in parallel and converges through discussion rounds until zero issues remain.

## Architecture — Managed Agents

v3.0 adopts Anthropic's [Managed Agents](https://www.anthropic.com/engineering/managed-agents) pivot: **Brain (Claude + orchestrator) / Hands (hooks + skills) / Session (event log) are decoupled**, linked by minimal primitives.

### Session as event log

Every state transition dual-writes to `$SESSION_DIR/events.jsonl`:

```jsonl
{"seq":1,"at":"...","runId":"...","actor":"orchestrator","type":"phase.started","data":{"phase":1}}
{"seq":2,"at":"...","actor":"hook:phase-gate","type":"gate.passed","data":{"gate":"phase","phase":1,"action":"begin"}}
```

17 event type families covering phases, gates, consensus iterations, bypasses, tool calls, session lifecycle, decisions, config snapshots, plan artifacts, and pattern lifecycle.

### Views as projections

The three existing state files (`progress-log.json`, `decision-log.json`, `pipeline-issues.json`) are now **derivable** from the event log via reducer scripts. Run `regenerate-views.sh` anytime to rebuild.

### Stateless restart

`wake.sh` returns compact JSON `{sessionDir, lastSeq, currentPhase, status, pendingAction, minimumContext}` — the orchestrator knows what to do next from the event log alone. `pendingAction` values like `phase.5.iteration.3.active`, `gate.1.pending`, `phase.4.ready`, `session.ready-to-resume` encode the next step from a finite-state view of the events.

### Seq-level replay

`replay.sh --until-seq N --target DIR` copies events up to `N` into an alt directory and regenerates views there. Enables "what was the state at seq 42?" queries and safe branch-at-point experimentation.

### Phase YAML + dispatcher

Each phase's metadata (requiredRefs, emits, invokes, produces, gates, budget, **instructions checklist**) lives in `phases/phase-N.yaml`. SKILL.md contains narrative prose. The dispatcher preamble reads both: YAML answers *what to do now*; SKILL.md answers *why and how to think about it*.

### Uniform tool dispatch

`execute.sh <kind> <name> --input JSON` wraps every invocation (hook, protocol, skill, agent) with automatic `tool.call.started` / `completed` / `failed` events. Single calling convention, unified audit trail.

### modelProfile config

`config.pipeline.modelProfile ∈ {conservative, balanced, trust-model}` tunes iteration caps and agent counts as model capability evolves. Event-log retrospection across runs lets you measure quality per profile.

### Multi-brain fan-out

`fan-out.sh --name N [--share-events]` spawns a child session (inheriting parent `runId`), optionally sharing the event log via symlink. Concurrency-safe up to 50+ parallel writers (mkdir-lock). Enables worktree-based side-workflow exploration.

## Installation

Add to your global Claude settings:

```json
// ~/.claude/settings.json
{
  "plugins": ["path/to/dev-framework"]
}
```

Or per-project:

```json
// .claude/settings.json
{
  "plugins": ["path/to/dev-framework"]
}
```

**Runtime requirements:** `bash`, `jq`, `git`. Standard POSIX tools. No additional dependencies.

## Commands: `/spike` and `/implement`

**`/implement`** launches the single-ticket implementation workflow. Auto-detects which mode based on context.

| Context | Workflow |
|---|---|
| Empty project directory | `init` \u2014 scaffolds structure + CLAUDE.md + ADR-001 |
| Ticket ref doc present under `docs/plan/{epic}/{ticket}.md` | `full cycle` with Phase 0 prereq check (spike-sourced) |
| Feature/task description (no ref doc) | `full cycle` \u2014 7 phases (ad-hoc; synthesizes `epicId = ad-hoc-{branch}`) |
| `review` keyword | Standalone review (3 agents, code quality) |
| `test` keyword | Testing strategy analysis and gap identification |
| `docs` keyword | Documentation maintenance and ADR updates |

**`/spike`** launches the research spike workflow. Input is an epic ID/slug + goal; output is `docs/plan/{epic}/spike-plan.md` + N per-ticket ref docs committed to the consuming repo. See the [design spec](../../docs/specs/2026-04-21-spike-implement-split.md) for the full phase contract.

## Agents (6 specialized)

| Agent | Perspective |
|---|---|
| `requirements-analyst` | Use cases, edge cases, user stories, acceptance criteria |
| `architect` | System design, component boundaries, data flow, dependencies |
| `test-strategist` | Coverage, test types, risk areas, edge cases |
| `code-quality-reviewer` | Result pattern, early exit, file size, naming, single responsibility |
| `observability-reviewer` | Structured logging, tracing, metrics, correlation IDs |
| `performance-reviewer` | Time complexity, memory, N+1 queries, bundle size |

## Standards enforced

- **Result\<T\> pattern** — uniform responses for fallible operations
- **Early exit / guard clauses** — clean control flow
- **90%+ branch coverage** — Unit + Integration + Smoke + E2E (all 4 layers)
- **File size limits** — files < 200 lines, functions < 30 lines
- **Structured logging** — correlation IDs, contextual metadata
- **Performance budgets** — measurable targets per project

## Plugin structure

```
plugins/dev-framework/
├── CLAUDE.md                     Plugin structure + config docs
├── README.md                     This file
├── .claude-plugin/
│   └── plugin.json               Manifest (v3.0.0)
├── commands/
│   └── dev.md                    Only command — routes to dev skill
├── agents/                       6 review/plan agents
├── phases/                       (v3.0+) phase YAML metadata
│   ├── README.md                         schema spec
│   └── phase-1.yaml..phase-7.yaml        per-phase metadata + instructions
├── hooks/
│   ├── hooks.json
│   └── scripts/                  v1 hooks + v3 primitives (14 total)
└── skills/
    └── dev/                      The one skill
        ├── SKILL.md              Orchestrator narrative
        └── references/           methodology / standards / templates / protocols / autonomous
```

### Hook scripts (v3.0.0)

Existing hooks (v1-v2, now event-emitting):
- `ensure-config.sh`, `freeze-gate.sh`, `push-guard.sh`, `phase-gate.sh`, `phase-progress-validator.sh`, `load-chronic-patterns.sh`, `precompact.sh`, `sessionend.sh`, `test-failure-capture.sh`

New primitives (v3.0.0):
- **M1 event log:** `_session-lib.sh`, `emit-event.sh`, `get-events.sh`
- **M2 views + restart + replay:** `_reducers.sh`, `reduce-progress-log.sh`, `reduce-decision-log.sh`, `reduce-pipeline-issues.sh`, `regenerate-views.sh`, `wake.sh`, `replay.sh`
- **M3 phase YAML + dispatch:** `read-phase.sh`, `execute.sh`
- **M4 multi-brain:** `fan-out.sh`

### Reference docs (v4.0.0)

Under `skills/implement/references/autonomous/`:
- `session-management.md` \u2014 folder resolution + resume protocol (epic-scoped in v4.0+)
- `review-loop-protocol.md` \u2014 iterative consensus review
- `mistake-tracker-protocol.md` \u2014 chronic code-pattern lifecycle
- `events-schema.md` (v3.0+, extended v4.0) \u2014 event type families (+`spike.*` and `ticket.*`)
- `views-spec.md` (v3.0+) \u2014 reducer contracts
- `dispatcher-spec.md` (v3.0+) \u2014 phase YAML + dispatcher semantics
- `worktree-orchestration.md` (v3.0+) \u2014 multi-brain patterns

Under `skills/spike/references/autonomous/`:
- `mistake-tracker-protocol.md` \u2014 chronic design-pattern lifecycle (fork of code variant, applied at spike-plan level)

## User Gates

| Gate | Phase | Interactive | Autonomous | Physical artifact |
|---|---|---|---|---|
| **GATE 1** — Freeze doc approval | End of Phase 3 | User approves by category | Auto-approve with audit | Freeze doc status: APPROVED |
| **GATE 2** — Final approval | End of Phase 7 | User confirms | Always user-interactive | `pipeline-complete.md` marker |

Between gates, `freeze-gate.sh` blocks `src/**` edits. After GATE 2, `push-guard.sh` allows `git push`.

## Config

Single source of truth: `~/.claude/autodev/config.json`. Created on first `/spike` or `/implement` invocation. Override any field.

Key sections:
- `pipeline.modelProfile` (v3.0+; default `balanced`) — `conservative | balanced | trust-model`
- `pipeline.maxReviewIterations` (default 10)
- `pipeline.consecutiveZerosToExit` (default 2)
- `pipeline.testCoverageTarget` (default 90)
- `pipeline.skills.*` — per-phase skill mappings (swap in custom skills)
- `pipeline.agents.plan`, `pipeline.agents.review` — agent rosters
- `pipeline.freezeDoc.categories` — 8 default, extend for custom categories

### Model Profile

| Value | Review iterations | Review agents | Use case |
|---|---|---|---|
| `conservative` | 15 | 3 | Older / cheaper models |
| `balanced` (default) | 10 | 3 | v1/v2 baseline |
| `trust-model` | `null` (model declares) | `auto` (1 for frontier) | Opus 4.7+ class |

## Session state

Per-repo-branch folder at `~/.claude/autodev/sessions/{repo}--{branch}/`:

| File | Purpose |
|---|---|
| `events.jsonl` | **v3.0+** Append-only event stream — source of truth |
| `.seq` | Atomic counter (mkdir-lock-protected) |
| `views/` | **v3.0+** Regenerable projections |
| `progress-log.json` + `.md` | Phase timing, metrics, status |
| `decision-log.json` + `.md` | Every decision with reasons |
| `pipeline-issues.json` | Review findings per phase |
| `tdd-plan.md` | Phase 4 output |
| `pipeline-complete.md` | GATE 2 marker (authorizes push) |
| `bypass.json` / `bypass-audit.jsonl` | Freeze-gate override audit trail |

## Query the event log

```bash
# All phase transitions for current session
bash hooks/scripts/get-events.sh --type 'phase.*'

# Where did freeze-gate block?
bash hooks/scripts/get-events.sh --type gate.blocked --format summary

# What's next?
bash hooks/scripts/wake.sh | jq -r '.pendingAction'
# → "phase.5.iteration.3.active" or "gate.1.pending" or ...

# What would state look like at an earlier seq?
bash hooks/scripts/replay.sh --until-seq 42 --target /tmp/at-42
cat /tmp/at-42/views/progress-log.json | jq '.currentPhase, .status'

# Retrospective: has maxReviewIterations=10 ever been hit?
bash hooks/scripts/get-events.sh --across-runs --type consensus.forced_stop
```

## Tests

21 test suites covering all primitives:

```bash
for t in plugins/dev-framework/tests/{m1,m2,m2_5,m3,m3b,m4,e2e}/*.test.sh; do
  bash "$t" && echo "✓ $t"
done
```

## Prerequisites

External skills the default config references (all optional — phase operates inline if missing):

| Config key | Default |
|---|---|
| `pipeline.skills.requirements` | `superpowers:brainstorming` |
| `pipeline.skills.exploration` | `feature-dev:code-explorer` |
| `pipeline.skills.architect` | `feature-dev:code-architect` |
| `pipeline.skills.planning` | `superpowers:writing-plans` |
| `pipeline.skills.tdd` | `superpowers:test-driven-development` |
| `pipeline.skills.implementation` | `superpowers:subagent-driven-development` |
| `pipeline.skills.requestReview` | `superpowers:requesting-code-review` |
| `pipeline.skills.receiveReview` | `superpowers:receiving-code-review` |
| `pipeline.skills.verification` | `superpowers:verification-before-completion` |
| `pipeline.skills.finishing` | `superpowers:finishing-a-development-branch` |
| `pipeline.skills.debugging` | `superpowers:systematic-debugging` |

## Evolution notes

- **v1.0** — initial 10-phase pipeline
- **v2.0** — consolidated to 7-phase cycle with freeze-doc enforcement + 2 user gates
- **v3.0** \u2014 **Managed Agents architecture**: event log, views, wake, replay, phase YAML + instructions, uniform tool dispatch, modelProfile, multi-brain fan-out. Non-breaking for existing `/dev` behavior.
- **v4.0** \u2014 **Workflow split into `/spike` + `/implement`**; `/dev` retired. Epic-scoped session folder (MA invariant: many brains share many hands). Plan docs in-repo under `docs/plan/{epic}/` with bi-directional plan\u2194ticket reference updates via append-only events. Retro-per-skill (code patterns in `/implement`, design patterns in `/spike`). See [docs/specs/2026-04-21-spike-implement-split.md](../../docs/specs/2026-04-21-spike-implement-split.md).

See `docs/specs/2026-04-20-managed-agents-evolution.md` and the four milestone plans in `docs/plans/` for the evolution rationale and scorecard (68/80 — all 8 principles ≥8).

## Troubleshooting

### Agents take too long
Consensus rounds with 3+ agents are slow on large codebases. Expected. For simple tasks, skip `/implement` and work directly.

### Too many clarifying questions in Phase 1
Provide more detail upfront — constraints, scope boundaries, known requirements.

### Standards too strict
The `references/standards/*` files are defaults. During Init, customize budgets and coverage for your project.

### Consensus loop won't converge
Default 10 iterations with 2 consecutive zero-issue rounds. If it hits the cap, unresolved issues escalate to you automatically. Some decisions need human judgment.

## License

MIT — see [LICENSE](./LICENSE).

## Author

Jiho Lee (ianjiholee@gmail.com)
