#!/bin/bash
# push-guard.sh (v6): force/delete, default-branch, unclaimed t/<n>- and needs-ack pushes are blocked.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${PG_HOOK:-$DIR/../../../hooks/scripts/push-guard.sh}"
CLAIM="$DIR/../../../bin/claim"
[ -x "$HOOK" ] || { echo "FAIL: hooks/scripts/push-guard.sh missing or not executable"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*"; exit 1; }
unset DEVFW_CONFIG DEVFW_CORE_DIR CDPATH

CORE="$TMP/core"; mkdir -p "$CORE" "$TMP/fakebin"
CFG='{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api","default":"main"}}}'
echo "$CFG" > "$CORE/orchestrator.json"

# origin (bare) behind the insteadOf trick; W is the managed work clone, U an unmanaged one.
g init -q --bare "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/W" 2>/dev/null
echo x > "$TMP/W/f"; g -C "$TMP/W" add f; g -C "$TMP/W" commit -qm init; g -C "$TMP/W" push -q origin main
git -C "$TMP/W" remote set-url origin https://github.com/acme/api.git
git -C "$TMP/W" config url."$(cygpath -m "$TMP/origin.git" 2>/dev/null || echo "$TMP/origin.git")".insteadOf https://github.com/acme/api.git
"$CLAIM" 41 x --repo-dir "$TMP/W" --base main >/dev/null || fail "setup: claim 41"
"$CLAIM" 12 x --repo-dir "$TMP/W" --base main >/dev/null || fail "setup: claim 12"
g init -q "$TMP/U"; git -C "$TMP/U" remote add origin https://github.com/other/x.git

# fake gh: GH_MODE = ok | ack | fail | slow
cat > "$TMP/fakebin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "${GH_LOG:-/dev/null}"
case "${GH_MODE:-ok}" in
  fail) exit 1 ;;
  slow) sleep 10 ;;
  ack) [ "$*" = "api repos/acme/core/issues/41" ] && { echo '{"labels":[{"name":"needs-ack"}]}'; exit 0; }; exit 1 ;;
  *) case "$*" in "api repos/acme/core/issues/41"|"api repos/acme/core/issues/12") echo '{"labels":[{"name":"p1"}]}'; exit 0 ;; esac; exit 1 ;;
esac
STUB
chmod +x "$TMP/fakebin/gh"
export PATH="$TMP/fakebin:$PATH" DEVFW_CORE_DIR="$CORE" GH_LOG="$TMP/gh.log"

run() {  # run <cwd> <command>
  ERR=$(jq -cn --arg c "$2" --arg cwd "$1" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}' | bash "$HOOK" 2>&1 >/dev/null); RC=$?
  ERR="${ERR//$'\r'/}"
}
expect() { [ "$RC" = "$1" ] || fail "$2: rc=$RC want $1 (stderr: $ERR)"; }
says() { grep -q -- "$1" <<<"$ERR" || fail "$2: stderr lacks '$1': $ERR"; }
W="$TMP/W"; U="$TMP/U"

