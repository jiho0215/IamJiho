# v6 hook live smoke (procedure for Plan 5)

Not run in Plan 3. Running it loads the branch build of the plugin into a real Claude Code session, so it needs the
owner's OK and is a Plan 5 step. Use the throwaway sandbox repos (`DEVFW_SANDBOX_CORE`, `DEVFW_SANDBOX_CODE`), never a
real project. Run `tests/v6/manual/hook-probe.sh` first (Q2, Q5): its answers decide whether the subagent row below
is expected to block.

## Load the branch build for one session only

1. Check out the branch in a scratch worktree: `git worktree add <scratch>/devfw-v6 claude/dev-framework-v6`.
2. Start ONE session with that plugin directory and nothing installed: `claude --plugin-dir <scratch>/devfw-v6/plugins/dev-framework`
   (no `/plugin install`, no change to user settings). Exit the session to unload it.
3. In that shell, before starting: `export DEVFW_CORE_DIR=<clone of the sandbox core>`; leave `DEVFW_BIN_DIR`,
   `DEVFW_HOOK_NET_TIMEOUT` and `DEVFW_HOOK_GATE_TIMEOUT` unset.
4. Confirm the wiring: `/hooks` lists SessionStart (2), PreToolUse `Edit|Write|MultiEdit|NotebookEdit` (2),
   PreToolUse `Bash` (4), Stop (1), and no `EnterWorktree` matcher.

## What to try, and what to expect

A block shows as the tool call refused with `devfw <hook-name>: <reason>` as the first line.

| Hook | Try | Expect |
|---|---|---|
| session-digest | Start the session | One digest block (or one `digest unavailable: <reason>` line); never a failed start. With `DEVFW_CORE_DIR` unset: `dev-framework v6: inactive (DEVFW_CORE_DIR not set)` |
| plan-edit-guard | Ask Claude to edit `<core>/docs/plan/PLAN.md` while `.orchestrator/lease` holds a token that is not the lease line on origin | Blocked, reason names the lease |
| plan-edit-guard | Same edit with the matching token | Allowed |
| plan-edit-guard | A file outside the plan dir | Allowed, no network |
| plan-edit-guard (subagent) | Ask a subagent to edit the plan | Blocked only if Q2 was VERIFIED; otherwise record what happened (convention-backed) |
| freeze-gate | On `t/<n>-<slug>` in the sandbox code repo with no committed `freeze.md`, edit `src/x.js` | Blocked |
| freeze-gate | Same branch, edit `tests/x.test.js` | Allowed (test pattern) |
| merge-gate-hook | `gh pr merge <n> --repo <code repo> --squash` for a PR whose cites are wrong | Blocked with the gate's first reason |
| merge-gate-hook | `gh pr merge <n> --squash` (no `--repo`) / `... --auto` | Blocked |
| push-guard | `git push origin HEAD:main` in the sandbox code repo | Blocked (default branch) |
| push-guard | `git push origin t/<n>-x` for an unclaimed branch | Blocked (no claim) |
| claim-guard | `git checkout -b t/<n>-x` for an issue with no claim on origin | Blocked |
| claim-guard | `git checkout -b feature-x` | Allowed |
| stop-backstop | With `<git-dir>/devfw/run.json` pointing at a ledger whose last two rounds stall, end the turn | Session continues once with a "post stopped <issue> stalled" instruction; the next stop ends |
| any | Same commands with `DEVFW_CORE_DIR` unset | Allowed (fail-open by design) |

Record per row: the command, the first stderr line, and allowed/blocked. Afterwards close anything the smoke opened in
the sandbox and remove the scratch worktree.
