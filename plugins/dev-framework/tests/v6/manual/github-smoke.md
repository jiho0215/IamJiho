# GitHub-layer read-only smoke (manual)

Fakes prove the logic; only the real API proves shapes (field names, pagination, GraphQL ids).
This procedure runs reads only. It never writes to GitHub.

## Rules
- Never pass `--apply`, `--writeback` or `--refresh-cites`. Never run `new-ticket`.
- Keep the scratch config outside any published repo. Never commit it.
- Record exit codes and counts or reason strings only. Never record issue bodies or titles.

## Setup
1. Use a checkout of the plan repo as `--core-dir`. If the plan is on an unmerged branch, fetch it
   (`git -C <core> fetch origin <branch>`) and pass `--ref origin/<branch>`. Do not switch the checkout's branch.
2. Write a scratch `orchestrator.json` outside the repo and point `DEVFW_CONFIG` at it. Shape:
   `plan {repo, path, branch}`; `repos` keyed by the first word of each plan item's `area:` line, each with
   `github: "owner/name"` (the key is `github`, not `repo`), `ci: "required"|"none"`, `tests: [...]`;
   `ownerArea`; `stages`; `project {owner, number, fields}`; `coverage`; `github {writeDelayMs}`; `reconcile {lookbackDays}`.
   A plan area word with no `repos` entry is reported as a finding; do not guess a repo.

## Runs (all dry)
| # | Command | Expected |
|---|---------|----------|
| 1 | `ticket-sync --core-dir <core> --ref <ref>` | The parse succeeds on every item; no exit 2. `missing` counts items with no issue; `extra`, `drift`, `labelsMissing` are reported as counts. Exit 7 means differences were found (not a crash). |
| 2 | `reconcile --core-dir <core> --ref <ref>` | Exit 0; one entry per item with a state and a reason; `changes` lists state flips that `--apply` would write. |
| 3 | `reconcile --core-dir <core> --ref <ref> --post-merge` | Exit 0 when nothing is stale. Exit 9 when something is stale or unverifiable: record the counts and reason strings. |
| 4 | `waiting --core-dir <core>` | Exit 0; `owner` and `orchestrator` lists (counts). `waiting` reads the plan from the checkout, not from `--ref`. |
| 5 | `merge-gate --repo <owner/name> --pr <n> --core-dir <core>` on the latest merged PR in a code repo | A structured verdict (`pass`, `checks`, `reasons`), exit 6 on refusal. Never a crash or a stack trace. A pre-v6 PR is expected to fail on `cites`. |

## What a failure means
- An `{"error": ...}` on exit 1 or 2 is a script or plan-format finding. Capture the command and the error text.
- A parse error naming a plan item means the plan uses syntax the parser rejects. Report the item id and the field; do not edit the plan to get past it, except in a throw-away scratch clone to see how far the run gets.
- A shape mismatch (a missing field, a pagination cut-off, a GraphQL id) shows up as a wrong count or an `undefined` in an error. Compare the count with the same query made by hand in `gh`.
- Record each run as: command, exit code, counts or reason strings.