# --- final-review fences first (they fail fast) ---
# C1 / R20: forms whose dir the old regex triggers missed, run from an UNMANAGED cwd. With HOME=$TMP, ~/W is W.
HOME="$TMP" run "$U" 'cd ~/W && git push origin main'; expect 2 "C1: cd ~/<managed> (home resolves it)"
says 'merge to main goes through the merge gate' "C1: ~ is resolved, not just opaque"
HOME="$TMP" run "$U" 'git -C ~/W push origin main'; expect 2 "C1: -C ~/<managed>"
HOME="$TMP" run "$U" 'cd ~/U && git push --force origin main'; expect 0 "C1: cd ~/<unmanaged> resolves out of scope"
run "$U" 'cd ~nosuchuser/W && git push origin main'; expect 2 "R20 trigger: ~user dir is unknown"
says 'cannot read this push command exactly' "R20 unknown-dir text"
run "$U" 'pushd $D && git push origin main'; expect 2 "R20 trigger: pushd <dynamic>"
run "$U" 'popd && git push origin main'; expect 2 "R20 trigger: popd"
run "$U" "cd '$TMP'/W* && git push origin main"; expect 2 "R20 trigger: glob in cd"
run "$U" "cd '$TMP'/{W,X} && git push origin main"; expect 2 "R20 trigger: brace in cd"
run "$U" "exec git -C '$W' push origin main"; expect 2 "C1: exec with a literal -C scopes against that dir"
says 'merge to main goes through the merge gate' "exec is read exactly"
# I4 / R25: unknown wrappers and aliases
run "$U" "stdbuf -oL git -C '$W' push origin main"; expect 2 "R20 trigger: opaque segment's literal -C dir is managed"
run "$U" "stdbuf -oL git -C '$U' push --force origin main"; expect 0 "opaque segment's literal -C dir is unmanaged"
run "$W" 'winpty git push origin main'; expect 2 "R25: unknown wrapper in a managed cwd"
git -C "$W" config alias.p push; git -C "$W" config alias.s status
run "$W" 'git p origin main'; expect 2 "R25: git alias for push"
says 'cannot read this push command exactly' "alias text"
run "$U" "git -C '$W' p origin main"; expect 2 "R25: alias of the -C repo, unmanaged cwd"
run "$W" 'git s'; expect 0 "R25: alias that is not a push"
git -C "$W" config --unset alias.p; git -C "$W" config --unset alias.s
# --- plan 3 hardening (rulings R27-R31): the final review's measured bypasses, exact commands; all were rc=0 ---
# A / R27: command words fold case, path and .exe
run "$W" 'GIT push origin main'; expect 2 "R27/A: GIT push"
says 'merge to main goes through the merge gate' "R27: GIT is read exactly"
run "$W" 'Git.EXE push origin main'; expect 2 "R27/A: Git.EXE push"
run "$W" 'git PUSH origin main'; expect 2 "R27/A: git PUSH"
# B / R28: interpreter strings mentioning git are opaque with an unknown dir (in scope from any cwd)
run "$W" "script -qc 'git push origin main'"; expect 2 "R28/B: script -qc"
says 'cannot read this push command exactly' "R28 text"
run "$W" "python -c \"import os; os.system('git push origin main')\""; expect 2 "R28/B: python -c"
run "$W" "perl -e 'system(\"git push origin main\")'"; expect 2 "R28/B: perl -e"
run "$U" "bash -c 'cd ~/api && git push origin main'"; expect 2 "R28/B: bash -c from an UNMANAGED cwd (R9 residual)"
run "$U" "python -c \"import os; os.system('git push origin main')\""; expect 2 "R28/B: python -c from an unmanaged cwd"
# C / R29: alias chains
git -C "$W" config alias.q p; git -C "$W" config alias.p push
run "$W" 'git q origin main'; expect 2 "R29/C: q -> p -> push"
says 'cannot read this push command exactly' "R29 text"
git -C "$W" config alias.q s; git -C "$W" config alias.s status
run "$W" 'git q'; expect 0 "R29: chain ending at a builtin the guard does not read"
git -C "$W" config alias.q nosuchalias
run "$W" 'git q origin main'; expect 2 "R29: a step naming an alias that does not resolve"
git -C "$W" config alias.q l1; git -C "$W" config alias.l1 q
run "$W" 'git q origin main'; expect 2 "R29: alias loop (depth > 10)"
git -C "$W" config alias.q '!sh ./x.sh'
run "$W" 'git q origin main'; expect 2 "R29: a shell (!) step"
git -C "$W" config --unset alias.q; git -C "$W" config --unset alias.p; git -C "$W" config --unset alias.s
git -C "$W" config --unset alias.l1
# D / R30: inline alias / config
run "$W" 'git -c alias.x=push x origin main'; expect 2 "R30/D: -c alias.x=push"
says 'cannot read this push command exactly' "R30 text"
run "$W" 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.x GIT_CONFIG_VALUE_0=push git x origin main'; expect 2 "R30/D: GIT_CONFIG_COUNT"
run "$W" "GIT_CONFIG_PARAMETERS=\"'alias.x'='push'\" git x origin main"; expect 2 "R30/D: GIT_CONFIG_PARAMETERS"
run "$W" 'git --config-env=alias.x=V x origin main'; expect 2 "R30/D: --config-env"
run "$W" "GIT_CONFIG_GLOBAL='$TMP/evil' git x origin main"; expect 2 "R30/D: alias from a config file, no push in the text (any)"
# E / R31: CDPATH (U/W does not exist; bash would take W from CDPATH=$TMP)
run "$U" 'cd W && git push origin main'; expect 0 "R31 baseline: no CDPATH, U/W is not a repo"
run "$U" "export CDPATH='$TMP'; cd W && git push origin main"; expect 2 "R31/E: export CDPATH"
run "$U" "CDPATH='$TMP' cd W && git push origin main"; expect 2 "R31/E: CDPATH prefix on cd"
CDPATH="$TMP" run "$U" 'cd W && git push origin main'; expect 2 "R31/E: CDPATH in the hook's environment"
# no-regression in a managed repo
run "$W" 'git push origin t/12-x'; expect 0 "no-regression: claimed push"
run "$W" 'git commit -m x'; expect 0 "no-regression: commit"
run "$W" 'git -c color.ui=never status'; expect 0 "no-regression: harmless -c"
run "$W" 'git -c color.ui=never push origin t/12-x'; expect 0 "no-regression: harmless -c on a claimed push"
run "$W" 'python -c "print(1)"'; expect 0 "no-regression: python without git"
run "$W" 'Git status'; expect 0 "no-regression: Git status"
run "$W" "bash -c 'git status'"; expect 0 "no-regression: interpreter string without a push"
# --- fix round 1 (rulings R27a, R28a; M1, M2) ---
# C1 / R27a: a mis-cased builtin is "command not found" in bash: the push still runs in the cwd
mkdir -p "$TMP/elsewhere"
run "$W" "CD '$TMP/elsewhere'; git push origin main"; expect 2 "R27a/C1: CD does not move the shell"
says 'merge to main goes through the merge gate' "R27a: the push is read in the cwd"
run "$W" "CD '$U'; git push --force origin main"; expect 2 "R27a/C1: CD into an unmanaged repo"
run "$W" 'Cd /tmp || git push origin main'; expect 2 "R27a/C1: Cd ||"
run "$W" "PUSHD '$TMP/elsewhere'; git push origin main"; expect 2 "R27a/C1: PUSHD"
run "$W" "COMMAND cd '$TMP/elsewhere'; git push origin main"; expect 2 "R27a/C1: COMMAND cd"
run "$W" "env cd '$TMP/elsewhere'; git push origin main"; expect 2 "R27a/C1: env cd (pre-existing)"
run "$W" "timeout 5 cd '$TMP/elsewhere'; git push origin main"; expect 2 "R27a/C1: timeout 5 cd (pre-existing)"
run "$W" "cd '$U' && git push --force origin main"; expect 0 "no-regression: a real cd into an unmanaged repo"
# C2 / R28a: the code runner need not be the command word
run "$W" "stdbuf -oL bash -c 'git push origin main'"; expect 2 "R28a/C2: stdbuf -oL bash -c"
says 'cannot read this push command exactly' "R28a text"
run "$W" "flock '$TMP/l' bash -c 'git push origin main'"; expect 2 "R28a/C2: flock bash -c"
run "$W" "winpty python -c \"import os; os.system('git push origin main')\""; expect 2 "R28a/C2: winpty python -c"
run "$U" "stdbuf -oL bash -c 'cd ~/api && git push origin main'"; expect 2 "R28a/C2: from an unmanaged cwd"
# I1 / R28a: code fed on stdin
run "$W" "echo 'git push origin main' | bash"; expect 2 "R28a/I1: echo | bash"
run "$W" "printf 'git push origin main' | sh"; expect 2 "R28a/I1: printf | sh"
run "$W" $'bash <<\'EOF\'\ngit push origin main\nEOF'; expect 2 "R28a/I1: heredoc into bash"
run "$W" $'python - <<\'EOF\'\nimport os; os.system("git push origin main")\nEOF'; expect 2 "R28a/I1: heredoc into python -"
run "$U" "echo 'git push origin main' | bash"; expect 2 "R28a/I1: from an unmanaged cwd"
run "$W" 'git log --oneline -3 | python -c "import sys"'; expect 0 "no-regression: piping data into python -c"
# I2 / R28a: a dynamic command word
run "$U" "\"\$SHELL\" -c 'cd ~/api && git push origin main'"; expect 2 "R28a/I2: \"\$SHELL\" -c from an unmanaged cwd"
# I3 / R28a: an alias called inside an interpreter string
git -C "$W" config alias.p push
run "$W" "bash -c 'git p origin main'"; expect 2 "R28a/I3: alias inside bash -c"
run "$W" "python -c \"import os; os.system('git p origin main')\""; expect 2 "R28a/I3: alias inside python -c"
git -C "$W" config --unset alias.p
# M1: a bare CDPATH assignment
run "$U" "CDPATH='$TMP'; cd W && git push origin main"; expect 2 "M1: CDPATH=...; cd"
# M2: a path component named git is not git
run "$U" 'python tools/git/push_stats.py'; expect 0 "M2: tools/git/ is not the word git"
# --- fix round 2 (ruling R28b, NC1): fed on stdin, whatever the arguments ---
run "$W" "echo 'git push origin main' | bash -s x"; expect 2 "R28b/NC1: | bash -s x"
says 'cannot read this push command exactly' "R28b text"
run "$W" "echo 'git push origin main' | sh -s -- x"; expect 2 "R28b/NC1: | sh -s -- x"
run "$W" "echo 'git push origin main' | bash /dev/stdin"; expect 2 "R28b/NC1: | bash /dev/stdin"
run "$W" "echo 'git push origin main' | python3 /dev/stdin"; expect 2 "R28b/NC1: | python3 /dev/stdin"
run "$W" "echo 'git push origin main' | \"\$SHELL\""; expect 2 "R28b/NC1: | \"\$SHELL\" (dynamic word)"
run "$U" "echo 'cd ~/api && git push origin main' | bash -s x"; expect 2 "R28b/NC1: | bash -s x from an unmanaged cwd"
run "$U" "bash -s x <<< 'cd ~/api && git push origin main'"; expect 2 "R28b/NC1: bash -s x <<< from an unmanaged cwd"
run "$U" "source /dev/stdin <<< 'cd ~/api && git push origin main'"; expect 2 "R28b/NC1: source /dev/stdin <<< from an unmanaged cwd"
run "$W" 'git log | python summarize.py'; expect 0 "no-regression: git log | python summarize.py"
run "$W" 'npm test | tail'; expect 0 "no-regression: npm test | tail"
# --- fix round 3 (rulings R28c, R33): fed on stdin through a subshell, loop or if; verbs as whole words ---
run "$W" "(echo 'git push origin main') | bash"; expect 2 "R28c/NC2: (echo ...) | bash"
says 'cannot read this push command exactly' "R28c text"
run "$W" "echo 'git push origin main' | (bash)"; expect 2 "R28c/NC2: | (bash)"
run "$U" "(echo 'cd ~/api && git push origin main') | bash -s x"; expect 2 "R28c/NC2: (echo ...) | bash -s x from an unmanaged cwd"
run "$W" "echo 'git push origin main' | if true; then bash; fi"; expect 2 "R28c/NC2: | if ... then bash"
run "$W" "echo 'git push origin main' | for i in 1; do bash; done"; expect 2 "R28c/NC2: | for ... do bash"
run "$W" "echo 'git push origin main' | while read -r l; do eval \"\$l\"; done"; expect 2 "R28c/NC2: | while read; eval"
run "$U" "echo 'cd ~/api && git push origin main' | while read -r l; do eval \"\$l\"; done"; expect 2 "R28c/NC2: | while read; eval from an unmanaged cwd"
run "$W" "while read -r l; do eval \"\$l\"; done <<< 'git push origin main'"; expect 2 "R28c/NC2: done <<< ..."
run "$W" "(echo 'git push -q origin main') | bash -s x"; expect 2 "R28c/NC2: real-effect form 1"
run "$W" "echo 'git push -q origin main' | (bash -s x)"; expect 2 "R28c/NC2: real-effect form 2"
run "$W" "echo 'git push -q origin main' | while read -r l; do eval \"\$l\"; done"; expect 2 "R28c/NC2: real-effect form 3"
run "$W" 'gh pr view 5 --json mergeStateStatus | python -c "import sys"'; expect 0 "no-regression: gh pr view | python -c"
run "$W" 'git log --merges | python summarize.py'; expect 0 "no-regression: git log --merges | python"
run "$W" 'git log | grep x'; expect 0 "no-regression: git log | grep x"
run "$W" "pushd sub 2>/dev/null; echo 'git status' | bash"; expect 0 "R33: pushd is not the verb push"
# --- fix round 4 (ruling R28d, NC3): >( ... ) and coproc feed a shell; a runner given a dynamic argument ---
run "$W" "echo 'git push origin main' > >(bash)"; expect 2 "R28d/NC3: > >(bash)"
says 'cannot read this push command exactly' "R28d text"
run "$W" "echo 'git push origin main' >(bash)"; expect 2 "R28d/NC3: >(bash) as an argument"
run "$W" "echo 'git push origin main' 1> >(bash -s x)"; expect 2 "R28d/NC3: 1> >(bash -s x)"
run "$U" "echo 'cd ~/api && git push origin main' > >(bash)"; expect 2 "R28d/NC3: > >(bash) from an unmanaged cwd"
run "$W" "coproc bash; echo 'git push origin main' >&\"\${COPROC[1]}\""; expect 2 "R28d/NC3: coproc bash"
run "$U" "coproc bash; echo 'cd ~/api && git push origin main' >&\"\${COPROC[1]}\""; expect 2 "R28d/NC3: coproc from an unmanaged cwd"
run "$W" "coproc S { bash; }; echo 'git push origin main' >&\"\${S[1]}\""; expect 2 "R28d/NC3: named coproc"
run "$W" "echo 'git push -q origin main' > >(bash)"; expect 2 "R28d/NC3: real-effect form 1"
run "$W" "coproc bash; echo 'git push -q origin main' >&\"\${COPROC[1]}\"; exec {COPROC[1]}>&-; wait"; expect 2 "R28d/NC3: real-effect form 2"
run "$W" "x='git push origin main'; eval \"\$x\""; expect 2 "R28d: eval \"\$x\""
run "$U" "x='cd ~/api && git push origin main'; eval \"\$x\""; expect 2 "R28d: eval \"\$x\" from an unmanaged cwd"
run "$W" "x='git push origin main'; bash -c \"\$x\""; expect 2 "R28d: bash -c \"\$x\""
run "$W" "x='git push origin main'; \$x"; expect 2 "R28d: \$x as the command word"
run "$W" "git commit -F - <<'EOF'
fix: then push and merge; eval and bash and python
EOF"; expect 0 "no-regression: heredoc commit naming push"
run "$W" "git commit -m \"\$(cat <<'EOF'
fix: run python, eval, then push
EOF
)\""; expect 0 "no-regression: \$(cat <<'EOF') commit naming push"
run "$W" "git add -A && git commit -m \"\$(cat <<'EOF'
fix: run python, eval, then push
EOF
)\" && git push origin t/12-x"; expect 0 "no-regression: heredoc commit then a claimed push"
run "$W" 'cat file > out.txt'; expect 0 "no-regression: cat file > out.txt"
run "$W" 'gh pr view 5 --json mergeStateStatus'; expect 0 "no-regression: gh pr view --json mergeStateStatus"
run "$W" 'git push origin t/12-x'; expect 0 "no-regression: claimed push"
run "$W" "find . -name '*.orig' -exec rm {} \\; && git push origin t/12-x"; expect 0 "R28d: a bare {} is not a dynamic argument"
# --- fix round 5 (ruling R28e, NC4; NI1 no-regressions) ---
run "$U" "export X='cd ~/api && git push origin main'; bash -c 'eval \"\$X\"'"; expect 2 "NC4: export carries git into a runner"
says 'cannot read this push command exactly' "NC4 text"
run "$W" "export X='cd ~/api && git push origin main'; bash -c 'eval \"\$X\"'"; expect 2 "NC4: export, managed cwd"
run "$U" "X='cd ~/api && git push origin main' bash -c 'eval \"\$X\"'"; expect 2 "NC4: prefix assignment carries git"
run "$U" "X='cd ~/api && git push origin main' python -c 'import os; os.system(os.environ[\"X\"])'"; expect 2 "NC4: prefix into python os.environ"
run "$W" "x='git push origin main'; eval \"\$x\""; expect 2 "R28e(a): eval \"\$x\" still blocks"
run "$W" "x='git push origin main'; \$x"; expect 2 "R28e(b): \$x command word still blocks"
run "$W" "set -- git push origin main; \"\$@\""; expect 2 "R28e(b): \"\$@\" command word still blocks"
# NI1 (my round-4 regression): ordinary test-then-push chains must stay allowed
run "$W" 'node --test tests/*.mjs && git push origin t/12-x'; expect 0 "NI1: node --test glob then claimed push"
run "$W" 'python -m pytest -k "$K" && git push origin t/12-x'; expect 0 "NI1: pytest -k then claimed push"
run "$W" 'python3 summarize.py *.json && git push origin t/12-x'; expect 0 "NI1: python script + glob"
run "$W" 'bash scripts/run.sh "$1" && git push origin t/12-x'; expect 0 "NI1: bash script file + arg"
run "$W" 'npm run start -- --port "$PORT" && git push origin t/12-x'; expect 0 "NI1: start as an npm arg"
run "$W" 'find . -name "$pat" -delete && git push origin t/12-x'; expect 0 "NI1: find -name with a var"
run "$W" 'sudo -u "$USER" true && git push origin t/12-x'; expect 0 "NI1: sudo with a var option"
run "$W" '"$REPO/scripts/test.sh" && git push origin t/12-x'; expect 0 "NI1: a path with an expansion is the script-file residual"
run "$W" 'ssh "$HOST" uptime && git push origin t/12-x'; expect 0 "NI1: ssh remote command"
# --- ruling R35: an unaccounted mention + a non-data program = one whole-command row, unknown dir ---
PV="printf -v x 'cd ~/W && git push origin main';"
for c in "$PV bash -lc \"\$x\"" "$PV sudo bash -c \"\$x\"" "$PV nohup bash -c \"\$x\"" "$PV bash -c\"\$x\"" \
  "$PV node -p \"require('child_process').execSync(process.argv[1]).toString()\" \"\$x\"" \
  "cmd=(git push origin main); \"\${cmd[@]}\"" "printf -v x 'git push origin main'; \${x:-}" \
  "declare -x X='cd ~/W && git push origin main'; python -c 'import os; os.system(os.environ[\"X\"])'" \
  "printf -v X 'cd ~/W && git push origin main'; export X; python -c 'import os; os.system(os.environ[\"X\"])'" \
  "$PV python -c 'import os,sys; os.system(sys.argv[1])' \"\$x\""; do
  HOME="$TMP" run "$U" "$c"; expect 2 "R35 (NC6-NC9), unmanaged cwd: $c"
