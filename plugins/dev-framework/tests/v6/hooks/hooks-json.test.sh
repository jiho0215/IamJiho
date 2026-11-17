#!/bin/bash
# hooks-json: the wiring of hooks/hooks.json (Plan 3 Task 10).
# - jq parses it; every command is `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/<name>` and <name> exists and is
#   executable (git index mode 100755, since Windows' -x is not a real check);
# - no PreToolUse entry or hook carries `if` (a blocking hook pre-filters itself; an `if` is a silent skip);
# - every Edit matcher also names Write, MultiEdit and NotebookEdit;
# - the v6 rows of the Task 10 table are present with their timeouts; no EnterWorktree matcher (ruling R5);
# - every hook's timeout is greater than its script's largest inner `timeout` default (a hook timeout does not
#   block, so the script's own bound must fire first). The bounds are written `timeout N`,
#   `timeout "${VAR:-N}"`, or via a variable set from `${VAR:-N}`; hook_claim_ok's default (60) counts for a
#   script that calls it unless the script exports HOOK_NET_TIMEOUT first. Every network-call line in a wired
#   v6 script carries `timeout`.
# DEVFW_TEST_HOOKS_JSON overrides the file under test (used to show RED against an older hooks.json).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$DIR/../../.." && pwd)"
HJ="${DEVFW_TEST_HOOKS_JSON:-$PLUGIN/hooks/hooks.json}"
SCRIPTS="$PLUGIN/hooks/scripts"
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
p() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
J() { jq -r "$@" "$(p "$HJ")" | tr -d '\r'; }

jq . "$(p "$HJ")" >/dev/null 2>&1 || { echo "FAIL: jq cannot parse $HJ"; exit 1; }

