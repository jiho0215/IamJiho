#!/bin/bash
# plan-edit-guard.sh (scenario A7): only the lease holder edits the plan.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/../../../hooks/scripts/plan-edit-guard.sh"
[ -x "$HOOK" ] || { echo "FAIL: hooks/scripts/plan-edit-guard.sh missing or not executable"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
fail() { echo "FAIL: $*"; exit 1; }
unset DEVFW_CONFIG DEVFW_CORE_DIR

g init -q --bare "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/core" 2>/dev/null
CORE="$TMP/core"
mkdir -p "$CORE/docs/plan" "$CORE/.orchestrator"
printf 'orchestrator: 00000000000000aa · box1 · since 2026-11-16T00:00:00Z\n\n# Start here\n' > "$CORE/docs/plan/START-HERE.md"
echo plan > "$CORE/docs/plan/PLAN.md"; echo readme > "$CORE/README.md"
g -C "$CORE" add -A; g -C "$CORE" commit -qm init; g -C "$CORE" push -q origin main
echo '{"plan":{"repo":"acme/core"}}' > "$CORE/orchestrator.json"
echo 00000000000000aa > "$CORE/.orchestrator/lease"
export DEVFW_CORE_DIR="$CORE"

# run <json> -> RC, ERR (stderr)
run() { ERR=$(printf '%s' "$1" | bash "$HOOK" 2>&1 >/dev/null); RC=$?; ERR="${ERR//$'\r'/}"; }
edit() { printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s"}%s}' "$CORE" "$1" "${2:-}"; }
bash_() { jq -cn --arg c "$1" --arg cwd "${2:-$CORE}" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}'; }
expect() { [ "$RC" = "$1" ] || fail "$2: rc=$RC want $1 (stderr: $ERR)"; }

run "$(edit "$CORE/docs/plan/PLAN.md")"; expect 0 "equal tokens"
run "$(edit "$CORE/docs/plan/PLAN.md" ',"agent_id":"a1"')"; expect 2 "subagent (rule 4)"
grep -q 'subagents never edit the plan' <<<"$ERR" || fail "subagent message: $ERR"
run "$(edit "$CORE/docs/plan/PLAN.md" ',"agent_id":""')"; expect 0 "empty agent_id is the main session"

echo ffffffffffffffff > "$CORE/.orchestrator/lease"
run "$(edit "$CORE/docs/plan/PLAN.md")"; expect 2 "token mismatch"
head -1 <<<"$ERR" | grep -q '^devfw plan-edit-guard: .*lease mismatch' || fail "mismatch line 1: $ERR"
run "$(edit "docs/plan/PLAN.md")"; expect 2 "relative path resolves against cwd"
run "$(edit "$CORE/docs/plan/../plan/PLAN.md")"; expect 2 "dot-dot path"
if command -v cygpath >/dev/null 2>&1; then
  W=$(cygpath -w "$CORE")
  run "$(jq -cn --arg p "$W\docs\plan\PLAN.md" '{tool_name:"Write",tool_input:{file_path:$p}}')"
  expect 2 "backslash path"
else echo "skip: backslash form (not Windows)"; fi
run "$(jq -cn --arg p "$CORE/docs/plan/n.ipynb" '{tool_name:"NotebookEdit",tool_input:{notebook_path:$p}}')"
expect 2 "notebook_path"
run "$(edit "$CORE/README.md")"; expect 0 "out of scope under mismatch"
run "$(edit "$CORE/docs/planning/x.md")"; expect 0 "sibling dir with plan prefix is out of scope"
unset DEVFW_CORE_DIR; run "$(edit "$CORE/docs/plan/PLAN.md")"; expect 0 "DEVFW_CORE_DIR unset"
export DEVFW_CORE_DIR="$CORE"

# Bash commit: scope from what the commit would contain.
echo more >> "$CORE/docs/plan/PLAN.md"; g -C "$CORE" add docs/plan/PLAN.md
run "$(bash_ 'git commit -m x')"; expect 2 "commit with staged plan file, mismatched token"
grep -q lease <<<"$ERR" || fail "commit block message: $ERR"
run "$(bash_ 'git status')"; expect 0 "non-commit command"
run "$(bash_ 'git commit -m x' "$TMP")"; expect 0 "commit outside core"
run "$(bash_ "cd '$CORE' && git commit -m x" "$TMP")"; expect 2 "cd into core then commit"
run "$(bash_ "git -C '$CORE' commit -m x" "$TMP")"; expect 2 "git -C core commit from cwd outside core"
g init -q "$TMP/other"; mkdir -p "$TMP/other/docs/plan"; echo o > "$TMP/other/docs/plan/f"; g -C "$TMP/other" add docs/plan/f
run "$(bash_ "git -C '$TMP/other' commit -m x")"; expect 0 "cwd in core, -C outside repo"
run "$(bash_ 'cd "$D" && git commit -m x' "$TMP")"; expect 2 "R9: non-literal cd, cwd outside core"
# C1 / R20: one fence per opaque-scope trigger, cwd outside core (the old regex missed ~, globs, pushd, popd)
HOME="$TMP" run "$(bash_ 'cd ~/core && git commit -m x' "$TMP")"; expect 2 "C1: cd ~/core resolves into core (home)"
grep -q lease <<<"$ERR" || fail "C1 ~ text: $ERR"
run "$(bash_ 'cd ~nosuchuser/core && git commit -m x' "$TMP")"; expect 2 "R20 trigger: unknown dir (~user)"
run "$(bash_ 'pushd $D && git commit -m x' "$TMP")"; expect 2 "R20 trigger: pushd <dynamic>"
run "$(bash_ 'popd && git commit -m x' "$TMP")"; expect 2 "R20 trigger: popd"
run "$(bash_ "cd '$TMP'/cor* && git commit -m x" "$TMP")"; expect 2 "R20 trigger: glob"
run "$(bash_ "stdbuf -oL git -C '$CORE' commit -m x" "$TMP")"; expect 2 "R20 trigger: opaque segment's literal dir is core"
run "$(bash_ "stdbuf -oL git -C '$TMP/other' commit -m x" "$TMP")"; expect 0 "opaque segment's literal dir outside core"
git -C "$CORE" config alias.ci commit
run "$(bash_ 'git ci -m x')"; expect 2 "R25: alias for commit in core"
run "$(bash_ "git -C '$CORE' ci -m x" "$TMP")"; expect 2 "R25: alias of -C core, cwd outside"
git -C "$CORE" config --unset alias.ci
CM=$(cygpath -m "$CORE" 2>/dev/null || echo "$CORE")
run "$(bash_ "cd '$CM' && eval \"git commit -m x\"" "$TMP")"; expect 2 "R9: opaque naming core path (C:/ form)"
if command -v cygpath >/dev/null 2>&1; then
  CU="/${CM:0:1}${CM:2}"   # C:/x -> /C/x (compare is case-insensitive on Windows)
  run "$(bash_ "cd '$CU' && eval \"git commit -m x\"" "$TMP")"; expect 2 "R9: /c/ form"
  run "$(bash_ "cd '$(cygpath -w "$CM")' && eval \"git commit -m x\"" "$TMP")"; expect 2 "R9: backslash form"