done
says 'cannot read this push command exactly' "R35 text"
run "$U" 'npm test && git commit -m "docs: explain git push flow"'; expect 2 "R35 stated cost: a git push in a message beside npm"
# ordinary rows stay allowed (managed cwd)
run "$W" 'BR=$(git branch --show-current); npm test && node scripts/lint.js && git push origin t/12-x'; expect 0 "R35/NI2"
run "$W" 'grep -rn "git push" docs/'; expect 0 "R35: grep is data"
run "$W" "echo 'run git push later' > notes.md"; expect 0 "R35: echo is data"
run "$W" 'git commit -m "docs: explain git push flow"'; expect 0 "R35: a message with git push, no non-data program"
run "$W" "git commit -F - <<'EOF'
docs: explain the git push flow

git push origin t/12-x is how a worker ships.
EOF"; expect 0 "R35: heredoc commit body naming git push"
run "$W" "git commit -m \"\$(cat <<'EOF'
docs: explain the git push flow
EOF
)\" && git push origin t/12-x"; expect 0 "R35: \$(cat <<'EOF') commit naming git push, then a push"
run "$W" "gh pr create --title x --body \"\$(cat <<'EOF'
Explains git push.
EOF
)\""; expect 0 "R35: gh pr create body naming git push"
run "$W" 'npm test && git push origin t/12-x'; expect 0 "R35: a read push accounts for its own mention"
# --- R35 fix round 1: C1 quote-aware run, R35a subscripts / indirection, R35b git runs text, M2 comments ---
for c in "printf -v x 'cd ~/W && git 2>&1 push origin main'; python -c 'import os,sys; os.system(sys.argv[1])' \"\$x\"" \
  "printf -v x 'cd ~/W && git -C \"a;b\" push origin main'; sudo bash -c \"\$x\"" \
  "printf -v x 'cd ~/W && git &>/dev/null push origin main'; sudo bash -c \"\$x\"" \
  "printf -v 'a[\$(cd ~/W && git push origin main)]' x" "declare -i w='r[\$(cd ~/W && git push origin main)]'" \
  "read -r 'b[\$(cd ~/W && git push origin main)]' <<< x" "test -v 'c[\$(cd ~/W && git push origin main)]'" \
  "GIT_SSH_COMMAND='sh -c \"cd ~/W && git push origin main\"' git fetch origin"; do
  HOME="$TMP" run "$U" "$c"; expect 2 "R35 round 1, unmanaged cwd: $c"