# 1. commands: form, existence, executable bit.
PREFIX='bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/'
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  case "$cmd" in "$PREFIX"*) ;; *) fail "command not of the form '${PREFIX}<name>': $cmd"; continue ;; esac
  name=${cmd#"$PREFIX"}
  [[ "$name" =~ ^[A-Za-z0-9._-]+\.sh$ ]] || { fail "command carries more than a script name: $cmd"; continue; }
  [ -f "$SCRIPTS/$name" ] || { fail "script missing: hooks/scripts/$name"; continue; }
  mode=$(git -C "$PLUGIN" ls-files -s -- "hooks/scripts/$name" 2>/dev/null | awk '{print $1}' | tr -d '\r')
  if [ -n "$mode" ]; then [ "$mode" = 100755 ] || fail "hooks/scripts/$name is mode $mode in the git index, not 100755"
  else [ -x "$SCRIPTS/$name" ] || fail "hooks/scripts/$name is not executable"; fi
done < <(J '.hooks[][].hooks[].command')

# 2. no `if` on any PreToolUse entry or hook.
n=$(J '[.hooks.PreToolUse // [] | .[] | select(has("if") or any(.hooks[]; has("if")))] | length')
[ "$n" = 0 ] || fail "$n PreToolUse entr(y/ies) carry an \"if\""

# 3. every Edit matcher names the full edit-tool family.
while IFS= read -r m; do
  [ -n "$m" ] || continue
  for tool in Edit Write MultiEdit NotebookEdit; do
    tr '|' '\n' <<<"$m" | grep -qx "$tool" || fail "matcher '$m' lacks $tool"
  done
done < <(J '.hooks[][] | .matcher | select(. != null) | select(split("|") | index("Edit"))')

# 4. the v6 rows (event, matcher, script, timeout).
EDITM='Edit|Write|MultiEdit|NotebookEdit'
row() {  # row <event> <matcher> <script> <timeout>
  local got
  got=$(J --arg e "$1" --arg m "$2" --arg c "$PREFIX$3" \
    '[.hooks[$e] // [] | .[] | select(.matcher == $m) | .hooks[] | select(.command == $c) | .timeout] | map(tostring) | join(",")')
  [ "$got" = "$4" ] || fail "$1 [$2] $3: timeout(s) '${got:-none}', want exactly one entry with $4"
}
row SessionStart '*' load-chronic-patterns.sh 3
row SessionStart '*' session-digest.sh 15
row PreToolUse "$EDITM" plan-edit-guard.sh 30
row PreToolUse "$EDITM" freeze-gate.sh 30
row PreToolUse Bash plan-edit-guard.sh 30
row PreToolUse Bash merge-gate-hook.sh 120
row PreToolUse Bash push-guard.sh 30
row PreToolUse Bash claim-guard.sh 30
row Stop '*' stop-backstop.sh 30
n=$(J '[.hooks[][] | .matcher // "" | split("|")[] | select(. == "EnterWorktree")] | length')
[ "$n" = 0 ] || fail "EnterWorktree is registered, but Q5 is unmeasured (ruling R5)"

# 5. inner bounds below the hook timeout.
bound() {  # bound <script path>: largest effective default bound in seconds (0 = none)
  local f="$1" max=0 v
  local nums
  nums=$( { grep -oE 'timeout [0-9]+' "$f" | grep -oE '[0-9]+'
            grep -E 'timeout ' "$f" | grep -oE '\$\{[A-Z_]*TIMEOUT[A-Z_]*:-[0-9]+\}' | grep -oE '[0-9]+'
            grep -E '^[[:space:]]*(export[[:space:]]+)?[A-Z_]+=.*\$\{[A-Z_]*TIMEOUT:-[0-9]+\}' "$f" \
              | grep -oE ':-[0-9]+\}' | grep -oE '[0-9]+'
            if grep -q 'hook_claim_ok ' "$f" && ! grep -qE '^[[:space:]]*export HOOK_NET_TIMEOUT=' "$f"; then
              grep -E 'HOOK_NET_TIMEOUT:-[0-9]+' "$SCRIPTS/_v6-hook.sh" | grep -oE 'HOOK_NET_TIMEOUT:-[0-9]+' | grep -oE '[0-9]+$'
            fi; } | tr -d '\r')
  for v in $nums; do [ "$v" -gt "$max" ] && max=$v; done
  echo "$max"
}
while IFS=$'\t' read -r cmd to; do
  [ -n "$cmd" ] || continue
  name=${cmd#"$PREFIX"}; f="$SCRIPTS/$name"; [ -f "$f" ] || continue
  b=$(bound "$f")
  [ "$b" -lt "$to" ] || fail "$name: inner timeout bound ${b}s is not below its hook timeout ${to}s"
done < <(J '.hooks[][].hooks[] | [.command, (.timeout|tostring)] | @tsv')

# 6. every network call in a wired v6 script carries timeout (no unbounded call hides behind a small bound).
for name in session-digest.sh plan-edit-guard.sh freeze-gate.sh merge-gate-hook.sh push-guard.sh claim-guard.sh stop-backstop.sh _v6-hook.sh; do
  while IFS= read -r line; do
    grep -q 'timeout' <<<"$line" || fail "$name: network call without timeout: $line"
  done < <(grep -vE '^[[:space:]]*#' "$SCRIPTS/$name" \
    | grep -E 'gh (api|pr) |[[:space:]]fetch[[:space:]]|ls-remote|/lease"? check|/merge-gate"? ' | grep -v 'hook_block' | tr -d '\r')
done

# 7. self-check: the bound reader reads each form (so a reader regression cannot make section 5 vacuous).
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf 'x=$(timeout 7 gh api a)\n' > "$T/a.sh";                                   [ "$(bound "$T/a.sh")" = 7 ] || fail "bound reader: 'timeout N'"
printf 'x=$(timeout "${DEVFW_HOOK_NET_TIMEOUT:-21}" gh api a)\n' > "$T/b.sh";       [ "$(bound "$T/b.sh")" = 21 ] || fail "bound reader: timeout \"\${VAR:-N}\""
printf 'NET="${DEVFW_HOOK_NET_TIMEOUT:-22}"\ntimeout "$NET" gh api a\n' > "$T/c.sh"; [ "$(bound "$T/c.sh")" = 22 ] || fail "bound reader: VAR=\${X:-N}"
printf 'hook_claim_ok "$d" "$b" || rc=$?\n' > "$T/d.sh"
want=$(grep -oE 'HOOK_NET_TIMEOUT:-[0-9]+' "$SCRIPTS/_v6-hook.sh" | grep -oE '[0-9]+$' | head -1)
[ -n "$want" ] && [ "$(bound "$T/d.sh")" = "$want" ] || fail "bound reader: hook_claim_ok without export should read _v6-hook's default ($want)"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "ok hooks.json wiring"
