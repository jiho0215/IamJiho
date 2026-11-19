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
# --- fix round 2 (ruling R28b, NC1) ---
run "echo 'gh pr merge 5 --repo acme/api --squash' | bash -s x"; expect 2 "R28b/NC1: | bash -s x"
grep -q 'cannot read this merge command exactly' <<<"$ERR" || fail "R28b text: $ERR"
run "echo 'gh pr merge 5 --repo acme/api --squash' | bash /dev/stdin"; expect 2 "R28b/NC1: | bash /dev/stdin"
run 'git log | python summarize.py'; expect 0 "no-regression: git log | python summarize.py"
run 'npm test | tail'; expect 0 "no-regression: npm test | tail"
# --- fix round 3 (rulings R28c, R33) ---
run "(echo 'gh pr merge 5 --repo acme/api --squash') | bash"; expect 2 "R28c/NC2: (echo ...) | bash, unmanaged cwd"
grep -q 'cannot read this merge command exactly' <<<"$ERR" || fail "R28c text: $ERR"
run "echo 'gh pr merge 5 --repo acme/api --squash' | (bash)"; expect 2 "R28c/NC2: | (bash)"
run "echo 'gh pr merge 5 --repo acme/api --squash' | while read -r l; do eval \"\$l\"; done"; expect 2 "R28c/NC2: | while read; eval"
run 'gh pr view 5 --json mergeStateStatus | python -c "import sys"'; expect 0 "R33: mergeStateStatus is not merge"
run 'git log --merges | python summarize.py'; expect 0 "R33: --merges is not merge"
run 'git log | grep x'; expect 0 "no-regression: git log | grep x"
# --- fix round 4 (rulings R28d, R34) ---
run "echo 'gh pr merge 5 --repo acme/api --squash' > >(bash)"; expect 2 "R28d/NC3: > >(bash), unmanaged cwd"
grep -q 'cannot read this merge command exactly' <<<"$ERR" || fail "R28d text: $ERR"
run "coproc bash; echo 'gh pr merge 5 --repo acme/api --squash' >&\"\${COPROC[1]}\""; expect 2 "R28d/NC3: coproc bash"
run "x='gh pr merge 5 --repo acme/api --squash'; eval \"\$x\""; expect 2 "R28d: eval \"\$x\""
: > "$LOG"
run 'gh api -X POST repos/acme/api/merges -f base=main -f head=t/12-x'; expect 2 "R34: POST repos/<o>/<n>/merges"
grep -q '^devfw merge-gate-hook: branch merges into a managed repo go through a PR' <<<"$ERR" || fail "R34 text: $ERR"
[ ! -s "$LOG" ] || fail "R34: merge-gate called for a branch merge: $(cat "$LOG")"
runin "$TMP/M" 'gh api -X POST repos/acme/api/merges -f base=main -f head=t/12-x'; expect 2 "R34: from a managed cwd"
run 'gh api repos/acme/api/merges -f base=main -f head=t/12-x'; expect 2 "R34: fields make it a POST"
run 'gh api --method=post https://api.github.com/repos/acme/api/merges -f base=main -f head=x'; expect 2 "R34: full URL, lower-case method"
run 'gh api -XPOST /repos/acme/api/merges --input body.json'; expect 2 "R34: -XPOST, leading /, --input"
run 'gh api -X PUT http://ghe.example/api/v3/repos/acme/api/merges/ -F base=main'; expect 2 "R34: GHE URL, PUT"
run 'gh api -X POST repos/ACME/API/merges -f base=main'; expect 2 "R34: repo case-insensitive"
run 'gh api -X POST repos/acme/core/merges -f base=main -f head=x'; expect 2 "R34: the plan repo is managed"
grep -q 'branch merges into a managed repo go through a PR' <<<"$ERR" || fail "R34 plan-repo text: $ERR"
run "gh api -X POST 'repos/{owner}/{repo}/merges' -f base=main -f head=x"; expect 2 "R34: placeholder repo is unknown"
run 'gh api -X "$M" repos/acme/api/merges'; expect 2 "R34: unknown method"
run "gh api graphql -f query='mutation{mergeBranch(input:{repositoryId:\"x\",base:\"main\",head:\"t\"}){clientMutationId}}'"; expect 2 "R34: GraphQL mergeBranch"
grep -q 'branch merges into a managed repo go through a PR' <<<"$ERR" || fail "R34 graphql text: $ERR"
run "bash -c 'gh api -X POST repos/acme/api/merges -f base=main -f head=x'"; expect 2 "R34: opaque form names the endpoint"
run 'gh api -X POST repos/other/x/merges -f base=main -f head=x'; expect 0 "R34: an unmanaged repo is not ours"
run 'gh api repos/acme/api/merges'; expect 0 "R34: a GET is no merge"
run "git commit -F - <<'EOF'
fix: then merge and push
EOF"; expect 0 "no-regression: heredoc commit naming merge"
run "git commit -m \"\$(cat <<'EOF'
fix: merge it, then push
EOF
)\""; expect 0 "no-regression: \$(cat <<'EOF') commit naming merge"
run 'cat file > out.txt'; expect 0 "no-regression: cat file > out.txt"
run 'gh pr view 5 --json mergeStateStatus'; expect 0 "no-regression: gh pr view --json mergeStateStatus"
run 'git push origin t/12-x'; expect 0 "no-regression: git push"
# --- fix round 5 (rulings R34a, NC5) ---
run "GH_REPO=github.com/acme/api gh api -X POST 'repos/{owner}/{repo}/merges' -f base=main -f head=t/12-x"; expect 2 "NC5: host-qualified GH_REPO normalised before the managed compare"
grep -q 'branch merges into a managed repo go through a PR' <<<"$ERR" || fail "NC5 text: $ERR"
run "GH_REPO=https://github.com/acme/api gh api -X POST 'repos/{owner}/{repo}/merges' -f base=main -f head=x"; expect 2 "NC5: https:// GH_REPO form"
runin "$TMP/M" "export GH_REPO=github.com/acme/api; gh api -X POST 'repos/{owner}/{repo}/merges' -f base=main"; expect 2 "NC5: exported GH_REPO, managed cwd"
run 'gh api repos/acme/api/merges -if base=main -if head=t/12-x'; expect 2 "R34a: combined -if cluster is a field (implicit POST)"
grep -q 'branch merges into a managed repo go through a PR' <<<"$ERR" || fail "R34a -if text: $ERR"
run 'gh api repos/acme/api/merges -fi base=main'; expect 2 "R34a: -fi cluster is a field"
run 'gh api repos/acme/api/merges -i base=main'; expect 0 "R34a: -i alone is not a field (GET, no merge)"
run "GH_REPO=github.com/other/x gh api -X POST 'repos/{owner}/{repo}/merges' -f base=main"; expect 0 "NC5: an unmanaged host-qualified repo is not ours"
# --- ruling R35: an unaccounted mention + a non-data program = one whole-command row, unknown dir ---
for c in "printf -v x 'gh pr merge 1 --repo acme/api --squash'; bash -lc \"\$x\"" \
  "printf -v x 'gh pr merge 1 --repo acme/api --squash'; sudo bash -c \"\$x\"" \
  "cmd=(gh pr merge 1 --repo acme/api --squash); \"\${cmd[@]}\"" \
  "declare -x X='gh pr merge 1 --repo acme/api'; python -c 'import os; os.system(os.environ[\"X\"])'" \
  "printf -v x 'gh pr merge 1 --repo acme/api'; python -c 'import os,sys; os.system(sys.argv[1])' \"\$x\"" \
  "printf -v x 'gh api -X POST repos/acme/api/merges -f base=main -f head=x'; nohup bash -c \"\$x\""; do
  run "$c"; expect 2 "R35 (NC6-NC9): $c"
