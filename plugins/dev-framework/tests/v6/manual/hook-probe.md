# Hook payload probe (Q2, Q5)

Date: 2026-11-17. `claude --version`: `2.1.193 (Claude Code)`.
Probe: `hook-probe.sh` (scratch dir `<scratch>`, model `haiku`).

## Result: probe did not run (not authenticated)

Both attempts (the script, then a bare `claude -p --model haiku "say ok"`) failed before any model call:

```
{"type":"result","subtype":"success","is_error":true,"num_turns":1,
 "result":"Not logged in · Please run /login","total_cost_usd":0, ...}
```

`<scratch>/payloads.jsonl` was never created: no `SessionStart`, `PreToolUse` or `Stop` hook fired.

| hook_event_name | tool_name | tool_input | session_id | agent_id | agent_type |
|---|---|---|---|---|---|
| (no payloads) | | | | | |

## Verdicts

- Q2: NOT VERIFIED. `session_id` equality: not measured.
- Q5: unverified: EnterWorktree not observed.

## To re-run

From an authenticated terminal: `timeout 5m bash tests/v6/manual/hook-probe.sh`, then paste the table here.
Q2 is VERIFIED when the `echo main-probe` row has no `agent_id` and the `echo sub-probe` row has a non-empty `agent_id` and `agent_type`.
