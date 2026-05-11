# Dev Framework Plugin

**v5.0.0** \u2014 AI-led, end-to-end software development plugin built on the **Managed Agents** architecture. v5 cleanly splits engineering work into two skills:

- **`/spike`** \u2014 the universal planning skill. Modes: **Epic** (multi-ticket decomposition), **Story** (single freeze doc), **Research** (investigation only).
- **`/implement`** \u2014 pure execution. Reads an **APPROVED** freeze doc produced by `/spike` and runs E1 Execute \u2192 E2 Verify \u2192 E3 Finalize.

Both skills share one epic-scoped event log; freeze docs are hash-locked contracts between them. Seq-level replay, stateless restart, multi-brain fan-out.

> **v4 \u2192 v5 breaking change.** `/implement` now requires an APPROVED freeze doc path as its argument; all requirements / research / planning moved into `/spike`. See [docs/specs/2026-05-09-spike-as-planning-skill.md](../../docs/specs/2026-05-09-spike-as-planning-skill.md) for design rationale.

## At a glance

```
/spike <epic description>                   Epic mode \u2014 multi-ticket research + decomposition
/spike story <ticket>                       Story mode \u2014 single-ticket planning \u2192 freeze doc
/spike research <topic>                     Research mode \u2014 standalone investigation
/spike --revisit <freeze-or-research-doc>   Re-open an APPROVED doc for amendment
/spike --retro EPIC-ID                      Post-merge design-pattern retro

/implement <freeze-doc-path>                Pure execution against APPROVED freeze doc
/implement --from N <freeze-doc-path>       Resume at E<N> (1=E1, 2=E2, 3=E3)
/implement --status <freeze-doc-path>       Status print
```

`/implement` v5 \u2014 **pure execution**, 3 phases (E1\u2013E3), 1 user gate (GATE 2):

```
[Startup: parse freeze doc \u2192 verify status=APPROVED \u2192 verify approvedHash \u2192 resolve SESSION_DIR
         \u2192 verify \u00a711 Prerequisites \u2192 write active-freeze-doc.txt pointer \u2192 begin E1]
E1 Execute          (TDD against freeze doc plan; freeze-gate hook enforces hash + prereqs on src/** edits)
E2 Verify           (full test suite + Layer 1 / Layer 2 multi-agent consensus reviews)
E3 Finalize         (docs + PR + mistake capture \u2192 \ud83d\udeaa GATE 2)
[push-guard hook \u2014 blocks git push until GATE 2 approved]
```

`/spike` v5 \u2014 **universal planning**, 7 phases (P1\u2013P7); mode dictates depth:

```
P1. Scope            (mode detection; epic/story/research routing)
P2. Investigate      (dispatch research-investigator agents; capture findings + Doc-vs-Reality)
P3. Decompose        (Epic only \u2014 break into tickets with DAG ordering)
P4. Spec             (author freeze doc \u00a71\u2013\u00a711 OR research doc; compute approvedHash)
P5. Review           (multi-agent consensus, severity-gated \u2014 Critical/Major block; Minor/Nit \u2192 backlog)
P6. Approve          (GATE 1 \u2014 user approval; status: APPROVED + approvedHash sealed)
P7. Retro            (async; design-pattern capture after all merges)
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

Each phase's metadata (requiredRefs, emits, invokes, produces, gates, budget, **instructions checklist**) lives in `phases/{spike,implement}/<phase-id>.yaml`. SKILL.md contains narrative prose. The dispatcher preamble reads both: YAML answers *what to do now*; SKILL.md answers *why and how to think about it*.

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
│   └── plugin.json               Manifest (v5.0.0)
├── commands/
│   ├── spike.md                  Routes to spike skill (universal planning)
│   ├── implement.md              Routes to implement skill (pure execution; freeze-doc-path required)
│   └── testbuilder.md            Routes to testbuilder skill (standalone testing)
├── agents/                       Shared review/plan agents + research-investigator
├── phases/                       Phase YAML metadata, split by skill (v5)
│   ├── README.md                         schema spec
│   ├── spike/p1-scope..p7-retro.yaml     /spike phase metadata
│   └── implement/e1-execute..e3-finalize.yaml  /implement phase metadata
├── hooks/
│   ├── hooks.json
│   └── scripts/                  v1 hooks + M1-M4 primitives + v5 freeze-doc-hash/prereqs
└── skills/
    ├── spike/                    Universal planning (epic / story / research / --revisit)
    │   ├── SKILL.md              Orchestrator narrative (P1–P7)
    │   └── references/           guardrails / templates / protocols / autonomous
    ├── implement/                Pure execution (E1 Execute / E2 Verify / E3 Finalize)
    │   ├── SKILL.md              Orchestrator narrative (E1–E3 + 7-step startup)
    │   └── references/           methodology / standards / templates / protocols / autonomous
    └── testbuilder/              Standalone testing workflow
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
- **v5.0** \u2014 **Planning vs. execution split.** `/spike` becomes the universal planning skill (Epic / Story / Research / `--revisit` modes). `/implement` becomes pure execution against an APPROVED, hash-locked freeze doc (E1 Execute / E2 Verify / E3 Finalize). Freeze docs carry `approvedHash` (sha256 over canonical body) + `\u00a711 Prerequisites` (DAG-derived); `freeze-gate.sh` verifies both on every src/** edit. See [docs/specs/2026-05-09-spike-as-planning-skill.md](../../docs/specs/2026-05-09-spike-as-planning-skill.md).

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