done
grep -q 'cannot read this merge command exactly' <<<"$ERR" || fail "R35 text: $ERR"
# per-guard verb: an unaccounted `git push` mention is not a merge, though the command text says merge (a read git merge)
run 'npm test && git commit -m "docs: explain git push flow" && git merge --ff-only main'; expect 0 "R35: a push mention is not merge-gate's"
run 'npm test && git commit -m "docs: then gh pr merge it"'; expect 2 "R35: a gh pr merge mention in a message beside npm (the stated cost)"
run 'BR=$(git branch --show-current); npm test && node scripts/lint.js && git push origin t/12-x'; expect 0 "R35/NI2"
run 'npm test && gh pr view 5 --json mergeStateStatus'; expect 0 "R35: a read gh call accounts for itself"
run "gh pr create --title x --body \"\$(cat <<'EOF'
Explains git push and gh pr merge.
EOF
)\""; expect 0 "R35: gh pr create body naming gh pr merge"
# --- R35 fix round 1: C1, R35a, R35b ---
for c in "printf -v x 'gh pr --repo \"acme/api|x\" merge 1'; node -p \"require('child_process').execSync(process.argv[1]).toString()\" \"\$x\"" \
  "printf -v x 'gh pr 2>&1 merge 1 --repo acme/api'; sudo bash -c \"\$x\"" \
  "printf -v 'a[\$(gh pr merge 1 --repo acme/api)]' x" \
  "git submodule foreach 'gh pr merge 1 --repo acme/api'"; do
  run "$c"; expect 2 "R35 round 1: $c"
