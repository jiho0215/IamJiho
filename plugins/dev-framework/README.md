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

## v6 hooks (Plan 3)

Wired in `hooks/hooks.json`; the wiring itself is fenced by `tests/v6/hooks/hooks-json.test.sh` (scripts exist, every
`bin/` file and every `hooks/scripts/*.sh` is mode 100755 in the git index, no `if` on any PreToolUse entry, the Edit
matcher is `Edit|Write|MultiEdit|NotebookEdit`, each script's run budget is below its hook timeout, every network call
goes through `hook_net`, no EnterWorktree matcher). Every v6 hook reads its config from
`DEVFW_CONFIG` or `<DEVFW_CORE_DIR>/orchestrator.json`, decides scope with no network, and inside scope fails closed:
a block is exit 2 with stderr line 1 `devfw <hook-name>: <reason>`. Each script's header comment states its rules in
order; the "rule" numbers below refer to those headers.

| Event / matcher | Script | Timeout | Rule | Status |
|---|---|---|---|---|
| SessionStart | `session-digest.sh` | 15 s | Print the plan digest (fetch bounded at 8 s; stale is flagged) | Informational: always exits 0 |
| PreToolUse Edit family + Bash | `plan-edit-guard.sh` | 30 s | Only the lease holder edits the plan or commits plan changes in core (`bin/lease check`, rules 2 and 5) | **Enforced** |
| PreToolUse Edit family + Bash | `plan-edit-guard.sh` | 30 s | Subagents never edit the plan (rule 4, gated on a non-empty `agent_id`) | **Convention-backed** until Q2 is measured (see below) |
| PreToolUse Edit family | `freeze-gate.sh` | 30 s | On a claim branch `t/<n>-<slug>`, a code edit needs the freeze doc committed on that branch to be APPROVED, hash-verified, and cite an `owner-said <n> <path>@<content hash>` comment on issue `<n>` by a trusted author (rules 4-8; hash from `freeze-content-hash.sh`) | **Enforced for Edit/Write/MultiEdit/NotebookEdit; Bash writes are convention** (ruling R26: `cat >`, `sed -i`, `cp` into a code path are not parsed); who typed `owner-said` is convention |
| PreToolUse Bash | `merge-gate-hook.sh` | 120 s | `gh pr merge` / `gh api .../pulls/N/merge` (the endpoint also as a full URL, ruling R22) and gh/git aliases that expand to one (R25): no `--auto`, `--repo` required, a plan-repo merge is decided by the lease alone (R23; `bin/merge-gate` is not called for it), other managed repos must pass `bin/merge-gate` (bounded at 100 s) | **Enforced** for merges run through Claude's Bash tool |
| PreToolUse Bash | `push-guard.sh` | 30 s | In a managed repo: no force/delete (unless `hooks.pushGuard.allowForce`), no push to the default branch (the destination resolved as git does: `@`, `HEAD`, `heads/<x>`, `refs/heads/<x>`; an unresolvable one blocks, ruling R21), a `t/<n>-...` push needs a claim on origin, and issue `<n>` must not carry `needs-ack` | **Enforced** |
| PreToolUse Bash | `claim-guard.sh` | 30 s | Creating a `t/<n>-<slug>` branch (`worktree add -b`, `checkout -b`, `switch -c`, `branch <new>`) needs a claim for `<n>` on origin | **Enforced** for the creation forms only |
| PreToolUse EnterWorktree | (none) | - | Claim check on EnterWorktree | **Not registered**: Q5 (is it hookable) is unmeasured (ruling R5) |
| Stop | `stop-backstop.sh` | 30 s | When `<git-dir>/devfw/run.json` exists and `bin/stop-check` names a stop code with no matching `devfw/handback.json`, keep the session going once | **Enforced once per stop**; not fail-closed by design |

The v5 hooks (`load-chronic-patterns.sh`, `test-failure-capture.sh`, `phase-progress-validator.sh`, `precompact.sh`,
`sessionend.sh`) stay wired as before until Plan 4 removes the v5-only ones.

**Owner-assisted step before cutover (Q2, Q5).** The hook payload probe has never run (the child `claude -p` was not
logged in; see `tests/v6/manual/hook-probe.md`). In a logged-in terminal run
`timeout 5m bash tests/v6/manual/hook-probe.sh` and paste the table into `hook-probe.md`. Until then the subagent clause
of `plan-edit-guard.sh` is convention-backed (if subagent payloads carry no `agent_id`, the clause is inert, never a
false block), and EnterWorktree stays unhooked. A manual live smoke of the wired hooks is in
`tests/v6/manual/hook-smoke.md`.

### Fail-open cases and known limits

