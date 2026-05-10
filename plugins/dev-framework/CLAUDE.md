# Dev Framework Plugin (v5.0.0)

AI-led, end-to-end software development built on the Managed Agents architecture. v5 cleanly splits **planning** (`/spike`) from **execution** (`/implement`): all requirements, research, decomposition, and freeze-doc authorship live in `/spike`; `/implement` is pure execution against an APPROVED freeze doc. `/testbuilder` remains the standalone testing skill. All three share one epic-scoped event log.

## Core Philosophy

1. **Planning vs. execution.** `/spike` is the universal planning skill — handles Epic decomposition, single-ticket Story planning, and standalone Research. `/implement` is pure execution: read APPROVED freeze doc → E1 Execute → E2 Verify → E3 Finalize. `/testbuilder` is standalone testing.
2. **Shared epic session.** All three skills write to one `events.jsonl` keyed by epic. `wake()` returns cross-ticket state in a single call (MA invariant: many brains share many hands).
3. **Move slow, do it right.** Reduce revisits and refactoring. Multi-agent consensus reviews with 10-iteration / 2-consecutive-zero convergence (severity-gated in `/spike`).
4. **Research-execution boundary is physical.** Freeze doc carries an `approvedHash` (sha256 over canonical body) and `§11 Prerequisites` (DAG-derived dependencies). `freeze-gate.sh` reads `active-freeze-doc.txt`, verifies hash + prereqs before unlocking src/** edits; `push-guard.sh` blocks `git push` until GATE 2.
5. **Language-agnostic.** Works with any tech stack. (Exception noted: `test-failure-capture.sh` default is `dotnet test` — override via `config.hooks.testCapture.testCommand`; tracked for correction.)
6. **Documentation as a first-class artifact.** `project-docs` protocol enforces `docs/` structure; `/spike` plan docs live in-repo under `docs/plan/{epic}/` and are PR-reviewable.

## The Workflows

```
/spike <epic description>                   Epic mode — multi-ticket research + decomposition
/spike story <ticket>                       Story mode — single-ticket planning -> freeze doc
/spike research <topic>                     Research mode — standalone investigation -> research doc
/spike --revisit <freeze-or-research-doc>   Re-open an APPROVED doc for amendment
/spike --retro EPIC-ID                      Post-merge retro (design pattern capture)

/implement <freeze-doc-path>                Pure execution against APPROVED freeze doc
/implement --from <N> <freeze-doc-path>     Resume at E<N> (1=E1, 2=E2, 3=E3)
/implement --status <freeze-doc-path>       Status print

/testbuilder [...]                          Standalone testing workflow (independent of /implement)
```

`/spike` universal planning skill — 7 phases (P1-P7); mode dictates depth (Epic runs all 7, Story/Research run a subset):

```
P1. Scope            (mode detection; epic/story/research routing)
P2. Investigate      (dispatch research-investigator agents; capture findings + Doc-vs-Reality)
P3. Decompose        (Epic only — break into tickets with DAG ordering)
P4. Spec             (author freeze doc §1-§11 OR research doc; compute approvedHash)
P5. Review           (multi-agent consensus, severity-gated — Critical/Major block, Minor/Nit -> backlog)
P6. Approve          (GATE 1 — user approval; status: APPROVED + approvedHash sealed)
P7. Retro            (async; design-pattern capture after all merges)
```

`/implement` v5 — pure execution, 3 phases (E1-E3):

```
[Startup: load freeze doc -> verify approvedHash -> verify §11 Prerequisites -> write active-freeze-doc.txt]
E1 Execute           (TDD against freeze doc plan; freeze-gate enforces hash+prereqs on every src/** edit)
E2 Verify            (full test suite + Layer 1/Layer 2 multi-agent consensus reviews)
E3 Finalize          (docs + PR + mistake capture -> 🚪 GATE 2)
[push-guard hook — blocks git push until GATE 2 approved]
```

## Plugin Structure

```
```
plugins/dev-framework/
├── CLAUDE.md                  this file
├── README.md
├── CHANGELOG.md
├── .claude-plugin/            plugin.json (v5.0.0)
├── commands/
│   ├── implement.md           routes to implement skill (pure execution; requires freeze-doc-path)
│   ├── spike.md               routes to spike skill (universal planning — epic/story/research/--revisit)
│   └── testbuilder.md         routes to testbuilder skill (standalone testing)
├── agents/                    shared review/plan agents
│   ├── architect.md
│   ├── code-quality-reviewer.md
│   ├── observability-reviewer.md
│   ├── performance-reviewer.md
│   ├── requirements-analyst.md
│   ├── research-investigator.md   v5 — universal Research agent (strategy toolbelt, Doc-vs-Reality, Bash scope guard)
│   └── test-strategist.md
├── phases/                    phase YAML metadata (M3+); v5 split by skill
│   ├── README.md                     schema spec
│   ├── spike/
│   │   ├── p1-scope.yaml             mode detection
│   │   ├── p2-investigate.yaml       dispatch research-investigator agents
│   │   ├── p3-decompose.yaml         Epic-only ticket decomposition
│   │   ├── p4-spec.yaml              author freeze/research doc + approvedHash
│   │   ├── p5-review.yaml            severity-gated consensus
│   │   ├── p6-approve.yaml           GATE 1 user approval
│   │   └── p7-retro.yaml             async retro
│   └── implement/
│       ├── e1-execute.yaml           TDD against APPROVED freeze doc
│       ├── e2-verify.yaml            tests + Layer 1/2 reviews
│       └── e3-finalize.yaml          docs + PR + GATE 2
├── hooks/
│   ├── hooks.json
│   └── scripts/
│       ├── ensure-config.sh          config bootstrap (single source of truth)
│       ├── freeze-gate.sh            v5 — reads active-freeze-doc.txt; verifies approvedHash + §11 Prerequisites before unlocking src/** edits
│       ├── push-guard.sh             block git push until GATE 2
│       ├── phase-gate.sh             v5 — resolves phase YAML by skill (phases/spike/ vs phases/implement/)
│       ├── phase-progress-validator.sh  independent progress consistency check
│       ├── load-chronic-patterns.sh  SessionStart: inject mistake patterns
│       ├── precompact.sh             PreCompact: preserve pipeline state
│       ├── sessionend.sh             SessionEnd: temp cleanup + interrupted marker
│       ├── test-failure-capture.sh   audit failed test runs
│       ├── freeze-doc-hash.sh        v5 — compute/verify canonical-body sha256 (approvedHash)
│       ├── freeze-doc-prereqs.sh     v5 — verify §11 Prerequisites against ticket.merged events / git merge log
│       ├── _session-lib.sh           (M1) shared session resolution helpers
│       ├── emit-event.sh             (M1) append event with atomic seq
│       ├── get-events.sh             (M1) query events.jsonl
│       ├── _reducers.sh              (M2) shared reducer helpers
│       ├── reduce-progress-log.sh    (M2) events -> views/progress-log.json
│       ├── reduce-decision-log.sh    (M2) events -> views/decision-log.json
│       ├── reduce-pipeline-issues.sh (M2) events -> views/pipeline-issues.json
│       ├── regenerate-views.sh       (M2) orchestrate all reducers
│       ├── wake.sh                   (M2) stateless restart summary
│       ├── replay.sh                 (M2) seq-level rewind into alt dir
│       ├── read-phase.sh             (M3) YAML field reader
│       └── execute.sh                (M3) uniform tool dispatch with auto events
└── skills/
    ├── implement/             v5 — pure execution skill (E1 Execute / E2 Verify / E3 Finalize)
    │   ├── SKILL.md
    │   └── references/
    │       ├── methodology/          DECISION_MAKING, DEVELOPMENT_CYCLE, DOCUMENTATION_STANDARDS, TESTING_STRATEGY
    │       ├── standards/            CODE_QUALITY, EARLY_EXIT, ERROR_HANDLING, OBSERVABILITY, PERFORMANCE, RESULT_PATTERN
    │       ├── templates/            ADR_TEMPLATE, CODE_REVIEW_CHECKLIST, TEST_PLAN_TEMPLATE
    │       ├── protocols/            internal protocols (multi-agent-consensus, project-docs, test-planning)
    │       └── autonomous/           session-management, review-loop-protocol, mistake-tracker-protocol (code),
    │                                 events-schema (M1), views-spec (M2), dispatcher-spec (M3)
    ├── spike/                 v5 — universal planning skill (epic/story/research/--revisit)
    │   ├── SKILL.md
    │   └── references/
    │       ├── guardrails.md         v5 — SOLID/DRY/YAGNI/Open-Closed reference for all dispatched agents
    │       ├── templates/            SPIKE_PLAN_TEMPLATE, TICKET_REF_TEMPLATE, FREEZE_DOC_TEMPLATE (with approvedHash + §11), RESEARCH_DOC_TEMPLATE, REVIEW_BACKLOG_TEMPLATE
    │       ├── protocols/            research-dispatch (fan-out + crash recovery + parallel rules)
    │       └── autonomous/           mistake-tracker-protocol (design) — variant for architectural patterns
    └── testbuilder/           standalone testing skill (independent of /implement)
        └── ...
```

All protocol files are **internal references** read by `SKILL.md` via the Read tool. They are not discoverable as standalone skills and are not exposed to the user.

## User Gates

| Gate | Phase | Mode behavior | Physical artifact |
|---|---|---|---|
| **GATE 1** — Freeze doc approval | End of `/spike` P6 (owner: Spike) | Interactive: user approves by category. Autonomous: auto-approves with audit note. Sealed by `approvedHash` over canonical body. | Freeze doc frontmatter `status: APPROVED` + `approvedHash` + `approvedAt`/`approvedBy`/`approvalMode`. |
| **GATE 2** — Final approval | End of `/implement` E3 (owner: Implement) | Always user-interactive (both modes). | `pipeline-complete.md` marker in session folder + progress-log `status: completed`. |

Between the two gates, `freeze-gate.sh` reads `active-freeze-doc.txt`, verifies `approvedHash` + §11 Prerequisites, and blocks src/** edits on mismatch; after GATE 2, `push-guard.sh` allows `git push`.

## Execution Question Zones (/implement E1-E3)

Four zones govern how the LLM handles questions during execution:

| Zone | Description | Behavior |
|---|---|---|
| 🛑 Frozen | Changes a freeze-doc §1-§8 decision | HALT; request ticket update |
| ✅ Non-Frozen | In `freezeDoc.nonFrozenAllowList` (observability, railroad, pure-function-composition) | May ask user |
| 🤔 Ambiguous | Technical, not covered above | 4-tier rule: existing code → follow; reference repo → follow; initial impl → ask; else → self-decide |
| ⚙️ Self-decide | Pure technical (naming, extraction, internal boundaries) | Decide without asking |

See `skills/spike/references/templates/FREEZE_DOC_TEMPLATE.md` §9 for the full "Ask with Suggestion" format (v5: spike owns the freeze doc template).

## Config

All configuration lives in `~/.claude/autodev/config.json` (single source of truth). Created on first `/spike` or `/implement` invocation via `hooks/scripts/ensure-config.sh`. Every field has a documented fallback in `skills/implement/references/autonomous/session-management.md`.

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
| `freeze-gate.sh` | PreToolUse (Edit\|Write) | v5 — reads `active-freeze-doc.txt` pointer (written by `/implement` at startup); verifies `approvedHash` (canonical-body sha256) and §11 Prerequisites (against `ticket.merged` events / git merge log). Blocks src/** edits on mismatch or until freeze doc is APPROVED |
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

Per-epic session folders at `~/.claude/autodev/sessions/{repo}--epic-{epicId}/` (v4.0.0+; ad-hoc `/implement` runs without a spike synthesize `epicId = ad-hoc-{sanitized-branch}`):

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

Every state transition dual-writes to `events.jsonl` alongside existing state files. Schema, type catalog, and query examples: [`skills/implement/references/autonomous/events-schema.md`](./skills/implement/references/autonomous/events-schema.md).

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
- [`skills/implement/references/autonomous/events-schema.md`](./skills/implement/references/autonomous/events-schema.md) \u2014 event type catalog (M1, extended in v4.0 with `spike.*` and `ticket.*`)
- [`skills/implement/references/autonomous/views-spec.md`](./skills/implement/references/autonomous/views-spec.md) \u2014 view reducer contracts (M2)
- [`skills/implement/references/autonomous/dispatcher-spec.md`](./skills/implement/references/autonomous/dispatcher-spec.md) \u2014 dispatcher pseudocode + invocation semantics (M3)
- [`skills/implement/references/autonomous/worktree-orchestration.md`](./skills/implement/references/autonomous/worktree-orchestration.md) \u2014 multi-brain patterns (M4)