done
for c in "git rebase -x 'git push origin main' main" "git submodule foreach 'git push origin main'" \
  "git -c core.sshCommand='sh -c \"git push origin main\"' fetch origin" "git bisect run sh -c 'git push origin main'" \
  "GIT_SSH_COMMAND='sh -c \"git push origin main\"' git fetch origin"; do
  run "$W" "$c"; expect 2 "R35b, managed cwd: $c"
done
run "$W" 'npm test && git commit -m "x" && git push origin t/12-x # git push origin main'; expect 0 "M2: a trailing comment is no mention"
run "$W" "echo 'git log | grep push' && npm test && git push origin t/12-x"; expect 0 "C1: | ends the run"
run "$W" "git rebase -x 'npm test' main"; expect 0 "R35b: rebase -x with no guarded mention"
# C2 / R21: destinations as git resolves them (W is on main)
run "$W" 'git push origin @'; expect 2 "C2: @ is the current branch (main)"
says 'merge to main goes through the merge gate' "@ text"
run "$W" 'git push origin heads/main'; expect 2 "C2: heads/main DWIMs to refs/heads/main"
run "$W" 'git push origin t/41-x:heads/main'; expect 2 "C2: src:heads/main"
run "$W" 'git push origin t/41-x:refs/devfw/x'; expect 0 "refs/devfw/* is not a branch"
run "$W" 'git push origin t/41-x:a..b'; expect 2 "R21: a dst git would not take as a branch"
says 'cannot tell what this push updates' "unresolvable dst text"

