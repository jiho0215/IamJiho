#!/bin/bash
# merge-gate-hook.sh (scenario A7): gh pr merge is blocked unless bin/merge-gate passes the PR.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/../../../hooks/scripts/merge-gate-hook.sh"
[ -x "$HOOK" ] || { echo "FAIL: hooks/scripts/merge-gate-hook.sh missing or not executable"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
unset DEVFW_CONFIG DEVFW_CORE_DIR CDPATH

CORE="$TMP/core"; mkdir -p "$CORE" "$TMP/bin"
echo '{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api"}}}' > "$CORE/orchestrator.json"
LOG="$TMP/gate.log"; LLOG="$TMP/lease.log"; : > "$LOG"; : > "$LLOG"
# Stub merge-gate: logs argv, canned JSON by --pr.
cat > "$TMP/bin/merge-gate" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
pr=""; repo=""; while [ $# -gt 0 ]; do [ "$1" = --pr ] && pr="$2"; [ "$1" = --repo ] && repo="$2"; shift; done
# I1 fence: this gate refuses every repo but the code repo, so a call for the plan repo cannot pass by accident
[ "$repo" = acme/api ] || { echo "{\"pass\":false,\"reasons\":[\"stub gate: not the code repo: $repo\"]}"; exit 0; }
case "$pr" in
  1) echo '{"pass":false,"reasons":["cites: stale P-1@abc","size: 400s > 300s"]}' ;;
  2) echo '{"pass":true,"reasons":[]}' ;;
  3) echo '{"error":"x"}'; exit 1 ;;
  4) echo 'boom on stderr' >&2; exit 1 ;;
  5) sleep 5 ;;
esac
STUB
# Stub lease: exit code from $STUB_LEASE_RC.
cat > "$TMP/bin/lease" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LLOG"
[ "${STUB_LEASE_RC:-0}" = 0 ] || echo "lease mismatch: stub"
exit "${STUB_LEASE_RC:-0}"
STUB
chmod +x "$TMP/bin/merge-gate" "$TMP/bin/lease"
export DEVFW_CORE_DIR="$CORE" DEVFW_BIN_DIR="$TMP/bin" STUB_LOG="$LOG" STUB_LLOG="$LLOG"

