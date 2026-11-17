# Hook contract pinned by scenario A7

Two PreToolUse hook scripts live in `hooks/scripts/`: `plan-edit-guard.sh` and `merge-gate-hook.sh`.

- **Input.** A Claude Code PreToolUse JSON payload on stdin:
  `{ "tool_name", "tool_input": { "file_path" | "command" }, "cwd", "session_id" }`.
- **Output.** Exit 0 allows. Exit 2 blocks, with the reason on stderr.
- **Config.** Read through `DEVFW_CONFIG`, or `<core>/orchestrator.json`, where `<core>` is `DEVFW_CORE_DIR`.

## plan-edit-guard.sh (tool_name `Edit`, `tool_input.file_path`)

| Case | Result |
|---|---|
| File under `<core>/docs/plan`, local lease token differs from the run branch's lease line | exit 2, stderr contains `lease` |
| Same file, tokens equal | exit 0 |
| File outside `docs/plan` | exit 0 |

The local token is `<core>/.orchestrator/lease`; the branch token is the `orchestrator: <token>` line of the plan's START-HERE.md.

## merge-gate-hook.sh (tool_name `Bash`, `tool_input.command`)

| Case | Result |
|---|---|
| `gh pr merge <n> --repo <code> --squash`, merge-gate refuses the PR | exit 2, stderr contains the gate's first reason |
| Same command, merge-gate passes the PR | exit 0 |
| Any command that is not a merge (for example `gh pr view <n>`) | exit 0 |
