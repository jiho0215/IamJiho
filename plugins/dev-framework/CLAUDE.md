# Dev Framework Plugin

Single-purpose plugin for AI-led, end-to-end software development. One command. One skill. One workflow.

## Core Philosophy

1. **One purpose.** AI leads development from requirement to completion. The user answers questions, discusses, confirms at two gates, and completes. Every file in this plugin exists to serve that single workflow.
2. **Move slow, do it right.** Reduce revisits and refactoring. Multi-agent consensus reviews with 10-iteration / 2-consecutive-zero convergence.
3. **Research-execution boundary is physical.** Phase 1-3 decisions are frozen in a single freeze doc artifact; src/** edits are blocked by a hook until the user approves at GATE 1; git push is blocked until GATE 2 approval.
4. **Language-agnostic.** Works with any tech stack. (Exception noted: `test-failure-capture.sh` default is `dotnet test` — override via `config.hooks.testCapture.testCommand`; tracked for correction.)
5. **Documentation as a first-class artifact.** `project-docs` protocol enforces `docs/` structure before any implementation begins.

## The Workflow

```
/dev [feature description]        Interactive full cycle (default)
/dev --autonomous TICKET-123       Autonomous full cycle
/dev --from N                      Resume at phase N
/dev --status                      Show current session status
/dev init                          Initialize a new project
/dev review                        Standalone review
/dev test                          Standalone test planning
/dev docs                          Standalone docs maintenance
```

Full cycle phases (both modes):

```
1. Requirements          (populates freeze doc §1, §5, §6)
2. Research              (populates freeze doc §2-§4, §7, §8)
3. Plan + Freeze Doc  →  🚪 GATE 1 (interactive approves; autonomous auto-approves with audit)
[freeze-gate hook ACTIVE — src/** edits blocked unless freeze doc APPROVED]
4. Test Planning
5. Implementation + Layer 1 Review (multi-agent consensus, 10 max / 2 zero)
6. Verification + Coverage Fill + Layer 2 Review (same convergence rules)
7. Documentation + Mistake Capture  →  🚪 GATE 2 (always interactive)
[push-guard hook — blocks git push until GATE 2 approved]
```

## Plugin Structure

```
plugins/dev-framework/
├── CLAUDE.md                  this file
├── README.md
├── .claude-plugin/
├── commands/
│   └── dev.md                 only command — routes to dev skill
├── agents/                    six review/plan agents (shared)
├── phases/                    (M3+) phase YAML metadata
│   ├── README.md                     schema spec
│   └── phase-1.yaml..phase-7.yaml    metadata per phase
├── hooks/
│   ├── hooks.json
│   └── scripts/
│       ├── ensure-config.sh          config bootstrap (single source of truth)
│       ├── freeze-gate.sh            block src/** edits unless freeze doc APPROVED
│       ├── push-guard.sh             block git push until GATE 2
│       ├── phase-gate.sh             phase boundary validation
│       ├── phase-progress-validator.sh  independent progress consistency check
│       ├── load-chronic-patterns.sh  SessionStart: inject mistake patterns
│       ├── precompact.sh             PreCompact: preserve pipeline state
│       ├── sessionend.sh             SessionEnd: temp cleanup + interrupted marker
│       ├── test-failure-capture.sh   audit failed test runs
│       ├── _session-lib.sh           (M1) shared session resolution helpers
│       ├── emit-event.sh             (M1) append event with atomic seq
│       ├── get-events.sh             (M1) query events.jsonl
│       ├── _reducers.sh              (M2) shared reducer helpers
│       ├── reduce-progress-log.sh    (M2) events → views/progress-log.json
│       ├── reduce-decision-log.sh    (M2) events → views/decision-log.json
│       ├── reduce-pipeline-issues.sh (M2) events → views/pipeline-issues.json
│       ├── regenerate-views.sh       (M2) orchestrate all reducers
│       ├── wake.sh                   (M2) stateless restart summary
│       ├── replay.sh                 (M2) seq-level rewind into alt dir
│       ├── read-phase.sh             (M3) YAML field reader
│       └── execute.sh                (M3) uniform tool dispatch with auto events
└── skills/
    └── dev/                   the only skill
        ├── SKILL.md
        └── references/
            ├── methodology/          DECISION_MAKING, DEVELOPMENT_CYCLE, DOCUMENTATION_STANDARDS, TESTING_STRATEGY
            ├── standards/            CODE_QUALITY, EARLY_EXIT, ERROR_HANDLING, OBSERVABILITY, PERFORMANCE, RESULT_PATTERN
            ├── templates/            ADR_TEMPLATE, CODE_REVIEW_CHECKLIST, FEATURE_SPEC_TEMPLATE, FREEZE_DOC_TEMPLATE, TEST_PLAN_TEMPLATE
            ├── protocols/            internal protocols (multi-agent-consensus, project-docs, test-planning)
            └── autonomous/           session-management, review-loop-protocol, mistake-tracker-protocol,
                                      events-schema (M1), views-spec (M2), dispatcher-spec (M3)
```

All protocol files are **internal references** read by `SKILL.md` via the Read tool. They are not discoverable as standalone skills and are not exposed to the user.

## User Gates

| Gate | Phase | Mode behavior | Physical artifact |
|---|---|---|---|
| **GATE 1** — Freeze doc approval | End of Phase 3 | Interactive: user approves by category. Autonomous: auto-approves with audit note. | Freeze doc frontmatter `status: APPROVED` + `approvedAt`/`approvedBy`/`approvalMode`. |
| **GATE 2** — Final approval | End of Phase 7 | Always user-interactive (both modes). | `pipeline-complete.md` marker in session folder + progress-log `status: completed`. |

Between the two gates, `freeze-gate.sh` blocks src/** edits; after GATE 2, `push-guard.sh` allows `git push`.

## Execution Question Zones (Phases 4-7)

Four zones govern how the LLM handles questions during execution:

| Zone | Description | Behavior |
|---|---|---|
| 🛑 Frozen | Changes a freeze-doc §1-§8 decision | HALT; request ticket update |
| ✅ Non-Frozen | In `freezeDoc.nonFrozenAllowList` (observability, railroad, pure-function-composition) | May ask user |
| 🤔 Ambiguous | Technical, not covered above | 4-tier rule: existing code → follow; reference repo → follow; initial impl → ask; else → self-decide |
| ⚙️ Self-decide | Pure technical (naming, extraction, internal boundaries) | Decide without asking |

See `skills/dev/references/templates/FREEZE_DOC_TEMPLATE.md` §9 for the full "Ask with Suggestion" format.

## Config

All configuration lives in `~/.claude/autodev/config.json` (single source of truth). Created on first `/dev` invocation via `hooks/scripts/ensure-config.sh`. Every field has a documented fallback in `skills/dev/references/autonomous/session-management.md`.

Key sections:
- `pipeline.modelProfile` (M3+; default `balanced`) — model capability profile (see below)
- `pipeline.maxReviewIterations` (default 10)
- `pipeline.consecutiveZerosToExit` (default 2)
- `pipeline.testCoverageTarget` (default 90)
- `pipeline.skills.*` — per-phase skill mappings (swap in custom skills as needed)
- `pipeline.agents.plan`, `pipeline.agents.review` — agent rosters
- `pipeline.freezeDoc.categories` — 8 categories by default; extend to add custom categories (also drop a template into `~/.claude/autodev/freeze-categories/`)
- `pipeline.freezeDoc.nonFrozenAllowList` — question-allowed list during execution

### Model Profile (M3+)

`config.pipeline.modelProfile` declares the expected model capability so the orchestrator can tune iteration counts and agent fan-out without changing per-value config:

| Value | Review iterations cap | Review agents | Notes |
|---|---|---|---|
| `conservative` | 15 | 3 | Older / cheaper models; maximum safety |
| `balanced` (default) | 10 | 3 | M1/M2 baseline |
| `trust-model` | `null` (model declares convergence) | `auto` (1 for frontier) | Opus 4.7+ class |

Profile is recorded on every run via `session.started.data.modelProfile`. Event-log retrospection across runs lets us compare quality metrics (post-GATE2 rework, consensus iteration counts, pattern promotion rate) across profiles — this is how we audit "which profile is better for my team?" empirically.

M3 introduces the knob but keeps legacy defaults when unset, so upgrading does not change existing behavior.

## Hooks

| Hook | Event | Purpose |
|---|---|---|
| `load-chronic-patterns.sh` | SessionStart | Load recurring-mistake patterns into session context |
| `freeze-gate.sh` | PreToolUse (Edit\|Write) | Block src/** edits unless freeze doc is APPROVED for this feature on this branch |
| `push-guard.sh` | PreToolUse (Bash git push) | Block `git push` until `pipeline-complete.md` marker exists (GATE 2 approval) or ticket-scoped bypass is active |
| `phase-gate.sh` | Called by SKILL.md | Validate progress-log.json at phase boundaries (begin/end). Blocks on failure (exit 2) |
| `phase-progress-validator.sh` | PostToolUse (phase-gate) | Independent post-gate consistency check (warning-only, exit 0) |
| `test-failure-capture.sh` | PostToolUse (dotnet test) | Log failed test runs to session folder (audit trail) |
| `precompact.sh` | PreCompact | Serialize pipeline state before context truncation |
| `sessionend.sh` | SessionEnd | Clean temp files, mark interrupted pipelines |

## Prerequisites

External skills the default config references. If any are unavailable, the phase that uses them operates without skill-specific guidance (graceful degradation):

| Config key | Default |
|---|---|
| `pipeline.skills.requirements` | `superpowers:brainstorming` |
| `pipeline.skills.exploration` | `feature-dev:code-explorer` |
| `pipeline.skills.architect` | `feature-dev:code-architect` |
| `pipeline.skills.planning` | `superpowers:writing-plans` |
| `pipeline.skills.tdd` | `superpowers:test-driven-development` |
| `pipeline.skills.implementation` | `superpowers:subagent-driven-development` |
| `pipeline.skills.implementationSequential` | `superpowers:executing-plans` |
| `pipeline.skills.implementationParallel` | `superpowers:dispatching-parallel-agents` |
| `pipeline.skills.requestReview` | `superpowers:requesting-code-review` |
| `pipeline.skills.receiveReview` | `superpowers:receiving-code-review` |
| `pipeline.skills.verification` | `superpowers:verification-before-completion` |
| `pipeline.skills.finishing` | `superpowers:finishing-a-development-branch` |
| `pipeline.skills.debugging` | `superpowers:systematic-debugging` |

Override any mapping in `~/.claude/autodev/config.json` to swap in custom skills.

## Session State

Per-repo-branch session folders at `~/.claude/autodev/sessions/{repo}--{branch}/`:

| File | Purpose |
|---|---|
| `events.jsonl` | Append-only event stream (M1+); every orchestrator state transition + every hook gate decision emits one line. Source of truth for retrospective queries. |
| `.seq` | Atomic counter for the last emitted event's `seq` value. Managed by `emit-event.sh` under mkdir-based lock. |
| `views/` | Regenerated views (M2+); pure functions over `events.jsonl`. Contains `progress-log.json`, `decision-log.json`, `pipeline-issues.json`. Disposable — regenerate via `hooks/scripts/regenerate-views.sh`. |
| `progress-log.json` + `.md` | Phase timing, metrics, status; includes `mode` (full-cycle, review, test, docs, init), `freezeDocPath`, `plannedFiles`, `featureSlug` |
| `decision-log.json` + `.md` | Every decision with reasoning |
| `pipeline-issues.json` | Review findings per phase |
| `tdd-plan.md` | Phase 4 output |
| `pipeline-complete.md` | GATE 2 marker (authorizes push) |
| `bypass.json` | Ticket-scoped freeze-gate override (live during session; deleted at GATE 2) |
| `bypass-audit.jsonl` | Durable bypass audit trail (written by `sessionend.sh` on crash/interrupt; merged into freeze doc `bypassHistory` at GATE 2, filtered by `runId`) |
| `test-failures.log` | Test failure audit trail (hook-written) |

### Events (M1+)

Every state transition dual-writes to `events.jsonl` alongside existing state files. Schema, type catalog, and query examples: [`skills/dev/references/autonomous/events-schema.md`](./skills/dev/references/autonomous/events-schema.md).

Primitives (all in `hooks/scripts/`):

**M1 (event log):**
- `emit-event.sh <type> [--data JSON] [--actor ACTOR]` — append one event with atomic seq
- `get-events.sh [--type T] [--phase N] [--since-seq N] [--format json|summary|count]` — query
- `_session-lib.sh` — shared helpers (cfg, sanitize_branch, resolve_session_dir, iso_utc)

**M2 (views, wake, replay):**
- `_reducers.sh` — shared helpers for reducer scripts (events_file, views_dir, atomic_write)
- `reduce-progress-log.sh` / `reduce-decision-log.sh` / `reduce-pipeline-issues.sh` — individual reducers
- `regenerate-views.sh` — master orchestrator calling all reducers
- `wake.sh` — stateless restart primitive. Returns compact JSON `{sessionDir, lastSeq, currentPhase, status, pendingAction, minimumContext}`. `pendingAction` values: `session.complete`, `session.ready-to-resume`, `phase.N.iteration.M.active`, `phase.N.completion`, `gate.1.pending`, `gate.2.pending`, `phase.N+1.ready`, `session.not-started`.
- `replay.sh --until-seq N --target DIR` — copy events up to seq N into alt dir and regenerate views there (rewind/branch primitive)

**M3 (phase YAML + dispatcher):**
- `read-phase.sh <file> <key>` — read a field from a phase YAML (scalar via dot-path, list via line-per-item)
- `execute.sh <kind> <name> [--input JSON]` — uniform tool dispatch (kind: hook|protocol|skill|agent); auto-emits `tool.call.started/completed/failed`

**M4 (multi-brain):**
- `fan-out.sh --name N [--target-dir DIR] [--share-events]` — spawn a child session folder (inherits parent runId); with `--share-events`, shares `events.jsonl` via symlink/hardlink (fallback to copy on platforms without link support). Emits `fan-out.spawned` in parent.

See [`docs/specs/2026-04-20-managed-agents-evolution.md`](../../docs/specs/2026-04-20-managed-agents-evolution.md) for the full evolution plan. Protocol references:
- [`skills/dev/references/autonomous/events-schema.md`](./skills/dev/references/autonomous/events-schema.md) — event type catalog (M1)
- [`skills/dev/references/autonomous/views-spec.md`](./skills/dev/references/autonomous/views-spec.md) — view reducer contracts (M2)
- [`skills/dev/references/autonomous/dispatcher-spec.md`](./skills/dev/references/autonomous/dispatcher-spec.md) — dispatcher pseudocode + invocation semantics (M3)
- [`skills/dev/references/autonomous/worktree-orchestration.md`](./skills/dev/references/autonomous/worktree-orchestration.md) — multi-brain patterns (M4)