done
run "echo 'gh pr view 1 | grep merge' && npm test"; expect 0 "C1: | ends the run (merge)"
# --- R35 fix round 2 (ruling R35c) ---
run "printf -v x \"gh pr --repo \$(echo \"acme/api\") merge 1\"; sudo bash -c \"\$x\""; expect 2 "R35c B: nested \"...\" in \$( ) inside \"...\""
run "x=\$(true)#; printf -v y 'gh pr merge 1 --repo acme/api'; sudo bash -c \"\$y\""; expect 2 "R35c A: # after ) is no comment"
run 'npm test && (true) # gh pr merge 1 --repo acme/api'; expect 2 "R35d: no mention is dropped as a comment (merge)"
# --- R35 fix round 3 (ruling R35d) ---
run ": \$[ #]; printf -v y 'gh pr merge 1 --repo acme/api'; sudo bash -c \"\$y\""; expect 2 "R35d Crit1: \$[ #] (merge)"
run "printf -v x \"gh pr --repo acme/api\$[ 0|0 ] merge 1\"; sudo bash -c \"\$x\""; expect 2 "R35d: the | inside \$[ ] is arithmetic, not a terminator"
run "printf -v x \"gh pr --repo \$(case a in a) echo \"acme/api\" ;; esac) merge 1\"; sudo bash -c \"\$x\""; expect 2 "R35d Crit2: case ) in \$( (merge)"
# --- R35 fix round 4 (ruling R35e) ---
NL=$'\n'
PADX="echo \"$(printf '%17000s' '' | tr ' ' x)\"; "
PYS="python3 -c 'import sys; exec(sys.argv[1])' \"\$x\""
run "${PADX}printf -v x 'import os; os.system(\"gh pr \"${NL}\"merge 1 --repo acme/api\")'; $PYS"
expect 2 "R35e N1: above the size cap the verb on the next line still counts (merge)"
run "${PADX}printf -v x 'import os; os.system(\"gh api -X PUT \"${NL}\"repos/acme/api/merges\")'; $PYS"
expect 2 "R35e N1: above the size cap, the branch-merge API on the next line"
run "printf -v x \"gh pr --repo \$(case a in b) echo esac ;; a) echo acme/api ;; esac) merge 1\"; sudo bash -c \"\$x\""
expect 2 "R35e Crit2: an argument esac does not end the case (merge)"
run "printf -v x \"gh pr --repo \$(: # )${NL}echo acme/api) merge 1\"; sudo bash -c \"\$x\""
expect 2 "R35e: a ) in a comment does not close \$( (merge)"
t0=$(date +%s%N)
run "echo $(printf 'gh pr %.0s' $(seq 4500))${NL}printf -v x 'import os; os.system(\"gh pr merge 1 --repo acme/api\")'; $PYS"
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
expect 2 "R35e Imp3: 27 KB of gh pr words, merge on the next line"
[ "$ms" -lt 10000 ] || fail "R35e Imp3: 27 KB took ${ms} ms (bound 10000; the hook timeout is 30 s)"
# a whole-command row (here: nesting deeper than the parser reads) is matched on its text by this hook's own regex:
# 1 MB of repos/repos/... must not make that regex pass the hook timeout (it did with repos/\S*/merges)
# (1 MB is past the Windows command-line limit, so the command goes to jq through a file, not --arg)
printf '%s' "echo $(printf 'repos/%.0s' $(seq 170000)) \$($(printf '$(%.0s' $(seq 60000)); printf -v x 'import os; os.system(\"gh pr merge 1 --repo acme/api\")'; $PYS" > "$TMP/big.txt"
t0=$(date +%s%N)
ERR=$(jq -cn --rawfile c "$TMP/big.txt" --arg cwd "$TMP" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}' | TMPDIR="$TMP/hooktmp" bash "$HOOK" 2>&1 >/dev/null); RC=$?
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
expect 2 "R35e: 1 MB whole-command row over repos/ words"
[ "$ms" -lt 10000 ] || fail "R35e: 1 MB repos/ row took ${ms} ms (bound 10000; the hook timeout is 30 s)"
run "sudo gh api -X PUT repos/acme/api/merges -f base=main -f head=x"; expect 2 "R34/R35e: a branch-merge API path in a whole-segment row"
run "sudo gh api repos/acme/api/mergesx"; expect 0 "R35e: mergesx is not the merges endpoint"
# --- R35 fix round 5 (ruling R35f) ---
AWK="awk 'BEGIN{system(ARGV[1])}' \"\$x\""
run "printf -v x \"gh pr --repo \$(case a in b|esac) echo X ;; a) echo acme/api ;; esac) merge 1\"; $AWK"
expect 2 "R35f B1: esac after a pattern-list | (merge)"
run "printf -v x \"gh pr --repo \$(: # '${NL}: '${NL}) \" '; echo acme/api) merge 1\"; sudo bash -c \"\$x\""
expect 2 "R35f B2: a quote inside a # comment (merge)"
t0=$(date +%s%N)
run "$(printf 'gh pr merge 1 --repo other/x; %.0s' $(seq 120))gh pr merge 1 --repo acme/api"
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
expect 2 "R35f O1: 120 merge calls"
grep -q 'too complex to check in time' <<<"$ERR" || fail "R35f O1 text: $ERR"
[ "$ms" -lt 20000 ] || fail "R35f O1: 120 calls took ${ms} ms end to end (bound 20000)"
unset DEVFW_CORE_DIR; run 'gh pr merge 1 --repo acme/api'; expect 0 "DEVFW_CORE_DIR unset"
echo "PASS: merge-gate-hook"
