#!/bin/bash
# plan-edit-guard.sh (scenario A7): only the lease holder edits the plan.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/../../../hooks/scripts/plan-edit-guard.sh"
[ -x "$HOOK" ] || { echo "FAIL: hooks/scripts/plan-edit-guard.sh missing or not executable"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
fail() { echo "FAIL: $*"; exit 1; }
unset DEVFW_CONFIG DEVFW_CORE_DIR CDPATH

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
# R28 adjudication: was "expect 0" (the R9 residual); eval mentioning git has an unknown dir now
run "$(bash_ 'eval "git commit -m x"' "$TMP")"; expect 2 "R28: eval, no core path, cwd outside core (R9 residual closed)"
# R9 text trigger alone: the core path only inside the eval string (no cd, dir not readable, cwd outside core)
run "$(bash_ "eval \"git -C '$CM' commit -m x\"" "$TMP")"; expect 2 "R9 trigger: core path named only inside an opaque string"
run "$(printf '{"tool_name":"MultiEdit","cwd":"%s","tool_input":{"file_path":"%s","edits":[]}}' "$CORE" "$CORE/docs/plan/PLAN.md")"
expect 2 "MultiEdit"
run "$(bash_ 'eval "git commit -m x"')"; expect 2 "opaque in core"
run "$(bash_ 'stdbuf -oL git commit -m x' "$TMP")"; expect 0 "opaque (R25, dir known) outside core"
# --- plan 3 hardening (rulings R27-R31); the plan file is staged and the lease mismatched here ---
run "$(bash_ 'GIT commit -m x')"; expect 2 "R27/A: GIT commit in core"
grep -q lease <<<"$ERR" || fail "R27: GIT commit is read exactly (lease checked): $ERR"
git -C "$CORE" config alias.ci commit
run "$(bash_ 'GIT ci -m x')"; expect 2 "R27/A: GIT + an alias (case-insensitive pre-filter)"
git -C "$CORE" config alias.q ci
run "$(bash_ 'git q -m x')"; expect 2 "R29/C: q -> ci -> commit"
git -C "$CORE" config --unset alias.q; git -C "$CORE" config --unset alias.ci
run "$(bash_ "python -c \"import os; os.system('git commit -m x')\"" "$TMP")"; expect 2 "R28/B: python -c, cwd outside core"
run "$(bash_ "script -qc 'git commit -m x'" "$TMP")"; expect 2 "R28/B: script -qc, cwd outside core"
run "$(bash_ "perl -e 'system(\"git commit -m x\")'" "$TMP")"; expect 2 "R28/B: perl -e, cwd outside core"
run "$(bash_ "bash -c 'cd ~/api && git commit -m x'" "$TMP")"; expect 2 "R28/B: bash -c, cwd outside core"
run "$(bash_ 'git -c alias.x=commit x -m x')"; expect 2 "R30/D: -c alias.x in core"
run "$(bash_ 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.x GIT_CONFIG_VALUE_0=commit git x -m x')"; expect 2 "R30/D: GIT_CONFIG_COUNT"
run "$(bash_ 'git --config-env=alias.x=V x -m x')"; expect 2 "R30/D: --config-env"
run "$(bash_ 'cd core && git commit -m x' "$TMP/other")"; expect 0 "R31 baseline: no CDPATH, other/core is not core"
run "$(bash_ "export CDPATH='$TMP'; cd core && git commit -m x" "$TMP/other")"; expect 2 "R31/E: export CDPATH"
CDPATH="$TMP" run "$(bash_ 'cd core && git commit -m x' "$TMP/other")"; expect 2 "R31/E: CDPATH in the hook's environment"
run "$(bash_ 'Git status')"; expect 0 "no-regression: Git status in core"
run "$(bash_ 'git -c color.ui=never status')"; expect 0 "no-regression: harmless -c in core"
run "$(bash_ 'python -c "print(1)"')"; expect 0 "no-regression: python without git"
run "$(bash_ 'git push origin t/12-x')"; expect 0 "no-regression: push"
# --- fix round 1 (rulings R27a, R28a) ---
mkdir -p "$TMP/elsewhere"
run "$(bash_ "CD '$TMP/elsewhere'; git commit -m x")"; expect 2 "R27a/C1: CD does not move the shell (commit in core)"
grep -q lease <<<"$ERR" || fail "R27a: the commit is read in core: $ERR"
run "$(bash_ "stdbuf -oL bash -c 'git commit -m x'")"; expect 2 "R28a/C2: stdbuf -oL bash -c in core"
run "$(bash_ "stdbuf -oL bash -c 'git commit -m x'" "$TMP")"; expect 2 "R28a/C2: from outside core (dir unknown)"
run "$(bash_ "echo 'git commit -m x' | bash" "$TMP")"; expect 2 "R28a/I1: echo | bash from outside core"
run "$(bash_ "cd '$TMP' && git commit -m x")"; expect 0 "no-regression: a real cd out of core"
# --- fix round 2 (ruling R28b, NC1) ---
run "$(bash_ "echo 'git commit -m x' | bash -s x")"; expect 2 "R28b/NC1: | bash -s x in core"
run "$(bash_ "echo 'git commit -m x' | bash -s x" "$TMP")"; expect 2 "R28b/NC1: | bash -s x from outside core"
run "$(bash_ "source /dev/stdin <<< 'git commit -m x'" "$TMP")"; expect 2 "R28b/NC1: source /dev/stdin from outside core"
run "$(bash_ 'git log | python summarize.py')"; expect 0 "no-regression: git log | python summarize.py"
run "$(bash_ 'npm test | tail')"; expect 0 "no-regression: npm test | tail"
# --- fix round 3 (rulings R28c, R33) ---
run "$(bash_ "echo 'git commit -m x' | (bash)")"; expect 2 "R28c/NC2: | (bash) in core"
run "$(bash_ "(echo 'git commit -m x') | bash" "$TMP")"; expect 2 "R28c/NC2: (echo ...) | bash from outside core"
run "$(bash_ "echo 'git commit -m x' | while read -r l; do eval \"\$l\"; done" "$TMP")"; expect 2 "R28c/NC2: | while read; eval from outside core"
run "$(bash_ 'git log --oneline | python -c "print(1)" # committed' "$TMP")"; expect 0 "R33: committed is not the verb commit"
run "$(bash_ 'git log | grep x')"; expect 0 "no-regression: git log | grep x"
# --- fix round 4 (ruling R28d, NC3) ---
run "$(bash_ "echo 'git commit -m x' > >(bash)")"; expect 2 "R28d/NC3: > >(bash) in core"
run "$(bash_ "echo 'git commit -m x' > >(bash)" "$TMP")"; expect 2 "R28d/NC3: > >(bash) from outside core"
run "$(bash_ "coproc bash; echo 'git commit -m x' >&\"\${COPROC[1]}\"" "$TMP")"; expect 2 "R28d/NC3: coproc from outside core"
run "$(bash_ "x='git commit -m x'; eval \"\$x\"" "$TMP")"; expect 2 "R28d: eval \"\$x\" from outside core"
run "$(bash_ "git commit -F - <<'EOF'
fix: then commit and push
EOF" "$TMP")"; expect 0 "no-regression: heredoc commit outside core"
run "$(bash_ "git commit -m \"\$(cat <<'EOF'
fix: run python, eval, then push
EOF
)\"" "$TMP")"; expect 0 "no-regression: \$(cat <<'EOF') commit outside core"
run "$(bash_ 'cat file > out.txt')"; expect 0 "no-regression: cat file > out.txt in core"
run "$(bash_ 'gh pr view 5 --json mergeStateStatus')"; expect 0 "no-regression: gh pr view in core"
# --- fix round 5 (ruling R28e, NC4; NI1 no-regression) ---
run "$(bash_ "export X='git commit -m x'; bash -c 'eval \"\$X\"'")"; expect 2 "NC4: export carries a commit into a runner (core)"
run "$(bash_ "export X='git commit -m x'; bash -c 'eval \"\$X\"'" "$TMP")"; expect 2 "NC4: export, outside core"
run "$(bash_ "x='git commit -m x'; eval \"\$x\"")"; expect 2 "R28e(a): eval \"\$x\" still blocks"
# NI1: the repo's own node test command chained before an ordinary commit must NOT be read as a plan commit
run "$(bash_ 'node --test tests/v6/node/*.test.mjs && git add -A && git commit -m x' "$TMP")"; expect 0 "NI1: node --test glob then a commit outside core"
run "$(bash_ 'python -m pytest -k "$K" && git commit -m x' "$TMP")"; expect 0 "NI1: pytest -k then a commit outside core"
# --- ruling R35: an unaccounted mention + a non-data program = one whole-command row, unknown dir (from outside core) ---
for c in "printf -v x 'git commit -m x'; bash -lc \"\$x\"" "printf -v x 'git commit -m x'; nohup bash -c \"\$x\"" \
  "cmd=(git commit -m x); \"\${cmd[@]}\"" "printf -v x 'git commit -m x'; \${x:-}" \
  "declare -x X='git commit -m x'; python -c 'import os; os.system(os.environ[\"X\"])'" \
  "printf -v x 'git commit -m x'; python -c 'import os,sys; os.system(sys.argv[1])' \"\$x\""; do
  run "$(bash_ "$c" "$TMP")"; expect 2 "R35 (NC6-NC9) outside core: $c"