mkdir -p "$TMP/hooktmp"
runin() { ERR=$(jq -cn --arg c "$2" --arg cwd "$1" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}' | TMPDIR="$TMP/hooktmp" bash "$HOOK" 2>&1 >/dev/null); RC=$?; ERR="${ERR//$'\r'/}"; }
run() { runin "$TMP" "$1"; }
expect() { [ "$RC" = "$1" ] || fail "$2: rc=$RC want $1 (stderr: $ERR)"; }

run 'gh pr merge 1 --repo acme/api --squash'; expect 2 "refused PR"
[ "$(head -1 <<<"$ERR")" = "devfw merge-gate-hook: cites: stale P-1@abc" ] || fail "line 1 is reasons[0]: $ERR"
tail -n +2 <<<"$ERR" | grep -q '^size: 400s > 300s' || fail "later reasons follow: $ERR"
grep -q -- '--pr 1' "$LOG" && grep -q -- '--repo acme/api' "$LOG" && grep -q -- '--core-dir' "$LOG" || fail "gate argv: $(cat "$LOG")"
run 'gh pr merge 2 --repo acme/api --squash'; expect 0 "passing PR"
run 'gh pr merge 3 --repo acme/api'; expect 2 "gate error"
grep -q 'merge-gate could not run: x' <<<"$ERR" || fail "error text: $ERR"
run 'gh pr merge 4 --repo acme/api'; expect 2 "no JSON"
grep -q 'merge-gate could not run: .*boom on stderr' <<<"$ERR" || fail "stderr text: $ERR"
DEVFW_HOOK_GATE_TIMEOUT=1 run 'gh pr merge 5 --repo acme/api'; expect 2 "gate timeout"
grep -q 'merge-gate could not run: timed out' <<<"$ERR" || fail "timeout text: $ERR"

: > "$LOG"
run 'gh pr merge 2 --repo acme/api --auto'; expect 2 "--auto"
grep -q 'never use gh pr merge --auto' <<<"$ERR" || fail "auto text: $ERR"
[ ! -s "$LOG" ] || fail "gate called for --auto: $(cat "$LOG")"
run 'gh pr merge 2 --repo acme/api -d --auto --squash'; expect 2 "--auto among flags"
run 'gh pr merge 2 --squash'; expect 2 "no --repo"
grep -q 'pass --repo <owner/name>' <<<"$ERR" || fail "no-repo text: $ERR"
: > "$LOG"
run 'gh pr merge 1 --repo other/x'; expect 0 "unmanaged repo"
[ ! -s "$LOG" ] || fail "gate called for an unmanaged repo"
run 'gh pr view 1 --repo acme/api'; expect 0 "non-merge gh command"
run 'git status'; expect 0 "no gh at all"
run 'gh api -X PUT repos/acme/api/pulls/1/merge'; expect 2 "gh api merge of a refused PR"
run 'gh api -X PUT repos/acme/api/pulls/2/merge'; expect 0 "gh api merge of a passing PR"
# C3 / R22: gh takes the endpoint as a full URL too
run 'gh api -X PUT https://api.github.com/repos/acme/api/pulls/1/merge'; expect 2 "C3: full-URL merge of a refused PR"
grep -q '^devfw merge-gate-hook: cites: stale P-1@abc' <<<"$ERR" || fail "C3: gated, not just blocked: $ERR"
run 'gh api --method put https://ghe.example/api/v3/repos/acme/api/pulls/2/merge'; expect 0 "C3: GHE URL, passing PR"
run 'gh api -X PUT https://api.github.com/repos/acme/api/pulls/5/merge/x'; expect 2 "C3: a merge endpoint that does not read exactly"
# R25: gh aliases (gh alias set m 'pr merge') and unknown wrappers
mkdir -p "$TMP/ghbin"
cat > "$TMP/ghbin/gh" <<'STUB'
#!/bin/bash
[ "$*" = "alias list" ] || exit 1
[ "${GH_ALIAS:-ok}" = ok ] || exit 1
printf 'co: pr checkout\nm: pr merge\nq: m\nv: pr view\nsh1: !gh pr view\n'
STUB
chmod +x "$TMP/ghbin/gh"
OLDP="$PATH"; PATH="$TMP/ghbin:$PATH"
run 'gh m 2 --repo acme/api'; expect 2 "R25: gh alias expanding to pr merge"
grep -q 'cannot read this merge command exactly' <<<"$ERR" || fail "alias text: $ERR"
run 'gh co 2'; expect 0 "R25: gh co is a gh command (pr checkout)"
run 'gh q 2 --repo acme/api'; expect 2 "R29/C: gh alias chain q -> m -> pr merge"
grep -q 'cannot read this merge command exactly' <<<"$ERR" || fail "R29 gh chain text: $ERR"
run 'gh v 2'; expect 0 "R29: gh alias to a non-merge command"
run 'gh sh1 2'; expect 2 "R29: gh shell (!) alias"
run 'gh xyz 2'; expect 0 "R25: unknown gh command that is no alias"
GH_ALIAS=fail run 'gh xyz 2'; expect 0 "R25: gh alias list fails, unmanaged cwd"
git init -q "$TMP/M"; git -C "$TMP/M" remote add origin https://github.com/acme/api.git
GH_ALIAS=fail runin "$TMP/M" 'gh xyz 2'; expect 2 "R25: gh alias list fails, managed cwd"
PATH="$OLDP"
run 'winpty gh pr merge 2 --repo acme/api'; expect 2 "R25: unknown wrapper before gh"
[ -z "$(ls -A "$TMP/hooktmp")" ] || fail "M4: temp files left behind: $(ls -A "$TMP/hooktmp")"
run 'eval "gh pr merge 2 --repo acme/api"'; expect 2 "opaque merge"
grep -q 'cannot read this merge command exactly' <<<"$ERR" || fail "opaque text: $ERR"
run 'eval "gh pr view 2"'; expect 0 "opaque non-merge"
run 'gh pr merge 2 --repo acme/api && gh pr merge 1 --repo acme/api'; expect 2 "second merge refused"
run 'gh pr merge 1 --repo ACME/API'; expect 2 "repo case-insensitive match"
# --- plan 3 hardening (rulings R27, R28, R30) ---
run 'Gh pr merge 1 --repo acme/api'; expect 2 "R27/A: Gh pr merge is gated"
[ "$(head -1 <<<"$ERR")" = "devfw merge-gate-hook: cites: stale P-1@abc" ] || fail "R27: Gh read exactly (gate reason): $ERR"
DEVFW_HOOK_GATE_TIMEOUT=1 run 'Gh pr merge 5 --repo acme/api'; expect 2 "R27/A: the measured bypass reaches the gate"
grep -q 'merge-gate could not run: timed out' <<<"$ERR" || fail "R27: gate called for Gh pr merge 5: $ERR"
run 'GH.exe PR MERGE 2 --repo acme/api'; expect 0 "R27: GH.exe PR MERGE of a passing PR is read exactly"
run "python -c \"import os; os.system('gh pr merge 2 --repo acme/api')\""; expect 2 "R28/B: python -c gh pr merge"
run "script -qc 'gh pr merge 2 --repo acme/api'"; expect 2 "R28/B: script -qc"
run "git -c alias.x='!gh pr merge 2 --repo acme/api' x"; expect 2 "R30/D: -c alias.x shell alias"
run 'GH_CONFIG_DIR=/t/gh gh m 2'; expect 2 "R30: gh alias from another config dir (any)"
run 'python -c "print(1)"'; expect 0 "no-regression: python without gh"
run 'gh pr view 2 --repo acme/api'; expect 0 "no-regression: gh pr view"

# Plan repo: the lease alone decides (ruling R23); bin/merge-gate is never called for it.
: > "$LOG"; : > "$LLOG"
run 'gh pr merge 2 --repo acme/core'; expect 0 "I1: plan repo, lease ok"
grep -q 'check' "$LLOG" || fail "lease not consulted: $(cat "$LLOG")"
[ ! -s "$LOG" ] || fail "I1: merge-gate called for the plan repo: $(cat "$LOG")"
run 'gh api -X PUT repos/acme/core/pulls/7/merge'; expect 0 "I1: plan repo via gh api, lease ok"
[ ! -s "$LOG" ] || fail "I1: merge-gate called for the plan repo (gh api): $(cat "$LOG")"
STUB_LEASE_RC=4 run 'gh pr merge 2 --repo acme/core'; expect 2 "plan repo, lease mismatch"
grep -q 'only the lease holder merges plan PRs' <<<"$ERR" || fail "lease text: $ERR"
: > "$LOG"; STUB_LEASE_RC=4 run 'gh pr merge 2 --repo acme/api'; expect 0 "lease not consulted for code repos"
: > "$LLOG"; run 'gh pr merge 2 --repo acme/api'; [ ! -s "$LLOG" ] || fail "lease called for code repo"

# fix round 1
run 'gh api graphql -f query="mutation{enablePullRequestAutoMerge(input:{pullRequestId:\"x\"}){clientMutationId}}"'; expect 2 "graphql auto-merge is opaque and blocks"
run 'g=gh; $g pr merge 2 --repo acme/api'; expect 2 "R12 dynamic command word"
run 'gh pr merge 2 --repo github.com/acme/api'; expect 0 "repo as github.com/acme/api"
run 'gh pr merge 1 --repo https://github.com/acme/api.git'; expect 2 "repo as https URL is gated (refused PR)"
run 'gh pr merge --repo acme/api'; expect 2 "no PR number"
grep -q 'give the PR number' <<<"$ERR" || fail "no-pr text: $ERR"
# a broken parser: a fake node first on PATH
mkdir -p "$TMP/badnode"; printf '#!/bin/bash\nexit 1\n' > "$TMP/badnode/node"; chmod +x "$TMP/badnode/node"
OLDP="$PATH"; PATH="$TMP/badnode:$PATH"
run 'gh pr merge 2 --repo acme/api'; expect 2 "parser failure on a merge-ish command blocks"
run 'echo right'; expect 0 "parser failure on an unrelated command"
run 'gh pr view 3'; expect 0 "parser failure on gh non-merge"
PATH="$OLDP"

# Task 10 (A7 on the real sandbox): the real bin/merge-gate is a `#!/usr/bin/env node` script. On Git Bash the hook
# exports MSYS_NO_PATHCONV, so node.exe got the script path as /c/... (read as C:\c\...) and could not load it.
# A node-shebang stub in a POSIX temp dir reproduces that on Windows; on Linux this case passes either way.
if command -v node >/dev/null 2>&1; then
  mkdir -p "$TMP/nodebin"
  printf '#!/usr/bin/env node\nprocess.stdout.write(JSON.stringify({pass:true,reasons:[]})+"\\n");\n' > "$TMP/nodebin/merge-gate"
  chmod +x "$TMP/nodebin/merge-gate"
  DEVFW_BIN_DIR="$TMP/nodebin" run 'gh pr merge 2 --repo acme/api --squash'; expect 0 "a node-shebang merge-gate runs (path conversion)"
fi

# --- fix round 1 (rulings R27a, R28a, R29a) ---
run "stdbuf -oL bash -c 'gh pr merge 5 --repo acme/api --squash'"; expect 2 "R28a/C2: stdbuf -oL bash -c gh pr merge"
grep -q 'cannot read this merge command exactly' <<<"$ERR" || fail "R28a text: $ERR"
run "echo 'gh pr merge 5 --repo acme/api --squash' | bash"; expect 2 "R28a/I1: echo | bash"
run 'EXPORT GH_REPO=acme/api; gh pr merge 2 --squash'; expect 2 "R27a/C1: EXPORT sets no GH_REPO"
grep -q 'pass --repo' <<<"$ERR" || fail "R27a: no repo inferred: $ERR"
# C3 / R29a: git aliases and injected config reach merge-gate-hook (the pre-filter takes git)
git -C "$TMP/M" config alias.m '!gh pr merge 5 --repo acme/api --squash'
runin "$TMP/M" 'git m'; expect 2 "R29a/C3: git alias running gh pr merge, managed cwd"
run "git -C '$TMP/M' m"; expect 2 "R29a/C3: same alias via -C, unmanaged cwd (text names gh)"
printf '[alias]\n\tx = !gh pr merge 5 --repo acme/api --squash\n' > "$TMP/evil"
runin "$TMP/M" "git -c include.path='$TMP/evil' x"; expect 2 "R29a/C3: -c include.path"
runin "$TMP/M" "GIT_CONFIG_GLOBAL='$TMP/evil' git x"; expect 2 "R29a/C3: GIT_CONFIG_GLOBAL"
# R29a narrowing: a `!` alias that names no gh/merge counts only where it was looked up in a managed repo
git -C "$TMP/M" config alias.lg '!git log --oneline'
git init -q "$TMP/UU"; git -C "$TMP/UU" config alias.lg '!git log --oneline'
runin "$TMP/M" 'git lg'; expect 2 "R29a: a ! alias in a managed repo counts"
run "git -C '$TMP/UU' lg"; expect 0 "R29a: a ! alias naming no merge, unmanaged repo"
runin "$TMP/UU" 'git lg'; expect 0 "R29a: same, from its own unmanaged cwd"
git -C "$TMP/M" config --unset alias.m; git -C "$TMP/M" config --unset alias.lg
run 'git status'; expect 0 "no-regression: git status through the widened pre-filter"
run 'git log --oneline -3'; expect 0 "no-regression: git log"
unset DEVFW_CORE_DIR; run 'gh pr merge 1 --repo acme/api'; expect 0 "DEVFW_CORE_DIR unset"
echo "PASS: merge-gate-hook"