Each item is a path on which a rule above does NOT block. They are accepted residuals, not bugs to rely on.

1. **`DEVFW_CORE_DIR` unset**: every v6 hook exits 0 (`_v6-hook.sh` `hook_init`; the digest prints one "inactive"
   line). Exception: `stop-backstop.sh` is scoped by `run.json`'s presence alone (ruling R17).
2. **A hook timeout does not block**, so each hook run has one deadline (ruling R19, `_v6-hook.sh` `hook_net`): a run
   budget set by `hook_init <name> <seconds>` (25 s for the 30 s hooks, 115 s for merge-gate-hook, 10 s for the
   digest), at least 5 s under the hooks.json timeout. Every network call is bounded by min(its per-call bound:
   `DEVFW_HOOK_NET_TIMEOUT` default 20 s, `DEVFW_HOOK_GATE_TIMEOUT` default 100 s; the time left), and a call with
   under 1 s left blocks with "time budget ran out" (the digest only marks itself stale). `hooks-json.test.sh` fences
   budget + 5 s <= timeout and that every network call goes through `hook_net`. `hook_net` captures output in a temp
   file, not a pipe, so a grandchild that outlives the command and holds stdout cannot stretch the run. What remains:
   local work after the last network call (node/jq/git, normally well under the 5 s margin) is not bounded, and
   `DEVFW_HOOK_BUDGET` raised past the hook timeout is a fail-open (user-controlled, like the per-call env vars,
   ruling R10).
