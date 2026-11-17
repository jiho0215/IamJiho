#!/usr/bin/env bash
# Measures whether Claude Code hook payloads identify subagents (Q2) and whether
# EnterWorktree fires a PreToolUse hook (Q5). Runs in a scratch dir; touches no repo.
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
scratch=$(mktemp -d)
mkdir -p "$scratch/work"
out="$scratch/payloads.jsonl"
: > "$out"
sc=$(cygpath -m "$scratch" 2>/dev/null || echo "$scratch")

# Logger: compact stdin to exactly one JSON line.
cat > "$scratch/log.sh" <<LOG
#!/usr/bin/env bash
jq -c . >> "$sc/payloads.jsonl" 2>/dev/null || { cat; echo; } >> "$sc/payloads.jsonl"
LOG
chmod +x "$scratch/log.sh"

hook='{"hooks":[{"type":"command","command":"bash '"$sc"'/log.sh"}]}'
cat > "$scratch/settings.json" <<JSON
{"hooks":{
 "PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"bash $sc/log.sh"}]}],
 "SessionStart":[{"hooks":[{"type":"command","command":"bash $sc/log.sh"}]}],
 "Stop":[{"hooks":[{"type":"command","command":"bash $sc/log.sh"}]}]
}}
JSON

prompt='Do these in order. 1) Run `echo main-probe` with the Bash tool. 2) Use the Agent tool (subagent_type general-purpose) with a prompt telling it to run `echo sub-probe` with Bash and report the output. 3) Call the EnterWorktree tool with name "probe". Report what happened to each step.'

cd "$scratch/work" || exit 1
timeout 5m claude -p --model haiku --settings "$sc/settings.json" \
  --allowedTools "Bash(echo *)" Agent EnterWorktree \
  --output-format json "$prompt" > "$scratch/result.json" 2> "$scratch/stderr.txt"
echo "claude exit: $?  scratch: $scratch"
echo "--- result.json ---"; cat "$scratch/result.json"; echo
echo "--- table ---"
jq -r '[.hook_event_name, (.tool_name // "-"),
        ((.tool_input.command // .tool_input.prompt // (.tool_input|tostring)) // "-" | tostring | .[0:50]),
        (.session_id // "-"), (.agent_id // "-"), (.agent_type // "-")] | @tsv' "$out" | tr -d '\r'
