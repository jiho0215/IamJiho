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
bash plugins/dev-framework/tests/v6/acceptance/run.sh --init   # once: commit the marker to the core repo's main
bash plugins/dev-framework/tests/v6/acceptance/run.sh          # every scenario, compared with expected.json
```

Exit 0 only when every scenario matches `expected.json`; 1 on any mismatch; 2 when the sandbox guard or env refuses.
Output lines: `A1 green ok`, `A7 red ok (until Plan 3)`, `A4 UNEXPECTED red: <msg>`, `A7 UNEXPECTED green`.
An expected `red` must fail with a message containing its `reason`; a crash or typo is reported, not accepted as red.

## The sandbox marker

A file named `DEVFW_SANDBOX` at the root of the core repo's default branch. Before any write, `openRun` reads it; if it is
missing nothing is cloned, created or pushed and a `SandboxError` is raised. The code repo deliberately has no marker, so
pointing `DEVFW_SANDBOX_CORE` at it is a real negative test (scenario A0).

## Each run

`openRun` makes a runId (`r` + UTC `yyyymmddhhmm` + 3 letters), a branch `run/<runId>` in the core repo carrying the
plan, decisions, lease line and `orchestrator.json`, and returns `{ runId, coreDir, codeDir, config, env }`.
`closeRun` closes every issue/PR labelled `epic:<runId>` or titled with the runId; branches stay in the run's namespace.
`eventually(fn)` retries a read for up to 30 s; never pass it a write.

The run config leaves `project` unset, so `ticket-sync` skips its Project step and no GitHub Project is ever touched.