run "$W" 'git push origin t/41-x'; expect 0 "claimed, no needs-ack"
run "$W" 'git push -u origin t/41-x:t/41-x'; expect 0 "claimed src:dst"
run "$W" 'git push origin t/41-x:refs/heads/t/41-x'; expect 0 "claimed refs/heads dst"
GH_MODE=ack run "$W" 'git push origin t/41-x'; expect 2 "needs-ack"
says 'devfw push-guard: issue 41 needs-ack: acknowledge the plan change (ack 41 <plan-sha>: ' "needs-ack text"
run "$W" 'git push origin t/42-y'; expect 2 "unclaimed"
says 'no claim for issue 42; run bin/claim first' "unclaimed text"
run "$W" 'git push origin main'; expect 2 "push to default"
says 'merge to main goes through the merge gate, not a push' "default text"
run "$W" 'git push origin HEAD:main'; expect 2 "HEAD:main"
run "$W" 'git push origin t/41-x:main'; expect 2 "src:main"
run "$W" 'git push origin t/41-x --force-with-lease'; expect 2 "force-with-lease"
says 'force-push and remote branch deletion are off (hooks.pushGuard.allowForce)' "force text"
run "$W" 'git push --force origin t/41-x'; expect 2 "--force"
run "$W" 'git push origin +t/41-x'; expect 2 "+refspec"
run "$W" 'git push origin :t/41-x'; expect 2 "delete via :refspec"
run "$W" 'git push origin --delete t/41-x'; expect 2 "--delete"
GH_MODE=fail run "$W" 'git push origin t/41-x'; expect 2 "gh exits 1"
says 'cannot read issue 41' "gh failure text"
DEVFW_HOOK_NET_TIMEOUT=1 GH_MODE=slow run "$W" 'git push origin t/41-x'; expect 2 "gh timeout"
says 'cannot read issue 41' "gh timeout text"
run "$W" 'git push origin feature/free'; expect 0 "ordinary branch"
run "$W" 'git push --tags'; expect 0 "tags are not a branch"
run "$W" 'git push origin refs/tags/v1'; expect 0 "tag ref"
run "$W" 'git push --all'; expect 2 "opaque push in a managed cwd"
says 'cannot read this push command exactly' "opaque text"
run "$W" 'eval "git push origin main"'; expect 2 "eval push in a managed cwd"
run "$W" 'git status'; expect 0 "no push word"
run "$W" 'echo push'; expect 0 "not a git push"