fi
run "$(bash_ 'eval "git commit -m x"' "$TMP")"; expect 0 "R9 residual: eval, no core path, cwd outside core"
# R9 text trigger alone: the core path only inside the eval string (no cd, dir not readable, cwd outside core)
run "$(bash_ "eval \"git -C '$CM' commit -m x\"" "$TMP")"; expect 2 "R9 trigger: core path named only inside an opaque string"
run "$(printf '{"tool_name":"MultiEdit","cwd":"%s","tool_input":{"file_path":"%s","edits":[]}}' "$CORE" "$CORE/docs/plan/PLAN.md")"
expect 2 "MultiEdit"
run "$(bash_ 'eval "git commit -m x"')"; expect 2 "opaque in core"
run "$(bash_ 'eval "git commit -m x"' "$TMP")"; expect 0 "opaque outside core"
g -C "$CORE" reset -q; g -C "$CORE" checkout -q -- docs/plan/PLAN.md
echo r2 >> "$CORE/README.md"; g -C "$CORE" add README.md
run "$(bash_ 'git commit -m x')"; expect 0 "only README staged"
g -C "$CORE" reset -q; echo r3 >> "$CORE/docs/plan/PLAN.md"
run "$(bash_ 'git commit -am x')"; expect 2 "R2: unstaged tracked plan change with -a"
g -C "$CORE" checkout -q -- docs/plan/PLAN.md README.md
echo 00000000000000aa > "$CORE/.orchestrator/lease"
echo more >> "$CORE/docs/plan/PLAN.md"; g -C "$CORE" add docs/plan/PLAN.md
run "$(bash_ 'git commit -m x')"; expect 0 "commit with plan file, equal tokens"
g -C "$CORE" reset -q; g -C "$CORE" checkout -q -- docs/plan/PLAN.md

# Missing token -> "no lease"
rm "$CORE/.orchestrator/lease"
run "$(edit "$CORE/docs/plan/PLAN.md")"; expect 2 "no local token"
grep -q 'no lease' <<<"$ERR" || fail "no-lease message: $ERR"
echo 00000000000000aa > "$CORE/.orchestrator/lease"

# origin gone: out of scope never fetches; in scope cannot verify.
g -C "$CORE" remote set-url origin "$TMP/gone.git"
run "$(edit "$CORE/README.md")"; expect 0 "README with origin deleted"
run "$(edit "$CORE/docs/plan/PLAN.md")"; expect 2 "plan edit with origin deleted"
grep -q 'cannot verify' <<<"$ERR" || fail "cannot-verify message: $ERR"

# Lease-call outcomes through a stub bin dir (DEVFW_BIN_DIR): 3, 1, and a hang cut by DEVFW_HOOK_NET_TIMEOUT.
STUB="$TMP/stub"; mkdir -p "$STUB"
stub() { printf '#!/bin/bash\n%s\n' "$1" > "$STUB/lease"; chmod +x "$STUB/lease"; }
export DEVFW_BIN_DIR="$STUB"
g -C "$CORE" remote set-url origin "$TMP/origin.git"
stub 'echo "lease: no lease line" >&2; exit 3'
run "$(edit "$CORE/docs/plan/PLAN.md")"; expect 2 "stub exit 3"
grep -q '^devfw plan-edit-guard: no lease' <<<"$ERR" || fail "exit 3 message: $ERR"
stub 'exit 1'
run "$(edit "$CORE/docs/plan/PLAN.md")"; expect 2 "stub exit 1"
grep -q 'cannot verify' <<<"$ERR" || fail "exit 1 message: $ERR"
stub 'exec sleep 10'
S=$SECONDS; DEVFW_HOOK_NET_TIMEOUT=1 run "$(edit "$CORE/docs/plan/PLAN.md")"
expect 2 "hung lease check"; [ $((SECONDS - S)) -lt 8 ] || fail "timeout not applied"
grep -q 'cannot verify' <<<"$ERR" || fail "timeout message: $ERR"
unset DEVFW_BIN_DIR
echo ok
