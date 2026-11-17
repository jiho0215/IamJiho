# v6 acceptance suite

Drives the real `bin/` scripts against a real, throwaway GitHub sandbox. It needs the network, writes to the sandbox,
and is **not** part of `tests/v6/run.sh`. Run it by hand.

## Env

| Variable | Meaning |
|---|---|
| `DEVFW_SANDBOX_CORE` | `owner/name` of the sandbox core repo (holds the plan; carries the marker) |
| `DEVFW_SANDBOX_CODE` | `owner/name` of the sandbox code repo (issues, PRs; must NOT carry the marker) |

The names live only in your shell, never in a committed file. `gh` must be logged in.

## Run

```bash
# once: commit the marker to the core repo's default branch (the two names must repeat the env values exactly)
bash plugins/dev-framework/tests/v6/acceptance/run.sh --init --confirm "$DEVFW_SANDBOX_CORE" "$DEVFW_SANDBOX_CODE"
bash plugins/dev-framework/tests/v6/acceptance/run.sh          # every scenario, compared with expected.json
```

`--init` refuses (exit 2, nothing written) unless `--confirm <core> <code>` repeats the env names exactly. Before it
creates the marker, or adds a code repo to it, it also refuses when either repo is public, has more than 20 commits on its
default branch, or has a closed PR that is not an acceptance-run PR (head or base on a `run/` branch). `--force-sandbox`
skips those three heuristics only, never `--confirm`. A marker read that fails with anything but a 404 refuses too: the
marker is never overwritten.

Exit 0 only when every scenario matches `expected.json`; 1 on any mismatch; 2 when the sandbox guard or env refuses.
Output lines: `A1 green ok`, `A7 red ok (until Plan 3)`, `A4 UNEXPECTED red: <msg>`, `A7 UNEXPECTED green`.
An expected `red` must fail with a message containing its `reason`; a crash or typo is reported, not accepted as red.

## The sandbox marker

A file named `DEVFW_SANDBOX` at the root of the core repo's default branch. Its content lists the allowed sandbox code
repos, one `owner/name` per line (`#` lines are comments). `run.sh --init` writes it (or adds the code repo's line to an
existing marker) from the env, by a normal push. Before any write, `openRun` reads it; if it is missing, or does not list
`DEVFW_SANDBOX_CODE`, nothing is cloned, created or pushed and a `SandboxError` is raised. `run.exec` (`execIn`) and
`closeRun` refuse any run object that `openRun` did not verify, and re-verify after 10 minutes. The code repo itself has
no marker, so pointing `DEVFW_SANDBOX_CORE` at it is a real negative test (scenario A0).

## Runner self-test

`node --test --test-timeout=60000 plugins/dev-framework/tests/v6/acceptance/runner.unit.test.mjs` (no network) checks the
runner: a SandboxError exits 2, a skip/todo never counts as green, and an expected red must carry its `reason` in the failure
message (not the title or path). `tap-report.mjs` holds the parser.

## Each run

`openRun` makes a runId (`r` + UTC `yyyymmddhhmm` + 3 letters), a branch `run/<runId>` in the core repo carrying the
plan, decisions, lease line and `orchestrator.json`, and returns `{ runId, coreDir, codeDir, config, env }`.
`closeRun` closes every issue/PR labelled `epic:<runId>` or titled with the runId; branches stay in the run's namespace.
`eventually(fn)` retries a read for up to 30 s; never pass it a write.

## Sweep (orphans of killed runs)

A run killed before `closeRun` leaves its issues and PRs open. `run.sh --sweep` closes, in both sandbox repos, every open
issue or PR that names only runIds older than 1 hour (in an `epic:<runId>` label or in its title), and every open
`merged-stale` / `merged-unverifiable` tracker whose PR's base ref starts with `run/`. A fresh run's items and a tracker of
a PR on any other base are never touched. It is guarded like any write (env names, then the marker pair), and every suite
run does it first; if it fails, no scenario runs.

The run config leaves `project` unset, so `ticket-sync` skips its Project step and no GitHub Project is ever touched.