# no refspec: the current branch is the destination
g -C "$W" checkout -q -b t/41-x origin/main 2>/dev/null || g -C "$W" checkout -q t/41-x 2>/dev/null
g -C "$W" fetch -q origin 't/41-x:refs/remotes/origin/t/41-x' 2>/dev/null
run "$W" 'git push'; expect 0 "bare push from claimed branch"
g -C "$W" checkout -q -b t/42-y; run "$W" 'git push'; expect 2 "bare push from unclaimed branch"
run "$W" 'git push origin HEAD'; expect 2 "HEAD from unclaimed branch"
g -C "$W" checkout -q main; run "$W" 'git push'; expect 2 "bare push from main"
g -C "$W" checkout -q --detach; run "$W" 'git push'; expect 2 "detached HEAD"
says 'cannot tell what this push updates' "detached text"
g -C "$W" checkout -q main

# where the push runs
run "$TMP/U" 'git push --force origin main'; expect 0 "unmanaged repo, force to main"
run "$TMP/U" "git -C '$W' push origin main"; expect 2 "-C into a managed repo from an unmanaged cwd"
run "$TMP/U" "cd '$W' && git push origin main"; expect 2 "cd into a managed repo"
run "$TMP/U" 'git push --all'; expect 0 "opaque push in an unmanaged cwd"
run "$W" "git -C '$TMP/U' push --force origin main"; expect 0 "-C into an unmanaged repo from a managed cwd"
git -C "$TMP/U" remote add up https://github.com/acme/api.git
run "$TMP/U" 'git push up main'; expect 2 "another remote that is managed"