3. **`cd` and opaque commands** (rulings R1, R9, R15, R20, R28, R31). A literal `cd <dir>` / `pushd <dir>` is tracked
   within one command; a leading `~`, `~/`, `$HOME` or `${HOME}` reads as `$HOME` (so `cd ~/repo` scopes like the full
   path). For every segment it cannot read exactly, the parser (`lib/hook-cmd.js`) also reports where it runs: dir
   unknown (a dynamic `cd`/`pushd`/`-C`, `popd`, `cd -`, `~user`, a glob or brace in the dir, `GIT_DIR`/`--git-dir`,
   a relative `cd`/`pushd` other than `.`, `..`, `./x`, `../x` while `CDPATH` is set in the command or in the hook's
   own environment (a bare `CDPATH=...` assignment counts too), a `cd`/`pushd`/`popd` behind a wrapper (`env cd x`,
   `timeout 5 cd x`, `stdbuf cd x`, `COMMAND cd x`; ruling R27a), and code that may run git from anywhere (rulings
   R28, R28a): a segment where ANY word is a code runner (`eval`, `xargs`, `sh`/`bash -c`, `script`, `python`,
   `perl`, `node`, `sudo`, `nohup`, `wsl`, ... — the `CODE_RUNNERS` set; so `stdbuf -oL bash -c '...'` and
   `winpty python -c '...'` too) and any word mentions `git`/`gh`; a dynamic command word (`"$SHELL" -c '...'`) whose
   arguments mention them; and a code runner (`source` and `.` included) or dynamic command word fed on stdin (a
   pipe, heredoc, here-string or `< file` into it, whatever its arguments: `-s x`, `/dev/stdin`, ...; ruling R28b)
   when the whole command text mentions them — that row's text is the whole command, so `git log | python
   summarize.py` is a row too, harmless unless the text names a guard's verb), else a literal `-C`/`--chdir` in the segment, else the cd dir. A `git <x>` / `gh <x>` written
   inside such code, where `<x>` is not a command, is looked up as an alias (item 20) from the hook cwd. All Bash
   guards share one rule (`_v6-hook.sh` `hook_opaque_rows` / `hook_opaque_hit`): an unreadable guarded segment is in
   scope when its dir is unknown, when its literal dir or the hook cwd is managed / in core, or when the text names a
   managed slug / the core path. So an unknown dir blocks from ANY cwd (a false block outside v6 repos, e.g.
   `bash -c 'git push ...'` or `echo 'git push' | bash` anywhere, or any relative `cd` before a guarded call when
   `CDPATH` is set; workaround: run git plainly and write the path literally). Residuals: an opaque segment counts for
   a guard only when its text names the guard's verb (`push`, `commit`, `merge`/`pulls/`, a branch verb;
   case-insensitive), so code that deliberately hides the verb or the git word (`bash -c "git $V"`, `pu""sh`,
   `g""it`) is not seen — no stronger than running a script file (item 18); a code runner not in `CODE_RUNNERS` that
   mentions git only inside a string (`npx foo -c 'git push'`, `uv run x -c '...'`) is not seen; an alias inside an
   interpreter string run from an unmanaged cwd is looked up there (only global aliases are seen); `sudo` and `nohup`
   are not read through, so `sudo git push ...` blocks as unreadable from any cwd.
4. **Web merges** (GitHub UI, API outside Claude's Bash tool) never pass `merge-gate-hook.sh`; they are caught after
   the fact by `bin/reconcile --post-merge` (`lib/reconcile.js`).
5. **`owner-said` authorship**: `freeze-gate.sh` rule 8 proves an `owner-said` record for this exact plan content
   exists on the ticket and that GitHub reports its author as trusted (`lib/acks.js` `isTrustedAuthor`), not that the
   owner typed it: the worker posts it with the owner's token (v6-design C1).
6. **EnterWorktree** is not hooked while Q5 is unmeasured (ruling R5).
7. **Detached HEAD** skips `freeze-gate.sh` (its scope requires `HEAD` on `t/<n>-<slug>`).
8. **Broad test patterns**: `freeze-gate.sh` treats any path matching v5's test patterns (`*.test.*`, `*.spec.*`,
   `*_test.*`, `*/tests/*`, `*/test/*`, `tests/*`, `test/*`, `*/__tests__/*`) as out of scope, even under a code path.
9. **Forgeable local approval cache**: a `"<blob sha> <comment id>"` line in `<git-dir>/devfw/freeze-ok` is trusted
   (`freeze-gate.sh` rule 7); anything that can write the git dir can pre-approve a blob. A cache line written before
   ruling R16 (content-hash `owner-said`) is still honoured after the upgrade.
10. **`freeze-content-hash.sh` scope**: only a CLOSED front matter (line 1 `---` and a later `---`) is stripped, and only
    of the `status:`, `approvedBy:`, `approvedAt:`, `approvedHash:` lines and the `bypassHistory:` line with its indented
    list; an unterminated front matter is hashed whole, and every other line (body, other keys, indented lines after
    other keys) is content. Residual: an edit confined to those stripped lines (e.g. a `bypassHistory` entry) does not
    change the content hash, by design. Each clause is fenced in `freeze-gate.test.sh`.
11. **`codePaths`**: a whitespace-only entry is silently ignored (fewer paths in scope) rather than rejected.
12. **DWIM checkout**: `git checkout t/43-x` / `git switch t/43-x` of an existing or remote-only branch is not a
    creation form, so `claim-guard.sh` does not see it; `push-guard.sh` rule 6 (claim on push) is the control.
13. **Push remote resolution**: a bare `git push` is scoped against the upstream remote, ignoring
    `branch.<b>.pushRemote` / `remote.pushDefault`; and remote classification reads `remote.<n>.url`, ignoring
    `remote.<n>.pushurl`. A managed push URL behind an unmanaged fetch URL is not seen.
14. **`plan-edit-guard.sh` pre-filter**: `cherry-pick`, `merge`, `revert`, `am` into core, and `git add <new> && git
    commit` in one command (the new file is not yet in the diff when the hook runs) are not seen.
15. **Paths**: `hook_under` does not resolve symlinks, and compares case-insensitively only on Windows.
16. **`--repo` case**: `merge-gate-hook.sh` matches `github.com/` case-sensitively, so `--repo https://GitHub.com/o/n`
    falls through as unmanaged.
17. **`DEVFW_BIN_DIR`** overrides where hooks find `bin/lease`, `bin/merge-gate` and `bin/stop-check`; it is a
    test-only knob, and pointing it at a stub disables those checks.
18. **Code written through Bash** (`cat > src/x.js`, `sed -i`, `cp`, `python -c ...`) never reaches `freeze-gate.sh`,
    which is wired to the Edit tools only (ruling R26). "No code before plan approval" is enforced for the Edit tools
    and is convention for Bash writes; nothing else re-checks the freeze approval for code written that way.
19. **Direct ref / merge writes through the API**: `gh api -X PATCH repos/o/n/git/refs/heads/main`,
    `gh api -X POST repos/o/n/merges`, `curl` to api.github.com, and any other HTTP client are not parsed; only
    `gh pr merge`, `gh api .../pulls/N/merge` and the GraphQL merge mutations are. Branch protection on GitHub and
    `bin/reconcile --post-merge` are the controls.
20. **Wrappers, case and aliases** (rulings R25, R27, R27a, R29, R29a, R30): external command words are compared
    case-insensitively by basename without `.exe` (`GIT`, `Git.EXE`, `/usr/bin/git`, `C:/Program Files/Git/cmd/git.exe`
    are git; the same for gh, env, timeout, the code runners and the data commands), and so are git subcommands and gh
    command groups (`git PUSH` is push), on every platform. Shell builtins and keywords (`cd pushd popd export unset
    command builtin exec eval source . alias declare local readonly typeset`, `if then ...`) match only as written,
    because bash dispatches them case-sensitively: `CD x` / `UNSET CDPATH` / `EXPORT GH_REPO=x` are "command not
    found" and change nothing, and a `cd` behind a wrapper makes later dirs unknown (item 3). A command word the parser does not know followed by `git`/`gh`
    (`stdbuf`, `winpty`, `flock`, ...) is unreadable and handled by item 3's rule with the dir as written; `exec`,
    `command`, `builtin`, `env`, `timeout`, `nice` are read through. Commands whose arguments are data (`echo`,
    `printf`, `grep`, `rg`, `cat`, `ls`, `test`, `[`, `read`, `alias`, ... — the `DATA` set in `lib/hook-cmd.js`)
    are not. A git subcommand that is not a git command is looked up as `alias.<name>` in the repo the segment runs
    in (from the hook cwd when that dir is unknown, so only global aliases are seen then); a gh command that is not a
    gh command is looked up in `gh alias list`. The lookup follows a chain (`q = p`, `p = push`) up to 10 steps; the
    call is unreadable when a step starts with `!` (a shell alias, whatever it runs), names the guarded verb, starts
    with an option, names a word that is neither an alias nor a command, or the chain is longer than 10. A git call
    carrying config that can define or redirect an alias (`-c alias.*`/`include.*`/`includeIf.*`/`remote.*`/`url.*`/
    `branch.*`/`push.*`, a dynamic `-c`, any `--config-env`, or `GIT_CONFIG_COUNT`/`_KEY_*`/`_VALUE_*`/
    `_PARAMETERS`/`_GLOBAL`/`_SYSTEM`/`GIT_CONFIG`/`HOME`/`XDG_CONFIG_HOME` in its env prefix or an earlier
    `export`) is unreadable when its subcommand is a guarded verb (push, commit, worktree, checkout, switch, branch);
    when it is not a git command at all, it is unreadable for EVERY guard whatever its text says (`any`; the
    expansion may live only in that config). gh with `GH_CONFIG_DIR`/`HOME`/`XDG_CONFIG_HOME`/`APPDATA` and a
    non-command group likewise. merge-gate-hook's pre-filter takes the word `git` too (R29a), so git aliases and
    injected config reach it; there a shell (`!`) alias step counts only when its text names `gh`, `merge` or
    `pulls/`, or when the repo it was looked up in is managed. Costs, accepted: a git shell alias (`!...`) blocks
    push-guard / plan-edit-guard in a managed repo / core and merge-gate-hook in a managed repo; a git alias for
    `git merge` (expansion names `merge`) blocks merge-gate-hook from any cwd; an alias step naming an external
    `git-<name>` command (not in the parser's command list) counts as unresolved. Residuals: claim-guard counts an
    alias only when a step is a creation form (`-b`, `-c`, `--create`, `--orphan`, `branch`, `worktree`) or a shell
    alias, and then only when the command text mentions `t/` or is non-literal (an `any` row from injected config is
    never dropped), so an alias for plain `checkout` is item 12's DWIM gap and a repo `!` alias that names the ticket
    branch only inside its expansion passes claim-guard (push-guard's claim check on the push is the control); a `!`
    alias that hides a merge behind a script file, outside a managed repo, is not seen by merge-gate-hook (the same
    class as running that script); when `gh alias list` fails, a gh alias call blocks only from a managed cwd; `-c`
    keys outside the list above and `--exec-path` / `GIT_EXEC_PATH` (which can run any binary as `git-push`; item 18's
    class) are read as harmless; `unset GIT_CONFIG_*` does not clear an earlier `export`.
21. **jq missing** (ruling R24; not a fail-open, but visible): with `DEVFW_CORE_DIR` set and no jq, a hook never
    blocks before scope. Each one reads the raw input for its own tokens (case-insensitively, R27) and blocks only
    those calls: push-guard on
    `push`, claim-guard on `worktree|checkout|switch|branch`, merge-gate-hook on `merge|pulls/`, plan-edit-guard on a
    Bash `commit` or an edit naming core's directory name, freeze-gate on an edit in a repo on a `t/<n>-...` branch;
    stop-backstop blocks once only when `devfw/run.json` exists, and never when `stop_hook_active` is true.
22. **Default branch from config**: push-guard takes a repo's default branch from `repos.<x>.default`, else
    `plan.default`, else `main`; it does not ask the remote. A config that omits `default` for a repo whose real
    default is not `main` lets a push to that default through (`lib/config.js`, which `bin/merge-gate` loads, already
    rejects a repo without `default`, so a config the merge gate accepts has it).

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