done
# per-guard verb: the unaccounted mention is a push, not a commit, though the text holds `git commit` (read, outside core)
run "$(bash_ 'npm test && git commit -m "docs: explain git push flow"' "$TMP")"; expect 0 "R35: a push mention is not plan-edit's"
run "$(bash_ 'npm test && git commit -m "docs: run git commit -a later"' "$TMP")"; expect 2 "R35: a commit mention in a message beside npm (the stated cost)"
run "$(bash_ 'BR=$(git branch --show-current); npm test && node x.js && git commit -m x' "$TMP")"; expect 0 "R35/NI2: outside core"
run "$(bash_ "echo 'git commit -m x' > notes.md" "$TMP")"; expect 0 "R35: echo is data"
# --- R35 fix round 1: C1, R35a, R35b (from outside core) ---
for c in "printf -v x 'git 2>&1 commit -m x'; sudo bash -c \"\$x\"" "declare -i w='r[\$(git commit -m x)]'" \
  "git bisect run sh -c 'git commit -m x'"; do
  run "$(bash_ "$c" "$TMP")"; expect 2 "R35 round 1 outside core: $c"
done
run "$(bash_ 'npm test && git status # then git commit -m x' "$TMP")"; expect 2 "R35d (was M2): a commit named in a comment beside npm is the stated cost"
# --- R35 fix round 2 (ruling R35c) ---
run "$(bash_ "printf -v x \"git -C \$(echo \".\" ) commit -m x\"; sudo bash -c \"\$x\"" "$TMP")"; expect 2 "R35c B: nested \"...\" in \$( ) (commit)"
run "$(bash_ "echo \${x:- #}; printf -v y 'git commit -m x'; sudo bash -c \"\$y\"" "$TMP")"; expect 2 "R35c A: # inside \${ } is no comment"
# --- R35 fix round 3 (ruling R35d) ---
run "$(bash_ ": \$[ #]; printf -v y 'git commit -m x'; sudo bash -c \"\$y\"" "$TMP")"; expect 2 "R35d Crit1: \$[ #] (commit)"
run "$(bash_ "printf -v x \"git -C \$(case a in a) echo \".\" ;; esac) commit -m x\"; sudo bash -c \"\$x\"" "$TMP")"; expect 2 "R35d Crit2: case ) in \$( (commit)"
# --- R35 fix round 4 (ruling R35e) ---
NL=$'\n'
PADX="echo \"$(printf '%17000s' '' | tr ' ' x)\"; "
PYS="python3 -c 'import sys; exec(sys.argv[1])' \"\$x\""
run "$(bash_ "${PADX}printf -v x 'import os; os.system(\"git \"${NL}\"commit -m x\")'; $PYS" "$TMP")"
expect 2 "R35e N1: above the size cap the verb on the next line still counts (commit)"
run "$(bash_ "printf -v x \"git -C \$(case a in b) echo esac ;; a) echo . ;; esac) commit -m x\"; sudo bash -c \"\$x\"" "$TMP")"
expect 2 "R35e Crit2: an argument esac does not end the case (commit)"
run "$(bash_ "printf -v x \"git -C \$(: # )${NL}) commit -m x\"; sudo bash -c \"\$x\"" "$TMP")"
expect 2 "R35e: a ) in a comment does not close \$( (commit)"
t0=$(date +%s%N)
run "$(bash_ "echo $(printf 'gh pr %.0s' $(seq 4500))${NL}printf -v x 'import os; os.system(\"git commit -m x\")'; $PYS" "$TMP")"
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
expect 2 "R35e Imp3: 27 KB of gh pr words, commit on the next line"
[ "$ms" -lt 10000 ] || fail "R35e Imp3: 27 KB took ${ms} ms (bound 10000; the hook timeout is 30 s)"
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