# R15: an opaque push is in scope with a non-literal cd / -C, or when the text names a managed repo
run "$TMP/U" 'cd $D && git push origin main'; expect 2 "non-literal cd, unmanaged cwd"
says 'cannot read this push command exactly' "R15 cd text"
run "$TMP/U" 'git -C "$D" push origin main'; expect 2 "non-literal -C, unmanaged cwd"
run "$TMP/U" 'eval "git push https://github.com/acme/api.git main"'; expect 2 "opaque push naming a managed slug"
run "$TMP/U" "cd '$TMP/U' && git push --force origin main"; expect 0 "literal cd to an unmanaged repo"
# R28 adjudication: eval mentioning git now has an unknown dir (was "expect 0": the accepted residual R28 closes)
run "$TMP/U" 'eval "git push other"'; expect 2 "R28: eval push from an unmanaged cwd"
run "$TMP/U" "stdbuf -oL git -C '$TMP/U' push other"; expect 0 "opaque push (R25, dir known), nothing managed named"

# push.default decides what a bare push updates
g -C "$W" checkout -q t/41-x
git -C "$W" config branch.t/41-x.remote origin; git -C "$W" config branch.t/41-x.merge refs/heads/main
run "$W" 'git push'; expect 0 "push.default unset: current branch t/41-x"
git -C "$W" config push.default simple; run "$W" 'git push'; expect 0 "push.default simple"
git -C "$W" config push.default upstream; run "$W" 'git push'; expect 2 "push.default upstream tracking origin/main"
says 'merge to main goes through the merge gate' "upstream text"
git -C "$W" config push.default tracking; run "$W" 'git push origin'; expect 2 "push.default tracking"
run "$W" 'git push origin HEAD'; expect 0 "HEAD is the current branch even with push.default upstream"
git -C "$W" config push.default matching; run "$W" 'git push'; expect 2 "push.default matching"
says 'name the refspec' "matching text"
git -C "$W" config push.default current; run "$W" 'git push'; expect 0 "push.default current"
git -C "$W" config --unset push.default
git -C "$W" config remote.origin.push 'refs/heads/*:refs/heads/*'; run "$W" 'git push'; expect 2 "remote.origin.push set"
says 'name the refspec' "remote.push text"
git -C "$W" config --unset remote.origin.push
git -C "$W" config --unset branch.t/41-x.merge; git -C "$W" config push.default upstream
run "$W" 'git push'; expect 2 "upstream with no branch.merge"
git -C "$W" config --unset push.default; g -C "$W" checkout -q main

# a URL remote is the repo's remote too; non-branch refs
run "$W" 'git push https://github.com/acme/api.git main'; expect 2 "URL remote, default branch"
run "$W" 'git push https://github.com/acme/api.git t/41-x'; expect 0 "URL remote, claimed branch"
run "$W" 'git push https://github.com/acme/api.git t/42-y'; expect 2 "URL remote, unclaimed"
says 'no claim for issue 42' "URL remote text"
run "$W" 'git push origin HEAD:refs/for/main'; expect 2 "other refs/ destination"
says 'unsupported destination' "unsupported text"

# claim fetch failure (origin unreachable)
ORIGP=$(cygpath -m "$TMP/origin.git" 2>/dev/null || echo "$TMP/origin.git")
git -C "$W" config --remove-section url."$ORIGP"
git -C "$W" config url."$TMP/nowhere.git".insteadOf https://github.com/acme/api.git
run "$W" 'git push origin t/41-x'; expect 2 "claim check cannot reach origin"
says 'cannot verify the claim (fetch failed)' "fetch-failed text"
git -C "$W" config --remove-section url."$TMP/nowhere.git"
git -C "$W" config url."$ORIGP".insteadOf https://github.com/acme/api.git
run "$W" 'git push origin t/41-x'; expect 0 "origin restored"

# the claim is checked on the push's own remote, not always origin: `up` is a managed remote with NO claims
g init -q --bare "$TMP/origin2.git"; g -C "$W" push -q "$TMP/origin2.git" main
git -C "$W" remote add up git@github.com:acme/api.git
git -C "$W" config url."$(cygpath -m "$TMP/origin2.git" 2>/dev/null || echo "$TMP/origin2.git")".insteadOf git@github.com:acme/api.git
run "$W" 'git push up t/41-x'; expect 2 "claim looked up on the push's remote"
says 'no claim for issue 41' "remote-specific claim text"

# allowForce
echo '{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api","default":"main"}},"hooks":{"pushGuard":{"allowForce":true}}}' > "$CORE/orchestrator.json"
run "$W" 'git push --force-with-lease origin t/41-x'; expect 0 "allowForce lets a force push through"
run "$W" 'git push --force origin main'; expect 2 "allowForce does not open the default branch"
echo "$CFG" > "$CORE/orchestrator.json"

# a broken parser
mkdir -p "$TMP/badnode"; printf '#!/bin/bash\nexit 1\n' > "$TMP/badnode/node"; chmod +x "$TMP/badnode/node"
OLDP="$PATH"; PATH="$TMP/badnode:$PATH"
run "$W" 'git push origin t/41-x'; expect 2 "parser failure on a push blocks"
run "$W" 'echo hi'; expect 0 "parser failure on an unrelated command"
PATH="$OLDP"

unset DEVFW_CORE_DIR; run "$W" 'git push --force origin main'; expect 0 "DEVFW_CORE_DIR unset"
echo "PASS: push-guard"
